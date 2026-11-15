# Monitoring

Two Helm releases in the `monitoring` namespace:

| Release | Chart | App | Values |
|---|---|---|---|
| `prometheus` | `prometheus-community/prometheus` `29.47.2` | `3.16.0` | chart defaults |
| `grafana` | `grafana/grafana` `14.4.1` | `13.3.1` | `grafana-values.yaml` |

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# the grafana chart moved here after 2026-01-30; grafana.github.io is frozen
helm repo add grafana https://grafana-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --version 29.47.2

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version 14.4.1 \
  -f grafana-values.yaml
```

Prometheus defaults create the server (15-day retention, 8 GiB Longhorn PVC),
Alertmanager (2 GiB PVC), kube-state-metrics, node-exporter, and pushgateway.

## Grafana secret

`grafana-values.yaml` sets `admin.existingSecret: grafana`. Create it first:

```bash
kubectl -n monitoring create secret generic grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='CHOOSE-A-STRONG-PASSWORD'
```

## Access

Grafana is exposed at `grafana.devinflake.com` by the IngressRoute in
`../dashboards/ingressroutes.yaml` (ClusterIP Service, port 80 → 3000).

## Known gaps

- Grafana currently has **no dashboards**.
- The Prometheus datasource is codified in `grafana-values.yaml`; on the live
  cluster it was added through the UI.
- Alertmanager has no receivers configured.
- Prometheus targets are healthy after the 2026-11-14 node removal (23 targets,
  0 down); see [../../docs/cluster-status.md](../../docs/cluster-status.md).
