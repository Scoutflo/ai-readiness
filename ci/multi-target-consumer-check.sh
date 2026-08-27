#!/bin/sh
# multi-target-consumer-check.sh — the sibling PRODUCER gate
# (multi-target-parity-check.sh) proves every own-block audit WRITES per-target
# output nested by a resolved <PREFIX>_SEG segment. This gate proves the three
# shared CONSUMERS READ that nested output: each must glob BOTH the one-level
# <target>/<date>/ AND the two-level <integration>/<label>/<date>/ layouts, or a
# labeled multi-target run (3 HyperDX instances, N Azure subscriptions) and the
# always-nesting single-block audits (signoz/<host>/, kubernetes/<context>/) go
# silently invisible to correlation, the cost roll-up, or the audit-all visuals.
#
# It asserts each consumer contains a two-level "*/*/" glob for the artifact it
# aggregates. The producers already resolve targets via toolkit-targets.sh and
# nest their output; this closes the read side so a future edit that drops the
# two-level glob from a consumer fails the build.
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0

# consumer <relative-path> <artifact-basename-regex>
consumer() {
  cc_rel="$1"
  cc_f="$DIR/$1"
  cc_art="$2"
  cc_disp="$(printf '%s' "$cc_art" | tr -d '\\')"   # plain name for messages
  if [ ! -f "$cc_f" ]; then
    echo "MULTI-TARGET-CONSUMER: expected shared consumer not found: ${cc_rel}"
    FAIL=1
    return
  fi
  # A two-level glob is "*/*/" somewhere ahead of the artifact on the same line
  # (e.g. "$DIR"/*/*/"$date"/findings.json). The one-level "*/"<date>/ form has
  # only a single "*/" and does not match, so a consumer that dropped the
  # two-level layout fails here.
  if ! grep -Eq '\*/\*/.*'"$cc_art" "$cc_f"; then
    echo "MULTI-TARGET-CONSUMER: ${cc_rel} has no two-level (*/*/) glob for ${cc_disp} — a labeled multi-target run (<integration>/<label>/<date>/) and the always-nesting single-block audits would be invisible to it; add the two-level glob alongside the one-level one (see the sibling producer gate multi-target-parity-check.sh)"
    FAIL=1
  fi
}

# correlation-engine and cost-analysis aggregate findings.json; render-report-viz
# aggregates findings.json (rollup) and inventory.json (inventory-rollup).
consumer "skills/correlation-engine/lib/correlation-engine.sh" 'findings\.json'
consumer "skills/correlation-engine/lib/correlation-engine.sh" 'inventory\.json'
consumer "skills/cost-analysis/lib/cost-analysis.sh"           'findings\.json'
consumer "report-standard/render-report-viz.sh"                'findings\.json'
consumer "report-standard/render-report-viz.sh"                'inventory\.json'

if [ "$FAIL" -ne 0 ]; then
  echo "MULTI-TARGET-CONSUMER CHECK FAILED"
  exit 1
fi
echo "MULTI-TARGET-CONSUMER-OK (correlation-engine, cost-analysis, and render-report-viz all glob the two-level <integration>/<label>/<date>/ layout)"
