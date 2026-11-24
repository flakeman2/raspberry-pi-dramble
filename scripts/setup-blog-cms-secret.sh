#!/usr/bin/env bash
# Build the SealedSecret for blog-cms-api without printing or committing any
# plaintext credential. Inputs are 0600 files and environment variables; the
# only output is a sealed manifest that is safe to commit.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${OUT:-"$root/cluster/secrets/sealed/blog-cms-api.yaml"}
key_dir=${BLOG_CMS_KEY_DIR:-"$HOME/.kube/blog-cms"}
admin_file=${ADMIN_PASSWORD_FILE:-"$HOME/.kube/unified-admin-password.txt"}
guest_file=${GUEST_PASSWORD_FILE:-"$key_dir/guest-password.txt"}
go_bin=${GO_BIN:-go}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

require_file() {
  local file=$1
  [[ -f "$file" ]] || {
    echo "missing file: $file" >&2
    exit 1
  }
  local mode
  mode=$(stat -c '%a' "$file")
  if [[ "$mode" != "600" ]]; then
    echo "refusing to read $file: mode is $mode, expected 600" >&2
    exit 1
  fi
}

ensure_var() {
  local name=$1
  if [[ -z "${!name:-}" ]]; then
    local value
    read -r -p "$name: " value
    printf -v "$name" '%s' "$value"
  fi
}

for cmd in kubeseal openssl python3 base64 "$go_bin"; do
  require_command "$cmd"
done

ntfy_source=${NTFY_FROM_SECRET:-}
if [[ -n "$ntfy_source" ]]; then
  require_command kubectl
  if [[ "$ntfy_source" != */* ]]; then
    echo "NTFY_FROM_SECRET must be namespace/name" >&2
    exit 1
  fi
  ntfy_ns=${ntfy_source%%/*}
  ntfy_name=${ntfy_source#*/}
  ntfy_full=$(kubectl -n "$ntfy_ns" get secret "$ntfy_name" -o jsonpath='{.data.url}' | base64 -d)
  if [[ -z "$ntfy_full" || "$ntfy_full" != */* ]]; then
    echo "ntfy source secret does not contain a usable url key" >&2
    exit 1
  fi
  NTFY_URL=${ntfy_full%/*}
  NTFY_TOPIC=${ntfy_full##*/}
fi

require_file "$admin_file"
require_file "$guest_file"
require_file "$key_dir/writer.pem"
require_file "$key_dir/publisher.pem"
require_file "$key_dir/approver.pem"

ensure_var WRITER_APP_ID
ensure_var WRITER_INSTALLATION_ID
ensure_var PUBLISHER_APP_ID
ensure_var PUBLISHER_INSTALLATION_ID
ensure_var APPROVER_APP_ID
ensure_var APPROVER_INSTALLATION_ID

session_key=$(openssl rand -base64 48 | tr -d '\n')
admin_password=$(<"$admin_file")
guest_password=$(<"$guest_file")
if [[ -z "$admin_password" || -z "$guest_password" ]]; then
  echo "password files must not be empty" >&2
  exit 1
fi

admin_hash=$(printf '%s' "$admin_password" | "$go_bin" run "$root/services/blog-cms-api/cmd/hashpassword")
guest_hash=$(printf '%s' "$guest_password" | "$go_bin" run "$root/services/blog-cms-api/cmd/hashpassword")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export SECRET_NAME=blog-cms-api
export SECRET_NAMESPACE=blog-cms
export SESSION_KEY="$session_key"
export ADMIN_HASH="$admin_hash"
export GUEST_HASH="$guest_hash"
export WRITER_APP_ID WRITER_INSTALLATION_ID
export PUBLISHER_APP_ID PUBLISHER_INSTALLATION_ID
export APPROVER_APP_ID APPROVER_INSTALLATION_ID
export NTFY_URL="${NTFY_URL:-}"
export NTFY_TOPIC="${NTFY_TOPIC:-}"
export WRITER_PRIVATE_KEY
export PUBLISHER_PRIVATE_KEY
export APPROVER_PRIVATE_KEY
WRITER_PRIVATE_KEY=$(<"$key_dir/writer.pem")
PUBLISHER_PRIVATE_KEY=$(<"$key_dir/publisher.pem")
APPROVER_PRIVATE_KEY=$(<"$key_dir/approver.pem")
export WRITER_PRIVATE_KEY PUBLISHER_PRIVATE_KEY APPROVER_PRIVATE_KEY

python3 - "$tmpdir/secret.json" <<'PY'
import json
import os
import sys

keys = [
    "SESSION_KEY",
    "ADMIN_PASSWORD_HASH",
    "GUEST_PASSWORD_HASH",
    "WRITER_APP_ID",
    "WRITER_INSTALLATION_ID",
    "WRITER_PRIVATE_KEY",
    "PUBLISHER_APP_ID",
    "PUBLISHER_INSTALLATION_ID",
    "PUBLISHER_PRIVATE_KEY",
    "APPROVER_APP_ID",
    "APPROVER_INSTALLATION_ID",
    "APPROVER_PRIVATE_KEY",
    "NTFY_URL",
    "NTFY_TOPIC",
]
source = {
    "SESSION_KEY": "SESSION_KEY",
    "ADMIN_PASSWORD_HASH": "ADMIN_HASH",
    "GUEST_PASSWORD_HASH": "GUEST_HASH",
}
data = {key: os.environ[source.get(key, key)] for key in keys}
secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": os.environ["SECRET_NAME"],
        "namespace": os.environ["SECRET_NAMESPACE"],
    },
    "type": "Opaque",
    "stringData": data,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(secret, handle)
PY

kubeseal --format yaml --scope strict < "$tmpdir/secret.json" > "$out"
chmod 0644 "$out"
echo "wrote $out"
