#!/bin/sh
# SessionStart hook: nudge an operator who has the plugin installed but has NOT
# configured it yet (no toolkit.yaml) toward /scoutflo:connect and /scoutflo:doctor.
# It is SILENT when a config exists — never nag a configured user. It reads only for
# the existence of a config file, prints no secret, makes no network/shell call, and
# exits 0 on any error so it can never disrupt a session. On exit 0 a SessionStart
# hook's plain stdout is injected as session context (no JSON wrapper needed — the
# most portable form across Claude Code versions).
#
# Config resolution mirrors every skill: explicit override -> project-local
# ./.scoutflo -> home ~/.scoutflo.

{
  cfg=""
  if [ -n "${SCOUTFLO_CONFIG:-}" ] && [ -f "${SCOUTFLO_CONFIG}" ]; then
    cfg="${SCOUTFLO_CONFIG}"
  elif [ -f "./.scoutflo/toolkit.yaml" ]; then
    cfg="./.scoutflo/toolkit.yaml"
  elif [ -n "${HOME:-}" ] && [ -f "${HOME}/.scoutflo/toolkit.yaml" ]; then
    cfg="${HOME}/.scoutflo/toolkit.yaml"
  fi

  # Configured -> stay completely silent (no output).
  [ -n "$cfg" ] && exit 0

  # Not configured -> emit a brief plain-text nudge (injected as SessionStart context).
  printf '%s\n' "Scoutflo AI Readiness is installed but not configured yet (no ~/.scoutflo/toolkit.yaml). To use it: run /scoutflo:connect to add read-only credentials, then /scoutflo:doctor to verify reachability, then an audit (e.g. /scoutflo:audit-all). It runs entirely on the user's machine and stores nothing remotely. Do not surface this again once a config exists."
} 2>/dev/null || true
exit 0
