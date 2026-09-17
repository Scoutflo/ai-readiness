#!/bin/sh
# test-setup-newrelic.sh — hermetic tests that EXECUTE the SKILL's own bash
# blocks (extracted from SKILL.md) on their fail-closed paths. No network, no
# creds: every case exits before any curl would run. The live success paths
# (backups, wire-verify, the E7 restore round-trip) were proven against a real
# account (see SMOKE-MATRIX); these lock the refusal behaviors mechanically.
set -u

DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROOT="$(CDPATH= cd -- "$DIR/../.." && pwd)"
SKILL="$DIR/SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: SKILL.md not found"; exit 1; }

WORK="${TMPDIR:-/tmp}/nr-setup-test.$$"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

extract() { # extract <start-heading-regex> <end-heading-regex> <outfile>
  awk "/$1/,/$2/" "$SKILL" | awk '/^```bash$/{f=1;next} /^```$/{f=0;exit} f' > "$3"
  [ -s "$3" ]
}

extract '^## Doctor gate' '^## Live-safety gate' "$WORK/doctor.sh" || { echo "FAIL: doctor block not extracted"; exit 1; }
extract '^## Live-safety gate' '^## Load findings' "$WORK/livesafety.sh" || { echo "FAIL: live-safety block not extracted"; exit 1; }
extract '^## Load findings' '^## Wire a workflow' "$WORK/findings.sh" || { echo "FAIL: findings block not extracted"; exit 1; }
extract '^## Wire a workflow' '2\. \*\*Announce' "$WORK/backup-wf.sh" || { echo "FAIL: workflow-backup block not extracted"; exit 1; }

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "Test 1: doctor gate FAILS CLOSED with no config"
( cd "$WORK" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/no-env" sh doctor.sh ) >"$WORK/out1" 2>&1
if [ $? -ne 0 ] && grep -q 'missing.*run /scoutflo:connect' "$WORK/out1"; then ok "no-config fails closed"; else bad "no-config: $(head -1 "$WORK/out1")"; fi

mkdir -p "$WORK/cfg/.scoutflo" "$WORK/emptyhome"
cat > "$WORK/cfg/.scoutflo/toolkit.yaml" <<'EOF'
newrelic:
  account_id: 1234567
  api_key_env: NR_TEST_KEY_THAT_IS_UNSET
  region: US
EOF
: > "$WORK/cfg/.scoutflo/env"
runc() { ( cd "$WORK/cfg" && HOME="$WORK/emptyhome" SCOUTFLO_ENV_FILE="$WORK/cfg/.scoutflo/env" sh "$1" ); }

echo "Test 2: doctor gate FAILS CLOSED on an unset key var, naming it, before any network call"
runc "$WORK/doctor.sh" >"$WORK/out2" 2>&1
if [ $? -ne 0 ] && grep -q 'NR_TEST_KEY_THAT_IS_UNSET is not set' "$WORK/out2"; then ok "unset key named + stopped"; else bad "unset-key: $(head -1 "$WORK/out2")"; fi

echo "Test 3: live-safety gate self-loads env and FAILS CLOSED on the unset key"
runc "$WORK/livesafety.sh" >"$WORK/out3" 2>&1
if [ $? -ne 0 ] && grep -q 'is not set' "$WORK/out3"; then ok "live-safety stops at the key guard"; else bad "live-safety: $(head -1 "$WORK/out3")"; fi

echo "Test 4: findings-load FAILS CLOSED when no audit-newrelic run exists (never plans from nothing)"
runc "$WORK/findings.sh" >"$WORK/out4" 2>&1
if [ $? -ne 0 ] && grep -q 'run /scoutflo:audit-newrelic first' "$WORK/out4"; then ok "no-findings path refuses with the audit-first hint"; else bad "findings-load: $(head -1 "$WORK/out4")"; fi

echo "Test 5: findings-load orders the change plan from a seeded findings.json (success path, hermetic)"
mkdir -p "$WORK/cfg/scoutflo-audits/newrelic/2026-09-17"
cat > "$WORK/cfg/scoutflo-audits/newrelic/2026-09-17/findings.json" <<'EOF'
{"findings":[
 {"id":"NR-030","severity":"high","title":"coverage gap","scoring_scope":"readiness"},
 {"id":"NR-023","severity":"low","title":"dead weight","scoring_scope":"readiness"},
 {"id":"NROPT-001","severity":"info","title":"ingest","scoring_scope":"non-scored"}]}
EOF
runc "$WORK/findings.sh" >"$WORK/out5" 2>&1
if [ $? -eq 0 ] && grep -q 'NR-030' "$WORK/out5" && ! grep -q 'NROPT-001' "$WORK/out5"; then ok "readiness findings listed; non-scored excluded from the plan"; else bad "plan build: $(head -2 "$WORK/out5" | tr '\n' ' ')"; fi

echo "Test 6: the workflow-plane backup block FAILS CLOSED on the unset key (before any curl)"
runc "$WORK/backup-wf.sh" >"$WORK/out6" 2>&1
if [ $? -ne 0 ] && grep -q 'is not set' "$WORK/out6"; then ok "backup block stops at the key guard"; else bad "backup guard: $(head -1 "$WORK/out6")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
