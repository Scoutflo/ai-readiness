#!/bin/sh
# Fixed read-only HyperDX recipe: select the target and project before persistence.
set +x
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
HDX_CAPTURE_URL=$HDX_URL
[ -n "$HDX_CAPTURE_URL" ] || { echo 'HyperDX blocked: target has no HyperDX URL' >&2; exit 1; }
HDX_CAPTURE_KEY=$(cs_secret hyperdx_api_key_env HDX_API_KEY)
HDX_CAPTURE_EMAIL=$(cs_secret hyperdx_email_env HDX_EMAIL)
HDX_CAPTURE_PASSWORD=$(cs_secret hyperdx_password_env HDX_PASSWORD)
HDX_CAPTURE_MODE=session
# A configured API-key binding selects key mode even when its variable is unset.
KEY_BINDING=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_api_key_env)
if [ -n "$KEY_BINDING" ] || [ -n "$HDX_CAPTURE_KEY" ]; then HDX_CAPTURE_MODE=key; fi
export HDX_CAPTURE_URL HDX_CAPTURE_KEY HDX_CAPTURE_EMAIL HDX_CAPTURE_PASSWORD HDX_CAPTURE_MODE
exec python3 "$CS_ROOT/skills/audit-clickstack/scripts/hyperdx-projection.py" "$CS_OUT/raw" "$CS_SEG" "$@"
