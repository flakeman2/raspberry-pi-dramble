# Cluster manifests

Everything the cluster runs, minus secrets. `../scripts/install-addons.sh`
creates namespaces, applies the sealed manifests and installs Argo CD; the root
app-of-apps then reconciles the Applications that consume these paths.

| Path | Contents |
|---|---|
| `namespaces.yaml` | All application namespaces |
| `metallb/` | MetalLB 0.16.2 upstream native manifest + `IPAddressPool`/`L2Advertisement` CRs |
| `longhorn/` | Longhorn 1.13.0 | **vendored** manifest `longhorn-v1.13.0.yaml` + install notes |
| `traefik/` | Helm values, TLSOption, Middlewares, IngressRoutes |
| `monitoring/` | Prometheus and Grafana Helm values, alert rules, scrape jobs and dashboards |
| `dns/` | Dynamic DNS CronJobs |
| `workloads/` | mysite, jekyll, whoami, blog-cms-api |
| `dashboards/` | Grafana/Longhorn UI IngressRoutes |
| `networkpolicies/` | Ingress/egress allow-lists for first-party namespaces |
| `poddisruptionbudgets/` | Nine first-party PDBs for orderly node drains |
| `secrets/` | Required Secrets and placeholder examples |

These pins are the **live** stack: the repository was retargeted on
2026-11-14, the rebuild completed on 2026-11-15/16, and Traefik/Grafana were
bumped again on 2026-11-18 — see [../docs/upgrade.md](../docs/upgrade.md) and
the current inventory in [../docs/cluster-status.md](../docs/cluster-status.md).
