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
    {"id":"FX-001","title":"t","severity":"high","area":"escalation","status":"validated-live","lifecycle":"new","points_recoverable":5,"evidence":[{"check":"c","command":"curl x","observed":"o"}],"recommendation":"r","remediation":"setup-fixture#a"},
    {"id":"FX-002","title":"t","severity":"medium","area":"noise","status":"configured","lifecycle":"new","points_recoverable":2,"evidence":[{"check":"c","command":"curl y","observed":"o"}],"recommendation":"r","remediation":"setup-fixture#b"},
    {"id":"FX-003","title":"t","severity":"info","area":"hygiene","status":"validated-live","lifecycle":"new","points_recoverable":0,"evidence":[{"check":"c","command":"curl z","observed":"o"}],"recommendation":"r","remediation":"doc#c"}
  ]
}
JSON
}
# jq filter -> mutate the good fixture into a specific defect.
mutate() { good | jq "$1" > "$WORK/f.json"; }
expect_ok()   { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { sh "$CHECK" "$WORK/f.json" 2>&1 | grep FINDINGS-FAIL; fail "$1"; }; }
expect_fail() { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 && fail "$1"; return 0; }

echo "=== check-findings self-test ==="

echo "Test 1: a valid findings.json (excluded category renormalized) PASSES"
mutate '.'
expect_ok "checker rejected a valid findings.json"
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
