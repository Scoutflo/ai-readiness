#!/bin/bash
# Shared State Initialization (Phase 0)
# Initializes all shared state before any audit runs
# Sets environment variables that ALL 12 audits will read

set -eu

# Session identifier (unique per run)
AUDIT_SESSION_ID="${AUDIT_SESSION_ID:-$(date +%s)}"
SHARED_STATE_DIR="/tmp/scoutflo-session-${AUDIT_SESSION_ID}"
mkdir -p "$SHARED_STATE_DIR"

# ============================================================================
# Load Configuration Sources
# ============================================================================

load_business_context() {
  local context_file="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/business_context.md}"

  if [ ! -f "$context_file" ]; then
    echo "" >&2
    return 1
  fi

  # Parse business_context.md into env vars
  # Format: each section is a YAML-like block with key: value pairs
  # Returns: SCOUTFLO_BUSINESS_CONTEXT as JSON

  jq -Rs '{
    critical_services: (. | match("## Critical Services\n(.+?)\n##"; "gm") | .captures[0].string | split("\n") | map(select(length > 0) | sub("^- "; ""))),
    cost_sensitivity: (. | match("Cost Sensitivity:\s*(\w+)") | .captures[0].string),
    environment: (. | match("Environment:\s*(\w+)") | .captures[0].string),
    excluded_regions: (. | match("## Regions[\s\S]+?Excluded:\n(.+?)\n##"; "gm") | .captures[0].string | split("\n") | map(select(length > 0) | sub("^- "; "")))
  }' "$context_file"
}

load_exemptions() {
  local exemptions_file="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/exemptions.yaml}"

  if [ ! -f "$exemptions_file" ]; then
    echo "[]"
    return 0
  fi

  # Convert YAML exemptions to JSON array
  # Each exemption has: finding_id, resource_id, reason, expires
  yq eval -o=json '.' "$exemptions_file" 2>/dev/null || echo "[]"
}

load_topology() {
  local topology_file="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/topology.json}"

  if [ ! -f "$topology_file" ]; then
    echo "{}"
    return 0
  fi

  cat "$topology_file"
}

load_metadata() {
  local metadata_file="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/computed_metadata.jsonl}"

  if [ ! -f "$metadata_file" ]; then
    echo "[]"
    return 0
  fi

  # Read all lines as JSON array
  jq -s '.' "$metadata_file"
}

# ============================================================================
# Initialize Shared State
# ============================================================================

init_shared_state() {
  echo "Phase 0: Initialize Shared State" >&2
  echo "  Session ID: $AUDIT_SESSION_ID" >&2
  echo "  State dir: $SHARED_STATE_DIR" >&2

  # Load all sources
  BUSINESS_CONTEXT=$(load_business_context 2>/dev/null || echo "{}")
  EXEMPTIONS=$(load_exemptions)
  TOPOLOGY=$(load_topology)
  METADATA=$(load_metadata)

  # Create shared findings log (JSONL, append-only)
  FINDINGS_LOG="$SHARED_STATE_DIR/findings-in-progress.jsonl"
  touch "$FINDINGS_LOG"

  # Create history log
  HISTORY_LOG="$SHARED_STATE_DIR/audit-session.log"
  touch "$HISTORY_LOG"
  echo "{\"phase\":\"init\",\"timestamp\":$(date +%s),\"session\":\"$AUDIT_SESSION_ID\"}" >> "$HISTORY_LOG"

  # Export as environment variables (available to all audits)
  export SCOUTFLO_SESSION_ID="$AUDIT_SESSION_ID"
  export SCOUTFLO_BUSINESS_CONTEXT="$BUSINESS_CONTEXT"
  export SCOUTFLO_EXEMPTIONS="$EXEMPTIONS"
  export SCOUTFLO_TOPOLOGY="$TOPOLOGY"
  export SCOUTFLO_METADATA="$METADATA"
  export SCOUTFLO_FINDINGS_LOG="$FINDINGS_LOG"
  export SCOUTFLO_HISTORY_LOG="$HISTORY_LOG"
  export SCOUTFLO_SHARED_STATE_DIR="$SHARED_STATE_DIR"

  echo "  ✓ Shared state initialized" >&2
  echo "  ✓ 6 env vars exported to all audits" >&2
}

# ============================================================================
# Main
# ============================================================================

init_shared_state
