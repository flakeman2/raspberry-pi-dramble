# Action items

Prioritized work for the live cluster. This replaces the old
`k3s-manifests/ACTION-ITEMS.md`, which described a design (kube-vip,
cert-manager, ghost-blog, Prometheus Operator) the cluster never adopted.

Status snapshot: [cluster-status.md](cluster-status.md). Rebuild procedure:
[redeploy.md](redeploy.md).

## P0 — do first

### 1. Rotate exposed credentials — done (2026-11-14/16)

- ~~**k3s join token**~~ — rotated automatically by the rebuild (2026-11-15): a
  fresh server generated a new token and the old one died with the cluster.
- ~~**Grafana admin password and `authsecret`**~~ — rotated *before* the wipe;
  the values live only in the off-repo export directory (`0600`).
- ~~**Park-Your-Domain (Namecheap) passwords**~~ — rotated **2026-11-16**, one
  unique value per domain (Namecheap enforces unique passwords), loaded into
  the two-key Secret `dyn-dns-credentials` (`password-devinflake.com`,
  `password-flakeman2.com`). Verified with manual jobs: **`<ErrCount>0</ErrCount>`
  on all three records of both domains**. The interim password files —
  including the value exposed during the investigation — were deleted.

Worth keeping as a permanent caveat: the CronJobs report `Complete` **even when
a password is wrong**, because the API answers HTTP 200 with `<ErrCount>` in the
body:

```bash
for j in $(kubectl -n default get jobs -o name --sort-by=.metadata.creationTimestamp | tail -2); do
  printf '%s  ' "$j"; kubectl -n default logs "$j" | grep -o '<ErrCount>[0-9]*</ErrCount>' | tail -1
done
# want <ErrCount>0</ErrCount> from BOTH jobs
```

### 2. ~~Stop kube2's broken `k3s.service`~~ — moot after the rebuild (2026-11-15)

The unit no longer exists: kube2 was reimaged, and `install-agent.sh` now
disables any stray `k3s` unit before enabling `k3s-agent.service`, so the
failure mode cannot recur. Verified 2026-11-16: `k3s` → `not-found`,
`k3s-agent` → `enabled`, 0 restarts.

### 3. ~~Decide the fate of `rpi-argon` and `rpi-retropie`~~ — done 2026-11-14

Both were unreachable. They were removed from the cluster:

```bash
kubectl delete node rpi-argon rpi-retropie
# force-deleted the eight pods still bound to those node names
```

Longhorn removed its node records automatically. All 15 replicas remained
`running` and all five volumes stayed healthy. Prometheus now reports 23 targets
with **0 down** (was 30 targets / 7 down).

If the hardware is ever returned to service, reimage it and join with
`scripts/install-agent.sh`; it will register as a new node.

### 4. ~~Control access to the cluster API~~ — verified clean 2026-11-16

The k3s API is reachable on `192.168.0.61:6443` **from the LAN only**. Verified
after the rebuild: the public IP does not answer on `6443` (the router forwards
only 80/443), `.201` does not answer on `6443`, and the only `LoadBalancer`
Service in the cluster is `traefik/traefik` → `192.168.0.201`. Re-check after
any router change:

```bash
PUB=$(curl -s https://api.ipify.org)
timeout 6 bash -c "exec 3<>/dev/tcp/$PUB/6443" && echo "EXPOSED" || echo "closed ✓"
kubectl get svc -A --no-headers | awk '$3=="LoadBalancer" {print $1"/"$2, $5}'
```

## P1 — correctness and resilience

### 5. ~~Rebuild off end-of-life versions~~ — done 2026-11-15/16

The rebuild replaced the frozen 2021 stack (k3s 1.22 EOL, Longhorn 1.2.3,
MetalLB 0.11.0, Traefik 2.5.6) with k3s `v1.36.6+k3s1`, Longhorn `1.13.0`,
MetalLB `0.16.2` (CRD pool), Traefik `v3.7.18` / chart `42.4.0`, Prometheus
`3.16.0` / chart `29.47.2`, and Grafana `13.3.1` / chart `14.4.1` — all live,
all verified against A4.

- Plan, gates and the in-place alternative: [upgrade.md](upgrade.md)
- Post-rebuild snapshot **and the rebuild history**: [cluster-status.md](cluster-status.md)
- The procedure that was actually followed: [redeploy.md](redeploy.md)
- The irreplaceable `mysite-content` was restored byte-identical from
  `cluster/workloads/mysite/content/`.

What is left in this area is follow-through rather than upgrade: Argo CD
([gitops.md](gitops.md)) plus the P1/P2 items below.

### 6. Add resource requests/limits and probes — done in git, 2026-11-14

**63 of 64 containers had no limits; 37 of 64 had no probes** — on a 4 GB node
a busy workload could OOM it. The manifests now carry budgets and probes; they
take effect when the cluster is rebuilt (the live cluster is untouched):

| Workload | requests | limits | probes |
|---|---|---|---|
| `mysite-nginx` | 25m / 32Mi | 500m / 128Mi | readiness `GET /`, liveness TCP 80 |
| `jekyll-website` ×3 | 25m / 32Mi | 500m / 128Mi | TCP 80 (already present) |
| `whoami` ×2 | 10m / 16Mi | 200m / 64Mi | readiness + liveness `GET /` |
| Traefik | 50m / 64Mi | 500m / 256Mi | the chart's `/ping` probes |
| Grafana | 100m / 128Mi | 500m / 512Mi | the chart's `GET /api/health` |
| Prometheus server | 200m / 512Mi | memory only (1Gi) | chart defaults |
| DNS CronJobs ×2 | 5m / 16Mi | 100m / 64Mi | n/a (Jobs) |

Grafana's probes come from the chart, so only the budget was added there; the
same is true of Traefik's `/ping` probes (the chart passes `--ping=true`). The
numbers are starting points — tune them from metrics after the rebuild, and do
not add a CPU limit to Prometheus or the Longhorn managers without measuring
first.

### 7. Finish the Grafana setup

- **0 dashboards.** Import node/cluster/Longhorn/Traefik dashboards and persist
  them (ConfigMap + dashboard provider, or export JSON into `cluster/dashboards/`).
- The Prometheus datasource was added through the UI; it is now codified in
  `cluster/monitoring/grafana-values.yaml`.
- Add an HTTP→HTTPS redirect for `grafana.devinflake.com`. Unlike the other
  hosts it returns `404` on port 80.
- Set a Grafana root URL and disable anonymous access if not already default.

### 8. ~~Remove pi-hole~~ — done (2026-11-14 → 11-16)

`pi-hole-service` was an `ExternalName` to `192.168.0.46:80`, which never
answered. Cleared in three passes:

- **Manifests (2026-11-14):** namespace, Service, `redirect-to-https`
  middleware, both IngressRoutes, and Traefik's `allowExternalNameServices`
  flags removed from the repo.
- **DNS (2026-11-16):** the `pi-hole.devinflake.com` record deleted at the
  provider.
- **Landing page (2026-11-16):** the dead link removed from
  `cluster/workloads/mysite/content/index.html` and the content redeployed
  (git is the source of truth for that PVC — copy with a **pod** name, not
  `deploy/…`):

  ```bash
  POD=$(kubectl -n mysite-nginx get pod -l app=mysite-nginx -o jsonpath='{.items[0].metadata.name}')
  kubectl -n mysite-nginx cp cluster/workloads/mysite/content/. "$POD":/usr/share/nginx/html/
  ```

  Verified live: zero `pi-hole` references in the served page, page and images
  all `200`, pod bytes identical to git.

## P2 — hygiene

### 9. ~~Pin image tags~~ — done 2026-11-17

The live cluster used floating tags for `nginx:latest` and `traefik/whoami`
(`curlimages/curl` was already pinned to `7.81.0` in the DNS manifests).

Pinned to **`nginx:1.31.8`** and **`traefik/whoami:v1.12.0`**, chosen by
matching the *running* container's index digest against the registry rather
than guessing: both images' `latest` and version tags resolved to the same
digest as what was already running, so pinning changed nothing content-wise —
it only stops `latest` from drifting on a node restart.

### 10. Backups

Longhorn has no backup target, no recurring jobs, and no off-cluster copy — and
since the 2026-11-14 decision to wipe all four disks without keeping the old
ones, **there is no rollback at all**. Today's mitigation is that the only
irreplaceable data is `mysite-content`, which is byte-identical to
`cluster/workloads/mysite/content/` in git, plus the off-repo secret export.

Before the reimage: verify the A0 gate in [upgrade.md](upgrade.md). After it:
add an S3/NFS backup target with a recurring snapshot job and test a restore,
so the next failure does not depend on git alone.

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

### 15. Adopt Argo CD — phases 1–2 done; 3–4 remain

**Phase 1 (2026-11-17):** Argo CD bootstrapped from `gitops/`, the `whoami`
pilot adopted, `argocd app diff` empty, reconciling from `dev`.

**Phase 2 (2026-11-17):** `mysite-nginx`, `jekyll-website`, `dashboards` and
`dns` adopted alongside `whoami` — all five on automated sync with self-heal
and prune. Each was registered with sync disabled first, diffed, and only then
given automation, per the convention that prune stays off until an app's diff
is clean. Sealed Secrets landed the same day and closed this item's blocker.

**Remaining:** addons as Argo Applications (3) and the rest of CI (4).
Conventions: [gitops.md](gitops.md) and [../gitops/README.md](../gitops/README.md).

### 16. ~~Restore host tuning: Wi-Fi, Bluetooth, and the overclock~~ — done 2026-11-16

The Ubuntu 26.04 image came up with `wlan0` and Bluetooth **enabled** and **no
overclock**. All five lines were appended to `/boot/firmware/config.txt` on
every node — one node at a time, drained first — and verified after each
reboot:

| Node | `wlan0` | Bluetooth | `scaling_max_freq` | `get_throttled` | Temp (settled) |
|---|---|---|---|---|---|
| kube1 | gone | 0 entries | 2000000 | `0x0` | 47.2 °C |
| kube2 | gone | 0 entries | 2000000 | `0x0` | 54.0 °C |
| kube3 | gone | 0 entries | 2000000 | `0x0` | 53.5 °C |
| kube4 | gone | 0 entries | 2000000 | `0x0` | 51.6 °C |

Also done on all four: **`sudo systemctl disable --now wpa_supplicant`** — the
image had left it `enabled` and `active` with a live process despite there
being no `wlan0` to manage. `NetworkManager` is inactive and `systemd-networkd`
drives `eth0`, so nothing legitimate needs it. Verified afterwards:
`enabled=disabled active=inactive procs=0`, default route and DNS intact,
cluster 4/4 `Ready`, Prometheus **24 up / 0 down**.

kube1 went **last** on purpose: as the only server its reboot takes the API
down with it (single-server topology — see item 12). SSH returned after 110 s
and the API about 15 s after that; volumes re-attached `healthy` within 80 s of
uncordoning. The procedure is kept below for the next reimage.

```bash
export KUBECONFIG=~/.kube/config-dramble-k3s
kubectl drain kube2 --ignore-daemonsets --delete-emptydir-data --timeout=10m

ssh pi@192.168.0.62
sudo tee -a /boot/firmware/config.txt <<'EOF'

# host tuning, restored after the 2026-11-15 reimage
dtoverlay=disable-wifi
dtoverlay=disable-bt
over_voltage=6
arm_freq=2000
gpu_mem=16
EOF
sudo reboot
```

Before moving on to the next node, verify:

```bash
kubectl uncordon kube2
kubectl get nodes                                     # this node Ready
kubectl -n longhorn-system get volumes.longhorn.io    # healthy again
ip link show wlan0                                    # fails: no such device
sudo vcgencmd measure_clock arm                       # ≈ 2000000000
sudo vcgencmd get_throttled                           # 0x0
```

After the last node, stop the Wi-Fi supplicant the image enables by default —
it has no `wlan0` to manage:

```bash
sudo systemctl disable --now wpa_supplicant    # on each of the four nodes
systemctl is-enabled wpa_supplicant            # expect: disabled
systemctl is-active wpa_supplicant             # expect: inactive
```

Active cooling is assumed: if temperature climbs or `get_throttled` is
non-zero, drop `over_voltage`/`arm_freq` first rather than the cooling.

Afterwards, update [hardware.md](hardware.md) — its bill of materials currently
records Wi-Fi as present-but-down and Bluetooth as not disabled, and the boot
config section says no overclock is set — and re-measure the health baseline.
