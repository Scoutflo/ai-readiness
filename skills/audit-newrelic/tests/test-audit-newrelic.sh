#!/bin/sh
# test-audit-newrelic.sh — hermetic tests that EXECUTE the SKILL's own bash
# blocks (extracted from SKILL.md) on their fail-closed paths, plus the nrq
# helper's empty-auth guard. No network, no creds: every case exits before any
# curl would run. Run by ci/run-tests.sh under /bin/sh.
set -u

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
SKILL="$DIR/SKILL.md"
REFS="$DIR/references/newrelic-checks.md"
[ -f "$SKILL" ] || { echo "FAIL: SKILL.md not found"; exit 1; }

WORK="${TMPDIR:-/tmp}/nr-audit-test.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Extract a SKILL section's first bash fence into a runnable script.
extract() { # extract <start-heading-regex> <end-heading-regex> <outfile>
  awk "/$1/,/$2/" "$SKILL" | awk '/^```bash$/{f=1;next} /^```$/{f=0;exit} f' > "$3"
  [ -s "$3" ]
}

extract '^## Doctor gate' '^## Live-safety gate' "$WORK/doctor.sh" || { echo "FAIL: doctor block not extracted"; exit 1; }
extract '^## Live-safety gate' '^## Ground rules' "$WORK/livesafety.sh" || { echo "FAIL: live-safety block not extracted"; exit 1; }
extract '^## Estate sizing' '^### Scope checkpoint' "$WORK/sizing.sh" || { echo "FAIL: sizing block not extracted"; exit 1; }

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "Test 1: doctor gate FAILS CLOSED with no config anywhere"
( cd "$WORK" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/no-env" sh doctor.sh ) >"$WORK/out1" 2>&1
if [ $? -ne 0 ] && grep -q 'missing\|run /scoutflo:connect' "$WORK/out1"; then ok "no-config path fails closed with the connect hint"; else bad "no-config path: $(head -1 "$WORK/out1")"; fi

# a real config but the key env var deliberately unset
mkdir -p "$WORK/cfg/.scoutflo" "$WORK/emptyhome"
cat > "$WORK/cfg/.scoutflo/toolkit.yaml" <<'EOF'
newrelic:
  account_id: 1234567
  api_key_env: NR_TEST_KEY_THAT_IS_UNSET
  region: US
EOF
: > "$WORK/cfg/.scoutflo/env"

echo "Test 2: doctor gate FAILS CLOSED on an unset key var, NAMING the var, before any network call"
( cd "$WORK/cfg" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/cfg/.scoutflo/env" sh "$WORK/doctor.sh" ) >"$WORK/out2" 2>&1
if [ $? -ne 0 ] && grep -q 'NR_TEST_KEY_THAT_IS_UNSET is not set' "$WORK/out2"; then ok "unset key fails closed naming the variable"; else bad "unset-key path: $(head -1 "$WORK/out2")"; fi

echo "Test 3: live-safety gate FAILS CLOSED on the same unset key (self-loads env; no carry-over assumption)"
( cd "$WORK/cfg" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/cfg/.scoutflo/env" sh "$WORK/livesafety.sh" ) >"$WORK/out3" 2>&1
if [ $? -ne 0 ] && grep -q 'NR_TEST_KEY_THAT_IS_UNSET is not set' "$WORK/out3"; then ok "live-safety fails closed naming the variable"; else bad "live-safety unset-key: $(head -1 "$WORK/out3")"; fi

echo "Test 4: estate sizing FAILS CLOSED on the unset key (the false-zero-on-401 class stays locked upstream)"
( cd "$WORK/cfg" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/cfg/.scoutflo/env" sh "$WORK/sizing.sh" ) >"$WORK/out4" 2>&1
if [ $? -ne 0 ] && grep -q 'is not set' "$WORK/out4"; then ok "sizing stops at the key guard before any curl"; else bad "sizing unset-key: $(head -1 "$WORK/out4")"; fi

echo "Test 5: sizing carries the fail-closed non-JSON guard (the live-caught 401 false-zero lock)"
if grep -q 'estate sizing read failed' "$WORK/sizing.sh"; then ok "non-JSON sizing guard present in the executed block"; else bad "sizing guard missing from extracted block"; fi

echo "Test 6: the nrq helper refuses to run with an unset key (empty-auth-header guard, executed)"
awk '/^## 1\. Read surface/,/^## 2\. Check catalog/' "$REFS" | awk '/^```bash$/{f=1;next} /^```$/{f=0;exit} f' > "$WORK/helpers.sh"
OUT=$( NR_API_HOST=api.invalid NR_ACCT=1 sh -c ". '$WORK/helpers.sh'; unset NEW_RELIC_USER_KEY; nrq 'query { x }'" 2>&1 )
if [ $? -ne 0 ] || printf '%s' "$OUT" | grep -q 'NEW_RELIC_USER_KEY is not set'; then ok "nrq guard stops before sending an empty API-Key header"; else bad "nrq guard: $OUT"; fi

echo "Test 7: doctor gate rejects an invalid region before any network call"
sed 's/region: US/region: MARS/' "$WORK/cfg/.scoutflo/toolkit.yaml" > "$WORK/cfg/.scoutflo/toolkit.yaml.tmp" && mv "$WORK/cfg/.scoutflo/toolkit.yaml.tmp" "$WORK/cfg/.scoutflo/toolkit.yaml"
( cd "$WORK/cfg" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/cfg/.scoutflo/env" sh "$WORK/doctor.sh" ) >"$WORK/out7" 2>&1
if [ $? -ne 0 ] && grep -q 'newrelic.region must be US or EU' "$WORK/out7"; then ok "invalid region fails closed with the exact message"; else bad "region path: $(head -1 "$WORK/out7")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
