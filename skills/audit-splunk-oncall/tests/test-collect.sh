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
  CFG="$WORK/single.yaml"; TARGET=; CASE_MODE=healthy
  EXPECT_ID=fixture-first-id; EXPECT_KEY=fixture-first-key
}
run() {
  : > "$WORK/calls"
  (cd "$WORK" && env -i HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin" \
    SCOUTFLO_CONFIG="$CFG" SCOUTFLO_ENV_FILE="$WORK/home/.scoutflo/env" \
    SCOUTFLO_TARGET="$TARGET" CASE_DIR="$WORK" CASE_MODE="$CASE_MODE" \
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
if ! grep -E 'private-.*-canary|fixture-(first|second)-(id|key)|unused-setup-canary|"(routingKey|apiKey|raw|phone|email|_selfUrl)"' "$WORK/out" "$WORK/err" >/dev/null; then
  ok 'project before output; no raw route, API or contact fields'
else bad 'sensitive projection'; fi
if assert_json '.routes[0].multi_responder==null and .routes[1].multi_responder==true'; then ok 'missing multi-responder remains unknown'; else bad 'missing multi-responder'; fi

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
