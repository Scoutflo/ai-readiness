#!/bin/sh
# doctor.sh -- read-only connection preflight for the Scoutflo SRE Toolkit.
#
# Usage:
#   doctor.sh [--config FILE] [--out DIR] [--slack-test]
#
#   --config FILE   Config to read. Default: $HOME/.scoutflo/toolkit.yaml
#                   (or $SCOUTFLO_CONFIG when set).
#   --out DIR       Run directory for the matrix file.
#                   Default: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/<UTC date>
#   --slack-test    Send the Slack webhook test post. Off by default because
#                   it posts a visible message; pass it only after the user
#                   has explicitly confirmed in the conversation.
#
# Output contract:
#   stdout          One JSON object per line, one line per check:
#                   {"integration":"...","check":"...","configured":"yes|no",
#                    "env_var":"...","result":"pass|fail|env-missing|skipped",
#                    "http_code":"200"|null,"hint":"..."}
#   stderr          Human-readable progress and diagnostics only.
#   DIR/matrix.tsv  One appended TSV row per check, same seven fields,
#                   header written when the file is created.
#
# Exit codes:
#   0  every configured integration passed (skipped rows do not fail)
#   1  config file missing or unreadable (fix hint on stderr)
#   2  a configured integration names a *_env variable that is not set;
#      takes precedence over 3 because exporting it may fix the live checks
#   3  a live check failed, or a required binary is missing
#
# Guarantees:
#   - Read-only: every call is a GET or a status read. The one exception is
#     the Slack test post, which runs only with --slack-test.
#   - Unconfigured integrations are reported as skipped, never as failures.
#   - No secret value is ever printed. Tokens are read with printenv into
#     curl arguments only. No eval anywhere. No set -x ever: command tracing
#     would leak Authorization headers into scrollback and logs.
#   - Authorization headers are sent only when the block names a token_env
#     AND that variable is non-empty. An empty bearer header is never sent.

set -eu

# --- defaults and argument parsing -------------------------------------------

CONFIG="${SCOUTFLO_CONFIG:-${HOME}/.scoutflo/toolkit.yaml}"
OUT_DIR=""
SLACK_TEST=0
MAX_TIME="${CURL_MAX_TIME:-10}"  # seconds; example, tune to your network latency
CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"  # seconds; example, tune to your network latency

usage() {
  echo "usage: doctor.sh [--config FILE] [--out DIR] [--slack-test]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      [ $# -ge 2 ] || { echo "doctor: --config needs a value" >&2; exit 1; }
      CONFIG="$2"; shift 2 ;;
    --out)
      [ $# -ge 2 ] || { echo "doctor: --out needs a value" >&2; exit 1; }
      OUT_DIR="$2"; shift 2 ;;
    --slack-test)
      SLACK_TEST=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "doctor: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

note() { printf '%s\n' "$*" >&2; }

# --- load the global secret store, if present --------------------------------
# ~/.scoutflo/env is the canonical, home-anchored place connect puts credential
# exports so they are available in every session/terminal/dir. Source it (if it
# exists and is ours) so a token set once is seen here without re-exporting. It
# only sets *_env variables; no secret value is printed. A profile that already
# sources it makes this a no-op.
SCOUTFLO_ENV="${HOME}/.scoutflo/env"
if [ -f "$SCOUTFLO_ENV" ]; then
  # shellcheck disable=SC1090
  . "$SCOUTFLO_ENV" || note "doctor: warning: could not source ${SCOUTFLO_ENV} (continuing with current environment)"
fi

# --- hard stop: config must exist --------------------------------------------

if [ ! -f "$CONFIG" ]; then
  note "doctor: config not found: ${CONFIG}"
  note "fix: run /scoutflo:connect to create it from templates/toolkit.yaml.example"
  exit 1
fi
if [ ! -r "$CONFIG" ]; then
  note "doctor: config exists but is not readable: ${CONFIG}"
  note "fix: chmod 600 ${CONFIG} and make sure you own the file"
  exit 1
fi

[ -n "$OUT_DIR" ] || OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"
mkdir -p "$OUT_DIR"
MATRIX="${OUT_DIR}/matrix.tsv"
if [ ! -f "$MATRIX" ]; then
  printf 'integration\tcheck\tconfigured\tenv_var\tresult\thttp_code\thint\n' > "$MATRIX"
fi

# --- config parsing: yq fast path, sed fallback -------------------------------

HAVE_YQ=0
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CONFIG" >/dev/null 2>&1; then
  HAVE_YQ=1
else
  note "doctor: yq not usable; using the built-in flat parser (two-level keys only)"
fi

# cfg <block> <key>: print a two-level value from the config, or nothing.
# Fallback parser handles the flat layout of templates/toolkit.yaml.example:
# a top-level "block:" line followed by indented "key: value" lines.
cfg() {
  if [ "$HAVE_YQ" -eq 1 ]; then
    yq -r ".${1}.${2} // \"\"" "$CONFIG" 2>/dev/null || true
  else
    sed -n "/^${1}:/,/^[A-Za-z_]/p" "$CONFIG" \
      | sed -n "s/^[[:space:]]\{1,\}${2}:[[:space:]]*//p" \
      | head -n 1 \
      | sed -e 's/[[:space:]]#.*$//' -e 's/^"//' -e 's/"$//' \
            -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*$//'
  fi
}

# --- result emission -----------------------------------------------------------

ANY_FAIL=0
ANY_ENV_MISSING=0
CONFIGURED_COUNT=0

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# row <integration> <check> <configured> <env_var> <result> <http_code> <hint>
# Emits one JSON line to stdout and appends one TSV row to the matrix.
# Use "-" for http_code on non-HTTP checks; it becomes null in the JSON.
row() {
  r_int="$1"; r_chk="$2"; r_cfg="$3"; r_env="$4"; r_res="$5"; r_http="$6"
  r_hint="$(printf '%s' "$7" | tr '\t\n' '  ')"
  if [ -n "$r_http" ] && [ "$r_http" != "-" ]; then
    r_json_http="\"$(esc "$r_http")\""
  else
    r_http="-"; r_json_http="null"
  fi
  printf '{"integration":"%s","check":"%s","configured":"%s","env_var":"%s","result":"%s","http_code":%s,"hint":"%s"}\n' \
    "$(esc "$r_int")" "$(esc "$r_chk")" "$(esc "$r_cfg")" "$(esc "$r_env")" \
    "$(esc "$r_res")" "$r_json_http" "$(esc "$r_hint")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$r_int" "$r_chk" "$r_cfg" "$r_env" "$r_res" "$r_http" "$r_hint" >> "$MATRIX"
  case "$r_res" in
    fail)        ANY_FAIL=1 ;;
    env-missing) ANY_ENV_MISSING=1 ;;
  esac
}

# --- token resolution (presence only, no eval) ---------------------------------

# resolve_token <block>: sets TOKEN_VAR (env var name or empty), TOKEN (value or
# empty; never printed), TOKEN_STATE (none|set|missing).
resolve_token() {
  TOKEN_VAR="$(cfg "$1" token_env)"
  TOKEN=""
  TOKEN_STATE="none"
  if [ -n "$TOKEN_VAR" ]; then
    TOKEN="$(printenv "$TOKEN_VAR" 2>/dev/null || true)"
    if [ -n "$TOKEN" ]; then TOKEN_STATE="set"; else TOKEN_STATE="missing"; fi
  fi
}

# --- HTTP helpers ---------------------------------------------------------------

# http_get <url> <token-or-empty>: sets HTTP_CODE ("000" on transport failure)
# and CURL_RC. The Authorization header is attached only when the token is
# non-empty, so an empty bearer header is never sent.
http_get() {
  hg_url="$1"; hg_tok="$2"
  CURL_RC=0
  if [ -n "$hg_tok" ]; then
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Authorization: Bearer ${hg_tok}" "$hg_url")" || CURL_RC=$?
  else
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      "$hg_url")" || CURL_RC=$?
  fi
}

transport_hint() {
  case "$1" in
    6)     echo "curl exit 6: DNS lookup failed; typo in the URL, or the host resolves only on VPN or internal DNS" ;;
    7)     echo "curl exit 7: connection refused; wrong port, service not exposed, or the port-forward is not running" ;;
    28)    echo "curl exit 28: timeout after ${MAX_TIME}s; check the network path before raising CURL_MAX_TIME" ;;
    35|60) echo "curl exit $1: TLS failure; trust the internal CA properly, never disable verification" ;;
    *)     echo "curl exit $1: transport failure before any HTTP response" ;;
  esac
}

http_hint() {
  case "$1" in
    401) echo "HTTP 401: token missing, invalid, or expired; recreate it per connect references/providers.md and re-export" ;;
    403) echo "HTTP 403: token authenticated but scope or role too low; raise to the tier scopes in connect references/providers.md" ;;
    404) echo "HTTP 404: wrong path, wrong region host, or a path prefix; verify the endpoint against your deployment" ;;
    *)   echo "HTTP $1: unexpected status; inspect the endpoint manually" ;;
  esac
}

# live_check <integration> <check> <url> <env_var_label> <token-or-empty>
# Expects HTTP 200. Records pass/fail with the observed code and a hint.
live_check() {
  lc_int="$1"; lc_chk="$2"; lc_url="$3"; lc_env="$4"; lc_tok="$5"
  note "doctor: checking ${lc_int} ${lc_chk}: GET ${lc_url}"
  http_get "$lc_url" "$lc_tok"
  if [ "$CURL_RC" -ne 0 ]; then
    row "$lc_int" "$lc_chk" yes "$lc_env" fail "000" "$(transport_hint "$CURL_RC") (${lc_url})"
  elif [ "$HTTP_CODE" = "200" ]; then
    row "$lc_int" "$lc_chk" yes "$lc_env" pass "$HTTP_CODE" "-"
  else
    row "$lc_int" "$lc_chk" yes "$lc_env" fail "$HTTP_CODE" "$(http_hint "$HTTP_CODE")"
  fi
}

# token_gate <integration> <check...>: when TOKEN_STATE=missing, records the
# env-missing row plus one blocked row per named check and returns 1.
token_gate() {
  tg_int="$1"; shift
  if [ "$TOKEN_STATE" = "missing" ]; then
    row "$tg_int" env yes "$TOKEN_VAR" env-missing - "add it once to ~/.scoutflo/env: echo 'export ${TOKEN_VAR}=\"<paste>\"' >> ~/.scoutflo/env (Windows PowerShell: setx ${TOKEN_VAR} \"<paste>\"), then rerun doctor; created per connect references/providers.md"
    for tg_chk in "$@"; do
      row "$tg_int" "$tg_chk" yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set"
    done
    return 1
  fi
  if [ "$TOKEN_STATE" = "set" ]; then
    row "$tg_int" env yes "$TOKEN_VAR" pass - -
  fi
  return 0
}

# --- required binaries ----------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
  row toolkit binary-curl yes - pass - -
else
  row toolkit binary-curl yes - fail - "install curl; doctor cannot run any live check without it"
  note "doctor: curl is missing; stopping before live checks"
  exit 3
fi
if command -v jq >/dev/null 2>&1; then
  row toolkit binary-jq yes - pass - -
else
  row toolkit binary-jq yes - fail - "install jq; every audit and setup skill parses JSON with it"
fi

# --- grafana ---------------------------------------------------------------------

GRAFANA_URL="$(cfg grafana url)"
if [ -z "$GRAFANA_URL" ]; then
  row grafana configured no - skipped - "add a grafana block via /scoutflo:connect if you run Grafana"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  GRAFANA_URL="${GRAFANA_URL%/}"
  resolve_token grafana
  if token_gate grafana health identity; then
    live_check grafana health   "${GRAFANA_URL}/api/health" "${TOKEN_VAR:-none}" "$TOKEN"
    live_check grafana identity "${GRAFANA_URL}/api/org"    "${TOKEN_VAR:-none}" "$TOKEN"
  fi
fi

# --- sentry ------------------------------------------------------------------------

SENTRY_HOST="$(cfg sentry host)"
if [ -z "$SENTRY_HOST" ]; then
  row sentry configured no - skipped - "add a sentry block via /scoutflo:connect if you run Sentry"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  SENTRY_ORG="$(cfg sentry org)"
  resolve_token sentry
  if [ -z "$SENTRY_ORG" ]; then
    row sentry config yes "${TOKEN_VAR:-none}" fail - "sentry.org is empty in toolkit.yaml; set your org slug"
  elif token_gate sentry org; then
    live_check sentry org "https://${SENTRY_HOST}/api/0/organizations/${SENTRY_ORG}/" "${TOKEN_VAR:-none}" "$TOKEN"
  fi
fi

# --- pagerduty ------------------------------------------------------------------------
# PagerDuty auth is "Authorization: Token token=<key>", not a Bearer header, so this
# block uses its own curl calls instead of live_check/http_get.
# The abilities probe validates the key; the analytics probe is a POST that reads
# (filter body, changes nothing) — read-only keys are documented GET-only, so a 403
# there is recorded as skipped-with-reason, never a failure: audit-pagerduty reads
# that row to decide whether to run its actionability section or exclude it honestly.

PD_TOKEN_VAR_CHECK="$(cfg pagerduty token_env)"
if [ -z "$PD_TOKEN_VAR_CHECK" ]; then
  row pagerduty configured no - skipped - "add a pagerduty block via /scoutflo:connect if you run PagerDuty"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  PD_REGION="$(cfg pagerduty region)"
  case "$PD_REGION" in
    eu) PD_API="https://api.eu.pagerduty.com" ;;
    *)  PD_API="https://api.pagerduty.com" ;;
  esac
  resolve_token pagerduty
  if token_gate pagerduty abilities analytics; then
    note "doctor: checking pagerduty abilities: GET ${PD_API}/abilities"
    PD_RC=0
    PD_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Authorization: Token token=${TOKEN}" \
      -H "Content-Type: application/json" "${PD_API}/abilities")" || PD_RC=$?
    if [ "$PD_RC" -ne 0 ]; then
      row pagerduty abilities yes "$TOKEN_VAR" fail "000" "$(transport_hint "$PD_RC") (${PD_API}/abilities)"
    elif [ "$PD_CODE" = "200" ]; then
      row pagerduty abilities yes "$TOKEN_VAR" pass "$PD_CODE" "-"
    elif [ "$PD_CODE" = "401" ]; then
      row pagerduty abilities yes "$TOKEN_VAR" fail "$PD_CODE" "HTTP 401: key invalid or revoked, or wrong region host (pagerduty.region: us vs eu); recreate per connect references/providers.md"
    else
      row pagerduty abilities yes "$TOKEN_VAR" fail "$PD_CODE" "$(http_hint "$PD_CODE")"
    fi
    if [ "$PD_CODE" = "200" ]; then
      # Read-only-by-effect POST: aggregated incident metrics over the last 7 days.
      note "doctor: checking pagerduty analytics: POST ${PD_API}/analytics/metrics/incidents/all (read-only filter body)"
      PDA_RC=0
      PDA_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -X POST \
        -H "Authorization: Token token=${TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"filters":{"created_at_start":"'"$(date -u -v-7d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT00:00:00Z)"'"}}' \
        "${PD_API}/analytics/metrics/incidents/all")" || PDA_RC=$?
      if [ "$PDA_RC" -ne 0 ]; then
        row pagerduty analytics yes "$TOKEN_VAR" skipped "000" "$(transport_hint "$PDA_RC"); audit-pagerduty will exclude the actionability section with this reason"
      elif [ "$PDA_CODE" = "200" ]; then
        row pagerduty analytics yes "$TOKEN_VAR" pass "$PDA_CODE" "-"
      elif [ "$PDA_CODE" = "403" ] || [ "$PDA_CODE" = "402" ]; then
        row pagerduty analytics yes "$TOKEN_VAR" skipped "$PDA_CODE" "HTTP ${PDA_CODE}: analytics blocked for this key or plan (read-only keys are GET-only; Analytics may need a higher plan); audit-pagerduty will exclude the actionability section with this reason, not fail"
      else
        row pagerduty analytics yes "$TOKEN_VAR" skipped "$PDA_CODE" "HTTP ${PDA_CODE}: analytics not confirmed; audit-pagerduty will exclude the actionability section with this reason"
      fi
    fi
  fi
fi

# --- datadog ------------------------------------------------------------------------
# Datadog needs a key PAIR: API key (DD-API-KEY) + Application key (DD-APPLICATION-KEY).
# Both headers are custom, so this block uses its own curl calls, not http_get.
# The validate call tests the API key alone; the monitor call tests the app key +
# monitors_read scope. The cost probe is informational only (like the AWS one): a
# missing usage/billing scope never fails doctor; audit-datadog reads that row to run
# or exclude its non-scored cost section.

DD_SITE="$(cfg datadog site)"
if [ -z "$DD_SITE" ]; then
  row datadog configured no - skipped - "add a datadog block via /scoutflo:connect if you run Datadog"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  DD_API_VAR="$(cfg datadog api_key_env)"
  DD_APP_VAR="$(cfg datadog app_key_env)"
  DD_API_KEY=""; DD_APP_KEY=""
  DD_BLOCKED=0
  if [ -z "$DD_API_VAR" ] || [ -z "$DD_APP_VAR" ]; then
    row datadog config yes - fail - "datadog needs both api_key_env and app_key_env in toolkit.yaml; set them per connect references/providers.md"
    DD_BLOCKED=1
  else
    DD_API_KEY="$(printenv "$DD_API_VAR" 2>/dev/null || true)"
    DD_APP_KEY="$(printenv "$DD_APP_VAR" 2>/dev/null || true)"
    if [ -z "$DD_API_KEY" ]; then
      row datadog env yes "$DD_API_VAR" env-missing - "add it once to ~/.scoutflo/env: echo 'export ${DD_API_VAR}=\"<paste>\"' >> ~/.scoutflo/env (Windows PowerShell: setx ${DD_API_VAR} \"<paste>\"), then rerun doctor; created per connect references/providers.md"
      DD_BLOCKED=1
    elif [ -z "$DD_APP_KEY" ]; then
      row datadog env yes "$DD_APP_VAR" env-missing - "add it once to ~/.scoutflo/env: echo 'export ${DD_APP_VAR}=\"<paste>\"' >> ~/.scoutflo/env (Windows PowerShell: setx ${DD_APP_VAR} \"<paste>\"), then rerun doctor; the app key is the second half of the pair"
      DD_BLOCKED=1
    else
      row datadog env yes "${DD_API_VAR}+${DD_APP_VAR}" pass - -
    fi
  fi
  if [ "$DD_BLOCKED" -eq 1 ]; then
    row datadog validate yes "${DD_API_VAR:-none}" skipped - "blocked: both Datadog keys must be set"
    row datadog monitors-read yes "${DD_APP_VAR:-none}" skipped - "blocked: both Datadog keys must be set"
  else
    DD_HOST="api.${DD_SITE}"
    note "doctor: checking datadog validate: GET https://${DD_HOST}/api/v1/validate"
    DDV_RC=0
    DDV_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "DD-API-KEY: ${DD_API_KEY}" "https://${DD_HOST}/api/v1/validate")" || DDV_RC=$?
    if [ "$DDV_RC" -ne 0 ]; then
      row datadog validate yes "$DD_API_VAR" fail "000" "$(transport_hint "$DDV_RC") (https://${DD_HOST}/api/v1/validate)"
      DD_BLOCKED=1
    elif [ "$DDV_CODE" = "200" ]; then
      row datadog validate yes "$DD_API_VAR" pass "$DDV_CODE" "-"
    else
      row datadog validate yes "$DD_API_VAR" fail "$DDV_CODE" "HTTP ${DDV_CODE}: API key invalid or wrong site (datadog.site '${DD_SITE}'); a valid key on the wrong site returns 403"
      DD_BLOCKED=1
    fi
    if [ "$DD_BLOCKED" -eq 0 ]; then
      note "doctor: checking datadog monitors-read: GET https://${DD_HOST}/api/v1/monitor?page_size=1"
      DDM_RC=0
      DDM_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
        "https://${DD_HOST}/api/v1/monitor?page_size=1")" || DDM_RC=$?
      if [ "$DDM_RC" -ne 0 ]; then
        row datadog monitors-read yes "$DD_APP_VAR" fail "000" "$(transport_hint "$DDM_RC")"
      elif [ "$DDM_CODE" = "200" ]; then
        row datadog monitors-read yes "$DD_APP_VAR" pass "$DDM_CODE" "-"
      elif [ "$DDM_CODE" = "403" ]; then
        row datadog monitors-read yes "$DD_APP_VAR" fail "$DDM_CODE" "HTTP 403: app key invalid, missing the monitors_read scope, or belongs to a disabled user; check the app key scopes per connect references/providers.md"
      else
        row datadog monitors-read yes "$DD_APP_VAR" fail "$DDM_CODE" "$(http_hint "$DDM_CODE")"
      fi
      # Informational cost probe. A missing usage_read/billing_read scope never fails
      # doctor; audit-datadog reads this row to run the non-scored cost section or
      # report it excluded with the reason.
      DD_COST_CHECKS="$(cfg datadog cost_checks)"
      if [ "$DD_COST_CHECKS" = "false" ]; then
        row datadog cost-permissions yes "$DD_APP_VAR" skipped - "datadog.cost_checks is false in toolkit.yaml; cost section will be skipped"
      else
        DDC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
          "https://${DD_HOST}/api/v1/usage/summary?start_month=$(date -u +%Y-%m-01T00 2>/dev/null)")" || true
        if [ "$DDC_CODE" = "200" ]; then
          row datadog cost-permissions yes "$DD_APP_VAR" pass "$DDC_CODE" "-"
        else
          row datadog cost-permissions yes "$DD_APP_VAR" skipped "${DDC_CODE:-000}" "usage_read/billing_read not confirmed (HTTP ${DDC_CODE:-000}); audit-datadog will report the cost section excluded with this reason, not fail"
        fi
      fi
    else
      row datadog monitors-read yes "$DD_APP_VAR" skipped - "blocked: API key validation failed above"
    fi
  fi
fi

# --- elk / kibana -------------------------------------------------------------------
# Kibana authenticates the Elasticsearch API key with "Authorization: ApiKey <encoded>",
# not a Bearer header, so this block uses its own curl call. /api/alerting/_health is the
# cheapest alerting-scoped probe and is itself an audit signal.

ELK_KIBANA_URL="$(cfg elk kibana_url)"
if [ -z "$ELK_KIBANA_URL" ]; then
  row elk configured no - skipped - "add an elk block via /scoutflo:connect if you run Kibana alerting"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  ELK_KIBANA_URL="${ELK_KIBANA_URL%/}"
  ELK_TOKEN_VAR="$(cfg elk token_env)"
  ELK_TOKEN=""
  ELK_TOKEN_STATE="none"
  if [ -n "$ELK_TOKEN_VAR" ]; then
    ELK_TOKEN="$(printenv "$ELK_TOKEN_VAR" 2>/dev/null || true)"
    if [ -n "$ELK_TOKEN" ]; then ELK_TOKEN_STATE="set"; else ELK_TOKEN_STATE="missing"; fi
  fi
  if [ -z "$ELK_TOKEN_VAR" ]; then
    row elk config yes - fail - "elk.token_env is empty in toolkit.yaml; name the variable holding the Kibana API key"
  elif [ "$ELK_TOKEN_STATE" = "missing" ]; then
    row elk env yes "$ELK_TOKEN_VAR" env-missing - "export ${ELK_TOKEN_VAR} in this shell, then rerun doctor; created per connect references/providers.md"
    row elk alerting-health yes "$ELK_TOKEN_VAR" skipped - "blocked: ${ELK_TOKEN_VAR} is not set"
  else
    row elk env yes "$ELK_TOKEN_VAR" pass - -
    note "doctor: checking elk alerting-health: GET ${ELK_KIBANA_URL}/api/alerting/_health"
    ELK_RC=0
    ELK_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Authorization: ApiKey ${ELK_TOKEN}" "${ELK_KIBANA_URL}/api/alerting/_health")" || ELK_RC=$?
    if [ "$ELK_RC" -ne 0 ]; then
      row elk alerting-health yes "$ELK_TOKEN_VAR" fail "000" "$(transport_hint "$ELK_RC") (${ELK_KIBANA_URL}/api/alerting/_health)"
    elif [ "$ELK_CODE" = "200" ]; then
      row elk alerting-health yes "$ELK_TOKEN_VAR" pass "$ELK_CODE" "-"
    elif [ "$ELK_CODE" = "404" ]; then
      row elk alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "HTTP 404: elk.kibana_url likely points at Elasticsearch, not Kibana, or a space/base-path prefix is wrong; alerting rules live in Kibana (:5601 self-managed)"
    elif [ "$ELK_CODE" = "401" ] || [ "$ELK_CODE" = "403" ]; then
      row elk alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "HTTP ${ELK_CODE}: key invalid, or the role lacks Kibana Read on Stack Rules; grant the privileges in connect references/providers.md"
    else
      row elk alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "$(http_hint "$ELK_CODE")"
    fi
  fi
fi

# --- jsm operations -----------------------------------------------------------------
# JSM Operations (the cloud successor to standalone Opsgenie) authenticates with an
# Atlassian API token over HTTP Basic (email:token), NOT a Bearer header and NOT a
# classic Opsgenie GenieKey. Every path needs the site's cloud_id; resolve it from
# jsm.cloud_id when set, else from the unauthenticated tenant_info edge route. The
# cheapest Operations-scoped probe is one page of alerts.

JSM_SITE="$(cfg jsm site)"
JSM_CLOUD_ID_CFG="$(cfg jsm cloud_id)"
if [ -z "$JSM_SITE" ] && [ -z "$JSM_CLOUD_ID_CFG" ]; then
  row jsm configured no - skipped - "add a jsm block via /scoutflo:connect if you run JSM Operations (Opsgenie successor)"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  JSM_EMAIL_VAR="$(cfg jsm email_env)"
  JSM_TOKEN_VAR="$(cfg jsm token_env)"
  JSM_EMAIL_VAL=""
  JSM_TOKEN_VAL=""
  JSM_BLOCKED=0
  if [ -z "$JSM_EMAIL_VAR" ] || [ -z "$JSM_TOKEN_VAR" ]; then
    row jsm config yes - fail - "jsm needs both email_env and token_env in toolkit.yaml; set them per connect references/providers.md"
    JSM_BLOCKED=1
  else
    JSM_EMAIL_VAL="$(printenv "$JSM_EMAIL_VAR" 2>/dev/null || true)"
    JSM_TOKEN_VAL="$(printenv "$JSM_TOKEN_VAR" 2>/dev/null || true)"
    if [ -z "$JSM_EMAIL_VAL" ]; then
      row jsm env yes "$JSM_EMAIL_VAR" env-missing - "export ${JSM_EMAIL_VAR} in this shell, then rerun doctor; it is the Basic-auth username (your Atlassian email)"
      JSM_BLOCKED=1
    elif [ -z "$JSM_TOKEN_VAL" ]; then
      row jsm env yes "$JSM_TOKEN_VAR" env-missing - "export ${JSM_TOKEN_VAR} in this shell, then rerun doctor; created per connect references/providers.md"
      JSM_BLOCKED=1
    else
      row jsm env yes "${JSM_EMAIL_VAR}+${JSM_TOKEN_VAR}" pass - -
    fi
  fi
  if [ "$JSM_BLOCKED" -eq 1 ]; then
    row jsm alerts-read yes "${JSM_TOKEN_VAR:-none}" skipped - "blocked: JSM credentials not resolved"
  else
    # Resolve cloud_id: config value wins; else tenant_info (unauthenticated, no secret).
    JSM_CLOUD_ID="$JSM_CLOUD_ID_CFG"
    if [ -z "$JSM_CLOUD_ID" ]; then
      note "doctor: resolving jsm cloud_id: GET https://${JSM_SITE}/_edge/tenant_info"
      JSM_CLOUD_ID="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        "https://${JSM_SITE}/_edge/tenant_info" 2>/dev/null | jq -r '.cloudId // empty' 2>/dev/null || true)"
    fi
    if [ -z "$JSM_CLOUD_ID" ]; then
      row jsm alerts-read yes "$JSM_TOKEN_VAR" fail - "could not resolve cloud_id from jsm.site '${JSM_SITE}' (tenant_info route blocked or wrong site); set jsm.cloud_id explicitly per connect references/providers.md"
    else
      JSM_BASE="https://api.atlassian.com/jsm/ops/api/${JSM_CLOUD_ID}/v1"
      note "doctor: checking jsm alerts-read: GET ${JSM_BASE}/alerts?size=1"
      JSM_RC=0
      JSM_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -u "${JSM_EMAIL_VAL}:${JSM_TOKEN_VAL}" "${JSM_BASE}/alerts?size=1")" || JSM_RC=$?
      if [ "$JSM_RC" -ne 0 ]; then
        row jsm alerts-read yes "$JSM_TOKEN_VAR" fail "000" "$(transport_hint "$JSM_RC") (${JSM_BASE}/alerts)"
      elif [ "$JSM_CODE" = "200" ]; then
        row jsm alerts-read yes "$JSM_TOKEN_VAR" pass "$JSM_CODE" "-"
      elif [ "$JSM_CODE" = "401" ]; then
        row jsm alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 401: bad API token or email; the token is the Basic-auth password and ${JSM_EMAIL_VAR} the username (not a GenieKey); recreate per connect references/providers.md"
      elif [ "$JSM_CODE" = "403" ]; then
        row jsm alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 403: the token's user lacks JSM Operations access; grant a read/observer Operations role per connect references/providers.md"
      elif [ "$JSM_CODE" = "404" ]; then
        row jsm alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 404: wrong cloud_id (resolved '${JSM_CLOUD_ID}') or the site has no Operations; verify jsm.site/jsm.cloud_id"
      else
        row jsm alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "$(http_hint "$JSM_CODE")"
      fi
    fi
  fi
fi

# --- zenduty (xurrent imr) ----------------------------------------------------------
# Zenduty authenticates with "Authorization: Token <key>" (the literal word Token, NOT
# Bearer), so this block uses its own curl call. GET /api/account/teams/ is the cheapest
# list read and the doctor probe. Zenduty has no read-only key scope; a Bot Token (Beta)
# is the least-privilege path (see connect references/providers.md).

ZD_TOKEN_VAR_CHECK="$(cfg zenduty token_env)"
if [ -z "$ZD_TOKEN_VAR_CHECK" ]; then
  row zenduty configured no - skipped - "add a zenduty block via /scoutflo:connect if you run Zenduty (Xurrent IMR)"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  ZD_TOKEN_VAR="$ZD_TOKEN_VAR_CHECK"
  ZD_TOKEN=""
  ZD_TOKEN_STATE="missing"
  ZD_TOKEN="$(printenv "$ZD_TOKEN_VAR" 2>/dev/null || true)"
  [ -n "$ZD_TOKEN" ] && ZD_TOKEN_STATE="set"
  if [ "$ZD_TOKEN_STATE" = "missing" ]; then
    row zenduty env yes "$ZD_TOKEN_VAR" env-missing - "export ${ZD_TOKEN_VAR} in this shell, then rerun doctor; created per connect references/providers.md"
    row zenduty teams-read yes "$ZD_TOKEN_VAR" skipped - "blocked: ${ZD_TOKEN_VAR} is not set"
  else
    row zenduty env yes "$ZD_TOKEN_VAR" pass - -
    note "doctor: checking zenduty teams-read: GET https://www.zenduty.com/api/account/teams/"
    ZD_RC=0
    ZD_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Authorization: Token ${ZD_TOKEN}" "https://www.zenduty.com/api/account/teams/")" || ZD_RC=$?
    if [ "$ZD_RC" -ne 0 ]; then
      row zenduty teams-read yes "$ZD_TOKEN_VAR" fail "000" "$(transport_hint "$ZD_RC") (https://www.zenduty.com/api/account/teams/)"
    elif [ "$ZD_CODE" = "200" ]; then
      row zenduty teams-read yes "$ZD_TOKEN_VAR" pass "$ZD_CODE" "-"
    elif [ "$ZD_CODE" = "401" ] || [ "$ZD_CODE" = "403" ]; then
      row zenduty teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "HTTP ${ZD_CODE}: key invalid or not prefixed correctly; the header must be 'Authorization: Token <key>' (the literal word Token, not Bearer); recreate per connect references/providers.md"
    elif [ "$ZD_CODE" = "429" ]; then
      row zenduty teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "HTTP 429: rate-limited (Zenduty limits are tight and per-endpoint-class); wait about a minute and rerun doctor"
    else
      row zenduty teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "$(http_hint "$ZD_CODE")"
    fi
  fi
fi

# --- groundcover --------------------------------------------------------------------
# Groundcover authenticates with "Authorization: Bearer <key>" on a service-account key,
# plus an "X-Backend-Id" header for multi-backend accounts. There is no whoami endpoint,
# so POST /api/monitors/list (with an empty sources filter) is the cheapest read and the
# doctor probe. It is a read-by-query POST, not a mutation.

GC_TOKEN_VAR_CHECK="$(cfg groundcover token_env)"
if [ -z "$GC_TOKEN_VAR_CHECK" ]; then
  row groundcover configured no - skipped - "add a groundcover block via /scoutflo:connect if you run groundcover"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  GC_TOKEN_VAR="$GC_TOKEN_VAR_CHECK"
  GC_TOKEN="$(printenv "$GC_TOKEN_VAR" 2>/dev/null || true)"
  GC_API="$(cfg groundcover api_url)"
  [ -n "$GC_API" ] || GC_API="https://api.groundcover.com"
  GC_API="${GC_API%/}"
  GC_BACKEND="$(cfg groundcover backend_id)"
  if [ -z "$GC_TOKEN" ]; then
    row groundcover env yes "$GC_TOKEN_VAR" env-missing - "export ${GC_TOKEN_VAR} in this shell, then rerun doctor; created per connect references/providers.md"
    row groundcover monitors-read yes "$GC_TOKEN_VAR" skipped - "blocked: ${GC_TOKEN_VAR} is not set"
  else
    row groundcover env yes "$GC_TOKEN_VAR" pass - -
    note "doctor: checking groundcover monitors-read: POST ${GC_API}/api/monitors/list"
    GC_RC=0
    if [ -n "$GC_BACKEND" ]; then
      GC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -H "Authorization: Bearer ${GC_TOKEN}" -H "X-Backend-Id: ${GC_BACKEND}" \
        -H "Content-Type: application/json" \
        -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || GC_RC=$?
    else
      GC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -H "Authorization: Bearer ${GC_TOKEN}" -H "Content-Type: application/json" \
        -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || GC_RC=$?
    fi
    if [ "$GC_RC" -ne 0 ]; then
      row groundcover monitors-read yes "$GC_TOKEN_VAR" fail "000" "$(transport_hint "$GC_RC") (${GC_API}/api/monitors/list)"
    elif [ "$GC_CODE" = "200" ]; then
      row groundcover monitors-read yes "$GC_TOKEN_VAR" pass "$GC_CODE" "-"
    elif [ "$GC_CODE" = "401" ]; then
      row groundcover monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "HTTP 401: API key invalid or expired; recreate on a Viewer-role service account per connect references/providers.md"
    elif [ "$GC_CODE" = "403" ]; then
      row groundcover monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "HTTP 403: key lacks access, or this is a multi-backend account and groundcover.backend_id (X-Backend-Id) is missing or wrong"
    else
      row groundcover monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "$(http_hint "$GC_CODE")"
    fi
  fi
fi

# --- prometheus and alertmanager (one block, shared optional token) -----------------

PROM_URL="$(cfg prometheus url)"
AM_URL="$(cfg prometheus alertmanager_url)"
if [ -z "$PROM_URL" ] && [ -z "$AM_URL" ]; then
  row prometheus configured no - skipped - "add a prometheus block via /scoutflo:connect if you run Prometheus"
  row alertmanager configured no - skipped - "-"
else
  resolve_token prometheus
  PROM_BLOCKED=0
  if [ "$TOKEN_STATE" = "missing" ]; then
    PROM_BLOCKED=1
    row prometheus env yes "$TOKEN_VAR" env-missing - "export ${TOKEN_VAR} in this shell, then rerun doctor"
  elif [ "$TOKEN_STATE" = "set" ]; then
    row prometheus env yes "$TOKEN_VAR" pass - -
  fi
  if [ -n "$PROM_URL" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    PROM_URL="${PROM_URL%/}"
    if [ "$PROM_BLOCKED" -eq 1 ]; then
      row prometheus query yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set"
    else
      # vector(1) succeeds on a server with zero targets: it tests the API, not the fleet.
      live_check prometheus query "${PROM_URL}/api/v1/query?query=vector%281%29" "${TOKEN_VAR:-none}" "$TOKEN"
    fi
  else
    row prometheus configured no - skipped - "prometheus.url is empty; only alertmanager_url is set"
  fi
  if [ -n "$AM_URL" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    AM_URL="${AM_URL%/}"
    if [ "$PROM_BLOCKED" -eq 1 ]; then
      row alertmanager status yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set"
    else
      live_check alertmanager status "${AM_URL}/api/v2/status" "${TOKEN_VAR:-none}" "$TOKEN"
    fi
  else
    row alertmanager configured no - skipped - "set prometheus.alertmanager_url if you run Alertmanager"
  fi
fi

# --- loki, tempo, mimir (same shape: /ready, optional token) -------------------------

for STORE in loki tempo mimir; do
  STORE_URL="$(cfg "$STORE" url)"
  if [ -z "$STORE_URL" ]; then
    row "$STORE" configured no - skipped - "add a ${STORE} block via /scoutflo:connect if you run it"
    continue
  fi
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  STORE_URL="${STORE_URL%/}"
  resolve_token "$STORE"
  if token_gate "$STORE" ready; then
    live_check "$STORE" ready "${STORE_URL}/ready" "${TOKEN_VAR:-none}" "$TOKEN"
  fi
done

# --- victoriametrics and vmalert -------------------------------------------------------

VM_URL="$(cfg victoriametrics url)"
if [ -z "$VM_URL" ]; then
  row victoriametrics configured no - skipped - "add a victoriametrics block via /scoutflo:connect if you run it"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  VM_URL="${VM_URL%/}"
  resolve_token victoriametrics
  if token_gate victoriametrics health vmalert-health; then
    live_check victoriametrics health "${VM_URL}/health" "${TOKEN_VAR:-none}" "$TOKEN"
    VMALERT_URL="$(cfg victoriametrics vmalert_url)"
    if [ -n "$VMALERT_URL" ]; then
      VMALERT_URL="${VMALERT_URL%/}"
      live_check vmalert health "${VMALERT_URL}/health" "${TOKEN_VAR:-none}" "$TOKEN"
    else
      row vmalert configured no - skipped - "set victoriametrics.vmalert_url if vmalert evaluates your rules"
    fi
  fi
fi

# --- digitalocean ------------------------------------------------------------------------

DO_TOKEN_VAR_CHECK="$(cfg digitalocean token_env)"
if [ -z "$DO_TOKEN_VAR_CHECK" ]; then
  row digitalocean configured no - skipped - "add a digitalocean block via /scoutflo:connect if you run DigitalOcean"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  # audit-digitalocean runs almost entirely on doctl; surface a missing CLI as its
  # own row (matching aws/gcloud/kubectl) instead of letting the audit fail downstream.
  if ! command -v doctl >/dev/null 2>&1; then
    row digitalocean binary-doctl yes - fail - "digitalocean is configured but doctl is not installed; install it (https://docs.digitalocean.com/reference/doctl/how-to/install/) — audit-digitalocean uses doctl for most checks"
  fi
  resolve_token digitalocean
  if token_gate digitalocean account; then
    live_check digitalocean account "https://api.digitalocean.com/v2/account" "${TOKEN_VAR:-none}" "$TOKEN"
  fi
fi

# --- gcp (gcloud identity, not a static bearer token) -------------------------------------

GCP_PROJECT="$(cfg gcp project)"
if [ -z "$GCP_PROJECT" ]; then
  row gcp configured no - skipped - "add a gcp block via /scoutflo:connect if you run Google Cloud"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  if ! command -v gcloud >/dev/null 2>&1; then
    row gcp binary-gcloud yes - fail - "gcp is configured but gcloud is not installed"
  else
    GCP_CRED_VAR="$(cfg gcp credentials_env)"
    GCP_TOKEN=""
    GCP_BLOCKED=0
    if [ -n "$GCP_CRED_VAR" ]; then
      GCP_CRED_PATH="$(printenv "$GCP_CRED_VAR" 2>/dev/null || true)"
      if [ -z "$GCP_CRED_PATH" ]; then
        row gcp env yes "$GCP_CRED_VAR" env-missing - "export ${GCP_CRED_VAR} in this shell, then rerun doctor; created per connect references/providers.md"
        GCP_BLOCKED=1
      elif [ ! -f "$GCP_CRED_PATH" ]; then
        row gcp env yes "$GCP_CRED_VAR" fail - "${GCP_CRED_VAR} names a file that does not exist: ${GCP_CRED_PATH}"
        GCP_BLOCKED=1
      else
        row gcp env yes "$GCP_CRED_VAR" pass - -
        GCP_TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
      fi
    else
      row gcp env yes none pass - -
      GCP_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    fi
    if [ "$GCP_BLOCKED" -eq 1 ]; then
      row gcp identity yes "${GCP_CRED_VAR:-none}" skipped - "blocked: credentials not resolved"
    elif [ -z "$GCP_TOKEN" ]; then
      row gcp identity yes "${GCP_CRED_VAR:-none}" fail - "gcloud produced no access token; run gcloud auth login (or point credentials_env at a service-account key) and rerun doctor"
    else
      live_check gcp monitoring-api "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1" "${GCP_CRED_VAR:-none}" "$GCP_TOKEN"
    fi
  fi
fi

# --- aws (aws CLI identity, not a static bearer token) -------------------------------------

AWS_ACCOUNT="$(cfg aws account_id)"
if [ -z "$AWS_ACCOUNT" ]; then
  row aws configured no - skipped - "add an aws block via /scoutflo:connect if you run AWS"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  if ! command -v aws >/dev/null 2>&1; then
    row aws binary-aws yes - fail - "aws is configured but the AWS CLI is not installed"
  else
    AWS_PROFILE_CFG="$(cfg aws profile)"
    AWS_REGION_CFG="$(cfg aws region)"
    AWS_ROLE_VAR="$(cfg aws role_env)"
    aws_cli() {
      if [ -n "$AWS_PROFILE_CFG" ]; then
        aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
      else
        aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
      fi
    }
    AWS_BLOCKED=0
    if [ -n "$AWS_ROLE_VAR" ]; then
      AWS_ROLE_ARN="$(printenv "$AWS_ROLE_VAR" 2>/dev/null || true)"
      if [ -z "$AWS_ROLE_ARN" ]; then
        row aws env yes "$AWS_ROLE_VAR" env-missing - "export ${AWS_ROLE_VAR} in this shell, then rerun doctor"
        AWS_BLOCKED=1
      else
        row aws env yes "$AWS_ROLE_VAR" pass - -
      fi
    else
      row aws env yes none pass - -
    fi
    if [ "$AWS_BLOCKED" -eq 1 ]; then
      row aws identity yes "${AWS_ROLE_VAR:-none}" skipped - "blocked: role ARN not resolved"
    else
      note "doctor: checking aws identity: aws sts get-caller-identity"
      STS_RC=0
      STS_OUT="$(aws_cli sts get-caller-identity --output json 2>&1)" || STS_RC=$?
      if [ "$STS_RC" -ne 0 ]; then
        row aws identity yes "${AWS_ROLE_VAR:-none}" fail - "aws sts get-caller-identity failed: run aws configure (or export AWS credentials), then rerun doctor"
      else
        LIVE_ACCOUNT="$(printf '%s' "$STS_OUT" | jq -r '.Account // empty' 2>/dev/null || true)"
        if [ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ]; then
          row aws identity yes "${AWS_ROLE_VAR:-none}" pass - -
        else
          row aws identity yes "${AWS_ROLE_VAR:-none}" fail - "live account ${LIVE_ACCOUNT:-unknown} does not match aws.account_id ${AWS_ACCOUNT} in toolkit.yaml; fix the config or switch credentials"
        fi
        note "doctor: checking aws cloudwatch reachability: aws cloudwatch describe-alarms --max-records 1"
        CW_RC=0
        aws_cli cloudwatch describe-alarms --max-records 1 >/dev/null 2>&1 || CW_RC=$?
        if [ "$CW_RC" -eq 0 ]; then
          row aws cloudwatch-read yes "${AWS_ROLE_VAR:-none}" pass - -
        else
          row aws cloudwatch-read yes "${AWS_ROLE_VAR:-none}" fail - "cloudwatch:DescribeAlarms denied or unreachable; grant the read-only policy in connect references/providers.md"
        fi
        # Optional cost-permission probe. Informational only: a missing scope here
        # never fails doctor or blocks the reliability checks. audit-aws reads this
        # row to decide whether to run the Cost & Resource Optimization section or
        # report it excluded with a reason.
        COST_CHECKS="$(cfg aws cost_checks)"
        if [ "$COST_CHECKS" = "false" ]; then
          row aws cost-permissions yes "${AWS_ROLE_VAR:-none}" skipped - "aws.cost_checks is false in toolkit.yaml; Cost & Resource Optimization section will be skipped"
        else
          CO_RC=0
          aws_cli compute-optimizer get-enrollment-status >/dev/null 2>&1 || CO_RC=$?
          if [ "$CO_RC" -eq 0 ]; then
            row aws cost-permissions yes "${AWS_ROLE_VAR:-none}" pass - -
          else
            row aws cost-permissions yes "${AWS_ROLE_VAR:-none}" skipped - "compute-optimizer/ce/support permissions not confirmed; audit-aws will report the affected Cost & Resource Optimization rows as excluded with this reason, not fail"
          fi
        fi
      fi
    fi
  fi
fi

# --- kubernetes --------------------------------------------------------------------------

KUBE_CONTEXT="$(cfg kubernetes context)"
if [ -z "$KUBE_CONTEXT" ]; then
  row kubernetes configured no - skipped - "add a kubernetes block via /scoutflo:connect if you audit a cluster"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  if ! command -v kubectl >/dev/null 2>&1; then
    row kubernetes binary-kubectl yes - fail - "kubernetes is configured but kubectl is not installed"
  else
    note "doctor: checking kubernetes rbac: kubectl --context ${KUBE_CONTEXT} auth can-i get pods"
    K_RC=0
    K_OUT="$(kubectl --context "$KUBE_CONTEXT" --request-timeout=10s auth can-i get pods 2>&1)" || K_RC=$?
    K_LINE="$(printf '%s' "$K_OUT" | head -n 1 | tr '\t' ' ')"
    if [ "$K_LINE" = "yes" ]; then
      row kubernetes rbac yes - pass - -
    elif [ "$K_LINE" = "no" ]; then
      row kubernetes rbac yes - fail - "context reaches the cluster but lacks read RBAC; bind the view ClusterRole per connect references/providers.md"
    else
      row kubernetes rbac yes - fail - "context error: ${K_LINE}; run kubectl config get-contexts and fix kubernetes.context"
    fi
  fi
fi

# --- slack (test post only with --slack-test) ----------------------------------------------

SLACK_VAR="$(cfg slack webhook_env)"
if [ -z "$SLACK_VAR" ]; then
  row slack configured no - skipped - "add a slack block via /scoutflo:connect to receive audit briefs"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  SLACK_URL="$(printenv "$SLACK_VAR" 2>/dev/null || true)"
  if [ -z "$SLACK_URL" ]; then
    row slack env yes "$SLACK_VAR" env-missing - "export ${SLACK_VAR} in this shell, then rerun doctor; the webhook URL is itself the secret"
    row slack webhook-post yes "$SLACK_VAR" skipped - "blocked: ${SLACK_VAR} is not set"
  elif [ "$SLACK_TEST" -eq 1 ]; then
    row slack env yes "$SLACK_VAR" pass - -
    note "doctor: checking slack webhook-post: POST to the configured webhook (URL hidden; it is a credential)"
    SLACK_RC=0
    SLACK_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -X POST -H 'Content-Type: application/json' \
      --data '{"text":"SRE Toolkit doctor: connection test"}' \
      "$SLACK_URL")" || SLACK_RC=$?
    if [ "$SLACK_RC" -ne 0 ]; then
      row slack webhook-post yes "$SLACK_VAR" fail "000" "$(transport_hint "$SLACK_RC") (webhook URL hidden)"
    elif [ "$SLACK_CODE" = "200" ]; then
      row slack webhook-post yes "$SLACK_VAR" pass "$SLACK_CODE" "-"
    else
      row slack webhook-post yes "$SLACK_VAR" fail "$SLACK_CODE" "HTTP ${SLACK_CODE}: webhook revoked or wrong URL; create a new one via /scoutflo:connect"
    fi
  else
    row slack env yes "$SLACK_VAR" pass - -
    row slack webhook-post yes "$SLACK_VAR" skipped - "test post sends a visible channel message; rerun with --slack-test after the user confirms"
  fi
fi

# --- verdict ----------------------------------------------------------------------------------

note "doctor: matrix appended to ${MATRIX}"
if [ "$CONFIGURED_COUNT" -eq 0 ]; then
  note "doctor: nothing is configured in ${CONFIG}; run /scoutflo:connect to add integrations"
fi
if [ "$ANY_ENV_MISSING" -eq 1 ]; then
  note "doctor: FAIL (exit 2): required env vars are missing; export them in this shell, then rerun"
  exit 2
fi
if [ "$ANY_FAIL" -eq 1 ]; then
  note "doctor: FAIL (exit 3): at least one live check failed; fix per the hints, then rerun"
  exit 3
fi
note "doctor: PASS: every configured integration passed"
exit 0
