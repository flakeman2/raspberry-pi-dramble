# GitOps

Declarative cluster state for Argo CD. **Thirteen Applications are live and
reconciling from `dev`**: the six first-party apps (including the new
`grafana-dashboards`) plus Sealed Secrets, MetalLB, Traefik, `traefik-config`,
Prometheus, Grafana and Longhorn (2026-11-21). `scripts/install-addons.sh`
remains the fallback until phase 3 is complete. The design,
phased rollout, and conventions are in [../docs/gitops.md](../docs/gitops.md);
the component upgrade that landed first is in
[../docs/upgrade.md](../docs/upgrade.md).

## Layout

```
bootstrap/   Argo CD install and the root Application — the only non-Git step
projects/    AppProject definitions (source and destination boundaries)
addons/      sealed-secrets, MetalLB, Traefik, traefik-config,
             prometheus, grafana, longhorn
apps/        First-party workloads, one directory per Application (Kustomize);
             grafana-dashboards renders JSON dashboards into labelled ConfigMaps
```

## Conventions

- Argo CD tracks `dev`, the repository default — a merge into `dev` is the
  deployment target, and there is no promotion step.
- Third-party software is consumed as a Helm chart in the `Application` source
  (`source.helm` with a committed values file), not as vendored YAML.
- First-party workloads use Kustomize with a `kustomization.yaml` per directory.
- Sync waves: `-10` namespaces, `-5` CRDs and controllers, `0` addons, `1+`
  workloads.
- Set `ServerSideApply=true` on Longhorn; its CRDs exceed the client-side apply
  annotation limit.
- Leave `prune` off until an app's diff is clean, then enable it per app.
- Secrets are sealed (see [../docs/gitops.md](../docs/gitops.md#secrets)); no
  plaintext `Secret` manifests belong in this tree.

## Intended bootstrap order

1. Install k3s and join all nodes (`scripts/install-*.sh`).
2. Install Argo CD ([bootstrap/](bootstrap/README.md)).
3. Apply the root Application; it discovers `projects/`, `addons/`, `apps/`.
4. Install the sealed-secrets controller before any app that references a
   sealed secret.
