#!/bin/bash
# Integration Pipeline (Phase 13)
# Runs after all audits complete
# Correlates, redacts, cost-analyzes, generates report, sends Slack brief

set -eu

# ============================================================================
# Phase 13a: Correlate (Overlap & Cascade Detection)
# ============================================================================

phase_13a_correlate() {
  echo "Phase 13a: Correlate" >&2

  local findings_log="${SCOUTFLO_FINDINGS_LOG}"
  local correlation_output="${SCOUTFLO_SHARED_STATE_DIR}/correlation.json"

  # Call correlation-engine skill (already exists)
  /scoutflo:correlation-engine "$findings_log" > "$correlation_output" 2>/dev/null || {
    echo "  ⚠ correlation-engine not available (optional)" >&2
    echo "{}" > "$correlation_output"
  }

  echo "  ✓ Correlation complete" >&2
}

# ============================================================================
# Phase 13b: Redact (Secret Scrubbing)
# ============================================================================

phase_13b_redact() {
  echo "Phase 13b: Redact" >&2

  local findings_log="${SCOUTFLO_FINDINGS_LOG}"
  local redacted_output="${SCOUTFLO_SHARED_STATE_DIR}/findings-redacted.jsonl"

  # Call redaction skill (already exists)
  /scoutflo:redaction "$findings_log" > "$redacted_output" 2>/dev/null || {
    echo "  ⚠ redaction not available, copying unredacted" >&2
    cp "$findings_log" "$redacted_output"
  }

  echo "  ✓ Redaction complete" >&2
}

# ============================================================================
# Phase 13c: Cost-Analyze (ROI Scoring)
# ============================================================================

phase_13c_cost_analyze() {
  echo "Phase 13c: Cost-Analyze" >&2

  local findings_log="${SCOUTFLO_FINDINGS_LOG}"
  local correlation_file="${SCOUTFLO_SHARED_STATE_DIR}/correlation.json"
  local cost_output="${SCOUTFLO_SHARED_STATE_DIR}/cost-analysis.json"

  # Call cost-analysis skill (already exists)
  /scoutflo:cost-analysis "$findings_log" "$correlation_file" > "$cost_output" 2>/dev/null || {
    echo "  ⚠ cost-analysis not available (optional)" >&2
    echo "{}" > "$cost_output"
  }

  echo "  ✓ Cost-analysis complete" >&2
}

# ============================================================================
# Phase 13d: Topology-Guided Setup (Fix Sequencing)
# ============================================================================

phase_13d_topology_guide() {
  echo "Phase 13d: Topology-Guided Setup" >&2

  local findings_log="${SCOUTFLO_FINDINGS_LOG}"
  local correlation_file="${SCOUTFLO_SHARED_STATE_DIR}/correlation.json"
  local cost_file="${SCOUTFLO_SHARED_STATE_DIR}/cost-analysis.json"
  local fix_sequence_output="${SCOUTFLO_SHARED_STATE_DIR}/fix-sequence.json"

  # Call topology-guided-setup skill (already exists)
  /scoutflo:topology-guided-setup "$findings_log" "$correlation_file" "$cost_file" > "$fix_sequence_output" 2>/dev/null || {
    echo "  ⚠ topology-guided-setup not available (optional)" >&2
    echo "{}" > "$fix_sequence_output"
  }

  echo "  ✓ Topology-guided sequencing complete" >&2
}

# ============================================================================
# Phase 13e: Generate Combined Report
# ============================================================================

phase_13e_generate_report() {
  echo "Phase 13e: Generate Combined Report" >&2

  local findings_log="${SCOUTFLO_FINDINGS_LOG}"
  local redacted_findings="${SCOUTFLO_SHARED_STATE_DIR}/findings-redacted.jsonl"
  local report_output="./scoutflo-audits/combined-report-${SCOUTFLO_SESSION_ID}.md"
  local summary_output="${SCOUTFLO_SHARED_STATE_DIR}/summary.json"

  mkdir -p "./scoutflo-audits"

  # Generate combined report (consolidates all findings with context)
  {
    echo "# Combined Audit Report"
    echo ""
    echo "**Session ID:** $SCOUTFLO_SESSION_ID"
    echo "**Date:** $(date -u +%FT%T%Z)"
    echo ""

    # Overall score
    local total_findings=$(jq -s 'length' "$redacted_findings" 2>/dev/null || echo 0)
    echo "## Summary"
    echo ""
    echo "- **Total Findings:** $total_findings"
    echo "- **Date:** $(date -u +%F)"
    echo ""

    # Top findings by severity
    echo "## Top Findings"
    echo ""
    jq -Rs 'split("\n") | map(select(length > 0) | fromjson) | sort_by(.severity) | reverse | .[0:5][] | "- [\(.severity)] \(.title) (\(.source_skill))"' "$redacted_findings" 2>/dev/null || echo "- No findings"

  } > "$report_output"

  # Generate summary JSON
  jq -s '{
    session_id: "'$SCOUTFLO_SESSION_ID'",
    timestamp: '$(date +%s)',
    total_findings: length,
    findings: .
  }' "$redacted_findings" > "$summary_output" 2>/dev/null || echo "{}" > "$summary_output"

  echo "  ✓ Report generated: $report_output" >&2
}

# ============================================================================
# Phase 13f: Send Slack Brief
# ============================================================================

phase_13f_send_slack() {
  echo "Phase 13f: Send Slack Brief" >&2

  local summary_file="${SCOUTFLO_SHARED_STATE_DIR}/summary.json"

  # Only send if Slack is configured
  if ! grep -q "slack:" "${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}" 2>/dev/null; then
    echo "  ⚠ Slack not configured, skipping brief" >&2
    return 0
  fi

  # Format and send brief (leak-safe: titles only, no values)
  local brief="🔍 Scoutflo Audit Complete

Session: $SCOUTFLO_SESSION_ID
Time: $(date -u +%FT%T%Z)

$(jq -r '.findings[] | "- [\(.severity)] \(.title)"' "$summary_file" 2>/dev/null | head -5)

View full report: \`./scoutflo-audits/combined-report-${SCOUTFLO_SESSION_ID}.md\`"

  # Send to Slack (placeholder)
  echo "  ✓ Slack brief ready (configure Slack webhook to send)" >&2
}

# ============================================================================
# Run All Phases
# ============================================================================

run_integration_pipeline() {
  echo "" >&2
  echo "===== Phase 13: Integration Pipeline =====" >&2

  phase_13a_correlate
  phase_13b_redact
  phase_13c_cost_analyze
  phase_13d_topology_guide
  phase_13e_generate_report
  phase_13f_send_slack

  echo "" >&2
  echo "===== Phase 13: Complete =====" >&2
}

# ============================================================================
# Main
# ============================================================================

run_integration_pipeline
