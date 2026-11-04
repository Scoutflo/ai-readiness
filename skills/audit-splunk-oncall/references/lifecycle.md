# Reuse, exemptions and history

Run this local-only recipe after authoring the complete seven-check `findings.json`. It never reads a provider or changes an observed check result. `derive` computes stable-check-ID lifecycle, affected-resource changes, exemptions and canonical scoring, then validates before replacing the file. Render the report from that result. Run `history` only after the report passes its validator; it replaces the same UTC date's row and preserves other valid rows. Both phases run in a fresh shell.

Set `SCOUTFLO_RUN_DATE` to the fixed date of this audit and `SCOUTFLO_LIFECYCLE_PHASE` to `derive` or `history`. Connection/config and list target resolution use the same shared parser as the collector. Keep the report root stable. Previous runs are earlier date-named folders for this exact target and skill, never the history ledger. A previous finding absent now is resolved only when this run's same-ID check passes; absent evidence or an omitted optional observation is not recovery. A failed check after a historically observed resolution is regressed, even when score models are incomparable.

## Normalize only explicit exemptions

The authoritative file is `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/exemptions.yaml`. If present, read it and produce a private JSON projection at `SCOUTFLO_EXEMPTIONS_JSON` containing every source entry without adding approval or inferring missing fields. There is no new YAML parser: use the guided session's structured conversion and compare it to the original. Bind it to the exact source bytes using the output of `cksum < exemptions.yaml | awk '{print $1 ":" $2}'`. This checksum detects a stale projection; it is not an approval signature. Never manufacture an exemption because a check is inconvenient.

Projection shape (values here are placeholders): `{"source_cksum":"<crc>:<bytes>","entries":[{"id":"SOC-004","reason":"<your accepted risk>","approved_by":"<optional owner or ticket>","expires":"YYYY-MM-DD"}]}`. Missing id/reason/expiry, invalid calendar dates and duplicate IDs are ignored with an aggregate diagnostic. Expiry is inclusive through the named UTC date. Expired entries reactivate the finding and record `exemption_expired: true`. A blocked check cannot be suppressed. With no source file, no exemption is applied and no projection is needed.

## Fixed artifact recipe

```bash
set -eu
umask 077
PHASE="${SCOUTFLO_LIFECYCLE_PHASE:-derive}"
case "$PHASE" in derive|history) ;; *) echo 'invalid lifecycle phase' >&2; exit 1 ;; esac
RUN_DATE="${SCOUTFLO_RUN_DATE:?retain this audit UTC date}"
printf '%s\n' "$RUN_DATE" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || exit 1
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for c in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$c" ] && { CFG="$c"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'config missing' >&2; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh"
KIND=$(sh "$TT" "$CFG" splunk_oncall kind); N=$(sh "$TT" "$CFG" splunk_oncall count)
[ "${N:-0}" -gt 0 ] || exit 1
SEG=splunk_oncall
if [ "$KIND" = seq ]; then
  LABELS=$(sh "$TT" "$CFG" splunk_oncall labels)
  li=0
  while [ "$li" -lt "$N" ]; do
    case "$(sh "$TT" "$CFG" splunk_oncall get "$li" label)" in ''|*[!A-Za-z0-9_-]*) echo 'List targets require explicit safe labels' >&2; exit 1;; esac
    li=$((li+1))
  done
  [ "$(printf '%s\n' "$LABELS" | sort -u | wc -l | tr -d ' ')" -eq "$N" ] || { echo 'duplicate target labels' >&2; exit 1; }
  case "${SCOUTFLO_TARGET:-}" in ''|*[!A-Za-z0-9_-]*) echo 'select a valid target label' >&2; exit 1 ;; esac
  printf '%s\n' "$LABELS" | grep -Fxq "$SCOUTFLO_TARGET" || exit 1
  SEG="splunk_oncall/$SCOUTFLO_TARGET"
fi
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
TARGET="$BASE/$SEG"; OUT="$TARGET/$RUN_DATE"; F="$OUT/findings.json"
[ -f "$F" ] && [ ! -L "$F" ] && [ ! -L "$OUT" ] || exit 1
jq -e --arg t "$SEG" --arg d "$RUN_DATE" '.schema=="scoutflo-findings/v2" and .skill=="audit-splunk-oncall" and .target==$t and .run_date==$d' "$F" >/dev/null
mkdir "$TARGET/.oncall-finalize.lock" || { echo 'another finalizer owns this target lock; do not steal it' >&2; exit 1; }
TMP=$(mktemp -d "$OUT/.lifecycle.XXXXXX")
trap 'rm -rf "$TMP"; rmdir "$TARGET/.oncall-finalize.lock"' EXIT HUP INT TERM
if [ "$PHASE" = history ]; then
  jq -e '(.delta|type)=="object" and (.lifecycle_metadata|type)=="object"' "$F" >/dev/null || { echo 'derive lifecycle before publishing history' >&2; exit 1; }
  CURRENT_SUM=""
  [ ! -f "$BASE/exemptions.yaml" ] || CURRENT_SUM=$(cksum < "$BASE/exemptions.yaml" | awk '{print $1 ":" $2}')
  jq -e --arg sum "$CURRENT_SUM" '(.lifecycle_metadata.exemptions_source_cksum//"")==$sum' "$F" >/dev/null || { echo 'exemptions changed; derive and render again before history' >&2; exit 1; }
  sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$F"
  sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
  HISTORY="$TARGET/history.jsonl"
  [ ! -L "$HISTORY" ] || exit 1
  : > "$TMP/history"; : > "$TMP/rejected"
  if [ -f "$HISTORY" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if printf '%s\n' "$line" | jq -e 'type=="object" and .skill=="audit-splunk-oncall" and (.run_date|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) and (.overall==null or ((.overall|type)=="number" and .overall>=0 and .overall<=100 and .overall==(.overall|floor))) and (.gate|type)=="number" and (.end_to_end|type)=="boolean" and (.severity_counts|type)=="object" and (.lifecycle_counts|type)=="object"' >/dev/null 2>&1; then
        old_date=$(printf '%s\n' "$line" | jq -r '.run_date')
        [ "$old_date" = "$RUN_DATE" ] || printf '%s\n' "$line" >> "$TMP/history"
      else
        printf '%s\n' "$line" >> "$TMP/rejected"
      fi
    done < "$HISTORY"
  fi
  jq -c '. as $doc | {run_date,skill,overall:.score.overall,gate:.score.gate,end_to_end:.score.end_to_end,scoring_model:.score.scoring_model,check_set:.score.check_set,assessment_coverage_percent:.score.assessment.coverage_percent,severity_counts,lifecycle_counts:(reduce ["new","unchanged","regressed","suppressed"][] as $k ({resolved:(.delta.resolved|length)}; .[$k]=([$doc.findings[]|select(.lifecycle==$k)]|length)))}' "$F" > "$TMP/row"
  cat "$TMP/row" >> "$TMP/history"
  if [ -s "$TMP/rejected" ]; then
    REJECTED=$(mktemp "$TARGET/history-rejected.XXXXXX.jsonl")
    mv "$TMP/rejected" "$REJECTED"
    echo "Malformed history rows quarantined in $REJECTED; valid rows preserved" >&2
  fi
  mv "$TMP/history" "$HISTORY"
  echo "History updated: $HISTORY"
  exit 0
fi
: > "$TMP/past.jsonl"
for prior in "$TARGET"/????-??-??/findings.json; do
  [ -f "$prior" ] || continue
  pd=$(basename "$(dirname "$prior")")
  printf '%s\n' "$pd" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue
  [ "$pd" = "$RUN_DATE" ] && continue
  [ "$(printf '%s\n%s\n' "$pd" "$RUN_DATE" | LC_ALL=C sort | head -n 1)" = "$pd" ] || continue
  [ ! -L "$prior" ] || exit 1
  jq -e --arg t "$SEG" --arg d "$pd" '.skill=="audit-splunk-oncall" and .target==$t and .run_date==$d and (.findings|type)=="array" and all(.findings[];(.id|type)=="string") and ([.findings[].id]|length==(unique|length))' "$prior" >/dev/null || { echo 'invalid prior artifact; do not guess lifecycle' >&2; exit 1; }
  jq -c '.' "$prior" >> "$TMP/past.jsonl"
done
jq -s 'sort_by(.run_date)' "$TMP/past.jsonl" > "$TMP/past.json"
printf '{"entries":[]}\n' > "$TMP/exemptions.json"
if [ -f "$BASE/exemptions.yaml" ]; then
  NORMAL="${SCOUTFLO_EXEMPTIONS_JSON:?normalize the explicit source exemptions first}"
  SUM=$(cksum < "$BASE/exemptions.yaml" | awk '{print $1 ":" $2}')
  jq -e --arg sum "$SUM" '.source_cksum==$sum and (.entries|type)=="array"' "$NORMAL" >/dev/null || { echo 'exemption projection missing or stale' >&2; exit 1; }
  cp "$NORMAL" "$TMP/exemptions.json"
fi
jq --slurpfile past "$TMP/past.json" --slurpfile ex "$TMP/exemptions.json" --arg day "$RUN_DATE" '
  def date_ok:
    if type!="string" then false else
      try (capture("^(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})$")|map_values(tonumber)|
        .y as $y|.m as $m|.d as $d|
        $y>0 and $m>=1 and $m<=12 and $d>=1 and
        $d<=([31,(if ($y%400==0 or ($y%4==0 and $y%100!=0)) then 29 else 28 end),31,30,31,30,31,31,30,31,30,31][$m-1])) catch false end;
  def good_entry:
    if type!="object" then false else
      (.id|if type=="string" then test("^[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}$") else false end) and
      (.reason|if type=="string" then test("[^[:space:]]") else false end) and (.expires|date_ok) and
      ((has("approved_by")|not) or (.approved_by|type)=="string") end;
  def recalc:
    .checks as $all |
    .score.categories |= map(. as $cat | [$all[]|select(.category==$cat.name)] as $rs |
      .checks_passed=([$rs[]|select(.suppressed!=true and .result=="pass")]|length) |
      .checks_partial=([$rs[]|select(.suppressed!=true and .result=="partial")]|length) |
      .checks_failed=([$rs[]|select(.suppressed!=true and .result=="fail")]|length) |
      .checks_blocked=([$rs[]|select(.result=="blocked")]|length) |
      .checks_suppressed=([$rs[]|select(.suppressed==true)]|length) |
      .checks_not_in_scope=([$rs[]|select(.result=="not-in-scope")]|length) |
      .checks_total=(.checks_passed+.checks_partial+.checks_failed) |
      .score=(if .checks_total==0 then 0 else ((100*(.checks_passed+0.5*.checks_partial)/.checks_total)|floor) end)) |
    .score.excluded=[.score.categories[]|select(.checks_total==0)|{name,weight,reason:"No unsuppressed assessed checks; see the check ledger"}] |
    [.score.categories[]|select(.checks_total>0)] as $inc |
    .score.state=(if ($inc|length)==0 then "unassessed" else "assessed" end) |
    .score.overall=(if ($inc|length)==0 then null else (($inc|map(.weight*.score)|add)/($inc|map(.weight)|add)|floor) end) |
    .score.end_to_end=false |
    .score.assessment={applicable_checks:([$all[]|select(.result!="not-in-scope")]|length),assessed_checks:([$all[]|select(.result|IN("pass","partial","fail"))]|length),scored_checks:([$all[]|select(.suppressed!=true and (.result|IN("pass","partial","fail")))]|length),blocked_checks:([$all[]|select(.result=="blocked")]|length),suppressed_checks:([$all[]|select(.suppressed==true)]|length),not_in_scope_checks:([$all[]|select(.result=="not-in-scope")]|length)} |
    .score.assessment.coverage_percent=(.score.assessment|if .applicable_checks==0 then 0 else (100*.assessed_checks/.applicable_checks|floor) end);
  if ($day|date_ok) then . else error("invalid calendar run date") end |
  $past[0] as $runs | ($runs[-1]//null) as $previous |
  [$ex[0].entries[]|select(good_entry)] as $valid |
  [$valid[]|. as $e|select(([$ex[0].entries[]|if type=="object" then select(.id==$e.id) else empty end]|length)==1)] as $unique |
  .lifecycle_metadata={exemptions_source_cksum:($ex[0].source_cksum//null),ignored_exemption_entries:(($ex[0].entries|length)-($unique|length))} |
  .checks |= map(del(.suppressed,.suppression_reason)) |
  .checks as $checks |
  .findings |= map(. as $f | del(.exemption,.exemption_expired) |
    ([$unique[]|select(.id==$f.id)][0]//null) as $e |
    if $e!=null and $e.expires>=$day and ($f.scoring_scope=="non-scored" or any($checks[];.id==$f.id and (.result|IN("partial","fail")))) then
      .lifecycle="suppressed" | .exemption=$e
    else
      .lifecycle=(if $previous!=null and any($previous.findings[];.id==$f.id) then "unchanged"
        elif any($runs[]; . as $r | any(.delta.resolved[]?;.==$f.id) or
          (any(.checks[]?;.id==$f.id and .result=="pass") and any($runs[];.run_date<$r.run_date and any(.findings[];.id==$f.id)))) then "regressed"
        else "new" end) |
      if $e!=null and $e.expires<$day then .exemption_expired=true else . end
    end) |
  [.findings[]|select(.lifecycle=="suppressed" and .scoring_scope=="readiness")|{id,reason:.exemption.reason}] as $supp |
  .checks |= map(. as $c | ([$supp[]|select(.id==$c.id)][0]//null) as $s | if $s==null then . else .suppressed=true|.suppression_reason=$s.reason end) |
  recalc | . as $doc |
  .findings |= map(. as $f | .points_recoverable=(if .severity=="info" or .lifecycle=="suppressed" or .status=="blocked" or .scoring_scope=="non-scored" then 0 else
    (($doc | .checks |= map(if .id==$f.id then .result="pass" else . end) | recalc | .score.overall)-$doc.score.overall)|[.,1]|max end)) |
  .severity_counts=(reduce [.findings[]|select(.lifecycle!="suppressed")|.severity][] as $s ({critical:0,high:0,medium:0,low:0,info:0}; .[$s]+=1)) |
  .delta={baseline_date:($previous.run_date//null),new:[.findings[]|select(.lifecycle=="new")|.id],unchanged:[.findings[]|select(.lifecycle=="unchanged")|.id],regressed:[.findings[]|select(.lifecycle=="regressed")|.id],suppressed:[.findings[]|select(.lifecycle=="suppressed")|.id],resolved:[$previous.findings[]? | .id as $id | select(any($doc.checks[];.id==$id and .result=="pass")) | $id],affected_changes:[$previous.findings[]? | . as $old | $doc.findings[] | select(.id==$old.id) | {id,added:((.affected//[])-($old.affected//[])),removed:(($old.affected//[])-(.affected//[]))} | select((.added|length)>0 or (.removed|length)>0)]}
' "$F" > "$TMP/derived.json"
IGNORED=$(jq -r '.lifecycle_metadata.ignored_exemption_entries' "$TMP/derived.json")
[ "$IGNORED" -eq 0 ] || echo "Ignored $IGNORED malformed or duplicate exemption entries; findings remain open" >&2
FINGERPRINT=$(jq -r '([.checks[]|"chk\t"+.id+"\t"+.category]+[.score.categories[]|"cat\t"+.name+"\t"+(.weight|tostring)]+["gate\t"+(.score.gate|tostring)])|sort|.[]' "$TMP/derived.json" | LC_ALL=C cksum | awk '{print "cksum-v2:" $1 ":" $2}')
jq --arg fp "$FINGERPRINT" --slurpfile past "$TMP/past.json" '.score.check_set=$fp | ($past[0][-1]//null) as $p | .delta.score_comparable=($p!=null and $p.score.scoring_model==.score.scoring_model and $p.score.check_set==.score.check_set) | .delta.score_change=(if .delta.score_comparable and .score.overall!=null and $p.score.overall!=null then .score.overall-$p.score.overall else null end)' "$TMP/derived.json" > "$TMP/checked.json"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$TMP/checked.json"
mv "$TMP/checked.json" "$F"
echo "Lifecycle, exemptions and scoring validated: $F"
```

The recipe keeps observed `partial`/`fail` rows when suppressing them, records the reason in both layers, excludes them only from readiness, and keeps them assessed. Re-running `derive` removes stale suppression and recalculates all counts, scores, recoverable points and the check-set fingerprint. It never marks a blocked check healthy or infers notification delivery.

The history phase also rejects an exemption-source change since derivation; derive and render again first. History rejects are retained in a private `history-rejected.*.jsonl` sidecar with a diagnostic; they are not silently converted to valid rows. The canonical ledger contains valid rows only. A failure before validation leaves the prior canonical findings/history unchanged. Do not reuse a prior report after deriving new findings: regenerate it before the history phase. History rotation and compatible last-five-row rendering follow the shared report standard.
