# Workloads

| Directory | Namespace | What it is |
|---|---|---|
| `mysite/` | `mysite-nginx` | Static site for `devinflake.com` / `flakeman2.com` |
| `jekyll/` | `jekyll` | Blog for `blog.devinflake.com` |
| `whoami/` | `whoami` | Traefik whoami demo at `/whoami` |

```bash
kubectl apply -R -f cluster/workloads
```

## mysite

- `nginx:1.31.8`, 1 replica, ClusterIP Service on 80/443.
- `mysite-content` 1 GiB **RWX** PVC mounted at `/usr/share/nginx/html`.
- `nginx-conf` ConfigMap mounted at `/etc/nginx/conf.d/default.conf`.
- The current document root is checked in under `mysite/content/`.

Restore the content after a rebuild:

```bash
kubectl -n mysite-nginx cp mysite/content/. \
  deploy/mysite-nginx:/usr/share/nginx/html/
```

## jekyll

`flakeman2/jekyll:sha-732b174`, 3 replicas, ClusterIP port 80, TCP readiness and
liveness probes. No PVC — the blog content is baked into the image.

The image, all four posts, and their history rebuild from
[`flakeman2/Ephesus`](https://github.com/flakeman2/Ephesus). Procedure,
the exact deployed commit, and verification:
[../../docs/blog-rebuild.md](../../docs/blog-rebuild.md).

## whoami

`traefik/whoami:v1.12.0`, 2 replicas, ClusterIP port 80. Routed at
`PathPrefix(/whoami)` on the apex domains.

## pi-hole — removed 2026-11-14

The `ExternalName` stub to `192.168.0.46:80` never worked (that host is
unreachable), so the namespace, Service, `redirect-to-https` middleware, and
both IngressRoutes were deleted before the reimage. The
`pi-hole.devinflake.com` DNS record and its certificate are no longer served;
delete the record at the provider if it still exists. Traefik's
`allowExternalNameServices` flags went with it.
