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
  tv_model=""; tv_set=""
  if [ -n "$tv_f" ] && [ -f "$tv_f" ]; then
    tv_model="$(jq -r '.score.scoring_model // ""' "$tv_f")"
    tv_set="$(jq -r '.score.check_set // ""' "$tv_f")"
  fi
  if [ -n "$tv_model" ] && [ -n "$tv_set" ]; then
    tail -n 30 "$1" 2>/dev/null \
      | jq -r --arg model "$tv_model" --arg set "$tv_set" \
          'select(.scoring_model == $model and .check_set == $set and (.overall|type)=="number") | .overall' 2>/dev/null \
      | tail -n 5 | tr '\n' ' '
  else
    tail -n 5 "$1" 2>/dev/null | jq -r 'select((.overall|type)=="number") | .overall' 2>/dev/null | tr '\n' ' '
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
    case "$ae_f" in */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*|*/alert-fatigue/*) continue ;; esac
    set -- "$@" "$ae_f"
  done
  if [ "$#" -eq 0 ]; then ae_all='[]'; else
    ae_all="$(jq -s '[ .[] | (.target // "unknown") as $t | (.findings // [])[] | . + {target: $t} ]' "$@")"
  fi
  # A finding target may be a plain string OR a structured object (audit-signoz
  # records {type,host,version,edition}); tdisp normalizes either to one display
  # string used as both the join key and the shown value, and s coerces any text
  # field that is not a string, so the renderer never does object+string.
  printf '%s' "$ae_all" | jq --slurpfile af "$ae_afj" '
    def tdisp: if type == "object" then (.host // .name // .type // tojson) else tostring end;
    def s: if type == "string" then . elif . == null then "" else tojson end;
    (map({key: ((.target | tdisp) + "\u0001" + (.id // "")), value: .}) | from_entries) as $idx
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
    # A stack is "end-to-end" only when it clears the score gate AND was fully
    # assessed (v2 coverage 100%). A high score over a mostly-blocked estate is NOT
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
      total=$((total + 1))
      if [ "$sc" = "unassessed" ]; then
        sort_key=-1
      else
        case "$sc" in *[!0-9]*) sc="unassessed"; sort_key=-1;;
          *) sort_key="$sc"
             # full coverage: v1 (na) or unparseable is not penalized; v2 must be 100
             full=1; case "$cov" in ''|na|*[!0-9]*) full=1;; *) [ "$cov" -eq 100 ] || full=0;; esac
             [ "$sc" -ge "$GATE" ] && [ "$full" -eq 1 ] && passing=$((passing + 1));;
        esac
      fi
      ROWS="${ROWS}${sort_key}	${sc}	${cov}	${tgt}
"
    done
    if [ "$total" -eq 0 ]; then echo "_No completed audits for ${RD}._"; exit 0; fi
    echo "**Stacks end-to-end (>= ${GATE} gate and fully assessed): ${passing}/${total}**  \`$(viz_bar "$passing" "$total" 12)\`"
    echo
    echo "| Stack | Score | | |"
    echo "| --- | ---: | --- | --- |"
    printf '%s' "$ROWS" | sort -t"$(printf '\t')" -k1,1n | while IFS="$(printf '\t')" read -r sort_key sc cov tgt; do
      [ -n "$tgt" ] || continue
      if [ "$sc" = "unassessed" ]; then
        echo "| \`${tgt}\` | unassessed | \`░░░░░░░░░░░░\` | ← no readiness score |"
      else
        full=1; case "$cov" in ''|na|*[!0-9]*) full=1;; *) [ "$cov" -eq 100 ] || full=0;; esac
        if [ "$sc" -lt "$GATE" ]; then flag="← below gate"
        elif [ "$full" -eq 0 ]; then flag="← only ${cov}% assessed — not end-to-end"
        else flag=""
        fi
        echo "| \`${tgt}\` | ${sc}/100 | \`$(viz_bar "$sc" 100 12)\` | ${flag} |"
      fi
    done
    echo
    echo "_Worst-first — send the team to the top row. A high score over a partly-assessed estate is flagged, not counted as end-to-end. Never a combined average: one score line per stack._"
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
    if [ "$TOT" -eq 0 ]; then
      echo "No objects found in \`${TGT}\` this run — the estate is empty here, or (see the empty/hidden-scope guardrail) this identity cannot see them. This is the full catalog, not the gaps (those are in Findings)."
      exit 0
    fi
    echo "Complete current-state catalog of what \`${TGT}\` has configured (${TOT} objects). This is what exists; the gaps are in Findings above."
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
        .items[] | select(.kind == $k) | [ ((.name // "") | esc), ((.covers // "-") | esc), ((.severity // "-") | esc), ((.routes_to // "-") | esc), (if .enabled == false then "no" else "yes" end) ] | @tsv' "$INV" 2>/dev/null \
      | while IFS="$(printf '\t')" read -r nm cov sev rt en; do
          echo "| \`${nm}\` | ${cov} | ${sev} | ${rt} | ${en} |"
        done
      echo
    done
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
    echo "Everything the configured stacks have, by type — the current-state catalog across the estate."
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
    if [ "${TN:-0}" -eq 0 ]; then
      echo "No alerting-noise findings for ${RD} — the configured alerting is clean on the checks that ran, or no alerting provider was audited. (This is a config + fire-history read; a true alert-to-incident ratio needs an incident feed.)"
      exit 0
    fi
    if [ "$RSTATUS" = "computed" ]; then
      RATIO_LINE="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | "ratio: \(.alerts_per_incident):1 (\(.alerts_fired) alerts / \(.incidents) incident(s) over \(.window))"' "$AFJ")"
    else
      RATIO_LINE="ratio: needs incident feed (not fabricated)"
    fi
    echo "**At a glance — ${TN} alerting-noise finding(s) across ${TT} tool(s) · ${TS} cross-source storm(s) · ${RATIO_LINE}.**"
    echo
    echo "Read across three honest tiers: **config** (rule hygiene — a real yes/no from the rules), **fire-history** (measured volume/flapping/dead-weight from the alert stream), and **incident-feed** (true precision & alert-to-incident ratio — reported only from your incident data, never fabricated). AF-001/AF-002 below are the config + fire-history picture; the ratio is the incident-feed tier."
    echo
    NOISE="$(af_enriched_noise "$AFJ" "$D" "$RD")"
    read -r SC SH SM SL SI <<EOF
$(printf '%s' "$NOISE" | jq -r 'reduce .[] as $f ({critical:0,high:0,medium:0,low:0,info:0}; .[$f.severity] += 1) | "\(.critical) \(.high) \(.medium) \(.low) \(.info)"')
EOF
    SEVMAX="$(printf '%s\n' "$SC" "$SH" "$SM" "$SL" "$SI" | sort -rn | head -1)"; [ "${SEVMAX:-0}" -gt 0 ] || SEVMAX=1
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
    echo "### Cross-source alert storms"
    echo
    if [ "${TS:-0}" -gt 0 ]; then
      echo "One real incident on these services pages through **every** listed tool at once. Consolidate the paging path so one incident is one page:"
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
      echo "No cross-source storms this run — no single service carries alerting-noise findings from two or more tools. This lights up as you audit more than one alerting provider; it is the cross-tool view no single-vendor tool sees."
    fi
    echo
    echo "### Alert-to-incident ratio"
    echo
    if [ "$RSTATUS" = "computed" ]; then
      jq -r '.af_findings[]? | select(.af_id=="AF-003")
        | "**\(.alerts_per_incident):1** — \(.alerts_fired) alerts fired to \(.incidents) real incident(s) over \(.window). The SRE-canon goal is 1:1 (Google SRE, *Being On-Call*); higher is paging fatigue. " + (.note // "")' "$AFJ"
    else
      jq -r '.af_findings[]? | select(.af_id=="AF-003")
        | "**Needs your incident feed.** " + (.reason // "No incident/ack stream supplied, so the true alert-to-incident ratio and %-actionable are not computed — and never fabricated. Provide a fatigue.json signal block ({window, alerts_fired, incidents}) to compute it.")' "$AFJ"
      echo
      echo "**Not measured this run (incident-feed tier — deliberately not fabricated):** true alert-to-incident ratio, %-actionable (precision), MTTA/MTTR, escalation & ack rates, and the off-hours interruption split (business / off / sleep hours) all need the paging tool's incident/ack stream. Connect it — or supply a \`fatigue.json\` signal block — to unlock them. This honesty is the point: we report what the config + fire-history reads prove, and say so where a number would be a guess (unlike a headline \"N% noise reduction\" no one can reconcile)."
    fi
    echo
    echo "### What \"good\" looks like (cited — score against these, never invent one)"
    echo
    echo "- **Every page actionable; page on symptoms, not causes.** (Google SRE, *Monitoring Distributed Systems*)"
    echo "- **<= 2 incidents per 12-hour shift**, on-call <= 25% of time. Above this is the fatigue red flag. (Google SRE, *Being On-Call*)"
    echo "- **Alert on SLO burn-rate, not static thresholds** — multi-window 14.4 (1h/5m) + 6 (6h/30m); short window ~ 1/12 the long, long <= 48h. (SRE Workbook, *Alerting on SLOs*)"
    echo "- **Target 1:1 alert-to-incident**; group (~30-min default) and dedup (~24h default) so one incident is one page. (incident.io / FireHydrant / Opsgenie)"
    echo "- **AIOps compression sweet spot ~ 70-85%** — higher over-groups and hides real signal. (BigPanda / Splunk)"
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
<div class="metrics">
<div class="metric"><span class="n">${TN}</span><span class="l">alerting-noise findings</span></div>
<div class="metric"><span class="n">${TT}</span><span class="l">tools with noise</span></div>
<div class="metric"><span class="n">${TS}</span><span class="l">cross-source storms</span></div>
<div class="metric"><span class="n" style="font-size:18px">${RATIO_TXT}</span><span class="l">alert-to-incident ratio</span></div>
</div>
<div class="sev">
<span class="chip"><span class="dot" style="background:#c53030"></span>${SC} critical</span>
<span class="chip"><span class="dot" style="background:#dd6b20"></span>${SH} high</span>
<span class="chip"><span class="dot" style="background:#d69e2e"></span>${SM} medium</span>
<span class="chip"><span class="dot" style="background:#3182ce"></span>${SL} low</span>
<span class="chip"><span class="dot" style="background:#a0aec0"></span>${SI} info</span>
</div>
<div class="tiers"><strong>Three honest tiers:</strong> <em>config</em> (rule hygiene, a real yes/no) · <em>fire-history</em> (measured volume/flapping/dead-weight from the alert stream) · <em>incident-feed</em> (true precision &amp; alert-to-incident ratio — only from your incident data, never fabricated). The noise findings below are the config + fire-history picture; the ratio is the incident-feed tier.</div>
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
<div class="card"><h1 style="font-size:16px">Cross-source alert storms</h1>
<p class="sub">One real incident on these services pages through every listed tool at once — consolidate the paging path so one incident is one page.</p>
<table><thead><tr><th>Service</th><th>Tools</th><th>Count</th></tr></thead><tbody>
HTMLSTORM
      jq -r 'def tdisp: if type=="object" then (.host // .name // .type // tojson) else tostring end;
        .af_findings[]? | select(.type=="cross-source-alert-storm") | .storms[]?
        | "<tr><td><code>\(.service|@html)</code></td><td>\(((.tools // []) | map(tdisp) | join(", "))|@html)</td><td>\(.tool_count)</td></tr>"' "$AFJ"
    fi
    RATIO_NOTE="$(jq -r '.af_findings[]? | select(.af_id=="AF-003") | (if .status=="computed" then ((.note // "")) else (.reason // "No incident/ack stream supplied — the true ratio and %-actionable are not computed and never fabricated. Provide a fatigue.json signal block to compute it.") end)' "$AFJ" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
    GATED_HTML=""
    if [ "$RSTATUS" != "computed" ]; then
      GATED_HTML='<p class="sub"><strong>Not measured this run (incident-feed tier — deliberately not fabricated):</strong> true alert-to-incident ratio, %-actionable (precision), MTTA/MTTR, escalation &amp; ack rates, and the off-hours interruption split all need the paging tool&rsquo;s incident/ack stream. Connect it &mdash; or supply a <code>fatigue.json</code> signal block &mdash; to unlock them. We report what the config + fire-history reads prove and say so where a number would be a guess.</p>'
    fi
    cat <<HTMLFOOT
</tbody></table></div>
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

  *)
    echo "usage: render-report-viz.sh {at-a-glance|scorecard|lanes|mermaid-topo|html|overlaps|rollup|inventory|inventory-rollup|alert-fatigue|alert-fatigue-html} ..." >&2
    exit 2
    ;;
esac
