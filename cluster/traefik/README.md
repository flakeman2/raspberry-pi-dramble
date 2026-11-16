# Traefik

Traefik chart `42.4.0` (application `v3.7.18`), one replica, exposed as a
`LoadBalancer` at `192.168.0.201` by MetalLB.

```bash
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --version 42.4.0 \
  -f values.yaml

kubectl apply -f tlsoption.yaml
kubectl apply -f middlewares.yaml
kubectl apply -f ingressroutes.yaml
```

The chart installs its own `traefik.io` CRDs from `crds/`; wait for them to be
established before applying the three files above on a fresh cluster
(`kubectl wait --for condition=established crd/ingressroutes.traefik.io`).

| File | Contents |
|---|---|
| `values.yaml` | Helm values (ACME, persistence, dashboard, logging, metrics) |
| `tlsoption.yaml` | `TLSOption/default`, minimum TLS 1.2 |
| `middlewares.yaml` | `basic-auth`, `redirect-to-https`, `ssl-redirect` |
| `ingressroutes.yaml` | Host routes for mysite, jekyll, whoami, Traefik UI |

## TLS

- Resolver `letsencrypt`, TLS-ALPN-01 challenge, Let's Encrypt production.
- Store: `/data/acme.json` on a 128 MiB Longhorn PVC.
- Account email: `devinflake@gmail.com` (change in `values.yaml` if desired).
- Six certificates are live and valid through January 2027.

## Auth

The `basic-auth` Middleware references Secret `default/authsecret` key `users`.
Create it before applying the middlewares:

```bash
kubectl -n default create secret generic authsecret \
  --from-literal=users="$(htpasswd -nbB admin 'CHOOSE-A-PASSWORD')"
```

See [../../docs/secrets.md](../../docs/secrets.md).

## Notes

- The Deployment runs with strategy **`Recreate`**, patched in
  `scripts/install-addons.sh` right after the Helm install. Chart 42 has no
  `deployment.strategy` value (its `values.schema.json` rejects unknown keys),
  and the default `RollingUpdate` deadlocks against the `acme.json` PVC: the
  new pod waits for a volume detach the old pod never makes while
  `maxUnavailable: 0` keeps it alive. It happened twice during the 2026-11-15
  rebuild and each time needed `kubectl delete pod` on the old one. `Recreate`
  costs a ~45 s gap on upgrade for a single replica, which is the honest cost
  of an `ReadWriteOnce` volume.
- The chart creates its own `traefik/traefik-dashboard` IngressRoute on
  `PathPrefix(/dashboard)` and `PathPrefix(/api)`.
- `traefik-dflake-dashboard` exposes the API on the hostnames
  `traefik.devinflake.com` / `traefik.flakeman2.com` behind basic auth.
- Only `IngressRoute` objects are used; there are no Kubernetes `Ingress`
  objects. The `kubernetesIngress` provider remains enabled.
- Metrics are exposed on the `metrics` entry point but not published by the
  Service; Prometheus scrapes the pod IP directly.
- The CRs use the Traefik 3.x API group `traefik.io/v1alpha1`; they were
  rewritten from `traefik.containo.us` in the 2026-11-14 retarget.
- Chart 42's `values.schema.json` sets `additionalProperties: false`, so keys
  cannot be carried over from chart 10 blindly: `logs:` is now `log:` +
  `accessLog:`, `service.type` is now `service.spec.type`, `image.name` is now
  `image.repository` (omitted entirely, so the chart pins its appVersion), and
  the two `allowexternalnameservices` CLI flags became provider settings.
