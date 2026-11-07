#!/bin/sh
# Execute the real doctor with an isolated config/store and an allowlisted PATH.
# The curl stand-in rejects wrong origins, writes, redirects and mixed key pairs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
mkdir -p "$WORK/bin"
for bin in awk basename cat cut date dirname grep head jq mkdir mktemp printenv sed sh sort tail tr wc; do
  path="$(command -v "$bin")" || fail "missing test prerequisite $bin"
  ln -s "$path" "$WORK/bin/$bin"
done
cat > "$WORK/bin/claude" <<'SH'
#!/bin/sh
printf '2.1.281 (fixture)\n'
SH
cat > "$WORK/bin/curl" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = --version ]; then
  if [ "$SOC_DOCTOR_MODE" = unknown-curl ]; then printf 'curl unknown fixture\n'; elif [ "$SOC_DOCTOR_MODE" = old-curl ]; then printf 'curl 8.3.0 fixture\n'; else printf 'curl 8.4.0 fixture\n'; fi
  exit 0
fi
[ "${1:-}" = -q ] || exit 90
id=''; key=''; url=''; bounded=0; proto=0; redirs=0
while [ $# -gt 0 ]; do
  case "$1" in
    -H)
      case "$2" in
        'X-VO-Api-Id: '*) id="${2#X-VO-Api-Id: }" ;;
        'X-VO-Api-Key: '*) key="${2#X-VO-Api-Key: }" ;;
        *) exit 91 ;;
      esac
      shift 2 ;;
    -L|--location|-X|--request|-d|--data*|-o|--output) exit 92 ;;
    --proto) [ "$2" = '=https' ] || exit 93; proto=1; shift 2 ;;
    --max-redirs) [ "$2" = 0 ] || exit 93; redirs=1; shift 2 ;;
    --max-filesize) [ "$2" = 1048576 ] || exit 93; bounded=1; shift 2 ;;
    -w|--connect-timeout|--max-time) shift 2 ;;
    https://*) url="$1"; shift ;;
    -q|-s) shift ;;
    *) exit 94 ;;
  esac
done
[ "$bounded$proto$redirs" = 111 ] || exit 95
case "$url|$id|$key" in
  'https://api.victorops.com/api-public/v1/team/team-a|fixture-id-a|fixture-key-a') team=team-a ;;
  'https://api.victorops.com/api-public/v1/team/team-b|fixture-id-b|fixture-key-b') team=team-b ;;
  *) printf 'contract-rejected\n' >> "$SOC_CALL_LOG"; exit 96 ;;
esac
printf '%s\n' "$team" >> "$SOC_CALL_LOG"
case "$SOC_DOCTOR_MODE" in
  good) printf '{"slug":"%s","name":"Fixture","description":"body-canary-do-not-print"}\n200 application/json' "$team" ;;
  wrong) printf '{"slug":"different-team","description":"body-canary-do-not-print"}\n200 application/json' ;;
  html) printf '<html>body-canary-do-not-print</html>\n200 text/html' ;;
  missing) printf '{"name":"Fixture"}\n200 application/json' ;;
  number) printf '{"slug":12}\n200 application/json' ;;
  null) printf '{"slug":null}\n200 application/json' ;;
  duplicate-identity) printf '{"slug":"wrong","slug":"%s"}\n200 application/json' "$team" ;;
  duplicate-object) printf '{"slug":{"nested":"wrong"},"slug":"%s"}\n200 application/json' "$team" ;;
  duplicate-array) printf '{"slug":["wrong"],"slug":"%s"}\n200 application/json' "$team" ;;
  duplicate-empty-object) printf '{"slug":{},"slug":"%s"}\n200 application/json' "$team" ;;
  duplicate-document) printf '{"slug":"wrong"}\n{"slug":"%s"}\n200 application/json' "$team" ;;
  truncated) printf '{"slug":"%s"\n200 application/json' "$team" ;;
  denied) printf '{"error":"body-canary-do-not-print"}\n401 application/json' ;;
  forbidden) printf '{"error":"body-canary-do-not-print"}\n403 application/json' ;;
  throttled) printf '{"error":"body-canary-do-not-print"}\n429 application/json' ;;
  redirect) printf '{"slug":"%s"}\n302 application/json' "$team" ;;
  transport) printf '{"slug":"%s"}\n200 application/json' "$team"; exit 28 ;;
  *) exit 97 ;;
esac
SH
chmod +x "$WORK/bin/claude" "$WORK/bin/curl"
# No system executable directory is on the launched doctor's PATH. A missing
# stand-in cannot fall through to a real cloud or network executable.
: > "$WORK/empty.env"
cat > "$WORK/single.yaml" <<'YAML'
splunk_oncall:
  api_id_env: SOC_FIXTURE_ID_A
  api_key_env: SOC_FIXTURE_KEY_A
  team_slug: team-a
YAML
cat > "$WORK/list.yaml" <<'YAML'
splunk_oncall:
  - label: alpha
    api_id_env: SOC_FIXTURE_ID_A
    api_key_env: SOC_FIXTURE_KEY_A
    team_slug: team-a
  - label: beta
    api_id_env: SOC_FIXTURE_ID_B
    api_key_env: SOC_FIXTURE_KEY_B
    team_slug: team-b
YAML
run_case() {
  case_name="$1"; mode="$2"; cfg="$3"; key_a="${4-fixture-key-a}"
  : > "$WORK/calls"
  rc=0
  (cd "$WORK" && /usr/bin/env -i PATH="$WORK/bin" \
    CLAUDE_PLUGIN_ROOT="$ROOT" SCOUTFLO_CONFIG="$WORK/$cfg" \
    SCOUTFLO_ENV_FILE="$WORK/empty.env" SOC_CALL_LOG="$WORK/calls" \
    SOC_DOCTOR_MODE="$mode" SOC_FIXTURE_ID_A=fixture-id-a \
    SOC_FIXTURE_KEY_A="$key_a" SOC_FIXTURE_ID_B=fixture-id-b \
    SOC_FIXTURE_KEY_B=fixture-key-b \
    /bin/sh "$ROOT/skills/doctor/scripts/doctor.sh" --out "$WORK/$case_name") \
    > "$WORK/$case_name.jsonl" 2> "$WORK/$case_name.stderr" || rc=$?
  grep -qE 'fixture-(key|id)-[ab]|body-canary' "$WORK/$case_name.jsonl" "$WORK/$case_name.stderr" "$WORK/$case_name/matrix.tsv" \
    && fail "$case_name exposed a credential or response body"
  return 0
}
run_case good good single.yaml
[ "$rc" = 0 ] || fail "valid team rejected (exit $rc)"
jq -s -e '[.[]|select(.integration=="splunk_oncall" and .check=="team-read" and .result=="pass")]|length==1' "$WORK/good.jsonl" >/dev/null || fail 'valid team did not pass'
[ "$(wc -l < "$WORK/calls" | tr -d ' ')" = 1 ] || fail 'single target did not make exactly one read'
for mode in wrong html missing number null duplicate-identity duplicate-object duplicate-array duplicate-empty-object duplicate-document truncated denied forbidden throttled redirect transport; do
  run_case "$mode" "$mode" single.yaml
  [ "$rc" = 3 ] || fail "$mode did not fail doctor (exit $rc)"
  jq -s -e '[.[]|select(.integration=="splunk_oncall" and .check=="team-read" and .result=="fail")]|length==1' "$WORK/$mode.jsonl" >/dev/null || fail "$mode lacks an explicit failed probe"
done
run_case list good list.yaml
[ "$rc" = 0 ] || fail 'valid two-account config failed'
jq -s -e '[.[]|select(.check=="team-read" and .result=="pass")|.integration]|sort==["splunk_oncall (alpha)","splunk_oncall (beta)"]' "$WORK/list.jsonl" >/dev/null || fail 'list did not independently verify both accounts'
[ "$(sort "$WORK/calls" | tr '\n' ' ')" = 'team-a team-b ' ] || fail 'mixed credentials or missing target read'
run_case no-key good single.yaml ''
[ "$rc" = 2 ] || fail 'unset key not env-missing'
[ ! -s "$WORK/calls" ] || fail 'unset key sent a request'
sed '/api_key_env:/d' "$WORK/single.yaml" > "$WORK/missing-key.yaml"
run_case missing-key good missing-key.yaml
[ "$rc" = 3 ] || fail 'configured block without required key was silently skipped'
[ ! -s "$WORK/calls" ] || fail 'missing key name sent a request'
sed 's/team-a/..\/team-a/' "$WORK/single.yaml" > "$WORK/path.yaml"
run_case invalid-path good path.yaml
[ "$rc" = 3 ] || fail 'invalid team path was accepted'
[ ! -s "$WORK/calls" ] || fail 'invalid team path sent a request'
sed '/team_slug:/d' "$WORK/single.yaml" > "$WORK/missing-team.yaml"
run_case missing-team good missing-team.yaml
[ "$rc" = 3 ] || fail 'missing team anchor was accepted'
[ ! -s "$WORK/calls" ] || fail 'missing team anchor sent a request'
run_case old-curl old-curl single.yaml
[ "$rc" = 3 ] || fail 'old curl was accepted'
[ ! -s "$WORK/calls" ] || fail 'old curl reached the network'
run_case unknown-curl unknown-curl single.yaml
[ "$rc" = 3 ] || fail 'unparseable curl was accepted'
[ ! -s "$WORK/calls" ] || fail 'unparseable curl reached the network'
sed 's/label: beta/label: alpha/' "$WORK/list.yaml" > "$WORK/duplicate-label.yaml"
run_case duplicate-label good duplicate-label.yaml
[ "$rc" = 3 ] || fail 'duplicate labels were accepted'
[ ! -s "$WORK/calls" ] || fail 'duplicate labels reached the network'
for label in '../alpha' 'bad label' 'bad/label'; do
  sed "s|label: alpha|label: $label|" "$WORK/list.yaml" > "$WORK/unsafe-label.yaml"
  run_case unsafe-label good unsafe-label.yaml
  [ "$rc" = 3 ] || fail 'unsafe label was accepted'
  [ ! -s "$WORK/calls" ] || fail 'unsafe label reached the network'
done
sed 's/- label: alpha/- api_id_env: SOC_FIXTURE_ID_A/' "$WORK/list.yaml" > "$WORK/missing-label.yaml"
run_case missing-label good missing-label.yaml
[ "$rc" = 3 ] || fail 'missing list label was accepted'
[ ! -s "$WORK/calls" ] || fail 'missing label reached the network'
sed '/  - label: beta/,$d; s/- label: alpha/- api_id_env: SOC_FIXTURE_ID_A/' "$WORK/list.yaml" > "$WORK/unlabeled-single-list.yaml"
run_case unlabeled-single-list good unlabeled-single-list.yaml
[ "$rc" = 3 ] || fail 'one-item list received an implicit label'
[ ! -s "$WORK/calls" ] || fail 'unlabeled one-item list reached the network'
printf 'ONCALL-DOCTOR-OK (30 behavior cases; fixed origin, credential isolation and body privacy)\n'
