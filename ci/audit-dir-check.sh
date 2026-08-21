#!/bin/sh
# audit-dir-check.sh — every runnable command block that DECLARES an output path
# under scoutflo-audits must resolve it via ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits},
# never a hardcoded literal.
#
# Why this exists: the report-standard output root is relocatable through the
# SCOUTFLO_AUDIT_DIR environment variable. A skill whose command block hardcodes
# `OUT="./scoutflo-audits/..."` silently ignores that override, so one audit's
# reports land in a different tree than every other audit's — history ledgers,
# the audit-all roll-up, and the correlation engine then miss that provider's
# runs entirely. This gate makes the drift a red CI check.
#
# Scope is deliberately NARROW to avoid false positives: it inspects only
# ASSIGNMENT lines (`VAR=...`, optionally prefixed export/local/readonly) inside
# fenced ``` command blocks of skills/*/SKILL.md and skills/*/references/*.md.
# Prose mentions, comments, and echo/printf messages may say `./scoutflo-audits`
# freely — a human-readable path in a sentence is not a declaration. Tilde-fenced
# (~~~) blocks are documentation templates here, not runnable commands, and are
# not inspected.
#
# Read-only. POSIX sh + awk.
set -eu
DIR="${1:-.}"
FAIL=0
q="'"

scan() {
  # Prints one line per violation: <file>:<line>: <content>
  awk -v q="$q" '
    /^[[:space:]]*```/ { inblock = !inblock; next }
    inblock {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/) next                     # comment lines are allowed
      if (line !~ /^(export |local |readonly )?[A-Za-z_][A-Za-z0-9_]*=/) next
      val = line
      sub(/^(export |local |readonly )?[A-Za-z_][A-Za-z0-9_]*=/, "", val)
      c = substr(val, 1, 1)
      if (c == "\"" || c == q) val = substr(val, 2)
      # A compliant value starts with ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits};
      # a violation starts with the literal path itself.
      pat = "^(\\./)?scoutflo-audits(/|\"|" q "|[[:space:]]|$)"
      if (val ~ pat) print FILENAME ":" FNR ": " $0
    }
  ' "$1"
}

for f in "$DIR"/skills/*/SKILL.md "$DIR"/skills/*/references/*.md; do
  [ -f "$f" ] || continue
  HITS="$(scan "$f" || true)"
  if [ -n "$HITS" ]; then
    echo "AUDIT-DIR: $f hardcodes a scoutflo-audits path in a runnable assignment — resolve via \${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits} instead:"
    printf '%s\n' "$HITS"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "AUDIT-DIR CHECK FAILED"
  exit 1
fi
echo "AUDIT-DIR-OK (every runnable scoutflo-audits path declaration resolves via SCOUTFLO_AUDIT_DIR)"
