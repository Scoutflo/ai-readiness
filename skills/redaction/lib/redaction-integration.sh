#!/bin/sh
# redaction-integration.sh
# Wire redaction into audit output (report.md + Slack briefs)
# Note: Caller must source redaction.sh before using these functions

set -eu

# --- Redact audit report ---
redaction_integration_report() {
  report_file="$1"

  [ -f "$report_file" ] || return 0

  # Count secrets before redacting
  before=$(count_redactions "$(cat "$report_file")")

  # Redact file in-place
  redact_file "$report_file"

  # Count secrets after redacting
  after=$(count_redactions "$(cat "$report_file")")

  redacted=$((after - before))

  if [ "$redacted" -gt 0 ]; then
    echo "[redaction] Report redacted: $redacted secrets removed from $report_file" >&2
  fi
}

# --- Redact Slack brief ---
redaction_integration_slack_brief() {
  brief_content="$1"

  # Redact content from stdin and return
  echo "$brief_content" | redact_content
}

# --- Redact findings JSON ---
redaction_integration_findings() {
  findings_file="$1"

  [ -f "$findings_file" ] || return 0

  # Read findings, redact descriptions, write back
  jq '.findings[] |= (
    .description |= (
      gsub("AKIA[0-9A-Z]{16}"; "AKIA[REDACTED]") |
      gsub("sk_live_[A-Za-z0-9]{24,}"; "sk_live_[REDACTED]") |
      gsub("Bearer [A-Za-z0-9._-]{40,}"; "Bearer [REDACTED]")
    )
  )' "$findings_file" > "$findings_file.tmp"

  mv "$findings_file.tmp" "$findings_file"
}

# --- Usage in audit skills ---
# After generating report.md:
#   redaction_integration_report "scoutflo-audits/2026-07-30/report.md"
#
# When sending Slack brief:
#   brief=$(redaction_integration_slack_brief "$brief_text")
#   curl -X POST $SLACK_WEBHOOK -d "{text: \"$brief\"}"
#
# After generating findings.json:
#   redaction_integration_findings "scoutflo-audits/2026-07-30/findings.json"
