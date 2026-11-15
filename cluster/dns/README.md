# Dynamic DNS

Two CronJobs update Park-Your-Domain A records every 30 minutes:

| CronJob | Domain | Hosts |
|---|---|---|
| `dyn-dns-devinflake.com` | `devinflake.com` | `@`, `www`, `*` |
| `dyn-dns-flakeman2.com` | `flakeman2.com` | `@`, `www`, `*` |

They run `curlimages/curl:7.81.0` and read the password from Secret
`default/dyn-dns-credentials` key `password`.

> **Two domains, one key.** The live passwords for `devinflake.com` and
> `flakeman2.com` are *different*, but both CronJobs read the same
> `password` key. Either set one password for both domains at Park-Your-Domain
> when you rotate (planned for immediately after the reimage), or split the
> Secret into `password-devinflake.com` and `password-flakeman2.com` and point
> each CronJob's `secretKeyRef.key` at its own. Resolve this before the
> rebuild, or one domain's updates fail silently.

```bash
kubectl -n default create secret generic dyn-dns-credentials \
  --from-literal=password='PARK-YOUR-DOMAIN-PASSWORD'
kubectl apply -f cronjobs.yaml
```

The live cluster still has the password embedded in the container command in
both jobs; applying this file replaces that. Delete old completed jobs to clear
the inline value from history:

```bash
kubectl -n default delete job -l job-name=dyn-dns-devinflake.com --ignore-not-found
kubectl -n default delete job -l job-name=dyn-dns-flakeman2.com --ignore-not-found
```

Verify:

```bash
kubectl -n default get cronjob
kubectl -n default create job --from=cronjob/dyn-dns-devinflake.com ddns-test
kubectl -n default logs job/ddns-test
kubectl -n default delete job ddns-test
```
