#!/bin/sh
# test-check-findings.sh
# Proves report-standard/check-findings.sh accepts a valid findings.json and
# rejects each defect class it exists to catch — so the gate that stops
# score-that-doesn't-match-its-scorecard (and schema drift) is itself guarded.
# Falsifiable: builds fixtures and asserts pass/fail. Runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/report-standard/check-findings.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# A valid baseline: overall 47 = (30*50 + 25*40 + 15*66 + 10*20) / 80  with the
# 20-weight "Actionability" category excluded (renormalized) -> 46.25 -> floor 46,
# within tolerance 1 of 47. Mirrors the real pagerduty shape (excluded category).
good() {
  cat <<'JSON'
{
  "schema": "scoutflo-findings/v1",
  "toolkit_version": "0.1.78",
  "skill": "audit-fixture",
  "target": "fixture",
  "run_date": "2026-08-02",
  "generated_at": "2026-08-02T12:00:00Z",
  "score": {
    "overall": 47,
    "gate": 85,
    "end_to_end": false,
    "categories": [
      {"name":"Escalation","weight":30,"score":50,"maturity":"reactive","checks_passed":3,"checks_total":6},
      {"name":"Noise","weight":25,"score":40,"maturity":"reactive","checks_passed":1,"checks_total":3},
      {"name":"Actionability","weight":20,"score":0,"maturity":"reactive","checks_passed":0,"checks_total":0},
      {"name":"Health","weight":15,"score":66,"maturity":"reactive","checks_passed":2,"checks_total":3},
      {"name":"Hygiene","weight":10,"score":20,"maturity":"reactive","checks_passed":1,"checks_total":4}
    ],
    "excluded": [ {"name":"Actionability","weight":0,"reason":"no incidents in window"} ]
  },
  "severity_counts": { "critical": 0, "high": 1, "medium": 1, "low": 0, "info": 1 },
  "findings": [
    {"id":"FX-001","title":"t","severity":"high","area":"escalation","status":"validated-live","lifecycle":"new","points_recoverable":5,"affected":["svc-a"],"evidence":[{"check":"c","command":"curl x","observed":"o"}],"recommendation":"r","remediation":"setup-fixture#a"},
    {"id":"FX-002","title":"t","severity":"medium","area":"noise","status":"configured","lifecycle":"new","points_recoverable":2,"affected":["svc-b"],"evidence":[{"check":"c","command":"curl y","observed":"o"}],"recommendation":"r","remediation":"setup-fixture#b"},
    {"id":"FX-003","title":"t","severity":"info","area":"hygiene","status":"validated-live","lifecycle":"new","points_recoverable":0,"evidence":[{"check":"c","command":"curl z","observed":"o"}],"recommendation":"r","remediation":"doc#c"}
  ]
}
JSON
}
# jq filter -> mutate the good fixture into a specific defect.
mutate() { good | jq "$1" > "$WORK/f.json"; }
good_v2() {
  cat <<'JSON'
{
  "schema": "scoutflo-findings/v2",
  "toolkit_version": "0.1.153",
  "skill": "audit-fixture",
  "target": "fixture",
  "run_date": "2026-08-28",
  "generated_at": "2026-08-28T12:00:00Z",
  "checks": [
    {"id":"FX-001","category":"Signals","result":"pass"},
    {"id":"FX-002","category":"Signals","result":"partial","reason":"one of two services is stale"},
    {"id":"FX-003","category":"Routing","result":"fail"},
    {"id":"FX-004","category":"Signals","result":"blocked","reason":"HTTP 403"},
    {"id":"FX-005","category":"Routing","result":"not-in-scope","reason":"no paging service is declared"}
  ],
  "score": {
    "overall": 45,
    "state": "assessed",
    "gate": 85,
    "end_to_end": false,
    "scoring_model": "assessed-only-v1",
    "check_set": "pending",
    "assessment": {"applicable_checks":4,"assessed_checks":3,"scored_checks":3,"blocked_checks":1,"suppressed_checks":0,"not_in_scope_checks":1,"coverage_percent":75},
    "categories": [
      {"name":"Signals","weight":60,"score":75,"maturity":"reactive","checks_passed":1,"checks_partial":1,"checks_failed":0,"checks_blocked":1,"checks_suppressed":0,"checks_not_in_scope":0,"checks_total":2},
      {"name":"Routing","weight":40,"score":0,"maturity":"reactive","checks_passed":0,"checks_partial":0,"checks_failed":1,"checks_blocked":0,"checks_suppressed":0,"checks_not_in_scope":1,"checks_total":1}
    ],
    "excluded": []
  },
  "severity_counts": {"critical":0,"high":1,"medium":1,"low":1,"info":0},
  "findings": [
    {"id":"FX-002","title":"one service is stale","severity":"medium","area":"signals","status":"configured","lifecycle":"new","scoring_scope":"readiness","report_lanes":["general-audit","ai-sre-readiness"],"points_recoverable":8,"affected":["svc-a"],"evidence":[{"check":"freshness","command":"query","observed":"one of two stale"}],"recommendation":"repair freshness","remediation":"setup-fixture#freshness"},
    {"id":"FX-003","title":"routing is broken","severity":"high","area":"routing","status":"validated-live","lifecycle":"new","scoring_scope":"readiness","report_lanes":["general-audit"],"points_recoverable":40,"affected":["route-a"],"evidence":[{"check":"routing","command":"query","observed":"no receiver"}],"recommendation":"wire receiver","remediation":"setup-fixture#routing"},
    {"id":"FX-004","title":"signal check could not be read","severity":"low","area":"signals","status":"blocked","lifecycle":"new","scoring_scope":"readiness","report_lanes":["ai-sre-readiness"],"points_recoverable":0,"affected":["scope-a"],"evidence":[{"check":"signal read","command":"query","observed":"HTTP 403"}],"recommendation":"grant the missing read scope","remediation":"doc#access"}
  ]
}
JSON
}
# Mirror check-findings.sh's check_set fingerprint (checks + category weights + gate).
fp_of() {
  jq -r '
    ( [ .checks[] | "chk\t" + .id + "\t" + .category ]
      + [ .score.categories[] | "cat\t" + .name + "\t" + (.weight|tostring) ]
      + [ "gate\t" + ((.score.gate // 85)|tostring) ]
    ) | sort | .[]' "$1" | LC_ALL=C cksum | awk '{print "cksum-v2:" $1 ":" $2}'
}
write_v2() {
  good_v2 > "$WORK/f.json"
  fp="$(fp_of "$WORK/f.json")"
  jq --arg fp "$fp" '.score.check_set=$fp' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
}
mutate_v2() { write_v2; jq "$1" "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"; }
expect_ok()   { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { sh "$CHECK" "$WORK/f.json" 2>&1 | grep FINDINGS-FAIL; fail "$1"; }; }
expect_fail() { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 && fail "$1"; return 0; }

echo "=== check-findings self-test ==="

echo "Test 1: a valid findings.json (excluded category renormalized) PASSES"
mutate '.'
expect_ok "checker rejected a valid findings.json"
echo "PASS"

echo "Test 11: a valid v2 ledger with blocked checks outside the readiness denominator PASSES"
write_v2
expect_ok "checker rejected a valid v2 findings ledger"
echo "PASS"

echo "Test 12: a v2 readiness score that counts a blocked check as failure is REJECTED"
mutate_v2 '.score.categories[0].score=50 | .score.overall=30'
expect_fail "checker accepted a v2 category score that counted blocked as failure"
echo "PASS"

echo "Test 13: incorrect v2 assessment coverage is REJECTED"
mutate_v2 '.score.assessment.coverage_percent=100'
expect_fail "checker accepted incorrect v2 assessment coverage"
echo "PASS"

echo "Test 14: a blocked v2 check without a same-ID finding is REJECTED"
mutate_v2 'del(.findings[] | select(.id=="FX-004"))'
expect_fail "checker accepted a blocked check with no explanatory finding"
echo "PASS"

echo "Test 15: a blocked finding with recoverable readiness points is REJECTED"
mutate_v2 '(.findings[] | select(.id=="FX-004") | .points_recoverable)=2'
expect_fail "checker accepted readiness points on an unassessed check"
echo "PASS"

echo "Test 16: a stale v2 check-set fingerprint is REJECTED"
mutate_v2 '.score.check_set="cksum-v1:0:0"'
expect_fail "checker accepted a stale check-set fingerprint"
echo "PASS"

echo "Test 17: a fully blocked v2 audit is unassessed rather than 0/100"
write_v2
jq '
  .checks=[{"id":"FX-004","category":"Signals","result":"blocked","reason":"HTTP 403"}]
  | .score.overall=null
  | .score.state="unassessed"
  | .score.assessment={"applicable_checks":1,"assessed_checks":0,"scored_checks":0,"blocked_checks":1,"suppressed_checks":0,"not_in_scope_checks":0,"coverage_percent":0}
  | .score.categories=[{"name":"Signals","weight":100,"score":0,"maturity":"reactive","checks_passed":0,"checks_partial":0,"checks_failed":0,"checks_blocked":1,"checks_suppressed":0,"checks_not_in_scope":0,"checks_total":0}]
  | .score.excluded=[{"name":"Signals","weight":100,"reason":"blocked: HTTP 403"}]
  | .findings=[.findings[] | select(.id=="FX-004")]
  | .severity_counts={"critical":0,"high":0,"medium":0,"low":1,"info":0}
' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
fp="$(fp_of "$WORK/f.json")"
jq --arg fp "$fp" '.score.check_set=$fp' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
expect_ok "checker rejected a valid fully blocked unassessed v2 run"
echo "PASS"

echo "Test 18: a v2 finding with an unknown report lane is REJECTED"
mutate_v2 '(.findings[] | select(.id=="FX-002") | .report_lanes)=["marketing"]'
expect_fail "checker accepted an unknown v2 report lane"
echo "PASS"

echo "Test 19: duplicate v2 report lanes are REJECTED"
mutate_v2 '(.findings[] | select(.id=="FX-002") | .report_lanes)=["general-audit","general-audit"]'
expect_fail "checker accepted duplicate v2 report lanes"
echo "PASS"

echo "Test 20: a valid active exemption remains assessed but is excluded from readiness scoring"
write_v2
jq '
  (.checks[] | select(.id=="FX-003")) += {"suppressed":true,"suppression_reason":"approved until 2026-09-30"}
  | (.findings[] | select(.id=="FX-003") | .lifecycle)="suppressed"
  | (.findings[] | select(.id=="FX-003") | .points_recoverable)=0
  | .score.overall=75
  | .score.assessment={"applicable_checks":4,"assessed_checks":3,"scored_checks":2,"blocked_checks":1,"suppressed_checks":1,"not_in_scope_checks":1,"coverage_percent":75}
  | .score.categories[1]={"name":"Routing","weight":40,"score":0,"maturity":"reactive","checks_passed":0,"checks_partial":0,"checks_failed":0,"checks_blocked":0,"checks_suppressed":1,"checks_not_in_scope":1,"checks_total":0}
  | .score.excluded=[{"name":"Routing","weight":40,"reason":"active exemption"}]
  | .severity_counts={"critical":0,"high":0,"medium":1,"low":1,"info":0}
' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
expect_ok "checker rejected a valid suppressed v2 check"
echo "PASS"

echo "Test 21: a suppressed finding without a suppressed ledger row is REJECTED"
mutate_v2 '(.findings[] | select(.id=="FX-003") | .lifecycle)="suppressed" | (.findings[] | select(.id=="FX-003") | .points_recoverable)=0 | .severity_counts.high=0'
expect_fail "checker accepted a suppressed scored finding that remained in readiness scoring"
echo "PASS"

echo "Test 22: suppression cannot hide a blocked check"
mutate_v2 '(.checks[] | select(.id=="FX-004")) += {"suppressed":true,"suppression_reason":"approved"}'
expect_fail "checker accepted suppression on a blocked evidence read"
echo "PASS"

echo "Test 23: a v2 finding without a same-ID check row is REJECTED"
mutate_v2 '.findings += [{"id":"FX-006","title":"orphan","severity":"info","area":"signals","status":"configured","lifecycle":"new","scoring_scope":"readiness","report_lanes":["general-audit"],"points_recoverable":0,"evidence":[{"check":"orphan","command":"query","observed":"orphan row"}],"recommendation":"remove orphan","remediation":"doc#orphan"}] | .severity_counts.info=1'
expect_fail "checker accepted an orphan v2 finding"
echo "PASS"

echo "Test 24: a pass check cannot carry an open finding"
mutate_v2 '.findings += [{"id":"FX-001","title":"contradictory pass finding","severity":"info","area":"signals","status":"validated-live","lifecycle":"new","scoring_scope":"readiness","report_lanes":["general-audit"],"points_recoverable":0,"evidence":[{"check":"pass","command":"query","observed":"healthy"}],"recommendation":"remove contradiction","remediation":"doc#pass"}] | .severity_counts.info=1'
expect_fail "checker accepted an open finding for a pass check"
echo "PASS"

echo "Test 25: a not-in-scope check cannot carry an open finding"
mutate_v2 '.findings += [{"id":"FX-005","title":"contradictory not-in-scope finding","severity":"info","area":"routing","status":"configured","lifecycle":"new","scoring_scope":"readiness","report_lanes":["general-audit"],"points_recoverable":0,"evidence":[{"check":"scope","command":"query","observed":"not applicable"}],"recommendation":"remove contradiction","remediation":"doc#scope"}] | .severity_counts.info=1'
expect_fail "checker accepted an open finding for a not-in-scope check"
echo "PASS"

echo "Test 26: an explicit non-scored finding with no ledger row and zero points PASSES"
mutate_v2 '.findings += [{"id":"FX-006","title":"cost opportunity","severity":"info","area":"cost-optimization","status":"configured","lifecycle":"new","scoring_scope":"non-scored","report_lanes":["general-audit"],"points_recoverable":0,"evidence":[{"check":"cost","command":"query","observed":"provider recommendation"}],"recommendation":"review separately","remediation":"doc#cost"}] | .severity_counts.info=1'
expect_ok "checker rejected a valid explicit non-scored finding"
echo "PASS"

echo "Test 27: a v2 finding without an explicit scoring scope is REJECTED"
mutate_v2 'del(.findings[0].scoring_scope)'
expect_fail "checker accepted an implicit v2 finding scoring scope"
echo "PASS"

echo "Test 28: a non-scored finding cannot share a readiness check row"
mutate_v2 '(.findings[] | select(.id=="FX-002") | .scoring_scope)="non-scored" | (.findings[] | select(.id=="FX-002") | .points_recoverable)=0'
expect_fail "checker accepted a non-scored finding linked to a readiness check"
echo "PASS"

echo "Test 29: end_to_end=true with <100% assessment coverage is REJECTED (coverage completeness gate)"
write_v2
jq '
  .checks=[{"id":"FX-001","category":"Signals","result":"pass"},{"id":"FX-004","category":"Signals","result":"blocked","reason":"HTTP 403"}]
  | .score.overall=100 | .score.state="assessed" | .score.end_to_end=true
  | .score.assessment={"applicable_checks":2,"assessed_checks":1,"scored_checks":1,"blocked_checks":1,"suppressed_checks":0,"not_in_scope_checks":0,"coverage_percent":50}
  | .score.categories=[{"name":"Signals","weight":100,"score":100,"maturity":"proactive","checks_passed":1,"checks_partial":0,"checks_failed":0,"checks_blocked":1,"checks_suppressed":0,"checks_not_in_scope":0,"checks_total":1}]
  | .score.excluded=[]
  | .findings=[{"id":"FX-004","title":"signal check could not be read","severity":"low","area":"signals","status":"blocked","lifecycle":"new","scoring_scope":"readiness","report_lanes":["ai-sre-readiness"],"points_recoverable":0,"affected":["scope-a"],"evidence":[{"check":"signal read","command":"query","observed":"HTTP 403"}],"recommendation":"grant the missing read scope","remediation":"doc#access"}]
  | .severity_counts={"critical":0,"high":0,"medium":0,"low":1,"info":0}
' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
fp="$(fp_of "$WORK/f.json")"; jq --arg fp "$fp" '.score.check_set=$fp' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
expect_fail "checker accepted end_to_end=true with 50% assessment coverage (coverage completeness gate missing)"
echo "PASS"

echo "Test 30: a category re-weighting changes the check_set fingerprint (re-weighted runs are not score-comparable)"
write_v2
set_a="$(jq -r '.score.check_set' "$WORK/f.json")"
# Same checks and same per-category scores, only the weights (and the reconciling overall) change.
jq '.score.categories[0].weight=90 | .score.categories[1].weight=10 | .score.overall=67' "$WORK/f.json" > "$WORK/f.tmp" && mv "$WORK/f.tmp" "$WORK/f.json"
set_b="$(fp_of "$WORK/f.json")"
[ "$set_a" != "$set_b" ] || fail "re-weighting did not change the check_set fingerprint — a re-weighted run would render a fabricated trend delta"
echo "PASS"

echo "Test 2: real repo fleet — the 4 known-clean latest runs PASS"
for t in alert-routing digitalocean elk pagerduty; do
  f="$ROOT/../scoutflo-audits/$t/2026-07-31/findings.json"
  [ -f "$f" ] || { echo "  (skip $t — not present)"; continue; }
  sh "$CHECK" "$f" >/dev/null 2>&1 || fail "checker rejected known-clean $t"
done
echo "PASS"

echo "Test 3: score that does NOT reconcile with the scorecard is REJECTED"
# bump overall to 60 (scorecard supports ~46) -> delta > 1.
mutate '.score.overall = 60'
expect_fail "checker accepted a score that overstates the scorecard"
echo "PASS"

echo "Test 4: severity_counts not matching the histogram is REJECTED"
mutate '.severity_counts.critical = 9'
expect_fail "checker accepted wrong severity_counts"
echo "PASS"

echo "Test 5: a missing required envelope field is REJECTED"
mutate 'del(.toolkit_version)'
expect_fail "checker accepted a findings.json missing toolkit_version"
echo "PASS"

echo "Test 6: an empty remediation pointer is REJECTED"
mutate '.findings[0].remediation = ""'
expect_fail "checker accepted an empty remediation"
echo "PASS"

echo "Test 7: category weights not summing to 100 is REJECTED"
mutate '.score.categories[0].weight = 5'
expect_fail "checker accepted weights that do not sum to 100"
echo "PASS"

echo "Test 8: a malformed finding ID is REJECTED"
mutate '.findings[0].id = "lowercase-1"'
expect_fail "checker accepted a malformed finding ID"
echo "PASS"

echo "Test 9: end_to_end=true below the gate is REJECTED"
mutate '.score.end_to_end = true'
expect_fail "checker accepted end_to_end=true with overall<85"
echo "PASS"

echo "Test 10: an info finding with non-zero points_recoverable is REJECTED"
mutate '(.findings[] | select(.severity=="info") | .points_recoverable) = 3'
expect_fail "checker accepted info finding with non-zero points_recoverable"
echo "PASS"

echo
echo "=== check-findings self-test passed ==="
