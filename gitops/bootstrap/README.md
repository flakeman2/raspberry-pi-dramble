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
| `root-app.yaml` | the root `Application`: `path: gitops/`, project `default`, automated prune/self-heal, wave `-10` |
| `ingressroute.yaml` | `argocd.devinflake.com` — redirect on `web`, TLS-ALPN via `letsencrypt` on `websecure` |

The root uses the `default` project because it creates the `drumble` AppProject
itself. It is excluded from the `gitops/kustomization.yaml` it points at, so
Argo CD never manages the manifest that installs it. `ingressroute.yaml` is
excluded for a different reason: it needs Traefik CRDs that only exist after the
`traefik-config` child has synced.

## Install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl apply -f gitops/bootstrap/namespace.yaml
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --version 10.18.0 \
  -f gitops/bootstrap/values.yaml --wait

# The root owns the AppProject and all fourteen child Applications.
kubectl apply -f gitops/bootstrap/root-app.yaml

# LAST: these routes use Traefik CRDs installed by the traefik-config child.
kubectl wait --for condition=established --timeout=60s \
  crd/ingressroutes.traefik.io crd/middlewares.traefik.io crd/tlsoptions.traefik.io
kubectl apply -f gitops/bootstrap/ingressroute.yaml
```

`scripts/install-addons.sh` performs this whole sequence, preceded by the
sealed-secrets key restore, namespace creation and sealed manifests. On an
existing cluster, apply `root-app.yaml` once by hand; after that, changes to the
Application set are ordinary git commits.

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

1. Confirm the root is `Synced/Healthy` and owns all fourteen children:
   `kubectl -n argocd get applications`.
2. Verify it created the project, not the other way round:
   `kubectl -n argocd get appproject drumble`.
3. Back up the sealed-secrets private key. The controller is now a child
   Application, but losing its key still makes every sealed secret in git
   unrecoverable — see [../../cluster/secrets/README.md](../../cluster/secrets/README.md).
