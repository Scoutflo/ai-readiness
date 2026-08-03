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

# Cascade: a datastore-dependency finding whose affected resource is ALSO named
# in another finding's affected list — i.e. a real shared-resource join, not a
# keyword guess. Both the root and every effect reference the same concrete
# resource token, so each cascade is evidence-backed: "datastore X has a
# reliability gap, and finding Y also depends on X." Without a shared resource
# there is no cascade emitted (we never invent a dependency edge). Effects are
# further limited to alerting/observability-area findings, since the cascade
# claim is specifically "if X fails, will you find out?".
#
# Precision rules that killed the v0.1.72 over-match:
#  - root affected must name a concrete datastore resource, not prose like
#    "4 managed databases" (requires a token that looks like a resource id/name);
#  - effect must SHARE an affected token with the root (a real join), so the
#    same 28-effect list can never attach to every root;
#  - config/cost/dashboard-only findings are excluded as roots.
# Reads findings on stdin.
correlation_find_cascades() {
  jq '
    # A resource token is "concrete" if it is not empty prose — we keep tokens
    # that contain a service/host/db-style name and drop bare count phrases.
    def concrete_tokens:
      (.affected // [])
      | map(ascii_downcase)
      | map(select(test("[a-z0-9]-[a-z0-9]|_|\\.|:")))   # svc-name / a_b / a.b / ns:x shapes
      | unique;
    . as $all
    | [ .[]
        | . as $root
        # root must be a datastore/dependency reliability finding with concrete affected
        | select((.area // "") | test("durab|data|database|reliab|backend|dependency"; "i"))
        | ($root | concrete_tokens) as $rtok
        | select($rtok | length > 0)
        # datastore signal in the affected/title
        | select((((($root.affected // []) | join(" ")) + " " + ($root.title // ""))
                  | test("database|postgres|mysql|rds|cloudsql|mongo|redis|cache|datastore|db"; "i")))
        | {
            cascade_id: ("CASC-" + $root.id),
            root_cause: {finding_id: $root.id, title: $root.title, target: $root.target,
                         shared_resources: $rtok},
            effects: [ $all[]
              | select(.id != $root.id)
              | select((.area // "") | test("alert|routing|deliver|notif|monitor|observab|coverage"; "i"))
              # REAL JOIN: effect must share a concrete resource token with the root
              | . as $eff
              | select((($eff | concrete_tokens) - ($rtok | map(select(. as $t | true)))) as $x
                       | (($eff | concrete_tokens) | map(. as $t | $rtok | index($t)) | any(. != null)))
              | {finding_id: .id, title: .title, target: .target,
                 condition: "shares a resource with the datastore finding; verify its signal survives if that datastore degrades"} ]
          }
        | select(.effects | length > 0)
      ]
  '
}

# Load business context (with safe defaults).
# Precedence: business_context.json (derived from the SSOT) is authoritative;
# legacy topology.json:.business_context is the migration fallback.
correlation_load_context() {
  BC_JSON="${BC_JSON:-$HOME/.scoutflo/business_context.json}"
  if [ -f "$BC_JSON" ]; then
    jq '{
      environment: (.environment // "production"),
      cost_sensitivity: (.cost_sensitivity // "medium"),
      critical_dependencies: (.critical_dependencies // [])
    }' "$BC_JSON"
  elif [ -f "$TOPOLOGY_FILE" ]; then
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
  environment=$(printf '%s\n' "$context" | jq -r '.environment // "production"')
  critical_deps=$(printf '%s\n' "$context" | jq '.critical_dependencies // []')

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

  total_raw=$(printf '%s\n' "$findings" | jq 'length')
  total_overlaps=$(printf '%s\n' "$overlaps" | jq 'length')
  total_cascades=$(printf '%s\n' "$cascades" | jq 'length')
  # Each overlap group of n findings represents n-1 candidate duplicates.
  dupes=$(printf '%s\n' "$overlaps" | jq '[.[] | (.findings | length) - 1] | add // 0')
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

  if [ "$(printf '%s\n' "$findings" | jq 'length')" -eq 0 ]; then
    echo "[correlation] No findings to correlate for $audit_date"
    return 0
  fi

  findings=$(printf '%s\n' "$findings" | correlation_apply_context)
  overlaps=$(printf '%s\n' "$findings" | correlation_find_overlaps)
  cascades=$(printf '%s\n' "$findings" | correlation_find_cascades)

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
