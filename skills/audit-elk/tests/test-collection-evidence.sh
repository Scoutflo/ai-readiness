#!/bin/sh
# Regression lock for audit-elk evidence states and complete pagination.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/elk-audit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'MOCK'
#!/bin/sh
set -eu
out=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--max-time) shift 2 ;;
    -sS|-fsS) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ -n "$out" ] || { echo "mock curl: missing -o" >&2; exit 2; }
scenario="${MOCK_SCENARIO:?}"

case "$url" in
  */api/status)
    printf '%s\n' '{"version":{"number":"9.2.0"},"name":"test-kibana"}' > "$out"
    printf '200'
    ;;
  */api/alerting/_health)
    printf '%s\n' '{"is_sufficiently_secure":true,"has_permanent_encryption_key":true}' > "$out"
    printf '200'
    ;;
  */api/spaces/space\?*)
    case "$scenario:$url" in
      legacy-array:*)
        printf '%s\n' '{"message":"unknown query parameter"}' > "$out"
        printf '400'
        ;;
      paginate-all:*\&page=1)
        jq -n '{page:1,per_page:100,total:101,
          spaces:([{id:"default",name:"Default"}]
            + [range(1;100) | {id:("space-" + tostring),name:("Space " + tostring)}])}' > "$out"
        printf '200'
        ;;
      paginate-all:*\&page=2)
        printf '%s\n' '{"page":2,"per_page":100,"total":101,"spaces":[{"id":"space-100","name":"Space 100"}]}' > "$out"
        printf '200'
        ;;
      spaces-partial:*\&page=1)
        jq -n '{page:1,per_page:100,total:125,
          spaces:([{id:"default",name:"Default"}]
            + [range(1;100) | {id:("space-" + tostring),name:("Space " + tostring)}])}' > "$out"
        printf '200'
        ;;
      spaces-partial:*)
        printf '%s\n' '{"message":"forbidden page"}' > "$out"
        printf '403'
        ;;
      spaces-forbidden:*)
        printf '%s\n' '{"message":"forbidden"}' > "$out"
        printf '403'
        ;;
      *)
        printf '%s\n' '[{"id":"default","name":"Default"}]' > "$out"
        printf '200'
        ;;
    esac
    ;;
  */api/spaces/space)
    if [ "$scenario" = "legacy-array" ]; then
      jq -n '[{id:"default",name:"Default"}]
        + [range(1;101) | {id:("space-" + tostring),name:("Space " + tostring)}]' > "$out"
      printf '200'
    else
      echo "mock curl: unexpected legacy spaces call" >&2; exit 4
    fi
    ;;
  */api/alerting/rules/_find\?*)
    case "$scenario:$url" in
      paginate-all:*\&page=1)
        jq -n '{page:1,per_page:100,total:101,
          data:[range(0;100) | {id:("rule-" + tostring),name:("Rule " + tostring),enabled:true,actions:[]}]}' > "$out"
        printf '200'
        ;;
      paginate-all:*\&page=2)
        printf '%s\n' '{"page":2,"per_page":100,"total":101,"data":[{"id":"rule-100","name":"Rule 100","enabled":true,"actions":[]}]}' > "$out"
        printf '200'
        ;;
      rules-partial:*\&page=1)
        jq -n '{page:1,per_page:100,total:125,
          data:[range(0;100) | {id:("rule-" + tostring),name:("Rule " + tostring),enabled:true,actions:[]}]}' > "$out"
        printf '200'
        ;;
      rules-partial:*)
        printf '%s\n' '{"message":"forbidden page"}' > "$out"
        printf '403'
        ;;
      rules-unauthenticated:*)
        printf '%s\n' '{"message":"unauthorized"}' > "$out"; printf '401'
        ;;
      rules-forbidden:*)
        printf '%s\n' '{"message":"forbidden"}' > "$out"; printf '403'
        ;;
      rules-unsupported:*)
        printf '%s\n' '{"message":"not found"}' > "$out"; printf '404'
        ;;
      rules-http-error:*)
        printf '%s\n' '{"message":"server error"}' > "$out"; printf '500'
        ;;
      rules-invalid-response:*)
        printf '%s\n' '<html>login</html>' > "$out"; printf '200'
        ;;
      rules-transport-error:*)
        printf '000'; exit 7
        ;;
      *)
        printf '%s\n' '{"page":1,"per_page":100,"total":0,"data":[]}' > "$out"
        printf '200'
        ;;
    esac
    ;;
  */api/actions/connectors\?*)
    case "$scenario:$url" in
      legacy-array:*)
        printf '%s\n' '{"message":"unknown query parameter"}' > "$out"
        printf '400'
        ;;
      paginate-all:*\&page=1)
        jq -n '{page:1,per_page:100,total:101,
          data:[range(0;100) | {id:("connector-" + tostring),name:("Connector " + tostring),connector_type_id:".webhook"}]}' > "$out"
        printf '200'
        ;;
      paginate-all:*\&page=2)
        printf '%s\n' '{"page":2,"per_page":100,"total":101,"data":[{"id":"connector-100","name":"Connector 100","connector_type_id":".webhook"}]}' > "$out"
        printf '200'
        ;;
      connectors-partial:*\&page=1)
        jq -n '{page:1,per_page:100,total:125,
          data:[range(0;100) | {id:("connector-" + tostring),name:("Connector " + tostring),connector_type_id:".webhook"}]}' > "$out"
        printf '200'
        ;;
      connectors-partial:*)
        printf '%s\n' '<html>proxy error</html>' > "$out"
        printf '200'
        ;;
      connectors-forbidden:*)
        printf '%s\n' '{"message":"forbidden"}' > "$out"
        printf '403'
        ;;
      *)
        printf '%s\n' '[]' > "$out"
        printf '200'
        ;;
    esac
    ;;
  */api/actions/connectors)
    if [ "$scenario" = "legacy-array" ]; then
      jq -n '[range(0;101) | {id:("connector-" + tostring),name:("Connector " + tostring),connector_type_id:".webhook"}]' > "$out"
      printf '200'
    else
      echo "mock curl: unexpected legacy connectors call" >&2; exit 4
    fi
    ;;
  */api/alerting/rule_types)
    printf '%s\n' '[]' > "$out"
    printf '200'
    ;;
  *)
    echo "mock curl: unexpected URL $url" >&2
    exit 4
    ;;
esac
MOCK
chmod +x "$WORK/bin/curl"
printf '%s\n' default > "$WORK/configured-spaces.txt"

run_case() {
  scenario="$1"
  out="$WORK/$scenario/raw"
  mkdir -p "$out"
  PATH="$WORK/bin:$PATH" \
    MOCK_SCENARIO="$scenario" \
    KIBANA_URL="https://kibana.invalid" \
    KIBANA_API_KEY="test-token-never-printed" \
    ELK_SPACES_FILE="$WORK/configured-spaces.txt" \
    OUT_DIR="$out" \
    bash "$SCRIPT" > "$WORK/$scenario.stdout" 2> "$WORK/$scenario.stderr" \
    || {
      sed -n '1,160p' "$WORK/$scenario.stdout" >&2
      sed -n '1,160p' "$WORK/$scenario.stderr" >&2
      fail "$scenario run exited nonzero"
    }
}

echo "Test 1: spaces, rules, and connectors collect every page beyond 100"
run_case paginate-all
ALL="$WORK/paginate-all/raw"
[ -f "$ALL/spaces.json" ] || {
  sed -n '1,200p' "$WORK/paginate-all.stdout" >&2
  sed -n '1,200p' "$ALL/errors.log" >&2
  sed -n '1,240p' "$ALL/request-status.jsonl" >&2
  fail "complete spaces artifact missing"
}
[ "$(jq 'length' "$ALL/spaces.json")" -eq 101 ] || fail "spaces pagination truncated"
[ "$(jq '.rules | length' "$ALL/spaces/default/rules.json")" -eq 101 ] || fail "rules pagination truncated"
[ "$(jq 'length' "$ALL/spaces/default/connectors.json")" -eq 101 ] || fail "connectors pagination truncated"
for prefix in '/api/spaces/space' '/api/alerting/rules/_find' '/api/actions/connectors'; do
  jq -e --arg prefix "$prefix" \
    'select((.path | contains($prefix)) and (.path | contains("page=2")) and (.state == "success-nonempty"))' \
    "$ALL/request-status.jsonl" >/dev/null || fail "$prefix did not request page 2"
done

echo "Test 2: first-page auth, HTTP, transport, and invalid JSON failures never become empty evidence"
for pair in \
  'rules-unauthenticated:unauthenticated:401' \
  'rules-forbidden:forbidden:403' \
  'rules-unsupported:unsupported:404' \
  'rules-http-error:http-error:500' \
  'rules-transport-error:transport-error:000' \
  'rules-invalid-response:invalid-response:200'
do
  scenario=${pair%%:*}; rest=${pair#*:}; expected=${rest%%:*}; code=${rest##*:}
  run_case "$scenario"
  raw="$WORK/$scenario/raw"
  [ ! -e "$raw/spaces/default/rules.json" ] || fail "$scenario produced a false complete rules artifact"
  [ ! -e "$raw/spaces/default/rules.partial.json" ] || fail "$scenario produced partial rules with zero successful pages"
  jq -e --arg state "$expected" --arg code "$code" \
    'select((.path | contains("/api/alerting/rules/_find?"))
      and .state == $state and .http_status == $code)' \
    "$raw/request-status.jsonl" >/dev/null || fail "$scenario state/status missing"
  grep -q '^rules=unavailable$' "$raw/summary.txt" \
    || fail "$scenario summary counted an unreadable rules estate"
done
[ -f "$WORK/rules-forbidden/raw/spaces/default/.rules-pages/page-1.json.http-403" ] \
  || fail "403 response body was not retained"
[ -f "$WORK/rules-invalid-response/raw/spaces/default/.rules-pages/page-1.json.invalid-response" ] \
  || fail "invalid 200 body was not retained"

echo "Test 3: legacy unpaginated spaces/connectors keep every object after query fallback"
run_case legacy-array
LEGACY="$WORK/legacy-array/raw"
[ "$(jq 'length' "$LEGACY/spaces.json")" -eq 101 ] || fail "legacy spaces array was truncated"
[ "$(jq 'length' "$LEGACY/spaces/default/connectors.json")" -eq 101 ] || fail "legacy connectors array was truncated"
jq -e 'select(.path == "/api/spaces/space" and .state == "success-nonempty")' \
  "$LEGACY/request-status.jsonl" >/dev/null || fail "legacy spaces fallback state missing"

echo "Test 4: a later rules page failure preserves only an explicit partial artifact"
run_case rules-partial
RULES_PARTIAL="$WORK/rules-partial/raw"
[ ! -e "$RULES_PARTIAL/spaces/default/rules.json" ] || fail "partial rules became complete"
jq -e '.state == "partial" and .collected == 100 and .expected_total == 125 and (.rules | length) == 100' \
  "$RULES_PARTIAL/spaces/default/rules.partial.json" >/dev/null || fail "rules partial artifact is wrong"
jq -e 'select(.path == "/api/alerting/rules/_find (paginated aggregate)" and .state == "partial")' \
  "$RULES_PARTIAL/request-status.jsonl" >/dev/null || fail "rules aggregate partial state missing"

echo "Test 5: connector pagination failure is partial, never a complete connector estate"
run_case connectors-partial
CONN_PARTIAL="$WORK/connectors-partial/raw"
[ ! -e "$CONN_PARTIAL/spaces/default/connectors.json" ] || fail "partial connectors became complete"
jq -e '.state == "partial" and .collected == 100 and .expected_total == 125 and (.connectors | length) == 100' \
  "$CONN_PARTIAL/spaces/default/connectors.partial.json" >/dev/null || fail "connector partial artifact is wrong"
jq -e 'select((.path | contains("/api/actions/connectors?")) and .state == "invalid-response")' \
  "$CONN_PARTIAL/request-status.jsonl" >/dev/null || fail "connector invalid later page state missing"

echo "Test 6: space pagination failure keeps partial discovery and uses an explicit configured fallback"
run_case spaces-partial
SPACES_PARTIAL="$WORK/spaces-partial/raw"
[ ! -e "$SPACES_PARTIAL/spaces.json" ] || fail "partial spaces became a complete discovery"
jq -e '.state == "partial" and .collected == 100 and .expected_total == 125 and (.spaces | length) == 100' \
  "$SPACES_PARTIAL/spaces.partial.json" >/dev/null || fail "spaces partial artifact is wrong"
jq -e '.collection_state == "partial" and (.audit_scope_state | startswith("configured-fallback"))' \
  "$SPACES_PARTIAL/space-discovery-state.json" >/dev/null || fail "space fallback state was hidden"
grep -qx default "$SPACES_PARTIAL/spaces.txt" || fail "configured fallback space was not audited"

echo "Test 7: first-page space/connector denials remain blocked evidence"
run_case spaces-forbidden
SPACES_DENIED="$WORK/spaces-forbidden/raw"
[ ! -e "$SPACES_DENIED/spaces.json" ] || fail "forbidden space discovery became complete"
[ ! -e "$SPACES_DENIED/spaces.partial.json" ] || fail "first-page space denial became partial data"
jq -e '.collection_state == "forbidden" and (.audit_scope_state | startswith("configured-fallback"))' \
  "$SPACES_DENIED/space-discovery-state.json" >/dev/null || fail "first-page space denial state missing"

run_case connectors-forbidden
CONN_DENIED="$WORK/connectors-forbidden/raw"
[ ! -e "$CONN_DENIED/spaces/default/connectors.json" ] || fail "forbidden connectors became complete"
[ ! -e "$CONN_DENIED/spaces/default/connectors.partial.json" ] || fail "first-page connector denial became partial data"
jq -e '.connectors.state == "forbidden" and .connectors.collected == 0' \
  "$CONN_DENIED/spaces/default/collection-state.json" >/dev/null || fail "connector denial state missing"

echo "Test 8: only documented normalized request states are emitted"
for ledger in "$WORK"/*/raw/request-status.jsonl; do
  jq -e 'select(.state as $s
    | ["success-empty","success-nonempty","forbidden","unauthenticated","unsupported",
       "transport-error","http-error","invalid-response","partial"] | index($s) == null)' \
    "$ledger" >/dev/null 2>&1 && fail "undocumented state in $ledger"
done

echo "ALL ELK COLLECTION-EVIDENCE TESTS PASSED"
