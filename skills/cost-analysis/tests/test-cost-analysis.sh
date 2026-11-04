#!/bin/sh
# test-cost-analysis.sh — tests the real cost-analysis library
# (lib/cost-analysis.sh) under /bin/sh with runtime-built fixtures.
#
# Regression-locks the cross-provider cost roll-up's directory enumeration:
#   R1. cost_analysis_aggregate_findings collects cost-optimization findings from
#       the ONE-level layout <integration>/<date>/findings.json.
#   R2. it ALSO collects them from the TWO-level layout
#       <integration>/<label>/<date>/findings.json (multi-target labels, and the
#       always-two-level signoz/kubernetes) — a one-level-only glob would drop
#       these, silently under-reporting savings for the exact multi-account /
#       multi-subscription / multi-target estates the roll-up is meant to serve.
#   R3. it skips the derived/combined dirs (all/, cost-analysis/, cost/, doctor/)
#       so their findings.json is never mistaken for a scored per-audit file.
#   R4. it selects only area=="cost-optimization" findings (never a reliability one).
# All fixture names are synthetic; no real estate values.

set -eu

LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

DATE="2026-01-15"

# The lib reads AUDITS_DIR from SCOUTFLO_AUDIT_DIR at source time — set it first.
SCOUTFLO_AUDIT_DIR="$TMP_ROOT"
export SCOUTFLO_AUDIT_DIR
# shellcheck disable=SC1090
. "$LIB_DIR/cost-analysis.sh"

# write_findings <dir-under-root> <target> <findings-json-array>
write_findings() {
  d="$TMP_ROOT/$1/$DATE"
  mkdir -p "$d"
  cat > "$d/findings.json" <<EOF
{ "schema": "scoutflo-audit/v1", "target": "$2", "run_date": "$DATE",
  "findings": $3 }
EOF
}

COST='[{"id":"X-001","title":"idle thing","area":"cost-optimization","affected":["svc-a"],"estimated_monthly_savings_usd":100}]'
COST2='[{"id":"Y-001","title":"oversized thing","area":"cost-optimization","affected":["svc-b"],"estimated_monthly_savings_usd":200}]'
RELIAB='[{"id":"R-001","title":"no alerts","area":"coverage","affected":["svc-c"]}]'

# R1: one-level cost finding
write_findings "aws" "aws" "$COST"
# R4 negative: a reliability finding in the same one-level target must NOT be collected
write_findings "grafana" "grafana" "$RELIAB"
# R2: two-level (multi-target label) cost finding
write_findings "azure/prod-core" "azure/prod-core" "$COST2"
# R3: derived/combined dirs that must be skipped even though they carry cost-area findings
write_findings "all" "all" "$COST"
write_findings "cost" "cost" "$COST"
write_findings "cost-analysis" "cost-analysis" "$COST"

OUT="$(cost_analysis_aggregate_findings "$DATE")"

# R1 + R2: exactly the two real cost findings, from both layouts
n="$(printf '%s' "$OUT" | jq 'length')"
[ "$n" = "2" ] || fail "expected 2 aggregated cost findings (one-level + two-level), got $n: $OUT"
printf '%s' "$OUT" | jq -e 'any(.[]; .id=="X-001" and .source_target=="aws")' >/dev/null \
  || fail "R1: one-level aws cost finding X-001 not collected"
printf '%s' "$OUT" | jq -e 'any(.[]; .id=="Y-001" and .source_target=="azure/prod-core")' >/dev/null \
  || fail "R2: two-level azure/prod-core cost finding Y-001 not collected (dual-glob regression)"

# R4: the reliability finding is never present
printf '%s' "$OUT" | jq -e 'any(.[]; .id=="R-001")' >/dev/null \
  && fail "R4: non-cost finding R-001 was collected" || true

# R3: nothing from all/ cost/ cost-analysis/ (X-001 appears once — only from aws/, not the skipped dirs)
dupes="$(printf '%s' "$OUT" | jq '[.[] | select(.id=="X-001")] | length')"
[ "$dupes" = "1" ] || fail "R3: X-001 collected $dupes times — a skipped derived dir (all/cost/cost-analysis) leaked in"

# R5: a same-date empty rerun regenerates an explicit empty roll-up, so old savings
# are never presented as current after the last source finding is removed.
BC_JSON="$TMP_ROOT/no-context.json"; TOPOLOGY_FILE="$TMP_ROOT/no-topology.json"
cost_analysis_run "$DATE" >/dev/null
REPORT="$TMP_ROOT/cost-analysis/$DATE/findings.json"
jq -e '.summary.monthly_savings_identified==300' "$REPORT" >/dev/null || fail "R5 initial roll-up"
write_findings "aws" "aws" '[]'
write_findings "azure/prod-core" "azure/prod-core" '[]'
cost_analysis_run "$DATE" >/dev/null
jq -e '.summary.total_findings==0 and .summary.monthly_savings_identified==0 and .summary.annual_savings_identified==0 and .data_status=="no-cost-findings"' "$REPORT" >/dev/null || fail "R5 empty rerun kept stale savings or implied assessed zero spend"

# R6: blocked/closed opportunities cannot inflate current savings.
for extra in '{"status":"blocked"}' '{"status":"unknown"}' '{"status":"deferred"}' '{"lifecycle":"suppressed"}' '{"lifecycle":"resolved"}'; do
  row=$(jq -nc --argjson extra "$extra" '[{id:"X-003",title:"Unused fixture",area:"cost-optimization",estimated_monthly_savings_usd:999} + $extra]')
  write_findings "aws" "aws" "$row"
  [ "$(cost_analysis_aggregate_findings "$DATE" | jq length)" -eq 0 ] || fail "R6 unobserved/closed row inflated savings"
done
# R7: reserved names apply to integrations only, never a report root or target label.
AUDITS_DIR="$TMP_ROOT/all/reports"; mkdir -p "$AUDITS_DIR/azure/cost/$DATE" "$AUDITS_DIR/all/$DATE"
printf '%s\n' '{"target":"azure/cost","findings":[{"id":"X-004","area":"cost-optimization","estimated_monthly_savings_usd":1}]}' > "$AUDITS_DIR/azure/cost/$DATE/findings.json"
printf '%s\n' '{"target":"all","findings":[{"id":"COMBINED","area":"cost-optimization"}]}' > "$AUDITS_DIR/all/$DATE/findings.json"
[ "$(cost_analysis_aggregate_findings "$DATE" | jq -r 'map(.id)|join(",")')" = X-004 ] || fail "R7 reserved parent/label name dropped real audit or included roll-up"

# R8: the same check ID in another labeled target is a different finding.
# Monitoring overlap annotates the matching target; it cannot discount dollars.
CORRELATION_FILE="$TMP_ROOT/correlation.json"
PAIR='[{"id":"X-005","source_target":"aws/prod","estimated_monthly_savings_usd":100},{"id":"X-005","source_target":"aws/dev","estimated_monthly_savings_usd":200}]'
jq -n --arg date "$DATE" '{audit_date:$date,overlaps:[{findings:[{target:"aws/prod",finding_id:"X-005"},{target:"grafana",finding_id:"GRAF-099"}],recommendation:"Review matching service evidence"}]}' > "$CORRELATION_FILE"
ANNOTATED=$(cost_analysis_deduplicate "$PAIR" "$DATE")
printf '%s\n' "$ANNOTATED" | jq -e 'length==2 and any(.[]; .source_target=="aws/prod" and .deduplicated==true) and any(.[]; .source_target=="aws/dev" and .deduplicated==false)' >/dev/null || fail "R8 overlap leaked across labeled targets sharing a check ID"
cost_analysis_build_report "$DATE" "$ANNOTATED" '{}' | jq -e '.summary.monthly_savings_identified==300 and .summary.annual_savings_identified==3600 and .summary.deduplicated_overlaps==1 and (.note|contains("not proven unique savings"))' >/dev/null || fail "R8 monitoring overlap changed native amounts or claimed unique savings"

# R9: stale or undated correlation cannot attest overlap in this run.
jq '.audit_date="2025-12-31"' "$CORRELATION_FILE" > "$TMP_ROOT/stale-correlation.json"
mv "$TMP_ROOT/stale-correlation.json" "$CORRELATION_FILE"
cost_analysis_deduplicate "$PAIR" "$DATE" | jq -e 'all(.[]; .deduplicated==false)' >/dev/null || fail "R9 stale correlation annotated current savings"
jq 'del(.audit_date)' "$CORRELATION_FILE" > "$TMP_ROOT/undated-correlation.json"
mv "$TMP_ROOT/undated-correlation.json" "$CORRELATION_FILE"
cost_analysis_deduplicate "$PAIR" "$DATE" | jq -e 'all(.[]; .deduplicated==false)' >/dev/null || fail "R9 undated correlation annotated current savings"

# R10: malformed optional correlation keeps the native findings and announces
# that overlap evidence is unavailable, rather than inventing an annotation.
printf '%s\n' 'not-json' > "$CORRELATION_FILE"
ANNOTATED=$(cost_analysis_deduplicate "$PAIR" "$DATE" 2> "$TMP_ROOT/correlation-warning.txt")
printf '%s\n' "$ANNOTATED" | jq -e 'length==2 and (map(.estimated_monthly_savings_usd)|add)==300 and all(.[]; .deduplicated!=true)' >/dev/null || fail "R10 malformed correlation lost findings or invented overlap"
grep -q 'overlap annotation unavailable' "$TMP_ROOT/correlation-warning.txt" || fail "R10 malformed correlation was silently ignored"

echo "=== cost-analysis self-test passed (R1-R10: layouts, eligibility, empty rerun, target/date-bound overlap, native amounts, degraded correlation) ==="
