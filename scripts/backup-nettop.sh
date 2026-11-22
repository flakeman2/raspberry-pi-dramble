#!/usr/bin/env bash
# Bidirectional backup between dflake-nettop (this host) and the workstation.
# Runs as dflake from dflake's crontab — no sudo is needed or used.
#
#   ./scripts/backup-nettop.sh --preflight   # check tools, SSH, staged tree; no changes
#   ./scripts/backup-nettop.sh --dry-run     # print the plan, change nothing
#   ./scripts/backup-nettop.sh               # run both legs
#
# Leg 1 (nettop -> workstation): ships the root-staged k3s recovery set
#   (scripts/stage-k3s-snapshot.sh) as a dated tar.gz, then clears the READY
#   marker. A tree without READY is skipped — that means root's cron has not
#   produced a new set, or this script already shipped it.
# Leg 2 (workstation -> nettop): the four small .kube secret artifacts.
#
# Both legs use explicit include lists rather than globs. That is the exclusion
# mechanism: files that belong on only one host are never named, so they cannot
# cross. See the EXCLUDED comments below for the rationale.
#
# Hash comparisons print only PASS/FAIL — never a hash or a secret value.
# Remote calls retry on transient failure (the workstation is a laptop that can
# suspend or restart sshd mid-run); leg 2 uses one SSH call for the manifest and
# one scp for all files, instead of several connections per file.
#
# Two crontabs, five minutes apart:
#   root:    55 2 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/stage-k3s-snapshot.sh >> /var/log/dramble-stage-k3s.log 2>&1
#   dflake:   0 3 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/backup-nettop.sh >> /home/dflake/backup-nettop.log 2>&1

set -euo pipefail
cd "$(dirname "$0")/.."

WORKSTATION_USER="${WORKSTATION_USER:-dflake}"
WORKSTATION_HOST="${WORKSTATION_HOST:-192.168.0.54}"
WORKSTATION_TARGET="${WORKSTATION_USER}@${WORKSTATION_HOST}"
# Where the k3s archive lands on the workstation.
WORKSTATION_BACKUP_DIR="${WORKSTATION_BACKUP_DIR:-/home/${WORKSTATION_USER}/.kube/dramble-backup/nettop}"
# Where root stages the k3s tree, and where the workstation secrets land.
STAGING_DIR="${STAGING_DIR:-/home/dflake/.kube/dramble-backup/staging}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-/home/dflake/.kube/dramble-backup}"
KEEP_DAYS="${KEEP_DAYS:-30}"
RETRIES="${RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-5}"
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

# Nettop staging files deliberately NOT pushed to the workstation:
#   db/state.db-wal, db/state.db-shm  raw WAL sidecars; the consistent snapshot
#                                    in db/state.db supersedes them
#   agent/, logs/, data/              regenerable agent/runtime state
# These are produced by stage-k3s-snapshot.sh, never by this script.

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

# SC2029: callers intentionally pass an already-quoted remote command string.
# shellcheck disable=SC2029
ssh_w() { ssh "${SSH_OPTS[@]}" "$WORKSTATION_TARGET" "$@"; }

# Retry remote calls: a refused connection is not evidence that a file is
# missing, and the workstation can be briefly unavailable mid-cron.
ssh_retry() {
  local n=1
  while :; do
    if ssh_w "$@"; then return 0; fi
    if [ "$n" -ge "$RETRIES" ]; then return 1; fi
    printf '  remote call failed (attempt %s/%s); retrying in %ss\n' "$n" "$RETRIES" "$RETRY_DELAY" >&2
    sleep "$RETRY_DELAY"
    n=$((n + 1))
  done
}

scp_retry() {
  local n=1
  while :; do
    if scp -q -p "$@"; then return 0; fi
    if [ "$n" -ge "$RETRIES" ]; then return 1; fi
    printf '  scp failed (attempt %s/%s); retrying in %ss\n' "$n" "$RETRIES" "$RETRY_DELAY" >&2
    sleep "$RETRY_DELAY"
    n=$((n + 1))
  done
}

preflight() {
  local ok=0 p
  for p in ssh scp tar sha256sum find stat mktemp install; do
    command -v "$p" >/dev/null || { log "MISSING local tool: $p"; ok=1; }
  done

  if [ -d "$STAGING_DIR" ]; then
    if [ -r "$STAGING_DIR" ]; then
      log "OK  staging tree: ${STAGING_DIR}"
    else
      log "UNREADABLE staging tree: ${STAGING_DIR}"; ok=1
    fi
    if [ -f "$STAGING_DIR/READY" ]; then
      log "OK  READY marker present — leg 1 has a new set to ship"
    else
      log "INFO no READY marker — leg 1 will skip (root cron has not staged a new set)"
    fi
  else
    log "INFO staging tree absent — root cron has not run yet; leg 1 will skip"
  fi

  if ssh_retry true 2>/dev/null; then
    log "OK  SSH to ${WORKSTATION_TARGET}"
  else
    log "FAIL SSH to ${WORKSTATION_TARGET} (need BatchMode key auth)"; ok=1
  fi

  if [ "$ok" -ne 0 ]; then
    fail "preflight failed — fix the above before scheduling cron"
  fi
  log "preflight OK"
}

verify_pair() {
  # $1 local path, $2 remote path, $3 label. Prints only PASS/FAIL.
  # Returns 2 for a transport failure, 1 for a hash mismatch.
  local local_hash remote_hash
  local_hash=$(sha256sum "$1" | cut -d' ' -f1) || return 2
  remote_hash=$(ssh_retry "sha256sum '$2'" | cut -d' ' -f1) || return 2
  if [ "$local_hash" = "$remote_hash" ]; then
    printf '  \033[32mPASS\033[0m  %s (hash matches, values not shown)\n' "$3"
    return 0
  fi
  printf '  \033[31mFAIL\033[0m  %s (remote hash differs)\n' "$3"
  return 1
}

leg_k3s_to_workstation() {
  local stage archive name remote_path fail=0

  if [ ! -f "$STAGING_DIR/READY" ]; then
    log "==> no READY marker in ${STAGING_DIR} — nothing new to ship, skipping"
    return 0
  fi

  stage=$(mktemp -d)
  STAGE=$stage
  name="k3s-$(date -u +%F).tar.gz"
  archive="$stage/$name"
  tar --exclude=READY -czf "$archive" -C "$STAGING_DIR" .
  chmod 600 "$archive"

  log "==> pushing ${name} to ${WORKSTATION_TARGET}:${WORKSTATION_BACKUP_DIR}"
  # SC2029: ${WORKSTATION_BACKUP_DIR} is intentionally expanded on the client;
  # the remote shell receives an already-literal, single-quoted path.
  # shellcheck disable=SC2029
  ssh_retry "umask 077; mkdir -p '${WORKSTATION_BACKUP_DIR}' && chmod 700 '${WORKSTATION_BACKUP_DIR}'" \
    || fail "cannot prepare ${WORKSTATION_TARGET}:${WORKSTATION_BACKUP_DIR}"
  remote_path="${WORKSTATION_BACKUP_DIR}/${name}"
  # SC2029: same intentional client-side expansion as above.
  # shellcheck disable=SC2029
  scp_retry "$archive" "${WORKSTATION_TARGET}:${remote_path}" \
    || fail "scp failed for ${name} after ${RETRIES} attempts"

  if verify_pair "$archive" "$remote_path" "$name"; then
    # Only clear READY after a verified copy; a failure leaves it for the next run.
    rm -f "$STAGING_DIR/READY"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf '  \033[31mFAIL\033[0m  %s (workstation unreachable for verification)\n' "$name"
    fi
    fail=1
  fi

  # Keep only recent daily archives; print what is removed.
  # shellcheck disable=SC2029
  ssh_retry "find '${WORKSTATION_BACKUP_DIR}' -maxdepth 1 -name 'k3s-*.tar.gz' -mtime +${KEEP_DAYS} -print -delete" \
    || log "WARN retention cleanup failed on ${WORKSTATION_HOST}"

  rm -rf "$stage"
  STAGE=""
  return "$fail"
}

leg_secrets_to_nettop() {
  local manifest line name mode remote_hash local_hash f remote_dir remote_list="" failed=0
  declare -A expect=()
  mkdir -p "$LOCAL_BACKUP_DIR"
  chmod 700 "$LOCAL_BACKUP_DIR"
  remote_dir="/home/${WORKSTATION_USER}/.kube"

  for f in "${SECRET_FILES[@]}"; do
    remote_list+=" '${f}'"
  done

  log "==> reading workstation secret manifest (one SSH call)"
  # One remote call for all four files: name, mode, sha256 — or MISSING.
  # SC2029: ${remote_dir} and ${remote_list} intentionally expand client-side;
  # the \$f escapes are for the remote shell's loop variable.
  # shellcheck disable=SC2029
  if ! manifest=$(ssh_retry "cd '${remote_dir}' || exit 1; for f in ${remote_list}; do if [ -f \"\$f\" ]; then printf '%s %s %s\\n' \"\$f\" \"\$(stat -c %a \"\$f\")\" \"\$(sha256sum \"\$f\" | cut -d' ' -f1)\"; else printf '%s MISSING -\\n' \"\$f\"; fi; done"); then
    fail "workstation unreachable for the secrets leg — check sshd on ${WORKSTATION_HOST}"
  fi

  for f in "${SECRET_FILES[@]}"; do
    line=$(printf '%s\n' "$manifest" | awk -v want="$f" '$1 == want { print; exit }')
    if [ -z "$line" ]; then
      printf '  \033[31mFAIL\033[0m  %s (no manifest entry — workstation unreachable or file vanished)\n' "$f"
      failed=1
      continue
    fi
    read -r name mode remote_hash <<< "$line"
    if [ "$mode" = "MISSING" ]; then
      printf '  \033[31mFAIL\033[0m  %s (missing on workstation)\n' "$f"
      failed=1
      continue
    fi
    if [ "$mode" != "600" ]; then
      printf '  \033[31mFAIL\033[0m  %s (mode %s on workstation, expected 600)\n' "$f" "$mode"
      failed=1
      continue
    fi
    expect["$f"]="$remote_hash"
  done

  if [ "${#expect[@]}" -eq 0 ]; then
    return "$failed"
  fi

  log "==> pulling ${#expect[@]} file(s) (one scp)"
  sources=()
  for f in "${!expect[@]}"; do
    sources+=("${WORKSTATION_TARGET}:${remote_dir}/${f}")
  done
  if ! scp_retry "${sources[@]}" "${LOCAL_BACKUP_DIR}/"; then
    for f in "${!expect[@]}"; do
      printf '  \033[31mFAIL\033[0m  %s (scp failed after %s attempts)\n' "$f" "$RETRIES"
    done
    return 1
  fi

  for f in "${!expect[@]}"; do
    local_hash=$(sha256sum "${LOCAL_BACKUP_DIR}/${f}" | cut -d' ' -f1)
    if [ "$local_hash" = "${expect[$f]}" ]; then
      printf '  \033[32mPASS\033[0m  %s (hash matches, values not shown)\n' "$f"
    else
      printf '  \033[31mFAIL\033[0m  %s (local hash differs from workstation manifest)\n' "$f"
      failed=1
    fi
  done
  return "$failed"
}

case "$MODE" in
  --preflight)
    preflight
    ;;
  --dry-run)
    log "DRY RUN — no changes."
    log "  root staging -> ${STAGING_DIR}/ (separate root cron, 02:55)"
    log "  k3s -> ${WORKSTATION_TARGET}:${WORKSTATION_BACKUP_DIR}/k3s-<date>.tar.gz"
    log "        contains: state.db (consistent snapshot), node-token, k3s.yaml,"
    log "        optional token/config.yaml, tls/, manifests/, SHA256SUMS"
    log "  secrets -> ${LOCAL_BACKUP_DIR}/ ($(IFS=,; echo "${SECRET_FILES[*]}"))"
    log "  excluded: WAL/SHM sidecars, agent/logs/data, gemini_api_key.txt,"
    log "            config-dramble-k3s.bak, cache/, k3s_state/, dramble-backup/"
    log "  retention: delete workstation archives older than ${KEEP_DAYS} days"
    log "  retries: ${RETRIES} attempts, ${RETRY_DELAY}s apart"
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
