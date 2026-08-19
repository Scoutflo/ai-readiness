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
REQUIRED='## At a glance
## Executive summary
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

# 5. Findings format: when a finding is rendered, it must use the human-first
#    What / Where / Why / How / Done-when shape (a demoted 'ref:' ID, not a table row).
findings_body="$(awk '/^## Findings$/{f=1; next} /^## /{f=0} f' "$REPORT")"
if printf '%s\n' "$findings_body" | grep -qE '[A-Z]{2,6}-[0-9]{2,4}'; then
  printf '%s\n' "$findings_body" | grep -q "What's wrong" \
    || fail "Findings are present but not in the What's wrong / Where / Why it matters / How to fix shape (see report-template.md); the old ID|Severity|Title table no longer conforms"
  printf '%s\n' "$findings_body" | grep -q 'Done when' \
    || fail "Findings lack a '**Done when:**' verification line; every rendered finding needs one (see report-template.md)"
fi

# 6. Topology Readiness rendering: plain-English column headers (raw T1-T6
#    codes must not be table headers) and confidence carrying its /10 scale.
topo_body="$(awk '/^## Scoutflo Topology Readiness$/{f=1; next} /^## /{f=0} f' "$REPORT")"
if printf '%s\n' "$topo_body" | grep -q '^| Service |'; then
  printf '%s\n' "$topo_body" | grep -E '^\| Service \|' | grep -qE 'T[1-6][^0-9]' \
    && fail "Topology Readiness table uses raw T1-T6 codes as column headers; use the plain-English check names from topology-readiness.md (codes belong in the legend line only)"
  printf '%s\n' "$topo_body" | awk -F'|' '/^\| [a-z]/ {v=$(NF-2); gsub(/ /,"",v); if (v ~ /^[0-9]+$/ && v !~ /\//) found=1} END {exit !found}' \
    && fail "Topology Readiness confidence column shows a bare number; render the scale as n/10 (see topology-readiness.md)"

  # 7. No internal jargon or file paths leaking into customer-facing prose. The
  #    legend line ("Checks T1-T6 per...") is the one sanctioned exception and
  #    is excluded before this scan; everything else in the section is prose a
  #    customer reads and must be plain language (see topology-readiness.md's
  #    "Internal identifiers — never customer-facing" section).
  topo_prose="$(printf '%s\n' "$topo_body" | grep -v '^<sub>Checks T1-T6')"
  printf '%s\n' "$topo_prose" | grep -E 'sync-ready|sync-readiness|MONITORED_BY|SENDS_METRICS_TO|SENDS_LOGS_TO|SENDS_TRACES_TO|DEPLOYED_AS|topology-export\.json|topology\.md|correlation attribute' \
    && fail "Topology Readiness prose leaks internal jargon or file names (sync-ready, MONITORED_BY-style edge names, topology-export.json, etc.) into customer-facing text; rewrite in plain language per topology-readiness.md"
fi

# 7. Standalone HTML dashboard sibling. Generated by render-report-viz.sh from the
#    same findings.json (see report-template.md). A soft check: warn if it is
#    missing so a run that skipped it is nudged, without failing a standalone
#    report.md validation (the '## At a glance' required section above is the hard
#    guarantee that the visuals were rendered).
REPORT_DIR="$(dirname "$REPORT")"
[ -f "$REPORT_DIR/report.html" ] \
  || echo "REPORT-WARN: no report.html next to $REPORT — run render-report-viz.sh html to emit the standalone dashboard (see report-template.md)"

# 8. Inventory conformance. When the audit emitted an inventory.json sibling
#    (scoutflo-inventory/v1), reconcile it and require the ## Inventory section,
#    so the catalog cannot silently drift or go missing. Skipped for reports that
#    carry no inventory (the audit-all combined report, audit-cost).
INV="$REPORT_DIR/inventory.json"
if [ -f "$INV" ]; then
  grep -qxF '## Inventory' "$REPORT" \
    || fail "inventory.json exists but report.md has no '## Inventory' section (render it with render-report-viz.sh inventory)"
  if command -v jq >/dev/null 2>&1; then
    jq -e '.schema == "scoutflo-inventory/v1"
           and (.items | type == "array")
           and (.counts.total == (.items | length))
           and (([.items[].kind] | group_by(.) | map({(.[0]): length}) | add // {}) == (.counts.by_kind // {}))' \
      "$INV" >/dev/null 2>&1 \
      || fail "inventory.json does not reconcile (needs schema scoutflo-inventory/v1, counts.total == items length, and counts.by_kind == the kind histogram); regenerate it, never hand-edit"
  else
    echo "REPORT-WARN: jq not available; skipped inventory.json reconciliation for $INV"
  fi
fi

if [ "$FAIL" -eq 0 ]; then
  echo "REPORT-OK: $REPORT conforms to report-template.md"
else
  echo "REPORT-DRIFT: fix the violations above and re-emit; see report-standard/report-template.md"
  exit 1
fi
