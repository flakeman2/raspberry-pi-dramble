# Raspberry Pi Drumble

A four-node Raspberry Pi 4 Kubernetes cluster running **k3s**, **Longhorn**
storage, **MetalLB** load balancing, and **Traefik** ingress with Let's Encrypt
TLS. This repository documents the cluster as it actually runs and contains the
manifests needed to rebuild it from scratch.

## History

This repository began as a fork of
[geerlingguy/raspberry-pi-dramble][upstream] — Jeff Geerling's Pi Dramble, a
Raspberry Pi cluster project first committed in February 2015 and originally
built with Ansible and kubeadm.

The fork tracked upstream through November 2021. The cluster documented here,
however, was built independently on k3s and never used the upstream Ansible
roles, kubeadm manifests, kube-vip plan, cert-manager setup, or `ghost-blog`
workload. In November 2026 the repository was rewritten to match reality:

| Date | Commit | Change |
|---|---|---|
| 2026-11-14 | `249f1ed` | Removed the upstream Ansible/kubeadm material; added k3s docs and sanitized manifests for the live cluster |
| 2026-11-14 | `bb76502` | Documented removal of the two unreachable nodes, `rpi-argon` and `rpi-retropie` |
| 2026-11-14 | — | Detached from the GitHub fork network; this is now a standalone repository |

Upstream history is preserved in the commit graph, and
[geerlingguy/raspberry-pi-dramble][upstream] remains the reference for the
original project. This repository does not track or merge from upstream, and
pull requests are no longer opened against it. See
[docs/architecture.md](docs/architecture.md) for what is actually deployed.

[upstream]: https://github.com/geerlingguy/raspberry-pi-dramble

## Cluster at a glance

| | |
|---|---|
| Distribution | k3s `v1.36.6+k3s1` (single control plane, embedded SQLite) |
| Nodes | 4 × Raspberry Pi 4 Model B, 4 cores / 4 GB RAM each |
| Storage | Longhorn `1.13.0`, `longhorn` default StorageClass, 3 replicas |
| Load balancer | MetalLB `0.16.2`, L2 pool `192.168.0.201–192.168.0.250` |
| Ingress | Traefik `3.7.18` (chart `42.4.0`) at `192.168.0.201` |
| TLS | Traefik built-in ACME (TLS-ALPN), Let's Encrypt production |
| Monitoring | Prometheus `3.16.0` (chart `29.47.2`), Grafana `13.3.1` (chart `14.4.1`), Alertmanager, kube-state-metrics, node-exporter |
| Metrics | metrics-server and CoreDNS, both bundled with k3s |
| DNS | Park-Your-Domain dynamic DNS via two CronJobs |

> **Live since 2026-11-16 — these are the versions the cluster runs, not just
> what the repository pins.** The rebuild landed every one of them; the
> snapshot, the phase-by-phase rebuild history, and the defects it surfaced are
> in [docs/cluster-status.md](docs/cluster-status.md), and the plan they came
> from is [docs/upgrade.md](docs/upgrade.md).

> **Status:** all four nodes `Ready` on k3s `v1.36.6+k3s1` (Ubuntu 26.04.1),
> all five volumes `healthy` with 15 replicas, **all fourteen public hostnames
> serving valid Let's Encrypt certificates** (7 certificates), Prometheus **24
> targets / 0 down**. The frozen 2021 stack was retired by a full rebuild on
> 2026-11-15/16 — before-and-after is recorded in
> [docs/cluster-status.md](docs/cluster-status.md).
>
> **Next:** bootstrap Argo CD per [docs/gitops.md](docs/gitops.md), then the
> open items in [docs/action-items.md](docs/action-items.md) — rotate the DDNS
> password, host tuning (item 16), Grafana dashboards, NetworkPolicies.

## Repository layout

```
cluster/                     Manifests for everything the cluster runs
  namespaces.yaml            All application namespaces
  metallb/                   MetalLB install manifest + address pool
  longhorn/                  Longhorn install notes (upstream manifest)
  traefik/                   Helm values + IngressRoutes/Middlewares/TLSOption
  monitoring/                Prometheus + Grafana Helm values
  dns/                       Dynamic DNS CronJobs
  workloads/                 mysite, jekyll, whoami
  dashboards/                IngressRoutes for Grafana/Longhorn UIs
  secrets/                   Secret requirements + example manifests (no values)
scripts/                     Install scripts for k3s and the add-ons
docs/                        Architecture, hardware, status, redeploy, secrets,
                             upgrade plan, GitOps plan, blog rebuild
gitops/                      Argo CD scaffold (not yet applied)
```

## Rebuild from bare Pis

The complete procedure is in [docs/redeploy.md](docs/redeploy.md). Short form:

```bash
# On kube1, after imaging and node preparation:
sudo ./scripts/install-server.sh

# On kube2–kube4:
sudo K3S_URL=https://192.168.0.61:6443 K3S_TOKEN=... ./scripts/install-agent.sh

# From a workstation with kubectl + helm:
export KUBECONFIG=~/.kube/config-dramble-k3s
# create the Secrets first (see cluster/secrets/README.md)
./scripts/install-addons.sh
```

## What is not in this repository

- Secrets, k3s join tokens, kubeconfigs, `acme.json`, htpasswd hashes, Grafana
  and dynamic-DNS passwords. See [docs/secrets.md](docs/secrets.md).
- The deprecated upstream Ansible playbooks, kubeadm manifests, kube-vip plan,
  cert-manager manifests, and the abandoned `ghost-blog` workload.

## Branching and review workflow

`dev` is the integration branch and the repository default. `master` mirrors what
is deployed to the cluster, so changes reach it only through a reviewed pull
request.

```bash
git switch dev && git pull
git switch -c fix/short-description      # short-lived topic branch
# edit, commit
git push -u origin fix/short-description
gh pr create --base dev --fill
```

Merge the topic branch into `dev` once it looks right. When a batch is ready to
be deployed, promote `dev` to `master` with a second pull request:

```bash
gh pr create --base master --head dev --title "Release: <summary>"
```

Repository settings back this up: `master` rejects direct pushes, force-pushes,
and deletion; `dev` rejects force-pushes and deletion. Head branches are
deleted automatically when a pull request merges (`delete_branch_on_merge`,
enabled 2026-11-14), so topic branches do not accumulate — the merged ones that
already had were pruned at the same time, leaving only `dev` and `master`. A
single maintainer cannot approve their own PR, so no approving review is
required — the PR itself is the review record. Enable "required approvals" in
the branch protection settings if another maintainer joins.

## License

MIT — see [LICENSE](LICENSE).
