# Control-plane migration: kube1 → dflake-nettop

**Status: EXECUTED 2026-11-21 — all steps verified.** This is the operator
runbook that was followed; the commands are kept verbatim for the next move or
a rollback. Do not skip the verification steps.

## Why

k3s's datastore is **kine (SQLite)**, running in-process on kube1. The failures
we saw on 2026-11-18 (17 restarts, 39 s compaction stalls, `Transaction commit
failed`) all come down to the datastore sitting on an I/O-starved node. Moving
the control plane to dedicated x86_64 hardware with its own fast disk removes
the datastore from that contention instead of tuning around it.

## What moves and what does not

| Moves to nettop | Stays on the Pis |
|---|---|
| SQLite datastore (`state.db` + WAL) — **all** Kubernetes objects, including Longhorn's `Volume`/`Snapshot`/`Backup` CRs | **Volume data** — Longhorn replicas live on Pi disks and are untouched |
| k3s CA + service certs (`server/tls/`) | All workloads — pods keep running and serving while the API is down |
| `node-token` / `token` — so agents rejoin with the **same token** | Traefik, MetalLB, sites; no public-IP or DNS change |

The five Longhorn volumes have **no off-cluster backup**, so the datastore copy
is the only thing standing between those volumes and being orphaned. That is why
the plan makes the backup non-negotiable and keeps an untouched rollback copy.

**Only the API endpoint changes: `192.168.0.61:6443` → `192.168.0.44:6443`.**
`192.168.0.201` does **not** change — that is a MetalLB pool address assigned to
Traefik's `LoadBalancer` Service, announced by the speakers on the Pis, and it
keeps serving your public names throughout. Nothing to re-point in DNS or on the
router.

**Backup taken 2026-11-21** (k3s stopped first, so the WAL is quiesced):

- this workstation: `/tmp/opencode/k3s-server-for-nettop.tar.gz` — **12 MB**
- `kube1:/root/k3s-server-for-nettop.2026-11-21.tar.gz` (rollback)
- `sha256 = b2f718ce5087f0934f40735b4d80e5a66e78145224b2fe807df261ca0b616afc`
- verified after restart: readyz ok, all 4 nodes Ready, 5 Longhorn volumes

## Prerequisites

- nettop's static IP is **reserved in DHCP**: `NETTOP_IP=192.168.0.44`.
- `dflake-nettop` reachable from kube1 on **6443/TCP**, and flannel
  **8472/UDP** + kubelet **10250/TCP** both ways between all nodes.
- The backup archive is already made (see above); move it over with
  `scp /tmp/opencode/k3s-server-for-nettop.tar.gz <user>@192.168.0.44:/tmp/`.
- **Same k3s version everywhere**: `v1.36.6+k3s1` (kube1 current).
- Downtime budget: the API is down while the DB is copied (~5 min at 25 MB).
  Pods and sites keep serving.

---

## Step 0 — Preflight on **dflake-nettop**

```bash
uname -m                                # must say x86_64
nproc && free -h && df -h /             # sane RAM/disk headroom
hostname                                # confirm it is dflake-nettop
sudo apt-get update && sudo apt-get install -y curl ca-certificates jq
```

Set the two variables you will reuse below:

```bash
NETTOP_IP=192.168.0.44       # <-- set to your reserved IP
K3S_VER=v1.36.6+k3s1
```

## Step 1 — Backup on **kube1** (I can run this for you)

Stop the server so SQLite's WAL is quiesced, then archive the entire server
state (db, CA, certs, token). Keep the original untouched.

```bash
sudo systemctl stop k3s
sudo tar -C /var/lib/rancher/k3s -czf /tmp/k3s-server-for-nettop.tar.gz server
sudo cp -a /tmp/k3s-server-for-nettop.tar.gz /root/k3s-server-for-nettop.$(date +%F).tar.gz
ls -lh /tmp/k3s-server-for-nettop.tar.gz       # expect ~25-40 MB
# a second rollback copy off kube1
scp /tmp/k3s-server-for-nettop.tar.gz dflake@<some-other-host>:/tmp/
```

Copy it to nettop:

```bash
scp /tmp/k3s-server-for-nettop.tar.gz <user>@192.168.0.44:/tmp/
```

> **Rollback note:** if anything below fails, stop k3s on nettop and restart it
> on kube1 — the untouched `server/` directory there picks up where it left off.

## Step 2 — Install k3s on **dflake-nettop** (server, tainted, not started)

The taint matters twice: it keeps the control plane free of workload load (the
whole point of the move), and the ARM64 workload images would not run on
x86_64 anyway.

```bash
export NETTOP_IP=192.168.0.44          # same value as Step 0
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION=v1.36.6+k3s1 \
  INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_SKIP_ENABLE=true \
  INSTALL_K3S_EXEC="server \
    --disable servicelb \
    --disable local-storage \
    --disable traefik \
    --tls-san ${NETTOP_IP} \
    --tls-san dflake-nettop \
    --node-taint node-role.kubernetes.io/control-plane=true:NoSchedule" \
  sh -
```

Notes:
- `--disable servicelb/local-storage/traefik` mirrors kube1's current flags
  (`ExecStart` on kube1, `scripts/install-server.sh`).
- `SKIP_START/SKIP_ENABLE` are what let you restore the datastore **before**
  first boot. Without them k3s initializes an empty cluster and the restore
  would clash with it.

## Step 3 — Restore the datastore on **dflake-nettop**

```bash
test -f /tmp/k3s-server-for-nettop.tar.gz && echo archive-present
# safety: refuse to clobber an already-running cluster
[ -f /etc/rancher/k3s/k3s.yaml ] && echo "WARNING: k3s.yaml exists — stop, check first"
sudo rm -rf /var/lib/rancher/k3s/server          # fresh node only, nothing here yet
sudo mkdir -p /var/lib/rancher/k3s
sudo tar -xzf /tmp/k3s-server-for-nettop.tar.gz -C /var/lib/rancher/k3s/
sudo ls -lh /var/lib/rancher/k3s/server/db/state.db

# Force the apiserver cert to be reissued for the NEW ip/hostname.
# The restored certs carry kube1's SANs; the CA itself is preserved.
sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt \
           /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key \
           /var/lib/rancher/k3s/server/tls/dynamic-cert.json
```

## Step 4 — First start on **dflake-nettop**

```bash
sudo systemctl enable --now k3s
sleep 45
sudo k3s kubectl get --raw /readyz        # expect: ok
sudo k3s kubectl get nodes -o wide        # expect dflake-nettop Ready
```

Then verify the datastore actually carried everything over:

```bash
sudo k3s kubectl get volumes.longhorn.io -A        # expect 5 volumes
sudo k3s kubectl get nodes                         # Pis will show NotReady until Step 5
sudo k3s kubectl -n longhorn-system get pods | head
```

If `NetReady` appears but the apiserver cert errors mention old SANs, the
deletion in Step 3 was skipped — redo it and `systemctl restart k3s`.

## Step 5 — Repoint the agents at **dflake-nettop**

On **kube2, kube3, kube4** (one at a time, verify each):

```bash
sudo sed -i "s|K3S_URL=.*|K3S_URL='https://${NETTOP_IP}:6443'|" \
    /etc/systemd/system/k3s-agent.service.env
sudo systemctl daemon-reload
sudo systemctl restart k3s-agent
```

On **kube1** — retire the server role, then rejoin as an agent:

```bash
sudo systemctl disable --now k3s
sudo mv /var/lib/rancher/k3s/server /var/lib/rancher/k3s/server.retired-$(date +%F)
# uses the repo's agent script; token unchanged (it was restored on nettop)
sudo K3S_URL=https://${NETTOP_IP}:6443 \
     K3S_TOKEN="$(sudo cat /var/lib/rancher/k3s/server/node-token)" \
     ./scripts/install-agent.sh
```

> Do **not** ever start the old `k3s.service` again without a full restore —
> two servers with forked copies of the same datastore is the one outcome that
> genuinely loses data. `disable` plus the renamed directory is deliberate.

## Step 6 — Point your admin kubeconfig

```bash
# on your laptop
cp ~/.kube/config-dramble-k3s ~/.kube/config-dramble-k3s.bak
sed -i 's|https://192.168.0.61:6443|https://192.168.0.44:6443|' ~/.kube/config-dramble-k3s
export KUBECONFIG=~/.kube/config-dramble-k3s
kubectl get nodes -o wide
kubectl -n longhorn-system get volumes.longhorn.io --no-headers | wc -l   # expect 5
```

## Step 7 — Re-enable Argo automation — DONE 2026-11-21

The hold was removed only after the API had been steady for ~30 minutes, the
Longhorn conflict loop was cleared (rolling restart of `longhorn-manager` and
`longhorn-global-manager`), and the `longhorn` Application had been manually
synced to a clean diff. Both projects were cleared live:

```bash
kubectl -n argocd patch appproject dramble --type=merge -p '{"spec":{"syncWindows":null}}'
kubectl -n argocd patch appproject default --type=merge -p '{"spec":{"syncWindows":null}}'
```

The `dramble` block had been written to `gitops/projects/default.yaml` but never
committed, so no revert PR was needed — the working-tree copy was simply
dropped. Result: **12/12 Applications Synced/Healthy**, zero Longhorn node
409s, nettop at 15–23% CPU instead of 99%.

## Step 8 — Follow-up, not urgent

- **ArgoCD's own placement**: moving the control plane does **not** move Argo off
  kube1. If kube1's load really is Argo-driven, that still needs addressing —
  either scheduling Argo onto kube2/3/4, or shrinking it. Separate change.
- ~~Update `192.168.0.61` references~~ — done across `scripts/` and `docs/`;
  `scripts/verify-docs.sh --skip-certs` passes with the new topology.
- ~~Parameterize `scripts/install-server.sh` for nettop~~ — done: it now takes
  `NETTOP_IP` (default `192.168.0.44`), adds the TLS SANs and the taint.
- After a week of stability: delete
  `/var/lib/rancher/k3s/server.retired-*` on kube1 and the rollback tarballs.
