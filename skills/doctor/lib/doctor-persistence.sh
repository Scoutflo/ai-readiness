#!/bin/sh
# doctor-persistence.sh
# Manages doctor-state.json persistence: save, load, skip logic

set -eu

# State file location (allow override for testing)
DOCTOR_STATE_FILE="${DOCTOR_STATE:-${HOME}/.scoutflo/doctor-state.json}"

# --- Initialize state file (v1.0) ---
doctor_state_init() {
  # If state exists, don't overwrite
  [ -f "$DOCTOR_STATE_FILE" ] && return 0

  # Create ~/.scoutflo if needed
  mkdir -p "$(dirname "$DOCTOR_STATE_FILE")"

  # Write empty state
  cat > "$DOCTOR_STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "last_full_check": null,
  "checks": {},
  "metadata": {
    "doctor_version": "2.3.1",
    "audit_scope": [],
    "environment": "production",
    "last_manual_reset": null
  }
}
EOF
}

# --- Load state from file ---
doctor_state_load() {
  doctor_state_init

  if [ ! -f "$DOCTOR_STATE_FILE" ]; then
    echo "{}" | jq .
    return 0
  fi

  # Check for corruption
  if ! jq . "$DOCTOR_STATE_FILE" > /dev/null 2>&1; then
    echo "doctor: warning: ${DOCTOR_STATE_FILE} corrupted, backing up" >&2
    cp "$DOCTOR_STATE_FILE" "${DOCTOR_STATE_FILE}.bak"
    doctor_state_init
    return 0
  fi

  cat "$DOCTOR_STATE_FILE"
}

# --- Check if we should skip this check (status=passed, skip_until in future) ---
doctor_should_skip() {
  check_id="$1"

  state=$(doctor_state_load)

  check=$(echo "$state" | jq --arg id "$check_id" '.checks[$id] // empty' 2>/dev/null || echo "{}")

  [ -z "$check" ] || [ "$check" = "{}" ] && return 1  # Check not in state, don't skip

  status=$(echo "$check" | jq -r '.status // empty' 2>/dev/null || echo "")
  [ "$status" != "passed" ] && return 1  # Not passed, don't skip

  skip_until=$(echo "$check" | jq -r '.skip_until // empty' 2>/dev/null || echo "")
  [ -z "$skip_until" ] && return 1  # No skip_until, don't skip

  # Compare skip_until to now (ISO 8601)
  # For now: simple string comparison (works for ISO 8601)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [ "$skip_until" > "$now" ]; then
    return 0  # Skip (skip_until is in future)
  fi

  return 1  # Don't skip (skip_until has passed)
}

# --- Save check result ---
doctor_state_save_check() {
  check_id="$1"
  check_name="$2"
  status="$3"  # passed, failed, fixed, skipped, error

  state=$(doctor_state_load)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Determine skip_until based on status
  case "$status" in
    passed)
      # Passed: skip for 7 days
      skip_until=$(date -u -v+7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+7 days" +"%Y-%m-%dT%H:%M:%SZ")
      ;;
    fixed)
      # Fixed: skip for 14 days (longer window after fix)
      skip_until=$(date -u -v+14d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "+14 days" +"%Y-%m-%dT%H:%M:%SZ")
      ;;
    *)
      # Failed, error, skipped: no skip
      skip_until="null"
      ;;
  esac

  # Update or create check in object
  if [ "$skip_until" = "null" ]; then
    skip_value="null"
  else
    skip_value="\"$skip_until\""
  fi

  state=$(echo "$state" | jq \
    --arg id "$check_id" \
    --arg name "$check_name" \
    --arg st "$status" \
    --arg now "$now" \
    '.checks[$id] = {
       check_id: $id,
       check_name: $name,
       status: $st,
       last_run: $now,
       skip_until: '"$skip_value"',
       last_failed: (if $st == "failed" then $now else (.last_failed // null) end),
       failure_count: (if $st == "failed" then 1 else 0 end),
       auto_fixed: (if $st == "fixed" then true else false end),
       fix_timestamp: (if $st == "fixed" then $now else null end)
     }')

  # Update last_full_check
  state=$(echo "$state" | jq --arg now "$now" '.last_full_check = $now')

  # Write back
  echo "$state" | jq . > "$DOCTOR_STATE_FILE"
}

# --- Auto-detect fix (check was failed, now passes) ---
doctor_auto_detect_fix() {
  check_id="$1"

  state=$(doctor_state_load)

  check=$(echo "$state" | jq --arg id "$check_id" '.checks[$id] // empty' 2>/dev/null || echo "{}")

  [ -z "$check" ] || [ "$check" = "{}" ] && return 1  # Check not in state

  prev_status=$(echo "$check" | jq -r '.status // empty' 2>/dev/null || echo "")

  if [ "$prev_status" = "failed" ]; then
    return 0  # Was failed, is now passed (auto-fix detected)
  fi

  return 1  # Not an auto-fix case
}

# --- Reset all state ---
doctor_state_reset_all() {
  rm -f "$DOCTOR_STATE_FILE"
  doctor_state_init
}

# --- Reset single check ---
doctor_state_reset_check() {
  check_id="$1"

  state=$(doctor_state_load)

  # Remove this check from state
  state=$(echo "$state" | jq --arg id "$check_id" 'del(.checks[$id])')

  echo "$state" | jq . > "$DOCTOR_STATE_FILE"
}
