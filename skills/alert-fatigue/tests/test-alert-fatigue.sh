#!/bin/sh
# test-alert-fatigue.sh — hermetic tests for the alert-fatigue roll-up lib.
# Run by ci/run-tests.sh under /bin/sh. No network, no creds, synthetic fixtures.
set -u

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$DIR/lib/alert-fatigue.sh"
[ -f "$LIB" ] || { echo "FAIL: lib not found at $LIB"; exit 1; }

WORK="${TMPDIR:-/tmp}/af-test.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want=$3 got=$2)"; fi; }

DATE="2026-08-29"
export SCOUTFLO_AUDIT_DIR="$WORK/audits"

mkfindings() {  # target date json-findings-array
  d="$SCOUTFLO_AUDIT_DIR/$1/$2"; mkdir -p "$d"
  jq -n --arg t "$1" --argjson f "$3" '{schema:"scoutflo-findings/v1", target:$t, findings:$f}' > "$d/findings.json"
}

# alertmanager: two alerting-noise findings (flapping on checkout, missing-for on payments)
mkfindings alertmanager "$DATE" '[
  {"id":"ALR-012","title":"Paging rules flap without a keep_firing_for hold","severity":"medium","area":"alert-hygiene","affected":["checkout"]},
  {"id":"ALR-014","title":"Paging rule has no for debounce","severity":"medium","area":"alert-hygiene","affected":["payments"]}
]'
# grafana: a flapping-alert finding on checkout -> shares checkout with alertmanager => cross-source storm
mkfindings grafana "$DATE" '[
  {"id":"GRAF-021","title":"Alert rule flapping, no dampening","severity":"medium","area":"alerting","affected":["checkout"]}
]'
# aws: NON-noise findings that must be EXCLUDED. AWS-050's title contains "log group" and
# AWS-032 is reliability — neither is alerting noise. AWS-050 shares `checkout` with the real
# noise above: if the title regex over-matched "group", checkout would falsely become a 3-tool storm.
mkfindings aws "$DATE" '[
  {"id":"AWS-032","title":"RDS instance is single-AZ","severity":"high","area":"reliability","affected":["db-main"]},
  {"id":"AWS-050","title":"Critical log group /aws/lambda/checkout has no subscription filter","severity":"medium","area":"logging","affected":["checkout"]}
]'
# kubernetes: a "Missing resource limits for deployment" finding on payments. If the title regex
# over-matched "missing .*for", payments (which has one real noise finding) would falsely become a storm.
mkfindings kubernetes "$DATE" '[
  {"id":"K8S-004","title":"Missing resource limits for deployment payments","severity":"high","area":"workload","affected":["payments"]}
]'

. "$LIB"
alert_fatigue_run "$DATE" >/dev/null 2>&1
OUT="$SCOUTFLO_AUDIT_DIR/alert-fatigue.json"
[ -f "$OUT" ] || { echo "FAIL: alert-fatigue.json not written"; exit 1; }

# 1. schema + non-scored
check "schema is scoutflo-alert-fatigue/v1" "$(jq -r '.schema' "$OUT")" "scoutflo-alert-fatigue/v1"
check "declared non-scored"                 "$(jq -r '.scoring_scope' "$OUT")" "non-scored"

# 2. noise selection: 3 noise findings (2 ALR + 1 GRAF); the AWS reliability finding excluded
check "3 alerting-noise findings selected"  "$(jq -r '.totals.alerting_noise_findings' "$OUT")" "3"
check "AWS-032 excluded from noise"         "$(jq -r '[.af_findings[0].source_findings[].finding_id] | index("AWS-032") // "none"' "$OUT")" "none"
check "2 tools carry noise"                 "$(jq -r '.totals.tools_with_noise' "$OUT")" "2"

# 3. cross-source storm on checkout (2 tools), payments NOT a storm (1 tool)
check "1 cross-source storm detected"       "$(jq -r '.totals.cross_source_storms' "$OUT")" "1"
check "storm is on checkout"                "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[0].service] | .[0]' "$OUT")" "checkout"
check "checkout storm spans 2 tools"        "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[0].tool_count] | .[0]' "$OUT")" "2"

# 4. storm cites source finding-IDs from BOTH tools (never re-scores)
check "storm cites ALR-012"                 "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[0].source_findings[].finding_id] | index("ALR-012") // "no"' "$OUT")" "0"
check "storm cites GRAF-021"                "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[0].source_findings[].finding_id] | any(.=="GRAF-021")' "$OUT")" "true"

# 5. AF-003 not-in-scope with no signal block (never a fabricated ratio)
check "AF-003 not-in-scope without signal"  "$(jq -r '.af_findings[] | select(.af_id=="AF-003") | .status' "$OUT")" "not-in-scope"

# 6. roll-up never wrote into a per-audit dir (only alert-fatigue.json at root)
check "no findings.json mutated (alertmanager)" "$(jq -r '.findings | length' "$SCOUTFLO_AUDIT_DIR/alertmanager/$DATE/findings.json")" "2"

# 6b. OVER-MATCH TRAPS (regression lock for the v0.1.159 title-regex fix): infra findings whose
#     titles merely contain "log group" / "missing ... for" must NOT be selected as alerting noise,
#     and must NOT fabricate a cross-source storm on a service that has a real noise finding.
check "AWS-050 (log group) excluded from noise" "$(jq -r '[.af_findings[0].source_findings[].finding_id] | index("AWS-050") // "none"' "$OUT")" "none"
check "K8S-004 (missing...for) excluded from noise" "$(jq -r '[.af_findings[0].source_findings[].finding_id] | index("K8S-004") // "none"' "$OUT")" "none"
check "checkout storm stays 2 tools (log-group not counted)" "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[] | select(.service=="checkout") | .tool_count] | .[0]' "$OUT")" "2"
check "payments has NO fabricated storm" "$(jq -r '[.af_findings[] | select(.type=="cross-source-alert-storm") | .storms[] | select(.service=="payments")] | length' "$OUT")" "0"

# 7. with a fatigue.json signal block, AF-003 computes alerts_per_incident
printf '%s\n' '{"window":"7d","alerts_fired":4200,"incidents":35}' > "$SCOUTFLO_AUDIT_DIR/fatigue.json"
alert_fatigue_run "$DATE" >/dev/null 2>&1
check "AF-003 computed with signal block"   "$(jq -r '.af_findings[] | select(.af_id=="AF-003") | .status' "$OUT")" "computed"
check "AF-003 alerts_per_incident = 120"    "$(jq -r '.af_findings[] | select(.af_id=="AF-003") | .alerts_per_incident' "$OUT")" "120"

echo "alert-fatigue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
