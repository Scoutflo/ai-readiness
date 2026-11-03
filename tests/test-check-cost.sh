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
echo "Test 24: the GCP cost lane resolves its project+billing export from config, per target"
GCPCOST="$ROOT/skills/audit-cost/references/gcp-cost.md"
K8SCOST="$ROOT/skills/audit-cost/references/kubernetes-cost.md"
DOC="$ROOT/skills/doctor/scripts/doctor.sh"

# The lane must READ its target through the shared enumerator, never a hand-filled literal.
# A hardcoded placeholder is what made a multi-project `gcp:` list unusable: there is no single
# gcp.project to fill, so the lane either guessed a project or stopped at the operator.
for f in "$GCPCOST" "$K8SCOST"; do
  grep -qF 'report-standard/toolkit-targets.sh' "$f" \
    || fail "$(basename "$f") does not resolve its gcp target via the shared enumerator"
  grep -qF 'gcp get "$GCP_IDX" project' "$f" \
    || fail "$(basename "$f") does not read project from the selected gcp target"
  grep -q 'your-project-id' "$f" \
    && fail "$(basename "$f") still hardcodes a single-project placeholder"
done
grep -qF 'gcp get "$GCP_IDX" billing_bq_dataset' "$GCPCOST" || fail "gcp-cost.md does not read billing_bq_dataset per target"
grep -qF 'gcp get "$GCP_IDX" billing_project' "$GCPCOST"    || fail "gcp-cost.md does not read billing_project per target"
grep -qF '[ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"' "$GCPCOST" \
  || fail "gcp-cost.md does not default billing_project to this target's own project"

# And no billing path addresses the dataset through the AUDITED project.
for pat in '${GCP_PROJECT}.${BILLING_DATASET}' 'bq ls --project_id="$GCP_PROJECT" --format=json "$BILLING_DATASET"' 'bq query --project_id="$GCP_PROJECT"'; do
  grep -qF "$pat" "$GCPCOST" && fail "a billing path still uses gcp.project to reach the dataset: $pat"
done
grep -qF 'bq ls --project_id="$BILLING_PROJECT"' "$GCPCOST" || fail "the table lookup does not use BILLING_PROJECT"
grep -qF '${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}' "$GCPCOST" || fail "the FROM clause does not use BILLING_PROJECT"
grep -qF 'bq query --project_id="$BILLING_PROJECT"' "$GCPCOST" || fail "the query job does not run in BILLING_PROJECT"
grep -qF 'Nothing here implements' "$GCPCOST" && fail "in-block prose still claims a default the block now implements"

# Doctor probes the same project, and falls back the same way (unchanged by this move).
grep -qF '"$_gpi" billing_project' "$DOC" || fail "doctor does not READ gcp.billing_project from the config"
grep -qF '[ -n "$GCP_BQ_PROJ" ] || GCP_BQ_PROJ="$GCP_PROJECT"' "$DOC" || fail "doctor does not default billing_project to gcp.project"
grep -qF 'bq ls --project_id="$GCP_BQ_PROJ"' "$DOC" || fail "doctor still probes the dataset in the audited project"
grep -qF 'set gcp.billing_project' "$DOC" || fail "doctor never tells the operator about gcp.billing_project on a failure"

# ---- BEHAVIOURAL: run the published blocks against real configs -----------------
# Not a re-implementation: extract every billing block verbatim, point it at a toolkit.yaml,
# and record what `bq` was actually asked to do.
BEH="$WORK/beh"; mkdir -p "$BEH/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/bq.log"\nexit 1\n' "$BEH" > "$BEH/bin/bq"
printf '#!/bin/sh\necho stub-token\n' > "$BEH/bin/gcloud"
chmod +x "$BEH/bin/bq" "$BEH/bin/gcloud"
for binary in curl aws az kubectl doctl; do
  printf '#!/bin/sh\nexit 97\n' > "$BEH/bin/$binary"
  chmod +x "$BEH/bin/$binary"
done
awk '/^```bash$/{n++; inb=1; next} inb && /^```$/{inb=0; next} inb{print > ("'"$BEH"'/blk." n ".sh")}' "$GCPCOST"

cat > "$BEH/single.yaml" <<'YAML'
gcp:
  project: SENTINEL-PROJECT
  billing_bq_dataset: SENTINEL-DATASET
  billing_project: SENTINEL-BILLING
YAML
cat > "$BEH/multi.yaml" <<'YAML'
gcp:
  - label: alpha
    project: SENTINEL-ALPHA
    billing_bq_dataset: DS-ALPHA
  - label: beta
    project: SENTINEL-BETA
    billing_bq_dataset: DS-BETA
    billing_project: SENTINEL-BETA-BILLING
YAML

run_blocks() { # <config> <audit-dir-tag> [SCOUTFLO_TARGET]
  : > "$BEH/bq.log"; _n=0
  for b in "$BEH"/blk.*.sh; do
    grep -q 'BILLING_DATASET=' "$b" || continue
    _n=$((_n+1))
    ( cd "$BEH" && PATH="$BEH/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" \
        SCOUTFLO_CONFIG="$1" SCOUTFLO_AUDIT_DIR="$BEH/$2" SCOUTFLO_TARGET="${3:-}" \
        sh "$b" >/dev/null 2>&1 || true )
  done
  BLOCKS_RUN=$_n
}

# (a) single block: the dataset is reached through billing_project, never the audited project.
run_blocks "$BEH/single.yaml" out-single
[ "$BLOCKS_RUN" -ge 8 ] || fail "extracted only $BLOCKS_RUN billing blocks, expected >=8"
[ -s "$BEH/bq.log" ] || fail "no bq invocation recorded for the single-block config"
grep -q 'SENTINEL-BILLING' "$BEH/bq.log" || fail "no bq call targeted the billing project: $(head -3 "$BEH/bq.log")"
grep -q 'project_id=SENTINEL-PROJECT' "$BEH/bq.log" \
  && fail "a bq call ran in the AUDITED project instead of the billing project"
grep -q 'SENTINEL-PROJECT\.SENTINEL-DATASET' "$BEH/bq.log" \
  && fail "a query addressed the dataset through the AUDITED project"
echo "PASS"

echo "Test 25: a multi-project gcp: list stops instead of billing the wrong project"
# No SCOUTFLO_TARGET: cloud spend is per project, so the lane must refuse to pick one.
run_blocks "$BEH/multi.yaml" out-noselect
if [ -s "$BEH/bq.log" ]; then
  fail "a gcp: LIST with no SCOUTFLO_TARGET still queried billing: $(head -3 "$BEH/bq.log")"
fi
# The refusal has to be actionable — it names the labels the operator can choose.
_msg="$( cd "$BEH" && PATH="$BEH/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" \
          SCOUTFLO_CONFIG="$BEH/multi.yaml" sh "$(grep -l 'BILLING_DATASET=' "$BEH"/blk.*.sh | head -1)" 2>&1 || true )"
case "$_msg" in
  *alpha*beta*) : ;;
  *) fail "the multi-project refusal does not list the selectable labels: $_msg" ;;
esac

# With a target selected: that target's project and ITS billing project are used, not the other's.
run_blocks "$BEH/multi.yaml" out-beta beta
[ -s "$BEH/bq.log" ] || fail "SCOUTFLO_TARGET=beta produced no bq invocation"
grep -q 'SENTINEL-BETA-BILLING' "$BEH/bq.log" || fail "the selected target's billing project was not used: $(head -3 "$BEH/bq.log")"
grep -q 'DS-ALPHA' "$BEH/bq.log" && fail "the UNSELECTED target's dataset was queried"
grep -q 'SENTINEL-ALPHA' "$BEH/bq.log" && fail "the UNSELECTED target's project was queried"
echo "PASS"

echo "PASS"


# --- the Recommender preflight must test the call the AUDIT makes -------------
# Live-caught on a customer run: the doctor probed recommender.googleapis.com over
# raw REST with only an Authorization header, which omits the quota project Google
# requires for a USER credential. All four of their projects reported 403, the whole
# native-dollar section was excluded, and the report carried $0 of priced savings on
# an estate that had them — while `gcloud recommender recommendations list` read the
# same recommendations fine. A preflight that exercises a different code path than
# the thing it gates fails closed on a working setup.
echo "Test 26: the Recommender preflight uses gcloud (the audit's own call), not raw REST"
DOC="$ROOT/skills/doctor/scripts/doctor.sh"
grep -qF 'recommender.googleapis.com/v1/projects' "$DOC" \
  && fail "the doctor still probes the Recommender over raw REST, which 403s on a user credential (no quota project) while the audit's gcloud call succeeds"
grep -qF 'gcloud recommender recommendations list' "$DOC" \
  || fail "the doctor does not probe the Recommender with the same call audit-cost makes"
# An API-disabled project PROMPTS to enable and WAITS unless prompts are off — a hang,
# or a write, inside a read-only gate.
_rec_line="$(grep -n 'gcloud recommender recommendations list' "$DOC" | head -1 | cut -d: -f1)"
sed -n "$((_rec_line-1)),$((_rec_line))p" "$DOC" | grep -qF 'CLOUDSDK_CORE_DISABLE_PROMPTS=1' \
  || fail "the Recommender probe can prompt to enable a disabled API (no CLOUDSDK_CORE_DISABLE_PROMPTS)"
# Both families still probed: compute alone is a false green for committed-use savings.
grep -qF 'google.compute.image.IdleResourceRecommender' "$DOC" || fail "the compute recommender family is no longer probed"
# The probe must name the recommender audit-cost ACTUALLY calls for COST-GCP-007.
# Pinning a different one is how the preflight drifted from the audit in the first place.
grep -qF 'google.compute.commitment.UsageCommitmentRecommender' "$DOC" || fail "the commitment (CUD) probe does not use google.compute.commitment.UsageCommitmentRecommender, the recommender COST-GCP-007 actually reads"
# Each failure must name its own cause rather than a bare status code.
# NOTE: no 'gcloud is not installed' case. That arm is unreachable (doctor has
# already proved `command -v gcloud` succeeds and reports binary-gcloud itself), and
# asserting it was VACUOUS — the string is satisfied by the pre-existing binary-gcloud
# hint text, so the whole branch could be deleted with this test still green.
for c in 'the Recommender API is not enabled on this project' 'lacks roles/recommender.viewer'; do
  grep -qF "$c" "$DOC" || fail "the probe cannot report the distinct cause: $c"
done
echo "PASS"

# --- per-target cost output must not collide ----------------------------------
# The GCP lane now STOPS on a multi-project `gcp:` list unless SCOUTFLO_TARGET says
# which project to cost, so a multi-project estate necessarily runs this skill once
# per target. A flat cost/<date>/ would make the second run of the day silently
# OVERWRITE the first — a whole project's findings lost with no error.
echo "Test 27: cost output nests per target, so same-day runs cannot overwrite each other"
CSKILL="$ROOT/skills/audit-cost/SKILL.md"
grep -qF 'COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"' "$CSKILL" \
  || fail "audit-cost does not build a per-target output segment"
grep -qF 'OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}/' "$CSKILL" \
  || fail "audit-cost does not use the per-target segment in its output path"
grep -qF 'OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/$(date' "$CSKILL" \
  && fail "audit-cost still writes to a flat cost/<date>/ path, so two targets collide on the same day"
# Behavioural: the expression must actually separate targets, and leave a
# single-target estate exactly where it was.
_seg() { SCOUTFLO_TARGET="${1:-}"; printf '%s' "cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"; }
[ "$(_seg '')" = "cost" ] || fail "an unset SCOUTFLO_TARGET changed the output path for a single-target estate: $(_seg '')"
[ "$(_seg prod-in2)" = "cost/prod-in2" ] || fail "a selected target did not nest: $(_seg prod-in2)"
[ "$(_seg prod-in2)" != "$(_seg dev-two)" ] || fail "two different targets resolved to the same output path"
unset SCOUTFLO_TARGET
echo "PASS"

echo

# Current v1 envelope contract, while archived versions remain readable.
echo "Test 28: current summaries require explicit evidence fields; legacy omission stays valid"
modern() {
  good | jq '.toolkit_version="0.1.238" |
    .summary.observed_monthly_spend={amount:3400,currency:"USD",period:"2026-10",source:"billing export"} |
    .summary.savings_pct_of_spend=10 | .summary.unassessed_monthly_spend=null |
    .summary.unit_economics=[{unit_name:"orders",excluded_reason:"volume unavailable"}]'
}
modern > "$WORK/f.json"; expect_ok "current summary rejected"
for field in observed_monthly_spend savings_pct_of_spend unassessed_monthly_spend unit_economics; do
  modern | jq --arg f "$field" 'del(.summary[$f])' > "$WORK/f.json"
  expect_fail "missing current $field accepted"
done
mutate '.'; expect_ok "archived v1 report no longer accepted"
mutate '.toolkit_version="unknown"'; expect_fail "invalid version bypasses current fields"
modern | jq '.toolkit_version="0.2.0" | del(.summary.unit_economics)' > "$WORK/f.json"
expect_fail "new minor version bypasses current fields"
echo "PASS"

echo "Test 29: spend percentage must reconcile and unknown spend is explicit"
for mutation in '.summary.savings_pct_of_spend=99' '.summary.observed_monthly_spend.amount=-1' \
  '.summary.observed_monthly_spend.source=""' '.summary.observed_monthly_spend=null' \
  '.summary.observed_monthly_spend.currency="EUR"' '.summary.observed_monthly_spend.amount=0'; do
  modern | jq "$mutation" > "$WORK/f.json"; expect_fail "invalid spend context accepted: $mutation"
done
modern | jq '.summary.observed_monthly_spend=null | .summary.savings_pct_of_spend=null' > "$WORK/f.json"
expect_ok "honest unknown spend rejected"
modern | jq '.summary.unassessed_monthly_spend={amount:400,currency:"USD",projects_or_targets:["unread-project"],reason:"inventory denied"}' > "$WORK/f.json"
expect_ok "valid unassessed spend rejected"
modern | jq '.summary.unassessed_monthly_spend={amount:400,currency:"USD",projects_or_targets:[],reason:""}' > "$WORK/f.json"
expect_fail "unassessed spend hides targets or cause"
echo "PASS"

echo "Test 30: unit economics is auditable arithmetic, never savings"
units() {
  modern | jq '.summary.unit_economics=[{unit_name:"orders",per:1000,
    spend:100,spend_prev:120,volume:10000,volume_prev:10000,
    unit_cost:10,unit_cost_prev:12,trend_pct:-16.666667,currency:"USD",
    spend_source:"billing export",volume_source:"declared PromQL",basis:"Oct vs Sep closed periods, same scope"}]'
}
units > "$WORK/f.json"; expect_ok "valid unit arithmetic rejected"
for mutation in 'del(.summary.unit_economics[0].volume_prev)' '.summary.unit_economics[0].volume=0' \
  '.summary.unit_economics[0].unit_cost=11' '.summary.unit_economics[0].trend_pct=10' \
  '.summary.unit_economics[0].volume_source=""' '.summary.unit_economics[0].estimated_monthly_savings_usd=5' \
  '.summary.unit_economics[0].excluded_reason="misaligned windows"'; do
  units | jq "$mutation" > "$WORK/f.json"; expect_fail "invalid unit arithmetic accepted: $mutation"
done
modern | jq '.summary.unit_economics=[]' > "$WORK/f.json"
expect_fail "missing unit declaration is silent (no COST-UNIT-004)"
modern | jq '.summary.unit_economics=[] | .findings += [.findings[1] | .id="COST-UNIT-004" | .title="No unit declared"] | .summary.opportunities_total=3 | .summary.presence_fact_opportunities=2' > "$WORK/f.json"
expect_ok "unit enablement finding rejected"
echo "PASS"

echo "Test 31: every AWS/Azure block selects the configured target before any provider call"
BIND="$WORK/bind"; mkdir -p "$BIND/bin" "$BIND/home"
export BIND_LOG="$BIND/calls"
for binary in aws az curl gcloud bq kubectl doctl; do
  printf '#!/bin/sh\necho "unexpected %s" >> "$BIND_LOG"\nexit 97\n' "$binary" > "$BIND/bin/$binary"
done
cat > "$BIND/bin/aws" <<'STUB'
#!/bin/sh
printf 'aws %s\n' "$*" >> "$BIND_LOG"
case " $* " in
  *' sts get-caller-identity '*) printf '%s\n' '{"Account":"SENTINEL-ACCOUNT","Arn":"test-principal"}' ;;
  *' get-enrollment-status '*) printf '%s\n' '{"status":"Active"}' ;;
  *) printf '%s\n' '{"Reservations":[],"Volumes":[],"Addresses":[],"Snapshots":[],"DBInstances":[],"DBSnapshots":[],"LoadBalancers":[],"AutoScalingGroups":[],"Functions":[],"items":[],"checks":[],"SavingsPlansCoverages":[],"Recommendations":[],"Anomalies":[],"Datapoints":[]}' ;;
esac
STUB
cat > "$BIND/bin/az" <<'STUB'
#!/bin/sh
printf 'az %s\n' "$*" >> "$BIND_LOG"
case " $* " in
  *' account show '*) printf '%s\n' '{"id":"SENTINEL-BETA","tenantId":"SENTINEL-TENANT"}' ;;
  *' account get-access-token '*) echo stub-token ;;
  *' advisor recommendation list '*) echo '[]' ;;
  *' resource list '*)
    [ "${SIZE_FAIL:-0}" = 0 ] || exit 33
    jq -cn --argjson n "${SIZE_COUNT:-0}" '[range(0;$n) | {id:("resource-"+tostring)}]' ;;
  *) exit 97 ;;
esac
STUB
cat > "$BIND/bin/curl" <<'STUB'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$BIND_LOG"
printf '%s\n200' '{"data":[],"count":0,"properties":{"columns":[],"rows":[]}}'
STUB
chmod +x "$BIND/bin/"*
cat > "$BIND/config.yaml" <<'YAML'
aws:
  - label: alpha
    profile: SENTINEL-ALPHA
    region: REGION-ALPHA
  - label: beta
    profile: SENTINEL-BETA
    account_id: SENTINEL-ACCOUNT
    region: REGION-BETA
azure:
  - label: alpha
    subscription_id: SENTINEL-ALPHA
  - label: beta
    subscription_id: SENTINEL-BETA
YAML
for provider in aws azure; do
  mkdir -p "$BIND/$provider"
  awk '/^```bash$/{n++; inb=1; next} inb && /^```$/{inb=0; next} inb{print > ("'"$BIND/$provider"'/block." n ".sh")}' "$ROOT/skills/audit-cost/references/$provider-cost.md"
  : > "$BIND_LOG"
  for block in "$BIND/$provider"/*.sh; do
    (cd "$BIND" && HOME="$BIND/home" PATH="$BIND/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_CONFIG="$BIND/config.yaml" SCOUTFLO_TARGET= sh "$block" > /dev/null 2>&1) && fail "unselected $provider list did not stop: $block"
  done
  [ ! -s "$BIND_LOG" ] || fail "$provider queried before selecting a target"
  for block in "$BIND/$provider"/*.sh; do
    # Doctor-matrix block is target-bound too, but not a provider query.
    grep -q 'MATRIX=' "$block" && continue
    (cd "$BIND" && HOME="$BIND/home" PATH="$BIND/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_CONFIG="$BIND/config.yaml" SCOUTFLO_TARGET=beta sh "$block" >/dev/null 2>&1) || fail "selected $provider block failed: $block"
  done
  [ -s "$BIND_LOG" ] || fail "no selected $provider calls observed"
  grep -q 'SENTINEL-ALPHA\|REGION-ALPHA' "$BIND_LOG" && fail "unselected $provider target leaked into calls"
  if [ "$provider" = aws ]; then
    awk '/^aws / && $0 !~ /--profile SENTINEL-BETA/ {bad=1} END{exit bad}' "$BIND_LOG" || fail "AWS call used ambient profile"
    awk '/^aws / && $0 !~ /--region / {bad=1} END{exit bad}' "$BIND_LOG" || fail "AWS call used ambient region"
  else
    awk '/^az / && $0 !~ /--subscription SENTINEL-BETA/ {bad=1} END{exit bad}' "$BIND_LOG" || fail "Azure call used ambient subscription"
  fi
done
echo "PASS"


echo "Test 32: real sizing counts cross the checkpoint; denied reads are unknown"
SCOPE="$BIND/scope"; mkdir -p "$SCOPE"
awk '/^```bash$/{n++; inb=1; next} inb && /^```$/{inb=0; next} inb{print > ("'"$SCOPE"'/block." n ".sh")}' "$ROOT/skills/audit-cost/references/estate-scope.md"
awk '/^```bash$/{n++; inb=1; next} inb && /^```$/{inb=0; next} inb{print > ("'"$SCOPE"'/skill." n ".sh")}' "$ROOT/skills/audit-cost/SKILL.md"
cat > "$SCOPE/config.yaml" <<'YAML'
azure:
  subscription_id: SENTINEL-BETA
YAML
cost_scope_run() {
  (cd "$BIND" && HOME="$BIND/home" PATH="$BIND/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT" \
    SCOUTFLO_CONFIG="${COST_SCOPE_CONFIG:-$SCOPE/config.yaml}" SCOUTFLO_AUDIT_DIR="$SCOPE/audits" SCOUTFLO_TARGET="${COST_SCOPE_TARGET:-}" \
    SIZE_COUNT="${SIZE_COUNT:-0}" SIZE_FAIL="${SIZE_FAIL:-0}" COST_RUN_ID="${COST_RUN_ID:-}" \
    COST_RUN_DIR="${COST_RUN_DIR:-}" COST_BATCH_ID="${COST_BATCH_ID:-}" sh "$1")
}
CHECKPOINT=$(grep -l 'TOTAL=$(jq' "$SCOPE"/skill.*.sh)
SIZE_COUNT=600; cost_scope_run "$SCOPE/block.1.sh" > "$SCOPE/collect.out"
jq -e '(.objects|length)==600 and (.unknown|length)==0' "$SCOPE/audits/cost/sizing.json" >/dev/null || fail "sizing did not count provider objects"
printf 'n\n' | cost_scope_run "$CHECKPOINT" > "$SCOPE/checkpoint.out"
grep -q 'Proceed?' "$SCOPE/checkpoint.out" || fail "600 objects skipped the scope confirmation"
SIZE_COUNT=5; cost_scope_run "$SCOPE/block.1.sh" > /dev/null
cost_scope_run "$CHECKPOINT" > "$SCOPE/small.out"
grep -q 'Proceed?' "$SCOPE/small.out" && fail "five objects got large-estate ceremony"
SIZE_FAIL=1; cost_scope_run "$SCOPE/block.1.sh" > /dev/null
jq -e '(.objects|length)==0 and (.unknown|length)==1' "$SCOPE/audits/cost/sizing.json" >/dev/null || fail "denied inventory became known empty"
printf 'n\n' | cost_scope_run "$CHECKPOINT" > "$SCOPE/unknown.out"
grep -q 'Proceed?' "$SCOPE/unknown.out" || fail "unknown count skipped scope decision"
SIZE_FAIL=0; SIZE_COUNT=3; cost_scope_run "$SCOPE/block.1.sh" > /dev/null
echo "PASS"

echo "Test 33: cost worklist resumes, locks and accepts only owned evidence"
COST_RUN_ID=20260101T000000Z
cost_scope_run "$SCOPE/block.2.sh" > "$SCOPE/run.out"
COST_RUN_DIR="$SCOPE/audits/cost/runs/$COST_RUN_ID"
[ "$(wc -l < "$COST_RUN_DIR/worklist.tsv" | tr -d ' ')" = 3 ] || fail "worklist lost sizing rows"
if cost_scope_run "$SCOPE/block.3.sh" > /dev/null 2>&1; then fail "unapproved scope claimed a batch"; fi
printf '%s\n' '{"approved":true,"included":["azure"],"excluded":[]}' > "$COST_RUN_DIR/scope.json"
cost_scope_run "$SCOPE/block.3.sh" > "$SCOPE/claim.out"
COST_BATCH_ID=$(cat "$COST_RUN_DIR/worklist.lock/batch-id")
if cost_scope_run "$SCOPE/block.3.sh" > /dev/null 2>&1; then fail "parallel claimant acquired a held batch"; fi
jq -cn --arg batch "$COST_BATCH_ID" '{batch_id:$batch,state:"done",reason:"read captured",checks:[{command:"stub resource read",observed:"resource exists"}]}' > "$COST_RUN_DIR/evidence/$COST_BATCH_ID/0.json"
jq -cn --arg batch "$COST_BATCH_ID" '{batch_id:$batch,state:"blocked",reason:"permission denied",checks:[]}' > "$COST_RUN_DIR/evidence/$COST_BATCH_ID/1.json"
_saved_batch=$COST_BATCH_ID; COST_BATCH_ID=wrong-batch
if cost_scope_run "$SCOPE/block.4.sh" > /dev/null 2>&1; then fail "foreign batch modified worklist"; fi
COST_BATCH_ID=$_saved_batch
cost_scope_run "$SCOPE/block.4.sh" > "$SCOPE/complete.out"
grep -q 'done=1 blocked=1 excluded=0 pending=1' "$SCOPE/complete.out" || fail "unread row was marked done or blocked evidence lost"
[ ! -d "$COST_RUN_DIR/worklist.lock" ] || fail "completed batch retained lock"
COST_RUN_ID=
if cost_scope_run "$SCOPE/block.2.sh" > "$SCOPE/resume.out" 2>&1; then fail "fresh run started over pending rows"; fi
grep -q 'unfinished run:' "$SCOPE/resume.out" || fail "resume offer missing"
PUBLISH=$(grep -l 'cost batch is still locked' "$SCOPE"/skill.*.sh)
if cost_scope_run "$PUBLISH" > "$SCOPE/publish.out" 2>&1; then fail "pending work published a complete report"; fi
grep -q 'cost work remains pending' "$SCOPE/publish.out" || fail "publish failed for a reason other than pending work"
echo "PASS"

echo "Test 34: fresh-shell publication cannot bypass a pending or required worklist"
COST_RUN_DIR=; COST_RUN_ID=
if cost_scope_run "$PUBLISH" > "$SCOPE/publish-fresh.out" 2>&1; then fail "unset run variables bypassed pending work"; fi
grep -q 'cost work remains pending' "$SCOPE/publish-fresh.out" || fail "fresh publication did not recover pending state"
rm "$SCOPE/audits/cost/active-run"
if cost_scope_run "$PUBLISH" > "$SCOPE/publish-lost-pointer.out" 2>&1; then fail "missing pointer hid pending work"; fi
grep -q 'cost work remains pending' "$SCOPE/publish-lost-pointer.out" || fail "missing pointer skipped saved worklist scan"
cp "$SCOPE/audits/cost/sizing.json" "$SCOPE/sizing.saved"
mv "$SCOPE/audits/cost/runs" "$SCOPE/runs.saved"
jq '.unknown=[{provider:"azure",target:"azure",surface:"resource",reason:"denied"}]' "$SCOPE/sizing.saved" > "$SCOPE/audits/cost/sizing.json"
if cost_scope_run "$PUBLISH" > "$SCOPE/publish-no-run.out" 2>&1; then fail "unknown scope published without a worklist"; fi
grep -q 'requires a bound cost worklist' "$SCOPE/publish-no-run.out" || fail "unknown scope did not require a persisted run"
mv "$SCOPE/runs.saved" "$SCOPE/audits/cost/runs"
cp "$SCOPE/sizing.saved" "$SCOPE/audits/cost/sizing.json"
printf '%s\n' 20260101T000000Z > "$SCOPE/audits/cost/active-run"
echo "PASS"

echo "Test 35: claim and completion bind config, selected target and canonical run path"
FOREIGN="$SCOPE/foreign"; mkdir -p "$FOREIGN"
printf '%s\n' '{"approved":true,"included":["other-target"],"excluded":[]}' > "$FOREIGN/scope.json"
printf '0\tpending\tazure\tother-target\tresource\tforeign\n' > "$FOREIGN/worklist.tsv"
COST_RUN_DIR="$FOREIGN"
if cost_scope_run "$SCOPE/block.3.sh" > "$SCOPE/foreign-claim.out" 2>&1; then fail "foreign directory claimed against current config"; fi
grep -q 'belongs to another selected run or target' "$SCOPE/foreign-claim.out" || fail "foreign run rejection was not target binding"
[ ! -d "$FOREIGN/worklist.lock" ] || fail "foreign run mutated before rejection"
COST_RUN_DIR=
cost_scope_run "$SCOPE/block.3.sh" > "$SCOPE/bound-claim.out"
COST_RUN_DIR="$SCOPE/audits/cost/runs/20260101T000000Z"
COST_BATCH_ID=$(cat "$COST_RUN_DIR/worklist.lock/batch-id")
cp "$SCOPE/config.yaml" "$SCOPE/config.saved"
printf '%s\n' 'azure:' '  subscription_id: OTHER-SUBSCRIPTION' > "$SCOPE/config.yaml"
_before=$(cksum < "$COST_RUN_DIR/worklist.tsv")
for block in "$SCOPE/block.3.sh" "$SCOPE/block.4.sh"; do
  if cost_scope_run "$block" > "$SCOPE/wrong-config.out" 2>&1; then fail "changed config was accepted: $block"; fi
  grep -q 'run config changed' "$SCOPE/wrong-config.out" || fail "wrong config not detected before mutation"
done
[ "$(cksum < "$COST_RUN_DIR/worklist.tsv")" = "$_before" ] || fail "wrong-config completion changed worklist"
[ -d "$COST_RUN_DIR/worklist.lock" ] || fail "wrong-config completion released another run lock"
cp "$SCOPE/config.saved" "$SCOPE/config.yaml"
# A copied run under another target still has its original selected_target binding.
mkdir -p "$SCOPE/audits/cost/other/runs"
cp -R "$COST_RUN_DIR" "$SCOPE/audits/cost/other/runs/20260101T000000Z"
printf '%s\n' 20260101T000000Z > "$SCOPE/audits/cost/other/active-run"
COST_RUN_DIR=; COST_SCOPE_TARGET=other
if cost_scope_run "$SCOPE/block.4.sh" > "$SCOPE/wrong-target.out" 2>&1; then fail "copied run accepted another selected target"; fi
grep -q 'run belongs to another config or target' "$SCOPE/wrong-target.out" || fail "selected target binding missing"
COST_SCOPE_TARGET=
cost_scope_run "$SCOPE/block.4.sh" > "$SCOPE/bound-complete.out"
echo "PASS"

echo "=== check-cost self-test passed ==="
