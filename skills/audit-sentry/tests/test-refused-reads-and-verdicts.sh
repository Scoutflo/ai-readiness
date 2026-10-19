#!/bin/sh
# test-refused-reads-and-verdicts.sh: runs audit-sentry's own published blocks, as written, with
# standard input closed (as in an agent session) and a stand-in curl first on PATH that never
# touches the network. It checks:
#  (a) a refused read (a 403 with a JSON {"detail": ...} body where -f reads exit 22, a 200 HTML
#      sign-in page, or no response at all) prints "SNTRY-NNN blocked: ..." and nothing else: no
#      pass, fail, n/a, row, or shell error. Answered reads still give each check its verdict, so a
#      check that always said "blocked" would fail here too;
#  (b) SNTRY-108 reads environment claims as whole words, on both alert-API branches;
#  (c) SNTRY-109 leaves disabled alerts to SNTRY-016 and applies FREQ_FLOOR_MIN, on both branches;
#  (d) SNTRY-022 prints each offending code mapping and a pass or fail verdict;
#  (e) Phase 1 and the large-org worklist record a refused project read in blocked-reads.tsv, carry
#      on with the next project, never store a failed keys read as [], and never save the project
#      securityToken or a key's secret.
# Set BLOCK_SH=dash to run the blocks under another POSIX shell.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECKS="$ROOT/skills/audit-sentry/references/api-checks.md"
SKILL="$ROOT/skills/audit-sentry/SKILL.md"
BLOCK_SH="${BLOCK_SH:-sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
mkdir -p "$WORK/bin" "$WORK/blocks" "$WORK/fx" "$WORK/tmp" "$WORK/home" "$WORK/cwd"
TAB="$(printf '\t')"
TODAY="$(date -u +%Y-%m-%d)"
FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }

# ---- stand-in curl ------------------------------------------------------------------------------
# A URL matching a glob in FAKE_CURL_ROUTES ("<glob><TAB><fixture file>" lines, first match wins)
# answers 200 application/json with that fixture. Every other URL is refused per FAKE_CURL_REFUSE.
cat > "$WORK/bin/curl" <<'EOF'
#!/bin/sh
out=""; fmt=""; hdr=""; fail=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -D) hdr="$2"; shift ;;
    -H|--max-time|-X|-d) shift ;;
    --fail) fail=1 ;;
    --*) ;;
    -*) case "$1" in *f*) fail=1 ;; esac ;;
    *) url="$1" ;;
  esac
  shift
done
[ -z "${FAKE_CURL_LOG:-}" ] || printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
status=""; ctype=""; body_file=""; body_text=""
if [ -f "${FAKE_CURL_ROUTES:-}" ]; then
  tab="$(printf '\t')"
  while IFS="$tab" read -r pat file; do
    [ -n "$pat" ] || continue
    case "$url" in $pat) status=200; ctype="application/json"; body_file="$file"; break ;; esac
  done < "$FAKE_CURL_ROUTES"
fi
write_out() {
  [ -n "$fmt" ] || return 0
  w="$(printf '%s' "$fmt" | sed -e "s|%{http_code}|${status}|g" -e "s|%{content_type}|${ctype}|g")"
  printf '%b' "$w"
}
if [ -z "$status" ]; then
  case "${FAKE_CURL_REFUSE:-403}" in
    html) status=200; ctype="text/html; charset=utf-8"; body_text="<html><body>Sign in to continue</body></html>" ;;
    down) status=000; ctype=""
          write_out
          echo "curl: (7) Failed to connect: network disabled in this test" >&2
          exit 7 ;;
    *) status=403; ctype="application/json"
       body_text='{"detail": "You do not have permission to perform this action."}' ;;
  esac
fi
[ -z "$hdr" ] || printf 'HTTP/1.1 %s\r\ncontent-type: %s\r\n\r\n' "$status" "$ctype" > "$hdr"
if [ "$fail" -eq 1 ] && [ "$status" -ge 400 ]; then
  write_out
  echo "curl: (22) The requested URL returned error: $status" >&2
  exit 22
fi
emit() { if [ -n "$body_file" ]; then cat "$body_file"; else printf '%s' "$body_text"; fi; }
if [ -n "$out" ]; then emit > "$out"; else emit; fi
write_out
exit 0
EOF
chmod +x "$WORK/bin/curl"

# ---- helpers ------------------------------------------------------------------------------------
# extract <file> <line prefix> <n> <name>: the n-th bash block after the first line starting with
# <line prefix>, written to $WORK/blocks/<name>.sh.
extract() {
  awk -v pre="$2" -v want="$3" '
    f == 0 && index($0, pre) == 1 { f = 1; next }
    f == 1 && /^```bash/ { n++; if (n == want) { f = 2; next } }
    f == 2 && /^```/ { exit }
    f == 2 { print }' "$1" > "$WORK/blocks/$4.sh"
  [ -s "$WORK/blocks/$4.sh" ] || { echo "FAIL: no bash block $3 after '$2' in $1" >&2; exit 1; }
}
# legacy <name>: a copy of block <name> that runs its SENTRY_ALERT_API=legacy branch.
legacy() {
  sed 's/^SENTRY_ALERT_API="workflows"/SENTRY_ALERT_API="legacy"/' "$WORK/blocks/$1.sh" > "$WORK/blocks/$1L.sh"
  grep -q '^SENTRY_ALERT_API="legacy"' "$WORK/blocks/$1L.sh" || { echo "FAIL: block $1 has no SENTRY_ALERT_API line" >&2; exit 1; }
}
# fx <name> <json>: writes a fixture file and prints its path.
fx() { printf '%s\n' "$2" > "$WORK/fx/$1"; printf '%s' "$WORK/fx/$1"; }
# routes [<glob> <fixture file>]...: the reads that answer 200; every other read is refused.
routes() { : > "$WORK/routes"; while [ $# -gt 1 ]; do printf '%s\t%s\n' "$1" "$2" >> "$WORK/routes"; shift 2; done; }
# run <block file> [refusal: 403|html|down]: runs the block in a clean environment, stdin closed.
run() {
  RC=0
  ( cd "$WORK/cwd" && env -i PATH="$WORK/bin:$PATH" HOME="$WORK/home" TMPDIR="$WORK/tmp" \
      SENTRY_TOKEN="example-not-a-secret" SCOUTFLO_AUDIT_DIR="$WORK/aud" \
      SCOUTFLO_CONFIG="$WORK/toolkit.yaml" CLAUDE_PLUGIN_ROOT="$ROOT" \
      FAKE_CURL_ROUTES="$WORK/routes" FAKE_CURL_REFUSE="${2:-403}" FAKE_CURL_LOG="$WORK/curl.log" \
      "$BLOCK_SH" "$1" ) < /dev/null > "$WORK/out" 2> "$WORK/err" || RC=$?
  if [ -n "$(ls -A "$WORK/tmp")" ]; then fail "$(basename "$1") left temp files behind"; rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"; fi
}
shown() { tr '\n' '|' < "$WORK/out" | cut -c1-400; }
has() { grep -Eq -- "$2" "$WORK/out" || fail "$1: expected a line matching /$2/ (stdout: $(shown); stderr: $(tail -2 "$WORK/err" | tr '\n' '|'))"; }
hasnt() { if grep -Eq -- "$2" "$WORK/out"; then fail "$1: unexpected line: $(grep -E -- "$2" "$WORK/out" | head -1)"; fi; }
ok_exit() { [ "$RC" -eq 0 ] || fail "$1: exited $RC, expected 0 (stderr: $(tail -2 "$WORK/err" | tr '\n' '|'))"; }
# only_blocked <case> <prefix>: exit 0, a "<prefix> blocked: " line, and no other output line.
only_blocked() {
  ok_exit "$1"
  grep -q "^$2 blocked: " "$WORK/out" || fail "$1: expected a '$2 blocked:' line (stdout: $(shown))"
  if grep -vq "^$2 blocked: " "$WORK/out"; then fail "$1: printed more than the blocked line: $(grep -v "^$2 blocked: " "$WORK/out" | head -1)"; fi
}
# no_secret <case> <dir or file>...: no saved file and no printed line carries a fixture secret.
no_secret() {
  c="$1"; shift
  for t in "$WORK/out" "$WORK/err" "$@"; do
    if [ -e "$t" ] && grep -rqE 'sectok-marker|ks-marker|dsn-marker' "$t"; then fail "$c: a project securityToken or key secret reached $t"; fi
  done
}

# ---- the published blocks -----------------------------------------------------------------------
extract "$CHECKS" '**SNTRY-002,' 1 p2
extract "$CHECKS" '**SNTRY-003,' 1 p3
extract "$CHECKS" '**SNTRY-003,' 2 p3b
extract "$CHECKS" '**SNTRY-004,' 1 p4
extract "$CHECKS" 'Snippet and reading order for SNTRY-009' 1 p9
extract "$CHECKS" '**SNTRY-016,' 1 p16
extract "$CHECKS" '**SNTRY-017,' 1 p17
extract "$CHECKS" '**SNTRY-019,' 1 p19
extract "$CHECKS" '**SNTRY-020,' 1 p20a
extract "$CHECKS" '**SNTRY-020,' 2 p20b
extract "$CHECKS" '**SNTRY-021,' 1 p21
extract "$CHECKS" '**SNTRY-022,' 1 p22
extract "$CHECKS" '**SNTRY-023,' 1 p23
extract "$CHECKS" '**SNTRY-024,' 1 p24
extract "$CHECKS" '**SNTRY-025,' 1 p25
extract "$CHECKS" '**SNTRY-102,' 1 p102
extract "$CHECKS" '**SNTRY-104,' 1 p104
extract "$CHECKS" '**SNTRY-105,' 1 p105
extract "$CHECKS" '**SNTRY-107,' 1 p107
extract "$CHECKS" '**SNTRY-108,' 1 p108
extract "$CHECKS" '**SNTRY-109,' 1 p109
extract "$CHECKS" '**SNTRY-110,' 1 p110
extract "$CHECKS" "**Step 3: pull the batch's raw data" 1 step3
extract "$CHECKS" '**Step 4: merge into the date-keyed' 1 step4
extract "$SKILL" '## Phase 1: Inventory' 1 phase1
for b in p16 p17 p102 p107 p108 p109 p110 phase1; do legacy "$b"; done
for pair in p2:SNTRY-002 p3:SNTRY-003 p3b:SNTRY-003 p4:SNTRY-004 p9:SNTRY-009 p16:SNTRY-016 p17:SNTRY-017 \
            p19:SNTRY-019 p20a:SNTRY-020 p20b:SNTRY-020 p21:SNTRY-021 p22:SNTRY-022 p23:SNTRY-023 p24:SNTRY-024 \
            p25:SNTRY-025 p102:SNTRY-102 p104:SNTRY-104 p105:SNTRY-105 p107:SNTRY-107 p108:SNTRY-108 \
            p109:SNTRY-109 p110:SNTRY-110; do
  grep -q "${pair#*:}" "$WORK/blocks/${pair%%:*}.sh" || { echo "FAIL: block ${pair%%:*} is not the ${pair#*:} block" >&2; exit 1; }
done

# ---- (a) every refused read prints blocked and nothing else ---------------------------------------
DENY="p2:SNTRY-002 p3:SNTRY-003 p4:SNTRY-004 p9:SNTRY-009 p16:SNTRY-016 p16L:SNTRY-016 p17:SNTRY-017 \
p17L:SNTRY-017 p19:SNTRY-019 p20a:SNTRY-020 p20b:SNTRY-020 p21:SNTRY-021 p22:SNTRY-022 p23:SNTRY-023 \
p24:SNTRY-024 p25:SNTRY-025 p102:SNTRY-102 p102L:SNTRY-102 p104:SNTRY-104 p105:SNTRY-105 p107:SNTRY-107 \
p107L:SNTRY-107 p108:SNTRY-108 p108L:SNTRY-108 p109:SNTRY-109 p109L:SNTRY-109 p110:SNTRY-110 p110L:SNTRY-110"
routes
for mode in 403 html down; do
  for c in $DENY; do
    run "$WORK/blocks/${c%%:*}.sh" "$mode"
    only_blocked "${c%%:*} refused ($mode)" "${c#*:}"
  done
done

# A read after one that was answered is refused: still blocked, and no half verdict.
ENVS2="$(fx envs2.json '[{"name":"production"},{"name":"staging"}]')"
EMPTY="$(fx empty.json '[]')"
DETAIL_OK="$(fx detail-ok.json '{"slug":"your-project-slug","platform":"python","firstEvent":null,"dataScrubber":true,"dataScrubberDefaults":true,"sensitiveFields":["password"],"scrubIPAddresses":true,"scrapeJavaScript":false,"securityToken":"sectok-marker"}')"
routes '*/integrations/?provider_key=github' "$(fx gh.json '[{"id":"1","name":"gh","status":"active"}]')"
run "$WORK/blocks/p9.sh"; only_blocked "p9 code-mappings refused" SNTRY-009
routes '*/projects/your-org-slug/your-project-slug/rules/' "$EMPTY"
run "$WORK/blocks/p16L.sh"; only_blocked "p16L metric alert rules refused" SNTRY-016
run "$WORK/blocks/p110L.sh"; only_blocked "p110L metric alert rules refused" SNTRY-110
routes '*/projects/your-org-slug/your-project-slug/environments/' "$ENVS2"
run "$WORK/blocks/p102L.sh"; only_blocked "p102L rules refused" SNTRY-102
run "$WORK/blocks/p102.sh"; only_blocked "p102 alerts refused" SNTRY-102
routes '*/projects/your-org-slug/your-project-slug/' "$DETAIL_OK"
run "$WORK/blocks/p105.sh"; only_blocked "p105 filters refused" SNTRY-105
routes '*/projects/your-org-slug/your-js-project-slug/issues/*' "$(fx issues1.json '[{"id":"7"}]')"
run "$WORK/blocks/p20a.sh"; only_blocked "p20a latest event refused" SNTRY-020
# SNTRY-023 needs its raw stats file; a missing one is blocked, and so is a refused projects read.
rm -rf "$WORK/aud"
routes '*/organizations/your-org-slug/monitors/' "$EMPTY"
run "$WORK/blocks/p23.sh"; only_blocked "p23 stats-projects.json missing" SNTRY-023
RAW="$WORK/aud/sentry/$TODAY/raw"; mkdir -p "$RAW"
printf '%s\n' '{"groups":[{"by":{"project":5,"outcome":"accepted"},"totals":{"sum(quantity)":100}}]}' > "$RAW/stats-projects.json"
run "$WORK/blocks/p23.sh"; only_blocked "p23 projects refused" SNTRY-023
# SNTRY-003's drop count reads stats-outcomes.json from the raw dump; missing is blocked, not zero.
routes
run "$WORK/blocks/p3b.sh"; only_blocked "p3b stats-outcomes.json missing" "SNTRY-003 drop count"

# Answered reads: every check still gives its verdict, and project or key secrets stay unprinted.
routes '*/projects/your-org-slug/your-project-slug/' "$DETAIL_OK"
run "$WORK/blocks/p2.sh"; ok_exit p2; has p2 '^SNTRY-002 pass: your-project-slug$'; no_secret p2
routes '*/projects/your-org-slug/your-project-slug/' "$(fx detail-off.json '{"slug":"your-project-slug","dataScrubber":false,"dataScrubberDefaults":true,"sensitiveFields":[],"scrapeJavaScript":true,"securityToken":"sectok-marker"}')"
run "$WORK/blocks/p2.sh"; ok_exit p2; has p2 '^SNTRY-002 fail: your-project-slug$'; no_secret p2
routes '*/projects/your-org-slug/your-project-slug/keys/' "$(fx keys-ok.json '[{"name":"Default","isActive":true,"rateLimit":{"window":60,"count":100},"secret":"ks-marker","dsn":{"public":"dsn-marker"}}]')"
run "$WORK/blocks/p3.sh"; ok_exit p3; has p3 '^SNTRY-003 pass: your-project-slug$'; no_secret p3
routes '*/projects/your-org-slug/your-project-slug/keys/' "$(fx keys-open.json '[{"name":"Default","isActive":true,"rateLimit":null,"secret":"ks-marker","dsn":{"public":"dsn-marker"}}]')"
run "$WORK/blocks/p3.sh"; ok_exit p3; has p3 '^SNTRY-003 fail: your-project-slug$'; no_secret p3
printf '%s\n' '{"groups":[{"by":{"outcome":"rate_limited"},"totals":{"sum(quantity)":7}}]}' > "$RAW/stats-outcomes.json"
run "$WORK/blocks/p3b.sh"; ok_exit p3b; has p3b '^SNTRY-003 org-wide drops to rate_limited/abuse/cardinality in window: 7 events$'
routes '*/projects/your-org-slug/your-project-slug/environments/' "$ENVS2"
run "$WORK/blocks/p4.sh"; ok_exit p4; has p4 '^SNTRY-004 pass: your-project-slug$'
routes '*/integrations/?provider_key=github' "$WORK/fx/gh.json" \
       '*/organizations/your-org-slug/code-mappings/' "$(fx cm1.json '[{"id":"31","projectId":"11","repoId":"21","defaultBranch":"main","stackRoot":"src/","sourceRoot":"src/"}]')"
run "$WORK/blocks/p9.sh"; ok_exit p9; has p9 '^SNTRY-009 step 1 pass: ' ; has p9 '^SNTRY-009 step 2 pass: '
routes '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rules16.json '[{"id":"1","name":"Off rule","status":"disabled","actions":[{"id":"a"}],"conditions":[{"id":"c"}]}]')" \
       '*/organizations/your-org-slug/alert-rules/' "$EMPTY"
run "$WORK/blocks/p16L.sh"; ok_exit p16L; has p16L "^1${TAB}Off rule${TAB}status=disabled${TAB}actions=1${TAB}conditions=c$"
routes '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rules17.json '[{"id":"2","name":"Owner rule","actions":[{"targetType":"IssueOwners"}]}]')" \
       '*/projects/your-org-slug/your-project-slug/ownership/' "$(fx own.json '{"raw":"","fallthrough":false}')"
run "$WORK/blocks/p17L.sh"; ok_exit p17L; has p17L "^2${TAB}Owner rule${TAB}targetType=IssueOwners$"; has p17L '"raw_empty": true'
routes '*/stats_v2/*groupBy=reason*' "$(fx reason.json '{"groups":[{"by":{"reason":"spike_protection","outcome":"rate_limited"},"totals":{"sum(quantity)":5}},{"by":{"reason":"key_quota","outcome":"rate_limited"},"totals":{"sum(quantity)":2}}]}')"
run "$WORK/blocks/p19.sh"; ok_exit p19; has p19 '^SNTRY-019: rate_limited drops in window .* spike_protection=5, other \(key/cardinality quota\)=2$'
run "$WORK/blocks/p104.sh"; ok_exit p104; has p104 '^SNTRY-104 pass: spike protection is live \(dropped 5 events'
routes '*/projects/your-org-slug/your-js-project-slug/issues/*' "$WORK/fx/issues1.json" \
       '*/organizations/your-org-slug/issues/7/events/latest/' "$(fx event.json '{"errors":[{"type":"js_no_source","message":"Source code was not found"}]}')"
run "$WORK/blocks/p20a.sh"; ok_exit p20a; has p20a '^SNTRY-020 fail: js_no_source .* Source code was not found'
routes '*/projects/your-org-slug/your-js-project-slug/files/artifact-bundles/' "$(fx bundles.json '[{"bundleId":"b1","dateModified":"2026-10-01T00:00:00Z"}]')"
run "$WORK/blocks/p20b.sh"; ok_exit p20b; has p20b '^SNTRY-020 upload-pipeline pass: 1 artifact bundle'
routes '*/organizations/your-org-slug/repos/' "$(fx repos.json '[{"id":"1","name":"origin","provider":{"id":"unknown"}},{"id":"2","name":"svc","provider":{"id":"integrations:github"}}]')"
run "$WORK/blocks/p21.sh"; ok_exit p21; has p21 '^SNTRY-021 fail: repo origin \(id=1\) has provider.id=unknown'; hasnt p21 'repo svc'
routes '*/organizations/your-org-slug/monitors/' "$EMPTY" \
       '*/organizations/your-org-slug/projects/' "$(fx projects23.json '[{"id":"5","slug":"api","platform":"python"},{"id":"6","slug":"web","platform":"javascript-react"}]')"
run "$WORK/blocks/p23.sh"; ok_exit p23; has p23 '^SNTRY-023 info: 0 monitors exist; backend project api accepted 100 events'; hasnt p23 'project web'
routes '*/organizations/your-org-slug/monitors/' "$(fx monitors1.json '[{"id":"m1"}]')"
run "$WORK/blocks/p23.sh"; ok_exit p23; has p23 '^SNTRY-023 not-in-scope: 1 monitor'
routes '*/projects/your-org-slug/your-project-slug/' "$DETAIL_OK"
run "$WORK/blocks/p24.sh"; ok_exit p24; has p24 '^SNTRY-024: your-project-slug never instrumented'; no_secret p24
routes '*/projects/your-org-slug/your-project-slug/environments/' "$(fx envs-syn.json '[{"name":"prod"},{"name":"production"}]')"
run "$WORK/blocks/p25.sh"; ok_exit p25; has p25 '^SNTRY-025 fail: synonym collision'
routes '*/projects/your-org-slug/your-project-slug/' "$DETAIL_OK" \
       '*/projects/your-org-slug/your-project-slug/filters/' "$(fx filters.json '[{"id":"web-crawlers","active":true},{"id":"filtered-transaction","active":true}]')"
run "$WORK/blocks/p105.sh"; ok_exit p105; has p105 '^SNTRY-105 pass: your-project-slug .*platform=python'; no_secret p105

# Alerts API shapes: one issue-stream monitor and the issue alerts attached to it.
DET="$(fx det.json '[{"id":"d1","type":"issue_stream","projectId":"1","enabled":true,"workflowIds":[]}]')"
WF_ENVNULL="$(fx wf-envnull.json '[{"id":"w1","name":"Every env","environment":null,"enabled":true,"detectorIds":["d1"],"triggers":{"conditions":[]},"actionFilters":[{"conditions":[{"type":"event_frequency_count","comparison":{"value":5,"interval":"5m"}}],"actions":[{"type":"email","config":{"targetType":"issue_owners"}}]}],"config":{"frequency":30},"lastTriggered":null,"owner":null}]')"
routes '*/projects/your-org-slug/your-project-slug/environments/' "$ENVS2" '*/workflows/?project=*' "$WF_ENVNULL" '*/detectors/?project=*' "$DET"
run "$WORK/blocks/p102.sh"; ok_exit p102; has p102 '^SNTRY-102 fail: your-project-slug'
routes '*/projects/your-org-slug/your-project-slug/environments/' "$(fx envs1.json '[{"name":"production"}]')"
run "$WORK/blocks/p102.sh"; ok_exit p102; has p102 '^SNTRY-102 n/a: your-project-slug has 1 environment'
routes '*/projects/your-org-slug/your-project-slug/environments/' "$ENVS2" \
       '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rules102.json '[{"actions":[{"id":"a"}],"environment":"production"}]')"
run "$WORK/blocks/p102L.sh"; ok_exit p102L; has p102L '^SNTRY-102 pass: your-project-slug$'
routes '*/projects/your-org-slug/your-project-slug/issues/*' "$(fx chronic.json '[{"shortId":"PROJ-1","count":"30000","firstSeen":"2026-06-24T00:00:00Z","substatus":"ongoing"}]')" \
       '*/workflows/?project=*' "$WF_ENVNULL" '*/detectors/?project=*' "$DET"
run "$WORK/blocks/p107.sh"; ok_exit p107; has p107 "^PROJ-1${TAB}events=30000${TAB}"; has p107 '^un-gated re-paging rules: 1;'
routes '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rules110.json '[{"owner":null},{"owner":"team:1"}]')" \
       '*/organizations/your-org-slug/alert-rules/' "$(fx metric110.json '[{"owner":"team:2"}]')"
run "$WORK/blocks/p110L.sh"; ok_exit p110L; has p110L '^SNTRY-110: your-project-slug unowned issue rules=1; org unowned metric alerts=0$'; has p110L '^SNTRY-110 fail'

# ---- (b) SNTRY-108: environment claims are whole words, on both branches --------------------------
# name / environment / channel: a correct non-prod scope, a "product" name, a "- Dev" rule scoped to
# production, a "- Prod" rule with no environment, a correct production scope, and a pre-prod channel
# rule scoped to production.
wf108() { printf '{"id":"%s","name":"%s","environment":%s,"enabled":true,"detectorIds":["d1"],"triggers":{"conditions":[{"type":"first_seen_event"}]},"actionFilters":[{"conditions":[],"actions":[{"type":"slack","config":{"targetDisplay":"%s","targetIdentifier":"C01"}}]}],"config":{"frequency":30},"lastTriggered":null,"owner":null}' "$1" "$2" "$3" "$4"; }
rl108() { printf '{"id":"%s","name":"%s","environment":%s,"actions":[{"id":"sentry.integrations.slack.notify_action.SlackNotifyServiceAction","channel":"%s"}]}' "$1" "$2" "$3" "$4"; }
for shape in wf108 rl108; do
  set -- 1 "Staging errors" '"staging"' "#errors-team"  2 "Product search" '"staging"' "#search-team" \
         3 "Checkout errors - Dev" '"production"' "#checkout-team"  4 "Payments - Prod" null "#payments-team" \
         5 "Billing - Production" '"production"' "#billing-team"  6 "Search alerts" '"production"' "#search-pre-prod"
  json="["; sep=""
  while [ $# -ge 4 ]; do json="${json}${sep}$($shape "$1" "$2" "$3" "$4")"; sep=","; shift 4; done
  json="${json}]"
  if [ "$shape" = wf108 ]; then
    routes '*/workflows/?project=*' "$(fx wf108.json "$json")" '*/detectors/?project=*' "$DET"; b=p108
  else
    routes '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rl108.json "$json")"; b=p108L
  fi
  run "$WORK/blocks/$b.sh"; ok_exit "$b"
  hasnt "$b correct non-prod scope" 'Staging errors'
  hasnt "$b product is not prod" 'Product search'
  has "$b dev rule scoped to production" '^SNTRY-108: Checkout errors - Dev claims non-prod \(name/channel\) but environment=production$'
  has "$b prod rule with no environment" '^SNTRY-108: Payments - Prod claims production \(name/channel\) but environment=null$'
  hasnt "$b correct production scope" 'Billing - Production'
  has "$b pre-prod channel scoped to production" '^SNTRY-108: Search alerts claims non-prod \(name/channel\) but environment=production$'
done

# ---- (c) SNTRY-109: enabled, never fired, and snoozed or a keyword re-notifying below the floor ----
wf109() { printf '{"id":"%s","name":"%s","environment":"production","enabled":%s,"detectorIds":["d1"],"triggers":{"conditions":[{"type":"first_seen_event"}]},"actionFilters":[{"conditions":%s,"actions":[{"type":"email","config":{"targetType":"issue_owners"}}]}],"config":{"frequency":%s},"lastTriggered":%s,"owner":null}' "$1" "$2" "$3" "$4" "$5" "$6"; }
KW_ERR='[{"type":"event_attribute","comparison":{"attribute":"message","match":"co","value":"error"}}]'
KW_TIMEOUT='[{"type":"event_attribute","comparison":{"attribute":"message","match":"co","value":"timeout"}}]'
routes '*/workflows/?project=*' "$(fx wf109.json "[$(wf109 w1 'Disabled keyword alert' false "$KW_ERR" 5 null),$(wf109 w2 'Timeout spam alert' true "$KW_TIMEOUT" 5 null),$(wf109 w3 'Slow keyword alert' true "$KW_ERR" 60 null),$(wf109 w4 'Fired keyword alert' true "$KW_ERR" 5 '"2026-10-01T00:00:00Z"'),$(wf109 w5 'Plain new-issue alert' true '[]' 5 null)]")" \
       '*/detectors/?project=*' "$DET"
run "$WORK/blocks/p109.sh"; ok_exit p109
hasnt "p109 disabled alert is SNTRY-016's" 'Disabled keyword alert'
has "p109 keyword re-notifying below the floor" '^SNTRY-109 dead-weight: Timeout spam alert '
hasnt "p109 keyword at or above the floor" 'Slow keyword alert'
hasnt "p109 alert that fired" 'Fired keyword alert'
hasnt "p109 alert with no keyword" 'Plain new-issue alert'
rl109() { printf '{"id":"%s","name":"%s","status":"%s","snooze":%s,"lastTriggered":null,"frequency":%s,"conditions":[],"filters":%s,"actions":[{"id":"a"}]}' "$1" "$2" "$3" "$4" "$5" "$6"; }
F_ERR='[{"id":"sentry.rules.filters.event_attribute.EventAttributeFilter","attribute":"message","match":"co","value":"error"}]'
F_TIMEOUT='[{"id":"sentry.rules.filters.event_attribute.EventAttributeFilter","attribute":"message","match":"co","value":"timeout"}]'
F_STATUS='[{"id":"sentry.rules.filters.event_attribute.EventAttributeFilter","attribute":"http.status_code","match":"sw","value":5}]'
routes '*/projects/your-org-slug/your-project-slug/rules/' "$(fx rl109.json "[$(rl109 1 'Disabled legacy rule' disabled false 5 "$F_ERR"),$(rl109 2 'Snoozed legacy rule' active true 30 '[]'),$(rl109 3 'Timeout legacy rule' active false 5 "$F_TIMEOUT"),$(rl109 4 'Slow legacy rule' active false 60 "$F_ERR"),$(rl109 5 'Status code legacy rule' active false 5 "$F_STATUS")]")"
run "$WORK/blocks/p109L.sh"; ok_exit p109L
hasnt "p109L disabled rule is SNTRY-016's" 'Disabled legacy rule'
has "p109L snoozed rule" '^SNTRY-109 dead-weight: Snoozed legacy rule \(never fired; snoozed\)$'
has "p109L keyword re-notifying below the floor" '^SNTRY-109 dead-weight: Timeout legacy rule '
hasnt "p109L keyword at or above the floor" 'Slow legacy rule'
hasnt "p109L numeric filter value" 'Status code legacy rule'

# ---- (d) SNTRY-022: each offending mapping prints, and the verdict is machine-checkable ------------
cmrow() { printf '{"id":"%s","projectId":"%s","repoId":"%s","stackRoot":"%s","sourceRoot":"src/"}' "$1" "$2" "$3" "$4"; }
routes '*/organizations/your-org-slug/code-mappings/' "$(fx cm-dup.json "[$(cmrow 31 11 21 src/),$(cmrow 32 11 21 src/./),$(cmrow 33 12 22 app/)]")"
run "$WORK/blocks/p22.sh"; ok_exit p22
has "p22 duplicate row" '^SNTRY-022 duplicate: mapping 31 project 11 repo 21 stackRoot "src/"$'
has "p22 duplicate row" '^SNTRY-022 duplicate: mapping 32 project 11 repo 21 stackRoot "src/\./"$'
has "p22 duplicate verdict" '^SNTRY-022 fail: 1 duplicate group\(s\), 0 build-host stackRoot\(s\), 0 over-routed'
hasnt "p22 duplicate verdict" '^SNTRY-022 pass'
routes '*/organizations/your-org-slug/code-mappings/' "$(fx cm-clean.json "[$(cmrow 31 11 21 src/),$(cmrow 33 12 22 app/)]")"
run "$WORK/blocks/p22.sh"; ok_exit p22
has "p22 clean set" '^SNTRY-022 pass: 2 code mapping'
hasnt "p22 clean set" '^SNTRY-022 (duplicate|build-host|over-routed|fail)'
routes '*/organizations/your-org-slug/code-mappings/' "$(fx cm-host.json "[$(cmrow 41 13 23 /tmp/build/src/),$(cmrow 42 13 23 a/),$(cmrow 43 13 23 b/),$(cmrow 44 13 23 c/),$(cmrow 45 13 23 d/),$(cmrow 46 13 23 e/)]")"
run "$WORK/blocks/p22.sh"; ok_exit p22
has "p22 build-host row" '^SNTRY-022 build-host: mapping 41 project 13 repo 23 stackRoot "/tmp/build/src/"$'
has "p22 over-routed row" '^SNTRY-022 over-routed: project 13 routes 6 mappings into repo 23 \(ceiling 5\)'
has "p22 build-host verdict" '^SNTRY-022 fail: 0 duplicate group\(s\), 1 build-host stackRoot\(s\), 1 over-routed'

# ---- (e) Phase 1 and the large-org worklist -------------------------------------------------------
printf 'sentry:\n  host: sentry.example.com\n  org: example-org\n  token_env: SENTRY_TOKEN\n  tier: read-only\n' > "$WORK/toolkit.yaml"
KEYS_SECRET="$(fx keys-secret.json '[{"name":"Default","isActive":true,"rateLimit":null,"secret":"ks-marker","dsn":{"public":"dsn-marker"}}]')"
DETAIL_TOKEN="$(fx detail-token.json '{"slug":"p","id":"1","platform":"python","securityToken":"sectok-marker"}')"
ORG_ROUTES="*/organizations/example-org/teams/ $EMPTY */organizations/example-org/integrations/ $EMPTY
*/organizations/example-org/repos/ $EMPTY */organizations/example-org/code-mappings/ $EMPTY
*/organizations/example-org/releases/ $EMPTY */organizations/example-org/monitors/ $EMPTY
*/organizations/example-org/workflows/ $EMPTY */organizations/example-org/detectors/ $EMPTY
*/organizations/example-org/available-actions/ $EMPTY */organizations/example-org/alert-rules/ $EMPTY
*/organizations/example-org/ $(fx org.json '{"slug":"example-org","name":"Example"}')
*/stats_v2/* $(fx stats-empty.json '{"groups":[]}')"
# Small path, alerts API: gamma's keys read and alpha's detail read are refused; beta answers.
rm -rf "$WORK/aud"; RAW="$WORK/aud/sentry/$TODAY/raw"
set -f   # $ORG_ROUTES splits into glob/fixture pairs; never expand them against files
routes '*/organizations/example-org/projects/' "$(fx projects-e.json '[{"slug":"gamma","id":"3"},{"slug":"alpha","id":"1"},{"slug":"beta","id":"2"}]')" \
       $ORG_ROUTES \
       '*/projects/example-org/gamma/' "$DETAIL_TOKEN" '*/projects/example-org/gamma/environments/' "$ENVS2" \
       '*/projects/example-org/alpha/environments/' "$ENVS2" '*/projects/example-org/alpha/keys/' "$KEYS_SECRET" \
       '*/projects/example-org/beta/' "$DETAIL_TOKEN" '*/projects/example-org/beta/environments/' "$ENVS2" \
       '*/projects/example-org/beta/keys/' "$KEYS_SECRET"
set +f
run "$WORK/blocks/phase1.sh"; ok_exit "phase1 small path"
grep -qxF "keys:gamma${TAB}403 application/json" "$RAW/blocked-reads.tsv" 2>/dev/null || fail "phase1: refused keys read for gamma is not in blocked-reads.tsv"
grep -qxF "detail:alpha${TAB}403 application/json" "$RAW/blocked-reads.tsv" 2>/dev/null || fail "phase1: refused detail read for alpha is not in blocked-reads.tsv"
[ ! -e "$RAW/projects/gamma/keys.json" ] || fail "phase1: a failed keys read was stored as $(cat "$RAW/projects/gamma/keys.json")"
[ ! -e "$RAW/projects/alpha/detail.json" ] || fail "phase1: a failed detail read left a detail.json"
for f in gamma/detail.json gamma/environments.json alpha/environments.json alpha/keys.json beta/detail.json beta/environments.json beta/keys.json; do
  [ -s "$RAW/projects/$f" ] || fail "phase1: $f is missing; the loop stopped at a refused read"
done
jq -e 'map(keys) | all(. == ["isActive", "name", "rateLimit"])' "$RAW/projects/beta/keys.json" >/dev/null 2>&1 || fail "phase1: keys.json holds more than name, isActive, rateLimit"
no_secret "phase1 small path" "$WORK/aud"
# Small path, legacy fallback: alpha's rules read and every uptime read are refused.
rm -rf "$WORK/aud"
set -f   # $ORG_ROUTES splits into glob/fixture pairs; never expand them against files
routes '*/organizations/example-org/projects/' "$(fx projects-l.json '[{"slug":"alpha","id":"1"},{"slug":"beta","id":"2"}]')" \
       $ORG_ROUTES \
       '*/projects/example-org/alpha/' "$DETAIL_TOKEN" '*/projects/example-org/alpha/environments/' "$ENVS2" '*/projects/example-org/alpha/keys/' "$KEYS_SECRET" \
       '*/projects/example-org/beta/' "$DETAIL_TOKEN" '*/projects/example-org/beta/environments/' "$ENVS2" '*/projects/example-org/beta/keys/' "$KEYS_SECRET" \
       '*/projects/example-org/beta/rules/' "$EMPTY"
set +f
run "$WORK/blocks/phase1L.sh"; ok_exit "phase1 legacy"
for row in "rules:alpha" "uptime:alpha" "uptime:beta"; do
  grep -qxF "${row}${TAB}403 application/json" "$RAW/blocked-reads.tsv" 2>/dev/null || fail "phase1 legacy: refused ${row} read is not in blocked-reads.tsv"
done
[ -s "$RAW/projects/beta/rules.json" ] || fail "phase1 legacy: beta/rules.json is missing; the loop stopped at alpha's refused rules read"
[ ! -e "$RAW/projects/alpha/rules.json" ] || fail "phase1 legacy: a failed rules read left a rules.json"

# Large path, step 3: checkout's detail and keys reads are refused; both projects still complete.
rm -rf "$WORK/aud"
RUN_DIR="$WORK/aud/sentry/runs/20260717T140500Z"; mkdir -p "$RUN_DIR/raw/projects"
printf 'checkout\tpending\npayments\tpending\nsearch\tpending\n' > "$RUN_DIR/worklist.tsv"
routes '*/projects/your-org-slug/checkout/environments/' "$ENVS2" \
       '*/projects/your-org-slug/payments/' "$DETAIL_TOKEN" '*/projects/your-org-slug/payments/environments/' "$ENVS2" \
       '*/projects/your-org-slug/payments/keys/' "$KEYS_SECRET"
run "$WORK/blocks/step3.sh"; ok_exit "worklist step 3"
for row in "checkout${TAB}done" "payments${TAB}done" "search${TAB}pending"; do
  grep -qxF "$row" "$RUN_DIR/worklist.tsv" || fail "worklist step 3: expected row '$row' in worklist.tsv ($(tr '\n' ' ' < "$RUN_DIR/worklist.tsv"))"
done
for row in "detail:checkout" "keys:checkout"; do
  grep -qxF "${row}${TAB}403 application/json" "$RUN_DIR/raw/blocked-reads.tsv" 2>/dev/null || fail "worklist step 3: refused ${row} read is not in the run's blocked-reads.tsv"
done
[ ! -e "$RUN_DIR/raw/projects/checkout/keys.json" ] || fail "worklist step 3: a failed keys read was stored as $(cat "$RUN_DIR/raw/projects/checkout/keys.json")"
[ -s "$RUN_DIR/raw/projects/payments/keys.json" ] || fail "worklist step 3: payments/keys.json is missing"
no_secret "worklist step 3" "$RUN_DIR"
# Step 4 carries the run's blocked reads into the merged raw dir.
printf 'checkout\tdone\npayments\tdone\n' > "$RUN_DIR/worklist.tsv"
printf '%s\n' '[{"slug":"checkout","id":"1"},{"slug":"payments","id":"2"}]' > "$RUN_DIR/raw/projects.json"
routes
run "$WORK/blocks/step4.sh"; ok_exit "worklist step 4"
grep -qxF "keys:checkout${TAB}403 application/json" "$RAW/worklist-blocked-reads.tsv" 2>/dev/null || fail "worklist step 4: the run's blocked reads were not carried into the merged raw dir"
# Then Phase 1 on the large path (its per-project loop skipped) lists them in blocked-reads.tsv.
awk 'skip == 0 && (index($0, "rm -f \"${RAW_DIR}/worklist-blocked-reads.tsv\"") == 1 || index($0, "for p in $(jq -r") == 1) { skip = 1; next }
     skip == 1 { if ($0 == "done") skip = 2; next }
     { print }' "$WORK/blocks/phase1.sh" > "$WORK/blocks/phase1-large.sh"
if grep -q 'for p in \$(jq -r' "$WORK/blocks/phase1-large.sh"; then echo "FAIL: could not skip the Phase 1 per-project loop" >&2; exit 1; fi
set -f   # $ORG_ROUTES splits into glob/fixture pairs; never expand them against files
routes '*/organizations/example-org/projects/' "$WORK/fx/projects-l.json" $ORG_ROUTES
set +f
run "$WORK/blocks/phase1-large.sh"; ok_exit "phase1 large path"
for row in "detail:checkout" "keys:checkout"; do
  grep -qxF "${row}${TAB}403 application/json" "$RAW/blocked-reads.tsv" 2>/dev/null || fail "phase1 large path: the worklist's refused ${row} read is not in blocked-reads.tsv"
done

if [ "$FAILS" -gt 0 ]; then echo "REFUSED-READS-AND-VERDICTS-FAILED ($FAILS failed assertions)" >&2; exit 1; fi
echo "REFUSED-READS-AND-VERDICTS-OK (refused reads print blocked on every changed check and branch; answered reads keep their verdicts; SNTRY-108 word claims, SNTRY-109 floor and disabled exclusion, SNTRY-022 rows; Phase 1 and the worklist record refused project reads and carry on)"
