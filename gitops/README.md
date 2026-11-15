# GitOps

Declarative cluster state for Argo CD. **Nothing here is applied yet** — the live
cluster is still installed by `scripts/install-addons.sh`. The design, phased
rollout, and conventions are in [../docs/gitops.md](../docs/gitops.md); the
component upgrade that must land first is in
[../docs/upgrade.md](../docs/upgrade.md).

## Layout

```
bootstrap/   Argo CD install and the root Application — the only non-Git step
projects/    AppProject definitions (source and destination boundaries)
addons/      MetalLB, Longhorn, Traefik, monitoring, sealed-secrets
apps/        First-party workloads, one directory per Application (Kustomize)
```

## Conventions

- Argo CD tracks `master`. `dev` accumulates changes until a promotion PR.
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
