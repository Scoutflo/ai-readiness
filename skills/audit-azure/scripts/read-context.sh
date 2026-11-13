#!/bin/sh
# Sourced by the Azure audit's fixed command recipes. No request runs on source.
# Target resolution is shared by live reads and local report consumers.
set +x
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -f "$CFG" ] || { echo "Azure blocked: selected config unavailable" >&2; return 1; }
TT="${CLAUDE_PLUGIN_ROOT:?plugin root required}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
[ "${AZ_N:-0}" -gt 0 ] || { echo "Azure blocked: no configured target" >&2; return 1; }
AZ_IDX=""; _i=0
while [ "$_i" -lt "$AZ_N" ]; do
  _label=$(sh "$TT" "$CFG" azure label "$_i")
  if [ -n "${SCOUTFLO_TARGET:-}" ]; then
    [ "$_label" != "$SCOUTFLO_TARGET" ] || AZ_IDX="$_i"
  elif [ "$AZ_KIND" = map ]; then AZ_IDX="$_i"; fi
  _i=$((_i + 1))
done
[ -n "$AZ_IDX" ] || { echo "Azure blocked: select an exact SCOUTFLO_TARGET label for the configured list" >&2; return 1; }
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX")
case "$AZ_LABEL" in ''|.|..|*[!A-Za-z0-9_-]*) echo "Azure blocked: unsafe target label" >&2; return 1;; esac
SUB=$(sh "$TT" "$CFG" azure get "$AZ_IDX" subscription_id)
AZ_TENANT_CFG=$(sh "$TT" "$CFG" azure get "$AZ_IDX" tenant_id)
[ -n "$SUB" ] || { echo "Azure blocked: subscription_id is required" >&2; return 1; }
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/$AZ_LABEL"; else AZ_SEG=azure; fi
RUN_DATE="${SCOUTFLO_RUN_DATE:-$(date -u +%Y-%m-%d)}"
printf '%s\n' "$RUN_DATE" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || { echo "Azure blocked: invalid run date" >&2; return 1; }
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}"
OUT="$TARGET_DIR/$RUN_DATE"; RAW_DIR="$OUT/raw"; ARM=https://management.azure.com
AZ_RUN_ID=""; AZ_RUN_DIR=""
if [ -f "$TARGET_DIR/.active-run" ]; then
  AZ_RUN_ID=$(cat "$TARGET_DIR/.active-run")
  case "$AZ_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo "Azure blocked: invalid run pointer" >&2; return 1;; esac
  AZ_RUN_DIR="$TARGET_DIR/runs/$AZ_RUN_ID"
  jq -e --arg label "$AZ_LABEL" --arg sub "$SUB" '.target==$label and .subscription_config==$sub' "$AZ_RUN_DIR/worklist.json" >/dev/null \
    || { echo "Azure blocked: worklist belongs to another selected target" >&2; return 1; }
  RUN_DATE=$(jq -r .run_date "$AZ_RUN_DIR/worklist.json")
  OUT="$TARGET_DIR/$RUN_DATE"; RAW_DIR="$AZ_RUN_DIR/raw"
fi

# Raw-provider jq errors can echo fragments of credential-bearing fields.
# Buffer stdout too: a later malformed item must not leave partial success output.
azure_project() {
  _projected=$(jq "$@" 2>/dev/null) || { echo "Azure blocked: provider projection failed" >&2; return 1; }
  [ -z "$_projected" ] || printf '%s\n' "$_projected"
}

azure_identity() {
  # Account listing is identity metadata only; never select an ambient account.
  _accounts=$(az account list -o json 2>/dev/null) || { echo "Azure blocked: account metadata unavailable" >&2; return 1; }
  _resolved=$(printf '%s' "$_accounts" | azure_project -er --arg s "$SUB" '
    if type!="array" then error("accounts") else . end
    |([.[]|select(.id==$s)]) as $ids
    |(if ($ids|length)>0 then $ids else [.[]|select(.name==$s)] end)
    |if length==1 then .[0].id else error("ambiguous or invisible subscription") end') \
    || { echo "Azure blocked: subscription is invisible or its name is ambiguous; use a unique ID" >&2; return 1; }
  SUB=$_resolved
  _acct=$(az account show --subscription "$SUB" -o json 2>/dev/null) || { echo "Azure blocked: selected account unavailable" >&2; return 1; }
  printf '%s' "$_acct" | azure_project -se --arg sub "$SUB" --arg tenant "$AZ_TENANT_CFG" '
    length==1 and (.[0] | type=="object" and (.id|type=="string" and length>0)
      and (.id==$sub or .name==$sub) and (.tenantId|type=="string" and length>0)
      and ($tenant=="" or .tenantId==$tenant) and (.user.name|type=="string" and length>0))' >/dev/null 2>&1 \
    || { echo "Azure blocked: subscription or tenant identity mismatch" >&2; return 1; }
  SUB=$(printf '%s' "$_acct" | azure_project -r .id)
  case "$SUB" in ''|*[!A-Za-z0-9-]*) echo "Azure blocked: invalid resolved subscription ID" >&2; return 1;; esac
  printf '%s' "$_acct" | azure_project --arg label "$AZ_LABEL" '{target:$label,subscription:.id,tenant:.tenantId,identity:.user.name}' >&2
}

azure_token() {
  ARM_TOKEN=$(az account get-access-token --subscription "$SUB" --resource "$ARM" --query accessToken -o tsv 2>/dev/null) \
    || { echo "Azure blocked: token request failed" >&2; return 1; }
  case "$ARM_TOKEN" in ''|*[[:space:]]*) echo "Azure blocked: token unavailable or malformed" >&2; return 1;; esac
}

# A CLI error, empty stream, error envelope or malformed JSON never becomes [].
azure_cli() {
  _json=$(az "$@" --subscription "$SUB" -o json 2>/dev/null) || { echo "Azure blocked: CLI read failed" >&2; return 1; }
  printf '%s' "$_json" | jq -se 'length==1 and (.[0] | (type=="object" or type=="array") and (if type=="object" then has("error")|not else true end))' >/dev/null 2>&1 \
    || { echo "Azure blocked: CLI returned no valid JSON result" >&2; return 1; }
  printf '%s' "$_json"
}

# Validate before sending credentials. Continuations must stay on the original
# collection path, on the fixed ARM origin, inside the selected subscription.
azure_url() {
  python3 - "$SUB" "$1" "${2:-$1}" <<'PY'
import sys, urllib.parse
sub, first, value = sys.argv[1:]
try:
    a, b = map(urllib.parse.urlsplit, (first, value))
    path = urllib.parse.unquote(b.path)
    assert b.scheme == 'https' and b.hostname == 'management.azure.com'
    assert b.port in (None,443) and not b.username and not b.password and not b.fragment
    assert not any(ord(c)<33 for c in value) and '\\' not in path
    assert not any(p in ('.','..') for p in path.split('/')) and '%' not in path
    assert urllib.parse.parse_qs(b.query).get('api-version') == urllib.parse.parse_qs(a.query).get('api-version')
    assert path.lower().startswith('/subscriptions/'+sub.lower()+'/')
    assert path.lower() == urllib.parse.unquote(a.path).lower()
except (AssertionError,ValueError):
    print('Azure blocked: response URL escaped selected scope',file=sys.stderr);sys.exit(1)
PY
}

# Only GET or the two documented read-only query POSTs. Raw bodies remain in
# shell memory; neither curl config nor redirects can change the destination.
azure_http() {
  _method=$1; _url=$2; _body=${3:-}; _attempt=1
  case "$_method:$_url" in
    GET:*) azure_url "$_url" || return 1 ;;
    POST:"$ARM/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"|POST:"$ARM/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01") ;;
    *) echo "Azure blocked: unsupported read recipe" >&2; return 1 ;;
  esac
  _version=$(curl --version | head -1 | awk '{print $2}')
  printf '%s' "$_version" | awk -F. '{exit !(($1>8)||($1==8&&$2>=4))}' || { echo "Azure blocked: curl 8.4+ required for bounded responses" >&2; return 1; }
  azure_token || return 1
  while [ "$_attempt" -le 5 ]; do
    if [ "$_method" = GET ]; then
      _wire=$(curl -q -sS --proto '=https' --max-time 30 --max-filesize 2097152 -w '\n%{http_code}\t%header{retry-after}' -H "Authorization: Bearer ${ARM_TOKEN}" "$_url" 2>/dev/null) \
        || { echo "Azure blocked: incomplete HTTP read" >&2; return 1; }
    else
      _wire=$(curl -q -sS --proto '=https' --max-time 30 --max-filesize 2097152 -w '\n%{http_code}\t%header{retry-after}' -X POST -H "Authorization: Bearer ${ARM_TOKEN}" -H 'Content-Type: application/json' -d "$_body" "$_url" 2>/dev/null) \
        || { echo "Azure blocked: incomplete query read" >&2; return 1; }
    fi
    _status=$(printf '%s' "$_wire" | tail -n1 | cut -f1)
    _retry=$(printf '%s' "$_wire" | tail -n1 | cut -f2)
    _payload=$(printf '%s' "$_wire" | sed '$d')
    case "$_status" in
      200) printf '%s' "$_payload" | jq -se 'length==1 and (.[0] | type=="object" and (has("error")|not))' >/dev/null 2>&1 \
          || { echo "Azure blocked: invalid HTTP JSON envelope" >&2; return 1; }
        printf '%s' "$_payload"; return 0 ;;
      429) [ "$_attempt" -lt 5 ] || break
        case "$_retry" in '') _retry=$((_attempt * _attempt * 2)); [ "$_retry" -le 30 ] || _retry=30;; *[!0-9]*) echo 'Azure blocked: retry later using the provider Retry-After header' >&2; return 1;; esac
        [ "$_retry" -le 30 ] || { echo "Azure blocked: throttled; retry after the provider delay" >&2; return 1; }
        sleep "$_retry"; _attempt=$((_attempt + 1)) ;;
      *) echo "Azure blocked: HTTP ${_status:-unknown}; no absence or cost inferred" >&2; return 1 ;;
    esac
  done
  echo "Azure blocked: HTTP 429 retry budget exhausted" >&2; return 1
}

# $2 is the check's explicit safe projection, applied before any file write.
arm_list() (
  _first="$ARM$1"; _next="$_first"; _seen='[]'; _items='[]'; _page=0
  while [ -n "$_next" ]; do
    azure_url "$_first" "$_next" || exit 1
    printf '%s' "$_seen" | jq -e --arg u "$_next" 'index($u)==null' >/dev/null || { echo "Azure blocked: repeated page" >&2; exit 1; }
    _page=$((_page+1)); [ "$_page" -le 20 ] || { echo "Azure blocked: page limit; collection incomplete" >&2; exit 1; }
    _seen=$(printf '%s' "$_seen" | jq -c --arg u "$_next" '.+[$u]')
    _resp=$(azure_http GET "$_next") || exit 1
    printf '%s' "$_resp" | azure_project -e '.value|type=="array"' >/dev/null 2>&1 || { echo "Azure blocked: list envelope missing value array" >&2; exit 1; }
    _safe=$(printf '%s' "$_resp" | azure_project -ce "$2") || { echo "Azure blocked: projection failed" >&2; exit 1; }
    printf '%s' "$_safe" | jq -e 'type=="array"' >/dev/null || exit 1
    _items=$(printf '%s\n%s' "$_items" "$_safe" | jq -sc '.[0]+.[1]')
    [ "${#_items}" -le 8388608 ] || { echo "Azure blocked: projected collection limit" >&2; exit 1; }
    _next=$(printf '%s' "$_resp" | azure_project -er 'if .nextLink==null then "" elif (.nextLink|type)=="string" then .nextLink else error("nextLink") end') || { echo "Azure blocked: malformed continuation" >&2; exit 1; }
  done
  printf '%s' "$_items"
)

azure_save() {
  _name=$1; _data=$2
  mkdir -p "$RAW_DIR"; chmod 700 "$RAW_DIR"
  _tmp=$(mktemp "$RAW_DIR/.safe.XXXXXX") || return 1
  printf '%s\n' "$_data" > "$_tmp"; chmod 600 "$_tmp"; mv "$_tmp" "$RAW_DIR/$_name.json"
}

azure_inventory() {
  _collection=$1; _path=$2; _projection=$3
  if _collected=$(arm_list "$_path" "$_projection"); then
    azure_save "$_collection" "$_collected"
  else
    echo "Azure blocked: $_collection collection incomplete" >&2
    return 1
  fi
}

azure_require() {
  [ ! -e "$RAW_DIR/.inventory-pending" ] || { echo "Azure blocked: inventory collection did not finish" >&2; return 1; }
  for _name in "$@"; do
    jq -e 'type=="array"' "$RAW_DIR/$_name.json" >/dev/null 2>&1 \
      || { echo "Azure blocked: current $_name inventory unavailable" >&2; return 1; }
  done
}

azure_booleans() {
  azure_require "$@" || return 1
  for _name in "$@"; do
    jq -e 'all(.[]; (.enabled|type)=="boolean")' "$RAW_DIR/$_name.json" >/dev/null 2>&1 \
      || { echo "Azure blocked: $_name has an unknown enabled state" >&2; return 1; }
  done
}

# Resource Graph returns only the safe fields selected by each catalog query.
# Continuation is consumed, or incomplete evidence blocks the whole conclusion.
rg_query() (
  _query=$1; _skip=''; _seen='[]'; _rows='[]'; _page=0; _expected=''
  while :; do
    _page=$((_page+1)); [ "$_page" -le 20 ] || { echo "Azure blocked: Resource Graph page limit" >&2; exit 1; }
    _body=$(jq -n --arg s "$SUB" --arg q "$_query" --arg token "$_skip" '{subscriptions:[$s],query:$q,options:({resultFormat:"objectArray"} + if $token=="" then {} else {"$skipToken":$token} end)}')
    _resp=$(azure_http POST "$ARM/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01" "$_body") || exit 1
    printf '%s' "$_resp" | azure_project -e '(.data|type)=="array" and (.count|type)=="number" and .count==(.data|length) and (.totalRecords|type)=="number"' >/dev/null 2>&1 \
      || { echo "Azure blocked: invalid Resource Graph result" >&2; exit 1; }
    _total=$(printf '%s' "$_resp"|azure_project -r .totalRecords)
    [ -z "$_expected" ] || [ "$_expected" = "$_total" ] || { echo "Azure blocked: Resource Graph inventory changed while paging" >&2; exit 1; }
    _expected=$_total
    _rows=$(printf '%s\n%s' "$_rows" "$_resp" | azure_project -sc '.[0]+.[1].data')
    [ "${#_rows}" -le 8388608 ] || { echo "Azure blocked: Resource Graph result bound" >&2; exit 1; }
    _skip=$(printf '%s' "$_resp" | azure_project -er 'if ."$skipToken"==null then "" elif (."$skipToken"|type)=="string" then ."$skipToken" else error("skipToken") end') || exit 1
    if [ -z "$_skip" ]; then
      _total=$(printf '%s' "$_resp" | azure_project -r .totalRecords)
      printf '%s' "$_rows" | jq -e --argjson total "$_total" 'length==$total' >/dev/null || { echo "Azure blocked: Resource Graph result incomplete" >&2; exit 1; }
      printf '%s' "$_resp" | azure_project -e '.resultTruncated != true and .resultTruncated != "true" and .resultTruncated != "True"' >/dev/null || { echo "Azure blocked: Resource Graph truncated" >&2; exit 1; }
      printf '%s' "$_rows" | jq '{count:length,rows:.,complete:true}'; exit 0
    fi
    printf '%s' "$_seen" | jq -e --arg t "$_skip" 'index($t)==null' >/dev/null || { echo "Azure blocked: repeated Resource Graph token" >&2; exit 1; }
    _seen=$(printf '%s' "$_seen" | jq -c --arg t "$_skip" '.+[$t]')
  done
)

# The diagnostic CLI uses an array; reject errors/unknown wrappers before projecting.
azure_diagnostics() {
  azure_url "$ARM$1" || return 1
  _diagnostics=$(azure_cli monitor diagnostic-settings list --resource "$1") || return 1
  _diagnostics=$(printf '%s' "$_diagnostics" | azure_project -ce '
    if type=="array" then . elif type=="object" and (.value|type)=="array" then .value else error("diagnostic list") end') \
    || { echo "Azure blocked: diagnostic-settings result is not a known list envelope" >&2; return 1; }
  printf '%s' "$_diagnostics" | azure_project '[.[]|{name,workspaceId:(.workspaceId//.properties.workspaceId),
    logs:[(.logs//.properties.logs//[])[]|{category,categoryGroup,enabled}],
    metrics:[(.metrics//.properties.metrics//[])[]|{category,enabled}]}]'
}

azure_resource_rows() {
  azure_require "$@" || return 1
  for _kind in "$@"; do
    if [ -n "${AZ_RUN_ID:-}" ]; then
      [ -n "${SCOUTFLO_AZURE_WORKER:-}" ] || { echo "Azure blocked: set the batch worker token" >&2; return 1; }
      jq -c --arg kind "$_kind" --arg owner "$SCOUTFLO_AZURE_WORKER" \
        '.items[]|select(.kind==$kind and .state=="claimed" and .owner==$owner)' "$AZ_RUN_DIR/worklist.json"
    else jq -c '.[]' "$RAW_DIR/$_kind.json"; fi
  done
}

azure_resource_done() {
  [ -n "${AZ_RUN_ID:-}" ] || return 0
  _receipt=$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)
  # Persist safe success or explicit failed-read evidence, never invented empty data.
  printf '%s' "$2" | jq -e --arg id "$1" '.resource_id==$id and (.result=="examined" or .result=="blocked") and (.read_status|type)=="object"' >/dev/null || return 1
  azure_save "receipt-$_receipt" "$2"
  sh "$CLAUDE_PLUGIN_ROOT/skills/audit-azure/scripts/worklist.sh" done "$1" "$RAW_DIR/receipt-$_receipt.json"
}

# Only earlier completed audit dates are comparable; setup folders and future
# runs must not become the baseline of an older resumed run.
azure_previous_findings() {
  python3 - "$TARGET_DIR" "$RUN_DATE" <<'PY'
import datetime,pathlib,re,sys
root=pathlib.Path(sys.argv[1]); current=datetime.date.fromisoformat(sys.argv[2]); candidates=[]
if root.is_dir():
    for folder in root.iterdir():
        if not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}',folder.name) or not folder.is_dir(): continue
        try: day=datetime.date.fromisoformat(folder.name)
        except ValueError: continue
        findings=folder/'findings.json'
        if day<current and findings.is_file(): candidates.append((day,findings))
if candidates: print(max(candidates)[1])
PY
}
