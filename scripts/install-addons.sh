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
#   - Secrets created first: see cluster/secrets/README.md
set -euo pipefail

cd "$(dirname "$0")/.."

: "${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}"

TRAEFIK_CHART_VERSION=10.9.1
PROMETHEUS_CHART_VERSION=15.1.3
GRAFANA_CHART_VERSION=6.21.4
LONGHORN_VERSION=1.2.3
METALLB_VERSION=0.11.0

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

echo "==> checking required Secrets"
missing=0
require_secret default authsecret || missing=1
require_secret default dyn-dns-credentials || missing=1
require_secret monitoring grafana || missing=1
if [ "$missing" -ne 0 ]; then
  echo
  echo "create the missing Secrets using cluster/secrets/examples/ as a template," >&2
  echo "then re-run this script. See cluster/secrets/README.md." >&2
  exit 1
fi

echo "==> namespaces"
kubectl apply -f cluster/namespaces.yaml

echo "==> MetalLB ${METALLB_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/v${METALLB_VERSION}/manifests/namespace.yaml"
kubectl apply -f cluster/metallb/metallb-v0.11.0.yaml
kubectl apply -f cluster/metallb/config.yaml
kubectl -n metallb-system rollout status deploy/controller --timeout=5m
kubectl -n metallb-system rollout status ds/speaker --timeout=5m

echo "==> Longhorn ${LONGHORN_VERSION}"
kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/v${LONGHORN_VERSION}/deploy/longhorn.yaml"
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=15m
kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=15m
kubectl get sc longhorn >/dev/null

echo "==> Helm repositories"
helm repo add traefik https://helm.traefik.io/traefik --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update

echo "==> Traefik ${TRAEFIK_CHART_VERSION}"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --version "${TRAEFIK_CHART_VERSION}" \
  -f cluster/traefik/values.yaml --wait --timeout 10m

echo "==> Prometheus ${PROMETHEUS_CHART_VERSION} (chart defaults)"
helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --version "${PROMETHEUS_CHART_VERSION}" \
  --wait --timeout 15m

echo "==> Grafana ${GRAFANA_CHART_VERSION}"
helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version "${GRAFANA_CHART_VERSION}" \
  -f cluster/monitoring/grafana-values.yaml --wait --timeout 10m

echo "==> Traefik CRs"
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
