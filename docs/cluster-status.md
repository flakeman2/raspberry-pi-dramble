# Cluster status snapshot

**Captured:** 2026-11-14 via `~/.kube/config-dramble-k3s` and SSH to each node.
**Updated:** 2026-11-14, after removing `rpi-argon` and `rpi-retropie`.
**Scope:** read-only inspection followed by the node removal described below.

This is a point-in-time snapshot of the live cluster. For what *should* be
running, see [architecture.md](architecture.md). For the rebuild procedure, see
[redeploy.md](redeploy.md).

## Headline

- The cluster is **serving traffic** and is healthy on **four nodes**.
- The stack is a **frozen 2021 release** and is **end-of-life**.
- `rpi-argon` and `rpi-retropie` were **removed** after being unreachable; all
  Longhorn volumes stayed healthy throughout.
- `kube2` runs a **broken, looping `k3s.service`** that has restarted ~1.58M
  times because it points at the abandoned kube-vip VIP `192.168.0.200`.
- Both dynamic-DNS CronJobs have the **password inline in the command**.
- The repository previously described a design the cluster never adopted
  (kube-vip, cert-manager, ghost-blog, Prometheus Operator). It has been replaced
  by this documentation.

## Versions

| Component | Version | Installed via |
|---|---|---|
| k3s | `v1.22.5+k3s1` (EOL 2022-05) | install script, 2021-12-29 |
| Longhorn | `1.2.3` | upstream `deploy/longhorn.yaml` |
| MetalLB | `0.11.0` | upstream `manifests/metallb.yaml` |
| Traefik | chart `10.9.1` / app `2.5.6` | Helm release `traefik` |
| Prometheus | chart `15.1.3` / app `2.31.1` | Helm release `prometheus` |
| Grafana | chart `6.21.4` / app `8.3.5` | Helm release `grafana` |
| metrics-server | `0.5.0` | k3s add-on |
| CoreDNS | `1.8.4` | k3s add-on |
| containerd | `1.5.8-k3s1` | bundled |

No `cert-manager`, no kube-vip, no Prometheus Operator CRDs, no `ServiceMonitor`
objects.

## Nodes

| Node | IP | Role | Status | Notes |
|---|---|---|---|---|
| `kube1` | 192.168.0.61 | control-plane,master | **Ready** | 31w uptime, 52.5 °C |
| `kube2` | 192.168.0.62 | node | **Ready** | stray `k3s.service` looping |
| `kube3` | 192.168.0.63 | node | **Ready** | 52.5 °C |
| `kube4` | 192.168.0.64 | node | **Ready** | 54.5 °C |

All nodes report `MemoryPressure=False`, `DiskPressure=False`,
`PIDPressure=False`. There are no unreachable nodes and no stale node taints.

`rpi-argon` (192.168.0.37) and `rpi-retropie` (192.168.0.7) were deleted from
the cluster. The removal sequence was:

```bash
kubectl delete node rpi-argon rpi-retropie
# force-deleted the eight pods still bound to those node names
kubectl get nodes                       # 4 Ready
kubectl -n longhorn-system get nodes.longhorn.io   # 4 nodes
```

Longhorn removed its own node records when the Kubernetes Node objects
disappeared. All 15 replicas remained `running` and all five volumes stayed
`healthy` before, during, and after the removal.

### kube2's broken unit

```
k3s.service: activating (auto-restart), restart counter at 1580789
ExecStart=/usr/local/bin/k3s server --server https://192.168.0.200:6443 \
  --disable servicelb --disable local-storage
fatal: failed to get CA certs: Get "https://192.168.0.200:6443/cacerts": no route to host
```

Both `k3s.service` and `k3s-agent.service` are enabled. The agent is what serves
the node; the server unit is residue from an abandoned kube-vip attempt and
should be disabled:

```bash
sudo systemctl disable --now k3s     # on kube2
```

`192.168.0.200` does not respond and no kube-vip DaemonSet/ServiceAccount exists.

## Workloads

| Namespace | Workload | Ready | Image |
|---|---|---|---|
| kube-system | `coredns` | 1/1 | `rancher/mirrored-coredns-coredns:1.8.4` |
| kube-system | `metrics-server` | 1/1 | `rancher/mirrored-metrics-server:v0.5.0` |
| metallb-system | `controller` | 1/1 | `quay.io/metallb/controller:v0.11.0` |
| metallb-system | `speaker` (DaemonSet) | 4/4 | `quay.io/metallb/speaker:v0.11.0` |
| longhorn-system | `longhorn-manager` (DaemonSet) | 1/1 per node | `longhornio/longhorn-manager:v1.2.3` |
| longhorn-system | `longhorn-driver-deployer` | 1/1 | `longhornio/longhorn-manager:v1.2.3` |
| longhorn-system | `longhorn-ui` | 1/1 | `longhornio/longhorn-ui:v1.2.3` |
| longhorn-system | `csi-attacher` / `csi-provisioner` / `csi-resizer` / `csi-snapshotter` | 3/3 each | Longhorn CSI |
| longhorn-system | `instance-manager-*` | 8 running | Longhorn |
| traefik | `traefik` | 1/1 | `traefik:2.5.6` |
| monitoring | `prometheus-server` | 1/1 | `quay.io/prometheus/prometheus:v2.31.1` |
| monitoring | `prometheus-alertmanager` | 1/1 | `quay.io/prometheus/alertmanager:v0.23.0` |
| monitoring | `prometheus-kube-state-metrics` | 1/1 | `k8s.gcr.io/kube-state-metrics/kube-state-metrics:v2.3.0` |
| monitoring | `prometheus-pushgateway` | 1/1 | `prom/pushgateway:v1.4.2` |
| monitoring | `prometheus-node-exporter` (DaemonSet) | 4/4 | `quay.io/prometheus/node-exporter:v1.3.0` |
| monitoring | `grafana` | 1/1 | `grafana/grafana:8.3.5` |
| mysite-nginx | `mysite-nginx` | 1/1 | `nginx:latest` |
| jekyll | `jekyll-website` | 3/3 | `flakeman2/jekyll:1.0.4` |
| whoami | `whoami` | 2/2 | `traefik/whoami` |
| default | `dyn-dns-*` CronJobs | completed | `curlimages/curl` (untagged) |

Total: 64 pods, 12 namespaces, 18 Deployments, 5 DaemonSets, 2 CronJobs, 23
Services, 11 IngressRoutes, 6 Middlewares, 1 TLSOption, 8 Longhorn PDBs.

### Node removal cleanup

The eight pods that were still bound to `rpi-argon`/`rpi-retropie` had to be
force-deleted (`--force --grace-period=0`); Kubernetes 1.22 did not garbage
collect them after the Node objects were deleted. They were the MetalLB speaker,
Longhorn manager/CSI/engine-image, Prometheus node-exporter, and two Longhorn
instance-manager pods. Nothing was running on those hosts.

## Storage

Longhorn reports all five volumes `attached`, `healthy`, `robustness=healthy`.
All PVCs are `Bound`. 15 replicas: 5 on kube1, 3 on kube2, 3 on kube3, 4 on kube4.
All 15 are `running` on the four remaining nodes. `default-replica-count=3`.

| PVC | Size | Mode | State |
|---|---|---|---|
| `traefik/traefik` | 128 MiB | RWO | Bound, healthy |
| `mysite-nginx/mysite-content` | 1 GiB | RWX | Bound, healthy |
| `monitoring/prometheus-alertmanager` | 2 GiB | RWO | Bound, healthy |
| `monitoring/prometheus-server` | 8 GiB | RWO | Bound, healthy |
| `monitoring/grafana` | 10 GiB | RWO | Bound, healthy |

## Networking

- MetalLB pool `192.168.0.201–192.168.0.250`, L2.
- Traefik Service `192.168.0.201`; ports 80→web, 443→websecure.
- No `Ingress` objects; 11 `IngressRoute` objects.
- `TLSOption/default`: `minVersion: VersionTLS12`.
- ACME store `/data/acme.json`, 79,156 bytes, 6 certificates:

| Certificate | SANs | Expires |
|---|---|---|
| `devinflake.com` | `www.devinflake.com`, `flakeman2.com`, `www.flakeman2.com` | 2027-01 |
| `blog.devinflake.com` | — | 2027-01 |
| `grafana.devinflake.com` | `grafana.flakeman2.com` | 2027-01 |
| `traefik.devinflake.com` | `traefik.flakeman2.com` | 2027-01 |
| `longhorn.devinflake.com` | `longhorn.flakeman2.com` | 2027-01 |
| `pi-hole.devinflake.com` | — | 2027-01 |

Verified live: `devinflake.com` and `blog.devinflake.com` return 301→HTTPS→200
with a valid Let's Encrypt certificate (`issuer O=Let's Encrypt, CN=YR2`).
`grafana.devinflake.com` returns 302 to the login page with a valid certificate.
`pi-hole.devinflake.com` cannot work: `192.168.0.46:80` is unreachable.

## Monitoring

- Prometheus scrapes **23 targets; 0 are down** after the node removal. Before
  the removal it scraped 30 targets with 7 down, all tied to the two dead nodes.
- Prometheus retention 15 days, data on the 8 GiB PVC.
- Grafana has **0 dashboards**.
- Grafana datasource `Prometheus` → `http://prometheus-server` is present,
  default, `access=proxy`, `httpMethod=POST`, `manageAlerts=true`. It was added
  through the UI, not through Helm values (now codified in
  `cluster/monitoring/grafana-values.yaml`).
- Grafana admin credentials come from the `monitoring/grafana` Secret
  (`admin-user`, `admin-password`, `ldap-toml`), created by the chart.
- Alertmanager is running but has no receivers configured beyond chart defaults.

## Security / hygiene observations

- **63 of 64 containers have no resource limits.** Allocated requests are only
  ~24% CPU and 0–1% memory per node; on 4 GB Pis this is an OOM risk.
- **37 of 64 long-running containers have no readiness or liveness probe.**
- **No NetworkPolicies.**
- Application PDBs: none. The only PDBs are Longhorn's auto-created
  `instance-manager` PDBs.
- **No secrets management**: Secrets are plain Kubernetes `Secret` objects; no
  Sealed Secrets/SOPS/External Secrets.
- `config.yml` in the working tree contains legacy plaintext database/Drupal
  passwords. It is gitignored and must never be committed.
- The k3s join token and the Park-Your-Domain password were exposed during the
  investigation (token printed from kube2, DDNS password inline in the CronJob
  spec). **Rotate both.** See [secrets.md](secrets.md).
- The API server serving certificate is valid until **2027-03-05**.
- `/readyz` passes; no unhealthy APIServices.

## Repo drift that was resolved

The old `k3s-manifests/` tree described a different cluster. It was removed and
replaced by `cluster/`:

| Old draft | Live reality |
|---|---|
| kube-vip DaemonSet + VIP `.200` | absent; `.200` dead; caused kube2's loop |
| `ghost-blog` namespace, 2 replicas, LB `.249` | never existed |
| `mysite` 2 replicas, 15 GiB RWO, LB `.250` | 1 replica, 1 GiB RWX, ClusterIP + IngressRoutes |
| cert-manager issuers + test certificate | absent; Traefik ACME does TLS |
| Prometheus Operator CRs / ServiceMonitors | plain Helm `prometheus` chart |
| one DynDNS CronJob | two CronJobs (`devinflake.com`, `flakeman2.com`) |
| `kubernetes-dashboard` RBAC | namespace absent, never applied |

## Recommended priorities

See [action-items.md](action-items.md). Immediate items:

1. Rotate the k3s join token and dynamic-DNS password.
2. Disable the stray `k3s.service` on kube2.
3. Plan the k3s/component upgrade (1.22 is EOL).
4. Add resource requests/limits and probes; import Grafana dashboards.
