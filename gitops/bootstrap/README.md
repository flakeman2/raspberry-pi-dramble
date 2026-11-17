# Bootstrap

The chicken-and-egg step: Argo CD cannot install itself, so this directory holds
the one remaining imperative action. Everything after this is Git.

**Prerequisite met 2026-11-16** — the cluster runs k3s `v1.36.6+k3s1`, inside
Argo CD 3.6's tested range; see
[../../docs/gitops.md](../../docs/gitops.md).

## Contents

| File | Purpose |
|---|---|
| `namespace.yaml` | the `argocd` namespace — the one namespace Argo cannot create for itself |
| `values.yaml` | chart `argo-cd` **10.18.0** (app `v3.6.1`), pinned: single replicas, Dex and notifications off, bundled Redis (not `redis-ha`), explicit budgets on every component, `server.insecure`, bcrypt admin password |
| `ingressroute.yaml` | `argocd.devinflake.com` — redirect on `web`, TLS-ALPN via `letsencrypt` on `websecure` |

`root-app.yaml` is deliberately **not** here yet: with no `Application`
manifests anywhere in `gitops/`, an app-of-apps root would be empty and would
fail to sync. It arrives in phase 2, once `apps/` and `addons/` hold real
Applications (see the phased rollout in `docs/gitops.md`).

## Install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl apply -f gitops/bootstrap/namespace.yaml
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --version 10.18.0 \
  -f gitops/bootstrap/values.yaml --wait
kubectl apply -f gitops/bootstrap/ingressroute.yaml
```

The admin password in `values.yaml` is already a **bcrypt hash** of the unified
cluster password (same credential as Grafana and the Traefik/Longhorn/Prometheus
basic-auth) — a hash, never the plaintext, so it is safe to commit. To rotate it:

```bash
mkpasswd -m bcrypt -R 10 '<new password>'   # paste over argocdServerAdminPassword
```

Bumping `argocdServerAdminPasswordMtime` forces Argo CD to re-hash the account
password from the value, so do that in the same change.

The step is idempotent: `helm upgrade --install` plus declarative `kubectl
apply` files, so a rebuild just runs it again.

## Budget

`values.yaml` carries explicit requests/limits for controller, server,
repo-server, redis and applicationSet (≈ 450m CPU / 608Mi requested in total,
≈ 2.3 GiB limited). Check reality after the first sync with
`kubectl top pod -n argocd` and adjust before enabling anything else — the same
four 4 GB nodes also run Longhorn, Prometheus and Grafana.

## After bootstrap

1. **Adopt the pilot app** (`gitops/apps/whoami/`) with *manual* sync and
   confirm `argocd app diff whoami` is empty before any auto-sync exists — that
   is phase 1's exit criterion.
2. Keep `scripts/install-addons.sh` working as the fallback until phase 3.
3. Bootstrap Sealed Secrets before phase 2 consumes sealed manifests, and back
   up its private key — losing it makes every sealed secret in git
   unrecoverable.
