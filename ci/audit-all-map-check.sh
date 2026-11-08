#!/bin/sh
# audit-all-map-check.sh — two guards on skills/audit-all/SKILL.md.
#
# (1) Coverage: every own-block audit-* must appear in audit-all's Phase-1
#     "Map keys to audits" table, so a provider can never silently drop out of
#     "audit everything" (azure/clickstack/signoz were each missing from the
#     table in a prior release even though their audit skill shipped). Iterates
#     the audit skill directories on disk and asserts each non-exempt one's
#     config key maps to that skill in the table. A skill-name mention on a
#     different row does not prove that its own block is discoverable.
#     Exemptions (documented, not silent):
#       - audit-all: the orchestrator itself.
#       - audit-cost: cross-provider roll-up, no own connection block (it runs
#         in Phase 3.6, not the Phase-1 mapping).
#       - audit-alertmanager: keyed by alertmanager_url/vmalert_url.
#       - audit-prometheus: shared-backend audit keyed by the prometheus block
#         (runs alongside audit-lgtm on the same prometheus: block, different plane).
#     The exempt audits still appear in the table by those config keys; they are
#     exempt from the own-block row assertion only.
#     audit-lgtm has an own lgtm: block as well as legacy backend-key triggers;
#     the legacy row cannot substitute for the lgtm -> audit-lgtm mapping.
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

# Audits exempt from the own-block row assertion (see header).
EXEMPT="audit-all audit-cost audit-alertmanager audit-prometheus"

# Scope the search to the Phase-1 mapping table only (from the "Map keys to
# audits" prose through the end of Phase 1), so a stray mention elsewhere in the
# file cannot satisfy the row assertion.
MAP="$(awk '/Map keys to audits/{f=1} /^## Phase 2/{f=0} f' "$SKILL")"

for d in "$DIR"/skills/audit-*/; do
  name="$(basename "$d")"
  case " $EXEMPT " in (*" $name "*) continue ;; esac
  block="$(printf '%s' "${name#audit-}" | tr '-' '_')"
  if ! printf '%s\n' "$MAP" | awk -F'|' -v key="\`$block\`" -v skill="\`$name\`" '
    /^\|/ && index($2, key) && index($3, skill) { found=1 }
    END { exit !found }
  '; then
    echo "AUDIT-ALL-MAP: ${name} has no ${block} -> ${name} row in audit-all's Phase-1 'Map keys to audits' table — its own config block would silently drop out of /scoutflo:audit-all; add the mapping (or document a shared-block exemption)"
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
