#!/bin/sh
# correlation-engine.sh
# Builds correlation.json after any audit(s): detects overlaps and cascades and
# applies business context. Works incrementally with any audit combination
# (audit-all, sequential, or a targeted subset).
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/<date>/findings.json
#         and ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<integration>/<label>/<date>/findings.json
#         (the report-standard layout every audit writes; the two-level form is
#         used by every multi-target labeled list AND by single-block signoz
#         (signoz/<host>/) and kubernetes (kubernetes/<context>/), which always nest)
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/correlation.json
#         (single canonical location; cost-analysis and topology-guided-setup read it here)

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CORRELATION_FILE="${AUDITS_DIR}/correlation.json"
# Pre-v0.1.80 migration remnant: business context now lives at ~/.scoutflo/business_context.json
# (the primary source, used below). This ~/.scoutflo/topology.json path is written by no current
# skill; the fallback below only fires when business_context.json is absent, then resolves to a
# non-existent file and returns the hardcoded safe defaults — the intended no-context behavior.
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"

# Collect all findings for one run date across every target directory.
# Emits a flat JSON array; each finding gains a `target` field from its file.
# Skips the `all/` combined-report dir, the `cost-analysis/` and `cost/` derived
# dirs, and the `doctor/` dir, whose findings.json files do not follow the
# per-audit schema. Globs BOTH the one-level `<target>/<date>/` and the two-level
# `<integration>/<label>/<date>/` layouts (multi-target labels, and single-block
# signoz/kubernetes which always nest), mirroring audit-all's aggregation.
correlation_collect_findings() {
  date="$1"
  set --
  for f in "$AUDITS_DIR"/*/"$date"/findings.json "$AUDITS_DIR"/*/*/"$date"/findings.json; do
    [ -e "$f" ] || continue
    case "$f" in
      */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*) continue ;;
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

# Collect ACTIVE coverage (positive monitors/alerts), not gaps, from every target's
# inventory.json (scoutflo-inventory/v1). This is what lets the engine tell "provider A
# reports no alarm on X, but provider B actively monitors X" — the cross-tool coverage join.
# Same dual-glob + skip set as the findings collector. Each item is tagged with its provider
# (first path segment of .target, e.g. "azure" from "azure/prod-core").
correlation_collect_coverage() {
  date="$1"
  set --
  for f in "$AUDITS_DIR"/*/"$date"/inventory.json "$AUDITS_DIR"/*/*/"$date"/inventory.json; do
    [ -e "$f" ] || continue
    case "$f" in
      */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*) continue ;;
    esac
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return 0
  fi
  jq -s '[ .[] | (.target // "unknown") as $t | ($t | split("/")[0]) as $prov
           | (.items // [])[]
           | {provider: $prov, target: $t, name: (.name // ""), kind: (.kind // ""),
              covers: (.covers // ""), enabled: (.enabled != false), routes_to: (.routes_to // "")} ]' "$@"
}

# Cross-tool COVERAGE correlation (advisory only; never mutates a finding or its severity).
# For each coverage-GAP finding, check whether ANOTHER provider has an ACTIVE, ROUTED monitor
# on the same resource identity, and classify:
#   covered-elsewhere : an exact normalized covers==affected match on an enabled, routed monitor
#                       in a different provider -> single-tool-dependency, NOT zero coverage.
#   unmappable        : only a fuzzy/substring match -> possible coverage, unconfirmed (verify-pending).
#   true-gap          : no active cross-tool coverage anywhere -> a real gap to elevate.
# HONESTY BAR: covered-elsewhere requires enabled != false AND a real routes_to AND an exact
# canonical-name match; the wording is always "single-tool-dependency ... confirm the signal",
# never "covered". Confidence is highest when map-topology has run (canonical names on both sides).
# Reads findings on stdin; coverage items passed as $1.
correlation_find_coverage() {
  cov="$1"
  jq --argjson cov "$cov" '
    def norm: (. // "") | ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$";"");
    def active($prov):
      [ $cov[] | select(
          (.provider != $prov)
          and ((.kind // "") | test("^(monitor|alert_rule|log_alert|activity_log_alert)$"))
          and ((.enabled) != false)
          and (((.routes_to) | norm) as $r | ($r != "" and $r != "none" and $r != "-")) ) ];
    [ .[]
      | . as $f
      | ($f.target | split("/")[0]) as $prov
      # A finding is a coverage-gap candidate if it carries an explicit coverage_gap
      # object (the precise, audit-declared signal) OR matches the area+title heuristic
      # (the fallback when an audit has not yet adopted the optional coverage_gap field).
      | select( ($f.coverage_gap != null)
                or ( (($f.area // "") | test("coverage|alert|monitor|metric";"i"))
                     and (($f.title // "") | test("no |missing|lacks|absent|not configured|no metric|without";"i")) ) )
      | (active($prov)) as $act
      | (($f.affected // [])[]) as $r0
      | ($r0 | norm) as $r
      | select($r != "")
      | ([ $act[] | (.covers|norm) as $cn | select($cn == $r) ]) as $exact
      | ([ $act[] | (.covers|norm) as $cn
                   | select($cn != $r and ($cn|length) > 0 and (($cn|contains($r)) or ($r|contains($cn)))) ]) as $fuzzy
      | if ($exact|length) > 0 then
          { finding_id: $f.id, target: $f.target, resource: $r0, classification: "covered-elsewhere",
            covered_by: [ $exact[] | {provider, inventory_name: .name, routes_to, match: "exact"} ],
            recommendation: ("single-tool-dependency: " + $exact[0].provider + " monitor " + $exact[0].name
                             + " actively covers " + $r0 + " and routes to " + $exact[0].routes_to
                             + "; confirm it covers " + (($f.coverage_gap.signal) // "the specific signal this gap names")
                             + " before de-prioritizing") }
        elif ($fuzzy|length) > 0 then
          { finding_id: $f.id, target: $f.target, resource: $r0, classification: "unmappable",
            covered_by: [ $fuzzy[] | {provider, inventory_name: .name, routes_to, match: "fuzzy"} ],
            recommendation: ("possible coverage in " + $fuzzy[0].provider + " (monitor " + $fuzzy[0].name
                             + ") — could not confirm it is the same resource; run /scoutflo:map-topology to join by canonical service name") }
        else
          { finding_id: $f.id, target: $f.target, resource: $r0, classification: "true-gap",
            covered_by: [],
            recommendation: "no active cross-tool coverage found for this resource — elevate; this is a real gap" }
        end
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
  coverage="${5:-[]}"

  total_raw=$(printf '%s\n' "$findings" | jq 'length')
  total_overlaps=$(printf '%s\n' "$overlaps" | jq 'length')
  total_cascades=$(printf '%s\n' "$cascades" | jq 'length')
  cov_covered=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="covered-elsewhere")] | length')
  cov_true_gap=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="true-gap")] | length')
  cov_unmappable=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="unmappable")] | length')
  # Candidate duplicates are counted per DISTINCT finding, never per
  # (finding, service) row. Overlap groups are per-service, so one finding
  # that names many affected services sits in many groups; the old
  # sum-of-(group-size - 1) counted such a finding once per group and drove
  # total_findings_deduplicated negative on real inputs (raw 32, "dupes" 38,
  # total -6). Instead: within each group each finding appears once, one
  # representative per group is kept (the first in jq's stable unique order),
  # and the union across groups counts every candidate duplicate at most once.
  # This guarantees 0 <= dupes < total_raw, so the dedup total reconciles
  # (dedup = raw - dupes) and can never go negative.
  dupes=$(printf '%s\n' "$overlaps" | jq '
    [ .[] | .findings
      | map({target, finding_id}) | unique   # one row per finding per group
      | .[1:] | .[]                          # all but the kept representative
    ]
    | unique | length                        # each finding at most once overall
  ')
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
    --argjson coverage "$coverage" \
    --argjson cov_covered "$cov_covered" \
    --argjson cov_true_gap "$cov_true_gap" \
    --argjson cov_unmappable "$cov_unmappable" \
    '{
      version: $version,
      generated_at: $generated_at,
      audit_date: $audit_date,
      total_findings_raw: $total_raw,
      total_findings_deduplicated: $total_dedup,
      total_overlaps_detected: $total_overlaps,
      total_cascades_detected: $total_cascades,
      total_coverage_covered_elsewhere: $cov_covered,
      total_coverage_true_gap: $cov_true_gap,
      total_coverage_unmappable: $cov_unmappable,
      overlaps: $overlaps,
      cascades: $cascades,
      coverage: $coverage,
      method: "same-affected-service overlap grouping + database-to-alerting cascade heuristic + cross-tool coverage join (a coverage-gap finding matched against another provider active, routed monitor from inventory.json); advisory only, never mutates a finding severity; every referenced finding_id and inventory item exists in this run"
    }' > "$CORRELATION_FILE"

  echo "[correlation] Written $CORRELATION_FILE"
  echo "[correlation] Raw findings: $total_raw | Deduplicated: $total_dedup | Overlaps: $total_overlaps | Cascades: $total_cascades | Coverage: covered-elsewhere=$cov_covered true-gap=$cov_true_gap unmappable=$cov_unmappable"
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
  coverage_items=$(correlation_collect_coverage "$audit_date")
  coverage=$(printf '%s\n' "$findings" | correlation_find_coverage "$coverage_items")

  correlation_save "$audit_date" "$overlaps" "$cascades" "$findings" "$coverage"

  echo "[correlation] Done. Ready for cost-analysis and topology-guided setup."
}

# Read helpers for integration consumers
correlation_get_overlaps() {
  jq '.overlaps' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_get_cascades() {
  jq '.cascades' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_get_coverage() {
  jq '.coverage // []' "$CORRELATION_FILE" 2>/dev/null || echo "[]"
}

correlation_find_related() {
  finding_id="$1"
  jq --arg id "$finding_id" \
    '[.overlaps[] | select(.findings[].finding_id == $id)] | first // {}' \
    "$CORRELATION_FILE" 2>/dev/null || echo "{}"
}
