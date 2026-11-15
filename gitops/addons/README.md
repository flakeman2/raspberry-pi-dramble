# Addons

Third-party components, each as one Argo CD `Application` wrapping its Helm
chart with a committed values file.

**Not yet applied.** Migration notes per component are in
[../../docs/upgrade.md](../../docs/upgrade.md) and
[../../docs/gitops.md](../../docs/gitops.md#prerequisite-the-kubernetes-upgrade).

| Directory | Component | Source | Notes |
|---|---|---|---|
| `metallb/` | MetalLB | Helm chart, target 0.16.2 | Replace `ConfigMap/config` with `IPAddressPool` + `L2Advertisement`; keep the `.201–.250` pool and Traefik's `.201`; pin the Service IP |
| `longhorn/` | Longhorn | Helm chart or upstream manifest, target 1.13.0 | `ServerSideApply=true`; verify replicas healthy between minors; keep `default-replica-count: 3` |
| `traefik/` | Traefik | Helm chart, chart `42.x` (Traefik `3.7.x`) | Migrate `traefik.containo.us` → `traefik.io` before v3; keep ACME TLS-ALPN resolver `letsencrypt` and the 128Mi `acme.json` PVC |
| `monitoring/` | Prometheus + Grafana | Helm charts, Prometheus 3.x and Grafana 13.x | Codify the Grafana datasource and dashboards before auto-sync; start from empty volumes |
| `metrics-server/` | metrics-server | Upstream manifest, current release | Redeploy last; confirm `kubectl top` works with `--kubelet-insecure-tls` if needed |
| `sealed-secrets/` | Sealed Secrets controller | Helm chart | Bootstrap before any sealed manifest; back up the private key |

Ordering (sync waves): MetalLB `-5`, Longhorn `-5`, sealed-secrets `-5`,
Traefik `0`, monitoring `0`. Longhorn must be ready before anything requests a
`longhorn` PVC.

Storage note: the Traefik `acme.json` volume is stateful. Argo CD should manage
the manifests, not recreate the PVC; guard against prune deleting it.
