# Cluster status snapshot

**Captured:** 2026-11-16 via `~/.kube/config-dramble-k3s` and SSH to each node.
**Updated:** 2026-11-21 after the control-plane move to `dflake-nettop`;
the node table and pod totals below reflect the live cluster.
**Scope:** first snapshot of the **rebuilt** cluster. The snapshot taken before
the rebuild is preserved verbatim at the bottom of this page.
**Related:** [architecture.md](architecture.md) (design),
[redeploy.md](redeploy.md) (procedure), [upgrade.md](upgrade.md) (plan and A4
exit criteria), [secrets.md](secrets.md).

This is a point-in-time record of what is actually running.

## Rebuild history

### Where it stood — 2026-11-14

- Four Pis serving traffic on a **frozen 2021 stack**: k3s `v1.22.5+k3s1`
  (EOL since 2022-05), Longhorn `1.2.3`, MetalLB `0.11.0`, Traefik `2.5.6`,
  Prometheus `2.31.1`, Grafana `8.3.5` — roughly 25 supervised upgrade hops
  away from anything supported.
- `rpi-argon` and `rpi-retropie` had died and were removed (2026-11-14);
  `kube2` still ran a stray server unit looping **~1.58 million times** against
  an abandoned kube-vip VIP `192.168.0.200`.
- Both site sources had been recovered: the landing page is byte-identical to
  `cluster/workloads/mysite/content/`, and the blog rebuilt **byte-for-byte**
  from `flakeman2/Ephesus` (source recovered, Dockerfile found, all posts and
  history intact).
- The decision was made to **rebuild rather than upgrade**, the repository was
  retargeted to current versions (A1), and an A0 preservation gate was run.

### What was done — 2026-11-14 → 2026-11-16

| Phase | When | Outcome |
|---|---|---|
| **A0** preserve + gate | 11-14 | mysite tarball (byte-identical to git), `acme.json`, rotated `authsecret`/`grafana` written off-repo at `0600`, host state recorded, tools installed |
| **A1** retarget repo | 11-14 | k3s `v1.36.6+k3s1`, MetalLB `0.16.2` + CRD pool, Traefik chart `42.4.0`, Prometheus `29.47.2`, Grafana `14.4.1` (new repo) — validated with `pluto` + `kubeconform` (PRs #8, #9, #12) |
| **Reimage — no rollback** | 11-15 | all four disks wiped → **Ubuntu Server 26.04.1 LTS**, kernel `7.0.0-1023-raspi`, cgroup v2, netplan; docs corrected for it (PR #16) |
| **Phase 0** prerequisites | 11-15 | `iscsid` enabled on all four, `/etc/hosts` cluster mapping recreated, host-tuning follow-up recorded (PR #17) |
| **Phase 1** k3s | 11-15 | `v1.36.6+k3s1` single server + 3 agents, all `Ready` in minutes; kube2's double-unit bug gone **by construction** (`install-agent.sh` disables a stray `k3s` unit) |
| **Phase 2** secrets | 11-15 | rotated `authsecret`/`grafana` applied; interim DDNS password (rotation still pending) |
| **Phase 3** add-ons | 11-15/16 | MetalLB `0.16.2` (`.201` pinned), Longhorn `1.13.0`, Traefik `42.4.0` / `v3.7.18`, Prometheus `29.47.2` / `3.16.0`, Grafana `14.4.1` / `13.3.1`, Traefik CRs, workloads, CronJobs |
| **Phase 4** content + routing | 11-16 | site restored (88,877 B = git), routes verified through `.201` |
| **Certificates** | 11-16 ~03:20Z | re-issued after the router was pointed back at `.201` |

**Downtime:** from the wipe until ~03:20Z on 2026-11-16 the public names were
parked behind an operator-run **Caddy maintenance page at `192.168.0.44`** (the
owner's deliberate stand-in). While it fronted `:443` Let's Encrypt TLS-ALPN
challenges could not complete, which is why issuance had to wait for the flip.

### Defects the rebuild surfaced — all fixed, all recorded in git

| # | Defect | Symptom seen live | Fixed in |
|---|---|---|---|
| 1 | Chart 42 sets pod-level `runAsNonRoot: true`; the `volume-permissions` init container inherited uid 65532 and could not chown a root-owned Longhorn volume | Traefik pod stuck `Init:Error`, `helm --wait` timed out | #18 |
| 2 | **Traefik v3 accepts one hostname per `Host()`** — the v2 multi-host form fails to parse | every multi-host route 404'd (apex, whoami, all dashboards) | #19 |
| 3 | **`nfs-common` is required to mount RWX** — I had wrongly removed it from the prerequisites in #16 | `mysite-content` stuck `ContainerCreating`, `MountVolume.MountDevice failed … exit status 32` | #20 |
| 4 | **MetalLB v0.16 moved metrics to HTTPS `9120` + bearer-token RBAC**; the vendored manifest had stale HTTP annotations and no TokenReview/SAR grants | 5 Prometheus targets permanently `down` (`400`) | #21 |
| 5 | **Traefik's RWO `acme.json` deadlocks `RollingUpdate`** (`maxUnavailable: 0` waits for a detach that never comes) — chart 42 exposes no `strategy` value | every restart/upgrade hung until a manual pod delete; twice | #22 |

Lessons worth keeping: validating *field names* in migrated CRs (the `traefik.io`
retarget) is not the same as validating *rule expressions*; and a doc
"optimization" (`nfs-common`) should be tested against the workload that needs
it — `mysite-content` is RWX.

### Result against A4 exit criteria (`upgrade.md`)

| Criterion | Status |
|---|---|
| 4/4 nodes `Ready`, server `v1.36.6+k3s1`, kubectl within one minor | ✅ (`v1.37.1` client) |
| 5 PVCs `Bound`, Longhorn volumes healthy, 3 replicas each | ✅ 5/5, 15/15 replicas |
| `devinflake.com`, `blog`, `grafana` valid certificates; whoami at `.201` | ✅ **all 11 names** then serving Let's Encrypt certs (14 today) |
| Prometheus targets with none down | ✅ **24 up / 0 down** |
| CronJobs complete | ✅ ran `03:30Z`, both jobs `Complete` (see caveat below) |
| Docs updated to the new versions | ✅ this page + README/architecture/hardware |

## Headline

- Four `Ready` nodes on **k3s `v1.36.6+k3s1`** / Ubuntu 26.04.1 / containerd
  `2.3.7-k3s1.36`, **no pressure conditions**, no failing APIServices.
- The stack is **fully supported** and matches the repository pins exactly.
- **60 pods**, all `Running` or `Completed` — nothing pending, nothing crash-looping.
- Public HTTPS works on all fourteen hostnames; the landing page content is
  byte-identical to git; the blog serves image `flakeman2/jekyll:1.0.6` with
  the post `/dramble_wiped_and_rebuilt/` live.

## Versions

| Component | Version | Installed via |
|---|---|---|
| k3s | `v1.36.6+k3s1` | `scripts/install-server.sh` / `install-agent.sh` |
| Longhorn | `1.13.0` | upstream `deploy/longhorn.yaml` |
| MetalLB | `0.16.2` | vendored native manifest + `IPAddressPool`/`L2Advertisement` |
| Traefik | chart `42.4.1` / app `v3.7.19` | Helm release `traefik` |
| Prometheus | chart `29.47.2` / app `3.16.0` | Helm release `prometheus` |
| Grafana | chart `14.5.0` / app `13.3.1` | Helm release `grafana` (grafana-community repo) |
| metrics-server | `v0.9.0` | k3s add-on |
| CoreDNS | `1.14.7` | k3s add-on |
| containerd | `2.3.7-k3s1.36` | bundled |

Still true of the design: no `cert-manager`, no kube-vip, no Prometheus
Operator CRDs, no `ServiceMonitor` objects.

## Nodes

| Node | IP | Role | Status | Notes |
|---|---|---|---|---|
| `dflake-nettop` | 192.168.0.44 | control-plane | **Ready** | x86_64 server, tainted; owns kine/SQLite datastore |
| `kube1` | 192.168.0.61 | agent | **Ready** | old server disabled; `server.retired-2026-11-21` retained; still a MetalLB speaker |
| `kube2` | 192.168.0.62 | node | **Ready** | stray-unit bug gone: only `k3s-agent.service` exists |
| `kube3` | 192.168.0.63 | node | **Ready** | |
| `kube4` | 192.168.0.64 | node | **Ready** | |

Health baseline, measured 2026-11-16 (~3.5 h after first boot, all workloads
running; `vcgencmd` needs `sudo` on this image):

| Node | Uptime | Load (1/5/15) | Memory used | Rootfs used | Temp | `get_throttled` |
|---|---|---|---|---|---|---|
| kube1 | 3h 28m | 1.43 / 1.09 / 1.02 | 1836 / 3777 MB | 8.4 G / 458 G | 42.8 °C | `0x0` |
| kube2 | 3h 28m | 2.44 / 1.27 / 0.76 | 1128 / 3777 MB | 8.3 G / 458 G | 50.6 °C | `0x0` |
| kube3 | 3h 17m | 0.49 / 0.56 / 0.61 | 1355 / 3777 MB | 9.9 G / 458 G | 55.5 °C | `0x0` |
| kube4 | 3h 28m | 0.46 / 0.54 / 0.59 | 1474 / 3777 MB | 8.0 G / 458 G | 51.6 °C | `0x0` |

No under-voltage or thermal throttling on any node.

## Workloads

| Namespace | Workload | Ready | Image |
|---|---|---|---|
| kube-system | `coredns` | 1/1 | `rancher/mirrored-coredns-coredns:1.14.7` |
| kube-system | `metrics-server` | 1/1 | `rancher/mirrored-metrics-server:v0.9.0` |
| metallb-system | `controller` | 1/1 | `quay.io/metallb/controller:v0.16.2` |
| metallb-system | `speaker` (DaemonSet) | 4/4 | `quay.io/metallb/speaker:v0.16.2` |
| longhorn-system | `longhorn-manager` (DaemonSet) | 1/1 per node | `longhornio/longhorn-manager:v1.13.0` |
| longhorn-system | `longhorn-driver-deployer`, `longhorn-global-manager`, `longhorn-ui` | 1/1, 3/3, 2/2 | Longhorn `1.13.0` |
| longhorn-system | CSI sidecars (`attacher`/`provisioner`/`resizer`/`snapshotter`) | 3/3 each | Longhorn CSI |
| longhorn-system | `share-manager-*` (one per RWX volume) | 1/1 | Longhorn NFS server |
| traefik | `traefik` | 1/1 | `docker.io/traefik:v3.7.19`, strategy **`Recreate`** |
| monitoring | `prometheus-server` | 1/1 | `quay.io/prometheus/prometheus:v3.16.0` |
| monitoring | `prometheus-alertmanager` (StatefulSet) | 1/1 | Alertmanager (ntfy receiver) |
| monitoring | `prometheus-kube-state-metrics` / `pushgateway` | 1/1 each | chart defaults |
| monitoring | `prometheus-prometheus-node-exporter` (DaemonSet) | 4/4 | chart defaults |
| monitoring | `grafana` | 1/1 | `docker.io/grafana/grafana:13.3.1-distroless`, strategy **`Recreate`** |
| mysite-nginx | `mysite-nginx` | 1/1 | `nginx:latest` |
| jekyll | `jekyll-website` | 3/3 | `flakeman2/jekyll:1.0.6` |
| whoami | `whoami` | 2/2 | `traefik/whoami` |
| default | `dyn-dns-*` CronJobs | Complete | `curlimages/curl:8.23.0` |

Totals: **66 pods**, 12 namespaces, 23 Deployments, 5 DaemonSets, 2
StatefulSets, 2 CronJobs, 27 Services, 12 IngressRoutes, 5 Middlewares, 1
TLSOption, 6 PDBs, 11 NetworkPolicies (6 Longhorn's own, 4 Argo CD's).

The workload count deliberately **excludes Job-owned pods** (CronJob and Job
output). Those come and go with `successfulJobsHistoryLimit`, so a total pod
count drifts every time a scheduled job runs and its predecessor is evicted —
which is exactly how this line was caught reading 66 while the cluster sat at
65 with nothing actually changed. `scripts/verify-docs.sh` asserts the same
workload-only number.

The workload deltas from the 2026-11-16 rebuild snapshot are all Argo CD (+1
namespace, +5 pods, +4 Deployments, +1 StatefulSet, +5 Services, +4
NetworkPolicies, +3 IngressRoutes from `prometheus` and the two `argocd`
routes) plus Sealed Secrets (+1 pod, +1 Deployment, +2 Services).

These numbers are asserted against the live cluster by
[`scripts/verify-docs.sh`](../scripts/verify-docs.sh); run it after changing
anything that alters the shape of the cluster.

The IngressRoutes are the pre-reimage set minus the two `pi-hole` routes
(`pi-hole` was removed from the manifests before the rebuild — action item #8).

## Storage

All five volumes are `attached`/`healthy` with `default-replica-count=3`;
**15 replicas running across the four nodes**. Default StorageClass:
`longhorn`.

| PVC | Size | Mode | State |
|---|---|---|---|
| `traefik/traefik` | 128 MiB | RWO | Bound, healthy |
| `mysite-nginx/mysite-content` | 1 GiB | RWX | Bound, healthy — content restored from git (88,877 bytes, md5-verified) |
| `monitoring/storage-prometheus-alertmanager-0` | 2 GiB | RWO | Bound, healthy |
| `monitoring/prometheus-server` | 8 GiB | RWO | Bound, healthy |
| `monitoring/grafana` | 10 GiB | RWO | Bound, healthy |

Note the alertmanager PVC name changed with chart 29 (`prometheus-alertmanager`
→ `storage-prometheus-alertmanager-0`, StatefulSet-backed).

## Networking

- MetalLB pool `192.168.0.201–192.168.0.250`, L2; the range is **reserved in
  the router's DHCP configuration**.
- Traefik Service pinned to `192.168.0.201` via
  `metallb.universe.tf/loadBalancerIPs` and announced by whichever speaker
  holds it — currently **kube1's MAC `dc:a6:32:96:f9:49`** (the MAC is not
  fixed; it follows the speaker).
- No `Ingress` objects; 12 `IngressRoute` objects; `TLSOption/default`
  `minVersion: VersionTLS12`.
- ACME store `/data/acme.json`: **7 certificates covering all fourteen public
  names**. Five were re-issued 2026-11-16 when the router returned to `.201`;
  `prometheus` and `argocd` were issued later as those two UIs were exposed:

| Stored certificate | Covers (verified over HTTPS) |
|---|---|
| `devinflake.com` | `devinflake.com`, `www.devinflake.com`, `flakeman2.com`, `www.flakeman2.com` |
| `blog.devinflake.com` | `blog.devinflake.com` |
| `grafana.devinflake.com` | `grafana.devinflake.com`, `grafana.flakeman2.com` |
| `prometheus.devinflake.com` | `prometheus.devinflake.com`, `prometheus.flakeman2.com` |
| `traefik.devinflake.com` | `traefik.devinflake.com`, `traefik.flakeman2.com` |
| `longhorn.devinflake.com` | `longhorn.devinflake.com`, `longhorn.flakeman2.com` |
| `argocd.devinflake.com` | `argocd.devinflake.com` |

Verified from outside: every name returns a Let's Encrypt certificate with the
right behaviour — apex/blog `200` after a `308` redirect, grafana `302`,
longhorn/traefik/prometheus `401` (basic auth), argocd `200` at the login
page, `/whoami` answering behind `PathPrefix(/whoami)`.

## Monitoring

- Prometheus: **24 targets up, 0 down** — `kubernetes-api-servers` 1,
  `kubernetes-nodes` 4, `kubernetes-nodes-cadvisor` 4, `kubernetes-pods` 1,
  `kubernetes-service-endpoints` 7, **`metallb-metrics` 5**, `prometheus` 1,
  `prometheus-pushgateway` 1.
- MetalLB metrics are scraped by an explicit job (`scheme: https`,
  `insecureSkipVerify`, bearer token, port `9120`) — v0.16 removed the plain
  HTTP endpoint and the annotation-based job cannot reach it (see defect #4).
- Retention 15 days on the 8 GiB PVC; the four Grafana dashboards are now
  provisioned from git (`cluster/monitoring/dashboards/*.json` via the
  `grafana-dashboards` Application); its `Prometheus` datasource
  (`http://prometheus-server`, proxy, POST, UID `prometheus`) is codified in
  `cluster/monitoring/grafana-values.yaml`.
- Alertmanager routes all alerts to an ntfy.sh webhook whose full URL is sealed
  in `cluster/secrets/sealed/alertmanager-ntfy.yaml` and mounted via `url_file`.
  Five rules cover node NotReady, PVC not Bound, Longhorn degraded/faulted and
  CronJob failure; certificate-expiry alerts are deferred (Traefik's ACME
  certificate is a file on its PVC, not a Kubernetes Secret).

### Dynamic DNS caveat

Both CronJobs ran and report `Complete`, **but job status lies here**: the
Park-Your-Domain API returns HTTP 200 with `<ErrCount>` in the body, so a wrong
password still exits 0. State on 2026-11-16:

- after the interim single-key Secret: `devinflake` `<ErrCount>0</ErrCount>` ✅,
  `flakeman2` `<ErrCount>1</ErrCount>` ❌ (one shared key, two different
  provider passwords);
- **after the rotation** (two-key Secret, unique password per domain): both
  jobs return **`<ErrCount>0</ErrCount>` on all three records** ✅.

Check `kubectl logs job/<name>` for `ErrCount`, never the job status. The
rotation history and the two-key design are in
[secrets.md](secrets.md#rotation-decisions-2026-11-14).

## Security / hygiene observations

- **21 of 74 containers now set CPU/memory limits** and **45 of 74 have
  probes** — before the rebuild it was 1 of 64 and 37 of 73. The remaining
  unlimited containers are k3s-bundled add-ons and Longhorn/CSI internals
  (action item #6 is done for everything this repo owns).
- 6 NetworkPolicies exist — all created by Longhorn for its own components.
  Still none for `monitoring`, `traefik`, `longhorn-system`, or egress from the
  DNS CronJobs (action item #11).
- Application PDBs: none (6 PDBs are Longhorn's).
- Secrets are plain Kubernetes `Secret` objects — no Sealed Secrets/SOPS yet
  (the GitOps plan adds Sealed Secrets at bootstrap).
- The k3s join token rotated with the rebuild (fresh cluster). The
  Park-Your-Domain password is still the exposed one and **must be rotated**;
  `authsecret` and `grafana` were rotated before the wipe.
- `config.yml` in the working tree still holds legacy plaintext passwords; it
  is gitignored and must never be committed.

---

## Pre-reimage snapshot (2026-11-14) — archived

The following describes the cluster **before** it was wiped. It is kept as the
"where we were" record; everything in it is historical.

**Captured:** 2026-11-14 via `~/.kube/config-dramble-k3s` and SSH to each node.
**Scope:** read-only inspection, then removal of `rpi-argon` and
`rpi-retropie`, then the blog roll to image `1.0.5`.

### Headline (historical)

- The cluster served traffic on a **frozen, end-of-life 2021 release**.
- `rpi-argon` and `rpi-retropie` were **removed** after being unreachable; all
  Longhorn volumes stayed healthy throughout.
- `kube2` ran a **broken, looping `k3s.service`** restarted ~1.58M times
  because it pointed at the abandoned kube-vip VIP `192.168.0.200`.
- Both dynamic-DNS CronJobs carried the **password inline in the command**.
- The repository previously described a design the cluster never adopted
  (kube-vip, cert-manager, ghost-blog, Prometheus Operator); it has since been
  replaced by this documentation.

### Versions (historical)

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

### Nodes (historical)

| Node | IP | Role | Status | Notes |
|---|---|---|---|---|
| `kube1` | 192.168.0.61 | control-plane,master | Ready | 31w uptime, 52.5 °C |
| `kube2` | 192.168.0.62 | node | Ready | stray `k3s.service` looping |
| `kube3` | 192.168.0.63 | node | Ready | 52.5 °C |
| `kube4` | 192.168.0.64 | node | Ready | 54.5 °C |

`rpi-argon` (192.168.0.37) and `rpi-retropie` (192.168.0.7) were deleted from
the cluster on 2026-11-14; eight stale pods had to be force-deleted
(`--force --grace-period=0`) because Kubernetes 1.22 did not garbage collect
them. All 15 replicas and five volumes stayed healthy before, during and after.

The stray kube2 unit (gone with the reimage):

```
k3s.service: activating (auto-restart), restart counter at 1580789
ExecStart=/usr/local/bin/k3s server --server https://192.168.0.200:6443
fatal: failed to get CA certs: no route to host
```

### Workloads (historical)

64 pods, 12 namespaces, 18 Deployments, 5 DaemonSets, 2 CronJobs, 23 Services,
11 IngressRoutes, 6 Middlewares, 1 TLSOption, 8 Longhorn PDBs — on k3s
`v1.22.5`, Longhorn `1.2.3`, MetalLB `0.11.0`, Traefik `2.5.6`, Prometheus
`2.31.1`, Grafana `8.3.5`, CoreDNS `1.8.4`, metrics-server `0.5.0`.

### Storage (historical)

Five PVCs `Bound`, five volumes `attached`/`healthy`, 15 replicas (5 on kube1,
3 on kube2, 3 on kube3, 4 on kube4). The alertmanager PVC was named
`monitoring/prometheus-alertmanager`.

### Networking (historical)

- MetalLB pool `192.168.0.201–192.168.0.250`, L2; Traefik Service at `.201`.
- 11 IngressRoutes (including two `pi-hole` routes that never worked — the
  backend `192.168.0.46` was unreachable).
- ACME store held **6 certificates**, expiring 2027-01, including one for
  `pi-hole.devinflake.com`.

### Monitoring (historical)

23 targets, 0 down after the node removal (30 targets / 7 down before it).
Grafana had 0 dashboards; its datasource was added through the UI (now
codified in values, and dashboards are provisioned from git as of 2026-11-21).

### Security / hygiene (historical)

- **63 of 64 containers had no limits; 37 of 73 had no probes.**
- No NetworkPolicies, no application PDBs, no secrets management.
- k3s join token and Park-Your-Domain password were exposed during the
  investigation; the token has since rotated with the rebuild, the DDNS
  password has not.
- API server certificate valid until 2027-03-05 (old cluster).

### Recommended priorities (historical, as written on 2026-11-14)

1. Rotate the k3s join token and dynamic-DNS password. *(token: done by
   rebuild; DDNS: still open)*
2. Disable the stray `k3s.service` on kube2. *(moot — node reimaged)*
3. Plan the k3s/component upgrade (1.22 is EOL). *(done — rebuild completed
   2026-11-16)*
4. Add resource requests/limits and probes; import Grafana dashboards.
   *(limits/probes done for repo-owned containers; dashboards provisioned from
   git 2026-11-21)*
