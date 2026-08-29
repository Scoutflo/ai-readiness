#!/bin/sh
# alert-fatigue.sh
# Builds alert-fatigue.json after any audit(s): a NON-SCORED, cross-audit roll-up
# of the alerting-noise findings the individual audits already produced, plus the
# estate-wide picture no single backend can see — where noise concentrates, which
# services are paged by MORE THAN ONE tool for one incident (cross-source storm),
# and (only when a fatigue-signal block is provided) the alert-to-incident ratio.
#
# Sibling of correlation-engine.sh / cost-analysis.sh:
#   - ZERO provider calls. Reads only this run's per-audit findings.json.
#   - Never mutates a finding or its severity; it CITES source finding-IDs.
#   - Not scored: no 0-100, no check-findings reconciliation. Advisory roll-up.
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/<date>/findings.json
#         and .../<integration>/<label>/<date>/findings.json (same dual-glob +
#         skip set as correlation-engine — signoz/kubernetes always nest two levels)
#         Optional: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue.json — an
#         operator-provided signal block {window, alerts_fired, incidents} used
#         ONLY for the alert-to-incident ratio (AF-003); absent -> AF-003 not-in-scope.
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue.json (single
#         canonical location; audit-all renders it after correlation).

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
FATIGUE_FILE="${AUDITS_DIR}/alert-fatigue.json"
SIGNAL_FILE="${ALERT_FATIGUE_SIGNAL:-${AUDITS_DIR}/fatigue.json}"

# Collect all findings for one run date across every target directory, flattened
# with a `target` field. Same dual-glob + roll-up-dir skip as correlation-engine
# (a one-level glob silently drops signoz/kubernetes/multi-target stacks).
alert_fatigue_collect_findings() {
  date="$1"
  set --
  for f in "$AUDITS_DIR"/*/"$date"/findings.json "$AUDITS_DIR"/*/*/"$date"/findings.json; do
    [ -e "$f" ] || continue
    case "$f" in
      */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*|*/alert-fatigue/*) continue ;;
    esac
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then echo "[]"; return 0; fi
  jq -s '[ .[] | (.target // "unknown") as $t | (.findings // [])[] | . + {target: $t} ]' "$@"
}

# Select the alerting-NOISE findings from the full set. This is the "cites source
# finding-IDs, never re-scores" step: it keeps each source finding's own id/severity
# and only tags it as a fatigue signal. A finding counts when its `area` names the
# alerting/routing/hygiene plane OR its title carries noise vocabulary (flapping,
# permanently-firing, missing debounce, duplicate delivery, re-notify/repeat storm,
# resolve-noise, grouping/inhibition gaps, noisy volume). This is area+title, both
# already in the data — no new per-audit field, so every audit's noise checks
# (ALR-012..018, LGTM-017/070-073, GRAF/DD/PD/JSM/ZD/GC noise controls) roll up here
# without a hardcoded ID list that would go stale. Reads findings on stdin.
alert_fatigue_select_noise() {
  jq '
    [ .[]
      | . as $f
      | (($f.area // "") | ascii_downcase) as $area
      | (($f.title // "") | ascii_downcase) as $title
      | select(
          ($area | test("alert|routing|hygiene|notif|paging|monitor"))
          or ($title | test("flap|permanent|always.?on|wallpaper|debounce|keep_?firing_?for|duplicate|dedup|re-?notify|repeat.?interval|resolve.?noise|resolve.?notif|storm|noisy|noise|high.?volume|mute|silence|grouping|group_?by|group.?wait|group.?interval|inhibit"))
        )
      | {target: $f.target, id: $f.id, title: $f.title, severity: ($f.severity // "info"),
         affected: ($f.affected // []), area: ($f.area // "")}
    ]
  '
}

# Cross-source ALERT STORM: a service (an `affected` token) that carries alerting-noise
# findings from TWO OR MORE DIFFERENT audit targets. That means one real incident on
# that service pages through N separate tools — the multi-tool fatigue no single backend
# sees. Same shape as correlation's overlap grouping, scoped to the noise subset and
# worded as a fatigue storm. Reads the noise list on stdin.
alert_fatigue_storms() {
  jq '
    [ .[] | . as $n | (($n.affected // [])[]) as $svc
      | {service: $svc, target: $n.target, id: $n.id, title: $n.title, severity: $n.severity} ]
    | group_by(.service)
    | map(select((map(.target) | unique | length) > 1))
    | map({
        af_id: ("AF-STORM-" + .[0].service),
        service: .[0].service,
        tools: (map(.target) | unique),
        tool_count: (map(.target) | unique | length),
        source_findings: map({target, finding_id: .id, title, severity}),
        note: ((map(.target) | unique | length | tostring) + " tools carry alerting-noise findings on " + .[0].service + "; one incident there pages through all of them — consolidate the paging path so a single incident is a single page")
      })
  '
}

# Roll noise up by source target: where does the alerting noise concentrate?
# Reads the noise list on stdin.
alert_fatigue_by_source() {
  jq '
    group_by(.target)
    | map({target: .[0].target, noise_findings: length,
           by_severity: (group_by(.severity) | map({(.[0].severity): length}) | add),
           finding_ids: (map(.id) | unique)})
    | sort_by(-.noise_findings)
  '
}

# Optional alert-to-incident ratio (AF-003). Computed ONLY from an operator-provided
# fatigue.json signal block {window, alerts_fired, incidents}; there is no incident
# feed in findings.json, so without this block AF-003 is not-in-scope (never a
# fabricated "N% actionable"). Emits a JSON object.
alert_fatigue_ratio() {
  if [ -f "$SIGNAL_FILE" ] && jq -e '.alerts_fired and .incidents' "$SIGNAL_FILE" >/dev/null 2>&1; then
    jq '{
      status: "computed",
      window: (.window // "unspecified"),
      alerts_fired: .alerts_fired,
      incidents: .incidents,
      alerts_per_incident: (if (.incidents // 0) > 0 then ((.alerts_fired) / (.incidents) | (.*100|round)/100) else null end),
      note: "alert-to-incident ratio from the operator-provided fatigue.json signal block; a high ratio means many alerts per real incident (fatigue). This is the only actionability number this roll-up will state, and only because you supplied the counts."
    }' "$SIGNAL_FILE"
  else
    jq -n '{
      status: "not-in-scope",
      reason: "no fatigue.json signal block ({window, alerts_fired, incidents}) — this roll-up has no incident feed and never fabricates an actionability percentage. Provide the counts to compute the ratio.",
      note: "structural noise (AF-001/AF-002) is still reported from the audits findings; only the alert-to-incident ratio needs the signal block."
    }'
  fi
}

# Write alert-fatigue.json.
alert_fatigue_save() {
  audit_date="$1"; noise="$2"; storms="$3"; by_source="$4"; ratio="$5"
  total_noise=$(printf '%s\n' "$noise" | jq 'length')
  total_storms=$(printf '%s\n' "$storms" | jq 'length')
  tools_with_noise=$(printf '%s\n' "$by_source" | jq 'length')
  # AF-NNN advisory items, each CITING source finding-IDs (never re-scoring them).
  jq -n \
    --arg version "1.0" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg audit_date "$audit_date" \
    --argjson noise "$noise" \
    --argjson storms "$storms" \
    --argjson by_source "$by_source" \
    --argjson ratio "$ratio" \
    --argjson total_noise "$total_noise" \
    --argjson total_storms "$total_storms" \
    --argjson tools_with_noise "$tools_with_noise" \
    '{
      schema: "scoutflo-alert-fatigue/v1",
      scoring_scope: "non-scored",
      version: $version,
      generated_at: $generated_at,
      audit_date: $audit_date,
      totals: {alerting_noise_findings: $total_noise, cross_source_storms: $total_storms, tools_with_noise: $tools_with_noise},
      af_findings: [
        {af_id: "AF-001", type: "alerting-noise-concentration", severity: "info",
         summary: (($total_noise|tostring) + " alerting-noise findings across " + ($tools_with_noise|tostring) + " tool(s); see by_source for where they concentrate"),
         by_source: $by_source,
         source_findings: [ $noise[] | {target, finding_id: .id, severity} ],
         note: "advisory roll-up of the audits own alerting/hygiene findings; each is scored once in its home audit — this never re-scores, it aggregates and cites."},
        {af_id: "AF-002", type: "cross-source-alert-storm", severity: (if $total_storms > 0 then "medium" else "info" end),
         summary: (($total_storms|tostring) + " service(s) carry alerting-noise findings from two or more tools — one incident pages through every tool"),
         storms: $storms},
        ({af_id: "AF-003", type: "alert-to-incident-ratio"} + $ratio)
      ],
      method: "non-scored cross-audit roll-up: selects each audits alerting-noise findings by area+title, groups by affected service to find cross-source storms (>=2 tools on one service), and — only when an operator fatigue.json signal block supplies counts — computes the alert-to-incident ratio. Zero provider calls; never mutates a finding or its severity; every source_finding id exists in this run."
    }' > "$FATIGUE_FILE"
  echo "[alert-fatigue] Written $FATIGUE_FILE"
  echo "[alert-fatigue] alerting-noise findings: $total_noise | cross-source storms: $total_storms | tools with noise: $tools_with_noise | ratio: $(printf '%s\n' "$ratio" | jq -r '.status')"
}

# Main entry point.
alert_fatigue_run() {
  audit_date="${1:-.}"
  [ "$audit_date" = "." ] && audit_date="$(date -u +%Y-%m-%d)"
  echo "[alert-fatigue] Starting roll-up for $audit_date..."
  findings=$(alert_fatigue_collect_findings "$audit_date")
  if [ "$(printf '%s\n' "$findings" | jq 'length')" -eq 0 ]; then
    echo "[alert-fatigue] No findings for $audit_date — nothing to roll up (clean skip)"
    return 0
  fi
  noise=$(printf '%s\n' "$findings" | alert_fatigue_select_noise)
  storms=$(printf '%s\n' "$noise" | alert_fatigue_storms)
  by_source=$(printf '%s\n' "$noise" | alert_fatigue_by_source)
  ratio=$(alert_fatigue_ratio)
  alert_fatigue_save "$audit_date" "$noise" "$storms" "$by_source" "$ratio"
  echo "[alert-fatigue] Done."
}
