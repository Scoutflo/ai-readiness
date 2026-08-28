#!/bin/sh
# Regression lock for Grafana API evidence states and paginated search honesty.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/grafana-audit.sh"
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

case "$url" in
  */api/health)
    printf '%s\n' '{"database":"ok"}' > "$out"
    printf '200'
    exit 0
    ;;
  */api/search\?*)
    scenario="${MOCK_SEARCH_SCENARIO:?}"
    case "$scenario" in
      success-empty)
        printf '%s\n' '[]' > "$out"; printf '200'; exit 0 ;;
      forbidden)
        printf '%s\n' '{"message":"forbidden"}' > "$out"; printf '403'; exit 0 ;;
      unauthenticated)
        printf '%s\n' '{"message":"unauthorized"}' > "$out"; printf '401'; exit 0 ;;
      unsupported)
        printf '%s\n' '{"message":"not found"}' > "$out"; printf '404'; exit 0 ;;
      http-error)
        printf '%s\n' '{"message":"server error"}' > "$out"; printf '500'; exit 0 ;;
      invalid-response)
        printf '%s\n' '<html>not json</html>' > "$out"; printf '200'; exit 0 ;;
      transport-error)
        printf '000'; exit 7 ;;
      partial)
        case "$url" in
          *page=1*) jq -n '[range(0;1000) | {uid:("d" + (tostring))}]' > "$out"; printf '200'; exit 0 ;;
          *) printf '%s\n' '{"message":"forbidden page"}' > "$out"; printf '403'; exit 0 ;;
        esac
        ;;
      *) echo "mock curl: unknown scenario $scenario" >&2; exit 3 ;;
    esac
    ;;
  *)
    echo "mock curl: unexpected URL $url" >&2
    exit 4
    ;;
esac
MOCK
chmod +x "$WORK/bin/curl"
: > "$WORK/no-dashboard-uids.txt"

run_case() {
  scenario="$1"
  out="$WORK/$scenario/raw"
  mkdir -p "$out"
  PATH="$WORK/bin:$PATH" \
    MOCK_SEARCH_SCENARIO="$scenario" \
    GRAFANA_URL="https://grafana.invalid" \
    GRAFANA_TOKEN="test-token-never-printed" \
    OUT_DIR="$out" \
    DASHBOARD_UIDS_FILE="$WORK/no-dashboard-uids.txt" \
    SKIP_NON_DASHBOARD=1 \
    bash "$SCRIPT" > "$WORK/$scenario.stdout" 2> "$WORK/$scenario.stderr" \
    || fail "$scenario run exited nonzero"
}

echo "Test 1: a verified empty search is success-empty and creates a complete empty index"
run_case success-empty
EMPTY="$WORK/success-empty/raw"
jq -e 'select(.path | startswith("/api/search?")) | select(.state == "success-empty")' \
  "$EMPTY/request-status.jsonl" >/dev/null || fail "success-empty state missing"
[ -f "$EMPTY/dashboard-index.json" ] || fail "complete empty index missing"
[ "$(jq length "$EMPTY/dashboard-index.json")" -eq 0 ] || fail "empty index is not empty"
[ ! -e "$EMPTY/dashboard-index.partial.json" ] || fail "empty complete response was marked partial"

echo "Test 2: auth, support, HTTP, transport, and invalid-response states never become []"
for pair in \
  'forbidden:forbidden:403' \
  'unauthenticated:unauthenticated:401' \
  'unsupported:unsupported:404' \
  'http-error:http-error:500' \
  'transport-error:transport-error:000' \
  'invalid-response:invalid-response:200'
do
  scenario=${pair%%:*}; rest=${pair#*:}; expected=${rest%%:*}; code=${rest##*:}
  run_case "$scenario"
  raw="$WORK/$scenario/raw"
  jq -e --arg state "$expected" --arg code "$code" \
    'select(.path | startswith("/api/search?"))
     | select(.state == $state and .http_status == $code)' \
    "$raw/request-status.jsonl" >/dev/null || fail "$scenario state/status missing"
  [ ! -e "$raw/dashboard-index.json" ] || fail "$scenario produced a false complete index"
  [ ! -e "$raw/dashboard-index.partial.json" ] || fail "$scenario produced a false partial index with zero pages"
  grep -q '^dashboard_index_state=unavailable$' "$raw/summary.txt" \
    || fail "$scenario summary did not declare unavailable"
done
[ -f "$WORK/forbidden/raw/.search-pages/page-1.json.http-403" ] \
  || fail "403 response body was not retained as evidence"
[ -f "$WORK/invalid-response/raw/.search-pages/page-1.json.invalid-response" ] \
  || fail "invalid 200 body was not retained as evidence"

echo "Test 3: a later-page failure preserves successful pages only as explicit partial evidence"
run_case partial
PARTIAL="$WORK/partial/raw"
[ ! -e "$PARTIAL/dashboard-index.json" ] || fail "partial pagination produced a complete index"
[ -f "$PARTIAL/dashboard-index.partial.json" ] || fail "partial pagination artifact missing"
[ "$(jq length "$PARTIAL/dashboard-index.partial.json")" -eq 1000 ] \
  || fail "partial artifact did not preserve the successful first page"
jq -e 'select(.path == "/api/search (paginated aggregate)") | select(.state == "partial")' \
  "$PARTIAL/request-status.jsonl" >/dev/null || fail "aggregate partial state missing"
jq -e 'select(.path | startswith("/api/search?")) | select(.state == "success-nonempty")' \
  "$PARTIAL/request-status.jsonl" >/dev/null || fail "successful nonempty page state missing"
jq -e 'select(.path | startswith("/api/search?")) | select(.state == "forbidden")' \
  "$PARTIAL/request-status.jsonl" >/dev/null || fail "failed later-page state missing"
grep -q '^dashboard_index_state=partial$' "$PARTIAL/summary.txt" \
  || fail "partial summary state missing"
grep -q '^dashboards=unavailable$' "$PARTIAL/summary.txt" \
  || fail "partial pagination was counted as a complete dashboard estate"

echo "Test 4: request ledger contains only the documented normalized states"
for ledger in "$WORK"/*/raw/request-status.jsonl; do
  jq -e 'select(.state as $s
    | ["success-empty","success-nonempty","forbidden","unauthenticated","unsupported",
       "transport-error","http-error","invalid-response","partial"] | index($s) == null)' \
    "$ledger" >/dev/null 2>&1 && fail "undocumented state in $ledger"
done

echo "Test 5: a normal same-day rerun removes dashboard and datasource artifacts that no longer exist"
RERUN="$WORK/rerun/raw"
mkdir -p "$RERUN/dashboards" "$RERUN/datasource-health"
printf '%s\n' '{"dashboard":{"uid":"deleted-dashboard","panels":[]}}' > "$RERUN/dashboards/deleted-dashboard.json"
printf '%s\n' '{"status":"OK"}' > "$RERUN/datasource-health/deleted-datasource.json"
PATH="$WORK/bin:$PATH" \
  MOCK_SEARCH_SCENARIO="success-empty" \
  GRAFANA_URL="https://grafana.invalid" \
  GRAFANA_TOKEN="test-token-never-printed" \
  OUT_DIR="$RERUN" \
  bash "$SCRIPT" > "$WORK/rerun.stdout" 2> "$WORK/rerun.stderr" \
  || fail "normal rerun exited nonzero"
[ ! -e "$RERUN/dashboards/deleted-dashboard.json" ] \
  || fail "deleted dashboard survived a normal same-day rerun"
[ ! -e "$RERUN/datasource-health/deleted-datasource.json" ] \
  || fail "deleted datasource health artifact survived a normal same-day rerun"
[ "$(jq length "$RERUN/dashboard-index.json")" -eq 0 ] \
  || fail "normal rerun did not preserve the current empty dashboard estate"

echo "ALL GRAFANA EVIDENCE-STATE TESTS PASSED"
