# Monitoring

Two Helm releases in the `monitoring` namespace:

| Release | Chart | App | Values |
|---|---|---|---|
| `prometheus` | `prometheus-community/prometheus` `29.47.2` | `3.16.0` | `prometheus-values.yaml` |
| `grafana` | `grafana/grafana` `14.5.0` | `13.3.1` | `grafana-values.yaml` |

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# the grafana chart moved here after 2026-01-30; grafana.github.io is frozen
helm repo add grafana https://grafana-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring --version 29.47.2 \
  -f prometheus-values.yaml

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring --version 14.5.0 \
  -f grafana-values.yaml
```

Chart defaults create the server (8 GiB Longhorn PVC), Alertmanager (2 GiB
PVC), kube-state-metrics, node-exporter, and pushgateway;
`prometheus-values.yaml` adds explicit 15-day retention, a resource budget for
the server, alert rules, an ntfy.sh receiver, and an explicit
**`metallb-metrics`** scrape job — MetalLB v0.16 serves metrics over HTTPS with
bearer-token auth, which the chart's annotation-driven job cannot do (see
`../metallb/README.md`). Every workload in this directory now has
requests/limits, and Grafana's probes come from the chart (`GET /api/health`).

## Grafana rollout strategy

Grafana's PVC is `ReadWriteOnce`, so its `deploymentStrategy` is set to
**`Recreate`** rather than the chart's default `RollingUpdate`. With one
replica, `RollingUpdate`'s 25% `maxUnavailable` rounds to **0** — the surge pod
is created first and the old pod is not terminated until it is Available, but
the surge pod cannot attach a volume the old pod still holds. That deadlock was
hit during the 2026-11-17 password rotation; it is the same failure mode as
Traefik's RWO `acme.json` (PR #22). `Recreate` costs a few seconds of
downtime per upgrade and guarantees the rollout finishes.

## Grafana secret

`grafana-values.yaml` sets `admin.existingSecret: grafana`. Create it first:

```bash
kubectl -n monitoring create secret generic grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='CHOOSE-A-STRONG-PASSWORD'
```

## Access

Grafana is exposed at `grafana.devinflake.com` by two IngressRoutes in
`../dashboards/ingressroutes.yaml`: `grafana-dashboard` terminates TLS on
`websecure`, and `grafana-dashboard-redirect` sends plain HTTP to HTTPS. They
must be separate because Traefik's `tls` setting applies to the whole router —
a single TLS router does not match the `web` entrypoint. Both front the
ClusterIP Service on port 80 → 3000.

## Dashboards and Longhorn metrics

`dashboards/*.json` are the source of truth for the four dashboards (cluster,
nodes, Traefik, Longhorn). The `grafana-dashboards` Application renders them
through Kustomize into labelled ConfigMaps; the chart's dashboard sidecar
provisions them into Grafana. Never build a dashboard in the UI and expect it
to survive a PVC loss — nothing in `monitoring/grafana` is backed up.

The PVC still held a UI-created Prometheus datasource with a generated UID.
Grafana 13 cannot change a datasource's UID in place and failed startup with
`Datasource provisioning error: data source not found` when the provisioned
file pinned `prometheus`. The provisioning file therefore deletes the old
datasource by name and recreates it with the stable UID the dashboards use.

Longhorn's `/metrics` endpoint is blocked by its own NetworkPolicy by default.
`manifests/longhorn-scrape-networkpolicy.yaml` opens port 9500 only to the
Prometheus server pods in `monitoring`, and `prometheus-values.yaml` defines
the matching static scrape job. Both are owned by the `prometheus`
Application, so they cannot drift apart.

## Alerting

Five rules in `prometheus-values.yaml` (`serverFiles.alerting_rules.yml`) fire
on: a node not Ready for 5m, a PVC not Bound for 15m, a Longhorn volume
`degraded` or `faulted` for 5m, and a CronJob whose last schedule has no later
success for 15m. All route to one receiver, `ntfy`, with `send_resolved: true`,
grouping by alert name and namespace.

The ntfy.sh topic is **not in git**. It is the `url` key of the SealedSecret
`../secrets/sealed/alertmanager-ntfy.yaml`, unsealed into Secret
`monitoring/alertmanager-ntfy` and mounted at `/etc/alertmanager/ntfy/url`.
Alertmanager does not expand environment variables in its config, so the
webhook uses `url_file` rather than `${NTFY_URL}`. A rebuild applies every
sealed manifest through `scripts/install-addons.sh`; on an existing cluster,
apply this one once with `kubectl apply -f ../secrets/sealed/alertmanager-ntfy.yaml`
**before** the Prometheus app syncs, or the Alertmanager pod stays Pending on
the missing volume. To subscribe, read the topic from the operator-local copy
(`~/.kube/dramble-ntfy-topic.txt`, mode 0600); whoever holds the full URL can
subscribe, so treat it as a bearer credential.

Certificate-expiry alerts are deliberately deferred: Traefik stores its ACME
certificate in a file on its PVC, not in a Kubernetes Secret, so there is no
cert-manager expiration metric to alert on.

## Prometheus targets

After the 2026-11-22 Prometheus restart refreshed service discovery following
the control-plane move, all 29 active targets are up. The
`kubernetes-api-servers` job now scrapes `192.168.0.44:6443`; the earlier stale
`192.168.0.61` endpoint is gone. See
[../../docs/cluster-status.md](../../docs/cluster-status.md).
