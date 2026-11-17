# Monitoring

Two Helm releases in the `monitoring` namespace:

| Release | Chart | App | Values |
|---|---|---|---|
| `prometheus` | `prometheus-community/prometheus` `29.47.2` | `3.16.0` | `prometheus-values.yaml` |
| `grafana` | `grafana/grafana` `14.4.1` | `13.3.1` | `grafana-values.yaml` |

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# the grafana chart moved here after 2026-01-30; grafana.github.io is frozen
helm repo add grafana https://grafana-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --version 29.47.2 \
  -f prometheus-values.yaml

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version 14.4.1 \
  -f grafana-values.yaml
```

Chart defaults create the server (15-day retention, 8 GiB Longhorn PVC),
Alertmanager (2 GiB PVC), kube-state-metrics, node-exporter, and pushgateway;
`prometheus-values.yaml` adds a resource budget for the server plus an explicit
**`metallb-metrics`** scrape job — MetalLB v0.16 serves metrics over HTTPS with
bearer-token auth, which the chart's annotation-driven job cannot do (see
`../metallb/README.md`). Every workload in this directory now has
requests/limits, and Grafana's probes come from the chart (`GET /api/health`).

## Grafana rollout strategy

Grafana's PVC is `ReadWriteOnce`, so its `deploymentStrategy` is set to
**`Recreate`** rather than the chart's default `RollingUpdate`. With one
replica, `RollingUpdate`'s 25% `maxUnavailable` rounds to **0** — the surge pod
is created first and the old pod is not terminated until it is Available, but
the surge pod cannot attach a volume the old pod still holds. That deadlock was
hit during the 2026-11-17 password rotation; it is the same failure mode as
Traefik's RWO `acme.json` (PR #22). `Recreate` costs a few seconds of
downtime per upgrade and guarantees the rollout finishes.

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
