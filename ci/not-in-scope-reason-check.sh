#!/bin/sh
# not-in-scope-reason-check.sh
#
# A `not-in-scope` checks[] row leaves BOTH the readiness and assessment-coverage
# denominators, so `report-standard/check-findings.sh` requires it to declare
# `not_in_scope_reason` from a closed four-value set (see
# report-standard/not-in-scope-reasons.md, CONTRACTS C23).
#
# That makes the instruction and the validator a matched pair, and this gate keeps
# them matched. When the field was introduced, seventeen SKILL.md files still told
# their audit to "record them not-in-scope with the reason" — the field-less form.
# An audit that followed its own skill emitted a row the validator rejects, and
# check-findings.sh fails the WHOLE findings document: an audit that passed
# yesterday would produce no output at all. Prose and validator drifting apart is
# the IMP-012 class, one layer up.
#
# Two rules:
#   1. A skill that authors a scoutflo-findings/v2 check ledger (it carries the
#      "Emit one `checks[]` row" contract) and mentions a `not-in-scope` row must
#      also mention `not_in_scope_reason`.
#   2. Every JSON example anywhere in report-standard/ and skills/ that sets
#      "result": "not-in-scope" must carry "not_in_scope_reason" in the same
#      object — the canonical schema example is the most-copied shape in the repo,
#      and it shipped violating the rule the same file introduced.
#
# Read-only. POSIX sh + POSIX awk only (no GNU extensions).
set -eu
DIR="${1:-.}"
FAIL=0

# --- rule 1: emission contracts -----------------------------------------------
for f in "$DIR"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  grep -q 'Emit one `checks\[\]` row' "$f" || continue       # not a v2 ledger author
  grep -q 'not-in-scope' "$f" || continue                    # never mentions the verdict
  if ! grep -q 'not_in_scope_reason' "$f"; then
    echo "NOT-IN-SCOPE-REASON-FAIL: $f authors a scoutflo-findings/v2 check ledger and instructs a 'not-in-scope' row, but never names not_in_scope_reason — an audit following this skill would emit a row check-findings.sh rejects, failing its whole findings.json." >&2
    FAIL=1
  fi
done

# --- rule 2: JSON examples ----------------------------------------------------
# Scan fenced JSON-ish examples for an object that sets result: "not-in-scope"
# without not_in_scope_reason. Objects here are written one-per-line in this repo's
# examples (the check ledger rows), so a line-scoped test is the honest match; a
# multi-line object is reported by the same rule only if the keys share a line.
for f in $(find "$DIR/report-standard" "$DIR/skills" -name '*.md' 2>/dev/null | sort); do
  [ -f "$f" ] || continue
  bad="$(awk '
    /"result"[[:space:]]*:[[:space:]]*"not-in-scope"/ {
      if ($0 !~ /not_in_scope_reason/) print FILENAME ":" FNR
    }' "$f" 2>/dev/null || true)"
  if [ -n "$bad" ]; then
    echo "$bad" | while IFS= read -r loc; do
      [ -n "$loc" ] || continue
      echo "NOT-IN-SCOPE-REASON-FAIL: $loc sets \"result\": \"not-in-scope\" with no \"not_in_scope_reason\" — this example is copied into real audits and would fail check-findings.sh." >&2
    done
    FAIL=1
  fi
done

[ "$FAIL" -eq 0 ] || exit 1
echo "NOT-IN-SCOPE-REASON-OK (every v2 ledger author names not_in_scope_reason; every not-in-scope example carries one)"
