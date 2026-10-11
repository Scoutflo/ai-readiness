#!/bin/sh
# Directory metadata must not open the manifest allowlist or escape the package.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/ci/manifest-compat-check.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$WORK/plugin/.claude-plugin" "$WORK/outside"
cp "$ROOT/.claude-plugin/scoutflo-icon.png" "$WORK/plugin/.claude-plugin/icon.png"
cp "$ROOT/.claude-plugin/scoutflo-icon.png" "$WORK/outside/icon.png"
cat > "$WORK/base.json" <<'EOF'
{
  "name": "fixture",
  "version": "1.0.0",
  "homepage": "https://example.com",
  "icon": "./.claude-plugin/icon.png",
  "documentationUrl": "https://example.com/install",
  "supportUrl": "https://example.com/issues",
  "privacyPolicyUrl": "https://example.com/data-handling",
  "termsOfServiceUrl": "https://example.com/license"
}
EOF
cat > "$WORK/marketplace.json" <<'EOF'
{"name":"fixture","owner":{"name":"Example"},"plugins":[{"name":"fixture","source":"./"}]}
EOF
reset_fixture() {
  cp "$WORK/base.json" "$WORK/plugin/.claude-plugin/plugin.json"
  cp "$WORK/marketplace.json" "$WORK/plugin/.claude-plugin/marketplace.json"
}
change_plugin() {
  jq "$1" "$WORK/base.json" > "$WORK/plugin/.claude-plugin/plugin.json"
}
expect_rejected() {
  if sh "$GATE" "$WORK/plugin" > "$WORK/output" 2>&1; then
    fail "$1"
  fi
}

sh "$GATE" "$ROOT" > "$WORK/output" 2>&1 || fail "shipped metadata rejected"
reset_fixture
sh "$GATE" "$WORK/plugin" > "$WORK/output" 2>&1 || fail "valid directory fields rejected"
change_plugin 'del(.icon, .documentationUrl, .supportUrl, .privacyPolicyUrl, .termsOfServiceUrl)'
sh "$GATE" "$WORK/plugin" > "$WORK/output" 2>&1 || fail "baseline without optional directory fields rejected"

# New directory fields do not permit foreign schemas or version-gated UI fields.
change_plugin '.interface = {"displayName":"Example"}'
expect_rejected "foreign interface field accepted"
change_plugin '.displayName = "Example"'
expect_rejected "displayName compatibility restriction removed"
change_plugin '.unknownDirectoryField = "value"'
expect_rejected "unknown plugin field accepted"

# Metadata must remain typed, and links cannot carry credentials or unsafe schemes.
for field in icon documentationUrl supportUrl privacyPolicyUrl termsOfServiceUrl; do
  jq --arg field "$field" '.[$field] = null' "$WORK/base.json" > "$WORK/plugin/.claude-plugin/plugin.json"
  expect_rejected "null $field accepted"
done
for url in 'http://example.com/help' 'https:///help' 'https://user:password@example.invalid/help' 'https://example.com/a b'; do
  jq --arg url "$url" '.supportUrl = $url' "$WORK/base.json" > "$WORK/plugin/.claude-plugin/plugin.json"
  expect_rejected "unsafe directory URL accepted"
done

# A valid-looking path must resolve inside the plugin, even through a parent link.
for icon in './missing.png' 'https://example.com/icon.png' '/icon.png' './../outside/icon.png'; do
  jq --arg icon "$icon" '.icon = $icon' "$WORK/base.json" > "$WORK/plugin/.claude-plugin/plugin.json"
  expect_rejected "unpackaged icon accepted"
done
ln -s "$WORK/outside/icon.png" "$WORK/plugin/.claude-plugin/linked.png"
change_plugin '.icon = "./.claude-plugin/linked.png"'
expect_rejected "symlinked icon accepted"
ln -s "$WORK/outside" "$WORK/plugin/outside-link"
change_plugin '.icon = "./outside-link/icon.png"'
expect_rejected "icon parent symlink escape accepted"

# Native directory fields are plugin-only, not marketplace fields or entry fields.
for field in icon documentationUrl supportUrl privacyPolicyUrl termsOfServiceUrl; do
  reset_fixture
  jq --arg field "$field" '.plugins[0][$field] = "https://example.com/value"' "$WORK/marketplace.json" > "$WORK/plugin/.claude-plugin/marketplace.json"
  expect_rejected "directory field in marketplace entry accepted"
  jq --arg field "$field" '.[$field] = "https://example.com/value"' "$WORK/marketplace.json" > "$WORK/plugin/.claude-plugin/marketplace.json"
  expect_rejected "directory field at marketplace root accepted"
done

echo "test-manifest-compat-gate: OK"
