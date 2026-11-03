#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/repo"
# Construct the synthetic path so the test source is itself public-repo-safe.
printf 'gitdir: /%s/%s/repo/.git/worktrees/demo\n' Users example > "$TMP/repo/.git"
sh "$ROOT/ci/leak-scan.sh" "$TMP/repo" >/dev/null
cp "$TMP/repo/.git" "$TMP/repo/plugin.md"
if sh "$ROOT/ci/leak-scan.sh" "$TMP/repo" >/dev/null 2>&1; then
  echo 'FAIL: excluded plugin content as well as Git metadata'; exit 1
fi
echo 'TESTS-OK: worktree Git pointer ignored, same content in plugin still rejected'
