#!/bin/sh
# redaction-parity-check.sh — every audit-* (except audit-all) must carry the
# secret-redaction discipline so no audit can silently leak a secret value into
# its terminal output, evidence, report, or brief.
#
# Why this exists: redaction was applied inconsistently — some audits redacted
# at capture, some relied only on audit-all's Phase 3.7 roll-up pass (which does
# NOT cover a single audit run standalone), and there was no gate proving a given
# audit even carries the rule. This makes the shared discipline
# (report-standard/secret-redaction.md) a mechanical requirement.
#
# Passing bar: the SKILL.md states the no-secret-values discipline — a line
# matching the redaction vocabulary (redact / never print|write a secret /
# strip webhook / capture ... key names only). This is deliberately a discipline
# check (does the skill commit to the rule?), complementing ci/leak-scan.sh
# (which catches secrets committed to the repo) and the runtime redact_file
# filter (which masks written artifacts).
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue   # orchestrator: runs the Phase 3.7 pass itself
  f="${d}SKILL.md"
  [ -f "$f" ] || continue

  if ! grep -qiE 'redact|strip[^.]*(webhook|token|secret|url)|never (print|write|log)[^.]*(secret|token|webhook|url|key|auth)|capture[^.]*(key names|names only)|no secrets? (in|reach)' "$f"; then
    echo "SECRET-REDACTION: ${name} states no secret-redaction discipline — it could leak a secret value into output; add the shared discipline from report-standard/secret-redaction.md"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "SECRET-REDACTION CHECK FAILED"
  exit 1
fi
echo "SECRET-REDACTION-OK (every audit-* carries the secret-redaction discipline)"
