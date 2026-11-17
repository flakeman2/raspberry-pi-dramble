# Apps

First-party workloads, one directory per Argo CD `Application`. **All five are
applied**, with automated sync, self-heal and prune.

| Directory | Workload | Namespace | Source path | Notes |
|---|---|---|---|---|
| `mysite-nginx/` | `mysite-nginx` | `mysite-nginx` | `cluster/workloads/mysite` | Pinned `nginx:1.31.8` |
| `jekyll/` | `jekyll-website` (3 replicas) | `jekyll` | `cluster/workloads/jekyll` | `flakeman2/jekyll:1.0.6`, built by Ephesus CI |
| `whoami/` | `whoami` (2 replicas) | `whoami` | `gitops/apps/whoami` (this dir) | Phase 1 pilot; pinned `traefik/whoami:v1.12.0` |
| `dns/` | two DynDNS CronJobs | `default` | `cluster/dns` | Reads the sealed `dyn-dns-credentials` |
| `dashboards/` | IngressRoutes for Grafana, Longhorn, Prometheus, Argo CD | `longhorn-system`, `monitoring` | `cluster/dashboards` | Basic auth via `authsecret` |

`pi-hole` is gone: its `ExternalName` pointed at an unreachable host, and the
whole workload was deleted from the manifests on 2026-11-14.

### Why the source paths mostly stay under `cluster/`

Only `whoami/` carries its own manifests. The other four **point at the
existing `cluster/…` paths instead of being moved here**, because
`scripts/install-addons.sh` applies those same files during a rebuild —
relocating them would break path references across thirteen documents and
create two sources for one workload.

The `Application` manifests live here so the future app-of-apps root (which
points at `gitops/`) can discover them. Moving the workloads themselves into
`gitops/apps/` belongs with **phase 3**, when the addons move too.

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
