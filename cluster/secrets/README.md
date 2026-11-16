# Secrets

Placeholders and requirements only. **No real secret values are stored here.**

| Secret | Namespace | Keys | What to do |
|---|---|---|---|
| `authsecret` | default | `users` | Copy `examples/authsecret.yaml`, replace the hash, apply |
| `grafana` | monitoring | `admin-user`, `admin-password` | Copy `examples/grafana.yaml`, set a password, apply |
| `dyn-dns-credentials` | default | `password-devinflake.com`, `password-flakeman2.com` | Copy `examples/dyn-dns-credentials.yaml`, set **both** passwords, apply |

The k3s join token, kubeconfig, and Traefik `acme.json` are not Kubernetes
Secrets and are not stored in this repository.

Full creation and rotation instructions: [../../docs/secrets.md](../../docs/secrets.md).

```bash
kubectl apply -f examples/authsecret.yaml
kubectl apply -f examples/grafana.yaml
kubectl apply -f examples/dyn-dns-credentials.yaml
```

Do not apply the examples unchanged; the placeholders are not valid credentials.
