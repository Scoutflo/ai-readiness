#!/bin/sh
# structure-check.sh — composes 15 checks: frontmatter, anchor, cross-block,
# coverage, remediation-map, skill-completeness, the four behavioral-parity
# gates (scope-checkpoint, redaction-parity, business-context-parity,
# env-load-parity), manifest-compat, min-version-consistency,
# catalog-consistency, liveness-readonly, audit-dir, and named-section.
# Keep this count in sync with AGENTS.md ("composes N checks").
set -eu
DIR="${1:-.}"
SELF_DIR=$(dirname "$0")
jq empty "$DIR/.claude-plugin/plugin.json"
jq empty "$DIR/.claude-plugin/marketplace.json"
jq -e '.name == "scoutflo"' "$DIR/.claude-plugin/plugin.json" >/dev/null
FAIL=0
for f in "$DIR"/skills/*/SKILL.md; do
  head -1 "$f" | grep -qx -- '---' || { echo "no frontmatter: $f"; FAIL=1; }
  awk '/^---$/{c++;next} c==1' "$f" | grep -q '^name:' || { echo "no name: $f"; FAIL=1; }
  awk '/^---$/{c++;next} c==1' "$f" | grep -q '^description:' || { echo "no description: $f"; FAIL=1; }
done
sh "$SELF_DIR/anchor-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/crossblock-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/coverage-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/remediation-map-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/skill-completeness-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/scope-checkpoint-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/redaction-parity-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/business-context-parity-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/env-load-parity-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/manifest-compat-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/min-version-consistency-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/catalog-consistency-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/liveness-readonly-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/audit-dir-check.sh" "$DIR" || FAIL=1
sh "$SELF_DIR/named-section-check.sh" "$DIR" || FAIL=1
[ "$FAIL" -eq 0 ] && echo STRUCTURE-OK || exit 1
