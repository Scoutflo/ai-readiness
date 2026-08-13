#!/bin/sh
# test-doctor-integration.sh
# END-TO-END smoke test: actually invoke scripts/doctor.sh and assert it does
# not crash on load, writes its matrix, and — the v0.1.99 regression guard —
# does NOT cache/skip a credential-liveness check between runs. doctor is a
# preflight: its whole job is to re-verify live every run, so a failed check
# must never be suppressed on a later run (that once let a broken Grafana
# credential report a false green light — see CHANGELOG v0.1.99).
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
# Minimal config: one Grafana block pointed at an unreachable host, with a
# (bogus but present) token so the token gate PASSES and the live check actually
# runs — then fails deterministically on DNS. This exercises the exact path the
# removed skip-cache used to short-circuit. doctor must re-attempt it every run.
export GRAFANA_TEST_TOKEN="bogus-value-for-test-only"
cat > "$SCOUTFLO_CONFIG" <<'EOF'
grafana:
  url: https://grafana.example.invalid
  token_env: GRAFANA_TEST_TOKEN
  tier: read-only
EOF

run_doctor() {  # $1 = out dir, $2 = log file
  mkdir -p "$1"
  set +e
  sh "$DOCTOR_DIR/scripts/doctor.sh" --out "$1" > "$2" 2>&1
  RC=$?
  set -e
}

echo "Test 1: doctor.sh loads and runs under /bin/sh without a 'command not found' crash"
run_doctor "$WORK/out1" "$WORK/doctor1.log"
grep -q "command not found" "$WORK/doctor1.log" \
  && fail "doctor.sh emitted 'command not found': $(grep 'command not found' "$WORK/doctor1.log" | head -1)"
echo "PASS (exit $RC, no load crash)"

echo "Test 2: matrix output written with a header"
[ -f "$WORK/out1/matrix.tsv" ] || fail "doctor did not write matrix.tsv"
head -1 "$WORK/out1/matrix.tsv" | grep -q "integration" || fail "matrix.tsv missing header row"
echo "PASS"

echo "Test 3: the Grafana live check actually ran (row present, not silently skipped)"
grep -q "^grafana	health" "$WORK/out1/matrix.tsv" || fail "no grafana health row in run 1 (check was skipped?)"
echo "PASS"

echo "Test 4: REGRESSION — no skip-cache. A failing check is NOT suppressed on a second run."
# The removed v0.1.65 persistence layer cached a hard-coded 'pass' and skipped the
# next run for 7 days, so a broken credential reported a false green light.
[ -f "$HOME/.scoutflo/doctor-state.json" ] && fail "doctor wrote doctor-state.json — the skip-cache regressed (should be removed)"
run_doctor "$WORK/out2" "$WORK/doctor2.log"
grep -q "^grafana	health" "$WORK/out2/matrix.tsv" || fail "grafana health row missing on run 2 — a skip-cache is suppressing it"
grep -qi "skipping .*previously" "$WORK/doctor2.log" && fail "doctor skipped a check as 'passed previously' — skip-cache regressed"
# Both runs must still surface the failure (unreachable host), never a spurious pass.
grep -qE "^grafana	health	yes	[^	]*	pass" "$WORK/out2/matrix.tsv" && fail "unreachable Grafana reported 'pass' on run 2 (false green light)"
echo "PASS (re-checked live on both runs, no cached pass)"

echo
echo "=== All doctor integration tests passed ==="
