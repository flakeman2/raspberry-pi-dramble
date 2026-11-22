#!/usr/bin/env bash
# Copy the workstation-side Drumble secret artifacts to dflake-nettop.
#
# The sealed-secrets private key is the load-bearing one: every file in
# cluster/secrets/sealed/ is unrecoverable without it. The ntfy topic URL and
# the unified admin password are also confidential and exist only here. None
# of these belong in git, and none of them are ever printed by this script —
# verification compares SHA-256 values and reports only PASS or FAIL.
#
# Run on the workstation (not on nettop). SSH must already work:
#
#   ./scripts/backup-secrets.sh --dry-run   # print the commands, change nothing
#   ./scripts/backup-secrets.sh             # copy and verify
#   NETTOP_USER=someone NETTOP_HOST=192.168.0.44 ./scripts/backup-secrets.sh
#
# The k3s datastore files (state.db + WAL + join token) are handled separately
# by the control-plane procedure; this script is for the small .kube secrets.
# Exit 0 only if every file copied and verified.

set -euo pipefail
cd "$(dirname "$0")/.."

NETTOP_USER="${NETTOP_USER:-dflake}"
NETTOP_HOST="${NETTOP_HOST:-192.168.0.44}"
REMOTE_DIR="${REMOTE_DIR:-/home/${NETTOP_USER}/.kube/dramble-backup}"
SOURCE_DIR="${SOURCE_DIR:-${HOME}/.kube}"
TARGET="${NETTOP_USER}@${NETTOP_HOST}"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Deliberately an explicit list rather than a glob: a stray credential file in
# ~/.kube must never be swept up by accident.
FILES=(
  sealed-secrets-private-key-backup.yaml
  dramble-ntfy-topic.txt
  unified-admin-password.txt
  config-dramble-k3s
)

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN — no changes. With the current settings this would run:"
  echo "  ssh ${TARGET} \"umask 077; mkdir -p '${REMOTE_DIR}'; chmod 700 '${REMOTE_DIR}'\""
  for f in "${FILES[@]}"; do
    echo "  scp -p '${SOURCE_DIR}/${f}' '${TARGET}:${REMOTE_DIR}/${f}'"
    echo "  ssh ${TARGET} \"sha256sum '${REMOTE_DIR}/${f}'\"   # compared locally"
  done
  exit 0
fi

mkdir -p "$SOURCE_DIR"
for f in "${FILES[@]}"; do
  src="${SOURCE_DIR}/${f}"
  if [ ! -f "$src" ]; then
    echo "missing local file: ${src}" >&2
    exit 1
  fi
  mode=$(stat -c '%a' "$src")
  if [ "$mode" != "600" ]; then
    echo "${src} is mode ${mode}, expected 600 — run: chmod 600 '${src}'" >&2
    exit 1
  fi
done

echo "==> preparing ${TARGET}:${REMOTE_DIR}"
# SC2029: expanding ${REMOTE_DIR} here on the client is intentional — the
# remote shell receives the already-literal path inside single quotes.
# shellcheck disable=SC2029
ssh "$TARGET" "umask 077; mkdir -p '${REMOTE_DIR}' && chmod 700 '${REMOTE_DIR}'"

fail=0
for f in "${FILES[@]}"; do
  src="${SOURCE_DIR}/${f}"
  echo "==> ${f}"
  scp -q -p "$src" "${TARGET}:${REMOTE_DIR}/${f}"

  local_hash=$(sha256sum "$src" | cut -d' ' -f1)
  # SC2029: same as above — ${REMOTE_DIR} and ${f} must expand client-side.
  # shellcheck disable=SC2029
  remote_hash=$(ssh "$TARGET" "sha256sum '${REMOTE_DIR}/${f}'" | cut -d' ' -f1)
  if [ "$local_hash" = "$remote_hash" ]; then
    printf '  \033[32mPASS\033[0m  %s (hash matches, values not shown)\n' "$f"
  else
    printf '  \033[31mFAIL\033[0m  %s (remote hash differs)\n' "$f"
    fail=1
  fi
done

echo
if [ "$fail" -ne 0 ]; then
  echo "one or more files did not verify — do not treat the backup as complete" >&2
  exit 1
fi
echo "all ${#FILES[@]} files copied and verified at mode 0600 in a 0700 directory."
echo "Re-run any time; scp overwrites in place and the hashes are compared again."
