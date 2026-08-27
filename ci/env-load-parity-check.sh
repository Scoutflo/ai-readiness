#!/bin/sh
# env-load-parity-check.sh — every audit-* (except audit-all) AND doctor.sh must
# SOURCE the home-anchored secret store ~/.scoutflo/env in its doctor gate, using the
# SAME layered resolver, so /scoutflo:doctor and the audits never diverge on where the
# store lives (a hardcoded $HOME-only path in doctor while the audits use the layered
# resolver is a real doctor<->audit asymmetry on sandboxed/project-local surfaces — C13).
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

# check_layered <file> <label>: assert the LAYERED secret-store resolver (override ->
# project-local -> home) plus an actual dot-source of the resolved path. The layered form
# is what makes the plugin work on sandboxed surfaces (Desktop app) where $HOME is not
# shell-writable: connect can fall back to ./.scoutflo and every reader still finds it.
# Shared by doctor.sh and every audit-* SKILL.md so the two can never diverge.
check_layered() {
  cl_f="$1"; cl_name="$2"
  [ -f "$cl_f" ] || return 0
  if ! grep -qF 'SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"' "$cl_f" \
     || ! grep -qF '[ -f "./.scoutflo/env" ]' "$cl_f" \
     || ! grep -qF '$HOME/.scoutflo/env' "$cl_f" \
     || ! grep -qE '(^|[^[:alnum:]_])\.[[:space:]]+"\$SCOUTFLO_ENV"' "$cl_f"; then
    echo "ENV-LOAD: ${cl_name} does not use the layered secret-store resolver in its doctor gate — add the canonical two lines: SCOUTFLO_ENV=\"\${SCOUTFLO_ENV_FILE:-}\"; [ -n ... ] || { if [ -f \"./.scoutflo/env\" ]; then ... else ...\$HOME/.scoutflo/env...; fi; } then: [ -f \"\$SCOUTFLO_ENV\" ] && . \"\$SCOUTFLO_ENV\" || true"
    FAIL=1
  fi
}

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  [ "$name" = "audit-all" ] && continue   # orchestrator: delegates to each audit, which sources it
  check_layered "${d}SKILL.md" "$name"
done

# doctor.sh must resolve the store IDENTICALLY to the audits (C13). doctor sources the
# store in shell, not a fenced SKILL.md block, but the resolver idiom is the same string.
check_layered "$DIR/skills/doctor/scripts/doctor.sh" "doctor.sh"

if [ "$FAIL" -ne 0 ]; then
  echo "ENV-LOAD CHECK FAILED"
  exit 1
fi
echo "ENV-LOAD-OK (doctor.sh + every audit-* use the layered secret-store resolver)"
