#!/usr/bin/env bash
# Install a k3s agent node (kube2, kube3, kube4).
#
# Run on each freshly imaged agent as a user with sudo:
#   sudo K3S_URL=https://192.168.0.61:6443 \
#     K3S_TOKEN="$(sudo cat /var/lib/rancher/k3s/server/node-token)" \
#     ./scripts/install-agent.sh
#
# IMPORTANT: on kube2, make sure only `k3s-agent.service` is enabled. The live
# cluster accumulated a second, broken `k3s.service` unit because a previous
# attempt pointed a server at the non-existent kube-vip VIP 192.168.0.200.
# This script installs only the agent.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.6+k3s1}"

if [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

if [ -z "${K3S_URL:-}" ]; then
  echo "K3S_URL is required, e.g. https://192.168.0.61:6443" >&2
  exit 1
fi
if [ -z "${K3S_TOKEN:-}" ]; then
  echo "K3S_TOKEN is required (from /var/lib/rancher/k3s/server/node-token on kube1)" >&2
  exit 1
fi

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="agent" \
  sh -

systemctl disable --now k3s 2>/dev/null || true
systemctl enable --now k3s-agent

echo "k3s agent installed: $(k3s --version | head -1)"
