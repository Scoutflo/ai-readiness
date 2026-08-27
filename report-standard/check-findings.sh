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
[ "$sch" = "scoutflo-findings/v1" ] || fail "schema is '$sch', expected 'scoutflo-findings/v1'"

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

# 3. Category weights (included + excluded) must sum to 100.
wsum="$(jq '([.score.categories[]?.weight] + [.score.excluded[]?.weight // 0]) | add // 0' "$F")"
[ "$wsum" = "100" ] || fail "category weights (incl+excl) sum to $wsum, expected 100"

# 4. overall must equal the weight-normalized sum over INCLUDED categories,
#    rounded down — excluding any category whose name is in score.excluded
#    (the standard's renormalization rule). Tolerance 1 for rounding.
# Guard the arithmetic: without this, a malformed score.overall (missing, string,
# fractional) or an empty/non-array score.categories makes the reconciliation
# below misbehave with a cryptic jq error instead of a clear schema failure.
# Set `overall` numerically up front (a non-number becomes -1) so every later
# integer comparison (the delta below, the end_to_end gate) stays safe even when
# the file is malformed — a string overall must never reach shell arithmetic.
overall="$(jq -r '(.score.overall | if type=="number" then . else -1 end)' "$F")"
if jq -e '
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
  fail "score.overall must be an integer number and score.categories a non-empty array (got overall=$(jq -c '.score.overall' "$F" 2>/dev/null || echo missing), categories=$(jq -c '.score.categories | length' "$F" 2>/dev/null || echo missing))"
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
  { [ "$overall" -ge 85 ] && [ "$nexcl" -eq 0 ]; } || fail "end_to_end=true but overall=$overall (<85) or excluded categories present ($nexcl); the gate forbids this"
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

if [ "$FAIL" -eq 0 ]; then
  echo "FINDINGS-OK: $F reconciles with the scoring model and schema (overall=$overall)"
else
  echo "FINDINGS-DRIFT: fix the violations above and re-emit; see report-standard/severity-and-scoring.md + findings-schema.md"
  exit 1
fi
