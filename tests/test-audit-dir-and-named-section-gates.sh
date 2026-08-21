#!/bin/sh
# test-audit-dir-and-named-section-gates.sh
# Guards the two path/pointer hygiene gates:
#   ci/audit-dir-check.sh     — runnable assignment lines that declare a
#     scoutflo-audits output path must resolve via ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits};
#     prose, comments, and echo mentions stay free-form (narrow by design).
#   ci/named-section-check.sh — every (cookbook: "Section Name") prose reference
#     in a SKILL.md must match a real '## Section Name' heading in that skill's
#     references/*.md (the lost-heading regression class found live).
# Each: the real repo PASSES, and falsifiable fixtures are REJECTED.
# Runs under /bin/sh.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADIR="$ROOT/ci/audit-dir-check.sh"
NSEC="$ROOT/ci/named-section-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
mk() { rm -rf "$WORK/t"; mkdir -p "$WORK/t/skills/audit-foo"; }

echo "=== audit-dir + named-section gate self-test ==="

echo "Test 1: the real repo PASSES both gates"
sh "$ADIR" "$ROOT" >/dev/null 2>&1 || { sh "$ADIR" "$ROOT" 2>&1 | head; fail "audit-dir gate rejects the shipped repo"; }
sh "$NSEC" "$ROOT" >/dev/null 2>&1 || { sh "$NSEC" "$ROOT" 2>&1 | head; fail "named-section gate rejects the shipped repo"; }
echo "PASS"

echo "Test 2: a hardcoded quoted assignment in a fenced block is REJECTED"
mk
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n```bash\nOUT="./scoutflo-audits/foo/x"\nmkdir -p "$OUT"\n```\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 && fail "audit-dir gate accepted a hardcoded quoted assignment"
echo "PASS"

echo "Test 3: an unquoted 'export VAR=./scoutflo-audits/...' in references/*.md is REJECTED"
mk; mkdir -p "$WORK/t/skills/audit-foo/references"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\nok\n' > "$WORK/t/skills/audit-foo/SKILL.md"
printf -- '# ref\n```sh\nexport TARGET=./scoutflo-audits/foo\n```\n' > "$WORK/t/skills/audit-foo/references/checks.md"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 && fail "audit-dir gate accepted an unquoted export assignment in references"
echo "PASS"

echo "Test 4: the compliant \${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits} form PASSES"
mk
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n```bash\nOUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/foo/${RUN_DATE}"\nmkdir -p "$OUT"\n```\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 || { sh "$ADIR" "$WORK/t" 2>&1 | head; fail "audit-dir gate rejected the compliant resolved form"; }
echo "PASS"

echo "Test 5: prose, comment, and echo mentions of ./scoutflo-audits are ALLOWED"
mk
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n'
  printf 'Reports land in `./scoutflo-audits/foo/` per the report standard.\n'
  printf '```bash\n# raw pull lands under ./scoutflo-audits/foo\necho "report at ./scoutflo-audits/foo/report.md"\n```\n'
} > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 || { sh "$ADIR" "$WORK/t" 2>&1 | head; fail "audit-dir gate flagged a prose/comment/echo mention (false positive)"; }
echo "PASS"

echo "Test 6: a hardcoded path OUTSIDE any fenced block is ALLOWED (prose declaration)"
mk
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\nOUT="./scoutflo-audits/foo" appears only in prose here, no fence.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 || { sh "$ADIR" "$WORK/t" 2>&1 | head; fail "audit-dir gate flagged prose outside a fenced block"; }
echo "PASS"

echo "Test 7: a resolving (cookbook: \"...\") reference PASSES, including multi-name parentheticals"
mk; mkdir -p "$WORK/t/skills/audit-foo/references"
{
  printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n'
  printf '1. Scan namespaces (cookbook: "Alpha scan").\n'
  printf '2. Lock, then pull (cookbook: "Worklist lock" and "Batch pull").\n'
} > "$WORK/t/skills/audit-foo/SKILL.md"
printf -- '# cookbook\n\n## Alpha scan\n\ncmd\n\n## Worklist lock\n\ncmd\n\n## Batch pull\n\ncmd\n' > "$WORK/t/skills/audit-foo/references/cookbook.md"
sh "$NSEC" "$WORK/t" >/dev/null 2>&1 || { sh "$NSEC" "$WORK/t" 2>&1 | head; fail "named-section gate rejected resolving references"; }
echo "PASS"

echo "Test 8: a dead pointer (heading renamed away) is REJECTED"
mk; mkdir -p "$WORK/t/skills/audit-foo/references"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n1. Scan (cookbook: "Alpha scan").\n' > "$WORK/t/skills/audit-foo/SKILL.md"
printf -- '# cookbook\n\n## Beta scan\n\ncmd\n' > "$WORK/t/skills/audit-foo/references/cookbook.md"
sh "$NSEC" "$WORK/t" >/dev/null 2>&1 && fail "named-section gate accepted a dead cookbook pointer"
echo "PASS"

echo "Test 9: one dead name inside a multi-name parenthetical is REJECTED"
mk; mkdir -p "$WORK/t/skills/audit-foo/references"
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n1. Lock, then pull (cookbook: "Worklist lock" and "Batch pull").\n' > "$WORK/t/skills/audit-foo/SKILL.md"
printf -- '# cookbook\n\n## Worklist lock\n\ncmd\n' > "$WORK/t/skills/audit-foo/references/cookbook.md"
sh "$NSEC" "$WORK/t" >/dev/null 2>&1 && fail "named-section gate accepted a parenthetical with one dead name (Batch pull)"
echo "PASS"

echo "Test 10: cookbook references with NO references/*.md at all are REJECTED"
mk
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\n1. Scan (cookbook: "Alpha scan").\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$NSEC" "$WORK/t" >/dev/null 2>&1 && fail "named-section gate accepted cookbook refs with no references dir"
echo "PASS"

echo "Test 11: a skill with no cookbook references is SKIPPED (both gates pass an empty fixture)"
mk
printf -- '---\nname: audit-foo\ndescription: x\n---\n# t\nplain skill, no cookbook form, no fenced paths.\n' > "$WORK/t/skills/audit-foo/SKILL.md"
sh "$NSEC" "$WORK/t" >/dev/null 2>&1 || fail "named-section gate rejected a skill with no cookbook references"
sh "$ADIR" "$WORK/t" >/dev/null 2>&1 || fail "audit-dir gate rejected a skill with no fenced path declarations"
echo "PASS"

echo
echo "=== audit-dir + named-section gate self-test passed ==="
