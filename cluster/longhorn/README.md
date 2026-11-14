# Longhorn

Longhorn `1.2.3` provides the default `longhorn` StorageClass with **3
replicas**. It was installed from the upstream manifest, not Helm (there is no
Helm release Secret in `longhorn-system`).

```bash
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.2.3/deploy/longhorn.yaml
```

The manifest creates the `longhorn-system` namespace, the `longhorn`
StorageClass, Longhorn CRDs, the manager DaemonSet, the CSI driver, the UI, and
the `default-replica-count=3` setting.

Prerequisites on every node (see [../../docs/hardware.md](../../docs/hardware.md)):

```bash
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid
```

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
