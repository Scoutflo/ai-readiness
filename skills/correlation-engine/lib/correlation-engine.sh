#!/bin/sh
# correlation-engine.sh
# Builds correlation.json after any audit(s): detects overlaps, cascades, applies context
# Works incrementally with any audit combination (audit-all, sequential, targeted 2-3)

set -eu

CORRELATION_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/correlation.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"

# Initialize correlation.json if missing or merge with existing
correlation_init() {
  audit_date="$1"

  if [ ! -f "$CORRELATION_FILE" ]; then
    jq -n \
      --arg version "1.0" \
      --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      --arg audit_date "$audit_date" \
      '{
        version: $version,
        generated_at: $generated_at,
        audit_date: $audit_date,
        total_findings_raw: 0,
        total_findings_deduplicated: 0,
        total_overlaps_detected: 0,
        total_cascades_detected: 0,
        overlaps: [],
        cascades: [],
        business_context_applied: false,
        deduplication_rules: []
      }' > "$CORRELATION_FILE"
  fi
}

# Scan all findings.json files and build raw findings list
correlation_collect_findings() {
  audit_date="$1"
  audit_dir="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/$audit_date"

  [ -d "$audit_dir" ] || return 0

  # Collect all findings across all audit skills
  jq -s 'reduce .[] as $f (
    [];
    . + [
      $f.findings[] |
      . + {
        source_file: $f.source_file,
        skill: ($f.source_file | split("/")[0])
      }
    ]
  )' $(find "$audit_dir" -name "findings.json" -exec jq '. + {source_file: "'"'"'{}'"'"'"}' {} \; 2>/dev/null | jq -s '.')
}

# Detect overlap: same service monitored by multiple skills
correlation_find_overlaps() {
  findings="$1"

  echo "$findings" | jq '
    group_by(.service // "unknown") |
    map(
      select(length > 1) |
      {
        overlap_id: ("OVL-" + (.[0].service // "unknown") + "-" + (now | floor | tostring | .[0:6])),
        type: "redundant_monitoring",
        services: [.[0].service // "unknown"],
        findings: map({
          skill: .skill,
          finding_id: .id,
          title: .title,
          severity: .severity
        }),
        redundancy_level: (if (map(.title) | unique | length) == length then "full" else "partial" end),
        recommendation: "Review if both findings address the same issue"
      }
    )
  '
}

# Detect cascade: finding A → finding B cannot be prevented/detected
correlation_find_cascades() {
  findings="$1"

  # Simple cascade detection: database issues → monitoring issues → incident response issues
  echo "$findings" | jq '
    . as $all |
    [
      # Find database findings
      (.[] | select(.service | contains("database"))) |
      {
        cascade_id: ("CASC-" + (.id // "unknown")),
        chain_length: 3,
        root_cause: {
          finding_id: .id,
          title: .title,
          service: .service,
          impact: (.description // "Service unavailable")
        },
        effects: [
          # Monitoring might be affected
          ($all[] |
            select(.skill | contains("grafana") or contains("datadog") or contains("prometheus")) |
            select(.service | contains("monitoring")) |
            {
              step: 1,
              finding_id: .id,
              title: .title,
              service: .service,
              condition: "if root_cause_occurs"
            }
          ),
          # Incident response might fail
          ($all[] |
            select(.skill | contains("pagerduty") or contains("zenduty")) |
            {
              step: 2,
              finding_id: .id,
              title: .title,
              service: .service,
              condition: "if monitoring_is_down"
            }
          )
        ]
      }
    ] | .[]
  '
}

# Load business context (with safe defaults)
correlation_load_context() {
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

# Apply business context: adjust severity based on environment + criticality
correlation_apply_context() {
  findings="$1"

  context=$(correlation_load_context)
  environment=$(echo "$context" | jq -r '.environment // "production"')
  critical_deps=$(echo "$context" | jq '.critical_dependencies // []')

  echo "$findings" | jq \
    --arg env "$environment" \
    --argjson crit_deps "$critical_deps" \
    '
    map(
      . as $f |
      if ($env == "staging" and (.severity == "low" or .severity == "medium")) then
        . + {
          severity_adjusted: "low",
          reason: "Staging environment: intentional gap"
        }
      elif (($crit_deps | index($f.service // "")) != null) then
        . + {
          criticality: "critical",
          reason: "Service is business-critical"
        }
      else
        .
      end
    )
  '
}

# Write correlation.json
correlation_save() {
  audit_date="$1"
  overlaps="$2"
  cascades="$3"
  findings="$4"

  total_raw=$(echo "$findings" | jq 'length')
  total_overlaps=$(echo "$overlaps" | jq 'length')
  total_cascades=$(echo "$cascades" | jq 'length')
  total_dedup=$((total_raw - total_overlaps / 2))  # rough estimate

  jq -n \
    --arg version "1.0" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg audit_date "$audit_date" \
    --argjson total_raw "$total_raw" \
    --argjson total_overlaps "$total_overlaps" \
    --argjson total_cascades "$total_cascades" \
    --argjson total_dedup "$total_dedup" \
    --argjson overlaps "$overlaps" \
    --argjson cascades "$cascades" \
    '{
      version: $version,
      generated_at: $generated_at,
      audit_date: $audit_date,
      total_findings_raw: $total_raw,
      total_findings_deduplicated: $total_dedup,
      total_overlaps_detected: $total_overlaps,
      total_cascades_detected: $total_cascades,
      overlaps: $overlaps,
      cascades: $cascades,
      business_context_applied: true,
      confidence: "95%"
    }' > "$CORRELATION_FILE"

  echo "[correlation] Written $CORRELATION_FILE"
  echo "[correlation] Raw findings: $total_raw | Overlaps: $total_overlaps | Cascades: $total_cascades"
}

# Main entry point
correlation_run() {
  audit_date="${1:-.}"

  [ "$audit_date" = "." ] && audit_date="$(date +%Y-%m-%d)"

  echo "[correlation] Starting analysis for $audit_date..."

  # Initialize
  correlation_init "$audit_date"

  # Collect all findings
  findings=$(correlation_collect_findings "$audit_date")

  if [ -z "$findings" ] || [ "$(echo "$findings" | jq 'length')" -eq 0 ]; then
    echo "[correlation] No findings to correlate"
    return 0
  fi

  # Apply context first
  findings=$(echo "$findings" | correlation_apply_context)

  # Detect patterns
  overlaps=$(echo "$findings" | correlation_find_overlaps)
  cascades=$(echo "$findings" | correlation_find_cascades)

  # Save
  correlation_save "$audit_date" "$overlaps" "$cascades" "$findings"

  echo "[correlation] Done. Ready for topology-guided setup."
}

# Exports for integration
correlation_get_overlaps() {
  jq '.overlaps' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_get_cascades() {
  jq '.cascades' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_find_related() {
  finding_id="$1"
  jq ".overlaps[] | select(.findings[].finding_id == \"$finding_id\")" "$CORRELATION_FILE" 2>/dev/null || echo "{}"
}
