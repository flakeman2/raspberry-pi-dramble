# Dynamic DNS

Two CronJobs update Namecheap (Park-Your-Domain) A records every 30 minutes:

| CronJob | Domain | Secret key | Hosts |
|---|---|---|---|
| `dyn-dns-devinflake.com` | `devinflake.com` | `password-devinflake.com` | `@`, `www`, `*` |
| `dyn-dns-flakeman2.com` | `flakeman2.com` | `password-flakeman2.com` | `@`, `www`, `*` |

They run `curlimages/curl:7.81.0`, take `DDNS_PASSWORD` from Secret
`default/dyn-dns-credentials`, and call
`https://dynamicdns.park-your-domain.com/update?host=…&domain=…&password=…`.

> **One password per domain — forced by the provider (2026-11-16).** An earlier
> plan used a single shared `password` key with one password for both domains,
> but **Namecheap requires a unique DDNS password per domain**. The Secret
> therefore carries two keys and each CronJob reads its own. Rotate both values
> together at Namecheap.

## Create the Secret

Both keys must exist before the CronJobs schedule cleanly:

```bash
kubectl -n default create secret generic dyn-dns-credentials \
  --from-literal=password-devinflake.com='DEVINFLAKE_COM_DDNS_PASSWORD' \
  --from-literal=password-flakeman2.com='FLAKEMAN2_COM_DDNS_PASSWORD'
kubectl apply -f cronjobs.yaml
```

Alternatively copy `../secrets/examples/dyn-dns-credentials.yaml`, substitute
real values, and apply it.

## Verify — read the logs, not the Job status

Namecheap answers **HTTP 200** with `<ErrCount>` in the body, so a job using the
wrong password still reports `Complete`:

```bash
kubectl -n default create job --from=cronjob/dyn-dns-devinflake.com ddns-check
kubectl -n default create job --from=cronjob/dyn-dns-flakeman2.com ddns-check-b
sleep 8
kubectl -n default logs job/ddns-check  | grep -o '<ErrCount>[0-9]*</ErrCount>' | tail -1   # want 0
kubectl -n default logs job/ddns-check-b | grep -o '<ErrCount>[0-9]*</ErrCount>' | tail -1   # want 0
kubectl -n default delete job ddns-check ddns-check-b
```

On 2026-11-16 `flakeman2.com` returned `<ErrCount>1</ErrCount>` under the
interim single-key Secret — the mismatch this two-key design removes.

Completed Job pods hold no secret material: the password arrives as an
environment variable sourced from the Secret, never in the command line, so
old Jobs can be left to the history limits.

## Records

Both domains publish A records pointing at the cluster's public IPv4 address,
and neither publishes an AAAA record — updating A records only is complete.
