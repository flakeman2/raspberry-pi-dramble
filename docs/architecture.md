# Architecture

The cluster is a single-control-plane k3s cluster: one x86_64 server
(`dflake-nettop`) plus four Raspberry Pi 4 agents. Kubernetes objects converge
to `dev` through Argo CD; there is no Ansible.

**Verified against the live cluster: 2026-11-16** after the rebuild, **updated
2026-11-21** after the control-plane move (snapshot, rebuild history and the
migration record: [cluster-status.md](cluster-status.md),
[control-plane-migration-nettop.md](control-plane-migration-nettop.md)).

```
                           LAN 192.168.0.0/24
                                    │
                     ┌──────────────┴──────────────┐
                     │  MetalLB L2: 192.168.0.201  │
                     │  Traefik Service (LoadBalancer)
                     └──────────────┬──────────────┘
                                    │  :80 / :443
                          ┌─────────┴─────────┐
                          │      Traefik      │  deployment, 1 replica
                          │ IngressRoutes +   │  ACME certs on Longhorn
                          │ Middlewares       │
                          └─────────┬─────────┘
              ┌───────────┬─────────┼──────────┬────────────┐
              │           │         │          │            │
        mysite-nginx    jekyll    whoami   monitoring   longhorn-system
        (nginx)        (blog)     (/whoami) (grafana)    (Longhorn UI)
```

## Control plane

| | |
|---|---|
| Server | `dflake-nettop` (192.168.0.44, x86_64) only — **tainted** `node-role.kubernetes.io/control-plane=true:NoSchedule` |
| Agents | `kube1`–`kube4` (192.168.0.61–.64, Raspberry Pi 4) |
| Datastore | embedded SQLite/kine at `/var/lib/rancher/k3s/server/db/state.db`, restored from kube1 on 2026-11-21 |
| k3s version | `v1.36.6+k3s1` |
| Server flags | `--disable servicelb --disable local-storage --disable traefik` |

`192.168.0.201` is a MetalLB address announced by the Pis, not the API endpoint;
it did not change in the move. The taint keeps workloads — including Argo CD —
off the machine that owns the datastore.

The three disabled components are replaced by explicit add-ons:

| Disabled k3s component | Replacement |
|---|---|
| `servicelb` (Klipper) | MetalLB 0.16.2 |
| `local-storage` | Longhorn 1.13.0 |
| bundled `traefik` | Traefik Helm chart 42.4.1 |

k3s still manages these add-ons in `kube-system`: `ccm`, `coredns` (k3s-bundled),
`metrics-server` (k3s-bundled), `resource-reader`, `aggregated-metrics-reader`,
`metrics-apiservice`, and the metrics-server RBAC/service objects.

There is **no** kube-vip, no external etcd, no HA control plane, and no
cert-manager. A single-node etcd was evaluated after the move and rejected: it
adds raft and fsync overhead on top of the same API traffic without addressing
the failure mode (see [action-items.md](action-items.md#17-move-the-k3s-control-plane-off-kube1--done-2026-11-21)).
The `192.168.0.200` VIP from an old kube-vip experiment does not exist. kube2
was reimaged during the rebuild and now runs only `k3s-agent.service`; there is
no residual server unit.

## Namespaces

| Namespace | Purpose |
|---|---|
| `kube-system` | k3s add-ons (CoreDNS, metrics-server, CCM) |
| `metallb-system` | MetalLB controller + speakers |
| `longhorn-system` | Longhorn manager, CSI drivers, UI |
| `traefik` | Traefik deployment, Service, dashboard IngressRoute |
| `monitoring` | Prometheus, Alertmanager, Grafana, exporters |
| `mysite-nginx` | Static site (`devinflake.com`, `flakeman2.com`) |
| `jekyll` | Blog (`blog.devinflake.com`) |
| `whoami` | Traefik whoami demo at `/whoami` |
| `argocd` | Argo CD controller, repo-server, API server and Redis |
| `default` | HTTP basic-auth Secret, Traefik middlewares, DynDNS CronJobs |

`kube-node-lease` and `kube-public` are the remaining two k3s system
namespaces; twelve namespaces exist in total.

## Networking

### MetalLB (layer 2)

- Version 0.16.2, from the vendored native manifest; the address pool is an `IPAddressPool` CR, not a ConfigMap.
- Address pool: `192.168.0.201–192.168.0.250`, protocol `layer2`.
- The `speaker` DaemonSet answers ARP for allocated addresses.
- Traefik is the only `LoadBalancer` Service and receives `192.168.0.201`.

### Traefik

- Chart `traefik` 42.4.1, application v3.7.19, one replica.
- Entry points: `web` (8000→80), `websecure` (8443→443), `metrics` (9100),
  `traefik` (9000, internal API).
- Providers: `kubernetesCRD` (with `allowCrossNamespace`) and `kubernetesIngress`.
  No `Ingress` objects exist; everything is `IngressRoute`.
- TLS: built-in ACME with the **TLS-ALPN-01** challenge and the Let's Encrypt
  production directory. Certificates are stored in `/data/acme.json` on a
  128 MiB Longhorn PVC.
- Default `TLSOption` (`default` namespace) enforces TLS 1.2 minimum.
- Dashboards are protected by the `basic-auth` Middleware, which reads the
  `default/authsecret` Secret (`users` key, htpasswd format).
- Access logging is enabled; request headers are dropped from the logs.
- Prometheus metrics are exposed on the `metrics` entry point, but the Service
  does not publish port 9100. The `kubernetes-pods` scrape job still reaches
  Traefik pod IPs directly.

### Domains and routes

| Host | Backend | TLS | Protection |
|---|---|---|---|
| `devinflake.com`, `www.devinflake.com`, `flakeman2.com`, `www.flakeman2.com` | `mysite-nginx/mysite-nginx-service:80` | ACME | HTTP→HTTPS redirect |
| same hosts + `PathPrefix(/whoami)` | `whoami/whoami:80` | ACME | redirect |
| `blog.devinflake.com` | `jekyll/jekyll-website:80` | ACME | redirect |
| `grafana.devinflake.com`, `grafana.flakeman2.com` | `monitoring/grafana:80` | ACME | none |
| `prometheus.devinflake.com`, `prometheus.flakeman2.com` | `monitoring/prometheus-server:80` | ACME | basic-auth + redirect |
| `traefik.devinflake.com`, `traefik.flakeman2.com` | `api@internal` | ACME | basic-auth + redirect |
| `longhorn.devinflake.com`, `longhorn.flakeman2.com` | `longhorn-system/longhorn-frontend:80` | ACME | basic-auth + redirect |
| `argocd.devinflake.com` | `argocd/argocd-server:80` | ACME | redirect; login is Argo CD's own |

Traefik's chart also creates `traefik/traefik-dashboard` on `PathPrefix(/dashboard)`
and `PathPrefix(/api)`. It is not exposed through the LoadBalancer by hostname.

### Dynamic DNS

Two CronJobs in `default` run every 30 minutes and update Park-Your-Domain
records for `devinflake.com` and `flakeman2.com` (hosts `@`, `www`, `*`). Both
live jobs read `dyn-dns-credentials` via `secretKeyRef` — one key per domain —
so no password appears in the command line.

## Storage

Longhorn 1.13.0 provides the `longhorn` default StorageClass with 3 replicas.

| PVC | Namespace | Size | Mode | Consumer |
|---|---|---|---|---|
| `traefik` | traefik | 128 MiB | RWO | ACME store |
| `mysite-content` | mysite-nginx | 1 GiB | RWX | nginx document root |
| `storage-prometheus-alertmanager-0` | monitoring | 2 GiB | RWO | Alertmanager |
| `prometheus-server` | monitoring | 8 GiB | RWO | Prometheus TSDB |
| `grafana` | monitoring | 10 GiB | RWO | Grafana database |

Each volume has three healthy replicas spread over the four Pi nodes (the
tainted server holds none). RWX
(`mysite-content`) is served by Longhorn's share-manager over NFS from inside
the cluster — and the *node* still needs an NFS client to mount it, which is
what `nfs-common` provides. Every node runs `open-iscsi`/`iscsid` (explicitly
enabled) and `nfs-common`.

## Monitoring

The `prometheus-community/prometheus` chart 29.47.2 is installed with the
committed values in `cluster/monitoring/prometheus-values.yaml` (resource
budgets, two custom scrape jobs, alert rules and a receiver). It creates:

- Prometheus server 3.16.0 (explicit 15-day retention, 8 GiB Longhorn PVC)
- Alertmanager 0.35.0 (2 GiB PVC)
- kube-state-metrics
- node-exporter (DaemonSet)
- pushgateway
- configmap-reload sidecar

Alert rules fire on node NotReady, PVC not Bound, Longhorn degraded/faulted
volumes and CronJob failure. Every alert routes to an ntfy.sh webhook whose URL
is a SealedSecret (`cluster/secrets/sealed/alertmanager-ntfy.yaml`) mounted as a
file: Alertmanager cannot expand `${ENV}` in its config, so the receiver uses
`url_file`. Certificate-expiry alerts are deferred because Traefik's ACME
certificate is a file on its PVC rather than a Kubernetes Secret.

Grafana chart 14.5.0 runs Grafana 13.3.1 with a 10 GiB Longhorn PVC, a ClusterIP
Service on port 80, and one Prometheus datasource (`http://prometheus-server`,
UID `prometheus`). It is exposed at `grafana.devinflake.com` by an `IngressRoute`
in `monitoring`. Four dashboards (cluster, nodes, Traefik, Longhorn) are
provisioned from git through labelled ConfigMaps
(`cluster/monitoring/dashboards/`), not imported into the UI.

## Workloads

| Workload | Namespace | Image | Replicas | Service |
|---|---|---|---|---|
| `mysite-nginx` | mysite-nginx | `nginx:1.31.8` | 1 | ClusterIP 80/443 |
| `jekyll-website` | jekyll | `flakeman2/jekyll:sha-5396fad` | 3 | ClusterIP 80 |
| `whoami` | whoami | `traefik/whoami:v1.12.0` | 2 | ClusterIP 80 |

`mysite-nginx` mounts the `mysite-content` RWX PVC at `/usr/share/nginx/html`
and a `nginx-conf` ConfigMap at `/etc/nginx/conf.d/default.conf`. A copy of the
current document root is checked in at `cluster/workloads/mysite/content/`.

## What is intentionally absent

- kube-vip and the `192.168.0.200` VIP
- cert-manager and the `letsencrypt-*` ClusterIssuers
- the `ghost-blog` namespace/workload and the `kubernetes-dashboard` RBAC
- Prometheus Operator CRDs (`Prometheus`, `ServiceMonitor`)
- Ansible, kubeadm, and the upstream `setup/`/`testing/` trees
