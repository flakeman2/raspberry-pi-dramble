# Longhorn

Longhorn `1.13.0` provides the default `longhorn` StorageClass with **3
replicas**. It is installed from the **vendored** manifest in this directory,
not from the network:

```bash
kubectl apply -f cluster/longhorn/longhorn-v1.13.0.yaml
```

`longhorn-v1.13.0.yaml` (243,976 bytes, 6,705 lines, 62 resources) was copied
from the pinned upstream release and **verified byte-identical to the live
cluster** with `kubectl diff` before it was committed — exit 0, no output, so
applying it changes nothing.

Why vendored rather than fetched at install time:

- the rebuild path must not depend on `raw.githubusercontent.com` being
  reachable while installing *storage*;
- nothing verifies the bytes of a 238 KB cluster-admin manifest pulled live,
  and **git tags are movable** (only the commit hash is immutable);
- upgrades become a reviewable diff instead of an opaque re-fetch;
- CI's `kubeconform` job validates everything under `cluster/` — a remote URL
  would put 28 CRDs and 6 NetworkPolicies outside validation entirely.

Provenance: upstream tag `v1.13.0`, resolving to commit `c3d88832bd8c`.

```text
sha256  d0f99488e7b2789312d45b0127ce7388df71a971e6fca2085e88635303cc0a1f
```

### Updating

```bash
NEW=1.14.0
curl -sSL -o "cluster/longhorn/longhorn-v${NEW}.yaml" \
  "https://raw.githubusercontent.com/longhorn/longhorn/v${NEW}/deploy/longhorn.yaml"
sha256sum "cluster/longhorn/longhorn-v${NEW}.yaml"
kubectl diff -f "cluster/longhorn/longhorn-v${NEW}.yaml"   # review BEFORE applying
```

Bump `LONGHORN_VERSION` in `scripts/install-addons.sh` to match, and open the
diff as a PR — that review *is* the upgrade plan.

The manifest creates the `longhorn-system` namespace, the `longhorn`
StorageClass, Longhorn CRDs, the manager DaemonSet, the CSI driver, the UI, and
the `default-replica-count=3` setting.

Prerequisites on every node (see [../../docs/hardware.md](../../docs/hardware.md)):

```bash
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

`nfs-common` supplies the NFS **client** that the node needs to mount RWX
volumes: the share-manager serves NFS from inside the cluster, but the mount
itself happens on the node. Without `mount.nfs`, an RWX pod stalls in
`ContainerCreating` with `MountVolume.MountDevice failed … exit status 32`
(observed on 2026-11-15 during the rebuild).

Volumes used by this cluster:

| PVC | Size | Mode | Consumer |
|---|---|---|---|
| `traefik/traefik` | 128 MiB | RWO | ACME store |
| `mysite-nginx/mysite-content` | 1 GiB | RWX | nginx document root |
| `monitoring/prometheus-alertmanager` | 2 GiB | RWO | Alertmanager |
| `monitoring/prometheus-server` | 8 GiB | RWO | Prometheus |
| `monitoring/grafana` | 10 GiB | RWO | Grafana |

Verify:

```bash
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState'
kubectl get pvc -A
```
