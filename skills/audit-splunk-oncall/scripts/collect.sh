#!/bin/sh
# One-shot, read-only evidence recipe. No raw response or credential is written.
set -eu
set +x
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
TT="$ROOT/report-standard/toolkit-targets.sh"
MODE=collect; ONLY_TEAM=""; SOURCE_ENV=""
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
for bin in curl jq; do command -v "$bin" >/dev/null || fail "missing binary: $bin"; done
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
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
if [ -n "$ONLY_TEAM" ]; then
  printf '%s' "$TEAMS" | jq -e --arg team "$ONLY_TEAM" 'any(.[];.slug==$team)' >/dev/null || fail 'selected team absent from complete inventory'
  TEAMS=$(printf '%s' "$TEAMS" | jq -c --arg team "$ONLY_TEAM" 'map(select(.slug==$team))')
  POLICIES=$(printf '%s' "$POLICIES" | jq -c --arg team "$ONLY_TEAM" 'map(select(.team==$team))')
  ROUTES=$(printf '%s\n' "$ROUTES" "$POLICIES" | jq -sc '(.[1]|map(.slug)) as $selected | [.[0][] | select(any(.policies[]; . as $p | $selected|index($p))) | . + {out_of_scope_policies:[.policies[]|. as $p|select(($selected|index($p))==null)]}]')
fi
if [ "$MODE" = plan ]; then
  printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" | jq -sc --arg target "$SOC_SEG" --arg anchor "$TEAM" --arg id_env "$ID_ENV" --arg key_env "$KEY_ENV" --argjson triage "$TRIAGE" '{scope:(if $triage==1 then "triage" else "account" end),target:$target,anchor_team:$anchor,credential_refs:{api_id_env:$id_env,api_key_env:$key_env},teams:(.[0]|length),policies:(.[1]|length),routes:(.[2]|length),objects:([.[]|length]|add),team_slugs:[.[0][].slug]}'
  exit 0
fi
# Triage deliberately stops at the bulk routing/ownership census. Empty detail
# arrays below are omitted reads, not evidence of empty staffing or coverage.
if [ "$TRIAGE" = 1 ]; then
  ANCHOR=$(get "/api-public/v1/team/$TEAM")
  printf '%s' "$ANCHOR" | jq -e --arg team "$TEAM" '.slug==$team' >/dev/null 2>&1 || fail 'identity changed during triage'
  printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" | jq -sc \
    --arg target "$SOC_SEG" --arg started "$STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{target:$target,started_at:$started,finished_at:$finished,scope:"triage",complete_reads:true,atomic_snapshot:false,
      assessed_check_ids:["SOC-001","SOC-002"],deferred_check_ids:["SOC-003","SOC-004","SOC-005","SOC-006","SOC-007"],
      source_match:null,teams:.[0],policies:.[1],routes:.[2],current:[],policy_details:[],team_details:[]}'
  exit 0
fi
CURRENT=$(get '/api-public/v1/oncall/current')
CURRENT=$(printf '%s' "$CURRENT" | jq -ce 'if (.teamsOnCall|type)=="array" and all(.teamsOnCall[]; (.team.slug|type)=="string" and (.oncallNow|type)=="array" and all(.oncallNow[];(.escalationPolicy.slug|type)=="string" and (.users|type)=="array" and all(.users[];(.onCalluser.username|type)=="string"))) then [.teamsOnCall[]|.team.slug as $team|.oncallNow[]|{team:$team,policy:.escalationPolicy.slug,users:[.users[].onCalluser.username]|unique}] else error("current shape") end' 2>/dev/null) || fail 'current on-call shape is unverified (oncallNow/onCalluser)'
if [ -n "$ONLY_TEAM" ]; then CURRENT=$(printf '%s' "$CURRENT" | jq -c --arg team "$ONLY_TEAM" 'map(select(.team==$team))'); fi
DETAILS='[]'
for policy in $(printf '%s' "$POLICIES" | jq -r '.[].slug'); do
  P=$(get "/api-public/v1/policies/$policy")
  P=$(printf '%s' "$P" | jq -ce --arg p "$policy" 'if .slug==$p and (.steps|type)=="array" and all(.steps[]; (.timeout|type)=="number" and .timeout>=0 and .timeout==(.timeout|floor) and (.entries|type)=="array" and all(.entries[];(.executionType|type)=="string" and (if .executionType=="user" then (.user.username|type)=="string" elif .executionType=="rotation_group" then (.rotationGroup.slug|type)=="string" else true end))) then {slug,steps:[.steps[]|{timeout,entries:[.entries[]|{type:.executionType,user:(if .executionType=="user" then .user.username else null end),rotation:(if .executionType=="rotation_group" then .rotationGroup.slug else null end)}]}]} else error("policy shape") end' 2>/dev/null) || fail 'policy detail identity or shape is unverified'
  DETAILS=$(printf '%s\n' "$DETAILS" "$P" | jq -sc '.[0]+[.[1]]')
done
TEAM_DATA='[]'
for team in $(printf '%s' "$TEAMS" | jq -r '.[].slug'); do
  M=$(get "/api-public/v1/team/$team/members")
  M=$(printf '%s' "$M" | jq -ce 'if (.members|type)=="array" and all(.members[];(.username|type)=="string" and (.verified|type)=="boolean") then [.members[]|{username,verified}] else error("members shape") end' 2>/dev/null) || fail 'team member shape is unverified'
  G=$(get "/api-public/v1/teams/$team/rotations")
  G=$(printf '%s' "$G" | jq -ce --arg team "$team" 'if (.rotationGroups|type)=="array" and all(.rotationGroups[];(.slug|type)=="string" and .teamSlug==$team and (.groupId|type)=="number" and .groupId>=0 and .groupId==(.groupId|floor)) then [.rotationGroups[]|{slug,groupId,teamSlug}] else error("groups shape") end' 2>/dev/null) || fail 'rotation group shape is unverified'
  R=$(get "/api-public/v2/team/$team/rotations")
  R=$(printf '%s' "$R" | jq -ce 'if (.rotations|type)=="array" and all(.rotations[]; (.groupId|type)=="number" and .groupId>=0 and .groupId==(.groupId|floor) and (.shifts|type)=="array" and all(.shifts[];(.shiftId|type)=="number" and .shiftId>=0 and .shiftId==(.shiftId|floor) and (.shifttype|type)=="string" and (.timezone|type)=="string" and (.current==null or ((.current|type)=="object" and (.current.username==null or (.current.username|type)=="string"))) and (.shiftMembers|type)=="array" and all(.shiftMembers[];(.username|type)=="string"))) then [.rotations[]|{groupId,shifts:[.shifts[]|{shiftId,shifttype,timezone,members:[.shiftMembers[].username]|unique,current_user:(if (.current.username|type)=="string" then .current.username else null end)}]}] else error("rotations shape") end' 2>/dev/null) || fail 'rotation roster shape is unverified'
  D=$(printf '%s\n' "$M" "$G" "$R" | jq -sc --arg team "$team" '{team:$team,members:.[0],groups:.[1],rotations:.[2]}')
  TEAM_DATA=$(printf '%s\n' "$TEAM_DATA" "$D" | jq -sc '.[0]+[.[1]]')
done
# Recheck identity at finish; this is sequential evidence, not an atomic snapshot.
ANCHOR=$(get "/api-public/v1/team/$TEAM")
printf '%s' "$ANCHOR" | jq -e --arg team "$TEAM" '.slug==$team' >/dev/null 2>&1 || fail 'identity changed during collection'
printf '%s\n' "$TEAMS" "$POLICIES" "$ROUTES" "$CURRENT" "$DETAILS" "$TEAM_DATA" | jq -sc \
  --arg target "$SOC_SEG" --arg started "$STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg scope "$ONLY_TEAM" --argjson source_match "$SOURCE_MATCH" \
  '{target:$target,started_at:$started,finished_at:$finished,scope:(if $scope=="" then "account" else $scope end),complete_reads:true,atomic_snapshot:false,source_match:$source_match,teams:.[0],policies:.[1],routes:.[2],current:.[3],policy_details:.[4],team_details:.[5]}'
