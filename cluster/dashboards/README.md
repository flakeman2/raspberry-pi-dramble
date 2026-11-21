# Dashboard IngressRoutes

UI routes for Grafana, Longhorn and Prometheus.

- `longhorn-dashboard` (namespace `longhorn-system`): `longhorn.devinflake.com`,
  `longhorn.flakeman2.com` → `longhorn-frontend:80`, behind `basic-auth` and
  `redirect-to-https`.
- `grafana-dashboard` (namespace `monitoring`): `grafana.devinflake.com`,
  `grafana.flakeman2.com` → `grafana:80`, on `web` and `websecure`; HTTP uses
  the shared `redirect-to-https` middleware.
- `prometheus-dashboard` (namespace `monitoring`): `prometheus.devinflake.com`,
  `prometheus.flakeman2.com` → `prometheus-server:80` (the chart's Service
  port, which fronts the UI on `/graph`, `/alerts`, `/targets`, `/config` …),
  behind `basic-auth` and `redirect-to-https`. It has no password of its own —
  Prometheus ships none — so the gate is the shared `authsecret` credential.
  DNS needed no work: the DynDNS `*` record already resolves both names.

```bash
kubectl apply -f ingressroutes.yaml
```

Grafana's TLS certificate is issued by Traefik ACME on first request. The
Longhorn UI requires the `authsecret` credentials.

The Grafana dashboard definitions themselves are not here — they live in
`../monitoring/dashboards/` as JSON files, delivered by their own Argo
Application. This directory owns routing only.
