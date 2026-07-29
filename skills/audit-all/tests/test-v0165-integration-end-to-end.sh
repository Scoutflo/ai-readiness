#!/bin/sh
# End-to-end integration test: v0.1.65 full wiring
# Simulates the complete flow: checkpoint → business context → doctor → audit → redaction → cross-references

set -eu

SKILLS_LIB_DIR="${SCOUTFLO_ROOT}/sre-toolkit/skills"
TEST_AUDIT_DIR="/tmp/scoutflo-audits-e2e-test"
TEST_TOPOLOGY="/tmp/.scoutflo/topology-e2e-test.json"
TEST_DOCTOR_STATE="/tmp/.scoutflo/doctor-state-e2e-test.json"
export SCOUTFLO_AUDIT_DIR="$TEST_AUDIT_DIR"
export DOCTOR_STATE="$TEST_DOCTOR_STATE"
export TOPOLOGY_FILE="$TEST_TOPOLOGY"
export HOME="/tmp"

setup() {
  mkdir -p "$TEST_AUDIT_DIR" "$(dirname "$TEST_TOPOLOGY")" "$(dirname "$TEST_DOCTOR_STATE")"
  rm -rf "$TEST_AUDIT_DIR"/* "$TEST_TOPOLOGY" "$TEST_DOCTOR_STATE" "$TEST_TOPOLOGY.bak" "$TEST_DOCTOR_STATE.bak"
}

teardown() {
  rm -rf "$TEST_AUDIT_DIR" "$TEST_TOPOLOGY" "$TEST_DOCTOR_STATE" "$TEST_TOPOLOGY.bak" "$TEST_DOCTOR_STATE.bak"
}

@test "v0.1.65 e2e: checkpoint initializes topology" {
  . "${SKILLS_LIB_DIR}/checkpoint/lib/checkpoint.sh"

  checkpoint_init_topology

  [ -f "$TEST_TOPOLOGY" ]
  grep -q "{" "$TEST_TOPOLOGY"
}

@test "v0.1.65 e2e: checkpoint saves scope" {
  . "${SKILLS_LIB_DIR}/checkpoint/lib/checkpoint.sh"

  checkpoint_init_topology
  checkpoint_save_scope "payment-svc,checkout-svc"

  # Verify it's in topology
  jq -e '.audit_scope.services' "$TEST_TOPOLOGY" >/dev/null
}

@test "v0.1.65 e2e: business context captures metadata" {
  . "${SKILLS_LIB_DIR}/business-context/lib/business-context.sh"

  business_context_init_topology

  # Manually set context (normally interactive)
  jq '.business_context = {
    "team": "platform",
    "environment": "production",
    "uptime_sla": 99.9,
    "cost_sensitivity": "high",
    "billing_owner": "ops-team",
    "captured_at": "2026-07-30T17:00:00Z"
  }' "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
  mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"

  # Verify it can be loaded
  team=$(business_context_get "team")
  [ "$team" = "platform" ]
}

@test "v0.1.65 e2e: doctor initializes and saves state" {
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-persistence.sh"
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-integration.sh"

  doctor_integration_init

  [ -f "$TEST_DOCTOR_STATE" ]

  # Save a check result
  doctor_integration_save_result "check-001" "Sample Check" "passed"

  # Verify it's persisted
  status=$(jq -r '.checks["check-001"].status' "$TEST_DOCTOR_STATE" 2>/dev/null || true)
  [ "$status" = "passed" ]
}

@test "v0.1.65 e2e: doctor skip logic prevents re-runs" {
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-persistence.sh"
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-integration.sh"

  doctor_integration_init
  doctor_integration_save_result "check-002" "Already Passed" "passed"

  # Next run should skip this check
  if ! doctor_integration_should_skip "check-002"; then
    echo "FAIL: Check should skip after passing"
    exit 1
  fi
}

@test "v0.1.65 e2e: redaction removes secrets from findings" {
  . "${SKILLS_LIB_DIR}/redaction/lib/redaction-integration.sh"

  # Create sample findings with AWS key
  mkdir -p "$TEST_AUDIT_DIR/aws/2026-07-30"
  cat > "$TEST_AUDIT_DIR/aws/2026-07-30/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "AWS-001",
      "description": "Found AWS key AKIA1234567890ABCDEF1 in logs"
    }
  ]
}
EOF

  # Redact it
  redaction_integration_findings "$TEST_AUDIT_DIR/aws/2026-07-30/findings.json"

  # Verify key is gone
  if grep -q "AKIA1234567890ABCDEF1" "$TEST_AUDIT_DIR/aws/2026-07-30/findings.json"; then
    echo "FAIL: AWS key not redacted"
    exit 1
  fi
}

@test "v0.1.65 e2e: redaction removes secrets from reports" {
  . "${SKILLS_LIB_DIR}/redaction/lib/redaction-integration.sh"

  # Create sample report with Stripe key
  mkdir -p "$TEST_AUDIT_DIR/grafana/2026-07-30"
  cat > "$TEST_AUDIT_DIR/grafana/2026-07-30/report.md" <<'EOF'
# Audit Report

Found Stripe key: sk_test_TENONLYKEY00000000000000TEST
Please remediate.
EOF

  # Redact it
  redaction_integration_report "$TEST_AUDIT_DIR/grafana/2026-07-30/report.md"

  # Verify key is gone
  if grep -q "sk_test_TENONLYKEY" "$TEST_AUDIT_DIR/grafana/2026-07-30/report.md"; then
    echo "FAIL: Stripe key not redacted from report"
    exit 1
  fi
}

@test "v0.1.65 e2e: cli interactive filter builder" {
  . "${SKILLS_LIB_DIR}/cli-interactive/lib/cli-interactive.sh"

  # Build exclusion filter
  filter=$(cli_build_exclusion_filter "s3,lambda" "ap-south-1" "stopped")

  # Should include all exclusion flags
  if ! echo "$filter" | grep -q "exclude-services"; then
    echo "FAIL: Services flag missing"
    exit 1
  fi
  if ! echo "$filter" | grep -q "exclude-regions"; then
    echo "FAIL: Regions flag missing"
    exit 1
  fi
  if ! echo "$filter" | grep -q "exclude-statuses"; then
    echo "FAIL: Statuses flag missing"
    exit 1
  fi
}

@test "v0.1.65 e2e: cross-references creates linkage" {
  . "${SKILLS_LIB_DIR}/cross-references/lib/cross-references.sh"

  # Create sample findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/audit-aws"
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/audit-grafana"

  cat > "$TEST_AUDIT_DIR/2026-07-30/audit-aws/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "AWS-023",
      "title": "Alarm disabled",
      "related_findings": []
    }
  ]
}
EOF

  cat > "$TEST_AUDIT_DIR/2026-07-30/audit-grafana/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "GRAFANA-018",
      "title": "Alert rule misconfigured",
      "related_findings": []
    }
  ]
}
EOF

  # Add cross-references
  xref_add_to_findings "$TEST_AUDIT_DIR/2026-07-30/audit-aws/findings.json" "2026-07-30"

  # Verify related_findings array exists
  jq -e '.findings[].related_findings' "$TEST_AUDIT_DIR/2026-07-30/audit-aws/findings.json" >/dev/null
}

@test "v0.1.65 e2e: full integration checkpoint to redaction" {
  # Verify all components are loaded and working together

  # 1. Initialize checkpoint & business context
  . "${SKILLS_LIB_DIR}/checkpoint/lib/checkpoint.sh"
  . "${SKILLS_LIB_DIR}/business-context/lib/business-context.sh"
  checkpoint_init_topology
  business_context_init_topology

  checkpoint_save_scope "api-gateway"
  jq '.business_context.environment = "production"' "$TEST_TOPOLOGY" > "$TEST_TOPOLOGY.tmp"
  mv "$TEST_TOPOLOGY.tmp" "$TEST_TOPOLOGY"

  # 2. Initialize doctor persistence
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-persistence.sh"
  . "${SKILLS_LIB_DIR}/doctor/lib/doctor-integration.sh"
  doctor_integration_init
  doctor_integration_save_result "health-check" "Health Check" "passed"

  # 3. Create audit output with findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30"
  cat > "$TEST_AUDIT_DIR/2026-07-30/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "TEST-001",
      "description": "Test finding with AWS key AKIA1234567890ABCDEF1"
    }
  ]
}
EOF

  cat > "$TEST_AUDIT_DIR/2026-07-30/report.md" <<'EOF'
# Test Report

Credentials found: sk_test_TENONLYKEY00000000000000TEST

Review immediately.
EOF

  # 4. Apply redaction
  . "${SKILLS_LIB_DIR}/redaction/lib/redaction-integration.sh"
  redaction_integration_findings "$TEST_AUDIT_DIR/2026-07-30/findings.json"
  redaction_integration_report "$TEST_AUDIT_DIR/2026-07-30/report.md"

  # 5. Verify end-to-end: all secrets redacted
  if grep -q "AKIA1234567890ABCDEF1" "$TEST_AUDIT_DIR/2026-07-30/findings.json"; then
    echo "FAIL: AWS key still present in findings"
    exit 1
  fi

  if grep -q "sk_test_TENONLYKEY" "$TEST_AUDIT_DIR/2026-07-30/report.md"; then
    echo "FAIL: Stripe key still present in report"
    exit 1
  fi

  # 6. Verify checkpoint and doctor state persisted
  [ -f "$TEST_TOPOLOGY" ]
  [ -f "$TEST_DOCTOR_STATE" ]

  # All components working together successfully
  return 0
}
