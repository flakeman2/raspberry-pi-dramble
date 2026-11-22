# Apps

First-party workloads, one directory per Argo CD `Application`. **All six are
applied**, with automated sync, self-heal and prune.

| Directory | Workload | Namespace | Source path | Notes |
|---|---|---|---|---|
| `mysite-nginx/` | `mysite-nginx` | `mysite-nginx` | `cluster/workloads/mysite` | Pinned `nginx:1.31.8` |
| `jekyll/` | `jekyll-website` (3 replicas) | `jekyll` | `cluster/workloads/jekyll` | `flakeman2/jekyll:1.0.6`, built by Ephesus CI |
| `whoami/` | `whoami` (2 replicas) | `whoami` | `gitops/apps/whoami` (this dir) | Phase 1 pilot; pinned `traefik/whoami:v1.12.0` |
| `dns/` | two DynDNS CronJobs | `default` | `cluster/dns` | Reads the sealed `dyn-dns-credentials` |
| `dashboards/` | IngressRoutes for Grafana, Longhorn, Prometheus, Argo CD | `longhorn-system`, `monitoring` | `cluster/dashboards` | Basic auth via `authsecret` |
| `grafana-dashboards/` | four Grafana dashboards as labelled ConfigMaps | `monitoring` | `cluster/monitoring/dashboards` | Kustomize renders JSON into ConfigMaps for the Grafana sidecar |

`pi-hole` is gone: its `ExternalName` pointed at an unreachable host, and the
whole workload was deleted from the manifests on 2026-11-14.

### Why the source paths mostly stay under `cluster/`

Only `whoami/` carries its own manifests. The other five **point at the
existing `cluster/…` paths instead of being moved here**: the `Application`
manifests live in this repository and the root app-of-apps discovers them, but
the workload payloads stay where they have always been. Moving them would break
path references across thirteen documents and create two sources for one
workload.

The root Application (`gitops/bootstrap/root-app.yaml`) discovers these through
the explicit list in `gitops/kustomization.yaml`. There is no automatic
directory generator; adding another first-party app means adding one line to
that list in the same PR.

### Conventions

- Pin every image tag. No `:latest`, no untagged images — `nginx:latest` and
  `traefik/whoami` were pinned on 2026-11-17 after matching their running
  index digests, so pinning changed nothing content-wise.
- `CreateNamespace=false` everywhere: namespaces come from
  `cluster/namespaces.yaml` via `install-addons.sh`, not from Argo.
- Secrets arrive as sealed manifests, never as plaintext.
- `prune` was enabled only after each app's diff was empty; keep it that way —
  a non-empty diff is a review, not something to prune through.
- `whoami/` keeps a `kustomization.yaml` because it holds real manifests; the
  other directories hold only an `Application`.

The `dns` CronJobs need `startingDeadlineSeconds` and `concurrencyPolicy: Forbid`
so a missed run does not pile up; keep the existing schedule.
