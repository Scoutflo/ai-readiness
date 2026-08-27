#!/bin/sh
# cost-analysis.sh
# Aggregates cost-optimization findings from all audit skills and deduplicates them
# via correlation.json into one non-scored cross-provider roll-up. There is NO 0-100
# score (cost is a ranked-savings axis, not a health grade — see cost_analysis_build_report)
# and NO skip/cache: it re-reads only the current run's local findings.json (zero API
# calls), so every invocation ALWAYS regenerates (the 24h skip was removed — see below).

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
COST_HISTORY="${AUDITS_DIR}/cost-analysis.jsonl"
CORRELATION_FILE="${AUDITS_DIR}/correlation.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"
# Derived projection of the business_context.md SSOT (authoritative when present).
BC_JSON="${BC_JSON:-$HOME/.scoutflo/business_context.json}"

# Load business context with safe defaults.
# Precedence: business_context.json (derived from the SSOT) is authoritative;
# legacy topology.json:.business_context is the migration fallback.
cost_analysis_load_context() {
  if [ -f "$BC_JSON" ]; then
    jq '{
      environment: (.environment // "production"),
      cost_sensitivity: (.cost_sensitivity // "medium"),
      critical_dependencies: (.critical_dependencies // []),
      environment_map: (.environment_map // [])
    }' "$BC_JSON"
  elif [ -f "$TOPOLOGY_FILE" ]; then
    jq '.business_context // {
      environment: "production",
      cost_sensitivity: "medium",
      sla: 99.9,
      team: "platform",
      critical_dependencies: []
    }' "$TOPOLOGY_FILE"
  else
    jq -n '{
      environment: "production",
      cost_sensitivity: "medium",
      sla: 99.9,
      team: "platform",
      critical_dependencies: []
    }'
  fi
}

# (Removed cost_analysis_should_skip — this roll-up now ALWAYS regenerates.
# It re-reads only the current run's findings at zero API cost, so caching bought
# nothing and a 24h skip could serve a stale roll-up. History is still appended
# below for the trend line; it is never used to skip a run.)

# Collect cost-optimization findings from all audit reports (no API calls).
# Per the report standard, cost findings live in the normal findings[] array
# with a parallel-section area ("cost-optimization" for AWSOPT-*/DDOPT-*),
# never in a separate top-level field. estimated_monthly_savings_usd is only
# present when the audit copied it verbatim from a provider-native
# recommendation; findings without it are presence facts and carry no figure.
cost_analysis_aggregate_findings() {
  audit_date="$1"

  # Glob BOTH the one-level `<target>/<date>/` and the two-level
  # `<integration>/<label>/<date>/` layouts (multi-target labels, and single-block
  # signoz/kubernetes which always nest), mirroring audit-all's aggregation. Skip
  # the derived/combined dirs whose findings.json is not a scored per-audit file.
  set --
  for findings_file in "$AUDITS_DIR"/*/"$audit_date"/findings.json "$AUDITS_DIR"/*/*/"$audit_date"/findings.json; do
    [ -e "$findings_file" ] || continue
    case "$findings_file" in
      */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*) continue ;;
    esac
    set -- "$@" "$findings_file"
  done

  if [ "$#" -eq 0 ]; then
    echo "[]"
    return 0
  fi

  jq -s --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [ .[] | (.target // "unknown") as $t | (.findings // [])[]
      | select(.area == "cost-optimization")
      | {
          id, title,
          source_target: $t,
          affected: (.affected // []),
          estimated_monthly_savings_usd: (.estimated_monthly_savings_usd // null),
          imported_at: $captured
        }
    ]' "$@"
}

# Apply deduplication: mark cost findings whose finding ID appears in a
# correlation.json overlap group (same service flagged by multiple targets).
cost_analysis_deduplicate() {
  findings="$1"

  if [ ! -f "$CORRELATION_FILE" ]; then
    # No correlation = no dedup possible, return as-is
    printf '%s\n' "$findings"
    return 0
  fi

  correlation=$(jq '.overlaps // []' "$CORRELATION_FILE")

  printf '%s\n' "$findings" | jq \
    --argjson overlaps "$correlation" \
    '
    map(
      . as $cost |
      ([$overlaps[] | select(.findings[]?.finding_id == $cost.id)] | first) as $ovl |
      . + {
        deduplicated: ($ovl != null),
        dedup_reason: ($ovl.recommendation // "No overlap")
      }
    )
    '
}

# Build the aggregated cost report. No score is computed: cost findings are a
# non-scored parallel section per the report standard (scoring waste against
# reliability creates perverse incentives, and inventing an estimated-total-
# spend denominator would violate the no-invented-numbers rule). Savings totals
# sum only provider-native estimated_monthly_savings_usd values; presence-fact
# findings are counted but never given a dollar figure.
cost_analysis_build_report() {
  audit_date="$1"
  all_costs="$2"
  context="$3"

  # Trend from history (last 5 runs). Malformed ledger lines are skipped
  # (fromjson? drops them) so a corrupted history line degrades the trend,
  # never crashes the whole analysis run.
  trend_array=$(
    if [ -f "$COST_HISTORY" ]; then
      tail -5 "$COST_HISTORY" | jq -Rs '[split("\n")[] | select(length > 0) | fromjson? | {date, monthly_savings_identified, state}]'
    else
      jq -n '[]'
    fi
  )

  cost_sensitivity=$(printf '%s\n' "$context" | jq -r '.cost_sensitivity // "medium"')

  # Sort: findings with a provider-native savings figure first (largest first),
  # presence facts after, dedup-flagged entries annotated but kept.
  sorted_findings=$(printf '%s\n' "$all_costs" | jq '
    map(. + {roi_annual: (if .estimated_monthly_savings_usd != null
                          then .estimated_monthly_savings_usd * 12 else null end)})
    | sort_by(.estimated_monthly_savings_usd // -1) | reverse
  ')

  jq -n \
    --arg date "$audit_date" \
    --arg env "$(printf '%s\n' "$context" | jq -r '.environment // "production"')" \
    --arg sensitivity "$cost_sensitivity" \
    --argjson findings "$sorted_findings" \
    --argjson trend "$trend_array" \
    '
    {
      audit_date: $date,
      generated_at: (now | todate),
      environment: $env,
      cost_sensitivity: $sensitivity,
      findings: $findings,
      summary: {
        total_findings: ($findings | length),
        findings_with_native_savings_figure:
          ($findings | map(select(.estimated_monthly_savings_usd != null)) | length),
        presence_fact_findings:
          ($findings | map(select(.estimated_monthly_savings_usd == null)) | length),
        monthly_savings_identified:
          ($findings | map(.estimated_monthly_savings_usd // 0) | add),
        annual_savings_identified:
          ($findings | map(.roi_annual // 0) | add),
        deduplicated_overlaps:
          ($findings | map(select(.deduplicated == true)) | length)
      },
      note: "Savings totals sum only provider-native recommendation figures (Compute Optimizer, Cost Explorer, Datadog usage). Presence-fact findings carry no invented dollar value.",
      trend: {last_5_runs: $trend}
    }
    '
}

# Main entry point
cost_analysis_run() {
  audit_date="${1:-.}"
  # (Second positional arg is ignored; kept for call-site compatibility.)

  # Normalize audit_date to YYYY-MM-DD if "."
  if [ "$audit_date" = "." ]; then
    audit_date=$(date +%Y-%m-%d)
  fi

  # ALWAYS regenerate. This roll-up only re-reads the current run's findings
  # (zero API calls), so there is nothing worth caching — and a 24h skip that
  # served a stale roll-up is exactly the "past data overpowers the output"
  # bias we removed from the deep cost path. There is no skip and no --force:
  # every invocation rebuilds from the findings present now.
  echo "[cost-analysis] Starting analysis for $audit_date"

  # Load context
  context=$(cost_analysis_load_context)

  # Aggregate findings from all audits (zero API calls)
  all_costs=$(cost_analysis_aggregate_findings "$audit_date")

  if [ "$(printf '%s\n' "$all_costs" | jq '. | length')" -eq 0 ]; then
    echo "[cost-analysis] No cost findings available"
    return 0
  fi

  # Deduplicate using correlation data
  deduped=$(cost_analysis_deduplicate "$all_costs")

  # Build report
  report=$(cost_analysis_build_report "$audit_date" "$deduped" "$context")

  # Write report to cost-analysis.json
  report_dir="$AUDITS_DIR/cost-analysis/$audit_date"
  mkdir -p "$report_dir"
  printf '%s\n' "$report" > "$report_dir/findings.json"

  # Append to history (cost-analysis.jsonl) — ONE LINE per entry
  count=$(printf '%s\n' "$report" | jq '.summary.total_findings')
  savings=$(printf '%s\n' "$report" | jq '.summary.monthly_savings_identified')

  history_entry=$(jq -c -n \
    --arg date "$audit_date" \
    --argjson count "$count" \
    --argjson savings "$savings" \
    '{date: $date, total_findings: $count, monthly_savings_identified: $savings, state: "analyzed"}')

  printf '%s\n' "$history_entry" >> "$COST_HISTORY"

  echo "[cost-analysis] Report complete: ${report_dir}/findings.json"
  echo "[cost-analysis] Findings: $count, provider-native monthly savings identified: \$$savings"

  return 0
}
