#!/bin/sh
# not-in-scope-reason-check.sh
#
# A `not-in-scope` checks[] row leaves BOTH the readiness and assessment-coverage
# denominators, so `report-standard/check-findings.sh` requires it to declare
# `not_in_scope_reason` from a closed four-value set (see
# report-standard/not-in-scope-reasons.md, CONTRACTS C23).
#
# That makes the instruction and the validator a matched pair, and this gate keeps
# them matched. When the field was introduced, nineteen SKILL.md files still told
# their audit to "record them not-in-scope with the reason" — the field-less form.
# An audit that followed its own skill emitted a row the validator rejects, and
# check-findings.sh fails the WHOLE findings document: an audit that passed
# yesterday would produce no output at all. Prose and validator drifting apart is
# the IMP-012 class, one layer up.
#
# Two rules:
#   1. A skill that authors a scoutflo-findings/v2 check ledger must name the field
#      ON ITS EMISSION-CONTRACT LINE (the "Emit one `checks[]` row" sentence). That
#      line is what the audit reads when deciding which fields to write, so a
#      file-scoped search would false-PASS on a mention anywhere else — which it
#      did: two skills kept the field-less business-context sentence while a
#      mention elsewhere in the file satisfied the gate.
#   2. A JSON object in a fenced block that sets "result": "not-in-scope" must carry
#      "not_in_scope_reason" IN THE SAME OBJECT. Object-scoped, not line-scoped, so
#      the canonical pretty-printed shape is allowed; and fence-scoped, so prose
#      that merely quotes the literal is not a violation.
#
# KNOWN LIMIT, stated rather than implied: rule 1 covers the emission contract, not
# every per-check `not-in-scope` decision written in a skill's `references/*.md`.
# Those are prose instructions this gate does not parse. It guarantees the contract
# each audit reads before writing findings.json; it does not guarantee every
# sentence in the repo.
#
# Read-only. POSIX sh + POSIX awk only (no GNU extensions).
set -eu
DIR="${1:-.}"
FAIL=0
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

# --- rule 1: the emission contract line ---------------------------------------
for f in "$DIR"/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  grep -q 'Emit one `checks\[\]` row' "$f" || continue       # not a v2 ledger author
  if ! grep 'Emit one `checks\[\]` row' "$f" | grep -q 'not_in_scope_reason'; then
    echo "NOT-IN-SCOPE-REASON-FAIL: $f authors a scoutflo-findings/v2 check ledger, but its \"Emit one \`checks[]\` row\" contract never names not_in_scope_reason — an audit following this skill would emit a not-in-scope row that check-findings.sh rejects, failing its whole findings.json." >&2
    FAIL=1
  fi
done

# --- rule 2: JSON examples, object-scoped and fence-scoped --------------------
# Track fenced blocks; inside one, buffer each brace-balanced object and test the
# buffer. Prose outside a fence is never a violation, and a correct multi-line
# object passes because the sibling key is found anywhere in the same object.
find "$DIR/report-standard" "$DIR/skills" -name '*.md' 2>/dev/null | sort > "$TMP" || true
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  bad="$(awk '
    /^[[:space:]]*```/ { infence = !infence; depth=0; buf=""; next }
    !infence { next }
    {
      line = $0
      # Track brace depth across the object, accumulating its text.
      n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
      if (depth == 0 && n > 0) { buf = ""; start = FNR }
      if (depth > 0 || n > 0) buf = buf " " $0
      depth += n - m
      if (depth <= 0 && buf != "") {
        if (buf ~ /"result"[[:space:]]*:[[:space:]]*"not-in-scope"/ && buf !~ /not_in_scope_reason/)
          print FILENAME ":" start
        buf = ""; depth = 0
      }
    }' "$f" 2>/dev/null || true)"
  if [ -n "$bad" ]; then
    echo "$bad" >> "$TMP.bad"
    FAIL=1
  fi
done < "$TMP"
if [ -f "$TMP.bad" ]; then
  while IFS= read -r loc; do
    [ -n "$loc" ] || continue
    echo "NOT-IN-SCOPE-REASON-FAIL: the JSON object starting at $loc sets \"result\": \"not-in-scope\" with no \"not_in_scope_reason\" — this example is copied into real audits and would fail check-findings.sh." >&2
  done < "$TMP.bad"
  rm -f "$TMP.bad"
fi

[ "$FAIL" -eq 0 ] || exit 1
echo "NOT-IN-SCOPE-REASON-OK (every v2 emission contract names not_in_scope_reason; every fenced not-in-scope object carries one)"
