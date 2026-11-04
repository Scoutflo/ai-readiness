#!/bin/sh
# Execute the published blocks in fresh isolated shells. All HTTP is a stand-in.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/state"
for tool in jq curl; do command -v "$tool" >/dev/null || { echo "Missing $tool"; exit 1; }; done
extract() {
  awk -v start="$2:start" -v stop="$2:end" '
    index($0,start) {active=1;next} index($0,stop) {active=0}
    active && /^```bash/ {fence=1;next} active && /^```/ {fence=0;next}
    active && fence {print}
  ' "$1" > "$3"
  [ -s "$3" ]; sh -n "$3"
}
extract "$ROOT/skills/setup-splunk-oncall/SKILL.md" oncall-setup-doctor "$WORK/doctor.sh"
extract "$ROOT/skills/setup-splunk-oncall/references/team-description.md" oncall-team-description "$WORK/change.sh"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
set -eu
[ "${1:-}" != --version ] || { echo 'curl 8.12.0 fixture'; exit 0; }
method=GET; url=''
while [ "$#" -gt 0 ]; do
  case "$1" in --request) method=$2; shift 2;;
    --config|--proto|--max-redirs|--connect-timeout|--max-time|--max-filesize|-w) shift 2;;
    https://*) url=$1; shift;; *) shift;; esac
done
headers=$(cat)
case "$headers" in *'X-VO-Api-Id: fixture-id'*) ;; *) exit 90;; esac
case "$headers" in *'X-VO-Api-Key: fixture-read-key'*|*'X-VO-Api-Key: fixture-write-key'*) ;; *) exit 91;; esac
[ "$url" = 'https://api.victorops.com/api-public/v1/team/team-safe' ] || exit 92
printf '%s\n' "$method" >> "$FIXTURE_STATE/calls"
if [ "$method" = PUT ]; then
  case "$headers" in *'X-VO-Api-Key: fixture-write-key'*) ;; *) exit 93;; esac
  data=$(printf '%s\n' "$headers" | sed -n 's/^data = //p' | jq -r .)
  printf '%s' "$data" | jq -e 'keys==["description","name"]' >/dev/null
  if [ "${FIXTURE_CASE:-}" = denied ]; then printf '{"error":"fixture-read-key"}\n401'; exit 0; fi
  if [ "${FIXTURE_CASE:-}" = write-throttled ]; then printf '{"error":"fixture-read-key"}\n429'; exit 0; fi
  jq --argjson data "$data" '.name=$data.name | .description=$data.description | .version+=1' "$FIXTURE_STATE/team.json" > "$FIXTURE_STATE/next.json"
  mv "$FIXTURE_STATE/next.json" "$FIXTURE_STATE/team.json"
  case "${FIXTURE_CASE:-}" in
    result-race) ln -s "$FIXTURE_STATE/../victim" "$FIXTURE_STATE/../out/splunk_oncall/setup-example-action/apply.result.json";;
    result-device-race) ln -s /dev/null "$FIXTURE_STATE/../out/splunk_oncall/setup-example-action/apply.result.json";;
    applied-device-race) ln -s /dev/null "$FIXTURE_STATE/../out/splunk_oncall/setup-example-action/applied.json";;
    applied-race) ln -s "$FIXTURE_STATE/../victim" "$FIXTURE_STATE/../out/splunk_oncall/setup-example-action/applied.json";;
  esac
  [ "${FIXTURE_CASE:-}" != ambiguous ] || exit 28
fi
case "${FIXTURE_CASE:-}" in
  html) printf '<html>login</html>\n200';;
  empty) printf '\n200';;
  redirect) printf '{}\n302';;
  auth) printf '{"error":"fixture-read-key"}\n401';;
  forbidden) printf '{"error":"fixture-read-key"}\n403';;
  throttled) printf '{"error":"fixture-read-key"}\n429';;
  server) printf '{"error":"fixture-read-key"}\n503';;
  truncated) printf '{"slug":'; exit 18;;
  *) cat "$FIXTURE_STATE/team.json"; printf '\n200';;
esac
STUB
cat > "$WORK/bin/sleep" <<'STUB'
#!/bin/sh
exit 0
STUB
for tool in aws gcloud kubectl doctl claude; do
  printf '#!/bin/sh\necho "Unexpected external CLI" >&2\nexit 98\n' > "$WORK/bin/$tool"
done
chmod +x "$WORK/bin/"*
TEST_PATH="$WORK/bin:$PATH"
[ "$(PATH="$TEST_PATH" command -v curl)" = "$WORK/bin/curl" ] || exit 1
cat > "$WORK/config.yaml" <<'CONFIG'
splunk_oncall:
  api_id_env: FIXTURE_ID
  api_key_env: FIXTURE_READ
  setup_api_key_env: FIXTURE_WRITE
  team_slug: team-safe
CONFIG
cat > "$WORK/store" <<'STORE'
FIXTURE_ID='fixture-id'
FIXTURE_READ='fixture-read-key'
FIXTURE_WRITE='fixture-write-key'
STORE
reset_fixture() {
  rm -rf "$WORK/out"
  : > "$WORK/state/calls"
  cat > "$WORK/state/team.json" <<'JSON'
{"_adminsUrl":"https://api.victorops.com/api-public/v1/team/team-safe/admins","_membersUrl":"https://api.victorops.com/api-public/v1/team/team-safe/members","_policiesUrl":"https://api.victorops.com/api-public/v1/team/team-safe/policies","_selfUrl":"https://api.victorops.com/api-public/v1/team/team-safe","description":"Approved ownership metadata","isDefaultTeam":false,"memberCount":1,"name":"Example response team","slug":"team-safe","version":1}
JSON
  fixture_case=''; mode=plan; checksum=''; config="$WORK/config.yaml"; target=''
  description_presence=set; new_description='Updated ownership metadata'
}
run() {
  recipe=$1
  approved=''; [ -z "$checksum" ] || approved="$mode:$checksum"
  set -- env -i PATH="$TEST_PATH" HOME="$WORK/home" CLAUDE_PLUGIN_ROOT="$ROOT" \
    SCOUTFLO_CONFIG="$config" SCOUTFLO_ENV_FILE="$WORK/store" \
    SCOUTFLO_AUDIT_DIR="$WORK/out" SCOUTFLO_TARGET="$target" \
    SOC_MODE="$mode" SOC_RUN_ID=example-action \
    SOC_APPROVED_PLAN="$approved" FIXTURE_STATE="$WORK/state" FIXTURE_CASE="$fixture_case"
  if [ "$description_presence" = set ]; then set -- "$@" "SOC_NEW_DESCRIPTION=$new_description"; fi
  "$@" sh "$recipe" < /dev/null > "$WORK/output" 2>&1
}
relative_links() {
  jq '._selfUrl |= ltrimstr("https://api.victorops.com") | ._membersUrl |= ltrimstr("https://api.victorops.com") | ._policiesUrl |= ltrimstr("https://api.victorops.com") | ._adminsUrl |= ltrimstr("https://api.victorops.com")' "$WORK/state/team.json" > "$WORK/state/next.json"
  mv "$WORK/state/next.json" "$WORK/state/team.json"
}
no_put() { ! grep -q '^PUT$' "$WORK/state/calls"; }
no_credentials() { ! grep -Eq 'fixture-id|fixture-read-key|fixture-write-key' "$WORK/output"; }
passes=0
pass() { passes=$((passes+1)); }
reset_fixture
run "$WORK/doctor.sh"; no_put; no_credentials; pass
for fixture_case in html empty redirect auth forbidden throttled server truncated; do
  : > "$WORK/state/calls"
  if run "$WORK/doctor.sh"; then echo "FAIL: doctor accepted $fixture_case"; exit 1; fi
  case "$fixture_case" in auth) grep -q 'HTTP 401' "$WORK/output";; forbidden) grep -q 'HTTP 403' "$WORK/output";; throttled) grep -q 'HTTP 429' "$WORK/output";; server) grep -q 'HTTP 503' "$WORK/output";; esac
  no_put; no_credentials; pass
done
reset_fixture
jq '.slug="wrong-team"' "$WORK/state/team.json" > "$WORK/state/next.json"; mv "$WORK/state/next.json" "$WORK/state/team.json"
if run "$WORK/doctor.sh"; then echo 'FAIL: wrong team passed'; exit 1; fi
no_put; pass
for duplicate in '"slug":"other-team",' '"slug":{"nested":"other-team"},' '"description":"hidden text",'; do
  reset_fixture
  { printf '{%s' "$duplicate"; sed 's/^{//' "$WORK/state/team.json"; } > "$WORK/state/next.json"
  mv "$WORK/state/next.json" "$WORK/state/team.json"
  if run "$WORK/change.sh"; then echo 'FAIL: ambiguous duplicate JSON passed metadata recipe'; exit 1; fi
  no_put; no_credentials
  case "$duplicate" in *slug*) if run "$WORK/doctor.sh"; then echo 'FAIL: ambiguous identity passed doctor'; exit 1; fi;; esac
  no_put; no_credentials; pass
done
reset_fixture
cat > "$WORK/multi.yaml" <<'CONFIG'
splunk_oncall:
  - label: first
    api_id_env: FIXTURE_ID
    api_key_env: FIXTURE_READ
    setup_api_key_env: FIXTURE_WRITE
    team_slug: team-safe
  - label: second
    api_id_env: FIXTURE_ID
    api_key_env: FIXTURE_READ
    setup_api_key_env: FIXTURE_WRITE
    team_slug: team-safe
CONFIG
config="$WORK/multi.yaml"
if run "$WORK/doctor.sh"; then echo 'FAIL: unselected list passed'; exit 1; fi
target=misspelled
if run "$WORK/doctor.sh"; then echo 'FAIL: unknown label passed'; exit 1; fi
target=second; run "$WORK/doctor.sh"; no_put; pass
sed 's/label: second/label: first/' "$WORK/multi.yaml" > "$WORK/duplicate-labels.yaml"
cat >> "$WORK/duplicate-labels.yaml" <<'CONFIG'
  - label: third
    api_id_env: FIXTURE_ID
    api_key_env: FIXTURE_READ
    setup_api_key_env: FIXTURE_WRITE
    team_slug: team-safe
CONFIG
config="$WORK/duplicate-labels.yaml"; target=third; : > "$WORK/state/calls"
if run "$WORK/doctor.sh"; then echo 'FAIL: duplicate unrelated labels passed'; exit 1; fi
[ ! -s "$WORK/state/calls" ]; pass
reset_fixture
run "$WORK/change.sh"; no_put; no_credentials
plan="$WORK/out/splunk_oncall/setup-example-action/plan.json"
[ -f "$plan" ]; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}')
mode=apply; run "$WORK/change.sh"
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 1 ]
jq -e '.description=="Updated ownership metadata" and .name=="Example response team"' "$WORK/state/team.json" >/dev/null
mode=restore; run "$WORK/change.sh"
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 2 ]
jq -e '.description=="Approved ownership metadata" and .name=="Example response team"' "$WORK/state/team.json" >/dev/null
no_credentials; pass
reset_fixture
relative_links
links=$(jq -c '[._selfUrl,._membersUrl,._policiesUrl,._adminsUrl]' "$WORK/state/team.json")
run "$WORK/change.sh"; no_put; no_credentials
jq -e '.before._selfUrl=="/api-public/v1/team/team-safe" and .after._selfUrl==.before._selfUrl' "$plan" >/dev/null
[ "$(jq -c '.before | [._selfUrl,._membersUrl,._policiesUrl,._adminsUrl]' "$plan")" = "$links" ]
checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); description_presence=unset
mode=apply; run "$WORK/change.sh"
mode=restore; run "$WORK/change.sh"
[ "$(jq -c '[._selfUrl,._membersUrl,._policiesUrl,._adminsUrl]' "$WORK/state/team.json")" = "$links" ]
jq -e '.description=="Approved ownership metadata"' "$WORK/state/team.json" >/dev/null
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 2 ]; no_credentials; pass
reset_fixture
jq '._selfUrl |= ltrimstr("https://api.victorops.com")' "$WORK/state/team.json" > "$WORK/state/next.json"; mv "$WORK/state/next.json" "$WORK/state/team.json"
run "$WORK/change.sh"; no_put
jq -e '.before._selfUrl=="/api-public/v1/team/team-safe" and .before._membersUrl=="https://api.victorops.com/api-public/v1/team/team-safe/members"' "$plan" >/dev/null
no_credentials; pass
for mutation in \
  '._selfUrl="https://example.com/api-public/v1/team/team-safe"' \
  '._membersUrl="/api-public/v1/team/another-team/members"' \
  '._policiesUrl="/api-public/v1/team/team-safe/policies?limit=1"' \
  '._adminsUrl="/api-public/v1/team/team-safe/admins#fragment"' \
  '._selfUrl="//api.victorops.com/api-public/v1/team/team-safe"' \
  '._membersUrl="https://example:@api.victorops.com/api-public/v1/team/team-safe/members"' \
  '._policiesUrl="/api-public//v1/team/team-safe/policies"' \
  '._adminsUrl="/api-public/v1/team/team-safe/%2e%2e/admins"' \
  '._selfUrl="http://api.victorops.com/api-public/v1/team/team-safe"' \
  '._adminsUrl="https://api.victorops.com:443/api-public/v1/team/team-safe/admins"' \
  '._adminsUrl="/api-public/v1/team/team-safe/members"'; do
  reset_fixture; relative_links
  jq "$mutation" "$WORK/state/team.json" > "$WORK/state/next.json"; mv "$WORK/state/next.json" "$WORK/state/team.json"
  if run "$WORK/change.sh"; then echo 'FAIL: noncanonical link passed metadata recipe'; exit 1; fi
  no_put; no_credentials; [ ! -e "$plan" ]; pass
done
reset_fixture; description_presence=unset
if run "$WORK/change.sh"; then echo 'FAIL: unset proposed description produced a plan'; exit 1; fi
[ ! -s "$WORK/state/calls" ]; [ ! -e "$plan" ]
grep -q 'Set SOC_NEW_DESCRIPTION explicitly' "$WORK/output"; pass
reset_fixture; new_description=''
run "$WORK/change.sh"; no_put
jq -e '.after.description=="" and .before.description=="Approved ownership metadata"' "$plan" >/dev/null
checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); description_presence=unset
mode=apply; run "$WORK/change.sh"
jq -e '.description==""' "$WORK/state/team.json" >/dev/null
mode=restore; run "$WORK/change.sh"
jq -e '.description=="Approved ownership metadata"' "$WORK/state/team.json" >/dev/null
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 2 ]; no_credentials; pass
reset_fixture
run "$WORK/change.sh"; mode=apply; checksum=wrong
if run "$WORK/change.sh"; then echo 'FAIL: wrong approval passed'; exit 1; fi
no_put; pass
reset_fixture
run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}')
jq '.version+=1' "$WORK/state/team.json" > "$WORK/state/next.json"; mv "$WORK/state/next.json" "$WORK/state/team.json"
if run "$WORK/change.sh"; then echo 'FAIL: drift passed'; exit 1; fi
no_put; pass
for mutation in 'del(.description)' '.description=null' '.unexpected="field"' '.isDefaultTeam=true' '._selfUrl="https://example.com/other"' '.description="fixture-read-key"'; do
  reset_fixture
  jq "$mutation" "$WORK/state/team.json" > "$WORK/state/next.json"; mv "$WORK/state/next.json" "$WORK/state/team.json"
  if run "$WORK/change.sh"; then echo "FAIL: unsafe team passed: $mutation"; exit 1; fi
  no_put; no_credentials; [ ! -e "$WORK/out/splunk_oncall/setup-example-action/plan.json" ]; pass
done
reset_fixture
run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); fixture_case=ambiguous
run "$WORK/change.sh"
jq -e '.effect=="verified-by-readback" and .write_response=="unknown"' "$WORK/out/splunk_oncall/setup-example-action/apply.result.json" >/dev/null
if run "$WORK/change.sh"; then echo 'FAIL: uncertain write replayed'; exit 1; fi
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 1 ]; no_credentials; pass
reset_fixture
run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); fixture_case=denied
if run "$WORK/change.sh"; then echo 'FAIL: denied write counted verified'; exit 1; fi
[ "$(tail -n 1 "$WORK/state/calls")" = GET ]
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 1 ]; pass
reset_fixture
run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); fixture_case=write-throttled
if run "$WORK/change.sh"; then echo 'FAIL: throttled write continued'; exit 1; fi
[ "$(tail -n 1 "$WORK/state/calls")" = PUT ]
grep -q 'HTTP 429' "$WORK/output"
jq -e '.write_response=="throttled-429" and .effect=="unknown"' "$WORK/out/splunk_oncall/setup-example-action/apply.result.json" >/dev/null
no_credentials; pass
# Pre-existing unsafe outputs must stop before any PUT; they are not retries.
for slot in applied.json apply.result.json; do
  for shape in symlink dangling regular directory; do
    reset_fixture; run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}')
    slot_path="$WORK/out/splunk_oncall/setup-example-action/$slot"
    printf 'preserve me\n' > "$WORK/victim"
    case "$shape" in
      symlink) ln -s "$WORK/victim" "$slot_path";;
      dangling) ln -s "$WORK/missing-target" "$slot_path";;
      regular) printf 'existing output\n' > "$slot_path";;
      directory) mkdir "$slot_path";;
    esac
    if run "$WORK/change.sh"; then echo 'FAIL: pre-existing output accepted'; exit 1; fi
    no_put; [ "$(cat "$WORK/victim")" = 'preserve me' ]; [ ! -e "$WORK/missing-target" ]; pass
  done
done
reset_fixture; run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}'); run "$WORK/change.sh"
printf 'preserve me\n' > "$WORK/victim"
ln -s "$WORK/victim" "$WORK/out/splunk_oncall/setup-example-action/restore.result.json"
mode=restore
if run "$WORK/change.sh"; then echo 'FAIL: unsafe restore result accepted'; exit 1; fi
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 1 ]; [ "$(cat "$WORK/victim")" = 'preserve me' ]; pass
# A race after the preflight may leave an applied effect without a receipt,
# but must not overwrite the external file or permit an automatic replay.
for fixture_race in result-race applied-race result-device-race applied-device-race; do
  reset_fixture; run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}')
  printf 'preserve me\n' > "$WORK/victim"; fixture_case=$fixture_race
  if run "$WORK/change.sh"; then echo 'FAIL: output race reported verified'; exit 1; fi
  [ "$(cat "$WORK/victim")" = 'preserve me' ]; [ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 1 ]
  [ -f "$WORK/out/splunk_oncall/setup-example-action/apply.started" ]; pass
done
# A synthetic second keyset returning identical metadata must invalidate approval.
# This does not assert that real provider team IDs collide between organizations.
cp "$WORK/store" "$WORK/original-store"
for credential in FIXTURE_ID FIXTURE_READ FIXTURE_WRITE; do
  cp "$WORK/original-store" "$WORK/store"
  reset_fixture; run "$WORK/change.sh"; mode=apply; checksum=$(cksum < "$plan" | awk '{print $1 ":" $2}')
  sed "/^$credential=/s/'$/-rotated'/" "$WORK/store" > "$WORK/rotated-store"; mv "$WORK/rotated-store" "$WORK/store"
  if run "$WORK/change.sh"; then echo 'FAIL: rotated credentials reused approval'; exit 1; fi
  no_put; grep -q 'credentials changed' "$WORK/output"; no_credentials; pass
done
cp "$WORK/original-store" "$WORK/store"
for hash_behavior in fail malformed; do
  reset_fixture
  case "$hash_behavior" in
    fail) printf '#!/bin/sh\nexit 7\n' > "$WORK/bin/shasum";;
    malformed) printf '#!/bin/sh\nprintf "malformed digest\\n"\n' > "$WORK/bin/shasum";;
  esac
  chmod +x "$WORK/bin/shasum"
  if run "$WORK/change.sh"; then echo 'FAIL: unavailable hash binding accepted'; exit 1; fi
  [ ! -s "$WORK/state/calls" ]; [ ! -e "$plan" ]; pass
  rm "$WORK/bin/shasum"
done
for list_shape in unsafe missing-single; do
  reset_fixture
  if [ "$list_shape" = unsafe ]; then
    sed 's|label: second|label: ../unsafe|' "$WORK/multi.yaml" > "$WORK/unsafe-list.yaml"; target=first
  else
    sed '/  - label: second/,$d; s/- label: first/- api_id_env: FIXTURE_ID/' "$WORK/multi.yaml" > "$WORK/unsafe-list.yaml"; target=splunk_oncall
  fi
  config="$WORK/unsafe-list.yaml"
  for recipe in "$WORK/doctor.sh" "$WORK/change.sh"; do
    if run "$recipe"; then echo 'FAIL: unsafe or absent list label accepted'; exit 1; fi
    [ ! -s "$WORK/state/calls" ]; pass
  done
done
# The metadata roundtrip also uses the nested list target layout.
reset_fixture; config="$WORK/multi.yaml"; target=second
run "$WORK/change.sh"
nested_plan="$WORK/out/splunk_oncall/second/setup-example-action/plan.json"
[ -f "$nested_plan" ]; [ ! -e "$plan" ]
checksum=$(cksum < "$nested_plan" | awk '{print $1 ":" $2}'); mode=apply; run "$WORK/change.sh"
mode=restore; run "$WORK/change.sh"
[ -f "$WORK/out/splunk_oncall/second/setup-example-action/restore.result.json" ]
[ "$(grep -c '^PUT$' "$WORK/state/calls")" -eq 2 ]; pass
printf 'ONCALL-SETUP-OK: %s groups; published doctor and plan/apply/restore blocks; zero live calls\n' "$passes"
