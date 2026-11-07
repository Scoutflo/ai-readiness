#!/bin/sh
# alert-fatigue.sh
# Builds alert-fatigue.json after any audit(s): a NON-SCORED alert noise & fatigue
# ANALYSIS. Two data sources, both LOCAL to this library (zero provider calls here):
#   1. Each audit findings.json — the CONFIG-tier picture (structural noise).
#   2. An optional fatigue-signals.json — the measured FIRE-HISTORY tier (per-alert
#      fires / flapping / stuck-duration / off-hours / reaches-a-human), produced by
#      the skill read-only fire-history collection lane (the provider calls happen
#      THERE, in the audit lane, never in this library). See references/fire-history-reads.md.
#
# From those it computes the fatigue analysis no single backend exposes:
#   AF-001 alerting-noise concentration (config, by tool)
#   AF-002 potential cross-source overlap (shared configuration findings, not delivered pages)
#   AF-003 alert-to-incident ratio (from a real incident feed OR operator fatigue.json)
#   AF-004 reachability   — how many alerting objects CANNOT reach a human (measured)
#   AF-005 measured volume & flapping — real fires, flap rate, top offenders by fatigue impact
#   AF-006 chronic / stuck — objects firing continuously for a long time (measured)
#   AF-007 fatigue anti-pattern histogram — noise classified into named failure modes
#
# Sibling of correlation-engine.sh / cost-analysis.sh:
#   - ZERO provider calls IN THIS LIBRARY. Reads only local files.
#   - Never mutates a finding or its severity; it CITES source finding-IDs.
#   - Not scored: no 0-100, no check-findings reconciliation. Advisory analysis.
#   - NEVER fabricates a measured number: a tier with no data is not-in-scope / verify-pending.
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/<date>/findings.json
#         and .../<integration>/<label>/<date>/findings.json (dual-glob + roll-up skip)
#         Optional: ${SCOUTFLO_AUDIT_DIR}/fatigue-signals.json (scoutflo-fatigue-signals/v1)
#           — the measured fire-history tier + optional incident_feed block.
#         Optional: ${SCOUTFLO_AUDIT_DIR}/fatigue.json {window, alerts_fired, incidents}
#           — operator-supplied incident counts (AF-003 fallback if no live feed).
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue.json

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
FATIGUE_FILE="${AUDITS_DIR}/alert-fatigue.json"
AF_IDENTITY_LIB="${CLAUDE_PLUGIN_ROOT:-.}/skills/correlation-engine/lib"
SIGNAL_FILE="${ALERT_FATIGUE_SIGNAL:-${AUDITS_DIR}/fatigue.json}"
SIGNALS_FILE="${ALERT_FATIGUE_SIGNALS:-${AUDITS_DIR}/fatigue-signals.json}"

# Collect all findings for one run date across every target directory, flattened
# with a `target` field. Same dual-glob + roll-up-dir skip as correlation-engine
# (a one-level glob silently drops signoz/kubernetes/multi-target stacks).
alert_fatigue_collect_findings() {
  date="$1"
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$date" || return 1
  set --
  for f in "$AUDITS_DIR"/*/"$date"/findings.json "$AUDITS_DIR"/*/*/"$date"/findings.json; do
    [ -e "$f" ] || continue
    sf_run_file "$f" || continue
    relative="${f#"$AUDITS_DIR"/}"
    case "$relative" in
      all/*|cost-analysis/*|cost/*|doctor/*|alert-fatigue/*) continue ;;
    esac
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then echo "[]"; return 0; fi
  # The artifact directory is the stable source identity, including labels.
  # Legacy structured .target metadata remains in the source, never concatenated.
  jq -n --arg root "$AUDITS_DIR/" --arg date "$date" --arg suffix "/$date/findings.json" '[
    inputs | . as $doc | (input_filename | ltrimstr($root) | rtrimstr($suffix)) as $t
    | (.findings // [])[] | . + {target: $t, _audit_date:$date, _document_date:$doc.run_date, _document_target:$doc.target, _generated_at:$doc.generated_at, _collection:$doc.collection}
  ]' "$@"
}

# Select the alerting-NOISE findings from the full set. Keeps each source finding
# own id/severity and only tags it as a fatigue signal. A finding counts when its
# `area` names the alerting/routing/hygiene plane OR its title carries noise vocabulary.
# area+title, both already in the data — no new per-audit field. Reads findings on stdin.
alert_fatigue_select_noise() {
  jq -L "$AF_IDENTITY_LIB" '
    include "service-identity";
    [ .[]
      | select(((.status as $s | [null, "configured", "validated-live"] | index($s)) != null
           and (.lifecycle as $l | [null, "new", "unchanged", "regressed"] | index($l)) != null))
      | . as $f
      | (($f.area // "") | ascii_downcase) as $area
      | (($f.title // "") | ascii_downcase) as $title
      | select(
          ($area | test("alert|routing|hygiene|notif|paging|monitor"))
          or ($title | test("flap|permanent|always.?on|wallpaper|debounce|keep_?firing_?for|duplicate|dedup|re-?notify|repeat.?interval|resolve.?noise|resolve.?notif|storm|noisy|noise|high.?volume|mute|silence|grouping|group_?by|group.?wait|group.?interval|inhibit"))
        )
      | {target: $f.target, id: $f.id, title: $f.title, severity: ($f.severity // "info"),
         affected: ($f.affected // []), area: ($f.area // ""),
         _bindings: ($f|si_finding_bindings),
         correlation_affected: (if (($f.target // "") | split("/")[0])=="splunk_oncall" then
           if ($f.correlation_affected|type)=="array" then
             [$f.correlation_affected[] | select(type=="string")
              | select(test("\\S") and (test("^route-[0-9]+$")|not))
              | select(. as $token | ($f.affected // []) | index($token))] | unique
           else [] end
         else ($f.affected // []) end)}
    ]
  '
}

# Candidate overlap uses the same generation-bound typed identity as coverage.
# Name-only legacy data still contributes to AF-001, never to a cross-target join.
alert_fatigue_storms() {
  jq -L "$AF_IDENTITY_LIB" '
    include "service-identity";
    [ .[] | . as $n | (._bindings // [])[]
      | {service:.affected,service_identity,key,evidence,target:$n.target,id:$n.id,title:$n.title,severity:$n.severity} ]
    | group_by(.key)
    | map(select(si_rows_consistent and (map(.target)|unique|length)>1))
    | map({af_id:("AF-STORM-"+(.[0].key|@base64)),service:.[0].service,service_identity:.[0].service_identity,
        tools:(map(.target)|unique),tool_count:(map(.target)|unique|length),
        source_findings:(map({target,finding_id:.id,title,severity,evidence})|unique),
        note:((map(.target)|unique|length|tostring)+" audit targets carry alerting configuration findings for this verified scoped identity; inspect whether they describe one linked path or independent paths. Shared findings do not prove duplicate events, pages or human delivery")})'
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

# ClickStack/HyperDX standalone dispatch uses audit-clickstack for config.
# Its history is not implemented by the native AF collection harness. Preserve
# other provider measurements and record that boundary even for zero findings.
alert_fatigue_clickstack_coverage() {
  af_date="$1"
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$af_date" || return 1
  set --
  for af_file in "$AUDITS_DIR"/clickstack/"$af_date"/findings.json "$AUDITS_DIR"/clickstack/*/"$af_date"/findings.json; do
    [ -f "$af_file" ] || continue
    sf_run_file "$af_file" || continue
    set -- "$@" "$af_file"
  done
  if [ "$#" -eq 0 ]; then cat; return; fi
  af_clickstack_targets=$(jq -n --arg root "$AUDITS_DIR/" --arg suffix "/$af_date/findings.json" --arg d "$af_date" '
    [inputs | . as $doc | (input_filename|ltrimstr($root)|rtrimstr($suffix)) as $target | select($doc.run_date==$d and $doc.target==$target) | $target] | unique' "$@") || return 1
  jq --argjson targets "$af_clickstack_targets" '. as $existing | . + [$targets[] | . as $target
    | select(any($existing[]; .provider=="clickstack" and (.target // "clickstack")==$target)|not)
    | {provider:"clickstack",target:$target,tier:"fire-history",status:"verify-pending",verification:"spec-only",
       reason:"Native ClickStack/HyperDX fire-history collection is not implemented here; audit-clickstack supplies configuration findings only. No event or notification totals inferred"}]'
}

# --- FIRE-HISTORY (measured) tier --------------------------------------------
# Validate an immutable local snapshot before either the measurements OR incident
# feed can be read. Invalid input is retained for correction; the new roll-up
# carries a blocked tier and the entry point returns nonzero after writing it.
alert_fatigue_prepare_signals() {
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$audit_date" || return 1
  AF_SIGNAL_STATE="absent"; AF_SIGNAL_REASON=""
  AF_SIGNALS_DOCUMENT='{"signals":[],"provider_coverage":[]}'
  if [ ! -e "$SIGNALS_FILE" ] && [ ! -L "$SIGNALS_FILE" ]; then return 0; fi
  AF_SIGNAL_STATE="blocked"
  AF_SIGNAL_REASON="fatigue-signals.json failed validation for the requested run date; correct or recollect the retained input and rerun"
  af_validator="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/check-fatigue-signals.sh"
  if [ ! -f "$af_validator" ]; then
    AF_SIGNAL_REASON="signals validator unavailable; set CLAUDE_PLUGIN_ROOT to the installed plugin and rerun"
    return 0
  fi
  af_tmp="$(mktemp -d "${TMPDIR:-/tmp}/scoutflo-af-signals.XXXXXX")" || return 1
  if [ -f "$SIGNALS_FILE" ] && cat < "$SIGNALS_FILE" > "$af_tmp/signals.json" 2>/dev/null \
     && sh "$af_validator" "$af_tmp/signals.json" "$AUDITS_DIR" "$audit_date" >&2; then
    AF_SIGNALS_DOCUMENT="$(cat "$af_tmp/signals.json")" || { rm -rf "$af_tmp"; return 1; }
    if [ "$SF_RUN_MODE" = selected ]; then
      AF_SIGNALS_DOCUMENT=$(printf '%s' "$AF_SIGNALS_DOCUMENT" | jq --argjson run "$SF_RUN_DOCUMENT" '
        def utc_instant:
          capture("^(?<seconds>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.(?<fraction>[0-9]+))?Z$")
          | [(.seconds+"Z"|fromdateiso8601), ((.fraction // "")|sub("0+$";""))];
        def current_instant:
          now|tostring|capture("^(?<seconds>[0-9]+)(?:\\.(?<fraction>[0-9]+))?$")
          | [(.seconds|tonumber), ((.fraction // "")|sub("0+$";""))];
        . as $doc
        | (try ((.generated_at|utc_instant) as $generated
            | $generated >= ($run.started_at|utc_instant) and $generated <= current_instant) catch false) as $fresh
        | .signals = [(.signals // [])[] | select($fresh and ((.target // .provider) as $t | ($run.completed_targets|index($t))!=null))]
        | .provider_coverage = [(.provider_coverage // [])[] | select((.target // .provider) as $t | ($run.targets|index($t))!=null)
           | if .status=="collected" and (($fresh|not) or ((.target // .provider) as $t | ($run.completed_targets|index($t))==null))
             then .status="verify-pending" | .reason="No fresh completed target evidence in this selected run" else . end]
        | if .incident_feed.status=="collected" and (($fresh|not) or (.incident_feed.target as $t | ($run.completed_targets|index($t))==null))
          then .incident_feed={status:"verify-pending",reason:"Incident population lacks a fresh completed target binding for this selected run"} else . end') || { rm -rf "$af_tmp"; return 1; }
    fi
    AF_SIGNAL_STATE="validated"
    AF_SIGNAL_REASON=""
  fi
  rm -rf "$af_tmp"
}
alert_fatigue_load_signals() {
  printf '%s\n' "$AF_SIGNALS_DOCUMENT" | jq '[.signals[] | . + {target: (.target // .provider)}]'
}
alert_fatigue_signal_coverage() {
  printf '%s\n' "$AF_SIGNALS_DOCUMENT" | jq '(.provider_coverage // [])'
}

# A native On-Call incident cohort has different units from source alert fires.
# Validate and summarize the safe local artifact; never relabel incidents or
# incident-lifetime alertCount as `fires` or manufacture an AF-003 ratio.
alert_fatigue_oncall_history() {
  AF_ONCALL_HISTORY='[]'
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$audit_date" || return 1
  af_history_reader="${CLAUDE_PLUGIN_ROOT:-.}/skills/audit-splunk-oncall/scripts/history.sh"
  for af_history_file in "$AUDITS_DIR"/splunk_oncall/"$audit_date"/oncall-history.json "$AUDITS_DIR"/splunk_oncall/*/"$audit_date"/oncall-history.json; do
    [ -e "$af_history_file" ] || [ -L "$af_history_file" ] || continue
    sf_run_file "$af_history_file" || continue
    af_relative="${af_history_file#"$AUDITS_DIR"/}"
    af_target="${af_relative%/"$audit_date"/oncall-history.json}"
    if [ -f "$af_history_reader" ] && af_history_summary=$(sh "$af_history_reader" --summarize "$af_history_file" --run-date "$audit_date" --target "$af_target" 2>/dev/null); then
      :
    else
      af_history_summary=$(jq -n --arg t "$af_target" '{target:$t,status:"blocked",complete_window:false,population_incidents:null,reason:"native incident history failed target, date, projection or completeness validation; retain and recollect the input"}')
      AF_INPUT_STATE=blocked
      AF_INPUT_REASON='native On-Call incident history failed validation; correct or recollect it for this target and run date'
    fi
    AF_ONCALL_HISTORY=$(printf '%s\n%s\n' "$AF_ONCALL_HISTORY" "$af_history_summary" | jq -sc '.[0]+[.[1]]') || return 1
  done
}

# Operator counts have no collection timestamp in their legacy contract. Check
# their declared window and numeric bounds when they are the selected ratio input.
alert_fatigue_prepare_operator() {
  AF_OPERATOR_DOCUMENT='{}'; AF_OPERATOR_INVALID=0
  AF_INPUT_STATE="$AF_SIGNAL_STATE"; AF_INPUT_REASON="$AF_SIGNAL_REASON"
  [ "$AF_SIGNAL_STATE" != "blocked" ] || return 0
  if printf '%s' "$AF_SIGNALS_DOCUMENT" | jq -e '.incident_feed.status=="collected"' >/dev/null; then return 0; fi
  if [ ! -e "$SIGNAL_FILE" ] && [ ! -L "$SIGNAL_FILE" ]; then return 0; fi
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$audit_date" || return 1
  if [ "$SF_RUN_MODE" = selected ]; then
    AF_OPERATOR_INVALID=1; AF_INPUT_STATE=blocked
    AF_INPUT_REASON='Legacy operator fatigue counts have no target/generation binding for this selected run; provide a validated scoped measured snapshot'
    return 0
  fi
  if [ -f "$SIGNAL_FILE" ] && AF_OPERATOR_DOCUMENT="$(cat < "$SIGNAL_FILE" 2>/dev/null)" \
     && printf '%s' "$AF_OPERATOR_DOCUMENT" | jq -se 'length==1 and (.[0] | type=="object"
       and (.window|type)=="string" and (.window|test("\\S"))
       and (.alerts_fired|type)=="number" and .alerts_fired>=0
       and (.incidents|type)=="number" and .incidents>=0)' >/dev/null 2>&1; then
    return 0
  fi
  AF_OPERATOR_DOCUMENT='{}'; AF_OPERATOR_INVALID=1
  AF_INPUT_STATE="blocked"
  AF_INPUT_REASON="operator fatigue.json is invalid; supply one JSON object with a stated window and nonnegative alerts_fired and incidents counts, then rerun"
}

# AF-004 reachability: of the alerting objects whose routing we could actually
# resolve (reaches_human known), how many can reach NOBODY by construction
# (zero-subscriber SNS / zero-workflow detector / no channel). Measured only —
# if no signal carries reaches_human, this is not-in-scope (never guessed).
# Reads the signals array on stdin.
alert_fatigue_reachability() {
  jq '
    length as $seen
    | [ .[] | select(has("reaches_human")) ] as $known
    | ([ $known[] | select(.reaches_human == false) ]) as $dead
    | {
        status: (if ($known|length) > 0 then "measured" else "not-in-scope" end),
        measured_objects: ($known|length),
        objects_seen: $seen,
        unreachable_objects: ($dead|length),
        routing_coverage_note: (if ($known|length) > 0 and $seen > ($known|length)
          then ("routing was resolved for " + (($known|length)|tostring) + " of " + ($seen|tostring) + " alerting objects seen this run — the unreachable count is over the RESOLVED subset, not the whole estate; the rest need a routing resolve to judge")
          else null end),
        by_reason: ($dead | map(.reach_reason // "unspecified") | group_by(.) | map({reason: .[0], count: length}) | sort_by(-.count)),
        examples: ($dead | map({provider, object_id, object_kind, reach_reason, source_finding_ids}) | .[0:10]),
        reason: (if ($known|length) > 0 then null else "no fire-history signal carried a resolved routing target (reaches_human); reachability needs the fire-history collection lane to resolve each alerting object routing to a live receiver" end)
      }'
}

# AF-005 measured volume & flapping: real fires per object over the window, the
# flapping set, and the top offenders ranked by a FATIGUE-IMPACT score (fires weighted
# up by flapping, off-hours share, and dead-end routing — each weight only added when
# its underlying datum is present, never fabricated). Reads the signals array on stdin.
alert_fatigue_volume() {
  jq '
    [ .[] | select(.fires != null) ] as $withfires
    | ($withfires
        | map(. + {fatigue_impact: (
            (.fires // 0)
            * (1
               + (if .flapping == true then 0.5 else 0 end)
               + (if .reaches_human == false then 0.5 else 0 end)
               + (if ((.fires // 0) > 0 and (.off_hours_fires // null) != null)
                    then (0.5 * ((.off_hours_fires // 0) / (.fires))) else 0 end))
          )})
        | sort_by(-.fatigue_impact)) as $ranked
    | {
        status: (if ($withfires|length) > 0 then "measured" else "not-in-scope" end),
        objects_with_history: ($withfires|length),
        total_fires: ([ $withfires[].fires ] | add // 0),
        flapping_objects: ([ $withfires[] | select(.flapping == true) ] | length),
        off_hours_known: ([ $withfires[] | select((.off_hours_fires // null) != null) ] | length),
        top_offenders: ($ranked | .[0:10] | map({provider, object_id, object_kind, fires, flapping, off_hours_fires, reaches_human, fatigue_impact: (.fatigue_impact | (.*100|round)/100), source_finding_ids})),
        reason: (if ($withfires|length) > 0 then null else "no fire-history signal carried a measured fire count; run the fire-history collection lane against a provider that exposes alarm/rule state history" end)
      }'
}

# AF-006 chronic / stuck: objects currently firing continuously for a long time
# (classic desensitization). Measured from stuck==true signals. Reads signals on stdin.
alert_fatigue_chronic() {
  jq '
    [ .[] | select(.stuck == true) ] as $stuck
    | {
        status: (if ([ .[] | select(has("stuck")) ] | length) > 0 then "measured" else "not-in-scope" end),
        chronic_objects: ($stuck|length),
        objects: ($stuck | sort_by(-(.stuck_days // 0)) | map({provider, object_id, object_kind, stuck_since, stuck_days, reaches_human, source_finding_ids}) | .[0:20]),
        reason: (if ([ .[] | select(has("stuck")) ] | length) > 0 then null else "no fire-history signal carried a stuck/chronic flag; needs the collection lane state-history read" end)
      }'
}

# AF-007 fatigue anti-pattern histogram: classify every noise finding into a named
# failure mode, enriched by the joined fire-history signal where present. This turns
# "N noise findings" into "what KIND of noise". Args: $1 = noise JSON, $2 = signals JSON.
alert_fatigue_antipatterns() {
  ap_noise="$1"; ap_signals="$2"
  printf '%s' "$ap_noise" | jq --argjson sig "$ap_signals" '
    (reduce ($sig[]) as $s ({}; reduce (($s.source_finding_ids // [])[]) as $fid (.; .[$s.target + " " + $fid] = $s))) as $idx
    | [ .[]
        | . as $f
        | ($idx[$f.target + " " + $f.id] // {}) as $s
        | (($f.title // "") | ascii_downcase) as $t
        | (($f.area // "") | ascii_downcase) as $a
        | (if ($s.stuck == true) then "chronic-stuck"
           elif ($s.reaches_human == false) or ($t | test("zero.?subscriber|no.?subscriber|no.?receiver|no.?channel|zero.?workflow|no.?workflow|routes? to (no|nobody|nowhere)|dead.?letter|reaches nobody|pages nobody|no notification")) then "dead-end"
           elif ($s.flapping == true) or ($t | test("flap|hysteresis|recovery.?threshold|debounce|keep_?firing|for.?duration|at.?least.?once|no .?for.?")) then "flap-prone"
           elif ($t | test("re-?notify|repeat.?interval|un-?gated|age.?gate|times.?seen|frequency|chronic.*re-?page")) then "un-gated-repage"
           elif ($t | test("owner|unowned|ownerless")) then "ownerless"
           elif ($t | test("no .?action|informational|decoration|never.?fired|never.?evaluat|dead.?weight|stale|paused|disabled|muted")) then "decoration-or-dead-weight"
           else "other-noise" end) as $class
        | {class: $class, target: $f.target, id: $f.id, severity: $f.severity} ]
    | {
        histogram: (group_by(.class) | map({class: .[0].class, count: length, finding_ids: (map(.id))}) | sort_by(-.count)),
        total: length
      }'
}

# AF-003 alert-to-incident ratio. Priority: (1) a real incident_feed block inside
# fatigue-signals.json (collected read-only from the paging tool — PagerDuty/Zenduty/
# Opsgenie/incident.io), then (2) an operator-supplied fatigue.json count. Absent both
# -> not-in-scope, never a fabricated actionability percentage. Emits a JSON object.
alert_fatigue_ratio() {
  # (1) live incident feed collected into fatigue-signals.json
  if [ "$AF_SIGNAL_STATE" = "blocked" ] || [ "$AF_OPERATOR_INVALID" -eq 1 ]; then
    jq -n --arg reason "$AF_INPUT_REASON" '{status:"blocked",reason:$reason}'
  elif printf '%s\n' "$AF_SIGNALS_DOCUMENT" | jq -e '(.incident_feed.status == "collected")' >/dev/null 2>&1; then
    printf '%s\n' "$AF_SIGNALS_DOCUMENT" | jq '.incident_feed | {
      status: "computed",
      source: (.source // "incident-feed"),
      window: (.window // "unspecified"),
      alerts_fired: .alerts_fired,
      incidents: .incidents,
      alerts_per_incident: (if (.incidents // 0) > 0 then ((.alerts_fired) / (.incidents) | (.*100|round)/100) else null end),
      mtta_seconds: (.mtta_seconds // null),
      mttr_seconds: (.mttr_seconds // null),
      actionable_pct: (.actionable_pct // null),
      note: "Alert-to-incident ratio computed from the collected read-only incident/ack feed. Assess actionability against the declared service objectives, paging budget, shift and observation window; no universal ratio alone establishes fatigue."
    }'
  # (2) operator-supplied count
  elif printf '%s' "$AF_OPERATOR_DOCUMENT" | jq -e 'has("alerts_fired") and has("incidents")' >/dev/null; then
    printf '%s' "$AF_OPERATOR_DOCUMENT" | jq '{
      status: "computed",
      source: "operator-fatigue.json",
      window: (.window // "unspecified"),
      alerts_fired: .alerts_fired,
      incidents: .incidents,
      alerts_per_incident: (if (.incidents // 0) > 0 then ((.alerts_fired) / (.incidents) | (.*100|round)/100) else null end),
      note: "Alert-to-incident ratio from operator-provided counts. Verify matching source-event and incident cohorts, units, window and mapping before comparing with your paging budget. The ratio alone is not an actionability or fatigue verdict."
    }'
  else
    jq -n '{
      status: "not-in-scope",
      reason: "No validated matching source-event and incident counts from an incident_feed or operator fatigue.json; AF-003 cannot compute a comparable alert-to-incident ratio.",
      note: "Configuration, source-fire and native incident-history tiers retain their independent measurements. Native response samples do not require this ratio; actionability needs reviewed labels and recall needs independent missed-event ground truth."
    }'
  fi
}

# Write alert-fatigue.json.
alert_fatigue_save() {
  audit_date="$1"; noise="$2"; storms="$3"; by_source="$4"; ratio="$5"
  mkdir -p "$AUDITS_DIR"
  signals="$6"; coverage="$7"; reachability="$8"; volume="$9"; chronic="${10}"; antipatterns="${11}"
  total_noise=$(printf '%s\n' "$noise" | jq 'length')
  total_storms=$(printf '%s\n' "$storms" | jq 'length')
  tools_with_noise=$(printf '%s\n' "$by_source" | jq 'length')
  fh_objects=$(printf '%s\n' "$signals" | jq 'length')
  jq -n \
    --arg version "1.1" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson run_selection "${AF_RUN_SELECTION:-null}" \
    --arg audit_date "$audit_date" \
    --arg input_status "$AF_INPUT_STATE" \
    --arg input_reason "$AF_INPUT_REASON" \
    --argjson noise "$noise" \
    --argjson storms "$storms" \
    --argjson by_source "$by_source" \
    --argjson ratio "$ratio" \
    --argjson coverage "$coverage" \
    --argjson reachability "$reachability" \
    --argjson volume "$volume" \
    --argjson chronic "$chronic" \
    --argjson antipatterns "$antipatterns" \
    --argjson incident_history "${AF_ONCALL_HISTORY:-[]}" \
    --argjson total_noise "$total_noise" \
    --argjson total_storms "$total_storms" \
    --argjson tools_with_noise "$tools_with_noise" \
    --argjson fh_objects "$fh_objects" \
    -L "$AF_IDENTITY_LIB" \
    'include "service-identity"; {
      schema: "scoutflo-alert-fatigue/v1",
      scoring_scope: "non-scored",
      version: $version,
      generated_at: $generated_at,
      audit_date: $audit_date,
      input_validation: {status:$input_status, reason:(if $input_reason=="" then null else $input_reason end)},
      totals: {alerting_noise_findings: $total_noise, cross_source_storms: $total_storms,
               tools_with_noise: $tools_with_noise, fire_history_objects: $fh_objects,
               unreachable_objects: (if $reachability.status=="measured" then $reachability.unreachable_objects else null end),
               chronic_objects: (if $chronic.status=="measured" then $chronic.chronic_objects else null end)},
      fire_history_coverage: $coverage,
      af_findings: [
        {af_id: "AF-001", type: "alerting-noise-concentration", severity: "info",
         summary: (($total_noise|tostring) + " alerting-noise findings across " + ($tools_with_noise|tostring) + " tool(s); see by_source for where they concentrate"),
         by_source: $by_source,
         source_findings: [ $noise[] | {target, finding_id: .id, severity} ],
         note: "advisory roll-up of the audits own alerting/hygiene findings; each is scored once in its home audit — this never re-scores, it aggregates and cites."},
        {af_id: "AF-002", type: "cross-source-alert-storm", severity: (if $total_storms > 0 then "medium" else "info" end),
         summary: (($total_storms|tostring) + " service(s) have potentially overlapping alerting configuration findings across audit targets; paging duplication and delivery are unverified"),
         identity_assessment:{status:(if any($noise[]; (._bindings|length)<(.correlation_affected|unique|length)) then "partial" else "complete-for-supplied-findings" end),
           unmappable_findings:[$noise[]|select((._bindings|length)<(.correlation_affected|unique|length))|{target,finding_id:.id}],
           conflicting_identities:([$noise[]._bindings[]]|group_by(.key)|map(select(si_rows_consistent|not)|.[0].service_identity)),
           reason:"Only current scope-qualified bindings support joins; zero groups is not proof of no duplicate paging"},
         storms: $storms},
        ({af_id: "AF-003", type: "alert-to-incident-ratio"} + $ratio),
        ({af_id: "AF-004", type: "alerting-reachability",
          severity: (if ($reachability.unreachable_objects // 0) > 0 then "high" else "info" end),
          summary: (if $reachability.status == "measured"
                    then (($reachability.unreachable_objects|tostring) + " of " + ($reachability.measured_objects|tostring) + " alerting objects have no configured receiver in the assessed routing path; alternative delivery and human receipt are unverified")
                    else "reachability not measured this run (fire-history lane did not resolve routing)" end)} + $reachability),
        ({af_id: "AF-005", type: "measured-noise-volume",
          severity: "info",
          summary: (if $volume.status == "measured"
                    then (($volume.total_fires|tostring) + " measured fires across " + ($volume.objects_with_history|tostring) + " object(s); " + ($volume.flapping_objects|tostring) + " flapping; top offenders ranked by fatigue impact")
                    elif any($incident_history[]; .status=="measured")
                    then "native On-Call incident history measured separately below; source fire totals remain unavailable"
                    else "measured volume not available this run (no fire-history signal)" end),
          incident_history:$incident_history,
          incident_history_status:(if any($incident_history[]; .status=="blocked") then "blocked" elif any($incident_history[]; .status=="measured") then "measured" else "not-in-scope" end)} + $volume),
        ({af_id: "AF-006", type: "chronic-stuck-alerts",
          severity: (if ($chronic.chronic_objects // 0) > 0 then "medium" else "info" end),
          summary: (if $chronic.status == "measured"
                    then (($chronic.chronic_objects|tostring) + " object(s) firing continuously for a long time (chronic/stuck — desensitization risk)")
                    else "chronic/stuck not measured this run (no fire-history state signal)" end)} + $chronic),
        {af_id: "AF-007", type: "fatigue-anti-pattern-histogram", severity: "info",
         summary: (($antipatterns.total|tostring) + " noise findings classified into " + (($antipatterns.histogram|length)|tostring) + " named failure modes"),
         histogram: $antipatterns.histogram}
      ],
      method: "non-scored alert-fatigue ANALYSIS over local audit findings, optional validated fatigue-signals.json, and optional validated native On-Call history. AF-005 preserves incident-cohort counts separately from source fires, incident-lifetime alerts, notification attempts and human receipt. AF-003 requires independently supported matching units and cohorts. This library makes ZERO provider calls and never changes an audit finding or its severity."
    } | if $run_selection.mode=="selected" then . + {run_selection:$run_selection} else . end' > "$FATIGUE_FILE.tmp.$$" || { rm -f "$FATIGUE_FILE.tmp.$$"; return 1; }
  if [ -n "${AF_RUN_SELECTION:-}" ]; then
    sf_run_prepare "$AUDITS_DIR" "$audit_date" || { rm -f "$FATIGUE_FILE.tmp.$$"; return 1; }
    jq -en --argjson before "$AF_RUN_SELECTION" --argjson after "$SF_RUN_DOCUMENT" '$before==$after' >/dev/null || { rm -f "$FATIGUE_FILE.tmp.$$"; echo '[alert-fatigue] selected run changed during analysis; rerun' >&2; return 1; }
  fi
  mv "$FATIGUE_FILE.tmp.$$" "$FATIGUE_FILE" || return 1
  # Precompute the summary scalars into vars first — bash 3.2 (macOS /bin/sh)
  # mis-parses MULTIPLE $(... '...' ...) command substitutions inside one
  # double-quoted string, so keep each on its own assignment line.
  sum_unreach=$(printf '%s' "$reachability" | jq -r 'if .status=="measured" then .unreachable_objects else .status end')
  sum_chronic=$(printf '%s' "$chronic" | jq -r 'if .status=="measured" then .chronic_objects else .status end')
  sum_ratio=$(printf '%s' "$ratio" | jq -r '.status')
  echo "[alert-fatigue] Written $FATIGUE_FILE"
  echo "[alert-fatigue] noise:$total_noise storms:$total_storms tools:$tools_with_noise | fire-history objects:$fh_objects unreachable:$sum_unreach chronic:$sum_chronic | ratio:$sum_ratio"
}

# Main entry point.
alert_fatigue_run() {
  audit_date="${1:-.}"
  [ "$audit_date" = "." ] && audit_date="$(date -u +%Y-%m-%d)"
  echo "[alert-fatigue] Starting analysis for $audit_date..."
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$audit_date" || return 1
  AF_RUN_SELECTION=$SF_RUN_DOCUMENT
  # No earlier generated result may survive a failed attempt as current evidence.
  rm -f "$FATIGUE_FILE" "$AUDITS_DIR/alert-fatigue-report.md" "$AUDITS_DIR/alert-fatigue-report.html" || return 1
  findings=$(alert_fatigue_collect_findings "$audit_date") || return 1
  alert_fatigue_prepare_signals || return 1
  alert_fatigue_prepare_operator || return 1
  alert_fatigue_oncall_history || return 1
  signals=$(alert_fatigue_load_signals) || return 1
  coverage=$(alert_fatigue_signal_coverage | alert_fatigue_clickstack_coverage "$audit_date") || return 1
  if [ "$(printf '%s\n' "$findings" | jq 'length')" -eq 0 ] && [ "$(printf '%s\n' "$signals" | jq 'length')" -eq 0 ]; then
    echo "[alert-fatigue] No findings and no fire-history signals for $audit_date; replacing the roll-up with empty configuration evidence and explicit measured gaps"
  fi
  noise=$(printf '%s\n' "$findings" | alert_fatigue_select_noise) || return 1
  storms=$(printf '%s\n' "$noise" | alert_fatigue_storms) || return 1
  by_source=$(printf '%s\n' "$noise" | alert_fatigue_by_source) || return 1
  ratio=$(alert_fatigue_ratio) || return 1
  reachability=$(printf '%s\n' "$signals" | alert_fatigue_reachability) || return 1
  volume=$(printf '%s\n' "$signals" | alert_fatigue_volume) || return 1
  chronic=$(printf '%s\n' "$signals" | alert_fatigue_chronic) || return 1
  antipatterns=$(alert_fatigue_antipatterns "$noise" "$signals") || return 1
  if [ "$AF_SIGNAL_STATE" = "blocked" ]; then
    reachability=$(printf '%s' "$reachability" | jq --arg reason "$AF_SIGNAL_REASON" ' . + {status:"blocked",reason:$reason,unreachable_objects:null,measured_objects:null}')
    volume=$(printf '%s' "$volume" | jq --arg reason "$AF_SIGNAL_REASON" ' . + {status:"blocked",reason:$reason,total_fires:null,objects_with_history:null,flapping_objects:null}')
    chronic=$(printf '%s' "$chronic" | jq --arg reason "$AF_SIGNAL_REASON" ' . + {status:"blocked",reason:$reason,chronic_objects:null}')
  fi
  alert_fatigue_save "$audit_date" "$noise" "$storms" "$by_source" "$ratio" \
    "$signals" "$coverage" "$reachability" "$volume" "$chronic" "$antipatterns" || return 1
  if [ "$AF_INPUT_STATE" = "blocked" ]; then
    echo "[alert-fatigue] Measured input blocked: $AF_INPUT_REASON" >&2
    return 1
  fi
  echo "[alert-fatigue] Done."
}
