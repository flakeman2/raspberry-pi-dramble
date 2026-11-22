#!/usr/bin/env bash
# Run as root on dflake-nettop from root's crontab.
#
# Stages a consistent k3s recovery set into a dflake-owned directory so that
# scripts/backup-nettop.sh can ship it to the workstation with *no sudo at all*.
# The READY marker is written last: the unprivileged script only ships a tree
# that has it, and removes it after a verified transfer.
#
#   sudo ./scripts/stage-k3s-snapshot.sh --dry-run
#   sudo ./scripts/stage-k3s-snapshot.sh
#
# root's crontab, daily 02:55 — five minutes before dflake's transfer:
#   55 2 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/stage-k3s-snapshot.sh >> /var/log/dramble-stage-k3s.log 2>&1

set -euo pipefail
cd "$(dirname "$0")/.."

STAGING_DIR="${STAGING_DIR:-/home/dflake/.kube/dramble-backup/staging}"
BACKUP_ROOT=$(dirname "$STAGING_DIR")
OWNER="${OWNER:-dflake}"
GROUP="${GROUP:-$(id -gn "$OWNER")}"
LOCK_DIR="${LOCK_DIR:-/tmp/dramble-stage-k3s.lock}"
K3S_DB=/var/lib/rancher/k3s/server/db/state.db
PYTHON_BIN=$(command -v python3 || true)

MODE="${1:-run}"
case "$MODE" in
  --dry-run|run) ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

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

log()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }

stage() {
  local work=$1 src base
  mkdir -p "$work/db"

  # SQLite's online backup API gives a consistent snapshot without stopping
  # k3s. Copying state.db plus its WAL sidecars from a live server is not safe.
  "$PYTHON_BIN" - "$K3S_DB" "$work/db/state.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst:
    src.backup(dst)
src.close()
dst.close()
PY

  for src in "${K3S_FILES[@]}"; do
    install -m 0600 -o "$OWNER" -g "$GROUP" "$src" "$work/$(basename "$src")"
  done
  for src in "${K3S_OPTIONAL_FILES[@]}"; do
    if [ -r "$src" ]; then
      install -m 0600 -o "$OWNER" -g "$GROUP" "$src" "$work/$(basename "$src")"
    fi
  done
  for src in "${K3S_DIRS[@]}"; do
    if [ -d "$src" ]; then
      base=$(basename "$src")
      tar -C "$(dirname "$src")" -cf - "$base" | tar -C "$work" -xf -
    fi
  done

  chown -R "$OWNER:$GROUP" "$work"
  (cd "$work" && find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
  chown "$OWNER:$GROUP" "$work/SHA256SUMS"

  # Written only after everything above succeeded.
  : > "$work/READY"
  chown "$OWNER:$GROUP" "$work/READY"
}

case "$MODE" in
  --dry-run)
    log "DRY RUN — no changes."
    log "  stage ${STAGING_DIR}/ as ${OWNER}:${GROUP}:"
    log "    db/state.db (consistent SQLite snapshot), node-token, k3s.yaml,"
    log "    optional token/config.yaml, tls/, manifests/, SHA256SUMS, READY"
    log "  then atomically replace the previous staged tree"
    ;;
  run)
    if [ "$(id -u)" -ne 0 ]; then
      fail "must run as root (this is root's half of the backup)"
    fi
    command -v "$PYTHON_BIN" >/dev/null 2>&1 || [ -x "$PYTHON_BIN" ] \
      || fail "python3 with sqlite3 is required for the consistent DB snapshot"
    [ -r "$K3S_DB" ] || fail "cannot read ${K3S_DB}"

    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      fail "another staging run holds ${LOCK_DIR} — exiting"
    fi
    WORK=""
    trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; [ -n "$WORK" ] && rm -rf "$WORK"' EXIT

    install -d -m 0700 -o "$OWNER" -g "$GROUP" "$BACKUP_ROOT"
    WORK=$(mktemp -d "${BACKUP_ROOT}/.stage.XXXXXX")
    stage "$WORK"

    if [ -d "$STAGING_DIR" ]; then
      mv "$STAGING_DIR" "${STAGING_DIR}.old"
    fi
    mv "$WORK" "$STAGING_DIR"
    WORK=""
    if [ -d "${STAGING_DIR}.old" ]; then
      rm -rf "${STAGING_DIR}.old"
    fi

    log "staged k3s recovery set at ${STAGING_DIR} (READY written)"
    ;;
esac
