# First-party PodDisruptionBudgets

Nine PDBs owned by this repository, reconciled by the
[`poddisruptionbudgets` Application](../../gitops/policies/poddisruptionbudgets/application.yaml).
Longhorn's six PDBs and the chart-owned components are not touched.

A PDB limits **voluntary** disruption: `kubectl drain`, a node reimage, or a
controller-initiated eviction. It does **not** protect against a crash, a dead
node, or an API outage — nothing here changes the single-control-plane risk in
[action item 12](../../docs/action-items.md#12-reduce-single-points-of-failure).
It only makes maintenance drains orderly.

| Workload | Replicas | PDB |
|---|---|---|
| `jekyll/jekyll-website` | 3 | `minAvailable: 2` |
| `blog-cms/blog-cms-api` | 2 | `minAvailable: 1` |
| `whoami/whoami` | 2 | `minAvailable: 1` |
| `mysite-nginx/mysite-nginx` | 1 | `maxUnavailable: 1` |
| `monitoring/grafana` | 1 | `maxUnavailable: 1` |
| `monitoring/prometheus-server` | 1 | `maxUnavailable: 1` |
| `monitoring/prometheus-kube-state-metrics` | 1 | `maxUnavailable: 1` |
| `monitoring/prometheus-prometheus-pushgateway` | 1 | `maxUnavailable: 1` |
| `monitoring/prometheus-alertmanager` (StatefulSet) | 1 | `maxUnavailable: 1` |

The single-replica entries use `maxUnavailable: 1` on purpose. `minAvailable: 1`
on one replica would block every drain forever: the eviction API refuses to
remove the only pod. `maxUnavailable: 1` admits the disruption and accepts the
brief outage, which is the accurate description of a single-replica service.

DaemonSets (node-exporter and friends) are not listed — PDBs are not a useful
control for them. Neither are the DynDNS CronJobs, which have no long-lived pod
to evict.

To verify after a change:

```bash
kubectl get pdb -A
kubectl describe pdb -n jekyll jekyll-website   # ALLOWED DISRUPTIONS should be 1
```

When a replica count changes, update `pdbs.yaml` in the same PR — a stale
`minAvailable` on a scaled-down workload is another way to wedge a drain.
