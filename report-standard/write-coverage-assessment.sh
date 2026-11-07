#!/bin/sh
# Read the actual selected audit queue; never infer completeness from files that happened to finish.
set -eu
PLAN="${1:?usage: write-coverage-assessment.sh run-plan.json}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
umask 077; mkdir -p "$OUT"
# A failed replacement must not leave yesterday's successful queue authoritative.
INVALID=$(mktemp "$OUT/.coverage-plan.XXXXXX")
printf '%s\n' '{"schema":"scoutflo-coverage-assessment/v1","status":"blocked","reason":"selected-run-plan-not-validated","expected_targets":[]}' > "$INVALID"
mv "$INVALID" "$OUT/coverage-assessment.json"
[ "$(basename -- "$PLAN")" = run-plan.json ] && [ "$(CDPATH= cd -- "$(dirname -- "$PLAN")" && pwd)" = "$(CDPATH= cd -- "$OUT" && pwd)" ] || {
  echo 'COVERAGE-PLAN-FAIL: use the current audit root run-plan.json' >&2; exit 1;
}
DAY=$(jq -er '.audit_date' "$PLAN") || exit 1
TMP=$(mktemp "$OUT/.coverage-plan.XXXXXX")
trap 'rm -f "$TMP"' EXIT HUP INT TERM
python3 "$ROOT/report-standard/run-selection.py" coverage-plan "$OUT" "$DAY" > "$TMP"
mv "$TMP" "$OUT/coverage-assessment.json"
echo 'COVERAGE-PLAN-OK: expected targets recorded before collecting results'
