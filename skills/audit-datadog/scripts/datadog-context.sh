#!/bin/sh
# Sourced, stateless target/path resolution. No provider calls at load time.
set +x
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _dd_c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_dd_c" ] && { CFG="$_dd_c"; break; }; done
[ -f "$CFG" ] || { echo 'Datadog config missing; select SCOUTFLO_CONFIG or run /scoutflo:connect.' >&2; exit 2; }
TT="${CLAUDE_PLUGIN_ROOT:?plugin root required}/report-standard/toolkit-targets.sh"
DD_KIND=$(sh "$TT" "$CFG" datadog kind)
DD_N=$(sh "$TT" "$CFG" datadog count)
[ "$DD_N" -gt 0 ] || { echo 'No Datadog target configured.' >&2; exit 2; }
DD_IDX=0
if [ "$DD_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select SCOUTFLO_TARGET from the configured Datadog labels.' >&2; exit 2; }
  _dd_found=0; _dd_labels='|'; _dd_i=0
  while [ "$_dd_i" -lt "$DD_N" ]; do
    _dd_label=$(sh "$TT" "$CFG" datadog label "$_dd_i")
    case "$_dd_label" in ''|*[!a-zA-Z0-9_-]*) echo 'Invalid Datadog target label.' >&2; exit 2;; esac
    case "$_dd_labels" in *"|$_dd_label|"*) echo 'Duplicate Datadog target label.' >&2; exit 2;; esac
    _dd_labels="${_dd_labels}${_dd_label}|"
    if [ "$_dd_label" = "$SCOUTFLO_TARGET" ]; then DD_IDX=$_dd_i; _dd_found=1; fi
    _dd_i=$((_dd_i+1))
  done
  [ "$_dd_found" = 1 ] || { echo 'Selected Datadog target does not exist; no fallback.' >&2; exit 2; }
fi
DD_LABEL=$(sh "$TT" "$CFG" datadog label "$DD_IDX")
DD_SEG=datadog; [ "$DD_KIND" != seq ] || DD_SEG="datadog/$DD_LABEL"
DD_SITE=$(sh "$TT" "$CFG" datadog get "$DD_IDX" site); DD_SITE=${DD_SITE:-datadoghq.com}
case "$DD_SITE" in datadoghq.com|us3.datadoghq.com|us5.datadoghq.com|datadoghq.eu|ap1.datadoghq.com|ap2.datadoghq.com|ddog-gov.com) ;; *) echo 'Unsupported Datadog site; use the documented site suffix, not a URL.' >&2; exit 2;; esac
DD_HOST="api.$DD_SITE"
RUN_DATE=${SCOUTFLO_DATADOG_RUN_DATE:-$(date -u +%Y-%m-%d)}
python3 -c 'import datetime,sys; d=datetime.date.fromisoformat(sys.argv[1]); assert d<=datetime.datetime.now(datetime.timezone.utc).date()' "$RUN_DATE" || { echo 'Invalid Datadog run date.' >&2; exit 2; }
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DD_SEG}"
OUT="${TARGET_DIR}/${RUN_DATE}"
RAW_DIR="${OUT}/raw"
export DD_SEG DD_SITE
unset DD_CREDENTIAL_GENERATION


dd_credentials() {
  SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
  [ -n "$SCOUTFLO_ENV" ] || { if [ -f ./.scoutflo/env ]; then SCOUTFLO_ENV=./.scoutflo/env; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
  DD_API_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" api_key_env); DD_API_VAR=${DD_API_VAR:-DATADOG_API_KEY}
  DD_APP_VAR=$(sh "$TT" "$CFG" datadog get "$DD_IDX" app_key_env); DD_APP_VAR=${DD_APP_VAR:-DATADOG_APP_KEY}
  for _dd_var in "$DD_API_VAR" "$DD_APP_VAR"; do
    case "$_dd_var" in ''|[0-9]*|*[!a-zA-Z0-9_]*) echo 'Invalid Datadog credential variable name.' >&2; return 2;; esac
  done
  # Import only the two selected variables. Never source the store into this shell.
  _dd_api=$(sh -c '( set -a; [ ! -f "$1" ] || . "$1" >/dev/null 2>&1; set +a; printenv "$2" )' _ "$SCOUTFLO_ENV" "$DD_API_VAR" 2>/dev/null || true)
  _dd_app=$(sh -c '( set -a; [ ! -f "$1" ] || . "$1" >/dev/null 2>&1; set +a; printenv "$2" )' _ "$SCOUTFLO_ENV" "$DD_APP_VAR" 2>/dev/null || true)
  [ -n "$_dd_api" ] && [ -n "$_dd_app" ] || { echo 'Selected Datadog credentials missing; no fallback to different variable names.' >&2; return 2; }
  DATADOG_API_KEY=$_dd_api; DATADOG_APP_KEY=$_dd_app
  export DATADOG_API_KEY DATADOG_APP_KEY DD_API_VAR DD_APP_VAR
  _dd_generation=$(python3 - "$TARGET_DIR" <<'PYGEN'
import hashlib,hmac,json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); p.mkdir(parents=True,exist_ok=True)
k=p/'.credential-generation-key'
try:
    fd=os.open(str(k),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
except FileExistsError: pass
else:
    with os.fdopen(fd,'wb') as f: f.write(os.urandom(32))
assert not k.is_symlink() and stat.S_IMODE(k.stat().st_mode)==0o600
key=k.read_bytes(); assert len(key)==32
fields=[os.environ[x] for x in ('DD_SEG','DD_SITE','DD_API_VAR','DD_APP_VAR','DATADOG_API_KEY','DATADOG_APP_KEY')]
print(hmac.new(key,json.dumps(fields,separators=(',',':')).encode(),hashlib.sha256).hexdigest())
PYGEN
  ) || { echo 'Private credential-generation binding unavailable.' >&2; return 2; }
  if [ -n "${DD_CREDENTIAL_GENERATION:-}" ] && [ "$DD_CREDENTIAL_GENERATION" != "$_dd_generation" ]; then
    echo 'Datadog credentials changed during this capture; restart the owning recipe.' >&2; return 2
  fi
  DD_CREDENTIAL_GENERATION=$_dd_generation; export DD_CREDENTIAL_GENERATION
}

dd_prerequisites() {
  for _dd_bin in curl jq python3; do command -v "$_dd_bin" >/dev/null || { echo "Missing binary: $_dd_bin" >&2; return 2; }; done
  _dd_curl=$(curl --version | head -1)
  printf '%s' "$_dd_curl" | python3 -c 'import re,sys; assert sys.version_info >= (3,8); m=re.match(r"curl (\d+)\.(\d+)\.(\d+)",sys.stdin.read()); assert m and tuple(map(int,m.groups())) >= (8,4,0)' 2>/dev/null || { echo 'Datadog requires Python >=3.8 and curl >=8.4 for bounded unknown-length responses.' >&2; return 2; }
}

dd_read() {
  # Fixed GET recipes plus the read-only events search POST. No redirects, raw files or errors.
  _dd_mode=$1; _dd_path=$2
  case "$_dd_path" in /api/*) ;; *) echo 'Datadog read requires a relative API path.' >&2; return 2;; esac
  case "$_dd_path" in *'..'*|*'://'*) echo 'Invalid Datadog API path.' >&2; return 2;; esac
  dd_prerequisites || return 2
  dd_credentials || return 2
  set --
  if [ "$_dd_mode" = events-v2 ]; then
    [ "$_dd_path" = /api/v2/events/search ] || return 2
    _dd_to=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _dd_from=$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
    _dd_body=$(jq -n --arg from "$_dd_from" --arg to "$_dd_to" '{filter:{query:"source:alert",from:$from,to:$to},page:{limit:1000}}')
    set -- -X POST -H 'Content-Type: application/json' --data "$_dd_body"
  fi
  _dd_response=$(curl --disable --globoff --silent --proto '=https' --max-time 45 --max-filesize 8388608 \
    -H "DD-API-KEY: $DATADOG_API_KEY" -H "DD-APPLICATION-KEY: $DATADOG_APP_KEY" \
    -w '\n%{http_code} %{content_type}' "$@" "https://${DD_HOST}${_dd_path}" 2>/dev/null) || {
      echo 'Datadog transport/size limit failure; dependent checks blocked; no raw response retained.' >&2; return 2;
    }
  printf '%s' "$_dd_response" | sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/project-read.sh" "$_dd_mode"
}

dd_capture() {
  _dd_file=$3
  case "$_dd_file" in *[!a-zA-Z0-9._-]*|'') echo 'Invalid Datadog evidence filename.' >&2; return 2;; esac
  dd_credentials || return 2
  umask 077; mkdir -p "$RAW_DIR"
  if _dd_safe=$(dd_read "$1" "$2"); then
    printf '%s\n' "$_dd_safe" > "$RAW_DIR/$_dd_file"
    dd_stamp "$_dd_file"
    rm -f "$RAW_DIR/$_dd_file.blocked"
  else
    # Clear a stale same-day success, but never substitute [] for denied evidence.
    rm -f "$RAW_DIR/$_dd_file"
    printf '%s\n' 'Read blocked; repeat the owning read before assessing dependent checks.' > "$RAW_DIR/$_dd_file.blocked"
    return 2
  fi
}

dd_stamp() {
  dd_credentials || return 2
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/capture-meta.sh" write "$RAW_DIR/$1" "$DD_SEG" "$DD_SITE" "$RUN_DATE"
}
dd_require() {
  dd_credentials || return 2
  for _dd_evidence in "$@"; do
    sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/capture-meta.sh" check "$RAW_DIR/$_dd_evidence" "$DD_SEG" "$DD_SITE" "$RUN_DATE" || return 2
  done
}
