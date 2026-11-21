# GitOps with Argo CD

**Status:** phases 1–4 complete. The root app-of-apps owns the `drumble`
AppProject and **fourteen Applications** — the root plus thirteen children —
all Synced/Healthy and reconciling from `dev` (2026-11-21).
`scripts/install-addons.sh` is now bootstrap-only: it installs Argo CD, restores
the sealed-secrets key and applies the root Application; the children are Git.
Longhorn's Application keeps `prune: false` so a sync cannot delete its CRDs and
orphan the volumes. The emergency Argo sync hold used during the 2026-11-18
kube1 apiserver failures was lifted on 2026-11-21 once the control plane had
moved to `dflake-nettop` and the Longhorn conflict loop was cleared. This page
is the design and the rollout record.

## Goals

- The cluster converges to `dev` in this repository; drift is visible and can
  be self-healed.
- Every change reaches the cluster through a pull request into `dev` (see the
  README workflow). There is no promotion step.
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
| Traefik | 2.5.6 | Manifests used `traefik.containo.us`; Traefik 3 dropped that group | `3.7.19`, chart `42.4.1`, `traefik.io` CRs |

All four gates below are **satisfied** — evidence in
[cluster-status.md](cluster-status.md):

- ✅ k3s is on a Kubernetes minor inside Argo CD's tested range (`1.36`);
- ✅ Longhorn, MetalLB and Traefik support that minor and are migrated;
- ✅ all four nodes are `Ready` and all five Longhorn volumes are `healthy`;
- ✅ the workloads are reachable over HTTPS again — all fourteen hostnames serve
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
| Git source | this repository, path `gitops/`, `targetRevision: dev` |
| Sync policy | automated + self-heal for **all** Applications, addons included |

**Sync policy — decided 2026-11-17.** Addons were originally planned as
*manual* sync, on the reasoning that they own CRDs, RBAC and storage, so a bad
chart bump should not reach the cluster without a human clicking Sync. That
reasoning still holds; it is being **accepted deliberately** in favour of
consistency with the phase-2 apps: a merged pin change deploys on its own, and
the gate is the pull request plus CI rather than a button.

The compensating control is `prune`, which is enabled per Application **only
after its diff is proven empty** — never on the strength of an assumption. The
one case where that mattered was Sealed Secrets, where the failure mode is
unrecoverable; see `gitops/addons/sealed-secrets/application.yaml` for how
prune was shown not to reach the controller's private key.

Argo CD adds a controller, repo-server, Redis, and API server to a cluster of
four 4 GB nodes. That is affordable but not free: give every component explicit
requests/limits, keep replicas at one, and confirm the totals with `kubectl top`
before enabling anything else. The resource work in
[action-items.md](action-items.md#6-add-resource-requestslimits-and-probes--done-in-git-2026-11-14)
has already landed for every container this repository owns — budget Argo CD
explicitly as well.

Argo CD tracks `dev`, which is also the repository default — so a merge into
`dev` *is* the deployment target and there is no promotion step. The `master`
branch existed until 2026-11-17 as the "deployed state" mirror; its tree was
byte-identical to `dev` (only promotion merge commits differed), so removing
it lost no content.

## Repository layout

```
gitops/
  README.md               Conventions and the app-of-apps root
  kustomization.yaml      Explicit AppProject + thirteen child Applications
  bootstrap/              Argo CD install and root-app.yaml — the only non-Git step
  projects/               AppProject boundaries
  addons/                 sealed-secrets, MetalLB, Traefik, traefik-config,
                          prometheus, grafana, Longhorn
  apps/                   First-party workloads (Kustomize), including the
                          grafana-dashboards ConfigMap generator
```

Conventions:

- One directory per child `Application`; a `kustomization.yaml` appears only in
  directories that hold real manifests (`whoami/`, and the root `gitops/`
  directory). Third-party charts use `source.helm` with committed values.
- The root `Application` (`bootstrap/root-app.yaml`) points at `gitops/`. Its
  `kustomization.yaml` lists the AppProject and all thirteen children
  explicitly — no `ApplicationSet` generator at this scale. It uses the
  `default` project because it creates `drumble` itself, and bootstrap files
  stay out of the build so Argo cannot manage its own installer.
- Sync waves order the rollout: `-10` root and AppProject, `-5` CRDs and
  controllers, `0` addons, `1+` workloads.
- Longhorn keeps `prune: false` because its CRDs own the volume records and
  there is no off-cluster backup. It does **not** use `ServerSideApply`: the
  largest manifest is ~21 KB against kubectl's 256 KB annotation limit, and a
  measured server-side diff would force ownership of 34 resources.
- `prune` stays off until an app's diff is clean, then turns on per app.

## Secrets

The repository is public, so plain `Secret` manifests cannot be committed.

**Decided 2026-11-17: Sealed Secrets.** One controller in `kube-system`, sealed
manifests in `cluster/secrets/sealed/`, no Argo CD plugin. It is installed from
the vendored release manifest `cluster/sealed-secrets/controller.yaml`
(v0.41.2, checksum-verified against the signed release) rather than the Helm
chart, because the chart's repository URL now returns 404.

**Back up the controller's private key — losing it means every sealed secret in
git is unrecoverable.** The key is the `sealed-secrets-key*` Secret in
`kube-system`; a copy is kept outside this repository at mode `0600`.

SOPS + age was the alternative and is **not** used. Do not mix the two.

The inventory is the same three Secrets — `authsecret`, `grafana`,
`dyn-dns-credentials` (see [secrets.md](secrets.md)) — all three now live in
git as SealedSecrets. The k3s join token, kubeconfig, and Traefik `acme.json`
stay outside git entirely.

### Adopting a Secret that already exists

The controller **refuses to take over a Secret it does not own**: it fails
with `already exists and is not managed by SealedSecret`, retries for about
fifteen seconds, then *gives up* — and deleting the Secret afterwards does not
wake it up. Annotating the SealedSecret does not either. What works:

1. `kubectl delete sealedsecret <name>` — resets its state
2. `kubectl delete secret <name>` — opens a short gap
3. `kubectl apply -f cluster/secrets/sealed/<name>.yaml` — a fresh reconcile
   creates the Secret with the correct `ownerReferences`

Do one Secret at a time and verify the data hash afterwards (a round-trip
through throwaway names proves byte-identity before you start).

**The gap matters more than it looks.** A missing `authsecret` does not merely
disable basic-auth — Traefik cannot resolve the middleware's Secret, so it
**drops the router entirely**: Longhorn, Prometheus and the Traefik dashboard
return `404`, not `401`. Grafana and the blog keep working, which is what makes
it look like an isolated problem when it is not.

## CI gates

Implemented in `.github/workflows/ci.yml`. Runs on PRs into `dev` as **four
independent jobs**, so a red check names itself:

- **Manifests** — `kubeconform -strict` over the raw manifests, all four Helm
  charts rendered at their pinned versions, and every Kustomize build under
  `gitops/` (the root app-of-apps) and `gitops/apps/*/`. The root build must
  render exactly the AppProject plus thirteen child Applications. Chart
  versions are **single-sourced** from `scripts/install-addons.sh` and
  `gitops/bootstrap/values.yaml`, so CI cannot drift from the install path — a
  removed pin fails the job. The Traefik, MetalLB and Argo CD custom resources
  are validated against the CRDs-catalog rather than skipped.
- **Secrets** — `gitleaks` across the **whole history**, not just the diff:
  the gate is "no credential lands in git", not "no credential lands in this
  PR". The two inherited 2018 upstream findings are allowlisted by commit in
  `.gitleaks.toml`.
- **Docs** — `scripts/check-docs.py`: local links, in-page anchors and
  reference links in every Markdown file.
- **Workflows** — `actionlint`.

### PR-Agent — advisory, not a gate

`.github/workflows/pr-agent.yml` posts `/describe` and `/review` on every opened
PR using [PR-Agent](https://github.com/The-PR-Agent/pr-agent) on **Google
Gemini's free tier** (`gemini/gemini-3.8-flash`, falling back to
`gemini/gemini-3.5-flash-lite`) — no card, no published daily cap. It needs one
secret, `GEMINI_API_KEY`, from <https://aistudio.google.com/apikey>.

- **A failed review never blocks a merge** — it is a second opinion, not a
  check. The four jobs above remain the gate.
- `.pr_agent.toml` is read from the **default branch**, not from the PR branch.
  A config merged in the same PR as the workflow therefore has no effect until
  it lands — the first run will still use the shipped default model and fail
  looking for an OpenAI key. Merge, then re-run.
- Deliberately **not pinned** to a SHA or tag. The action's Dockerfile is a
  single `FROM pragent/pr-agent:github_action`, so pinning the wrapper would
  pin the wrapper and not the code that runs. It posts comments; it is nowhere
  near the deploy path.
- Free-tier caveat: Google's terms allow free-tier content to be used to
  improving their products. Both repositories are public, so the exposure is
  low — but it is the reason this is not the default for private work.

Not yet: an `argocd app diff --local` job for apps that have cluster access.

CI deliberately holds **no cluster credentials**. The other half of "docs match
reality" — do the documented numbers match the *running* cluster? — is
[`scripts/verify-docs.sh`](../scripts/verify-docs.sh), which needs a kubeconfig
and is therefore run locally. It asserts the `cluster-status.md` totals, the
hostname/routing-table sets, a valid Let's Encrypt cert on every hostname, the
four chart pins against live Helm releases, that every SealedSecret is
`Synced`, and each manifest image tag against the live Deployment. A
self-hosted runner on a Pi would be the way to run it in CI instead.

Image builds (the `jekyll` site) are CI too, in the **Ephesus** repository:
build ARM64, smoke-test, push, then open the bump PR here. A small workflow
that opens a PR is easier to reason about than Argo CD Image Updater with git
write-back.

There are no preview environments on this hardware. The diff job is the review
gate.

## Phased rollout

| Phase | Scope | Done when | Status |
|---|---|---|---|
| 0. Upgrade | k3s, Longhorn, MetalLB, Traefik, monitoring charts | Argo CD's tested k8s range is met; volumes healthy | ✅ done 2026-11-16 |
| 1. Pilot | Bootstrap Argo CD; adopt one stateless app (`whoami`) with manual sync | `argocd app diff` is empty; no surprise mutations | ✅ done 2026-11-17 |
| 2. Workloads | `apps/` for mysite, jekyll, whoami, dashboards, DNS; sealed secrets | Apps auto-sync with self-heal; Grafana is code, not UI state | ✅ done 2026-11-17 |
| 3. Addons | Traefik, Prometheus, Grafana as Helm Applications; root app-of-apps | Addons sync automatically with self-heal; bootstrap script only installs Argo CD | ✅ done 2026-11-21 — AppProject + thirteen children under the root app |
| 4. CI | kustomize/kubeconform/gitleaks gates; image pipeline | A bad manifest cannot merge | ✅ done 2026-11-21 — gates live 2026-11-17; image pipeline shipped in Ephesus |

A fresh rebuild is now `scripts/install-addons.sh` → Argo CD sync. The script no
longer installs add-ons or workloads one by one, but its version-pin variables
remain the single source that CI and `check-updates.sh` read.

## Drift to codify first

Argo CD will surface these immediately; fix them before turning on auto-sync.
**Status 2026-11-16 — most of this list was cleared by the rebuild:**

- ~~the inline dynamic-DNS password in the live CronJobs~~ — resolved: both
  CronJobs read `dyn-dns-credentials` (one key per domain) and are verified at
  `<ErrCount>0</ErrCount>`;
- ~~the stray `k3s.service` on kube2~~ — moot: the node was reimaged and
  `install-agent.sh` now disables any stray server unit;
- ~~the floating `curlimages/curl` tag~~ — pinned (now `8.23.0`) in
  `cluster/dns/cronjobs.yaml`;
- ~~Grafana's datasource~~ — already codified in
  `cluster/monitoring/grafana-values.yaml`;
- ~~Grafana's dashboards~~ — four dashboards now live in
  `cluster/monitoring/dashboards/*.json` and are rendered to labelled ConfigMaps
  by the `grafana-dashboards` Application (item 7), so a rebuild no longer
  starts empty.

**Still open:**

- floating image tags `nginx:latest` and untagged `traefik/whoami`
  ([action-items.md](action-items.md) item 9) — pin them before adopting the
  workloads, or Argo CD will faithfully reconcile a tag someone else moved;
- host configuration (SSH keys, netplan, `iscsid`, `wpa_supplicant`, boot
  tuning) stays in [redeploy.md](redeploy.md) and [hardware.md](hardware.md) —
  Argo CD manages cluster objects, not nodes.

## Open questions

- One repository (current plan) versus splitting cluster config from application
  source. Splitting buys per-repo permissions and smaller diffs; it costs a
  second repo and cross-repo PRs. At this scale, one repository wins.
- Whether Longhorn should be Argo-managed or remain bootstrap-only. It is
  CRD-heavy and upgrade-sensitive, and it carries every volume on the cluster,
  so it is the last phase-3 migration rather than the first. MetalLB answered
  the same question on 2026-11-18: adopted, with `prune` proven safe by listing
  what Argo tracks first.
- ~~Sealed Secrets versus SOPS~~ — **decided 2026-11-17: Sealed Secrets**, see
  [Secrets](#secrets).
