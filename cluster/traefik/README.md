# Traefik

Traefik chart `10.9.1` (application `2.5.6`), one replica, exposed as a
`LoadBalancer` at `192.168.0.201` by MetalLB.

```bash
helm install traefik traefik/traefik \
  --namespace traefik --version 10.9.1 \
  -f values.yaml

kubectl apply -f tlsoption.yaml
kubectl apply -f middlewares.yaml
kubectl apply -f ingressroutes.yaml
```

| File | Contents |
|---|---|
| `values.yaml` | Helm values (ACME, persistence, dashboard, logging, metrics) |
| `tlsoption.yaml` | `TLSOption/default`, minimum TLS 1.2 |
| `middlewares.yaml` | `basic-auth`, `redirect-to-https`, `ssl-redirect` |
| `ingressroutes.yaml` | Host routes for mysite, jekyll, whoami, pi-hole, Traefik UI |

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

- The chart creates its own `traefik/traefik-dashboard` IngressRoute on
  `PathPrefix(/dashboard)` and `PathPrefix(/api)`.
- `traefik-dflake-dashboard` exposes the API on the hostnames
  `traefik.devinflake.com` / `traefik.flakeman2.com` behind basic auth.
- Only `IngressRoute` objects are used; there are no Kubernetes `Ingress`
  objects. The `kubernetesIngress` provider remains enabled.
- Metrics are exposed on the `metrics` entry point but not published by the
  Service; Prometheus scrapes the pod IP directly.
- The CRDs use the Traefik 2.x API group `traefik.containo.us`. A Traefik v3
  upgrade requires rewriting these objects to `traefik.io`.
