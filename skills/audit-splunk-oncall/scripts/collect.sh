#!/bin/sh
# One-shot, read-only evidence recipe. No raw response or credential is written.
set -eu
set +x
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TT="$ROOT/report-standard/toolkit-targets.sh"
MODE=collect; ONLY_TEAM=""; SOURCE_ENV=""
DAYS_FORWARD="${SCOUTFLO_ONCALL_DAYS_FORWARD:-14}"
DAYS_SKIP="${SCOUTFLO_ONCALL_DAYS_SKIP:-0}"
QUALITY_MAX_USERS="${SCOUTFLO_ONCALL_QUALITY_MAX_USERS:-100}"
QUALITY_MAX_CALLS="${SCOUTFLO_ONCALL_QUALITY_MAX_CALLS:-500}"
for number in "$DAYS_FORWARD" "$DAYS_SKIP" "$QUALITY_MAX_USERS" "$QUALITY_MAX_CALLS"; do
  case "$number" in ''|*[!0-9]*|?????*) echo 'On-Call collection bounds must be small integers' >&2; exit 2;; esac
done
[ "$DAYS_FORWARD" -ge 1 ] && [ "$DAYS_FORWARD" -le 123 ] && [ "$DAYS_SKIP" -le 90 ] && [ "$QUALITY_MAX_USERS" -ge 1 ] && [ "$QUALITY_MAX_USERS" -le 1000 ] && [ "$QUALITY_MAX_CALLS" -ge 1 ] && [ "$QUALITY_MAX_CALLS" -le 2000 ] || { echo 'On-Call collection bounds outside documented/request limits' >&2; exit 2; }
TRIAGE="${SCOUTFLO_TRIAGE:-0}"
case "$TRIAGE" in 0|1) ;; *) echo "SCOUTFLO_TRIAGE must be 0 or 1" >&2; exit 2 ;; esac
case "${1:-}" in
  --plan) [ "$#" -eq 1 ] || { echo 'Use exactly one collector mode' >&2; exit 2; }; MODE=plan ;;
  --team) [ "$#" -eq 2 ] || { echo 'Use --team with exactly one team slug' >&2; exit 2; }; ONLY_TEAM="$2" ;;
  --source-route-env) [ "$#" -eq 2 ] && [ -n "$2" ] || { echo 'Use --source-route-env with exactly one variable name' >&2; exit 2; }; SOURCE_ENV="$2" ;;
  '') [ "$#" -eq 0 ] || { echo 'Empty collector argument' >&2; exit 2; } ;;
  *) echo 'usage: collect.sh [--plan | --team TEAM_SLUG | --source-route-env VARIABLE_NAME]' >&2; exit 2 ;;
esac
fail() { echo "splunk-oncall: $1" >&2; exit 1; }
if [ "$TRIAGE" = 1 ] && { [ -n "$ONLY_TEAM" ] || [ -n "$SOURCE_ENV" ]; }; then
  fail 'triage supports only the bulk routing census; scoped deep verification requires SCOUTFLO_TRIAGE=0'
fi
slug_ok() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac; }
[ "${1:-}" != --team ] || slug_ok "$ONLY_TEAM" || fail 'invalid selected team slug'
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for c in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$c" ] && { CFG="$c"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || fail 'config missing; run /scoutflo:connect'
for bin in curl jq python3; do command -v "$bin" >/dev/null || fail "missing binary: $bin"; done
CURL_VERSION=$(curl --version | awk 'NR==1 {print $2}')
printf '%s\n' "$CURL_VERSION" | awk -F. '$1>8 || ($1==8 && $2>=4) {ok=1} END {exit !ok}' \
  || fail 'curl 8.4 or newer is required for unknown-length response bounds'
KIND=$(sh "$TT" "$CFG" splunk_oncall kind); N=$(sh "$TT" "$CFG" splunk_oncall count)
[ "${N:-0}" -gt 0 ] || fail 'no splunk_oncall target configured'
IDX=0
if [ "$KIND" = seq ]; then
  LABELS=$(sh "$TT" "$CFG" splunk_oncall labels)
  li=0
  while [ "$li" -lt "$N" ]; do
    slug_ok "$(sh "$TT" "$CFG" splunk_oncall get "$li" label)" || fail 'list targets require explicit safe labels'
    li=$((li+1))
  done
  [ "$(printf '%s\n' "$LABELS" | sort -u | wc -l | tr -d ' ')" -eq "$N" ] || fail 'duplicate target labels are ambiguous'
  [ -n "${SCOUTFLO_TARGET:-}" ] || fail 'select a configured label with SCOUTFLO_TARGET'
  IDX=-1; i=0
  while [ "$i" -lt "$N" ]; do
    [ "$(sh "$TT" "$CFG" splunk_oncall label "$i")" != "$SCOUTFLO_TARGET" ] || IDX=$i
    i=$((i+1))
  done
  [ "$IDX" -ge 0 ] || fail 'SCOUTFLO_TARGET matches no configured label'
fi
LABEL=$(sh "$TT" "$CFG" splunk_oncall label "$IDX")
slug_ok "$LABEL" || fail 'target label must contain only letters, digits, underscore or hyphen'
SOC_SEG=splunk_oncall; [ "$KIND" != seq ] || SOC_SEG="splunk_oncall/$LABEL"
TEAM=$(sh "$TT" "$CFG" splunk_oncall get "$IDX" team_slug)
slug_ok "$TEAM" || fail 'team_slug is missing or invalid'
ID_ENV=$(sh "$TT" "$CFG" splunk_oncall get "$IDX" api_id_env)
KEY_ENV=$(sh "$TT" "$CFG" splunk_oncall get "$IDX" api_key_env)
for var in "$ID_ENV" "$KEY_ENV"; do
  case "$var" in ''|[0-9]*|*[!A-Za-z0-9_]*) fail 'invalid credential variable name' ;; esac
done
# Selected names only leave this child shell. Never import the store into this process.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f './.scoutflo/env' ]; then SCOUTFLO_ENV='./.scoutflo/env'; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
read_secret() { sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1; fi; printenv "$2"' _ "$SCOUTFLO_ENV" "$1" 2>/dev/null || true; }
API_ID=$(read_secret "$ID_ENV"); API_KEY=$(read_secret "$KEY_ENV")
[ -n "$API_ID" ] && [ -n "$API_KEY" ] || fail 'required read-only credential is not set; run /scoutflo:connect'
SOURCE_KEY=''
if [ -n "$SOURCE_ENV" ]; then
  case "$SOURCE_ENV" in [0-9]*|*[!A-Za-z0-9_]*) fail 'invalid source credential variable name' ;; esac
  SOURCE_KEY=$(read_secret "$SOURCE_ENV")
  [ -n "$SOURCE_KEY" ] || fail 'source routing-key variable is unset'
fi
# Header injection is never a valid credential. No value appears in diagnostics.
CR=$(printf '\r')
case "$API_ID$API_KEY" in *'
'*|*"$CR"*) fail 'invalid credential encoding' ;; esac
CREDENTIAL_FINGERPRINT=$(printf '%s\n%s' "$API_ID" "$API_KEY" | python3 -c 'import hashlib,hmac,sys; p=sys.stdin.buffer.read().split(b"\n",1); print(hmac.new(p[1],p[0],hashlib.sha256).hexdigest())')
CREDENTIAL_BINDING=$(jq -nc --arg id_env "$ID_ENV" --arg key_env "$KEY_ENV" --arg fingerprint "$CREDENTIAL_FINGERPRINT" '{api_id_env:$id_env,api_key_env:$key_env,fingerprint:$fingerprint}')
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
private_fingerprint() {
  # Input is the read key on the first line and one already validated JSON body.
  # Keep opaque keyed equality evidence while discarding all sensitive values.
  python3 -c 'import hashlib,hmac,json,sys
key,raw=sys.stdin.buffer.read().split(b"\n",1)
def stable(v):
 if isinstance(v,dict):return {k:stable(x) for k,x in v.items() if not k.startswith("_") and k not in ("lastUpdated","lastUpdatedBy")}
 if isinstance(v,list):return [stable(x) for x in v]
 return v
body=json.dumps(stable(json.loads(raw)),sort_keys=True,separators=(",",":"),allow_nan=False).encode()
print(hmac.new(key,body,hashlib.sha256).hexdigest())' 2>/dev/null
}
get() {
  # Paths are assembled only from constants and validated IDs, never provider links.
  sleep 1
  WIRE=$(curl -q -sS --proto '=https' --max-time 25 --max-redirs 0 --max-filesize 2097152 \
    -H "X-VO-Api-Id: $API_ID" -H "X-VO-Api-Key: $API_KEY" \
    -H 'Accept: application/json' -H 'Accept-Encoding: identity' \
    -w '\n%{http_code}' "https://api.victorops.com$1" 2>/dev/null) \
    || { CURL_RC=$?; fail "read incomplete (curl exit $CURL_RC, path $1); no snapshot emitted"; }
  STATUS=${WIRE##*'
'}; BODY=${WIRE%'
'*}
  [ "$STATUS" = 200 ] || fail "read refused (HTTP $STATUS); no snapshot emitted"
  case "$1" in
    /api-public/v1/team/"$TEAM"|/api-public/v1/policies/*)
      # Validate identity before normal parsing can collapse duplicate keys.
      printf '%s' "$BODY" | jq --stream -ne '[inputs | select(length==2 and .[0][0]=="slug")] | length==1 and .[0][0]==["slug"] and (.[0][1]|type)=="string"' >/dev/null 2>&1 \
        || fail 'ambiguous or missing response identity'
      ;;
  esac
  # Reject duplicate JSON keys before projections could hide conflicting state.
  printf '%s' "$BODY" | python3 -c 'import json,sys
def obj(pairs):
 d={}
 for k,v in pairs:
  if k in d: raise ValueError("duplicate")
  d[k]=v
 return d
json.load(sys.stdin,object_pairs_hook=obj,parse_constant=lambda _:(_ for _ in ()).throw(ValueError("number")))' 2>/dev/null \
    || fail 'ambiguous or malformed JSON response; no snapshot emitted'
  printf '%s' "$BODY" | jq -ce -s 'if length==1 then .[0] else error("document count") end' 2>/dev/null \
    || fail 'expected one complete JSON response; no snapshot emitted'
}
# Fresh identity preflight before every mode and every scoped batch.
ANCHOR=$(get "/api-public/v1/team/$TEAM")
printf '%s' "$ANCHOR" | jq -e --arg team "$TEAM" 'type=="object" and (.slug|type)=="string" and .slug==$team' >/dev/null 2>&1 \
  || fail 'configured team identity did not match; stop'
TEAMS=$(get '/api-public/v1/team')
TEAMS=$(printf '%s' "$TEAMS" | jq -ce 'if type=="array" and all(.[]; (.slug|type)=="string" and (.slug|test("^[A-Za-z0-9_-]+$"))) and ([.[].slug]|length== (unique|length)) then map({slug}) else error("teams shape") end' 2>/dev/null) || fail 'team inventory shape is unverified'
POLICIES=$(get '/api-public/v1/policies')
POLICIES=$(printf '%s' "$POLICIES" | jq -ce 'if (.policies|type)=="array" and all(.policies[]; (.policy.slug|type)=="string" and (.team.slug|type)=="string" and (.policy.slug|test("^[A-Za-z0-9_-]+$"))) then [.policies[]|{slug:.policy.slug,team:.team.slug}] else error("policies shape") end' 2>/dev/null) || fail 'global policy inventory shape is unverified'
ROUTES=$(get '/api-public/v1/org/routing-keys')
ROUTING_FINGERPRINT=$( { printf '%s\n' "$API_KEY"; printf '%s' "$ROUTES"; } | private_fingerprint) || fail 'routing definition binding failed'
# Raw key-to-alias map lives only in this process for private maintenance/rule joins.
ROUTE_KEY_MAP=$(printf '%s' "$ROUTES" | jq -ce 'if (.routingKeys|type)=="array" then [.routingKeys|to_entries[]|{key:.value.routingKey,alias:("route-"+((.key+1)|tostring))}] else error("route map") end' 2>/dev/null) || fail 'routing inventory shape is unverified'
SOURCE_MATCH=null
if [ -n "$SOURCE_ENV" ]; then
  # The source key is joined in memory, never used as an artifact ID or emitted.
  SOURCE_MATCH=$( { printf '%s\n' "$ROUTES"; printf '%s' "$SOURCE_KEY" | jq -Rs .; } | jq -sce '
    .[1] as $key | if (.[0].routingKeys|type)=="array" then
      [.[0].routingKeys|to_entries[]|select(.value.routingKey==$key)] as $matches |
      {route_aliases:[$matches[]|"route-"+((.key+1)|tostring)],policies:[$matches[].value.targets[].policySlug]|unique}
    else error("route shape") end' 2>/dev/null) || fail 'source routing comparison is unverified'
fi
# Keys and _selfUrl never leave memory. Aliases are run-local, NOT cross-run identity.
ROUTES=$(printf '%s' "$ROUTES" | jq -ce 'if (.routingKeys|type)=="array" and all(.routingKeys[]; (.routingKey|type)=="string" and (.targets|type)=="array" and all(.targets[];(.policySlug|type)=="string")) then [.routingKeys|to_entries[]|{alias:("route-"+((.key+1)|tostring)),is_default:(if (.value.isDefault|type)=="boolean" then .value.isDefault else null end),multi_responder:(if (.value.isMultiResponder|type)=="boolean" then .value.isMultiResponder else null end),policies:[.value.targets[].policySlug]}] else error("route shape") end' 2>/dev/null) || fail 'routing inventory shape is unverified'
ALL_POLICIES=$POLICIES
if [ -n "$ONLY_TEAM" ]; then
  printf '%s' "$TEAMS" | jq -e --arg team "$ONLY_TEAM" 'any(.[];.slug==$team)' >/dev/null || fail 'selected team absent from complete inventory'
  TEAMS=$(printf '%s' "$TEAMS" | jq -c --arg team "$ONLY_TEAM" 'map(select(.slug==$team))')
  POLICIES=$(printf '%s' "$POLICIES" | jq -c --arg team "$ONLY_TEAM" 'map(select(.team==$team))')
  ROUTES=$(printf '%s\n' "$ROUTES" "$POLICIES" | jq -sc '(.[1]|map(.slug)) as $selected | [.[0][] | select(any(.policies[]; . as $p | $selected|index($p))) | . + {out_of_scope_policies:[.policies[]|. as $p|select(($selected|index($p))==null)]}]')
fi
if [ "$MODE" = plan ]; then
  printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" | jq -sc --arg target "$SOC_SEG" --arg anchor "$TEAM" --arg id_env "$ID_ENV" --arg key_env "$KEY_ENV" --argjson triage "$TRIAGE" --arg routing_fingerprint "$ROUTING_FINGERPRINT" --argjson credential_binding "$CREDENTIAL_BINDING" '{routing_definition_fingerprint:$routing_fingerprint,credential_binding:$credential_binding,scope:(if $triage==1 then "triage" else "account" end),target:$target,anchor_team:$anchor,credential_refs:{api_id_env:$id_env,api_key_env:$key_env},teams:(.[0]|length),policies:(.[1]|length),routes:(.[2]|length),objects:([.[]|length]|add),team_slugs:[.[0][].slug]}'
  exit 0
fi
# Triage deliberately stops at the bulk routing/ownership census. Empty detail
# arrays below are omitted reads, not evidence of empty staffing or coverage.
if [ "$TRIAGE" = 1 ]; then
  ANCHOR=$(get "/api-public/v1/team/$TEAM")
  printf '%s' "$ANCHOR" | jq -e --arg team "$TEAM" '.slug==$team' >/dev/null 2>&1 || fail 'identity changed during triage'
  printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" | jq -sc \
    --arg target "$SOC_SEG" --arg started "$STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg routing_fingerprint "$ROUTING_FINGERPRINT" --argjson credential_binding "$CREDENTIAL_BINDING" \
    '{routing_definition_fingerprint:$routing_fingerprint,credential_binding:$credential_binding,target:$target,started_at:$started,finished_at:$finished,scope:"triage",complete_reads:true,atomic_snapshot:false,
      assessed_check_ids:["SOC-001","SOC-002"],deferred_check_ids:["SOC-003","SOC-004","SOC-005","SOC-006","SOC-007","SOC-009","SOC-010","SOC-011","SOC-012","SOC-013","SOC-014","SOC-015","SOC-016","SOC-017","SOC-018","SOC-019"],
      source_match:null,teams:.[0],policies:.[1],routes:.[2],current:[],policy_details:[],team_details:[]}'
  exit 0
fi
CURRENT=$(get '/api-public/v1/oncall/current')
CURRENT=$(printf '%s' "$CURRENT" | jq -ce 'if (.teamsOnCall|type)=="array" and all(.teamsOnCall[]; (.team.slug|type)=="string" and (.oncallNow|type)=="array" and all(.oncallNow[];(.escalationPolicy.slug|type)=="string" and (.users|type)=="array" and all(.users[];(.onCalluser.username|type)=="string"))) then [.teamsOnCall[]|.team.slug as $team|.oncallNow[]|{team:$team,policy:.escalationPolicy.slug,users:[.users[].onCalluser.username]|unique}] else error("current shape") end' 2>/dev/null) || fail 'current on-call shape is unverified (oncallNow/onCalluser)'
if [ -n "$ONLY_TEAM" ]; then CURRENT=$(printf '%s' "$CURRENT" | jq -c --arg team "$ONLY_TEAM" 'map(select(.team==$team))'); fi
DETAILS='[]'
for policy in $(printf '%s' "$POLICIES" | jq -r '.[].slug'); do
  P=$(get "/api-public/v1/policies/$policy")
  P_FINGERPRINT=$( { printf '%s\n' "$API_KEY"; printf '%s' "$P"; } | private_fingerprint) || fail 'policy definition binding failed'
  P=$(printf '%s' "$P" | jq -ce --arg p "$policy" --argjson owners "$ALL_POLICIES" 'if .slug==$p and (.steps|type)=="array" and all(.steps[]; (.timeout|type)=="number" and .timeout>=0 and .timeout==(.timeout|floor) and (.entries|type)=="array" and all(.entries[];(.executionType|type)=="string" and (if .executionType=="user" then (.user.username|type)=="string" and (.user.username|test("^[A-Za-z0-9_-]+$")) elif (.executionType|IN("rotation_group","rotation_group_next","rotation_group_previous")) then (.rotationGroup.slug|type)=="string" and (.rotationGroup.slug|test("^[A-Za-z0-9_-]+$")) elif .executionType=="policy_routing" then (.targetPolicy.policySlug|type)=="string" and (.targetPolicy.policySlug|test("^[A-Za-z0-9_-]+$")) and (if (.targetPolicy|has("teamSlug")) then (.targetPolicy.teamSlug|type)=="string" and (.targetPolicy.teamSlug|test("^[A-Za-z0-9_-]+$")) and (.targetPolicy as $target | [$owners[]|select(.slug==$target.policySlug)] | length==1 and .[0].team==$target.teamSlug) else true end) else true end))) then {slug,ignore_custom_paging:(if (.ignoreCustomPagingPolicies|type)=="boolean" then .ignoreCustomPagingPolicies else null end),steps:[.steps[]|{timeout,entries:[.entries[]|{type:(if (.executionType|IN("user","rotation_group","rotation_group_next","rotation_group_previous","policy_routing","email","webhook")) then .executionType else "unsupported" end),user:(if .executionType=="user" then .user.username else null end),rotation:(if (.executionType as $kind | ["rotation_group","rotation_group_next","rotation_group_previous"]|index($kind))!=null then .rotationGroup.slug else null end),policy:(if .executionType=="policy_routing" then .targetPolicy.policySlug else null end),policy_team:(if .executionType=="policy_routing" and (.targetPolicy|has("teamSlug")) then .targetPolicy.teamSlug else null end),destination_present:(if .executionType=="email" then (.email.address|type=="string" and length>0) elif .executionType=="webhook" then (.webhook.slug|type=="string" and length>0) else null end)}]}]} else error("policy shape") end' 2>/dev/null) || fail 'policy detail identity or shape is unverified'
  P=$(printf '%s' "$P" | jq -c --arg fingerprint "$P_FINGERPRINT" '.+{definition_fingerprint:$fingerprint}')
  DETAILS=$(printf '%s\n' "$DETAILS" "$P" | jq -sc '.[0]+[.[1]]')
done
TEAM_DATA='[]'
for team in $(printf '%s' "$TEAMS" | jq -r '.[].slug'); do
  M=$(get "/api-public/v1/team/$team/members")
  M=$(printf '%s' "$M" | jq -ce 'if (.members|type)=="array" and all(.members[];(.username|type)=="string" and (.verified|type)=="boolean") then [.members[]|{username,verified}] else error("members shape") end' 2>/dev/null) || fail 'team member shape is unverified'
  G=$(get "/api-public/v1/teams/$team/rotations")
  G=$(printf '%s' "$G" | jq -ce --arg team "$team" 'if (.rotationGroups|type)=="array" and all(.rotationGroups[];(.slug|type)=="string" and .teamSlug==$team and (.groupId|type)=="number" and .groupId>=0 and .groupId==(.groupId|floor)) then [.rotationGroups[]|{slug,groupId,teamSlug}] else error("groups shape") end' 2>/dev/null) || fail 'rotation group shape is unverified'
  R=$(get "/api-public/v2/team/$team/rotations")
  R=$(printf '%s' "$R" | jq -ce 'if (.rotations|type)=="array" and all(.rotations[]; (.groupId|type)=="number" and .groupId>=0 and .groupId==(.groupId|floor) and (.shifts|type)=="array" and all(.shifts[];(.shiftId|type)=="number" and .shiftId>=0 and .shiftId==(.shiftId|floor) and (.shifttype|type)=="string" and (.timezone|type)=="string" and (.current==null or ((.current|type)=="object" and (.current.username==null or (.current.username|type)=="string"))) and (.shiftMembers|type)=="array" and all(.shiftMembers[];(.username|type)=="string"))) then [.rotations[]|{groupId,shifts:[.shifts[]|{shiftId,shifttype,timezone,members:[.shiftMembers[].username],current_user:(if (.current.username|type)=="string" then .current.username else null end),next_user:(if (.next.username|type)=="string" then .next.username else null end),periods:(if (.periods|type)=="array" then [.periods[]|{start:(if ((.start|type)=="string" and (.start|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.start|type)=="number" then .start else null end),end:(if ((.end|type)=="string" and (.end|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.end|type)=="number" then .end else null end),username:(if (.username|type)=="string" then .username else null end)}] else null end),current_period:(if (.current|type)=="object" then (.current|{start:(if ((.start|type)=="string" and (.start|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.start|type)=="number" then .start else null end),end:(if ((.end|type)=="string" and (.end|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.end|type)=="number" then .end else null end),username:(if (.username|type)=="string" then .username else null end)}) else null end),next_period:(if (.next|type)=="object" then (.next|{start:(if ((.start|type)=="string" and (.start|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.start|type)=="number" then .start else null end),end:(if ((.end|type)=="string" and (.end|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$"))) or (.end|type)=="number" then .end else null end),username:(if (.username|type)=="string" then .username else null end)}) else null end)}]}] else error("rotations shape") end' 2>/dev/null) || fail 'rotation roster shape is unverified'
  D=$(printf '%s\n' "$M" "$G" "$R" | jq -sc --arg team "$team" '{team:$team,members:.[0],groups:.[1],rotations:.[2]}')
  TEAM_DATA=$(printf '%s\n' "$TEAM_DATA" "$D" | jq -sc '.[0]+[.[1]]')
done
# Optional quality reads never erase valid core evidence. Each is bounded and
# projected immediately; raw keys, contacts, predicates and annotations stay here.
QUALITY_CALLS=0
quality_get() {
  if [ "$QUALITY_CALLS" -ge "$QUALITY_MAX_CALLS" ]; then Q_STATUS=budget-exhausted; Q_BODY='null'; return; fi
  QUALITY_CALLS=$((QUALITY_CALLS+1))
  Q_FINGERPRINT=''
  if Q_BODY=$(get "$1" 2>/dev/null); then
    if Q_FINGERPRINT=$( { printf '%s\n' "$API_KEY"; printf '%s' "$Q_BODY"; } | private_fingerprint); then Q_STATUS=collected; else Q_STATUS=read-blocked; Q_BODY='null'; fi
  else Q_STATUS=read-blocked; Q_BODY='null'; fi
}
project_quality() {
  if [ "$Q_STATUS" = collected ]; then
    if Q_VALUE=$(printf '%s' "$Q_BODY" | jq -ce "$1" 2>/dev/null); then
      Q_RESULT=$(printf '%s' "$Q_VALUE" | jq -c --arg fingerprint "$Q_FINGERPRINT" '{status:"collected",definition_fingerprint:$fingerprint,data:.}')
    else Q_RESULT='{"status":"schema-blocked","data":null}'; fi
  else Q_RESULT=$(jq -nc --arg status "$Q_STATUS" '{status:$status,data:null}'); fi
  Q_BODY='null'; Q_VALUE='null'
}
quality_get '/api-public/v1/maintenancemode'
if [ "$Q_STATUS" = collected ]; then
  # Targets are joined to this run's aliases before the raw state is discarded.
  if MAINTENANCE=$(printf '%s\n' "$Q_BODY" "$ROUTE_KEY_MAP" | jq -sce '
    .[0] as $m | .[1] as $keys |
    if ($m.activeInstances|type)=="array" and all($m.activeInstances[]; (.instanceId|type)=="string" and (.instanceId|test("^[A-Za-z0-9_-]+$")) and (.startedAt|type)=="number" and (.isGlobal|type)=="boolean" and (.targets|type)=="array" and all(.targets[]; .type=="RoutingKeys" and (.names|type)=="array" and all(.names[];type=="string"))) then
      {status:"collected",data:[$m.activeInstances[]|{id:.instanceId,started_at_ms:.startedAt,global:(.isGlobal or any(.targets[];(.names|length)==0)),route_aliases:([.targets[].names[]|. as $key|$keys[]|select(.key==$key)|.alias]|unique),unmatched_targets:([.targets[].names[]|. as $key|select(([$keys[]|select(.key==$key)]|length)!=1)]|length)}]}
    else error("maintenance shape") end' 2>/dev/null); then :; else MAINTENANCE='{"status":"schema-blocked","data":null}'; fi
else MAINTENANCE=$(jq -nc --arg status "$Q_STATUS" '{status:$status,data:null}'); fi
if [ "$Q_STATUS" = collected ]; then MAINTENANCE=$(printf '%s' "$MAINTENANCE" | jq -c --arg fingerprint "$Q_FINGERPRINT" '.+{definition_fingerprint:$fingerprint}'); fi
quality_get '/api-public/v1/alertRules'
if [ "$Q_STATUS" = collected ]; then
  if RULES=$(printf '%s\n' "$Q_BODY" "$ROUTE_KEY_MAP" | jq -sce '
    .[0] as $rules | .[1] as $keys |
    def field: if type=="string" and IN("entity_id","entity_display_name","message_type","routing_key","monitoring_tool","state_message","service","environment","runbook_url") then . else "other" end;
    if ($rules|type)=="array" and all($rules[];(.id|type)=="number" and (.id|floor)==.id and .id>=0 and (.rank|type)=="number" and (.rank|floor)==.rank and (.stopFlag|type)=="boolean" and (.annotations|type)=="array") then
      {status:"collected",data:[$rules[]|{id,rank,stop:.stopFlag,field:(.alertField|field),match_type:(if .matchType=="WILDCARD" or .matchType=="REGEX" then .matchType else "unsupported" end),wildcard_all:(.matchType=="WILDCARD" and .alertValueMatch=="*"),route_rewrite:(if .routeKey==null or .routeKey=="" then false elif (.routeKey|type)=="string" then true else null end),route_aliases:(.routeKey as $key|[$keys[]|select(.key==$key)|.alias]),annotation_fields:[.annotations[].fieldName|field],identity_mutation:any(.annotations[];.fieldName=="entity_id"),severity_mutation:any(.annotations[];.fieldName=="message_type")}]|sort_by(.rank)}
    else error("rules shape") end' 2>/dev/null); then :; else RULES='{"status":"schema-blocked","data":null}'; fi
else RULES=$(jq -nc --arg status "$Q_STATUS" '{status:$status,data:null}'); fi
if [ "$Q_STATUS" = collected ]; then RULES=$(printf '%s' "$RULES" | jq -c --arg fingerprint "$Q_FINGERPRINT" '.+{definition_fingerprint:$fingerprint}'); fi
Q_BODY='null'; ROUTE_KEY_MAP='null'
SELECTED_USERS=$(printf '%s\n' "$CURRENT" "$DETAILS" "$TEAM_DATA" | jq -sc '[.[0][].users[],.[1][].steps[].entries[]|select(type=="string" or .type=="user")|if type=="string" then . else .user end] + [.[2][].rotations[].shifts[].members[]] | unique')
USER_COUNT=$(printf '%s' "$SELECTED_USERS" | jq length)
USERS='[]'
for user in $(printf '%s' "$SELECTED_USERS" | jq -r --argjson cap "$QUALITY_MAX_USERS" '.[:$cap][]'); do
  if ! slug_ok "$user"; then
    U=$(jq -nc --arg user "$user" '{user:$user,primary:{status:"identity-blocked",data:null},personal:{status:"identity-blocked",data:null},contacts:{status:"identity-blocked",data:null}}')
  else
    quality_get "/api-public/v1/profile/$user/policies"
    POLICY_PROJECTION='def steps: if type=="array" and all(.[]; (.index|type)=="number" and (.timeout|type)=="number" and (.rules|type)=="array" and all(.rules[];(.index|type)=="number" and (.type|type)=="string")) then [.[]|{index,timeout,rules:[.rules[]|{index,channel:(if .type=="email" or .type=="phone" or .type=="sms" or .type=="push" then .type else "unsupported" end),contact_id:(if (.contact.id|type)=="number" then .contact.id else null end),contact_type:(if (.contact.type|type)=="string" and ((.contact.type|ascii_downcase)=="email" or (.contact.type|ascii_downcase)=="phone") then (.contact.type|ascii_downcase) else null end)}]}] else error("steps shape") end;'
    project_quality "$POLICY_PROJECTION .steps|steps"
    PRIMARY=$Q_RESULT
    quality_get "/api-public/v2/profile/$user/policies"
    project_quality "$POLICY_PROJECTION if (.policies|type)==\"array\" and all(.policies[];(.slug|type)==\"string\" and (.slug|test(\"^[A-Za-z0-9_-]+$\")) and (.rank|type)==\"number\") then [.policies[]|{slug,rank,terminal_action:(if .terminalAction==\"repeat_last_step\" then \"repeat_last_step\" else null end),time_mask:(if (.timeMask|type)==\"object\" then (.timeMask|{sunday:(if (.sunday|type)==\"boolean\" then .sunday else null end),monday:(if (.monday|type)==\"boolean\" then .monday else null end),tuesday:(if (.tuesday|type)==\"boolean\" then .tuesday else null end),wednesday:(if (.wednesday|type)==\"boolean\" then .wednesday else null end),thursday:(if (.thursday|type)==\"boolean\" then .thursday else null end),friday:(if (.friday|type)==\"boolean\" then .friday else null end),saturday:(if (.saturday|type)==\"boolean\" then .saturday else null end),timeZone:(if (.timeZone|type)==\"string\" and (.timeZone|test(\"^[A-Za-z0-9_+/-]+$\")) then .timeZone else null end),startTime:(if (.startTime|type)==\"string\" and (.startTime|test(\"^[0-9:.]+$\")) then .startTime else null end),endTime:(if (.endTime|type)==\"string\" and (.endTime|test(\"^[0-9:.]+$\")) then .endTime else null end)}) else null end),steps:(.steps|steps)}] else error(\"policies shape\") end"
    PERSONAL=$Q_RESULT
    quality_get "/api-public/v1/user/$user/contact-methods"
    project_quality 'def list: if type=="array" then . elif type=="object" and (.contactMethods|type)=="array" then .contactMethods else error("contact collection") end; def verified: if type=="boolean" then . elif .=="true" or .=="verified" then true elif .=="false" or .=="unverified" then false else null end; [.emails|list|.[]|{kind:"email",id:(if (.id|type)=="number" then .id else null end),verified:(.verified|verified)}] + [.phones|list|.[]|{kind:"phone",id:(if (.id|type)=="number" then .id else null end),verified:(.verified|verified)}] + [.devices|list|.[]|{kind:"push",id:null,verified:null}]'
    CONTACTS=$Q_RESULT
    U=$(printf '%s\n' "$PRIMARY" "$PERSONAL" "$CONTACTS" | jq -sc --arg user "$user" '{user:$user,primary:.[0],personal:.[1],contacts:.[2]}')
  fi
  USERS=$(printf '%s\n' "$USERS" "$U" | jq -sc '.[0]+[.[1]]')
done
SCHEDULES='[]'; ADMINS='[]'
for team in $(printf '%s' "$TEAMS" | jq -r '.[].slug'); do
  quality_get "/api-public/v1/team/$team/admins"
  project_quality 'if (.teamAdmins|type)=="array" and all(.teamAdmins[];(.username|type)=="string") then [.teamAdmins[].username]|unique else error("admins shape") end'
  A=$(printf '%s' "$Q_RESULT" | jq -c --arg team "$team" '.+{team:$team}')
  ADMINS=$(printf '%s\n' "$ADMINS" "$A" | jq -sc '.[0]+[.[1]]')
  STEPS=$(printf '%s\n' "$DETAILS" "$POLICIES" | jq -sc --arg team "$team" '(.[1]|map(select(.team==$team)|.slug)) as $ids | [.[0][]|select(.slug as $s|$ids|index($s))|.steps|length] | if length==0 then 1 else max end | if .>4 then 4 else . end')
  step=0
  while [ "$step" -lt "$STEPS" ]; do
    quality_get "/api-public/v2/team/$team/oncall/schedule?daysForward=$DAYS_FORWARD&daysSkip=$DAYS_SKIP&step=$step"
    project_quality 'def user: if type=="object" and (.username|type)=="string" then .username elif .==null then null else error("schedule user") end;
      def stamp: if type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$") then . else error("timestamp") end;
      if (.team.slug|type)=="string" and (.schedules|type)=="array" and all(.schedules[];(.policy.slug|type)=="string" and (.schedule|type)=="array" and (.overrides|type)=="array") then
      {team:.team.slug,policies:[.schedules[]|{policy:.policy.slug,entries:[.schedule[]|{type:(if (.onCallType|type)=="string" then .onCallType else "unsupported" end),user:(.onCallUser|user),override_user:(.overrideOnCallUser|user),rolls:(if (.rolls|type)=="array" then [.rolls[]|{start:(.start|stamp),end:(.end|stamp),user:(.onCallUser|user),is_roll:(if (.isRoll|type)=="boolean" then .isRoll else null end)}] else error("rolls") end)}],overrides:[.overrides[]|{original_user:(.origOnCallUser|user),user:(.overrideOnCallUser|user),start:(.start|stamp),end:(.end|stamp)}]}]}
      else error("schedule shape") end'
    S=$(printf '%s' "$Q_RESULT" | jq -c --arg team "$team" --argjson step "$step" --argjson days "$DAYS_FORWARD" --argjson skip "$DAYS_SKIP" 'if .status=="collected" and .data.team!=$team then {status:"identity-blocked",data:null} else . end | .+{team:$team,step:$step,days_forward:$days,days_skip:$skip}')
    SCHEDULES=$(printf '%s\n' "$SCHEDULES" "$S" | jq -sc '.[0]+[.[1]]')
    step=$((step+1))
  done
done
quality_get '/api-public/v1/overrides'
project_quality 'if (.overrides|type)=="array" then [.overrides[]|{id:(if (.publicId|type)=="string" and (.publicId|test("^[A-Za-z0-9_-]+$")) then .publicId else error("override identity") end),user:(if (.user.username|type)=="string" then .user.username else null end),start:(if (.start|type)=="string" and (.start|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$")) then .start else error("time") end),end:(if (.end|type)=="string" and (.end|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.,+Z-]+$")) then .end else error("time") end),assignments:(if (.assignments|type)=="array" then [.assignments[]|{team:(if (.team|type)=="string" then .team else null end),policy:(if (.policy|type)=="string" then .policy else null end),assigned:(if (.assigned|type)=="boolean" then .assigned else null end),user:(if (.user|type)=="string" then .user else null end)}] else null end)}] else error("overrides shape") end'
OVERRIDES=$Q_RESULT
QUALITY=$(printf '%s\n' "$USERS" "$MAINTENANCE" "$RULES" "$SCHEDULES" "$OVERRIDES" "$ADMINS" | jq -sc --argjson count "$USER_COUNT" --argjson cap "$QUALITY_MAX_USERS" --argjson calls "$QUALITY_CALLS" --argjson budget "$QUALITY_MAX_CALLS" '{schema:"scoutflo-oncall-quality/v1",selected_users:.[0],selected_user_count:$count,user_collection_complete:($count<=$cap),maintenance:.[1],transformations:.[2],schedules:.[3],overrides:.[4],team_admins:.[5],global_paging:{status:"attended-required",data:null},calls:$calls,call_budget:$budget}')

# Recheck identity at finish; this is sequential evidence, not an atomic snapshot.
ANCHOR=$(get "/api-public/v1/team/$TEAM")
printf '%s' "$ANCHOR" | jq -e --arg team "$TEAM" '.slug==$team' >/dev/null 2>&1 || fail 'identity changed during collection'
printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" "$CURRENT" "$DETAILS" "$TEAM_DATA" "$QUALITY" | jq -sc \
  --arg target "$SOC_SEG" --arg started "$STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg scope "$ONLY_TEAM" --argjson source_match "$SOURCE_MATCH" --arg routing_fingerprint "$ROUTING_FINGERPRINT" --argjson credential_binding "$CREDENTIAL_BINDING" \
  '{routing_definition_fingerprint:$routing_fingerprint,credential_binding:$credential_binding,target:$target,started_at:$started,finished_at:$finished,scope:(if $scope=="" then "account" else $scope end),complete_reads:true,atomic_snapshot:false,source_match:$source_match,teams:.[0],policies:.[1],routes:.[2],current:.[3],policy_details:.[4],team_details:.[5],quality:.[6]}'
