# Secrets

No secret values are stored in this repository. This page lists every secret the
cluster needs, how to create it, and how to rotate it.

## Inventory

| Secret | Namespace | Keys | Consumer |
|---|---|---|---|
| `authsecret` | `default` | `users` | Traefik `basic-auth` Middleware (Traefik + Longhorn dashboards) |
| `grafana` | `monitoring` | `admin-user`, `admin-password`, `ldap-toml` | Grafana deployment |
| `dyn-dns-credentials` | `default` | `password` | Both dynamic-DNS CronJobs (**not yet applied live**) |
| k3s join token | node filesystem | `/var/lib/rancher/k3s/server/node-token`, `k3s-agent.service.env` | k3s agents |
| kubeconfig | workstation | client cert/key | `kubectl` / Helm |
| ACME account + certs | `traefik` PVC | `/data/acme.json` | Traefik |
| `config.yml` | working tree | legacy DB/Drupal passwords | nothing (gitignored) |

Kubernetes also creates service-account token Secrets automatically; they are
not managed here.

### Not in the cluster

The live cluster has no `cert-manager`, no image-pull registry Secret, and no
Sealed Secrets/SOPS/External Secrets controller. Everything is a plain
Kubernetes Secret.

## Create the required Secrets

Apply the namespaces first:

```bash
kubectl apply -f cluster/namespaces.yaml
```

### `authsecret` (dashboard basic auth)

`users` is an htpasswd file body. Generate a bcrypt entry:

```bash
htpasswd -nbB admin 'CHOOSE-A-STRONG-PASSWORD'
# admin:$2y$05$...
```

Create the Secret:

```bash
kubectl -n default create secret generic authsecret \
  --from-literal=users="$(htpasswd -nbB admin 'CHOOSE-A-STRONG-PASSWORD')"
```

Add more users by appending additional `user:hash` lines, separated by newlines,
to the `users` value.

### `grafana`

```bash
kubectl -n monitoring create secret generic grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='CHOOSE-A-STRONG-PASSWORD'
```

`cluster/monitoring/grafana-values.yaml` sets `admin.existingSecret: grafana`, so
the chart does not generate its own credentials. The live cluster's Secret also
has an empty `ldap-toml` key; it is optional because LDAP is disabled.

### `dyn-dns-credentials`

```bash
kubectl -n default create secret generic dyn-dns-credentials \
  --from-literal=password='PARK-YOUR-DOMAIN-PASSWORD'
```

The live CronJobs still embed this password in the container command. After
creating the Secret, re-apply `cluster/dns/cronjobs.yaml` so the jobs reference
the Secret instead, then delete the old Jobs:

```bash
kubectl apply -f cluster/dns/cronjobs.yaml
kubectl -n default delete job -l job-name=dyn-dns-devinflake.com --ignore-not-found
kubectl -n default delete job -l job-name=dyn-dns-flakeman2.com --ignore-not-found
```

## k3s join token

The server stores it at `/var/lib/rancher/k3s/server/node-token`; agents receive
it through `/etc/systemd/system/k3s-agent.service.env` (`K3S_TOKEN=...`). It was
exposed during the 2026-11-14 investigation and should be rotated.

The least disruptive rotation is during the planned rebuild: a fresh
`install-server.sh` generates a new token, and each `install-agent.sh` receives
it via `K3S_TOKEN`. To rotate an existing cluster, set a new token on the server
(`--token` in `/etc/rancher/k3s/config.yaml` or `K3S_TOKEN` in
`k3s.service.env`), restart the server, then update every agent's
`k3s-agent.service.env` and restart `k3s-agent`.

Do not put the token in this repository or in shell history on shared machines.

## kubeconfig

The k3s kubeconfig is a client certificate/key pair with cluster-admin scope.
Keep it outside the repository:

```bash
ssh pi@192.168.0.61 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-dramble-k3s
sed -i 's/127\.0\.0\.1/192.168.0.61/' ~/.kube/config-dramble-k3s
chmod 600 ~/.kube/config-dramble-k3s
```

The server certificate is valid until 2027-03-05.

## ACME state

Traefik writes account keys and certificates to `/data/acme.json` on the
`traefik` Longhorn PVC (mode `0600`, owner `65532`). It is not a Kubernetes
Secret and must never be committed. The file on the live cluster is ~79 KB and
holds six certificates.

## Legacy `config.yml`

The working tree contains an untracked `config.yml` with plaintext database and
Drupal passwords from the upstream Ansible project. It is listed in
`.gitignore` and is not used by the cluster. Delete it from your workstation if
you do not need it locally:

```bash
rm config.yml
```

## Scanning before you commit

```bash
git grep -nEi 'password|passwd|secret|token|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' -- \
  ':!docs/secrets.md' ':!cluster/secrets/examples' ':!cluster/dns/cronjobs.yaml'
```

Also check that no real values slipped into the example manifests:

```bash
git grep -nE 'REPLACE_WITH|\$2[aby]\$' -- cluster/secrets
```

The only acceptable hits are placeholders such as `REPLACE_WITH_...`.

## Git history

The live secrets were never committed. The only credential-like content in
history is the upstream `example.config.yml` file, whose values (MySQL/Drupal
passwords, hash salt, registry HTTP secret) were examples from the original
Ansible project and were never used by this cluster. The previously tracked
`k8s-manifests/docker-registry/certs/` directory only ever held a README and a
`.gitignore`, not certificates or keys. No history rewrite is needed.
