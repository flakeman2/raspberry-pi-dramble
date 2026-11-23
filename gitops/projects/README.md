# Projects

`AppProject` definitions that bound what each `Application` may touch. The
`dramble` project in `default.yaml` is live and is created by the root
app-of-apps at wave `-10`, before any child Application that uses it.

There is one tenant today: the repository owner. Keep one project with a tight
source and destination allow-list instead of relying on the `default` project,
which permits every repository and every namespace. The root itself is the one
exception: it must use `default` because `dramble` does not exist until the root
creates it.

`default.yaml` pins:

- `sourceRepos` — this repository plus the Helm repositories the charts come
  from. An Application whose chart comes from a Helm repo is rejected without
  one.
- `destinations` — the in-cluster API server, any namespace. This is pragmatic
  for one tenant; narrow it if a second appears.
- `clusterResourceWhitelist` — the cluster-scoped kinds the add-ons actually
  create, derived by scanning the vendored manifests and rendering every Helm
  chart. Missing entries have blocked adoptions before (`PriorityClass` for
  Longhorn, `ValidatingWebhookConfiguration` for MetalLB, `IngressClass` for
  Traefik), so extend it from evidence, not memory.
- `namespaceResourceBlacklist` — no `ResourceQuota` or `LimitRange` anywhere.

Notes:

- Do not grant `cluster-admin` to an `Application`; the project's allow-lists are
  the boundary.
- Adding a Helm repository here without registering it in CI's render step just
  moves the failure from Argo CD to the manifests job. Update both.
- The emergency sync window used during the 2026-11-18 apiserver failures is
  gone; do not reintroduce a deny window without an explicit incident record.
