# GitOps with Argo CD

**Status:** planned. Nothing in `gitops/` is applied yet; the live cluster is
still managed by `scripts/install-addons.sh` plus manual `kubectl`/`helm`. This
page is the design and the staged rollout plan.

## Goals

- The cluster converges to `master` in this repository; drift is visible and can
  be self-healed.
- Every change reaches the cluster through a pull request into `dev`, then a
  promotion PR into `master` (see the README workflow).
- Secrets never appear in git as plaintext.
- A bare rebuild becomes: install k3s, bootstrap Argo CD, sync.

Non-goals for now: a separate management cluster, HA Argo CD, multi-tenant
projects, and preview environments. Four 4 GB Pis do not have the headroom.

## Prerequisite: the Kubernetes upgrade

**Status: met 2026-11-16.** Argo CD 3.6 (2026-11-04) is tested against
Kubernetes **1.34–1.37**. The cluster now runs k3s **`v1.36.6+k3s1`** (rebuilt
2026-11-15) — inside that range. Before the rebuild it ran k3s **1.22.5**, EOL
since 2022, which is exactly why the upgrade had to come first: pinning a
2022-era Argo CD release would have put an unmaintained controller in charge of
reconciliation.

The add-ons that used to cap the k3s version were all migrated in this
repository before the rebuild:

| Component | Was (until the 2026-11-15 rebuild) | What capped it | Now |
|---|---|---|---|
| Longhorn | 1.2.3 | Supported k8s only through ~1.24; step through minors | `1.13.0` (tested 1.33–1.36) |
| MetalLB | 0.11.0 | ConfigMap address pool; 0.13+ requires `IPAddressPool` CRs | `0.16.2` with `IPAddressPool` + `L2Advertisement` |
| Traefik | 2.5.6 | Manifests used `traefik.containo.us`; Traefik 3 dropped that group | `3.7.18`, chart `42.4.0`, `traefik.io` CRs |

All four gates below are **satisfied** — evidence in
[cluster-status.md](cluster-status.md):

- ✅ k3s is on a Kubernetes minor inside Argo CD's tested range (`1.36`);
- ✅ Longhorn, MetalLB and Traefik support that minor and are migrated;
- ✅ all four nodes are `Ready` and all five Longhorn volumes are `healthy`;
- ✅ the workloads are reachable over HTTPS again — all eight hostnames serve
  valid Let's Encrypt certificates.

## Target architecture

| | |
|---|---|
| Namespace | `argocd` |
| Version | pinned in `gitops/bootstrap/`; 3.6.x once k8s reaches the 1.36 target |
| HA | no — single replicas, bundled Redis |
| Dex / notifications | disabled |
| Ingress | `argocd.devinflake.com` via `IngressRoute`, TLS-ALPN, server runs `--insecure` |
| Storage | none (emptyDir caches); no PVC |
| Git source | this repository, path `gitops/`, `targetRevision: master` |
| Sync policy | automated + self-heal for apps; manual for addons |

Argo CD adds a controller, repo-server, Redis, and API server to a cluster of
four 4 GB nodes. That is affordable but not free: give every component explicit
requests/limits, keep replicas at one, and confirm the totals with `kubectl top`
before enabling anything else. The resource work in
[action-items.md](action-items.md#6-add-resource-requestslimits-and-probes--done-in-git-2026-11-14)
has already landed for every container this repository owns — budget Argo CD
explicitly as well.

Argo CD tracks `master`, not `dev`. `dev` is where changes accumulate; `master`
is what the cluster should be running.

## Repository layout

```
gitops/
  README.md               Conventions and the app-of-apps root
  bootstrap/              Argo CD install — the only non-Git step
  projects/               AppProject boundaries
  addons/                 MetalLB, Longhorn, Traefik, monitoring, sealed-secrets
  apps/                   First-party workloads (Kustomize)
```

Conventions:

- One directory per Argo CD `Application`, each with a `kustomization.yaml`.
  Third-party charts are referenced with `source.helm` and committed values,
  not vendored YAML.
- A root app-of-apps `Application` points at `gitops/` and discovers the rest.
  Start with explicit `Application` manifests; reach for `ApplicationSet`
  generators only when the app count justifies it.
- Sync waves order the rollout: `-10` namespaces, `-5` CRDs and controllers,
  `0` addons, `1+` workloads.
- Use `ServerSideApply=true` for the Longhorn CRDs; client-side apply exceeds the
  annotation size limit.
- `prune` stays off until an app's diff is clean, then turns on per app.

## Secrets

The repository is public, so plain `Secret` manifests cannot be committed.

**Recommended: Sealed Secrets.** One controller in `kube-system`, sealed
manifests in git, no Argo CD plugin. Bootstrap it before any application that
consumes a sealed secret, and back up the controller's private key — losing it
means every sealed secret in git is unrecoverable.

**Alternative: SOPS + age** with a Kustomize plugin. More flexible, more moving
parts; pick one and do not mix.

Either way the inventory is the same three Secrets — `authsecret`, `grafana`,
`dyn-dns-credentials` (see [secrets.md](secrets.md)). The k3s join token,
kubeconfig, and Traefik `acme.json` stay outside git entirely.

## CI gates

GitHub Actions on PRs into `dev`:

- `kustomize build` for every overlay;
- `kubeconform -strict` against the target Kubernetes version;
- `gitleaks` for accidental credentials;
- `helm template` for addon values once addons are adopted;
- later, an `argocd app diff --local` job for the apps that have cluster access.

Image builds (the `jekyll` site) stay in CI: build ARM64, push, then bump the
tag in git. Argo CD Image Updater with git write-back is optional; a small
workflow that opens the bump PR is easier to reason about.

There are no preview environments on this hardware. The diff job is the review
gate.

## Phased rollout

| Phase | Scope | Done when |
|---|---|---|
| 0. Upgrade | k3s, Longhorn, MetalLB, Traefik, monitoring charts | Argo CD's tested k8s range is met; volumes healthy |
| 1. Pilot | Bootstrap Argo CD; adopt one stateless app (`whoami`) with manual sync | `argocd app diff` is empty; no surprise mutations |
| 2. Workloads | `apps/` for mysite, jekyll, whoami, dashboards, DNS; sealed secrets | Apps auto-sync with self-heal; Grafana is code, not UI state |
| 3. Addons | Traefik, Prometheus, Grafana as Helm Applications; Argo CD self-managed | Addons sync manually; bootstrap script only installs Argo CD |
| 4. CI | kustomize/kubeconform/gitleaks gates; image pipeline | A bad manifest cannot merge |

Keep the rebuild path working throughout: `scripts/install-addons.sh` remains
the fallback until phase 3 is complete.

## Drift to codify first

Argo CD will surface these immediately; fix them before turning on auto-sync:

- Grafana's Prometheus datasource and missing dashboards (UI state today);
- the inline dynamic-DNS password in the live CronJobs;
- floating image tags (`nginx:latest`, `traefik/whoami`, `curlimages/curl`);
- the stray `k3s.service` on kube2 — host configuration, not Kubernetes state,
  so it stays in [redeploy.md](redeploy.md), not in GitOps.

## Open questions

- One repository (current plan) versus splitting cluster config from application
  source. Splitting buys per-repo permissions and smaller diffs; it costs a
  second repo and cross-repo PRs. At this scale, one repository wins.
- Whether MetalLB and Longhorn should be Argo-managed or remain bootstrap-only.
  They are CRD-heavy and upgrade-sensitive; managing them is the goal, but they
  can be the last phase-3 migration rather than the first.
- Sealed Secrets versus SOPS — decide before phase 2, since it determines the
  shape of every application manifest.
