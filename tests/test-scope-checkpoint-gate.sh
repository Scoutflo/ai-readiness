#!/bin/sh
# test-scope-checkpoint-gate.sh
# Proves ci/scope-checkpoint-check.sh accepts the wired fleet and rejects an
# audit that has an estate-sizing phase but no pause — so the parity gate that
# stops "large audits grind unbounded with no scoping question" can't itself rot.
# Falsifiable fixtures; runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/ci/scope-checkpoint-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "=== scope-checkpoint gate self-test ==="

echo "Test 1: the real repo fleet PASSES (every audit-* wires the pause)"
sh "$GATE" "$ROOT" >/dev/null 2>&1 || { sh "$GATE" "$ROOT" 2>&1 | head; fail "gate rejects the wired fleet"; }
echo "PASS"

mk() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/skills"; }

echo "Test 2: an audit that never calls cli_pause_before_audit is REJECTED"
mk
mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n## Estate sizing\nTOTAL=5\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted an audit with no scope pause"
echo "PASS"

echo "Test 3: an audit that calls the pause with a large-estate gate PASSES"
mk
mkdir -p "$WORK/t/skills/audit-foo"
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n## Estate sizing\n'
  printf '```bash\nTOTAL=5\nif [ "$TOTAL" -ge 501 ]; then cli_pause_before_audit "$TOTAL"; fi\n```\n'
} > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || fail "gate rejected a properly-wired audit"
echo "PASS"

echo "Test 4: a pause call with NO large-estate threshold gate is REJECTED"
mk
mkdir -p "$WORK/t/skills/audit-foo"
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n## Estate sizing\n'
  printf '```bash\ncli_pause_before_audit "$TOTAL"\n```\n'   # no >=501/1000 gate around it
} > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 && fail "gate accepted a pause with no large-estate threshold"
echo "PASS"

echo "Test 5: audit-all is exempt (orchestrator, no pause required)"
mk
mkdir -p "$WORK/t/skills/audit-all"
printf -- '---\nname: audit-all\ndescription: x\n---\n## Combined\nruns each audit\n' > "$WORK/t/skills/audit-all/SKILL.md"
sh "$GATE" "$WORK/t" >/dev/null 2>&1 || fail "gate wrongly rejected audit-all (should be exempt)"
echo "PASS"

echo
echo "=== scope-checkpoint gate self-test passed ==="
