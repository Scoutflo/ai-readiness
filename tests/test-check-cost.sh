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
  "providers_excluded":[{"provider":"gcp","reason":"recommender.googleapis.com disabled"}],
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

echo "Test 11: a missing providers_excluded is REJECTED (exclusions must never be silent)"
mutate 'del(.providers_excluded)'
expect_fail "checker accepted a report with no providers_excluded field"
echo "PASS"

echo "Test 12: an exclusion with no reason is REJECTED (a reasonless exclusion is a silent drop)"
mutate '.providers_excluded = [{"provider":"gcp"}]'
expect_fail "checker accepted an exclusion carrying no reason"
echo "PASS"

echo "Test 13: a provider in BOTH covered and excluded is REJECTED"
mutate '.providers_excluded = [{"provider":"aws","reason":"scope missing"}]'
expect_fail "checker accepted a provider listed as both covered and excluded"
echo "PASS"

echo "Test 14: zero native dollars with NOTHING excluded is REJECTED (blocked run must not read as 'no waste')"
mutate '.findings = [.findings[1]] | .summary.opportunities_total = 1 | .summary.opportunities_with_native_figure = 0 | .summary.presence_fact_opportunities = 1 | .summary.monthly_savings_identified_usd = 0 | .summary.annual_savings_identified_usd = 0 | .providers_excluded = []'
expect_fail "checker accepted a \$0 cost report with no stated reason"
echo "PASS"

echo "Test 15: zero native dollars WITH a stated exclusion PASSES (honest 'could not look')"
mutate '.findings = [.findings[1]] | .summary.opportunities_total = 1 | .summary.opportunities_with_native_figure = 0 | .summary.presence_fact_opportunities = 1 | .summary.monthly_savings_identified_usd = 0 | .summary.annual_savings_identified_usd = 0 | .providers_excluded = [{"provider":"aws","reason":"Cost Explorer scope missing"}] | .providers_covered = ["gcp"]'
sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { echo "FAIL: checker rejected an honest \$0 report that names its exclusion" >&2; exit 1; }
echo "PASS"

echo "Test 16: an indicative figure summed into the savings total is REJECTED"
mutate '.findings[1].indicative_monthly_usd = 100 | .findings[1].indicative_source = "published pd-standard GB-month rate, one class transition" | .summary.indicative_monthly_usd = 100 | .summary.monthly_savings_identified_usd = (.summary.monthly_savings_identified_usd + 100)'
expect_fail "checker let a published-list-price figure into the provider-native savings total"
echo "PASS"

echo "Test 17: an indicative figure with no indicative_source is REJECTED"
mutate '.findings[1].indicative_monthly_usd = 100 | .summary.indicative_monthly_usd = 100'
expect_fail "checker accepted an indicative figure that named no published price basis"
echo "PASS"

echo "Test 18: a finding carrying BOTH a native and an indicative figure is REJECTED"
mutate '.findings[0].indicative_monthly_usd = 50 | .findings[0].indicative_source = "published rate" | .summary.indicative_monthly_usd = 50'
expect_fail "checker accepted a finding with both a native and an indicative figure"
echo "PASS"

echo "Test 19: a correctly-reported indicative figure PASSES (sourced, separate, not in the total)"
mutate '.findings[1].indicative_monthly_usd = 100 | .findings[1].indicative_source = "published Nearline GB-month rate; one storage-class transition" | .summary.indicative_monthly_usd = 100'
sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { echo "FAIL: checker rejected a properly sourced, separately-reported indicative figure" >&2; exit 1; }
echo "PASS"

echo "Test 20: a utilization with no basis is REJECTED (a snapshot must not read as a trend)"
mutate '.findings[1].utilization = "6% of requests"'
expect_fail "checker accepted a utilization figure with no measurement basis"
echo "PASS"

echo "Test 21: a basis mixing a snapshot AND a window in one finding is REJECTED"
mutate '.findings[1].utilization = "6% of requests" | .findings[1].basis = "p95 over 7d and snapshot 2026-10-21T15:30Z"'
expect_fail "checker accepted one finding mixing a windowed and a snapshot basis"
echo "PASS"

echo "Test 22: a utilization with a single clear basis PASSES"
mutate '.findings[1].utilization = "6% of requests" | .findings[1].basis = "p95 over 7d"'
sh "$CHECK" "$WORK/f.json" >/dev/null 2>&1 || { echo "FAIL: checker rejected a utilization carrying one clear basis" >&2; exit 1; }
echo "PASS"

echo
echo "=== check-cost self-test passed ==="
