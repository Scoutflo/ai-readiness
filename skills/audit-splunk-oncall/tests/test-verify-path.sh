#!/bin/sh
# Executes the published predicate block using a recording, no-network collector.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/plugin/skills/audit-splunk-oncall/references" "$WORK/plugin/skills/audit-splunk-oncall/scripts" "$WORK/bin" "$WORK/home"
awk '/oncall-verify-path:start/ {active=1;next} /oncall-verify-path:end/ {active=0} active && /^```bash/ {fence=1;next} active && /^```/ {fence=0;next} active && fence {print}' "$ROOT/skills/audit-splunk-oncall/references/verify-path.md" > "$WORK/verify.sh"
[ -s "$WORK/verify.sh" ]; sh -n "$WORK/verify.sh"
cp "$ROOT/skills/audit-splunk-oncall/references/effective-quality.md" "$WORK/plugin/skills/audit-splunk-oncall/references/effective-quality.md"
cat > "$WORK/plugin/skills/audit-splunk-oncall/scripts/collect.sh" <<'STUB'
#!/bin/sh
set -eu
[ "${FIXTURE_FAILURE:-}" != yes ] || exit 1
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --source-route-env ] && [ "$2" = FIXTURE_ROUTE ] || exit 90
fi
printf '%s\n' "${1:-collect}" >> "$FIXTURE_CALLS"
cat "$FIXTURE_SNAPSHOT"
STUB
for tool in curl aws gcloud kubectl doctl claude; do
  printf '#!/bin/sh\necho unexpected-network-cli >> "$FIXTURE_CALLS"\nexit 98\n' > "$WORK/bin/$tool"
done
chmod +x "$WORK/bin/"*
TEST_PATH="$WORK/bin:$PATH"
[ "$(PATH="$TEST_PATH" command -v curl)" = "$WORK/bin/curl" ] || exit 1
cat > "$WORK/base.json" <<'JSON'
{
  "target":"splunk_oncall","scope":"account","complete_reads":true,"atomic_snapshot":false,
  "teams":[{"slug":"team-one"}],
  "policies":[{"slug":"policy-one","team":"team-one"},{"slug":"policy-two","team":"team-one"}],
  "routes":[{"alias":"route-1","policies":["policy-one","policy-two"]}],
  "current":[{"team":"team-one","policy":"policy-one","users":["user-one"]},{"team":"team-one","policy":"policy-two","users":["user-one"]}],
  "policy_details":[
    {"slug":"policy-one","steps":[{"timeout":0,"entries":[{"type":"user","user":"user-one","rotation":null}]}]},
    {"slug":"policy-two","steps":[{"timeout":0,"entries":[{"type":"user","user":"user-one","rotation":null}]}]}
  ],
  "team_details":[{"team":"team-one","members":[{"username":"user-one","verified":true},{"username":"user-two","verified":true}],"groups":[{"slug":"rotation-one","groupId":1,"teamSlug":"team-one"}],"rotations":[{"groupId":1,"shifts":[{"shiftId":1,"shifttype":"std","timezone":"UTC","members":["user-one","user-two"],"current_user":"user-one"}]}]}],
  "source_match":{"route_aliases":["route-1"],"policies":["policy-one","policy-two"]}
}
JSON
reset_case() {
  cp "$WORK/base.json" "$WORK/snapshot.json"
  : > "$WORK/calls"
  check=SOC-001; minimum=1; selected='["policy-one"]'; team=team-one; source_scope=''; source_file=''; failure=''; max_age=3600; clock_skew=60; triage=0
}
mutate() { jq "$1" "$WORK/snapshot.json" > "$WORK/next.json"; mv "$WORK/next.json" "$WORK/snapshot.json"; }
run() {
  expected=$1
  rc=0
  env -i PATH="$TEST_PATH" HOME="$WORK/home" CLAUDE_PLUGIN_ROOT="$WORK/plugin" \
    SCOUTFLO_TRIAGE="$triage" SCOUTFLO_VERIFY_CHECK="$check" SCOUTFLO_VERIFY_POLICY=policy-one SCOUTFLO_VERIFY_TEAM="$team" \
    SCOUTFLO_VERIFY_POLICIES="$selected" SCOUTFLO_VERIFY_MIN_RESPONDERS="$minimum" \
    SCOUTFLO_VERIFY_SOURCE_EVIDENCE="$source_file" SCOUTFLO_VERIFY_SOURCE_SCOPE="$source_scope" \
    SCOUTFLO_VERIFY_SOURCE_MAX_AGE_SECONDS="$max_age" SCOUTFLO_VERIFY_CLOCK_SKEW_SECONDS="$clock_skew" \
    FIXTURE_SNAPSHOT="$WORK/snapshot.json" FIXTURE_CALLS="$WORK/calls" FIXTURE_FAILURE="$failure" \
    sh "$WORK/verify.sh" > "$WORK/result" 2>&1 || rc=$?
  [ "$rc" -eq "$expected" ] || { echo "FAIL $check: expected exit $expected, got $rc"; cat "$WORK/result"; exit 1; }
  ! grep -q unexpected-network-cli "$WORK/calls"
  passes=$((passes+1))
}
passes=0
reset_case; triage=1; run 2; [ ! -s "$WORK/calls" ] || { echo "FAIL triage performed deep reads"; exit 1; }
for check_id in SOC-001 SOC-002 SOC-003 SOC-005; do reset_case; check=$check_id; run 0; done
reset_case; check=SOC-004; run 3
reset_case; check=SOC-006; selected='["policy-one","policy-two"]'; minimum=2; run 1
jq -e '.observed_responders==1 and .required_responders==2' "$WORK/result" >/dev/null
mutate '.policy_details[1].steps[0].entries[0].user="user-two" | .current[1].users=["user-two"]'; run 0
jq -e '.observed_responders==2' "$WORK/result" >/dev/null
reset_case; check=SOC-006; minimum=''; run 2; [ ! -s "$WORK/calls" ]
minimum=none; run 3; [ ! -s "$WORK/calls" ]
reset_case; mutate '.routes=[]'; run 1
reset_case; mutate '.routes[0].policies += ["missing-policy"]'; run 1
reset_case; mutate '.policies += [.policies[0]]'; run 2
reset_case; mutate '.routes[0].policies += ["policy-one"]'; run 2
reset_case; mutate '.scope="team-one"'; run 2
reset_case; check=SOC-002; team=team-other; run 1
reset_case; check=SOC-002; mutate '.teams=[]'; run 1
reset_case; check=SOC-003; mutate '.policy_details[0].steps[0].entries=[]'; run 1
reset_case; check=SOC-003; mutate '.policy_details[0].steps[0].timeout=5'; run 0
reset_case; check=SOC-003; mutate '.policy_details[0].steps[0].entries[0].type="unknown"'; run 2
reset_case; check=SOC-003; mutate '.team_details[0].members[0].verified=false'; run 1
reset_case; check=SOC-003; mutate '.team_details[0].members += [.team_details[0].members[0]]'; run 2
reset_case; check=SOC-004
mutate '.policy_details[0].steps[0].entries=[{"type":"rotation_group","user":null,"rotation":"rotation-one"}]'
run 0
mutate '.team_details[0].rotations[0].shifts[0].members=[] | .team_details[0].rotations[0].shifts[0].current_user=null | .team_details[0].rotations[0].shifts[0].periods=[{"start":1,"end":2}]'; run 1
reset_case; check=SOC-004
mutate '.policy_details[0].steps[0].entries=[{"type":"rotation_group","user":null,"rotation":"rotation-one"}] | .team_details[0].rotations[0].shifts[0].shifttype="unproven"'; run 2
reset_case; check=SOC-004
mutate '.policy_details[0].steps[0].entries=[{"type":"rotation_group","user":null,"rotation":"rotation-one"}] | .team_details[0].rotations[0].shifts[0].members=["user-two"]'; run 2
reset_case; check=SOC-005
mutate '.policy_details[0].steps[0].entries += [{"type":"rotation_group","user":null,"rotation":"rotation-one"}] | .team_details[0].rotations[0].shifts[0].members=[] | .team_details[0].rotations[0].shifts[0].current_user=null'; run 0
reset_case; check=SOC-005; mutate '.current[0].users=[]'; run 1
reset_case; check=SOC-005; mutate '.current[0].users=["user-two"]'; run 2
reset_case; check=SOC-005; mutate '.current[0].team="other-team"'; run 2
reset_case; check=SOC-005; mutate '.current += [.current[0]]'; run 2
reset_case; failure=yes; run 2
reset_case; check=SOC-007; run 2; [ ! -s "$WORK/calls" ]
source_scope=none; team=''; run 3; [ ! -s "$WORK/calls" ]
reset_case; check=SOC-007; source_file="$WORK/source.json"
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{source_id:"monitor-example",observed_at:$at,route_env:"FIXTURE_ROUTE",expected_policy:"policy-one",expected_team:"team-one",verified:true}' > "$source_file"
run 0; grep -q '^--source-route-env$' "$WORK/calls"
mutate '.source_match.route_aliases=[]'; run 1
mutate '.source_match.route_aliases=["route-1","route-2"]'; run 2
mutate '.source_match.route_aliases=["route-1"] | .source_match.policies=["policy-two"]'; run 1
mutate 'del(.source_match)'; run 2
: > "$WORK/calls"
jq '.observed_at="2000-01-01T00:00:00Z"' "$source_file" > "$WORK/stale.json"; source_file="$WORK/stale.json"
run 2; [ ! -s "$WORK/calls" ]
reset_case; check=SOC-007; source_file="$WORK/source.json"
jq -n '{source_id:"monitor-example",observed_at:((now-120)|floor|todateiso8601),route_env:"FIXTURE_ROUTE",expected_policy:"policy-one",expected_team:"team-one",verified:true}' > "$source_file"
max_age=10; run 2; [ ! -s "$WORK/calls" ]
max_age=300; run 0
jq '.observed_at=((now+300)|floor|todateiso8601)' "$source_file" > "$WORK/future.json"; source_file="$WORK/future.json"
: > "$WORK/calls"; run 2; [ ! -s "$WORK/calls" ]
clock_skew=600; run 0
for bad_window in 0 -1 1.5 invalid 1e999; do
  : > "$WORK/calls"; max_age=$bad_window; run 2; [ ! -s "$WORK/calls" ]
  max_age=3600; clock_skew=$bad_window; run 2; [ ! -s "$WORK/calls" ]
done
printf 'ONCALL-VERIFY-PATH-OK: %s cases; exact published block; zero provider calls\n' "$passes"
