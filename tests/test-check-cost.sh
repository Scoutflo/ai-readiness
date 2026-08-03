#!/bin/sh
# test-check-cost.sh
# Proves report-standard/check-cost.sh accepts a valid scoutflo-cost/v1 report and
# rejects each money-integrity / schema defect it exists to catch — so the gate
# that stops invented dollar figures and thin cost output is itself guarded.
# Falsifiable fixtures, runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/report-standard/check-cost.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

good() {
  cat <<'JSON'
{
  "schema":"scoutflo-cost/v1","toolkit_version":"0.1.79","skill":"audit-cost","target":"cost",
  "run_date":"2026-08-03","generated_at":"2026-08-03T12:00:00Z",
  "providers_covered":["aws"],
  "summary":{"opportunities_total":2,"opportunities_with_native_figure":1,"presence_fact_opportunities":1,
    "monthly_savings_identified_usd":340,"annual_savings_identified_usd":4080,
    "largest_single_lever":{"id":"COST-AWS-001","monthly_usd":340,"title":"right-size"},"deduplicated_overlaps":0},
  "findings":[
    {"id":"COST-AWS-001","title":"rightsize db","provider":"aws","area":"cost-optimization","signal":"rightsizing","status":"validated-live","affected":["rds/db-primary (ap-south-2, db.r5.xlarge)"],"estimated_monthly_savings_usd":340,"savings_source":"aws-compute-optimizer","evidence":[{"check":"co","command":"aws compute-optimizer get-rds-database-recommendations","observed":"savings 340"}],"recommendation":"right-size to db.r5.large"},
    {"id":"COST-AWS-004","title":"unattached ebs","provider":"aws","area":"cost-optimization","signal":"unattached-storage","status":"validated-live","affected":["vol-0a1 (100GB gp3)"],"estimated_monthly_savings_usd":null,"savings_source":null,"evidence":[{"check":"vol","command":"aws ec2 describe-volumes","observed":"4 available"}],"recommendation":"delete after snapshot"}
  ]
}
JSON
}
mutate() { good | jq "$1" > "$WORK/f.json"; }
expect_ok()   { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { sh "$CHECK" "$WORK/f.json" 2>&1 | grep COST-FAIL; fail "$1"; }; }
expect_fail() { sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 && fail "$1"; return 0; }

echo "=== check-cost self-test ==="

echo "Test 1: a valid cost report (1 priced + 1 presence-fact) PASSES"
mutate '.'; expect_ok "checker rejected a valid cost report"
echo "PASS"

echo "Test 2: an INVENTED savings total is REJECTED"
mutate '.summary.monthly_savings_identified_usd = 9999'
expect_fail "checker accepted a savings total that doesn't sum the native figures"
echo "PASS"

echo "Test 3: a presence-fact given a dollar figure (no source) is REJECTED"
mutate '.findings[1].estimated_monthly_savings_usd = 50'
expect_fail "checker accepted a dollar figure on a finding with no savings_source"
echo "PASS"

echo "Test 4: annual != monthly*12 is REJECTED"
mutate '.summary.annual_savings_identified_usd = 1'
expect_fail "checker accepted inconsistent annual figure"
echo "PASS"

echo "Test 5: presence-fact-before-priced ordering is REJECTED"
mutate '.findings |= reverse'
expect_fail "checker accepted findings not ordered native-figure-first"
echo "PASS"

echo "Test 6: a finding with empty 'affected' (no concrete resource) is REJECTED"
mutate '.findings[0].affected = []'
expect_fail "checker accepted a finding with no concrete resource"
echo "PASS"

echo "Test 7: a malformed cost ID is REJECTED"
mutate '.findings[0].id = "AWS-1"'
expect_fail "checker accepted a malformed cost finding ID"
echo "PASS"

echo "Test 8: wrong summary counts (native/presence split) is REJECTED"
mutate '.summary.opportunities_with_native_figure = 5'
expect_fail "checker accepted a wrong native-figure count"
echo "PASS"

echo "Test 9: a non-cost-optimization area is REJECTED"
mutate '.findings[0].area = "reliability"'
expect_fail "checker accepted a finding whose area isn't cost-optimization"
echo "PASS"

echo "Test 10: empty providers_covered is REJECTED"
mutate '.providers_covered = []'
expect_fail "checker accepted an empty providers_covered"
echo "PASS"

echo
echo "=== check-cost self-test passed ==="
