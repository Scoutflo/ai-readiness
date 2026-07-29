#!/bin/sh
# doctor-integration.sh
# Wire doctor persistence into main doctor.sh loop
# This is a thin wrapper that re-exports doctor-persistence functions

set -eu

# Source persistence module (required; will be sourced by caller before using these functions)
# Caller should do: . "${DOCTOR_LIB}/doctor-persistence.sh" in main script

# Initialize via doctor_state_init (from doctor-persistence)
doctor_integration_init() {
  doctor_state_init
}

# Check if we should skip (forwards to doctor_should_skip from doctor-persistence)
doctor_integration_should_skip() {
  check_id="$1"
  doctor_should_skip "$check_id" || return 1
}

# Save check result (forwards to doctor_state_save_check from doctor-persistence)
doctor_integration_save_result() {
  check_id="$1"
  check_name="$2"
  status="$3"  # pass, fail, error

  # Map pass/fail to saved status
  case "$status" in
    pass) saved_status="passed" ;;
    fail) saved_status="failed" ;;
    error) saved_status="error" ;;
    *) saved_status="$status" ;;
  esac

  doctor_state_save_check "$check_id" "$check_name" "$saved_status"
}

# Auto-detect fixes (forwards to doctor_auto_detect_fix from doctor-persistence)
doctor_integration_auto_detect_fix() {
  check_id="$1"

  if doctor_auto_detect_fix "$check_id"; then
    doctor_state_save_check "$check_id" "" "fixed"
    return 0
  fi

  return 1
}
