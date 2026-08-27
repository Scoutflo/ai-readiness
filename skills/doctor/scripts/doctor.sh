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

CONFIG="${SCOUTFLO_CONFIG:-}"
# Order: explicit > project-local > last-selected (connect persists it to
# ~/.scoutflo/active-config so a new terminal remembers a multi-env choice) > home default.
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
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
# Resolve the store with the SAME layered resolver the audits use (override ->
# project-local -> home), so doctor and every audit agree on where the secret store
# lives even on sandboxed/project-local surfaces where $HOME is not shell-writable
# (ci/env-load-parity-check.sh enforces this parity across doctor + audit-*).
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
STORE_LOAD_FAILED=0
if [ -f "$SCOUTFLO_ENV" ]; then
  # Suspend errexit/nounset while sourcing: this file is user-edited, so a
  # single failing or unbound line inside it must degrade to a diagnostic, not
  # abort the whole preflight. (Under `set -e`, a failure inside a sourced file
  # exits the shell before the `|| ...` can run, so the guard was inert.)
  # A subshell can't be used — the exported *_env vars must land in this shell.
  # A genuine parse failure (e.g. a wrapped paste with an unbalanced quote) is
  # buffered here and surfaced as a matrix row once row()/MATRIX exist (below).
  set +eu
  # shellcheck disable=SC1090
  . "$SCOUTFLO_ENV" || { STORE_LOAD_FAILED=1; note "doctor: warning: could not source ${SCOUTFLO_ENV}; a pasted line may be malformed (continuing with current environment)"; }
  set -eu
fi

# --- version stamp ------------------------------------------------------------
# Print which toolkit version is answering, so any pasted output/screenshot is
# self-diagnosing (a stale install is the #1 cause of "my picker looks different").
# Plugins do not auto-update: refresh with `claude plugin update scoutflo@scoutflo`.
# Resolve the manifest robustly: prefer CLAUDE_PLUGIN_ROOT when it actually holds the
# manifest, else resolve relative to THIS script's dir (skills/doctor/scripts -> repo
# root), so the version is surfaced even when doctor runs standalone (no CLAUDE_PLUGIN_ROOT).
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT%/}/.claude-plugin/plugin.json" ]; then
  PLUGIN_MANIFEST="${CLAUDE_PLUGIN_ROOT%/}/.claude-plugin/plugin.json"
else
  PLUGIN_MANIFEST="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/.claude-plugin/plugin.json"
fi
TOOLKIT_VERSION=""
if [ -f "$PLUGIN_MANIFEST" ]; then
  TOOLKIT_VERSION=$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PLUGIN_MANIFEST" | head -1)
  note "doctor: Scoutflo AI Readiness toolkit v${TOOLKIT_VERSION:-unknown} (update: claude plugin update scoutflo@scoutflo)"
else
  note "doctor: Scoutflo AI Readiness toolkit (version manifest not found; running from a partial install?)"
fi

# --- Claude Code client version (warn-only, best-effort) ----------------------
# The plugin's documented minimum. Keep this token in lockstep with README.md,
# docs/install.md, and docs/faq.md (ci/min-version-consistency-check.sh enforces it).
# This is warn-only: if doctor is running at all, the client already loaded the
# plugin, so it is almost certainly fine — the real protection for a too-old
# client is the marketplace-add/install error + the docs, not this check (a
# client too old to load the plugin never reaches this line). We still surface it
# so a borderline client gets an explicit heads-up instead of subtle breakage.
MIN_CLAUDE_VERSION="2.1.140"
CLIENT_VER=""
if command -v claude >/dev/null 2>&1; then
  CLIENT_VER="$(claude --version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
elif [ -n "${CLAUDE_CODE_EXECPATH:-}" ] && [ -x "${CLAUDE_CODE_EXECPATH}" ]; then
  CLIENT_VER="$("${CLAUDE_CODE_EXECPATH}" --version 2>/dev/null | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
fi
if [ -z "$CLIENT_VER" ]; then
  note "doctor: Claude Code client version unknown (\`claude\` not on PATH in this shell); the plugin needs v${MIN_CLAUDE_VERSION}+"
else
  # Compare CLIENT_VER >= MIN_CLAUDE_VERSION using sort -V (POSIX-ish; coreutils/BSD both have it).
  LOWER="$(printf '%s\n%s\n' "$MIN_CLAUDE_VERSION" "$CLIENT_VER" | sort -V | head -1)"
  if [ "$LOWER" = "$MIN_CLAUDE_VERSION" ] || [ "$CLIENT_VER" = "$MIN_CLAUDE_VERSION" ]; then
    note "doctor: Claude Code v${CLIENT_VER} (>= v${MIN_CLAUDE_VERSION} minimum)"
  else
    note "doctor: WARNING — Claude Code v${CLIENT_VER} is below the plugin minimum v${MIN_CLAUDE_VERSION}; some skills may not load. Update: npm install -g @anthropic-ai/claude-code, then restart."
  fi
fi

# --- hard stop: config must exist --------------------------------------------

if [ ! -f "$CONFIG" ]; then
  note "doctor: config not found: ${CONFIG}"
  # Multi-environment setup: offer named variants instead of a dead stall; never auto-pick.
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    note "doctor: no default config, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /' >&2
    note "fix: re-run with --config <one of the above> (or SCOUTFLO_CONFIG=...) for the environment you want; connect can also create a default"
  else
    note "fix: run /scoutflo:connect to create it from templates/toolkit.yaml.example"
  fi
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

# --- multi-target enumeration (report-standard/toolkit-targets.sh) --------------
# A block in toolkit.yaml may be a single mapping (one target — today's shape) OR a
# labeled YAML list of N targets (e.g. three HyperDX instances, N Azure subscriptions).
# doctor probes EVERY target, never just target 0, and never reports a labeled list
# "not configured". toolkit-targets.sh is the one shared parser (yq fast path, awk
# fallback — so multi-target needs no yq). For a single-block mapping the per-target
# value read routes back through cfg(), so single-block behavior is byte-identical to
# before this change; only a labeled list ("seq") goes through the indexed getter.
# Locate the shared target enumerator robustly: prefer CLAUDE_PLUGIN_ROOT when it
# actually contains it, else resolve relative to THIS script's own directory
# (skills/doctor/scripts/ -> repo root), so doctor works when invoked standalone
# (no CLAUDE_PLUGIN_ROOT, any CWD) exactly as it does under the plugin harness.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT%/}/report-standard/toolkit-targets.sh" ]; then
  TT="${CLAUDE_PLUGIN_ROOT%/}/report-standard/toolkit-targets.sh"
else
  TT="$(cd "$(dirname "$0")/../../.." 2>/dev/null && pwd)/report-standard/toolkit-targets.sh"
fi
# A missing enumerator must fail loudly, never silently make every block look absent
# (that would reintroduce the zero-rows false-green this preflight exists to kill).
[ -f "$TT" ] || { echo "doctor: cannot locate report-standard/toolkit-targets.sh (via CLAUDE_PLUGIN_ROOT or the doctor script dir); cannot resolve integration targets; repair the install: claude plugin update scoutflo@scoutflo, or run doctor.sh from the plugin repo root so report-standard/ resolves" >&2; exit 2; }

# tkind <block>: "seq" (labeled list), "map" (single block), or "absent".
tkind()  { sh "$TT" "$CONFIG" "$1" kind 2>/dev/null || echo absent; }
# tcount <block>: number of configured targets (0 when the block is absent).
tcount() { _tc="$(sh "$TT" "$CONFIG" "$1" count 2>/dev/null || echo 0)"; [ -n "$_tc" ] || _tc=0; printf '%s' "$_tc"; }
# tlabel <block> <i>: the target's label (the block name for a single mapping).
tlabel() { sh "$TT" "$CONFIG" "$1" label "$2" 2>/dev/null || true; }
# tv <block> <kind> <i> <key>: a two-level value for target i. A single mapping
# (kind != seq) routes through cfg() unchanged; a labeled list reads target i.
tv() {
  if [ "$2" = seq ]; then sh "$TT" "$CONFIG" "$1" get "$3" "$4" 2>/dev/null || true
  else cfg "$1" "$4"; fi
}
# tint <block> <i> <count>: the integration name for row(). Plain block name for a
# single target; "<block> (<label>)" when the block lists more than one target, so a
# multi-target matrix stays unambiguous while single-block rows are unchanged.
tint() {
  if [ "${3:-1}" -gt 1 ]; then printf '%s (%s)' "$1" "$(tlabel "$1" "$2")"; else printf '%s' "$1"; fi
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

# missing_hint <VAR>: the uniform env-missing hint. The plugin runs in its own
# process and cannot see a shell `export`; credentials must live in the secret store
# connect writes (~/.scoutflo/env), which doctor sources above. If the store already
# NAMES the variable but it did not load, that line is malformed — say so precisely.
# Greps the NAME only; never reads or prints the value (leak-scan stays green).
missing_hint() {
  mh_var="$1"
  if [ -f "$SCOUTFLO_ENV" ] && grep -qE "^[[:space:]]*export[[:space:]]+${mh_var}=" "$SCOUTFLO_ENV" 2>/dev/null; then
    printf '%s' "${mh_var} appears in ~/.scoutflo/env but did not load — that line is malformed (a space in the name from a wrapped paste like HDX_E U_KEY, or a doubled =); fix that one line, then rerun doctor."
  else
    printf '%s' "${mh_var} is not in ~/.scoutflo/env — the plugin reads that file, not your shell. Add it: echo 'export ${mh_var}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env (Windows: setx ${mh_var} \"<paste>\"), then rerun doctor."
  fi
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

# resolve_token_t <block> <kind> <i>: target-aware resolve_token — sets the same
# TOKEN_VAR/TOKEN/TOKEN_STATE globals for target i. A single-block mapping routes
# through cfg() (via tv), so its result is identical to resolve_token.
resolve_token_t() {
  TOKEN_VAR="$(tv "$1" "$2" "$3" token_env)"
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
# status-probe-ok: this is the reachability primitive for text/plain readiness
# endpoints (loki/tempo/mimir /ready, which return "ready", not JSON). Probes that
# must prove authorized DATA access assert a JSON body via live_check's jq arg or
# authed_json_check instead of calling http_get directly.
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
    52|55|56) echo "curl exit $1: the connection was dropped mid-transfer with no HTTP response, usually a proxy or corporate firewall between you and the host, not the token; retry once with proxy vars cleared (env -u HTTPS_PROXY -u https_proxy ...) and confirm the host is reachable from this network (curl -I the base URL)" ;;
    *)     echo "curl exit $1: transport failure before any HTTP response (not an auth error); the host was unreachable from this network, check proxy/VPN/firewall" ;;
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

# live_check <integration> <check> <url> <env_var_label> <token-or-empty> [jq-filter]
# Records pass/fail with the observed code and a hint. With a 6th <jq-filter> arg it
# becomes JSON-asserting: a 200 passes ONLY when the Content-Type is JSON AND the filter
# matches — so an SSO/proxy 200 HTML login page or a moved-path SPA fall-through fails
# closed instead of scoring a false pass. Without the filter it stays status-only, which
# is correct for genuine text/plain readiness endpoints (e.g. loki/tempo /ready → "ready").
live_check() {
  lc_int="$1"; lc_chk="$2"; lc_url="$3"; lc_env="$4"; lc_tok="$5"; lc_jq="${6:-}"
  note "doctor: checking ${lc_int} ${lc_chk}: GET ${lc_url}"
  if [ -z "$lc_jq" ]; then
    http_get "$lc_url" "$lc_tok"
    if [ "$CURL_RC" -ne 0 ]; then
      row "$lc_int" "$lc_chk" yes "$lc_env" fail "000" "$(transport_hint "$CURL_RC") (${lc_url})"
    elif [ "$HTTP_CODE" = "200" ]; then
      row "$lc_int" "$lc_chk" yes "$lc_env" pass "$HTTP_CODE" "-"
    else
      row "$lc_int" "$lc_chk" yes "$lc_env" fail "$HTTP_CODE" "$(http_hint "$HTTP_CODE")"
    fi
    return
  fi
  # JSON-asserting path: keep the body, add %{content_type}, require real JSON on a 200.
  lc_body="$(mktemp)"; CURL_RC=0
  if [ -n "$lc_tok" ]; then
    lc_meta="$(curl -s -o "$lc_body" -w '%{http_code} %{content_type}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "Authorization: Bearer ${lc_tok}" "$lc_url")" || CURL_RC=$?
  else
    lc_meta="$(curl -s -o "$lc_body" -w '%{http_code} %{content_type}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$lc_url")" || CURL_RC=$?
  fi
  HTTP_CODE="${lc_meta%% *}"; HTTP_CT="${lc_meta#* }"
  if [ "$CURL_RC" -ne 0 ]; then
    row "$lc_int" "$lc_chk" yes "$lc_env" fail "000" "$(transport_hint "$CURL_RC") (${lc_url})"
  elif [ "$HTTP_CODE" = "200" ]; then
    if printf '%s' "$HTTP_CT" | grep -qi json && jq -e "$lc_jq" "$lc_body" >/dev/null 2>&1; then
      row "$lc_int" "$lc_chk" yes "$lc_env" pass "$HTTP_CODE" "-"
    else
      row "$lc_int" "$lc_chk" yes "$lc_env" fail "$HTTP_CODE" "200 but Content-Type='${HTTP_CT}' / body is not the expected JSON (${lc_jq}): looks like an HTML login/SPA/proxy page, not the API — verify the URL and that no SSO proxy fronts it"
    fi
  else
    row "$lc_int" "$lc_chk" yes "$lc_env" fail "$HTTP_CODE" "$(http_hint "$HTTP_CODE")"
  fi
  rm -f "$lc_body"
}

# authed_json_check <int> <chk> <url> <env-label> <jq-filter> <header-name> <header-value> [method] [data]
# The anti-false-green path for every AUTHENTICATED HTTP probe. Unlike live_check it keeps the
# body and records `pass` ONLY on 2xx AND a JSON content-type AND <jq-filter> matching a field
# the real API always returns. A 200 with a non-JSON (HTML) body — an SSO/reverse-proxy login
# page, a captive portal, or a route that moved and fell through to a SPA — is recorded `fail`
# with an explicit hint, NOT a pass. Works with any auth header (Bearer, Token token=, ApiKey,
# DD-API-KEY, SIGNOZ-API-KEY, Basic via -u done by the caller) and GET or POST.
authed_json_check() {
  aj_int="$1"; aj_chk="$2"; aj_url="$3"; aj_env="$4"; aj_jq="$5"; aj_hn="$6"; aj_hv="$7"; aj_method="${8:-GET}"; aj_data="${9:-}"
  note "doctor: checking ${aj_int} ${aj_chk}: ${aj_method} ${aj_url}"
  aj_body="$(mktemp)"; aj_rc=0
  if [ "$aj_method" = "POST" ]; then
    aj_meta="$(curl -s -o "$aj_body" -w '%{http_code} %{content_type}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -X POST \
      -H "${aj_hn}: ${aj_hv}" -H "Content-Type: application/json" --data "$aj_data" "$aj_url")" || aj_rc=$?
  else
    aj_meta="$(curl -s -o "$aj_body" -w '%{http_code} %{content_type}' \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
      -H "${aj_hn}: ${aj_hv}" "$aj_url")" || aj_rc=$?
  fi
  aj_code="${aj_meta%% *}"; aj_ct="${aj_meta#* }"
  if [ "$aj_rc" -ne 0 ]; then
    row "$aj_int" "$aj_chk" yes "$aj_env" fail "000" "$(transport_hint "$aj_rc") (${aj_url})"
  elif [ "$aj_code" = "200" ]; then
    case "$aj_ct" in
      application/json*|*+json*)
        if jq -e "$aj_jq" "$aj_body" >/dev/null 2>&1; then
          row "$aj_int" "$aj_chk" yes "$aj_env" pass "$aj_code" "-"
        else
          row "$aj_int" "$aj_chk" yes "$aj_env" fail "$aj_code" "200 JSON but unexpected shape (expected: ${aj_jq}); inspect ${aj_url} manually"
        fi ;;
      *)
        row "$aj_int" "$aj_chk" yes "$aj_env" fail "$aj_code" "200 but Content-Type='${aj_ct}' (not JSON): looks like an HTML login/SPA/proxy page, not the API — verify the URL and that no SSO/reverse proxy fronts it" ;;
    esac
  else
    row "$aj_int" "$aj_chk" yes "$aj_env" fail "$aj_code" "$(http_hint "$aj_code")"
  fi
  rm -f "$aj_body"
}

# token_gate <integration> <check...>: when TOKEN_STATE=missing, records the
# env-missing row plus one blocked row per named check and returns 1.
token_gate() {
  tg_int="$1"; shift
  if [ "$TOKEN_STATE" = "missing" ]; then
    row "$tg_int" env yes "$TOKEN_VAR" env-missing - "$(missing_hint "$TOKEN_VAR")"
    for tg_chk in "$@"; do
      row "$tg_int" "$tg_chk" yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set — see the ${TOKEN_VAR} env row above, then rerun"
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
  row toolkit binary-jq yes - fail - "install jq; every audit and setup skill parses JSON with it (macOS: brew install jq; Debian/Ubuntu: apt-get install -y jq)"
fi

# Toolkit version row (in addition to the stderr note above): plugins do not
# auto-update, and a stale install is the #1 cause of "my picker looks different".
if [ -n "${TOOLKIT_VERSION:-}" ]; then
  row toolkit version yes - pass - "v${TOOLKIT_VERSION}; plugins do not auto-update — if older than expected run /reload-plugins (or restart Claude Code), then rerun; update: claude plugin update scoutflo@scoutflo"
fi
# Buffered secret-store parse failure (detected above before row()/MATRIX existed).
if [ "$STORE_LOAD_FAILED" -eq 1 ]; then
  row env store-load yes - fail - "~/.scoutflo/env failed to parse (a pasted line may have wrapped, or has a stray char like == or a space in the variable name) — fix that line or re-run /scoutflo:connect, then rerun doctor."
fi

# --- grafana ---------------------------------------------------------------------

GRAFANA_KIND="$(tkind grafana)"; GRAFANA_N="$(tcount grafana)"
if [ "${GRAFANA_N:-0}" -eq 0 ]; then
  row grafana configured no - skipped - "add a grafana block via /scoutflo:connect if you run Grafana"
else
  _gi=0
  while [ "$_gi" -lt "$GRAFANA_N" ]; do
    G_INT="$(tint grafana "$_gi" "$GRAFANA_N")"
    GRAFANA_URL="$(tv grafana "$GRAFANA_KIND" "$_gi" url)"
    if [ -z "$GRAFANA_URL" ]; then
      row "$G_INT" configured no - skipped - "add a grafana block via /scoutflo:connect if you run Grafana"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      GRAFANA_URL="${GRAFANA_URL%/}"
      resolve_token_t grafana "$GRAFANA_KIND" "$_gi"
      if token_gate "$G_INT" health identity; then
        authed_json_check "$G_INT" health   "${GRAFANA_URL}/api/health" "${TOKEN_VAR:-none}" '.database=="ok"'          Authorization "Bearer ${TOKEN}"
        authed_json_check "$G_INT" identity "${GRAFANA_URL}/api/org"    "${TOKEN_VAR:-none}" '.name!=null and .id!=null' Authorization "Bearer ${TOKEN}"
      fi
    fi
    _gi=$((_gi+1))
  done
fi

# --- sentry ------------------------------------------------------------------------

SENTRY_KIND="$(tkind sentry)"; SENTRY_N="$(tcount sentry)"
if [ "${SENTRY_N:-0}" -eq 0 ]; then
  row sentry configured no - skipped - "add a sentry block via /scoutflo:connect if you run Sentry"
else
  _si=0
  while [ "$_si" -lt "$SENTRY_N" ]; do
    S_INT="$(tint sentry "$_si" "$SENTRY_N")"
    SENTRY_HOST="$(tv sentry "$SENTRY_KIND" "$_si" host)"
    if [ -z "$SENTRY_HOST" ]; then
      row "$S_INT" configured no - skipped - "add a sentry block via /scoutflo:connect if you run Sentry"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      SENTRY_ORG="$(tv sentry "$SENTRY_KIND" "$_si" org)"
      resolve_token_t sentry "$SENTRY_KIND" "$_si"
      if [ -z "$SENTRY_ORG" ]; then
        row "$S_INT" config yes "${TOKEN_VAR:-none}" fail - "sentry.org is empty in toolkit.yaml; set your org slug"
      elif token_gate "$S_INT" org; then
        authed_json_check "$S_INT" org "https://${SENTRY_HOST}/api/0/organizations/${SENTRY_ORG}/" "${TOKEN_VAR:-none}" ".slug==\"${SENTRY_ORG}\"" Authorization "Bearer ${TOKEN}"
      fi
    fi
    _si=$((_si+1))
  done
fi

# --- pagerduty ------------------------------------------------------------------------
# PagerDuty auth is "Authorization: Token token=<key>", not a Bearer header, so this
# block uses its own curl calls instead of live_check/http_get.
# The abilities probe validates the key; the analytics probe is a POST that reads
# (filter body, changes nothing) — read-only keys are documented GET-only, so a 403
# there is recorded as skipped-with-reason, never a failure: audit-pagerduty reads
# that row to decide whether to run its actionability section or exclude it honestly.

PD_KIND="$(tkind pagerduty)"; PD_N="$(tcount pagerduty)"
if [ "${PD_N:-0}" -eq 0 ]; then
  row pagerduty configured no - skipped - "add a pagerduty block via /scoutflo:connect if you run PagerDuty"
else
  _pi=0
  while [ "$_pi" -lt "$PD_N" ]; do
    PD_INT="$(tint pagerduty "$_pi" "$PD_N")"
    PD_TOKEN_VAR_CHECK="$(tv pagerduty "$PD_KIND" "$_pi" token_env)"
    if [ -z "$PD_TOKEN_VAR_CHECK" ]; then
      row "$PD_INT" configured no - skipped - "add a pagerduty block via /scoutflo:connect if you run PagerDuty"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      PD_REGION="$(tv pagerduty "$PD_KIND" "$_pi" region)"
      case "$PD_REGION" in
        eu) PD_API="https://api.eu.pagerduty.com" ;;
        *)  PD_API="https://api.pagerduty.com" ;;
      esac
      resolve_token_t pagerduty "$PD_KIND" "$_pi"
      if token_gate "$PD_INT" abilities analytics; then
        note "doctor: checking ${PD_INT} abilities: GET ${PD_API}/abilities"
        PD_RC=0
        PD_BODY="$(mktemp)"
        PD_META="$(curl -s -o "$PD_BODY" -w '%{http_code} %{content_type}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "Authorization: Token token=${TOKEN}" \
          -H "Content-Type: application/json" "${PD_API}/abilities")" || PD_RC=$?
        PD_CODE="${PD_META%% *}"; PD_CT="${PD_META#* }"
        if [ "$PD_RC" -ne 0 ]; then
          row "$PD_INT" abilities yes "$TOKEN_VAR" fail "000" "$(transport_hint "$PD_RC") (${PD_API}/abilities)"
          PD_CODE="000"
        elif [ "$PD_CODE" = "200" ]; then
          # 200 alone is not proof — assert the abilities JSON so an HTML/proxy 200 fails closed.
          if printf '%s' "$PD_CT" | grep -qi json && jq -e 'has("abilities")' "$PD_BODY" >/dev/null 2>&1; then
            row "$PD_INT" abilities yes "$TOKEN_VAR" pass "$PD_CODE" "-"
          else
            row "$PD_INT" abilities yes "$TOKEN_VAR" fail "$PD_CODE" "200 but body is not the PagerDuty abilities JSON (Content-Type=${PD_CT}) — looks like an HTML/proxy page, not api.pagerduty.com; verify the host/region"
            PD_CODE="notjson"   # do not let the analytics step trust this 200
          fi
        elif [ "$PD_CODE" = "401" ]; then
          row "$PD_INT" abilities yes "$TOKEN_VAR" fail "$PD_CODE" "HTTP 401: key invalid or revoked, or wrong region host (pagerduty.region: us vs eu); recreate per connect references/providers.md"
        else
          row "$PD_INT" abilities yes "$TOKEN_VAR" fail "$PD_CODE" "$(http_hint "$PD_CODE")"
        fi
        rm -f "$PD_BODY"
        if [ "$PD_CODE" = "200" ]; then
          # Read-only-by-effect POST: aggregated incident metrics over the last 7 days.
          note "doctor: checking ${PD_INT} analytics: POST ${PD_API}/analytics/metrics/incidents/all (read-only filter body)"
          PDA_RC=0
          # status-probe-ok: secondary read-by-effect POST to api.pagerduty.com (fixed JSON SaaS, no SSO fall-through); the abilities probe above already asserted JSON this run.
          PDA_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -X POST \
            -H "Authorization: Token token=${TOKEN}" \
            -H "Content-Type: application/json" \
            --data '{"filters":{"created_at_start":"'"$(date -u -v-7d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT00:00:00Z)"'"}}' \
            "${PD_API}/analytics/metrics/incidents/all")" || PDA_RC=$?
          if [ "$PDA_RC" -ne 0 ]; then
            row "$PD_INT" analytics yes "$TOKEN_VAR" skipped "000" "$(transport_hint "$PDA_RC"); audit-pagerduty will exclude the actionability section with this reason"
          elif [ "$PDA_CODE" = "200" ]; then
            row "$PD_INT" analytics yes "$TOKEN_VAR" pass "$PDA_CODE" "-"
          elif [ "$PDA_CODE" = "403" ] || [ "$PDA_CODE" = "402" ]; then
            row "$PD_INT" analytics yes "$TOKEN_VAR" skipped "$PDA_CODE" "HTTP ${PDA_CODE}: analytics blocked for this key or plan (read-only keys are GET-only; Analytics may need a higher plan); audit-pagerduty will exclude the actionability section with this reason, not fail"
          else
            row "$PD_INT" analytics yes "$TOKEN_VAR" skipped "$PDA_CODE" "HTTP ${PDA_CODE}: analytics not confirmed; audit-pagerduty will exclude the actionability section with this reason"
          fi
        fi
      fi
    fi
    _pi=$((_pi+1))
  done
fi

# --- datadog ------------------------------------------------------------------------
# Datadog needs a key PAIR: API key (DD-API-KEY) + Application key (DD-APPLICATION-KEY).
# Both headers are custom, so this block uses its own curl calls, not http_get.
# The validate call tests the API key alone; the monitor call tests the app key +
# monitors_read scope. The cost probe is informational only (like the AWS one): a
# missing usage/billing scope never fails doctor; audit-datadog reads that row to run
# or exclude its non-scored cost section.

DD_KIND="$(tkind datadog)"; DD_N="$(tcount datadog)"
if [ "${DD_N:-0}" -eq 0 ]; then
  row datadog configured no - skipped - "add a datadog block via /scoutflo:connect if you run Datadog"
else
  _di=0
  while [ "$_di" -lt "$DD_N" ]; do
    DD_INT="$(tint datadog "$_di" "$DD_N")"
    DD_SITE="$(tv datadog "$DD_KIND" "$_di" site)"
    if [ -z "$DD_SITE" ]; then
      row "$DD_INT" configured no - skipped - "add a datadog block via /scoutflo:connect if you run Datadog"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      DD_API_VAR="$(tv datadog "$DD_KIND" "$_di" api_key_env)"
      DD_APP_VAR="$(tv datadog "$DD_KIND" "$_di" app_key_env)"
      DD_API_KEY=""; DD_APP_KEY=""
      DD_BLOCKED=0
      if [ -z "$DD_API_VAR" ] || [ -z "$DD_APP_VAR" ]; then
        row "$DD_INT" config yes - fail - "datadog needs both api_key_env and app_key_env in toolkit.yaml; set them per connect references/providers.md"
        DD_BLOCKED=1
      else
        DD_API_KEY="$(printenv "$DD_API_VAR" 2>/dev/null || true)"
        DD_APP_KEY="$(printenv "$DD_APP_VAR" 2>/dev/null || true)"
        if [ -z "$DD_API_KEY" ]; then
          row "$DD_INT" env yes "$DD_API_VAR" env-missing - "add it once to ~/.scoutflo/env: echo 'export ${DD_API_VAR}=\"<paste>\"' >> ~/.scoutflo/env (Windows PowerShell: setx ${DD_API_VAR} \"<paste>\"), then rerun doctor; created per connect references/providers.md"
          DD_BLOCKED=1
        elif [ -z "$DD_APP_KEY" ]; then
          row "$DD_INT" env yes "$DD_APP_VAR" env-missing - "add it once to ~/.scoutflo/env: echo 'export ${DD_APP_VAR}=\"<paste>\"' >> ~/.scoutflo/env (Windows PowerShell: setx ${DD_APP_VAR} \"<paste>\"), then rerun doctor; the app key is the second half of the pair"
          DD_BLOCKED=1
        else
          row "$DD_INT" env yes "${DD_API_VAR}+${DD_APP_VAR}" pass - -
        fi
      fi
      if [ "$DD_BLOCKED" -eq 1 ]; then
        row "$DD_INT" validate yes "${DD_API_VAR:-none}" skipped - "blocked: both Datadog keys must be set — see the datadog env/config row above, then rerun"
        row "$DD_INT" monitors-read yes "${DD_APP_VAR:-none}" skipped - "blocked: both Datadog keys must be set — see the datadog env/config row above, then rerun"
      else
        DD_HOST="api.${DD_SITE}"
        note "doctor: checking ${DD_INT} validate: GET https://${DD_HOST}/api/v1/validate"
        DDV_RC=0; DDV_BODY="$(mktemp)"
        DDV_META="$(curl -s -o "$DDV_BODY" -w '%{http_code} %{content_type}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "DD-API-KEY: ${DD_API_KEY}" "https://${DD_HOST}/api/v1/validate")" || DDV_RC=$?
        DDV_CODE="${DDV_META%% *}"; DDV_CT="${DDV_META#* }"
        if [ "$DDV_RC" -ne 0 ]; then
          row "$DD_INT" validate yes "$DD_API_VAR" fail "000" "$(transport_hint "$DDV_RC") (https://${DD_HOST}/api/v1/validate)"
          DD_BLOCKED=1
        elif [ "$DDV_CODE" = "200" ] && printf '%s' "$DDV_CT" | grep -qi json && jq -e '.valid==true' "$DDV_BODY" >/dev/null 2>&1; then
          row "$DD_INT" validate yes "$DD_API_VAR" pass "$DDV_CODE" "-"
        elif [ "$DDV_CODE" = "200" ]; then
          row "$DD_INT" validate yes "$DD_API_VAR" fail "$DDV_CODE" "200 but body is not the Datadog validate JSON (Content-Type=${DDV_CT}) — not api.${DD_SITE}; verify datadog.site and that no proxy fronts it"
          DD_BLOCKED=1
        else
          row "$DD_INT" validate yes "$DD_API_VAR" fail "$DDV_CODE" "HTTP ${DDV_CODE}: API key invalid or wrong site (datadog.site '${DD_SITE}'); a valid key on the wrong site returns 403"
          DD_BLOCKED=1
        fi
        rm -f "$DDV_BODY"
        if [ "$DD_BLOCKED" -eq 0 ]; then
          note "doctor: checking ${DD_INT} monitors-read: GET https://${DD_HOST}/api/v1/monitor?page_size=1"
          DDM_RC=0; DDM_BODY="$(mktemp)"
          DDM_META="$(curl -s -o "$DDM_BODY" -w '%{http_code} %{content_type}' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
            "https://${DD_HOST}/api/v1/monitor?page_size=1")" || DDM_RC=$?
          DDM_CODE="${DDM_META%% *}"; DDM_CT="${DDM_META#* }"
          if [ "$DDM_RC" -ne 0 ]; then
            row "$DD_INT" monitors-read yes "$DD_APP_VAR" fail "000" "$(transport_hint "$DDM_RC")"
          elif [ "$DDM_CODE" = "200" ] && printf '%s' "$DDM_CT" | grep -qi json && jq -e 'type=="array"' "$DDM_BODY" >/dev/null 2>&1; then
            row "$DD_INT" monitors-read yes "$DD_APP_VAR" pass "$DDM_CODE" "-"
          elif [ "$DDM_CODE" = "200" ]; then
            row "$DD_INT" monitors-read yes "$DD_APP_VAR" fail "$DDM_CODE" "200 but body is not the monitors JSON array (Content-Type=${DDM_CT}) — inspect the host"
          elif [ "$DDM_CODE" = "403" ]; then
            row "$DD_INT" monitors-read yes "$DD_APP_VAR" fail "$DDM_CODE" "HTTP 403: app key invalid, missing the monitors_read scope, or belongs to a disabled user; check the app key scopes per connect references/providers.md"
          else
            row "$DD_INT" monitors-read yes "$DD_APP_VAR" fail "$DDM_CODE" "$(http_hint "$DDM_CODE")"
          fi
          rm -f "$DDM_BODY"
          # Informational cost probe. This hits /api/v1/usage/summary, which needs
          # usage_read only; a pass therefore confirms usage_read, NOT billing_read.
          # The audit's estimated/historical cost-trend call (/api/v2/usage/estimated_cost)
          # additionally needs billing_read and can still 403 on a usage_read-only key —
          # the pass hint says so rather than overclaiming. A missing scope never fails
          # doctor; audit-datadog reads this row to run the non-scored cost section or
          # report it excluded with the reason.
          DD_COST_CHECKS="$(tv datadog "$DD_KIND" "$_di" cost_checks)"
          if [ "$DD_COST_CHECKS" = "false" ]; then
            row "$DD_INT" cost-permissions yes "$DD_APP_VAR" skipped - "datadog.cost_checks is false in toolkit.yaml; cost section will be skipped"
          else
            # status-probe-ok: informational scope probe, skipped either way (never a pass/fail gate); body shape not needed.
            DDC_CODE="$(curl -s -o /dev/null -w '%{http_code}' \
              --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
              -H "DD-API-KEY: ${DD_API_KEY}" -H "DD-APPLICATION-KEY: ${DD_APP_KEY}" \
              "https://${DD_HOST}/api/v1/usage/summary?start_month=$(date -u +%Y-%m-01T00 2>/dev/null)")" || true
            if [ "$DDC_CODE" = "200" ]; then
              row "$DD_INT" cost-permissions yes "$DD_APP_VAR" pass "$DDC_CODE" "usage_read confirmed via /api/v1/usage/summary only; the estimated/historical cost trend (/api/v2/usage/estimated_cost) also needs billing_read and can still 403 — audit-datadog degrades that part gracefully"
            else
              row "$DD_INT" cost-permissions yes "$DD_APP_VAR" skipped "${DDC_CODE:-000}" "usage_read/billing_read not confirmed (HTTP ${DDC_CODE:-000}); audit-datadog will report the cost section excluded with this reason, not fail"
            fi
          fi
        else
          row "$DD_INT" monitors-read yes "$DD_APP_VAR" skipped - "blocked: API key validation failed above — see the validate row above, then rerun"
        fi
      fi
    fi
    _di=$((_di+1))
  done
fi

# --- elk / kibana -------------------------------------------------------------------
# Kibana authenticates the Elasticsearch API key with "Authorization: ApiKey <encoded>",
# not a Bearer header, so this block uses its own curl call. /api/alerting/_health is the
# cheapest alerting-scoped probe and is itself an audit signal.

ELK_KIND="$(tkind elk)"; ELK_N="$(tcount elk)"
if [ "${ELK_N:-0}" -eq 0 ]; then
  row elk configured no - skipped - "add an elk block via /scoutflo:connect if you run Kibana alerting"
else
  _ei=0
  while [ "$_ei" -lt "$ELK_N" ]; do
    E_INT="$(tint elk "$_ei" "$ELK_N")"
    ELK_KIBANA_URL="$(tv elk "$ELK_KIND" "$_ei" kibana_url)"
    if [ -z "$ELK_KIBANA_URL" ]; then
      row "$E_INT" configured no - skipped - "add an elk block via /scoutflo:connect if you run Kibana alerting"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      ELK_KIBANA_URL="${ELK_KIBANA_URL%/}"
      ELK_TOKEN_VAR="$(tv elk "$ELK_KIND" "$_ei" token_env)"
      ELK_TOKEN=""
      ELK_TOKEN_STATE="none"
      if [ -n "$ELK_TOKEN_VAR" ]; then
        ELK_TOKEN="$(printenv "$ELK_TOKEN_VAR" 2>/dev/null || true)"
        if [ -n "$ELK_TOKEN" ]; then ELK_TOKEN_STATE="set"; else ELK_TOKEN_STATE="missing"; fi
      fi
      if [ -z "$ELK_TOKEN_VAR" ]; then
        row "$E_INT" config yes - fail - "elk.token_env is empty in toolkit.yaml; name the variable holding the Kibana API key"
      elif [ "$ELK_TOKEN_STATE" = "missing" ]; then
        row "$E_INT" env yes "$ELK_TOKEN_VAR" env-missing - "$(missing_hint "$ELK_TOKEN_VAR")"
        row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" skipped - "blocked: ${ELK_TOKEN_VAR} is not set — see the ${ELK_TOKEN_VAR} env row above, then rerun"
      else
        row "$E_INT" env yes "$ELK_TOKEN_VAR" pass - -
        note "doctor: checking ${E_INT} alerting-health: GET ${ELK_KIBANA_URL}/api/alerting/_health"
        ELK_RC=0; ELK_BODY="$(mktemp)"
        ELK_META="$(curl -s -o "$ELK_BODY" -w '%{http_code} %{content_type}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "Authorization: ApiKey ${ELK_TOKEN}" "${ELK_KIBANA_URL}/api/alerting/_health")" || ELK_RC=$?
        ELK_CODE="${ELK_META%% *}"; ELK_CT="${ELK_META#* }"
        if [ "$ELK_RC" -ne 0 ]; then
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" fail "000" "$(transport_hint "$ELK_RC") (${ELK_KIBANA_URL}/api/alerting/_health)"
        elif [ "$ELK_CODE" = "200" ] && printf '%s' "$ELK_CT" | grep -qi json && jq -e 'type=="object" or type=="array"' "$ELK_BODY" >/dev/null 2>&1; then
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" pass "$ELK_CODE" "-"
          # Space visibility: audit-elk auto-discovers spaces via GET /api/spaces/space, but the
          # response is filtered to spaces this key can see. Surface how many are visible so a
          # single-space key (the wrong/empty-space bug) is caught at doctor time. Degrade
          # gracefully: a non-200 or empty body just skips this row, it never fails the elk block.
          ELK_SPACES_JSON="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -H "Authorization: ApiKey ${ELK_TOKEN}" "${ELK_KIBANA_URL}/api/spaces/space" 2>/dev/null || echo '')"
          ELK_SPACE_IDS="$(printf '%s' "$ELK_SPACES_JSON" | jq -r 'if type=="array" then .[].id else empty end' 2>/dev/null | tr '\n' ' ')"
          ELK_SPACE_N="$(printf '%s' "$ELK_SPACE_IDS" | wc -w | tr -d ' ')"
          if [ "${ELK_SPACE_N:-0}" -gt 0 ]; then
            if [ "$ELK_SPACE_N" = "1" ] && printf '%s' "$ELK_SPACE_IDS" | grep -qw default; then
              row "$E_INT" spaces yes "$ELK_TOKEN_VAR" pass "$ELK_CODE" "only the 'default' space is visible to this key; if alerting rules live in another space, widen the key to spaces:[\"*\"] read (connect references/providers.md) so audit-elk can discover it"
            else
              row "$E_INT" spaces yes "$ELK_TOKEN_VAR" pass "$ELK_CODE" "visible spaces (${ELK_SPACE_N}): ${ELK_SPACE_IDS}"
            fi
          fi
        elif [ "$ELK_CODE" = "200" ]; then
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "200 but Content-Type='${ELK_CT}' / non-JSON body: Kibana is likely behind an SSO/OAuth reverse proxy returning its login page (or kibana_url is wrong) — a 200 HTML page is not proof of API access; audit-elk cannot read alerting until a real JSON response comes back"
        elif [ "$ELK_CODE" = "404" ]; then
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "HTTP 404: elk.kibana_url likely points at Elasticsearch, not Kibana, or a space/base-path prefix is wrong; alerting rules live in Kibana (:5601 self-managed)"
        elif [ "$ELK_CODE" = "401" ] || [ "$ELK_CODE" = "403" ]; then
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "HTTP ${ELK_CODE}: key invalid, or the role lacks Kibana Read on Stack Rules; grant the privileges in connect references/providers.md"
        else
          row "$E_INT" alerting-health yes "$ELK_TOKEN_VAR" fail "$ELK_CODE" "$(http_hint "$ELK_CODE")"
        fi
        rm -f "$ELK_BODY"
      fi
    fi
    _ei=$((_ei+1))
  done
fi

# --- jsm operations -----------------------------------------------------------------
# JSM Operations (the cloud successor to standalone Opsgenie) authenticates with an
# Atlassian API token over HTTP Basic (email:token), NOT a Bearer header and NOT a
# classic Opsgenie GenieKey. Every path needs the site's cloud_id; resolve it from
# jsm.cloud_id when set, else from the unauthenticated tenant_info edge route. The
# cheapest Operations-scoped probe is one page of alerts.

JSM_KIND="$(tkind jsm)"; JSM_N="$(tcount jsm)"
if [ "${JSM_N:-0}" -eq 0 ]; then
  row jsm configured no - skipped - "add a jsm block via /scoutflo:connect if you run JSM Operations (Opsgenie successor)"
else
  _ji=0
  while [ "$_ji" -lt "$JSM_N" ]; do
    J_INT="$(tint jsm "$_ji" "$JSM_N")"
    JSM_SITE="$(tv jsm "$JSM_KIND" "$_ji" site)"
    JSM_CLOUD_ID_CFG="$(tv jsm "$JSM_KIND" "$_ji" cloud_id)"
    if [ -z "$JSM_SITE" ] && [ -z "$JSM_CLOUD_ID_CFG" ]; then
      row "$J_INT" configured no - skipped - "add a jsm block via /scoutflo:connect if you run JSM Operations (Opsgenie successor)"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      JSM_EMAIL_VAR="$(tv jsm "$JSM_KIND" "$_ji" email_env)"
      JSM_TOKEN_VAR="$(tv jsm "$JSM_KIND" "$_ji" token_env)"
      JSM_EMAIL_VAL=""
      JSM_TOKEN_VAL=""
      JSM_BLOCKED=0
      if [ -z "$JSM_EMAIL_VAR" ] || [ -z "$JSM_TOKEN_VAR" ]; then
        row "$J_INT" config yes - fail - "jsm needs both email_env and token_env in toolkit.yaml; set them per connect references/providers.md"
        JSM_BLOCKED=1
      else
        JSM_EMAIL_VAL="$(printenv "$JSM_EMAIL_VAR" 2>/dev/null || true)"
        JSM_TOKEN_VAL="$(printenv "$JSM_TOKEN_VAR" 2>/dev/null || true)"
        if [ -z "$JSM_EMAIL_VAL" ]; then
          row "$J_INT" env yes "$JSM_EMAIL_VAR" env-missing - "$(missing_hint "$JSM_EMAIL_VAR")"
          JSM_BLOCKED=1
        elif [ -z "$JSM_TOKEN_VAL" ]; then
          row "$J_INT" env yes "$JSM_TOKEN_VAR" env-missing - "$(missing_hint "$JSM_TOKEN_VAR")"
          JSM_BLOCKED=1
        else
          row "$J_INT" env yes "${JSM_EMAIL_VAR}+${JSM_TOKEN_VAR}" pass - -
        fi
      fi
      if [ "$JSM_BLOCKED" -eq 1 ]; then
        row "$J_INT" alerts-read yes "${JSM_TOKEN_VAR:-none}" skipped - "blocked: JSM credentials not resolved — see the env/config row above, then rerun"
      else
        # Resolve cloud_id: config value wins; else tenant_info (unauthenticated, no secret).
        JSM_CLOUD_ID="$JSM_CLOUD_ID_CFG"
        if [ -z "$JSM_CLOUD_ID" ]; then
          note "doctor: resolving ${J_INT} cloud_id: GET https://${JSM_SITE}/_edge/tenant_info"
          JSM_CLOUD_ID="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            "https://${JSM_SITE}/_edge/tenant_info" 2>/dev/null | jq -r '.cloudId // empty' 2>/dev/null || true)"
        fi
        if [ -z "$JSM_CLOUD_ID" ]; then
          row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail - "could not resolve cloud_id from jsm.site '${JSM_SITE}' (tenant_info route blocked or wrong site); set jsm.cloud_id explicitly per connect references/providers.md"
        else
          JSM_BASE="https://api.atlassian.com/jsm/ops/api/${JSM_CLOUD_ID}/v1"
          note "doctor: checking ${J_INT} alerts-read: GET ${JSM_BASE}/alerts?size=1"
          JSM_RC=0; JSM_BODY="$(mktemp)"
          JSM_META="$(curl -s -o "$JSM_BODY" -w '%{http_code} %{content_type}' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -u "${JSM_EMAIL_VAL}:${JSM_TOKEN_VAL}" "${JSM_BASE}/alerts?size=1")" || JSM_RC=$?
          JSM_CODE="${JSM_META%% *}"; JSM_CT="${JSM_META#* }"
          if [ "$JSM_RC" -ne 0 ]; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "000" "$(transport_hint "$JSM_RC") (${JSM_BASE}/alerts)"
          elif [ "$JSM_CODE" = "200" ] && printf '%s' "$JSM_CT" | grep -qi json && jq -e 'type=="object" or type=="array"' "$JSM_BODY" >/dev/null 2>&1; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" pass "$JSM_CODE" "-"
          elif [ "$JSM_CODE" = "200" ]; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "200 but body is not JSON (Content-Type=${JSM_CT}) — not the JSM Operations API; verify jsm.site/cloud_id and that no proxy fronts api.atlassian.com"
          elif [ "$JSM_CODE" = "401" ]; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 401: bad API token or email; the token is the Basic-auth password and ${JSM_EMAIL_VAR} the username (not a GenieKey); recreate per connect references/providers.md"
          elif [ "$JSM_CODE" = "403" ]; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 403: the token's user lacks JSM Operations access; grant a read/observer Operations role per connect references/providers.md"
          elif [ "$JSM_CODE" = "404" ]; then
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "HTTP 404: wrong cloud_id (resolved '${JSM_CLOUD_ID}') or the site has no Operations; verify jsm.site/jsm.cloud_id"
          else
            row "$J_INT" alerts-read yes "$JSM_TOKEN_VAR" fail "$JSM_CODE" "$(http_hint "$JSM_CODE")"
          fi
          rm -f "$JSM_BODY"
        fi
      fi
    fi
    _ji=$((_ji+1))
  done
fi

# --- zenduty (xurrent imr) ----------------------------------------------------------
# Zenduty authenticates with "Authorization: Token <key>" (the literal word Token, NOT
# Bearer), so this block uses its own curl call. GET /api/account/teams/ is the cheapest
# list read and the doctor probe. Zenduty has no read-only key scope; a Bot Token (Beta)
# is the least-privilege path (see connect references/providers.md).

ZD_KIND="$(tkind zenduty)"; ZD_N="$(tcount zenduty)"
if [ "${ZD_N:-0}" -eq 0 ]; then
  row zenduty configured no - skipped - "add a zenduty block via /scoutflo:connect if you run Zenduty (Xurrent IMR)"
else
  _zi=0
  while [ "$_zi" -lt "$ZD_N" ]; do
    ZD_INT="$(tint zenduty "$_zi" "$ZD_N")"
    ZD_TOKEN_VAR="$(tv zenduty "$ZD_KIND" "$_zi" token_env)"
    if [ -z "$ZD_TOKEN_VAR" ]; then
      row "$ZD_INT" configured no - skipped - "add a zenduty block via /scoutflo:connect if you run Zenduty (Xurrent IMR)"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      ZD_TOKEN=""
      ZD_TOKEN_STATE="missing"
      ZD_TOKEN="$(printenv "$ZD_TOKEN_VAR" 2>/dev/null || true)"
      [ -n "$ZD_TOKEN" ] && ZD_TOKEN_STATE="set"
      if [ "$ZD_TOKEN_STATE" = "missing" ]; then
        row "$ZD_INT" env yes "$ZD_TOKEN_VAR" env-missing - "$(missing_hint "$ZD_TOKEN_VAR")"
        row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" skipped - "blocked: ${ZD_TOKEN_VAR} is not set — see the ${ZD_TOKEN_VAR} env row above, then rerun"
      else
        row "$ZD_INT" env yes "$ZD_TOKEN_VAR" pass - -
        note "doctor: checking ${ZD_INT} teams-read: GET https://www.zenduty.com/api/account/teams/"
        ZD_RC=0; ZD_BODY="$(mktemp)"
        ZD_META="$(curl -s -o "$ZD_BODY" -w '%{http_code} %{content_type}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "Authorization: Token ${ZD_TOKEN}" "https://www.zenduty.com/api/account/teams/")" || ZD_RC=$?
        ZD_CODE="${ZD_META%% *}"; ZD_CT="${ZD_META#* }"
        if [ "$ZD_RC" -ne 0 ]; then
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" fail "000" "$(transport_hint "$ZD_RC") (https://www.zenduty.com/api/account/teams/)"
        elif [ "$ZD_CODE" = "200" ] && printf '%s' "$ZD_CT" | grep -qi json && jq -e 'type=="array" or type=="object"' "$ZD_BODY" >/dev/null 2>&1; then
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" pass "$ZD_CODE" "-"
        elif [ "$ZD_CODE" = "200" ]; then
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "200 but Content-Type='${ZD_CT}' / non-JSON body: likely a Cloudflare interstitial or SPA/login page from www.zenduty.com, not the API — a 200 HTML page is not proof; retry or verify the token"
        elif [ "$ZD_CODE" = "401" ] || [ "$ZD_CODE" = "403" ]; then
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "HTTP ${ZD_CODE}: key invalid or not prefixed correctly; the header must be 'Authorization: Token <key>' (the literal word Token, not Bearer); recreate per connect references/providers.md"
        elif [ "$ZD_CODE" = "429" ]; then
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "HTTP 429: rate-limited (Zenduty limits are tight and per-endpoint-class); wait about a minute and rerun doctor"
        else
          row "$ZD_INT" teams-read yes "$ZD_TOKEN_VAR" fail "$ZD_CODE" "$(http_hint "$ZD_CODE")"
        fi
        rm -f "$ZD_BODY"
      fi
    fi
    _zi=$((_zi+1))
  done
fi

# --- groundcover --------------------------------------------------------------------
# Groundcover authenticates with "Authorization: Bearer <key>" on a service-account key,
# plus an "X-Backend-Id" header for multi-backend accounts. There is no whoami endpoint,
# so POST /api/monitors/list (with an empty sources filter) is the cheapest read and the
# doctor probe. It is a read-by-query POST, not a mutation.

GC_KIND="$(tkind groundcover)"; GC_N="$(tcount groundcover)"
if [ "${GC_N:-0}" -eq 0 ]; then
  row groundcover configured no - skipped - "add a groundcover block via /scoutflo:connect if you run groundcover"
else
  _gci=0
  while [ "$_gci" -lt "$GC_N" ]; do
    GC_INT="$(tint groundcover "$_gci" "$GC_N")"
    GC_TOKEN_VAR="$(tv groundcover "$GC_KIND" "$_gci" token_env)"
    if [ -z "$GC_TOKEN_VAR" ]; then
      row "$GC_INT" configured no - skipped - "add a groundcover block via /scoutflo:connect if you run groundcover"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      GC_TOKEN="$(printenv "$GC_TOKEN_VAR" 2>/dev/null || true)"
      GC_API="$(tv groundcover "$GC_KIND" "$_gci" api_url)"
      [ -n "$GC_API" ] || GC_API="https://api.groundcover.com"
      GC_API="${GC_API%/}"
      GC_BACKEND="$(tv groundcover "$GC_KIND" "$_gci" backend_id)"
      if [ -z "$GC_TOKEN" ]; then
        row "$GC_INT" env yes "$GC_TOKEN_VAR" env-missing - "$(missing_hint "$GC_TOKEN_VAR")"
        row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" skipped - "blocked: ${GC_TOKEN_VAR} is not set — see the ${GC_TOKEN_VAR} env row above, then rerun"
      else
        row "$GC_INT" env yes "$GC_TOKEN_VAR" pass - -
        note "doctor: checking ${GC_INT} monitors-read: POST ${GC_API}/api/monitors/list"
        GC_RC=0; GC_BODY="$(mktemp)"
        if [ -n "$GC_BACKEND" ]; then
          GC_META="$(curl -s -o "$GC_BODY" -w '%{http_code} %{content_type}' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -H "Authorization: Bearer ${GC_TOKEN}" -H "X-Backend-Id: ${GC_BACKEND}" \
            -H "Content-Type: application/json" \
            -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || GC_RC=$?
        else
          GC_META="$(curl -s -o "$GC_BODY" -w '%{http_code} %{content_type}' \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -H "Authorization: Bearer ${GC_TOKEN}" -H "Content-Type: application/json" \
            -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}')" || GC_RC=$?
        fi
        GC_CODE="${GC_META%% *}"; GC_CT="${GC_META#* }"
        if [ "$GC_RC" -ne 0 ]; then
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" fail "000" "$(transport_hint "$GC_RC") (${GC_API}/api/monitors/list)"
        elif [ "$GC_CODE" = "200" ] && printf '%s' "$GC_CT" | grep -qi json && jq -e 'type=="array" or type=="object"' "$GC_BODY" >/dev/null 2>&1; then
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" pass "$GC_CODE" "-"
        elif [ "$GC_CODE" = "200" ]; then
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "200 but Content-Type='${GC_CT}' / non-JSON body at ${GC_API} — on a self-hosted groundcover (non-api.groundcover.com) this usually means the monitors API is not exposed at this host, or an ingress/UI/proxy answered; a 200 HTML page is not proof of the monitors API"
        elif [ "$GC_CODE" = "401" ]; then
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "HTTP 401: API key invalid or expired; recreate on a Viewer-role service account per connect references/providers.md"
        elif [ "$GC_CODE" = "403" ]; then
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "HTTP 403: key lacks access, or this is a multi-backend account and groundcover.backend_id (X-Backend-Id) is missing or wrong"
        else
          row "$GC_INT" monitors-read yes "$GC_TOKEN_VAR" fail "$GC_CODE" "$(http_hint "$GC_CODE")"
        fi
        rm -f "$GC_BODY"
      fi
    fi
    _gci=$((_gci+1))
  done
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
    row prometheus env yes "$TOKEN_VAR" env-missing - "$(missing_hint "$TOKEN_VAR")"
  elif [ "$TOKEN_STATE" = "set" ]; then
    row prometheus env yes "$TOKEN_VAR" pass - -
  fi
  if [ -n "$PROM_URL" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    PROM_URL="${PROM_URL%/}"
    if [ "$PROM_BLOCKED" -eq 1 ]; then
      row prometheus query yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set — see the ${TOKEN_VAR} env row above, then rerun"
    else
      # vector(1) succeeds on a server with zero targets: it tests the API, not the fleet.
      # Assert the Prometheus JSON envelope so a 200 HTML/proxy page fails closed.
      live_check prometheus query "${PROM_URL}/api/v1/query?query=vector%281%29" "${TOKEN_VAR:-none}" "$TOKEN" '.status=="success"'
    fi
  else
    row prometheus configured no - skipped - "prometheus.url is empty; only alertmanager_url is set"
  fi
  if [ -n "$AM_URL" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    AM_URL="${AM_URL%/}"
    if [ "$PROM_BLOCKED" -eq 1 ]; then
      row alertmanager status yes "$TOKEN_VAR" skipped - "blocked: ${TOKEN_VAR} is not set — see the ${TOKEN_VAR} env row above, then rerun"
    else
      live_check alertmanager status "${AM_URL}/api/v2/status" "${TOKEN_VAR:-none}" "$TOKEN" '.cluster != null or .versionInfo != null'
    fi
  else
    row alertmanager configured no - skipped - "set prometheus.alertmanager_url if you run Alertmanager"
  fi
fi

# --- loki, tempo, mimir (same shape: /ready, optional token) -------------------------
# A loki/tempo URL often fronts VictoriaLogs/VictoriaTraces instead (drop-in for the
# same role) — those answer /health, not /ready. Probe /ready first, fall back to
# /health, and say which shape answered. audit-lgtm detects the engine either way.

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
    note "doctor: checking ${STORE} ready: GET ${STORE_URL}/ready"
    http_get "${STORE_URL}/ready" "$TOKEN"
    if [ "$CURL_RC" -eq 0 ] && [ "$HTTP_CODE" = "200" ]; then
      row "$STORE" ready yes "${TOKEN_VAR:-none}" pass "$HTTP_CODE" "-"
    else
      note "doctor: ${STORE} /ready did not answer 200; trying /health (VictoriaLogs/VictoriaTraces shape)"
      http_get "${STORE_URL}/health" "$TOKEN"
      if [ "$CURL_RC" -eq 0 ] && [ "$HTTP_CODE" = "200" ]; then
        row "$STORE" ready yes "${TOKEN_VAR:-none}" pass "$HTTP_CODE" "answers /health not /ready: VictoriaLogs/VictoriaTraces-style backend; audit-lgtm handles this automatically"
      else
        # both probes failed: report against the canonical /ready with full hints
        live_check "$STORE" ready "${STORE_URL}/ready" "${TOKEN_VAR:-none}" "$TOKEN"
      fi
    fi
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

# --- signoz (clickhouse-backed, otel-native) ----------------------------------------
# SigNoz authenticates with "SIGNOZ-API-KEY: <token>" on a Service Account token that must
# hold at least the read-only signoz-viewer role. /api/v1/version + /api/v1/health are open;
# /api/v1/rules requires >= viewer. A 200 with an HTML body is the SPA/login fall-through
# (a path moved on this version, or a proxy fronts auth) — not proof of API access.

SIGNOZ_KIND="$(tkind signoz)"; SIGNOZ_N="$(tcount signoz)"
if [ "${SIGNOZ_N:-0}" -eq 0 ]; then
  row signoz configured no - skipped - "add a signoz block via /scoutflo:connect if you run SigNoz"
else
  _szi=0
  while [ "$_szi" -lt "$SIGNOZ_N" ]; do
    SG_INT="$(tint signoz "$_szi" "$SIGNOZ_N")"
    SIGNOZ_URL="$(tv signoz "$SIGNOZ_KIND" "$_szi" url)"
    if [ -z "$SIGNOZ_URL" ]; then
      row "$SG_INT" configured no - skipped - "add a signoz block via /scoutflo:connect if you run SigNoz"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      SIGNOZ_URL="${SIGNOZ_URL%/}"
      SIGNOZ_TOKEN_VAR="$(tv signoz "$SIGNOZ_KIND" "$_szi" api_key_env)"
      SIGNOZ_TOKEN=""; SIGNOZ_TOKEN_STATE="none"
      if [ -n "$SIGNOZ_TOKEN_VAR" ]; then
        SIGNOZ_TOKEN="$(printenv "$SIGNOZ_TOKEN_VAR" 2>/dev/null || true)"
        if [ -n "$SIGNOZ_TOKEN" ]; then SIGNOZ_TOKEN_STATE="set"; else SIGNOZ_TOKEN_STATE="missing"; fi
      fi
      # Reachability + version (open, no auth) — echo the version the run verified against.
      SIG_VER="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "${SIGNOZ_URL}/api/v1/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
      if [ -n "$SIG_VER" ]; then
        row "$SG_INT" version yes - pass 200 "SigNoz ${SIG_VER}"
      else
        row "$SG_INT" version yes - fail - "GET ${SIGNOZ_URL}/api/v1/version did not return JSON with a .version — wrong host/port, or not a SigNoz API; verify signoz.url in toolkit.yaml"
      fi
      if [ -z "$SIGNOZ_TOKEN_VAR" ]; then
        row "$SG_INT" config yes - fail - "signoz.api_key_env is empty in toolkit.yaml; name the variable holding the Service Account token"
      elif [ "$SIGNOZ_TOKEN_STATE" = "missing" ]; then
        row "$SG_INT" env yes "$SIGNOZ_TOKEN_VAR" env-missing - "$(missing_hint "$SIGNOZ_TOKEN_VAR")"
        row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" skipped - "blocked: ${SIGNOZ_TOKEN_VAR} is not set — see the ${SIGNOZ_TOKEN_VAR} env row above, then rerun"
      else
        row "$SG_INT" env yes "$SIGNOZ_TOKEN_VAR" pass - -
        note "doctor: checking ${SG_INT} rules-read: GET ${SIGNOZ_URL}/api/v1/rules"
        SIGB="$(mktemp)"; SIGR=0
        SIGM="$(curl -s -o "$SIGB" -w '%{http_code} %{content_type}' \
          --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
          -H "SIGNOZ-API-KEY: ${SIGNOZ_TOKEN}" "${SIGNOZ_URL}/api/v1/rules")" || SIGR=$?
        SIGC="${SIGM%% *}"; SIGCT="${SIGM#* }"
        if [ "$SIGR" -ne 0 ]; then
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" fail "000" "$(transport_hint "$SIGR") (${SIGNOZ_URL}/api/v1/rules)"
        elif [ "$SIGC" = "200" ] && printf '%s' "$SIGCT" | grep -qi json && jq -e 'type=="array" or has("data") or has("rules")' "$SIGB" >/dev/null 2>&1; then
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" pass "$SIGC" "-"
        elif [ "$SIGC" = "200" ]; then
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" fail "$SIGC" "200 but Content-Type='${SIGCT}' / non-JSON: /api/v1/rules fell through to the SigNoz SPA/login page — path moved on ${SIG_VER:-this version} or a proxy fronts auth; not verified"
        elif [ "$SIGC" = "401" ]; then
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" fail "$SIGC" "HTTP 401: SIGNOZ-API-KEY missing or invalid; recreate per connect references/providers.md"
        elif [ "$SIGC" = "403" ]; then
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" fail "$SIGC" "HTTP 403 authz_forbidden: token authenticated but its service account has NO read role (below viewer) — assign it the read-only signoz-viewer role (SigNoz Settings -> Service Accounts -> Roles)"
        else
          row "$SG_INT" rules-read yes "$SIGNOZ_TOKEN_VAR" fail "$SIGC" "$(http_hint "$SIGC")"
        fi
        rm -f "$SIGB"
      fi
      # Optional ClickHouse deep-lane preflight. audit-signoz's SIG-030/SIG-060/SIG-061
      # read ClickHouse directly (signoz.clickhouse_url + clickhouse_user +
      # clickhouse_password_env); the SigNoz API token above does not cover it. Preflight
      # it read-only with a SELECT 1 (the same idiom as clickstack) so a broken CH path is
      # caught here, not mid-audit. Runs only when clickhouse_url is set; otherwise the deep
      # lane is not configured and the audit marks SIG-030/060/061 not-in-scope (no row).
      SIG_CH_URL="$(tv signoz "$SIGNOZ_KIND" "$_szi" clickhouse_url)"
      if [ -n "$SIG_CH_URL" ]; then
        SIG_CH_USER="$(tv signoz "$SIGNOZ_KIND" "$_szi" clickhouse_user)"; [ -n "$SIG_CH_USER" ] || SIG_CH_USER="signoz_ro"
        SIG_CH_PW_VAR="$(tv signoz "$SIGNOZ_KIND" "$_szi" clickhouse_password_env)"
        SIG_CH_PW=""; [ -n "$SIG_CH_PW_VAR" ] && SIG_CH_PW="$(printenv "$SIG_CH_PW_VAR" 2>/dev/null || true)"
        if [ -n "$SIG_CH_PW_VAR" ] && [ -z "$SIG_CH_PW" ]; then
          row "$SG_INT" clickhouse yes "$SIG_CH_PW_VAR" env-missing - "signoz.clickhouse_password_env names ${SIG_CH_PW_VAR} but it is not set; add it to ~/.scoutflo/env or run /scoutflo:connect — SIG-030/060/061 (the ClickHouse deep lane) need it"
        else
          note "doctor: checking ${SG_INT} clickhouse: SELECT 1 against ${SIG_CH_URL}"
          SIG_CH_BODY="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
            -H "X-ClickHouse-User: ${SIG_CH_USER}" ${SIG_CH_PW:+-H "X-ClickHouse-Key: ${SIG_CH_PW}"} \
            --data-binary 'SELECT 1' "${SIG_CH_URL%/}/" 2>/dev/null)" || SIG_CH_BODY=""
          if [ "$SIG_CH_BODY" = "1" ]; then
            row "$SG_INT" clickhouse yes "${SIG_CH_PW_VAR:-none}" pass 200 -
          else
            row "$SG_INT" clickhouse yes "${SIG_CH_PW_VAR:-none}" fail - "SELECT 1 as ${SIG_CH_USER} against ${SIG_CH_URL} did not return 1 — check the URL/port-forward, user, and password variable; audit-signoz SIG-030/060/061 (the ClickHouse deep lane) cannot read until this passes"
          fi
        fi
      fi
    fi
    _szi=$((_szi+1))
  done
fi

# --- digitalocean ------------------------------------------------------------------------

DO_KIND="$(tkind digitalocean)"; DO_N="$(tcount digitalocean)"
if [ "${DO_N:-0}" -eq 0 ]; then
  row digitalocean configured no - skipped - "add a digitalocean block via /scoutflo:connect if you run DigitalOcean"
else
  _doi=0
  while [ "$_doi" -lt "$DO_N" ]; do
    DO_INT="$(tint digitalocean "$_doi" "$DO_N")"
    DO_TOKEN_VAR_CHECK="$(tv digitalocean "$DO_KIND" "$_doi" token_env)"
    if [ -z "$DO_TOKEN_VAR_CHECK" ]; then
      row "$DO_INT" configured no - skipped - "add a digitalocean block via /scoutflo:connect if you run DigitalOcean"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      # audit-digitalocean runs almost entirely on doctl; surface a missing CLI as its
      # own row (matching aws/gcloud/kubectl) instead of letting the audit fail downstream.
      if ! command -v doctl >/dev/null 2>&1; then
        row "$DO_INT" binary-doctl yes - fail - "digitalocean is configured but doctl is not installed; install it (https://docs.digitalocean.com/reference/doctl/how-to/install/) — audit-digitalocean uses doctl for most checks"
      fi
      resolve_token_t digitalocean "$DO_KIND" "$_doi"
      if token_gate "$DO_INT" account; then
        live_check "$DO_INT" account "https://api.digitalocean.com/v2/account" "${TOKEN_VAR:-none}" "$TOKEN"
      fi
    fi
    _doi=$((_doi+1))
  done
fi

# --- gcp (gcloud identity, not a static bearer token) -------------------------------------

GCP_KIND="$(tkind gcp)"; GCP_N="$(tcount gcp)"
if [ "${GCP_N:-0}" -eq 0 ]; then
  row gcp configured no - skipped - "add a gcp block via /scoutflo:connect if you run Google Cloud"
else
  _gpi=0
  while [ "$_gpi" -lt "$GCP_N" ]; do
    GCP_INT="$(tint gcp "$_gpi" "$GCP_N")"
    GCP_PROJECT="$(tv gcp "$GCP_KIND" "$_gpi" project)"
    if [ -z "$GCP_PROJECT" ]; then
      row "$GCP_INT" configured no - skipped - "add a gcp block via /scoutflo:connect if you run Google Cloud"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      if ! command -v gcloud >/dev/null 2>&1; then
        row "$GCP_INT" binary-gcloud yes - fail - "gcp is configured but gcloud is not installed; install the Google Cloud CLI (https://cloud.google.com/sdk/docs/install) — macOS: brew install --cask google-cloud-sdk"
      else
        GCP_CRED_VAR="$(tv gcp "$GCP_KIND" "$_gpi" credentials_env)"
        GCP_TOKEN=""
        GCP_BLOCKED=0
        if [ -n "$GCP_CRED_VAR" ]; then
          GCP_CRED_PATH="$(printenv "$GCP_CRED_VAR" 2>/dev/null || true)"
          if [ -z "$GCP_CRED_PATH" ]; then
            row "$GCP_INT" env yes "$GCP_CRED_VAR" env-missing - "$(missing_hint "$GCP_CRED_VAR")"
            GCP_BLOCKED=1
          elif [ ! -f "$GCP_CRED_PATH" ]; then
            row "$GCP_INT" env yes "$GCP_CRED_VAR" fail - "${GCP_CRED_VAR} names a file that does not exist: ${GCP_CRED_PATH}"
            GCP_BLOCKED=1
          else
            row "$GCP_INT" env yes "$GCP_CRED_VAR" pass - -
            GCP_TOKEN="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
          fi
        else
          row "$GCP_INT" env yes none pass - -
          GCP_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
        fi
        if [ "$GCP_BLOCKED" -eq 1 ]; then
          row "$GCP_INT" identity yes "${GCP_CRED_VAR:-none}" skipped - "blocked: credentials not resolved — see the ${GCP_CRED_VAR:-none} env row above, then rerun"
        elif [ -z "$GCP_TOKEN" ]; then
          row "$GCP_INT" identity yes "${GCP_CRED_VAR:-none}" fail - "gcloud produced no access token; run gcloud auth login (or point credentials_env at a service-account key) and rerun doctor"
        else
          live_check "$GCP_INT" monitoring-api "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1" "${GCP_CRED_VAR:-none}" "$GCP_TOKEN"
          # Informational cost probe (like the AWS/Datadog ones): never fails doctor.
          # audit-cost reads this row to run GCP Recommender native-dollar checks or
          # report them excluded; the presence-fact GCP checks run regardless.
          GCP_COST_CHECKS="$(tv gcp "$GCP_KIND" "$_gpi" cost_checks)"
          if [ "$GCP_COST_CHECKS" = "false" ]; then
            row "$GCP_INT" cost-permissions yes "${GCP_CRED_VAR:-none}" skipped - "gcp.cost_checks is false in toolkit.yaml; audit-cost GCP Recommender checks will be skipped"
          else
            # status-probe-ok: informational cost-permissions probe on googleapis.com (fixed JSON API), skipped either way — never a pass/fail gate.
            GCP_REC_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GCP_TOKEN}" "https://recommender.googleapis.com/v1/projects/${GCP_PROJECT}/locations/global/recommenders/google.compute.image.IdleResourceRecommender/recommendations?pageSize=1" 2>/dev/null || echo 000)"
            if [ "$GCP_REC_CODE" = "200" ]; then
              row "$GCP_INT" cost-permissions yes "${GCP_CRED_VAR:-none}" pass "$GCP_REC_CODE" -
            else
              row "$GCP_INT" cost-permissions yes "${GCP_CRED_VAR:-none}" skipped "$GCP_REC_CODE" "Recommender API/viewer role not confirmed (HTTP ${GCP_REC_CODE}); audit-cost will report GCP native-dollar checks excluded with this reason, presence-fact checks still run"
            fi
          fi
        fi
      fi
    fi
    _gpi=$((_gpi+1))
  done
fi

# --- aws (aws CLI identity, not a static bearer token) -------------------------------------

AWS_KIND="$(tkind aws)"; AWS_N="$(tcount aws)"
if [ "${AWS_N:-0}" -eq 0 ]; then
  row aws configured no - skipped - "add an aws block via /scoutflo:connect if you run AWS"
else
  _awi=0
  while [ "$_awi" -lt "$AWS_N" ]; do
    AWS_INT="$(tint aws "$_awi" "$AWS_N")"
    AWS_ACCOUNT="$(tv aws "$AWS_KIND" "$_awi" account_id)"
    # aws.account_id is OPTIONAL here: audit-aws runs on the ambient credential chain
    # (profile/region/assumed role), NOT on a pinned account_id — so doctor probes that
    # SAME chain and always emits a pass/fail identity row instead of skipping when
    # account_id is unset, so doctor and the audit agree on when AWS is auditable. When
    # account_id IS set, doctor additionally asserts the live account matches it.
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    if ! command -v aws >/dev/null 2>&1; then
      row "$AWS_INT" binary-aws yes - fail - "aws is configured but the AWS CLI is not installed; install AWS CLI v2 (https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) — macOS: brew install awscli"
    else
      AWS_PROFILE_CFG="$(tv aws "$AWS_KIND" "$_awi" profile)"
      AWS_REGION_CFG="$(tv aws "$AWS_KIND" "$_awi" region)"
      AWS_ROLE_VAR="$(tv aws "$AWS_KIND" "$_awi" role_env)"
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
          row "$AWS_INT" env yes "$AWS_ROLE_VAR" env-missing - "$(missing_hint "$AWS_ROLE_VAR")"
          AWS_BLOCKED=1
        else
          row "$AWS_INT" env yes "$AWS_ROLE_VAR" pass - -
        fi
      else
        row "$AWS_INT" env yes none pass - -
      fi
      if [ "$AWS_BLOCKED" -eq 1 ]; then
        row "$AWS_INT" identity yes "${AWS_ROLE_VAR:-none}" skipped - "blocked: role ARN not resolved — see the ${AWS_ROLE_VAR:-none} env row above, then rerun"
      else
        note "doctor: checking ${AWS_INT} identity: aws sts get-caller-identity"
        STS_RC=0
        STS_OUT="$(aws_cli sts get-caller-identity --output json 2>&1)" || STS_RC=$?
        if [ "$STS_RC" -ne 0 ]; then
          row "$AWS_INT" identity yes "${AWS_ROLE_VAR:-none}" fail - "aws sts get-caller-identity failed: run aws configure (or export AWS credentials), then rerun doctor"
        else
          LIVE_ACCOUNT="$(printf '%s' "$STS_OUT" | jq -r '.Account // empty' 2>/dev/null || true)"
          if [ -z "$AWS_ACCOUNT" ]; then
            # account_id not pinned in toolkit.yaml: prove identity on the credential chain
            # (the audit uses the same chain) with no account match to assert. Surface the live
            # account so a wrong-account credential is still visible; pin aws.account_id to have
            # doctor enforce the expected-account match.
            row "$AWS_INT" identity yes "${AWS_ROLE_VAR:-none}" pass - "authenticated as account ${LIVE_ACCOUNT:-unknown}; aws.account_id is unset in toolkit.yaml so no expected account is pinned — set aws.account_id to have doctor assert the credential resolves to it"
          elif [ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ]; then
            row "$AWS_INT" identity yes "${AWS_ROLE_VAR:-none}" pass - -
          else
            row "$AWS_INT" identity yes "${AWS_ROLE_VAR:-none}" fail - "live account ${LIVE_ACCOUNT:-unknown} does not match aws.account_id ${AWS_ACCOUNT} in toolkit.yaml; fix the config or switch credentials"
          fi
          note "doctor: checking ${AWS_INT} cloudwatch reachability: aws cloudwatch describe-alarms --max-records 1"
          CW_RC=0
          aws_cli cloudwatch describe-alarms --max-records 1 >/dev/null 2>&1 || CW_RC=$?
          if [ "$CW_RC" -eq 0 ]; then
            row "$AWS_INT" cloudwatch-read yes "${AWS_ROLE_VAR:-none}" pass - -
          else
            row "$AWS_INT" cloudwatch-read yes "${AWS_ROLE_VAR:-none}" fail - "cloudwatch:DescribeAlarms denied or unreachable; grant the read-only policy in connect references/providers.md"
          fi
          # Optional cost-permission probe. Informational only: a missing scope here
          # never fails doctor or blocks the reliability checks. audit-aws reads this
          # row to decide whether to run the Cost & Resource Optimization section or
          # report it excluded with a reason.
          COST_CHECKS="$(tv aws "$AWS_KIND" "$_awi" cost_checks)"
          if [ "$COST_CHECKS" = "false" ]; then
            row "$AWS_INT" cost-permissions yes "${AWS_ROLE_VAR:-none}" skipped - "aws.cost_checks is false in toolkit.yaml; Cost & Resource Optimization section will be skipped"
          else
            CO_RC=0
            aws_cli compute-optimizer get-enrollment-status >/dev/null 2>&1 || CO_RC=$?
            if [ "$CO_RC" -eq 0 ]; then
              row "$AWS_INT" cost-permissions yes "${AWS_ROLE_VAR:-none}" pass - -
            else
              row "$AWS_INT" cost-permissions yes "${AWS_ROLE_VAR:-none}" skipped - "compute-optimizer/ce/support permissions not confirmed; audit-aws will report the affected Cost & Resource Optimization rows as excluded with this reason, not fail"
            fi
          fi
        fi
      fi
    fi
    _awi=$((_awi+1))
  done
fi

# --- github ------------------------------------------------------------------------

GITHUB_ORG="$(cfg github org)"
if [ -z "$GITHUB_ORG" ]; then
  row github configured no - skipped - "add a github block via /scoutflo:connect if you run map-repos"
else
  CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  resolve_token github
  if token_gate github org; then
    note "doctor: checking github org: GET https://api.github.com/orgs/${GITHUB_ORG}"
    http_get "https://api.github.com/orgs/${GITHUB_ORG}" "$TOKEN"
    if [ "$CURL_RC" -ne 0 ]; then
      row github org yes "${TOKEN_VAR:-none}" fail "000" "$(transport_hint "$CURL_RC") (https://api.github.com/orgs/${GITHUB_ORG})"
    elif [ "$HTTP_CODE" = "200" ]; then
      row github org yes "${TOKEN_VAR:-none}" pass "$HTTP_CODE" -
    elif [ "$HTTP_CODE" = "404" ]; then
      note "doctor: checking github user (org lookup 404'd): GET https://api.github.com/users/${GITHUB_ORG}"
      http_get "https://api.github.com/users/${GITHUB_ORG}" "$TOKEN"
      if [ "$CURL_RC" -ne 0 ]; then
        row github org yes "${TOKEN_VAR:-none}" fail "000" "$(transport_hint "$CURL_RC") (https://api.github.com/users/${GITHUB_ORG})"
      elif [ "$HTTP_CODE" = "200" ]; then
        row github org yes "${TOKEN_VAR:-none}" pass "$HTTP_CODE" "-"
      else
        row github org yes "${TOKEN_VAR:-none}" fail "$HTTP_CODE" "$(http_hint "$HTTP_CODE") (github.org is not an org or a user login GitHub recognizes)"
      fi
    else
      row github org yes "${TOKEN_VAR:-none}" fail "$HTTP_CODE" "$(http_hint "$HTTP_CODE")"
    fi
  fi
fi

# --- kubernetes --------------------------------------------------------------------------

KUBE_KIND="$(tkind kubernetes)"; KUBE_N="$(tcount kubernetes)"
KUBE_CONTEXT=""   # keep defined for the estate-coherence check below (set -u safe); a single block leaves it = the one context
if [ "${KUBE_N:-0}" -eq 0 ]; then
  row kubernetes configured no - skipped - "add a kubernetes block via /scoutflo:connect if you audit a cluster"
else
  _ki=0
  while [ "$_ki" -lt "$KUBE_N" ]; do
    K_INT="$(tint kubernetes "$_ki" "$KUBE_N")"
    KUBE_CONTEXT="$(tv kubernetes "$KUBE_KIND" "$_ki" context)"
    if [ -z "$KUBE_CONTEXT" ]; then
      row "$K_INT" configured no - skipped - "add a kubernetes block via /scoutflo:connect if you audit a cluster"
    else
      CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
      if ! command -v kubectl >/dev/null 2>&1; then
        row "$K_INT" binary-kubectl yes - fail - "kubernetes is configured but kubectl is not installed; install it (https://kubernetes.io/docs/tasks/tools/) — macOS: brew install kubectl"
      else
        note "doctor: checking ${K_INT} rbac: kubectl --context ${KUBE_CONTEXT} auth can-i get pods"
        K_RC=0
        K_OUT="$(kubectl --context "$KUBE_CONTEXT" --request-timeout=10s auth can-i get pods 2>&1)" || K_RC=$?
        K_LINE="$(printf '%s' "$K_OUT" | head -n 1 | tr '\t' ' ')"
        if [ "$K_LINE" = "yes" ]; then
          row "$K_INT" rbac yes - pass - -
        elif [ "$K_LINE" = "no" ]; then
          row "$K_INT" rbac yes - fail - "context reaches the cluster but lacks read RBAC; bind the view ClusterRole per connect references/providers.md"
        else
          row "$K_INT" rbac yes - fail - "context error: ${K_LINE}; run kubectl config get-contexts and fix kubernetes.context — a GKE/EKS/AKS context failing here often needs exec-plugin reauth (gcloud auth login / aws sso login / az aks get-credentials), not an RBAC change. A private or unreachable API server (no such host, dial tcp, i/o timeout, connection refused) is a NETWORK problem, not RBAC: run from inside the VNet, add your IP to the cluster API-server authorized ranges, or use 'az aks command invoke'"
        fi
      fi
    fi
    _ki=$((_ki+1))
  done
fi

# --- clickstack (ClickHouse + HyperDX) ------------------------------------------------------
# ClickHouse OR HyperDX — at least one; a HyperDX-only target is fully supported. The two lanes
# are probed INDEPENDENTLY: the ClickHouse SELECT 1 runs only when clickhouse_url is set, and the
# HyperDX probes run whenever hyperdx_url is set (never gated on ClickHouse). The target counts as
# configured when EITHER lane is present, so a HyperDX-only config is never reported "not configured".

CS_KIND="$(tkind clickstack)"; CS_N="$(tcount clickstack)"
_csi=0
while [ "$_csi" -lt "${CS_N:-0}" ]; do
  CS_INT="$(tint clickstack "$_csi" "$CS_N")"
  CH_URL_CFG="$(tv clickstack "$CS_KIND" "$_csi" clickhouse_url)"
  HDX_URL_CFG="$(tv clickstack "$CS_KIND" "$_csi" hyperdx_url)"
  # Count this target once when EITHER lane is configured (guard so ClickHouse+HyperDX
  # on one target counts once, and a HyperDX-only target is not counted as absent).
  if [ -n "$CH_URL_CFG" ] || [ -n "$HDX_URL_CFG" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
  fi
  # ClickHouse lane: read-only SELECT 1, only when clickhouse_url is set for THIS target.
  if [ -n "$CH_URL_CFG" ]; then
    CH_USER_CFG="$(tv clickstack "$CS_KIND" "$_csi" clickhouse_user)"; [ -n "$CH_USER_CFG" ] || CH_USER_CFG="default"
    CH_PW_VAR="$(tv clickstack "$CS_KIND" "$_csi" clickhouse_password_env)"
    CH_PW=""; [ -n "$CH_PW_VAR" ] && CH_PW="$(printenv "$CH_PW_VAR" 2>/dev/null || true)"
    if [ -n "$CH_PW_VAR" ] && [ -z "$CH_PW" ]; then
      row "$CS_INT" clickhouse yes "$CH_PW_VAR" env-missing - "$(missing_hint "$CH_PW_VAR")"
    else
      note "doctor: checking ${CS_INT} clickhouse: SELECT 1 against ${CH_URL_CFG}"
      CH_BODY="$(curl -s --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
        -H "X-ClickHouse-User: ${CH_USER_CFG}" ${CH_PW:+-H "X-ClickHouse-Key: ${CH_PW}"} \
        --data-binary 'SELECT 1' "${CH_URL_CFG%/}/" 2>/dev/null)" || CH_BODY=""
      if [ "$CH_BODY" = "1" ]; then
        row "$CS_INT" clickhouse yes "${CH_PW_VAR:-none}" pass 200 -
      else
        row "$CS_INT" clickhouse yes "${CH_PW_VAR:-none}" fail - "SELECT 1 as ${CH_USER_CFG} against ${CH_URL_CFG} did not return 1 — check the URL/port-forward, user, and password variable; audit-clickstack cannot read anything until this passes"
      fi
    fi
  fi
  # HyperDX lane: runs whenever hyperdx_url is set, INDEPENDENT of ClickHouse.
  if [ -n "$HDX_URL_CFG" ]; then
    # status-probe-ok: unauthenticated /api/health reachability ping (no credential sent); the authed read is the /api/v2 Bearer probe below with the Personal API Access Key.
    HDX_HC="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "${HDX_URL_CFG%/}/api/health")" || HDX_HC="000"
    if [ "$HDX_HC" = "200" ]; then
      row "$CS_INT" hyperdx-health yes - pass 200 "reachable; note: HyperDX reads via the external API v2 (/api/v2/*) with the per-user Personal API Access Key (Authorization: Bearer) set in hyperdx_api_key_env — NOT the team ingestion key (which 401s there). Legacy fallback: hyperdx_email_env + hyperdx_password_env (session login). With neither, the HyperDX categories are marked not-in-scope (expected)"
    else
      row "$CS_INT" hyperdx-health yes - fail "$HDX_HC" "GET ${HDX_URL_CFG%/}/api/health did not return 200 — check clickstack.hyperdx_url"
    fi
    # Optional v2 session-login credentials: presence-check only, never a login from doctor
    # and never a value printed. Both-or-neither: one without the other cannot log in.
    HDX_EMAIL_VAR="$(tv clickstack "$CS_KIND" "$_csi" hyperdx_email_env)"
    HDX_PW_VAR="$(tv clickstack "$CS_KIND" "$_csi" hyperdx_password_env)"
    if [ -n "$HDX_EMAIL_VAR" ] || [ -n "$HDX_PW_VAR" ]; then
      HDX_EMAIL_VAL=""; [ -n "$HDX_EMAIL_VAR" ] && HDX_EMAIL_VAL="$(printenv "$HDX_EMAIL_VAR" 2>/dev/null || true)"
      HDX_PW_VAL=""; [ -n "$HDX_PW_VAR" ] && HDX_PW_VAL="$(printenv "$HDX_PW_VAR" 2>/dev/null || true)"
      if [ -n "$HDX_EMAIL_VAR" ] && [ -n "$HDX_PW_VAR" ] && [ -n "$HDX_EMAIL_VAL" ] && [ -n "$HDX_PW_VAL" ]; then
        row "$CS_INT" hyperdx-login-env yes "$HDX_PW_VAR" pass - "v2 login credentials present (presence-checked only) — audit-clickstack obtains a session via POST /api/login/password (cookie in a 0600 mktemp jar, deleted on exit) and scores CS-040/CS-041"
      else
        row "$CS_INT" hyperdx-login-env yes "${HDX_PW_VAR:-$HDX_EMAIL_VAR}" env-missing - "clickstack.hyperdx_email_env/hyperdx_password_env are configured but incomplete (both keys and both variables must be set); add the missing piece to ~/.scoutflo/env or run /scoutflo:connect — until then the v2 HyperDX categories stay not-in-scope"
      fi
    fi
    # Personal API Access Key: a LIVE JSON-asserting Bearer probe (the same pattern
    # audit-clickstack uses), not a presence check — probe both the direct /api/v2 form
    # and the app-proxy-doubled /api/api/v2 form, and credit only on a real JSON body.
    HDX_KEY_VAR="$(tv clickstack "$CS_KIND" "$_csi" hyperdx_api_key_env)"
    if [ -n "$HDX_KEY_VAR" ]; then
      HDX_API_KEY="$(printenv "$HDX_KEY_VAR" 2>/dev/null || true)"
      if [ -z "$HDX_API_KEY" ]; then
        row "$CS_INT" hyperdx-api-key yes "$HDX_KEY_VAR" env-missing - "$(missing_hint "$HDX_KEY_VAR")"
      else
        note "doctor: checking ${CS_INT} hyperdx-api-key: GET ${HDX_URL_CFG%/}/api/v2/alerts (Bearer)"
        _hdx_ok=0; _hdx_c=""
        for _b in "/api/v2" "/api/api/v2"; do
          _hb="$(mktemp)"
          _meta="$(curl -s -o "$_hb" -w '%{http_code} %{content_type}' --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL_CFG%/}${_b}/alerts")" || _meta="000 -"
          _hdx_c="${_meta%% *}"; _hdx_ct="${_meta#* }"
          if [ "$_hdx_c" = "200" ] && printf '%s' "$_hdx_ct" | grep -qi json && jq -e 'type=="array" or has("data") or has("alerts")' "$_hb" >/dev/null 2>&1; then
            _hdx_ok=1; rm -f "$_hb"; break
          fi
          rm -f "$_hb"
        done
        if [ "$_hdx_ok" = "1" ]; then
          row "$CS_INT" hyperdx-api-key yes "$HDX_KEY_VAR" pass 200 "Personal API Access Key verified (GET /api/v2/alerts -> 200 JSON)"
        elif [ "$_hdx_c" = "401" ] || [ "$_hdx_c" = "403" ]; then
          row "$CS_INT" hyperdx-api-key yes "$HDX_KEY_VAR" fail "$_hdx_c" "HTTP ${_hdx_c} on GET ${HDX_URL_CFG%/}/api/v2/alerts (also tried /api/api/v2): this looks like the team INGESTION key, not the per-user Personal API Access Key (Settings -> API Keys) — recreate per connect references/providers.md; legacy fallback: the hyperdx_email_env + hyperdx_password_env session pair"
        elif [ "$_hdx_c" = "000" ] || [ -z "$_hdx_c" ]; then
          row "$CS_INT" hyperdx-api-key yes "$HDX_KEY_VAR" fail "000" "could not reach ${HDX_URL_CFG%/}/api/v2/alerts (also tried /api/api/v2) — transport failure, not an auth error; check clickstack.hyperdx_url and the network path"
        else
          row "$CS_INT" hyperdx-api-key yes "$HDX_KEY_VAR" fail "$_hdx_c" "GET ${HDX_URL_CFG%/}/api/v2/alerts (also tried /api/api/v2) returned HTTP ${_hdx_c} without the expected JSON alerts body — $(http_hint "$_hdx_c"); if this fronts an SSO/SPA the Personal API Access Key never reached the API"
        fi
      fi
    fi
  fi
  # clickstack credential keys configured without a hyperdx_url are silently unused —
  # say so instead of leaving the user to wonder why HyperDX categories stay not-in-scope.
  if [ -n "$CH_URL_CFG" ] && [ -z "$HDX_URL_CFG" ]; then
    _hdx_stray=""
    for _k in hyperdx_email_env hyperdx_password_env hyperdx_api_key_env; do
      [ -n "$(tv clickstack "$CS_KIND" "$_csi" "$_k")" ] && _hdx_stray="${_hdx_stray} ${_k}"
    done
    [ -n "$_hdx_stray" ] && row "$CS_INT" hyperdx-config yes - warn - "clickstack.${_hdx_stray# } configured but clickstack.hyperdx_url is not set — these credentials are unused until hyperdx_url is added; HyperDX categories stay not-in-scope"
  fi
  _csi=$((_csi+1))
done

# --- azure (az CLI identity, mirrors the audit-azure doctor gate) ---------------------------

AZ_KIND="$(tkind azure)"; AZ_N="$(tcount azure)"
_azi=0
while [ "$_azi" -lt "${AZ_N:-0}" ]; do
  AZ_INT="$(tint azure "$_azi" "$AZ_N")"
  AZ_SUB="$(tv azure "$AZ_KIND" "$_azi" subscription_id)"
  if [ -n "$AZ_SUB" ]; then
    CONFIGURED_COUNT=$((CONFIGURED_COUNT + 1))
    if ! command -v az >/dev/null 2>&1; then
      row "$AZ_INT" binary-az yes - fail - "azure block configured but the az CLI is not installed; install it (https://learn.microsoft.com/cli/azure/install-azure-cli) — macOS: brew install azure-cli"
    else
      note "doctor: checking ${AZ_INT} identity: az account show --subscription ${AZ_SUB}"
      if az account show --subscription "$AZ_SUB" --query id -o tsv >/dev/null 2>&1; then
        row "$AZ_INT" identity yes - pass - -
      else
        row "$AZ_INT" identity yes - fail - "az account show failed for subscription ${AZ_SUB} — run az login and confirm the subscription id in toolkit.yaml"
      fi
    fi
  fi
  _azi=$((_azi+1))
done

# --- unknown blocks: never let a configured block silently skip -----------------------------
# Every top-level key in toolkit.yaml must be one doctor knows how to check; a block
# doctor does not know is reported, never silently ignored (a clickstack-only config
# once exited 0 "PASS" with zero rows — that class of false green is what this kills).

KNOWN_BLOCKS="grafana sentry pagerduty datadog elk jsm zenduty groundcover prometheus alertmanager loki tempo mimir victoriametrics vmalert signoz digitalocean gcp aws azure github kubernetes clickstack slack"
for blk in $(sed -n 's/^\([a-z_][a-z_0-9]*\):.*$/\1/p' "$CONFIG" | sort -u); do
  case " $KNOWN_BLOCKS " in
    *" $blk "*) : ;;
    *) row "$blk" not-checked-by-doctor yes - warn - "toolkit.yaml has a '${blk}:' block that doctor has no check for — its health is UNKNOWN, not verified; if this is a real integration, doctor needs a check for it" ;;
  esac
done

# --- placeholder secrets: catch '<your-token>'-style stubs before they burn a 401 ----------

sed -n 's/^[[:space:]]\{1,\}[a-z_]*_env:[[:space:]]*//p' "$CONFIG" | sed 's/[[:space:]]#.*$//' | sort -u | while IFS= read -r pv; do
  [ -n "$pv" ] || continue
  pval="$(printenv "$pv" 2>/dev/null || true)"
  [ -n "$pval" ] || continue
  case "$pval" in
    \<*\>|changeme|CHANGEME|your-*|YOUR-*|xxx*|XXX*|placeholder|PLACEHOLDER|TODO|todo)
      row env placeholder-token yes "$pv" warn - "${pv} is set to a placeholder-looking value — replace it with the real secret in ~/.scoutflo/env before it burns a live 401" ;;
  esac
done

# --- estate coherence (topology vs config) ------------------------------------------------
# A config can drift into naming TWO estates at once: kubernetes.context pointing at one
# cluster while topology.md (and the audits that read it) was generated against another.
# Every audit then correlates findings against the wrong service map. This check catches the
# exact mismatch mechanically: the cluster context recorded in topology.md's header must be
# the same string as kubernetes.context. It only runs when both sides exist; a missing
# topology.md is a normal pre-map-topology state, not a failure.

TOPO_MD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md"
if [ -n "$KUBE_CONTEXT" ] && [ -f "$TOPO_MD" ]; then
  TOPO_CTX="$(awk -F'|' '/Cluster context/ {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$TOPO_MD")"
  if [ -z "$TOPO_CTX" ]; then
    row estate coherence yes - skipped - "topology.md has no 'Cluster context' header row; regenerate it with /scoutflo:map-topology"
  elif [ "$TOPO_CTX" = "$KUBE_CONTEXT" ]; then
    row estate coherence yes - pass - -
  else
    row estate coherence yes - fail - "mixed estate: topology.md was generated against '${TOPO_CTX}' but kubernetes.context is '${KUBE_CONTEXT}' — re-run /scoutflo:map-topology against the current context, or fix kubernetes.context; audits would otherwise correlate against the wrong service map"
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
    row slack env yes "$SLACK_VAR" env-missing - "$(missing_hint "$SLACK_VAR")"
    row slack webhook-post yes "$SLACK_VAR" skipped - "blocked: ${SLACK_VAR} is not set — see the ${SLACK_VAR} env row above, then rerun"
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
  note "doctor: FAIL (exit 2): required env vars are missing — add them to ~/.scoutflo/env (the plugin reads that file, not your shell), then rerun; the env-missing rows above name the exact variables"
  exit 2
fi
if [ "$ANY_FAIL" -eq 1 ]; then
  note "doctor: FAIL (exit 3): at least one live check failed; fix per the hints, then rerun"
  exit 3
fi
note "doctor: PASS: every configured integration passed"
exit 0
