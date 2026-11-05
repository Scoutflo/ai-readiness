#!/bin/sh
# render-report-viz.sh — deterministic report visuals generated from findings.json.
#
# Why this exists: report.md is human-readable but text-heavy. This renders the
# at-a-glance visuals (score bar, trend sparkline, severity histogram, scorecard
# bars), an optional Mermaid blast-radius graph, and a standalone report.html
# dashboard — ALL computed from the canonical findings.json (+ history.jsonl for
# the trend, topology-export.json for the graph), so a visual can never disagree
# with the numbers the way hand-written prose can. findings.json stays canonical;
# this only renders it.
#
# Usage:
#   render-report-viz.sh at-a-glance      <findings.json> [history.jsonl]
#   render-report-viz.sh scorecard        <findings.json>
#   render-report-viz.sh lanes            <findings.json>
#   render-report-viz.sh mermaid-topo     <topology-export.json> <target>
#   render-report-viz.sh topology-inventory <topology-export.json>
#   render-report-viz.sh mermaid-mesh      <topology-export.json>
#   render-report-viz.sh html             <findings.json> <out.html> [history.jsonl]
#   render-report-viz.sh overlaps         <correlation.json>
#   render-report-viz.sh rollup           <audits-dir> <run-date>
#   render-report-viz.sh inventory        <inventory.json>
#   render-report-viz.sh inventory-rollup <audits-dir> <run-date>
#
# The rollup / inventory-rollup modes glob BOTH the one-level <target>/<date>/ and
# the two-level <integration>/<label>/<date>/ layouts (multi-target labels, and
# single-block signoz/kubernetes which always nest), matching audit-all.
#
# Read-only over local artifacts; prints markdown to stdout (or writes the HTML
# file). No secrets: it renders only structured fields (scores, counts, titles,
# ids, points) — never evidence values or raw command output.
set -eu

MODE="${1:-}"; shift 2>/dev/null || true
command -v jq >/dev/null 2>&1 || { echo "render-report-viz: jq not installed" >&2; exit 1; }

GATE="${SCOUTFLO_SCORE_GATE:-85}"   # end-to-end gate (example, tune to your bar)

# viz_bar <value> <max> [width] — Unicode progress bar (█ filled, ░ empty).
viz_bar() {
  vb_v="${1:-0}"; vb_m="${2:-100}"; vb_w="${3:-20}"
  case "$vb_v$vb_m" in *[!0-9]*) vb_v=0; vb_m=100;; esac
  [ "$vb_m" -gt 0 ] || vb_m=100
  vb_f=$(( vb_v * vb_w / vb_m ))
  [ "$vb_f" -lt 0 ] && vb_f=0; [ "$vb_f" -gt "$vb_w" ] && vb_f="$vb_w"
  vb_i=0; vb_o=""
  while [ "$vb_i" -lt "$vb_f" ]; do vb_o="${vb_o}█"; vb_i=$((vb_i+1)); done
  while [ "$vb_i" -lt "$vb_w" ]; do vb_o="${vb_o}░"; vb_i=$((vb_i+1)); done
  printf '%s' "$vb_o"
}

# viz_spark "<space-separated ints>" — 8-level Unicode sparkline.
viz_spark() {
  vs_lo=""; vs_hi=""
  for vs_v in $1; do
    case "$vs_v" in *[!0-9]*) continue;; esac
    [ -z "$vs_lo" ] && { vs_lo="$vs_v"; vs_hi="$vs_v"; }
    [ "$vs_v" -lt "$vs_lo" ] && vs_lo="$vs_v"
    [ "$vs_v" -gt "$vs_hi" ] && vs_hi="$vs_v"
  done
  [ -n "$vs_lo" ] || { printf ''; return; }
  vs_r=$(( vs_hi - vs_lo )); [ "$vs_r" -gt 0 ] || vs_r=1
  vs_o=""
  for vs_v in $1; do
    case "$vs_v" in *[!0-9]*) continue;; esac
    vs_l=$(( (vs_v - vs_lo) * 7 / vs_r ))
    case "$vs_l" in
      0) vs_c="▁";; 1) vs_c="▂";; 2) vs_c="▃";; 3) vs_c="▄";;
      4) vs_c="▅";; 5) vs_c="▆";; 6) vs_c="▇";; *) vs_c="█";;
    esac
    vs_o="${vs_o}${vs_c}"
  done
  printf '%s' "$vs_o"
}

score_label() {  # a plain-language band for a 0-100 score; $2 = end_to_end (true/false)
  sl="$1"; sl_e2e="${2:-false}"
  # "end-to-end ready" requires BOTH the score gate AND the findings' own
  # end_to_end flag — a score >= GATE with end_to_end:false (excluded categories,
  # coverage gaps) is above the gate but NOT end-to-end, and saying otherwise is
  # a false green light (found live: an 86/100 with 2 excluded categories).
  if [ "$sl" -ge "$GATE" ]; then
    if [ "$sl_e2e" = "true" ]; then echo "end-to-end ready (>= ${GATE} gate)"
    else echo "above the ${GATE} gate — not end-to-end (excluded categories or coverage gaps)"
    fi
  elif [ "$sl" -ge 50 ]; then echo "good base coverage (below the ${GATE} end-to-end gate)"
  else echo "early coverage (below 50)"
  fi
}

# --- trend from history.jsonl (last 5 compatible scores, oldest first) -------
trend_scores() {  # $1 = history.jsonl (optional), $2 = current findings.json
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  tv_f="${2:-}"
  tv_model=""; tv_set=""; tv_scope='"full"'
  if [ -n "$tv_f" ] && [ -f "$tv_f" ]; then
    tv_model="$(jq -r '.score.scoring_model // ""' "$tv_f")"
    tv_set="$(jq -r '.score.check_set // ""' "$tv_f")"
    tv_scope="$(jq -c '(.scope//"full") | if .=="account" then "full" else . end' "$tv_f")"
  fi
  # Same check IDs do not make a fast subset comparable to a full audit.
  # Legacy rows without scope mean full/account; preserve their old readability.
  tail -n 30 "$1" 2>/dev/null \
    | jq -r --arg model "$tv_model" --arg set "$tv_set" --argjson scope "$tv_scope" '
        def scope_key: (.scope//"full") | if .=="account" then "full" else . end;
        select(scope_key==$scope and (.overall|type)=="number"
          and (($model=="" or $set=="") or (.scoring_model==$model and .check_set==$set))) | .overall' 2>/dev/null \
    | tail -n 5 | tr '\n' ' '
}

# A scope is a boundary of the result, not just a history-comparison key.
# Historical missing scope and explicit full/account keep their existing display.
# Escaping supports both Markdown and HTML without rendering scope text as markup.
scope_notice() {  # $1 = findings.json (or a scope-bearing inventory)
  [ -f "$1" ] || return 0
  jq -r '
    (if has("scope") and .scope != null then .scope else "full" end) as $s
    | if $s == "full" or $s == "account" then empty
      elif $s == "triage" then "TRIAGE — a subset, not a full assessment."
      elif ($s|type) == "string" and ($s|length) > 0
        then "Scoped assessment: " + $s + ". Results cover only that scope; other resources remain unassessed."
      else "Scoped assessment: scope is not a supported label; full coverage is not established."
      end
    | gsub("[\\r\\n\\t]"; " ") | @html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")
  ' "$1"
}

inventory_scope_notice() {  # use the matching audit envelope when inventory has no scope
  is_inv="$1"; is_findings="${2:-$(dirname "$1")/findings.json}"
  if jq -e 'has("scope") and .scope != null' "$is_inv" >/dev/null 2>&1; then
    scope_notice "$is_inv"
    return
  fi
  if [ -f "$is_findings" ] && jq -e --slurpfile inv "$is_inv" '
    .target == $inv[0].target and (.run_date | type) == "string"
    and ($inv[0].generated_at | type) == "string"
    and .run_date == ($inv[0].generated_at[0:10])
  ' "$is_findings" >/dev/null 2>&1; then
    scope_notice "$is_findings"
  else
    scope_notice "$is_inv"
  fi
}

# --- alert-fatigue: enrich the cited noise findings with their fix text -------
# The roll-up (alert-fatigue.json) cites WHICH findings are noise by (target, id)
# — the authoritative selection. The fix text (title / where / why / how-to-fix)
# stays canonical in each per-audit findings.json. This joins the two so the
# report can show problem -> exact fix per finding without the roll-up
# duplicating remediation. Same dual-glob + roll-up-dir skip as the lib, so a
# single-block signoz/kubernetes or a multi-target label is never dropped.
af_enriched_noise() {  # $1=alert-fatigue.json  $2=audits-dir  $3=run-date -> JSON array
  ae_afj="$1"; ae_d="$2"; ae_dt="$3"
  set --
  for ae_f in "$ae_d"/*/"$ae_dt"/findings.json "$ae_d"/*/*/"$ae_dt"/findings.json; do
    [ -e "$ae_f" ] || continue
    ae_rel="${ae_f#"$ae_d"/}"
    case "${ae_rel%%/*}" in all|cost-analysis|cost|doctor|alert-fatigue) continue ;; esac
    set -- "$@" "$ae_f"
  done
  if [ "$#" -eq 0 ]; then ae_all='[]'; else
    ae_all="$(jq -n --arg root "$ae_d/" --arg suffix "/$ae_dt/findings.json" '[
      inputs | (.target // "unknown") as $legacy
      | (input_filename | ltrimstr($root) | rtrimstr($suffix)) as $t
      | (.findings // [])[] | . + {target:$t, legacy_target:$legacy}
    ]' "$@")"
  fi
  # A finding target may be a plain string OR a structured object (audit-signoz
  # records {type,host,version,edition}); tdisp normalizes either to one display
  # string used as both the join key and the shown value, and s coerces any text
  # field that is not a string, so the renderer never does object+string.
  printf '%s' "$ae_all" | jq --slurpfile af "$ae_afj" '
    def tdisp: if type == "object" then (.host // .name // .type // tojson) else tostring end;
    def s: if type == "string" then . elif . == null then "" else tojson end;
    # Old roll-ups cite envelope targets; retain their unambiguous aliases.
    # New roll-ups use file target identities, which always take precedence.
    ((map({key: ((.legacy_target | tdisp) + "\u0001" + (.id // "")), value: .})
       | group_by(.key) | map(select(length==1) | .[0]) | from_entries)
     + (map({key: (.target + "\u0001" + (.id // "")), value:.}) | from_entries)) as $idx
    | ([ $af[0].af_findings[]? | select(.af_id == "AF-001") | .source_findings[]? ]) as $sf
    | [ $sf[] | . as $n
        | ($idx[($n.target | tdisp) + "\u0001" + $n.finding_id] // {}) as $d
        | { target: ($n.target | tdisp), id: $n.finding_id,
            severity: ($d.severity // $n.severity // "info"),
            title: (($d.title // $n.finding_id) | s),
            affected: ($d.affected // []),
            impact: (($d.impact // "") | s),
            recommendation: (($d.recommendation // "") | s),
            remediation: (($d.remediation // "") | s) } ]'
}

# AF-005 native incident history is additive to its existing fire-history fields.
# Keep units, incomplete windows and response sample denominators identical in
# Markdown and HTML. This projection does not convert incidents into fires/pages.
af_incident_history_rows() {  # $1=alert-fatigue.json -> safe display-row JSON array
  jq '
    def text: if type=="string" and length>0 then . else "not recorded" end;
    def count: if type=="number" and .>=0 and .==floor then . else null end;
    def shown: if .==null then "not measured" else tostring end;
    def average($samples):
      if ($samples|count)!=null and $samples>0 and type=="number" and .>=0
      then (.*100|round)/100|tostring else "not measured" end;
    def obj: if type=="object" then . else {} end;
    def arr: if type=="array" then . else [] end;
    def ref($prefix): if type=="string" and test("^"+$prefix+"-[a-f0-9]{24}$") then . else "not recorded" end;
    def incident: if type=="string" and test("^[0-9]{1,20}$") then . else "not recorded" end;
    def slug: if type=="string" and test("^[A-Za-z0-9][A-Za-z0-9_.-]*$") then . else "not recorded" end;
    def stamp: if type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.+-]+Z?$") then . else "not recorded" end;
    def cohort_count($observed):
      if (.|count)!=null and ($observed|count)!=null and .<=$observed then tostring else "not measured" end;
    def duration:
      obj | if (.hours|type)=="number" and (.minutes|type)=="number" and .hours>=0 and .minutes>=0
      then "\(.hours) h \(.minutes) min" else "not measured" end;
    def presence($keys):
      obj as $values | [true,false,null] | map(. as $want |
        [$keys[] | . as $key | select(if $want==null then ($values[$key]!=true and $values[$key]!=false) else $values[$key]==$want end)]
        | if length>0 then join(", ") else "none observed" end);
    def details($h;$unit):
      ($h.recurrence|obj) as $r | ($h.workload|obj) as $w | ($w.assignment_time|obj) as $d
      | ($h.observed_incidents|count) as $observed
      | ($unit and $r.interpretation=="review-candidates-not-proven-noise" and ($r.ranked_entities|type)=="array") as $rec
      | ($r.ranked_entities|arr|map(select(type=="object"))) as $rank
      | ($rec and $observed!=null and all($rank[]; (.incidents|count)!=null and .incidents<=$observed)
          and (($rank|map(.incidents|count)|map(select(.!=null))|add//0)<=$observed)) as $rec_counts
      | ($unit and $w.interpretation=="assignments-not-pages-or-human-interruptions") as $work
      | ($unit and $d.interpretation=="assignment-time-not-interruptions"
          and ($d.users|type)=="array" and $d.started_at==$h.window.started_after and $d.ended_at==$h.window.started_before) as $duty
      | { recurrence_available:$rec, recurrence_counts_valid:$rec_counts,
          missing_entity:(if $rec then $r.incidents_missing_entity|cohort_count($observed) else "not measured" end),
          recurrence:(if $rec then [$rank[] | [(.entity_ref|ref("entity")),(.service_ref|ref("service")),(.host_ref|ref("host")),
            (if $rec_counts then .incidents|cohort_count($observed) else "not measured" end),
            (.incident_numbers|arr|map(incident)|if length>0 then join(", ") else "not recorded" end),
            (if $h.provider_alert_count_unit=="alerts-received-over-incident-lifetime" then .provider_alert_count|count|shown else "not measured" end)]] else [] end),
          assignments:(if $work then
            [($w.incident_assignment_counts|arr)[] | select(type=="object") | ["Responder",(.responder_ref|ref("responder")),(.incidents|cohort_count($observed))]]
            + [($w.team_assignment_counts|arr)[] | select(type=="object") | ["Team",(.team|slug),(.incidents|cohort_count($observed))]] else [] end),
          duty_available:$duty,duty_team:($d.team|slug),duty_start:($d.started_at|stamp),duty_end:($d.ended_at|stamp),duty_lag:($d.lag_seconds|count|shown),
          duty:(if $duty then [$d.users[] | select(type=="object") | [(.user_ref|ref("log-user")),(.reported_total|duration),(.reported_adjusted_total|duration),
            (.intervals|arr|map(select(type=="object")|(.on|stamp)+" to "+(.off|stamp))|if length>0 then join("; ") else "not recorded" end)]] else [] end),
          context:(if $unit then [($h.context|arr)[] | select(type=="object" and .interpretation=="presence-only" and .original_alert_read==true)
            | . as $c | ["Basic",(.fields_present|presence(["entity","description","monitoring_tool","display_name"]))],
                        ["Raw context",(.raw_fields_present|presence(["service","environment","owner","runbook","impact"]))]
            | [($c.incident_number|incident),(if ["INFO","WARNING","ACKNOWLEDGEMENT","CRITICAL","RECOVERY"]|index($c.message_type) then $c.message_type else "not recorded" end),.[0]] + .[1]
          ] else [] end) };
    [ .af_findings[]? | select(.af_id=="AF-005")
      | (.incident_history // []) | if type=="array" then .[] else empty end
      | select(type=="object")
      | .window = (if (.window|type)=="object" then .window else {} end)
      | .response = (if (.response|type)=="object" then .response else {} end)
      | .limitations = (if (.limitations|type)=="array" then .limitations else [] end)
      | . as $h
      | (.count_unit=="incidents-started-in-window") as $unit
      | (.status=="measured" and .complete_window==true and $unit
          and (.population_incidents|count)!=null
          and (.observed_incidents|count)==.population_incidents) as $complete
      | { target:(.target|text), state:(if $complete then "measured" else "blocked" end),
          start:(.window.started_after|text), end:(.window.started_before|text),
          phases:(.window.query_phases|if type=="array" then map(select(type=="string"))|join(", ") else "not recorded" end),
          complete:(if $complete then "yes" else "no; full-window totals unavailable" end),
          observed:(if $unit then .observed_incidents|count|shown else "not measured" end),
          population:(if $complete then .population_incidents|count|shown else "not measured" end),
          provider_alerts:(if .provider_alert_count_unit=="alerts-received-over-incident-lifetime"
            then .provider_alert_count|count|shown else "not measured" end),
          ack_samples:(.response.ack_samples|count|shown),
          ack_seconds:(.response.mean_ack_seconds_observed_subset|average($h.response.ack_samples)),
          resolution_samples:(.response.resolution_samples|count|shown),
          resolution_seconds:(.response.mean_resolution_seconds_observed_subset|average($h.response.resolution_samples)),
          missing_transitions:(.response.missing_or_unverified_transitions|count|shown),
          unacknowledged:(.response.unacknowledged_or_censored|count|shown),
          details:details($h;$unit),
          note:([.reason, (.limitations // [])[]] | map(select(type=="string" and length>0)) | join("; "))
        }
    ]
  ' "$1"
}

# Render the same allowlisted observations in both report formats. No arbitrary
# payload field is serialized, and these tables never create a health verdict.
af_incident_history_details() {  # $1=markdown|html; display rows on stdin
  jq -r --arg format "$1" '
    def esc: tostring|gsub("[\\r\\n\\t]";" ")|@html|gsub("`";"&#96;")|gsub("\\|";"&#124;");
    def paragraph($s): if $format=="html" then "<p class=\"sub\">"+($s|@html)+"</p>" else "\n"+($s|esc)+"\n" end;
    def table($title;$headers;$rows):
      if $format=="html" then
        "<h2 style=\"font-size:14px\">"+($title|@html)+"</h2>"
        + (if ($rows|length)==0 then "<p class=\"sub\">No supported rows supplied; this is not a zero or a healthy result.</p>"
           else "<table><thead><tr>"+($headers|map("<th>"+(.|@html)+"</th>")|join(""))+"</tr></thead><tbody>"
             +($rows|map("<tr>"+(map("<td>"+(tostring|@html)+"</td>")|join(""))+"</tr>")|join(""))+"</tbody></table>" end)
      else "\n**"+($title|esc)+"**\n\n"
        +(if ($rows|length)==0 then "No supported rows supplied; this is not a zero or a healthy result.\n"
          else "| "+($headers|map(esc)|join(" | "))+" |\n| "+($headers|map("---")|join(" | "))+" |\n"
            +($rows|map("| "+(map(esc)|join(" | "))+" |")|join("\n"))+"\n" end) end;
    .[] | .details as $d
    | paragraph("Observed details for "+.target+"; incident start window "+.start+" to "+.end+"; "+.observed+" observed incidents. Complete window: "+.complete+".")
      , table("Recurrence candidates";["Entity reference","Service reference","Host reference","Incidents in observed cohort","Incident references","Provider alerts (incident lifetime)"];$d.recurrence)
      , paragraph("Ranked rows are the supplied exact entity/service/host groups, not proven noise or duplicate pages. Incidents without entity reference: "+$d.missing_entity+". "+(if $d.recurrence_available and ($d.recurrence_counts_valid|not) then "Inconsistent recurrence counts are unavailable. " else "" end)+"Review the named incidents against your paging budget and source evidence before tuning.")
      , table("Observed incident assignments";["Assignment kind","Reference","Assigned incidents in observed cohort"];$d.assignments)
      , paragraph("Assignments are not notification attempts, human receipts or interruptions. One incident can have multiple assignments; do not sum rows as unique incidents. Off-hours and fairness are not assessed without the declared duty model and matching evidence.")
      , table("Reported duty observations";["Duty-log user reference","Reported total","Reported adjusted total","Observed on/off intervals"];$d.duty)
      , paragraph(if $d.duty_available then "Duty-log team "+$d.duty_team+", window "+$d.duty_start+" to "+$d.duty_end+", reporting lag "+$d.duty_lag+" seconds. Durations are provider-reported first-step assignment time, not interruption time. Do not sum overlapping intervals or join log-user and responder references as the same person without verified identity." else "A supported duty log matching this window was not supplied; duty totals remain unavailable." end)
      , table("Selected original-alert context";["Selected incident","Message type","Field family","Present","Absent","Unknown"];$d.context)
      , paragraph("Presence is not correctness, usefulness or runbook accessibility. These rows cover only the selected original alert, which may be outside the incident cohort; they do not establish account-wide context coverage. Confirm the required service, environment, owner, impact and diagnostic links before proposing source enrichment.")
  '
}

# =============================================================================
case "$MODE" in
  at-a-glance)
    F="${1:?findings.json}"; HIST="${2:-}"
    [ -f "$F" ] || { echo "render-report-viz: no such file: $F" >&2; exit 1; }
    OVERALL="$(jq -r 'if .score.overall == null then "unassessed" else .score.overall end' "$F")"
    SCORE_STATE="$(jq -r '.score.state // "assessed"' "$F")"
    read -r CP CT <<EOF
$(jq -r '(([.score.categories[]?.checks_passed]|add // 0)|tostring) + " " + (([.score.categories[]?.checks_total]|add // 0)|tostring)' "$F")
EOF
    read -r SC SH SM SL SI <<EOF
$(jq -r '.severity_counts | "\(.critical//0) \(.high//0) \(.medium//0) \(.low//0) \(.info//0)"' "$F")
EOF
    SEVMAX="$(printf '%s\n' "$SC" "$SH" "$SM" "$SL" "$SI" | sort -rn | head -1)"; [ "${SEVMAX:-0}" -gt 0 ] || SEVMAX=1
    TREND="$(trend_scores "$HIST" "$F")"
    E2E="$(jq -r '.score.end_to_end // false' "$F")"
    # Severity first, then points: a +1 critical outranks a +3 high — the lever
    # is "restore the paging path", not "harvest the most points". (Found live:
    # points-first told the operator to fix Loki rate-limiting before a dead
    # default receiver.) Within a severity band, higher points win.
    TOP="$(jq -r '[.findings[]? | select((.lifecycle // "new") != "suppressed") | select((.severity!="info") and ((.points_recoverable//0)>0))]
      | sort_by([ ({critical:0,high:1,medium:2,low:3,info:4}[.severity] // 5), ((.points_recoverable // 0) * -1) ])
      | (.[0] // empty) | "\(.id)\t\(.points_recoverable)\t\(.severity)\t\(.title)"' "$F" 2>/dev/null)"

    echo "## At a glance"
    echo
    SCOPE_NOTICE="$(scope_notice "$F")"
    if [ -n "$SCOPE_NOTICE" ]; then printf '> **%s**\n\n' "$SCOPE_NOTICE"; fi
    if [ "$SCORE_STATE" = "unassessed" ] || [ "$OVERALL" = "unassessed" ]; then
      suppressed_count="$(jq -r '.score.assessment.suppressed_checks // 0' "$F")"
      blocked_count="$(jq -r '.score.assessment.blocked_checks // 0' "$F")"
      if [ "$suppressed_count" -gt 0 ] && [ "$blocked_count" -eq 0 ]; then
        echo "**Readiness: unassessed**  No unsuppressed check remains in the readiness denominator; all assessed gaps are covered by explicit exemptions."
      elif [ "$suppressed_count" -gt 0 ]; then
        echo "**Readiness: unassessed**  No unsuppressed check remains in the readiness denominator; applicable checks are blocked or explicitly exempted."
      else
        echo "**Readiness: unassessed**  No applicable check produced enough evidence for a readiness score."
      fi
    else
      echo "**Score: ${OVERALL}/100**  \`$(viz_bar "$OVERALL" 100 20)\`  $(score_label "$OVERALL" "$E2E")"
    fi
    if jq -e '.score.assessment | type == "object"' "$F" >/dev/null 2>&1; then
      read -r AA AS AX AB AU AN AC <<EOF
$(jq -r '.score.assessment | "\(.applicable_checks) \(.assessed_checks) \(.scored_checks // .assessed_checks) \(.blocked_checks) \(.suppressed_checks // 0) \(.not_in_scope_checks) \(.coverage_percent)"' "$F")
EOF
      echo
      echo "Assessment coverage: **${AS}/${AA} (${AC}%)** applicable checks assessed; **${AX} scored**; **${AB} blocked**; **${AU} suppressed**; **${AN} not in scope**."
    fi
    if [ -n "$TREND" ]; then
      CURFIRST="${TREND%% *}"; CURLAST="$(printf '%s' "$TREND" | awk '{print $NF}')"
      DELTA=$(( CURLAST - CURFIRST ))
      SIGN="+"; [ "$DELTA" -lt 0 ] && SIGN=""
      echo
      echo "Trend (last $(printf '%s' "$TREND" | wc -w | tr -d ' ') runs): $(printf '%s' "$TREND" | sed 's/ / → /g; s/ → $//')  \`$(viz_spark "$TREND")\`  (${SIGN}${DELTA})"
    fi
    echo
    echo "Checks passed: **${CP:-0}/${CT:-0}**"
    echo
    echo "| Severity | Count | |"
    echo "| --- | ---: | --- |"
    echo "| 🔴 critical | ${SC} | \`$(viz_bar "$SC" "$SEVMAX" 10)\` |"
    echo "| 🟠 high | ${SH} | \`$(viz_bar "$SH" "$SEVMAX" 10)\` |"
    echo "| 🟡 medium | ${SM} | \`$(viz_bar "$SM" "$SEVMAX" 10)\` |"
    echo "| 🔵 low | ${SL} | \`$(viz_bar "$SL" "$SEVMAX" 10)\` |"
    echo "| ⚪ info | ${SI} | \`$(viz_bar "$SI" "$SEVMAX" 10)\` |"
    if [ -n "$TOP" ]; then
      TID="$(printf '%s' "$TOP" | cut -f1)"; TP="$(printf '%s' "$TOP" | cut -f2)"; TSEV="$(printf '%s' "$TOP" | cut -f3)"; TT="$(printf '%s' "$TOP" | cut -f4)"
      echo
      echo "**Start here → ${TT} (${TID}): highest-severity actionable finding (${TSEV}, +${TP} points).**"
    fi
    ;;

  scorecard)
    F="${1:?findings.json}"; [ -f "$F" ] || { echo "no such file: $F" >&2; exit 1; }
    echo "| Category | Weight | Score | | Maturity | Passed / scored | Blocked | Suppressed |"
    echo "| --- | ---: | ---: | --- | --- | ---: | ---: | ---: |"
    jq -r '(.score.excluded // [] | map(.name)) as $excluded
      | .score.categories[]?
      | select(.name as $name | ($excluded | index($name)) == null)
      | "\(.name)\t\(.weight)\t\(.score)\t\(.maturity // "-")\t\(.checks_passed)\t\(.checks_total)\t\(.checks_blocked // 0)\t\(.checks_suppressed // 0)"' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt sc mat cp ct cb cs; do
        echo "| ${nm} | ${wt} | ${sc}/100 | \`$(viz_bar "$sc" 100 10)\` | ${mat} | ${cp}/${ct} | ${cb} | ${cs} |"
      done
    jq -r '.score.excluded[]? | "\(.name)\t\(.weight)\t\(.reason)"' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt rs; do
        echo "| ${nm} | ${wt} | excluded | \`░░░░░░░░░░\` | - | - | - | - |"
      done
    ;;

  lanes)
    F="${1:?findings.json}"; [ -f "$F" ] || { echo "no such file: $F" >&2; exit 1; }
    echo "## Findings by purpose"
    echo
    echo "Two standalone reads over the same audit: General audit (operational reliability) and AI SRE readiness (trustworthy AI-assisted diagnosis). Each lists its findings with what's wrong, why it matters, and the recommended action; a finding relevant to both appears in both. Full evidence for each finding lives in the Findings section below (and, for a non-scored finding, its own section) — it is not repeated here."
    for lane in general-audit ai-sre-readiness; do
      case "$lane" in
        general-audit) heading="General audit" ;;
        *) heading="AI SRE readiness" ;;
      esac
      echo
      echo "### ${heading}"
      echo
      count="$(jq --arg lane "$lane" '[.findings[]? | select((.lifecycle // "new") != "suppressed") | select((.report_lanes // []) | index($lane))] | length' "$F")"
      if [ "$count" -eq 0 ]; then
        echo "_No findings classified in this lane._"
        continue
      fi
      # Readable per-view analysis: severity + what's wrong, then why-it-matters and
      # the recommended action when the finding carries them. Ordered worst-first.
      # Detailed evidence (commands/observed) stays in the Findings section — not here.
      jq -r --arg lane "$lane" '
        def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.] // 5;
        [ .findings[]? | select((.lifecycle // "new") != "suppressed") | select((.report_lanes // []) | index($lane)) ]
        | sort_by(.severity | rank)
        | .[]
        | "- **[" + ((.severity // "info") | ascii_upcase) + "] " + (.title // "(untitled)") + "** (ref: `" + (.id // "?") + "`)\n"
          + (if (.impact // "") != "" then "  - Why it matters: " + .impact + "\n" else "" end)
          + (if (.recommendation // "") != "" then "  - Recommended action: " + .recommendation + "\n" else "" end)
      ' "$F"
    done
    ;;

  mermaid-topo)
    T="${1:?topology-export.json}"; TARGET="${2:?target}"
    [ -f "$T" ] || { echo "> _No topology-export.json — run \`/scoutflo:map-topology\` for a blast-radius graph._"; exit 0; }
    echo "\`\`\`mermaid"
    echo "flowchart LR"
    # Normalize both real shapes to from/rel/to; render only edges touching the target.
    jq -r --arg t "$TARGET" '
      (( .relationships // [] ) | map({from: .from.name, to: .to.name, rel: .relation}))
      + (( .edges // [] )       | map({from: .from,      to: .to,      rel: .type}))
      | .[] | select(.from == $t or .to == $t)
      | "  \(.from|gsub("[^a-zA-Z0-9_]";"_"))[\"\(.from)\"] -->|\(.rel)| \(.to|gsub("[^a-zA-Z0-9_]";"_"))[\"\(.to)\"]"' "$T" 2>/dev/null | sort -u
    echo "  classDef target fill:#e6f0ff,stroke:#2b6cb0,stroke-width:2px;"
    echo "  class $(printf '%s' "$TARGET" | sed 's/[^a-zA-Z0-9_]/_/g') target;"
    echo "\`\`\`"
    ;;

  html)
    F="${1:?findings.json}"; OUT="${2:?out.html}"; HIST="${3:-}"
    [ -f "$F" ] || { echo "no such file: $F" >&2; exit 1; }
    SKILL="$(jq -r '.skill // "audit"' "$F")"; TARGET="$(jq -r '.target // "target"' "$F")"
    RUNDATE="$(jq -r '.run_date // ""' "$F")"; OVERALL="$(jq -r 'if .score.overall == null then 0 else .score.overall end' "$F")"
    OVERALL_LABEL="$(jq -r 'if .score.overall == null then "unassessed" else (.score.overall|tostring) end' "$F")"
    # Human display name: strip the 'audit-' lane prefix and title-case the words
    # (so the tab/heading read "Grafana audit — <target>", not the raw "audit-grafana" slug).
    DISPLAY="$(printf '%s' "$SKILL" | sed 's/^audit-//' | awk -F- '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}}1' OFS=' ') audit"
    read -r SC SH SM SL SI <<EOF
$(jq -r '.severity_counts | "\(.critical//0) \(.high//0) \(.medium//0) \(.low//0) \(.info//0)"' "$F")
EOF
    # score color band. An unassessed run is neutral, not a red 0/100.
    if [ "$OVERALL_LABEL" = "unassessed" ]; then SCOLOR="#718096"
    elif [ "$OVERALL" -ge "$GATE" ]; then SCOLOR="#2f855a"
    elif [ "$OVERALL" -ge 50 ]; then SCOLOR="#b7791f"
    else SCOLOR="#c53030"
    fi
    # SVG donut math: circumference for r=54
    DASH="$(awk -v s="$OVERALL" 'BEGIN{c=2*3.14159265*54; printf "%.1f %.1f", c*s/100, c*(1-s/100)}')"
    TREND="$(trend_scores "$HIST" "$F")"
    SPARK_PTS="$(printf '%s' "$TREND" | awk '{n=split($0,a," ");for(i=1;i<=n;i++){x=(i-1)*(300/((n>1)?n-1:1)); y=60-(a[i]*0.5); printf "%s%.0f,%.0f", (i>1?" ":""), x, y}}')"

    {
    cat <<HTMLHEAD
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scoutflo AI Readiness — ${DISPLAY} — ${TARGET}</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f7f8fa;color:#1a202c}
@media(prefers-color-scheme:dark){body{background:#12151a;color:#e2e8f0}.card{background:#1a1f27!important;border-color:#2d3748!important}}
.wrap{max-width:960px;margin:0 auto;padding:24px}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:20px;margin:16px 0;box-shadow:0 1px 3px rgba(0,0,0,.04)}
h1{font-size:20px;margin:0 0 4px}.sub{color:#718096;font-size:13px}
.top{display:flex;gap:24px;align-items:center;flex-wrap:wrap}
.sev{display:flex;gap:16px;flex-wrap:wrap;margin-top:8px}
.chip{display:inline-flex;align-items:center;gap:6px;font-weight:600}
.dot{width:12px;height:12px;border-radius:50%;display:inline-block}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e2e8f0}
th{cursor:pointer;user-select:none;color:#4a5568}
.barwrap{background:#edf2f7;border-radius:4px;height:14px;width:120px;display:inline-block;vertical-align:middle;overflow:hidden}
.bar{height:100%;border-radius:4px}
.footer{color:#a0aec0;font-size:12px;text-align:center;margin:24px 0}
</style></head><body><div class="wrap">
<div class="card"><h1>${DISPLAY} — ${TARGET}</h1><div class="sub">Scoutflo AI Readiness · ${RUNDATE} (UTC)</div>
<div class="top" style="margin-top:16px">
<svg width="130" height="130" viewBox="0 0 130 130" role="img" aria-label="score ${OVERALL_LABEL}">
<circle cx="65" cy="65" r="54" fill="none" stroke="#e2e8f0" stroke-width="14"/>
<circle cx="65" cy="65" r="54" fill="none" stroke="${SCOLOR}" stroke-width="14" stroke-linecap="round"
 stroke-dasharray="${DASH}" transform="rotate(-90 65 65)"/>
<text x="65" y="60" text-anchor="middle" font-size="30" font-weight="700" fill="${SCOLOR}">${OVERALL_LABEL}</text>
<text x="65" y="82" text-anchor="middle" font-size="12" fill="#718096">readiness</text></svg>
<div><div class="sev">
<span class="chip"><span class="dot" style="background:#c53030"></span>${SC} critical</span>
<span class="chip"><span class="dot" style="background:#dd6b20"></span>${SH} high</span>
<span class="chip"><span class="dot" style="background:#d69e2e"></span>${SM} medium</span>
<span class="chip"><span class="dot" style="background:#3182ce"></span>${SL} low</span>
<span class="chip"><span class="dot" style="background:#a0aec0"></span>${SI} info</span>
</div>
HTMLHEAD
    SCOPE_NOTICE="$(scope_notice "$F")"
    if [ -n "$SCOPE_NOTICE" ]; then printf '<p><strong>%s</strong></p>\n' "$SCOPE_NOTICE"; fi
    if [ "$OVERALL_LABEL" != "unassessed" ] && jq -e '.schema == "scoutflo-findings/v2" or (.score | has("end_to_end"))' "$F" >/dev/null; then
      E2E="$(jq -r '.score.end_to_end // false' "$F")"
      printf '<p class="sub">%s</p>\n' "$(score_label "$OVERALL" "$E2E")"
    fi
    if jq -e '.score.assessment | type == "object"' "$F" >/dev/null 2>&1; then
      jq -r '.score.assessment | "<div class=\"sub\" style=\"margin-top:10px\">Assessment coverage: <strong>\(.assessed_checks)/\(.applicable_checks) (\(.coverage_percent)%)</strong>; \(.scored_checks // .assessed_checks) scored; \(.blocked_checks) blocked; \(.suppressed_checks // 0) suppressed; \(.not_in_scope_checks) not in scope.</div>"' "$F"
    fi
    if [ -n "$SPARK_PTS" ]; then
      echo "<svg width=\"320\" height=\"64\" style=\"margin-top:12px\" role=\"img\" aria-label=\"score trend\"><polyline fill=\"none\" stroke=\"${SCOLOR}\" stroke-width=\"2\" points=\"${SPARK_PTS}\"/></svg><div class=\"sub\">score trend (last ${TREND:+$(printf '%s' "$TREND" | wc -w | tr -d ' ')} runs)</div>"
    fi
    cat <<'HTMLMID'
</div></div></div>
<div class="card"><h1 style="font-size:16px">Scorecard</h1>
<table><thead><tr><th onclick="sortT(this,0)">Category</th><th onclick="sortT(this,1,1)">Weight</th><th onclick="sortT(this,2,1)">Score</th><th>Maturity</th><th>Passed / scored</th><th>Blocked</th><th>Suppressed</th></tr></thead><tbody>
HTMLMID
    jq -r '(.score.excluded // [] | map(.name)) as $excluded
      | .score.categories[]?
      | select(.name as $name | ($excluded | index($name)) == null)
      | [.name,(.weight|tostring),(.score|tostring),(.maturity // "-"),(.checks_passed|tostring),(.checks_total|tostring),((.checks_blocked//0)|tostring),((.checks_suppressed//0)|tostring)] | @tsv' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt sc mat cp ct cb cs; do
        if [ "$sc" -ge "$GATE" ]; then bc="#2f855a"; elif [ "$sc" -ge 50 ]; then bc="#b7791f"; else bc="#c53030"; fi
        enm="$(printf '%s' "$nm" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td>${enm}</td><td>${wt}</td><td>${sc}/100<div class=\"barwrap\"><div class=\"bar\" style=\"width:${sc}%;background:${bc}\"></div></div></td><td>${mat}</td><td>${cp}/${ct}</td><td>${cb}</td><td>${cs}</td></tr>"
      done
    jq -r '.score.excluded[]? | [.name,(.weight|tostring),(.reason // "excluded")] | @tsv' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt reason; do
        enm="$(printf '%s' "$nm" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        ers="$(printf '%s' "$reason" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td>${enm}</td><td>${wt}</td><td>excluded</td><td>-</td><td>-</td><td title=\"${ers}\">-</td><td>-</td></tr>"
      done
    cat <<'HTMLFIND'
</tbody></table></div>
<div class="card"><h1 style="font-size:16px">Findings</h1>
<table id="find"><thead><tr><th onclick="sortT(this,0)">Severity</th><th onclick="sortT(this,1)">Finding</th><th onclick="sortT(this,2,1)">Points</th><th>Ref</th></tr></thead><tbody>
HTMLFIND
    # Order matches report.md: severity (critical->info) then points_recoverable
    # descending. A sort key (severity rank, then -points) is emitted, sorted
    # numerically, then dropped. All severities including info are shown, so the
    # table matches report.md and the info chip's count.
    jq -r '.findings[]?
      | select((.lifecycle // "new") != "suppressed")
      | ({critical:0,high:1,medium:2,low:3,info:4}[.severity] // 5) as $r
      | [($r|tostring), (((.points_recoverable//0) * -1)|tostring), .severity, ((.points_recoverable//0)|tostring), .title, .id] | @tsv' "$F" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n \
    | while IFS="$(printf '\t')" read -r rank negpts sev pts title id; do
        case "$sev" in critical) sd="#c53030";; high) sd="#dd6b20";; medium) sd="#d69e2e";; low) sd="#3182ce";; *) sd="#a0aec0";; esac
        # escape HTML-special chars in the model-authored title
        et="$(printf '%s' "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td><span class=\"dot\" style=\"background:${sd}\"></span> ${sev}</td><td>${et}</td><td>${pts}</td><td><code>${id}</code></td></tr>"
      done
    SUPPRESSED="$(jq '[.findings[]? | select(.lifecycle == "suppressed")] | length' "$F")"
    if [ "$SUPPRESSED" -gt 0 ]; then
      cat <<'HTMLSUPPRESSED'
</tbody></table></div>
<div class="card"><h1 style="font-size:16px">Suppressed findings</h1>
<p class="sub">Active approved exemptions. These findings are excluded from readiness scoring and the active severity totals.</p>
<table><thead><tr><th>Severity</th><th>Finding</th><th>Ref</th></tr></thead><tbody>
HTMLSUPPRESSED
      jq -r '.findings[]? | select(.lifecycle == "suppressed") | [.severity,.title,.id] | @tsv' "$F" \
      | while IFS="$(printf '\t')" read -r sev title id; do
          et="$(printf '%s' "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
          echo "<tr><td>${sev}</td><td>${et}</td><td><code>${id}</code></td></tr>"
        done
    fi
    cat <<HTMLFOOT
</tbody></table></div>
<div class="footer">Generated by Scoutflo AI Readiness for Claude Code · report.html mirrors findings.json · contains infrastructure detail — keep within your team</div>
<script>
function sortT(th,col,num){var t=th.closest('table'),tb=t.tBodies[0],rows=[].slice.call(tb.rows);
var d=th.__d=!th.__d;rows.sort(function(a,b){var x=a.cells[col].innerText,y=b.cells[col].innerText;
if(num){x=parseFloat(x)||0;y=parseFloat(y)||0;return d?x-y:y-x;}return d?x.localeCompare(y):y.localeCompare(x);});
rows.forEach(function(r){tb.appendChild(r);});}
</script>
</div></body></html>
HTMLFOOT
    } > "$OUT"
    echo "wrote $OUT"
    ;;

  overlaps)
    # Render the cross-stack correlation the engine already computed (overlaps =
    # the same service flagged by 2+ stacks; cascades = root_cause -> effects).
    # This data is written to correlation.json every audit-all run and shown to a
    # human nowhere; this only renders it (never re-derives or re-scores it).
    C="${1:?correlation.json}"
    [ -d "$C" ] && C="$C/correlation.json"   # accept a file OR the audits dir (rollup form)
    echo "## Cross-stack correlation"
    echo
    if [ ! -f "$C" ]; then
      echo "_No \`correlation.json\` — cross-stack correlation runs in \`/scoutflo:audit-all\` (needs two or more audits)._"
      exit 0
    fi
    NOVL="$(jq '(.overlaps // []) | length' "$C" 2>/dev/null || echo 0)"
    NCAS="$(jq '(.cascades // []) | length' "$C" 2>/dev/null || echo 0)"
    NCOV="$(jq '(.coverage // []) | length' "$C" 2>/dev/null || echo 0)"
    if [ "${NOVL:-0}" -eq 0 ] && [ "${NCAS:-0}" -eq 0 ] && [ "${NCOV:-0}" -eq 0 ]; then
      echo "No cross-stack overlaps, cascades, or cross-tool coverage reframing detected this run — each finding is scoped to a single stack."
      exit 0
    fi
    if [ "${NOVL:-0}" -gt 0 ]; then
      echo "**Redundant monitoring — one service flagged by multiple stacks. Review whether the coverage overlaps and consolidate the paging path:**"
      echo
      echo "| Service | Stacks | Findings | Consolidation review |"
      echo "| --- | --- | ---: | --- |"
      jq -r 'def esc: tostring | gsub("\\|"; "\\|");   # escape pipes so a value never breaks the table
        .overlaps[]? | [ ((.service // "") | esc), (((.targets // []) | join(", ")) | esc), ((.findings // []) | length | tostring), ((.recommendation // "-") | esc) ] | @tsv' "$C" \
      | while IFS="$(printf '\t')" read -r svc stacks nf rec; do
          echo "| \`${svc}\` | ${stacks} | ${nf} | ${rec} |"
        done
      echo
      # Per-overlap finding detail, so the reader sees exactly what each stack flagged.
      jq -r '.overlaps[]? | "- **\(.service)** — flagged by \((.targets // []) | length) stacks:\n" + ((.findings // []) | map("  - \(.target): \(.finding_id) [\(.severity)] \(.title)") | join("\n"))' "$C"
      echo
    fi
    if [ "${NCAS:-0}" -gt 0 ]; then
      echo "**Cascade chains — a root cause with the downstream failures it explains:**"
      echo
      jq -r '.cascades[]? | "- ROOT \(.root_cause.finding_id) \(.root_cause.title)\n  → effects: " + ((.effects // []) | map("\(.finding_id) \(.title)") | join(" | "))' "$C"
    else
      echo "_No cross-stack cascade chains detected this run._"
    fi
    if [ "${NCOV:-0}" -gt 0 ]; then
      echo
      echo "### Cross-tool coverage"
      echo
      NCE="$(jq '[.coverage[]? | select(.classification=="covered-elsewhere")] | length' "$C" 2>/dev/null || echo 0)"
      NTG="$(jq '[.coverage[]? | select(.classification=="true-gap")] | length' "$C" 2>/dev/null || echo 0)"
      NUM="$(jq '[.coverage[]? | select(.classification=="unmappable")] | length' "$C" 2>/dev/null || echo 0)"
      if [ "${NCE:-0}" -gt 0 ]; then
        echo "**Covered by another tool (single-tool dependency, NOT zero coverage — confirm the covering monitor watches the signal the gap names):**"
        echo
        echo "| Resource | Gap flagged by | Actively covered by | Note |"
        echo "| --- | --- | --- | --- |"
        jq -r 'def esc: tostring | gsub("\\|"; "\\|");
          .coverage[]? | select(.classification=="covered-elsewhere")
          | [ ((.resource // "") | esc), ((.target // "") | esc),
              (([.covered_by[]? | "\(.provider):\(.inventory_name) → \(.routes_to)"] | join("; ")) | esc),
              ("single-tool dependency" | esc) ] | @tsv' "$C" \
        | while IFS="$(printf '\t')" read -r res tgt cov note; do
            echo "| \`${res}\` | \`${tgt}\` | ${cov} | ${note} |"
          done
        echo
      fi
      if [ "${NTG:-0}" -gt 0 ]; then
        echo "**True gaps — no active cross-tool coverage anywhere; these are real and should be elevated:**"
        echo
        jq -r '.coverage[]? | select(.classification=="true-gap") | "- \(.resource) (flagged by \(.target), \(.finding_id))"' "$C"
        echo
      fi
      if [ "${NUM:-0}" -gt 0 ]; then
        echo "**Possible coverage, unconfirmed — a name-only/fuzzy match; run \`/scoutflo:map-topology\` to join by canonical service name:**"
        echo
        jq -r '.coverage[]? | select(.classification=="unmappable") | "- \(.resource) (flagged by \(.target)) — maybe covered by \([.covered_by[]?.provider] | join(", "))"' "$C"
        echo
      fi
    fi
    ;;

  rollup)
    # Combined "At a glance" for audit-all: gate-count meter + worst-first per-stack
    # score bars, read from every target's findings.json for the run date. Never a
    # mean (an average hides a failing stack behind a healthy one).
    D="${1:?audits-dir}"; RD="${2:?run-date}"
    echo "## At a glance (all stacks)"
    echo
    # Glob BOTH the one-level `<target>/<date>/` and two-level
    # `<integration>/<label>/<date>/` layouts (multi-target labels, and single-block
    # signoz/kubernetes which always nest), mirroring audit-all's Phase-3 loops.
    # A stack is "end-to-end" only when it clears the score gate, was fully
    # assessed (v2 coverage 100%), and its own explicit readiness flag permits it.
    # A missing v1 flag keeps legacy behavior; missing v2 proof fails closed.
    # A high score over a mostly-blocked estate is NOT
    # end-to-end and must not be counted or rendered as if it were (else partial
    # collection reads as a clean bill of health at the leader-facing headline).
    # cov is the v2 assessment coverage percent, or "na" for a v1 stack that has none.
    ROWS=""; total=0; passing=0
    for f in "$D"/*/"$RD"/findings.json "$D"/*/*/"$RD"/findings.json; do
      [ -f "$f" ] || continue
      tgt="$(jq -r '.target // "?"' "$f" 2>/dev/null)"
      case "$tgt" in all|cost|cost-analysis|doctor|"?") continue;; esac
      sc="$(jq -r 'if .score.overall == null then "unassessed" else .score.overall end' "$f" 2>/dev/null)"
      cov="$(jq -r '.score.assessment.coverage_percent // "na"' "$f" 2>/dev/null)"
      e2e="$(jq -r 'if (.score | has("end_to_end")) then .score.end_to_end elif .schema=="scoutflo-findings/v2" then false else "legacy" end' "$f" 2>/dev/null)"
      total=$((total + 1))
      if [ "$sc" = "unassessed" ]; then
        sort_key=-1
      else
        case "$sc" in *[!0-9]*) sc="unassessed"; sort_key=-1;;
          *) sort_key="$sc"
             # full coverage: v1 (na) or unparseable is not penalized; v2 must be 100
             full=1; case "$cov" in ''|na|*[!0-9]*) full=1;; *) [ "$cov" -eq 100 ] || full=0;; esac
             if [ "$sc" -ge "$GATE" ] && [ "$full" -eq 1 ]; then
               case "$e2e" in true|legacy) passing=$((passing + 1));; esac
             fi;;
        esac
      fi
      ROWS="${ROWS}${sort_key}	${sc}	${cov}	${e2e}	${tgt}
"
    done
    if [ "$total" -eq 0 ]; then echo "_No completed audits for ${RD}._"; exit 0; fi
    echo "**Stacks end-to-end (>= ${GATE} gate and fully assessed): ${passing}/${total}**  \`$(viz_bar "$passing" "$total" 12)\`"
    echo
    echo "| Stack | Score | | |"
    echo "| --- | ---: | --- | --- |"
    printf '%s' "$ROWS" | sort -t"$(printf '\t')" -k1,1n | while IFS="$(printf '\t')" read -r sort_key sc cov e2e tgt; do
      [ -n "$tgt" ] || continue
      if [ "$sc" = "unassessed" ]; then
        echo "| \`${tgt}\` | unassessed | \`░░░░░░░░░░░░\` | ← no readiness score |"
      else
        full=1; case "$cov" in ''|na|*[!0-9]*) full=1;; *) [ "$cov" -eq 100 ] || full=0;; esac
        if [ "$sc" -lt "$GATE" ]; then flag="← below gate"
        elif [ "$full" -eq 0 ]; then flag="← only ${cov}% assessed — not end-to-end"
        elif [ "$e2e" != true ] && [ "$e2e" != legacy ]; then flag="← end-to-end not established"
        else flag=""
        fi
        echo "| \`${tgt}\` | ${sc}/100 | \`$(viz_bar "$sc" 100 12)\` | ${flag} |"
      fi
    done
    for f in "$D"/*/"$RD"/findings.json "$D"/*/*/"$RD"/findings.json; do
      [ -f "$f" ] || continue
      tgt="$(jq -r '.target // "?"' "$f")"
      case "$tgt" in all|cost|cost-analysis|doctor|"?") continue;; esac
      SCOPE_NOTICE="$(scope_notice "$f")"
      if [ -n "$SCOPE_NOTICE" ]; then
        safe_target="$(jq -r '.target | @html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")' "$f")"
        printf '\n- %s: %s\n' "$safe_target" "$SCOPE_NOTICE"
      fi
    done
    echo
    echo "_Worst-first — send the team to the top row. Partial assessment or an explicit false readiness flag prevents end-to-end credit even at a high score. Missing v1 flags retain legacy behavior. Never a combined average: one score line per stack._"
    ;;

  inventory)
    # Complete current-state catalog from inventory.json (scoutflo-inventory/v1):
    # "what exists," parallel to Findings ("the gaps"). One table per kind. Renders
    # only structured fields (name/covers/severity/routes_to/enabled) — never a
    # secret value; the inventory.json is already redacted at capture.
    INV="${1:?inventory.json}"
    echo "## Inventory"
    echo
    if [ ! -f "$INV" ]; then
      echo "_No \`inventory.json\` for this run._"
      exit 0
    fi
    TGT="$(jq -r '.target // "target"' "$INV" 2>/dev/null)"
    TOT="$(jq -r '.counts.total // (.items | length) // 0' "$INV" 2>/dev/null)"
    case "$TOT" in *[!0-9]*) TOT=0;; esac
    SCOPE_NOTICE="$(inventory_scope_notice "$INV" "${2:-}")"
    if [ -n "$SCOPE_NOTICE" ]; then printf '> **%s**\n\n' "$SCOPE_NOTICE"; fi
    if [ "$TOT" -eq 0 ]; then
      echo "No objects recorded in \`${TGT}\` for this run. Check the report's scope and visibility limits before concluding the estate is empty."
      exit 0
    fi
    echo "Observed inventory for \`${TGT}\` (${TOT} objects). Counts describe the supplied inventory; see the report for scope and collection limits. Findings describe the gaps."
    echo
    jq -r '[.items[].kind] | unique[]' "$INV" 2>/dev/null | while IFS= read -r kind; do
      [ -n "$kind" ] || continue
      n="$(jq --arg k "$kind" '[.items[] | select(.kind == $k)] | length' "$INV" 2>/dev/null)"
      label="$(printf '%s' "$kind" | tr '_' ' ')"
      echo "**${label} (${n})**"
      echo
      echo "| name | covers | severity | routes to | enabled |"
      echo "| --- | --- | --- | --- | --- |"
      jq -r --arg k "$kind" 'def esc: tostring | gsub("\\|"; "\\|");   # escape pipes so a value never breaks the table
        .items[] | select(.kind == $k) | [ ((.name // "") | esc), ((.covers // "-") | esc), ((.severity // "-") | esc), ((.routes_to // "-") | esc), (if .enabled == true then "yes" elif .enabled == false then "no" else "unknown" end) ] | @tsv' "$INV" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r nm cov sev rt en; do
          echo "| \`${nm}\` | ${cov} | ${sev} | ${rt} | ${en} |"
        done
      echo
    done
    # --- Per-environment view: the "PP vs Prod at a glance" grid, reusable for any target. ---
    # Env per item: an explicit env field wins; else derived from the name, else the covered
    # service. The matcher tests pre-prod/pp BEFORE prod ("preprod" contains the substring "prod").
    # Emits nothing when no environment is derivable, so it never forces a section on flat estates.
    ENVSECT="$(jq -r '
      def envof($n): (($n // "")|ascii_downcase) as $l
        | if   ($l|test("pre-?_?prod|(^|[-_])pp([-_]|$)")) then "pre-prod"
          elif ($l|test("stag|(^|[-_])stg([-_]|$)"))       then "staging"
          elif ($l|test("test|(^|[-_])qa([-_]|$)"))        then "testing"
          elif ($l|test("(^|[-_])dev([-_]|$)"))            then "dev"
          elif ($l|test("prod|(^|[-_])prd([-_]|$)"))       then "prod"
          else "unspecified" end;
      def baseof($n): (($n // "")|ascii_downcase)
        | gsub("[-_](pre-?_?prod|preprod|prod|prd|pp|staging|stg|testing|test|qa|dev)([-_].*)?$";"");
      def norm($x): ($x|ascii_downcase|gsub("[-_ ]";"")) as $c
        | if   ($c=="pp" or $c=="preprod")                 then "pre-prod"
          elif ($c=="prod" or $c=="prd" or $c=="production") then "prod"
          elif ($c|startswith("stag"))                     then "staging"
          elif ($c=="qa" or ($c|startswith("test")))       then "testing"
          elif ($c=="dev" or ($c|startswith("develop")))   then "dev"
          else $c end;
      def e2($it): (($it.env // $it.attrs.env // $it.attrs.environment) // null) as $x
        | (if $x != null then norm($x)
           else (envof($it.name) as $en | if $en!="unspecified" then $en else envof($it.covers) end) end);
      ([.items[] | . + {e: e2(.), b: baseof(.name)}]) as $it
      | if (($it | map(select(.e!="unspecified")) | length) == 0) then empty else
          "### By environment", "",
          "Objects grouped by environment; a marker in the name or an `env` field decides it, unmarked objects are `unspecified`.", "",
          "| environment | objects | kinds |", "| --- | --- | --- |",
          ($it | group_by(.e)[] | "| " + .[0].e + " | " + (length|tostring) + " | " + ([.[].kind]|unique|join(", ")) + " |"),
          "", "**Environment twins** — same base name in more than one environment (the core stack should mirror; a base in only one environment is flagged to confirm):", "",
          ($it | group_by(.b)[] | ([.[].e]|unique) as $es
             | if   ($es|length) > 1        then "- `" + .[0].b + "`: " + ($es|join(" + "))
               elif ($es[0] != "unspecified") then "- `" + .[0].b + "`: " + $es[0] + " only — no twin (intended, or a missing environment?)"
               else empty end),
          "" end' "$INV" 2>/dev/null)"
    if [ -n "$ENVSECT" ]; then printf '%s\n' "$ENVSECT"; fi   # if (not &&): a false test must not trip set -e and blank the whole section
    ;;

  topology-inventory)
    # The topology's own inventory, grouped by environment: the complete
    # server/datastore catalog from topology-export.json (already saved + reused
    # by map-topology), rendered as the "PP vs Prod at a glance" paired grid.
    # A server is listed whether or not an edge was found for it.
    T="${1:?topology-export.json}"
    echo "## Inventory (by environment)"
    echo
    if [ ! -f "$T" ]; then echo "_No \`topology-export.json\` — run \`/scoutflo:map-topology\`._"; exit 0; fi
    jq empty "$T" 2>/dev/null || { echo "_\`topology-export.json\` is not valid JSON — re-run \`/scoutflo:map-topology\`._"; exit 0; }
    jq -r '
      def envof($n): (($n // "")|ascii_downcase) as $l
        | if   ($l|test("pre-?_?prod|(^|[-_])pp([-_]|$)")) then "pre-prod"
          elif ($l|test("stag|(^|[-_])stg([-_]|$)"))       then "staging"
          elif ($l|test("test|(^|[-_])qa([-_]|$)"))        then "testing"
          elif ($l|test("(^|[-_])dev([-_]|$)"))            then "dev"
          elif ($l|test("prod|(^|[-_])prd([-_]|$)"))       then "prod"
          else "unspecified" end;
      def baseof($n): (($n // "")|ascii_downcase)
        | gsub("[-_](pre-?_?prod|preprod|prod|prd|pp|staging|stg|testing|test|qa|dev)([-_].*)?$";"");
      def norm($x): ($x|ascii_downcase|gsub("[-_ ]";"")) as $c
        | if   ($c=="pp" or $c=="preprod")                 then "pre-prod"
          elif ($c=="prod" or $c=="prd" or $c=="production") then "prod"
          elif ($c|startswith("stag"))                     then "staging"
          elif ($c=="qa" or ($c|startswith("test")))       then "testing"
          elif ($c=="dev" or ($c|startswith("develop")))   then "dev"
          else $c end;
      def e2($it): (($it.attributes.env // $it.attributes.environment // $it.environment) // null) as $x
        | (if $x != null then norm($x) else envof($it.name) end);
      ( [ .services[]?  | {name, k:"service",   e: e2(.), b: baseof(.name)} ]
      + [ .resources[]? | {name, k:"datastore", e: e2(.), b: baseof(.name)} ] ) as $it
      | "Complete server + datastore inventory grouped by environment (from the topology map). A row is listed whether or not a connection was found for it.", "",
        "| environment | services | datastores | total |", "| --- | --- | --- | --- |",
        ($it | group_by(.e)[]
           | "| " + .[0].e + " | " + ([.[]|select(.k=="service")]|length|tostring)
             + " | " + ([.[]|select(.k=="datastore")]|length|tostring) + " | " + (length|tostring) + " |"),
        "", "**Environment twins** — same base name in more than one environment (a base in only one is flagged: intended, or a missing environment?):", "",
        ($it | group_by(.b)[] | ([.[].e]|unique) as $es
           | if   ($es|length) > 1        then "- `" + .[0].b + "`: " + ($es|join(" + "))
             elif ($es[0] != "unspecified") then "- `" + .[0].b + "`: " + $es[0] + " only — no twin"
             else empty end)
    ' "$T" 2>/dev/null
    echo
    ;;

  mermaid-mesh)
    # Full service→datastore mesh (not target-scoped like mermaid-topo): a service
    # map with DIRECTIONAL arrows LABELLED by connection type + evidence class,
    # datastore cylinders carrying config detail (engine·port), and nodes coloured
    # by environment. Renders only resource-dependency edges (never CALLS/traffic).
    T="${1:?topology-export.json}"
    [ -f "$T" ] || { echo "> _No topology-export.json — run \`/scoutflo:map-topology\` for a service map._"; exit 0; }
    jq empty "$T" 2>/dev/null || { echo "> _topology-export.json is not valid JSON — re-run \`/scoutflo:map-topology\`._"; exit 0; }
    echo '```mermaid'
    echo 'flowchart LR'
    jq -r '
      def id($n): ($n|gsub("[^a-zA-Z0-9_]";"_"));
      (.resources // []) as $res | ($res | map(.name)) as $rn
      # service nodes (only those with a resource edge, keeps the map focused)
      | ((.relationships // []) | map(select(.to.name as $t | $rn|index($t))) ) as $edges
      | ( [ $edges[].from.name ] | unique | .[] | "  " + id(.) + "[\"" + . + "\"]" ),
        # datastore nodes as cylinders, with engine·port config when present
        ( $res[] | (.attributes // {}) as $a
          | (($a.engine // $a.kind // "" | tostring)) as $eng
          | (($a.endpoint_port // $a.port // "") | tostring) as $port
          | (if ($eng != "" or $port != "") then "<br/>" + ($eng) + (if $port != "" then " · " + $port else "" end) else "" end) as $cfg
          | "  " + id(.name) + "[(\"" + .name + $cfg + "\")]" ),
        # edges: direction native, label = relation · evidence
        ( $edges[] | .from.name as $f | .to.name as $t | (.relation // "USES") as $r
          | (.attributes.evidence_class // "") as $ev
          | "  " + id($f) + " -->|" + $r + (if $ev != "" then " · " + $ev else "" end) + "| " + id($t) )
    ' "$T" 2>/dev/null | awk '!seen[$0]++'   # stable de-dup, keep first-seen order
    # environment node classes
    jq -r '
      def id($n): ($n|gsub("[^a-zA-Z0-9_]";"_"));
      def envcls($n): (($n//"")|ascii_downcase) as $l
        | if ($l|test("pre-?_?prod|(^|[-_])pp([-_]|$)|test|stag|(^|[-_])dev([-_]|$)")) then "ppenv"
          elif ($l|test("prod|prd")) then "prodenv" else "unkenv" end;
      ( [ (.services//[])[].name ] + [ (.resources//[])[].name ] ) | unique | .[] | "  class " + id(.) + " " + envcls(.) + ";"
    ' "$T" 2>/dev/null
    echo '  classDef prodenv fill:#e6f0ff,stroke:#2b6cb0,color:#0b2e6b;'
    echo '  classDef ppenv fill:#fff7e6,stroke:#b7791f,color:#5c3400;'
    echo '  classDef unkenv fill:#f0f0f0,stroke:#888,color:#333;'
    echo '```'
    ;;

  inventory-rollup)
    # audit-all estate inventory: per-stack object counts by kind, from every
    # target's inventory.json for the run date.
    D="${1:?audits-dir}"; RD="${2:?run-date}"
    echo "## Estate inventory (all stacks)"
    echo
    found=0
    for f in "$D"/*/"$RD"/inventory.json "$D"/*/*/"$RD"/inventory.json; do [ -f "$f" ] && found=1; done
    if [ "$found" -eq 0 ]; then echo "_No \`inventory.json\` for ${RD}._"; exit 0; fi
    echo "Observed objects by type in the supplied inventories. Counts do not establish complete estate coverage; each report retains its scope and collection limits."
    echo
    echo "| Stack | Total | By kind |"
    echo "| --- | ---: | --- |"
    # Two-level glob included so multi-target labels and single-block signoz/kubernetes appear.
    for f in "$D"/*/"$RD"/inventory.json "$D"/*/*/"$RD"/inventory.json; do
      [ -f "$f" ] || continue
      tgt="$(jq -r '.target // "?"' "$f" 2>/dev/null)"
      case "$tgt" in all|cost|cost-analysis|doctor|"?") continue;; esac
      tot="$(jq -r '.counts.total // (.items|length) // 0' "$f" 2>/dev/null)"
      bk="$(jq -r '(.counts.by_kind // {}) | to_entries | map("\(.key): \(.value)") | join(", ")' "$f" 2>/dev/null)"
      echo "| \`${tgt}\` | ${tot} | ${bk:--} |"
    done
    for f in "$D"/*/"$RD"/inventory.json "$D"/*/*/"$RD"/inventory.json; do
      [ -f "$f" ] || continue
      tgt="$(jq -r '.target // "?"' "$f")"
      case "$tgt" in all|cost|cost-analysis|doctor|"?") continue;; esac
      SCOPE_NOTICE="$(inventory_scope_notice "$f")"
      if [ -n "$SCOPE_NOTICE" ]; then
        safe_target="$(jq -r '.target | @html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")' "$f")"
        printf '\n- %s: %s\n' "$safe_target" "$SCOPE_NOTICE"
      fi
    done
    ;;

  alert-fatigue)
    # Render alert-fatigue.json (the non-scored roll-up) as a human report: an
    # at-a-glance line, the honest three-tier framing, a worst-first "top
    # offenders" list where EACH noise finding shows problem -> exact fix (joined
    # from the canonical findings.json), where noise concentrates by tool, the
    # cross-source storms, the alert-to-incident ratio (computed or honestly
    # not-in-scope), and the cited benchmarks. Renders only structured fields
    # (never a secret/raw command output). Read-only.
    AFJ="${1:?alert-fatigue.json}"; D="${2:?audits-dir}"; RD="${3:?run-date}"
    echo "## Alert noise & fatigue"
    echo
    if [ ! -f "$AFJ" ]; then
      echo "_No \`alert-fatigue.json\` — run \`/scoutflo:audit-all\` (Phase 3.6) or the standalone alert-fatigue skill against a configured alerting provider._"
      exit 0
    fi
    read -r TN TS TT <<EOF
$(jq -r '.totals | "\(.alerting_noise_findings // 0) \(.cross_source_storms // 0) \(.tools_with_noise // 0)"' "$AFJ")
EOF
    RSTATUS="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | .status // "not-in-scope"' "$AFJ")"
    FHO="$(jq -r '.totals.fire_history_objects // 0' "$AFJ")"
    IH_ROWS="$(af_incident_history_rows "$AFJ")"
    IH_COUNT="$(printf '%s' "$IH_ROWS" | jq 'length')"
    if [ "$(jq -r ' .input_validation.status // ""' "$AFJ")" = "blocked" ]; then
      jq -r '"**Measured input blocked:** " + .input_validation.reason' "$AFJ"
      echo
    fi
    # A native incident lane must render even with no config or fire-history rows.
    if [ "${TN:-0}" -eq 0 ] && [ "${FHO:-0}" -eq 0 ] && [ "$IH_COUNT" -eq 0 ]; then
      echo "No alerting-noise findings and no measured fire-history were supplied for ${RD}. This is not an all-clear: inspect each audit coverage ledger; notification volume, delivery and incident ratios remain unmeasured."
      exit 0
    fi
    if [ "$RSTATUS" = "computed" ]; then
      RATIO_LINE="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | "ratio: \(.alerts_per_incident):1 (\(.alerts_fired) alerts / \(.incidents) incident(s) over \(.window))"' "$AFJ")"
    else
      RATIO_LINE="ratio: needs incident feed (not fabricated)"
    fi
    echo "**At a glance — ${TN} alerting-noise finding(s) across ${TT} tool(s) · ${TS} potential cross-source overlap(s) · ${RATIO_LINE}.**"
    echo
    echo "Read each evidence lane in its own units: **config** findings, **fire-history** observations, and **native incident history** with its stated start window and response sample counts. AF-005 can carry incident history even when fire-history is not collected. An alert-to-incident ratio needs a separate comparable alert/incident feed; incident history alone does not establish actionability or human receipt."
    echo
    NOISE="$(af_enriched_noise "$AFJ" "$D" "$RD")"
    read -r SC SH SM SL SI <<EOF
$(printf '%s' "$NOISE" | jq -r 'reduce .[] as $f ({critical:0,high:0,medium:0,low:0,info:0}; .[$f.severity] += 1) | "\(.critical) \(.high) \(.medium) \(.low) \(.info)"')
EOF
    SEVMAX="$(printf '%s\n' "$SC" "$SH" "$SM" "$SL" "$SI" | sort -rn | head -1)"; [ "${SEVMAX:-0}" -gt 0 ] || SEVMAX=1
    if [ "${TN:-0}" -gt 0 ]; then
    echo "| Severity | Noise findings | |"
    echo "| --- | ---: | --- |"
    echo "| 🔴 critical | ${SC} | \`$(viz_bar "$SC" "$SEVMAX" 10)\` |"
    echo "| 🟠 high | ${SH} | \`$(viz_bar "$SH" "$SEVMAX" 10)\` |"
    echo "| 🟡 medium | ${SM} | \`$(viz_bar "$SM" "$SEVMAX" 10)\` |"
    echo "| 🔵 low | ${SL} | \`$(viz_bar "$SL" "$SEVMAX" 10)\` |"
    echo "| ⚪ info | ${SI} | \`$(viz_bar "$SI" "$SEVMAX" 10)\` |"
    echo
    echo "### Start here — noisiest alerting, worst first (problem -> fix)"
    echo
    printf '%s' "$NOISE" | jq -r '
      def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.] // 5;
      sort_by([(.severity|rank), .target, .id])
      | .[]
      | "- **[" + ((.severity // "info") | ascii_upcase) + "] " + .title + "**  (`" + .id + "` · " + .target + ")\n"
        + (if ((.affected | length) > 0) then "  - Where: " + (.affected | join(", ")) + "\n" else "" end)
        + (if (.impact != "") then "  - Why it matters: " + .impact + "\n" else "" end)
        + (if (.recommendation != "") then "  - Fix: " + .recommendation + (if (.remediation != "") then "  -> `" + .remediation + "`" else "" end) + "\n"
           elif (.remediation != "") then "  - Fix: `" + .remediation + "`\n" else "" end)'
    echo
    else
      echo "_Config tier: 0 alerting-noise findings were supplied. Check assessment coverage and the available measured lanes below; this is not proof of a quiet or healthy estate._"
      echo
    fi
    echo "### Where the noise concentrates (by tool)"
    echo
    echo "| Tool | Noise findings | By severity |"
    echo "| --- | ---: | --- |"
    jq -r 'def tdisp: if type=="object" then (.host // .name // .type // tojson) else tostring end;
      .af_findings[]? | select(.af_id=="AF-001") | .by_source[]?
      | [ (.target|tdisp), (.noise_findings | tostring),
          (((.by_severity // {}) | to_entries | map("\(.value) \(.key)") | join(", "))) ] | @tsv' "$AFJ" \
    | while IFS="$(printf '\t')" read -r t n bs; do
        echo "| \`${t}\` | ${n} | ${bs:--} |"
      done
    echo
    # --- Measured fire-history tier (AF-004/005/006) — shown only when collected ---
    REACH_STATUS="$(jq -r '.af_findings[]? | select(.af_id=="AF-004") | .status // "not-in-scope"' "$AFJ")"
    VOL_STATUS="$(jq -r '.af_findings[]? | select(.af_id=="AF-005") | .status // "not-in-scope"' "$AFJ")"
    CHRON_STATUS="$(jq -r '.af_findings[]? | select(.af_id=="AF-006") | .status // "not-in-scope"' "$AFJ")"
    if [ "$REACH_STATUS" = "measured" ] || [ "$VOL_STATUS" = "measured" ] || [ "$CHRON_STATUS" = "measured" ]; then
      echo "### Measured fire-history (this run)"
      echo
      # per-provider fire-history coverage (collected / verify-pending / spec-only) — honesty
      if jq -e '(.fire_history_coverage // []) | length > 0' "$AFJ" >/dev/null 2>&1; then
        echo "| Provider | Fire-history | Verification | Note |"
        echo "| --- | --- | --- | --- |"
        jq -r 'def esc: tostring | gsub("\\|"; "\\|"); .fire_history_coverage[]? | [ (.provider|esc), ((.status // "-")|esc), ((.verification // "-")|esc), ((.reason // "-")|esc) ] | @tsv' "$AFJ" \
        | while IFS="$(printf '\t')" read -r pv st vf rs; do echo "| ${pv} | ${st} | ${vf} | ${rs} |"; done
        echo
        if jq -e '[.fire_history_coverage[]? | select(.verification=="spec-only")] | length > 0' "$AFJ" >/dev/null 2>&1; then
          echo "_Providers marked \`spec-only\` were read from a doc-verified but not-yet-live-confirmed lane — the numbers are real reads; a first live run confirms the field parsing (see references/fire-history-reads.md § Live-verification)._"
          echo
        fi
      fi
      if [ "$REACH_STATUS" = "measured" ]; then
        jq -r '.af_findings[]? | select(.af_id=="AF-004")
          | "**Reachability — \(.unreachable_objects) of \(.measured_objects) alerting objects cannot reach a human by construction.** These fire into the void (a page that pages nobody):"' "$AFJ"
        echo
        # honest coverage: if routing was resolved for only a subset of objects seen, say so
        jq -r '.af_findings[]? | select(.af_id=="AF-004") | select(.routing_coverage_note != null) | "_(" + .routing_coverage_note + ".)_"' "$AFJ"
        echo
        echo "| Can't reach a human because | Objects |"
        echo "| --- | ---: |"
        jq -r 'def esc: tostring | gsub("\\|"; "\\|"); .af_findings[]? | select(.af_id=="AF-004") | .by_reason[]? | [ (.reason|esc), (.count|tostring) ] | @tsv' "$AFJ" \
        | while IFS="$(printf '\t')" read -r rsn cnt; do echo "| ${rsn} | ${cnt} |"; done
        echo
      fi
      if [ "$VOL_STATUS" = "measured" ]; then
        jq -r '.af_findings[]? | select(.af_id=="AF-005")
          | "**Top offenders — ranked by measured fatigue impact** (\(.total_fires) total fires across \(.objects_with_history) object(s); \(.flapping_objects) flapping). Fatigue impact weights raw fires by flapping, off-hours share, and dead-end routing:"' "$AFJ"
        echo
        echo "| Object | Tool | Fires | Flapping | Off-hours | Reaches human | Fatigue impact |"
        echo "| --- | --- | ---: | --- | ---: | --- | ---: |"
        jq -r 'def esc: tostring | gsub("\\|"; "\\|");
          .af_findings[]? | select(.af_id=="AF-005") | .top_offenders[]?
          | [ (.object_id|esc), (.provider|esc), (.fires|tostring),
              (if .flapping==true then "yes" else "no" end),
              ((.off_hours_fires // "—")|tostring),
              (if .reaches_human==false then "**NO**" elif .reaches_human==true then "yes" else "?" end),
              (.fatigue_impact|tostring) ] | @tsv' "$AFJ" \
        | while IFS="$(printf '\t')" read -r oid prov fires flap oh reach imp; do
            echo "| \`${oid}\` | ${prov} | ${fires} | ${flap} | ${oh} | ${reach} | ${imp} |"
          done
        echo
      fi
      if [ "$CHRON_STATUS" = "measured" ]; then
        NCHRON="$(jq -r '.af_findings[]? | select(.af_id=="AF-006") | .chronic_objects // 0' "$AFJ")"
        if [ "${NCHRON:-0}" -gt 0 ]; then
          echo "**Chronic / stuck — firing continuously for a long time (desensitization risk — the team has learned to ignore these):**"
          echo
          echo "| Object | Tool | Stuck since | Days |"
          echo "| --- | --- | --- | ---: |"
          jq -r 'def esc: tostring | gsub("\\|"; "\\|"); .af_findings[]? | select(.af_id=="AF-006") | .objects[]? | [ (.object_id|esc), (.provider|esc), ((.stuck_since // "—")|esc), ((.stuck_days // 0)|tostring) ] | @tsv' "$AFJ" \
          | while IFS="$(printf '\t')" read -r oid prov since days; do echo "| \`${oid}\` | ${prov} | ${since} | ${days} |"; done
          echo
        fi
      fi
      # honest coverage line
      PENDING="$(jq -r '[.fire_history_coverage[]? | select(.status!="collected") | .provider] | join(", ")' "$AFJ")"
      [ -n "$PENDING" ] && { echo "_Fire-history not collected for: ${PENDING} (marked verify-pending — no measured number is guessed for them)._"; echo; }
    else
      echo "_Measured fire-history tier not collected this run. Inspect its coverage record for missing or blocked inputs. Native incident history, if supplied, is shown separately and never converted into fire counts._"
      echo
    fi
    if [ "$IH_COUNT" -gt 0 ]; then
      echo "### Native incident history"
      echo
      echo "Incidents are counted by start time in the stated window. Provider alert counts span incident lifetimes and are not windowed fires, notification attempts or human receipts. Incomplete windows show observed rows only; no full-window total is inferred."
      echo
      echo "| Target | State | Started after | Started before | Query phases | Complete window | Observed incidents | Full-window incidents | Provider alerts (incident lifetime) |"
      echo "| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: |"
      printf '%s' "$IH_ROWS" | jq -r '
        def esc: tostring|gsub("[\\r\\n\\t]";" ")|@html|gsub("`";"&#96;")|gsub("\\|";"&#124;");
        .[] | [.target,.state,.start,.end,.phases,.complete,.observed,.population,.provider_alerts]
        | "| " + (map(esc)|join(" | ")) + " |"'
      echo
      echo "Response means cover only observed, verified transition samples. Missing transitions and open/unacknowledged episodes remain visible; resolution does not prove source recovery."
      echo
      echo "| Target | Ack samples | Mean ack seconds (observed subset) | Resolution samples | Mean resolution seconds (observed subset) | Missing/unverified transitions | Unacknowledged or censored |"
      echo "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"
      printf '%s' "$IH_ROWS" | jq -r '
        def esc: tostring|gsub("[\\r\\n\\t]";" ")|@html|gsub("`";"&#96;")|gsub("\\|";"&#124;");
        .[] | [.target,.ack_samples,.ack_seconds,.resolution_samples,.resolution_seconds,.missing_transitions,.unacknowledged]
        | "| " + (map(esc)|join(" | ")) + " |"'
      printf '%s' "$IH_ROWS" | jq -r '
        def esc: gsub("[\\r\\n\\t]";" ")|@html|gsub("`";"&#96;")|gsub("\\|";"&#124;");
        .[] | select(.note!="") | "\n- " + (.target|esc) + ": " + (.note|esc)'
      echo
      printf '%s' "$IH_ROWS" | af_incident_history_details markdown
      echo "Recurring entities and short/no-ack episodes are review candidates, not proven false positives. Assignments are not interruptions. No noise-reduction percentage, duplicate-page count or savings is inferred."
      echo
    fi
    # --- Fatigue anti-pattern histogram (AF-007) ---
    if jq -e '.af_findings[]? | select(.af_id=="AF-007") | (.histogram | length) > 0' "$AFJ" >/dev/null 2>&1; then
      echo "### What KIND of noise (anti-pattern histogram)"
      echo
      echo "| Failure mode | Findings |"
      echo "| --- | ---: |"
      jq -r 'def esc: tostring | gsub("\\|"; "\\|"); .af_findings[]? | select(.af_id=="AF-007") | .histogram[]? | [ (.class|esc), (.count|tostring) ] | @tsv' "$AFJ" \
      | while IFS="$(printf '\t')" read -r cls cnt; do echo "| ${cls} | ${cnt} |"; done
      echo
    fi
    echo "### Potential cross-source overlap"
    echo
    if [ "${TS:-0}" -gt 0 ]; then
      echo "These audit targets share alerting configuration findings. This does not prove duplicate pages or human delivery. Verify whether they describe one linked path or independent paths before changing routing:"
      echo
      echo "| Service | Tools | Count |"
      echo "| --- | --- | ---: |"
      jq -r 'def tdisp: if type=="object" then (.host // .name // .type // tojson) else tostring end;
        def esc: tostring | gsub("\\|"; "\\|");
        .af_findings[]? | select(.type=="cross-source-alert-storm") | .storms[]?
        | [ (.service | esc), (((.tools // []) | map(tdisp) | join(", ")) | esc), (.tool_count | tostring) ] | @tsv' "$AFJ" \
      | while IFS="$(printf '\t')" read -r s tl c; do
          echo "| \`${s}\` | ${tl} | ${c} |"
        done
    else
      echo "No shared configuration findings were identified across the audited targets this run. This does not establish absence of duplicate events or pages."
    fi
    echo
    echo "### Alert-to-incident ratio"
    echo
    if [ "$RSTATUS" = "computed" ]; then
      jq -r '.af_findings[]? | select(.af_id=="AF-003")
        | "**\(.alerts_per_incident):1** — \(.alerts_fired) alerts fired to \(.incidents) real incident(s) over \(.window). Compare this with the declared paging budget and service objectives for this window. " + (.note // "")' "$AFJ"
    else
      jq -r '.af_findings[]? | select(.af_id=="AF-003")
        | "**Needs comparable source and incident populations.** " + (.reason // "No compatible source-event and incident populations were supplied. A validated fatigue.json signal block can supply the ratio inputs; it cannot establish actionability or human delivery.")' "$AFJ"
      echo
      echo "**Not measured this run:** an alert-to-incident ratio without comparable populations, actionability without labeled outcomes, and interruptions or delivery without notification/receipt evidence. Native incident response samples, when present above, do not supply those missing measurements."
    fi
    echo
    echo "### Operating guidance (apply your declared objectives)"
    echo
    echo "- **Every page actionable; page on symptoms, not causes.** (Google SRE, *Monitoring Distributed Systems*)"
    echo "- **<= 2 incidents per 12-hour shift**, on-call <= 25% of time, is a published operating example. (Google SRE, *Being On-Call*)"
    echo "Research and vendor benchmarks provide context, not universal pass/fail thresholds. Compare the declared service objectives, shift length, paging budget and observation window before setting an action threshold."
    echo "- **Alert on SLO burn-rate, not static thresholds** — multi-window 14.4 (1h/5m) + 6 (6h/30m); short window ~ 1/12 the long, long <= 48h. (SRE Workbook, *Alerting on SLOs*)"
    echo "- Group repeated updates without merging distinct problems. Preserve an urgent-event positive control when changing delay, grouping or suppression; no universal grouping window or compression percentage is assumed."
    echo "- Full principles, per-tier checklist, and sources: \`skills/alert-fatigue/references/methodology.md\`."
    echo
    echo "_Non-scored roll-up — cites each source finding-ID, re-scores nothing; noise is scored once in its home audit. Config + fire-history numbers are measured from read-only reads; the alert-to-incident ratio is reported only from your incident data._"
    ;;

  alert-fatigue-html)
    # Standalone HTML dashboard for alert-fatigue.json — mirrors the audit report.html
    # (severity chips, sortable "top offenders" table with a Fix column), scoped to
    # the alert-noise/fatigue view. Renders only structured fields, HTML-escaped via
    # jq @html; never a secret or raw command output. Read-only over local files.
    AFJ="${1:?alert-fatigue.json}"; OUT="${2:?out.html}"; D="${3:?audits-dir}"; RD="${4:?run-date}"
    [ -f "$AFJ" ] || { echo "no such file: $AFJ" >&2; exit 1; }
    read -r TN TS TT <<EOF
$(jq -r '.totals | "\(.alerting_noise_findings // 0) \(.cross_source_storms // 0) \(.tools_with_noise // 0)"' "$AFJ")
EOF
    RSTATUS="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | .status // "not-in-scope"' "$AFJ")"
    if [ "$RSTATUS" = "computed" ]; then
      RATIO_TXT="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | "\(.alerts_per_incident):1 (\(.alerts_fired) alerts / \(.incidents) incident(s), \(.window))"' "$AFJ")"
    else
      RATIO_TXT="needs incident feed (not fabricated)"
    fi
    NOISE="$(af_enriched_noise "$AFJ" "$D" "$RD")"
    read -r SC SH SM SL SI <<EOF
$(printf '%s' "$NOISE" | jq -r 'reduce .[] as $f ({critical:0,high:0,medium:0,low:0,info:0}; .[$f.severity] += 1) | "\(.critical) \(.high) \(.medium) \(.low) \(.info)"')
EOF
    UNREACH_STATUS="$(jq -r '[.af_findings[]?|select(.af_id=="AF-004")|.status][0] // "not-in-scope"' "$AFJ")"
    CHRON_STATUS="$(jq -r '[.af_findings[]?|select(.af_id=="AF-006")|.status][0] // "not-in-scope"' "$AFJ")"
    UNREACH_LABEL="can't reach a human"; CHRON_LABEL="chronic / stuck"
    UNREACH="not measured"; CHRON="not measured"
    if [ "$UNREACH_STATUS" = "measured" ]; then
      UNREACH="$(jq -r '.af_findings[]|select(.af_id=="AF-004")|.unreachable_objects' "$AFJ")"
      UNREACH_LABEL="$UNREACH_LABEL (measured)"
    elif [ "$UNREACH_STATUS" = "blocked" ]; then UNREACH="blocked"; fi
    if [ "$CHRON_STATUS" = "measured" ]; then
      CHRON="$(jq -r '.af_findings[]|select(.af_id=="AF-006")|.chronic_objects' "$AFJ")"
      CHRON_LABEL="$CHRON_LABEL (measured)"
    elif [ "$CHRON_STATUS" = "blocked" ]; then CHRON="blocked"; fi
    INPUT_NOTICE="$(jq -r 'if .input_validation.status=="blocked" then "<p><strong>Measured input blocked:</strong> " + (.input_validation.reason|@html) + "</p>" else "" end' "$AFJ")"
    FHOBJ="$(jq -r '.totals.fire_history_objects // 0' "$AFJ")"
    IH_ROWS="$(af_incident_history_rows "$AFJ")"
    IH_COUNT="$(printf '%s' "$IH_ROWS" | jq 'length')"
    {
    cat <<HTMLHEAD
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scoutflo AI Readiness — Alert noise &amp; fatigue</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f7f8fa;color:#1a202c}
@media(prefers-color-scheme:dark){body{background:#12151a;color:#e2e8f0}.card{background:#1a1f27!important;border-color:#2d3748!important}}
.wrap{max-width:1000px;margin:0 auto;padding:24px}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:20px;margin:16px 0;box-shadow:0 1px 3px rgba(0,0,0,.04)}
h1{font-size:20px;margin:0 0 4px}.sub{color:#718096;font-size:13px}
.metrics{display:flex;gap:28px;flex-wrap:wrap;margin:14px 0 4px}
.metric{display:flex;flex-direction:column}.metric .n{font-size:26px;font-weight:700}.metric .l{color:#718096;font-size:12px}
.sev{display:flex;gap:16px;flex-wrap:wrap;margin-top:8px}
.chip{display:inline-flex;align-items:center;gap:6px;font-weight:600}
.dot{width:12px;height:12px;border-radius:50%;display:inline-block}
.tiers{font-size:13px;color:#4a5568;margin-top:12px;line-height:1.6}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}
th{cursor:pointer;user-select:none;color:#4a5568}
code{font-size:12px}
.footer{color:#a0aec0;font-size:12px;text-align:center;margin:24px 0}
</style></head><body><div class="wrap">
<div class="card"><h1>Alert noise &amp; fatigue</h1><div class="sub">Scoutflo AI Readiness · ${RD} (UTC) · read-only, non-scored</div>
${INPUT_NOTICE}
<div class="metrics">
<div class="metric"><span class="n">${TN}</span><span class="l">alerting-noise findings</span></div>
<div class="metric"><span class="n">${TT}</span><span class="l">tools with noise</span></div>
<div class="metric"><span class="n">${TS}</span><span class="l">potential cross-source overlaps</span></div>
<div class="metric"><span class="n" style="color:#c53030">${UNREACH}</span><span class="l">${UNREACH_LABEL}</span></div>
<div class="metric"><span class="n" style="color:#dd6b20">${CHRON}</span><span class="l">${CHRON_LABEL}</span></div>
<div class="metric"><span class="n" style="font-size:18px">${RATIO_TXT}</span><span class="l">alert-to-incident ratio</span></div>
</div>
<div class="sev">
<span class="chip"><span class="dot" style="background:#c53030"></span>${SC} critical</span>
<span class="chip"><span class="dot" style="background:#dd6b20"></span>${SH} high</span>
<span class="chip"><span class="dot" style="background:#d69e2e"></span>${SM} medium</span>
<span class="chip"><span class="dot" style="background:#3182ce"></span>${SL} low</span>
<span class="chip"><span class="dot" style="background:#a0aec0"></span>${SI} info</span>
</div>
<div class="tiers"><strong>Evidence lanes keep their own units:</strong> config findings, fire-history observations, and native incident history with its start window and response sample counts. AF-005 can carry incident history without measured fires. A ratio requires comparable alert and incident populations; incident history alone does not prove actionability or human receipt.</div>
</div>
<div class="card"><h1 style="font-size:16px">Top offenders — worst first (problem &rarr; fix)</h1>
<table id="find"><thead><tr><th onclick="sortT(this,0)">Severity</th><th onclick="sortT(this,1)">Problem</th><th onclick="sortT(this,2)">Where</th><th onclick="sortT(this,3)">How to fix</th><th>Ref</th></tr></thead><tbody>
HTMLHEAD
    printf '%s' "$NOISE" | jq -r '
      def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.] // 5;
      def sd: {critical:"#c53030",high:"#dd6b20",medium:"#d69e2e",low:"#3182ce"}[.] // "#a0aec0";
      sort_by([(.severity|rank), .target, .id])
      | .[]
      | "<tr><td><span class=\"dot\" style=\"background:\(.severity|sd)\"></span> \(.severity)</td>"
        + "<td>\(.title|@html)<div class=\"sub\">\((.impact // "")|@html)</div></td>"
        + "<td>\(((.affected // []) | join(", "))|@html)</td>"
        + "<td>\(((.recommendation // "") + (if (.remediation // "") != "" then " -> " + .remediation else "" end))|@html)</td>"
        + "<td><code>\(.id|@html)</code> · \(.target|@html)</td></tr>"'
    cat <<'HTMLMID'
</tbody></table></div>
<div class="card"><h1 style="font-size:16px">Where the noise concentrates (by tool)</h1>
<table><thead><tr><th onclick="sortT(this,0)">Tool</th><th onclick="sortT(this,1,1)">Noise findings</th><th>By severity</th></tr></thead><tbody>
HTMLMID
    jq -r 'def tdisp: if type=="object" then (.host // .name // .type // tojson) else tostring end;
      .af_findings[]? | select(.af_id=="AF-001") | .by_source[]?
      | "<tr><td><code>\((.target|tdisp)|@html)</code></td><td>\(.noise_findings)</td><td>\(((.by_severity // {}) | to_entries | map("\(.value) \(.key)") | join(", "))|@html)</td></tr>"' "$AFJ"
    if [ "${TS:-0}" -gt 0 ]; then
      cat <<'HTMLSTORM'
</tbody></table></div>
<div class="card"><h1 style="font-size:16px">Potential cross-source overlap</h1>
<p class="sub">These audit targets share alerting configuration findings. This does not prove duplicate pages or human delivery. Verify linked versus independent paths before changing routing.</p>
<table><thead><tr><th>Service</th><th>Tools</th><th>Count</th></tr></thead><tbody>
HTMLSTORM
      jq -r 'def tdisp: if type=="object" then (.host // .name // .type // tojson) else tostring end;
        .af_findings[]? | select(.type=="cross-source-alert-storm") | .storms[]?
        | "<tr><td><code>\(.service|@html)</code></td><td>\(((.tools // []) | map(tdisp) | join(", "))|@html)</td><td>\(.tool_count)</td></tr>"' "$AFJ"
    fi
    echo '</tbody></table></div>'
    # Measured fire-history cards (AF-004/005/006) — shown only when the lane collected
    REACH_ST="$(jq -r '.af_findings[]? | select(.af_id=="AF-004") | .status // "not-in-scope"' "$AFJ")"
    VOL_ST="$(jq -r '.af_findings[]? | select(.af_id=="AF-005") | .status // "not-in-scope"' "$AFJ")"
    if [ "$REACH_ST" = "measured" ] || [ "$VOL_ST" = "measured" ]; then
      echo '<div class="card"><h1 style="font-size:16px">Measured fire-history</h1>'
      if [ "$REACH_ST" = "measured" ]; then
        jq -r '.af_findings[]? | select(.af_id=="AF-004") | "<p><strong style=\"color:#c53030\">\(.unreachable_objects) of \(.measured_objects)</strong> alerting objects cannot reach a human by construction — a page that pages nobody. By reason: " + (([.by_reason[]? | "\(.reason|@html) (\(.count))"]) | join("; ")) + ".</p>"' "$AFJ"
      fi
      if [ "$VOL_ST" = "measured" ]; then
        echo '<p class="sub">Top offenders ranked by measured fatigue impact (fires weighted by flapping / off-hours share / dead-end routing):</p>'
        echo '<table><thead><tr><th onclick="sortT(this,0)">Object</th><th onclick="sortT(this,1)">Tool</th><th onclick="sortT(this,2,1)">Fires</th><th>Flapping</th><th>Reaches human</th><th onclick="sortT(this,5,1)">Fatigue impact</th></tr></thead><tbody>'
        jq -r '.af_findings[]? | select(.af_id=="AF-005") | .top_offenders[]?
          | "<tr><td><code>\(.object_id|@html)</code></td><td>\(.provider|@html)</td><td>\(.fires)</td><td>\(if .flapping==true then "yes" else "no" end)</td><td>\(if .reaches_human==false then "<strong style=\"color:#c53030\">NO</strong>" elif .reaches_human==true then "yes" else "?" end)</td><td>\(.fatigue_impact)</td></tr>"' "$AFJ"
        echo '</tbody></table>'
      fi
      echo '</div>'
    fi
    if [ "$IH_COUNT" -gt 0 ]; then
      echo '<div class="card"><h1 style="font-size:16px">Native incident history</h1>'
      echo '<p class="sub">Incidents are counted by start time in the stated window. Provider alert counts cover incident lifetimes, not windowed fires, notification attempts or human receipts. Incomplete windows show observed rows only; full-window totals stay unavailable.</p>'
      echo '<table><thead><tr><th>Target</th><th>State</th><th>Started after</th><th>Started before</th><th>Query phases</th><th>Complete window</th><th>Observed incidents</th><th>Full-window incidents</th><th>Provider alerts (incident lifetime)</th></tr></thead><tbody>'
      printf '%s' "$IH_ROWS" | jq -r '.[] | [.target,.state,.start,.end,.phases,.complete,.observed,.population,.provider_alerts]
        | "<tr>" + (map("<td>" + (tostring|@html) + "</td>")|join("")) + "</tr>"'
      echo '</tbody></table><p class="sub">Response means cover only observed, verified transition samples. Missing transitions and open/unacknowledged episodes remain visible. Resolution is not proof of source recovery.</p>'
      echo '<table><thead><tr><th>Target</th><th>Ack samples</th><th>Mean ack seconds (observed subset)</th><th>Resolution samples</th><th>Mean resolution seconds (observed subset)</th><th>Missing/unverified transitions</th><th>Unacknowledged or censored</th></tr></thead><tbody>'
      printf '%s' "$IH_ROWS" | jq -r '.[] | [.target,.ack_samples,.ack_seconds,.resolution_samples,.resolution_seconds,.missing_transitions,.unacknowledged]
        | "<tr>" + (map("<td>" + (tostring|@html) + "</td>")|join("")) + "</tr>"'
      echo '</tbody></table>'
      printf '%s' "$IH_ROWS" | jq -r '.[] | select(.note!="") | "<p class=\"sub\">" + (.target|@html) + ": " + (.note|@html) + "</p>"'
      printf '%s' "$IH_ROWS" | af_incident_history_details html
      echo '<p class="sub">Recurring entities and short/no-ack episodes are review candidates, not proven false positives. Assignments are not interruptions. No noise-reduction percentage, duplicate-page count or savings is inferred.</p></div>'
    fi
    # Anti-pattern histogram card (AF-007)
    if jq -e '.af_findings[]? | select(.af_id=="AF-007") | (.histogram | length) > 0' "$AFJ" >/dev/null 2>&1; then
      echo '<div class="card"><h1 style="font-size:16px">What KIND of noise</h1><table><thead><tr><th>Failure mode</th><th>Findings</th></tr></thead><tbody>'
      jq -r '.af_findings[]? | select(.af_id=="AF-007") | .histogram[]? | "<tr><td>\(.class|@html)</td><td>\(.count)</td></tr>"' "$AFJ"
      echo '</tbody></table></div>'
    fi
    RATIO_NOTE="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | (if .status=="computed" then ((.note // "")) else (.reason // "No compatible source-event and incident populations were supplied. A validated fatigue.json signal block can supply ratio inputs, not actionability or human-delivery evidence.") end)' "$AFJ" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    GATED_HTML=""
    if [ "$RSTATUS" != "computed" ]; then
      GATED_HTML='<p class="sub"><strong>Additional evidence needed:</strong> comparable alert/incident populations for the ratio, labeled outcomes for actionability, and actual notification/receipt data for interruption or delivery claims. Native incident response samples do not supply those missing measurements.</p>'
    fi
    cat <<HTMLFOOT
<div class="card"><h1 style="font-size:16px">Alert-to-incident ratio</h1>
<p><strong>${RATIO_TXT}</strong></p><p class="sub">${RATIO_NOTE}</p>${GATED_HTML}</div>
<div class="footer">Generated by Scoutflo AI Readiness for Claude Code · mirrors alert-fatigue.json · non-scored roll-up · contains infrastructure detail — keep within your team</div>
<script>
function sortT(th,col,num){var t=th.closest('table'),tb=t.tBodies[0],rows=[].slice.call(tb.rows);
var d=th.__d=!th.__d;rows.sort(function(a,b){var x=a.cells[col].innerText,y=b.cells[col].innerText;
if(num){x=parseFloat(x)||0;y=parseFloat(y)||0;return d?x-y:y-x;}return d?x.localeCompare(y):y.localeCompare(x);});
rows.forEach(function(r){tb.appendChild(r);});}
</script>
</div></body></html>
HTMLFOOT
    } > "$OUT"
    echo "wrote $OUT"
    ;;

  exec-summary)
    # The top-of-report EXECUTIVE one-pager across the whole estate, computed from
    # the per-audit findings.json (+ alert-fatigue.json). Ranking is severity-first
    # (lexicographic), then recoverable points, then $ as an IN-BAND tiebreaker — a
    # big dollar figure NEVER promotes a low-severity finding above a critical one
    # (CVSS / AWS Security Hub both keep severity separate from $/criticality). No
    # blended composite score. Read-only; renders only structured fields.
    D="${1:?audits-dir}"; RD="${2:?run-date}"; TOPN="${3:-6}"
    set --
    for f in "$D"/*/"$RD"/findings.json "$D"/*/*/"$RD"/findings.json; do
      [ -e "$f" ] || continue
      relative="${f#"$D"/}"
      case "${relative%%/*}" in all|doctor|alert-fatigue|cost-analysis) continue ;; esac
      case "$(jq -r '.target // "?"' "$f")" in all|cost-analysis|doctor|"?") continue ;; esac
      set -- "$@" "$f"
    done
    # P3: detect a triage run — any findings.json with a "triage" scope envelope. A triage
    # pass is a curated fast SUBSET, so its one-pager must never read as a full assessment.
    TRIAGE=0
    for f in "$@"; do
      [ "$(jq -r '.scope // ""' "$f" 2>/dev/null)" = "triage" ] && { TRIAGE=1; break; }
    done
    echo "## Executive summary"
    echo
    if [ "$#" -eq 0 ]; then
      echo "_No audit findings for ${RD} yet — run \`/scoutflo:audit-all\` (or a triage pass) first._"
      exit 0
    fi
    if [ "$TRIAGE" -eq 1 ]; then
      echo "> ⚡ **TRIAGE — fast worst-first subset, NOT a full assessment.** This pass ran a curated high-signal subset per provider (smallest scope, no per-resource sweep). A clean or quiet result here is *not* an all-clear — run the full \`/scoutflo:audit-all\` for complete coverage."
      echo
    fi
    SCOPED=0
    for f in "$@"; do
      SCOPE_NOTICE="$(scope_notice "$f")"
      if [ -n "$SCOPE_NOTICE" ]; then
        if jq -e '.schema != "scoutflo-cost/v1" and .target != "cost"' "$f" >/dev/null; then SCOPED=1; fi
        safe_target="$(jq -r '.target | @html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")' "$f")"
        printf -- '- %s: %s\n' "$safe_target" "$SCOPE_NOTICE"
      fi
    done
    if [ "$SCOPED" -eq 1 ]; then echo; fi
    # Stack and assessment counts come from envelopes, including zero-finding
    # audits. Unknown evidence is not a confirmed gap or a healthy estate.
    read -r NST UNASSESSED INCOMPLETE BLOCKED <<EOF
$(jq -sr --argjson gate "$GATE" '
  # Cost opportunities have no readiness score by design. Keep them in the
  # ranked findings below, but out of all readiness denominators.
  [.[] | select(.schema != "scoutflo-cost/v1" and .target != "cost")] as $r
  | $r
  | length as $n
  | ([.[] | select(.score.overall == null or .score.state == "unassessed"
       or (.schema == "scoutflo-findings/v2" and (.score.assessment.scored_checks // 0) == 0))] | length) as $u
  | ([.[] | select(.score.overall == null or .score.overall < $gate
       or .score.end_to_end == false
       or (.schema == "scoutflo-findings/v2" and
           (.score.end_to_end != true or (.score.assessment.coverage_percent // 0) < 100)))] | length) as $i
  | ([.[] | (.checks // [] | map(select(.result == "blocked")) | length) as $c
       | (.findings // [] | map(select(.status == "blocked")) | length) as $f
       | [$c, $f, (.score.assessment.blocked_checks // 0)] | max] | add // 0) as $b
  | "\($n) \($u) \($i) \($b)"' "$@")
EOF
    ALL="$(jq -s '[ .[] | .target as $t | (.findings // [])[]
      | select((.lifecycle // "new") | IN("new","unchanged","regressed"))
      | select((.status // "configured") | IN("configured","validated-live"))
      | . + {target: $t} ]' "$@")"
    read -r NC NH NM <<EOF
$(printf '%s' "$ALL" | jq -r '"\([.[]|select(.severity=="critical")]|length) \([.[]|select(.severity=="high")]|length) \([.[]|select(.severity=="medium")]|length)"')
EOF
    # posture grade from the worst severity present
    if [ "$NST" -eq 0 ]; then GRADE="NO READINESS ASSESSMENT — only non-scored evidence supplied"
    elif [ "${NC:-0}" -gt 0 ]; then GRADE="AT RISK — critical gaps"; elif [ "${NH:-0}" -gt 0 ]; then GRADE="NEEDS WORK — high-severity gaps"; elif [ "${NM:-0}" -gt 0 ]; then GRADE="FAIR — medium gaps";
    elif [ "$TRIAGE" -eq 1 ]; then GRADE="no critical/high/medium in the TRIAGE SUBSET — not a full-assessment all-clear"
    elif [ "$UNASSESSED" -gt 0 ] || [ "$BLOCKED" -gt 0 ]; then GRADE="UNASSESSED OR PARTIAL — missing evidence prevents an all-clear"
    elif [ "$SCOPED" -eq 1 ] || [ "$INCOMPLETE" -gt 0 ]; then GRADE="no critical/high/medium findings in the assessed scope — end-to-end readiness not established"
    else GRADE="HEALTHY on what ran"; fi
    echo "**Posture: ${GRADE}.** ${NC} critical · ${NH} high · ${NM} medium across ${NST} stack(s), ${RD}."
    if [ "$BLOCKED" -gt 0 ] || [ "$UNASSESSED" -gt 0 ]; then
      echo "Evidence limits: ${UNASSESSED} stack(s) have no readiness score; ${BLOCKED} check(s) are blocked. See their reports to unlock evidence; these are not confirmed failures."
    fi
    if [ "$(printf '%s' "$ALL" | jq '[.[] | select(.severity != "info")] | length')" -gt 0 ]; then
      echo "Start with up to ${TOPN} observed findings below (worst first)."
    else
      echo "No observed non-info findings were supplied. This does not establish coverage beyond the assessed scope."
    fi
    echo
    echo "| # | Severity | What's wrong | Where (blast radius) | \$/mo | Fix |"
    echo "| --- | --- | --- | --- | ---: | --- |"
    printf '%s' "$ALL" | jq -r --argjson n "$TOPN" '
      def rank: {"critical":0,"high":1,"medium":2,"low":3,"info":4}[.] // 5;
      def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
      [ .[] | select(.severity != "info") ]
      | sort_by([ (.severity|rank), (-((.points_recoverable) // 0)), (-((.estimated_monthly_savings_usd) // 0)) ])
      | .[0:$n] | to_entries[]
      | ((.key + 1) | tostring) as $i | .value as $f
      | "| " + $i + " | " + (($f.severity // "info") | ascii_upcase) + " | " + ($f.title | esc)
        + "<br><sub>" + ($f.target | esc) + " · " + ($f.id | esc) + "</sub> | "
        + (($f.affected // [] | join(", ")) | esc) + " | "
        + (if ($f.estimated_monthly_savings_usd // null) != null then ("$" + ($f.estimated_monthly_savings_usd | tostring)) else "—" end) + " | "
        + ($f.recommendation // "" | esc) + (if ($f.remediation // "") != "" then " → `" + $f.remediation + "`" else "" end) + " |"'
    echo
    # measured reachability headline (alert-fatigue AF-004) — the fatigue-adjacent exec signal
    AFJ="$D/alert-fatigue.json"
    if [ -f "$AFJ" ]; then
      jq -r '.af_findings[]? | select(.af_id=="AF-004" and .status=="measured" and ((.unreachable_objects // 0) > 0))
        | "**Alerting reachability:** \(.unreachable_objects) of \(.measured_objects) alerting objects cannot reach a human by construction — a page that pages nobody (see Alert noise & fatigue)." + (if .routing_coverage_note != null then " _(routing resolved for \(.measured_objects) of \(.objects_seen) objects seen — over the resolved subset, not the whole estate.)_" else "" end)' "$AFJ"
    fi
    # top real cost lever (never modeled — only a provider-native $)
    TOPSAVE="$(printf '%s' "$ALL" | jq -r '[.[] | select((.estimated_monthly_savings_usd // 0) > 0)] | sort_by(-(.estimated_monthly_savings_usd)) | (.[0] // empty) | "\(.estimated_monthly_savings_usd)\t\(.title)"')"
    if [ -n "$TOPSAVE" ]; then
      TSV="$(printf '%s' "$TOPSAVE" | cut -f1)"; TST="$(printf '%s' "$TOPSAVE" | cut -f2-)"
      echo "**Top cost lever:** \$${TSV}/mo — ${TST} (provider-native figure; full ranked savings in the cost section)."
    fi
    echo
    echo "_Ranked worst-first by severity, then recoverable points, then \$ as an in-band tiebreaker — never a blended cross-domain score, and \$ never promotes a lesser finding above a critical one. Full per-finding detail is in each stack's report and the sections below._"
    ;;

  migration-plan)
    # Render a migration-plan.json (scoutflo-migration-plan/v1) as the human plan:
    # at-a-glance disposition counts, the honest mode banner, per-disposition
    # tables (each drop/fix row shows its EVIDENCE — the plan proposes, the human
    # decides), the capability-gap table with real alternatives, and the cutover
    # section with the history-does-not-transfer honesty. Renders only structured
    # fields; never re-derives a disposition. Read-only.
    MP="${1:?migration-plan.json}"
    echo "## Migration plan"
    echo
    if [ ! -f "$MP" ]; then
      echo "_No \`migration-plan.json\` — run the migration-plan skill first (it needs the source audit's artifacts for the run date)._"
      exit 0
    fi
    MP_SRC="$(jq -r '.source.provider // "?"' "$MP")"
    MP_TGT="$(jq -r '.target.provider // "?"' "$MP")"
    MP_MODE="$(jq -r '.mode // "?"' "$MP")"
    MP_DATE="$(jq -r '.run_date // "?"' "$MP")"
    read -r MN MM MF MD MC MG <<EOF
$(jq -r '.totals | "\(.objects // 0) \(.migrate // 0) \(.fix_then_migrate // 0) \(.drop_candidates // 0) \(.already_covered // 0) \(.no_equivalent // 0)"' "$MP")
EOF
    echo "**${MP_SRC} → ${MP_TGT}** · ${MP_DATE} · read-only plan (nothing is changed by this plan)"
    echo
    echo "**At a glance — ${MN} source objects: ${MM} migrate · ${MF} fix-then-migrate · ${MD} drop-candidates (evidence-cited) · ${MC} already covered on ${MP_TGT} · ${MG} no native equivalent.**"
    echo
    if [ "$MP_MODE" = "source-only" ]; then
      echo "> **Source-only mode:** ${MP_TGT} was not readable this run, so already-covered checks did not run and target shapes come from the pair catalog's capability model — verify against the live target before executing. Nothing here is fabricated from an unread target."
      echo
    fi
    if [ "${MF:-0}" -gt 0 ]; then
      echo "### Fix first, then migrate (broken at the source — do not import the defect)"
      echo
      echo "| Object | Kind | Why | Evidence |"
      echo "| --- | --- | --- | --- |"
      jq -r 'def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
        .inventory[] | select(.disposition == "fix-then-migrate")
        | [ ((if .source_target then .source_target + "/" + .name else .name end)|esc), (.kind|esc), (.disposition_reason|esc),
            ((.evidence // []) | map(.finding_id // ("signal:" + (.object_id // "?"))) | unique | join(", ")) ] | @tsv' "$MP" \
      | while IFS="$(printf '\t')" read -r n k w e; do echo "| \`${n}\` | ${k} | ${w} | ${e} |"; done
      echo
    fi
    if [ "${MD:-0}" -gt 0 ]; then
      echo "### Drop candidates (dead weight — migration is the moment to shed it)"
      echo
      echo "These are **proposals with evidence, pending your confirmation** — nothing is dropped silently:"
      echo
      echo "| Object | Kind | Why | Evidence |"
      echo "| --- | --- | --- | --- |"
      jq -r 'def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
        .inventory[] | select(.disposition == "drop-candidate")
        | [ ((if .source_target then .source_target + "/" + .name else .name end)|esc), (.kind|esc), (.disposition_reason|esc),
            ((.evidence // []) | map(.finding_id // ("signal:" + (.object_id // "?"))) | unique | join(", ")) ] | @tsv' "$MP" \
      | while IFS="$(printf '\t')" read -r n k w e; do echo "| \`${n}\` | ${k} | ${w} | ${e} |"; done
      echo
    fi
    if [ "${MC:-0}" -gt 0 ]; then
      echo "### Already covered on the target (do not double-migrate — and mind double-paging during the parallel run)"
      echo
      jq -r '.inventory[] | select(.disposition == "already-covered")
        | "- `\(if .source_target then .source_target + "/" + .name else .name end)` → matches `\(if .matched_target_identity then .matched_target_identity.target + "/" + .matched_target_identity.name else (.matched_target // "?") end)` on the target"' "$MP"
      echo
    fi
    echo "### Migrate (with the target shape per the pair catalog)"
    echo
    echo "| Object | Kind | Equivalence | Notes |"
    echo "| --- | --- | --- | --- |"
    jq -r 'def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
      .inventory[] | select(.disposition == "migrate")
      | [ ((if .source_target then .source_target + "/" + .name else .name end)|esc), (.kind|esc),
          ((.equivalence // .equivalence_default // "?")|esc),
          ((.notes // .target_shape.summary // "-")|esc) ] | @tsv' "$MP" \
    | while IFS="$(printf '\t')" read -r n k q o; do echo "| \`${n}\` | ${k} | ${q} | ${o} |"; done
    echo
    if [ "${MG:-0}" -gt 0 ]; then
      echo "### No native equivalent (honest gaps — each with its alternative)"
      echo
      echo "| Kind | Status | Alternative |"
      echo "| --- | --- | --- |"
      jq -r 'def esc: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
        (.gaps // [])[] | [ (.kind|esc), ((.status // "no-native-equivalent")|esc), ((.alternative // "?")|esc) ] | @tsv' "$MP" \
      | while IFS="$(printf '\t')" read -r k s a; do echo "| ${k} | ${s} | ${a} |"; done
      echo
    fi
    echo "### Cutover & data continuity (the honest part)"
    echo
    echo "- **Historical telemetry does not transfer** — config carries over per this plan; history stays in the source until retention/sunset. Continuity comes from the dual-write/parallel-run window below."
    jq -r '.cutover | "- **Parallel run:** " + (.parallel_run // "-")' "$MP"
    jq -r '.cutover | "- **Sunset gate:** " + (.audit_parity_gate // "-")' "$MP"
    echo
    echo "_Plan-only and read-only: this skill changes nothing on either side. Every drop/fix row cites audit or fire-history evidence from this run; equivalence classes are from the pair catalog (direct / approximate / manual / none) — an untranslatable part is named \`manual\`, never silently auto-translated._"
    ;;

  migration-plan-html)
    # Standalone HTML dashboard for migration-plan.json — disposition tiles + the
    # per-disposition tables, mirroring the markdown. Structured fields only,
    # HTML-escaped via jq @html; self-contained, no external assets. Read-only.
    MP="${1:?migration-plan.json}"; OUT="${2:?out.html}"
    [ -f "$MP" ] || { echo "no such file: $MP" >&2; exit 1; }
    MP_SRC="$(jq -r '.source.provider // "?"' "$MP")"
    MP_TGT="$(jq -r '.target.provider // "?"' "$MP")"
    MP_MODE="$(jq -r '.mode // "?"' "$MP")"
    MP_DATE="$(jq -r '.run_date // "?"' "$MP")"
    read -r MN MM MF MD MC MG <<EOF
$(jq -r '.totals | "\(.objects // 0) \(.migrate // 0) \(.fix_then_migrate // 0) \(.drop_candidates // 0) \(.already_covered // 0) \(.no_equivalent // 0)"' "$MP")
EOF
    MODE_HTML=""
    if [ "$MP_MODE" = "source-only" ]; then
      MODE_HTML='<div class="sub" style="margin-top:10px"><strong>Source-only mode:</strong> the target was not readable this run — already-covered checks did not run and target shapes come from the pair catalog; verify against the live target before executing.</div>'
    fi
    {
    cat <<HTMLHEAD
<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Scoutflo AI Readiness — Migration plan ${MP_SRC} → ${MP_TGT}</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.5 -apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;margin:0;background:#f7f8fa;color:#1a202c}
@media(prefers-color-scheme:dark){body{background:#12151a;color:#e2e8f0}.card{background:#1a1f27!important;border-color:#2d3748!important}}
.wrap{max-width:1000px;margin:0 auto;padding:24px}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:20px;margin:16px 0;box-shadow:0 1px 3px rgba(0,0,0,.04)}
h1{font-size:20px;margin:0 0 4px}.sub{color:#718096;font-size:13px}
.metrics{display:flex;gap:28px;flex-wrap:wrap;margin:14px 0 4px}
.metric{display:flex;flex-direction:column}.metric .n{font-size:26px;font-weight:700}.metric .l{color:#718096;font-size:12px}
table{border-collapse:collapse;width:100%;font-size:14px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e2e8f0;vertical-align:top}
th{cursor:pointer;user-select:none;color:#4a5568}
code{font-size:12px}
.footer{color:#a0aec0;font-size:12px;text-align:center;margin:24px 0}
</style></head><body><div class="wrap">
<div class="card"><h1>Migration plan — ${MP_SRC} &rarr; ${MP_TGT}</h1><div class="sub">Scoutflo AI Readiness · ${MP_DATE} (UTC) · read-only plan — nothing is changed by this plan</div>
<div class="metrics">
<div class="metric"><span class="n">${MN}</span><span class="l">source objects</span></div>
<div class="metric"><span class="n" style="color:#2f855a">${MM}</span><span class="l">migrate</span></div>
<div class="metric"><span class="n" style="color:#dd6b20">${MF}</span><span class="l">fix, then migrate</span></div>
<div class="metric"><span class="n" style="color:#c53030">${MD}</span><span class="l">drop candidates (evidenced)</span></div>
<div class="metric"><span class="n">${MC}</span><span class="l">already covered</span></div>
<div class="metric"><span class="n">${MG}</span><span class="l">no equivalent</span></div>
</div>${MODE_HTML}
</div>
<div class="card"><h1 style="font-size:16px">Dispositions</h1>
<table><thead><tr><th onclick="sortT(this,0)">Object</th><th onclick="sortT(this,1)">Kind</th><th onclick="sortT(this,2)">Disposition</th><th>Why</th><th>Evidence</th></tr></thead><tbody>
HTMLHEAD
    jq -r '
      def drank: {"drop-candidate":0,"fix-then-migrate":1,"no-equivalent":2,"already-covered":3,"migrate":4}[.] // 5;
      def dcol: {"drop-candidate":"#c53030","fix-then-migrate":"#dd6b20","no-equivalent":"#718096","already-covered":"#3182ce","migrate":"#2f855a"}[.] // "#a0aec0";
      .inventory | sort_by((.disposition | drank), .kind, .name) | .[]
      | "<tr><td><code>\((if .source_target then .source_target + "/" + .name else .name end)|@html)</code></td><td>\(.kind|@html)</td>"
        + "<td><span style=\"color:\(.disposition|dcol);font-weight:600\">\(.disposition|@html)</span></td>"
        + "<td>\(.disposition_reason|@html)" + (if .matched_target_identity then "<br><code>\((.matched_target_identity.target + "/" + .matched_target_identity.name)|@html)</code>" elif .matched_target then "<br><code>\(.matched_target|@html)</code>" else "" end) + "</td>"
        + "<td>\(((.evidence // []) | map(.finding_id // ("signal:" + (.object_id // "?"))) | unique | join(", "))|@html)</td></tr>"' "$MP"
    cat <<'HTMLMID'
</tbody></table></div>
HTMLMID
    if [ "${MG:-0}" -gt 0 ]; then
      echo '<div class="card"><h1 style="font-size:16px">No native equivalent — honest gaps</h1><table><thead><tr><th>Kind</th><th>Alternative</th></tr></thead><tbody>'
      jq -r '(.gaps // [])[] | "<tr><td>\(.kind|@html)</td><td>\((.alternative // "?")|@html)</td></tr>"' "$MP"
      echo '</tbody></table></div>'
    fi
    CUT_NOTE="$(jq -r '.cutover.note // ""' "$MP" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    cat <<HTMLFOOT
<div class="card"><h1 style="font-size:16px">Cutover &amp; data continuity</h1>
<p><strong>Historical telemetry does not transfer.</strong> ${CUT_NOTE}</p></div>
<div class="footer">Generated by Scoutflo AI Readiness for Claude Code · mirrors migration-plan.json · plan-only, read-only · contains infrastructure detail — keep within your team</div>
<script>
function sortT(th,col,num){var t=th.closest('table'),tb=t.tBodies[0],rows=[].slice.call(tb.rows);
var d=th.__d=!th.__d;rows.sort(function(a,b){var x=a.cells[col].innerText,y=b.cells[col].innerText;
if(num){x=parseFloat(x)||0;y=parseFloat(y)||0;return d?x-y:y-x;}return d?x.localeCompare(y):y.localeCompare(x);});
rows.forEach(function(r){tb.appendChild(r);});}
</script>
</div></body></html>
HTMLFOOT
    } > "$OUT"
    echo "wrote $OUT"
    ;;

  env-compare)
    # Combined prod-vs-pre-prod (or N-environment) view for audit-all's "all
    # environments" flow. Environment is a config-file axis (SCOUTFLO_CONFIG=
    # toolkit-<env>.yaml), not a path level, and findings.json carries no env
    # field — so each environment is audited into its OWN audit-dir and this mode
    # reads each dir and lays the per-integration readiness side by side. Never a
    # blended score across environments; an integration audited in one env but not
    # another is flagged as a coverage gap, not counted as a pass.
    #   env-compare <run-date> <label1> <dir1> [<label2> <dir2> ...]
    RD="${1:?run-date}"; shift 2>/dev/null || { echo "env-compare: run-date required" >&2; exit 2; }
    [ "$#" -ge 2 ] || { echo "env-compare: need at least one <label> <dir> pair" >&2; exit 2; }
    AGG="$(mktemp)"; FND="$(mktemp)"; ENVS=""
    trap 'rm -f "$AGG" "$FND"' EXIT
    TB="$(printf '\t')"
    while [ "$#" -ge 2 ]; do
      _lbl="$1"; _dir="$2"; shift 2
      ENVS="${ENVS} ${_lbl}"
      # dual-glob one-level <target>/<date>/ and two-level <integration>/<label>/<date>/
      for f in "$_dir"/*/"$RD"/findings.json "$_dir"/*/*/"$RD"/findings.json; do
        [ -f "$f" ] || continue
        tgt="$(jq -r '.target // "?"' "$f" 2>/dev/null || echo "?")"
        case "$tgt" in all|doctor|alert-fatigue|"?") continue ;; esac
        sc="$(jq -r 'if .score.overall == null then "na" else (.score.overall|tostring) end' "$f" 2>/dev/null || echo na)"
        read -r c h <<EOF
$(jq -r '[.findings[]?|select((.lifecycle//"new")!="suppressed")] | "\([.[]|select(.severity=="critical")]|length) \([.[]|select(.severity=="high")]|length)"' "$f" 2>/dev/null || echo "0 0")
EOF
        printf '%s\t%s\t%s\t%s\t%s\n' "$_lbl" "$tgt" "$sc" "${c:-0}" "${h:-0}" >> "$AGG"
        printf '%s\t%s\n' "$_lbl" "$f" >> "$FND"
      done
    done
    echo "## Prod vs pre-prod — combined readiness (${RD})"
    echo
    if [ ! -s "$AGG" ]; then echo "_No completed audits for ${RD} in any environment — run \`/scoutflo:audit-all\` per environment first._"; exit 0; fi
    INTS="$(cut -f2 "$AGG" | sort -u)"
    hdr="| Integration"; sep="| ---"
    for e in $ENVS; do hdr="${hdr} | ${e} score | ${e} crit/high"; sep="${sep} | ---: | ---:"; done
    echo "${hdr} |"; echo "${sep} |"
    for i in $INTS; do
      rowline="| \`${i}\`"
      for e in $ENVS; do
        line="$(awk -F"$TB" -v e="$e" -v i="$i" '$1==e && $2==i{print;exit}' "$AGG")"
        if [ -n "$line" ]; then
          s="$(printf '%s' "$line" | cut -f3)"; c="$(printf '%s' "$line" | cut -f4)"; h="$(printf '%s' "$line" | cut -f5)"
          [ "$s" = "na" ] && sdisp="unassessed" || sdisp="${s}/100"
          rowline="${rowline} | ${sdisp} | ${c}c / ${h}h"
        else
          rowline="${rowline} | — | —"
        fi
      done
      echo "${rowline} |"
    done
    echo
    NENV="$(printf '%s' "$ENVS" | wc -w | tr -d ' ')"
    gaps=""
    for i in $INTS; do
      seen="$(awk -F"$TB" -v i="$i" '$2==i{print $1}' "$AGG" | sort -u | wc -l | tr -d ' ')"
      [ "$seen" -lt "$NENV" ] && gaps="${gaps} \`${i}\`"
    done
    if [ -n "$gaps" ]; then
      echo "**Coverage gaps (audited in some environments but not all):**${gaps}. An integration missing from an environment is an untested surface, not a pass — confirm it is intentionally absent before treating that environment as clean."
      echo
    fi
    while IFS="$TB" read -r lbl f; do
      [ -f "$f" ] || continue
      SCOPE_NOTICE="$(scope_notice "$f")"
      if [ -n "$SCOPE_NOTICE" ]; then
        safe_label="$(printf '%s' "$lbl" | jq -Rr '@html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")')"
        safe_target="$(jq -r '.target | @html | gsub("`"; "&#96;") | gsub("\\|"; "&#124;")' "$f")"
        printf -- '- %s / %s: %s\n' "$safe_label" "$safe_target" "$SCOPE_NOTICE"
      fi
    done < "$FND"
    echo
    for e in $ENVS; do
      set --
      while IFS="$TB" read -r lbl f; do [ "$lbl" = "$e" ] && [ -f "$f" ] && set -- "$@" "$f"; done < "$FND"
      [ "$#" -ge 1 ] || continue
      _top="$(jq -s -r '[.[]|(.target//"?") as $t|(.findings//[])[]|select((.lifecycle//"new")!="suppressed")|.+{target:$t}]
        | map(select(.severity=="critical" or .severity=="high"))
        | sort_by({"critical":0,"high":1}[.severity]) | .[0:8][]
        | "- **" + (.severity|ascii_upcase) + "** `" + (.target) + "` — " + (.title) + (if (.affected//[]|length)>0 then " (" + ((.affected)|join(", ")) + ")" else "" end)' "$@" 2>/dev/null || true)"
      if [ -n "$_top" ]; then
        echo "### ${e} — top critical/high findings"
        echo
        printf '%s\n' "$_top"
        echo
      fi
    done
    echo "_Side-by-side per environment, never a blended cross-environment score. Each environment's full detail lives in its own audit directory._"
    ;;

  *)
    echo "usage: render-report-viz.sh {at-a-glance|scorecard|lanes|mermaid-topo|html|overlaps|rollup|inventory|inventory-rollup|alert-fatigue|alert-fatigue-html|exec-summary|env-compare|migration-plan|migration-plan-html} ..." >&2
    exit 2
    ;;
esac
