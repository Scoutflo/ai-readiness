#!/bin/sh
# correlation-engine.sh
# Builds correlation.json after any audit(s): detects overlaps and cascades and
# applies business context. Works incrementally with any audit combination
# (audit-all, sequential, or a targeted subset).
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/<date>/findings.json
#         (the report-standard layout every audit writes)
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/correlation.json
#         (single canonical location; cost-analysis and topology-guided-setup read it here)

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CORRELATION_FILE="${AUDITS_DIR}/correlation.json"
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"

# Collect all findings for one run date across every target directory.
# Emits a flat JSON array; each finding gains a `target` field from its file.
# Skips the `all/` combined-report dir and the `cost-analysis/` derived dir,
# whose findings.json files do not follow the per-audit schema.
correlation_collect_findings() {
  date="$1"
  set --
  for f in "$AUDITS_DIR"/*/"$date"/findings.json; do
    [ -e "$f" ] || continue
    case "$f" in
      */all/*|*/cost-analysis/*) continue ;;
    esac
    set -- "$@" "$f"
  done

  if [ "$#" -eq 0 ]; then
    echo "[]"
    return 0
  fi

  jq -s '[ .[] | (.target // "unknown") as $t | (.findings // [])[] | . + {target: $t} ]' "$@"
}

# Overlap: the same affected service appears in findings from two or more
# different targets — candidate redundant monitoring. Reads findings on stdin.
correlation_find_overlaps() {
  jq '
    [ .[] | . as $f | (($f.affected // [])[]) as $svc |
      {service: $svc, target: $f.target, id: $f.id, title: $f.title, severity: $f.severity} ]
    | group_by(.service)
    | map(select((map(.target) | unique | length) > 1))
    | map({
        overlap_id: ("OVL-" + .[0].service),
        type: "redundant_monitoring",
        service: .[0].service,
        targets: (map(.target) | unique),
        findings: map({target, finding_id: .id, title, severity}),
        recommendation: ("Multiple stacks report findings against " + .[0].service + "; review whether the monitoring overlaps and consolidate the paging path")
      })
  '
}

# Cascade: a database-family finding whose failure would also degrade the
# alerting/paging findings reported by other targets. Heuristic, evidence-
# linked: every effect is a real finding ID from this run, never invented.
# Reads findings on stdin.
correlation_find_cascades() {
  jq '
    . as $all |
    [ .[]
      | select(((((.affected // []) | join(" ")) + " " + (.title // ""))
                | test("database|postgres|mysql|rds|cloudsql|mongo|redis"; "i")))
      | . as $root
      | {
          cascade_id: ("CASC-" + $root.id),
          root_cause: {finding_id: $root.id, title: $root.title, target: $root.target},
          effects: [ $all[]
            | select(.id != $root.id)
            | select(((.area // "") + " " + (.title // ""))
                     | test("alert|routing|paging|delivery|receiver|notification"; "i"))
            | {finding_id: .id, title: .title, target: .target,
               condition: "delivery of this alert path is untested if the root-cause resource fails"} ]
        }
      | select(.effects | length > 0)
    ]
  '
}

# Load business context (with safe defaults).
correlation_load_context() {
  if [ -f "$TOPOLOGY_FILE" ]; then
    jq '.business_context // {
      environment: "production",
      cost_sensitivity: "medium",
      critical_dependencies: []
    }' "$TOPOLOGY_FILE"
  else
    jq -n '{
      environment: "production",
      cost_sensitivity: "medium",
      critical_dependencies: []
    }'
  fi
}

# Apply business context: annotate findings; never change the audit-owned
# severity field, only add advisory annotations. Reads findings on stdin.
correlation_apply_context() {
  context=$(correlation_load_context)
  environment=$(echo "$context" | jq -r '.environment // "production"')
  critical_deps=$(echo "$context" | jq '.critical_dependencies // []')

  jq \
    --arg env "$environment" \
    --argjson crit_deps "$critical_deps" \
    '
    map(
      . as $f |
      if ($env == "staging" and (.severity == "low" or .severity == "medium")) then
        . + {context_note: "staging environment: gap may be intentional"}
      elif ((($f.affected // []) | map(. as $a | $crit_deps | index($a)) | any(. != null))) then
        . + {context_note: "touches a business-critical dependency"}
      else
        .
      end
    )
  '
}

# Write correlation.json.
correlation_save() {
  audit_date="$1"
  overlaps="$2"
  cascades="$3"
  findings="$4"

  total_raw=$(echo "$findings" | jq 'length')
  total_overlaps=$(echo "$overlaps" | jq 'length')
  total_cascades=$(echo "$cascades" | jq 'length')
  # Each overlap group of n findings represents n-1 candidate duplicates.
  dupes=$(echo "$overlaps" | jq '[.[] | (.findings | length) - 1] | add // 0')
  total_dedup=$((total_raw - dupes))

  jq -n \
    --arg version "2.0" \
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
      method: "same-affected-service overlap grouping + database-to-alerting cascade heuristic; every referenced finding_id exists in this run"
    }' > "$CORRELATION_FILE"

  echo "[correlation] Written $CORRELATION_FILE"
  echo "[correlation] Raw findings: $total_raw | Overlaps: $total_overlaps | Cascades: $total_cascades"
}

# Main entry point
correlation_run() {
  audit_date="${1:-.}"
  [ "$audit_date" = "." ] && audit_date="$(date -u +%Y-%m-%d)"

  echo "[correlation] Starting analysis for $audit_date..."

  findings=$(correlation_collect_findings "$audit_date")

  if [ "$(echo "$findings" | jq 'length')" -eq 0 ]; then
    echo "[correlation] No findings to correlate for $audit_date"
    return 0
  fi

  findings=$(echo "$findings" | correlation_apply_context)
  overlaps=$(echo "$findings" | correlation_find_overlaps)
  cascades=$(echo "$findings" | correlation_find_cascades)

  correlation_save "$audit_date" "$overlaps" "$cascades" "$findings"

  echo "[correlation] Done. Ready for cost-analysis and topology-guided setup."
}

# Read helpers for integration consumers
correlation_get_overlaps() {
  jq '.overlaps' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_get_cascades() {
  jq '.cascades' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_find_related() {
  finding_id="$1"
  jq --arg id "$finding_id" \
    '[.overlaps[] | select(.findings[].finding_id == $id)] | first // {}' \
    "$CORRELATION_FILE" 2>/dev/null || echo "{}"
}
