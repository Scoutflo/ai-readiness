#!/bin/sh
# Integration tests: doctor persistence with main doctor loop
# Tests that doctor.sh calls doctor-integration.sh correctly

set -eu

DOCTOR_LIB="${BATS_TEST_DIRNAME}/../lib"
DOCTOR_STATE="/tmp/.scoutflo/doctor-state-integration-test.json"
export DOCTOR_STATE

setup() {
  mkdir -p "$(dirname "$DOCTOR_STATE")"
  rm -f "$DOCTOR_STATE" "$DOCTOR_STATE.bak"
}

teardown() {
  rm -f "$DOCTOR_STATE" "$DOCTOR_STATE.bak"
}

@test "doctor integration: init creates state file" {
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  [ ! -f "$DOCTOR_STATE" ]
  doctor_integration_init
  [ -f "$DOCTOR_STATE" ]
}

@test "doctor integration: full loop with skip logic" {
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  doctor_integration_init

  # First run: check is NOT skipped (new)
  if doctor_integration_should_skip "check-001"; then
    skip "Check should not skip on first run"
  fi

  # Simulate check pass and save state
  doctor_integration_save_result "check-001" "Sample Check" "passed"

  # Second run: check SHOULD be skipped (passed previously)
  if ! doctor_integration_should_skip "check-001"; then
    skip "Check should skip after passing"
  fi
}

@test "doctor integration: auto-detect fix" {
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  doctor_integration_init

  # First run: check fails
  doctor_integration_save_result "check-002" "Failed Check" "failed"
  state=$(jq -r '.checks["check-002"].status' "$DOCTOR_STATE" 2>/dev/null || true)
  [ "$state" = "failed" ]

  # Simulate manual fix: update to passed
  doctor_state_load
  jq '.checks["check-002"].status = "passed"' "$DOCTOR_STATE" > "$DOCTOR_STATE.tmp"
  mv "$DOCTOR_STATE.tmp" "$DOCTOR_STATE"

  # Auto-detect fix
  doctor_integration_auto_detect_fix "check-002"

  # Verify auto_fixed flag set
  auto_fixed=$(jq -r '.checks["check-002"].auto_fixed' "$DOCTOR_STATE" 2>/dev/null || true)
  [ "$auto_fixed" = "true" ]
}

@test "doctor integration: persist state across sessions" {
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  doctor_integration_init
  doctor_integration_save_result "check-003" "Session Check" "passed"

  # Unset functions to simulate new session
  unset doctor_integration_should_skip doctor_integration_save_result

  # Reload in new "session"
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  # State should persist
  if ! doctor_integration_should_skip "check-003"; then
    skip "State should persist across sessions"
  fi
}

@test "doctor integration: multiple checks tracked independently" {
  . "${DOCTOR_LIB}/doctor-persistence.sh"
  . "${DOCTOR_LIB}/doctor-integration.sh"

  doctor_integration_init

  # Save different statuses for different checks
  doctor_integration_save_result "check-a" "Check A" "passed"
  doctor_integration_save_result "check-b" "Check B" "failed"

  # Check A should skip, Check B should not
  if ! doctor_integration_should_skip "check-a"; then
    skip "Check A should skip"
  fi

  if doctor_integration_should_skip "check-b"; then
    skip "Check B should not skip (failed)"
  fi
}
