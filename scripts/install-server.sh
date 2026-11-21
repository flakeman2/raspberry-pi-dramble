#!/usr/bin/env bash
# Install the k3s control-plane node (dflake-nettop).
#
# Run on the x86_64 server as a user with sudo:
#   sudo ./scripts/install-server.sh
#
# The node is tainted so workloads never compete with the kine datastore for
# its disk. NETTOP_IP overrides the TLS SAN if the server is re-addressed.
#
# Pin K3S_VERSION to reproduce the live cluster. The target stack is
# v1.36.6+k3s1 — the newest minor that both Longhorn 1.13 (1.33-1.36) and
# Argo CD 3.6 (1.34-1.37) support together. See docs/upgrade.md for the full
# component matrix; bump this only alongside the add-on pins in
# scripts/install-addons.sh.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.6+k3s1}"
NETTOP_IP="${NETTOP_IP:-192.168.0.44}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server --disable servicelb --disable local-storage --disable traefik --tls-san ${NETTOP_IP} --tls-san dflake-nettop --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule" \
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
