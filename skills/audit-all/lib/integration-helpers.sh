#!/bin/bash
# Integration Helpers (Shared by all 12 audits)
# Used in Phase 1-12 to apply integration logic to findings

set -eu

# ============================================================================
# Helper: Apply Exemptions (C4)
# Filters findings based on exemptions.yaml
# ============================================================================

apply_exemptions() {
  local findings_file="$1"
  local exemptions_json="${SCOUTFLO_EXEMPTIONS:-[]}"

  if [ ! -f "$findings_file" ]; then
    return 1
  fi

  # Filter out exempted findings, move to appendix
  jq --argjson exemptions "$exemptions_json" '
    .findings as $findings |
    .findings |= map(
      . as $finding |
      if $exemptions[] | select(.finding_id == $finding.id or .resource_id == $finding.affected_resource) then
        . + {status: "suppressed", suppression_reason: ($exemptions[] | select(.finding_id == $finding.id) | .reason)}
      else
        .
      end
    ) |
    .suppressed_findings = [.findings[] | select(.status == "suppressed")] |
    .findings |= map(select(.status != "suppressed"))
  ' "$findings_file"
}

# ============================================================================
# Helper: Classify Lifecycle (C3)
# Compares against previous run to classify as new/unchanged/regressed/resolved
# ============================================================================

classify_lifecycle() {
  local findings_file="$1"
  local session_id="${SCOUTFLO_SESSION_ID:-$(date +%s)}"
  local history_dir="${SCOUTFLO_SHARED_STATE_DIR}/.history"

  mkdir -p "$history_dir"

  # Get previous findings (from last run's archive)
  local previous_findings="[]"
  if [ -f "$history_dir/previous-findings.json" ]; then
    previous_findings=$(cat "$history_dir/previous-findings.json")
  fi

  # Classify each finding
  jq --argjson previous "$previous_findings" '
    .findings |= map(
      . as $finding |
      ($previous[] | select(.id == $finding.id)) as $prev |
      if $prev == null then
        . + {lifecycle: "new"}
      elif .severity == "resolved" then
        . + {lifecycle: "resolved"}
      elif .severity > ($prev.severity // 0) then
        . + {lifecycle: "regressed"}
      elif .severity < ($prev.severity // 0) then
        . + {lifecycle: "improved"}
      else
        . + {lifecycle: "unchanged"}
      end
    )
  ' "$findings_file"

  # Archive current findings as previous for next run
  jq '.findings' "$findings_file" > "$history_dir/previous-findings.json"
}

# ============================================================================
# Helper: Escalate Severity (B - Business Context)
# Bumps severity for critical services
# ============================================================================

escalate_severity() {
  local findings_file="$1"
  local business_context="${SCOUTFLO_BUSINESS_CONTEXT:-{}}"

  jq --argjson context "$business_context" '
    .findings |= map(
      . as $finding |
      if ($context.critical_services[] | select(. == $finding.affected_resource)) then
        .severity = "critical" |
        .escalation_reason = "Resource in critical services list"
      else
        .
      end
    )
  ' "$findings_file"
}

# ============================================================================
# Helper: Add Remediation Links (G3)
# Maps finding IDs to setup skills with anchors
# ============================================================================

add_remediation() {
  local findings_file="$1"
  local remediation_map_file="./docs/finding-remediation-map.json"

  if [ ! -f "$remediation_map_file" ]; then
    cat "$findings_file"
    return 0
  fi

  local remediation_map=$(cat "$remediation_map_file" | jq '.mappings // {}')

  jq --argjson map "$remediation_map" '
    .findings |= map(
      . as $finding |
      if $map[$finding.id] then
        . + {
          next_safe_action: $map[$finding.id].setup_skill,
          remediation_anchor: $map[$finding.id].anchor,
          remediation_category: $map[$finding.id].category
        }
      else
        .
      end
    )
  ' "$findings_file"
}

# ============================================================================
# Helper: Append to Shared Log
# Appends findings to shared log (used by all 12 audits instead of individual files)
# ============================================================================

append_to_shared_log() {
  local findings_file="$1"
  local skill_name="$2"
  local shared_log="${SCOUTFLO_FINDINGS_LOG}"

  if [ ! -f "$findings_file" ]; then
    return 1
  fi

  # Extract findings array and append each with metadata
  jq -c '.findings[]' "$findings_file" | while read -r finding; do
    echo "$finding" | jq '. + {
      source_skill: "'$skill_name'",
      audit_time: "'$(date -u +%FT%T%Z)'",
      session_id: "'${SCOUTFLO_SESSION_ID}'"
    }' >> "$shared_log"
  done
}

# ============================================================================
# Helper: Log to History Ledger (C1)
# Records audit completion in history ledger
# ============================================================================

log_to_history() {
  local skill_name="$1"
  local status="$2"
  local finding_count="$3"
  local history_log="${SCOUTFLO_HISTORY_LOG}"

  echo "{\"skill\":\"$skill_name\",\"timestamp\":$(date +%s),\"status\":\"$status\",\"findings\":$finding_count}" >> "$history_log"
}

# ============================================================================
# Main Integration: All-in-one (called by each audit after generating findings.json)
# ============================================================================

apply_all_integration_logic() {
  local findings_file="$1"
  local skill_name="$2"

  # Apply in order: exemptions → lifecycle → escalation → remediation → append
  local temp_file=$(mktemp)

  apply_exemptions "$findings_file" > "$temp_file"
  classify_lifecycle "$temp_file" > "$temp_file.1" && mv "$temp_file.1" "$temp_file"
  escalate_severity "$temp_file" > "$temp_file.2" && mv "$temp_file.2" "$temp_file"
  add_remediation "$temp_file" > "$temp_file.3" && mv "$temp_file.3" "$temp_file"

  # Count findings
  local finding_count=$(jq '.findings | length' "$temp_file" 2>/dev/null || echo 0)

  # Append to shared log
  append_to_shared_log "$temp_file" "$skill_name"

  # Log to history
  log_to_history "$skill_name" "complete" "$finding_count"

  # Output final findings (for audit's own use)
  cat "$temp_file"

  rm -f "$temp_file" "$temp_file.1" "$temp_file.2" "$temp_file.3"
}
