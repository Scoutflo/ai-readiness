#!/bin/sh
# report-conformance.sh — validate a generated report.md against the canonical
# skeleton in report-standard/report-template.md. This is the gate the audit
# skills run on their OWN emitted report.md before declaring done, so rendered
# output cannot silently drift from the standard the way it has in the past.
#
# Usage: report-standard/check-report.sh path/to/report.md
# Exit 0 = conforms (prints REPORT-OK). Exit 1 = drift (prints each violation).
#
# It checks structure, never content: the required header table, the canonical
# bold Score line, and the required section headers in the required order. It
# does not judge scores or findings — only that the shape matches the standard.
set -eu

REPORT="${1:?usage: report-conformance.sh path/to/report.md}"
[ -f "$REPORT" ] || { echo "REPORT-FAIL: no such file: $REPORT"; exit 1; }

FAIL=0
fail() { echo "REPORT-FAIL: $1"; FAIL=1; }

# 1. Title line (# <Audit name>: <target>) must be the first non-empty line.
first="$(grep -m1 -E '.' "$REPORT" || true)"
case "$first" in
  '# '*) : ;;
  *) fail "first content line must be a '# ' H1 title, found: ${first%%$(printf '\n')*}" ;;
esac

# 2. Header table: the four required rows must all be present.
for row in 'Target' 'Date' 'Toolkit version' 'Skill'; do
  grep -qE "^\| *${row} *\|" "$REPORT" || fail "header table missing required '| ${row} |' row"
done

# 3. Canonical Score line: '**Score: <n>/100**' (bold, exact prefix). This is the
#    exact drift seen in the wild ('Overall score: 42/100' is a violation).
grep -qE '^\*\*Score: [0-9]+/100\*\*' "$REPORT" \
  || fail "missing canonical '**Score: <n>/100**' line in the executive summary (a plain 'Overall score:' line does not conform)"

# 4. Required section headers, in order. Optional sections (Suppressed findings,
#    Coverage matrix, Scoutflo Topology Readiness, Delta) are not required to be
#    present, but the core spine must be, and in this relative order.
REQUIRED='## Executive summary
## Scorecard
## Findings
## Next safe actions
## Evidence appendix'

prev_line=0
echo "$REQUIRED" | while IFS= read -r sec; do
  ln="$(grep -nxF "$sec" "$REPORT" | head -1 | cut -d: -f1 || true)"
  if [ -z "$ln" ]; then
    echo "REPORT-FAIL: missing required section header: '$sec'"
    exit 1
  fi
  if [ "$ln" -lt "$prev_line" ]; then
    echo "REPORT-FAIL: section '$sec' is out of order (line $ln before previous section at line $prev_line)"
    exit 1
  fi
  prev_line="$ln"
done || FAIL=1

if [ "$FAIL" -eq 0 ]; then
  echo "REPORT-OK: $REPORT conforms to report-template.md"
else
  echo "REPORT-DRIFT: fix the violations above and re-emit; see report-standard/report-template.md"
  exit 1
fi
