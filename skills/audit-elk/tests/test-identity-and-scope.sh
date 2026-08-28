#!/bin/sh
# Locks the distinction between Kibana identity and permission-dependent
# alerting evidence. Read denials after identity must produce blocked evidence,
# not a false empty estate or a no-report abort.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ELK="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$ELK/../.." && pwd)"
SKILL="$ELK/SKILL.md"
CHECKS="$ELK/references/elk-checks.md"
COLLECTOR="$ELK/scripts/elk-audit.sh"
DOCTOR="$ROOT/skills/doctor/scripts/doctor.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== audit-elk identity/scope lock ==="

grep -q 'identity/readiness gate' "$SKILL" || fail "SKILL does not identify /api/status as the identity gate"
grep -q '"${KIBANA_URL}/api/status"' "$SKILL" || fail "SKILL identity gate does not call /api/status"
grep -q 'ELK_KIBANA_URL}/api/status' "$DOCTOR" || fail "doctor does not call Kibana /api/status"

grep -q '\[ "$ELK_CODE" = "403" \]' "$DOCTOR" \
  || fail "doctor does not distinguish an alerting-health 403"
grep -q 'alerting-health.*skipped.*authenticated but lacks Kibana Alerting read' "$DOCTOR" \
  || fail "doctor does not preserve alerting-health 403 as a non-fatal blocked scope"
grep -q 'alerting-health-state.json' "$COLLECTOR" \
  || fail "ELK evidence pack does not persist the alerting-health state"
grep -q '401) state="unauthenticated"' "$COLLECTOR" \
  || fail "ELK evidence pack does not distinguish 401 unauthenticated"
grep -q '403) state="forbidden"' "$COLLECTOR" \
  || fail "ELK evidence pack does not distinguish 403 forbidden"
grep -q '404|405|501) state="unsupported"' "$COLLECTOR" \
  || fail "ELK evidence pack does not distinguish 404 unsupported"
grep -q 'continues across readable surfaces' "$CHECKS" \
  || fail "ELK evidence pack does not require partial-report continuation"

grep -q 'does not establish Elasticsearch cluster/shard health' "$CHECKS" \
  || fail "Kibana-alerting scope boundary is missing"

echo "PASS"
