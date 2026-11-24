# Blog post editor (design)

Status: **proposed**. This document records the Phase 0 decisions for adding a
browser-based post editor to the Flake blog. It is the design companion to
[blog-rebuild.md](blog-rebuild.md), which describes the current static Jekyll
build and image pipeline.

## Decisions

| Decision | Choice |
|---|---|
| Editing experience | Markdown-first editor with a live preview and a formatting toolbar; Jekyll/Kramdown remains the only renderer of record. |
| Publish flow | Admin: preview → **Publish** merges the post PR immediately. Guest: preview → **Submit for review** opens a PR and waits in the admin queue. |
| Admin login | Reuse the unified admin password. The API stores only a bcrypt hash in a SealedSecret; the plaintext is never committed or printed. |
| Guest login | Dedicated shared guest password. Its bcrypt hash is stored in a SealedSecret; guest can only create drafts and submit posts for review. |
| Bump PR | Fully automatic: a separate approver identity approves and merges the image-bump PR into `dev`. |
| UI location | `https://blog.devinflake.com/post/`, with the page source living in the Ephesus repository. |
| API location | A small in-cluster service routed at `https://blog.devinflake.com/post/api/` by Traefik. |
| Hostnames | No new public hostname. The existing `blog.devinflake.com` certificate and `letsencrypt` resolver are reused. |
| Database | None. Drafts live in Git branches; sessions are signed cookies; audit history is Git history. |

## Why not an off-the-shelf CMS

Decap CMS and Sveltia CMS are the natural Jekyll candidates: they are
MIT-licensed, Git-backed, responsive, and have an editorial workflow that maps
draft/review/publish to branches and pull requests. They are not a fit here
because their authentication is GitHub OAuth (or a paid hosted layer), not
shared admin and guest passwords with distinct roles. Their open-authoring
model also requires a GitHub account for each guest, and guest PRs are approved
in the Git host rather than in the CMS queue.

Sitepins has real roles, email/password accounts and in-app PR merge, but
self-hosting it means adding Node 22, MongoDB, S3-compatible storage, a mail
provider and an AGPL-licensed service stack for one blog. Pages CMS is MIT and
self-hostable but needs PostgreSQL and does not yet have granular permissions.
TinaCMS and CloudCannon are React/SaaS-oriented, and Jekyll Admin is explicitly
local-only with no auth. A thin first-party service is smaller than any of
these alternatives and matches the workflow exactly.

## Architecture

### Static page in Ephesus

The editor page is committed to Ephesus so it ships with the blog image:

- `_pages/post.md` with `layout: page` and `permalink: /post/` (the `pages`
  collection already exists in `_config.yml`).
- `assets/js/post-editor.js` and additions to `assets/css/style.css`.
- `_pages/**` is added to the path filter in
  Ephesus `.github/workflows/publish.yml`; `assets/**` is already covered.

The page contains the editor, the preview page, the login form and the review
queue. It never holds a GitHub token and never talks to GitHub directly. All
data goes to the same-origin API under `/post/api/`.

### API service in the cluster

A new Go service, built as a small static binary, provides the endpoints below.
Its source lives in `services/blog-cms-api/`; CI publishes
`ghcr.io/flakeman2/blog-cms-api:sha-<7>` on changes to `dev`.

- `POST /post/api/login` — verifies either the admin or guest password hash;
  sets a signed, HttpOnly, Secure, SameSite cookie carrying the role.
- `GET/POST /post/api/drafts` — create and update `_drafts/<slug>.md` on a
  `cms/<slug>` branch in Ephesus.
- `POST /post/api/preview` — render the Markdown/front matter for the preview
  page. Phase 1 uses server-side Markdown rendering with GFM settings chosen
  to match Kramdown; Phase 2 can add a Jekyll-built preview URL.
- `POST /post/api/submit` — open the PR from `cms/<slug>` to Ephesus `master`,
  labelled `cms/guest` or `cms/admin`.
- `GET /post/api/review` — admin-only list of open `cms/*` PRs.
- `POST /post/api/approve` — admin-only merge of a guest post PR.
- `POST /post/api/publish` — admin-only merge of an admin post PR.

Database-free state:

- Draft content is a file in Git, so it survives restarts and is visible across
  devices.
- Session state is a signed cookie (no server-side session store).
- Required front matter is validated before a PR is opened: `title`, `date`,
  `author`, `layout: post`, `permalink`, `tags`, AI-model disclosure, and the
  verification line required by the blog's publishing policy.

### Traefik routing

Add a more specific HTTPS route in
`cluster/traefik/ingressroutes.yaml`, with higher priority than the existing
`jekyll-ingressroute`:

```text
Host(`blog.devinflake.com`) && PathPrefix(`/post/api`) -> blog-cms-api:8080
Host(`blog.devinflake.com`)                          -> jekyll-website:80
```

The existing HTTP-to-HTTPS redirect already covers the path. TLS continues to
use `certResolver: letsencrypt`; no new certificate is needed.

### GitHub identities

Three GitHub Apps keep role enforcement at the token level:

| App | Repository permissions | Used for |
|---|---|---|
| `cms-writer` | Ephesus: Contents read/write, Pull requests read/write | Guest and admin draft commits and PR creation. Cannot merge. |
| `cms-publisher` | Ephesus: Contents read/write, Pull requests read/write | Admin Publish and admin approval of guest PRs. |
| `cms-approver` | `raspberry-pi-dramble`: Contents read/write, Pull requests read/write | Approves and merges the bump PR created by the existing Ephesus workflow. |

A separate approver identity is required because
`raspberry-pi-dramble/dev` has branch protection with one approving review;
the app that creates a PR cannot be relied on to approve its own PR.

App private keys, the admin and guest password hashes, and the session signing
key are stored as SealedSecrets in `cluster/secrets/sealed/`. The existing
`DRAMBLE_BUMP_TOKEN` remains an Ephesus Actions secret. No plaintext credential
is written to git or to a container image.

### Publishing pipeline

The existing Ephesus `publish.yml` already builds the tagged image, smoke-tests
it, and opens the bump PR. The webapp plugs into it rather than replacing it:

1. Editor saves a draft to `_drafts/` on `cms/<slug>`.
2. Preview shows the rendered post with **Save for later** and either
   **Publish** (admin) or **Submit for review** (guest).
3. Admin Publish merges the Ephesus PR with `cms-publisher`. Guest submit only
   opens the PR; admin later clicks Approve in the review queue.
4. The merge to Ephesus `master` triggers the existing image build and bump PR.
5. `cms-approver` approves and merges the bump PR into
   `raspberry-pi-dramble/dev`.
6. Argo CD syncs `jekyll-website` to the new `sha-<7>` tag; the three blog pods
   roll over within a few minutes.

Notifications can reuse the existing sealed ntfy topic on guest submission and
on successful publish.

## Files to add or change

### Ephesus

- `_pages/post.md` (new) — editor/preview/review page.
- `assets/js/post-editor.js` (new), `assets/css/style.css` (extend).
- `.github/workflows/publish.yml` — add `_pages/**` to the path filter.
- `README.md` / `CONTRIBUTING.md` — document the `/post/` editor.

### raspberry-pi-dramble

- `services/blog-cms-api/` (new) — API source, tests, Dockerfile and README.
- `cluster/namespaces.yaml` — add namespace `blog-cms`.
- `cluster/workloads/blog-cms-api/` (new) — Deployment, Service, Kustomization.
- `gitops/apps/blog-cms-api/application.yaml` (new) — project `dramble`,
  automated prune/selfHeal, `CreateNamespace=false`, sync wave `1`.
- `gitops/kustomization.yaml` — add the explicit Application resource.
- `cluster/traefik/ingressroutes.yaml` — add the `/post/api` route.
- `cluster/networkpolicies/ingress.yaml` — allow `traefik` and node IPs into
  `blog-cms`.
- `cluster/poddisruptionbudgets/pdbs.yaml` — PDB for two API replicas.
- `cluster/secrets/sealed/` (new sealed manifests), `cluster/secrets/examples/`
  (templates), `docs/secrets.md`, `docs/architecture.md`,
  `docs/blog-rebuild.md`, `docs/gitops.md`, `gitops/apps/README.md`,
  `cluster/workloads/README.md`, `scripts/verify-docs.sh`.
- `.github/workflows/build-blog-cms.yml` (new) — test and publish the API image
  to GHCR. The deployment PR pins the resulting `sha-<7>` tag.

See [architecture.md](architecture.md) for the current route/workload tables,
[gitops.md](gitops.md) for Argo sync rules, and [secrets.md](secrets.md) for the
SealedSecret workflow.

## Security notes

- Reusing the unified admin password for the public CMS couples the two
  systems: rotating the cluster password must also rotate the CMS hash. It also
  exposes a cluster administrator credential at a public login form. Rate
  limiting, CSRF protection, constant-time bcrypt verification and no token in
  browser storage are mandatory mitigations.
- The guest password is shared by design, so it can spread beyond the intended
  authors. Treat guest as an untrusted role: the admin review queue is the
  control. Add per-IP rate limiting and a honeypot field in Phase 1, and consider
  CAPTCHA or per-author accounts later. The plaintext will be supplied
  out-of-band, hashed, and sealed before deployment; rotate it like any shared
  credential.
- The API must never receive or return a GitHub token to the browser. All
  GitHub calls happen server-side with the short-lived App installation token.
- `cluster/workloads/jekyll/deployment.yaml` remains the only image tag source
  of truth; `scripts/verify-docs.sh` must be extended to check the new API image
  tag as well.

## Phases

1. **Phase 1 — MVP:** auth, editor, preview page, draft branches, PR creation,
   admin review queue, admin publish, guest submit, fully automatic bump PR,
   manifests, SealedSecrets, CI build and docs.
2. **Phase 2 — polish:** Jekyll-built preview URLs from draft branches, image
   uploads, ntfy notifications, audit UI, stronger guest controls.

Acceptance for Phase 1: an admin can log in with the unified password, write a
post at `/post/`, preview it, and publish it without leaving the browser; a
guest can log in with the shared guest password, submit a post and see it
pending; admin approves it in the same UI; both paths result in a new `sha-<7>`
blog image and a live blog update a few minutes later.
