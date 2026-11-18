#!/usr/bin/env bash
# Check every version pin in this repository — and Ephesus, if it is checked
# out alongside — against its upstream source, and report what is newer.
#
# Usage:
#   scripts/check-updates.sh
#
# Exit codes:
#   0  every pin is current
#   1  at least one update is available, OR one is blocked by a compatibility
#      constraint (still actionable: the blocker has to move first)
#   2  at least one check could not run (network / API failure)
#      — distinct from 1 on purpose: "we could not tell" must never look like
#        "nothing to do".
#
# Pins are read from the files that declare them (scripts/install-addons.sh,
# gitops/bootstrap/values.yaml, the manifests), never restated here, so this
# script cannot drift from what it is checking. Same principle as CI's
# single-sourcing of chart versions.
#
# Deliberately NOT a merge gate: it needs the network, and a flaky upstream
# must not block a pull request. Wire it into a scheduled workflow that opens
# an issue instead.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

# Where Ephesus is checked out. Defaults to the sibling directory locally;
# CI checks it out inside the workspace instead and points this at it, because
# a workflow cannot write outside GITHUB_WORKSPACE.
EPHESUS_DIR="${EPHESUS_DIR:-../Ephesus}"

UPDATES=0
ERRORS=0
BLOCKED=0
CHECKS=0

# --- reporting -------------------------------------------------------------
row() { # status label detail
  printf '  %-9s %-34s %s\n' "$1" "$2" "$3"
  CHECKS=$((CHECKS + 1))
  case "$1" in
    update)  UPDATES=$((UPDATES + 1)) ;;
    blocked) BLOCKED=$((BLOCKED + 1)) ;;
    error)   ERRORS=$((ERRORS + 1)) ;;
  esac
}

# True if $1 is a higher version than $2 (numeric dot-separated segments).
newer() {
  python3 - "$1" "$2" <<'PY'
import sys
def parts(v):
    out = []
    for seg in v.strip().lstrip('v').split('.'):
        num = ''.join(c for c in seg if c.isdigit())
        out.append(int(num) if num else 0)
    return out
a, b = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(a), len(b))
a += [0] * (n - len(a)); b += [0] * (n - len(b))
sys.exit(0 if a > b else 1)
PY
}

# The highest Kubernetes minor the INSTALLED Longhorn version was tested
# against, read from the compatibility table in docs/upgrade.md (section B2)
# rather than hardcoded — so it stays correct when Longhorn is upgraded.
#
# This matters: k3s 1.37.2 is newer than our pin, but Longhorn 1.13.x is only
# tested on 1.33–1.36, so taking it now would put the storage layer outside
# its supported range. Reporting that as a plain "update available" would be
# actively misleading.
max_k8s_for_longhorn() { # $1 = installed longhorn version
  python3 - "$1" <<'PY'
import re, sys

installed = sys.argv[1].lstrip('v')
doc = open('docs/upgrade.md', encoding='utf-8').read()

def matches(pattern, version):
    """'1.13.x' matches '1.13.0'; '1.9.2' matches only itself."""
    p = [s for s in pattern.strip().split('.')]
    v = [s for s in version.split('.')]
    if len(p) != len(v):
        return False
    return all(seg == 'x' or seg == ver for seg, ver in zip(p, v))

best = None
for line in doc.splitlines():
    # rows look like: | 1.12.x, 1.13.x | 1.33–1.36 |
    m = re.match(r'\|\s*([\d.,\sx]+?)\s*\|\s*([\d.]+)[–-]([\d.]+)\s*\|', line)
    if not m:
        continue
    if any(matches(pat, installed) for pat in m.group(1).split(',')):
        top = int(m.group(3).split('.')[1])       # minor of the upper bound
        best = top if best is None else max(best, top)

if best is None:
    # The table is explicitly "verified anchors, not the full path", so a
    # missing row is unknown rather than unconstrained. Returning nothing here
    # would silently drop the guard the moment Longhorn is upgraded past the
    # last documented version — printing a sentinel lets check_k3s report it.
    print('unknown')
    sys.exit(0)
print(best)
PY
}

# The same bound for Argo CD, read from docs/gitops.md's prerequisite section.
# Argo CD 3.6 is tested against Kubernetes 1.34-1.37, so today Longhorn binds
# first (1.36) - but once Longhorn moves past 1.37 this becomes the ceiling
# instead, which is exactly the sort of constraint that gets forgotten.
max_k8s_for_argocd() { # $1 = argo-cd chart version (unused today, kept for the message)
  python3 - <<'PY'
import re, sys
doc = open('docs/gitops.md', encoding='utf-8').read()
m = re.search(r'tested against\s+Kubernetes\s+\*\*([\d.]+)[–-]([\d.]+)\*\*', doc)
if not m:
    sys.exit(1)
print(int(m.group(2).split('.')[1]))            # minor of the upper bound
PY
}

# Every installed component that limits which Kubernetes minors we may run.
# Prints "<label>|<max minor>" per line; add a new provider here, not in
# check_k3s. The strictest (lowest) ceiling wins.
k8s_constraints() {
  local minor label
  for spec in "Longhorn ${LONGHORN:-unknown}:$(max_k8s_for_longhorn "${LONGHORN:-}" 2>/dev/null || true)" \
              "Argo CD ${ARGOCD:-unknown}:$(max_k8s_for_argocd 2>/dev/null || true)"; do
    label=${spec%%:*}
    minor=${spec##*:}
    [ -n "$minor" ] || continue
    printf '%s|%s\n' "$label" "$minor"
  done
}

# Docker Hub's API wants `library/` for official images and no `docker.io/`
# prefix for anything else. Getting this wrong is a silent 404.
hub_path() {
  local img=${1#docker.io/}
  case "$img" in
    */*) printf '%s' "$img" ;;
    *)   printf 'library/%s' "$img" ;;
  esac
}

# --- checkers --------------------------------------------------------------
check_helm() { # label index_url chart current
  local label=$1 index=$2 chart=$3 current=$4 latest
  latest=$(curl -fsSL --max-time 25 "$index" 2>/dev/null | python3 -c "
import sys, yaml
try:
    e = yaml.safe_load(sys.stdin)['entries']['$chart']
    print(e[0]['version'])          # entries are newest-first
except Exception:
    sys.exit(1)
") || { row error "$label" "could not read chart index"; return; }
  if newer "$latest" "$current"; then
    row update "$label" "$current -> $latest"
  elif [ "$latest" = "$current" ]; then
    row ok "$label" "$current (current)"
  else
    row ok "$label" "$current (latest is $latest — pin is ahead, check why)"
  fi
}

check_release() { # label github_repo current
  local label=$1 repo=$2 current=$3 latest
  latest=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null) \
    || { row error "$label" "could not read $repo releases"; return; }
  latest=${latest#v}
  if newer "$latest" "$current"; then
    row update "$label" "$current -> $latest"
  elif [ "$latest" = "$current" ]; then
    row ok "$label" "$current (current)"
  else
    row ok "$label" "$current (latest is $latest)"
  fi
}

check_image() { # label image current
  local label=$1 image=$2 current=$3 latest path
  path=$(hub_path "$image")
  # newest tag that looks like a plain version, by last_updated
  latest=$(curl -fsSL --max-time 25 \
    "https://hub.docker.com/v2/repositories/$path/tags?page_size=100&ordering=last_updated" \
    2>/dev/null | python3 -c "
import sys, json, re
try:
    tags = [t['name'] for t in json.load(sys.stdin).get('results', [])]
    vers = [t for t in tags if re.fullmatch(r'v?\d+(\.\d+)*', t)]
    if vers:
        vers.sort(key=lambda t: [int(x) for x in t.lstrip('v').split('.')])
        print(vers[-1])
except Exception:
    pass
" 2>/dev/null) || true
  if [ -z "$latest" ]; then
    row error "$label" "could not read tags for $path"
  elif newer "$latest" "$current"; then
    row update "$label" "$current -> $latest"
  elif [ "$latest" = "$current" ]; then
    row ok "$label" "$current (current)"
  else
    row ok "$label" "$current (latest version tag is $latest)"
  fi
}

check_k3s() { # current
  local current=$1 latest minor ceiling="" binding=""
  # /channels/stable answers 302 -> HTML; the collection endpoint is JSON.
  latest=$(curl -fsSL --max-time 25 https://update.k3s.io/v1-release/channels 2>/dev/null \
    | python3 -c "
import sys, json
for c in json.load(sys.stdin).get('data', []):
    if c.get('id') == 'stable':
        print(c['latest']); break
" 2>/dev/null) || { row error "k3s (stable channel)" "could not read channel"; return; }
  latest=${latest%%+*}          # v1.37.2+k3s1 -> v1.37.2
  minor=$(printf '%s' "$latest" | cut -d. -f2)

  # The strictest ceiling across every installed component wins. Process
  # substitution, not a pipe — the loop must set ceiling/binding in this shell.
  while IFS='|' read -r label bound; do
    [ -n "${bound:-}" ] || continue
    if ! printf '%s' "$bound" | grep -qE '^[0-9]+$'; then
      # Unknown beats silently unconstrained: without a tested-range row we
      # cannot say the next minor is safe, so report it rather than skip it.
      row error "k3s (stable channel)" "no tested-range row for ${label} — update docs/upgrade.md B2"
      return
    fi
    if [ -z "$ceiling" ] || [ "$bound" -lt "$ceiling" ]; then
      ceiling=$bound
      binding=$label
    fi
  done < <(k8s_constraints)

  if [ -n "$ceiling" ] && [ -n "$minor" ] && [ "$minor" -gt "$ceiling" ] 2>/dev/null; then
    row blocked "k3s (stable channel)" \
      "$current -> $latest  BLOCKED: ${binding} tested only to 1.${ceiling}"
    return
  fi

  if newer "$latest" "$current"; then
    row update "k3s (stable channel)" "$current -> $latest"
  else
    row ok "k3s (stable channel)" "$current (current)"
  fi
}

# The check CI does not have: a version variable and the vendored file that
# embeds it must agree, or the rebuild path breaks at exactly the wrong moment.
check_filename() { # label version filepath_glob
  local label=$1 version=$2 pattern=$3 found
  found=$(find "$(dirname "$pattern")" -maxdepth 1 -name "$(basename "$pattern")" 2>/dev/null | head -1)
  if [ -z "$found" ]; then
    row error "$label" "no file matches $pattern"
  elif printf '%s' "$found" | grep -qF "$version"; then
    row ok "$label" "$version matches $(basename "$found")"
  else
    row update "$label" "var=$version but file is $(basename "$found")"
  fi
}

# Action refs: a major tag (v7) floats to the latest v7.x, and a branch or SHA
# is pinned on purpose — neither is an available update. Only compare refs that
# are full versions.
check_action() { # ref  (owner/repo@ref)
  local ref=$1 action=${1%@*} cur=${1##*@} latest
  if ! printf '%s' "$cur" | grep -qE '^v?[0-9]+\.[0-9]+'; then
    row ok "action $action" "$cur (branch or major tag — floats by design)"
    return
  fi
  latest=$(gh api "repos/$action/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")
  if [ -z "$latest" ]; then
    row error "action $action" "could not read releases"
  elif newer "${latest#v}" "${cur#v}"; then
    row update "action $action" "$cur -> $latest"
  else
    row ok "action $action" "$cur (current)"
  fi
}

# =============================================================================
echo "== charts and manifests (scripts/install-addons.sh) =="

TRAEFIK=$(grep -oE '^TRAEFIK_CHART_VERSION=[0-9.]+' scripts/install-addons.sh | cut -d= -f2)
PROM=$(grep -oE '^PROMETHEUS_CHART_VERSION=[0-9.]+' scripts/install-addons.sh | cut -d= -f2)
GRAFANA=$(grep -oE '^GRAFANA_CHART_VERSION=[0-9.]+' scripts/install-addons.sh | cut -d= -f2)
LONGHORN=$(grep -oE '^LONGHORN_VERSION=[0-9.]+' scripts/install-addons.sh | cut -d= -f2)
METALLB=$(grep -oE '^METALLB_VERSION=[0-9.]+' scripts/install-addons.sh | cut -d= -f2)
# The version sits in a markdown-quoted header, so match the digits after it
# rather than the backticks — quoting them trips shellcheck's SC2016.
ARGOCD=$(grep -oE 'chart .argo-cd. [0-9.]+' gitops/bootstrap/values.yaml | grep -oE '[0-9.]+$')

check_helm "traefik chart"     https://traefik.github.io/charts/index.yaml              traefik     "${TRAEFIK:-missing}"
check_helm "prometheus chart"  https://prometheus-community.github.io/helm-charts/index.yaml prometheus "${PROM:-missing}"
check_helm "grafana chart"     https://grafana-community.github.io/helm-charts/index.yaml    grafana    "${GRAFANA:-missing}"
check_helm "argo-cd chart"     https://argoproj.github.io/argo-helm/index.yaml           argo-cd     "${ARGOCD:-missing}"
check_release "Longhorn"       longhorn/longhorn   "${LONGHORN:-missing}"
check_release "MetalLB"        metallb/metallb     "${METALLB:-missing}"
# The k3s version is documented as `v1.36.6+k3s1` in a table cell — there are
# words between "k3s" and the version, so match the version itself rather than
# a prefix, and avoid quoting backticks (shellcheck SC2016).
K3S_CURRENT=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' docs/architecture.md | head -1 | sed 's/^v//; s/+.*//')
check_k3s "${K3S_CURRENT:-missing}"

echo "== vendored filenames vs their version variable =="
check_filename "longhorn manifest" "${LONGHORN:-missing}" "cluster/longhorn/longhorn-v*.yaml"
check_filename "metallb manifest"  "${METALLB:-missing}"  "cluster/metallb/metallb-v*.yaml"

echo "== container images pinned in manifests =="
# flakeman2/jekyll:sha-* is deliberately excluded: the Ephesus pipeline sets it.
# Process substitution, not a pipe: `cmd | while` runs the loop in a subshell
# and the counters would silently reset to zero.
while read -r image; do
  [ -n "$image" ] || continue
  check_image "${image%%:*}" "${image%%:*}" "${image##*:}"
done < <(grep -rhoE 'image: (nginx|traefik/whoami|curlimages/curl|busybox|docker\.io/bitnami/sealed-secrets-controller):[^ "]+' cluster/ gitops/ \
  | sed 's/^image: //' | sort -u)

echo "== GitHub Actions =="
while read -r ref; do
  [ -n "$ref" ] || continue
  check_action "$ref"
done < <(grep -rhoE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[^ ]+' .github/workflows/ \
  | sed 's/uses: //' | grep -v 'docker://' | sort -u)

# =============================================================================
if [ -d "$EPHESUS_DIR" ]; then
  echo "== Ephesus ($EPHESUS_DIR) =="
  while read -r image; do
    [ -n "$image" ] || continue
    check_image "${image%%:*}" "${image%%:*}" "${image##*:}"
  done < <(grep -E '^FROM ' "$EPHESUS_DIR/Dockerfile" \
    | sed -E 's/^FROM( --platform=[^ ]+)? //; s/ AS .*//' | sort -u)
  for gem in jekyll rouge; do
    cur=$(grep -oE "^    $gem \([0-9.]+\)" "$EPHESUS_DIR/Gemfile.lock" | grep -oE '[0-9.]+' | head -1)
    latest=$(curl -fsSL --max-time 20 "https://rubygems.org/api/v1/versions/$gem/latest.json" 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "")
    if [ -z "$latest" ] || [ -z "$cur" ]; then
      row error "gem $gem" "could not determine version"
    elif newer "$latest" "$cur"; then
      row update "gem $gem" "$cur -> $latest"
    else
      row ok "gem $gem" "$cur (current)"
    fi
  done
fi

# =============================================================================
echo
echo "checks: $CHECKS   updates: $UPDATES   blocked: $BLOCKED   errors: $ERRORS"
if [ "$ERRORS" -gt 0 ]; then
  echo "RESULT: could not verify everything — treat as unknown, not as current."
  exit 2
elif [ "$BLOCKED" -gt 0 ]; then
  echo "RESULT: a newer version exists but a compatibility constraint blocks it."
  echo "        Upgrade the blocker first — see docs/upgrade.md B2."
  exit 1
elif [ "$UPDATES" -gt 0 ]; then
  echo "RESULT: updates available."
  exit 1
fi
echo "RESULT: everything current."
exit 0
