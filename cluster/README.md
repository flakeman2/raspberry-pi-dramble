# Cluster manifests

Everything the cluster runs, minus secrets. Apply order is handled by
`../scripts/install-addons.sh`.

| Path | Contents |
|---|---|
| `namespaces.yaml` | All application namespaces |
| `metallb/` | MetalLB 0.11.0 upstream manifest + L2 address pool |
| `longhorn/` | Longhorn 1.2.3 install notes (upstream manifest) |
| `traefik/` | Helm values, TLSOption, Middlewares, IngressRoutes |
| `monitoring/` | Grafana Helm values; Prometheus uses chart defaults |
| `dns/` | Dynamic DNS CronJobs |
| `workloads/` | mysite, jekyll, whoami, pi-hole |
| `dashboards/` | Grafana/Longhorn UI IngressRoutes |
| `secrets/` | Required Secrets and placeholder examples |

Versions are pinned to match the live cluster. See
[../docs/architecture.md](../docs/architecture.md) and
[../docs/redeploy.md](../docs/redeploy.md).
