#!/bin/sh
# test-parity-gates.sh
# Guards the behavioral-parity gates:
#   ci/redaction-parity-check.sh        — every audit-* carries the secret-redaction discipline (v0.1.83)
#   ci/business-context-parity-check.sh — every audit-* reads the SSOT + names an apply behavior (v0.1.83)
#   ci/env-load-parity-check.sh         — every audit-* sources ~/.scoutflo/env like doctor (v0.1.91)
# Each: the real fleet PASSES, and a stub audit missing the marker is REJECTED.
# Falsifiable fixtures; runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED="$ROOT/ci/redaction-parity-check.sh"
BC="$ROOT/ci/business-context-parity-check.sh"
ENVL="$ROOT/ci/env-load-parity-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mk() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/skills"; }

echo "=== parity-gates self-test ==="

echo "Test 1: the real fleet PASSES all three gates"
sh "$RED" "$ROOT" >/dev/null 2>&1 || { sh "$RED" "$ROOT" 2>&1 | head; fail "redaction gate rejects the shipped fleet"; }
sh "$BC"  "$ROOT" >/dev/null 2>&1 || { sh "$BC"  "$ROOT" 2>&1 | head; fail "business-context gate rejects the shipped fleet"; }
sh "$ENVL" "$ROOT" >/dev/null 2>&1 || { sh "$ENVL" "$ROOT" 2>&1 | head; fail "env-load gate rejects the shipped fleet"; }
echo "PASS"

echo "Test 2: an audit with NO redaction discipline is REJECTED"
mk; mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\nreads stuff and reports.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$RED" "$WORK/t" >/dev/null 2>&1 && fail "redaction gate accepted an audit with no discipline"
echo "PASS"

echo "Test 3: an audit WITH redaction discipline PASSES the redaction gate"
mk; mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\nNever print or write a secret value; captured by key name only.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$RED" "$WORK/t" >/dev/null 2>&1 || { sh "$RED" "$WORK/t" 2>&1 | head; fail "redaction gate rejected a compliant audit"; }
echo "PASS"

echo "Test 4: an audit with NO Metadata Load block is REJECTED by the business-context gate"
mk; mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\nNever write a secret.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$BC" "$WORK/t" >/dev/null 2>&1 && fail "business-context gate accepted an audit with no Metadata Load"
echo "PASS"

echo "Test 5: a Metadata Load block that reads a source but names NO apply behavior is REJECTED"
mk; mkdir -p "$WORK/t/skills/audit-foo"
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\n'
  printf '## Metadata Load\nreads business_context.json and sets LOAD_METADATA_MODE.\n'
} > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$BC" "$WORK/t" >/dev/null 2>&1 && fail "business-context gate accepted a block with no apply behavior"
echo "PASS"

echo "Test 6: a complete Metadata Load block (source + apply behavior) PASSES"
mk; mkdir -p "$WORK/t/skills/audit-foo"
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\n'
  printf '## Metadata Load\nreads business_context.json; exclude excluded resources, escalate critical services, apply cost_sensitivity.\n'
} > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$BC" "$WORK/t" >/dev/null 2>&1 || { sh "$BC" "$WORK/t" 2>&1 | head; fail "business-context gate rejected a complete block"; }
echo "PASS"

echo "Test 7: audit-all is exempt from all three gates (orchestrator)"
mk; mkdir -p "$WORK/t/skills/audit-all"
printf -- '---\nname: audit-all\ndescription: x\n---\n# audit-all\nruns each audit.\n' > "$WORK/t/skills/audit-all/SKILL.md"
sh "$RED" "$WORK/t" >/dev/null 2>&1 || fail "redaction gate wrongly rejected audit-all"
sh "$BC"  "$WORK/t" >/dev/null 2>&1 || fail "business-context gate wrongly rejected audit-all"
sh "$ENVL" "$WORK/t" >/dev/null 2>&1 || fail "env-load gate wrongly rejected audit-all"
echo "PASS"

echo "Test 8: an audit that does NOT source ~/.scoutflo/env is REJECTED by the env-load gate"
mk; mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\n[ -n "${FOO_TOKEN:-}" ] || exit 1\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ENVL" "$WORK/t" >/dev/null 2>&1 && fail "env-load gate accepted an audit that never sources the store"
echo "PASS"

echo "Test 9: an audit that sources ~/.scoutflo/env PASSES the env-load gate"
mk; mkdir -p "$WORK/t/skills/audit-foo"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# audit-foo\n[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env" || true\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ENVL" "$WORK/t" >/dev/null 2>&1 || { sh "$ENVL" "$WORK/t" 2>&1 | head; fail "env-load gate rejected an audit that sources the store"; }
echo "PASS"

echo
echo "=== parity-gates self-test passed ==="
