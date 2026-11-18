# Scripts

| Script | Run on | Purpose |
|---|---|---|
| `install-server.sh` | `kube1` | Install pinned k3s server with servicelb/local-storage/traefik disabled |
| `install-agent.sh` | `kube2`–`kube4` | Install pinned k3s agent and disable any stray server unit |
| `install-addons.sh` | workstation | MetalLB, Longhorn, Traefik, Prometheus, Grafana, CRs, workloads, DNS |
| `verify-docs.sh` | workstation (needs `KUBECONFIG`) | Assert documented numbers against the **live** cluster — 18 checks. Not CI: it needs cluster credentials |
| `check-updates.sh` | anywhere with `gh` + network | Compare every version pin against upstream and report what is newer. Not a merge gate: it needs the network, so a flaky upstream must not block a PR |

Exit codes for `check-updates.sh`: `0` current, `1` updates available,
`2` a check could not run — deliberately distinct, so *"we could not tell"*
never reads as *"nothing to do"*.

All scripts honour `K3S_VERSION` (default `v1.36.6+k3s1`). See
[../docs/redeploy.md](../docs/redeploy.md) for the full sequence and
prerequisites.

```bash
chmod +x scripts/*.sh
```
