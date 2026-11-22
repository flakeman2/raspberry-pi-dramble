#!/usr/bin/env bash
# Bidirectional backup between dflake-nettop (this host) and the workstation.
# Designed to run from cron on nettop; also safe to run interactively.
#
#   ./scripts/backup-nettop.sh --preflight   # check tools, SSH, paths; no changes
#   ./scripts/backup-nettop.sh --dry-run     # print the plan, change nothing
#   ./scripts/backup-nettop.sh               # run both legs
#
# Leg 1 (nettop -> workstation): a *consistent* SQLite snapshot of state.db
#   plus the full k3s recovery set, packed as one dated tar.gz.
# Leg 2 (workstation -> nettop): the four small .kube secret artifacts.
#
# Both legs use explicit include lists rather than globs. That is the exclusion
# mechanism: files that belong on only one host are never named, so they cannot
# cross. See the EXCLUDED comments below for the rationale.
#
# Hash comparisons print only PASS/FAIL — never a hash or a secret value.
#
# Cron (root's crontab, daily 03:00):
#   0 3 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/backup-nettop.sh >> /var/log/dramble-backup.log 2>&1
# Running as dflake works too, but needs passwordless `sudo -n` for the
# root-owned k3s files.

set -euo pipefail
cd "$(dirname "$0")/.."

WORKSTATION_USER="${WORKSTATION_USER:-dflake}"
WORKSTATION_HOST="${WORKSTATION_HOST:-192.168.0.54}"
WORKSTATION_TARGET="${WORKSTATION_USER}@${WORKSTATION_HOST}"
# Where the k3s archive lands on the workstation.
WORKSTATION_BACKUP_DIR="${WORKSTATION_BACKUP_DIR:-/home/${WORKSTATION_USER}/.kube/dramble-backup/nettop}"
# Where the workstation's secrets land on nettop (same as backup-secrets.sh).
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/home/dflake/.kube/dramble-backup}"
KEEP_DAYS="${KEEP_DAYS:-30}"
LOCK_DIR="${LOCK_DIR:-/tmp/dramble-backup.lock}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

MODE="${1:-run}"
case "$MODE" in
  --preflight|--dry-run|run) ;;
  *) echo "usage: $0 [--preflight|--dry-run]" >&2; exit 2 ;;
esac

# Workstation files deliberately NOT pulled to nettop:
#   gemini_api_key.txt       workstation-only tool credential, not cluster state
#   config-dramble-k3s.bak   stale duplicate of the live kubeconfig
#   cache/, k3s_state/       transient / obsolete local state
#   dramble-backup/          the incoming nettop archive — must not bounce back
SECRET_FILES=(
  sealed-secrets-private-key-backup.yaml
  dramble-ntfy-topic.txt
  unified-admin-password.txt
  config-dramble-k3s
)

# Nettop files deliberately NOT pushed to the workstation:
#   db/state.db-wal, db/state.db-shm  raw WAL sidecars; a consistent .backup()
#                                    snapshot supersedes them (copying the WAL
#                                    files from a running k3s is not reliable)
#   agent/, logs/, data/              regenerable agent/runtime state
K3S_FILES=(
  /var/lib/rancher/k3s/server/node-token
  /etc/rancher/k3s/k3s.yaml
)
K3S_OPTIONAL_FILES=(
  /var/lib/rancher/k3s/server/token
  /etc/rancher/k3s/config.yaml
)
K3S_DIRS=(
  /var/lib/rancher/k3s/server/tls
  /var/lib/rancher/k3s/server/manifests
)
K3S_DB=/var/lib/rancher/k3s/server/db/state.db

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  root_run() { "$@"; }
else
  root_run() { sudo -n "$@"; }
fi

# SC2029: callers intentionally pass an already-quoted remote command string.
# shellcheck disable=SC2029
ssh_w() { ssh "${SSH_OPTS[@]}" "$WORKSTATION_TARGET" "$@"; }

preflight() {
  local ok=0 p
  for p in ssh scp tar sha256sum find stat mktemp install; do
    command -v "$p" >/dev/null || { log "MISSING local tool: $p"; ok=1; }
  done
  python3 -c 'import sqlite3' 2>/dev/null \
    || { log "MISSING python3 sqlite3 (needed for the consistent DB snapshot)"; ok=1; }

  if [ "$(id -u)" -eq 0 ]; then
    log "OK  running as root"
  elif sudo -n true 2>/dev/null; then
    log "OK  passwordless sudo -n"
  else
    log "MISSING passwordless sudo -n (or run from root's crontab)"; ok=1
  fi

  for p in "$K3S_DB" "${K3S_FILES[@]}" "${K3S_DIRS[@]}"; do
    if root_run test -r "$p" 2>/dev/null; then
      log "OK  readable: $p"
    else
      log "MISSING/UNREADABLE: $p"; ok=1
    fi
  done

  if ssh_w true 2>/dev/null; then
    log "OK  SSH to ${WORKSTATION_TARGET}"
  else
    log "FAIL SSH to ${WORKSTATION_TARGET} (need BatchMode key auth)"; ok=1
  fi

  if [ "$ok" -ne 0 ]; then
    fail "preflight failed — fix the above before scheduling cron"
  fi
  log "preflight OK"
}

# SQLite's online backup API gives a consistent snapshot without stopping k3s.
snapshot_db() {
  local out=$1
  root_run python3 - "$K3S_DB" "$out" <<'PY'
import sqlite3, sys
src = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
src.close()
dst.close()
PY
  root_run chown "$(id -u):$(id -g)" "$out"
}

stage_k3s() {
  local tree=$1 src base
  mkdir -p "$tree/db"
  snapshot_db "$tree/db/state.db"

  for src in "${K3S_FILES[@]}"; do
    base=$(basename "$src")
    root_run install -m 0600 "$src" "$tree/$base"
  done
  for src in "${K3S_OPTIONAL_FILES[@]}"; do
    if root_run test -r "$src" 2>/dev/null; then
      root_run install -m 0600 "$src" "$tree/$(basename "$src")"
    fi
  done
  for src in "${K3S_DIRS[@]}"; do
    if root_run test -d "$src" 2>/dev/null; then
      base=$(basename "$src")
      mkdir -p "$tree/$base"
      # --no-same-owner keeps the staged tree readable by the invoking user.
      root_run tar -C "$(dirname "$src")" -cf - "$base" | tar -C "$tree" -xf - --no-same-owner
    fi
  done

  root_run chown -R "$(id -u):$(id -g)" "$tree"
  (cd "$tree" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
}

verify_pair() {
  # $1 local path, $2 remote path, $3 label. Prints only PASS/FAIL.
  local local_hash remote_hash
  local_hash=$(sha256sum "$1" | cut -d' ' -f1)
  remote_hash=$(ssh_w "sha256sum '$2'" | cut -d' ' -f1)
  if [ "$local_hash" = "$remote_hash" ]; then
    printf '  \033[32mPASS\033[0m  %s (hash matches, values not shown)\n' "$3"
    return 0
  fi
  printf '  \033[31mFAIL\033[0m  %s (remote hash differs)\n' "$3"
  return 1
}

leg_k3s_to_workstation() {
  local stage archive name remote_path fail=0
  stage=$(mktemp -d)
  STAGE=$stage

  log "==> staging k3s recovery set"
  stage_k3s "$stage/tree"

  name="k3s-$(date -u +%F).tar.gz"
  archive="$stage/$name"
  tar -czf "$archive" -C "$stage/tree" .

  log "==> pushing ${name} to ${WORKSTATION_TARGET}:${WORKSTATION_BACKUP_DIR}"
  # SC2029: ${WORKSTATION_BACKUP_DIR} is intentionally expanded on the client;
  # the remote shell receives an already-literal, single-quoted path.
  # shellcheck disable=SC2029
  ssh_w "umask 077; mkdir -p '${WORKSTATION_BACKUP_DIR}' && chmod 700 '${WORKSTATION_BACKUP_DIR}'"
  remote_path="${WORKSTATION_BACKUP_DIR}/${name}"
  # SC2029: same intentional client-side expansion as above.
  # shellcheck disable=SC2029
  scp -q -p "$archive" "${WORKSTATION_TARGET}:${remote_path}" \
    || fail "scp failed for ${name}"
  verify_pair "$archive" "$remote_path" "$name" || fail=1

  # Keep only recent daily archives; print what is removed.
  # shellcheck disable=SC2029
  ssh_w "find '${WORKSTATION_BACKUP_DIR}' -maxdepth 1 -name 'k3s-*.tar.gz' -mtime +${KEEP_DAYS} -print -delete"

  rm -rf "$stage"
  STAGE=""
  return "$fail"
}

leg_secrets_to_nettop() {
  local f remote_src fail=0 mode
  mkdir -p "$LOCAL_BACKUP_DIR"
  chmod 700 "$LOCAL_BACKUP_DIR"

  for f in "${SECRET_FILES[@]}"; do
    remote_src="/home/${WORKSTATION_USER}/.kube/${f}"
    log "==> pulling ${f}"
    # shellcheck disable=SC2029
    if ! ssh_w "test -f '${remote_src}'"; then
      printf '  \033[31mFAIL\033[0m  %s (missing on workstation)\n' "$f"
      fail=1
      continue
    fi
    # shellcheck disable=SC2029
    mode=$(ssh_w "stat -c '%a' '${remote_src}'")
    if [ "$mode" != 600 ]; then
      printf '  \033[31mFAIL\033[0m  %s (mode %s on workstation, expected 600)\n' "$f" "$mode"
      fail=1
      continue
    fi
    scp -q -p "${WORKSTATION_TARGET}:${remote_src}" "${LOCAL_BACKUP_DIR}/${f}" \
      || { printf '  \033[31mFAIL\033[0m  %s (scp failed)\n' "$f"; fail=1; continue; }
    # Here the workstation is the source; compare the local copy against it.
    verify_pair "${LOCAL_BACKUP_DIR}/${f}" "$remote_src" "$f" || fail=1
  done
  return "$fail"
}

case "$MODE" in
  --preflight)
    preflight
    ;;
  --dry-run)
    log "DRY RUN — no changes."
    log "  k3s -> ${WORKSTATION_TARGET}:${WORKSTATION_BACKUP_DIR}/k3s-<date>.tar.gz"
    log "        contains: state.db (consistent snapshot), node-token, k3s.yaml,"
    log "        optional token/config.yaml, tls/, manifests/, SHA256SUMS"
    log "  secrets -> ${LOCAL_BACKUP_DIR}/ ($(IFS=,; echo "${SECRET_FILES[*]}"))"
    log "  excluded: WAL/SHM sidecars, agent/logs/data, gemini_api_key.txt,"
    log "            config-dramble-k3s.bak, cache/, k3s_state/, dramble-backup/"
    log "  retention: delete workstation archives older than ${KEEP_DAYS} days"
    ;;
  run)
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      fail "another backup run holds ${LOCK_DIR} — exiting"
    fi
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; [ -n "${STAGE:-}" ] && rm -rf "$STAGE"' EXIT

    preflight
    fail=0
    leg_k3s_to_workstation || fail=1
    leg_secrets_to_nettop  || fail=1
    echo
    if [ "$fail" -ne 0 ]; then
      fail "one or more legs did not verify — do not treat this backup as complete"
    fi
    log "both legs copied and verified."
    ;;
esac
