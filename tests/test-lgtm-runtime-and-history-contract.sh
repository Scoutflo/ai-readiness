#!/bin/sh
# Regression coverage for the LGTM runtime declaration and the Grafana/LGTM
# history-ledger wiring. Runs under POSIX sh with no network access.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== LGTM runtime + history contract ==="

echo "Test 1: both audit skills append complete v2 history rows and replace same-date rows"
for pair in "audit-grafana:audit-grafana" "audit-lgtm:audit-lgtm"; do
  dir="${pair%%:*}"; skill="${pair#*:}"; file="$ROOT/skills/$dir/SKILL.md"
  grep -q "skill:\"${skill}\"" "$file" || fail "$skill history row is missing its skill identity"
  grep -q 'assessment_coverage_percent:.score.assessment.coverage_percent' "$file" || fail "$skill history row omits assessment coverage"
  grep -q 'scoring_model:.score.scoring_model, check_set:.score.check_set' "$file" || fail "$skill history row omits comparison keys"
  grep -q 'grep -v.*run_date.*RUN_DATE.*history.jsonl' "$file" || fail "$skill does not replace an existing same-date history row"
  grep -q 'overall|type)=="number" or .overall==null' "$file" || fail "$skill history verification rejects/omits unassessed null scores"
done
echo "PASS"

echo "Test 2: runtime_mode has one explicit config contract across template, connect, audit, and doctor"
awk '/^lgtm:/{f=1; print; next} f && /^[a-z_]/{exit} f{print}' "$ROOT/templates/toolkit.yaml.example" \
  | grep -q '^[[:space:]]*runtime_mode:[[:space:]]*choose-one' \
  || fail "template does not expose the required lgtm.runtime_mode placeholder"
grep -q '^lgtm:' "$ROOT/skills/connect/references/providers.md" || fail "connect provider reference lacks an lgtm config block"
grep -q 'lgtm.runtime_mode' "$ROOT/skills/connect/SKILL.md" || fail "connect does not gather lgtm.runtime_mode"
grep -q 'req[[:space:]]*lgtm[[:space:]]*runtime_mode' "$ROOT/ci/optional-key-parity-check.sh" || fail "required-key gate does not lock lgtm.runtime_mode"
grep -q 'KNOWN_BLOCKS=.* lgtm ' "$ROOT/skills/doctor/scripts/doctor.sh" || fail "doctor does not recognize the lgtm block"
grep -q "yq -r '.lgtm.runtime_mode" "$ROOT/skills/audit-lgtm/SKILL.md" || fail "audit-lgtm does not read runtime_mode from config"
if grep -q 'RUNTIME_MODE="required-runtime-mode"' "$ROOT/skills/audit-lgtm/SKILL.md"; then
  fail "audit-lgtm still contains the invented runtime placeholder"
fi
echo "PASS"

run_doctor() {
  cfg="$1"; name="$2"
  mkdir -p "$WORK/home" "$WORK/$name"
  set +e
  HOME="$WORK/home" SCOUTFLO_ENV_FILE="$WORK/no-env" \
    sh "$ROOT/skills/doctor/scripts/doctor.sh" --config "$cfg" --out "$WORK/$name" \
      > "$WORK/$name.stdout" 2> "$WORK/$name.stderr"
  rc=$?
  set -e
  printf '%s' "$rc"
}

echo "Test 3: doctor rejects an invalid runtime mode"
printf 'lgtm:\n  runtime_mode: vm\n' > "$WORK/invalid.yaml"
rc="$(run_doctor "$WORK/invalid.yaml" invalid)"
[ "$rc" -eq 3 ] || fail "doctor returned $rc instead of 3 for invalid runtime_mode"
grep -q '"integration":"lgtm","check":"runtime-mode".*"result":"fail"' "$WORK/invalid.stdout" \
  || fail "doctor did not emit a failing lgtm runtime-mode row"
echo "PASS"

echo "Test 4: doctor rejects a present lgtm block with no runtime mode"
printf 'lgtm:\n' > "$WORK/missing.yaml"
rc="$(run_doctor "$WORK/missing.yaml" missing)"
[ "$rc" -eq 3 ] || fail "doctor returned $rc instead of 3 for missing runtime_mode"
grep -q 'lgtm.runtime_mode is required' "$WORK/missing.stdout" \
  || fail "doctor did not explain the missing runtime_mode"
echo "PASS"

echo "Test 5: doctor accepts each declared non-Kubernetes runtime mode"
for mode in ec2-systemd docker external; do
  printf 'lgtm:\n  runtime_mode: %s\n' "$mode" > "$WORK/valid.yaml"
  rc="$(run_doctor "$WORK/valid.yaml" "valid-$mode")"
  [ "$rc" -eq 0 ] || fail "doctor rejected valid runtime_mode=$mode (exit $rc)"
  grep -q '"integration":"lgtm","check":"runtime-mode".*"result":"pass"' "$WORK/valid-$mode.stdout" \
    || fail "doctor did not emit a passing row for runtime_mode=$mode"
done
echo "PASS"

echo "Test 6: kubernetes mode fails closed without an explicit context"
printf 'lgtm:\n  runtime_mode: kubernetes\n' > "$WORK/kubernetes.yaml"
rc="$(run_doctor "$WORK/kubernetes.yaml" kubernetes)"
[ "$rc" -eq 3 ] || fail "doctor returned $rc instead of 3 for kubernetes mode without context"
grep -q 'runtime_mode=kubernetes requires kubernetes.context' "$WORK/kubernetes.stdout" \
  || fail "doctor did not explain the missing Kubernetes context"
echo "PASS"

echo "=== LGTM runtime + history contract passed ==="
