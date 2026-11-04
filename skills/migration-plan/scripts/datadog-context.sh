#!/bin/sh
# Source inside a fresh set -eu block. Resolve one explicitly selected source;
# never use another session's site, token names or target as a fallback.
set +x
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for c in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$c" ] && { CFG="$c"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'no toolkit.yaml; run /scoutflo:connect' >&2; return 1; }
DD_TT="${CLAUDE_PLUGIN_ROOT:?}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$DD_TT" "$CFG" datadog kind); DD_N=$(sh "$DD_TT" "$CFG" datadog count)
[ "${DD_N:-0}" -gt 0 ] || { echo 'Datadog source is not configured' >&2; return 1; }
DD_IDX=0; DD_TARGET=datadog
if [ "$DD_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select a Datadog label with SCOUTFLO_TARGET for this detail pull' >&2; return 1; }
  DD_IDX=-1; DD_I=0; DD_MATCHES=0
  while [ "$DD_I" -lt "$DD_N" ]; do
    DD_LABEL=$(sh "$DD_TT" "$CFG" datadog get "$DD_I" label)
    case "$DD_LABEL" in ''|*[!A-Za-z0-9_-]*) echo 'Datadog list labels must be explicit and safe' >&2; return 1 ;; esac
    if [ "$DD_LABEL" = "$SCOUTFLO_TARGET" ]; then DD_IDX=$DD_I; DD_MATCHES=$((DD_MATCHES+1)); fi
    DD_I=$((DD_I+1))
  done
  [ "$DD_MATCHES" -eq 1 ] || { echo 'Datadog target label is missing or ambiguous' >&2; return 1; }
  DD_TARGET="datadog/$SCOUTFLO_TARGET"
fi
DD_SITE=$(sh "$DD_TT" "$CFG" datadog get "$DD_IDX" site)
[ -n "$DD_SITE" ] || DD_SITE=datadoghq.com
case "$DD_SITE" in datadoghq.com|datadoghq.eu|us3.datadoghq.com|us5.datadoghq.com|ap1.datadoghq.com|ap2.datadoghq.com|ddog-gov.com) ;; *) echo 'Unrecognized Datadog site; verify its official API origin before continuing' >&2; return 1 ;; esac
DD_API_REF=$(sh "$DD_TT" "$CFG" datadog get "$DD_IDX" api_key_env)
DD_APP_REF=$(sh "$DD_TT" "$CFG" datadog get "$DD_IDX" app_key_env)
for DD_REF in "$DD_API_REF" "$DD_APP_REF"; do
  case "$DD_REF" in ''|[0-9]*|*[!A-Za-z0-9_]*) echo 'Configure safe Datadog credential variable names' >&2; return 1 ;; esac
done
DD_STORE="${SCOUTFLO_ENV_FILE:-}"
[ -n "$DD_STORE" ] || { if [ -f './.scoutflo/env' ]; then DD_STORE='./.scoutflo/env'; else DD_STORE="$HOME/.scoutflo/env"; fi; }
dd_selected_secret() { sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1; fi; printenv "$2"' _ "$DD_STORE" "$1"; }
DATADOG_API_KEY=$(dd_selected_secret "$DD_API_REF") || { echo 'Datadog API key is unset' >&2; return 1; }
DATADOG_APP_KEY=$(dd_selected_secret "$DD_APP_REF") || { echo 'Datadog application key is unset' >&2; return 1; }
[ -n "$DATADOG_API_KEY" ] && [ -n "$DATADOG_APP_KEY" ] || { echo 'Datadog credentials are empty' >&2; return 1; }
DD_CR=$(printf '\r')
case "$DATADOG_API_KEY$DATADOG_APP_KEY" in *'
'*|*"$DD_CR"*) echo 'Invalid Datadog credential encoding' >&2; return 1 ;; esac
