# Raspberry Pi Drumble

A six-node Raspberry Pi 4 Kubernetes cluster running **k3s**, **Longhorn**
storage, **MetalLB** load balancing, and **Traefik** ingress with Let's Encrypt
TLS. This repository documents the cluster as it actually runs and contains the
manifests needed to rebuild it from scratch.

This is a fork of [geerlingguy/raspberry-pi-dramble][upstream]. The upstream
Ansible/kubeadm material has been removed because this cluster never used it;
see [docs/architecture.md](docs/architecture.md) for what is actually deployed.

[upstream]: https://github.com/geerlingguy/raspberry-pi-dramble

## Cluster at a glance

| | |
|---|---|
| Distribution | k3s `v1.22.5+k3s1` (single control plane, embedded SQLite) |
| Nodes | 6 × Raspberry Pi 4 Model B, 4 cores / 4 GB RAM each |
| Storage | Longhorn `1.2.3`, `longhorn` default StorageClass, 3 replicas |
| Load balancer | MetalLB `0.11.0`, L2 pool `192.168.0.201–192.168.0.250` |
| Ingress | Traefik `2.5.6` (chart `10.9.1`) at `192.168.0.201` |
| TLS | Traefik built-in ACME (TLS-ALPN), Let's Encrypt production |
| Monitoring | Prometheus `2.31.1`, Grafana `8.3.5`, Alertmanager, kube-state-metrics, node-exporter |
| Metrics | metrics-server `0.5.0`, CoreDNS `1.8.4` |
| DNS | Park-Your-Domain dynamic DNS via two CronJobs |

> **Status:** the cluster is live on 4 of 6 nodes. `rpi-argon` and
> `rpi-retropie` are powered off/unreachable. The full snapshot, including
> faults and end-of-life warnings, is in
> [docs/cluster-status.md](docs/cluster-status.md).

## Repository layout

```
cluster/                     Manifests for everything the cluster runs
  namespaces.yaml            All application namespaces
  metallb/                   MetalLB install manifest + address pool
  longhorn/                  Longhorn install notes (upstream manifest)
  traefik/                   Helm values + IngressRoutes/Middlewares/TLSOption
  monitoring/                Grafana Helm values (Prometheus uses chart defaults)
  dns/                       Dynamic DNS CronJobs
  workloads/                 mysite, jekyll, whoami, pi-hole
  dashboards/                IngressRoutes for Grafana/Longhorn UIs
  secrets/                   Secret requirements + example manifests (no values)
scripts/                     Install scripts for k3s and the add-ons
docs/                        Architecture, hardware, status, redeploy, secrets
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

## License

MIT — see [LICENSE](LICENSE).
