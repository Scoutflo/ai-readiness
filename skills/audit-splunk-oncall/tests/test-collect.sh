#!/bin/sh
# Exercise the shipped collector with isolated config, credentials and a denying
# transport. All response values below are synthetic; no provider is contacted.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
COLLECT="$ROOT/skills/audit-splunk-oncall/scripts/collect.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/oncall-collect.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/home/.scoutflo" "$WORK/responses"
ln -s "$(command -v jq)" "$WORK/bin/jq"
cat > "$WORK/bin/sleep" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$WORK/bin/curl" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = --version ]; then
  if [ "$CASE_MODE" = old-curl ]; then printf 'curl 8.3.0 fixture\n'; else printf 'curl 8.4.0 fixture\n'; fi
  exit 0
fi
url=; id=; key=; proto=; redirects=; bound=; method=GET; no_curlrc=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in
        'X-VO-Api-Id: '*) id=${2#X-VO-Api-Id: } ;;
        'X-VO-Api-Key: '*) key=${2#X-VO-Api-Key: } ;;
      esac
      shift 2 ;;
    --proto) proto=$2; shift 2 ;;
    --max-redirs) redirects=$2; shift 2 ;;
    --max-filesize) bound=$2; shift 2 ;;
    --max-time|-w) shift 2 ;;
    -X|--request) method=$2; shift 2 ;;
    -q) no_curlrc=1; shift ;;
    -sS) shift ;;
    https://*) url=$1; shift ;;
    *) exit 87 ;;
  esac
done
# Every unmatched invocation fails here, never by falling back to real curl.
printf '%s\n' "$url" >> "$CASE_DIR/calls"
[ "$no_curlrc" -eq 1 ] && [ "$proto" = '=https' ] && [ "$redirects" = 0 ] && [ "$bound" = 2097152 ] && [ "$method" = GET ] || exit 88
[ "$id" = "$EXPECT_ID" ] && [ "$key" = "$EXPECT_KEY" ] || exit 89
case "$url" in
  https://api.victorops.com/*) route=${url#https://api.victorops.com} ;;
  *) exit 90 ;;
esac
if [ "$CASE_MODE" = wrong-team ] && [ "$route" = /api-public/v1/team/team-a ]; then
  printf '%s\n200' '{"slug":"wrong-team"}'; exit 0
fi
if [ "$CASE_MODE" = identity-drift ] && [ "$route" = /api-public/v1/team/team-a ] && [ "$(grep -c '/api-public/v1/team/team-a$' "$CASE_DIR/calls")" -gt 1 ]; then
  printf '%s\n200' '{"slug":"wrong-team"}'; exit 0
fi
if [ "$CASE_MODE" = quality-denied ] && [ "$route" = /api-public/v1/alertRules ]; then printf '%s\n403' '{"error":"private-error-canary"}'; exit 0; fi
if [ "$CASE_MODE" = html ]; then printf '%s\n200' '<html>login</html>'; exit 0; fi
case "$CASE_MODE" in
  http-*) printf '%s\n%s' '{"error":"fixture refusal"}' "${CASE_MODE#http-}"; exit 0 ;;
  transport) exit 28 ;;
esac
if [ "$CASE_MODE" = partial ] && [ "$route" = /api-public/v1/policies ]; then
  printf '%s\n200' '{"policies":['; exit 0
fi
case "$route" in
  /api-public/v1/team/team-a) file=anchor ;;
  /api-public/v1/team) file=teams ;;
  /api-public/v1/policies) file=policies ;;
  /api-public/v1/org/routing-keys) file=routes ;;
  /api-public/v1/oncall/current) file=current ;;
  /api-public/v1/policies/policy-a) file=policy-a ;;
  /api-public/v1/policies/policy-b) file=policy-b ;;
  /api-public/v1/team/team-a/members) file=members-a ;;
  /api-public/v1/team/team-b/members) file=members-b ;;
  /api-public/v1/teams/team-a/rotations) file=groups-a ;;
  /api-public/v1/teams/team-b/rotations) file=groups-b ;;
  /api-public/v2/team/team-a/rotations) file=rotations-a ;;
  /api-public/v2/team/team-b/rotations) file=rotations-b ;;
  /api-public/v1/maintenancemode) file=maintenance ;;
  /api-public/v1/alertRules) file=rules ;;
  /api-public/v1/overrides) file=overrides ;;
  /api-public/v1/profile/person-a/policies|/api-public/v1/profile/person-b/policies) file=primary ;;
  /api-public/v2/profile/person-a/policies|/api-public/v2/profile/person-b/policies) file=personal ;;
  /api-public/v1/user/person-a/contact-methods|/api-public/v1/user/person-b/contact-methods) file=contacts ;;
  /api-public/v1/team/team-a/admins) file=admins-a ;;
  /api-public/v1/team/team-b/admins) file=admins-b ;;
  /api-public/v2/team/team-a/oncall/schedule\?daysForward=14\&daysSkip=0\&step=0) file=schedule-a ;;
  /api-public/v2/team/team-b/oncall/schedule\?daysForward=14\&daysSkip=0\&step=0) file=schedule-b ;;
  *) exit 91 ;;
esac
cat "$CASE_DIR/responses/$file.json"
printf '\n200'
SH
chmod +x "$WORK/bin/curl" "$WORK/bin/sleep"

fixtures() {
  cat > "$WORK/single.yaml" <<'YAML'
splunk_oncall:
  team_slug: team-a
  api_id_env: FIRST_ID
  api_key_env: FIRST_KEY
YAML
  cat > "$WORK/list.yaml" <<'YAML'
splunk_oncall:
  - label: first
    team_slug: team-a
    api_id_env: FIRST_ID
    api_key_env: FIRST_KEY
  - label: second
    team_slug: team-a
    api_id_env: SECOND_ID
    api_key_env: SECOND_KEY
YAML
  cat > "$WORK/home/.scoutflo/env" <<'SH'
export FIRST_ID='fixture-first-id'
export FIRST_KEY='fixture-first-key'
export SECOND_ID='fixture-second-id'
export SECOND_KEY='fixture-second-key'
export UNUSED_SETUP_KEY='unused-setup-canary'
SH
  chmod 600 "$WORK/home/.scoutflo/env"
  cat > "$WORK/responses/anchor.json" <<'JSON'
{"slug":"team-a","description":"private-description-canary"}
JSON
  cat > "$WORK/responses/teams.json" <<'JSON'
[{"slug":"team-a","name":"private-team-name-canary"},{"slug":"team-b"}]
JSON
  cat > "$WORK/responses/policies.json" <<'JSON'
{"policies":[{"policy":{"slug":"policy-a"},"team":{"slug":"team-a"}},{"policy":{"slug":"policy-b"},"team":{"slug":"team-b"}}]}
JSON
  cat > "$WORK/responses/routes.json" <<'JSON'
{"routingKeys":[{"routingKey":"private-route-a-canary","apiKey":"private-api-canary","_selfUrl":"private-url-canary","raw":"{\"routing_key\":\"private-nested-canary\"}","isDefault":false,"targets":[{"policySlug":"policy-a"}]},{"routingKey":"private-route-b-canary","isDefault":true,"isMultiResponder":true,"targets":[{"policySlug":"policy-b"}]}]}
JSON
  cat > "$WORK/responses/current.json" <<'JSON'
{"teamsOnCall":[{"team":{"slug":"team-a"},"oncallNow":[{"escalationPolicy":{"slug":"policy-a"},"users":[{"onCalluser":{"username":"person-a","email":"private-contact-canary"}}]}]},{"team":{"slug":"team-b"},"oncallNow":[{"escalationPolicy":{"slug":"policy-b"},"users":[{"onCalluser":{"username":"person-b"}}]}]}]}
JSON
  cat > "$WORK/responses/policy-a.json" <<'JSON'
{"slug":"policy-a","steps":[{"timeout":0,"entries":[{"executionType":"rotation_group","rotationGroup":{"slug":"rotation-a"}}]}]}
JSON
  cat > "$WORK/responses/policy-b.json" <<'JSON'
{"slug":"policy-b","steps":[{"timeout":0,"entries":[{"executionType":"user","user":{"username":"person-b"}}]}]}
JSON
  cat > "$WORK/responses/members-a.json" <<'JSON'
{"members":[{"username":"person-a","verified":true,"email":"private-contact-canary","phone":"private-phone-canary"}]}
JSON
  cat > "$WORK/responses/members-b.json" <<'JSON'
{"members":[{"username":"person-b","verified":true}]}
JSON
  cat > "$WORK/responses/groups-a.json" <<'JSON'
{"rotationGroups":[{"slug":"rotation-a","groupId":1,"teamSlug":"team-a"}]}
JSON
  cat > "$WORK/responses/groups-b.json" <<'JSON'
{"rotationGroups":[]}
JSON
  cat > "$WORK/responses/rotations-a.json" <<'JSON'
{"rotations":[{"groupId":1,"shifts":[{"shiftId":10,"shifttype":"std","timezone":"UTC","shiftMembers":[{"username":"person-a"}],"current":{"username":"person-a","start":1,"end":2}}]}]}
JSON
  cat > "$WORK/responses/rotations-b.json" <<'JSON'
{"rotations":[]}
JSON
  cat > "$WORK/responses/maintenance.json" <<'JSON'
{"activeInstances":[{"instanceId":"maintenance-one","startedAt":1,"isGlobal":false,"targets":[{"type":"RoutingKeys","names":["private-route-a-canary"]}]}]}
JSON
  cat > "$WORK/responses/rules.json" <<'JSON'
[{"id":1,"rank":0,"stopFlag":true,"alertField":"state_message","alertValueMatch":"private-match-canary","matchType":"REGEX","routeKey":"private-route-a-canary","annotations":[{"fieldName":"entity_id","fieldValue":"private-annotation-canary"}]}]
JSON
  cat > "$WORK/responses/primary.json" <<'JSON'
{"steps":[{"index":0,"timeout":5,"rules":[{"index":0,"type":"email","contact":{"id":1,"type":"Email"}}]}]}
JSON
  cat > "$WORK/responses/personal.json" <<'JSON'
{"policies":[{"slug":"primary-one","rank":0,"timeMask":{"sunday":true,"monday":true,"tuesday":true,"wednesday":true,"thursday":true,"friday":true,"saturday":true,"timeZone":"UTC","startTime":"00:00:00.000","endTime":"00:00:00.000"},"terminalAction":"repeat_last_step","steps":[{"index":0,"timeout":5,"rules":[{"index":0,"type":"email","contact":{"id":1,"type":"Email"}}]}]}]}
JSON
  cat > "$WORK/responses/contacts.json" <<'JSON'
{"emails":{"contactMethods":[{"id":1,"email":"private-contact-canary","verified":"verified","extId":"private-email-canary"}],"_selfUrl":"private-contact-url-canary"},"phones":{"contactMethods":[]},"devices":{"contactMethods":[]}}
JSON
  printf '%s\n' '{"teamAdmins":[{"username":"person-a"}]}' > "$WORK/responses/admins-a.json"
  printf '%s\n' '{"teamAdmins":[{"username":"person-b"}]}' > "$WORK/responses/admins-b.json"
  printf '%s\n' '{"team":{"slug":"team-a"},"schedules":[{"policy":{"slug":"policy-a"},"schedule":[{"onCallType":"rotation","onCallUser":{"username":"person-a"},"rolls":[{"start":"2030-01-01T00:00:00Z","end":"2030-01-02T00:00:00Z","onCallUser":{"username":"person-a"},"isRoll":true}]}],"overrides":[]}]}' > "$WORK/responses/schedule-a.json"
  printf '%s\n' '{"team":{"slug":"team-b"},"schedules":[{"policy":{"slug":"policy-b"},"schedule":[{"onCallType":"user","onCallUser":{"username":"person-b"},"rolls":[]}],"overrides":[]}]}' > "$WORK/responses/schedule-b.json"
  printf '%s\n' '{"overrides":[]}' > "$WORK/responses/overrides.json"
  CFG="$WORK/single.yaml"; TARGET=; CASE_MODE=healthy; TRIAGE=0; QUALITY_BUDGET=500; USER_CAP=100
  EXPECT_ID=fixture-first-id; EXPECT_KEY=fixture-first-key
}
run() {
  : > "$WORK/calls"
  (cd "$WORK" && env -i HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin" \
    SCOUTFLO_CONFIG="$CFG" SCOUTFLO_ENV_FILE="$WORK/home/.scoutflo/env" \
    CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_SOURCE_EVIDENCE="$WORK/source.json" SCOUTFLO_SOURCE_MAPPING="$WORK/source-mapping.json" SCOUTFLO_ONCALL_SOURCE_BINDING="${DOC_BINDING:-$WORK/source-bound.json}" \
    SCOUTFLO_TARGET="$TARGET" SCOUTFLO_TRIAGE="$TRIAGE" SCOUTFLO_ONCALL_QUALITY_MAX_CALLS="$QUALITY_BUDGET" SCOUTFLO_ONCALL_QUALITY_MAX_USERS="$USER_CAP" CASE_DIR="$WORK" CASE_MODE="$CASE_MODE" \
    EXPECT_ID="$EXPECT_ID" EXPECT_KEY="$EXPECT_KEY" \
    /bin/sh "$COLLECT" "$@") > "$WORK/out" 2> "$WORK/err"
}
FAILS=0; PASSES=0
ok() { PASSES=$((PASSES+1)); printf 'PASS %s\n' "$1"; }
bad() { FAILS=$((FAILS+1)); printf 'FAIL %s\n' "$1" >&2; }
assert_json() { jq -e "$1" "$WORK/out" >/dev/null 2>&1; }
must_reject() {
  title=$1; shift
  if run "$@"; then bad "$title accepted"; return; fi
  if [ -s "$WORK/out" ]; then bad "$title leaked a partial snapshot"; else ok "$title"; fi
}
must_reject_before_call() {
  title=$1; shift
  must_reject "$title" "$@"
  [ ! -s "$WORK/calls" ] || bad "$title reached transport"
}

fixtures
if run && assert_json '.target=="splunk_oncall" and .complete_reads==true and .atomic_snapshot==false and (.teams|length)==2 and .current[0].users==["person-a"] and .team_details[0].rotations[0].shifts[0].members==["person-a"]'; then
  ok 'populated graph and endpoint-specific current casing'
else bad 'populated graph'; fi
if ! grep -E 'private-.*-canary|fixture-(first|second)-(id|key)|unused-setup-canary|"(routingKey|apiKey|raw|phone|email|_selfUrl)"[[:space:]]*:' "$WORK/out" "$WORK/err" >/dev/null; then
  ok 'project before output; no raw route, API or contact fields'
else bad 'sensitive projection'; fi
if assert_json '.quality.user_collection_complete==true and (.quality.selected_users|length)==2 and .quality.selected_users[0].primary.data[0].rules[0].contact_type=="email" and .quality.selected_users[0].contacts.data[0].verified==true and .quality.maintenance.data[0].route_aliases==["route-1"] and .quality.transformations.data[0].route_aliases==["route-1"] and .quality.transformations.data[0].identity_mutation==true and .quality.schedules[0].status=="collected"'; then
  ok 'quality projection preserves effective joins, exact contact types and bounded schedule scope'
else bad 'quality projection'; fi
if [ "$(grep -c '/v1/profile/person-a/policies$' "$WORK/calls")" -eq 1 ]; then ok 'referenced profile calls deduplicate people'; else bad 'profile dedup'; fi
if assert_json '.routes[0].multi_responder==null and .routes[1].multi_responder==true'; then ok 'missing multi-responder remains unknown'; else bad 'missing multi-responder'; fi

fixtures; CASE_MODE=quality-denied
if run && assert_json '.complete_reads==true and .quality.transformations.status=="read-blocked" and .quality.transformations.data==null'; then ok 'optional API denial preserves core and remains unknown'; else bad 'optional denial'; fi
fixtures; QUALITY_BUDGET=1
if run && assert_json '.quality.calls==1 and .quality.transformations.status=="budget-exhausted" and .quality.overrides.status=="budget-exhausted"'; then ok 'quality request cap remains explicit'; else bad 'quality request cap'; fi
fixtures; USER_CAP=1
if run && assert_json '.quality.selected_user_count==2 and .quality.user_collection_complete==false and (.quality.selected_users|length)==1'; then ok 'bounded user tail is incomplete'; else bad 'bounded user tail'; fi
fixtures
jq '.policies[0].timeMask.timeZone="private-timezone-canary:secret" | .policies[0].timeMask.monday={key:"private-mask-canary"} | .policies[0].timeMask.startTime="private-time-canary"' "$WORK/responses/personal.json" > "$WORK/change"; mv "$WORK/change" "$WORK/responses/personal.json"
if run && assert_json '.quality.selected_users[0].personal.data[0].time_mask | .timeZone==null and .monday==null and .startTime==null' && ! grep -q 'private-.*-canary' "$WORK/out"; then ok 'arbitrary time-mask values never survive projection'; else bad 'time mask projection'; fi
fixtures
printf '%s\n' '{"activeInstances":[],"activeInstances":[{"unknown":"private-duplicate-canary"}]}' > "$WORK/responses/maintenance.json"
if run && assert_json '.quality.maintenance.status=="read-blocked"' && ! grep -q 'private-.*-canary' "$WORK/out"; then ok 'duplicate optional JSON keys cannot hide conflicting state'; else bad 'duplicate quality JSON'; fi

fixtures
printf '%s\n' '{"policies":[]}' > "$WORK/responses/policies.json"
printf '%s\n' '{"routingKeys":[]}' > "$WORK/responses/routes.json"
printf '%s\n' '{"teamsOnCall":[]}' > "$WORK/responses/current.json"
printf '%s\n' '{"members":[]}' > "$WORK/responses/members-a.json"
printf '%s\n' '{"rotationGroups":[]}' > "$WORK/responses/groups-a.json"
printf '%s\n' '{"rotations":[]}' > "$WORK/responses/rotations-a.json"
if run && assert_json '(.routes|length)==0 and (.policies|length)==0 and (.policy_details|length)==0 and (.current|length)==0 and (.team_details[0].rotations|length)==0'; then
  ok 'empty collections do not manufacture item evidence'
else bad 'empty collections'; fi

for mode in wrong-team html http-401 http-403 http-429 partial transport; do
  fixtures; CASE_MODE=$mode; must_reject "$mode" --plan
done
for kind in scalar nested; do
  fixtures
  if [ "$kind" = scalar ]; then
    printf '%s\n' '{"slug":"wrong-team","slug":"team-a"}' > "$WORK/responses/anchor.json"
  else
    printf '%s\n' '{"slug":{"other":"wrong-team"},"slug":"team-a"}' > "$WORK/responses/anchor.json"
  fi
  must_reject "duplicate $kind anchor identity" --plan
  fixtures
  if [ "$kind" = scalar ]; then
    printf '%s\n' '{"slug":"wrong-policy","slug":"policy-a","steps":[]}' > "$WORK/responses/policy-a.json"
  else
    printf '%s\n' '{"slug":{"other":"wrong-policy"},"slug":"policy-a","steps":[]}' > "$WORK/responses/policy-a.json"
  fi
  must_reject "duplicate $kind policy identity"
done
fixtures; CASE_MODE=identity-drift; must_reject 'identity drift discards entire snapshot'
fixtures; CASE_MODE=old-curl; must_reject_before_call 'old curl cannot bound unknown-length responses' --plan

fixtures
jq '.teamsOnCall[0].oncallNow[0].users[0] |= {onCallUser:.onCalluser}' "$WORK/responses/current.json" > "$WORK/change"
mv "$WORK/change" "$WORK/responses/current.json"
must_reject 'schedule casing cannot replace current casing'

fixtures
jq '.steps[0].entries=[{executionType:"policy_routing",targetPolicy:{policySlug:"policy-b"}}]' "$WORK/responses/policy-a.json" > "$WORK/change"
mv "$WORK/change" "$WORK/responses/policy-a.json"
if run && assert_json '.policy_details[0].steps[0].entries[0] | .type=="policy_routing" and .user==null and .rotation==null'; then
  ok 'unproven entry variant remains distinguishable'
else bad 'unproven entry variant'; fi

fixtures
jq '.steps[0].entries=[{executionType:"policy_routing",targetPolicy:{policySlug:"policy-b",teamSlug:"team-b",name:"Wrong display alias",policyName:"Another display alias"}}]' "$WORK/responses/policy-a.json" > "$WORK/change"; mv "$WORK/change" "$WORK/responses/policy-a.json"
if run && assert_json '.policy_details[0].steps[0].entries[0] | .policy=="policy-b" and .policy_team=="team-b"'; then ok 'nested returned team is retained and agrees with census'; else bad 'nested team identity'; fi
jq '.steps[0].entries[0].targetPolicy.teamSlug="team-a"' "$WORK/responses/policy-a.json" > "$WORK/change"; mv "$WORK/change" "$WORK/responses/policy-a.json"
must_reject 'nested returned team contradicts the complete policy census'

fixtures; CFG="$WORK/list.yaml"
must_reject_before_call 'list requires explicit target' --plan
TARGET=missing; must_reject_before_call 'unknown target cannot fall back' --plan
TARGET=second; EXPECT_ID=fixture-second-id; EXPECT_KEY=fixture-second-key
if run --plan && assert_json '.target=="splunk_oncall/second" and .teams==2'; then ok 'selected target uses its own credentials'; else bad 'selected target credentials'; fi

fixtures; TARGET=unrelated
if run --plan && assert_json '.target=="splunk_oncall"'; then ok 'single target ignores unrelated selector'; else bad 'single selector'; fi

fixtures
if run --team team-a && assert_json '.scope=="team-a" and .teams==[{slug:"team-a"}] and all(.policies[];.team=="team-a") and all(.current[];.team=="team-a") and all(.routes[].policies[];.=="policy-a")'; then
  ok 'team scope cannot consume another team current or routes'
else bad 'team-scoped inventory contains unrelated data'; fi
fixtures
jq '.routingKeys[0].targets += [{policySlug:"policy-b"}]' "$WORK/responses/routes.json" > "$WORK/change"; mv "$WORK/change" "$WORK/responses/routes.json"
if run --team team-a && assert_json '.routes|length==1 and .[0].policies==["policy-a","policy-b"] and .[0].out_of_scope_policies==["policy-b"]'; then
  ok 'scoped fanout retains explicit unresolved external policy boundary'
else bad 'scoped fanout boundary'; fi
must_reject 'missing selected team' --team team-missing
must_reject_before_call 'selected team rejects path injection' --team '../team-a'

fixtures
sed 's/team_slug: team-a/team_slug: ..\/team-a/' "$WORK/single.yaml" > "$WORK/change"
mv "$WORK/change" "$WORK/single.yaml"
must_reject_before_call 'configured team rejects path injection' --plan
fixtures
sed '/api_key_env:/d' "$WORK/single.yaml" > "$WORK/change"; mv "$WORK/change" "$WORK/single.yaml"
must_reject_before_call 'missing credential reference' --plan
fixtures
sed '/export FIRST_KEY=/d' "$WORK/home/.scoutflo/env" > "$WORK/change"; mv "$WORK/change" "$WORK/home/.scoutflo/env"
must_reject_before_call 'missing selected credential value' --plan
fixtures
printf "export FIRST_KEY='fixture-first-key\rheader'\n" >> "$WORK/home/.scoutflo/env"
must_reject_before_call 'credential CR cannot enter a header' --plan
fixtures
printf "export FIRST_KEY='fixture-first-key\nheader'\n" >> "$WORK/home/.scoutflo/env"
must_reject_before_call 'credential newline cannot enter a header' --plan
fixtures; CFG="$WORK/not-present.yaml"
must_reject_before_call 'missing config' --plan
fixtures
sed 's/api_key_env: FIRST_KEY/api_key_env: FIRST;KEY/' "$WORK/single.yaml" > "$WORK/change"; mv "$WORK/change" "$WORK/single.yaml"
must_reject_before_call 'invalid environment reference' --plan

# Known field names do not make arbitrary nested values safe to retain.
for slot in timeout target group-team shift-mode shift-zone shift-id; do
  fixtures
  case "$slot" in
    timeout) file=policy-a; edit='.steps[0].timeout={apiKey:"private-type-canary"}' ;;
    target) file=policy-b; edit='.steps[0].entries[0].user.username={apiKey:"private-type-canary"}' ;;
    group-team) file=groups-a; edit='.rotationGroups[0].teamSlug={apiKey:"private-type-canary"}' ;;
    shift-mode) file=rotations-a; edit='.rotations[0].shifts[0].shifttype={apiKey:"private-type-canary"}' ;;
    shift-zone) file=rotations-a; edit='.rotations[0].shifts[0].timezone={apiKey:"private-type-canary"}' ;;
    shift-id) file=rotations-a; edit='.rotations[0].shifts[0].shiftId=1.5' ;;
  esac
  jq "$edit" "$WORK/responses/$file.json" > "$WORK/change"; mv "$WORK/change" "$WORK/responses/$file.json"
  must_reject "invalid retained $slot field"
done

# The protected store permits both exported and ordinary assignment syntax.
fixtures
sed 's/^export //' "$WORK/home/.scoutflo/env" > "$WORK/plain-env"; mv "$WORK/plain-env" "$WORK/home/.scoutflo/env"
if run --plan; then ok 'assignment-only credentials'; else bad 'assignment-only credentials'; fi
fixtures; CFG="$WORK/list.yaml"; TARGET=first
sed 's/label: second/label: first/' "$CFG" > "$WORK/change"; mv "$WORK/change" "$CFG"
must_reject_before_call 'duplicate labels'

# An exact source-key join retains aliases/policies only and never emits the key.
fixtures
printf "SOURCE_ROUTE='private-route-a-canary'\n" >> "$WORK/home/.scoutflo/env"
if run --source-route-env SOURCE_ROUTE && assert_json '.source_match=={route_aliases:["route-1"],policies:["policy-a"]}'; then ok 'exact source route joins'; else bad 'exact source route joins'; fi
if ! grep -q 'private-route-a-canary' "$WORK/out" "$WORK/err" "$WORK/calls"; then ok 'source secret never emitted'; else bad 'source secret emitted'; fi
fixtures
printf "SOURCE_ROUTE='nonmatching-route-canary'\n" >> "$WORK/home/.scoutflo/env"
if run --source-route-env SOURCE_ROUTE && assert_json '.source_match.route_aliases==[] and .source_match.policies==[]'; then ok 'source no-match remains explicit'; else bad 'source no-match'; fi
fixtures; must_reject_before_call 'unset source key' --source-route-env UNSET_SOURCE
fixtures; must_reject_before_call 'invalid source variable' --source-route-env 'BAD;KEY'

fixtures; must_reject_before_call 'extra plan scope argument' --plan --team team-a
fixtures; must_reject_before_call 'extra source argument after team' --team team-a --source-route-env SOURCE_ROUTE
fixtures; must_reject_before_call 'extra trailing source argument' --source-route-env SOURCE_ROUTE extra
fixtures; must_reject_before_call 'missing team argument' --team
fixtures; must_reject_before_call 'empty team argument' --team ''
fixtures; must_reject_before_call 'empty source argument' --source-route-env ''
fixtures; must_reject_before_call 'empty positional argument' ''

fixtures; CFG="$WORK/list.yaml"; TARGET=first
sed 's|label: second|label: ../unsafe|' "$CFG" > "$WORK/change"; mv "$WORK/change" "$CFG"
must_reject_before_call 'unsafe unselected list label'
fixtures; CFG="$WORK/list.yaml"; TARGET=first
sed '/  - label: second/,$d; s/- label: first/- api_id_env: FIRST_ID/' "$CFG" > "$WORK/change"; mv "$WORK/change" "$CFG"
TARGET=splunk_oncall
must_reject_before_call 'single-item list requires explicit label'

# Fast-pass regression: count transport calls, not just a metadata label.
fixtures; TRIAGE=1
if run && assert_json '.scope=="triage" and .assessed_check_ids==["SOC-001","SOC-002"] and (.deferred_check_ids|length)==16 and .current==[] and .policy_details==[] and .team_details==[]' && [ "$(wc -l < "$WORK/calls" | tr -d ' ')" -eq 5 ] && ! grep -Eq '/(members|rotations|current)$|/policies/' "$WORK/calls"; then ok 'triage bulk subset makes five reads and no detail fanout'; else bad 'triage ran deep or misstated scope'; fi
fixtures; TRIAGE=1
if run --plan && assert_json '.scope=="triage"' && [ "$(wc -l < "$WORK/calls" | tr -d ' ')" -eq 4 ]; then ok 'triage plan exposes subset scope'; else bad 'triage plan'; fi
fixtures; TRIAGE=1; CASE_MODE=identity-drift; must_reject 'triage final identity changed'
fixtures; TRIAGE=1; must_reject_before_call 'triage refuses scoped deep batch' --team team-a
fixtures; TRIAGE=1; must_reject_before_call 'triage refuses deep source selector' --source-route-env SOURCE_ROUTE
fixtures; TRIAGE=invalid; must_reject_before_call 'unknown triage setting'

# Batch source evidence compares all keys in one management snapshot, never once
# per source. The source receipt is a synthetic independently verified capture.
fixtures; CFG="$WORK/list.yaml"; TARGET=first
printf "SOURCE_ROUTE='private-route-a-canary'\n" >> "$WORK/home/.scoutflo/env"
python3 - "$WORK" <<'PY_SOURCE'
import datetime,hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1])
def raw(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
records=[{'record_id':'path-'+str(i),'source_id':'monitor-'+str(i),'route_env':None if i==98 else 'SOURCE_ROUTE','route_verification':'candidate' if i==98 else 'verified','definition':{'source_id':'monitor-'+str(i),'kind':'rule','receiver_id':'receiver-a','enabled':True,'destination_kind':'oncall-inbound'}} for i in range(100)]
common={'producer':'audit-generic','source_provider':'generic','source_target':'generic/first','observed_at':at}
source={'schema':'scoutflo-alert-source-evidence/v1',**common,'verification':{'kind':'api-read','status':'verified','evidence_ref':'source-capture.json'},'records':records}
(p/'source.json').write_bytes(raw(source))
(p/'source-capture.json').write_bytes(raw({'schema':'scoutflo-alert-source-capture/v1',**common,'verification':{'kind':'api-read','status':'verified'},'records_sha256':hashlib.sha256(raw(records)).hexdigest()}))
(p/'source-mapping.json').write_bytes(raw({'schema':'scoutflo-oncall-source-mapping/v1','source_provider':'generic','source_target':'generic/first','source_sha256':hashlib.sha256(raw(source)).hexdigest(),'expected_oncall_target':'splunk_oncall/first','records':[{'record_id':r['record_id'],'expected_policy':'policy-a','expected_team':'team-a'} for r in records if r['record_id']!='path-99']}))
PY_SOURCE
if run --bind-source-evidence "$WORK/source.json" "$WORK/source-mapping.json" && [ ! -s "$WORK/calls" ] && assert_json '(.records|length)==100 and ([.records[]|select(.status=="bound")]|length)==98'; then
  cp "$WORK/out" "$WORK/source-bound.json"; ok 'binder makes zero provider calls and preserves two blocked records'
else bad 'source binding'; cat "$WORK/err" >&2; fi
if run; then BASE_CALLS=$(wc -l < "$WORK/calls" | tr -d ' '); else bad 'source baseline collection'; BASE_CALLS=-1; fi
if run --source-records "$WORK/source-bound.json" && assert_json '(.source_matches.records|length)==100 and ([.source_matches.records[]|select(.binding_verified)]|length)==98' && [ "$(wc -l < "$WORK/calls" | tr -d ' ')" -eq "$BASE_CALLS" ] && [ "$(grep -c '/org/routing-keys$' "$WORK/calls")" -eq 1 ]; then
  ok 'one hundred source paths use one full collection and one routing read'
else bad 'batched source collection'; cat "$WORK/err" >&2; fi
if ! grep -E 'private-.*-canary|fixture-(first|second)-(id|key)' "$WORK/out" "$WORK/err" "$WORK/source-bound.json" >/dev/null; then ok 'bound packet and batch snapshot contain no secret values'; else bad 'source packet secret leak'; fi
# Execute both published source recipes in fresh shells, in flow order.
python3 - "$ROOT" "$WORK" <<'PY_RECIPES'
import pathlib,re,sys
root,work=map(pathlib.Path,sys.argv[1:])
blocks=re.findall(r'```bash\n(.*?)\n```',(root/'skills/audit-splunk-oncall/references/source-evidence.md').read_text(),re.S)
assert len(blocks)==2
for i,block in enumerate(blocks): (work/('source-recipe-'+str(i)+'.sh')).write_text(block+'\n')
PY_RECIPES
REAL_COLLECT="$COLLECT"; DOC_BINDING="$WORK/doc-bound.json"; COLLECT="$WORK/source-recipe-0.sh"
if run && [ -f "$DOC_BINDING" ] && [ ! -s "$WORK/calls" ]; then ok 'published private binder block runs in a fresh shell'; else bad 'source binder cookbook'; fi
COLLECT="$WORK/source-recipe-1.sh"
if run && assert_json '.total==100 and .assessed==98 and .counts.verified==98 and .counts.blocked==2 and .delivery_proven==false' && [ "$(wc -l < "$WORK/calls" | tr -d ' ')" -eq "$BASE_CALLS" ]; then ok 'published batch block preserves all records using one fresh collection'; else bad 'source batch cookbook'; cat "$WORK/err" >&2; fi
COLLECT="$REAL_COLLECT"; DOC_BINDING=''
TARGET=second; EXPECT_ID=fixture-second-id; EXPECT_KEY=fixture-second-key
must_reject_before_call 'same route and policy in another account cannot replay source proof' --source-records "$WORK/source-bound.json"
TARGET=first; EXPECT_ID=fixture-first-id; EXPECT_KEY=fixture-first-key
printf "SOURCE_ROUTE='changed-route-value'\n" >> "$WORK/home/.scoutflo/env"
must_reject_before_call 'changed protected route invalidates source binding' --source-records "$WORK/source-bound.json"
printf "SOURCE_ROUTE='private-route-a-canary'\n" >> "$WORK/home/.scoutflo/env"
printf '\n' >> "$WORK/source-capture.json"
must_reject_before_call 'changed capture receipt invalidates source generation' --source-records "$WORK/source-bound.json"

# Mutation control: the same wrong-team input must escape an intentionally
# disabled identity predicate. The immutable copy never alters shipped code.
fixtures; CASE_MODE=wrong-team
mkdir -p "$WORK/mutant/skills/audit-splunk-oncall/scripts" "$WORK/mutant/report-standard"
cp "$ROOT/report-standard/toolkit-targets.sh" "$WORK/mutant/report-standard/"
sed 's/and \.slug==\$team/and true/' "$COLLECT" > "$WORK/mutant/skills/audit-splunk-oncall/scripts/collect.sh"
if cmp -s "$COLLECT" "$WORK/mutant/skills/audit-splunk-oncall/scripts/collect.sh"; then
  bad 'identity mutation did not match collector'
else
  COLLECT="$WORK/mutant/skills/audit-splunk-oncall/scripts/collect.sh"
  if run --plan; then ok 'wrong-team regression catches disabled identity predicate'; else bad 'identity mutation was not observable'; fi
fi
printf 'On-Call collector: %s passed, %s failed\n' "$PASSES" "$FAILS"
[ "$FAILS" -eq 0 ]
