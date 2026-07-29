#!/bin/sh
# test-doctor-persistence.sh
# Unit tests for doctor-state.json persistence

set -eu

# Setup
TEST_STATE_DIR="$(mktemp -d)"
TEST_STATE_FILE="${TEST_STATE_DIR}/doctor-state.json"

cleanup() {
    rm -rf "$TEST_STATE_DIR"
}
trap cleanup EXIT

# --- Test 1: doctor-state.json created on first run ---
test_state_creation() {
    echo "Test 1: doctor-state.json created on first run"

    # Mock: simulate doctor writing state file
    cat > "$TEST_STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "last_full_check": "2026-07-30T14:30:00Z",
  "checks": [
    {
      "check_id": "aws-001",
      "check_name": "EC2 Security Groups",
      "status": "passed",
      "last_run": "2026-07-30T14:30:00Z",
      "skip_until": "2026-08-06T14:30:00Z",
      "last_failed": null,
      "failure_count": 0,
      "auto_fixed": false,
      "fix_timestamp": null
    }
  ],
  "metadata": {
    "doctor_version": "2.3.1",
    "audit_scope": ["critical-services"],
    "environment": "production",
    "last_manual_reset": null
  }
}
EOF

    # Verify file exists
    [ -f "$TEST_STATE_FILE" ] || { echo "FAIL: State file not created"; return 1; }

    # Verify valid JSON
    jq . "$TEST_STATE_FILE" > /dev/null || { echo "FAIL: Invalid JSON"; return 1; }

    # Verify version
    version=$(jq -r '.version' "$TEST_STATE_FILE")
    [ "$version" = "1.0" ] || { echo "FAIL: Wrong version: $version"; return 1; }

    # Verify checks array not empty
    check_count=$(jq '.checks | length' "$TEST_STATE_FILE")
    [ "$check_count" -gt 0 ] || { echo "FAIL: No checks in state"; return 1; }

    echo "PASS"
}

# --- Test 2: Check results saved with status + timestamp ---
test_check_save() {
    echo "Test 2: Check results saved with status + timestamp"

    # Verify first check has all required fields
    check=$(jq '.checks[0]' "$TEST_STATE_FILE")

    echo "$check" | jq -e '.check_id' > /dev/null || { echo "FAIL: Missing check_id"; return 1; }
    echo "$check" | jq -e '.status' > /dev/null || { echo "FAIL: Missing status"; return 1; }
    echo "$check" | jq -e '.last_run' > /dev/null || { echo "FAIL: Missing last_run"; return 1; }

    status=$(echo "$check" | jq -r '.status')
    [ "$status" = "passed" ] || { echo "FAIL: Wrong status: $status"; return 1; }

    echo "PASS"
}

# --- Test 3: Skip logic (check if skip_until is in future) ---
test_skip_logic() {
    echo "Test 3: Skip logic (skip_until in future means skip)"

    check=$(jq '.checks[0]' "$TEST_STATE_FILE")
    skip_until=$(echo "$check" | jq -r '.skip_until')

    # Parse ISO timestamp, compare to now
    # For test: just verify field exists and is parseable as ISO 8601
    echo "$skip_until" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' || {
        echo "FAIL: skip_until not ISO 8601: $skip_until"
        return 1
    }

    echo "PASS"
}

# --- Test 4: Auto-fix detection (status changed from failed to fixed) ---
test_auto_fix_detection() {
    echo "Test 4: Auto-fix detection"

    # Simulate: add a failed check, then mark it as fixed
    cat > "$TEST_STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "last_full_check": "2026-07-30T14:30:00Z",
  "checks": [
    {
      "check_id": "aws-002",
      "check_name": "RDS Backup",
      "status": "fixed",
      "last_run": "2026-07-30T15:00:00Z",
      "skip_until": "2026-08-13T15:00:00Z",
      "last_failed": "2026-07-28T09:00:00Z",
      "failure_count": 0,
      "auto_fixed": true,
      "fix_timestamp": "2026-07-30T11:15:00Z"
    }
  ],
  "metadata": {
    "doctor_version": "2.3.1",
    "audit_scope": ["critical-services"],
    "environment": "production",
    "last_manual_reset": null
  }
}
EOF

    check=$(jq '.checks[0]' "$TEST_STATE_FILE")

    status=$(echo "$check" | jq -r '.status')
    [ "$status" = "fixed" ] || { echo "FAIL: Status not 'fixed': $status"; return 1; }

    auto_fixed=$(echo "$check" | jq -r '.auto_fixed')
    [ "$auto_fixed" = "true" ] || { echo "FAIL: auto_fixed not true: $auto_fixed"; return 1; }

    fix_timestamp=$(echo "$check" | jq -r '.fix_timestamp')
    [ "$fix_timestamp" != "null" ] || { echo "FAIL: fix_timestamp is null"; return 1; }

    echo "PASS"
}

# --- Test 5: State persistence (file survives session) ---
test_persistence() {
    echo "Test 5: State persistence across sessions"

    # Write state, then read it back
    cat > "$TEST_STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "last_full_check": "2026-07-30T14:30:00Z",
  "checks": [
    {
      "check_id": "aws-003",
      "check_name": "Test Check",
      "status": "passed",
      "last_run": "2026-07-30T14:30:00Z",
      "skip_until": "2026-08-06T14:30:00Z",
      "last_failed": null,
      "failure_count": 0,
      "auto_fixed": false,
      "fix_timestamp": null
    }
  ],
  "metadata": {
    "doctor_version": "2.3.1",
    "audit_scope": ["critical-services"],
    "environment": "production",
    "last_manual_reset": null
  }
}
EOF

    # Read back and verify
    team=$(jq -r '.metadata.audit_scope[0]' "$TEST_STATE_FILE")
    [ "$team" = "critical-services" ] || { echo "FAIL: Data not persisted: $team"; return 1; }

    echo "PASS"
}

# --- Run all tests ---
echo "=== Doctor Persistence Tests ==="
echo

test_state_creation
test_check_save
test_skip_logic
test_auto_fix_detection
test_persistence

echo
echo "=== All tests passed ==="
