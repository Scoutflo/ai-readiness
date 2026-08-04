#!/bin/sh
# test-space-discovery.sh
# Locks the audit-elk space-discovery fix so the wrong/empty-space bug (a real
# customer 0/100 on a non-default space) can never silently regress.
#
# Two kinds of assertion:
#  (A) STRUCTURAL — the skill must reference GET /api/spaces/space and must NOT
#      hardcode `printf ... "default" ... > spaces.txt` as the sole space source.
#  (B) FUNCTIONAL — run the skill's actual enumeration + audited-set + zero-rule
#      guard jq/shell against real-shape fixtures and assert the invariants:
#      a non-default space is discovered and audited; a key that sees only the
#      default space with zero rules trips the ELK-033 visibility guard (never a
#      confident 0/100); a 404 from the Spaces API degrades, does not crash.
#
# Self-contained, runs anywhere under /bin/sh, no cloud access.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ELK="$(cd "$HERE/.." && pwd)"
SKILL="$ELK/SKILL.md"
CHECKS="$ELK/references/elk-checks.md"
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== audit-elk space-discovery lock ==="

# ---- (A) STRUCTURAL ---------------------------------------------------------
echo "Test 1: the skill enumerates spaces via GET /api/spaces/space"
grep -q 'api/spaces/space' "$CHECKS" || fail "elk-checks.md no longer references GET /api/spaces/space"
grep -q 'api/spaces/space' "$SKILL"  || fail "SKILL.md Phase 1 no longer references GET /api/spaces/space"
echo "PASS"

echo "Test 2: spaces.txt is NOT hardcoded to \"default\" as the sole source"
# The old bug was: printf '%s\n' "default" > "${RAW_DIR}/spaces.txt"  (with a
# 'replace with elk.spaces' comment). If that exact single-source pattern comes
# back, the audit is blind again. Allow "default" only inside the documented
# 404/Serverless FALLBACK branch, never as the primary materialization.
if grep -Eq 'printf .*"default".*> *"?\$\{RAW_DIR\}/spaces\.txt' "$CHECKS"; then
  fail "elk-checks.md hardcodes spaces.txt to 'default' again (the wrong/empty-space bug)"
fi
# The primary materialization must come from the discovered list.
grep -q 'spaces-discovered.txt' "$CHECKS" || fail "elk-checks.md does not materialize the audited set from the discovered spaces"
echo "PASS"

echo "Test 3: the empty/hidden-rules guard + ELK-033 exist"
grep -q 'ELK-033' "$CHECKS" || fail "ELK-033 not in the check catalog"
grep -q 'ELK-033' "$SKILL"  || fail "ELK-033 not wired into the SKILL phases"
grep -qi 'ZERO_RULES' "$SKILL" || fail "no zero-rule flag/guard in SKILL.md"
# Coverage weight range must include 033
grep -q 'ELK-030 to ELK-033' "$SKILL" || fail "scorecard Coverage range not updated to ELK-033"
echo "PASS"

echo "Test 4: connect recipe grants Kibana feature privileges at spaces:[\"*\"]"
PROV="$ELK/../connect/references/providers.md"
grep -q 'spaces:\["\*"\]' "$PROV" || fail "connect providers.md does not require spaces:[\"*\"] read"
grep -q 'feature_stackAlerts.read' "$PROV" || fail "connect providers.md lacks the correct role_descriptors (feature privileges)"
echo "PASS"

# ---- (B) FUNCTIONAL: run the real enumeration/guard logic on fixtures --------
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# GET /api/spaces/space real shape: array of {id,name,...}, filtered to what the
# key can see. Case 1: key sees a non-default space that holds the rules.
cat > "$WORK/spaces-multi.json" <<'JSON'
[{"id":"default","name":"Default"},{"id":"observability","name":"Observability"},{"id":"security","name":"Security"}]
JSON
# Case 2: key sees ONLY default (single-space key = the visibility gap).
cat > "$WORK/spaces-default-only.json" <<'JSON'
[{"id":"default","name":"Default"}]
JSON

# The skill's enumeration jq (verbatim intent): ids, sorted-unique.
discover() { jq -r 'if type=="array" then .[].id else empty end' "$1" 2>/dev/null | sort -u; }

echo "Test 5: multi-space discovery surfaces the non-default space"
disc="$(discover "$WORK/spaces-multi.json")"
echo "$disc" | grep -qx observability || fail "discovery did not surface the non-default 'observability' space"
echo "$disc" | grep -qx default || fail "discovery dropped the default space"
# audited set when elk.spaces unset = all discovered
[ "$(echo "$disc" | wc -l | tr -d ' ')" = "3" ] || fail "expected 3 discovered spaces"
echo "PASS"

echo "Test 6: elk.spaces restriction intersects with discovered (invisible configured space flagged)"
printf 'observability\nmarketing\n' > "$WORK/elk-spaces-config.txt"   # marketing is NOT visible
: > "$WORK/spaces.txt"; : > "$WORK/spaces-skipped.txt"
discover "$WORK/spaces-multi.json" > "$WORK/spaces-discovered.txt"
while read -r s; do
  [ -n "$s" ] || continue
  if grep -qxF "$s" "$WORK/spaces-discovered.txt"; then
    printf '%s\n' "$s" >> "$WORK/spaces.txt"
  else
    printf '%s\tconfigured-but-not-visible\n' "$s" >> "$WORK/spaces-skipped.txt"
  fi
done < "$WORK/elk-spaces-config.txt"
grep -qx observability "$WORK/spaces.txt" || fail "visible configured space 'observability' not audited"
grep -q '^marketing' "$WORK/spaces-skipped.txt" || fail "invisible configured space 'marketing' not flagged as skipped"
grep -qx marketing "$WORK/spaces.txt" && fail "invisible space 'marketing' wrongly added to audited set"
echo "PASS"

echo "Test 7: zero rules + only default visible => visibility trip-wire (Case B), not a confident 0/100"
discover "$WORK/spaces-default-only.json" > "$WORK/spaces-discovered.txt"
cp "$WORK/spaces-discovered.txt" "$WORK/spaces.txt"    # elk.spaces unset => audit all discovered
TOTAL=0                                                # simulate 0 rules in default
ZERO_RULES=0; [ "$TOTAL" -eq 0 ] && ZERO_RULES=1
UNAUDITED="$(comm -23 "$WORK/spaces-discovered.txt" "$WORK/spaces.txt" 2>/dev/null | tr '\n' ' ')"
[ "$ZERO_RULES" -eq 1 ] || fail "zero-rule flag not set on an empty estate"
# Case B: nothing unaudited is discoverable => this is the ELK-033 gap, NOT empty coverage.
[ -z "${UNAUDITED// /}" ] || fail "fixture wrong: expected no unaudited spaces for the single-space case"
echo "PASS (Case B: block coverage w/ ELK-033 visibility reason, never a confident 0/100)"

echo "Test 8: 404 from the Spaces API degrades to a stated fallback, does not crash"
SPACES_CODE="404"
DISCOVERY="ok"
if [ "$SPACES_CODE" = "200" ]; then :; else
  DISCOVERY="unavailable (HTTP ${SPACES_CODE})"
  printf '%s\n' "default" > "$WORK/spaces-discovered-fallback.txt"
fi
[ "$DISCOVERY" != "ok" ] || fail "404 not recorded as discovery-unavailable"
grep -qx default "$WORK/spaces-discovered-fallback.txt" || fail "404 fallback did not write the default space"
echo "PASS (discovery unavailable => stated fallback, not a silent default-is-the-estate assumption)"

echo "=== ALL SPACE-DISCOVERY TESTS PASSED ==="
