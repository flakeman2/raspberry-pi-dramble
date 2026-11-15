# Apps

First-party workloads, one directory per Argo CD `Application`, rendered with
Kustomize. **Not yet applied.**

| Directory | Workload | Namespace | Notes |
|---|---|---|---|
| `mysite-nginx/` | `mysite-nginx` | `mysite-nginx` | Pin the image tag; currently `nginx:latest` |
| `jekyll/` | `jekyll-website` (3 replicas) | `jekyll` | Pin `flakeman2/jekyll`; built ARM64 in CI |
| `whoami/` | `whoami` (2 replicas) | `whoami` | Pilot app for phase 1; currently floating tag |
| `dns/` | two DynDNS CronJobs | `default` | Password must come from a sealed `dyn-dns-credentials` |
| `dashboards/` | IngressRoutes for Grafana/Longhorn | `traefik` | Basic auth via `authsecret` |

`pi-hole` is gone: its `ExternalName` pointed at an unreachable host, and the
whole workload was deleted from the manifests on 2026-11-14.

Conventions:

- `kustomization.yaml` per directory, plus `base/` + `overlays/` only when a
  second environment exists. There is one cluster; do not invent overlays.
- Pin every image tag. No `:latest`, no untagged images.
- Add requests/limits and readiness/liveness probes as each app is adopted.
- Secrets arrive as sealed manifests, never as plaintext.

The `dns` CronJobs need `startingDeadlineSeconds` and `concurrencyPolicy: Forbid`
so a missed run does not pile up; keep the existing schedule.
