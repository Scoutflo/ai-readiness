#!/bin/sh
# test-correlation-engine.sh - Core correlation engine tests

set -eu

echo "=== Correlation Engine Tests ==="

CORR_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_AUDIT_DIR="/tmp/correlation-test-audits"
export SCOUTFLO_AUDIT_DIR="$TEST_AUDIT_DIR"
export TOPOLOGY_FILE="/tmp/correlation-test-topology.json"

setup() {
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/aws" "$TEST_AUDIT_DIR/2026-07-30/grafana"
  rm -f "$CORRELATION_FILE" "$TOPOLOGY_FILE"
}

teardown() {
  rm -rf "$TEST_AUDIT_DIR" "$TOPOLOGY_FILE"
}

@test "correlation: init creates correlation.json" {
  . "${CORR_LIB}/correlation-engine.sh"

  correlation_init "2026-07-30"

  [ -f "$CORRELATION_FILE" ]
  grep -q "version.*1.0" "$CORRELATION_FILE"
}

@test "correlation: detects overlaps (AWS + Grafana same metric)" {
  . "${CORR_LIB}/correlation-engine.sh"

  # Create AWS findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/aws"
  cat > "$TEST_AUDIT_DIR/2026-07-30/aws/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "AWS-023",
      "title": "CloudWatch Alarms Not Configured",
      "service": "payment-svc",
      "severity": "high",
      "description": "No alarms on payment database"
    }
  ]
}
EOF

  # Create Grafana findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/grafana"
  cat > "$TEST_AUDIT_DIR/2026-07-30/grafana/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "GRAFANA-045",
      "title": "Alert Rule Missing for Payment Service",
      "service": "payment-svc",
      "severity": "high",
      "description": "Grafana rule for payment-svc"
    }
  ]
}
EOF

  correlation_init "2026-07-30"
  correlation_run "2026-07-30"

  # Verify overlap detected
  overlaps=$(jq '.total_overlaps_detected' "$CORRELATION_FILE")
  [ "$overlaps" -gt 0 ] || {
    echo "FAIL: Expected overlaps, got $overlaps"
    exit 1
  }
}

@test "correlation: applies business context (staging = low priority)" {
  . "${CORR_LIB}/correlation-engine.sh"

  # Create business context
  jq -n '{
    business_context: {
      environment: "staging",
      critical_dependencies: []
    }
  }' > "$TOPOLOGY_FILE"

  # Create findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/aws"
  cat > "$TEST_AUDIT_DIR/2026-07-30/aws/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "AWS-001",
      "title": "HTTPS Not Enforced",
      "service": "api-svc",
      "severity": "medium"
    }
  ]
}
EOF

  correlation_init "2026-07-30"
  correlation_run "2026-07-30"

  # Verify context applied
  applied=$(jq '.business_context_applied' "$CORRELATION_FILE")
  [ "$applied" = "true" ] || {
    echo "FAIL: Context not applied"
    exit 1
  }
}

@test "correlation: handles missing findings gracefully" {
  . "${CORR_LIB}/correlation-engine.sh"

  correlation_init "2026-07-30"
  correlation_run "2026-07-30"

  # Should not crash, just report 0 findings
  total=$(jq '.total_findings_raw' "$CORRELATION_FILE")
  [ "$total" -eq 0 ] || {
    echo "FAIL: Expected 0 findings, got $total"
    exit 1
  }
}

@test "correlation: detects cascades (database → monitoring → incident)" {
  . "${CORR_LIB}/correlation-engine.sh"

  # Create database findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/aws"
  cat > "$TEST_AUDIT_DIR/2026-07-30/aws/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "AWS-055",
      "title": "MySQL Master Instance Unhealthy",
      "service": "database-svc",
      "severity": "critical"
    }
  ]
}
EOF

  # Create monitoring findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/grafana"
  cat > "$TEST_AUDIT_DIR/2026-07-30/grafana/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "GRAFANA-022",
      "title": "Alert Rule Disabled",
      "service": "monitoring-svc",
      "severity": "high"
    }
  ]
}
EOF

  # Create incident findings
  mkdir -p "$TEST_AUDIT_DIR/2026-07-30/pagerduty"
  cat > "$TEST_AUDIT_DIR/2026-07-30/pagerduty/findings.json" <<'EOF'
{
  "findings": [
    {
      "id": "PAGERDUTY-008",
      "title": "Incident Cannot Be Created",
      "service": "incident-svc",
      "severity": "high"
    }
  ]
}
EOF

  correlation_init "2026-07-30"
  correlation_run "2026-07-30"

  # Verify cascade detected
  cascades=$(jq '.total_cascades_detected' "$CORRELATION_FILE")
  [ "$cascades" -gt 0 ] || {
    echo "FAIL: Expected cascades, got $cascades"
    exit 1
  }
}

@test "correlation: safe defaults when business-context not set" {
  . "${CORR_LIB}/correlation-engine.sh"

  # Don't create topology file
  correlation_init "2026-07-30"

  # Load context should return defaults
  context=$(correlation_load_context)
  env=$(echo "$context" | jq -r '.environment')
  [ "$env" = "production" ] || {
    echo "FAIL: Expected production env, got $env"
    exit 1
  }
}

echo "=== All correlation tests passed ==="
