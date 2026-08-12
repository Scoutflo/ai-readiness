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
# If a new key is genuinely wanted, it must be added to BASELINE_KEYS here in the
# same change — a deliberate, reviewed decision, not an accident.
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

# 1. Explicit block on the known version-gated offender.
if jq -e 'has("displayName")' "$M" >/dev/null 2>&1; then
  echo "MANIFEST-COMPAT: plugin.json uses 'displayName' — valid only on Claude Code v2.1.143+; on older clients the runtime rejects the whole manifest and NO skills load. Remove it (it falls back to 'name')."
  FAIL=1
fi

# 2. Any top-level key not in the baseline set is a compat risk.
for k in $(jq -r 'keys[]' "$M"); do
  case " $BASELINE_KEYS " in
    *" $k "*) : ;;  # allowed
    *)
      echo "MANIFEST-COMPAT: plugin.json has non-baseline top-level key '$k' — confirm it is not version-gated in the Claude Code plugins reference and add it to BASELINE_KEYS in ci/manifest-compat-check.sh if intended."
      FAIL=1 ;;
  esac
done

# 3. marketplace.json is a manifest too — an old client rejects it the same way
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
echo "MANIFEST-COMPAT-OK (plugin.json + marketplace.json use only broadly-compatible manifest keys)"
