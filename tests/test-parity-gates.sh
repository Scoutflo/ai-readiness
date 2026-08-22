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
MCOMPAT="$ROOT/ci/manifest-compat-check.sh"
MINVER="$ROOT/ci/min-version-consistency-check.sh"
CATALOG="$ROOT/ci/catalog-consistency-check.sh"
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

echo "Test 9: an audit with the layered secret-store resolver PASSES the env-load gate"
mk; mkdir -p "$WORK/t/skills/audit-foo"
cat > "$WORK/t/skills/audit-foo/SKILL.md" <<'FIXEOF'
---
name: audit-foo
description: x
---
# audit-foo
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
FIXEOF
sh "$ENVL" "$WORK/t" >/dev/null 2>&1 || { sh "$ENVL" "$WORK/t" 2>&1 | head; fail "env-load gate rejected an audit that sources the store"; }
echo "PASS"

echo "Test 10: manifest-compat gate REJECTS the version-gated 'displayName' key"
mk; mkdir -p "$WORK/t/.claude-plugin"
printf '{"name":"scoutflo","displayName":"X","version":"0.0.0"}' > "$WORK/t/.claude-plugin/plugin.json"
sh "$MCOMPAT" "$WORK/t" >/dev/null 2>&1 && fail "manifest-compat accepted displayName (breaks older Claude Code clients)"
echo "PASS"

echo "Test 11: manifest-compat gate ACCEPTS a baseline-only manifest, REJECTS an unknown key"
mk; mkdir -p "$WORK/t/.claude-plugin"
printf '{"name":"scoutflo","version":"0.0.0","description":"d","keywords":["k"]}' > "$WORK/t/.claude-plugin/plugin.json"
sh "$MCOMPAT" "$WORK/t" >/dev/null 2>&1 || { sh "$MCOMPAT" "$WORK/t" 2>&1 | head; fail "manifest-compat rejected a clean baseline manifest"; }
printf '{"name":"scoutflo","version":"0.0.0","madeUpKey":true}' > "$WORK/t/.claude-plugin/plugin.json"
sh "$MCOMPAT" "$WORK/t" >/dev/null 2>&1 && fail "manifest-compat accepted an unknown non-baseline key"
echo "PASS"

echo "Test 12: the REAL shipped plugin.json passes manifest-compat"
sh "$MCOMPAT" "$ROOT" >/dev/null 2>&1 || { sh "$MCOMPAT" "$ROOT" 2>&1 | head; fail "shipped plugin.json fails manifest-compat"; }
echo "PASS"

echo "Test 13: min-version gate PASSES the real repo (one consistent floor, matches doctor.sh)"
sh "$MINVER" "$ROOT" >/dev/null 2>&1 || { sh "$MINVER" "$ROOT" 2>&1 | head; fail "min-version gate rejects the shipped repo"; }
echo "PASS"

echo "Test 14: min-version gate REJECTS an inconsistent floor across docs"
mk; mkdir -p "$WORK/t/skills/doctor/scripts" "$WORK/t/docs"
printf 'MIN_CLAUDE_VERSION="2.1.140"\n' > "$WORK/t/skills/doctor/scripts/doctor.sh"
printf 'need Claude Code v2.1.140\n' > "$WORK/t/README.md"
printf 'need Claude Code v2.1.140\n' > "$WORK/t/docs/install.md"
printf 'need Claude Code v2.1.999\n' > "$WORK/t/docs/faq.md"   # divergent floor
sh "$MINVER" "$WORK/t" >/dev/null 2>&1 && fail "min-version gate accepted two different floor tokens"
echo "PASS"

echo "Test 15: min-version gate REJECTS a docs floor that disagrees with doctor.sh"
mk; mkdir -p "$WORK/t/skills/doctor/scripts" "$WORK/t/docs"
printf 'MIN_CLAUDE_VERSION="2.1.140"\n' > "$WORK/t/skills/doctor/scripts/doctor.sh"
printf 'need Claude Code v2.1.150\n' > "$WORK/t/README.md"
printf 'need Claude Code v2.1.150\n' > "$WORK/t/docs/install.md"
printf 'need Claude Code v2.1.150\n' > "$WORK/t/docs/faq.md"   # consistent across docs but != code floor
sh "$MINVER" "$WORK/t" >/dev/null 2>&1 && fail "min-version gate accepted a docs floor that differs from doctor.sh MIN_CLAUDE_VERSION"
echo "PASS"

echo "Test 16: catalog-consistency gate PASSES the real repo (every public skill is in README + start)"
sh "$CATALOG" "$ROOT" >/dev/null 2>&1 || { sh "$CATALOG" "$ROOT" 2>&1 | head; fail "catalog gate rejects the shipped repo"; }
echo "PASS"

# Shared fixture builder for the catalog tests: a mini repo with two public
# skills (an audit + a harness) and one internal helper, plus matching catalogs.
mk_catalog_repo() {
  mk; mkdir -p "$WORK/t/skills/audit-foo" "$WORK/t/skills/rca" "$WORK/t/skills/checkpoint" "$WORK/t/skills/start"
  for s in audit-foo rca checkpoint start; do
    printf -- '---\nname: %s\ndescription: x\n---\n# %s\n' "$s" "$s" > "$WORK/t/skills/$s/SKILL.md"
  done
  # start catalog + README both name the two public skills; checkpoint (internal) omitted
  printf '# start\nRun scoutflo:audit-foo, scoutflo:rca, scoutflo:start.\n' > "$WORK/t/skills/start/SKILL.md"
  printf '# README\nCatalog: scoutflo:audit-foo, scoutflo:rca, scoutflo:start.\n' > "$WORK/t/README.md"
}

echo "Test 17: catalog gate PASSES a consistent mini repo (internal helper correctly omitted)"
mk_catalog_repo
sh "$CATALOG" "$WORK/t" >/dev/null 2>&1 || { sh "$CATALOG" "$WORK/t" 2>&1 | head; fail "catalog gate rejected a consistent repo"; }
echo "PASS"

echo "Test 18: catalog gate REJECTS a public skill missing from README"
mk_catalog_repo
printf '# README\nCatalog: scoutflo:audit-foo, scoutflo:start.\n' > "$WORK/t/README.md"  # rca dropped
sh "$CATALOG" "$WORK/t" >/dev/null 2>&1 && fail "catalog gate accepted a public skill (rca) missing from README"
echo "PASS"

echo "Test 19: catalog gate REJECTS a public skill missing from the start catalog"
mk_catalog_repo
printf '# start\nRun scoutflo:audit-foo, scoutflo:start.\n' > "$WORK/t/skills/start/SKILL.md"  # rca dropped
sh "$CATALOG" "$WORK/t" >/dev/null 2>&1 && fail "catalog gate accepted a public skill (rca) missing from start"
echo "PASS"

echo "Test 20: catalog gate REJECTS a dangling catalog entry (command with no skill)"
mk_catalog_repo
printf '# README\nCatalog: scoutflo:audit-foo, scoutflo:rca, scoutflo:start, scoutflo:ghost.\n' > "$WORK/t/README.md"
sh "$CATALOG" "$WORK/t" >/dev/null 2>&1 && fail "catalog gate accepted a dangling entry (scoutflo:ghost)"
echo "PASS"

echo
echo "=== parity-gates self-test passed ==="
