#!/bin/sh
# test-uptime-restore-verify-agegate.sh: runs setup-sentry's uptime, restore, bulk-verify, cron
# rollback, and age-gate blocks, as written, against a fake Sentry (a stand-in curl first on PATH;
# nothing leaves this machine; each block runs with stdin closed) and asserts that:
#   1. the uptime create sends the alerts-API monitor body (type, dataSources, config.environment)
#      and prints the id; its rollback refuses a monitor of the wrong type or name, and calls it
#      gone only on the JSON "does not exist" 404, never a bare 404, on both alert APIs;
#   2. every restore refuses a backup that is missing, empty, not JSON, or the wrong JSON type, and
#      one its edit cannot apply to, with no write sent; a good backup sends exactly one write;
#   3. the bulk verify runs one check per rule (CHANGE=updated|deleted), exits nonzero when the PUT
#      assertion fails, proves a delete only by the JSON 404 on both APIs, and refuses any other
#      CHANGE and an unfilled rule id;
#   4. the cron rollback refuses a monitor whose slug or name differs, and needs the JSON 404;
#   5. the age gate refuses a filter whose logic is not all, a TARGET_ENV the project lacks, and an
#      alert on no monitor of PROJECT (legacy: a filterMatch other than all, a regression condition),
#      with no write; its apply path sends exactly one PUT and its verify finds the gate by filter id.
# Every failed assertion is reported; the suite exits 1 if any failed.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/skills/setup-sentry/SKILL.md"
COOKBOOK="$ROOT/skills/setup-sentry/references/api-cookbook.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required" >&2; exit 1; }
STATE="$WORK/state"
: > "$WORK/failures"
fail() { echo "FAIL: $1" | tr "\n" " " >&2; echo >&2; echo x >> "$WORK/failures"; }

# Fake curl. A GET answers from $STUB_DIR/fx/<key>.body (+ .code), where <key> is the method and
# path with every other character turned into "_"; a path with no fixture answers a bare 404. Every
# request is logged. A PUT, POST, or DELETE is also logged as a write with its body: a PUT becomes
# what the next GET of that path answers (or <key>.after when the test set one), a POST answers its
# body plus "id":"4242" and becomes the GET of <path>4242/, and after a DELETE the next GET of that
# path answers per $STUB_DIR/gone: json404 (the default), bare404, or still. -f, -o, and -w behave
# like curl's.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
method=GET; url=""; data=""; out=""; wfmt=""; fail=0; skip=""
for a in "$@"; do
  if [ -n "$skip" ]; then
    case "$skip" in -X) method="$a" ;; -d|--data|--data-binary) data="$a" ;; -o) out="$a" ;; -w) wfmt="$a" ;; esac
    skip=""; continue
  fi
  case "$a" in
    -X|-d|--data|--data-binary|-o|-w|-H|--max-time|-D) skip="$a" ;;
    http://*|https://*) url="$a" ;;
    --*) : ;;
    -*f*) fail=1 ;;
  esac
done
[ "$data" = "@-" ] && data="$(cat)"
path="$(printf '%s' "$url" | sed 's#^https*://[^/]*##')"
key() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_'; }
fx="$STUB_DIR/fx"
respond() { # respond <body> <code> <content type>
  wout=""
  [ -z "$wfmt" ] || wout="$(printf '%s' "$wfmt" | sed -e "s/%{http_code}/$2/g" -e "s#%{content_type}#$3#g")"
  if [ "$fail" = 1 ] && [ "$2" -ge 400 ]; then
    echo "curl: (22) The requested URL returned error: $2" >&2
    [ -z "$wout" ] || printf '%b' "$wout"
    exit 22
  fi
  if [ -n "$out" ]; then [ "$out" = /dev/null ] || printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi
  [ -z "$wout" ] || printf '%b' "$wout"
  exit 0
}
printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/requests.log"
get="$(key GET "$path")"
if [ "$method" != GET ]; then
  printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/writes.log"
  printf '%s' "$data" > "$STUB_DIR/last-body.json"
  case "$method" in
    PUT)
      if [ -f "$fx/$get.after" ]; then cp "$fx/$get.after" "$fx/$get.body"; else printf '%s' "$data" > "$fx/$get.body"; fi
      rm -f "$fx/$get.code"
      respond "$data" 200 application/json ;;
    POST)
      created="$(printf '%s' "$data" | jq -c '(if type == "object" then . else {} end) + {id: "4242"}' 2>/dev/null || true)"
      [ -n "$created" ] || created='{"id":"4242"}'
      new="$(key GET "${path}4242/")"
      [ -f "$fx/$new.body" ] || printf '%s' "$created" > "$fx/$new.body"
      respond "$created" 201 application/json ;;
    *)
      : > "$STUB_DIR/deleted.$get"
      respond '' 204 '' ;;
  esac
fi
if [ -f "$STUB_DIR/deleted.$get" ]; then
  case "$(cat "$STUB_DIR/gone" 2>/dev/null || echo json404)" in
    bare404) respond '' 404 '' ;;
    still) : ;;
    *) respond '{"detail":"The requested resource does not exist"}' 404 application/json ;;
  esac
fi
if [ -f "$fx/$get.body" ]; then
  code=200; [ ! -f "$fx/$get.code" ] || code="$(cat "$fx/$get.code")"
  respond "$(cat "$fx/$get.body")" "$code" application/json
fi
printf 'GET %s\n' "$path" >> "$STUB_DIR/unknown.log"
respond '' 404 ''
STUB
chmod +x "$WORK/bin/curl"

fxkey() { printf '%s %s' "$1" "$2" | tr -c 'A-Za-z0-9' '_'; }
fixture() { # fixture <path> <body> [code]: the stub answers GET <path> with <body>
  printf '%s' "$2" > "$STATE/fx/$(fxkey GET "$1").body"
  if [ -n "${3:-}" ]; then printf '%s' "$3" > "$STATE/fx/$(fxkey GET "$1").code"; fi
}
after_put() { # after_put <path> <body>: the GET after a PUT to <path> answers <body>
  printf '%s' "$2" > "$STATE/fx/$(fxkey GET "$1").after"
}
gone_mode() { printf '%s' "$1" > "$STATE/gone"; }
reset() {
  rm -rf "$STATE" "$WORK/home" "$WORK/out" "$WORK/backup.json"
  mkdir -p "$STATE/fx" "$WORK/home"
  : > "$STATE/requests.log"; : > "$STATE/writes.log"; : > "$STATE/unknown.log"
}
nwrites() { wc -l < "$STATE/writes.log" | tr -d ' '; }
nrequests() { wc -l < "$STATE/requests.log" | tr -d ' '; }
first_write() { head -1 "$STATE/writes.log"; }

# Every bash block in SKILL.md or the cookbook that contains <marker>, exactly as written, goes to
# $WORK/blocks/<name>.<n>.sh; prints how many there were.
mkdir -p "$WORK/blocks"
extract() { # extract <marker> <name>
  awk -v out="$WORK/blocks/$2" -v marker="$1" '
    /^```bash/ { b = ""; inb = 1; next }
    /^```/     { if (inb && index(b, marker)) { k++; print b > (out "." k ".sh") } inb = 0; next }
    inb        { b = b $0 "\n" }
    END { print k + 0 }' "$SKILL" "$COOKBOOK"
}

# prep <block> <alert api> [sed args]: fill every <...> placeholder, pick the alert API, and apply
# any extra edits, into $WORK/run.sh.
prep() {
  src="$1"; api="$2"; shift 2
  sed -e "s|^SENTRY_ALERT_API=\"workflows\"|SENTRY_ALERT_API=\"$api\"|" \
      -e 's|"<project-slug>"|"checkout"|g' -e 's|"<rule-id>"|"12345678"|g' -e 's|"<key-id>"|"k1"|g' \
      -e 's|"<metric-alert-id>"|"12345678"|g' -e "s|\"<backup-path>\"|\"$WORK/backup.json\"|g" \
      -e 's|^BACKUP_DATE="YYYY-MM-DD"|BACKUP_DATE="2026-01-01"|' \
      -e 's|^CHECK_ID="<uptime-check-id>"|CHECK_ID="4242"|' \
      -e 's|^CHECK_NAME="<uptime-check-name>"|CHECK_NAME="API health check"|' \
      -e 's|^MONITOR_SLUG="<monitor-slug>"|MONITOR_SLUG="nightly-data-sync"|' \
      "$@" "$src" > "$WORK/run.sh"
}

# run: run $WORK/run.sh in a fresh sh, stdin closed, against the fake Sentry; sets RC.
run() {
  set +e
  ( cd "$WORK" && HOME="$WORK/home" SCOUTFLO_ENV_FILE= SCOUTFLO_CONFIG= SCOUTFLO_TARGET= SCOUTFLO_AUDIT_DIR="$WORK/out" STUB_DIR="$STATE" \
      PATH="$WORK/bin:$PATH" SENTRY_TOKEN="example-not-a-secret" sh "$WORK/run.sh" ) \
    > "$WORK/stdout" 2> "$WORK/stderr" <&-
  RC=$?
  set -e
}

# refused <label> [reason]: the block exited nonzero, sent no write, and (when given) said why.
refused() {
  [ "$RC" -ne 0 ] || fail "$1: exited 0"
  [ "$(nwrites)" -eq 0 ] || fail "$1: sent a write: $(tr '\n' ' ' < "$STATE/writes.log")"
  if [ -n "${2:-}" ]; then
    grep -qF "$2" "$WORK/stderr" || fail "$1: did not refuse for the expected reason ($2): $(tail -1 "$WORK/stderr")"
  fi
}
# applied <label> <write line>: the block exited 0 and sent exactly that one write.
applied() {
  [ "$RC" -eq 0 ] || fail "$1: exited $RC: $(tail -1 "$WORK/stderr")"
  [ "$(nwrites)" -eq 1 ] || fail "$1: expected exactly one write, got $(nwrites): $(tr '\n' ' ' < "$STATE/writes.log")"
  [ "$(first_write)" = "$2" ] || fail "$1: expected '$2', got '$(first_write)'"
}
outhas() { grep -qF "$2" "$WORK/stdout" || fail "$1: stdout lacks '$2': $(tr '\n' ' ' < "$WORK/stdout")"; }
outlacks() { if grep -qF "$2" "$WORK/stdout" "$WORK/stderr"; then fail "$1: printed '$2'"; fi; }

ORG="/api/0/organizations/your-org-slug"
PROJ="/api/0/projects/your-org-slug/checkout"
# 1) uptime monitor: create on both APIs, then the guarded rollback
[ "$(extract 'UPTIME_INTERVAL_S=' uptime-create)" -eq 1 ] || fail "expected one uptime create block"
[ "$(extract 'CHECK_ID="<uptime-check-id>"' uptime-rollback)" -eq 1 ] || fail "expected one uptime rollback block"
UC="$WORK/blocks/uptime-create.1.sh"; UR="$WORK/blocks/uptime-rollback.1.sh"
DETECTOR='{"id":"4242","type":"uptime_domain_failure","name":"API health check","enabled":true,"dataSources":[{"queryObj":{"url":"https://api.example.com/health","intervalSeconds":300}}]}'
if [ -f "$UC" ]; then
  for env in none production; do
    reset; fixture "$ORG/detectors/4242/" "$DETECTOR"
    if [ "$env" = none ]; then prep "$UC" workflows; else prep "$UC" workflows -e 's|^UPTIME_ENV=""|UPTIME_ENV="production"|'; fi
    run
    applied "uptime create (alerts API, environment $env)" "POST $ORG/projects/checkout/detectors/"
    outhas "uptime create (alerts API)" "created uptime monitor: 4242"
    want='null'; [ "$env" = none ] || want='"production"'
    jq -e --argjson env "$want" '.type == "uptime_domain_failure" and .name == "API health check"
        and (.config | has("environment")) and .config.environment == $env
        and .config.downtimeThreshold == 3 and .config.recoveryThreshold == 1
        and (.dataSources | length) == 1 and .dataSources[0].url == "https://api.example.com/health"
        and .dataSources[0].intervalSeconds == 300 and .dataSources[0].timeoutMs == 5000
        and .dataSources[0].method == "GET" and .dataSources[0].traceSampling == false
        and .dataSources[0].responseCaptureEnabled == true' "$STATE/last-body.json" > /dev/null 2>&1 \
      || fail "uptime create (alerts API, environment $env): wrong detector body: $(tr -d "\n" < "$STATE/last-body.json")"
  done
  # no free uptime seat: Sentry creates the monitor disabled, and the verify must fail
  reset; fixture "$ORG/detectors/4242/" "$(printf '%s' "$DETECTOR" | jq -c '.enabled = false')"
  prep "$UC" workflows; run
  [ "$RC" -ne 0 ] || fail "uptime create: verify passed on a monitor created with enabled false"
  reset; prep "$UC" legacy; run
  applied "uptime create (legacy)" "POST $PROJ/uptime/"
  outhas "uptime create (legacy)" "created uptime monitor: 4242"
fi
if [ -f "$UR" ]; then
  reset; cp "$UR" "$WORK/run.sh"; run
  [ "$RC" -ne 0 ] && [ "$(nrequests)" -eq 0 ] || fail "uptime rollback: ran with its placeholders unfilled"
  for api in workflows legacy; do
    if [ "$api" = workflows ]; then p="$ORG/detectors/4242/"; else p="$PROJ/uptime/4242/"; fi
    reset; fixture "$p" "$DETECTOR"; prep "$UR" "$api"; run
    applied "uptime rollback ($api)" "DELETE $p"
    outhas "uptime rollback ($api)" "post-delete: 404"
    reset; fixture "$p" "$(printf '%s' "$DETECTOR" | jq -c '.name = "Checkout synthetic"')"; prep "$UR" "$api"; run
    refused "uptime rollback ($api, another monitor's name)" "not deleting"
    reset; fixture "$p" "$DETECTOR"; gone_mode bare404; prep "$UR" "$api"; run
    [ "$RC" -ne 0 ] || fail "uptime rollback ($api): a bare 404 after the delete was taken as proof"
  done
  reset; fixture "$ORG/detectors/4242/" "$(printf '%s' "$DETECTOR" | jq -c '.type = "metric_issue"')"; prep "$UR" workflows; run
  refused "uptime rollback (alerts API, a metric monitor with the same name)" "not deleting"
fi

# 2) restores: a bad backup never sends a write; a good one sends exactly one
OBJ='{"id":"12345678","name":"Send a notification for high priority issues","enabled":false,"createdBy":null,"environment":null,"owner":null,"config":{"frequency":30},"detectorIds":["111"],"triggers":{"id":"7","logicType":"any-short","conditions":[{"id":"8","type":"first_seen_event","comparison":true,"conditionResult":true}]},"actionFilters":[{"id":"9","logicType":"all","conditions":[{"id":"11","type":"level","comparison":{"level":40,"match":"gte"},"conditionResult":true}],"actions":[{"id":"10","type":"email","integrationId":null,"config":{"targetType":"issue_owners","targetIdentifier":null},"data":{"fallthroughType":"AllMembers"}}]}],"actionMatch":"any","filterMatch":"all","frequency":30,"conditions":[{"id":"sentry.rules.conditions.first_seen_event.FirstSeenEventCondition"}],"filters":[],"actions":[{"id":"sentry.mail.actions.NotifyEmailAction","targetType":"IssueOwners","fallthroughType":"AllMembers"}],"type":"metric_issue","conditionGroup":{"id":"5","logicType":"any","conditions":[{"id":"1","type":"gt","comparison":25,"conditionResult":75},{"id":"2","type":"gt","comparison":10,"conditionResult":50},{"id":"3","type":"lte","comparison":10,"conditionResult":0}]},"dataScrubber":true,"dataScrubberDefaults":true,"scrubIPAddresses":false,"scrapeJavaScript":true,"sensitiveFields":["customer_ssn"],"isActive":true,"rateLimit":null}'
write_backup() { # write_backup <file> <mode>
  mkdir -p "$(dirname "$1")"
  case "$2" in
    missing)  rm -f "$1" ;;
    empty)    : > "$1" ;;
    html)     printf '<html><body>Sign in</body></html>' > "$1" ;;
    null)     printf 'null' > "$1" ;;
    string)   printf '"12345678"' > "$1" ;;
    object)   printf '%s' "$OBJ" > "$1" ;;
    array)    printf '[%s]' "$OBJ" > "$1" ;;
    badentry) printf '[{"id":"12345678","name":"x","actionFilters":null}]' > "$1" ;;
  esac
}
n1="$(extract '"<backup-path>"' restore)"; n2="$(extract 'BACKUP_DATE="YYYY-MM-DD"' snapshot-restore)"
[ "$n1" -eq 5 ] || fail "expected 5 restore blocks that take a backup path, found $n1"
[ "$n2" -eq 2 ] || fail "expected 2 rule-set snapshot restore blocks, found $n2"
restores=0
for b in "$WORK"/blocks/restore.*.sh "$WORK"/blocks/snapshot-restore.*.sh; do
  [ -f "$b" ] || continue
  name="$(basename "$b" .sh)"
  apis="any-api"; grep -q '^SENTRY_ALERT_API=' "$b" && apis="workflows legacy"
  for api in $apis; do
    case "$name" in
      snapshot-*)
        good=array; bad="missing empty html null string object"
        bf="$WORK/home/.scoutflo/sentry-rules-backup-2026-01-01/workflows.json"
        [ "$api" = workflows ] || bf="$WORK/home/.scoutflo/sentry-rules-backup-2026-01-01/issue-rules-checkout.json"
        if [ "$api" = workflows ] && grep -q -- '-X POST' "$b"; then bad="$bad badentry"; fi ;;
      *)
        good=object; bad="missing empty html null string array"; bf="$WORK/backup.json" ;;
    esac
    for mode in $bad good; do
      [ "$mode" = good ] && mode="$good"
      reset; fixture "$ORG/alert-rules/12345678/" "$OBJ"; write_backup "$bf" "$mode"; prep "$b" "$api"; run
      restores=$((restores + 1))
      if [ "$mode" = "$good" ]; then
        [ "$RC" -eq 0 ] || fail "$name ($api): a good backup did not restore: $(tail -1 "$WORK/stderr")"
        [ "$(nwrites)" -eq 1 ] || fail "$name ($api): a good backup sent $(nwrites) writes, expected one"
        jq -e 'type == "object" and length > 0' "$STATE/last-body.json" > /dev/null 2>&1 \
          || fail "$name ($api): the restore body is not a non-empty JSON object: $(tr -d "\n" < "$STATE/last-body.json")"
      else
        refused "$name ($api, $mode backup)"
      fi
    done
  done
  # the legacy warning-tier restore also reads the current metric alert: an empty or null read
  # must stop it, never send an empty or partial PUT
  if grep -q 'alert-rules/${ALERT_RULE_ID}/' "$b"; then
    for cur in '' 'null'; do
      reset; fixture "$ORG/alert-rules/12345678/" "$cur"; write_backup "$WORK/backup.json" object; prep "$b" legacy; run
      refused "$name (legacy, current read '${cur:-empty}')"
    done
  fi
done

# 3) bulk verify: one check per rule, picked by CHANGE
[ "$(extract 'EXPECT_FREQ=' bulk-verify)" -eq 1 ] || fail "expected one bulk verify block"
BV="$WORK/blocks/bulk-verify.1.sh"
if [ -f "$BV" ]; then
  # an unfilled id must never yield a "gone (404)" line for a rule nobody named
  # (PROJECT is filled so only the rule-id refusal can stop it; the unfilled id's URL answers the JSON 404)
  reset; fixture "$ORG/workflows/<rule-id>/" '{"detail":"The requested resource does not exist"}' 404
  sed -e 's|^CHANGE="updated"|CHANGE="deleted"|' -e 's|"<project-slug>"|"checkout"|' "$BV" > "$WORK/run.sh"; run
  [ "$RC" -ne 0 ] && [ "$(nrequests)" -eq 0 ] || fail "bulk verify: ran with its rule id unfilled"
  for api in workflows legacy; do
    if [ "$api" = workflows ]; then p="$ORG/workflows/12345678/"; ok='{"id":"12345678","enabled":true,"config":{"frequency":1440}}'; bad='{"id":"12345678","enabled":true,"config":{"frequency":60}}'
    else p="$PROJ/rules/12345678/"; ok='{"id":"12345678","frequency":1440}'; bad='{"id":"12345678","frequency":60}'; fi
    reset; fixture "$p" "$ok"; prep "$BV" "$api" -e 's|^CHANGE="updated"|CHANGE="updated"|'; run
    [ "$RC" -eq 0 ] || fail "bulk verify ($api): a correctly updated rule failed: $(tr '\n' ' ' < "$WORK/stderr")"
    outhas "bulk verify ($api, updated)" "rule 12345678: verified"
    outlacks "bulk verify ($api, updated)" "post-delete"
    [ "$(nrequests)" -eq 1 ] || fail "bulk verify ($api, updated): ran $(nrequests) checks, expected one"
    reset; fixture "$p" "$bad"; prep "$BV" "$api"; run
    [ "$RC" -ne 0 ] || fail "bulk verify ($api): exited 0 although the PUT assertion failed"
    grep -qF "not verified" "$WORK/stderr" || fail "bulk verify ($api): a failed PUT assertion did not say so"
    outlacks "bulk verify ($api, failed PUT)" "rule 12345678: verified"
    reset; fixture "$p" '{"detail":"The requested resource does not exist"}' 404; prep "$BV" "$api" -e 's|^CHANGE="updated"|CHANGE="deleted"|'; run
    [ "$RC" -eq 0 ] || fail "bulk verify ($api): the JSON 404 after a delete was not accepted"
    outhas "bulk verify ($api, deleted)" "rule 12345678: gone (404)"
    [ "$(nrequests)" -eq 1 ] || fail "bulk verify ($api, deleted): ran $(nrequests) checks, expected one"
    reset; fixture "$p" '' 404; prep "$BV" "$api" -e 's|^CHANGE="updated"|CHANGE="deleted"|'; run
    [ "$RC" -ne 0 ] || fail "bulk verify ($api): a bare 404 was taken as proof of deletion"
    reset; fixture "$p" "$ok"; prep "$BV" "$api" -e 's|^CHANGE="updated"|CHANGE="removed"|'; run
    [ "$RC" -ne 0 ] && [ "$(nrequests)" -eq 0 ] || fail "bulk verify ($api): an unknown CHANGE was not refused before any request"
  done
fi

# 4) cron monitor rollback: name check, then the JSON 404
[ "$(extract 'MONITOR_SLUG="<monitor-slug>"' cron-rollback)" -eq 1 ] || fail "expected one cron rollback block"
CR="$WORK/blocks/cron-rollback.1.sh"
if [ -f "$CR" ]; then
  MON="$ORG/monitors/nightly-data-sync/"
  MONITOR='{"id":"m1","slug":"nightly-data-sync","name":"nightly-data-sync","status":"disabled"}'
  reset; cp "$CR" "$WORK/run.sh"; run
  [ "$RC" -ne 0 ] && [ "$(nrequests)" -eq 0 ] || fail "cron rollback: ran with its placeholder unfilled"
  reset; fixture "$MON" "$MONITOR"; prep "$CR" workflows; run
  applied "cron rollback" "DELETE $MON"
  outhas "cron rollback" "post-delete: 404"
  reset; fixture "$MON" "$(printf '%s' "$MONITOR" | jq -c '.name = "Nightly data sync (billing)"')"; prep "$CR" workflows; run
  refused "cron rollback (a monitor this setup did not name)" "not deleting"
  reset; fixture "$MON" "$MONITOR"; gone_mode bare404; prep "$CR" workflows; run
  [ "$RC" -ne 0 ] || fail "cron rollback: a bare 404 after the delete was taken as proof"
fi

# 5) age gate: every refusal stops before the PUT; the apply path sends exactly one PUT
[ "$(extract 'RULE_AGE_GATE_DAYS=' age-gate)" -eq 1 ] || fail "expected one age-gate block"
AG="$WORK/blocks/age-gate.1.sh"
ALERT='{"id":"12345678","name":"Burst errors","enabled":true,"environment":null,"owner":"team:1","config":{"frequency":15},"detectorIds":["111"],"triggers":{"id":"7","logicType":"any-short","conditions":[]},"actionFilters":[{"id":"9","logicType":"all","conditions":[{"id":"11","type":"event_frequency_count","comparison":{"value":100,"interval":"1h"},"conditionResult":true}],"actions":[{"id":"10","type":"email","integrationId":null,"config":{"targetType":"issue_owners","targetIdentifier":null},"data":{"fallthroughType":"AllMembers"}}]}]}'
RULE='{"id":"12345678","name":"Burst errors","actionMatch":"any","filterMatch":"all","environment":null,"frequency":15,"owner":"team:1","conditions":[{"id":"sentry.rules.conditions.event_frequency.EventFrequencyCondition","value":100,"interval":"1h","comparisonType":"count"}],"filters":[],"actions":[{"id":"sentry.mail.actions.NotifyEmailAction","targetType":"IssueOwners","fallthroughType":"AllMembers"}]}'
MONITORS='[{"id":"111","projectId":"1","type":"issue_stream"},{"id":"999","projectId":null,"type":"issue_stream"}]'
ENVS='[{"id":"1","name":"production","isHidden":false},{"id":"2","name":"staging","isHidden":false}]'
STAGING_ONLY='[{"id":"2","name":"staging","isHidden":false}]'
age_gate() { # age_gate <api> <alert or rule> <environments>: set the fixtures and run the block
  reset
  if [ "$1" = workflows ]; then fixture "$ORG/workflows/12345678/" "$2"; else fixture "$PROJ/rules/12345678/" "$2"; fi
  fixture "$ORG/detectors/?project=checkout" "$MONITORS"
  fixture "$PROJ/environments/" "$3"
  prep "$AG" "$1"; run
}
if [ -f "$AG" ]; then
  age_gate workflows "$ALERT" "$ENVS"
  applied "age gate (alerts API)" "PUT $ORG/workflows/12345678/"
  jq -e '.environment == "production" and .config.frequency == 1440 and .enabled == true
      and (.actionFilters | length) == 1 and .actionFilters[0].id == "9" and .actionFilters[0].logicType == "all"
      and any(.actionFilters[0].conditions[]; .type == "age_comparison" and .comparison.comparisonType == "newer"
              and .comparison.value == 7 and .comparison.time == "day")' "$STATE/last-body.json" > /dev/null 2>&1 \
    || fail "age gate (alerts API): wrong PUT body: $(tr -d "\n" < "$STATE/last-body.json")"
  for logic in any any-short none; do
    age_gate workflows "$(printf '%s' "$ALERT" | jq -c --arg l "$logic" '.actionFilters[0].logicType = $l')" "$ENVS"
    refused "age gate (alerts API, $logic filter)" "logicType all"
  done
  age_gate workflows "$ALERT" "$STAGING_ONLY"
  refused "age gate (alerts API, TARGET_ENV not in the project)" "has no environment"
  age_gate workflows "$(printf '%s' "$ALERT" | jq -c '.detectorIds = ["555"]')" "$ENVS"
  refused "age gate (alerts API, alert on another project's monitor)" "not attached to a monitor of project"
  age_gate workflows "$(printf '%s' "$ALERT" | jq -c '.detectorIds = ["999"]')" "$ENVS"
  refused "age gate (alerts API, alert on the org-wide monitor only)" "not attached to a monitor of project"
  age_gate workflows "$(printf '%s' "$ALERT" | jq -c '.triggers.conditions = [{"id":"8","type":"regression_event","comparison":true,"conditionResult":true}]')" "$ENVS"
  refused "age gate (alerts API, regression trigger)" "regression"
  # the verify finds the gate in the backed-up filter, by id: a gate that landed elsewhere fails it
  reset
  fixture "$ORG/workflows/12345678/" "$ALERT"; fixture "$ORG/detectors/?project=checkout" "$MONITORS"; fixture "$PROJ/environments/" "$ENVS"
  after_put "$ORG/workflows/12345678/" "$(printf '%s' "$ALERT" | jq -c '.environment = "production" | .config.frequency = 1440
      | .actionFilters += [{"id":"77","logicType":"all","conditions":[{"id":"78","type":"age_comparison","comparison":{"comparisonType":"newer","time":"day","value":7},"conditionResult":true}],"actions":[]}]')"
  prep "$AG" workflows; run
  [ "$RC" -ne 0 ] || fail "age gate (alerts API): verify passed with the age gate in a different filter"
  # ... and the backed-up filter must still be all-match: the gate in filter 9 under an any filter fails it
  reset
  fixture "$ORG/workflows/12345678/" "$ALERT"; fixture "$ORG/detectors/?project=checkout" "$MONITORS"; fixture "$PROJ/environments/" "$ENVS"
  after_put "$ORG/workflows/12345678/" "$(printf '%s' "$ALERT" | jq -c '.environment = "production" | .config.frequency = 1440
      | .actionFilters[0].logicType = "any"
      | .actionFilters[0].conditions += [{"id":"78","type":"age_comparison","comparison":{"comparisonType":"newer","time":"day","value":7},"conditionResult":true}]')"
  prep "$AG" workflows; run
  [ "$RC" -ne 0 ] || fail "age gate (alerts API): verify passed with the backed-up filter no longer all-match"
  age_gate legacy "$RULE" "$ENVS"
  applied "age gate (legacy)" "PUT $PROJ/rules/12345678/"
  jq -e '.filterMatch == "all" and .environment == "production" and .frequency == 1440
      and any(.filters[]; .id == "sentry.rules.filters.age_comparison.AgeComparisonFilter"
              and .comparison_type == "newer" and .value == 7)' "$STATE/last-body.json" > /dev/null 2>&1 \
    || fail "age gate (legacy): wrong PUT body: $(tr -d "\n" < "$STATE/last-body.json")"
  # the legacy verify checks the age filter's values, not its presence: an "older" filter fails it
  reset
  fixture "$PROJ/rules/12345678/" "$RULE"; fixture "$PROJ/environments/" "$ENVS"
  after_put "$PROJ/rules/12345678/" "$(printf '%s' "$RULE" | jq -c '.environment = "production" | .frequency = 1440
      | .filters += [{"id":"sentry.rules.filters.age_comparison.AgeComparisonFilter","comparison_type":"older","time":"day","value":7}]')"
  prep "$AG" legacy; run
  [ "$RC" -ne 0 ] || fail "age gate (legacy): verify passed with an age filter that is not newer than the announced days"
  for match in any none; do
    age_gate legacy "$(printf '%s' "$RULE" | jq -c --arg m "$match" '.filterMatch = $m')" "$ENVS"
    refused "age gate (legacy, filterMatch $match)" "filterMatch other than all"
  done
  age_gate legacy "$(printf '%s' "$RULE" | jq -c '.conditions += [{"id":"sentry.rules.conditions.regression_event.RegressionEventCondition"}]')" "$ENVS"
  refused "age gate (legacy, regression condition)" "regression"
  age_gate legacy "$RULE" "$STAGING_ONLY"
  refused "age gate (legacy, TARGET_ENV not in the project)" "has no environment"
fi

nfail="$(wc -l < "$WORK/failures" | tr -d ' ')"
if [ "$nfail" -ne 0 ]; then
  echo "SETUP-SENTRY-UPTIME-RESTORE-VERIFY-AGEGATE FAILED ($nfail assertions)" >&2
  exit 1
fi
echo "SETUP-SENTRY-UPTIME-RESTORE-VERIFY-AGEGATE-OK (uptime create and rollback on both APIs; $restores restore runs, every bad backup refused with no write; bulk verify one check per rule; cron rollback name check; age-gate refusals with no write)"
