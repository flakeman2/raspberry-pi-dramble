#!/usr/bin/env bash
# Bootstrap a fresh cluster for GitOps.
#
# This script no longer installs the add-ons or workloads one by one. It does
# only the imperative steps Argo CD cannot do for itself:
#
#   1. restore the sealed-secrets private key and apply the sealed manifests;
#   2. create namespaces (every Application uses CreateNamespace=false);
#   3. install Argo CD from gitops/bootstrap/values.yaml;
#   4. apply the root app-of-apps, which owns the AppProject and all fourteen
#      child Applications;
#   5. wait for the cluster to converge, then install Argo CD's own public
#      IngressRoute (it needs the Traefik CRDs the root app installs).
#
# Run from the repository root after k3s is up on all nodes and kubeconfig is
# pointed at the cluster:
#   export KUBECONFIG=~/.kube/config-dramble-k3s
#   ./scripts/install-addons.sh
#
# `--print-pins` is a pure, offline mode that prints the version pins. CI,
# check-updates.sh and verify-docs.sh currently grep the declarations directly;
# the mode exists for tooling that wants the values without a kubeconfig.
#
# Prerequisites:
#   - kubectl and helm 3 installed on the machine running this script
#   - the sealed-secrets private key backup, if this is a fresh cluster:
#     see cluster/secrets/README.md (sealed manifests cannot be unsealed
#     without the key that encrypted them)
set -euo pipefail

cd "$(dirname "$0")/.."

TRAEFIK_CHART_VERSION=42.4.1
PROMETHEUS_CHART_VERSION=29.47.2
GRAFANA_CHART_VERSION=14.5.0
LONGHORN_VERSION=1.13.0
METALLB_VERSION=0.16.2

print_pins() {
  printf 'TRAEFIK_CHART_VERSION=%s\n' "$TRAEFIK_CHART_VERSION"
  printf 'PROMETHEUS_CHART_VERSION=%s\n' "$PROMETHEUS_CHART_VERSION"
  printf 'GRAFANA_CHART_VERSION=%s\n' "$GRAFANA_CHART_VERSION"
  printf 'LONGHORN_VERSION=%s\n' "$LONGHORN_VERSION"
  printf 'METALLB_VERSION=%s\n' "$METALLB_VERSION"
}

if [ "${1:-}" = "--print-pins" ]; then
  print_pins
  exit 0
fi

if [ $# -ne 0 ]; then
  echo "unknown argument: $1" >&2
  exit 2
fi

: "${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}"

if ! command -v helm >/dev/null; then
  echo "helm is required: https://helm.sh/docs/intro/install/" >&2
  exit 1
fi

require_secret() {
  local ns=$1 name=$2
  if ! kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    echo "missing Secret $ns/$name" >&2
    return 1
  fi
}

# Sealed manifests are encrypted to a specific controller key. On a fresh
# cluster the controller generates a new key and then cannot read anything in
# cluster/secrets/sealed/ — so restore the backup BEFORE starting it, while
# there is still no key of its own to conflict with.
KEY_BACKUP="${SEALED_SECRETS_KEY_BACKUP:-$HOME/.kube/sealed-secrets-private-key-backup.yaml}"
if [ -f "$KEY_BACKUP" ]; then
  echo "==> restoring sealed-secrets key from ${KEY_BACKUP}"
  kubectl apply -f "$KEY_BACKUP"
else
  echo "==> WARNING: no sealed-secrets key backup at ${KEY_BACKUP}" >&2
  echo "   On a brand-new cluster this is fatal: the controller will mint a" >&2
  echo "   fresh key and every manifest in cluster/secrets/sealed/ will fail" >&2
  echo "   to unseal. Copy the backup to that path first." >&2
fi

echo "==> namespaces"
kubectl apply -f cluster/namespaces.yaml

echo "==> sealed manifests"
# The controller is installed by the root app below. It will unseal these as
# soon as it starts; no addon Application needs to wait for that here.
kubectl apply -f cluster/secrets/sealed/

echo "==> Argo CD"
ARGOCD_CHART_VERSION=$(grep -oE 'chart .argo-cd. [0-9.]+' gitops/bootstrap/values.yaml | grep -oE '[0-9.]+$')
if [ -z "$ARGOCD_CHART_VERSION" ]; then
  echo "cannot read the argo-cd chart pin from gitops/bootstrap/values.yaml" >&2
  exit 1
fi
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --version "$ARGOCD_CHART_VERSION" \
  -f gitops/bootstrap/values.yaml --wait --timeout 10m

echo "==> root app-of-apps"
kubectl apply -f gitops/bootstrap/root-app.yaml

echo "==> waiting for Argo CD to converge"
missing=1
for _ in $(seq 1 60); do
  missing=0
  bad=$(kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
    | grep -vcE '^Synced Healthy$' || true)
  [ "$bad" -eq 0 ] || missing=1

  require_secret default authsecret || missing=1
  require_secret default dyn-dns-credentials || missing=1
  require_secret monitoring grafana || missing=1
  # The Alertmanager StatefulSet mounts this Secret; without it the pod stays
  # Pending even though the chart itself renders fine.
  require_secret monitoring alertmanager-ntfy || missing=1
  # The CMS Deployment has envFrom on this Secret and cannot start without it.
  require_secret blog-cms blog-cms-api || missing=1

  [ "$missing" -eq 0 ] && break
  sleep 10
done
if [ "$missing" -ne 0 ]; then
  echo
  echo "the cluster did not converge within 10 minutes." >&2
  echo "Check: kubectl -n argocd get applications" >&2
  echo "       kubectl -n kube-system logs deploy/sealed-secrets-controller" >&2
  echo "Most likely the key backup is missing or belongs to another cluster." >&2
  echo "See cluster/secrets/README.md and docs/gitops.md#secrets." >&2
  exit 1
fi

echo "==> Argo CD IngressRoute"
# Deliberately after convergence: this manifest uses Traefik CRDs, which the
# root app installs as part of traefik-config. An earlier apply fails on a
# genuinely fresh cluster.
kubectl wait --for condition=established --timeout=60s \
  crd/ingressroutes.traefik.io crd/middlewares.traefik.io crd/tlsoptions.traefik.io
kubectl apply -f gitops/bootstrap/ingressroute.yaml

echo
echo "done. Check: kubectl get nodes,pods -A"
