#!/bin/sh
# test-topology-guided-setup.sh
# Tests the real topology-guided-setup library against a correlation.json in
# the current (v0.1.73) shape: shared-resource-join cascades, overlap groups.
# Replaces a bats-format stub that crashed on an unbound BATS_TEST_DIRNAME and
# therefore never ran. Every assertion exits 1 on failure; runs under /bin/sh.

set -eu

LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export SCOUTFLO_AUDIT_DIR="$WORK/audits"
export TOPOLOGY_FILE="$WORK/topology.json"
mkdir -p "$SCOUTFLO_AUDIT_DIR"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== topology-guided-setup lib tests ==="

# Fixture: correlation.json in the current engine's output shape.
cat > "$SCOUTFLO_AUDIT_DIR/correlation.json" <<'EOF'
{
  "version": "2.0",
  "overlaps": [
    {
      "overlap_id": "OVL-payments-db",
      "type": "redundant_monitoring",
      "service": "payments-db",
      "targets": ["aws", "grafana"],
      "findings": [
        {"target": "aws", "finding_id": "AWS-020", "title": "No alarm on payments-db", "severity": "high"},
        {"target": "grafana", "finding_id": "GRAF-050", "title": "Alert on payments-db routes nowhere", "severity": "high"}
      ],
      "recommendation": "Review overlap"
    }
  ],
  "cascades": [
    {
      "cascade_id": "CASC-AWS-030",
      "root_cause": {"finding_id": "AWS-030", "title": "RDS payments-db no backup", "target": "aws"},
      "effects": [
        {"finding_id": "GRAF-050", "title": "Alert on payments-db routes nowhere", "target": "grafana"}
      ]
    }
  ]
}
EOF

cat > "$TOPOLOGY_FILE" <<'EOF'
{"business_context":{"environment":"production","critical_dependencies":["payments-db"]}}
EOF

. "$LIB_DIR/topology-guided-setup.sh"
correlation="$(_load_correlation)"
context="$(_load_context 2>/dev/null || printf '%s' '{"critical_dependencies":["payments-db"]}')"

echo "Test 1: overlap detection finds the redundant pair"
ovl="$(topology_guided_check_overlap "AWS-020" "$correlation")"
printf '%s' "$ovl" | jq -e '.is_redundant == true' > /dev/null \
  || fail "AWS-020 should be flagged redundant (in OVL-payments-db): $ovl"
printf '%s' "$ovl" | jq -e '.related_findings[0].finding_id == "GRAF-050"' > /dev/null \
  || fail "related finding should be GRAF-050"
echo "PASS"

echo "Test 2: cascade root detection"
root="$(topology_guided_check_cascade_root "AWS-030" "$correlation")"
printf '%s' "$root" | jq -e '.is_root_cause == true' > /dev/null \
  || fail "AWS-030 should be a cascade root: $root"
echo "PASS"

echo "Test 3: cascade impact says fix the root first"
impact="$(topology_guided_check_cascade_impact "GRAF-050" "$correlation")"
printf '%s' "$impact" | jq -e '.root_cause.finding_id == "AWS-030"' > /dev/null \
  || fail "GRAF-050's cascade root should be AWS-030: $impact"
echo "PASS"

echo "Test 4: criticality from business context"
[ "$(topology_guided_is_critical "payments-db" "$context")" = "true" ] \
  || fail "payments-db is in critical_dependencies and must be critical"
[ "$(topology_guided_is_critical "random-svc" "$context")" = "false" ] \
  || fail "random-svc must not be critical"
echo "PASS"

echo "Test 5: non-existent finding matches nothing (no invented guidance)"
none="$(topology_guided_check_overlap "FAKE-999" "$correlation")"
[ -z "$none" ] || fail "FAKE-999 should match no overlap, got: $none"
echo "PASS"

echo "Test 6: cascade-root recommendation reports a real step count, not null"
rec="$(topology_guided_get_recommendation "AWS-030" "payments-db" "RDS payments-db no backup")"
printf '%s' "$rec" | jq -e '.recommendation_type == "CASCADE_ROOT"' > /dev/null \
  || fail "AWS-030 should yield a CASCADE_ROOT recommendation: $rec"
printf '%s' "$rec" | jq -e '.rationale | test("prevents [0-9]+-step cascade")' > /dev/null \
  || fail "rationale must name a real step count, not \"null\": $rec"
printf '%s' "$rec" | jq -e '.rationale | contains("null") | not' > /dev/null \
  || fail "rationale must not contain the literal \"null\": $rec"
echo "PASS"

echo "Test 7: missing correlation.json degrades to empty, not a crash"
rm "$SCOUTFLO_AUDIT_DIR/correlation.json"
empty="$(_load_correlation)"
printf '%s' "$empty" | jq -e '.overlaps == [] and .cascades == []' > /dev/null \
  || fail "missing correlation.json should load as empty lists"
echo "PASS"

echo
echo "=== All topology-guided-setup tests passed ==="
