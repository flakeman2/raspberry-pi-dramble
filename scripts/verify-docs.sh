#!/usr/bin/env bash
# Assert that what the docs CLAIM matches what the cluster ACTUALLY does.
#
# This needs a kubeconfig, so it is deliberately NOT a CI job: CI must not hold
# cluster credentials (docs/gitops.md#ci-gates). Run it locally instead:
#
#   export KUBECONFIG=~/.kube/config-dramble-k3s
#   ./scripts/verify-docs.sh              # everything
#   ./scripts/verify-docs.sh --skip-certs # skip the per-hostname TLS probe
#
# The static half — links, in-page and cross-file anchors, reference links —
# needs no cluster and runs in CI via scripts/check-docs.py.
#
# Exits 0 only if every check passes.

set -euo pipefail
cd "$(dirname "$0")/.."

: "${KUBECONFIG:?set KUBECONFIG to the cluster kubeconfig}"

SKIP_CERTS=0
[ "${1:-}" = "--skip-certs" ] && SKIP_CERTS=1

PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }

count() { kubectl get "$1" -A --no-headers 2>/dev/null | grep -c . || true; }

# Job-owned pods (CronJob and Job output) come and go with
# successfulJobsHistoryLimit, so an exact TOTAL pod count is inherently
# unstable — it drifts every time a scheduled job runs and its predecessor is
# evicted. That is what made this check fail at 66 vs 65 with no real change:
# the workload count had been 64 the whole time. Assert on workload pods.
count_workload_pods() {
  kubectl get pods -A -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(sum(1 for p in d['items']
          if not any(o.get('kind') == 'Job'
                     for o in (p['metadata'].get('ownerReferences') or []))))
"
}

echo "== 1. cluster-status.md totals vs live =="
# shellcheck disable=SC2016
DOC_TOTALS=$(python3 - <<'PY'
import re
doc = open('docs/cluster-status.md').read()
m = re.search(
    r'Totals: \*\*(\d+) pods\*\*, (\d+) namespaces, (\d+) Deployments, (\d+) DaemonSets, (\d+)\n'
    r'StatefulSets, (\d+) CronJobs, (\d+) Services, (\d+) IngressRoutes, (\d+) Middlewares, (\d+)\n'
    r'TLSOption, (\d+) PDBs, (\d+) NetworkPolicies', doc)
keys = ['pods','namespaces','Deployments','DaemonSets','StatefulSets','CronJobs',
        'Services','IngressRoutes','Middlewares','TLSOption','PDBs','NetworkPolicies']
if not m:
    print('PARSE_ERROR')
else:
    print('\n'.join(f'{k}={v}' for k, v in zip(keys, map(int, m.groups()))))
PY
)
if [ "$DOC_TOTALS" = "PARSE_ERROR" ] || [ -z "$DOC_TOTALS" ]; then
  fail "could not parse the Totals line in docs/cluster-status.md"
else
  declare -A LIVE=(
    [pods]="$(count_workload_pods)"
    [namespaces]="$(count ns)"
    [Deployments]="$(count deploy)"
    [DaemonSets]="$(count ds)"
    [StatefulSets]="$(count sts)"
    [CronJobs]="$(count cronjob)"
    [Services]="$(count svc)"
    [IngressRoutes]="$(count ingressroute)"
    [Middlewares]="$(count middleware)"
    [TLSOption]="$(count tlsoption)"
    [PDBs]="$(count pdb)"
    [NetworkPolicies]="$(count netpol)"
  )
  while IFS='=' read -r key want; do
    got="${LIVE[$key]:-?}"
    if [ "$want" = "$got" ]; then
      pass "totals: $key = $got"
    else
      fail "totals: $key doc=$want live=$got"
    fi
  done <<< "$DOC_TOTALS"
fi

echo "== 2. documented hostnames vs the manifests =="
if python3 - <<'PY'
import re, sys, pathlib
manifest_names = set()
for p in list(pathlib.Path('cluster').rglob('*.yaml')) + list(pathlib.Path('gitops').rglob('*.yaml')):
    manifest_names |= set(re.findall(r'Host\(`([^`]+)`\)', p.read_text(errors='replace')))
tbl = pathlib.Path('docs/architecture.md').read_text()
section = tbl.split('### Domains and routes')[1].split('\n###')[0]
table_names = set(re.findall(r'`([a-z0-9.-]+\.com)`', section))
# the whoami row reuses the apex hosts, so the table may legitimately name them
if manifest_names != table_names:
    print(f'    only in manifests: {sorted(manifest_names - table_names) or "none"}')
    print(f'    only in table    : {sorted(table_names - manifest_names) or "none"}')
    sys.exit(1)
print(f'    {len(manifest_names)} names, both sides identical')
PY
then
  pass "routing table covers exactly the Host() names in the manifests"
else
  fail "routing table and manifests disagree on hostnames"
fi

echo "== 3. every hostname serves a valid Let's Encrypt cert =="
if [ "$SKIP_CERTS" = 1 ]; then
  echo "  SKIP  (--skip-certs)"
else
  HOSTNAMES=$(grep -rhoE 'Host\([^)]*\)' cluster gitops 2>/dev/null \
    | tr -d '`' | sed -E 's/^Host\(//; s/\)$//' | sort -u)
  TOTAL=0
  GOOD=0
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    TOTAL=$((TOTAL + 1))
    if CERT=$(echo | timeout 6 openssl s_client -connect "$host:443" -servername "$host" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null) \
       && printf '%s' "$CERT" | grep -qi "Let's Encrypt"; then
      GOOD=$((GOOD + 1))
    else
      fail "cert: $host is not serving a Let's Encrypt certificate"
    fi
  done <<< "$HOSTNAMES"
  [ "$GOOD" = "$TOTAL" ] && pass "certs: $GOOD/$TOTAL hostnames on valid Let's Encrypt certificates"
fi

echo "== 4. documented chart versions vs live releases =="
if python3 - <<'PY'
import re, subprocess, sys
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=False).stdout

# pins from the install script / bootstrap values (the same source CI uses)
pins = {}
for line in open('scripts/install-addons.sh'):
    m = re.match(r'([A-Z_]+_CHART_VERSION)=([0-9.]+)', line)
    if m: pins[m.group(1)] = m.group(2)
argocd = re.search(r'chart `argo-cd` ([0-9.]+)', open('gitops/bootstrap/values.yaml').read())
if argocd: pins['ARGOCD_CHART_VERSION'] = argocd.group(1)

want = {
    'traefik':    pins.get('TRAEFIK_CHART_VERSION'),
    'prometheus': pins.get('PROMETHEUS_CHART_VERSION'),
    'grafana':    pins.get('GRAFANA_CHART_VERSION'),
    'argocd':     pins.get('ARGOCD_CHART_VERSION'),
}
# `helm ls -A --no-headers` is tab-separated but each field is padded with
# trailing spaces, which breaks a `$`-anchored regex — strip first.
#   name ns revision updated status chart appversion   -> chart is field 5
out = sh('helm', 'ls', '-A', '--no-headers')
live = {}
for line in out.splitlines():
    parts = [p.strip() for p in line.split('\t')]
    if len(parts) >= 6:
        m = re.search(r'-(\d+\.\d+\.\d+)$', parts[5])
        if m: live[parts[0]] = m.group(1)

bad = 0
for name, version in want.items():
    got = live.get(name)
    if version is None:
        print(f'  FAIL  versions: no pin found for {name}')
        bad += 1
    elif got == version:
        print(f'  PASS  versions: {name} = {version}')
    else:
        print(f'  FAIL  versions: {name} doc={version} live={got}')
        bad += 1
sys.exit(1 if bad else 0)
PY
then
  pass "versions: all four chart pins match the live releases"
else
  fail "versions: a documented pin does not match the live release"
fi

echo "== 5. addon Application chart pins vs scripts/install-addons.sh =="
# Chart versions are now declared in two places: the install script (the
# bootstrap path) and each Application's targetRevision (the GitOps path).
# Neither is derived from the other, so nothing stops a bump from updating
# one and silently leaving the other behind — and check 4 above would only
# notice once the cluster had already moved. Assert the two agree here, where
# the failure is still a PR rather than a surprise.
if python3 - <<'PY'
import glob, re, sys, yaml

pins = {}
for line in open('scripts/install-addons.sh'):
    m = re.match(r'([A-Z_]+)_CHART_VERSION=([0-9.]+)', line)
    if m:
        pins[m.group(1)] = m.group(2)

# chart name -> the install script's variable
name_map = {'traefik': 'TRAEFIK', 'prometheus': 'PROMETHEUS', 'grafana': 'GRAFANA'}

bad = 0
found = 0
for path in sorted(glob.glob('gitops/addons/*/application.yaml')):
    doc = yaml.safe_load(open(path))
    spec = doc.get('spec', {})
    sources = spec.get('sources') or ([spec.get('source')] if spec.get('source') else [])
    for src in sources:
        chart = (src or {}).get('chart')
        if not chart:
            continue  # path-based Application, no chart pin to compare
        found += 1
        var = name_map.get(chart.lower())
        want = pins.get(var)
        got = src.get('targetRevision')
        if want is None:
            print(f'  FAIL  pins: {path} chart {chart} has no *_CHART_VERSION in install-addons.sh')
            bad += 1
        elif got == want:
            print(f'  PASS  pins: {path} chart {chart} = {got}')
        else:
            print(f'  FAIL  pins: {path} chart {chart} Application={got} install-addons.sh={want}')
            bad += 1

if found == 0:
    print('  FAIL  pins: no Helm-source Application found under gitops/addons/')
    bad += 1

sys.exit(1 if bad else 0)
PY
then
  pass "pins: every addon Application chart pin matches install-addons.sh"
else
  fail "pins: an Application chart pin disagrees with install-addons.sh"
fi

echo "== 6. SealedSecrets are all synced =="
# `get sealedsecret` shows only ns/name/age — the Synced condition needs
# custom-columns, otherwise $NF is the age and everything looks unsynced.
SS_STATE=$(kubectl get sealedsecret -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SYNCED:.status.conditions[?(@.type=="Synced")].status' \
  --no-headers 2>/dev/null || true)
TOTAL_SS=$(printf '%s\n' "$SS_STATE" | grep -c . || true)
UNSYNCED=$(printf '%s\n' "$SS_STATE" | awk '$3 != "True" {print $1"/"$2}' | tr '\n' ' ')
if [ -n "${SS_STATE// /}" ] && [ -z "${UNSYNCED// /}" ]; then
  pass "sealed: $TOTAL_SS/$TOTAL_SS SealedSecrets Synced=True"
else
  fail "sealed: ${TOTAL_SS:-0} found, not synced -> ${UNSYNCED:-none}"
fi

echo "== 7. image tags in manifests vs live deployments =="
if python3 - <<'PY'
import re, pathlib, subprocess, sys
def live_image(ns, name):
    out = subprocess.run(
        ['kubectl','-n',ns,'get','deploy',name,
         '-o','jsonpath={.spec.template.spec.containers[0].image}'],
        capture_output=True, text=True).stdout.strip()
    return out

bad = 0
checked = 0
for dep in pathlib.Path('cluster/workloads').rglob('deployment.yaml'):
    text = dep.read_text()
    ns = re.search(r'namespace:\s*(\S+)', text)
    name = re.search(r'^\s*name:\s*(\S+)', text, re.M)
    img = re.search(r'image:\s*(\S+)', text)
    if not (ns and name and img):
        continue
    ns, name, img = ns.group(1), name.group(1), img.group(1)
    got = live_image(ns, name)
    checked += 1
    if got == img:
        print(f'  PASS  image: {ns}/{name} = {img}')
    else:
        print(f'  FAIL  image: {ns}/{name} git={img} live={got}')
        bad += 1
if checked == 0:
    print('  FAIL  image: no deployments found under cluster/workloads/')
    bad += 1
sys.exit(1 if bad else 0)
PY
then
  pass "images: every manifest tag matches the live deployment"
else
  fail "images: a manifest tag does not match the live deployment"
fi

echo "== 8. Argo CD tracks the repository default branch =="
# Repointing Argo by hand is exactly the kind of manual change that silently
# drifts from the documented branching model, so assert the two agree.
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)
if [ -z "$DEFAULT_BRANCH" ] && command -v gh >/dev/null; then
  DEFAULT_BRANCH=$(gh repo view flakeman2/raspberry-pi-dramble \
    --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
fi
TARGET=$(kubectl get applications.argoproj.io -n argocd \
  -o jsonpath='{.items[0].spec.source.targetRevision}' 2>/dev/null || true)
if [ -z "$DEFAULT_BRANCH" ]; then
  fail "argocd: could not determine the default branch (set origin/HEAD or install gh)"
elif [ -z "$TARGET" ]; then
  fail "argocd: no Application found to check"
elif [ "$TARGET" = "$DEFAULT_BRANCH" ]; then
  pass "argocd: targetRevision=$TARGET matches the default branch"
else
  fail "argocd: targetRevision=$TARGET but the default branch is $DEFAULT_BRANCH"
fi

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "docs and cluster disagree — fix the docs or the cluster, then re-run."
  exit 1
fi
echo "docs match the live cluster."
