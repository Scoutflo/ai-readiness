#!/bin/sh
# Execute the published collection blocks in fresh shells with local-only stubs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/af-workflow.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
mkdir -p "$WORK/plugin/skills/alert-fatigue/lib" "$WORK/plugin/skills/doctor/scripts" "$WORK/plugin/report-standard" "$WORK/bin" "$WORK/home"
cp "${AF_WORKFLOW_LIB:-$ROOT/skills/alert-fatigue/lib/collection-workflow.sh}" "$WORK/plugin/skills/alert-fatigue/lib/collection-workflow.sh"
cp "$ROOT/report-standard/toolkit-targets.sh" "$ROOT/report-standard/check-fatigue-signals.sh" "$WORK/plugin/report-standard/"
export CLAUDE_PLUGIN_ROOT="$WORK/plugin" SCOUTFLO_CONFIG="$WORK/config.yaml" SCOUTFLO_ENV_FILE="$WORK/env" SCOUTFLO_AUDIT_DIR="$WORK/audits" AF_COLLECTION_PLAN="$WORK/plan.json" AF_CALLS="$WORK/calls" AF_FAULT_FILE="$WORK/fault" AF_QUERY_LOG="$WORK/queries"
printf '%s\n' 'export PRIMARY_TOKEN=synthetic-test-value' > "$SCOUTFLO_ENV_FILE"
cat > "$SCOUTFLO_CONFIG" <<'YAML'
prometheus:
  - label: primary
    url: https://primary.example.com
    token_env: PRIMARY_TOKEN
  - label: secondary
    url: https://secondary.example.com
    token_env: SECONDARY_TOKEN
aws:
  account_id: unselected
YAML
RD=$(date -u +%Y-%m-%d); NOW=$(date -u +%s); START=$((NOW-3600))
jq -n --arg date "$RD" --argjson start "$START" --argjson end "$NOW" '{schema:"scoutflo-fatigue-collection/v1",run_id:"fixture-run",run_date:$date,provider:"prometheus",target_label:"primary",identity:{expected:"cluster-example",path:["identity"],query:"up{cluster=\"cluster-example\"}",label:"cluster"},window:{start:$start,end:$end,description:"1h"},limits:{batch_size:1,max_pages:2,page_size:100},thresholds:{sample_step_seconds:30},objects:[{job_id:"job-001",object_id:"CheckoutErrors",object_kind:"prometheus_alert"},{job_id:"job-002",object_id:"Queue\"Errors\\Pending",object_kind:"prometheus_alert"}]}' > "$AF_COLLECTION_PLAN"
cat > "$WORK/plugin/skills/doctor/scripts/doctor.sh" <<'DOCTOR'
#!/bin/sh
set -eu
[ "$1" = --config ] && [ "$3" = --out ] || exit 9
! grep -q secondary "$2" || exit 9
! grep -q '^aws:' "$2" || exit 9
printf 'doctor\n' >> "$AF_CALLS"
case "$(cat "$AF_FAULT_FILE" 2>/dev/null || true)" in doctor-fail) exit 3;; doctor-empty) exit 0;; esac
printf '%s\n' '{"integration":"prometheus","configured":"yes","check":"query","result":"pass"}'
DOCTOR
cat > "$WORK/bin/curl" <<'CURL'
#!/bin/sh
set -eu
printf 'curl\n' >> "$AF_CALLS"
args=$(printf '%s\n' "$@")
printf '%s' "$args" | grep -q 'https://primary.example.com/api/v1/' || exit 7
printf '%s' "$args" | grep -q 'Authorization: Bearer synthetic-test-value' || exit 8
fault=$(cat "$AF_FAULT_FILE" 2>/dev/null || true)
case "$args" in
 *query_range*)
   query=''; query_count=0
   for arg do
     case "$arg" in query=*) query=$arg; query_count=$((query_count+1));; esac
   done
   jq -cn --arg job "$AF_JOB_ID" --arg query "$query" '{job:$job,query:$query}' >> "$AF_QUERY_LOG"
   # Literal expected PromQL is deliberately independent of the recipe's encoder.
   case "$AF_JOB_ID" in
     job-001) expected='query=ALERTS_FOR_STATE{alertname="CheckoutErrors"} and ignoring(alertstate) ALERTS{alertname="CheckoutErrors",alertstate="firing"}';;
     job-002) expected='query=ALERTS_FOR_STATE{alertname="Queue\"Errors\\Pending"} and ignoring(alertstate) ALERTS{alertname="Queue\"Errors\\Pending",alertstate="firing"}';;
     *) echo 'unexpected history job' >&2; exit 23;;
   esac
   [ "$query_count" -eq 1 ] && [ "$query" = "$expected" ] || { printf 'unexpected PromQL: %s\nexpected PromQL: %s\n' "$query" "$expected" >&2; exit 23; }
   [ "$fault" != read-fail ] || { printf '{"status":"success"}'; exit 22; }
   [ "$fault" != malformed ] || { printf '{broken'; exit 0; }
   name=$(jq -r --arg id "$AF_JOB_ID" '.objects[]|select(.job_id==$id)|.object_id' "$AF_COLLECTION_PLAN")
   jq -n --slurpfile plan "$AF_COLLECTION_PLAN" --arg name "$name" --arg fault "$fault" '$plan[0].window.start as $s | {status:"success",data:{resultType:"matrix",result:[{metric:{alertname:(if $fault=="wrong-object" then "OtherAlert" else $name end)},values:[[$s+20,($s+5|tostring)],[$s+30,($s+5|tostring)],[$s+50,($s+40|tostring)],[$s+70,($s+60|tostring)]]}]}}'
 ;;
 *) jq -n --arg fault "$fault" '{status:"success",data:{resultType:"vector",result:[{metric:{cluster:(if $fault=="wrong-identity" then "other-scope" else "cluster-example" end)},value:[1,"1"]}]}}';;
esac
CURL
chmod +x "$WORK/bin/curl"
for command in aws gcloud kubectl az doctl wget ssh helm gh claude; do
  printf '#!/bin/sh\necho "provider command denied in fixture" >&2\nexit 97\n' > "$WORK/bin/$command"; chmod +x "$WORK/bin/$command"
done
export PATH="$WORK/bin:$PATH"
# Exercise the literal source blocks, not a hand-written mirror.
extract() { awk -v want="$2" '/^```bash$/{n++; inside=1;next} /^```$/{inside=0;next} inside && n==want{print}' "$1" > "$3"; }
extract "$ROOT/skills/alert-fatigue/references/collection-workflow.md" 1 "$WORK/init.sh"
extract "$ROOT/skills/alert-fatigue/references/collection-workflow.md" 2 "$WORK/preflight.sh"
extract "${AF_FIRE_HISTORY_READS:-$ROOT/skills/alert-fatigue/references/fire-history-reads.md}" 1 "$WORK/read.sh"
extract "$ROOT/skills/alert-fatigue/references/collection-workflow.md" 3 "$WORK/finish.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "ok $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect() { if /bin/sh "$2" > "$WORK/output" 2>&1; then rc=0; else rc=$?; fi; if [ "$rc" = "$1" ]; then ok "$3"; else bad "$3 (expected $1 got $rc)"; cat "$WORK/output"; fi; }
script() { printf '%s\n' 'set -eu' '. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/collection-workflow.sh"' 'afc_open "$AF_COLLECTION_PLAN"' "$1" > "$WORK/check.sh"; }
expect 0 "$WORK/init.sh" 'fresh published init block freezes selected target'
RUN="$SCOUTFLO_AUDIT_DIR/alert-fatigue/runs/fixture-run"
! grep -q synthetic-test-value "$RUN/config.yaml" && ok 'config contains credential names only' || bad 'secret copied to config'
export AF_JOB_ID=job-001
expect 1 "$WORK/read.sh" 'read refuses missing live preflight'
[ ! -f "$AF_CALLS" ] && ok 'missing gate makes zero provider calls' || bad 'provider called before gate'
for fault in doctor-fail doctor-empty wrong-identity; do
 printf '%s\n' "$fault" > "$AF_FAULT_FILE"
 expect 1 "$WORK/preflight.sh" "$fault stops published preflight"
done
: > "$AF_FAULT_FILE"
expect 0 "$WORK/preflight.sh" 'published doctor and live identity gate succeeds'
[ "$(grep -c '"job_id"' "$WORK/output")" -eq 1 ] && ok 'next respects batch size' || bad 'batch size ignored'
expect 0 "$WORK/read.sh" 'published bounded sample read succeeds'
jq -e 'select(.job=="job-001") | .query=="query=ALERTS_FOR_STATE{alertname=\"CheckoutErrors\"} and ignoring(alertstate) ALERTS{alertname=\"CheckoutErrors\",alertstate=\"firing\"}"' "$AF_QUERY_LOG" >/dev/null && ok 'ordinary alert name is encoded exactly once in outgoing query' || bad 'ordinary query matcher encoded incorrectly'
jq -e '.signal.distinct_active_since_values==3 and (.signal|has("fires")|not) and .proof.complete_window==false' "$RUN/jobs/job-001/result.json" >/dev/null && ok 'three observed state origins are not one series or exact fires' || bad 'bad Prometheus sample derivation'
before=$(wc -l < "$AF_CALLS")
expect 0 "$WORK/read.sh" 'fresh-shell completed retry skips read'
[ "$(wc -l < "$AF_CALLS")" -eq "$before" ] && ok 'completed retry makes zero extra calls' || bad 'completed job fetched again'
script 'afc_assemble'; expect 1 "$WORK/check.sh" 'unfinished work cannot publish complete fragment'
export AF_JOB_ID=job-002
for fault in read-fail malformed wrong-object; do
 printf '%s\n' "$fault" > "$AF_FAULT_FILE"
 if /bin/sh "$WORK/read.sh" > "$WORK/output" 2>&1; then bad "$fault became success"; else ok "$fault rejects actual block"; fi
 [ ! -f "$RUN/jobs/job-002/complete.json" ] && [ ! -d "$RUN/jobs/job-002/.read-lock" ] && ok "$fault stays pending and releases own claim" || bad "$fault left bad receipt or lock"
done
: > "$AF_FAULT_FILE"
script 'afc_claim job-002'; expect 0 "$WORK/check.sh" 'claim pending job'
expect 1 "$WORK/read.sh" 'second session cannot duplicate claimed read'
script 'afc_release job-002'; expect 1 "$WORK/check.sh" 'another session cannot release the claim'
[ -d "$RUN/jobs/job-002/.read-lock" ] && ok 'foreign claim preserved' || bad 'foreign claim removed'
# The test owns this disposable abandoned-lock fixture; clear it for the retry case.
rm "$RUN/jobs/job-002/.read-lock/owner"; rmdir "$RUN/jobs/job-002/.read-lock"
expect 0 "$WORK/read.sh" 'pending failed job resumes successfully'
expected='query=ALERTS_FOR_STATE{alertname="Queue\"Errors\\Pending"} and ignoring(alertstate) ALERTS{alertname="Queue\"Errors\\Pending",alertstate="firing"}'
jq -e --arg expected "$expected" 'select(.job=="job-002") | .query==$expected' "$AF_QUERY_LOG" >/dev/null && ok 'quotes and backslashes match exact escaped PromQL literals' || bad 'quoted/backslashed query matcher encoded incorrectly'
export AF_RESULT="$RUN/jobs/job-002/result.json"
expect 0 "$WORK/finish.sh" 'published completion block assembles validated results'
jq -e '.signals|length==2' "$RUN/fatigue-signals.json" >/dev/null && ok 'both results retained' || bad 'result lost'
cp "$AF_COLLECTION_PLAN" "$WORK/plan-backup.json"
jq '.window.end+=1' "$AF_COLLECTION_PLAN" > "$WORK/change.json"; cp "$WORK/change.json" "$AF_COLLECTION_PLAN"
expect 1 "$WORK/init.sh" 'changed run basis cannot overwrite earlier evidence'
cp "$WORK/plan-backup.json" "$AF_COLLECTION_PLAN"
cp "$RUN/jobs/job-001/result.json" "$WORK/result-backup.json"
jq '.signal.distinct_active_since_values=999' "$RUN/jobs/job-001/result.json" > "$WORK/change.json"; cp "$WORK/change.json" "$RUN/jobs/job-001/result.json"
script 'afc_next'; expect 1 "$WORK/check.sh" 'tampered completed evidence stops reuse'
cp "$WORK/result-backup.json" "$RUN/jobs/job-001/result.json"
# Declaring exact fires over sampled data is rejected even if numeric types pass.
script 'afc_complete job-003 "$AF_BAD_RESULT"'
jq '.signal.fires=3' "$RUN/jobs/job-001/result.json" > "$WORK/bad-result.json"
export AF_BAD_RESULT="$WORK/bad-result.json"
# Use a new pending plan/job, keeping all existing evidence intact.
jq '.run_id="exact-claim" | .objects=[.objects[0]] | .objects[0].job_id="job-003"' "$AF_COLLECTION_PLAN" > "$WORK/new-plan.json"
AF_COLLECTION_PLAN="$WORK/new-plan.json" /bin/sh "$WORK/preflight.sh" > "$WORK/output" 2>&1
AF_COLLECTION_PLAN="$WORK/new-plan.json" expect 1 "$WORK/check.sh" 'sample proof cannot support exact fires'
export AF_COLLECTION_PLAN="$WORK/plan.json"
# Adversarial observed-response shapes; no provider command runs in these probes.
export AF_SAMPLE_INPUT="$WORK/sample.json"
for sample in empty warning nonnumeric wrong-wrapper future-value ha-duplicates; do
  jq -n --slurpfile plan "$AF_COLLECTION_PLAN" --arg sample "$sample" '$plan[0].window.start as $s | {status:"success",data:{resultType:"matrix",result:[{metric:{alertname:"CheckoutErrors"},values:[[$s+20,($s+5|tostring)],[$s+50,($s+40|tostring)]]}]}} | if $sample=="empty" then .data.result=[] elif $sample=="warning" then .warnings=["partial data"] elif $sample=="nonnumeric" then .data.result[0].values[0][1]="NaN" elif $sample=="wrong-wrapper" then .data.resultType="vector" elif $sample=="future-value" then .data.result[0].values[0][1]=($s+5000|tostring) elif $sample=="ha-duplicates" then .data.result += .data.result else . end' > "$AF_SAMPLE_INPUT"
  script 'afc_prometheus_result job-001 < "$AF_SAMPLE_INPUT" > "$SCOUTFLO_AUDIT_DIR/sample-result.json"'
  case "$sample" in empty|ha-duplicates) expect 0 "$WORK/check.sh" "$sample measured-sample shape accepted";; *) if /bin/sh "$WORK/check.sh" > "$WORK/output" 2>&1; then bad "$sample normalized as valid"; else ok "$sample rejected by response assertions"; fi;; esac
  if [ "$sample" = ha-duplicates ]; then jq -e '.signal.distinct_active_since_values==2 and (.signal|has("fires")|not)' "$SCOUTFLO_AUDIT_DIR/sample-result.json" >/dev/null && ok 'HA series do not inflate distinct state values' || bad 'HA duplication inflated samples'; fi
  if [ "$sample" = empty ]; then jq -e '.signal.distinct_active_since_values==0 and (.signal|has("fires")|not)' "$SCOUTFLO_AUDIT_DIR/sample-result.json" >/dev/null && ok 'empty observed range does not invent zero exact fires' || bad 'empty range invented fires'; fi
done
# A newly missing named secret invalidates the old receipt before any requests.
printf '%s\n' 'unset PRIMARY_TOKEN' > "$SCOUTFLO_ENV_FILE"
before=$(wc -l < "$AF_CALLS")
expect 1 "$WORK/preflight.sh" 'fresh missing token stops before doctor or HTTP'
[ "$(wc -l < "$AF_CALLS")" -eq "$before" ] && [ ! -f "$RUN/identity.json" ] && ok 'missing auth makes no request and invalidates prior gate' || bad 'stale auth receipt or request'
# Voice/frontmatter/triggers are observable product contract, not inferred intent.
! grep -q '^disable-model-invocation:' "$ROOT/skills/alert-fatigue/SKILL.md" && ok 'non-setup invocation is enabled' || bad 'non-setup invocation disabled'
grep -q 'Use when' "$ROOT/skills/alert-fatigue/SKILL.md" && grep -q 'Do not use' "$ROOT/skills/alert-fatigue/SKILL.md" && ok 'positive and negative triggers exist' || bad 'missing triggers'
! grep -Eq 'prod/PP|our wedge|our checks|presented to a customer' "$ROOT/skills/alert-fatigue/SKILL.md" "$ROOT/skills/alert-fatigue/references/methodology.md" && ok 'public self-service voice' || bad 'private or consultant wording'
echo "collection-workflow: $PASS passed, $FAIL failed (zero real provider calls)"
[ "$FAIL" -eq 0 ]
