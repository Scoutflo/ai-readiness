#!/bin/sh
# Proves report conformance keeps assessed and fully blocked v2 runs distinct.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/report-standard/check-report.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

write_report() {
  headline="$1"
  if [ -f "$WORK/findings.json" ] \
     && [ "$(jq -r '.schema // ""' "$WORK/findings.json")" = "scoutflo-findings/v2" ]; then
    lane_block="$(sh "$ROOT/report-standard/render-report-viz.sh" lanes "$WORK/findings.json")"
  else
    lane_block='## Findings by purpose

No classified findings.'
  fi
  cat > "$WORK/report.md" <<EOF
# Fixture audit: fixture

| | |
| --- | --- |
| Target | fixture |
| Date | 2026-08-28 (UTC) |
| Toolkit version | 0.1.153 |
| Skill | audit-fixture |

## At a glance

$headline

## Executive summary

$headline

## Scorecard

No assessed categories.

$lane_block

## Findings

No verified defects.

## Next safe actions

Unlock evidence if required.

## Evidence appendix

No evidence entries.
EOF
  : > "$WORK/report.html"
}

expect_ok() { sh "$CHECK" "$WORK/report.md" >/dev/null 2>&1 || fail "$1"; }
expect_fail() { sh "$CHECK" "$WORK/report.md" >/dev/null 2>&1 && fail "$1"; return 0; }

echo "=== check-report self-test ==="

echo "Test 1: assessed report requires and accepts a numeric score"
printf '%s\n' '{"score":{"state":"assessed","overall":72,"end_to_end":false}}' > "$WORK/findings.json"
write_report '**Score: 72/100**'
expect_ok "assessed report with canonical score was rejected"
echo "PASS"

echo "Test 2: fully blocked v2 report accepts readiness unassessed"
printf '%s\n' '{"schema":"scoutflo-findings/v2","score":{"state":"unassessed","overall":null,"end_to_end":false}}' > "$WORK/findings.json"
write_report '**Readiness: unassessed**'
expect_ok "unassessed report with canonical headline was rejected"
echo "PASS"

echo "Test 3: fully blocked v2 report rejects a fabricated 0/100 score"
write_report '**Score: 0/100**'
expect_fail "unassessed report accepted a numeric score"
echo "PASS"

echo "Test 4: assessed report rejects an unassessed headline"
printf '%s\n' '{"score":{"state":"assessed","overall":72,"end_to_end":false}}' > "$WORK/findings.json"
write_report '**Readiness: unassessed**'
expect_fail "assessed report omitted its numeric score"
echo "PASS"

echo "Test 5: a v2 report without the findings-by-purpose section is REJECTED"
printf '%s\n' '{"schema":"scoutflo-findings/v2","score":{"state":"assessed","overall":72,"end_to_end":false}}' > "$WORK/findings.json"
write_report '**Score: 72/100**'
sed '/^## Findings by purpose$/,/^## Findings$/{ /^## Findings$/!d; }' "$WORK/report.md" > "$WORK/report.tmp"
mv "$WORK/report.tmp" "$WORK/report.md"
expect_fail "v2 report omitted its findings-by-purpose section"
echo "PASS"

echo "Test 6: a stale hand-edited v2 findings-by-purpose section is REJECTED"
printf '%s\n' '{"schema":"scoutflo-findings/v2","score":{"state":"assessed","overall":72,"end_to_end":false},"findings":[]}' > "$WORK/findings.json"
write_report '**Score: 72/100**'
sed 's/_No findings classified in this lane\._/_Stale hand-edited lane._/' "$WORK/report.md" > "$WORK/report.tmp"
mv "$WORK/report.tmp" "$WORK/report.md"
expect_fail "v2 report accepted lane content that drifted from findings.json"
echo "PASS"

echo
echo "=== check-report self-test passed ==="
