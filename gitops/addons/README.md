# Addons

Third-party components, each as one Argo CD `Application` wrapping its Helm
chart with a committed values file.

**Not yet applied.** Migration notes per component are in
[../../docs/upgrade.md](../../docs/upgrade.md) and
[../../docs/gitops.md](../../docs/gitops.md#prerequisite-the-kubernetes-upgrade).

| Directory | Component | Source | Notes |
|---|---|---|---|
| `metallb/` | MetalLB 0.16.2 | vendored native manifest + `metallb.io` CRs | Already migrated in this repo (2026-11-14): `IPAddressPool` + `L2Advertisement` replace the old ConfigMap; keep the `.201–.250` pool and Traefik's `.201` |
| `longhorn/` | Longhorn 1.13.0 | **vendored** manifest (`cluster/longhorn/longhorn-v1.13.0.yaml`), not a Helm chart | `ServerSideApply=true`; verify replicas healthy between minors; keep `default-replica-count: 3`. Verified byte-identical to live with `kubectl diff` before committing |
| `traefik/` | Traefik 3.7.18, chart `42.4.0` | Helm chart | CRs already rewritten to `traefik.io`; keep the ACME TLS-ALPN resolver `letsencrypt`, the 128Mi `acme.json` PVC, and the `.201` annotation |
| `monitoring/` | Prometheus 3.16.0 (chart `29.47.2`), Grafana 13.3.1 (chart `14.4.1`) | Helm charts, Grafana from the `grafana-community` repo | Codify the Grafana datasource and dashboards before auto-sync; start from empty volumes |
| `metrics-server/` | metrics-server | bundled with k3s | Nothing to install; confirm `kubectl top` works after the upgrade |
| `sealed-secrets/` | Sealed Secrets controller `0.41.2` | vendored release manifest (`cluster/sealed-secrets/controller.yaml`), not Helm — the chart repo 404s | Bootstrap before any sealed manifest; **back up the private key**. Install order matters: it must exist before `cluster/secrets/sealed/` is applied |

Ordering (sync waves): MetalLB `-5`, Longhorn `-5`, sealed-secrets `-5`,
Traefik `0`, monitoring `0`. Longhorn must be ready before anything requests a
`longhorn` PVC.

Storage note: the Traefik `acme.json` volume is stateful. Argo CD should manage
the manifests, not recreate the PVC; guard against prune deleting it.
