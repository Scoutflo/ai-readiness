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

echo "Test 2: an audit stub (tiny SKILL.md, no gates/refs/scenario) is REJECTED"
mk_tree
mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: audit foo\n---\n# audit-foo\nchecks foo.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted an audit stub"
echo "PASS"

echo "Test 3: a COMPLETE audit skill passes every marker"
mk_tree
mkdir -p "$WORK/t/skills/audit-foo/references" "$WORK/t/tests/pressure-scenarios/audit-foo"
{
  printf -- '---\nname: audit-foo\ndescription: read-only scored audit of foo\n---\n\n# audit-foo\n\n'
  printf '## Doctor gate\n\ngate.\n\n## Live-safety gate\n\nprint target.\n\n'
  printf 'Outputs per the report standard and findings-schema.\n\n'
  printf '## Common Failure Modes\n\n| a | b |\n\n'
  # pad well past the 8KB provider floor with realistic body
  i=0; while [ "$i" -lt 400 ]; do printf 'This is a substantive line of audit workflow documentation describing a check.\n'; i=$((i+1)); done
} > "$WORK/t/skills/audit-foo/SKILL.md"
printf '# check catalog\nFOO-001 ...\n' > "$WORK/t/skills/audit-foo/references/foo-checks.md"
printf '# scenario\nexpected behaviour ...\n' > "$WORK/t/tests/pressure-scenarios/audit-foo/x.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || { sh "$GATE" "$WORK/t" 2>&1 | grep audit-foo; fail "gate rejected a complete audit skill"; }
echo "PASS"

echo "Test 4: a setup skill missing disable-model-invocation is REJECTED"
mk_tree
mkdir -p "$WORK/t/skills/setup-foo"
{
  printf -- '---\nname: setup-foo\ndescription: guided hardening of foo\n---\n\n# setup-foo\n\n'
  printf '## The change protocol\n\nannounce/confirm/verify.\n\n## Doctor gate\n\ngate.\n\n## Live-safety gate\n\nprint.\n\n## Common Failure Modes\n\n| a | b |\n\n'
  i=0; while [ "$i" -lt 400 ]; do printf 'A substantive line of setup workflow documentation.\n'; i=$((i+1)); done
} > "$WORK/t/skills/setup-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted a setup skill with no disable-model-invocation"
echo "PASS"

echo "Test 5: a harness library dir (lib/tests, no SKILL.md) is ALLOWED"
mk_tree
mkdir -p "$WORK/t/skills/foo-helper/lib" "$WORK/t/skills/foo-helper/tests"
printf '#!/bin/sh\n:\n' > "$WORK/t/skills/foo-helper/lib/foo.sh"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || fail "gate rejected a legitimate harness library dir with no SKILL.md"
echo "PASS"

echo
echo "=== skill-completeness gate self-test passed ==="
