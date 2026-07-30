#!/bin/sh
# cost-analysis.sh
# Aggregates cost findings from all audit skills, deduplicates via correlation,
# and produces scored 0-100 report. Avoids re-analysis within 24h with history-driven skip logic.

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
COST_HISTORY="${AUDITS_DIR}/cost-analysis.jsonl"
CORRELATION_FILE="${AUDITS_DIR}/correlation.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"

# Load business context with safe defaults
cost_analysis_load_context() {
  if [ -f "$TOPOLOGY_FILE" ]; then
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

# Check if cost-analysis should skip (already current within 24h, no new findings)
cost_analysis_should_skip() {
  [ ! -f "$COST_HISTORY" ] && return 1  # No history = first run, DO RUN

  last_run=$(tail -1 "$COST_HISTORY" | jq -r '.date // "2000-01-01"')
  last_run_epoch=$(date -d "$last_run" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  hours_ago=$(( (now_epoch - last_run_epoch) / 3600 ))

  # Skip if <24h old AND no new audit findings
  if [ "$hours_ago" -lt 24 ]; then
    new_findings=$(find "$AUDITS_DIR" -name "findings.json" \
      -newer "$COST_HISTORY" 2>/dev/null | wc -l)

    if [ "$new_findings" -eq 0 ]; then
      echo "Cost analysis is current (${hours_ago}h old, no new findings)"
      return 0  # SKIP
    fi
  fi

  return 1  # RUN
}

# Collect cost_section from all audit reports (no API calls)
cost_analysis_aggregate_findings() {
  audit_date="$1"

  # Scan all audit directories for findings.json with cost_section
  all_costs=$(jq -n '[]')

  for audit_dir in "$AUDITS_DIR"/*; do
    [ -d "$audit_dir" ] || continue
    findings_file="$audit_dir/$audit_date/findings.json"

    [ -e "$findings_file" ] || continue
    target=$(jq -r '.target // "unknown"' "$findings_file")

    # Extract cost_section if present
    cost_section=$(jq '.cost_section // empty' "$findings_file")

    if [ -n "$cost_section" ]; then
      # Add source target + capture timestamp
      cost_with_meta=$(echo "$cost_section" | jq \
        --arg target "$target" \
        --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + {source_target: $target, imported_at: $captured}')

      all_costs=$(echo "$all_costs" | jq \
        --argjson cost "$cost_with_meta" \
        '. += [$cost]')
    fi
  done

  echo "$all_costs"
}

# Apply deduplication: check correlation.json for overlaps
cost_analysis_deduplicate() {
  findings="$1"

  if [ ! -f "$CORRELATION_FILE" ]; then
    # No correlation = no dedup possible, return as-is
    echo "$findings"
    return 0
  fi

  correlation=$(jq '.overlaps // []' "$CORRELATION_FILE")

  # Mark cost findings that overlap with other providers
  echo "$findings" | jq \
    --argjson overlaps "$correlation" \
    '
    map(
      . as $cost |
      {
        $cost,
        deduplicated: (
          $overlaps | map(
            select(
              .findings[] |
              select(.finding_id == $cost.findings[].id)
            )
          ) | length > 0
        ),
        overlap_reason: (
          ($overlaps | map(
            select(.findings[] | select(.finding_id == $cost.findings[].id))
          ) | first | .recommendation) // "No overlap"
        )
      }
    ) |
    map(
      .cost as $c |
      $c + {
        deduplicated: .deduplicated,
        dedup_reason: .overlap_reason
      }
    )
    '
}

# Calculate dynamic score (0-100)
cost_analysis_calculate_score() {
  all_costs="$1"
  context="$2"

  # Get identifiable waste total
  waste_total=$(echo "$all_costs" | jq '[.[].total_identifiable_waste // 0] | add')

  # Estimate total cloud spend (heuristic: assume waste is 5% of total)
  estimated_spend=$(echo "$waste_total * 20" | bc 2>/dev/null || echo 0)

  # Waste percentage (capped at 100)
  waste_pct=$(
    if [ "$estimated_spend" -gt 0 ]; then
      echo "scale=2; ($waste_total * 100) / $estimated_spend" | bc
    else
      echo "0"
    fi | xargs printf "%.0f"
  )
  [ "$waste_pct" -gt 100 ] && waste_pct=100

  # Count overlaps marked as deduplicated
  dedup_count=$(echo "$all_costs" | jq '[.[] | select(.deduplicated == true)] | length')

  # Count action items with <5 min fix time (heuristic: cost_section typically quick fixes)
  action_count=$(echo "$all_costs" | jq '[.[].findings[]? | select(.monthly_cost > 50)] | length')
  [ "$action_count" -lt 1 ] && action_count=0

  # Score formula: 100 - (waste% * 0.6) - (overlaps * 10) - (missing actions * 5)
  waste_component=$(echo "scale=0; $waste_pct * 60 / 100" | bc)
  dedup_component=$(echo "$dedup_count * 10" | bc)

  action_gap=$([ "$action_count" -lt 1 ] && echo "5" || echo "0")

  score=$(echo "100 - $waste_component - $dedup_component - $action_gap" | bc)
  [ "$score" -lt 0 ] && score=0
  [ "$score" -gt 100 ] && score=100

  echo "$score"
}

# Build cost-analysis.json report
cost_analysis_build_report() {
  audit_date="$1"
  all_costs="$2"
  context="$3"

  # Calculate score
  score=$(cost_analysis_calculate_score "$all_costs" "$context")

  # Get trend from history (last 5 runs)
  trend_array=$(
    if [ -f "$COST_HISTORY" ]; then
      tail -5 "$COST_HISTORY" | jq -s '[.[] | {date, overall, monthly_waste, state}]'
    else
      jq -n '[]'
    fi
  )

  # Determine trend direction
  trend_direction="stable"
  if [ -f "$COST_HISTORY" ]; then
    prev_score=$(tail -1 "$COST_HISTORY" | jq -r '.overall // 0')
    if [ "$score" -gt "$prev_score" ]; then
      trend_direction="improving"
    elif [ "$score" -lt "$prev_score" ]; then
      trend_direction="regressing"
    fi
  fi

  # Build findings array with per-finding ROI (simplified: monthly_cost / 1 day effort)
  findings_array=$(echo "$all_costs" | jq \
    'map(
      .findings[] as $f |
      {
        id: $f.id,
        title: $f.title,
        type: $f.type,
        source: $f.source_target,
        monthly_cost: $f.monthly_cost,
        roi_annual: ($f.monthly_cost * 12),
        fix_priority: (
          if $f.monthly_cost >= 200 then "high"
          elif $f.monthly_cost >= 50 then "medium"
          else "low"
          end
        ),
        effort_minutes: (
          if $f.type == "stopped_instances" then 5
          elif $f.type == "underutilized_rds" then 15
          elif $f.type == "unused_disk_snapshots" then 3
          else 10
          end
        )
      }
    ) |
    sort_by(.monthly_cost) |
    reverse
    ')

  # Sort by cost_sensitivity
  cost_sensitivity=$(echo "$context" | jq -r '.cost_sensitivity // "medium"')

  sorted_findings=$(
    if [ "$cost_sensitivity" = "high" ]; then
      # High sensitivity: sort by ROI (annual savings)
      echo "$findings_array" | jq 'sort_by(.roi_annual) | reverse'
    else
      # Low/medium sensitivity: sort by monthly impact
      echo "$findings_array" | jq 'sort_by(.monthly_cost) | reverse'
    fi
  )

  # Build final report
  jq -n \
    --arg date "$audit_date" \
    --argjson score "$score" \
    --arg env "$(echo "$context" | jq -r '.environment // "production"')" \
    --argjson findings "$sorted_findings" \
    --argjson trend "$trend_array" \
    --arg direction "$trend_direction" \
    '
    {
      audit_date: $date,
      timestamp: now | todate,
      overall_score: $score,
      environment: $env,
      findings: $findings,
      summary: {
        total_findings: ($findings | length),
        total_monthly_waste: ($findings | map(.monthly_cost) | add),
        total_annual_impact: ($findings | map(.roi_annual) | add),
        high_priority: ($findings | map(select(.fix_priority == "high")) | length),
        medium_priority: ($findings | map(select(.fix_priority == "medium")) | length),
        low_priority: ($findings | map(select(.fix_priority == "low")) | length)
      },
      trend: {
        last_5_runs: $trend,
        direction: $direction,
        momentum: (
          if $trend | length >= 2 then
            (($trend[-1].overall // 0) - ($trend[0].overall // 0)) |
            if . > 0 then "+" + (. | tostring) + " improving"
            elif . < 0 then (. | tostring) + " regressing"
            else "stable"
            end
          else "insufficient_data"
          end
        )
      }
    }
    '
}

# Main entry point
cost_analysis_run() {
  audit_date="${1:-.}"
  force="${2:-}"

  # Normalize audit_date to YYYY-MM-DD if "."
  if [ "$audit_date" = "." ]; then
    audit_date=$(date +%Y-%m-%d)
  fi

  # Check skip condition (unless --force)
  if [ "$force" != "--force" ] && cost_analysis_should_skip; then
    echo "[cost-analysis] Skipping (analysis current)"
    return 0
  fi

  echo "[cost-analysis] Starting analysis for $audit_date"

  # Load context
  context=$(cost_analysis_load_context)

  # Aggregate findings from all audits (zero API calls)
  all_costs=$(cost_analysis_aggregate_findings "$audit_date")

  if [ "$(echo "$all_costs" | jq '. | length')" -eq 0 ]; then
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
  echo "$report" > "$report_dir/findings.json"

  # Append to history (cost-analysis.jsonl)
  score=$(echo "$report" | jq '.overall_score')
  waste=$(echo "$report" | jq '.summary.total_monthly_waste')

  history_entry=$(jq -n \
    --arg date "$audit_date" \
    --arg score "$score" \
    --arg waste "$waste" \
    '{date: $date, overall: ($score | tonumber), monthly_waste: ($waste | tonumber), state: "analyzed"}')

  echo "$history_entry" >> "$COST_HISTORY"

  echo "[cost-analysis] Report complete: ${report_dir}/findings.json"
  echo "[cost-analysis] Score: $score, Monthly waste: \$$waste"

  return 0
}

# Export functions
export -f cost_analysis_should_skip
export -f cost_analysis_load_context
export -f cost_analysis_aggregate_findings
export -f cost_analysis_deduplicate
export -f cost_analysis_calculate_score
export -f cost_analysis_build_report
export -f cost_analysis_run
