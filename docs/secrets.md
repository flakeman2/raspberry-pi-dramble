# Secrets

No secret values are stored in this repository. This page lists every secret the
cluster needs, how to create it, and how to rotate it.

## Inventory

| Secret | Namespace | Keys | Consumer |
|---|---|---|---|
| `authsecret` | `default` | `users` | Traefik `basic-auth` Middleware (Traefik + Longhorn dashboards) |
| `grafana` | `monitoring` | `admin-user`, `admin-password`, `ldap-toml` | Grafana deployment |
| `dyn-dns-credentials` | `default` | `password-devinflake.com`, `password-flakeman2.com` | One key per dynamic-DNS CronJob — Namecheap requires a unique password per domain |
| k3s join token | node filesystem | `/var/lib/rancher/k3s/server/node-token`, `k3s-agent.service.env` | k3s agents |
| kubeconfig | workstation | client cert/key | `kubectl` / Helm |
| ACME account + certs | `traefik` PVC | `/data/acme.json` | Traefik |

Kubernetes also creates service-account token Secrets automatically; they are
not managed here.

### Not in the cluster

The live cluster has no `cert-manager`, no image-pull registry Secret, and no
Sealed Secrets/SOPS/External Secrets controller. Everything is a plain
Kubernetes Secret.

### Rotation decisions (2026-11-14)

- **`authsecret` and `grafana` are rotated, not restored.** Fresh values were
  generated on 2026-11-14 (bcrypt for `authsecret`) and written only to an
  off-repo directory at mode `0600`. The values on the live cluster die with it;
  do not export them.
- **Park-Your-Domain (Namecheap) passwords — rotated 2026-11-16.** Two unique
  values (one per domain — the provider enforces this), loaded into the
  two-key Secret at `04:56Z` and verified: manual jobs returned
  `<ErrCount>0</ErrCount>` on all three records for **both** domains. The
  interim value that had been exposed during the investigation was deleted
  along with its exported copy. Sequence used: bring the cluster up → rotate at
  Namecheap → write both values to a `0600` file → create the two-key Secret →
  apply `cluster/dns/cronjobs.yaml` → run both jobs and read `ErrCount`.
- **k3s join token and kubeconfig** regenerate during the rebuild; no action.

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

Namecheap requires a **unique DDNS password per domain**, so the Secret holds
one key per CronJob:

```bash
kubectl -n default create secret generic dyn-dns-credentials \
  --from-literal=password-devinflake.com='DEVINFLAKE_COM_DDNS_PASSWORD' \
  --from-literal=password-flakeman2.com='FLAKEMAN2_COM_DDNS_PASSWORD'
```

Each CronJob reads its own key (`cluster/dns/cronjobs.yaml`). Create **both**
keys first — a CronJob whose key is missing sits in `ContainerCreating` — then
apply the CronJobs and clean up any old Jobs:

```bash
kubectl apply -f cluster/dns/cronjobs.yaml
kubectl -n default delete job -l job-name=dyn-dns-devinflake.com --ignore-not-found
kubectl -n default delete job -l job-name=dyn-dns-flakeman2.com --ignore-not-found
```

## k3s join token

The server stores it at `/var/lib/rancher/k3s/server/node-token`; agents receive
it through `/etc/systemd/system/k3s-agent.service.env` (`K3S_TOKEN=...`).

**Rotated by the rebuild (2026-11-15).** The token exposed during the
2026-11-14 investigation died with the old cluster — `install-server.sh`
generated a fresh one for the new server, which is precisely the rotation this
section asked for. Keep the procedure below for any future in-place rotation.

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
ssh dflake@192.168.0.44 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config-dramble-k3s
sed -i 's/127\.0\.0\.1/192.168.0.44/' ~/.kube/config-dramble-k3s
chmod 600 ~/.kube/config-dramble-k3s
```

The 2026-11-21 control-plane move preserved the CA and client certificates,
so only the server URL changed — no new credentials were needed. Re-download
after any rebuild — this one was captured on 2026-11-15 for the new cluster,
whose cluster CA is valid until **2036-11-13**. (The pre-reimage
cluster's certificate, valid until 2027-03-05, died with it.)

## ACME state

Traefik writes account keys and certificates to `/data/acme.json` on the
`traefik` Longhorn PVC (mode `0600`, owner `65532`). It is not a Kubernetes
Secret and must never be committed. The file on the live cluster is ~79 KB and
holds six certificates.

## Legacy `config.yml` — removed 2026-11-22

The 2021 upstream fork left an untracked `config.yml` in the working tree with
plaintext Drupal, MySQL and registry passwords. It was gitignored, unused by
the cluster, and deleted locally on 2026-11-22. Its values were never committed;
the allowlists in [../.gitleaks.toml](../.gitleaks.toml) cover only the older
`example.config.yml` in inherited upstream history.

## Backups between the workstation and dflake-nettop

The two machines now mirror each other. Both scripts use **explicit include
lists** rather than globs — that is the exclusion mechanism: a file that belongs
on only one host is never named, so it cannot cross. Both compare SHA-256 and
print only PASS/FAIL, never a hash or a value (even a hash of a short password
is brute-forceable).

| Direction | Script | Runs on | Payload |
|---|---|---|---|
| nettop → workstation | [`stage-k3s-snapshot.sh`](../scripts/stage-k3s-snapshot.sh) + [`backup-nettop.sh`](../scripts/backup-nettop.sh) | nettop: root, then dflake | consistent `state.db` snapshot, `node-token`, `k3s.yaml`, `tls/`, `manifests/`, optional `token`/`config.yaml`, `SHA256SUMS` |
| workstation → nettop | [`backup-secrets.sh`](../scripts/backup-secrets.sh) | workstation | the four files below |

### Workstation → nettop

| File | Why it matters |
|---|---|
| `sealed-secrets-private-key-backup.yaml` | without it every SealedSecret in git is unrecoverable |
| `dramble-ntfy-topic.txt` | the full ntfy URL is the capability — anyone holding it can post |
| `unified-admin-password.txt` | cluster admin password |
| `config-dramble-k3s` | client cert/key; regenerable, but convenient after a machine loss |

Run on the workstation:

```bash
./scripts/backup-secrets.sh --dry-run   # show the commands, change nothing
./scripts/backup-secrets.sh             # copy to nettop and verify
```

It requires `0600` sources, creates a `0700` remote directory, and overwrites in
place. Override `NETTOP_USER`, `NETTOP_HOST`, `REMOTE_DIR` or `SOURCE_DIR` if the
defaults are wrong.

### Nettop → workstation (two crontabs, no sudo)

Reading `/var/lib/rancher/k3s/server` needs root; reaching the workstation
needs dflake's SSH key. Rather than grant dflake passwordless sudo, split the
job:

1. **root, 02:55** — `stage-k3s-snapshot.sh` takes a consistent SQLite
   `backup()` snapshot of `state.db` (k3s keeps running — copying `state.db`
   and its WAL sidecars from a live server is not reliable), collects the
   recovery set, and writes a dflake-owned tree at
   `/home/dflake/.kube/dramble-backup/staging/` with `SHA256SUMS` and a `READY`
   marker written last.
2. **dflake, 03:00** — `backup-nettop.sh` ships only a tree carrying `READY`,
   verifies it, then clears the marker. If the marker is absent it skips leg 1,
   so re-runs and out-of-order crons are harmless.

Remote calls retry on transient failure (`RETRIES=3`, `RETRY_DELAY=5` by
default). Leg 2 reads all four files in one SSH call before a single `scp`, so
a brief sshd restart or suspended workstation does not get misreported as
"missing" files.

The first live run exposed a second constraint: the workstation runs
`ufw limit ssh`, which rejects the 6th new connection from one source inside
30 seconds (`[UFW LIMIT BLOCK]` in `dmesg`, seen by the client as
`Connection refused`). All ssh and scp calls in `backup-nettop.sh` now share a
single multiplexed control connection (`ControlMaster=auto`), so one full run
counts as one connection. Alternatively, allow nettop's IP without a limit in
UFW on the workstation.

```bash
# root's crontab:
# 55 2 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/stage-k3s-snapshot.sh >> /var/log/dramble-stage-k3s.log 2>&1
# dflake's crontab:
# 0 3 * * * /home/dflake/github.com/raspberry-pi-dramble/scripts/backup-nettop.sh >> /home/dflake/backup-nettop.log 2>&1
```

Check both before scheduling:

```bash
sudo /home/dflake/github.com/raspberry-pi-dramble/scripts/stage-k3s-snapshot.sh --dry-run
/home/dflake/github.com/raspberry-pi-dramble/scripts/backup-nettop.sh --preflight
/home/dflake/github.com/raspberry-pi-dramble/scripts/backup-nettop.sh --dry-run
```

The dflake script needs only key-based SSH to `192.168.0.54`
(`WORKSTATION_HOST`). Archives land in
`~/.kube/dramble-backup/nettop/k3s-<date>.tar.gz` on the workstation; those
older than `KEEP_DAYS` (30) are deleted. To inspect or restore:

```bash
tar -tzf ~/.kube/dramble-backup/nettop/k3s-<date>.tar.gz
# extract into a scratch dir, then follow docs/control-plane-migration-nettop.md
```

### Deliberately excluded

- Nettop → workstation: `db/state.db-wal` and `db/state.db-shm` (the consistent
  snapshot replaces them), plus `agent/`, `logs/` and `data/` (regenerable).
- Workstation → nettop: `gemini_api_key.txt` (workstation-only tool credential),
  `config-dramble-k3s.bak`, `cache/`, `k3s_state/` and `dramble-backup/`. The last
  one matters most: it is the incoming nettop archive and must not be shuttled
  back.

### What this still does not cover

Both machines are in the same house, on the same power and LAN. This protects
against losing one machine, not against site loss (fire, theft, surge) or
lateral ransomware. There is still no off-site copy. The SealedSecret values
need no plaintext export — they are in git, encrypted to the private key; that
key is the load-bearing file. The old `~/.kube/dramble-secrets-2026-11-14/`
directory is gone and that is fine.

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
