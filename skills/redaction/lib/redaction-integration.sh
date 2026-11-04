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

  # Share the canonical patterns with reports and briefs; a second short regex
  # list silently omitted newer credential families and evidence fields.
  jq -e 'type=="object" and (.findings|type)=="array"' "$findings_file" >/dev/null || return 1
  redaction_tmp=$(umask 077; mktemp "${findings_file}.redacted.XXXXXX") || return 1
  if ! redact_content < "$findings_file" > "$redaction_tmp" ||
     ! jq -e 'type=="object" and (.findings|type)=="array"' "$redaction_tmp" >/dev/null; then
    rm -f "$redaction_tmp"; return 1
  fi
  mv "$redaction_tmp" "$findings_file"
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
