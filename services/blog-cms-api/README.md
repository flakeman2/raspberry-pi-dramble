# blog-cms-api

Small Go service behind `blog.devinflake.com/post/api/`. It backs the static
post editor in Ephesus. Drafts are files in Git on `cms/<slug>` branches; there
is no database and no GitHub token is ever sent to the browser.

## Routes

| Method | Path | Role | Purpose |
|---|---|---|---|
| `GET` | `/post/api/healthz` | public | Liveness/readiness |
| `POST` | `/post/api/login` | public | Verify admin or guest password; set signed session cookie |
| `POST` | `/post/api/logout` | any | Clear session cookie |
| `GET` | `/post/api/me` | any | Return current role |
| `GET` | `/post/api/drafts` | any | List open draft PRs visible to the role |
| `POST` | `/post/api/drafts` | any | Save `_drafts/<slug>.md` on `cms/<slug>` |
| `POST` | `/post/api/preview` | any | Validate front matter and render Markdown preview |
| `POST` | `/post/api/submit` | any | Open the post PR; guest PRs wait for approval |
| `GET` | `/post/api/review` | admin | List guest and admin post PRs |
| `POST` | `/post/api/approve` | admin | Merge a guest post PR |
| `POST` | `/post/api/publish` | admin | Merge an admin post PR |

All state-changing routes except login require the CSRF token returned by
login in the `X-CSRF-Token` header.

## Configuration

The service reads configuration from environment variables. No secret value is
stored in this repository; in the cluster these come from SealedSecrets.

| Variable | Purpose |
|---|---|
| `ADDR` | Listen address; defaults to `:8080` |
| `COOKIE_SECURE` | Set to `false` only for local HTTP testing; defaults to `true` |
| `SESSION_KEY` | Base64-encoded HMAC key, at least 32 bytes |
| `ADMIN_PASSWORD_HASH` | bcrypt hash of the unified admin password |
| `GUEST_PASSWORD_HASH` | bcrypt hash of the shared guest password |
| `LOGIN_RATE_LIMIT` | Failed-login budget per IP; defaults to `5` |
| `LOGIN_RATE_WINDOW` | Rate-limit window; defaults to `1m` |
| `EPHESUS_OWNER`, `EPHESUS_REPO` | Blog content repository; defaults to `flakeman2`/`Ephesus` |
| `DRAMBLE_OWNER`, `DRAMBLE_REPO` | Deployment repository; defaults to `flakeman2`/`raspberry-pi-dramble` |
| `GITHUB_API_URL` | GitHub API base URL; defaults to `https://api.github.com` |
| `NTFY_URL`, `NTFY_TOPIC` | Optional sealed notification destination |
| `WRITER_APP_ID`, `WRITER_INSTALLATION_ID`, `WRITER_PRIVATE_KEY` | GitHub App for drafts and PR creation |
| `PUBLISHER_APP_ID`, `PUBLISHER_INSTALLATION_ID`, `PUBLISHER_PRIVATE_KEY` | GitHub App for merging post PRs |
| `APPROVER_APP_ID`, `APPROVER_INSTALLATION_ID`, `APPROVER_PRIVATE_KEY` | GitHub App for approving and merging bump PRs |

The background reconciler polls for open `bump/jekyll-sha-*` and
`bump/blog-cms-api-sha-*` PRs into `dev`, approves them with `cms-approver`, and
merges them. Session state is a signed cookie; role checks are repeated on the
server for every privileged route.

## Local checks

```bash
go test ./...
go vet ./...
```
