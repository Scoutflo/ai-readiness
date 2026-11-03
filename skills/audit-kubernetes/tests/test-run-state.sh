#!/bin/sh
# Exercises the shipped sizing/scope blocks and helper in fresh shells. No live
# CLIs, ambient config, or real HOME writes. Optional root is for mutation tests.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
CLAUDE_PLUGIN_ROOT=${K8S_TEST_PLUGIN_ROOT:-$ROOT}; export CLAUDE_PLUGIN_ROOT
STATE="$CLAUDE_PLUGIN_ROOT/skills/audit-kubernetes/scripts/run-state.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
HOME="$WORK/home"; SCOUTFLO_CONFIG="$WORK/config.yaml"; SCOUTFLO_AUDIT_DIR="$WORK/audits"
export HOME SCOUTFLO_CONFIG SCOUTFLO_AUDIT_DIR
unset SCOUTFLO_TARGET SCOUTFLO_K8S_RUN_ID OBJ TOTAL
mkdir -p "$HOME" "$WORK/bin"
PATH="$WORK/bin:$PATH"; export PATH
REAL_MV=$(command -v mv); export REAL_MV
STUB_LOG="$WORK/kubectl.log"; STUB_FIXTURE="$WORK/objects.json"; STUB_CONTEXT=example-context; STUB_RC=0
export STUB_LOG STUB_FIXTURE STUB_CONTEXT STUB_RC
cat > "$WORK/bin/kubectl" <<'STUB'
#!/bin/sh
[ "$1" = --context ] && [ "$2" = "$STUB_CONTEXT" ] && [ "$3" = --request-timeout=30s ] && [ "$4" = get ] || exit 99
printf '%s\n' "$*" >> "$STUB_LOG"
cat "$STUB_FIXTURE"
exit "$STUB_RC"
STUB
# Avoid host yq implementation differences; exercise the shipped awk resolver.
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/yq"
chmod +x "$WORK/bin/kubectl" "$WORK/bin/yq"
cat > "$WORK/bin/mv" <<'STUB'
#!/bin/sh
case "$1" in */draft) [ "${STUB_FAIL_PUBLISH:-0}" != 1 ] || exit 1;; esac
exec "$REAL_MV" "$@"
STUB
chmod +x "$WORK/bin/mv"
printf 'kubernetes:\n  context: example-context\n' > "$SCOUTFLO_CONFIG"
fail() { echo "FAIL: $*" >&2; exit 1; }
reject() { if "$@" > "$WORK/rejected.log" 2>&1; then fail "unexpected success: $*"; fi; }
run() { sh "$STATE" "$@"; }
extract_block() {
  awk -v h="$1" '$0==h{section=1;next} section && /^```bash$/{block=1;next} block && /^```$/{exit} block{print}' \
    "$CLAUDE_PLUGIN_ROOT/skills/audit-kubernetes/SKILL.md" > "$2"
  [ -s "$2" ] || fail "missing published block: $1"
}
extract_block '## Estate sizing' "$WORK/size.sh"
extract_block '### Scope checkpoint' "$WORK/scope.sh"
BASE="$SCOUTFLO_AUDIT_DIR/kubernetes/example-context"

echo 'Test 1: single target, fresh-shell sizing/checkpoint, and no worklist for a tiny estate'
printf '%s\n' '{"items":[{"kind":"Namespace","metadata":{"name":"app"}},{"kind":"Pod","metadata":{"name":"web","namespace":"app"},"spec":{"containers":[{"env":[{"value":"PRIVATE_FIXTURE_VALUE"}]}]}}]}' > "$STUB_FIXTURE"
sh "$WORK/size.sh" > /dev/null
sh "$WORK/scope.sh" > /dev/null
jq -e '.objects==2 and .path=="small" and .target=="kubernetes/example-context"' "$BASE/sizing.json" >/dev/null || fail 'wrong single target sizing'
[ ! -d "$BASE/runs" ] || fail 'tiny estate created a worklist'
! grep -R -q PRIVATE_FIXTURE_VALUE "$SCOUTFLO_AUDIT_DIR" || fail 'raw object spec was persisted'
echo PASS

echo 'Test 2: denied reads, even with valid stdout, and malformed reads never become zero'
STUB_RC=1
reject sh "$WORK/size.sh"
jq -e '.status=="blocked" and (has("objects")|not)' "$BASE/sizing.json" >/dev/null || fail 'denied read saved a usable count'
reject sh "$WORK/scope.sh"
STUB_RC=0
printf '{"items":' > "$STUB_FIXTURE"
reject run size
reject run sizing
# A successful first JSON object must not hide trailing corruption or a second
# response. No prefix may become the measured estate after a parse failure.
printf '%s\n' '{"items":[{"kind":"Pod","metadata":{"name":"web","namespace":"app"}}]}' > "$WORK/valid-list.json"
for tail in '{broken' '{"items":[]}'; do
  cat "$WORK/valid-list.json" > "$STUB_FIXTURE"
  printf '%s\n' "$tail" >> "$STUB_FIXTURE"
  if run size > "$WORK/rejected.log" 2>&1; then fail "sizing accepted trailing JSON: $tail"; fi
  jq -e '.status=="blocked" and (has("objects")|not)' "$BASE/sizing.json" >/dev/null || fail 'invalid trailing response saved a usable count'
  reject run sizing
done
cp "$WORK/valid-list.json" "$STUB_FIXTURE"
run size >/dev/null
jq -e '.status=="ok" and .objects==1 and (.items|length)==1' "$BASE/sizing.json" >/dev/null || fail 'single valid List control rejected'
echo PASS

echo 'Test 3: large checkpoint requires confirmation, persists namespace scope, and claims bounded batches'
# 505 identities: app has one Namespace and two Pods; other has 500 Pods and
# its Namespace. One ClusterRole must remain for cross-object RBAC reasoning.
jq -n '{items:([{kind:"Namespace",metadata:{name:"app"}},{kind:"Namespace",metadata:{name:"other"}},
  {kind:"ClusterRole",metadata:{name:"reader"}}]
  + [range(0;2)|{kind:"Pod",metadata:{name:("web-"+tostring),namespace:"app"}}]
  + [range(0;500)|{kind:"Pod",metadata:{name:("worker-"+tostring),namespace:"other"}}])}' > "$STUB_FIXTURE"
sh "$WORK/size.sh" >/dev/null
printf 'n\n' | sh "$WORK/scope.sh" >/dev/null
[ ! -d "$BASE/runs" ] || fail 'declining scope still started a run'
printf 'yes\napp\n' | sh "$WORK/scope.sh" >/dev/null
RUN_ID=$(cat "$BASE/active-run"); RUN="$BASE/runs/$RUN_ID"
[ "$(wc -l < "$RUN/worklist.tsv" | tr -d ' ')" = 4 ] || fail 'namespace scope leaked or cluster-wide identity missing'
! grep -q other "$RUN/worklist.tsv" || fail 'unselected namespace was included'
[ "$(run next 2 | wc -l | tr -d ' ')" = 2 ] || fail 'batch size was ignored'
reject run next 2
reject run ready
reject run release-batch
echo PASS

echo 'Test 4: receipts bind target, context, object and read outcome before marking done'
make_receipt() {
  row=$(awk -F '\t' -v k="$1" '$1==k' "$RUN/worklist.tsv")
  printf '%s\n' "$row" | jq -R --arg t "$RECEIPT_TARGET" --arg c "$STUB_CONTEXT" 'split("\t") |
    {target:$t,context:$c,key:.[0],object:{kind:.[1],namespace:.[2],name:.[3]},read_exit:0,
     evidence:"Read-only fixture evidence for this object; applicable checks assessed.",checks:[{id:"K8S-001",result:"pass"}]}' > "$WORK/receipt.json"
}
RECEIPT_TARGET=kubernetes/example-context
make_receipt 0
jq '.read_exit=1' "$WORK/receipt.json" > "$WORK/bad.json"
reject run done 0 "$WORK/bad.json"
jq '.object.name="different"' "$WORK/receipt.json" > "$WORK/bad.json"
reject run done 0 "$WORK/bad.json"
jq '.target="kubernetes/other"' "$WORK/receipt.json" > "$WORK/bad.json"
reject run done 0 "$WORK/bad.json"
run done 0 "$WORK/receipt.json"
[ "$(awk -F '\t' '$1==0{print $5}' "$RUN/worklist.tsv")" = done ] || fail 'valid receipt not recorded'
make_receipt 1
jq '.read_exit=1 | .checks=[{id:"K8S-002",result:"blocked",reason:"Forbidden listing bindings; permissions unknown"}]' "$WORK/receipt.json" > "$WORK/blocked.json"
run done 1 "$WORK/blocked.json"
[ ! -d "$RUN/batch" ] || fail 'finished batch claim not released'
echo PASS

echo 'Test 5: resume retains completed rows and frozen scope/date; pending work preserves the last complete output'
FINAL=$(run final-path)
mkdir -p "$FINAL"
printf 'previous-complete-findings\n' > "$FINAL/findings.json"
printf 'previous-complete-report\n' > "$FINAL/report.md"
cp "$FINAL/findings.json" "$WORK/previous.json"
cp "$FINAL/report.md" "$WORK/previous.md"
reject run begin all
printf '%s\n' "$RUN_ID" | sh "$WORK/scope.sh" >/dev/null
jq -e '.scope=="app"' "$RUN/meta.json" >/dev/null || fail 'resume widened saved scope'
[ "$(awk -F '\t' '$5=="done"{n++} END{print n+0}' "$RUN/worklist.tsv")" = 2 ] || fail 'resume lost completed rows'
[ "$(run output)" = "$RUN/draft" ] || fail 'partial output targets the completed date directory'
reject run publish
cmp "$WORK/previous.json" "$FINAL/findings.json" || fail 'pending publish changed completed findings'
cmp "$WORK/previous.md" "$FINAL/report.md" || fail 'pending publish changed completed report'
reject run published-path
run next 1 > "$WORK/batch.tsv"
run release-batch --confirm-abandoned >/dev/null
run next 100 > "$WORK/batch.tsv"
while IFS="$(printf '\t')" read -r key kind ns name status; do make_receipt "$key"; run done "$key" "$WORK/receipt.json"; done < "$WORK/batch.tsv"
run ready >/dev/null
cp "$RUN/receipts/0.json" "$WORK/saved-receipt.json"
rm "$RUN/receipts/0.json"
reject run ready
cp "$WORK/saved-receipt.json" "$RUN/receipts/0.json"
echo PASS

echo 'Test 6: multi-target selection is explicit; same label with a changed context cannot resume'
cat > "$SCOUTFLO_CONFIG" <<'CFG'
kubernetes:
  - label: east
    context: east-context
  - label: west
    context: west-context
CFG
reject run size
SCOUTFLO_TARGET=missing; export SCOUTFLO_TARGET
reject run size
SCOUTFLO_TARGET=east; STUB_CONTEXT=east-context
run size >/dev/null
run begin app >/dev/null
EAST_RUN_ID=$(cat "$SCOUTFLO_AUDIT_DIR/kubernetes/east/active-run")
SCOUTFLO_TARGET=west; STUB_CONTEXT=west-context
run size >/dev/null
reject run begin all "$EAST_RUN_ID"
SCOUTFLO_TARGET=east
sed 's/east-context/replacement-context/' "$SCOUTFLO_CONFIG" > "$WORK/new-config.yaml"
mv "$WORK/new-config.yaml" "$SCOUTFLO_CONFIG"
reject run begin all "$EAST_RUN_ID"
STUB_CONTEXT=replacement-context
run size >/dev/null
reject run begin all "$EAST_RUN_ID"
echo PASS

echo 'Test 7: publishing validates the aggregate, replaces only a completed run, and retains its backup'
unset SCOUTFLO_TARGET
STUB_CONTEXT=example-context
printf 'kubernetes:\n  context: example-context\n' > "$SCOUTFLO_CONFIG"
VERSION=$(jq -r '.version' "$ROOT/.claude-plugin/plugin.json")
# A complete all-pass ledger is a fixture, not an assertion about any cluster.
jq -n --arg version "$VERSION" --arg date "$(basename "$FINAL")" '
  [{name:"Workload hardening",weight:25,ids:["001","007","008"]},
   {name:"Identity & access",weight:20,ids:["002","006","009"]},
   {name:"Network segmentation",weight:20,ids:["003","011","010"]},
   {name:"Reliability & resilience",weight:20,ids:["005","012","013"]},
   {name:"Resource governance",weight:15,ids:["004","014"]}] as $cats |
  {schema:"scoutflo-findings/v2",toolkit_version:$version,skill:"audit-kubernetes",target:"kubernetes/example-context",run_date:$date,generated_at:($date+"T12:00:00Z"),estate:{objects:505,path:"large"},
   checks:[$cats[] | . as $c | .ids[] | {id:("K8S-"+.),category:$c.name,result:"pass"}],
   score:{overall:100,state:"assessed",gate:85,end_to_end:false,scoring_model:"assessed-only-v1",check_set:"pending",
     assessment:{applicable_checks:14,assessed_checks:14,scored_checks:14,blocked_checks:0,suppressed_checks:0,not_in_scope_checks:0,coverage_percent:100},
     categories:[$cats[] | {name,weight,score:100,maturity:"proactive",checks_passed:(.ids|length),checks_partial:0,checks_failed:0,checks_blocked:0,checks_suppressed:0,checks_not_in_scope:0,checks_total:(.ids|length)}],excluded:[]},
   severity_counts:{critical:0,high:0,medium:0,low:0,info:0},findings:[]}' > "$RUN/draft/findings.json"
FP=$(jq -r '([.checks[]|"chk\t"+.id+"\t"+.category]+[.score.categories[]|"cat\t"+.name+"\t"+(.weight|tostring)]+["gate\t"+(.score.gate|tostring)])|sort|.[]' "$RUN/draft/findings.json" | LC_ALL=C cksum | awk '{print "cksum-v2:" $1 ":" $2}')
jq --arg fp "$FP" '.score.check_set=$fp' "$RUN/draft/findings.json" > "$WORK/final.json"
mv "$WORK/final.json" "$RUN/draft/findings.json"
cat > "$RUN/draft/report.md" <<'REPORT'
# Kubernetes audit: example
| | |
| --- | --- |
| Target | example |
| Date | fixture UTC |
| Toolkit version | fixture |
| Skill | audit-kubernetes |
## At a glance
**Score: 100/100**
## Executive summary
Good base posture in the selected scope.
## Scorecard
All fixture checks passed.
REPORT
sh "$ROOT/report-standard/render-report-viz.sh" lanes "$RUN/draft/findings.json" >> "$RUN/draft/report.md"
printf '%s\n' '{"schema":"scoutflo-inventory/v1","target":"kubernetes/example-context","items":[],"counts":{"total":0,"by_kind":{}}}' > "$RUN/draft/inventory.json"
sh "$ROOT/report-standard/render-report-viz.sh" inventory "$RUN/draft/inventory.json" >> "$RUN/draft/report.md"
cat >> "$RUN/draft/report.md" <<'REPORT'

## Findings
No verified fixture defects.
## Next safe actions
Retain the report.
## Evidence appendix
Hermetic fixture receipts.
REPORT
# Validate first so a pending-work mutation cannot hide behind a malformed draft.
sh "$ROOT/report-standard/check-findings.sh" "$RUN/draft/findings.json" > "$WORK/findings-check.log" 2>&1 || { cat "$WORK/findings-check.log"; fail 'invalid publication fixture'; }
sh "$ROOT/report-standard/check-report.sh" "$RUN/draft/report.md" > "$WORK/report-check.log" 2>&1 || { cat "$WORK/report-check.log"; fail 'invalid report fixture'; }
cp "$RUN/worklist.tsv" "$WORK/complete.tsv"
awk -F '\t' -v OFS='\t' '$1==0{$5="pending"}{print}' "$RUN/worklist.tsv" > "$WORK/pending.tsv"
cp "$WORK/pending.tsv" "$RUN/worklist.tsv"
reject run publish
cmp "$WORK/previous.json" "$FINAL/findings.json" || fail 'pending valid draft replaced completed findings'
cp "$WORK/complete.tsv" "$RUN/worklist.tsv"
STUB_FAIL_PUBLISH=1; export STUB_FAIL_PUBLISH
reject run publish
cmp "$WORK/previous.json" "$FINAL/findings.json" || fail 'failed publication did not restore previous findings'
cmp "$WORK/previous.md" "$FINAL/report.md" || fail 'failed publication did not restore previous report'
unset STUB_FAIL_PUBLISH
run publish >/dev/null
cmp "$WORK/previous.json" "$RUN/previous-complete/findings.json" || fail 'previous findings backup missing'
cmp "$WORK/previous.md" "$RUN/previous-complete/report.md" || fail 'previous report backup missing'
[ "$(run published-path)" = "$FINAL" ] || fail 'published path lost the frozen run date'
jq -e '.target=="kubernetes/example-context" and .score.overall==100' "$FINAL/findings.json" >/dev/null || fail 'validated result not published'
reject run publish
echo PASS
echo 'Test 8: medium, large and xlarge boundaries come from actual persisted counts'
SCOUTFLO_AUDIT_DIR="$WORK/boundaries"
for count in 100 101 500 501 2000 2001; do
  jq -n --argjson count "$count" '{items:[range(0;$count)|{kind:"Pod",metadata:{name:("pod-"+tostring),namespace:"app"}}]}' > "$STUB_FIXTURE"
  run size >/dev/null
  case "$count" in 100) expected=small;; 101|500) expected=medium;; 501|2000) expected=large;; 2001) expected=xlarge;; esac
  run sizing | jq -e --arg p "$expected" --argjson n "$count" '.objects==$n and .path==$p' >/dev/null || fail "wrong path at $count"
done
echo PASS
echo 'audit-kubernetes run-state: 8 cases passed'
