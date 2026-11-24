# Blog CMS GitHub App and secret setup

This is the one-time credential setup for the blog post editor API. It creates
three GitHub Apps, seals their keys plus the admin/guest credentials, and
produces one manifest that is safe to commit. No plaintext is written to git or
printed by the helper script.

The design and role model are in [blog-cms.md](blog-cms.md).

## Why three apps

Role enforcement lives in the GitHub tokens, not only in the web UI:

| App | Installed on | Grants | Used for |
|---|---|---|---|
| `cms-writer` | `flakeman2/Ephesus` | Contents write, Issues write, Pull requests write | Draft commits and post PR creation. Cannot merge. |
| `cms-publisher` | `flakeman2/Ephesus` | Contents write, Issues write, Pull requests write | Admin publish and admin approval of guest PRs. |
| `cms-approver` | `flakeman2/raspberry-pi-dramble` | Contents write, Pull requests write | Approve and merge image-bump PRs into protected `dev`. |

`Issues: write` is needed only to add the `cms/guest` and `cms/admin` labels to
pull requests.

## 1. Create the GitHub Apps

The exact permission sets are in `docs/blog-cms-app-manifests/`. For each of
`writer.json`, `publisher.json` and `approver.json`:

1. In GitHub, go to **Settings → Developer settings → GitHub Apps → New GitHub App**.
2. Copy the name, homepage URL, callback URL, permission toggles and event list
   from the matching JSON file.
3. Leave webhooks inactive and make the app private to the account.
4. Click **Create GitHub App** and record the **App ID** shown on the app page.

If a name is already taken on the account, append a short suffix and record the
actual name; only the IDs and keys matter to the service.

## 2. Install the apps and record installation IDs

Install each app on the repository listed in the table above:

- `cms-writer` and `cms-publisher`: `flakeman2/Ephesus`
- `cms-approver`: `flakeman2/raspberry-pi-dramble`

After installation, the browser URL contains the installation ID, for example
`/settings/installations/12345678`. Record that numeric ID for each app.

## 3. Generate private keys

On each app page, choose **Generate a private key** and save the downloaded PEM
files locally with mode `0600`:

```bash
mkdir -p -m 700 ~/.kube/blog-cms
install -m 600 /path/to/writer.pem    ~/.kube/blog-cms/writer.pem
install -m 600 /path/to/publisher.pem ~/.kube/blog-cms/publisher.pem
install -m 600 /path/to/approver.pem  ~/.kube/blog-cms/approver.pem
```

Do not copy these files into the repository. `.gitignore` already excludes
`*.pem`.

## 4. Prepare the password files

The admin password is reused from the existing off-repo file. Create the guest
password file with restrictive permissions and put the shared guest password
in it:

```bash
install -m 600 /dev/null ~/.kube/blog-cms/guest-password.txt
# Write the guest password into that file, with no surrounding quotes.
```

The script reads `~/.kube/unified-admin-password.txt` by default. It never
prints either password; only their bcrypt hashes enter the SealedSecret.

## 5. Seal the credentials

Export the IDs from step 2. To reuse the blog's existing ntfy destination,
point the script at the already-sealed Secret instead of handling the URL
directly:

```bash
export WRITER_APP_ID=... WRITER_INSTALLATION_ID=...
export PUBLISHER_APP_ID=... PUBLISHER_INSTALLATION_ID=...
export APPROVER_APP_ID=... APPROVER_INSTALLATION_ID=...
export NTFY_FROM_SECRET=monitoring/alertmanager-ntfy
```

The script reads that Secret's `url` key in-cluster, splits it into base URL and
topic, and seals both values into the new manifest without printing them. If
you prefer, set `NTFY_URL` and `NTFY_TOPIC` directly instead.

Then run from the repository root:

```bash
export KUBECONFIG=~/.kube/config-dramble-k3s
./scripts/setup-blog-cms-secret.sh
```

The script:

- verifies that all source files are mode `0600`;
- generates a fresh base64 session key;
- hashes both passwords with bcrypt cost 12;
- reads the three private keys;
- writes `cluster/secrets/sealed/blog-cms-api.yaml` with `kubeseal --scope strict`.

Only commit the generated SealedSecret. Keep the PEM files, password files and
all exported values off-repo.

## 6. Deployment

The generated SealedSecret is applied by the bootstrap path before Argo starts
the `blog-cms-api` Application. The deployment PR pins the API image tag and
adds the Argo Application, Traefik route and workload-local policy resources.

See [gitops.md](gitops.md#secrets) for the general SealedSecret workflow and
[blog-rebuild.md](blog-rebuild.md) for the blog image pipeline this API drives.
