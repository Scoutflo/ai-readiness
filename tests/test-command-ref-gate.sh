#!/bin/sh
# test-command-ref-gate.sh — falsifiable fixtures for ci/command-ref-check.sh.
# The shipped repo passes; a dangling ${CLAUDE_PLUGIN_ROOT}/*.sh reference and a
# runnable scoutflo_addsecret recipe are each rejected; a prose-only mention and a
# reference that resolves both pass.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/ci/command-ref-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) the shipped repo passes
sh "$GATE" "$ROOT" >/dev/null 2>&1 || fail "gate rejects the shipped repo"

# 2) a dangling ${CLAUDE_PLUGIN_ROOT}/*.sh reference is rejected
mkdir -p "$WORK/dangling/skills/audit-x"
cat > "$WORK/dangling/skills/audit-x/SKILL.md" <<'EOF'
# x
```bash
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-x/scripts/missing.sh" "$CFG"
```
EOF
sh "$GATE" "$WORK/dangling" >/dev/null 2>&1 && fail "gate accepted a dangling script reference"

# 3) a runnable scoutflo_addsecret recipe (inside a fence) is rejected
mkdir -p "$WORK/recipe/skills/connect"
cat > "$WORK/recipe/skills/connect/SKILL.md" <<'EOF'
# connect
```bash
scoutflo_addsecret GRAFANA_TOKEN
```
EOF
sh "$GATE" "$WORK/recipe" >/dev/null 2>&1 && fail "gate accepted a runnable scoutflo_addsecret recipe"

# 4) a prose-only mention of scoutflo_addsecret (outside any fence) passes
mkdir -p "$WORK/prose/skills/connect"
cat > "$WORK/prose/skills/connect/SKILL.md" <<'EOF'
# connect
You can still define your own `scoutflo_addsecret` function; the shipped script is the default.
EOF
sh "$GATE" "$WORK/prose" >/dev/null 2>&1 || fail "gate rejected a prose-only scoutflo_addsecret mention"

# 5) a ${CLAUDE_PLUGIN_ROOT}-relative reference that resolves to a shipped file passes
mkdir -p "$WORK/good/skills/audit-y" "$WORK/good/report-standard"
: > "$WORK/good/report-standard/toolkit-targets.sh"
cat > "$WORK/good/skills/audit-y/SKILL.md" <<'EOF'
# y
```bash
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
```
EOF
sh "$GATE" "$WORK/good" >/dev/null 2>&1 || fail "gate rejected a reference that resolves"

echo "test-command-ref-gate: OK"
