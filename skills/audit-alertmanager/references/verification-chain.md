# Verification chain: commands, contracts, and a worked example

Lookup material for [SKILL.md](../SKILL.md). Every block declares its placeholder variables at the top, resolved from `~/.scoutflo/toolkit.yaml` per the [config access rules](../../../docs/skill-authoring-conventions.md#config-access). Run blocks as pasted; nothing here is pseudo-code.

## 0. Auth header convention for every Prometheus and Alertmanager call

`prometheus.token_env` is optional: some deployments sit behind an open network boundary and need no bearer token at all, others require one for both Prometheus and Alertmanager (the doctor gate resolves one shared token for both, since they are typically fronted by the same auth layer). Every command in this reference that calls `PROM_URL` or `AM_URL` follows the same rule `doctor.sh`'s `http_get` helper uses: attach `Authorization: Bearer` only when the token is actually present and non-empty, never send the header empty.

```bash
set -eu
set +x
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
```

Every block below re-declares `PROM_TOKEN` and `AUTH` this way (stateless blocks cannot share a prior block's variables) and passes `-H "$AUTH"` on every `curl` to `PROM_URL` or `AM_URL`.

- ❌ `curl -fsS --max-time 10 "${PROM_URL}/api/v1/rules"` against a token-gated Prometheus reads back `401`, gets logged as "no rules loaded", and the audit reports the paging path as broken.
- ✅ `curl -fsS --max-time 10 -H "$AUTH" "${PROM_URL}/api/v1/rules"` where `AUTH` resolves to the bearer header only when `PROM_TOKEN` is set; the same `401` on an authenticated deployment now means the token itself is missing or wrong (doctor gate should have caught it first), not that rules failed to load.

A `401` or `403` from any of the calls below is an auth-scope finding, not a routing or reachability finding: name it as such in evidence and stop trusting anything downstream of that call until the token is fixed. See section 2 for the reachability read that applies this distinction first.

## 1. Alertmanager reachability fallback

Some clusters expose the Alertmanager UI/API through an ingress; others keep it cluster-internal. Try the ingress first. If it is not reachable, port-forward instead of widening any permission or exposing the service publicly:

```bash
set -eu
set +x
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
AM_LOCAL_PORT="9093"                 # local port for the forward, example, tune to your environment
PROM_TOKEN="${PROM_TOKEN:-}"         # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" port-forward svc/alertmanager-operated "${AM_LOCAL_PORT}:9093" >/tmp/alertmanager-port-forward.log 2>&1 &
AM_PF_PID=$!
trap 'kill "$AM_PF_PID" 2>/dev/null || true' 0
sleep 2
AM_URL="http://127.0.0.1:${AM_LOCAL_PORT}"
AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-metadata)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s' "$AM_SAFE" | jq -e '.cluster.status == "ready"' >/dev/null || { echo 'Alertmanager is not ready'; exit 1; }
echo 'alertmanager reachable via port-forward'
kill "$AM_PF_PID"
trap - 0
```

Expect: `true` printed by the `jq -e` assertion and the confirmation line. `jq -e` exits nonzero (and the `&&` short-circuits) when `.cluster.status` is anything other than `ready`, which is itself the failure signal, not a status a human has to eyeball. Note in evidence whether the run used the ingress URL or the port-forward path; both are read-only, but the choice explains why a later command targets `127.0.0.1` instead of the configured host. A `401`/`403` here means the token attached in `$AUTH` is wrong or missing scope, even though the network path itself is fine; do not read it as "port-forward failed".

## 2. Reachability (ALR-010)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"                      # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

dig +short "$(printf '%s' "$PROM_URL" | sed -E 's#^https?://([^/]+).*#\1#')" || \
  nslookup "$(printf '%s' "$PROM_URL" | sed -E 's#^https?://([^/]+).*#\1#')"

# Do NOT judge reachability on the status code alone: a reverse proxy fronting auth, a moved
# path, or a POST-only route hit with GET can each answer 200 with an HTML SSO/login/SPA page,
# which a status-only check reads as "reachable". These endpoints are typically UNAUTHENTICATED,
# so a JSON-shaped 200 proves the API answered (reachability), not that the caller is authorized.
# Keep the body, capture the content-type, and require 200 + JSON + a field the real API always
# returns before printing pass; a 200 that is not that JSON is an ALR-010 fail (a fronting page).
PROM_JSON="$(json_read '.status=="success" and (.data.version|type)=="string" and (.data.version|length)>0' -H "$AUTH" "${PROM_URL}/api/v1/status/buildinfo")" || exit 1
AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 10 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' -H "$AUTH" "${AM_URL}/api/v2/status" 2>/dev/null)" || AM_RESPONSE='
000 -'
AM_META="$(printf '%s' "$AM_RESPONSE" | tail -n 1)"
PROM_CODE=200
AM_CODE="${AM_META%% *}"; AM_CT="${AM_META#* }"
echo "prometheus: ${PROM_CODE}"
echo "alertmanager: ${AM_CODE}"
PROM_OK=1; AM_OK=0
if [ "$AM_CODE" = "200" ] && printf '%s' "$AM_CT" | grep -qi json && printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-metadata >/dev/null 2>&1; then
  AM_OK=1
elif [ "$AM_CODE" = "200" ]; then
  echo "ALR-010 fail: alertmanager HTTP 200 did not return the expected JSON identity; verify the API endpoint or proxy. Raw headers and body are not retained."
fi
unset AM_RESPONSE
unset PROM_JSON
[ "$PROM_OK" = "1" ] && [ "$AM_OK" = "1" ] && echo "ALR-010: pass"
```

**DNS-truth classification (on a resolution failure, sharpens the ALR-010 evidence).** When the host does not resolve, do not stop at "unreachable" - a *decommissioned* target (the record was deleted) and a *broken ingress* (the name exists, the path is down) read identically at the socket but need opposite responses: retarget/remove the config vs fix the network. Query the zone's authoritative nameserver directly and read the DNS `status`, ruling out a local resolver failure with a known-good sibling (the zone apex). All read-only `dig` lookups:

```bash
set -eu
set +x
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
DNS_ZONE="${ALR_DNS_ZONE:?set ALR_DNS_ZONE to the authoritative zone for this target}"
HOST="$(python3 -c 'import sys; from urllib.parse import urlsplit; print(urlsplit(sys.argv[1]).hostname or "")' "$PROM_URL")"
[ -n "$HOST" ] || { echo 'DNS blocked: endpoint has no host'; exit 1; }
NS_REPLY="$(dig +short NS "$DNS_ZONE")" || { echo 'DNS blocked: nameserver lookup failed'; exit 1; }
NS="$(printf '%s\n' "$NS_REPLY" | sed -n '1p')"
[ -n "$NS" ] || { echo 'DNS blocked: no authoritative nameserver'; exit 1; }
HOST_REPLY="$(dig "@$NS" +noall +comments "$HOST")" || { echo 'DNS blocked: authoritative lookup failed'; exit 1; }
ZONE_REPLY="$(dig "@$NS" +noall +comments "$DNS_ZONE")" || { echo 'DNS blocked: zone control lookup failed'; exit 1; }
STATUS="$(printf '%s' "$HOST_REPLY" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | sed -n '1p')"
CONTROL="$(printf '%s' "$ZONE_REPLY" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | sed -n '1p')"
[ "$CONTROL" = NOERROR ] || { echo 'DNS blocked: zone control did not resolve'; exit 1; }
case "$STATUS" in
 NOERROR) echo 'DNS answered NOERROR; verify the returned address and network path' ;;
 NXDOMAIN) echo 'DNS evidence: NXDOMAIN-authoritative record absent; lifecycle/decommission remains unverified'; exit 1 ;;
 SERVFAIL) echo 'DNS blocked: authoritative SERVFAIL'; exit 1 ;;
 *) echo 'DNS blocked: no supported authoritative status'; exit 1 ;;
esac
```

Expect: a resolvable A/CNAME record, and both probes returning `200` **with a real API body** - Prometheus `buildinfo` carrying `.data.version` and Alertmanager `/api/v2/status` carrying supported `.cluster.status` and `.versionInfo.version` metadata. The final assertion prints `ALR-010: pass` only then. A `200` whose body is not that JSON is an ALR-010 **fail**, flagged as a fronting SSO/login/SPA/proxy page rather than the API. Because these endpoints are typically UNAUTHENTICATED, a JSON-shaped `200` is proof of *reachability*, not of authorized access. Anything else means the check failed and the reader must classify why, per this table:

| Observed code | Diagnosis | Not this |
| --- | --- | --- |
| `000` / connect refused / DNS failure | Reachability problem: DNS, ingress, or network path (ALR-010, high) | Not a routing or auth problem; nothing downstream can be trusted until this is fixed |
| `401` | Auth problem: the token attached in `$AUTH` is missing, wrong, or expired. Record it as an auth-scope finding, not as "unreachable" or "routing broken" | Never re-run the doctor token check as the fix; this is the live call itself failing auth |
| `403` | Auth problem: the token is valid but lacks the scope this endpoint needs | Never downgrade to "endpoint not exposed"; the endpoint answered |
| `200` but HTML / non-API body (no `.data.version`, or no `.cluster`/`.versionInfo`) | A fronting SSO/login/SPA page or reverse proxy answered, not the API (ALR-010, high) | Not "reachable and healthy"; the status code passed but the body did not |
| `200` with a real API body (JSON, expected field present) | Reachable and answering (auth not required, or the token passed); proceed to the next phase | - |

A `401`/`403` on a deployment where the doctor gate reported the token as present means the token's scope, not its existence, is the problem; say so explicitly in the finding text.

## 3. Rule discovery (non-scored input - rule presence retired `ALR-001` → `/scoutflo:audit-prometheus` PROM-022)

> **Retired as a scored check (v0.1.158):** rule **presence** is now `/scoutflo:audit-prometheus` (PROM-022). The commands below are kept as **non-scored input** - audit-alertmanager reads the live rules only to map each firing alert to its route; the presence *verdict* is audit-prometheus's. Where the text below says "the ALR-001 finding", read it as "the rule-presence gap audit-prometheus owns (PROM-022)".

Two-step discipline: try the names you expect, then fall back to live discovery by label. Never assume a name from a manifest survived renames.

Both `kubectl` calls below target the Prometheus Operator's `PrometheusRule` CRD; a cluster running Google Managed Prometheus (GMP) instead has no such CRD at all (it uses `rules.monitoring.googleapis.com`, `clusterrules`, `globalrules`), and `kubectl get prometheusrule` fails outright with "the server doesn't have a resource type" rather than returning zero rules. Both calls below redirect that error and degrade to the live-discovery fallback instead of crashing; the confirmation check right after this block (`/api/v1/rules`) works identically regardless of which CRD family, or none, backs the rules, so it stays the real source of truth either way.

```bash
set -eu
set +x
KUBE_CONTEXT="your-kube-context"     # kubernetes.context, verified by the skill gate
MON_NS="monitoring"                # kubernetes.monitoring_namespace
RULES="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get prometheusrule -o json 2>/dev/null)" || { echo 'CRD discovery blocked or unsupported; use the live rules API below and record the restriction'; exit 1; }
printf '%s' "$RULES" | jq -e -s 'length==1 and (.[0].items|type)=="array"' >/dev/null || { echo 'CRD discovery blocked: unsupported response'; exit 1; }
printf '%s' "$RULES" | jq '[.items[] | {namespace:.metadata.namespace,name:.metadata.name}]'
```

Then confirm the selected rule is actually loaded into Prometheus, not just present as a CRD:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
RULE_GROUP="your-rule-group"                # spec.groups[].name from the selected PrometheusRule
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
printf '%s' "$RULES" | jq -e --arg g "$RULE_GROUP" '[.data.groups[]|select(.name==$g)] | length==1 and (.[0].rules|length)>0' >/dev/null || { echo 'Selected rule group is absent or ambiguous; record the non-scored rule-source gap'; exit 1; }
printf '%s' "$RULES" | jq --arg g "$RULE_GROUP" '[.data.groups[]|select(.name==$g)|{name,rules:[.rules[].name]}]'
```

Expect: `CODE` is `200` and the `jq -e` assertion prints `true`, followed by the group and its rule names. An empty result (assertion prints `false`, exits nonzero) with the CRD present in section 3's step 2 is usually a `ruleSelector` label mismatch between the CRD and the Prometheus or PrometheusOperator resource selector; that mismatch is the ALR-001 finding, not "Prometheus is broken." A `401`/`403` here is never read as "rules failed to load": it is an auth-scope finding, and everything downstream in this phase is blocked, not failed, until the token works.

## 4. Config drift across three layers (ALR-002, ALR-003)

Read the declared object, the rendered file, and the running config, in that order. Redact before you look at, log, or store any of them (section 5).

```bash
set -eu
set +x
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
KUBE_CONTEXT="your-kube-context"     # kubernetes.context
MON_NS="monitoring"                  # kubernetes.monitoring_namespace
AM_CONFIG_NAME="your-alertmanager-config"   # AlertmanagerConfig object name, or the base Secret name
AM_POD="alertmanager-0"              # a running Alertmanager pod name from `kubectl get pods`
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"         # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

# Each original stays in shell memory only; print only the validated projection.
AM_DECLARED="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get alertmanagerconfig "$AM_CONFIG_NAME" -o json 2>/dev/null)" || { echo 'Declared config read blocked'; exit 1; }
printf '%s' "$AM_DECLARED" | sh "$AM_PROJECT" crd
unset AM_DECLARED

AM_RENDERED="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" exec "$AM_POD" -c alertmanager -- cat /etc/alertmanager/config_out/alertmanager.env.yaml 2>/dev/null)" || { echo 'Rendered config read blocked'; exit 1; }
printf '%s' "$AM_RENDERED" | sh "$AM_PROJECT" yaml
unset AM_RENDERED

AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-status)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s\n' "$AM_SAFE"
```

If `kubectl exec` is denied in your cluster, use the port-forward path in section 1 for layer 3 and rely on layers 1 and 2; note the exec restriction in evidence and mark any check that strictly needs in-pod access `blocked` with that reason, never silently skipped.

Two rules keep the comparison honest:

- Operator-managed installs rewrite receiver names to `<namespace>/<config-name>/<receiver>` and add a namespace matcher to routes generated from an `AlertmanagerConfig` CRD. That transformation is expected; do not flag it as drift.
- Reload proof, not apply proof:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-metadata)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s' "$AM_SAFE" | jq -r '.cluster.status, .version'
RELOAD_MAX_AGE_SECONDS="${ALR_RELOAD_MAX_AGE_SECONDS:-86400}" # example freshness requirement, tune to your release process
case "$RELOAD_MAX_AGE_SECONDS" in ''|*[!0-9]*) echo 'Set a numeric reload age'; exit 1 ;; esac
RELOAD_OK="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=alertmanager_config_last_reload_successful" "${PROM_URL}/api/v1/query")" || exit 1
RELOAD_TIME="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=alertmanager_config_last_reload_success_timestamp_seconds" "${PROM_URL}/api/v1/query")" || exit 1
printf '%s\n%s' "$RELOAD_OK" "$RELOAD_TIME" | jq -e -s --argjson age "$RELOAD_MAX_AGE_SECONDS" '
 def key: .metric|del(.__name__)|to_entries|sort_by(.key)|from_entries|tojson;
 (.[0].data.result|map({key:key,value:(.value[1]|tonumber)})) as $ok |
 (.[1].data.result|map({key:key,value:(.value[1]|tonumber)})) as $ts |
 ($ok|length)>0 and ($ts|length)>0 and
 (($ok|map(.key)|sort)==($ts|map(.key)|sort)) and
 (($ok|map(.key)|unique|length)==($ok|length)) and
 all($ok[];.value==1) and all($ts[];.value>0 and .value<=now and now-.value<=$age)
' >/dev/null || { echo 'Reload unverified: missing/ambiguous series, unsuccessful reload or timestamp outside the declared age'; exit 1; }
echo 'ALR-003 reload observed successful within the declared age on every returned matching instance'
```

The assertion verifies successful reload metrics within your declared age for every returned matching instance. First match those instances to the selected Alertmanager deployment. When verifying a specific config change, compare the timestamp with that change and the projected running config. An old timestamp on an unchanged deployment is not itself a failed reload. A zero success metric or an expected change absent from the running config supports ALR-003; missing/mismatched metrics, an arbitrary freshness cutoff or denied reads remain unverified. The example age is a configurable review requirement, not a universal operating threshold.

## 5. Config projection at capture

The stateless [projection helper](../scripts/project-config.sh) parses a rendered YAML config, an `AlertmanagerConfig` JSON object, or an HTTP status response **in memory**. Python 3 with PyYAML and curl 8.4 or newer are required; `check` mode fails before provider reads when unavailable. Status requests disable curl configuration files and redirects. URI-bearing identity, matcher or metadata fields block projection rather than being masked into a false equality. It bounds input to 2 MiB, nesting to 30 and visited values to 50,000; malformed YAML/JSON, duplicate keys and recursive aliases stop without echoing the response.

Only route matchers/timing/grouping, interval definitions, receiver names/types, field names, credential-field presence, `send_resolved`, and destination classification are emitted. Native `victorops_configs` and CRD `victoropsConfigs` remain visible as receiver types; their API/routing keys, URLs, HTTP headers, custom details and templates never enter output. Cluster metadata is separately allowlisted. A parser or read failure is blocked, never an empty healthy configuration. Do not save `/api/v2/status`, `config.original`, or the loaded YAML before this projection, even temporarily; later report redaction cannot undo a capture leak.

Compare observed route structure and receiver type/count/presence across projections after accounting for the Operator namespace transformation. **`credential_equality: unassessed` is deliberate:** two redacted projections do not prove credential or destination equality, and an omitted field is not absent configuration. Keep the exact destination/credential part of ALR-002 unverified without separate protected in-memory comparison or authoritative source evidence. A type such as `victorops` does not reveal a routing key. For the source-to-policy/team/current-responder join, hand verified source metadata and the protected routing-key variable to [SOC-007](../../audit-splunk-oncall/references/verify-path.md#source-side-evidence-for-soc-007); keep upstream route findings here and downstream policy/staffing findings in that audit.

## 6. Active alerts and their resolved receiver (ALR-004)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

ALERTS="$(json_read 'type=="array" and all(.[]; (.labels|type)=="object" and (.labels.alertname|type)=="string" and (.receivers|type)=="array")' -H "$AUTH" "${AM_URL}/api/v2/alerts")" || exit 1
printf '%s' "$ALERTS" | jq '[.[]|{alertname:.labels.alertname,namespace:.labels.namespace,severity:.labels.severity,receivers:[.receivers[].name]}]'
FIRING="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode 'query=count by (namespace) (ALERTS{alertstate="firing"})' "${PROM_URL}/api/v1/query")" || exit 1
printf '%s' "$FIRING" | jq '.data.result'
```

A `401`/`403` from either call means the active-alerts read is auth-blocked, not that no alerts are firing; report it as a blocked check, never as zero active alerts.

The `receivers` field on each `api/v2/alerts` entry names its assigned/resolved receiver. This is routing-state evidence, not proof of dispatch, downstream acceptance or human receipt.

## 7. Route matcher coverage (ALR-004, ALR-011)

Compare the route tree's matchers (from the rendered config in section 4) against the firing-namespace distribution (section 6) and against `topology.md` when it exists:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
LONG_FIRING_HOURS="24"   # example, tune to your environment: how long is "too long" for a firing alert in your stack
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

ALERTS="$(json_read 'type=="array" and all(.[]; (.labels|type)=="object" and (.labels.alertname|type)=="string" and (.receivers|type)=="array")' -H "$AUTH" "${AM_URL}/api/v2/alerts")" || exit 1
printf '%s' "$ALERTS" | python3 -c '
import datetime,json,sys
hours=float(sys.argv[1]); now=datetime.datetime.now(datetime.timezone.utc); out=[]
for alert in json.load(sys.stdin):
    started=datetime.datetime.fromisoformat(alert["startsAt"].replace("Z","+00:00"))
    if started.tzinfo is None: raise ValueError("startsAt must carry a timezone")
    if (now-started).total_seconds()>hours*3600: out.append({"alertname":alert["labels"]["alertname"],"receivers":[r["name"] for r in alert["receivers"]]})
print(json.dumps(out))
' "$LONG_FIRING_HOURS" 2>/dev/null || { echo 'Long-firing check blocked: invalid timestamps or duration'; exit 1; }
```

Three comparisons, each producing findings when they disagree:

1. **Firing namespaces vs matcher scope.** A namespace that fires alerts but matches no route falls through to the default route. If the default receiver is null, a loopback, or an address nobody watches, that namespace pages no one (ALR-004, high).
2. **topology.md vs matcher coverage.** Every namespace or service `topology.md` lists must be covered by a matcher or by an explicit, stated default-route decision. List uncovered services by name in `affected`; do not summarize as a count.
3. **Long-firing alerts vs the receivers they occupy.** Alerts firing longer than `LONG_FIRING_HOURS` sharing a paging receiver with time-sensitive alerts bury real pages under old noise (ALR-011, medium).

## 8. Dispatch proof (ALR-005, ALR-006)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
RECENT_WINDOW="1h"   # example, tune to your alert volume: window for judging "is this failing right now"
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo 'Configure prometheus.alertmanager_url'; exit 1; }
# Empty self-metric vectors mean unobserved counters, not zero failures.
NEED_DIRECT=0
for QUERY in 'sum by (integration) (alertmanager_notifications_total)' "sum by (integration) (increase(alertmanager_notifications_total[${RECENT_WINDOW}]))" "sum by (integration) (increase(alertmanager_notifications_failed_total[${RECENT_WINDOW}]))"; do
METRICS="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=${QUERY}" "${PROM_URL}/api/v1/query")" || exit 1
  printf '%s' "$METRICS" | jq -e '.data.result|length>0' >/dev/null || { NEED_DIRECT=1; break; }
  printf '%s' "$METRICS" | jq '[.data.result[]|{integration:.metric.integration,value:.value[1]}]'
done

if [ "$NEED_DIRECT" -eq 1 ]; then
  # Direct ${AM_URL}/metrics fallback when Prometheus does not scrape Alertmanager.
  # This supplies lifetime counters only; recent delivery needs a reset-aware delta.
  AM_METRICS="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/metrics")" || { RC=$?; echo "Direct metrics blocked: curl exit $RC"; exit 1; }
  printf '%s' "$AM_METRICS" | python3 -c '
import json,math,re,sys
try:
    raw=sys.stdin.buffer.read(2097153); assert len(raw)<=2097152
    body,meta=raw.decode().rsplit("\n",1); code,ct=meta.split(" ",1)
    assert re.fullmatch(r"[0-9]{3}",code)
    if code!="200": print("Direct metrics blocked: HTTP "+code,file=sys.stderr);sys.exit(2)
    assert ct.lower().startswith(("text/plain","application/openmetrics-text"))
    out=[]
    for line in body.splitlines():
        if not re.match(r"^alertmanager_notifications_(?:failed_)?total(?:\{|\s)",line):continue
        m=re.fullmatch(r"(alertmanager_notifications_(?:failed_)?total)(?:\{(.*)\})?\s+([^\s]+)(?:\s+[^\s]+)?",line); assert m
        fields={}; label_text=(m[2] or "").strip(); pos=0
        for field in re.finditer(r"(?:^|,)\s*([A-Za-z_][A-Za-z0-9_]*)=(\"(?:[^\"\\]|\\.)*\")",label_text):
            assert field.start()==pos; pos=field.end()
            assert field[1] not in fields; fields[field[1]]=json.loads(field[2])
        assert pos==len(label_text)
        integration=fields.get("integration"); assert isinstance(integration,str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,64}",integration)
        value=float(m[3]); assert math.isfinite(value) and value>=0
        out.append({"counter":m[1],"integration":integration,"value":value})
    assert out
    print(json.dumps({"scope":"lifetime-only","windowed_delivery":"unassessed","counters":out}))
except Exception:
    print("Direct metrics blocked: missing counters or unsupported exposition; no raw response retained",file=sys.stderr);sys.exit(2)
' || { unset AM_METRICS; exit 1; }
  unset AM_METRICS
  echo 'Lifetime counters observed directly. Recent delivery remains unassessed until comparable samples establish a delta without a process reset'
  exit 1
fi
```

Verdicts, only once the queries above returned `200` and not an auth code:

- Any failure counter above zero inside `RECENT_WINDOW`: delivery is breaking right now (ALR-005, high). If your Alertmanager version exposes a `reason` label, group by it too.
- These queries aggregate by `integration`, not by receiver. Several receivers can share `slack`, `victorops` or another integration type. A flat aggregate cannot identify a named receiver failure. ALR-006 receiver drift requires independently attributable receiver evidence (for example, safely projected dispatch logs tied to that receiver and window) plus the expected routing behavior. Do not infer it from integration totals or substitute a lifetime counter for the windowed evidence.
- A receiver with zero traffic and zero alerts routed to it in section 6 is unproven, not broken: status `configured`, never `pass`. The controlled test that forces one delivery and upgrades it to proven is a setup-lane action.
- A `401`/`403` on either query is never read as "flat at zero" or "no failures": an auth-blocked query proves nothing about dispatch, and reporting it as a passing or flat receiver is the exact false-diagnosis this phase exists to prevent.

## 9. Triage metadata contract (ALR-007)

A firing alert that reaches a responder with only its name starts every investigation from zero. Score every paging-severity rule against this contract. Field names here are this toolkit's example convention: map them to whatever identity your own runbooks, ticketing system, or agent tooling actually consume, and say so in the report when you remap them.

Required identity labels:

- `severity`
- `service`
- `namespace`
- `environment` - a real, commonly-missed label even when `severity`/`service`/`namespace` are all present; without it, every triaged alert's environment reads as unknown and prod-vs-staging blast-radius reasoning has nothing to key off

Required annotations, each a complete sentence or query a responder can act on without asking a follow-up question:

- `summary`: what is happening, in one line.
- `impact`: what breaks for users or downstream services if this stays true.
- `confirmation_query`: the exact query, against the same telemetry backend the rule uses, that a responder or an automated agent re-runs to confirm the condition still holds.
- `triage_scope`: the exact object scope to inspect next (namespace, workload, selector).
- `handoff_note`: one line stating the next tool and what to look for there, when a second signal (logs, traces, error tracker) is expected to help.

Check command, run per paging-severity rule found in section 3:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
printf '%s' "$RULES" | jq '[.data.groups[] as $g | $g.rules[] | select(.type=="alerting") | {group:$g.name,name,labels:(.labels|keys),annotations:(.annotations|keys)}]'
```

This read uses the loaded rules API for Operator, GMP and non-CRD deployments. An unavailable rules API blocks metadata assessment; an observed empty rule list is recorded explicitly and is not proof that every expected rule exists.

A rule missing any required label or annotation key is an ALR-007 finding, `medium`, with the rule name and the missing keys in evidence. Then run each rule's `confirmation_query` annotation against its backend:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
CONFIRMATION_QUERY="your-confirmation-query"   # from the rule's confirmation_query annotation
PROM_TOKEN="${PROM_TOKEN:-}"                # value of the var named by prometheus.token_env, if set
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

CONFIRM="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=${CONFIRMATION_QUERY}" "${PROM_URL}/api/v1/query")" || exit 1
printf '%s' "$CONFIRM" | jq '{result_count:(.data.result|length)}'
echo 'A successful empty query is inconclusive without rule-state and expected-series context; it is not proof of a dead metric'
```

A successful empty confirmation query is inconclusive by itself: a valid predicate can be empty while its alert condition is inactive. Compare the rule state, query semantics and expected underlying series before identifying an unavailable metric. This happens most often when a rule was written against an app-specific metric that was never actually emitted; prefer `kube_state_metrics` and kubelet-sourced signals (`kube_deployment_status_replicas_available`, `kube_pod_container_status_restarts_total`, `container_memory_working_set_bytes`, `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`) when app metrics are unproven. A `401`/`403` is not an empty result and must never be scored as a dead handoff; it means the query never actually ran.

## 10. Error-tracker handoff verification (ALR-008)

Only run this section when a rule's annotations claim an error-tracker handoff. A DSN present in a workload secret proves the SDK was configured once; it does not prove an issue ever arrived. Verify with a read-only API call:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" sentry count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" sentry get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "sentry in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads SENTRY_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where sentry is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" sentry get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" sentry kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then SENTRY_TOKEN="$_sf_v"; export SENTRY_TOKEN; else unset SENTRY_TOKEN; echo "note: ${_sf_tv} (named by sentry.token_env) is not set in the secret store or the shell" >&2; fi; fi
SENTRY_HOST="sentry.io"              # sentry.host
SENTRY_ORG="your-org-slug"           # sentry.org
SENTRY_PROJECT="your-project-slug"   # from the rule's error-tracker project annotation
SENTRY_QUERY="your-issue-query"      # from the rule's error-tracker query annotation
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

ISSUES="$(json_read 'type=="array"' -H "Authorization: Bearer ${SENTRY_TOKEN}" -G --data-urlencode "query=${SENTRY_QUERY}" "https://${SENTRY_HOST}/api/0/projects/${SENTRY_ORG}/${SENTRY_PROJECT}/issues/")" || exit 1
printf '%s' "$ISSUES" | jq '[.[]|{shortId,title,lastSeen}]'
```

A non-empty result with recent `lastSeen` values proves the handoff is live: `validated-live`. An empty result is not automatically a failure; it can mean the query is too narrow or nothing has fired recently. A `401`/`403`/`404` means the project or org slug is wrong, or the token lacks project access; record the status code. Never write `pass` for this check from DSN presence alone (ALR-008, medium). The full error-tracking audit is `audit-sentry`.

## 11. Worked example: a receiver drifted live while the repo stayed correct

An anonymized pattern from a real routing audit, generalized because it recurs:

The declared manifest (layer 1) named a receiver channel that matched what the on-call team expected. The running config on disk (layer 2) still matched the manifest. But the notification-failure counters (section 8) showed a rising `alertmanager_notifications_failed_total` on the Slack integration, and the Alertmanager pod logs carried repeated `channel_not_found` errors.

The cause: someone had renamed the destination channel directly in the chat platform, outside of any manifest change. The three-layer read (section 4) could not have caught this alone, because layers 1 and 2 agreed with each other; only the counters and the log lines, cross-checked against the reload timestamp to rule out stale noise (section 4's reload-proof step), exposed the drift.

Lessons folded into the check catalog:

- Config-layer agreement is necessary but not sufficient. A receiver can be internally consistent across every layer this audit reads and still point at a destination that no longer exists on the receiving end. Only dispatch counters and logs catch that class of drift; that is why ALR-005/ALR-006 are separate checks from ALR-002/ALR-003, not folded into them.
- Log lines age out. The same `channel_not_found` error kept appearing in `kubectl logs` output well after the destination was fixed, because the tail window included pre-fix history. Always compare the error timestamp to the last successful reload (section 4) before citing a log line as current (ALR-009).
- Extract receiver targets by field name, not by array index. A one-liner like `.spec.receivers[1].slackConfigs[0].channel` breaks the moment a receiver list is reordered or a new receiver is inserted. Use section 4’s receiver-name/type projection so reordered receiver lists remain attributable; verify any protected destination separately without publishing its value.

## 12. Large-path worklist: alert rule batches

Run only after the large-scope checkpoint in [Estate sizing](../SKILL.md#estate-sizing-and-scope-checkpoint). The unit is an actual loaded alert rule identified by source file, rule group and rule name, so Operator and non-CRD deployments use the same path. Set `ALR_RUN_ID` once to a selected run ID (for example `$(date -u +%Y%m%dT%H%M%SZ)`), and keep it for every subsequent block. Inputs in this section are explicit session variables; target endpoints and named secrets are independently reloaded from the selected config. A single Prometheus block is required.

**Fixed:** create a new run only when no previous worklist is pending. Run this as written after the skill's verified target/identity gate; do not alter the read or state-transition guards. Existing run IDs are never overwritten. For an interrupted run, skip seeding and use its exact ID in the next block. Selected file/group/name identities are frozen for that run; newly added rules require a separately declared scope, and a disappeared/ambiguous selected rule blocks collection until reconciled. The recipe requires a fresh, matching large-path sizing receipt and stops when service exclusions are nonempty because it does not implement verified service-to-rule filtering. Recompute the checkpoint for a supported scope; never ignore exclusions. These are dated observations: endpoint/run binding does not bind credentials or rule definitions, and completed rows are not silently refreshed on resume. Re-audit when current definitions or changed credentials must be established.

```bash
set -eu
set +x
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" = map ] || { echo 'Select one Prometheus target in SCOUTFLO_CONFIG'; exit 1; }
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)"
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)"
[ -n "$PROM_URL" ] && [ -n "$AM_URL" ] || { echo 'Both Prometheus and Alertmanager URLs are required'; exit 1; }
ALR_RUN_ID="${ALR_RUN_ID:?set ALR_RUN_ID to the selected new or resumed run ID}"
case "$ALR_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo 'Invalid run ID'; exit 1 ;; esac
RUNS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/runs"
RUN_DIR="${RUNS}/${ALR_RUN_ID}"

SIZING_RECEIPT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/estate-sizing.json"
SIZING_MAX_AGE_SECONDS="${ALR_SIZING_MAX_AGE_SECONDS:-3600}" # example freshness window; tune to the attended run
python3 - "$SIZING_RECEIPT" "$PROM_URL" "$AM_URL" "$SIZING_MAX_AGE_SECONDS" <<'SCOPE'
import datetime,hashlib,json,pathlib,sys
try:
    p,prom,am,limit=sys.argv[1:]; limit=int(limit); assert limit>0
    receipt=json.loads(pathlib.Path(p).read_text())
    binding=hashlib.sha256(json.dumps([prom.rstrip("/"),am.rstrip("/")]).encode()).hexdigest()
    assert receipt["target_binding"]==binding and receipt["path"]=="large"
    assert isinstance(receipt["excluded_services"],list) and not receipt["excluded_services"]
    captured=datetime.datetime.fromisoformat(receipt["observed_at"].replace("Z","+00:00")); assert captured.tzinfo
    age=(datetime.datetime.now(datetime.timezone.utc)-captured).total_seconds(); assert 0<=age<=limit
except Exception:
    sys.exit("Scope blocked: rerun the current target sizing/checkpoint; stale or missing receipt, wrong target, or unresolved service exclusions cannot authorize rule reads")
SCOPE

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
# A new run must not silently abandon an interrupted run.
for d in "$RUNS"/*; do
  [ -f "$d/worklist.tsv" ] || continue
  if awk -F '\t' '$2!="done"{found=1} END{exit !found}' "$d/worklist.tsv"; then
    echo "Pending work exists in $d; resume that run or explicitly archive it after reviewing scope"; exit 1
  fi
done
RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
ITEMS="$(printf '%s' "$RULES" | jq '[.data.groups[] as $g | $g.rules[] | select(.type=="alerting") | {source_file:($g.file // ""),group:$g.name,name}] | sort_by(.source_file,.group,.name) | to_entries | map(.value + {id:("rule-"+(.key|tostring))})')"
printf '%s' "$ITEMS" | jq -e 'length>0 and (map([.source_file,.group,.name])|unique|length)==length' >/dev/null || { echo 'Cannot seed: no observed alert rules or ambiguous file/group/name identities'; exit 1; }
mkdir -p "$RUNS"
mkdir "$RUN_DIR" || { echo 'Run already exists; resume it without reseeding'; exit 1; }
umask 077
printf '%s\n' "$ITEMS" > "$RUN_DIR/items.json"
jq -n --arg run "$ALR_RUN_ID" --arg prom "$PROM_URL" --arg am "$AM_URL" '{schema:"scoutflo-alertmanager-worklist/v1",run_id:$run,prometheus_url:$prom,alertmanager_url:$am,scope:"seeded-loaded-alert-rules"}' > "$RUN_DIR/binding.json"
printf '%s' "$ITEMS" | jq -r '.[]|[.id,"pending"]|@tsv' > "$RUN_DIR/worklist.tsv"
printf '%s\n' "$ALR_RUN_ID" > "$RUN_DIR/run-id"
echo "Seeded $(jq length "$RUN_DIR/items.json") rules in $RUN_DIR; no rule is done yet"
```

**Fixed:** collect a bounded batch. Each selected rule is re-read, its metadata keys are measured, and its advertised confirmation query is actually executed when present. Unsupported/API failures stop and leave pending rows intact. Observation files contain field presence and safe counts, not query text, annotation values or response values. `ALR_BATCH_SIZE=20` is an example; tune it to the declared read budget. Locks use atomic directories; a lock is never stolen because a timer elapsed. Recover an abandoned lock only after verifying its owner is no longer running.

```bash
set -eu
set +x
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" = map ] || { echo 'Select one Prometheus target in SCOUTFLO_CONFIG'; exit 1; }
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)"
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)"
[ -n "$PROM_URL" ] && [ -n "$AM_URL" ] || { echo 'Both Prometheus and Alertmanager URLs are required'; exit 1; }
ALR_RUN_ID="${ALR_RUN_ID:?set ALR_RUN_ID to the selected new or resumed run ID}"
case "$ALR_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo 'Invalid run ID'; exit 1 ;; esac
RUNS="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/runs"
RUN_DIR="${RUNS}/${ALR_RUN_ID}"

SIZING_RECEIPT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/estate-sizing.json"
SIZING_MAX_AGE_SECONDS="${ALR_SIZING_MAX_AGE_SECONDS:-3600}" # example freshness window; tune to the attended run
python3 - "$SIZING_RECEIPT" "$PROM_URL" "$AM_URL" "$SIZING_MAX_AGE_SECONDS" <<'SCOPE'
import datetime,hashlib,json,pathlib,sys
try:
    p,prom,am,limit=sys.argv[1:]; limit=int(limit); assert limit>0
    receipt=json.loads(pathlib.Path(p).read_text())
    binding=hashlib.sha256(json.dumps([prom.rstrip("/"),am.rstrip("/")]).encode()).hexdigest()
    assert receipt["target_binding"]==binding and receipt["path"]=="large"
    assert isinstance(receipt["excluded_services"],list) and not receipt["excluded_services"]
    captured=datetime.datetime.fromisoformat(receipt["observed_at"].replace("Z","+00:00")); assert captured.tzinfo
    age=(datetime.datetime.now(datetime.timezone.utc)-captured).total_seconds(); assert 0<=age<=limit
except Exception:
    sys.exit("Scope blocked: rerun the current target sizing/checkpoint; stale or missing receipt, wrong target, or unresolved service exclusions cannot authorize rule reads")
SCOPE

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
BATCH_SIZE="${ALR_BATCH_SIZE:-20}" # example, tune to your estate and read budget
case "$BATCH_SIZE" in ''|*[!0-9]*|0) echo 'Set a positive batch size'; exit 1 ;; esac
jq -e --arg run "$ALR_RUN_ID" --arg p "$PROM_URL" --arg a "$AM_URL" '.run_id==$run and .prometheus_url==$p and .alertmanager_url==$a' "$RUN_DIR/binding.json" >/dev/null || { echo 'Run target mismatch; do not mix evidence'; exit 1; }
LOCK="$RUN_DIR/worklist.lock"
mkdir "$LOCK" 2>/dev/null || { echo 'Run locked; stop. Never reclaim by elapsed time alone'; exit 1; }
printf '%s\n' "$$" > "$LOCK/owner"
trap 'rm -f "$LOCK/owner" "$LOCK/batch" "$LOCK/observation.json"; rmdir "$LOCK" 2>/dev/null || true' 0
mkdir -p "$RUN_DIR/observations"
awk -F '\t' -v n="$BATCH_SIZE" '$2=="pending" && count<n {print $1;count++}' "$RUN_DIR/worklist.tsv" > "$LOCK/batch"
while IFS= read -r ID; do printf '%s\n' 'pending revalidation' > "$RUN_DIR/observations/$ID.blocked"; done < "$LOCK/batch"
RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
mkdir -p "$RUN_DIR/observations"
while IFS= read -r ID; do
  ITEM="$(jq -ce --arg id "$ID" '.[]|select(.id==$id)' "$RUN_DIR/items.json")" || exit 1
  RULE="$(printf '%s' "$RULES" | jq -ce --argjson item "$ITEM" '[.data.groups[] as $g|$g.rules[]|select(.type=="alerting" and ($g.file // "")==$item.source_file and $g.name==$item.group and .name==$item.name)] | if length==1 then .[0] else error("rule missing or ambiguous") end' 2>/dev/null)" || { echo "Rule $ID missing or ambiguous; remains pending"; exit 1; }
  printf '%s' "$RULE" | jq -e '(.labels|type)=="object" and (.annotations|type)=="object"' >/dev/null || { echo "Rule $ID metadata unsupported; remains pending"; exit 1; }
  # Read the advertised confirmation query; never store its text or response values.
  QUERY="$(printf '%s' "$RULE" | jq -r '.annotations.confirmation_query // ""')"
  CONFIRMATION=not-provided; RESULT_COUNT=0
  if [ -n "$QUERY" ]; then
    CONFIRM="$(json_read '.status=="success" and (.data.result|type)=="array"' -H "$AUTH" -G --data-urlencode "query=$QUERY" "${PROM_URL}/api/v1/query")" || { echo "Rule $ID confirmation read blocked; remains pending"; exit 1; }
    RESULT_COUNT="$(printf '%s' "$CONFIRM" | jq '.data.result|length')"
    CONFIRMATION=observed; [ "$RESULT_COUNT" -ne 0 ] || CONFIRMATION=empty-inconclusive
  fi
  OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s' "$RULE" | jq --argjson item "$ITEM" --arg at "$OBSERVED_AT" --arg run "$ALR_RUN_ID" --arg confirmation "$CONFIRMATION" --argjson count "$RESULT_COUNT" '
    {run_id:$run,item:$item,observed_at:$at,read_status:"observed",paging:(.labels.severity=="critical" or .labels.severity=="warning"),
     missing_labels:(["severity","service","namespace","environment"] - [.labels|to_entries[]|select((.value|type)=="string" and .value!="")|.key]),
     missing_annotations:(["summary","impact","confirmation_query","triage_scope","handoff_note"] - [.annotations|to_entries[]|select((.value|type)=="string" and .value!="")|.key]),
     health_present:has("health"),health_ok:(.health=="ok"),last_error_present:((.lastError // "")!=""),
     confirmation:$confirmation,confirmation_result_count:$count,semantic_review:"required"}' > "$LOCK/observation.json"
  mv "$LOCK/observation.json" "$RUN_DIR/observations/$ID.json"
  rm -f "$RUN_DIR/observations/$ID.blocked"
  python3 - "$RUN_DIR/observations/$ID.json" <<'HASH'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]); print(p.name+" SHA256="+hashlib.sha256(p.read_bytes()).hexdigest())
HASH
  echo "Observed $ID; review metadata meaning, confirmation semantics and any second-signal expectation before completion"
done < "$LOCK/batch"
rm -f "$LOCK/batch"
echo "Collection finished; pending=$(awk -F '\t' '$2=="pending"{n++}END{print n+0}' "$RUN_DIR/worklist.tsv"). No row was marked done"
```

**Judgment followed by a fixed commit:** inspect each saved observation and the rule context read in memory. Assess metadata meaning, legitimate empty predicates, applicable severity and any claimed second-signal link using sections 9 and 10. Finish those checks and record their finding IDs before marking the row reviewed. Missing access or unverified semantics stay pending. For a legitimate inactive predicate, independently establish the expected underlying series and current rule state, explain that evidence in the review reason, and set `ALR_EMPTY_QUERY_INTERPRETATION=valid-inactive-predicate`; an unexplained empty result cannot pass. Supply the exact observation hash, a reason and `pass`, `finding` or `not-in-scope`; `done` means the review is complete, not that the rule is healthy or a human received a page.

```bash
set -eu
set +x
ALR_RUN_ID="${ALR_RUN_ID:?select the same run}"
ALR_RULE_ID="${ALR_RULE_ID:?select the observed rule ID}"
ALR_OBSERVATION_SHA256="${ALR_OBSERVATION_SHA256:?paste the exact observation hash you reviewed}"
ALR_REVIEW_RESULT="${ALR_REVIEW_RESULT:?pass, finding or not-in-scope after attended evidence review}"
ALR_REVIEW_REASON="${ALR_REVIEW_REASON:?state the evidence-based review reason; no secrets}"
ALR_FINDING_IDS="${ALR_FINDING_IDS:-}" # comma-separated ALR IDs when result=finding
ALR_EMPTY_QUERY_INTERPRETATION="${ALR_EMPTY_QUERY_INTERPRETATION:-}" # valid-inactive-predicate only after independent series/state evidence
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/runs/${ALR_RUN_ID}"
python3 - "$RUN_DIR" "$ALR_RUN_ID" "$ALR_RULE_ID" "$ALR_OBSERVATION_SHA256" "$ALR_REVIEW_RESULT" "$ALR_REVIEW_REASON" "$ALR_FINDING_IDS" "$ALR_EMPTY_QUERY_INTERPRETATION" <<'REVIEW'
import datetime,hashlib,json,pathlib,re,sys
root,run,rule,digest,result,reason,ids,empty_review=sys.argv[1:]; root=pathlib.Path(root)
assert re.fullmatch(r"[A-Za-z0-9_-]+",run) and re.fullmatch(r"rule-[0-9]+",rule), "invalid identity"
assert result in ("pass","finding","not-in-scope") and reason.strip(), "explicit review required"
fids=[v for v in ids.split(",") if v]
assert all(re.fullmatch(r"ALR-[0-9]{3}",v) for v in fids) and (result!="finding" or fids), "finding references required"
lock=root/"worklist.lock"
try: lock.mkdir()
except FileExistsError: raise SystemExit("Run locked; do not reclaim by elapsed time alone")
try:
    b=json.loads((root/"binding.json").read_text()); assert b["run_id"]==run, "run mismatch"
    path=root/"observations"/(rule+".json"); assert not path.with_suffix(".blocked").exists(), "latest collection incomplete or blocked"
    raw=path.read_bytes(); obs=json.loads(raw)
    assert hashlib.sha256(raw).hexdigest()==digest and obs["run_id"]==run and obs["item"]["id"]==rule and obs["read_status"]=="observed", "stale or incomplete observation"
    if result=="pass":
        assert not obs["missing_labels"] and not obs["missing_annotations"], "pass lacks required metadata"
        assert obs["confirmation"]=="observed" or (obs["confirmation"]=="empty-inconclusive" and empty_review=="valid-inactive-predicate"), "empty query needs an explicit evidence-based inactive-predicate review; otherwise leave pending"
    rows=[x.split("\t") for x in (root/"worklist.tsv").read_text().splitlines()]
    matches=[x for x in rows if x[0]==rule]; assert len(matches)==1 and matches[0][1]=="pending", "rule not pending"
    receipts=root/"reviews"; receipts.mkdir(exist_ok=True)
    receipt={"run_id":run,"rule_id":rule,"observation_sha256":digest,"result":result,"reason":reason,"finding_ids":fids,"empty_query_interpretation":empty_review,"reviewed_at":datetime.datetime.now(datetime.timezone.utc).isoformat()}
    tmp=receipts/(rule+".tmp"); tmp.write_text(json.dumps(receipt,indent=2)); tmp.replace(receipts/(rule+".json"))
    matches[0][1]="done"; tmp=root/"worklist.next"; tmp.write_text("".join("\t".join(x)+"\n" for x in rows));tmp.replace(root/"worklist.tsv")
    print("Reviewed "+rule+"; remaining="+str(sum(x[1]!="done" for x in rows)))
finally: lock.rmdir()
REVIEW
```

**Fixed publication check:** run this before describing the seeded rule scope as complete. Partial reports must name pending IDs and blocked checks and must not claim full scope. Receivers, source-to-route joins, global config and live delivery remain separate checks; this worklist never substitutes for them.

```bash
set -eu
set +x
ALR_RUN_ID="${ALR_RUN_ID:?select the reviewed run}"
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alertmanager/runs/${ALR_RUN_ID}"
python3 - "$RUN_DIR" <<'VERIFY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]); rows=[x.split("\t") for x in (root/"worklist.tsv").read_text().splitlines()]
items=json.loads((root/"items.json").read_text())
assert len(rows)==len(items) and len({x[0] for x in rows})==len(rows) and {x[0] for x in rows}=={x["id"] for x in items}, "worklist differs from seeded scope"
assert rows and all(len(x)==2 and x[1]=="done" for x in rows), "required work pending: do not publish a complete-scope report"
for rule,_ in rows:
    raw=(root/"observations"/(rule+".json")).read_bytes(); r=json.loads((root/"reviews"/(rule+".json")).read_text())
    assert r["observation_sha256"]==hashlib.sha256(raw).hexdigest(), "review is stale"
print("Every seeded rule has a dated attended review tied to its saved observation; this does not establish current rule definitions, credentials or delivery")
VERIFY
```

❌ Marked every selected row done after printing its name, or lost completed evidence while reseeding an interrupted run.
✅ Stored a successful observation, checked its exact hash during attended review, and left failed/unreviewed rows pending for the same run.

## 13. Alert hygiene: range queries and config reads (ALR-012 to ALR-020)

Runs Phase 8. Every block is read-only and reuses endpoints the earlier phases already reach. Honest ceiling, repeated because it belongs in the evidence: these are structural noise signals, not an actionability rate; the flapping and volume windows are bounded by how far back Prometheus still holds the `ALERTS` series and by the continuity of `alertmanager_notifications_total` (a pod restart truncates it), so report the effective lookback the run actually had; and flapping faster than `STEP` is invisible. Every block surfaces evidence; apply the named thresholds (`FLAP_EPISODES`, `STUCK_FRACTION`, etc.) as the reader, exactly as the rest of this audit does. A `401`/`403` on any read here blocks its check; it is never a clean or passing result.

### 13.1 Flapping and stuck rules from the ALERTS range (ALR-012, ALR-013)

`ALERTS{alertstate="firing"}` exists only while a rule is firing, so its appear/disappear pattern over a range reconstructs firing episodes. Episodes count rising edges; firing fraction is present samples over total steps.

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
LOOKBACK="14d"        # example, tune to your Prometheus retention of the ALERTS series
STEP="300"            # seconds; resolution of the episode reconstruction, example, tune it
FLAP_EPISODES="6"     # example, tune it: firing episodes over LOOKBACK above which a paging rule is flapping
STUCK_FRACTION="90"   # example, tune it: firing percent of the window above which a rule is always-on
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

END="$(date -u +%s)"
case "$LOOKBACK" in
  *d) START=$(( END - ${LOOKBACK%d} * 86400 ));;
  *h) START=$(( END - ${LOOKBACK%h} * 3600 ));;
  *)  echo "set LOOKBACK as Nd or Nh"; exit 1;;
esac
TOTAL_STEPS=$(( (END - START) / STEP ))
echo "effective lookback: $(( (END - START) / 86400 ))d at ${STEP}s step (bounded by ALERTS retention)"

RANGE="$(json_read '.status=="success" and (.data.result|type)=="array" and all(.data.result[];(.values|type)=="array")' -H "$AUTH" -G --data-urlencode 'query=ALERTS{alertstate="firing"}' --data-urlencode "start=${START}" --data-urlencode "end=${END}" --data-urlencode "step=${STEP}s" "${PROM_URL}/api/v1/query_range")" || exit 1
# episodes = 1 + gaps wider than 2 steps; firing_pct = present samples / total steps.
RANGE_ROWS="$(printf '%s' "$RANGE" | jq -r --argjson step "$STEP" --argjson total "$TOTAL_STEPS" '
  .data.result[]
  | (.values | map(.[0])) as $ts
  | ( [ range(1; ($ts | length)) | select($ts[.] - $ts[.-1] > ($step * 2)) ] | length ) as $gaps
  | { alert: (.metric.alertname // "?"), severity: (.metric.severity // "-"),
      episodes: (1 + $gaps),
      firing_pct: ((($ts | length) * 100) / (if $total > 0 then $total else 1 end) | floor) }
  | "\(.alert) severity=\(.severity) episodes=\(.episodes) firing_pct=\(.firing_pct)"
')" || { echo 'Range sample shape unsupported'; exit 1; }
printf '%s\n' "$RANGE_ROWS" | sort
echo "flag: paging rules with episodes > ${FLAP_EPISODES} (ALR-012, confirm keep_firing_for==0 in 13.2), or firing_pct > ${STUCK_FRACTION} (ALR-013)"
```

A paging-severity rule over `FLAP_EPISODES` episodes is a flap candidate; confirm it has no `keep_firing_for` hold (13.2) before writing ALR-012. A rule over `STUCK_FRACTION` percent is always-on wallpaper (ALR-013). Sub-`STEP` flapping is invisible; say so in the finding rather than implying the rule is clean.

### 13.2 The `for` debounce and `keep_firing_for` hold (ALR-014, ALR-012)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
printf '%s' "$RULES" | jq '[.data.groups[].rules[]|select(.type=="alerting")|{name,severity:.labels.severity,for_seconds:.duration,keep_firing_for_seconds:.keepFiringFor}]'
echo 'Missing duration fields remain unknown; compare only observed values with the declared debounce policy'
```

On a GMP-style cluster with no `PrometheusRule` CRD, `/api/v1/rules` still carries `duration`/`keepFiringFor` inline, so this check works from the live rules response regardless of the CRD family (same fallback as ALR-007).

### 13.3 Volume concentration and top-talkers (ALR-015)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
LOOKBACK="14d"   # example, match 13.1
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

TOP_RULES="${ALR_TOP_RULES:-20}" # example display limit; tune to your estate
case "$TOP_RULES" in ''|*[!0-9]*|0) echo 'Set TOP_RULES to a positive integer'; exit 1 ;; esac
NOTIFICATIONS="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=sum by (integration) (increase(alertmanager_notifications_total[${LOOKBACK}]))" "${PROM_URL}/api/v1/query")" || exit 1
VOLUME="$(json_read '.status == "success" and (.data.result|type) == "array" and all(.data.result[]; (.metric|type)=="object" and (.value|type)=="array" and (.value|length)==2 and (try (.value[1]|tonumber|isfinite) catch false))' -H "$AUTH" -G --data-urlencode "query=sum by (alertname) (count_over_time(ALERTS{alertstate=\"firing\"}[${LOOKBACK}]))" "${PROM_URL}/api/v1/query")" || exit 1
printf '%s' "$NOTIFICATIONS" | jq -e '.data.result|length>0' >/dev/null || { echo 'Notification volume unobserved: missing series is not zero'; exit 1; }
printf '%s' "$NOTIFICATIONS" | jq '[.data.result[]|{integration:.metric.integration,value:.value[1]}]'
printf '%s' "$VOLUME" | jq --argjson limit "$TOP_RULES" '[.data.result[]|{alertname:.metric.alertname,value:(.value[1]|tonumber)}]|sort_by(-.value)|.[:$limit]'
echo 'Volume concentration is candidate evidence; join it with routing and expected noise policy before assigning ALR-015'
```

### 13.4 Grouping, inhibition, mute intervals, repeat_interval, resolve-noise (ALR-016, ALR-015, ALR-018)

All from the running config. Redact per section 5 before storing any of it.

```bash
set -eu
set +x
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-status)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s\n' "$AM_SAFE" | jq '{route,inhibit_rules,time_intervals,mute_time_intervals,global,receivers}'
```

Read the projected fields against these rules; omitted credential/destination values remain unverified:

- **`group_by` (ALR-016):** absent on a child route inherits the parent grouping; resolve that inheritance before judging it. An explicit empty list groups all alerts together and can over-aggregate unrelated incidents. The special value `['...']` also defeats aggregation - it means "group by every label", so each distinct alert becomes its own group. Compare the effective grouping with your incident boundaries; a typical `group_by` names the few labels that define an incident (for example `['alertname','cluster','namespace']`).
- **`inhibit_rules` (ALR-016):** empty or absent means no configured inhibition; call it a gap only when your declared routing design requires suppression of known correlated alerts.
- **`time_intervals` + route `mute_time_intervals`/`active_time_intervals`:** every referenced interval name must resolve to a definition; a dangling reference is a config error.
- **`repeat_interval` (ALR-015):** a short value (minutes) on a paging route re-pages the same firing group repeatedly.
- **`send_resolved` (ALR-018):** `true` on a paging receiver emits a fire and a resolve per incident, roughly doubling its volume. Often deliberate - `info` unless it inflates a receiver already flagged by 13.3, then `medium`.
- **`resolve_timeout` (ALR-018):** global, default 5m; how fast an alert with no explicit resolve is treated as cleared.

### 13.5 Duplicate delivery and HA dedup health (ALR-017)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

# Alertmanager dedup only holds while the HA cluster is healthy.
AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-metadata)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s' "$AM_SAFE" | jq -r '.cluster | "cluster.status=\(.status) peers=\(.peer_count)"'

ALERTS="$(json_read 'type=="array" and all(.[]; (.labels|type)=="object" and (.labels.alertname|type)=="string" and (.receivers|type)=="array")' -H "$AUTH" "${AM_URL}/api/v2/alerts")" || exit 1
printf '%s' "$ALERTS" | jq '[.[]|select((.receivers|length)>1)|{alertname:.labels.alertname,receivers:[.receivers[].name]}]'
echo 'Multiple configured receivers are candidate evidence; verify intended fan-out and the declared HA peer count'
```

### 13.6 Stale silences masking real alerts (ALR-013)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

SILENCES="$(json_read 'type=="array" and all(.[];(.status.state|type)=="string" and (.matchers|type)=="array")' -H "$AUTH" "${AM_URL}/api/v2/silences")" || exit 1
printf '%s' "$SILENCES" | jq '[.[]|select(.status.state=="active")|{id,startsAt,endsAt,matcher_names:[.matchers[].name]}]'
echo 'Compare the observed silence window with its owner-approved expiry; active alone is not a fault'
```

### 13.7 le/quantile matcher normalization on Prometheus 3.x (ALR-019)

Prometheus 3.0 normalizes `le` (classic histograms) and `quantile` (summaries) label values to a float form on ingestion: `le="1"` becomes `le="1.0"`. An exact-string route or inhibition matcher pinned to the integer form silently stops selecting those series after the upgrade. Gate the whole check on the target's Prometheus major version.

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

BUILD="$(json_read '.status=="success" and (.data.version|type)=="string" and (.data.version|test("^v?[0-9]+[.][0-9]+[.][0-9]+"))' -H "$AUTH" "${PROM_URL}/api/v1/status/buildinfo")" || exit 1
PVER="$(printf '%s' "$BUILD" | jq -r '.data.version')"; PVER="${PVER#v}"; PMAJOR="${PVER%%.*}"
if [ "$PMAJOR" -lt 3 ]; then
  echo 'ALR-019 not-in-scope: verified Prometheus major version below 3'
else
AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-status)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
  printf '%s' "$AM_SAFE" | jq '[.. | objects | to_entries[]
    | select(.key | IN("matchers","source_matchers","target_matchers","match","match_re","source_match","source_match_re","target_match","target_match_re"))
    | {kind:.key,matchers:.value}]'

  echo 'Inspect only le/quantile integer-value matchers; other matchers and normalized values are not ALR-019 findings'
fi
```

Note: the projected matcher list is candidate evidence, not the verdict. Read each matcher in context - a matcher like `le="1.0"` (already normalized) or `le=~"1\\.0"` (correctly escaped) is fine; only a bare integer (`le="1"`, `quantile="0"`) is the finding. UTF-8 strict matcher mode is still opt-in in Alertmanager (fallback mode is the default through 0.33.x), so the escaping note applies regardless of parser mode.

### 13.8 Deprecated msteams delivery path (ALR-020)

`msteams_configs` depends on the Office 365 connector Microsoft is retiring; Alertmanager 0.28.0 added `msteamsv2_configs` (adaptive-card Workflows format) as the replacement. A receiver still on the old block parses but is a dying delivery path.

```bash
set -eu
set +x
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

# Receivers still carrying an msteams_configs block (the deprecated path).
AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-status)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s' "$AM_SAFE" | jq '[.receivers[] | select(any(.targets[]; .type=="msteams")) | .name]'
echo "flag: each hit is an ALR-020 finding (medium) - migrate that receiver to msteamsv2_configs; the Office 365 connector msteams_configs relies on is being retired"
```

## 14. Live suppression and page timing (ALR-022, ALR-023) - with retired rule-eval-health context (ALR-021 → audit-prometheus)

Two live checks (ALR-022, ALR-023) that everything above can pass while the page still never lands - a paging alert that is firing but *suppressed right now*, and a route that pages but late or muted at this clock - plus **non-scored context** on rule-evaluation health (retired `ALR-021`, now `/scoutflo:audit-prometheus` PROM-020/021). All read-only, proven live against the benchmark (Prometheus + vmalert + Alertmanager).

### 14.1 Rule-evaluation health (retired `ALR-021` → `/scoutflo:audit-prometheus` PROM-020/021 - non-scored context)

> **Retired as a scored check (v0.1.158):** rule-evaluation **health** is now `/scoutflo:audit-prometheus` (PROM-020/021). Kept here as context for the suppression (ALR-022) and page-timing (ALR-023) checks that follow - a rule that evaluates cleanly can still be suppressed or delayed at the routing layer, which is this audit's job. audit-alertmanager does not score rule-evaluation health.

`/api/v1/rules` `health`/`lastError` is the **primary, engine-agnostic** signal - both Prometheus and vmalert expose it. The self-metric confirmation is **engine-gated**, because the metric names differ:

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
PROM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 url)" # prometheus.url
[ -n "$PROM_URL" ] || { echo "Configure prometheus.url"; exit 1; }
RULES="$(json_read '.status=="success" and ((.warnings // [])|type)=="array" and ((.warnings // [])|length)==0 and (.data.groups|type)=="array" and all(.data.groups[]; (.name|type)=="string" and (.name|length)>0 and (.rules|type)=="array" and all(.rules[]; (.type|IN("alerting","recording")) and (.name|type)=="string" and (.name|length)>0))' -H "$AUTH" "${PROM_URL}/api/v1/rules")" || exit 1
printf '%s' "$RULES" | jq '[.data.groups[].rules[]|select(.type=="alerting")|{name,health,last_error_present:((.lastError // "")|length>0)}]'
echo 'Missing health is unassessed. This is rule-evaluation context for audit-prometheus, not an ALR finding'
```

Context (retired `ALR-021` → `/scoutflo:audit-prometheus` PROM-020/021 - **not scored here**): a rule can be *loaded* yet have `health!="ok"` or a `lastError`, so it has fired zero times and never will until the expression is fixed - e.g. "`CheckoutErrorBudgetBurn` loaded but `health=err`". `/scoutflo:audit-prometheus` scores that (PROM-020/021, with the same blast-radius reasoning - count of paging rules with `health!=ok` and the critical services left with a dead rule); `audit-alertmanager` consumes the verdict as a precondition and never emits an `ALR-021` finding. It matters to §14.2/§14.3 because a rule that evaluates cleanly can *still* be suppressed or delayed at the routing layer - which is exactly what ALR-022/ALR-023 below check. (An empty self-metric result **on the wrong engine** is `not observable`, never `healthy` - state which engine was detected when reading this as input.)

### 14.2 Live suppression of a paging alert (ALR-022)

```bash
set -eu
set +x

# Fixed read: errors stop this block; nothing raw is written to disk.
json_read() {
  jr_predicate="$1"; shift
  jr_raw="$(curl -q -s --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 30 --max-filesize 2097152 -w '\n%{http_code} %{content_type}' "$@")" || {
    jr_rc=$?; printf 'Read blocked: curl exit %s\n' "$jr_rc" >&2; return 1;
  }
  jr_meta="$(printf '%s\n' "$jr_raw" | tail -n 1)"
  jr_code="${jr_meta%% *}"; jr_ct="${jr_meta#* }"
  case "$jr_code" in [0-9][0-9][0-9]) ;; *) echo 'Read blocked: malformed HTTP metadata' >&2; return 1 ;; esac
  [ "$jr_code" = 200 ] || { printf 'Read blocked: HTTP %s (401/403 access, 404 endpoint, 429 rate limit, 5xx provider)\n' "$jr_code" >&2; return 1; }
  printf '%s' "$jr_ct" | grep -qi json || { echo 'Read blocked: expected JSON content type' >&2; return 1; }
  jr_body="$(printf '%s\n' "$jr_raw" | sed '$d')"
  printf '%s' "$jr_body" | jq -e -s "length == 1 and (.[0] | ($jr_predicate))" >/dev/null 2>&1 || { echo 'Read blocked: malformed or unsupported JSON response' >&2; return 1; }
  printf '%s' "$jr_body"
}
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
PROM_TOKEN="${PROM_TOKEN:-}"   # value of the var named by prometheus.token_env, if set; presence-checked, never printed, never logged
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"   # harmless placeholder header; never an empty bearer
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
ALERTS="$(json_read 'type=="array" and all(.[]; (.labels|type)=="object" and (.labels.alertname|type)=="string" and (.receivers|type)=="array")' -H "$AUTH" "${AM_URL}/api/v2/alerts?active=true&silenced=true&inhibited=true")" || exit 1
printf '%s' "$ALERTS" | jq -e 'all(.[];(.status.state|type)=="string")' >/dev/null || { echo 'Suppression evidence blocked: state absent'; exit 1; }
printf '%s' "$ALERTS" | jq '[.[]|select((.labels.severity=="critical" or .labels.severity=="warning") and .status.state=="suppressed")|{alertname:.labels.alertname,namespace:.labels.namespace,silencedBy:.status.silencedBy,inhibitedBy:.status.inhibitedBy}]'
```

Candidate evidence: an active paging-severity alert has `.status.state=="suppressed"`. Approved maintenance silences and intended inhibition are expected behavior. Emit ALR-022 only after proving the suppression is unintended or overbroad and removes intended paging coverage; cite the governing policy and affected silence/inhibition. Suppression metadata alone does not prove a lost human notification. "`PaymentsDown` (critical) is active but suppressed right now, `inhibitedBy` an over-broad `ClusterDown` inhibit rule - the payments page is eaten by a correlation rule meant to reduce noise." Blast radius is the count of currently-suppressed paging alerts and which silence/inhibit id owns each. Distinct from the config-side stale-silence check (ALR-013, section 13.6) which reads silence *definitions*; this reads live routing *state*. Remediation: `setup-lgtm#add-severity-routes-and-inhibition` for over-broad inhibit rules; an unintended silence expires through the Alertmanager UI/amtool (as in ALR-013).

### 14.3 Route timing and live-clock mute (ALR-023)

This adds only the **live-clock and latency** axis; the dangling/misconfigured mute-interval *definition* error is already owned by section 13.4 - cross-reference it, do not re-report it here.

```bash
set -eu
set +x
set +x
AM_PROJECT="${CLAUDE_PLUGIN_ROOT}/skills/audit-alertmanager/scripts/project-config.sh"
sh "$AM_PROJECT" check   # dependencies before any provider read
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
_SF_CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$_SF_CFG" ] || for _sf_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_sf_c" ] && { _SF_CFG="$_sf_c"; break; }; done
_SF_TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
[ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind)" != seq ] || { echo "Select one Prometheus target in SCOUTFLO_CONFIG"; exit 1; }
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" token_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own token_env, and this step reads PROM_TOKEN by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 token_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_TOKEN="$_sf_v"; export PROM_TOKEN; else unset PROM_TOKEN; echo "note: ${_sf_tv} (named by prometheus.token_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_user_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_user_env, and this step reads PROM_BASIC_USER by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_user_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_USER="$_sf_v"; export PROM_BASIC_USER; else unset PROM_BASIC_USER; echo "note: ${_sf_tv} (named by prometheus.basic_user_env) is not set in the secret store or the shell" >&2; fi; fi
if [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" = seq ]; then _sf_i=0; while [ "$_sf_i" -lt "$(sh "$_SF_TT" "$_SF_CFG" prometheus count 2>/dev/null || echo 0)" ]; do [ -z "$(sh "$_SF_TT" "$_SF_CFG" prometheus get "$_sf_i" basic_pass_env 2>/dev/null || true)" ] || { echo "prometheus in ${_SF_CFG} is a list of targets that each name their own basic_pass_env, and this step reads PROM_BASIC_PASS by its default name, so it cannot tell which target's value to use. It stops instead of guessing: give that target a config of its own where prometheus is a single block, and run with SCOUTFLO_CONFIG set to that file (and SCOUTFLO_AUDIT_DIR to its own folder)."; exit 1; }; _sf_i=$((_sf_i+1)); done; fi
_sf_tv="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 basic_pass_env 2>/dev/null || true)"; if [ -n "$_sf_tv" ] && [ "$(sh "$_SF_TT" "$_SF_CFG" prometheus kind 2>/dev/null || true)" != seq ]; then _sf_v="$(sh -c '( [ -f "$1" ] && . "$1" >/dev/null 2>&1; printenv -- "$2" ) 2>/dev/null || printenv -- "$2"' _ "$SCOUTFLO_ENV" "$_sf_tv" 2>/dev/null || true)"; if [ -n "$_sf_v" ]; then PROM_BASIC_PASS="$_sf_v"; export PROM_BASIC_PASS; else unset PROM_BASIC_PASS; echo "note: ${_sf_tv} (named by prometheus.basic_pass_env) is not set in the secret store or the shell" >&2; fi; fi
AM_URL="$(sh "$_SF_TT" "$_SF_CFG" prometheus get 0 alertmanager_url)" # prometheus.alertmanager_url
[ -n "$AM_URL" ] || { echo "Configure prometheus.alertmanager_url"; exit 1; }
PROM_TOKEN="${PROM_TOKEN:-}"
AUTH="Authorization: Bearer ${PROM_TOKEN}"
[ -n "$PROM_TOKEN" ] || AUTH="Accept: application/json"
if [ -n "${PROM_BASIC_USER:-}" ] && [ -n "${PROM_BASIC_PASS:-}" ]; then AUTH="Authorization: Basic $(printf '%s:%s' "$PROM_BASIC_USER" "$PROM_BASIC_PASS" | base64 | tr -d '\n')"; fi   # prom basic_user_env/basic_pass_env override (basic auth beats bearer)

AM_RESPONSE="$(curl -q -sS --proto '=http,https' --max-redirs 0 --connect-timeout 5 --max-time 15 --max-filesize 2097152 -H "$AUTH" -w '\n%{http_code} %{content_type}' "${AM_URL}/api/v2/status" 2>/dev/null)" || { AM_RC=$?; printf 'Alertmanager transport failed (curl exit %s); no raw response retained\n' "$AM_RC"; exit 1; }
AM_SAFE="$(printf '%s' "$AM_RESPONSE" | sh "$AM_PROJECT" http-status)" || { unset AM_RESPONSE; echo 'Alertmanager projection blocked; do not assess downstream checks'; exit 1; }
unset AM_RESPONSE
printf '%s' "$AM_SAFE" | jq '{route,time_intervals,mute_time_intervals}'
date -u '+now UTC: %Y-%m-%d %H:%M %A'   # compare against any mute/active interval whose route pages 24/7
```

Fail (ALR-023, medium): a paging route sets a large `group_wait` (minutes) - that latency is added to MTTA on every incident before the first page leaves ("severity=critical route sets `group_wait: 5m`, so every critical page is delayed 5 minutes by design"); OR a `mute_time_intervals` on a 24/7 paging route covers the current UTC time, so that route is paging nobody at this moment. Blast radius is the group_wait seconds added to MTTA and whether a paging route is muted at the current clock. Verified live: the benchmark's default route is `group_wait: 10s` (fine) with no mute intervals. Remediation: `setup-lgtm#add-severity-routes-and-inhibition`.
