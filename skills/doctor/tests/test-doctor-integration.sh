#!/bin/sh
# test-doctor-integration.sh
# END-TO-END smoke test: actually invoke scripts/doctor.sh and assert it does
# not crash on load. This is the test that was missing when v0.1.65's
# persistence layer shipped broken — the old bats-style unit tests sourced the
# lib directly (and crashed on an unbound BATS_TEST_DIRNAME, so they never ran
# at all), which is exactly why doctor.sh failing to source
# doctor-persistence.sh went unnoticed (doctor_state_init: command not found,
# exit 127).
#
# Runs under plain /bin/sh with a throwaway HOME and a minimal config, so it
# exercises the real load path without any live integration or secret.
# Every assertion exits 1 on failure; no unconditional PASS.

set -eu

DOCTOR_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_ROOT="$(cd "$DOCTOR_DIR/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== doctor end-to-end integration test ==="

# Isolated env: fake HOME, minimal config, plugin root pointed at the repo.
export HOME="$WORK/home"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export SCOUTFLO_CONFIG="$WORK/toolkit.yaml"
mkdir -p "$HOME/.scoutflo"
# Minimal config: one block that is skipped (bogus creds) — doctor must still
# load, init persistence, and exit without crashing on the load path.
cat > "$SCOUTFLO_CONFIG" <<'EOF'
grafana:
  url: https://grafana.example.invalid
  token_env: GRAFANA_TOKEN_DOES_NOT_EXIST
  tier: read-only
EOF

echo "Test 1: doctor.sh loads and runs under /bin/sh without a 'command not found' crash"
OUT="$WORK/out"; mkdir -p "$OUT"
LOG="$WORK/doctor.log"
# doctor may exit non-zero on a failed live check — fine. We assert on the
# CRASH signature (bug#1), not the verdict.
set +e
sh "$DOCTOR_DIR/scripts/doctor.sh" --out "$OUT" > "$LOG" 2>&1
rc=$?
set -e
if grep -q "command not found" "$LOG"; then
  fail "doctor.sh emitted 'command not found' (persistence lib not sourced — bug#1): $(grep 'command not found' "$LOG" | head -1)"
fi
if grep -q "doctor_state_init:" "$LOG"; then
  fail "doctor.sh referenced doctor_state_init before it was defined (sourcing order regressed)"
fi
echo "PASS (exit $rc, no load crash)"

echo "Test 2: persistence initialized — doctor-state.json created and valid JSON"
STATE="$HOME/.scoutflo/doctor-state.json"
[ -f "$STATE" ] || fail "doctor-state.json not created (persistence init did not run)"
jq empty "$STATE" 2>/dev/null || fail "doctor-state.json is not valid JSON"
grep -q '"version"' "$STATE" || fail "doctor-state.json missing version field"
echo "PASS"

echo "Test 3: skip-logic comparison does not leak a junk timestamp file (bug#2)"
# The v0.1.72 bug: [ "\$a" > "\$b" ] was a redirect, creating a file named after
# the timestamp. Assert no ISO-8601-named file appeared in the working dirs.
junk=$(find "$WORK" "$PLUGIN_ROOT" -maxdepth 1 -name '20[0-9][0-9]-[0-1][0-9]-*T*' 2>/dev/null | head -1)
[ -z "$junk" ] || fail "skip-logic created a junk timestamp file (unescaped > redirect regressed): $junk"
echo "PASS"

echo "Test 4: matrix output written with a header"
[ -f "$OUT/matrix.tsv" ] || fail "doctor did not write matrix.tsv"
head -1 "$OUT/matrix.tsv" | grep -q "integration" || fail "matrix.tsv missing header row"
echo "PASS"

echo "Test 5: NEGATIVE — a doctor.sh that fails to source the lib must fail Test 1"
# Prove the assertion bites: simulate the bug by calling the un-sourced function.
probe=$(sh -c 'doctor_state_init 2>&1 || true')
echo "$probe" | grep -q "not found" || fail "negative control did not reproduce the bug#1 signature"
echo "PASS (assertion is falsifiable)"

echo
echo "=== All doctor integration tests passed ==="
