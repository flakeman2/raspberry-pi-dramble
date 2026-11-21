# Grafana dashboards

Four dashboards, authored in this repository rather than imported from a URL:

| File | Dashboard | Data source |
|---|---|---|
| `dramble-cluster.json` | Cluster | kube-state-metrics + cAdvisor |
| `dramble-nodes.json` | Nodes | node-exporter |
| `dramble-traefik.json` | Traefik | Traefik `/metrics` |
| `dramble-longhorn.json` | Longhorn | `longhorn-metrics` scrape job |

All panels use the provisioned Prometheus datasource with UID `prometheus`,
declared in `../grafana-values.yaml`. No Grafana content lives only in the
ReadWriteOnce PVC: edit the JSON here and the sidecar re-provisions it.

`kustomization.yaml` converts each JSON file into a ConfigMap labelled
`grafana_dashboard: "1"` in `monitoring`. The chart's dashboard sidecar watches
that label and writes the dashboards into Grafana. Name hashes are disabled so
Argo's diffs stay readable.

```bash
# Render exactly what Argo CD applies:
kubectl kustomize cluster/monitoring/dashboards
```

Every PromQL expression in the cluster, nodes and Traefik dashboards was
checked against live Prometheus before it was committed. The Longhorn
expressions use the metric names and label semantics from Longhorn 1.13's
[metrics reference](https://longhorn.io/docs/1.13.0/monitoring/metrics/):
`longhorn_volume_robustness` carries a `state` label with value `1` only for the
current state, and `longhorn_volume_actual_size_bytes` is reported **per
replica**, so volume counts are deduplicated with `count by(...)` and used
space is averaged across replicas before comparing to capacity. These queries
can only be confirmed live once the `longhorn-metrics` job has collected data.
