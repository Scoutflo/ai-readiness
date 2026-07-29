#!/bin/sh
# Integration tests: redaction in audit output pipeline
# Tests that redaction-integration.sh correctly redacts findings.json and report.md

set -eu

REDACTION_LIB="${BATS_TEST_DIRNAME}/../lib"
TEST_OUTPUT="/tmp/redaction-integration-test"
export REDACTION_LIB

setup() {
  mkdir -p "$TEST_OUTPUT"
  rm -f "$TEST_OUTPUT"/*.json "$TEST_OUTPUT"/*.md "$TEST_OUTPUT"/.bak
}

teardown() {
  rm -rf "$TEST_OUTPUT"
}

@test "redaction integration: redact findings.json descriptions" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  # Create sample findings.json with AWS key in description
  cat > "$TEST_OUTPUT/findings.json" <<'EOF'
{
  "target": "aws",
  "findings": [
    {
      "id": "AWS-001",
      "title": "Exposed credential in log",
      "description": "Found AWS key AKIA1234567890ABCDEF1 in CloudWatch logs"
    }
  ]
}
EOF

  # Run redaction
  redaction_integration_findings "$TEST_OUTPUT/findings.json"

  # Verify AWS key is redacted
  if grep -q "AKIA1234567890ABCDEF1" "$TEST_OUTPUT/findings.json"; then
    echo "FAIL: AWS key not redacted"
    exit 1
  fi

  if grep -q "\[REDACTED\]" "$TEST_OUTPUT/findings.json"; then
    return 0
  else
    echo "FAIL: REDACTED marker not found"
    exit 1
  fi
}

@test "redaction integration: redact report.md for API keys" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  # Create sample report.md with Stripe key
  cat > "$TEST_OUTPUT/report.md" <<'EOF'
# Audit Report

## Secrets Found

The following secrets were discovered:
- Stripe key: sk_test_TENONLYKEY00000000000000TEST
- Bearer token: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9

Please remediate these findings.
EOF

  # Run redaction
  redaction_integration_report "$TEST_OUTPUT/report.md"

  # Verify secrets are redacted
  if grep -q "sk_live_" "$TEST_OUTPUT/report.md"; then
    echo "FAIL: Stripe key not redacted"
    exit 1
  fi

  if grep -q "Bearer eyJ" "$TEST_OUTPUT/report.md"; then
    echo "FAIL: Bearer token not redacted"
    exit 1
  fi

  # Count redactions
  redacted_count=$(grep -c "\[REDACTED\]" "$TEST_OUTPUT/report.md" || true)
  if [ "$redacted_count" -lt 2 ]; then
    echo "FAIL: Expected 2+ redactions, got $redacted_count"
    exit 1
  fi
}

@test "redaction integration: slack brief redaction" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  brief="Alert summary: AWS key AKIA1234567890ABCDEF1 found in log. Status: open"

  # Run slack brief redaction
  redacted_brief=$(redaction_integration_slack_brief "$brief")

  # Verify key is redacted
  if echo "$redacted_brief" | grep -q "AKIA1234567890ABCDEF1"; then
    echo "FAIL: AWS key not redacted in Slack brief"
    exit 1
  fi

  if echo "$redacted_brief" | grep -q "\[REDACTED\]"; then
    return 0
  else
    echo "FAIL: REDACTED marker not found in Slack brief"
    exit 1
  fi
}

@test "redaction integration: no false positives on legitimate text" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  # Create report with legitimate text that might look like secrets
  cat > "$TEST_OUTPUT/report.md" <<'EOF'
# Performance Report

## Key Metrics

The key performance indicators for Q3 were:
- Bearer performance improved 25%
- SKU count increased from 100 to 150
- API call latency reduced

No actual credentials here.
EOF

  # Run redaction
  redaction_integration_report "$TEST_OUTPUT/report.md"

  # Verify legitimate text is unchanged
  if ! grep -q "key performance indicators" "$TEST_OUTPUT/report.md"; then
    echo "FAIL: Legitimate text was modified"
    exit 1
  fi

  if ! grep -q "Bearer performance" "$TEST_OUTPUT/report.md"; then
    echo "FAIL: Legitimate 'Bearer' word was modified"
    exit 1
  fi

  if ! grep -q "SKU count" "$TEST_OUTPUT/report.md"; then
    echo "FAIL: Legitimate 'SKU' text was modified"
    exit 1
  fi
}

@test "redaction integration: multiple findings redacted" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  # Create findings with multiple secrets
  cat > "$TEST_OUTPUT/findings.json" <<'EOF'
{
  "target": "datadog",
  "findings": [
    {
      "id": "DD-001",
      "description": "API key dd_key_abcd1234efgh5678ijkl9012mnop3456 found in code"
    },
    {
      "id": "DD-002",
      "description": "Application key app_key_5678efgh9012ijkl3456mnop7890qrst found in logs"
    }
  ]
}
EOF

  # Run redaction
  redaction_integration_findings "$TEST_OUTPUT/findings.json"

  # Both keys should be redacted
  redacted_count=$(grep -c "\[REDACTED\]" "$TEST_OUTPUT/findings.json" || true)
  if [ "$redacted_count" -lt 2 ]; then
    echo "FAIL: Expected 2+ redactions, got $redacted_count"
    exit 1
  fi
}

@test "redaction integration: handles missing files gracefully" {
  . "${REDACTION_LIB}/redaction-integration.sh"

  # Should not fail if file doesn't exist
  redaction_integration_report "/nonexistent/file.md" || true
  redaction_integration_findings "/nonexistent/findings.json" || true

  return 0
}
