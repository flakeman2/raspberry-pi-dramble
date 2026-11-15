# Rebuilding the blog and the landing page

**Status:** verified 2026-11-14 against the live cluster. Nothing on this page
has been executed against the cluster; the rebuild was reproduced in a scratch
directory and diffed against the running image.

Both sites are rebuildable from source. The blog source lives in a *different*
repository, which is the main thing to know about.

| Site | Served by | Source | Rebuildable? |
|---|---|---|---|
| `blog.devinflake.com` | `flakeman2/jekyll:1.0.5`, content baked into the image (no volume) | [`flakeman2/Ephesus`](https://github.com/flakeman2/Ephesus) | Yes — Dockerfile, all 5 posts, full history |
| `devinflake.com` / `flakeman2.com` | `nginx:latest` + the `mysite-content` PVC | this repo, `cluster/workloads/mysite/content/` | Yes — no build step at all |

## Blog source

`https://github.com/flakeman2/Ephesus` — public, a fork of
[`onepase/Ephesus`](https://github.com/onepase/Ephesus) (the theme, still
maintained). It is the site source, not just the theme:

- `_posts/` — all five posts, as markdown, with their front matter:
  `2022-01-22-Hello-devinflake_com.md`, `2022-01-23-raspberry-pi.md`,
  `2022-01-24-taking_the_cka.md`, `2022-02-04-passing_the_cka.md`,
  `2026-11-14-dramble-cleanup-and-plan.md`
- `_config.yml`, `_layouts/`, `_includes/`, `assets/` — theme and configuration
  (Google Analytics, Disqus, `url: https://blog.devinflake.com`)
- `Dockerfile`, `Gemfile`, `Gemfile.lock` — the build
- 27 commits, 2021-09-23 → 2026-11-14, including the upstream theme history.
  Nothing is unpushed (`git log origin/master..master` is empty).

`_site/` is deliberately absent — it is gitignored, and build output is
reproducible. Two older commits briefly committed it (`1b241d9`, `9289e52`);
they are history, not a source of truth.

### Which commit is deployed

**The running image, `1.0.5`, was built from `8a49a1f` — the branch head — on
2026-11-14. Source and cluster agree.**

| Commit | When | Shipped in |
|---|---|---|
| `df1dbaa` | 2022-02-04 | `1.0.4`, built 2022-02-05T02:06:19Z |
| `a5fe7fa` | 2022-02-05T05:37Z | `1.0.5` — sat unshipped for four years |
| `91e0560` | 2026-11-14 | `1.0.5` — the "Dramble: cleanup and a plan" post |
| `8a49a1f` (head) | 2026-11-14 | `1.0.5` — the Dockerfile `--platform` fix |

They did not always match: `1.0.4` was built from `df1dbaa` while the branch had
already moved to `a5fe7fa`, so for four years the deployed site lagged the
source, and building from head produced a visibly different site (extra header
row in `index.html`, different `style.css` layout rules, `Hobbies and Interests`
instead of `Hobbies and interests`). Rebuilding `df1dbaa` reproduces `1.0.4`
exactly — see [Verification](#verification) below. Since `1.0.5`, building from
`master` ships exactly what is deployed.

### Docker image history

`flakeman2/jekyll` on Docker Hub is public, not automated (built by hand):

| Tag | Built | Architectures |
|---|---|---|
| `1.0.2` | 2022-01-25 | amd64 + arm64 |
| `1.0.3` | 2022-01-25 | amd64 + arm64 |
| `1.0.4` | 2022-02-05 | **arm64 only** |
| `1.0.5` (deployed) | 2026-11-14 | **arm64 only** |

Deployed digest:
`sha256:9d3e6c1d27ce8e0bd892559e760fcb308e2e0ac05fc60101e55e6bb3a477ce0d`.
`1.0.5` is an OCI image index — one arm64 manifest plus buildx's provenance
attestation as `unknown/unknown`; the arm64 entry inside it is
`sha256:eeaeb90d77923eac37e07a05fe86bc389fdd3064cd25a51624dbead1a19dd052`.
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
  -t flakeman2/jekyll:1.0.5 --push .
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

## Publishing a post

1. Add `_posts/YYYY-MM-DD-slug.md` in `Ephesus`, commit, push.
2. Build and push a new image tag (above), verifying first.
3. Bump the image tag in `cluster/workloads/jekyll/deployment.yaml`.
4. Follow the branch workflow in the README: commit to `dev`, promote to
   `master` through a pull request.

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
  in `raspberry-pi-dramble` references it except this page.
- **No CI.** `.github/` in `Ephesus` has only issue templates; images are built
  and pushed by hand, which is how the deployed image and its source commit
  drifted apart.
- **Arm64-only image.** Any rebuild needs a cross-build or a Pi.
- **Tag, not digest, in the manifest.** A tag can be moved; pinning the digest
  makes the deployment reproducible.
