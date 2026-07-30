#!/bin/bash
# audit-all v0.1.69 — Orchestrator with Smart Auto Integration
# Phase 0-13 pipeline: Initialize → Run audits with shared state → Integrate

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# ============================================================================
# PHASE 0: Initialize Shared State
# ============================================================================

phase_0_init() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ PHASE 0: INITIALIZE SHARED STATE                              ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""

  source "$LIB_DIR/shared-state-init.sh"

  echo "  Session: $SCOUTFLO_SESSION_ID"
  echo "  State dir: $SCOUTFLO_SHARED_STATE_DIR"
  echo "  Env vars exported:"
  echo "    - SCOUTFLO_SESSION_ID"
  echo "    - SCOUTFLO_BUSINESS_CONTEXT"
  echo "    - SCOUTFLO_EXEMPTIONS"
  echo "    - SCOUTFLO_TOPOLOGY"
  echo "    - SCOUTFLO_METADATA"
  echo "    - SCOUTFLO_FINDINGS_LOG"
  echo "    - SCOUTFLO_HISTORY_LOG"
  echo "    - SCOUTFLO_SHARED_STATE_DIR"
}

# ============================================================================
# PHASE 1-12: Run Audits with Shared State
# ============================================================================

phase_1_12_audits() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ PHASE 1-12: RUN AUDITS WITH SHARED STATE                      ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""

  local config="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
  [ -f "$config" ] || { echo "Config not found: $config"; exit 1; }

  # Map config keys to audits
  local audits=()

  grep -q "^prometheus:\|^loki:\|^tempo:\|^mimir:\|^victoriametrics:" "$config" && audits+=(audit-lgtm)
  grep -q "^grafana:" "$config" && audits+=(audit-grafana)
  grep -q "^sentry:" "$config" && audits+=(audit-sentry)
  grep -q "^pagerduty:" "$config" && audits+=(audit-pagerduty)
  grep -q "^datadog:" "$config" && audits+=(audit-datadog)
  grep -q "^elk:" "$config" && audits+=(audit-elk)
  grep -q "^zenduty:" "$config" && audits+=(audit-zenduty)
  grep -q "^gcp:" "$config" && audits+=(audit-gcp)
  grep -q "^aws:" "$config" && audits+=(audit-aws)
  grep -q "^digitalocean:" "$config" && audits+=(audit-digitalocean)

  echo "Queued audits: ${audits[@]}"
  echo ""

  # Run each audit (Phase 1-12)
  for i in "${!audits[@]}"; do
    local audit="${audits[$i]}"
    local phase=$((i + 1))

    echo "Phase $phase: /scoutflo:$audit"

    # Audits now read env vars and append to shared log (see integration-helpers.sh)
    /scoutflo:$audit 2>&1 | sed 's/^/  /' || {
      echo "  ⚠ Audit failed (continuing with others)"
    }
  done

  echo ""
  echo "Audits complete. Findings aggregated in shared log."
}

# ============================================================================
# PHASE 13: Integration Pipeline
# ============================================================================

phase_13_integrate() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ PHASE 13: INTEGRATION PIPELINE                                ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""

  source "$LIB_DIR/integration-pipeline.sh"
}

# ============================================================================
# Main
# ============================================================================

main() {
  phase_0_init
  phase_1_12_audits
  phase_13_integrate

  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ COMPLETE                                                       ║"
  echo "╚════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "All phases complete."
  echo "Session: $SCOUTFLO_SESSION_ID"
  echo "Results: $SCOUTFLO_SHARED_STATE_DIR"
}

main "$@"
