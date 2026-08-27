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

echo "=== cost-analysis self-test passed (R1 one-level, R2 two-level, R3 skips, R4 area filter) ==="
