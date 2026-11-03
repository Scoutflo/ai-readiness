#!/bin/sh
# Sourced in each fresh shell; read-only requests with config-bound authentication.
set -eu
# Resolve the shared prometheus block from ~/.scoutflo/toolkit.yaml via the shared enumerator (single
# mapping = target 0; this audit never iterates labels). url + the token_env VARIABLE NAME come from the
# block; the token value is read from the store with printenv — presence only, NEVER printed.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$TT" "$CFG" prometheus kind)" = map ] || { echo "prometheus requires a single-block config" >&2; exit 1; }
PROM_URL=$(sh "$TT" "$CFG" prometheus get 0 url); PROM_URL="${PROM_URL%/}"
PROM_TOKEN_VAR=$(sh "$TT" "$CFG" prometheus get 0 token_env)
PROM_TOKEN=""
if [ -n "$PROM_TOKEN_VAR" ]; then
  PROM_TOKEN=$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$PROM_TOKEN_VAR" 2>/dev/null || true)
fi
[ -z "$PROM_TOKEN_VAR" ] || [ -n "$PROM_TOKEN" ] || { echo "configured Prometheus token variable is unset" >&2; exit 1; }
[ -n "$PROM_URL" ] || { echo "prometheus.url is missing" >&2; exit 1; }
AUTH="Authorization: Bearer ${PROM_TOKEN}"; [ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

# pq  <path>          -> GET a raw API path (e.g. /api/v1/targets?state=active). GET only.
# pqq <promql>        -> GET an instant query, url-encoded. GET only, no writes possible.
pq()  { curl -fsS --max-time 20 -H "$AUTH" "${PROM_URL}$1"; }
pqq() { curl -fsS --max-time 20 -H "$AUTH" --get --data-urlencode "query=$1" "${PROM_URL}/api/v1/query"; }

# Detect the rule/metrics engine once (drives which self-metric names are valid downstream).
ENGINE="unknown"
if   pq "/api/v1/status/buildinfo" | jq -e '.data.version' >/dev/null 2>&1; then ENGINE="prometheus"
elif pqq 'vmalert_iteration_total' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then ENGINE="vmalert"
elif pqq 'cortex_build_info' | jq -e '.data.result | length > 0' >/dev/null 2>&1; then ENGINE="mimir"
fi
PROM_HOST=${PROM_URL#*://}; PROM_HOST=${PROM_HOST%%/*}; PROM_HOST=${PROM_HOST##*@}
echo "prometheus target: ${PROM_HOST}  engine=${ENGINE}"

# API error/empty/non-JSON responses are never valid empty collections.
pq_json() {
  _pq_body=$(pq "$1") || { echo "Prometheus read failed: $1 (blocked)" >&2; return 1; }
  printf '%s' "$_pq_body" | jq -e '.status == "success" and (.data != null)' >/dev/null 2>&1 \
    || { echo "Prometheus response is not a successful JSON API envelope (blocked)" >&2; return 1; }
  printf '%s' "$_pq_body"
}
pqq_json() {
  _pq_body=$(pqq "$1") || { echo "Prometheus query failed (blocked)" >&2; return 1; }
  printf '%s' "$_pq_body" | jq -e '.status == "success" and (.data.result | type == "array")' >/dev/null 2>&1 \
    || { echo "Prometheus query response is not a successful result array (blocked)" >&2; return 1; }
  printf '%s' "$_pq_body"
}
