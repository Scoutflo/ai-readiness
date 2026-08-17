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
#   render-report-viz.sh at-a-glance  <findings.json> [history.jsonl]
#   render-report-viz.sh scorecard    <findings.json>
#   render-report-viz.sh mermaid-topo <topology-export.json> <target>
#   render-report-viz.sh html         <findings.json> <out.html> [history.jsonl]
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

score_label() {  # a plain-language band for a 0-100 score
  sl="$1"
  if   [ "$sl" -ge "$GATE" ]; then echo "end-to-end ready (>= ${GATE} gate)"
  elif [ "$sl" -ge 50 ]; then echo "good base coverage (below the ${GATE} end-to-end gate)"
  else echo "early coverage (below 50)"
  fi
}

# --- trend from history.jsonl (last 5 overall scores, oldest first) -----------
trend_scores() {  # $1 = history.jsonl (optional)
  [ -n "${1:-}" ] && [ -f "$1" ] || return 0
  tail -n 5 "$1" 2>/dev/null | jq -r '.overall // empty' 2>/dev/null | tr '\n' ' '
}

# =============================================================================
case "$MODE" in
  at-a-glance)
    F="${1:?findings.json}"; HIST="${2:-}"
    [ -f "$F" ] || { echo "render-report-viz: no such file: $F" >&2; exit 1; }
    OVERALL="$(jq -r '.score.overall // 0' "$F")"
    read -r CP CT <<EOF
$(jq -r '(([.score.categories[]?.checks_passed]|add // 0)|tostring) + " " + (([.score.categories[]?.checks_total]|add // 0)|tostring)' "$F")
EOF
    read -r SC SH SM SL SI <<EOF
$(jq -r '.severity_counts | "\(.critical//0) \(.high//0) \(.medium//0) \(.low//0) \(.info//0)"' "$F")
EOF
    SEVMAX="$(printf '%s\n' "$SC" "$SH" "$SM" "$SL" "$SI" | sort -rn | head -1)"; [ "${SEVMAX:-0}" -gt 0 ] || SEVMAX=1
    TREND="$(trend_scores "$HIST")"
    TOP="$(jq -r '[.findings[]? | select((.severity!="info") and ((.points_recoverable//0)>0))] | max_by(.points_recoverable) // empty | "\(.id)\t\(.points_recoverable)\t\(.title)"' "$F" 2>/dev/null)"

    echo "## At a glance"
    echo
    echo "**Score: ${OVERALL}/100**  \`$(viz_bar "$OVERALL" 100 20)\`  $(score_label "$OVERALL")"
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
      TID="$(printf '%s' "$TOP" | cut -f1)"; TP="$(printf '%s' "$TOP" | cut -f2)"; TT="$(printf '%s' "$TOP" | cut -f3)"
      echo
      echo "**Start here → ${TT} (${TID}): recovers the most points (+${TP}).**"
    fi
    ;;

  scorecard)
    F="${1:?findings.json}"; [ -f "$F" ] || { echo "no such file: $F" >&2; exit 1; }
    echo "| Category | Weight | Score | | Maturity | Checks |"
    echo "| --- | ---: | ---: | --- | --- | ---: |"
    jq -r '.score.categories[]? | "\(.name)\t\(.weight)\t\(.score)\t\(.maturity)\t\(.checks_passed)\t\(.checks_total)"' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt sc mat cp ct; do
        echo "| ${nm} | ${wt} | ${sc}/100 | \`$(viz_bar "$sc" 100 10)\` | ${mat} | ${cp}/${ct} |"
      done
    jq -r '.score.excluded[]? | "\(.name)\t\(.weight)\t\(.reason)"' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt rs; do
        echo "| ${nm} | ${wt} | excluded | \`░░░░░░░░░░\` | - | - |"
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
    RUNDATE="$(jq -r '.run_date // ""' "$F")"; OVERALL="$(jq -r '.score.overall // 0' "$F")"
    # Human display name: strip the 'audit-' lane prefix and title-case the words
    # (so the tab/heading read "Grafana audit — <target>", not the raw "audit-grafana" slug).
    DISPLAY="$(printf '%s' "$SKILL" | sed 's/^audit-//' | awk -F- '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}}1' OFS=' ') audit"
    read -r SC SH SM SL SI <<EOF
$(jq -r '.severity_counts | "\(.critical//0) \(.high//0) \(.medium//0) \(.low//0) \(.info//0)"' "$F")
EOF
    # score color band
    if [ "$OVERALL" -ge "$GATE" ]; then SCOLOR="#2f855a"; elif [ "$OVERALL" -ge 50 ]; then SCOLOR="#b7791f"; else SCOLOR="#c53030"; fi
    # SVG donut math: circumference for r=54
    DASH="$(awk -v s="$OVERALL" 'BEGIN{c=2*3.14159265*54; printf "%.1f %.1f", c*s/100, c*(1-s/100)}')"
    TREND="$(trend_scores "$HIST")"
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
<svg width="130" height="130" viewBox="0 0 130 130" role="img" aria-label="score ${OVERALL} of 100">
<circle cx="65" cy="65" r="54" fill="none" stroke="#e2e8f0" stroke-width="14"/>
<circle cx="65" cy="65" r="54" fill="none" stroke="${SCOLOR}" stroke-width="14" stroke-linecap="round"
 stroke-dasharray="${DASH}" transform="rotate(-90 65 65)"/>
<text x="65" y="60" text-anchor="middle" font-size="30" font-weight="700" fill="${SCOLOR}">${OVERALL}</text>
<text x="65" y="82" text-anchor="middle" font-size="12" fill="#718096">/ 100</text></svg>
<div><div class="sev">
<span class="chip"><span class="dot" style="background:#c53030"></span>${SC} critical</span>
<span class="chip"><span class="dot" style="background:#dd6b20"></span>${SH} high</span>
<span class="chip"><span class="dot" style="background:#d69e2e"></span>${SM} medium</span>
<span class="chip"><span class="dot" style="background:#3182ce"></span>${SL} low</span>
<span class="chip"><span class="dot" style="background:#a0aec0"></span>${SI} info</span>
</div>
HTMLHEAD
    if [ -n "$SPARK_PTS" ]; then
      echo "<svg width=\"320\" height=\"64\" style=\"margin-top:12px\" role=\"img\" aria-label=\"score trend\"><polyline fill=\"none\" stroke=\"${SCOLOR}\" stroke-width=\"2\" points=\"${SPARK_PTS}\"/></svg><div class=\"sub\">score trend (last ${TREND:+$(printf '%s' "$TREND" | wc -w | tr -d ' ')} runs)</div>"
    fi
    cat <<'HTMLMID'
</div></div></div>
<div class="card"><h1 style="font-size:16px">Scorecard</h1>
<table><thead><tr><th onclick="sortT(this,0)">Category</th><th onclick="sortT(this,1,1)">Weight</th><th onclick="sortT(this,2,1)">Score</th><th>Maturity</th><th>Checks</th></tr></thead><tbody>
HTMLMID
    jq -r '.score.categories[]? | [.name,(.weight|tostring),(.score|tostring),.maturity,(.checks_passed|tostring),(.checks_total|tostring)] | @tsv' "$F" \
    | while IFS="$(printf '\t')" read -r nm wt sc mat cp ct; do
        if [ "$sc" -ge "$GATE" ]; then bc="#2f855a"; elif [ "$sc" -ge 50 ]; then bc="#b7791f"; else bc="#c53030"; fi
        enm="$(printf '%s' "$nm" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td>${enm}</td><td>${wt}</td><td>${sc}/100<div class=\"barwrap\"><div class=\"bar\" style=\"width:${sc}%;background:${bc}\"></div></div></td><td>${mat}</td><td>${cp}/${ct}</td></tr>"
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
      | ({critical:0,high:1,medium:2,low:3,info:4}[.severity] // 5) as $r
      | [($r|tostring), (((.points_recoverable//0) * -1)|tostring), .severity, ((.points_recoverable//0)|tostring), .title, .id] | @tsv' "$F" \
    | sort -t"$(printf '\t')" -k1,1n -k2,2n \
    | while IFS="$(printf '\t')" read -r rank negpts sev pts title id; do
        case "$sev" in critical) sd="#c53030";; high) sd="#dd6b20";; medium) sd="#d69e2e";; low) sd="#3182ce";; *) sd="#a0aec0";; esac
        # escape HTML-special chars in the model-authored title
        et="$(printf '%s' "$title" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
        echo "<tr><td><span class=\"dot\" style=\"background:${sd}\"></span> ${sev}</td><td>${et}</td><td>${pts}</td><td><code>${id}</code></td></tr>"
      done
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
    echo "## Cross-stack correlation"
    echo
    if [ ! -f "$C" ]; then
      echo "_No \`correlation.json\` — cross-stack correlation runs in \`/scoutflo:audit-all\` (needs two or more audits)._"
      exit 0
    fi
    NOVL="$(jq '(.overlaps // []) | length' "$C" 2>/dev/null || echo 0)"
    NCAS="$(jq '(.cascades // []) | length' "$C" 2>/dev/null || echo 0)"
    if [ "${NOVL:-0}" -eq 0 ] && [ "${NCAS:-0}" -eq 0 ]; then
      echo "No cross-stack overlaps or cascades detected this run — each finding is scoped to a single stack."
      exit 0
    fi
    if [ "${NOVL:-0}" -gt 0 ]; then
      echo "**Redundant monitoring — one service flagged by multiple stacks. Review whether the coverage overlaps and consolidate the paging path:**"
      echo
      echo "| Service | Stacks | Findings | Consolidation review |"
      echo "| --- | --- | ---: | --- |"
      jq -r '.overlaps[]? | [ .service, ((.targets // []) | join(", ")), ((.findings // []) | length | tostring), (.recommendation // "-") ] | @tsv' "$C" \
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
    ;;

  rollup)
    # Combined "At a glance" for audit-all: gate-count meter + worst-first per-stack
    # score bars, read from every target's findings.json for the run date. Never a
    # mean (an average hides a failing stack behind a healthy one).
    D="${1:?audits-dir}"; RD="${2:?run-date}"
    echo "## At a glance (all stacks)"
    echo
    ROWS=""; total=0; passing=0
    for f in "$D"/*/"$RD"/findings.json; do
      [ -f "$f" ] || continue
      tgt="$(jq -r '.target // "?"' "$f" 2>/dev/null)"
      case "$tgt" in all|"?") continue;; esac
      sc="$(jq -r '.score.overall // 0' "$f" 2>/dev/null)"
      case "$sc" in *[!0-9]*) sc=0;; esac
      total=$((total + 1)); [ "$sc" -ge "$GATE" ] && passing=$((passing + 1))
      ROWS="${ROWS}${sc}	${tgt}
"
    done
    if [ "$total" -eq 0 ]; then echo "_No completed audits for ${RD}._"; exit 0; fi
    echo "**Stacks passing the ${GATE} gate: ${passing}/${total}**  \`$(viz_bar "$passing" "$total" 12)\`"
    echo
    echo "| Stack | Score | | |"
    echo "| --- | ---: | --- | --- |"
    printf '%s' "$ROWS" | sort -n | while IFS="$(printf '\t')" read -r sc tgt; do
      [ -n "$tgt" ] || continue
      [ "$sc" -ge "$GATE" ] && flag="" || flag="← below gate"
      echo "| \`${tgt}\` | ${sc}/100 | \`$(viz_bar "$sc" 100 12)\` | ${flag} |"
    done
    echo
    echo "_Worst-first — send the team to the top row. Never a combined average: one score line per stack._"
    ;;

  *)
    echo "usage: render-report-viz.sh {at-a-glance|scorecard|mermaid-topo|html|overlaps|rollup} ..." >&2
    exit 2
    ;;
esac
