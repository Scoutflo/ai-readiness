#!/bin/sh
# Exercise gate composition without installing or contacting any provider.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/repo/.claude-plugin"
printf '{}\n' > "$TMP/repo/.claude-plugin/marketplace.json"
printf '{}\n' > "$TMP/repo/.claude-plugin/plugin.json"
printf 'icon\n' > "$TMP/repo/.claude-plugin/icon.svg"
printf 'Plugin README\n' > "$TMP/repo/README.md"
printf 'Follow AGENTS.md\n' > "$TMP/repo/CLAUDE.md"
cat > "$TMP/bin/claude" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = plugin ] && [ "$2" = validate ] && [ "$4" = --strict ]
printf '%s\n' "$3" >> "$CALLS"
case "$3" in
  */marketplace.json) [ "${REJECT:-}" != marketplace ] ;;
  */plugin.json)
    [ -f "$(dirname "$3")/icon.svg" ]
    [ -f "$(dirname "$(dirname "$3")")/README.md" ]
    [ ! -f "$(dirname "$(dirname "$3")")/CLAUDE.md" ]
    [ "${REJECT:-}" != plugin ] ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/claude"
PATH="$TMP/bin:$PATH"; export PATH
CALLS="$TMP/calls"; export CALLS
sh "$ROOT/ci/plugin-validate.sh" "$TMP/repo" >/dev/null
[ "$(wc -l < "$CALLS" | tr -d ' ')" -eq 2 ]
for REJECT in marketplace plugin; do
  export REJECT
  if sh "$ROOT/ci/plugin-validate.sh" "$TMP/repo" >/dev/null 2>&1; then echo "FAIL: accepted invalid $REJECT manifest"; exit 1; fi
done
unset REJECT
touch "$TMP/repo/.DS_Store"
if sh "$ROOT/ci/plugin-validate.sh" "$TMP/repo" >/dev/null 2>&1; then echo 'FAIL: accepted OS metadata'; exit 1; fi
rm "$TMP/repo/.DS_Store" "$TMP/repo/.claude-plugin/plugin.json"
if sh "$ROOT/ci/plugin-validate.sh" "$TMP/repo" >/dev/null 2>&1; then echo 'FAIL: accepted missing plugin manifest'; exit 1; fi
echo 'TESTS-OK: strict manifest validation, rejection, and OS metadata checks'
