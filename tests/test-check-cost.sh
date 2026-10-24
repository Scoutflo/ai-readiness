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
# --- doctor: both Cloud Billing export flavours must be recognised -------------
# The DETAILED, resource-level export table is named gcp_billing_export_RESOURCE_v1_*
# and therefore does NOT contain the substring "gcp_billing_export_v1". A doctor
# that greps only the standard name reports "no export present" to a customer who
# enabled exactly the flavour the audit prefers — and it is the only flavour GKE
# cost allocation can attribute per cluster/namespace. Live-caught before a
# customer run.
echo "Test 23: doctor recognises BOTH the standard and the detailed billing export"
DOCTOR="$ROOT/skills/doctor/scripts/doctor.sh"
grep -q "grep -q 'gcp_billing_export_resource_v1'" "$DOCTOR" \
  || fail "doctor does not probe for the DETAILED export (gcp_billing_export_resource_v1_*)"
grep -q "grep -q 'gcp_billing_export_v1'" "$DOCTOR" \
  || fail "doctor no longer probes for the standard export (gcp_billing_export_v1_*)"
# The detailed branch must be tested FIRST: the standard pattern is a substring of
# neither, but ordering also decides which capability message the operator sees.
_res_ln="$(grep -n "grep -q 'gcp_billing_export_resource_v1'" "$DOCTOR" | head -1 | cut -d: -f1)"
_std_ln="$(grep -n "grep -q 'gcp_billing_export_v1'" "$DOCTOR" | head -1 | cut -d: -f1)"
[ "$_res_ln" -lt "$_std_ln" ] \
  || fail "the standard-export branch precedes the detailed one, so a detailed export would be described as standard-only"
# And prove the substring trap itself, so nobody 'simplifies' this back to one grep.
printf '%s' 'gcp_billing_export_resource_v1_0123AB_ABCDEF' | grep -q 'gcp_billing_export_v1' \
  && fail "assumption broken: the detailed table name now contains the standard pattern; simplify the doctor branches"
printf '%s' 'gcp_billing_export_v1_0123AB_ABCDEF' | grep -q 'gcp_billing_export_v1' \
  || fail "the standard pattern no longer matches the standard table name"
echo "PASS"

# --- gcp.billing_project: the export dataset may live in another project -------
# A Cloud Billing export is commonly written to a dedicated billing/admin project.
# The audit addresses the table as <project>.<dataset>.<table>, so without an
# optional billing_project the only way to read it was to point gcp.project at the
# billing project — which would then aim every GCP resource check at the wrong
# place. Live-caught while preparing a customer re-run.
echo "Test 24: the billing export is addressed via gcp.billing_project, falling back to gcp.project"
GCPCOST="$ROOT/skills/audit-cost/references/gcp-cost.md"
DOC="$ROOT/skills/doctor/scripts/doctor.sh"

# Every billing block resolves the host project with the documented default.
n_decl="$(grep -c 'BILLING_PROJECT="your-project-id"' "$GCPCOST" || true)"
[ "${n_decl:-0}" -ge 8 ] || fail "expected >=8 BILLING_PROJECT declarations in gcp-cost.md, got ${n_decl:-0}"
# It must follow this file's convention: a literal placeholder the model fills from
# config, NOT a shell fallback. A shell fallback would silently honour an inherited
# BILLING_PROJECT from an unrelated run, and a model filling placeholders may not
# substitute an expression at all.
grep -qF 'BILLING_PROJECT="${BILLING_PROJECT:-' "$GCPCOST" \
  && fail "BILLING_PROJECT uses a shell fallback instead of this file's placeholder convention"
# Every declaration must name BOTH keys, so the fallback rule is unambiguous to the model.
n_doc="$(grep -c 'gcp.billing_project when set, ELSE the same value as gcp.project' "$GCPCOST" || true)"
[ "${n_doc:-0}" -ge 8 ] || fail "only ${n_doc:-0} of the BILLING_PROJECT placeholders state the gcp.project fallback"

# And no billing path still addresses the dataset through the audited project.
for pat in '${GCP_PROJECT}.${BILLING_DATASET}' 'bq ls --project_id="$GCP_PROJECT" --format=json "$BILLING_DATASET"' 'bq query --project_id="$GCP_PROJECT"'; do
  if grep -qF "$pat" "$GCPCOST"; then
    fail "a billing path still uses gcp.project to reach the dataset: $pat"
  fi
done

# The three places that must use the host project each do.
grep -qF 'bq ls --project_id="$BILLING_PROJECT"' "$GCPCOST" || fail "the table lookup does not use BILLING_PROJECT"
grep -qF '${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}' "$GCPCOST" || fail "the FROM clause does not use BILLING_PROJECT"
grep -qF 'bq query --project_id="$BILLING_PROJECT"' "$GCPCOST" || fail "the query job does not run in BILLING_PROJECT"

# Doctor probes the same project, and falls back the same way.
grep -qF 'billing_project' "$DOC" || fail "doctor does not read gcp.billing_project"
grep -qF '[ -n "$GCP_BQ_PROJ" ] || GCP_BQ_PROJ="$GCP_PROJECT"' "$DOC" || fail "doctor does not default billing_project to gcp.project"
grep -qF 'bq ls --project_id="$GCP_BQ_PROJ"' "$DOC" || fail "doctor still probes the dataset in the audited project"
# A wrong-project mistake must be nameable from the row itself.
grep -qF 'set gcp.billing_project' "$DOC" || fail "doctor never tells the operator about gcp.billing_project on a failure"

# The doctor is where the fallback is EXECUTABLE, so assert it there rather than
# re-implementing it: an unset key resolves to gcp.project, a set one wins.
GCP_BQ_PROJ=""; GCP_PROJECT="audited-proj"
[ -n "$GCP_BQ_PROJ" ] || GCP_BQ_PROJ="$GCP_PROJECT"
[ "$GCP_BQ_PROJ" = "audited-proj" ] || fail "an unset billing_project did not fall back to gcp.project"
GCP_BQ_PROJ="billing-admin-proj"
[ -n "$GCP_BQ_PROJ" ] || GCP_BQ_PROJ="$GCP_PROJECT"
[ "$GCP_BQ_PROJ" = "billing-admin-proj" ] || fail "a set billing_project did not win over gcp.project"
echo "PASS"

echo
echo "=== check-cost self-test passed ==="
