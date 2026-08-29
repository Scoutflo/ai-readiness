#!/bin/sh
# check-findings.sh — validate a findings.json against the canonical scoring
# model and schema in report-standard/severity-and-scoring.md + findings-schema.md.
#
# Why this exists: report.md conformance (check-report.sh) validates the report's
# SHAPE, but nothing validated the NUMBERS. The overall score is authored by the
# model at runtime, and in real runs it drifted 2-5 points above what its own
# scorecard supports (audit-lgtm 44 vs 39, audit-aws 24 vs 20, ...) — a headline
# score that does not reconcile with the category breakdown printed right below
# it. This gate makes that class mechanically impossible to ship: it recomputes
# `overall` from `score.categories` (excluding renormalized categories exactly as
# the standard prescribes) and fails on any disagreement > 1 point, plus the
# other machine-checkable schema invariants.
#
# Usage: report-standard/check-findings.sh path/to/findings.json
# Exit 0 = consistent (prints FINDINGS-OK). Exit 1 = drift/violation (lists each).
#
# It checks arithmetic + schema, never judgment: it cannot know whether a finding
# is TRUE about the live system (that needs live re-verification) — only that the
# file agrees with itself and the schema.
set -eu

F="${1:?usage: check-findings.sh path/to/findings.json}"
[ -f "$F" ] || { echo "FINDINGS-FAIL: no such file: $F"; exit 1; }
command -v jq >/dev/null || { echo "FINDINGS-FAIL: jq not installed"; exit 1; }
jq empty "$F" 2>/dev/null || { echo "FINDINGS-FAIL: $F is not valid JSON"; exit 1; }

FAIL=0
fail() { echo "FINDINGS-FAIL: $1"; FAIL=1; }

# 1. Envelope: required top-level fields present.
for k in schema toolkit_version skill target run_date generated_at score severity_counts findings; do
  jq -e --arg k "$k" 'has($k)' "$F" >/dev/null 2>&1 || fail "missing required envelope field: $k"
done
sch="$(jq -r '.schema // ""' "$F")"
case "$sch" in
  scoutflo-findings/v1|scoutflo-findings/v2) : ;;
  *) fail "schema is '$sch', expected 'scoutflo-findings/v1' or 'scoutflo-findings/v2'" ;;
esac

# 2. severity_counts must equal the actual histogram of NON-SUPPRESSED
#    findings[].severity. Suppressed findings (lifecycle=="suppressed") move to the
#    report's Suppressed appendix and are excluded from the severity counts (per
#    findings-schema.md and report-template.md), so the histogram is computed over
#    findings whose lifecycle != "suppressed" to match the schema. (The suppressed
#    lifecycle enum itself is still validated in 7d below.)
declared="$(jq -cS '.severity_counts' "$F")"
actual="$(jq -cS '[.findings[] | select(.lifecycle != "suppressed") | .severity]
  | {critical:(map(select(.=="critical"))|length),
     high:(map(select(.=="high"))|length),
     medium:(map(select(.=="medium"))|length),
     low:(map(select(.=="low"))|length),
     info:(map(select(.=="info"))|length)}' "$F")"
[ "$declared" = "$actual" ] || fail "severity_counts $declared != actual histogram of non-suppressed findings $actual"

# 3. Category weights must sum to 100. Current artifacts keep every category in
#    score.categories and use score.excluded as a named exclusion ledger. Older
#    v1 artifacts may instead put omitted-category weight only in score.excluded;
#    accept both shapes without double-counting a category named in both arrays.
wsum="$(jq '
  (.score.categories // []) as $cats
  | ($cats | map(.name)) as $names
  | (($cats | map(.weight) | add // 0)
     + ([.score.excluded[]? | select(.name as $n | ($names | index($n)) == null) | (.weight // 0)] | add // 0))
' "$F")"
[ "$wsum" = "100" ] || fail "distinct category weights sum to $wsum, expected 100"

# 4. overall must equal the weight-normalized sum over INCLUDED categories,
#    rounded down — excluding any category whose name is in score.excluded
#    (the standard's renormalization rule). Tolerance 1 for rounding.
# Guard the arithmetic: without this, a malformed score.overall (missing, string,
# fractional) or an empty/non-array score.categories makes the reconciliation
# below misbehave with a cryptic jq error instead of a clear schema failure.
# Set `overall` numerically up front (a non-number becomes -1) so every later
# integer comparison (the delta below, the end_to_end gate) stays safe even when
# the file is malformed — a string overall must never reach shell arithmetic.
overall="$(jq -r 'if .score.overall == null then "null" elif (.score.overall|type)=="number" then .score.overall else "invalid" end' "$F")"
score_state="$(jq -r '.score.state // "assessed"' "$F")"
if [ "$overall" = "null" ]; then
  if [ "$sch" != "scoutflo-findings/v2" ] || [ "$score_state" != "unassessed" ]; then
    fail "score.overall may be null only for a v2 score.state=unassessed run"
  fi
  inc_count="$(jq '(.score.excluded // [] | map(.name)) as $ex | [.score.categories[]? | select(.name as $n | ($ex | index($n)) | not)] | length' "$F")"
  [ "$inc_count" = "0" ] || fail "score.state=unassessed requires every scorecard category to be excluded"
elif jq -e '
  (.score.overall   | type == "number" and . == floor)
  and (.score.categories | type == "array" and (length > 0))
' "$F" >/dev/null; then
  recomp="$(jq '
    (.score.excluded // [] | map(.name)) as $ex
    | (.score.categories | map(select(.name as $n | ($ex | index($n)) | not))) as $inc
    | if ($inc | length) == 0 then null
      else (($inc | map(.weight * .score) | add) / ($inc | map(.weight) | add)) | floor
      end' "$F")"
  if [ "$recomp" = "null" ]; then
    fail "no included categories to recompute overall from (all excluded?)"
  else
    d=$(( overall > recomp ? overall - recomp : recomp - overall ))
    [ "$d" -le 1 ] || fail "overall=$overall does not reconcile with scorecard (categories -> $recomp, delta $d > 1); overall must be the weight-normalized sum over included categories, rounded down"
  fi
else
  fail "score.overall must be an integer number (or null for a v2 unassessed run) and score.categories a non-empty array (got overall=$(jq -c '.score.overall' "$F" 2>/dev/null || echo missing), categories=$(jq -c '.score.categories | length' "$F" 2>/dev/null || echo missing))"
fi

# 5. Each included category: score 0-100, checks_passed <= checks_total,
#    weight positive. (checks_total 0 is allowed only for an excluded/renormalized
#    category, checked via exclusion above.)
badcat="$(jq -r '
  (.score.excluded // [] | map(.name)) as $ex
  | .score.categories[]?
  | select(.name as $n | ($ex | index($n)) | not)
  | select((.score < 0) or (.score > 100) or (.weight <= 0) or ((.checks_passed // 0) > (.checks_total // 0)))
  | .name' "$F")"
[ -z "$badcat" ] || fail "included category(ies) with impossible score/weight/checks: $(echo "$badcat" | tr '\n' ' ')"

# 6. end_to_end must be false unless overall>=85 AND no category excluded.
e2e="$(jq -r '.score.end_to_end' "$F")"
nexcl="$(jq '.score.excluded // [] | length' "$F")"
if [ "$e2e" = "true" ]; then
  if [ "$overall" = "null" ] || [ "$overall" = "invalid" ]; then
    fail "end_to_end=true but the run has no numeric readiness score"
  else
    { [ "$overall" -ge 85 ] && [ "$nexcl" -eq 0 ]; } || fail "end_to_end=true but overall=$overall (<85) or excluded categories present ($nexcl); the gate forbids this"
  fi
fi

# 7. Finding objects: id well-formed (PREFIX 2-6 alnum, ending in a letter, then
#    -NNN) and unique; required fields present; evidence has command+observed;
#    remediation non-empty; severity in the enum; points_recoverable 0 for
#    info findings.
# 7a. ID format — prefix is 2-6 chars of [A-Z0-9] that starts with a letter
#     (covers K8S, SNTRY, ALR, DD, GC, ...), then -<2-4 digits>.
badids="$(jq -r '.findings[].id | select(test("^[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}$") | not)' "$F")"
[ -z "$badids" ] || fail "malformed finding IDs: $(echo "$badids" | tr '\n' ' ')"
dupe="$(jq -r '[.findings[].id] | (length) - (unique | length)' "$F")"
[ "$dupe" = "0" ] || fail "$dupe duplicate finding ID(s)"

# 7b. required per-finding fields.
for k in id title severity area status lifecycle points_recoverable evidence recommendation remediation; do
  miss="$(jq -r --arg k "$k" '.findings[] | select(has($k) | not) | .id // "?"' "$F")"
  [ -z "$miss" ] || fail "findings missing required field '$k': $(echo "$miss" | tr '\n' ' ')"
done

# 7c. severity enum.
badsev="$(jq -r '.findings[] | select(.severity | IN("critical","high","medium","low","info") | not) | .id' "$F")"
[ -z "$badsev" ] || fail "findings with invalid severity: $(echo "$badsev" | tr '\n' ' ')"

# 7d. status + lifecycle enums.
badstatus="$(jq -r '.findings[] | select(.status | IN("validated-live","configured","blocked") | not) | .id' "$F")"
[ -z "$badstatus" ] || fail "findings with invalid status: $(echo "$badstatus" | tr '\n' ' ')"
badlc="$(jq -r '.findings[] | select(.lifecycle | IN("new","unchanged","regressed","suppressed") | not) | .id' "$F")"
[ -z "$badlc" ] || fail "findings with invalid lifecycle: $(echo "$badlc" | tr '\n' ' ')"

# 7e. evidence present with command + observed.
noev="$(jq -r '.findings[] | select((.evidence | type != "array") or (.evidence | length == 0) or ((.evidence[0].command // "") == "") or ((.evidence[0].observed // "") == "")) | .id' "$F")"
[ -z "$noev" ] || fail "findings with empty/incomplete evidence: $(echo "$noev" | tr '\n' ' ')"

# 7f. remediation non-empty (schema marks it required). This is where the 3
#     empty-remediation findings (AWSOPT-002, SNTRY-020, ZD-015) trip.
norem="$(jq -r '.findings[] | select((.remediation // "") == "") | .id' "$F")"
[ -z "$norem" ] || fail "findings with empty 'remediation' (schema requires a pointer, or an explicit doc anchor): $(echo "$norem" | tr '\n' ' ')"

# 7f-corr. Correlation readiness: a non-info finding should name a concrete
#     resource in `affected` so the correlation engine can join it to findings
#     from other audits (it groups overlaps by shared `affected` service, and
#     detects cascades by shared-resource join). A finding with no `affected`
#     silently contributes no join key — correlation degrades but never sees it.
#     Advisory for info findings (observations may be account-scoped); required
#     for critical/high/medium/low so cross-stack correlation is not blinded.
noaff="$(jq -r '.findings[] | select(.severity != "info") | select((.affected | type != "array") or (.affected | length == 0)) | .id' "$F")"
[ -z "$noaff" ] || fail "findings with no concrete resource in 'affected' (correlation cannot join them across audits; name the affected service/resource): $(echo "$noaff" | tr '\n' ' ')"

# 7g. info findings must carry points_recoverable 0.
badpts="$(jq -r '.findings[] | select(.severity == "info" and (.points_recoverable // 0) != 0) | .id' "$F")"
[ -z "$badpts" ] || fail "info findings with non-zero points_recoverable (must be 0): $(echo "$badpts" | tr '\n' ' ')"

# 8. Version 2 evidence-aware scoring. The normalized checks[] ledger is the
#    score input. Blocked means unassessed, never failed. This section
#    recomputes every denominator, category score, the overall assessment
#    coverage, and the check-set fingerprint so authored arithmetic cannot
#    silently turn a denied or incomplete read into a readiness conclusion.
if [ "$sch" = "scoutflo-findings/v2" ]; then
  jq -e '
    (.checks | type == "array" and length > 0)
    and (.score.scoring_model == "assessed-only-v1")
    and (.score.check_set | type == "string" and length > 0)
    and (.score.assessment | type == "object")
    and (.score.state | IN("assessed","unassessed"))
  ' "$F" >/dev/null 2>&1 || fail "v2 requires a non-empty checks[] ledger plus score.state, scoring_model=assessed-only-v1, check_set, and score.assessment"

  badcheck="$(jq -r '
    .checks[]?
    | select(
        ((.id // "") | test("^[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}$") | not)
        or ((.category // "") | length == 0)
        or ((.result // "") | IN("pass","partial","fail","blocked","not-in-scope") | not)
        or (has("suppressed") and ((.suppressed | type) != "boolean"))
      )
    | .id // "?"' "$F")"
  [ -z "$badcheck" ] || fail "v2 checks with malformed id/category/result: $(echo "$badcheck" | tr '\n' ' ')"

  check_dupe="$(jq '[.checks[]?.id] | length - (unique | length)' "$F")"
  [ "$check_dupe" = "0" ] || fail "v2 checks[] contains $check_dupe duplicate check ID(s)"

  missing_reason="$(jq -r '.checks[]? | select(.result | IN("partial","blocked","not-in-scope")) | select(((.reason // "") | length) == 0) | .id' "$F")"
  [ -z "$missing_reason" ] || fail "v2 partial/blocked/not-in-scope checks missing reason: $(echo "$missing_reason" | tr '\n' ' ')"

  bad_suppressed_check="$(jq -r '
    .checks[]?
    | select(.suppressed == true)
    | select(
        ((.result | IN("partial","fail")) | not)
        or (((.suppression_reason // "") | length) == 0)
      )
    | .id' "$F")"
  [ -z "$bad_suppressed_check" ] || fail "v2 suppressed checks must retain a partial/fail result and a non-empty suppression_reason: $(echo "$bad_suppressed_check" | tr '\n' ' ')"

  unknown_category="$(jq -r '(.score.categories | map(.name)) as $cats | .checks[]? | select(.category as $c | ($cats | index($c)) == null) | .id + ":" + .category' "$F")"
  [ -z "$unknown_category" ] || fail "v2 checks reference scorecard categories that do not exist: $(echo "$unknown_category" | tr '\n' ' ')"

  empty_category="$(jq -r '(.checks | map(.category)) as $used | .score.categories[]? | select(.name as $n | ($used | index($n)) == null) | .name' "$F")"
  [ -z "$empty_category" ] || fail "v2 scorecard categories have no check-ledger rows: $(echo "$empty_category" | tr '\n' ' ')"

  # Each non-pass scored check needs a same-ID finding. A finding is the
  # explanation and remediation; the ledger row is the score input.
  missing_finding="$(jq -r '(.findings | map(.id)) as $ids | .checks[]? | select(.result | IN("partial","fail","blocked")) | select(.id as $id | ($ids | index($id)) == null) | .id' "$F")"
  [ -z "$missing_finding" ] || fail "v2 non-pass checks missing same-ID findings: $(echo "$missing_finding" | tr '\n' ' ')"

  # Referential integrity is bidirectional. A readiness finding explains one
  # non-pass ledger row. Deliberately non-scored findings (for example AWS cost
  # opportunities) must declare that scope explicitly and recover zero points.
  bad_scoring_scope="$(jq -r '.findings[]? | select((.scoring_scope // "") | IN("readiness","non-scored") | not) | .id' "$F")"
  [ -z "$bad_scoring_scope" ] || fail "v2 findings require scoring_scope=readiness or non-scored: $(echo "$bad_scoring_scope" | tr '\n' ' ')"

  orphan_finding="$(jq -r '(.checks | map(.id)) as $ids | .findings[]? | select(.scoring_scope == "readiness") | select(.id as $id | ($ids | index($id)) == null) | .id' "$F")"
  [ -z "$orphan_finding" ] || fail "v2 readiness findings missing same-ID checks[] rows: $(echo "$orphan_finding" | tr '\n' ' ')"

  bad_non_scored_finding="$(jq -r '
    (.checks | map(.id)) as $ids
    | .findings[]?
    | select(.scoring_scope == "non-scored")
    | select((.points_recoverable // -1) != 0 or (.id as $id | ($ids | index($id)) != null))
    | .id' "$F")"
  [ -z "$bad_non_scored_finding" ] || fail "v2 scoring_scope=non-scored findings must have points_recoverable=0 and no checks[] row: $(echo "$bad_non_scored_finding" | tr '\n' ' ')"

  finding_on_nonfinding_result="$(jq -r '
    (.checks | map({key:.id,value:.}) | from_entries) as $checks
    | .findings[]?
    | select(.scoring_scope == "readiness")
    | select(($checks[.id].result // "missing") | IN("pass","not-in-scope"))
    | .id' "$F")"
  [ -z "$finding_on_nonfinding_result" ] || fail "v2 findings may describe only partial/fail/blocked checks, not pass/not-in-scope rows: $(echo "$finding_on_nonfinding_result" | tr '\n' ' ')"

  bad_blocked_status="$(jq -r '(.findings | map({key:.id,value:.}) | from_entries) as $f | .checks[]? | select(.result=="blocked") | select(($f[.id].status // "") != "blocked" or (($f[.id].points_recoverable // -1) != 0)) | .id' "$F")"
  [ -z "$bad_blocked_status" ] || fail "v2 blocked checks require a status=blocked finding with points_recoverable=0: $(echo "$bad_blocked_status" | tr '\n' ' ')"

  bad_suppressed_finding="$(jq -r '
    (.findings | map({key:.id,value:.}) | from_entries) as $findings
    | .checks[]?
    | select(.suppressed == true)
    | select(
        (($findings[.id].lifecycle // "") != "suppressed")
        or (($findings[.id].points_recoverable // -1) != 0)
      )
    | .id' "$F")"
  [ -z "$bad_suppressed_finding" ] || fail "v2 suppressed checks require a same-ID lifecycle=suppressed finding with points_recoverable=0: $(echo "$bad_suppressed_finding" | tr '\n' ' ')"

  unsuppressed_ledger="$(jq -r '
    (.checks | map({key:.id,value:.}) | from_entries) as $checks
    | .findings[]?
    | select(.lifecycle == "suppressed")
    | select(($checks[.id] != null) and ($checks[.id].suppressed != true))
    | .id' "$F")"
  [ -z "$unsuppressed_ledger" ] || fail "v2 suppressed scored findings require suppressed=true on the same-ID checks[] row: $(echo "$unsuppressed_ledger" | tr '\n' ' ')"

  bad_lanes="$(jq -r '
    .findings[]?
    | select(
        (.report_lanes | type != "array")
        or ((.report_lanes | length) == 0)
        or ([.report_lanes[] | select(IN("general-audit","ai-sre-readiness") | not)] | length > 0)
        or ((.report_lanes | unique | length) != (.report_lanes | length))
      )
    | .id' "$F")"
  [ -z "$bad_lanes" ] || fail "v2 findings require unique report_lanes from general-audit/ai-sre-readiness: $(echo "$bad_lanes" | tr '\n' ' ')"

  bad_check_score="$(jq -r '
    (.score.excluded // [] | map(.name)) as $excluded
    | .score.categories[] as $cat
    | [.checks[] | select(.category == $cat.name)] as $rows
    | ($rows | map(select((.suppressed != true) and .result=="pass")) | length) as $pass
    | ($rows | map(select((.suppressed != true) and .result=="partial")) | length) as $partial
    | ($rows | map(select((.suppressed != true) and .result=="fail")) | length) as $failed
    | ($rows | map(select(.result=="blocked")) | length) as $blocked
    | ($rows | map(select(.suppressed==true)) | length) as $suppressed
    | ($rows | map(select(.result=="not-in-scope")) | length) as $nis
    | ($pass + $partial + $failed) as $assessed
    | (if $assessed == 0 then 0 else (((($pass * 2) + $partial) * 50 / $assessed) | floor) end) as $expected_score
    | select(
        (($cat.checks_passed // -1) != $pass)
        or (($cat.checks_partial // -1) != $partial)
        or (($cat.checks_failed // -1) != $failed)
        or (($cat.checks_blocked // -1) != $blocked)
        or (($cat.checks_suppressed // -1) != $suppressed)
        or (($cat.checks_not_in_scope // -1) != $nis)
        or (($cat.checks_total // -1) != $assessed)
        or (($cat.score // -1) != $expected_score)
        or (($assessed == 0) and (($excluded | index($cat.name)) == null))
        or (($assessed > 0) and (($excluded | index($cat.name)) != null))
      )
    | $cat.name' "$F")"
  [ -z "$bad_check_score" ] || fail "v2 category score/counts do not reconcile with checks[]: $(echo "$bad_check_score" | tr '\n' ' ')"

  read -r exp_applicable exp_assessed exp_scored exp_blocked exp_suppressed exp_nis exp_coverage <<EOF
$(jq -r '
  ([.checks[] | select(.result != "not-in-scope")] | length) as $app
  | ([.checks[] | select(.result | IN("pass","partial","fail"))] | length) as $assessed
  | ([.checks[] | select((.suppressed != true) and (.result | IN("pass","partial","fail")))] | length) as $scored
  | ([.checks[] | select(.result == "blocked")] | length) as $blocked
  | ([.checks[] | select(.suppressed == true)] | length) as $suppressed
  | ([.checks[] | select(.result == "not-in-scope")] | length) as $nis
  | (if $app == 0 then 0 else (($assessed * 100 / $app) | floor) end) as $coverage
  | "\($app) \($assessed) \($scored) \($blocked) \($suppressed) \($nis) \($coverage)"' "$F")
EOF
  read -r got_applicable got_assessed got_scored got_blocked got_suppressed got_nis got_coverage <<EOF
$(jq -r '.score.assessment | "\(.applicable_checks // -1) \(.assessed_checks // -1) \(.scored_checks // -1) \(.blocked_checks // -1) \(.suppressed_checks // -1) \(.not_in_scope_checks // -1) \(.coverage_percent // -1)"' "$F")
EOF
  [ "$got_applicable $got_assessed $got_scored $got_blocked $got_suppressed $got_nis $got_coverage" = "$exp_applicable $exp_assessed $exp_scored $exp_blocked $exp_suppressed $exp_nis $exp_coverage" ] \
    || fail "v2 score.assessment does not reconcile with checks[] (got $got_applicable/$got_assessed/$got_scored/$got_blocked/$got_suppressed/$got_nis/$got_coverage; expected $exp_applicable/$exp_assessed/$exp_scored/$exp_blocked/$exp_suppressed/$exp_nis/$exp_coverage)"

  if [ "$exp_scored" -eq 0 ]; then
    [ "$score_state" = "unassessed" ] || fail "v2 run with zero unsuppressed scored checks must use score.state=unassessed"
    [ "$overall" = "null" ] || fail "v2 unassessed run must use score.overall=null"
  else
    [ "$score_state" = "assessed" ] || fail "v2 run with assessed checks must use score.state=assessed"
    [ "$overall" != "null" ] && [ "$overall" != "invalid" ] || fail "v2 assessed run requires an integer score.overall"
  fi

  # The fingerprint folds category weights + the gate in, not just check id/category.
  # A pure re-weighting changes the scoring model, so a prior run is NOT score-comparable
  # and MUST produce a different check_set — otherwise the trend consumer renders a
  # fabricated score delta for an estate that did not change. (cksum-v2 bumps the format
  # so old id/category-only fingerprints never collide with a weighted one.)
  expected_check_set="$(jq -r '
    ( [ .checks[] | "chk\t" + .id + "\t" + .category ]
      + [ .score.categories[] | "cat\t" + .name + "\t" + (.weight|tostring) ]
      + [ "gate\t" + ((.score.gate // 85)|tostring) ]
    ) | sort | .[]' "$F" | LC_ALL=C cksum | awk '{print "cksum-v2:" $1 ":" $2}')"
  got_check_set="$(jq -r '.score.check_set // ""' "$F")"
  [ "$got_check_set" = "$expected_check_set" ] || fail "v2 score.check_set '$got_check_set' does not match ledger fingerprint '$expected_check_set'"

  if [ "$e2e" = "true" ] && [ "$exp_coverage" -ne 100 ]; then
    fail "end_to_end=true but v2 assessment coverage is ${exp_coverage}% (must be 100%)"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "FINDINGS-OK: $F reconciles with the scoring model and schema (overall=$overall)"
else
  echo "FINDINGS-DRIFT: fix the violations above and re-emit; see report-standard/severity-and-scoring.md + findings-schema.md"
  exit 1
fi
