#!/usr/bin/env bash
# Install the cluster add-ons and workloads from this repository.
#
# Run from the repository root after k3s is up on all nodes and kubeconfig is
# pointed at the cluster:
#   export KUBECONFIG=~/.kube/config-dramble-k3s
#   ./scripts/install-addons.sh
#
# Prerequisites:
#   - kubectl and helm 3 installed on the machine running this script
#   - the sealed-secrets private key backup, if this is a fresh cluster:
#     see cluster/secrets/README.md (sealed manifests cannot be unsealed
#     without the key that encrypted them)
set -euo pipefail

cd "$(dirname "$0")/.."

: "${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}"

TRAEFIK_CHART_VERSION=42.4.1
PROMETHEUS_CHART_VERSION=29.47.2
GRAFANA_CHART_VERSION=14.5.0
LONGHORN_VERSION=1.13.0
METALLB_VERSION=0.16.2

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

echo "==> sealed-secrets controller"
kubectl apply -f cluster/sealed-secrets/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=5m

echo "==> required Secrets (unsealed from cluster/secrets/sealed/)"
kubectl apply -f cluster/secrets/sealed/

# The controller unseals asynchronously — wait for it instead of failing.
missing=1
for _ in $(seq 1 30); do
  missing=0
  require_secret default authsecret || missing=1
  require_secret default dyn-dns-credentials || missing=1
  require_secret monitoring grafana || missing=1
  [ "$missing" -eq 0 ] && break
  sleep 2
done
if [ "$missing" -ne 0 ]; then
  echo
  echo "the controller did not unseal the Secrets within 60s." >&2
  echo "Check: kubectl -n kube-system logs deploy/sealed-secrets-controller" >&2
  echo "Most likely the key backup is missing or belongs to another cluster." >&2
  echo "See cluster/secrets/README.md and docs/gitops.md#secrets." >&2
  exit 1
fi

echo "==> namespaces"
kubectl apply -f cluster/namespaces.yaml

echo "==> MetalLB ${METALLB_VERSION}"
# The native manifest ships the namespace, CRDs, validation webhook,
# controller and speaker; the address pool is a CR (metallb.io/v1beta1)
# rather than the pre-0.13 ConfigMap.
kubectl apply -f "cluster/metallb/metallb-v${METALLB_VERSION}.yaml"
# v0.16 metrics authenticate via TokenReview/SAR — permissions the native
# manifest does not include; without them every scrape returns 500
kubectl apply -f cluster/metallb/metrics-rbac.yaml
kubectl -n metallb-system rollout status deploy/controller --timeout=5m
kubectl -n metallb-system rollout status ds/speaker --timeout=5m
kubectl wait --for condition=established --timeout=60s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl apply -f cluster/metallb/config.yaml

echo "==> Longhorn ${LONGHORN_VERSION}"
# Vendored, not fetched: a rebuild must not depend on raw.githubusercontent.com
# being reachable while you are trying to install storage. The file was
# verified byte-identical to the live cluster with `kubectl diff` before it was
# committed (exit 0, zero output). See cluster/longhorn/README.md to update it.
kubectl apply -f "cluster/longhorn/longhorn-v${LONGHORN_VERSION}.yaml"
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=15m
kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=15m
kubectl get sc longhorn >/dev/null

echo "==> Helm repositories"
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
# The grafana chart moved to grafana-community after 2026-01-30; the old
# grafana.github.io endpoint serves a frozen, deprecated 10.5.x line.
helm repo add grafana https://grafana-community.github.io/helm-charts --force-update
helm repo update

echo "==> Traefik ${TRAEFIK_CHART_VERSION}"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --version "${TRAEFIK_CHART_VERSION}" \
  -f cluster/traefik/values.yaml --wait --timeout 10m
# Chart 42 has no `deployment.strategy` key and its schema rejects unknown
# keys, so the Recreate strategy is set via `updateStrategy.type` in
# cluster/traefik/values.yaml — which means the chart renders it directly and
# there is no window during an upgrade where RollingUpdate is live against the
# RWO acme.json PVC. The patch below is kept as a belt-and-braces fallback for
# the case where that value is ever removed: the default RollingUpdate
# deadlocks (new pod waits for a detach that never comes while maxUnavailable
# keeps the old one alive), hit twice during the 2026-10-15 rebuild, each time
# needing a manual pod delete.
kubectl -n traefik patch deploy traefik --type json \
  -p '[{"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}}]'

echo "==> Prometheus ${PROMETHEUS_CHART_VERSION}"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --version "${PROMETHEUS_CHART_VERSION}" \
  -f cluster/monitoring/prometheus-values.yaml \
  --wait --timeout 15m

echo "==> Grafana ${GRAFANA_CHART_VERSION}"
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version "${GRAFANA_CHART_VERSION}" \
  -f cluster/monitoring/grafana-values.yaml --wait --timeout 10m

echo "==> Traefik CRs"
# Helm installs the traefik.io CRDs from the chart; wait until the API server
# serves them before applying our resources against a fresh cluster.
kubectl wait --for condition=established --timeout=60s \
  crd/ingressroutes.traefik.io crd/middlewares.traefik.io crd/tlsoptions.traefik.io
kubectl apply -f cluster/traefik/tlsoption.yaml
kubectl apply -f cluster/traefik/middlewares.yaml
kubectl apply -f cluster/traefik/ingressroutes.yaml

echo "==> workloads"
kubectl apply -R -f cluster/workloads

echo "==> dashboard IngressRoutes"
kubectl apply -f cluster/dashboards/ingressroutes.yaml

echo "==> dynamic DNS CronJobs"
kubectl apply -f cluster/dns/cronjobs.yaml

echo "==> waiting for the Traefik LoadBalancer address"
for _ in $(seq 1 60); do
  ip=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$ip" ]; then
    echo "Traefik LoadBalancer IP: $ip"
    break
  fi
  sleep 5
done

echo
echo "done. Check: kubectl get nodes,pods -A"
