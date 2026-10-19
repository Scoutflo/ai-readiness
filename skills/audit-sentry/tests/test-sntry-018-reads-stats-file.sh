#!/bin/sh
# test-sntry-018-reads-stats-file.sh: runs audit-sentry's own SNTRY-018 block, as written, against a
# fixture stats file with standard input closed (as in an agent session) and a stand-in curl that
# refuses network. The block must read the stats file it names: a project over the drop-ratio floor
# is reported, one under it is not. Before the fix the final jq read standard input, printed nothing
# and so read as a pass on every estate.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECKS="$ROOT/skills/audit-sentry/references/api-checks.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || fail "jq is required"

# The bash block under the SNTRY-018 heading, exactly as published.
awk 'f == 0 && /^\*\*SNTRY-018/ { f = 1; next }
     f == 1 && /^```bash/ { f = 2; next }
     f == 2 && /^```/ { exit }
     f == 2 { print }' "$CHECKS" > "$WORK/block.sh"
grep -q 'SNTRY-018 fail' "$WORK/block.sh" || fail "could not extract the SNTRY-018 block"

# No network: the block must use the stats file the fixture provides.
mkdir -p "$WORK/bin"
printf '#!/bin/sh\necho "curl: (7) network disabled in this test" >&2\nexit 7\n' > "$WORK/bin/curl"
chmod +x "$WORK/bin/curl"

# run_case <stats json> : prints the block's stdout
run_case() {
  raw="$WORK/aud/sentry/$(date -u +%Y-%m-%d)/raw"
  rm -rf "$WORK/aud"; mkdir -p "$raw"
  printf '%s\n' "$1" > "$raw/stats-projects.json"
  ( cd "$WORK" && HOME="$WORK/home" SCOUTFLO_ENV_FILE= SCOUTFLO_CONFIG= SCOUTFLO_AUDIT_DIR="$WORK/aud" PATH="$WORK/bin:$PATH" SENTRY_TOKEN="example-not-a-secret" \
      sh "$WORK/block.sh" ) < /dev/null
}

# Project 1: 46 dropped of 428 (10.7%), over the 5% floor. Project 2: 204 of 8455 (2.4%), under it.
over='{"groups":[
 {"by":{"project":1,"outcome":"accepted"},"totals":{"sum(quantity)":382}},
 {"by":{"project":1,"outcome":"rate_limited"},"totals":{"sum(quantity)":46}},
 {"by":{"project":2,"outcome":"accepted"},"totals":{"sum(quantity)":8251}},
 {"by":{"project":2,"outcome":"rate_limited"},"totals":{"sum(quantity)":204}}]}'
out="$(run_case "$over" 2> "$WORK/err")" || fail "the SNTRY-018 block failed on a valid stats file: $(tail -1 "$WORK/err")"
printf '%s\n' "$out" | grep -q '^SNTRY-018 fail: project 1 drop ratio 10% (46/428) exceeds floor 5%' \
  || fail "a project over the floor was not reported (output: ${out:-<nothing>})"
printf '%s\n' "$out" | grep -q 'project 2 ' && fail "a project under the floor was reported: $out"

# Nobody over the floor: no rows.
under='{"groups":[{"by":{"project":2,"outcome":"accepted"},"totals":{"sum(quantity)":8251}},{"by":{"project":2,"outcome":"rate_limited"},"totals":{"sum(quantity)":204}}]}'
out="$(run_case "$under" 2> "$WORK/err")" || fail "the SNTRY-018 block failed on a valid stats file: $(tail -1 "$WORK/err")"
[ -z "$out" ] || fail "rows printed although no project is over the floor: $out"

echo "SNTRY-018-READS-STATS-OK (reads its stats file with stdin closed; reports the project over the floor and only that one)"
