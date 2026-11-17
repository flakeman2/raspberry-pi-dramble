# Cluster manifests

Everything the cluster runs, minus secrets. Apply order is handled by
`../scripts/install-addons.sh`.

| Path | Contents |
|---|---|
| `namespaces.yaml` | All application namespaces |
| `metallb/` | MetalLB 0.16.2 upstream native manifest + `IPAddressPool`/`L2Advertisement` CRs |
| `longhorn/` | Longhorn 1.13.0 | **vendored** manifest `longhorn-v1.13.0.yaml` + install notes |
| `traefik/` | Helm values, TLSOption, Middlewares, IngressRoutes |
| `monitoring/` | Grafana Helm values; Prometheus uses chart defaults |
| `dns/` | Dynamic DNS CronJobs |
| `workloads/` | mysite, jekyll, whoami |
| `dashboards/` | Grafana/Longhorn UI IngressRoutes |
| `secrets/` | Required Secrets and placeholder examples |

These pins are the **target** stack: the repository was retargeted on
2026-11-14, while the live cluster still runs the 2021 versions until it is
reimaged — see [../docs/upgrade.md](../docs/upgrade.md) and the snapshot in
[../docs/cluster-status.md](../docs/cluster-status.md).
