#!/bin/sh
# audit-all-map-check.sh — two guards on skills/audit-all/SKILL.md.
#
# (1) Coverage: every own-block audit-* must appear in audit-all's Phase-1
#     "Map keys to audits" table, so a provider can never silently drop out of
#     "audit everything" (azure/clickstack/signoz were each missing from the
#     table in a prior release even though their audit skill shipped). Iterates
#     the audit skill directories on disk and asserts each non-exempt one has a
#     row. Exemptions (documented, not silent):
#       - audit-all: the orchestrator itself.
#       - audit-cost: cross-provider roll-up, no own connection block (it runs
#         in Phase 3.6, not the Phase-1 mapping).
#       - audit-lgtm: keyed by prometheus/loki/tempo/mimir/victoriametrics.
#       - audit-alert-routing: keyed by alertmanager_url/vmalert_url.
#     The exempt audits still appear in the table by those config keys; they are
#     exempt from the by-name row assertion only.
#
# (2) Jargon: audit-all must not resurrect the forbidden "critical services
#     sync-ready" phrasing that report-standard/check-report.sh rejects in a
#     rendered report — the topology-readiness headline is the plain-language
#     "N of M critical services are ready for automatic Scoutflo correlation".
#
# Read-only. POSIX sh + grep + awk.
set -eu
DIR="${1:-.}"
SKILL="$DIR/skills/audit-all/SKILL.md"
FAIL=0

[ -f "$SKILL" ] || { echo "AUDIT-ALL-MAP: missing $SKILL"; exit 1; }

# Own-block audits exempt from the by-name row assertion (see header).
EXEMPT="audit-all audit-cost audit-lgtm audit-alert-routing"

# Scope the search to the Phase-1 mapping table only (from the "Map keys to
# audits" prose through the end of Phase 1), so a stray mention elsewhere in the
# file cannot satisfy the row assertion.
MAP="$(awk '/Map keys to audits/{f=1} /^## Phase 2/{f=0} f' "$SKILL")"

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  case " $EXEMPT " in (*" $name "*) continue ;; esac
  if ! printf '%s\n' "$MAP" | grep -q "$name"; then
    echo "AUDIT-ALL-MAP: ${name} has an audit skill but no row in audit-all's Phase-1 'Map keys to audits' table — it would silently drop out of /scoutflo:audit-all; add its config-key -> ${name} row (or add it to the documented EXEMPT list with a reason)"
    FAIL=1
  fi
done

# Forbidden jargon: the exact phrase check-report.sh rejects in a rendered report.
if grep -q 'critical services sync-ready' "$SKILL"; then
  echo "AUDIT-ALL-MAP: audit-all/SKILL.md contains the forbidden 'critical services sync-ready' jargon (check-report.sh rejects it in any rendered report); use the plain-language headline 'N of M critical services are ready for automatic Scoutflo correlation'"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "AUDIT-ALL-MAP CHECK FAILED"
  exit 1
fi
echo "AUDIT-ALL-MAP-OK (every own-block audit is mapped in audit-all Phase-1; no forbidden sync-ready jargon)"
