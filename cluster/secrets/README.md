# Secrets

## Sealed (in git)

Real credentials are stored here as **SealedSecrets** — encrypted with the
controller's public key, so they are safe to commit to this public repository.

```bash
sealed/
  authsecret.yaml             default/authsecret              → users
  grafana.yaml                monitoring/grafana              → admin-user, admin-password
  dyn-dns-credentials.yaml    default/dyn-dns-credentials     → password-devinflake.com, password-flakeman2.com
```

The **namespace, name and key names are plaintext** in a SealedSecret; only the
values are encrypted. That is by design — it is what lets you see what a
manifest contains without being able to read it.

### Prerequisites

1. The controller must be running first:
   `kubectl apply -f ../sealed-secrets/controller.yaml`
2. `kubeseal` on your workstation (`kubectl` plugin or standalone binary).

### Applying

```bash
kubectl apply -f sealed/
```

### Changing a value

```bash
# read the live secret, seal the new value, apply — never print the value
kubectl -n <ns> get secret <name> -o json | kubeseal --format yaml > sealed/<name>.yaml
kubectl apply -f sealed/<name>.yaml
```

Full rotation procedure: [../../docs/secrets.md](../../docs/secrets.md).

### If the controller does not own the Secret yet

A Secret created by hand cannot be adopted automatically — the controller fails
with `already exists and is not managed by SealedSecret` and then gives up.
Delete the SealedSecret, delete the Secret, and re-apply the SealedSecret; see
[../../docs/gitops.md](../../docs/gitops.md#adopting-a-secret-that-already-exists).

**Losing the controller's private key makes every file in `sealed/`
unrecoverable.** Back it up outside this repository (mode `0600`); it is the
`sealed-secrets-key*` Secret in `kube-system`.

## Templates (examples)

`examples/` holds plaintext templates with **placeholder** values, for
understanding the shape of each Secret or for bootstrapping before the
controller exists.

**Do not apply the examples unchanged; the placeholders are not valid
credentials.** In practice `sealed/` supersedes them — once the controller is
up, apply `sealed/` instead.

| Secret | Namespace | Keys |
|---|---|---|
| `authsecret` | default | `users` |
| `grafana` | monitoring | `admin-user`, `admin-password` |
| `dyn-dns-credentials` | default | `password-devinflake.com`, `password-flakeman2.com` |

## Not stored in this repository

The k3s join token, kubeconfig, Traefik `acme.json`, and the sealed-secrets
**private key** are not Kubernetes Secrets managed here, and never belong in
git.

- k3s join token / kubeconfig: regenerate during a rebuild.
- `acme.json`: lives on the Traefik PVC; restoring it is optional (Let's
  Encrypt will re-issue).
- Sealed-secrets private key: backed up off-repo at `0600`. Use
  [`../../scripts/backup-secrets.sh`](../../scripts/backup-secrets.sh) to copy
  it (and the other small `.kube` secrets) to `dflake-nettop` and verify the
  copies by hash. The reverse direction (k3s recovery set → workstation) is
  [`../../scripts/backup-nettop.sh`](../../scripts/backup-nettop.sh); both are
  described in [../../docs/secrets.md#backups-between-the-workstation-and-dflake-nettop](../../docs/secrets.md#backups-between-the-workstation-and-dflake-nettop).

Full creation and rotation instructions: [../../docs/secrets.md](../../docs/secrets.md).
