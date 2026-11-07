#!/bin/sh
# test-alert-fatigue.sh — hermetic tests for the alert-fatigue roll-up lib.
# Run by ci/run-tests.sh under /bin/sh. No network, no creds, synthetic fixtures.
set -u

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$DIR/lib/alert-fatigue.sh"
export CLAUDE_PLUGIN_ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
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

python3 "$CLAUDE_PLUGIN_ROOT/skills/correlation-engine/tests/qualified-fixtures.py" "$SCOUTFLO_AUDIT_DIR" "$DATE"
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

# 8. MEASURED fire-history tier — a fatigue-signals.json drives AF-004/005/006 and
#    a live incident_feed drives AF-003 (preferred over the operator fatigue.json).
cat > "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json" <<'JSON'
{ "schema":"scoutflo-fatigue-signals/v1","generated_at":"2026-08-29T12:00:00Z","window":"30d",
  "signals":[
    {"provider":"alertmanager","target":"alertmanager","object_id":"checkout-flap","object_kind":"prometheus_alert","fires":40,"flapping":true,"stuck":false,"off_hours_fires":20,"reaches_human":false,"reach_reason":"routes to a black-hole receiver","source_finding_ids":["ALR-012"]},
    {"provider":"grafana","target":"grafana","object_id":"checkout-stuck","object_kind":"grafana_rule","fires":1,"flapping":false,"stuck":true,"stuck_since":"2025-11-01T00:00:00Z","stuck_days":311,"reaches_human":true,"source_finding_ids":["GRAF-021"]}
  ],
  "provider_coverage":[{"provider":"alertmanager","tier":"fire-history","status":"collected"},{"provider":"datadog","tier":"fire-history","status":"verify-pending","reason":"no key"}],
  "incident_feed":{"status":"collected","source":"pagerduty","window":"30d","alerts_fired":400,"incidents":8,"actionable_pct":40}
}
JSON
alert_fatigue_run "$DATE" >/dev/null 2>&1
check "AF-004 reachability measured"          "$(jq -r '.af_findings[]|select(.af_id=="AF-004")|.status' "$OUT")" "measured"
check "AF-004 one unreachable object"          "$(jq -r '.af_findings[]|select(.af_id=="AF-004")|.unreachable_objects' "$OUT")" "1"
check "AF-004 by-reason names the black hole"  "$(jq -r '.af_findings[]|select(.af_id=="AF-004")|.by_reason[0].reason' "$OUT")" "routes to a black-hole receiver"
check "AF-005 total fires = 41"                "$(jq -r '.af_findings[]|select(.af_id=="AF-005")|.total_fires' "$OUT")" "41"
check "AF-005 top offender is the flapper"     "$(jq -r '.af_findings[]|select(.af_id=="AF-005")|.top_offenders[0].object_id' "$OUT")" "checkout-flap"
check "AF-006 one chronic object"              "$(jq -r '.af_findings[]|select(.af_id=="AF-006")|.chronic_objects' "$OUT")" "1"
check "AF-006 chronic is the stuck rule"       "$(jq -r '.af_findings[]|select(.af_id=="AF-006")|.objects[0].object_id' "$OUT")" "checkout-stuck"
check "AF-007 histogram has classes"           "$(jq -r '[.af_findings[]|select(.af_id=="AF-007")|.histogram[].class] | any(. == "dead-end" or . == "flap-prone" or . == "chronic-stuck")' "$OUT")" "true"
check "AF-003 prefers the live incident feed"  "$(jq -r '.af_findings[]|select(.af_id=="AF-003")|.source' "$OUT")" "pagerduty"
check "AF-003 ratio from feed = 50"            "$(jq -r '.af_findings[]|select(.af_id=="AF-003")|.alerts_per_incident' "$OUT")" "50"
check "coverage marks datadog verify-pending"  "$(jq -r '[.fire_history_coverage[]|select(.status=="verify-pending")|.provider]|.[0]' "$OUT")" "datadog"
check "totals.unreachable_objects = 1"         "$(jq -r '.totals.unreachable_objects' "$OUT")" "1"

# 9. NEVER-FABRICATE — with signals removed, the measured tiers are not-in-scope, not guessed
rm -f "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"
alert_fatigue_run "$DATE" >/dev/null 2>&1
check "AF-004 not-in-scope without signals"    "$(jq -r '.af_findings[]|select(.af_id=="AF-004")|.status' "$OUT")" "not-in-scope"
check "AF-005 not-in-scope without signals"    "$(jq -r '.af_findings[]|select(.af_id=="AF-005")|.status' "$OUT")" "not-in-scope"
check "AF-006 not-in-scope without signals"    "$(jq -r '.af_findings[]|select(.af_id=="AF-006")|.status' "$OUT")" "not-in-scope"

# Shared configuration findings are not evidence that any page was delivered.
AF_TWO=$(jq -r '.af_findings[] | select(.af_id=="AF-002") | .summary, .storms[]?.note' "$OUT")
if printf '%s' "$AF_TWO" | grep -Eq 'one incident.*pages through|incident there pages'; then
  bad "configuration overlap asserted actual paging delivery"
else ok "configuration overlap never asserts actual paging delivery"; fi

# A second run with no source findings/signals must not retain the previous noise.
rm -rf "$SCOUTFLO_AUDIT_DIR/alertmanager" "$SCOUTFLO_AUDIT_DIR/grafana" "$SCOUTFLO_AUDIT_DIR/aws" "$SCOUTFLO_AUDIT_DIR/kubernetes"
rm -f "$SCOUTFLO_AUDIT_DIR/fatigue.json"
alert_fatigue_run "$DATE" >/dev/null 2>&1
check "empty rerun replaces stale noise total" "$(jq -r '.totals.alerting_noise_findings' "$OUT")" "0"
check "empty rerun replaces stale overlap total" "$(jq -r '.totals.cross_source_storms' "$OUT")" "0"
check "empty rerun preserves unknown measured volume" "$(jq -r '.af_findings[] | select(.af_id=="AF-005") | .status' "$OUT")" "not-in-scope"

# Unobserved or closed rows are not current noise; historical missing fields work.
for extra in '{"status":"blocked"}' '{"status":"unknown"}' '{"status":"deferred"}' '{"lifecycle":"suppressed"}' '{"lifecycle":"resolved"}'; do
  rows=$(jq -nc --argjson extra "$extra" '[{id:"SOC-003",target:"splunk_oncall",title:"Paging unavailable",area:"paging",affected:["checkout"]} + $extra]')
  check "unobserved/closed row is not noise" "$(printf '%s' "$rows" | alert_fatigue_select_noise | jq length)" "0"
done
rows='[{"id":"SOC-003","target":"splunk_oncall","title":"Paging unavailable","area":"paging","affected":["checkout"]}]'
check "legacy row stays eligible" "$(printf '%s' "$rows" | alert_fatigue_select_noise | jq length)" "1"
# Reserved names are only skipped at the integration level, not labels/root names.
AUDITS_DIR="$WORK/all/audits"; mkdir -p "$AUDITS_DIR/splunk_oncall/doctor/$DATE" "$AUDITS_DIR/all/$DATE"
printf '%s\n' '{"target":"splunk_oncall/doctor","findings":[{"id":"SOC-003"}]}' > "$AUDITS_DIR/splunk_oncall/doctor/$DATE/findings.json"
printf '%s\n' '{"target":"all","findings":[{"id":"COMBINED"}]}' > "$AUDITS_DIR/all/$DATE/findings.json"
check "reserved parent/label names preserve real audit" "$(alert_fatigue_collect_findings "$DATE" | jq -r 'map(.id)|join(",")')" "SOC-003"

echo "alert-fatigue: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
