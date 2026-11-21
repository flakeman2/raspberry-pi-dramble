# Upgrade plan

**Status (2026-11-16): DONE — the rebuild path was executed and A4 met.**

| Phase | When | Result |
|---|---|---|
| **A0** preserve + gate | 2026-11-14 | mysite tarball byte-identical to git, `acme.json`, rotated `authsecret`/`grafana` off-repo at `0600`, host state, tools — gate passed **before** the wipe, which mattered because there was no rollback |
| **A1** retarget the repo | 2026-11-14 | PRs #8/#9/#12; `pluto` (no APIs removed by 1.36) and `kubeconform` clean |
| **A2** reimage + rebuild | 2026-11-15 | all four disks wiped → Ubuntu Server 26.04.1 LTS, then k3s `v1.36.6+k3s1`, MetalLB `0.16.2`, Longhorn `1.13.0`, Traefik `42.4.0`, Prometheus `29.47.2`, Grafana `14.4.1` |
| **A3** restore + verify | 2026-11-16 | content restored byte-identical; certificates re-issued for all 11 hostnames then in service once the router returned to `.201` (14 today) |
| **A4** exit criteria | 2026-11-16 | all six criteria met — see [cluster-status.md](cluster-status.md) for the post-rebuild snapshot **and the rebuild history**, including the five defects the rebuild surfaced |

Version data was checked on 2026-11-14; the pins above are what the rebuild
installed, and Traefik (`42.4.1`) and Grafana (`14.5.0`) were bumped again on
2026-11-18 — [cluster-status.md](cluster-status.md) is the current inventory.
Still open after the rebuild: the Park-Your-Domain rotation
([secrets.md](secrets.md#rotation-decisions-2026-11-14)), host tuning
([action-items.md](action-items.md) item 16), and Argo CD
([gitops.md](gitops.md)).

This page covers every component, the order, the gates between steps, and the
choice between upgrading in place and rebuilding. Argo CD adoption is sequenced
after this work; see [gitops.md](gitops.md).

## Target versions

| Component | Live | Target | Constraint |
|---|---|---|---|
| k3s / Kubernetes | `v1.22.5+k3s1` | `v1.36.6+k3s1` | Newest minor tested by both Longhorn 1.13 (`1.33–1.36`) and Argo CD 3.6 (`1.34–1.37`); `1.36.6` was current on 2026-11-14 |
| Longhorn | `1.2.3` | `1.13.0` | Tested on k8s 1.33–1.36 |
| MetalLB | `0.11.0` | `0.16.2` (vendored native manifest) | CRD-based configuration since 0.13; no Helm chart needed |
| Traefik | `2.5.6`, chart `10.9.1` | `3.7.19`, chart `42.4.1` | Chart requires k8s ≥ 1.30; its values schema rejects unknown keys |
| Prometheus | `2.31.1`, chart `15.1.3` | `3.16.0`, chart `29.47.2` | Chart requires a current k8s minor |
| Grafana | `8.3.5`, chart `6.21.4` | `13.3.1`, chart `14.5.0` | Chart moved to the `grafana-community` Helm repo after 2026-01-30; `grafana.github.io` serves a frozen, deprecated 10.5.x line |
| metrics-server | `0.5.0` | k3s-bundled | Nothing to install; confirm `kubectl top` afterwards |
| CoreDNS | `1.8.4` | k3s bundled | Do not manage separately |
| Argo CD | — | `3.6.x` | Install after k8s reaches ≥ 1.34 |

These are the exact versions pinned in `scripts/install-server.sh` and
`scripts/install-addons.sh`; bump them together, re-running `pluto` and
`kubeconform` and re-rendering the charts, so the next rebuild stays
reproducible.

## Decision: in place or rebuild

**In place** means 14 Kubernetes minor hops (1.22 → 1.36), and Longhorn documents
one-minor-at-a-time upgrades, so 11 more hops (1.2 → 1.13) — roughly 25 upgrade
events, each with a drain, a replica rebuild, and a verification gate.

**Rebuild** means fresh installs on the target versions and restoring the small
amount of state that matters. The cluster's persistent state is mostly
disposable:

| Volume | Size | Contents | Keep? |
|---|---|---|---|
| `mysite-nginx/mysite-content` | 1 GiB | Website content | **Yes — back up** |
| `traefik/traefik` | 128 MiB | `acme.json` | Optional — re-issuing is safe |
| `monitoring/grafana` | 10 GiB | Grafana DB | No — dashboards now provisioned from git (item 7) |
| `monitoring/prometheus-server` | 8 GiB | 15 days of metrics | No |
| `monitoring/prometheus-alertmanager` | 2 GiB | Silences | No |

**Recommendation: rebuild.** The only irreplaceable data is one gigabyte of
website content, the stack has no backup target (so in-place Longhorn has no
rollback path anyway), and a rebuild exercises
[redeploy.md](redeploy.md) end to end. In-place only wins if you need to keep the
Prometheus history and the current control-plane state. Roughly: one day of work
for the rebuild versus several supervised sessions plus replica rebuilds for the
in-place path.

The rest of this page gives both paths. Use the same verification gates either
way; the rebuild is Path A because it is the recommendation.

## Path A — rebuild (recommended)

### A0. Preserve what exists

```bash
export KUBECONFIG=~/.kube/config-dramble-k3s
umask 077

# Website content — the only irreplaceable data. It is already byte-identical
# to cluster/workloads/mysite/content/, but keep a tarball anyway.
kubectl -n mysite-nginx exec deploy/mysite-nginx -- \
  tar czf - -C /usr/share/nginx/html . > "mysite-content-$(date +%F).tgz"
ls -lh mysite-content-*.tgz
diff <(kubectl -n mysite-nginx exec deploy/mysite-nginx -- ls -1 /usr/share/nginx/html | sort) \
     <(ls -1 cluster/workloads/mysite/content | sort)

# ACME state (optional; re-issuing 6 certificates is within Let's Encrypt limits)
kubectl -n traefik exec deploy/traefik -- cat /data/acme.json > acme.json
```

**Secrets — rotated, not restored.** `authsecret` and `grafana` were
regenerated on 2026-11-14; the new values exist only in the off-repo export
directory (`0600`), alongside `acme.json`. The Park-Your-Domain password still
has to be rotated at the provider — it was read during the investigation and
lives inline in the two live CronJobs. The k3s join token and the kubeconfig
regenerate themselves during the rebuild.

**Gate: there is no rollback.** All four disks are wiped, so the moment A2
starts the old cluster is gone for good. Do not start it until every one of
these is true:

- the `mysite-content` tarball exists, is over 0 bytes, and its file list
  matches `cluster/workloads/mysite/content/`
- the rotated `authsecret` and `grafana` values are recorded somewhere you can
  read them afterwards — they exist nowhere else
- the DDNS rotation is sequenced: rotate at Park-Your-Domain **immediately
  after the reimage**, before `dyn-dns-credentials` is created — with **one
  password per domain** (Namecheap enforces unique passwords, so the Secret
  carries two keys) — see
  [secrets.md](secrets.md#rotation-decisions-2026-11-14)
- `acme.json` is saved, or you have accepted re-issuing all six certificates
- host state is written down in [hardware.md](hardware.md): node addresses,
  `/etc/hosts`, and the router's reserved `192.168.0.201–.250` range
- `kubectl`, `helm`, `kubeconform` and `pluto` are installed on this workstation

Nothing in that list goes into the repository.

### A1. Prepare the target state in git — **done, 2026-11-14**

All five items landed on `dev` and were validated with
`pluto detect-files -d cluster/ --target-versions k8s=v1.36.0` (no deprecated
APIs) and `kubeconform` (0 invalid, 0 errors, on both the manifests and the
`helm template` output for all three charts):

1. `K3S_VERSION` → `v1.36.6+k3s1` in `scripts/install-server.sh` and
   `scripts/install-agent.sh`.
2. `cluster/metallb/metallb-v0.11.0.yaml` replaced by `metallb-v0.16.2.yaml`;
   `cluster/metallb/config.yaml` converted from the `ConfigMap` to
   `IPAddressPool` + `L2Advertisement` (see below).
3. `cluster/traefik/values.yaml` rewritten for chart `42.4.0` — the chart's
   `values.schema.json` sets `additionalProperties: false`, so `logs:` became
   `log:`/`accessLog:` and `service.type` became `service.spec.type` — and the
   CRs changed from `traefik.containo.us/v1alpha1` to `traefik.io/v1alpha1`.
4. Grafana values updated for chart `14.4.1` (app `13.3.1`) from the
   `grafana-community` repo, and the Prometheus chart to `29.47.2`. There is no
   metrics-server manifest: k3s bundles it.
5. `pluto` and `kubeconform` run over `cluster/` and over the rendered Helm
   output.

### A2. Rebuild the nodes — done, 2026-11-15

Follow [redeploy.md](redeploy.md). The additions specific to this upgrade:

```bash
# on each node, as root, if it is not being reimaged
/usr/local/bin/k3s-uninstall.sh        # server (kube1)
/usr/local/bin/k3s-agent-uninstall.sh  # agents

# always, before the node joins the new cluster
sudo rm -rf /var/lib/longhorn
```

Do not reuse Longhorn disks written by `1.2.3`; a fresh install with a clean
`/var/lib/longhorn` avoids mixing volume formats.

### A3. Restore and verify — done, 2026-11-16

- Create namespaces, Secrets (rotated), Longhorn, MetalLB, Traefik, monitoring.
- Restore the website content once the `mysite-content` PVC is bound and the pod
  is running:

  ```bash
  kubectl -n mysite-nginx exec -i deploy/mysite-nginx -- \
    tar xzf - -C /usr/share/nginx/html < mysite-content-2026-11-14.tgz
  ```

- Prefer letting Traefik re-issue certificates over restoring `acme.json`; keep
  the file as a fallback until HTTPS is confirmed.
- **There is no rollback.** The four disks were wiped in A2, so if the new
  cluster fails you fix forward from the A0 artifacts — there is no old cluster
  to boot back into.

### A4. Exit criteria — met, 2026-11-16

- 4/4 nodes `Ready`; the server reports `v1.36.6+k3s1` and your `kubectl` is
  within one minor of it.
- All five PVCs `Bound`, all Longhorn volumes `healthy`, 3 replicas each.
- `devinflake.com`, `blog.devinflake.com`, `grafana.devinflake.com` return valid
  certificates; `whoami` reachable at `192.168.0.201`.
- Prometheus has targets and no down endpoints; DNS CronJobs complete.
- Docs and manifests updated to the new versions; `docs/cluster-status.md`
  re-snapshotted.

## Path B — in place

Only if the Prometheus history or control-plane state must survive. Every gate
below is mandatory; do not batch hops.

### B0. Safety net

- Configure a Longhorn backup target (NFS or S3) and take one backup of every
  volume. Longhorn cannot be downgraded, so this is the only storage rollback.
- Copy `/var/lib/rancher/k3s/server/db/` and the join token off kube1.
- Take the same artifact backups as A0.
- Schedule maintenance: one minor per session, ~30–60 minutes per hop plus
  replica rebuild time. Do not start a hop without time to finish it.

### B1. Preflight (before every hop)

```bash
kubectl get nodes
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness'
pluto detect-all-in-cluster -o wide     # removed APIs before the next minor
kubectl -n longhorn-system get nodes.longhorn.io -o wide
```

Every volume must be `attached`/`healthy` and every node `Ready` before starting.

### B2. Longhorn and Kubernetes, in lockstep

Longhorn has documented one-minor-at-a-time upgrades since 1.5; apply the same
rule below 1.5. The rule for the whole path: **the next k3s minor must be inside
the tested range of the Longhorn version currently installed.** If it is not,
upgrade Longhorn first.

Verified anchors (not the full path):

| Longhorn | Tested k8s |
|---|---|
| 1.9.2 | 1.31–1.33 |
| 1.10.2 | 1.30–1.33 |
| 1.11.3 | 1.34–1.36 |
| 1.12.x, 1.13.x | 1.33–1.36 |

Check the archived support matrix for 1.2–1.8 before each early hop. Upgrade
Longhorn with the manifest method it was installed with — do not switch to Helm
mid-upgrade. Current versions are vendored in `cluster/longhorn/`; for a new
one, fetch it there, review the `kubectl diff`, and open that diff as the
upgrade PR.

```bash
# historical example: an early 1.3.x hop, when the manifest was fetched live
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.3.x/deploy/longhorn.yaml
kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=15m
kubectl -n longhorn-system get volumes.longhorn.io   # wait for healthy
```

Then the Kubernetes hop, server first:

```bash
# dflake-nettop, during a window: the API is unavailable while the server restarts
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.23.x+k3s1 \
  INSTALL_K3S_EXEC="server --disable servicelb --disable local-storage --disable traefik" \
  sh -

# each agent, one at a time
kubectl drain kube2 --ignore-daemonsets --delete-emptydir-data --timeout=10m
# on kube2:
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.23.x+k3s1 \
  K3S_URL=https://192.168.0.44:6443 K3S_TOKEN=... \
  INSTALL_K3S_EXEC="agent" sh -
kubectl uncordon kube2
kubectl -n longhorn-system get volumes.longhorn.io   # healthy before the next node
```

Expect Longhorn replica rebuilds after each drain; on SD-card/USB storage this is
the slow part. Never drain a second node until replicas are `running` again.

### B3. Component migrations, in this order

**MetalLB — before k8s 1.25.** The vendored 0.11 manifest contains
`policy/v1beta1` PodSecurityPolicy objects, removed in 1.25. Upgrade to 0.13+
while the cluster is still on 1.24 or earlier, convert the ConfigMap to CRDs,
then move to 0.16.2:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: default, namespace: metallb-system }
spec:
  addresses: ["192.168.0.201-192.168.0.250"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: default, namespace: metallb-system }
spec:
  ipAddressPools: ["default"]
```

Pin the Traefik Service to `192.168.0.201` with the
`metallb.universe.tf/loadBalancerIPs` annotation so a reinstall cannot take a
different address. Delete the old `config` ConfigMap after the CRDs are serving.

**Traefik — staged, last.** 2.5.6 → 2.10 (the first 2.x release that serves both
API groups) → 2.11 → 3.7. Rewrite the CRs to `traefik.io/v1alpha1` while on 2.10,
then install chart `42.x` once k8s is ≥ 1.30. Chart 10 and chart 42 share almost
no values schema: render the new values from scratch, update CRDs with
`helm show crds`, and expect a brief ingress outage during the swap.

**Prometheus and Grafana — after k8s is current.** The Grafana database has no
dashboards, so delete the PVC and let a fresh 13.x create a clean database
instead of migrating 8.x SQLite. For Prometheus, upgrading the chart is fine;
wiping the 8 GiB PVC and starting a new 15-day retention window is simpler than
carrying 2.x TSDB blocks forward.

**metrics-server — last.** Redeploy the current release; confirm
`kubectl top nodes` works and keep `--kubelet-insecure-tls` if the kubelet
certificates are still self-signed.

### B4. Exit criteria

Same as A4. Additionally: every Longhorn volume has been healthy after each hop,
and no `pluto` finding remains for APIs removed in the new minor.

## Host prerequisites

Modern Kubernetes expects cgroup v2. Check each node before starting either path:

```bash
stat -fc %T /sys/fs/cgroup        # cgroup2fs is required for a clean upgrade
uname -m                          # aarch64
```

If that prints `tmpfs`, the nodes are on cgroup v1 and need a boot-argument or OS
change. This alone can force a reimage, which is another argument for Path A.

## Post-upgrade

1. Bump the version pins in `scripts/install-server.sh`,
   `scripts/install-agent.sh`, `scripts/install-addons.sh`, and the target table
   above.
2. Update `docs/cluster-status.md`, `docs/hardware.md`, `README.md`, and the
   component READMEs with the new versions.
3. Re-run the verification steps and compare against the current snapshot in
   [cluster-status.md](cluster-status.md).
4. Then start the Argo CD rollout in [gitops.md](gitops.md), phase 1.
