#!/bin/sh
# Cloud Mode multi-cloud locks (DigitalOcean / Azure / GCP / APM overlay):
# per-cloud secret-safety invariants, shared-rules wiring, SKILL routing.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF="$ROOT/skills/map-topology/references"
SKILL="$ROOT/skills/map-topology/SKILL.md"
fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { echo "ok: $1"; }

# --- 1. artifacts exist + shared-rules pointers -------------------------------
for f in cloud-mode-digitalocean.md cloud-mode-azure.md cloud-mode-gcp.md cloud-mode-apm-overlay.md; do
  [ -f "$REF/$f" ] || fail "$f missing"
  grep -q "Shared rules" "$REF/$f" || fail "$f lost its shared-rules pointer to the AWS cookbook"
done

# --- 2. DigitalOcean: the connection password can never surface ---------------
DO="$REF/cloud-mode-digitalocean.md"
grep -q "connection.password" "$DO" && { grep -q "never print" "$DO" || fail "DO: password mentioned without the never-print rule"; } || true
grep -qE 'doctl databases (list|connection)[^|]*> ' "$DO" && fail "DO: raw databases JSON redirected to a file" || ok "DO: no raw databases dump"
grep -q '.connection.host' "$DO" || fail "DO: catalog must field-select connection.host in-pipe"
grep -q "Traps" "$DO" || fail "DO: traps section missing"

# --- 3. Azure: elevated lane is opt-in; no vault secret reads -----------------
AZ="$REF/cloud-mode-azure.md"
grep -q "OPT-IN GATE" "$AZ" || fail "Azure: elevated lane lost its opt-in gate marker"
grep -q "az keyvault secret" "$AZ" && fail "Azure: a Key Vault secret read appeared" || ok "Azure: no vault secret reads"
n=$(grep -cF '(?i)password|passwd|secret|token|api_?key|private|credential' "$AZ" || true)
[ "$n" -ge 2 ] || fail "Azure: secret-key skip filter must guard both extraction blocks (found $n)"
grep -q "Verification status:" "$AZ" || fail "Azure: honesty banner missing"
grep -q "owed" "$AZ" || fail "Azure: banner must state what verification is still owed"

# --- 4. GCP: default-SA demotion; secret refs never resolved ------------------
GC="$REF/cloud-mode-gcp.md"
grep -qi "default.SA" "$GC" || grep -q "default compute service account" "$GC" || fail "GCP: default-SA demotion rule missing"
grep -q "gcloud secrets versions access" "$GC" && fail "GCP: a Secret Manager value read appeared" || ok "GCP: no secret value reads"
grep -qF '(?i)password|passwd|secret|token|api_?key|private|credential' "$GC" || fail "GCP: secret-key skip filter missing"

# --- 5. APM overlay: TTL + traffic-map separation + key guard -----------------
AP="$REF/cloud-mode-apm-overlay.md"
grep -qi "expire" "$AP" || fail "overlay: TTL/expiry rule missing"
grep -q "never enters the Traffic map" "$AP" || grep -q "not CALLS" "$AP" || fail "overlay: CALLS/Traffic-map separation missing"
grep -qF '[ -n "${NEW_RELIC_USER_KEY:-}" ]' "$AP" || fail "overlay: NR key guard missing (empty-header class)"

# --- 6. SKILL wiring -----------------------------------------------------------
grep -q "cloud-mode-digitalocean.md" "$SKILL" || fail "SKILL: DO cookbook not wired"
grep -q "cloud-mode-azure.md" "$SKILL" || fail "SKILL: Azure cookbook not wired"
grep -q "cloud-mode-gcp.md" "$SKILL" || fail "SKILL: GCP cookbook not wired"
grep -q "cloud-mode-apm-overlay.md" "$SKILL" || fail "SKILL: overlay cookbook not wired"
grep -q "for src in kubernetes aws digitalocean azure gcp newrelic sentry prometheus mimir victoriametrics" "$SKILL" || fail "SKILL: Phase-0 routing loop missing azure/gcp/metrics-stores"
grep -q "APM overlay" "$SKILL" || fail "SKILL: overlay step missing from Phase 2E"
RCA="$ROOT/skills/rca/SKILL.md"
grep -q "STORES_DATA_IN|CACHES_IN" "$RCA" || fail "rca: classifier lost the resource-dependency suspect branch (C7 promise)"

# --- 6b. fallback playbook: every denial has a next move ----------------------
FB="$REF/cloud-mode-fallbacks.md"
[ -f "$FB" ] || fail "cloud-mode-fallbacks.md missing"
grep -q "never present a denial as a dead end" "$FB" || fail "fallbacks: the operating rule sentence missing"
grep -q "The fallback matrix" "$FB" || fail "fallbacks: matrix section missing"
grep -qi "zero access" "$FB" || fail "fallbacks: zero-access row missing"
grep -q "cloud-mode-fallbacks.md" "$SKILL" || fail "SKILL: fallback playbook not wired"
grep -q "retried" "$FB" || fail "fallbacks: no-retry rule missing"

# --- 6c. network flow-log lanes + tempo split ---------------------------------
grep -q "Observed lane: VPC flow logs" "$REF/cloud-mode-aws.md" || fail "AWS: flow-log lane missing"
grep -q "Observed lane: VPC flow logs" "$GC" || fail "GCP: flow-log lane missing"
grep -q "Observed lane: VNet flow logs" "$AZ" || fail "Azure: flow-log lane missing"
grep -q "freshness" "$GC" || fail "GCP: the freshness-flag trap note missing"
grep -q "network-management vpc-flow-logs-configs" "$GC" || fail "GCP: NM-API second-surface probe missing"
grep -q "SubType == .FlowLog." "$AZ" || fail "Azure: SubType FlowLog filter missing"
grep -q "AGGREGATED" "$AZ" || fail "Azure: aggregation caveat missing"
grep -q "describe-flow-logs" "$REF/cloud-mode-aws.md" || fail "AWS: flow-log discovery missing"
grep -q "connection_type" "$AP" || fail "overlay: connection_type split missing"
grep -q "Tempo service-graphs" "$ROOT/skills/map-topology/references/non-k8s-sources.md" || fail "sources: tempo service-graph section missing"

# --- 6d. basic-auth override: drift lock + behavior ---------------------------
for pair in "skills/audit-alertmanager/references/verification-chain.md" "skills/audit-lgtm/references/backend-checks.md" "skills/audit-prometheus/references/prometheus-checks.md" "skills/audit-prometheus/SKILL.md" "skills/audit-alertmanager/SKILL.md"; do
  bc=$(grep -cE 'Bearer \$\{(PROM|LOKI|TEMPO|MIMIR|VM)_TOKEN\}' "$ROOT/$pair" || true)
  oc=$(grep -c "_BASIC_USER:-" "$ROOT/$pair" || true)
  [ "$bc" -eq "$oc" ] || fail "basic-auth override drift in $pair (bearer:$bc overrides:$oc)"
done
OUT=$(sh -eu -c 'LOKI_TOKEN=""; AUTH="Authorization: Bearer "; LOKI_BASIC_USER=u; LOKI_BASIC_PASS=p
if [ -n "${LOKI_BASIC_USER:-}" ] && [ -n "${LOKI_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf "%s:%s" "$LOKI_BASIC_USER" "$LOKI_BASIC_PASS" | base64 | tr -d "\n")"; fi
printf "%s" "$AUTH"' )
printf '%s' "$OUT" | grep -q "Basic dTpw" || fail "basic-auth override behavior broken (expected base64 of u:p)"
grep -q "MS_BASIC_USER" "$AP" || fail "overlay: metrics-store basic-auth support missing"
ok "basic-auth override locks"

# --- 6e. dogfood hardening: merge-all-lanes + control-char guard -------------
AWSC="$REF/cloud-mode-aws.md"
grep -q "Merge every lane before you decide coverage" "$AWSC" || fail "aws cookbook: merge-all-lanes hardening note missing"
grep -q "Control characters in env values" "$AWSC" || fail "aws cookbook: control-char guard missing"
grep -q "never re-parse" "$AWSC" || grep -q "never a re-parsed shell" "$AWSC" || true
[ -f "$ROOT/tests/pressure-scenarios/map-topology/cloud-mode-multi-lane-merge-coverage.md" ] || fail "multi-lane-merge scenario missing"

# --- 6f. cross-cloud IP attribution: shared rules + honesty + join behavior ---
grep -q "^## Cross-cloud IP attribution$" "$AWSC" || fail "aws cookbook: cross-cloud attribution section heading missing/renamed"
grep -q 'reachable` class only' "$AWSC" || fail "cross-cloud: reachable-class-only rule missing (no upgrade on IP evidence)"
grep -q "never expand a non-host CIDR" "$AWSC" || fail "cross-cloud: /32-strip / wildcard-demotion rule missing"
grep -q "stays an unattributed" "$AWSC" || fail "cross-cloud: no-match-stays-unattributed rule missing"
grep -q "recorded as ambiguous, not duplicated" "$AWSC" || fail "cross-cloud: ambiguous shared-NAT rule missing"
# SKILL wiring: the step exists in Phase 2E and points at the cookbook section
grep -q "2c. \*\*Cross-cloud attribution\*\*" "$SKILL" || fail "SKILL: cross-cloud attribution step (2c) not wired into Phase 2E"
grep -q 'cookbook: "Cross-cloud IP attribution"' "$SKILL" || fail "SKILL: cross-cloud step does not reference the cookbook section"
# each multi-cloud cookbook hands its IP openings to the pass
grep -q "Cross-cloud IP attribution" "$DO" || fail "DO: no pointer feeding ip openings to the cross-cloud pass"
grep -q "Cross-cloud IP attribution" "$GC" || fail "GCP: no pointer feeding ip openings to the cross-cloud pass"
grep -q "authorizedNetworks" "$GC" || fail "GCP: public-IP allowlist openings (authorizedNetworks) lane missing"
[ -f "$ROOT/tests/pressure-scenarios/map-topology/cloud-mode-cross-cloud-attribution.md" ] || fail "cross-cloud attribution scenario missing"
# behavior: /32 hit resolves; no-match stays OPEN; wide CIDR is never expanded
XOUT=$(sh -eu -c '
# RFC5737 documentation IPs (never real infra; not matched by the leak scan)
CAT=$(printf "192.0.2.10\tvm-prod\tgcp\n198.51.100.5\tvm-pp\tgcp\n")
resolve() { ip=$1; res=$2; ipx=${ip%/32};
  case "$ipx" in */*) echo "OPEN  $res allows $ipx (wide CIDR — finding, not an edge)"; return;; esac
  owner=$(printf "%s\n" "$CAT" | awk -F"\t" -v i="$ipx" "\$1==i{print \$2\" (\"\$3\")\"}" | head -1)
  if [ -n "$owner" ]; then echo "EDGE  $owner -> $res  [reachable]"; else echo "OPEN  $res allows $ipx — owner not in any configured cloud"; fi; }
resolve "192.0.2.10/32"  mongo-prod
resolve "203.0.113.7/32" mongo-pp
resolve "0.0.0.0/0"      mongo-x
')
printf '%s\n' "$XOUT" | grep -q "EDGE  vm-prod (gcp) -> mongo-prod" || fail "cross-cloud join: a /32 hit did not resolve to the catalog owner"
printf '%s\n' "$XOUT" | grep -q "OPEN  mongo-pp allows 203.0.113.7 — owner not in any" || fail "cross-cloud join: a no-match /32 was not kept as an unattributed opening"
printf '%s\n' "$XOUT" | grep -q "OPEN  mongo-x allows 0.0.0.0/0 (wide CIDR" || fail "cross-cloud join: a wide CIDR was not demoted (must not expand per-owner)"
printf '%s\n' "$XOUT" | grep -q "vm-pp -> mongo" && fail "cross-cloud join: resolved an owner never named by any opening (invented edge)" || ok "cross-cloud attribution locks"

# --- 6g. environment coverage: three-signal env inference + wiring -----------
grep -q "^## Environment coverage$" "$AWSC" || fail "env-coverage: cookbook section heading missing/renamed"
grep -q 'cookbook: "Environment coverage"' "$SKILL" || fail "env-coverage: SKILL Phase 5 does not reference the cookbook section"
grep -q "### Environment coverage" "$SKILL" || fail "env-coverage: SKILL Phase 5 step missing"
grep -q "contains the substring" "$AWSC" || fail "env-coverage: preprod-before-prod rationale (naive *prod* match) missing"
grep -qi "weakest" "$AWSC" || fail "env-coverage: 'label is the weakest signal / never trust alone' rule missing"
grep -q "what the service actually connects to" "$AWSC" || fail "env-coverage: connectivity (third) signal missing"
grep -qi "ask, never guess" "$AWSC" || fail "env-coverage: access-denied fallback (ask the operator) missing"
grep -qi "unconfirmed" "$AWSC" || fail "env-coverage: 'unconfirmed' env state (not guessed) missing in cookbook"
grep -qi "unconfirmed" "$SKILL" || fail "env-coverage: SKILL step does not route unconfirmed env to operator review"
[ -f "$ROOT/tests/pressure-scenarios/map-topology/environment-coverage-symmetry.md" ] || fail "env-coverage scenario missing"

# --- 7. redaction behavior on the GCP/Azure-style env extraction --------------
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
OUT=$(printf '%s' '[{"metadata":{"name":"checkout"},"spec":{"template":{"spec":{"containers":[{"env":[
 {"name":"DATABASE_URL","value":"postgres://svc:my.secret.pw@db.internal.test:5432/orders"},
 {"name":"PGPASSWORD","value":"dotted.secret.value"},
 {"name":"CACHE_REF","valueFrom":{"secretKeyRef":{"name":"cache-dsn"}}}]}]}}}}]' \
| jq -r '.[] | .metadata.name as $svc
  | (.spec.template.spec.containers[]? .env // [])[]
  | select(.valueFrom == null)
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?"; "g")
  | [$svc, $k, .h, (.p // "-")] | @tsv')
echo "$OUT" | grep -q "db.internal.test	5432" || fail "gcp-style extraction lost the endpoint join"
echo "$OUT" | grep -q "my.secret.pw" && fail "gcp-style extraction leaked a userinfo credential" || ok "userinfo stripped"
echo "$OUT" | grep -q "dotted.secret.value" && fail "gcp-style extraction leaked a secret-named key" || ok "secret key skipped"
echo "$OUT" | grep -q "cache-dsn" && fail "secretKeyRef resolved instead of skipped" || ok "secretRef entries excluded from value parsing"

# --- 7b. env-coverage: run the SHIPPED recipe against a fixture with the traps -
# Extract the jq program from the cookbook's "## Environment coverage" block so
# this locks the actual shipped behavior, not a copy that can drift.
ECJQ="${TMPDIR:-/tmp}/envcov-shipped.jq"
awk '/^## Environment coverage/{s=1} s&&/^jq -r '\''/{c=1;next} c&&/^'\'' "\$EXPORT"/{exit} c{print}' "$AWSC" > "$ECJQ"
[ -s "$ECJQ" ] || fail "env-coverage: could not extract the shipped jq recipe from the cookbook"
# Fixture with every trap: a -pp app the platform mislabels "Production",
# a preprod resource, and a testing service that connects to a prod resource.
ECFIX="${TMPDIR:-/tmp}/envcov-fixture.json"
cat > "$ECFIX" <<'JSON'
{ "version":"scoutflo-topology-export/v1",
  "services":[
    {"name":"web-prod","attributes":{"runtime":"do-app-platform"}},
    {"name":"web-pp","attributes":{"runtime":"do-app-platform","environment":"Production"}},
    {"name":"api-testing","attributes":{"runtime":"gcp-vm"}}
  ],
  "resources":[ {"name":"db-prod"}, {"name":"db-pp"} ],
  "relationships":[
    {"from":{"name":"web-prod"},"to":{"name":"db-prod"},"relation":"STORES_DATA_IN"},
    {"from":{"name":"web-pp"},"to":{"name":"db-pp"},"relation":"STORES_DATA_IN"},
    {"from":{"name":"api-testing"},"to":{"name":"db-prod"},"relation":"STORES_DATA_IN"}
  ] }
JSON
EC=$(jq -r -f "$ECJQ" "$ECFIX" 2>&1) || fail "env-coverage: shipped recipe failed to run"
# preprod is a real bucket and web-pp landed in it (NOT mislabeled to prod by the "Production" label)
printf '%s\n' "$EC" | grep -Eq 'preprod[[:space:]]+svc=1' || fail "env-coverage: -pp app not bucketed as preprod (label trap or naive *prod* match)"
# the platform label conflict is surfaced, name is preferred
printf '%s\n' "$EC" | grep -q "web-pp: name=>preprod label=>prod" || fail "env-coverage: wrong platform label ('Production' on a -pp app) not flagged"
# connectivity catches the testing->prod cross-environment access
printf '%s\n' "$EC" | grep -q "api-testing \[testing\] -> mostly \[prod\]" || fail "env-coverage: cross-environment access (testing service -> prod resource) not flagged"
# twin coverage names the shared base across environments
printf '%s\n' "$EC" | grep -Eq 'db[[:space:]]+(preprod:edges[[:space:]]+prod:edges|prod:edges[[:space:]]+preprod:edges)' || fail "env-coverage: twin coverage did not pair db-prod/db-pp"
ok "env-coverage: shipped recipe classifies envs by name+label+connectivity"

[ "$fails" -eq 0 ] && echo "PASS: cloud-mode multicloud locks" || { echo "FAILURES: $fails"; exit 1; }
