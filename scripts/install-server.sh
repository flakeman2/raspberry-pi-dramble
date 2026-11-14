#!/usr/bin/env bash
# Install the k3s control-plane node (kube1).
#
# Run on a freshly imaged kube1 as a user with sudo:
#   ./scripts/install-server.sh
#
# Pin K3S_VERSION to reproduce the live cluster. The live cluster runs
# v1.22.5+k3s1, which is end-of-life; see docs/action-items.md before choosing a
# newer version, because the Traefik CRDs in cluster/traefik/ use the
# `traefik.containo.us` API group that only exists in Traefik 2.x.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.22.5+k3s1}"

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
