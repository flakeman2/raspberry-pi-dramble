# Rebuilding the blog and the landing page

**Status:** verified 2026-11-14, then **rebuilt and re-verified 2026-11-15** as
image `1.0.6`. This page records both: how the source was recovered, and what
the currently deployed image was built from.

Both sites are rebuildable from source. The blog source lives in a *different*
repository, which is the main thing to know about.

| Site | Served by | Source | Rebuildable? |
|---|---|---|---|
| `blog.devinflake.com` | `flakeman2/jekyll:sha-732b174`, content baked into the image (no volume) | [`flakeman2/Ephesus`](https://github.com/flakeman2/Ephesus) | Yes — Dockerfile, all 9 posts, full history |
| `devinflake.com` / `flakeman2.com` | `nginx:latest` + the `mysite-content` PVC | this repo, `cluster/workloads/mysite/content/` | Yes — no build step at all |

## Blog source

`https://github.com/flakeman2/Ephesus` — public, a fork of
[`onepase/Ephesus`](https://github.com/onepase/Ephesus) (the theme, still
maintained). It is the site source, not just the theme:

- `_posts/` — all nine posts, as markdown, with their front matter:
  `2022-01-22-Hello-devinflake_com.md`, `2022-01-23-raspberry-pi.md`,
  `2022-01-24-taking_the_cka.md`, `2022-02-04-passing_the_cka.md`,
  `2026-11-14-dramble-cleanup-and-plan.md`,
  `2026-11-15-dramble-wiped-and-rebuilt.md`,
  `2026-11-17-dramble-gitops-live.md`, `2026-11-17-pr-agent-free-tier.md`,
  `2026-11-21-control-plane-migration.md`
- `_config.yml`, `_layouts/`, `_includes/`, `assets/` — theme and configuration
  (Google Analytics, Disqus, `url: https://blog.devinflake.com`)
- `Dockerfile`, `Gemfile`, `Gemfile.lock` — the build
- 44 commits, 2021-09-23 → 2026-11-21, including the upstream theme history.
  Nothing is unpushed (`git log origin/master..master` is empty).

`_site/` is deliberately absent — it is gitignored, and build output is
reproducible. Two older commits briefly committed it (`1b241d9`, `9289e52`);
they are history, not a source of truth.

### Which commit is deployed

**The running image, `1.0.6`, was built from `f8650e8` — the branch head — and
pushed 2026-11-16T06:10Z. Source and cluster agree.**

From 2026-11-17 the tag carries this on its face: it *is* the source commit
(`sha-<7>`), so the table below stops being necessary for new releases — see
[Publishing a post](#publishing-a-post).

| Commit | When | Shipped in |
|---|---|---|
| `df1dbaa` | 2022-02-04 | `1.0.4`, built 2022-02-05T02:06:19Z |
| `a5fe7fa` | 2022-02-05T05:37Z | `1.0.5` — sat unshipped for four years |
| `91e0560` | 2026-11-14 | `1.0.5` — the "Dramble: cleanup and a plan" post |
| `8a49a1f` | 2026-11-14 | `1.0.5` — the Dockerfile `--platform` fix |
| `f8650e8` (head) | 2026-11-15 | `1.0.6` — "Dramble: wiped and rebuilt" + three photos |

They did not always match: `1.0.4` was built from `df1dbaa` while the branch had
already moved to `a5fe7fa`, so for four years the deployed site lagged the
source, and building from head produced a visibly different site (extra header
row in `index.html`, different `style.css` layout rules, `Hobbies and Interests`
instead of `Hobbies and interests`). Rebuilding `df1dbaa` reproduces `1.0.4`
exactly — see [Verification](#verification) below. Since `1.0.5`, building from
`master` ships exactly what is deployed, and `1.0.6` keeps that rule.

### Docker image history

`flakeman2/jekyll` on Docker Hub is public. Tags through `1.0.6` were built by
hand; **since 2026-11-17 CI publishes them** — see
[Publishing a post](#publishing-a-post):

| Tag | Built | Architectures |
|---|---|---|
| `1.0.2` | 2022-01-25 | amd64 + arm64 |
| `1.0.3` | 2022-01-25 | amd64 + arm64 |
| `1.0.4` | 2022-02-05 | **arm64 only** |
| `1.0.5` | 2026-11-14 | **arm64 only** |
| `1.0.6` (deployed) | 2026-11-15 | **arm64 only** |
| `sha-<7>` (from 2026-11-17) | CI | **arm64 only** |

Deployed digest (`1.0.6`, 15.5 MB):
`sha256:e334741bbc912c4928096161bae95d35512db069cdaf1f868f7fa092f9690bb5`
— an OCI image index holding one arm64 manifest
(`sha256:e25847c0814eae2482159ce82649fa4723ea66c6794663eb5db37f550e0b5be7`)
plus buildx's provenance attestation as `unknown/unknown`. `1.0.5` had the same
shape (`9d3e6c1d…` / `eeaeb90d…`).
The Deployment in `cluster/workloads/jekyll/deployment.yaml` pins the tag, not
the digest.

## The Dockerfile

`Ephesus/Dockerfile`. The only change since 2022-01-23 is the `--platform`
flag on the first line, added 2026-11-14 so that an arm64 build does not have
to compile the gems under qemu emulation:

```dockerfile
FROM --platform=$BUILDPLATFORM ruby:3.1.0-buster AS build
COPY . /Ephesus
WORKDIR /Ephesus
RUN bundle install \
    && jekyll build

FROM nginx:1.21.5-alpine AS final
COPY --from=build /Ephesus/_site /usr/share/nginx/html
```

Jekyll's output is architecture-independent, so the build stage now runs
natively on whatever host does the build while only the final `COPY` stage
targets arm64. The rendered HTML is unaffected — an amd64 build was verified
byte-identical to the arm64 image running in the cluster.

This matches the image config history of `1.0.4`: the last layer is
`COPY /Ephesus/_site /usr/share/nginx/html # buildkit`. `50x.html` in the
served content comes from the nginx base image, not from Jekyll.

## Rebuild

```bash
git clone https://github.com/flakeman2/Ephesus.git
cd Ephesus
git checkout master         # head == deployed; see "Which commit is deployed"

docker buildx build --platform linux/arm64 \
  -t flakeman2/jekyll:sha-732b174 --push .
```

Three things to get right:

- **`--platform linux/arm64`.** Every published tag is arm64-only, so a plain
  `docker build` on an amd64 workstation produces an image the cluster cannot
  schedule (the nodes are aarch64). Cross-build as above, or build on a Pi. The
  Dockerfile pins the *build* stage to `$BUILDPLATFORM`, so only the final
  `COPY` runs emulated — native gem compilation takes seconds where the emulated
  attempt spent 10+ minutes compiling libsass.
- **Keep the `rouge` pin.** `Gemfile.lock` pins Jekyll `4.2.1` and
  `rouge 3.26.1`. Rouge 4.x changes syntax-highlight markup and breaks
  byte-for-byte output in `feed.json` and the post pages. `bundle install`
  inside the Dockerfile honours the lockfile; do not let it float.
- **The base images are EOL** (`ruby:3.1.0-buster`, `nginx:1.21.5-alpine`).
  They still pull, and bumping them will change the served HTML slightly
  (nginx error pages). Do it as a deliberate change, not as a side effect.

## Verification

Diff a rebuild against the running image before deploying it:

```bash
export KUBECONFIG=~/.kube/config-dramble-k3s
POD=$(kubectl -n jekyll get pod -l app=jekyll-website -o jsonpath='{.items[0].metadata.name}')

mkdir -p /tmp/live-blog
kubectl -n jekyll exec "$POD" -- tar cf - -C /usr/share/nginx/html . \
  | tar xf - -C /tmp/live-blog

# after: jekyll build in the source checkout
diff -rq /tmp/live-blog _site
```

Expected differences on a faithful rebuild, and nothing else:

| File | Why it differs |
|---|---|
| every `*.html` (4 lines) | the cache-busting query string on `assets/css/*.css?…`, regenerated from the build time on every build |
| `atom.xml` (1 line) | `<updated>` is the build time |

Verified 2026-11-14: all CSS, JS, images, `feed.json`, `sitemap.xml`,
`robots.txt`, `package*.json` and the post bodies were byte-identical between
`df1dbaa` + rouge 3.26.1 and image `1.0.4`.

After `1.0.5` rolled out the same day, the deployed site was checked end to
end: 3/3 pods on `1.0.5`, 8 sitemap URLs, 5 feed entries, and the new post at
`/dramble_cleanup_and_plan/` returning 200 with the AI disclosure rendered and
no IP addresses in the served HTML.

After `1.0.6` (2026-11-15) the same checks were repeated with one more page:
3/3 pods on `1.0.6`, **9 sitemap URLs**, 6 feed entries,
`/dramble_wiped_and_rebuilt/` → 200 with all three photos fetching, and the
landing page's hero image → 200.

After `sha-732b174` (2026-11-21) the same checks were repeated: 3/3 pods on
`flakeman2/jekyll:sha-732b174`, **12 sitemap URLs**, **9 feed entries**,
`/dramble_control_plane_move/` → 200 with the AI disclosure and all three
self-authored diagrams fetching, and every public name still answering on `.201`.

## Publishing a post

Since 2026-11-17 this is one step, not four — `.github/workflows/publish.yml`
in Ephesus does the rest:

1. Add `_posts/YYYY-MM-DD-slug.md` in `Ephesus`, commit, push to `master`.
2. CI builds `linux/arm64`, **smoke-tests it** (200 homepage, real HTML, at
   least one `<entry>` in the atom feed), pushes
   `flakeman2/jekyll:sha-<7 of the commit>`, and opens the bump PR against
   `raspberry-pi-dramble` with `base: dev`.
3. Merge the bump PR. **Argo CD watches `dev`**, so the blog updates at that
   point — one merge, not two.

The tag *is* the Ephesus commit, so the deployed tag names its own source and
the `1.0.4`/`1.0.5` drift cannot recur. It also means the tag is never reused,
which keeps `imagePullPolicy: IfNotPresent` honest.

Secrets in Ephesus (none grant cluster access): `DOCKERHUB_USERNAME`,
`DOCKERHUB_TOKEN`, and `DRAMBLE_BUMP_TOKEN` — a fine-grained PAT scoped to
`flakeman2/raspberry-pi-dramble` for Contents + Pull requests.

Building by hand still works and remains the fallback — see
[Rebuild](#rebuild) above.

## Landing page (`mysite-content`)

There is nothing to build: `nginx:latest` serves static files from a PVC. The
document root is checked in at `cluster/workloads/mysite/content/`, and it is
**byte-identical to the live PVC** — all 10 files match by md5, 88,877 bytes
total. The PVC is therefore redundant with git; it exists only because the
content was copied there once by hand.

Nothing seeds the PVC on a rebuild, so restore it explicitly:

```bash
kubectl -n mysite-nginx cp cluster/workloads/mysite/content/. \
  deploy/mysite-nginx:/usr/share/nginx/html/
```

See also `cluster/workloads/README.md`.

## Gaps

- **The blog source lives outside this repository.** If `flakeman2/Ephesus` is
  deleted or made private, the blog source and its history go with it. Nothing
  in `raspberry-pi-dramble` references it except this page. **CI does not fix
  this** — it needs a mirror or a backup.
- ~~**No CI.**~~ Resolved 2026-11-17: `.github/workflows/publish.yml` builds,
  verifies, publishes and opens the bump PR (see
  [Publishing a post](#publishing-a-post)). Images were built and pushed by
  hand, which is how the deployed image and its source commit drifted apart.
- **Arm64-only image.** Still arm64-only, but no longer a constraint: the
  Dockerfile pins the build stage to `$BUILDPLATFORM`, so CI compiles the gems
  natively on an amd64 runner and only the final `COPY` targets arm64 — no Pi
  and no cross-build setup.
- **Tag, not digest, in the manifest.** The tag is now content-derived
  (`sha-<7>`), so it names its own source and cannot be quietly repointed at
  different content — but it is still a tag. Pinning the digest would also
  defend against registry-side tampering.
