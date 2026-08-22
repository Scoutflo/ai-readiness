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

  # Require the LAYERED secret-store resolver (override -> project-local -> home)
  # plus an actual dot-source of the resolved path. The layered form is what makes
  # the plugin work on sandboxed surfaces (Desktop app) where $HOME is not shell-
  # writable: connect can fall back to ./.scoutflo and every audit still finds it.
  if ! grep -qF 'SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"' "$f" \
     || ! grep -qF '[ -f "./.scoutflo/env" ]' "$f" \
     || ! grep -qF '$HOME/.scoutflo/env' "$f" \
     || ! grep -qE '(^|[^[:alnum:]_])\.[[:space:]]+"\$SCOUTFLO_ENV"' "$f"; then
    echo "ENV-LOAD: ${name} does not use the layered secret-store resolver in its doctor gate — add the canonical two lines: SCOUTFLO_ENV=\"\${SCOUTFLO_ENV_FILE:-}\"; [ -n ... ] || { if [ -f \"./.scoutflo/env\" ]; then ... else ...\$HOME/.scoutflo/env...; fi; } then: [ -f \"\$SCOUTFLO_ENV\" ] && . \"\$SCOUTFLO_ENV\" || true"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "ENV-LOAD CHECK FAILED"
  exit 1
fi
echo "ENV-LOAD-OK (every audit-* uses the layered secret-store resolver, matching doctor)"
