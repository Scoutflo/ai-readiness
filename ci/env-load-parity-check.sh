#!/bin/sh
# env-load-parity-check.sh — every audit-* (except audit-all) must SOURCE the
# home-anchored secret store ~/.scoutflo/env in its doctor gate, the same way
# /scoutflo:doctor does.
#
# Why this exists: doctor.sh sources ~/.scoutflo/env before its checks, but the
# audit skills did not — they only presence-checked the *_env variable. So a
# token added to ~/.scoutflo/env mid-session (by connect) showed GREEN in
# /scoutflo:doctor (which sourced the file) but "not set" in the audit run (a
# fresh shell that never sourced it, and whose login profile was read at launch
# before the token was added). Doctor said connected; the audit said not set.
# This gate makes sourcing the store a mechanical requirement across every audit,
# so doctor and the audits always agree on what credentials are available.
#
# Passing bar: the SKILL.md sources the store in a command block — a line that
# reads (dot-sources) ~/.scoutflo/env, e.g.
#   [ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env" || true
# The check is transport-agnostic about the exact guard/quoting; it requires a
# real `.`/`source` of a path ending in scoutflo/env.
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue   # orchestrator: delegates to each audit, which sources it
  f="${d}SKILL.md"
  [ -f "$f" ] || continue

  # Require an actual source of a *scoutflo/env path: `.` or `source`, then the path.
  if ! grep -qE '(^|[^[:alnum:]_])(\.|source)[[:space:]]+"?[^"]*scoutflo/env' "$f"; then
    echo "ENV-LOAD: ${name} does not source ~/.scoutflo/env in its doctor gate — a token added to the store mid-session would show green in doctor but 'not set' here; add: [ -f \"\$HOME/.scoutflo/env\" ] && . \"\$HOME/.scoutflo/env\" || true"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "ENV-LOAD CHECK FAILED"
  exit 1
fi
echo "ENV-LOAD-OK (every audit-* sources the ~/.scoutflo/env secret store, matching doctor)"
