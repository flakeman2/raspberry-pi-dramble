#!/usr/bin/env bash
# Install the k3s control-plane node (kube1).
#
# Run on a freshly imaged kube1 as a user with sudo:
#   ./scripts/install-server.sh
#
# Pin K3S_VERSION to reproduce the live cluster. The target stack is
# v1.36.6+k3s1 — the newest minor that both Longhorn 1.13 (1.33-1.36) and
# Argo CD 3.6 (1.34-1.37) support together. See docs/upgrade.md for the full
# component matrix; bump this only alongside the add-on pins in
# scripts/install-addons.sh.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.6+k3s1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server --disable servicelb --disable local-storage --disable traefik" \
  sh -

echo "waiting for the node to register..."
for _ in $(seq 1 60); do
  if k3s kubectl get node "$(hostname)" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo
echo "k3s server installed: $(k3s --version | head -1)"
echo "join token: $(cat /var/lib/rancher/k3s/server/node-token)"
echo "kubeconfig: /etc/rancher/k3s/k3s.yaml"
