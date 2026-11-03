#!/bin/sh
# Validate both published manifests strictly, on every supported contributor CLI.
# CLAUDE.md is a contributor adapter, not packaged runtime context. Selecting the
# marketplace manifest explicitly avoids treating that adapter as a plugin entry.
# The isolated metadata fixture preserves the plugin manifest and its assets.
# Skill content is checked separately by structure-check.sh and run-tests.sh.
set -eu
ROOT=$(CDPATH= cd -- "${1:-.}" && pwd)
command -v claude >/dev/null 2>&1 || { echo 'PLUGIN-VALIDATE-FAIL: Claude Code CLI is required' >&2; exit 1; }
for manifest in marketplace.json plugin.json; do
  [ -f "$ROOT/.claude-plugin/$manifest" ] || { echo "PLUGIN-VALIDATE-FAIL: missing .claude-plugin/$manifest" >&2; exit 1; }
done
# Local OS metadata must not make its way into an archive. Exclude Git internals.
noise=$(find "$ROOT" -name .git -prune -o \( -name .DS_Store -o -name Thumbs.db -o -name desktop.ini -o -name __MACOSX \) -print)
[ -z "$noise" ] || { printf 'PLUGIN-VALIDATE-FAIL: remove OS metadata before validation:\n%s\n' "$noise" >&2; exit 1; }
claude plugin validate "$ROOT/.claude-plugin/marketplace.json" --strict
fixture=$(mktemp -d "${TMPDIR:-/tmp}/scoutflo-plugin-metadata.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
cp -R "$ROOT/.claude-plugin" "$fixture/.claude-plugin"
cp "$ROOT/README.md" "$fixture/README.md"
claude plugin validate "$fixture/.claude-plugin/plugin.json" --strict
echo 'PLUGIN-VALIDATE-OK (strict marketplace and plugin metadata)'
