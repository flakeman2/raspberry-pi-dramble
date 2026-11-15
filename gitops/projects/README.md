# Projects

`AppProject` definitions that bound what each `Application` may touch.
**Not yet applied.**

There is one tenant today: the repository owner. Keep one project with a tight
source and destination allow-list instead of relying on the `default` project,
which permits every repository and every namespace.

Planned `default.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: drumble
  namespace: argocd
spec:
  description: Raspberry Pi Drumble cluster
  sourceRepos:
    - https://github.com/flakeman2/raspberry-pi-dramble
  destinations:
    - server: https://kubernetes.default.svc
      namespace: "*"
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  namespaceResourceBlacklist:
    - group: ""
      kind: ResourceQuota
    - group: ""
      kind: LimitRange
```

Notes:

- The namespace wildcard is a pragmatic choice for one tenant. Narrow it per app
  if a second tenant ever appears.
- Do not grant `cluster-admin` to an `Application`; the project's allow-lists are
  the boundary.
- `sourceRepos` must stay pinned to this repository so a compromised manifest
  cannot pull from elsewhere.
