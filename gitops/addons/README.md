# Addons

Third-party components, each as one Argo CD `Application` wrapping its Helm
chart with a committed values file.

**Not yet applied.** Migration notes per component are in
[../../docs/action-items.md](../../docs/action-items.md#5-plan-the-upgrade-off-end-of-life-versions)
and [../../docs/gitops.md](../../docs/gitops.md#prerequisite-the-kubernetes-upgrade).

| Directory | Component | Source | Notes |
|---|---|---|---|
| `metallb/` | MetalLB | Helm chart, target 0.14.x | Replace `ConfigMap/config` with `IPAddressPool` + `L2Advertisement`; keep the `.201–.250` pool and Traefik's `.201` |
| `longhorn/` | Longhorn | Helm chart, target latest supported | `ServerSideApply=true`; verify replicas healthy between minors; keep `default-replica-count: 3` |
| `traefik/` | Traefik | Helm chart, last 2.x then 3.x | Migrate `traefik.containo.us` → `traefik.io` before v3; keep ACME TLS-ALPN resolver `letsencrypt` and the 128Mi `acme.json` PVC |
| `monitoring/` | Prometheus + Grafana | Helm charts | Codify the Grafana datasource and dashboards before auto-sync |
| `sealed-secrets/` | Sealed Secrets controller | Helm chart | Bootstrap before any sealed manifest; back up the private key |

Ordering (sync waves): MetalLB `-5`, Longhorn `-5`, sealed-secrets `-5`,
Traefik `0`, monitoring `0`. Longhorn must be ready before anything requests a
`longhorn` PVC.

Storage note: the Traefik `acme.json` volume is stateful. Argo CD should manage
the manifests, not recreate the PVC; guard against prune deleting it.
