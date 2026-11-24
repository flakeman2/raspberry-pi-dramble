# GitOps

Declarative cluster state for Argo CD. **Seventeen Applications are live and
reconciling from `dev`**: the root app-of-apps, seven first-party apps (including
`grafana-dashboards` and `blog-cms-api`), seven add-ons — Sealed Secrets, MetalLB,
Traefik, `traefik-config`, Prometheus, Grafana and Longhorn — and two
cluster-policy apps, NetworkPolicies and PodDisruptionBudgets (2026-11-23).
`scripts/install-addons.sh` is bootstrap-only; the child Applications are
managed entirely by the root. The design, phased rollout, and conventions are
in [../docs/gitops.md](../docs/gitops.md); the component upgrade that landed
first is in [../docs/upgrade.md](../docs/upgrade.md).

## Layout

```
kustomization.yaml  Explicit list: the AppProject + 16 child Applications
bootstrap/    Argo CD install and root-app.yaml — the only non-Git step
projects/     AppProject definitions (source and destination boundaries)
addons/       sealed-secrets, MetalLB, Traefik, traefik-config,
              prometheus, grafana, longhorn
apps/         First-party workloads, one directory per Application (Kustomize);
              grafana-dashboards renders JSON into labelled ConfigMaps
policies/     Cluster policy: NetworkPolicies and PodDisruptionBudgets,
              each backed by a directory under cluster/
```

## Conventions

- Argo CD tracks `dev`, the repository default — a merge into `dev` is the
  deployment target, and there is no promotion step.
- Third-party software is consumed as a Helm chart in the `Application` source
  (`source.helm` with a committed values file), not as vendored YAML.
- First-party workloads use Kustomize with a `kustomization.yaml` per directory.
- Sync waves: `-10` root and AppProject, `-5` CRDs and controllers, `0` addons,
  `1+` workloads.
- Longhorn's Application keeps `prune: false`; deleting its CRDs would cascade
  into volume records with no off-cluster backup. It does not need
  `ServerSideApply` — the largest manifest is ~21 KB, well below kubectl's
  256 KB annotation limit.
- Leave `prune` off until an app's diff is clean, then enable it per app.
- Secrets are sealed (see [../docs/gitops.md](../docs/gitops.md#secrets)); no
  plaintext `Secret` manifests belong in this tree.

## Bootstrap order

1. Install k3s and join all nodes (`scripts/install-*.sh`).
2. Run `scripts/install-addons.sh`: restore the sealed-secrets key, create
   namespaces, apply the sealed manifests, install Argo CD from
   [bootstrap/](bootstrap/README.md), and apply `bootstrap/root-app.yaml`.
3. The root creates the `dramble` AppProject and all sixteen children. Apply
   `bootstrap/ingressroute.yaml` only after the Traefik CRDs exist, so Argo CD's
   own public route is the last imperative step.
