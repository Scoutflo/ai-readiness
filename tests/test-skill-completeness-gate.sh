#!/bin/sh
# test-skill-completeness-gate.sh
# Proves ci/skill-completeness-check.sh actually catches stubs and passes real
# skills — so the gate that stops the "4KB stub ships" class is itself guarded.
# Falsifiable: builds throwaway skill trees and asserts pass/fail. Runs under sh.

set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/ci/skill-completeness-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== skill-completeness gate self-test ==="

echo "Test 1: the real repo fleet PASSES the gate"
sh "$GATE" "$ROOT" >/dev/null 2>&1 || fail "gate rejects the current shipped fleet (false positive)"
echo "PASS"

# Build a minimal throwaway tree with just skills/ + tests/pressure-scenarios/.
mk_tree() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/skills" "$WORK/t/tests/pressure-scenarios"; }

# Write a complete audit-foo SKILL.md + references (every marker, past the byte
# floor) but NO scenarios — callers add scenarios to exercise the I4 count.
mk_complete_audit() {
  mkdir -p "$WORK/t/skills/audit-foo/references" "$WORK/t/tests/pressure-scenarios/audit-foo"
  {
    printf -- '---\nname: audit-foo\ndescription: read-only scored audit of foo\n---\n\n# audit-foo\n\n'
    printf '## Doctor gate\n\ngate.\n\n## Live-safety gate\n\nprint target.\n\n'
    printf 'Outputs per the report standard and findings-schema.\n\n'
    printf '## Common Failure Modes\n\n| a | b |\n\n'
    i=0; while [ "$i" -lt 400 ]; do printf 'This is a substantive line of audit workflow documentation describing a check.\n'; i=$((i+1)); done
  } > "$WORK/t/skills/audit-foo/SKILL.md"
  printf '# check catalog\nFOO-001 ...\n' > "$WORK/t/skills/audit-foo/references/foo-checks.md"
}

# Write $2 pressure scenarios (Expected-behavior blocks) into a single file $1.
pack_scenarios() {
  : > "$1"; n=0
  while [ "$n" -lt "$2" ]; do n=$((n+1)); printf '## scenario %s\n\n**Pressure prompt:** do the risky thing.\n\n**Expected behavior:** the skill does the safe thing.\n\n' "$n" >> "$1"; done
}

# Write a setup-foo skill. $1 = yes|no (include disable-model-invocation); $2 = scenario count.
mk_setup() {
  mkdir -p "$WORK/t/skills/setup-foo" "$WORK/t/tests/pressure-scenarios/setup-foo"
  {
    printf -- '---\nname: setup-foo\ndescription: guided hardening of foo\n'
    [ "$1" = "yes" ] && printf 'disable-model-invocation: true\n'
    printf -- '---\n\n# setup-foo\n\n'
    printf '## The change protocol\n\nannounce/confirm/verify.\n\n## Doctor gate\n\ngate.\n\n## Live-safety gate\n\nprint.\n\n## Common Failure Modes\n\n| a | b |\n\n'
    i=0; while [ "$i" -lt 400 ]; do printf 'A substantive line of setup workflow documentation.\n'; i=$((i+1)); done
  } > "$WORK/t/skills/setup-foo/SKILL.md"
  pack_scenarios "$WORK/t/tests/pressure-scenarios/setup-foo/all.md" "$2"
}

echo "Test 2: an audit stub (tiny SKILL.md, no gates/refs/scenario) is REJECTED"
mk_tree
mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: audit foo\n---\n# audit-foo\nchecks foo.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted an audit stub"
echo "PASS"

echo "Test 3: a COMPLETE audit skill (>= 3 scenarios) passes every marker"
mk_tree
mk_complete_audit
for s in 1 2 3; do printf '# scenario %s\n\n**Pressure prompt:** do the risky thing.\n\n**Expected behavior:** the skill does the safe thing.\n' "$s" > "$WORK/t/tests/pressure-scenarios/audit-foo/s$s.md"; done
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || { sh "$GATE" "$WORK/t" 2>&1 | grep audit-foo; fail "gate rejected a complete audit skill"; }
echo "PASS"

echo "Test 4: a setup skill missing disable-model-invocation is REJECTED (>=3 scenarios present, so that is the only failure)"
mk_tree
mk_setup no 3
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted a setup skill with no disable-model-invocation"
echo "PASS"

echo "Test 5: a harness library dir (lib/tests, no SKILL.md) is ALLOWED"
mk_tree
mkdir -p "$WORK/t/skills/foo-helper/lib" "$WORK/t/skills/foo-helper/tests"
printf '#!/bin/sh\n:\n' > "$WORK/t/skills/foo-helper/lib/foo.sh"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || fail "gate rejected a legitimate harness library dir with no SKILL.md"
echo "PASS"

echo "Test 6: a complete audit skill with only 2 scenarios is REJECTED (I4 >= 3 floor)"
mk_tree
mk_complete_audit
for s in 1 2; do printf '# scenario %s\n\n**Expected behavior:** the skill does the safe thing.\n' "$s" > "$WORK/t/tests/pressure-scenarios/audit-foo/s$s.md"; done
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted an audit skill with only 2 scenarios"
echo "PASS"

echo "Test 7: 3 scenarios packed in ONE file are ACCEPTED (scenarios counted, not files)"
mk_tree
mk_complete_audit
pack_scenarios "$WORK/t/tests/pressure-scenarios/audit-foo/all.md" 3
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || { sh "$GATE" "$WORK/t" 2>&1 | grep audit-foo; fail "gate rejected 3 scenarios packed into one file"; }
echo "PASS"

echo "Test 8: a COMPLETE setup skill (disable-model + >= 3 scenarios) is ACCEPTED"
mk_tree
mk_setup yes 3
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || { sh "$GATE" "$WORK/t" 2>&1 | grep setup-foo; fail "gate rejected a complete setup skill"; }
echo "PASS"

echo "Test 9: a complete setup skill with only 2 scenarios is REJECTED (I4 >= 3 floor, setup lane)"
mk_tree
mk_setup yes 2
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted a setup skill with only 2 scenarios"
echo "PASS"

echo
echo "=== skill-completeness gate self-test passed ==="
