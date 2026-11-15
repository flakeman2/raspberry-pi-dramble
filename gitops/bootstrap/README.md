# Bootstrap

The chicken-and-egg step: Argo CD cannot install itself, so this directory holds
the one remaining imperative action. Everything after this is Git.

**Not yet valid on this cluster.** Argo CD 3.6 requires Kubernetes 1.34–1.37 and
the cluster runs k3s 1.22.5; see
[../../docs/gitops.md](../../docs/gitops.md#prerequisite-the-kubernetes-upgrade).
The version and resource values below are the intended starting point, to be
confirmed against the cluster that exists at that time.

## Planned install

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version <PINNED_CHART_VERSION> \
  -f values.yaml --wait
```

`values.yaml` will pin the chart and image tag and keep the footprint small on
the 4 GB nodes:

- `dex.enabled: false`, `notifications.enabled: false`;
- `redis-ha.enabled: false`, single controller/server/repo-server replicas;
- explicit requests/limits on every component;
- `configs.params.server.insecure: true`, because Traefik terminates TLS.

Then expose the UI with an `IngressRoute` for `argocd.devinflake.com` using the
existing `letsencrypt` TLS-ALPN resolver, and apply the root Application
(`root-app.yaml`) pointing at `gitops/` on `master`.

## Resource budget

Start around 100m CPU / 128Mi memory requested per component (controller,
repo-server, redis, server) and adjust after `kubectl top pod -n argocd` on a
real sync. Do not give Argo CD a CPU limit it can hit during a large diff.

## After bootstrap

The root Application adopts `projects/`, `addons/`, and `apps/`. Keep a copy of
the sealed-secrets controller key (see the plan) before relying on sealed
manifests, and keep `scripts/install-addons.sh` working until phase 3 of the
rollout is complete.
