# Raspberry Pi Dramble

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
| Distribution | k3s `v1.36.6+k3s1` (single control plane on `dflake-nettop`, embedded SQLite/kine) |
| Nodes | 4 × Raspberry Pi 4 Model B (agents) + 1 × x86_64 `dflake-nettop` (tainted server) |
| Storage | Longhorn `1.13.0`, `longhorn` default StorageClass, 3 replicas |
| Load balancer | MetalLB `0.16.2`, L2 pool `192.168.0.201–192.168.0.250` |
| Ingress | Traefik `3.7.19` (chart `42.4.1`) at `192.168.0.201` — unchanged by the control-plane move |
| TLS | Traefik built-in ACME (TLS-ALPN), Let's Encrypt production |
| Monitoring | Prometheus `3.16.0` (chart `29.47.2`), Grafana `13.3.1` (chart `14.5.0`), Alertmanager, kube-state-metrics, node-exporter |
| GitOps | Argo CD `v3.6.1` (chart `10.18.0`), root app-of-apps + 16 children tracking `dev` |
| Metrics | metrics-server and CoreDNS, both bundled with k3s |
| DNS | Park-Your-Domain dynamic DNS via two CronJobs |

> **Live since 2026-11-16 — these are the versions the cluster runs, not just
> what the repository pins.** The rebuild landed every one of them; the
> snapshot, the phase-by-phase rebuild history, and the defects it surfaced are
> in [docs/cluster-status.md](docs/cluster-status.md), and the plan they came
> from is [docs/upgrade.md](docs/upgrade.md).

> **Status:** five nodes `Ready` on k3s `v1.36.6+k3s1` (Ubuntu 26.04.1),
> all five volumes `healthy` with 15 replicas, **all fourteen public hostnames
> serving valid Let's Encrypt certificates** (7 certificates), Prometheus **29
> targets / 0 down**. The frozen 2021 stack was retired by a full rebuild on
> 2026-11-15/16 — before-and-after is recorded in
> [docs/cluster-status.md](docs/cluster-status.md).
>
> **Current work:** all rebuild action items are complete. Argo CD reconciles the
> cluster from `dev` (root + 16 children), with sealed secrets, Grafana
> dashboards, NetworkPolicies and PDBs in place. The blog post editor API is
> added through the same GitOps path. See
> [docs/gitops.md](docs/gitops.md) and
> [docs/action-items.md](docs/action-items.md).

## The full story

For a single end-to-end narrative of the rebuild — the reasons for retiring the
2021 stack, the five defects it surfaced, the control-plane migration, GitOps,
hardening, backups and the accepted risks — see
[docs/rebuild-writeup.md](docs/rebuild-writeup.md). The individual blog posts and
runbooks remain the detailed record.

The browser-based blog post editor design and rollout are documented in
[docs/blog-cms.md](docs/blog-cms.md); the one-time GitHub App and credential
setup is in [docs/blog-cms-app-setup.md](docs/blog-cms-app-setup.md).

## Repository layout

```
cluster/                     Manifests for everything the cluster runs
  namespaces.yaml            All application namespaces
  metallb/                   MetalLB install manifest + address pool
  longhorn/                  Vendored Longhorn manifest + install notes
  traefik/                   Helm values + IngressRoutes/Middlewares/TLSOption
  monitoring/                Prometheus + Grafana Helm values
  dns/                       Dynamic DNS CronJobs
  workloads/                 mysite, jekyll, whoami, blog-cms-api
  dashboards/                IngressRoutes for Grafana/Longhorn UIs
  secrets/                   Secret requirements + example manifests (no values)
scripts/                     Install scripts for k3s and the add-ons
docs/                        Architecture, hardware, status, redeploy, secrets,
                             upgrade plan, GitOps plan, blog rebuild, rebuild write-up
gitops/                      Argo CD root app-of-apps + 16 children tracking dev
services/                    First-party service source (blog post editor API)
```

## Rebuild from bare Pis

The complete procedure is in [docs/redeploy.md](docs/redeploy.md). Short form:

```bash
# On dflake-nettop, after OS preparation (tainted, TLS SANs for its own IP):
sudo ./scripts/install-server.sh

# On kube1–kube4:
sudo K3S_URL=https://192.168.0.44:6443 K3S_TOKEN=... ./scripts/install-agent.sh

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

`dev` is the only branch, and the repository default. Argo CD tracks it, so a
merged pull request *is* the deployment target — there is no promotion step.

```bash
git switch dev && git pull
git switch -c fix/short-description      # short-lived topic branch
# edit, commit
git push -u origin fix/short-description
gh pr create --base dev --fill
```

Merge the topic branch into `dev` once it looks right. CI runs four jobs on the
PR — manifests, secrets, docs, workflows — and a green check is the review
record. PR-Agent additionally posts an AI `/describe` and `/review` on every
opened PR, on Google's free Gemini tier; that is advisory second opinion, not a
gate, and a failed review never blocks a merge (see
[docs/gitops.md](docs/gitops.md#pr-agent--advisory-not-a-gate)).

Repository settings back this up: `dev` rejects force-pushes and deletion. Head
branches are deleted automatically when a pull request merges
(`delete_branch_on_merge`, enabled 2026-11-14), so topic branches do not
accumulate. A single maintainer cannot approve their own PR, so no approving
review is required — enable "required approvals" in the branch protection
settings if another maintainer joins.

A `master` branch existed until 2026-11-17 as the "deployed state" mirror that
promotion PRs targeted. Its tree was byte-identical to `dev` — only the
promotion merge commits differed — so deleting it lost no content, and it also
removed the second merge a blog post needed before going live.

## License

MIT — see [LICENSE](LICENSE).
