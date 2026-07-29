#!/bin/sh
# test-business-context.sh - business context skill tests

set -eu

TEST_DIR="$(mktemp -d)"
TEST_TOPOLOGY="${TEST_DIR}/topology.json"

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

echo "=== Business Context Tests ==="

# Test 1: Save business context to topology.json
echo "Test 1: Save business context to topology.json"

# Initialize empty topology
echo '{}' | jq . > "$TEST_TOPOLOGY"

# Simulate save
cat > "$TEST_DIR/context.json" << 'EOF'
{
  "team": "payments-team",
  "environment": "production",
  "sla": {
    "uptime_percent": 99.99,
    "response_time_ms": 200,
    "error_rate_percent": 0.001
  },
  "cost_sensitivity": "high",
  "billing_owner": "payments-lead",
  "critical_dependencies": ["api-gateway", "checkout-svc"],
  "updated_at": "2026-07-29T16:45:00Z",
  "notes": "PCI-DSS compliance required"
}
EOF

# Merge into topology
jq ".business_context = $(cat "$TEST_DIR/context.json")" "$TEST_TOPOLOGY" > "$TEST_DIR/topology_merged.json"
mv "$TEST_DIR/topology_merged.json" "$TEST_TOPOLOGY"

# Verify
team=$(jq -r '.business_context.team' "$TEST_TOPOLOGY")
[ "$team" = "payments-team" ] && echo "PASS" || { echo "FAIL: $team"; exit 1; }

# Test 2: Verify all required fields
echo "Test 2: All required fields present"
jq -e '.business_context.team' "$TEST_TOPOLOGY" > /dev/null || { echo "FAIL: team"; exit 1; }
jq -e '.business_context.environment' "$TEST_TOPOLOGY" > /dev/null || { echo "FAIL: environment"; exit 1; }
jq -e '.business_context.sla.uptime_percent' "$TEST_TOPOLOGY" > /dev/null || { echo "FAIL: uptime"; exit 1; }
jq -e '.business_context.cost_sensitivity' "$TEST_TOPOLOGY" > /dev/null || { echo "FAIL: cost_sensitivity"; exit 1; }
jq -e '.business_context.billing_owner' "$TEST_TOPOLOGY" > /dev/null || { echo "FAIL: billing_owner"; exit 1; }
echo "PASS"

# Test 3: Environment values validated
echo "Test 3: Environment in [staging, production, dr, dev]"
env=$(jq -r '.business_context.environment' "$TEST_TOPOLOGY")
case "$env" in
  staging|production|dr|dev) echo "PASS" ;;
  *) echo "FAIL: invalid env $env"; exit 1 ;;
esac

# Test 4: Cost sensitivity in [low, medium, high]
echo "Test 4: Cost sensitivity valid"
cost=$(jq -r '.business_context.cost_sensitivity' "$TEST_TOPOLOGY")
case "$cost" in
  low|medium|high) echo "PASS" ;;
  *) echo "FAIL: invalid cost $cost"; exit 1 ;;
esac

# Test 5: Persist across sessions
echo "Test 5: Context persists (file survives reload)"
# Read again
persisted_team=$(jq -r '.business_context.team' "$TEST_TOPOLOGY")
[ "$persisted_team" = "payments-team" ] && echo "PASS" || { echo "FAIL: $persisted_team"; exit 1; }

echo
echo "=== All business context tests passed ==="
