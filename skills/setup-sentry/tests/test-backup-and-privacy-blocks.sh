#!/bin/sh
# test-backup-and-privacy-blocks.sh: runs setup-sentry's own write blocks, as written, against a
# fake Sentry (a stand-in curl; nothing leaves this machine) and asserts that:
#   1. no backup check uses the non-stopping `test -s "$BACKUP_FILE" && echo` form;
#   2. every guarded write block stops, with no write sent, when its backup read comes back
#      empty, not JSON, JSON null, or refused, on both alert APIs, and the legacy warning-tier
#      update stops (instead of sending an empty PUT) when its edit of the backup fails;
#   3. the privacy write keeps the fields a project already scrubs (Sentry replaces the
#      sensitiveFields list with whatever is sent), and its verify step fails if one is missing.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$ROOT/skills/setup-sentry/SKILL.md"
COOKBOOK="$ROOT/skills/setup-sentry/references/api-cookbook.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"

# 1) the non-stopping form is gone
if grep -n 'test -s "$BACKUP_FILE" && echo' "$SKILL" "$COOKBOOK"; then
  fail "a backup check still uses test -s ... && echo, which never stops the block"
fi

# Fake curl. The first GET of a single object is the block's backup read and gets FAULT_MODE
# (empty | html | null | notriggers | fail | none); other GETs get fixture JSON. A PUT/POST/DELETE is logged and its
# body kept; a later GET of the project applies that body the way Sentry does (fields replaced),
# minus STUB_DROP if set, so the verify step can be tested.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/sh
method=GET; url=""; data=""; out=""; wfmt=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method="$a" ;; -d|--data) data="$a" ;; -o) out="$a" ;; -w) wfmt="$a" ;; esac
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
[ "$data" = "@-" ] && data="$(cat)"
path="$(printf '%s' "$url" | sed 's#^https://[^/]*##')"
emit() {
  if [ -n "$out" ]; then [ "$out" = /dev/null ] || printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi
  [ -z "$wfmt" ] || printf '%s' "$2"
}
is() { printf '%s' "$path" | grep -Eq "$1"; }
if [ "$method" != GET ]; then
  printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/writes.log"
  printf '%s' "$data" > "$STUB_DIR/last-body.json"
  emit '' '204'; exit 0
fi
if is '/(projects/[^/?]+/[^/?]+|keys/[^/?]+|workflows/[0-9]+|rules/[0-9]+|detectors/[0-9]+|alert-rules/[0-9]+)/$' \
   && [ ! -f "$STUB_DIR/backup-read" ]; then
  : > "$STUB_DIR/backup-read"
  case "${FAULT_MODE:-none}" in
    empty) emit '' '200 application/json'; exit 0 ;;
    html)  emit '<html><body>Sign in</body></html>' '200 text/html'; exit 0 ;;
    null)  emit 'null' '200 application/json'; exit 0 ;;
    notriggers) emit '{"id":"12345678","name":"x"}' '200 application/json'; exit 0 ;;
    fail)  echo "curl: (22) The requested URL returned error: 403" >&2; exit 22 ;;
  esac
fi
project='{"slug":"checkout","dataScrubber":false,"dataScrubberDefaults":true,"scrubIPAddresses":false,"scrapeJavaScript":true,"sensitiveFields":["customer_ssn"]}'
if is '/detectors/\?'; then emit '[{"id":"111","type":"issue_stream","projectId":"1","workflowIds":["12345678"]}]' '200 application/json'
elif is '/workflows/\?'; then emit '[{"id":"12345678","name":"Send a notification for high priority issues","createdBy":null,"detectorIds":["111"]}]' '200 application/json'
elif is '/rules/$'; then emit '[{"id":"12345678","name":"Send a notification for high priority issues","createdBy":null}]' '200 application/json'
elif is '/environments/$'; then emit '[{"id":"1","name":"production","isHidden":false}]' '200 application/json'
elif is '^/api/0/projects/[^/]+/[^/]+/$'; then
  if [ -s "$STUB_DIR/last-body.json" ]; then
    emit "$(printf '%s\n%s\n' "$project" "$(cat "$STUB_DIR/last-body.json")" \
      | jq -cs --arg drop "${STUB_DROP:-}" '.[0] * .[1] | .sensitiveFields |= map(select(. != $drop))')" '200 application/json'
  else
    emit "$project" '200 application/json'
  fi
else
  emit '{"id":"12345678","name":"x","enabled":true,"createdBy":null,"detectorIds":["111"],"type":"metric_issue","actionFilters":[{"id":"9","logicType":"all","conditions":[],"actions":[]}],"triggers":[],"config":{"frequency":5},"conditionGroup":{"id":"5","logicType":"any","conditions":[{"id":"1","type":"gt","comparison":10,"conditionResult":50}]},"filters":[],"actions":[],"filterMatch":"all","rateLimit":null}' '200 application/json'
fi
exit 0
STUB
chmod +x "$WORK/bin/curl"

# Extract every bash block that carries the backup guard, exactly as written.
mkdir -p "$WORK/blocks"
for f in "$SKILL" "$COOKBOOK"; do
  awk -v out="$WORK/blocks/$(basename "$f" .md)" '
    /^```bash/ { b = ""; inb = 1; next }
    /^```/     { if (inb && index(b, "is empty or not a JSON object; not writing")) { k++; print b > (out "." k ".sh") } inb = 0; next }
    inb        { b = b $0 "\n" }' "$f"
done
nblocks=$(ls "$WORK/blocks" | wc -l | tr -d ' ')
nguards=$(cat "$SKILL" "$COOKBOOK" | grep -c 'is empty or not a JSON object; not writing')
# 8 blocks hold 12 guards: four blocks carry one per alert API (new and legacy).
[ "$nblocks" -ge 8 ] || fail "expected at least 8 guarded write blocks, found $nblocks"
[ "$nguards" -ge 12 ] || fail "expected at least 12 backup guards, found $nguards"

# run_block <block> <alert api> <fault mode> [drop field]: prints the block's exit status
run_block() {
  sed -e "s|^SENTRY_ALERT_API=\"workflows\"|SENTRY_ALERT_API=\"$2\"|" \
      -e 's|^ALERT_RULE_ID="your-metric-alert-id"|ALERT_RULE_ID="12345678"|' "$1" > "$WORK/run.sh"
  rm -rf "$WORK/state" "$WORK/home" "$WORK/out"; mkdir -p "$WORK/state" "$WORK/home"
  set +e
  ( cd "$WORK" && HOME="$WORK/home" SCOUTFLO_AUDIT_DIR="$WORK/out" STUB_DIR="$WORK/state" \
      FAULT_MODE="$3" STUB_DROP="${4:-}" PATH="$WORK/bin:$PATH" SENTRY_TOKEN="example-not-a-secret" \
      sh "$WORK/run.sh" ) > "$WORK/stdout" 2> "$WORK/stderr"
  rc=$?
  set -e
  echo "$rc"
}

# 2) every guarded block stops on a bad backup, with no write sent
runs=0
for b in "$WORK"/blocks/*.sh; do
  apis="workflows"; grep -q '^SENTRY_ALERT_API=' "$b" && apis="workflows legacy"
  for api in $apis; do
    for mode in empty html null fail; do
      rc="$(run_block "$b" "$api" "$mode")"
      [ "$rc" -ne 0 ] || fail "$(basename "$b") ($api, $mode backup) exited 0"
      [ ! -s "$WORK/state/writes.log" ] || fail "$(basename "$b") ($api, $mode backup) sent a write: $(cat "$WORK/state/writes.log")"
      runs=$((runs + 1))
    done
  done
done

# 2b) the legacy warning-tier update builds its body before the PUT: an object backup its edit
#     cannot apply to (no triggers) must stop the block, never send an empty PUT
wt=0
for b in "$WORK"/blocks/*.sh; do
  grep -q 'alert-rules/${ALERT_RULE_ID}/' "$b" || continue
  wt=$((wt + 1))
  rc="$(run_block "$b" legacy notriggers)"
  [ "$rc" -ne 0 ] || fail "$(basename "$b"): legacy warning tier exited 0 on a backup without triggers"
  [ ! -s "$WORK/state/writes.log" ] || fail "$(basename "$b"): legacy warning tier sent a write when its edit failed: $(cat "$WORK/state/writes.log")"
done
[ "$wt" -eq 1 ] || fail "expected one legacy warning-tier block, found $wt"

# 3) the privacy write keeps existing fields, and its verify catches a dropped one
privacy=0
for b in "$WORK"/blocks/*.sh; do
  grep -q 'STARTER_FIELDS=' "$b" || continue
  privacy=$((privacy + 1))
  rc="$(run_block "$b" workflows none)"
  [ "$rc" -eq 0 ] || fail "$(basename "$b"): privacy block failed on a healthy project: $(tail -1 "$WORK/stderr")"
  [ "$(wc -l < "$WORK/state/writes.log" | tr -d ' ')" -eq 1 ] || fail "$(basename "$b"): expected exactly one write"
  jq -e '(.sensitiveFields | index("customer_ssn")) != null and (.sensitiveFields | index("dsn")) != null' \
    "$WORK/state/last-body.json" > /dev/null || fail "$(basename "$b"): the PUT body dropped a field the project already scrubbed"
  rc="$(run_block "$b" workflows none customer_ssn)"
  [ "$rc" -ne 0 ] || fail "$(basename "$b"): verify passed although a backed-up field was no longer listed"
done
[ "$privacy" -eq 2 ] || fail "expected the privacy block in SKILL.md and the cookbook, found $privacy"

echo "SETUP-SENTRY-BACKUP-PRIVACY-OK ($nguards backup guards in $nblocks write blocks, $runs bad-backup runs with no write; privacy keeps existing fields in $privacy blocks)"
