#!/bin/sh
# test-topology-guided-setup.sh - Topology-guided setup decision tests

set -eu

echo "=== Topology-Guided Setup Tests ==="

TOPO_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_AUDIT_DIR="/tmp/topo-guided-test-audits"
TEST_CORR_FILE="$TEST_AUDIT_DIR/correlation.json"
TEST_TOPOLOGY="/tmp/topo-guided-topology.json"
export SCOUTFLO_AUDIT_DIR="$TEST_AUDIT_DIR"
export TOPOLOGY_FILE="$TEST_TOPOLOGY"

setup() {
  mkdir -p "$TEST_AUDIT_DIR"
  rm -f "$TEST_CORR_FILE" "$TEST_TOPOLOGY"
}

teardown() {
  rm -rf "$TEST_AUDIT_DIR" "$TEST_TOPOLOGY"
}

@test "topology-guided: detects overlap and recommends skip" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  # Create correlation with overlap
  jq -n '{
    overlaps: [
      {
        overlap_id: "OVL-001",
        findings: [
          {finding_id: "AWS-023", skill: "audit-aws", title: "CloudWatch Not Configured"},
          {finding_id: "GRAFANA-045", skill: "audit-grafana", title: "Alert Rule Missing"}
        ],
        recommendation: "Keep Grafana, skip AWS"
      }
    ],
    cascades: []
  }' > "$TEST_CORR_FILE"

  recommendation=$(topology_guided_get_recommendation "AWS-023" "payment-svc" "CloudWatch Not Configured")
  type=$(echo "$recommendation" | jq -r '.recommendation_type')
  action=$(echo "$recommendation" | jq -r '.action')

  [ "$type" = "OVERLAP_DETECTED" ] || { echo "FAIL: Expected OVERLAP_DETECTED, got $type"; exit 1; }
  [ "$action" = "SKIP_OR_DEDUP" ] || { echo "FAIL: Expected SKIP_OR_DEDUP, got $action"; exit 1; }
}

@test "topology-guided: detects cascade root and prioritizes" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  # Create correlation with cascade
  jq -n '{
    overlaps: [],
    cascades: [
      {
        cascade_id: "CASC-001",
        root_cause: {finding_id: "AWS-055", title: "MySQL Master Unhealthy", service: "database-svc"},
        effects: [
          {step: 1, finding_id: "GRAFANA-022", title: "Alert Rule Disabled"},
          {step: 2, finding_id: "PAGERDUTY-008", title: "Incident Cannot Be Created"}
        ]
      }
    ]
  }' > "$TEST_CORR_FILE"

  recommendation=$(topology_guided_get_recommendation "AWS-055" "database-svc" "MySQL Master Unhealthy")
  type=$(echo "$recommendation" | jq -r '.recommendation_type')
  action=$(echo "$recommendation" | jq -r '.action')

  [ "$type" = "CASCADE_ROOT" ] || { echo "FAIL: Expected CASCADE_ROOT, got $type"; exit 1; }
  [ "$action" = "FIX_FIRST_PRIORITY" ] || { echo "FAIL: Expected FIX_FIRST_PRIORITY, got $action"; exit 1; }
}

@test "topology-guided: applies business context for critical service" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  # Create business context with critical service
  jq -n '{
    business_context: {
      environment: "production",
      critical_dependencies: ["payment-svc"]
    }
  }' > "$TEST_TOPOLOGY"

  # Empty correlation (no overlaps/cascades)
  jq -n '{overlaps: [], cascades: []}' > "$TEST_CORR_FILE"

  recommendation=$(topology_guided_get_recommendation "AWS-001" "payment-svc" "HTTPS Not Enforced")
  type=$(echo "$recommendation" | jq -r '.recommendation_type')
  action=$(echo "$recommendation" | jq -r '.action')

  [ "$type" = "CRITICAL_SERVICE" ] || { echo "FAIL: Expected CRITICAL_SERVICE, got $type"; exit 1; }
  [ "$action" = "REQUIRE_APPROVAL" ] || { echo "FAIL: Expected REQUIRE_APPROVAL, got $action"; exit 1; }
}

@test "topology-guided: uses safe defaults without business context" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  # No business context file
  # Empty correlation
  jq -n '{overlaps: [], cascades: []}' > "$TEST_CORR_FILE"

  recommendation=$(topology_guided_get_recommendation "AWS-001" "api-svc" "HTTPS Not Enforced")
  type=$(echo "$recommendation" | jq -r '.recommendation_type')

  [ "$type" = "STANDARD" ] || { echo "FAIL: Expected STANDARD (safe default), got $type"; exit 1; }
}

@test "topology-guided: estimates tokens based on criticality" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  jq -n '{
    business_context: {
      environment: "production",
      critical_dependencies: ["critical-svc", "payment-svc"]
    }
  }' > "$TEST_TOPOLOGY"

  jq -n '{overlaps: [], cascades: []}' > "$TEST_CORR_FILE"

  # Critical prod service
  tokens=$(topology_guided_estimate_tokens "AWS-001" "payment-svc" "$(jq '.business_context' "$TEST_TOPOLOGY")")
  [ "$tokens" = "20000" ] || { echo "FAIL: Expected 20000 tokens for critical prod, got $tokens"; exit 1; }

  # Non-critical prod
  tokens=$(topology_guided_estimate_tokens "AWS-002" "api-svc" "$(jq '.business_context' "$TEST_TOPOLOGY")")
  [ "$tokens" = "10000" ] || { echo "FAIL: Expected 10000 tokens for standard prod, got $tokens"; exit 1; }
}

@test "topology-guided: cascades impact recommendation" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  # Create cascade impact
  jq -n '{
    overlaps: [],
    cascades: [
      {
        cascade_id: "CASC-001",
        root_cause: {finding_id: "AWS-055", title: "MySQL Master Unhealthy"},
        effects: [
          {step: 1, finding_id: "GRAFANA-022", title: "Alert Rule Disabled"}
        ]
      }
    ]
  }' > "$TEST_CORR_FILE"

  recommendation=$(topology_guided_get_recommendation "GRAFANA-022" "monitoring-svc" "Alert Rule Disabled")
  type=$(echo "$recommendation" | jq -r '.recommendation_type')
  action=$(echo "$recommendation" | jq -r '.action')

  [ "$type" = "CASCADE_IMPACT" ] || { echo "FAIL: Expected CASCADE_IMPACT, got $type"; exit 1; }
  [ "$action" = "WAIT_FOR_ROOT_FIX" ] || { echo "FAIL: Expected WAIT_FOR_ROOT_FIX, got $action"; exit 1; }
}

@test "topology-guided: fix order priority" {
  . "${TOPO_LIB}/topology-guided-setup.sh"

  jq -n '{
    overlaps: [],
    cascades: [
      {
        cascade_id: "CASC-001",
        root_cause: {finding_id: "AWS-055"}
      }
    ]
  }' > "$TEST_CORR_FILE"

  # Root cause = priority 1
  order=$(topology_guided_get_fix_order "AWS-055")
  [ "$order" = "1" ] || { echo "FAIL: Expected priority 1 for root cause, got $order"; exit 1; }

  # Standard = priority 3
  order=$(topology_guided_get_fix_order "AWS-001")
  [ "$order" = "3" ] || { echo "FAIL: Expected priority 3 for standard, got $order"; exit 1; }
}

echo "=== All topology-guided tests passed ==="
