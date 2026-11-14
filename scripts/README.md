# Scripts

| Script | Run on | Purpose |
|---|---|---|
| `install-server.sh` | `kube1` | Install pinned k3s server with servicelb/local-storage/traefik disabled |
| `install-agent.sh` | `kube2`–`kube4` | Install pinned k3s agent and disable any stray server unit |
| `install-addons.sh` | workstation | MetalLB, Longhorn, Traefik, Prometheus, Grafana, CRs, workloads, DNS |

All scripts honour `K3S_VERSION` (default `v1.22.5+k3s1`). See
[../docs/redeploy.md](../docs/redeploy.md) for the full sequence and
prerequisites.

```bash
chmod +x scripts/*.sh
```
