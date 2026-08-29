#!/bin/sh
# multi-target-parity-check.sh — every own-block audit must support "multiple targets of one
# integration in one environment": it resolves its targets through the shared enumerator
# (report-standard/toolkit-targets.sh) and writes per-target output keyed by a resolved
# <PREFIX>_SEG segment (so a labeled list writes <integration>/<label>/<date>/ and cannot
# collide, while a single block stays flat). This makes the multi-target behavior mechanical:
# a new own-block audit that hardcodes a single target / a flat output path fails the build.
#
# Exemptions (documented, not silent):
#   - audit-all: orchestrator; it aggregates the per-target dirs (two-level glob), not a target.
#   - audit-cost: cross-provider aggregator; no own connection block.
#   - audit-lgtm, audit-alertmanager, audit-prometheus: these read the SHARED backend block(s)
#     (prometheus/loki/tempo/mimir/grafana/alertmanager) as a single mapping, not a labeled own
#     block — a labeled list under prometheus: would break doctor/audit-lgtm/audit-alertmanager,
#     which all read `cfg prometheus url`. "Multiple targets" there is a distinct multi-stack
#     design tracked as a follow-up. When they adopt it, remove them here.
#
# Read-only. POSIX sh + grep.
set -eu
DIR="${1:-.}"
FAIL=0
EXEMPT="audit-all audit-cost audit-lgtm audit-alertmanager audit-prometheus"

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  case " $EXEMPT " in (*" $name "*) continue ;; esac
  f="${d}SKILL.md"
  [ -f "$f" ] || continue
  if ! grep -q 'report-standard/toolkit-targets.sh' "$f"; then
    echo "MULTI-TARGET-PARITY: ${name} does not resolve targets via the shared enumerator (report-standard/toolkit-targets.sh) — wire the per-target resolver (copy the audit-azure idiom), or add ${name} to the documented EXEMPT list with a reason"
    FAIL=1
  fi
  if ! grep -qE '_SEG' "$f"; then
    echo "MULTI-TARGET-PARITY: ${name} has no per-target output segment (a <PREFIX>_SEG resolved to <integration> or <integration>/<label>) — its output would collide across targets; wire per-target output like audit-azure"
    FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "MULTI-TARGET-PARITY CHECK FAILED"
  exit 1
fi
echo "MULTI-TARGET-PARITY-OK (every own-block audit resolves targets via the enumerator and nests output per target)"
