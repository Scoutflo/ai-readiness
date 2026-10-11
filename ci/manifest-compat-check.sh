#!/bin/sh
# manifest-compat-check.sh — the plugin.json manifest must use only keys that
# load on OLDER Claude Code, not just the newest CLI.
#
# Why this exists (real incident): v0.1.x shipped `displayName` in
# .claude-plugin/plugin.json. That key is valid ONLY on Claude Code v2.1.143+.
# On an older client (a customer on v2.0.55) the runtime rejects the manifest as
# having an "Unrecognized key" and refuses to load the ENTIRE plugin — all skills
# silently vanish while `/plugin` still shows it "installed". Worse, `claude
# plugin validate --strict` on a NEW CLI passes it, so the break is invisible to
# the author. This gate is the backstop `plugin validate` cannot be:
#   1. hard-fail on `displayName` (the known version-gated offender), and
#   2. hard-fail on ANY top-level key outside the broadly-compatible baseline set,
#      so a future version-gated or typo'd key can't silently ship and fail-closed
#      for every customer on an older client.
#
# Directory listing fields are a narrow exception: Claude Code ignores them at
# runtime. Installation and discovery of all 46 skills plus the hook were verified on the
# supported 2.1.140 floor. Their validator support starts at 2.1.281, so CI uses
# that validator without raising the runtime minimum. These fields belong only
# in plugin.json, never marketplace.json; their types and paths are checked below.
# Reference: https://code.claude.com/docs/en/plugins-reference#directory-listing-fields
# Any other new key still needs a reviewed compatibility decision.
#
# Read-only. POSIX sh + jq.
set -eu
DIR="${1:-.}"
M="$DIR/.claude-plugin/plugin.json"
FAIL=0

[ -f "$M" ] || { echo "MANIFEST-COMPAT: no $M"; exit 1; }
command -v jq >/dev/null || { echo "MANIFEST-COMPAT: jq required"; exit 1; }
jq -e . "$M" >/dev/null 2>&1 || { echo "MANIFEST-COMPAT: $M is not valid JSON"; exit 1; }

# Keys that load on old AND new Claude Code. Deliberately conservative: metadata
# fields only (component-path keys like skills/commands are valid too but we
# auto-discover, so we don't use them). Add a key here only after confirming it
# is NOT version-gated in the plugins reference.
BASELINE_KEYS="name version description author homepage repository license keywords \$schema"
DIRECTORY_KEYS="icon documentationUrl supportUrl privacyPolicyUrl termsOfServiceUrl"

# 1. Explicit block on the known version-gated offender.
if jq -e 'has("displayName")' "$M" >/dev/null 2>&1; then
  echo "MANIFEST-COMPAT: plugin.json uses 'displayName' — valid only on Claude Code v2.1.143+; on older clients the runtime rejects the whole manifest and NO skills load. Remove it (it falls back to 'name')."
  FAIL=1
fi

# 2. Any top-level key not in the baseline set is a compat risk.
for k in $(jq -r 'keys[]' "$M"); do
  case " $BASELINE_KEYS $DIRECTORY_KEYS " in
    *" $k "*) : ;;  # allowed
    *)
      echo "MANIFEST-COMPAT: plugin.json has non-baseline top-level key '$k' — confirm it is not version-gated in the Claude Code plugins reference and add it to BASELINE_KEYS in ci/manifest-compat-check.sh if intended."
      FAIL=1 ;;
  esac
done

# 3. Directory URLs must be public HTTPS references. icon must name a real file
# inside the plugin, not a remote URL, missing file, or path escaping via '..'
# or a symlink. The linked documents describe existing behavior and license
# terms; adding a link does not adopt a new legal policy.
for k in $DIRECTORY_KEYS; do
  if jq -e --arg k "$k" 'has($k)' "$M" >/dev/null 2>&1; then
    if ! jq -e --arg k "$k" '.[$k] | type == "string" and length > 0' "$M" >/dev/null 2>&1; then
      echo "MANIFEST-COMPAT: directory field '$k' must be a non-empty string."
      FAIL=1
      continue
    fi
    value="$(jq -r --arg k "$k" '.[$k]' "$M")"
    if [ "$k" = icon ]; then
      valid_icon=1
      case "$value" in ./*) : ;; *) valid_icon=0 ;; esac
      case "/${value#./}/" in */../*|*/./*|*//*) valid_icon=0 ;; esac
      if [ "$valid_icon" -eq 1 ] && [ -f "$DIR/$value" ] && [ ! -L "$DIR/$value" ]; then
        plugin_root="$(cd "$DIR" && pwd -P)"
        icon_parent="$(cd "$(dirname "$DIR/$value")" && pwd -P)"
        case "$icon_parent/" in "$plugin_root/"*) : ;; *) valid_icon=0 ;; esac
      else
        valid_icon=0
      fi
      if [ "$valid_icon" -ne 1 ]; then
        echo "MANIFEST-COMPAT: icon must resolve to a packaged file under './', with no traversal or symlink escape."
        FAIL=1
      fi
    elif ! jq -e --arg k "$k" '.[$k] | test("^https://[^/?#@\\s]+([/?#][^\\s]*)?$")' "$M" >/dev/null 2>&1; then
      echo "MANIFEST-COMPAT: directory field '$k' must be an HTTPS URL without embedded credentials or whitespace."
      FAIL=1
    fi
  fi
done

# 4. marketplace.json is a manifest too — an old client rejects it the same way
#    (the customer's screenshots showed mass "plugins.N.source: Invalid input" and
#    "Unrecognized key(s): displayName" on marketplaces). Guard its keys symmetrically.
MP="$DIR/.claude-plugin/marketplace.json"
if [ -f "$MP" ]; then
  jq -e . "$MP" >/dev/null 2>&1 || { echo "MANIFEST-COMPAT: $MP is not valid JSON"; FAIL=1; }
  MP_TOP_BASELINE="name owner description plugins \$schema metadata"
  MP_PLUGIN_BASELINE="name source description category keywords \$schema strict"
  for k in $(jq -r 'keys[]' "$MP" 2>/dev/null); do
    case " $MP_TOP_BASELINE " in
      *" $k "*) : ;;
      *) echo "MANIFEST-COMPAT: marketplace.json has non-baseline top-level key '$k' — confirm it is not version-gated and add it to MP_TOP_BASELINE if intended."; FAIL=1 ;;
    esac
  done
  # every plugins[] entry
  n="$(jq '.plugins | length' "$MP" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    for k in $(jq -r ".plugins[$i] | keys[]" "$MP" 2>/dev/null); do
      case " $MP_PLUGIN_BASELINE " in
        *" $k "*) : ;;
        *) echo "MANIFEST-COMPAT: marketplace.json plugins[$i] has non-baseline key '$k' — confirm it is not version-gated and add it to MP_PLUGIN_BASELINE if intended."; FAIL=1 ;;
      esac
    done
    i=$((i + 1))
  done
fi

if [ "$FAIL" -ne 0 ]; then
  echo "MANIFEST-COMPAT CHECK FAILED"
  exit 1
fi
echo "MANIFEST-COMPAT-OK (runtime metadata compatibility and marketplace field restrictions)"
