#!/bin/sh
# Cloud Mode (AWS) locks: redaction behavior of the extraction pipeline,
# no-secret-value-calls invariant, wildcard demotion, phase/template/export
# wiring. Run by ci/run-tests.sh under /bin/sh.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COOK="$ROOT/skills/map-topology/references/cloud-mode-aws.md"
SKILL="$ROOT/skills/map-topology/SKILL.md"
EXPORT="$ROOT/skills/map-topology/references/scoutflo-export.md"
fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { echo "ok: $1"; }

# --- 1. artifacts exist ------------------------------------------------------
[ -f "$COOK" ] || fail "cloud-mode-aws.md missing"
[ -f "$ROOT/tests/pressure-scenarios/map-topology/cloud-mode-edge-evidence-honesty.md" ] || fail "evidence-honesty scenario missing"
[ -f "$ROOT/tests/pressure-scenarios/map-topology/cloud-mode-review-batching-and-tiers.md" ] || fail "review-batching scenario missing"

# --- 2. redaction pipeline BEHAVIOR (the load-bearing lock) ------------------
# Fixture: a dotted password inside URL userinfo, a bare dotted secret under a
# secret-named key, and a legitimate DSN. The pipeline (same fragments the
# cookbook ships) must yield the endpoint and NEVER any credential.
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
TD_FIX="${TMPDIR:-/tmp}/cloudmode-test-td.json"
cat > "$TD_FIX" <<'EOF'
{"taskDefinition":{"containerDefinitions":[{"environment":[
  {"name":"DATABASE_URL","value":"postgres://svc:my.secret.pw@db.example.test:5432/orders"},
  {"name":"PGPASSWORD","value":"dotted.secret.value"},
  {"name":"REDIS_HOST","value":"cache.internal.example.test:6379"},
  {"name":"API_TOKEN","value":"tok.abc.def"}
]}]}}
EOF
OUT=$(jq -r '.taskDefinition.containerDefinitions[] | .environment // [] | .[]
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?(/(?<db>[A-Za-z0-9_-]+))?"; "g")
  | [$k, .h, (.p // "-"), (.db // "-")] | @tsv' "$TD_FIX")
rm -f "$TD_FIX"
echo "$OUT" | grep -q "db.example.test	5432	orders" || fail "extraction lost the real endpoint join (host/port/db)"
echo "$OUT" | grep -q "cache.internal.example.test	6379" || fail "extraction lost the host:port join"
echo "$OUT" | grep -q "my.secret.pw" && fail "URL userinfo credential leaked through extraction" || ok "userinfo credential stripped"
echo "$OUT" | grep -q "dotted.secret.value" && fail "secret-named key value leaked through extraction" || ok "secret-named key skipped"
echo "$OUT" | grep -q "tok.abc.def" && fail "token value leaked through extraction" || ok "token key skipped"

# --- 3. the shipped cookbook carries exactly these defenses (drift lock) -----
grep -qF 'gsub("://[^@/]*@"; "://")' "$COOK" || fail "cookbook lost the userinfo strip"
grep -qF '(?i)password|passwd|secret|token|api_?key|private|credential' "$COOK" || fail "cookbook lost the secret-key skip filter"
n=$(grep -cF '(?i)password|passwd|secret|token|api_?key|private|credential' "$COOK" || true)
[ "$n" -ge 2 ] || fail "secret-key skip filter must be in BOTH declared sections (ECS + Lambda), found $n"

# --- 4. no secret-value reads, any lane, any tier ----------------------------
grep -q "get-secret-value" "$COOK" && fail "cookbook invokes get-secret-value" || ok "no get-secret-value invocation"
grep -qE "ssm get-parameter|aws secretsmanager" "$COOK" && fail "cookbook invokes a secret/parameter value read" || ok "no parameter value reads"

# --- 5. wildcard demotion + tier gate + review protocol wiring ---------------
grep -q "Wildcard demotion" "$COOK" || fail "wildcard demotion rule missing from cookbook"
grep -q "access tier:" "$COOK" || fail "access-tier gate echo missing"
grep -q "no-config-read" "$COOK" || fail "no-config-read tier missing"
grep -q "Zero-access discovery pack" "$COOK" || fail "discovery-pack section missing"
grep -q "## Phase 2E" "$SKILL" || fail "Phase 2E missing from SKILL.md"
grep -q "## Cloud resources and connections" "$SKILL" || fail "map template section missing"
grep -q "Connection carry-forward" "$SKILL" || fail "re-run carry-forward for connections missing"
grep -q "IAM .Resource: ...\"" "$SKILL" 2>/dev/null || grep -q 'Resource: "\*"' "$SKILL" || fail "wildcard-demotion failure-mode row missing from SKILL.md"

# --- 6. export contract additions --------------------------------------------
grep -q "## Cloud Mode" "$EXPORT" || fail "export contract missing Cloud Mode section"
grep -q "STORES_DATA_IN" "$EXPORT" || fail "export contract missing STORES_DATA_IN"
grep -q "never appear" "$EXPORT" && grep -q "in the Traffic map" "$EXPORT" || fail "export contract must separate connections from CALLS/Traffic edges"
grep -q "Unclaimed resources export as resources without edges" "$EXPORT" || fail "unclaimed-resources rule missing"

[ "$fails" -eq 0 ] && echo "PASS: cloud-mode-aws locks" || { echo "FAILURES: $fails"; exit 1; }
