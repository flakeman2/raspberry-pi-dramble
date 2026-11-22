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

The k3s API is reachable on `192.168.0.44:6443` **from the LAN only** (moved from `192.168.0.61` to `dflake-nettop` on 2026-11-21; see item 17). Verified
after the rebuild: the public IP does not answer on `6443` (the router forwards
only 80/443), `.201` does not answer on `6443`, and the only `LoadBalancer`
Service in the cluster is `traefik/traefik` → `192.168.0.201`. Re-check after
any router change:

```bash
PUB=$(curl -s https://api.ipify.org)
timeout 6 bash -c "exec 3<>/dev/tcp/$PUB/6443" && echo "EXPOSED" || echo "closed ✓"
kubectl get svc -A --no-headers | awk '$3=="LoadBalancer" {print $1"/"$2, $5}'
```

### 17. ~~Move the k3s control plane off kube1~~ — done 2026-11-21

**The cluster's control plane is failing every 10–20 minutes.** By 22:00 on
2026-11-18 k3s on kube1 had restarted **17 times** — 16 that day, against one
the day before — and the interval had collapsed from hours to ~20 minutes.

**Cause, measured rather than guessed:**

```
Slow SQL: DELETE ... name=Compact   duration=39.27s
level=fatal  msg="Transaction commit failed: sql: transaction has already been committed or rolled back"
```

k3s uses **kine** (SQLite) as its datastore, in-process, writing to kube1's
disk. A compaction stalled for 39 seconds, every write timed out, the
transaction rolled back, and k3s exited `1` — systemd `Restart=always` brings
it back, which is why the cluster keeps coming up again. On kube1: **79%
iowait**, load **20–27 sustained** across 4 cores, 4 GB RAM with **no swap**,
and `longhorn-manage` plus `argocd-application-controller` both in **D state**
(uninterruptible I/O sleep). The node is I/O-starved, not CPU-starved.

**Why kube1 specifically:** it runs the control plane, the Longhorn storage
engine and the monitoring/ingress stack on one contended disk. The datastore
sits on exactly the resource that is saturated.

**Interim measure, in place 2026-11-18 → lifted 2026-11-21:** an emergency
`syncWindows` deny window on *both* AppProjects (`drumble` in
`gitops/projects/default.yaml`; `default` is created by Argo CD and is not in
this repository). It denied automated sync — and therefore selfHeal — so the
12 Applications stopped retrying against an apiserver that could not answer,
while `manualSync` kept operator-initiated syncs working. The `drumble` block
was never committed to `dev`, so lifting the hold needed **no git revert**: both
projects were patched live with `{"spec":{"syncWindows":null}}` after the move.
Note this install does not ship the `SyncWindow` CRD, so the AppProject field is
the only way to do it.

**Decision:** move the k3s control plane to a dedicated **x86_64 server —
same LAN, always-on, fast disk**. That removes the datastore from the
contended resource instead of tuning around it.

**Sequencing, because of item 10:** there is deliberately **no off-cluster
Longhorn backup**, and the `LonghornVolume`/`Snapshot`/`Backup` objects live
*inside that datastore*. A control-plane migration **is** a datastore
migration — the highest-risk operation available on this cluster, against
five volumes with no recovery path if it is botched. Volume *data* stays on
the Pi disks; only metadata moves, and that is exactly what must be verified.

**Executed 2026-11-21** (full operator runbook:
[control-plane-migration-nettop.md](control-plane-migration-nettop.md)):

1. **Back up first**: kube1's k3s was stopped so the SQLite WAL was quiesced,
   then `/var/lib/rancher/k3s/server` (database **and** TLS certs) was archived
   — 12 MB, SHA-256 `b2f718ce…b616afc` — with an untouched rollback copy left
   on kube1. Adding swap was considered but skipped: the fix was to move the
   datastore off the contended disk, not tune around it.
2. **New server**: `dflake-nettop` (`192.168.0.44`, x86_64, always-on, fast
   disk) installed as a **tainted** server with `SKIP_START/SKIP_ENABLE`, the
   datastore restored, and the apiserver cert reissued for the new IP.
3. **Cutover**: kube1's `k3s.service` disabled and its state directory renamed
   to `server.retired-2026-11-21`; all four Pis rejoined as agents with
   `K3S_URL=https://192.168.0.44:6443`. The admin kubeconfig was repointed in
   place (the CA and client certs survived, so no new credentials were needed).
4. **Verified**: all 5 nodes `Ready`, 5/5 Longhorn volumes attached and
   `healthy`, all PVCs Bound, no failing pods, and the public names unaffected
   — `.201` is a MetalLB address and never moved.
5. **Aftercare**: the Longhorn conflict loop below was cleared, then the Argo
   holds were lifted. All 12 Applications are now Synced/Healthy with automation
   back on.

**The first surprise after the move:** nettop's CPU pegged at **99%** even
though iowait was **0** and kine compactions were down to **104–467 ms** (from
39.27 s on kube1). `/metrics` showed **1,518 `PUT longhorn.io/nodes` in 30 s,
1,430 of them `409 Conflict`** — a stale-informer retry loop after the datastore
moved, not datastore load. A rolling restart of `longhorn-manager` (one pod at a
time) and `longhorn-global-manager` cleared it: **0 conflicts**, nettop back to
15–23% CPU, all five volumes untouched. **Switching to etcd was considered and
rejected** — single-node etcd adds raft and fsync work on top of the same failed
writes, without fixing the loop.

## P1 — correctness and resilience

### 5. ~~Rebuild off end-of-life versions~~ — done 2026-11-15/16

The rebuild replaced the frozen 2021 stack (k3s 1.22 EOL, Longhorn 1.2.3,
MetalLB 0.11.0, Traefik 2.5.6) with k3s `v1.36.6+k3s1`, Longhorn `1.13.0`,
MetalLB `0.16.2` (CRD pool), Traefik `v3.7.18` / chart `42.4.0`, Prometheus
`3.16.0` / chart `29.47.2`, and Grafana `13.3.1` / chart `14.4.1` — all live
and verified against A4. Traefik and Grafana have since been bumped to chart
`42.4.1` / `v3.7.19` and `14.5.0` (2026-11-18); the current inventory is
[cluster-status.md](cluster-status.md).

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

### 7. ~~Finish the Grafana setup~~ — done in git (2026-11-21)

- **Four dashboards, authored here and persisted from git:** cluster, nodes,
  Traefik and Longhorn. The JSON lives in `cluster/monitoring/dashboards/` and
  Kustomize turns each file into a ConfigMap labelled `grafana_dashboard: "1"`;
  the chart's dashboard sidecar provisions them on every change. Nothing
  long-lived has to be built in the UI, which is what makes the no-backup
  decision in item 10 safe for Grafana.
- The Prometheus datasource is codified in `cluster/monitoring/grafana-values.yaml`
  with the fixed UID `prometheus`, so the dashboards reference it without
  templating.
- Longhorn's own metrics were not being collected at all: its default
  NetworkPolicy denies port 9500 from outside `longhorn-system`. Added a
  `longhorn-metrics` scrape job plus a narrow allow rule, both owned by the
  `prometheus` Application.
- Grafana now has two IngressRoutes: `grafana-dashboard` (TLS on `websecure`)
  and `grafana-dashboard-redirect` (plain `web` with the existing
  `redirect-to-https` middleware). Traefik applies `tls` at router level, so
  the earlier single TLS router never matched port 80 and returned 404; the
  split makes port 80 return a 301 instead.
- `grafana.ini.server.root_url` is `https://grafana.devinflake.com` and
  `auth.anonymous.enabled` is explicitly `false`.

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
(`curlimages/curl` was already pinned in the DNS manifests; that pin is
now `8.23.0`).

Pinned to **`nginx:1.31.8`** and **`traefik/whoami:v1.12.0`**, chosen by
matching the *running* container's index digest against the registry rather
than guessing: both images' `latest` and version tags resolved to the same
digest as what was already running, so pinning changed nothing content-wise —
it only stops `latest` from drifting on a node restart.

### 10. Backups — state files done; Longhorn deliberately not backed up

**Decided 2026-11-18.** Two separate things, so they read separately:

**Cluster state — done.** `state.db` (plus the WAL sidecars) and the join
token are backed up off kube1 to `dflake-nettop`. Copying `state.db` alone
would not be enough: SQLite runs in WAL mode, so committed writes can still be
sitting in `state.db-wal`.

**Longhorn volumes — no off-cluster backup, on purpose.** The `BackupTarget`
stays unconfigured and no snapshot job runs. What this buys and costs:

- **Covered:** a single node dying. Longhorn keeps three replicas across
  nodes, so the PVCs keep serving while the cluster rebuilds around them.
- **Not covered:** cluster-wide loss — all four disks at once, a botched
  reimage, or anything that destroys the cluster rather than a member of it.
  That is exactly what happened on 2026-11-14, and it would have taken the
  PVCs with it.

The exposure is small *today*, because every PVC holds either something
regenerable or something already in git:

| PVC | If lost |
|---|---|
| `mysite-content` | byte-identical to `cluster/workloads/mysite/content/` in git |
| `traefik` (`acme.json`) | Let's Encrypt re-issues |
| `prometheus-server`, `prometheus-alertmanager` | history regenerates |
| `monitoring/grafana` | dashboards now provisioned from git (item 7); users/preferences would be lost |

**That last row was the catch.** Grafana was the one place real work could
accumulate with no way to recover it, which is why [item
7](#7-finish-the-grafana-setup--done-in-git-2026-11-21) was load-bearing:
dashboards are provisioned from ConfigMaps in git, never built in the UI. Same
for anything else long-lived in a PVC.

Also outstanding: the off-repo secret export still needs to live somewhere
that survives the machine, alongside the `.kube` copies on `dflake-nettop`.

Note for [upgrade.md](upgrade.md) §B0: it still lists "configure a Longhorn
backup target" as **mandatory** before a hop, on the grounds that Longhorn
cannot be downgraded. That instruction is unchanged by this decision — if a
B-series upgrade ever happens, revisit it rather than skipping it silently.

### 11. Pod disruption budgets and NetworkPolicies

- No first-party application PDBs. The six PDBs are all Longhorn's own: four
  `instance-manager` PDBs plus `csi-attacher` and `csi-provisioner`.
- Sixteen NetworkPolicies exist: four shipped by the Argo CD chart, seven in
  `longhorn-system` (including `allow-prometheus-longhorn-metrics`, which lets
  Prometheus scrape Longhorn over HTTPS), and five first-party policies added
  2026-11-22. Ingress allow-lists isolate `monitoring`, `mysite-nginx`, `jekyll`
  and `whoami` to node IPs (kubelet probes and SNAT'd Traefik traffic), the
  `traefik` namespace and the `monitoring` namespace. The DynDNS CronJobs in
  `default` are isolated to DNS (53) and HTTPS (443) egress. Still open: first-
  party PDBs, and ingress policy for `longhorn-system` beyond its own seven.

### 12. Reduce single points of failure

- One control-plane node (`dflake-nettop`) with embedded SQLite/kine. Losing
  it still stops the API. HA would need three servers and embedded etcd —
  deliberately not done; see item 17 and the runbook for why.
- Longhorn runs 3 replicas across 4 nodes; losing two nodes can take a volume
  offline.

### 13. Monitoring gaps

- ~~Alertmanager has no receivers configured; add at least one.~~ — resolved
  2026-11-21 with an ntfy.sh webhook; the full URL (including the topic) is a
  SealedSecret, mounted as a file and read via `url_file` because Alertmanager
  does not expand environment variables in its config.
- ~~Prometheus retention is 15 days with an 8 GiB volume. Decide whether that is
  enough.~~ — 15 days kept and made explicit: measured ~1.8 GiB of TSDB blocks
  and ~99k head series, about a quarter of the 8 GiB PVC. Revisit at 4 GiB of
  blocks; `retentionSize: 6Gi` is the next lever.
- ~~Add alerts for node NotReady, PVC/volume degraded, and CronJob failure.~~ —
  five rules cover node NotReady, PVC not Bound, Longhorn degraded/faulted, and
  CronJob failure. **Certificate expiry is deliberately deferred**: Traefik's
  ACME certificate lives in a file on its PVC, so there is no cert-manager
  expiration metric to alert on.

### 14. Cleanup

- Delete completed CronJob pods if they accumulate faster than the history
  limits allow (the live jobs had 6).
- The `kube-root-ca.crt` "not registered" FailedMount warnings on DynDNS jobs
  are transient and harmless; they disappear once the ConfigMap is cached.
- Remove the abandoned kube-vip, cert-manager, ghost-blog, and
  kubernetes-dashboard material from any remaining notes or scripts.

### 15. ~~Adopt Argo CD — phases 1–4~~ — done 2026-11-21

**Phase 1 (2026-11-17):** Argo CD bootstrapped from `gitops/`, the `whoami`
pilot adopted, `argocd app diff` empty, reconciling from `dev`.

**Phase 2 (2026-11-17):** `mysite-nginx`, `jekyll-website`, `dashboards` and
`dns` adopted alongside `whoami` — all five on automated sync with self-heal
and prune. Each was registered with sync disabled first, diffed, and only then
given automation, per the convention that prune stays off until an app's diff
is clean. Sealed Secrets landed the same day and closed this item's blocker.

**Phase 3 (2026-11-17/18):** the `drumble` AppProject, then Sealed Secrets,
MetalLB, Traefik and monitoring — Traefik as two Applications, `traefik` (the
Helm release) and `traefik-config` (the CRs), because an Application is either
a chart or a directory of manifests, never both; Prometheus and Grafana as one
each, since they are simply two independent releases in one namespace. Every
one followed the same register-diff-then-automate discipline, and the
AppProject whitelist was widened three times by the adoptions themselves:
`PriorityClass` for Longhorn, `ValidatingWebhookConfiguration` for MetalLB,
`IngressClass` for Traefik.

**Phase 3 completion (2026-11-21):** Longhorn joined as an Application with
`prune: false` and no `ServerSideApply` (measured rather than assumed — see the
comments in its `application.yaml`). The root app-of-apps then landed: one
root `Application` on the `default` project owns the `drumble` AppProject at
wave `-10` and fourteen children through an explicit `gitops/kustomization.yaml`.
`install-addons.sh` is bootstrap-only, with `--print-pins` keeping CI and
`check-updates.sh` on the same version pins. **Phase 4** gates are live and the
image pipeline ships in Ephesus. Conventions:
[gitops.md](gitops.md) and [../gitops/README.md](../gitops/README.md).

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

kube1 went **last** on purpose: at the time it was the only server, so its
reboot took the API down with it (single-server topology — see item 12; it has
been an agent since 2026-11-21). SSH returned after 110 s
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
