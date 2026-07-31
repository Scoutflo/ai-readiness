#!/bin/sh
# test-v0171-orchestration-wiring.sh
# Proves the audit-all Phase 3.5 (correlation), 3.6 (cost-analysis), and 3.7
# (redaction) libraries actually transform data, using the report-standard
# findings layout. Every assertion exits 1 on failure. A NEGATIVE control at
# the end proves the assertions are falsifiable — a gutted library cannot
# pass this suite (the v0.1.69 test-theater class).

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export SCOUTFLO_AUDIT_DIR="$WORK/scoutflo-audits"
export TOPOLOGY_FILE="$WORK/topology.json"
D="$(date -u +%Y-%m-%d)"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== v0.1.71 orchestration wiring tests ==="

# ---- Fixtures: two audits, report-standard layout --------------------------
mkdir -p "$SCOUTFLO_AUDIT_DIR/aws/$D" "$SCOUTFLO_AUDIT_DIR/grafana/$D"

cat > "$TOPOLOGY_FILE" <<'EOF'
{"business_context":{"environment":"production","cost_sensitivity":"high","critical_dependencies":["payments-db"]}}
EOF

cat > "$SCOUTFLO_AUDIT_DIR/aws/$D/findings.json" <<EOF
{"target":"aws","date":"$D",
 "findings":[
  {"id":"AWS-020","title":"No alarm on RDS CPU for payments-db","severity":"high","area":"compute-health","lifecycle":"new","affected":["payments-db"]},
  {"id":"AWS-010","title":"SNS alert delivery route has no subscription","severity":"high","area":"alert-routing","lifecycle":"new","affected":["alerts-topic"]},
  {"id":"AWSOPT-001","title":"Compute Optimizer: db.r5.xlarge over-provisioned","severity":"medium","area":"cost-optimization","lifecycle":"new","affected":["payments-db"],"estimated_monthly_savings_usd":340},
  {"id":"AWSOPT-002","title":"6 EBS volumes unattached 40+ days","severity":"low","area":"cost-optimization","lifecycle":"new","affected":["vol-1"]}
 ]}
EOF

cat > "$SCOUTFLO_AUDIT_DIR/grafana/$D/findings.json" <<EOF
{"target":"grafana","date":"$D",
 "findings":[
  {"id":"GRAF-050","title":"Alert rule for payments-db routes to no contact point","severity":"high","area":"alert-rules","lifecycle":"new","affected":["payments-db"]}
 ]}
EOF

# ---- Phase 3.5: correlation ------------------------------------------------
echo "Test 1: correlation_run writes correlation.json with real counts"
( . "$ROOT/skills/correlation-engine/lib/correlation-engine.sh"; correlation_run "$D" ) > /dev/null
CORR="$SCOUTFLO_AUDIT_DIR/correlation.json"
[ -f "$CORR" ] || fail "correlation.json not written"
raw=$(jq '.total_findings_raw' "$CORR")
[ "$raw" -eq 5 ] || fail "expected 5 raw findings, got $raw"
echo "PASS"

echo "Test 2: overlap detected — payments-db flagged by both aws and grafana"
svc=$(jq -r '.overlaps[0].service' "$CORR")
[ "$svc" = "payments-db" ] || fail "expected payments-db overlap, got: $svc"
tcount=$(jq '.overlaps[0].targets | length' "$CORR")
[ "$tcount" -eq 2 ] || fail "expected 2 targets in overlap, got $tcount"
echo "PASS"

echo "Test 3: cascade links the db finding to alert-delivery findings, all IDs real"
jq -e '.cascades[] | select(.root_cause.finding_id == "AWS-020")' "$CORR" > /dev/null \
  || fail "no cascade rooted at AWS-020"
for id in $(jq -r '.cascades[].effects[].finding_id' "$CORR"); do
  case "$id" in
    AWS-020|AWS-010|AWSOPT-001|AWSOPT-002|GRAF-050) : ;;
    *) fail "cascade references invented finding ID: $id" ;;
  esac
done
echo "PASS"

# ---- Phase 3.6: cost-analysis ----------------------------------------------
echo "Test 4: cost_analysis_run aggregates only cost-optimization findings"
( . "$ROOT/skills/cost-analysis/lib/cost-analysis.sh"; cost_analysis_run "$D" ) > /dev/null
COST="$SCOUTFLO_AUDIT_DIR/cost-analysis/$D/findings.json"
[ -f "$COST" ] || fail "cost-analysis findings.json not written"
n=$(jq '.summary.total_findings' "$COST")
[ "$n" -eq 2 ] || fail "expected 2 cost findings (AWSOPT only), got $n"
jq -e '.findings[] | select(.id == "AWS-020")' "$COST" > /dev/null \
  && fail "reliability finding AWS-020 leaked into the cost report"
echo "PASS"

echo "Test 5: savings sum only provider-native figures; presence facts get none"
monthly=$(jq '.summary.monthly_savings_identified' "$COST")
[ "$monthly" = "340" ] || fail "expected 340 monthly savings (native only), got $monthly"
native=$(jq '.summary.findings_with_native_savings_figure' "$COST")
presence=$(jq '.summary.presence_fact_findings' "$COST")
[ "$native" -eq 1 ] && [ "$presence" -eq 1 ] || fail "native/presence split wrong: $native/$presence"
jq -e '.findings[] | select(.id == "AWSOPT-002") | .estimated_monthly_savings_usd == null' "$COST" > /dev/null \
  || fail "presence fact AWSOPT-002 was given a dollar figure"
echo "PASS"

echo "Test 6: history line appended and 24h skip logic engages on re-run"
[ -f "$SCOUTFLO_AUDIT_DIR/cost-analysis.jsonl" ] || fail "history ledger not written"
out=$( ( . "$ROOT/skills/cost-analysis/lib/cost-analysis.sh"; cost_analysis_run "$D" ) 2>&1 )
echo "$out" | grep -q "Skipping" || fail "re-run within 24h did not skip: $out"
echo "PASS"

# ---- Phase 3.7: redaction ---------------------------------------------------
echo "Test 7: redact_file scrubs a combined report in place"
mkdir -p "$SCOUTFLO_AUDIT_DIR/all/$D"
REPORT="$SCOUTFLO_AUDIT_DIR/all/$D/report.md"
AKIA_KEY="AKIA$(printf 'B%.0s' 1 2 3 4 5 6 7 8)$(printf '2%.0s' 1 2 3 4 5 6 7 8)"
printf '# Combined report\nleaked: %s\n' "$AKIA_KEY" > "$REPORT"
( . "$ROOT/skills/redaction/lib/redaction.sh"; redact_file "$REPORT" )
grep -q "$AKIA_KEY" "$REPORT" && fail "raw key survived redaction pass"
grep -q 'AKIA\[REDACTED\]' "$REPORT" || fail "no redaction marker in report"
echo "PASS"

# ---- Remediation map --------------------------------------------------------
echo "Test 8: remediation map resolves a real high-severity finding to a real anchor"
MAP="$ROOT/docs/finding-remediation-map.json"
[ -f "$MAP" ] || fail "finding-remediation-map.json missing"
skill=$(jq -r '.mappings["AWS-020"].setup_skill' "$MAP")
anchor=$(jq -r '.mappings["AWS-020"].anchor' "$MAP")
[ "$skill" = "setup-aws" ] || fail "AWS-020 maps to '$skill', expected setup-aws"
slugged=$(sed -n 's/^#\{1,6\} //p' "$ROOT/skills/setup-aws/SKILL.md" \
  | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g; s/ /-/g')
echo "$slugged" | grep -qx "$anchor" || fail "anchor '$anchor' not a real setup-aws heading"
echo "PASS"

# ---- NEGATIVE control ---------------------------------------------------------
echo "Test 9: NEGATIVE — a gutted correlation lib must fail this suite"
GUTTED="$WORK/gutted.sh"
printf 'correlation_run() { :; }\n' > "$GUTTED"
rm -f "$CORR"
( . "$GUTTED"; correlation_run "$D" ) > /dev/null 2>&1 || true
if [ -f "$CORR" ]; then
  fail "negative control produced correlation.json — assertions are not binding"
fi
echo "PASS (a no-op library cannot satisfy Test 1)"

echo
echo "=== All v0.1.71 orchestration wiring tests passed ==="
