# Dashboard IngressRoutes

UI routes for Grafana and Longhorn.

- `longhorn-dashboard` (namespace `longhorn-system`): `longhorn.devinflake.com`,
  `longhorn.flakeman2.com` → `longhorn-frontend:80`, behind `basic-auth` and
  `redirect-to-https`.
- `grafana-dashboard` (namespace `monitoring`): `grafana.devinflake.com`,
  `grafana.flakeman2.com` → `grafana:80`, TLS only.

```bash
kubectl apply -f ingressroutes.yaml
```

Grafana's TLS certificate is issued by Traefik ACME on first request. The
Longhorn UI requires the `authsecret` credentials.

Note: `grafana.devinflake.com` has no HTTP→HTTPS redirect (it returns 404 on port
80). See [../../docs/action-items.md](../../docs/action-items.md).
