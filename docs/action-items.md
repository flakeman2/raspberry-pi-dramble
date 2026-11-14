# Action items

Prioritized work for the live cluster. This replaces the old
`k3s-manifests/ACTION-ITEMS.md`, which described a design (kube-vip,
cert-manager, ghost-blog, Prometheus Operator) the cluster never adopted.

Status snapshot: [cluster-status.md](cluster-status.md). Rebuild procedure:
[redeploy.md](redeploy.md).

## P0 — do first

### 1. Rotate exposed credentials

- **k3s join token** was printed from kube2 during the investigation.
- **Park-Your-Domain password** is inline in both live CronJobs and was read
  during the investigation.
- Treat the Grafana admin password as sensitive too; it was used read-only via
  the API.

Rotate the token (see [secrets.md](secrets.md#k3s-join-token)) and the DDNS
password, then re-apply `cluster/dns/cronjobs.yaml` so the password moves into
the `dyn-dns-credentials` Secret.

```bash
kubectl -n default get cronjob dyn-dns-devinflake.com \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].command}'
# should contain ${DDNS_PASSWORD}, not a literal password
```

### 2. Stop kube2's broken `k3s.service`

Both `k3s.service` and `k3s-agent.service` are enabled. The server unit points at
the dead kube-vip VIP `192.168.0.200` and has restarted ~1.58 million times.

```bash
ssh pi@192.168.0.62
sudo systemctl disable --now k3s
systemctl is-enabled k3s k3s-agent     # disabled, enabled
sudo journalctl -u k3s --since '5 min ago' --no-pager | tail
```

No workloads are affected; `k3s-agent` continues to serve the node.

### 3. Decide the fate of `rpi-argon` and `rpi-retropie`

Both are powered off/unreachable. They contribute seven down Prometheus targets,
stale MetalLB speaker pods, and two Longhorn instance-manager pods stuck
`Terminating` for 627 days. No Longhorn replica lives on either node, so no
volume is degraded.

**Repair:** power them on, confirm they rejoin, then:

```bash
kubectl get nodes -w
kubectl -n longhorn-system get nodes.longhorn.io
```

**Remove:** if they are permanently retired:

```bash
kubectl delete node rpi-argon rpi-retropie
kubectl -n longhorn-system delete node.longhorn.io rpi-argon rpi-retropie
kubectl -n longhorn-system delete pod --field-selector=status.phase!=Running --force --grace-period=0
```

Before deleting, confirm no Longhorn replica references them:

```bash
kubectl -n longhorn-system get replicas.longhorn.io \
  -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState'
```

### 4. Control access to the cluster API

The k3s API is reachable on `192.168.0.61:6443` from the LAN. If the router
forwards 6443, stop that immediately; nothing in this design requires remote API
access. Only 80/443 should reach `192.168.0.201`.

## P1 — correctness and resilience

### 5. Plan the upgrade off end-of-life versions

The whole stack is from 2021:

| Component | Live | Notes |
|---|---|---|
| k3s / Kubernetes | 1.22.5 | EOL since 2022-05 |
| Longhorn | 1.2.3 | upgrade through 1.3 → 1.4 → … |
| MetalLB | 0.11.0 | 0.13 moved the address pool to `IPAddressPool` CRs |
| Traefik | 2.5.6 | 2.x → 3.x changes the CRD API group |
| Prometheus | 2.31.1 | chart 15.1.3 |
| Grafana | 8.3.5 | chart 6.21.4 |

Kubernetes does not support skipping minor versions. Upgrade **one minor at a
time** (1.22 → 1.23 → 1.24 → …), server first, then agents one at a time:

```bash
# on kube1
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.23.x+k3s1 \
  INSTALL_K3S_EXEC="server --disable servicelb --disable local-storage --disable traefik" \
  sh -

# on each agent, one at a time
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.23.x+k3s1 \
  K3S_URL=https://192.168.0.61:6443 K3S_TOKEN=... \
  INSTALL_K3S_EXEC="agent" sh -
```

Component order after Kubernetes is current:

1. MetalLB → 0.13+ (migrate `ConfigMap/config` to `IPAddressPool` +
   `L2Advertisement`)
2. Longhorn → next minor, verify replicas healthy between hops
3. Traefik → 2.10 then v3 (rewrite `traefik.containo.us` → `traefik.io`)
4. Prometheus/Grafana charts

Do the upgrade after the rebuild is verified, not during it.

### 6. Add resource requests/limits and probes

**78 of 79 containers have no limits; 42 of 73 have no probes.** The scheduler
sees ~24% CPU and ~0–1% memory allocated per node, so a busy workload can OOM a
4 GB Pi. Start with the application workloads and Traefik/Grafana:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

Do not set a CPU limit on Prometheus/Longhorn managers without measuring first.

### 7. Finish the Grafana setup

- **0 dashboards.** Import node/cluster/Longhorn/Traefik dashboards and persist
  them (ConfigMap + dashboard provider, or export JSON into `cluster/dashboards/`).
- The Prometheus datasource was added through the UI; it is now codified in
  `cluster/monitoring/grafana-values.yaml`.
- Add an HTTP→HTTPS redirect for `grafana.devinflake.com`. Unlike the other
  hosts it returns `404` on port 80.
- Set a Grafana root URL and disable anonymous access if not already default.

### 8. Fix or remove pi-hole

`pi-hole-service` is an `ExternalName` to `192.168.0.46:80`, which is
unreachable. Either restore that host or remove the namespace, Service, and two
IngressRoutes so the ingress stops advertising a broken endpoint.

## P2 — hygiene

### 9. Pin image tags

The live cluster uses floating tags for `nginx:latest`, `traefik/whoami`, and
`curlimages/curl`. The DNS manifests in this repo pin curl to `7.81.0`; pin the
other two after choosing versions.

### 10. Backups

Longhorn has no backup target, no recurring jobs, and no off-cluster copy. The
cluster can lose all five volumes with the Pis. Add an S3/NFS backup target and
a recurring snapshot/backup job, then test a restore.

### 11. Pod disruption budgets and NetworkPolicies

- No application PDBs. The 12 existing PDBs are Longhorn's auto-created
  `instance-manager` PDBs.
- No NetworkPolicies. At minimum, restrict ingress to `monitoring`, `traefik`,
  and `longhorn-system`, and egress from the DNS CronJobs.

### 12. Reduce single points of failure

- One control-plane node (`kube1`) with embedded SQLite. Losing it stops the API.
  An HA control plane would need three servers and an external datastore (or
  embedded etcd).
- Longhorn runs 3 replicas across 4 nodes; losing two nodes can take a volume
  offline.

### 13. Monitoring gaps

- Alertmanager has no receivers configured; add at least one.
- Prometheus retention is 15 days with an 8 GiB volume. Decide whether that is
  enough.
- Add alerts for node NotReady, PVC/volume degraded, certificate expiry, and
  CronJob failure.

### 14. Cleanup

- Delete completed CronJob pods if they accumulate faster than the history
  limits allow (the live jobs had 6).
- The `kube-root-ca.crt` "not registered" FailedMount warnings on DynDNS jobs
  are transient and harmless; they disappear once the ConfigMap is cached.
- Remove the abandoned kube-vip, cert-manager, ghost-blog, and
  kubernetes-dashboard material from any remaining notes or scripts.
