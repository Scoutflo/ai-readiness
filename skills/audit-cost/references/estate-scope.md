# Cost estate scope and resumable batches

## Collect sizing evidence

Run after the scope display and before deep checks. This cheap inventory measures the
configured AWS region, all visible GCP resource locations, the selected Azure subscription,
and the selected Kubernetes context. It deduplicates `(provider, target, kind, id)`.
A denied, malformed, warned-about or incomplete read is unknown, never zero.
Other cost catalogs whose complete object count is not available here are explicitly
unknown and require the scope checkpoint; their billed spend is not silently covered.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh"
select_target() {
  COST_PROVIDER="$1"; COST_KIND=$(sh "$TT" "$CFG" "$1" kind); COST_N=$(sh "$TT" "$CFG" "$1" count)
  COST_IDX=0
  [ "$COST_N" -gt 0 ] || return 1
  if [ "$COST_KIND" = seq ]; then
    COST_IDX=""; _i=0
    while [ "$_i" -lt "$COST_N" ]; do
      [ "$(sh "$TT" "$CFG" "$1" label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && COST_IDX=$_i
      _i=$((_i+1))
    done
    [ -n "$COST_IDX" ] || { echo "select $1 with SCOUTFLO_TARGET; labels: $(sh "$TT" "$CFG" "$1" labels | tr '\n' ' ')" >&2; exit 1; }
  fi
  COST_LABEL=$(sh "$TT" "$CFG" "$1" label "$COST_IDX")
}
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}"
mkdir -p "$BASE"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT HUP INT TERM
: > "$TMP/objects"; : > "$TMP/unknown"
unknown() {
  jq -cn --arg p "$COST_PROVIDER" --arg t "$COST_LABEL" --arg s "$1" --arg r "$2" \
    '{provider:$p,target:$t,surface:$s,reason:$r}' >> "$TMP/unknown"
}
collect() { # kind, jq producing [{id}], command + arguments
  _kind="$1"; _filter="$2"; shift 2
  if _payload=$("$@" 2>"$TMP/stderr") && [ ! -s "$TMP/stderr" ] && \
     _rows=$(printf '%s' "$_payload" | jq -ce "$_filter | if type == \"array\" and all(.[]; (.id | type == \"string\" and length > 0)) then . else error(\"invalid inventory\") end" 2>/dev/null); then
    printf '%s' "$_rows" | jq -c --arg p "$COST_PROVIDER" --arg t "$COST_LABEL" --arg k "$_kind" \
      '.[] | {provider:$p,target:$t,kind:$k,id:.id}' >> "$TMP/objects"
  else
    unknown "$_kind" "inventory read failed, warned, or was incomplete; size is unknown"
  fi
}
if select_target aws; then
  PROFILE=$(sh "$TT" "$CFG" aws get "$COST_IDX" profile)
  REGION=$(sh "$TT" "$CFG" aws get "$COST_IDX" region)
  EXPECTED=$(sh "$TT" "$CFG" aws get "$COST_IDX" account_id)
  [ -n "$REGION" ] || { echo "aws.region required before sizing"; exit 1; }
  A() { if [ -n "$PROFILE" ]; then aws --profile "$PROFILE" --region "$REGION" "$@"; else aws --region "$REGION" "$@"; fi; }
  ID=$(A sts get-caller-identity --output json)
  printf '%s' "$ID" | jq -e --arg expected "$EXPECTED" '.Account and .Arn and ($expected == "" or .Account == $expected)' >/dev/null || { echo "AWS identity mismatch"; exit 1; }
  collect instance 'if (.Reservations|type)=="array" then [.Reservations[].Instances[] | {id:.InstanceId}] else error("shape") end' A ec2 describe-instances --output json
  collect volume 'if (.Volumes|type)=="array" then [.Volumes[] | {id:.VolumeId}] else error("shape") end' A ec2 describe-volumes --output json
  collect address 'if (.Addresses|type)=="array" then [.Addresses[] | {id:(.AllocationId // .PublicIp)}] else error("shape") end' A ec2 describe-addresses --output json
  collect snapshot 'if (.Snapshots|type)=="array" then [.Snapshots[] | {id:.SnapshotId}] else error("shape") end' A ec2 describe-snapshots --owner-ids self --output json
  collect database 'if (.DBInstances|type)=="array" then [.DBInstances[] | {id:.DBInstanceIdentifier}] else error("shape") end' A rds describe-db-instances --output json
  collect load-balancer 'if (.LoadBalancers|type)=="array" then [.LoadBalancers[] | {id:.LoadBalancerArn}] else error("shape") end' A elbv2 describe-load-balancers --output json
  collect autoscaling-group 'if (.AutoScalingGroups|type)=="array" then [.AutoScalingGroups[] | {id:.AutoScalingGroupName}] else error("shape") end' A autoscaling describe-auto-scaling-groups --output json
  collect lambda 'if (.Functions|type)=="array" then [.Functions[] | {id:.FunctionArn}] else error("shape") end' A lambda list-functions --output json
  unknown account-catalogs "S3, ECS, commitment and provider-recommendation counts are not included in this regional lower bound; select their scope explicitly"
fi
if select_target gcp; then
  PROJECT=$(sh "$TT" "$CFG" gcp get "$COST_IDX" project)
  [ -n "$PROJECT" ] || { echo "gcp.project required before sizing"; exit 1; }
  export CLOUDSDK_CORE_DISABLE_PROMPTS=1
  ID=$(gcloud projects describe "$PROJECT" --project="$PROJECT" --format=json)
  printf '%s' "$ID" | jq -e --arg project "$PROJECT" '.projectId == $project' >/dev/null || { echo "GCP project identity mismatch"; exit 1; }
  collect instance 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud compute instances list --project="$PROJECT" --format=json
  collect disk 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud compute disks list --project="$PROJECT" --format=json
  collect snapshot 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud compute snapshots list --project="$PROJECT" --format=json
  collect address 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud compute addresses list --project="$PROJECT" --format=json
  collect forwarding-rule 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud compute forwarding-rules list --project="$PROJECT" --format=json
  collect database 'if type=="array" then [.[] | {id:(.selfLink // .name)}] else error("shape") end' gcloud sql instances list --project="$PROJECT" --format=json
  collect bucket 'if type=="array" then [.[] | {id:.name}] else error("shape") end' gcloud storage buckets list --project="$PROJECT" --format=json
  unknown project-catalogs "Managed capacity, logging, inference, commitments and billing SKU counts are not included in this lower bound; select their scope explicitly"
fi
if select_target azure; then
  SUB=$(sh "$TT" "$CFG" azure get "$COST_IDX" subscription_id)
  [ -n "$SUB" ] || { echo "azure.subscription_id required before sizing"; exit 1; }
  ID=$(az account show --subscription "$SUB" -o json)
  printf '%s' "$ID" | jq -e --arg sub "$SUB" '.id == $sub' >/dev/null || { echo "Azure subscription mismatch"; exit 1; }
  collect resource 'if type=="array" then [.[] | {id:.id}] else error("shape") end' az resource list --subscription "$SUB" -o json
fi
if select_target kubernetes; then
  CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$COST_IDX" context)
  [ -n "$CONTEXT" ] || { echo "kubernetes.context required before sizing"; exit 1; }
  # The explicit context is also used by the cost catalog; never use the current default.
  collect workload 'if (.items|type)=="array" then [.items[] | {id:(.kind+"/"+(.metadata.namespace // "_")+"/"+.metadata.name)}] else error("shape") end' kubectl --context "$CONTEXT" get pods,persistentvolumeclaims,persistentvolumes --all-namespaces -o json
fi
for provider in datadog digitalocean signoz newrelic; do
  if select_target "$provider"; then unknown provider-catalog "complete sizing is unavailable here; review the provider inventory and bound this phase before deep reads"; fi
done
jq -n --slurpfile objects "$TMP/objects" --slurpfile unknown "$TMP/unknown" \
  --arg config "$CFG" --arg fingerprint "$(cksum < "$CFG")" --arg selected "${SCOUTFLO_TARGET:-}" --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{config:$config,config_fingerprint:$fingerprint,selected_target:$selected,generated_at:$generated,objects:($objects | unique_by([.provider,.target,.kind,.id])),unknown:$unknown}' > "$TMP/sizing.json"
mv "$TMP/sizing.json" "$BASE/sizing.json"
echo "sizing evidence: $BASE/sizing.json"
```

AWS and GCP counts are deliberate lower bounds, not all-service census claims. Unknown
catalogs force a scope decision. If the selected scope excludes them, write that exclusion
and its reason into `scope.json` and the report; do not erase the original sizing evidence.
The provider's configured credential chain must already pass its identity gate. No command
switches a shared CLI default, creates credentials, enables APIs, or installs anything.

## Large-path worklist and resume

Use a fixed run ID for working state; publish the ordinary date-based report only at
completion. Run this block after the scope decision. `COST_RUN_ID` is an existing run
chosen for resume or unset for a new run. The selected ID is persisted in the target's
`active-run`; every claim, completion and publication revalidates its config fingerprint
and selected target in a fresh shell. `COST_RUN_DIR` cannot select a foreign directory. A found unfinished run must be offered before
choosing a new one. Do not choose by “newest” alone; config fingerprints must match.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh"
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}"
SIZE="$BASE/sizing.json"
[ -f "$SIZE" ] || { echo "collect sizing evidence first"; exit 1; }
FINGERPRINT=$(cksum < "$CFG")
jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config == $config and .config_fingerprint == $fingerprint and .selected_target == $selected' "$SIZE" >/dev/null || { echo "sizing belongs to another config; recollect it"; exit 1; }
if [ -z "${COST_RUN_ID:-}" ]; then
  found=0
  for dir in "$BASE"/runs/*; do
    [ -f "$dir/worklist.tsv" ] || continue
    if [ -d "$dir/worklist.lock" ] || awk -F'\t' '$2=="pending" {found=1} END{exit !found}' "$dir/worklist.tsv"; then
      echo "unfinished run: $dir (offer resume; verify its config fingerprint)"; found=1
    fi
  done
  [ "$found" -eq 0 ] || { echo "choose COST_RUN_ID before continuing; no new run was created"; exit 1; }
  COST_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
fi
case "$COST_RUN_ID" in ''|*[!0-9TZ]*) echo "invalid cost run ID"; exit 1 ;; esac
COST_RUN_DIR="$BASE/runs/$COST_RUN_ID"
if [ ! -d "$COST_RUN_DIR" ]; then
  mkdir -p "$BASE/runs"
  mkdir "$COST_RUN_DIR" || { echo "run already created by another session; inspect it before resuming"; exit 1; }
  cp "$SIZE" "$COST_RUN_DIR/sizing.json"
  printf '%s\n' "$FINGERPRINT" > "$COST_RUN_DIR/config-fingerprint"
  date -u +%Y-%m-%d > "$COST_RUN_DIR/report-date"
  # One resource per row, plus one row per provider catalog whose size was unknown.
  # Fields: row ID, state, provider, target, kind/surface, resource ID/reason.
  jq -r '([.objects[] | [.provider,.target,.kind,.id]] + [.unknown[] | [.provider,.target,.surface,.reason]]) | to_entries[] | [.key,"pending"] + .value | @tsv' "$SIZE" > "$COST_RUN_DIR/worklist.tsv"
  printf '%s\n' '{"approved":false,"included":[],"excluded":[]}' > "$COST_RUN_DIR/scope.json"
fi
[ "$(cat "$COST_RUN_DIR/config-fingerprint")" = "$FINGERPRINT" ] || { echo "run config changed; do not mix evidence"; exit 1; }
jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected' "$COST_RUN_DIR/sizing.json" >/dev/null || { echo "run belongs to another config or target; do not mix evidence"; exit 1; }
printf '%s\n' "$COST_RUN_ID" > "$BASE/active-run.$$"
mv "$BASE/active-run.$$" "$BASE/active-run"
echo "run directory: $COST_RUN_DIR; record the approved scope in scope.json; later blocks recover this selection from active-run"
```

Record the actual selected providers/regions/classes in `scope.json`, set `approved:true`
after the user's decision, and include `{scope,reason}` for every exclusion. Mark matching
worklist rows `excluded` only with that record. Run account-wide catalog reads once, then
judge resource-specific results in batches. Never repeat full billing queries for every row.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "cost configuration is missing"; exit 1; }
case "${SCOUTFLO_TARGET:-}" in .|..|*[!a-zA-Z0-9._-]*) echo "invalid cost target label"; exit 1;; esac
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}"
[ -d "$BASE" ] || { echo "collect cost sizing and select a run first"; exit 1; }
BASE=$(CDPATH= cd -- "$BASE" && pwd -P)
COST_RUN_ID="${COST_RUN_ID:-}"
[ -n "$COST_RUN_ID" ] || { [ ! -f "$BASE/active-run" ] || COST_RUN_ID=$(cat "$BASE/active-run"); }
case "$COST_RUN_ID" in ''|*[!0-9TZ]*) echo "select a bound cost run before continuing"; exit 1;; esac
EXPECTED_RUN="$BASE/runs/$COST_RUN_ID"
[ -d "$EXPECTED_RUN" ] || { echo "selected cost run is missing"; exit 1; }
EXPECTED_RUN=$(CDPATH= cd -- "$EXPECTED_RUN" && pwd -P)
[ "$EXPECTED_RUN" = "$BASE/runs/$COST_RUN_ID" ] || { echo "cost run escapes its target directory"; exit 1; }
if [ -n "${COST_RUN_DIR:-}" ]; then
  GIVEN_RUN=$(CDPATH= cd -- "$COST_RUN_DIR" && pwd -P) || exit 1
  [ "$GIVEN_RUN" = "$EXPECTED_RUN" ] || { echo "cost run directory belongs to another selected run or target"; exit 1; }
fi
COST_RUN_DIR="$EXPECTED_RUN"
FINGERPRINT=$(cksum < "$CFG")
[ "$(cat "$COST_RUN_DIR/config-fingerprint")" = "$FINGERPRINT" ] || { echo "run config changed; do not mix evidence"; exit 1; }
jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected' "$COST_RUN_DIR/sizing.json" >/dev/null || { echo "run belongs to another config or target; do not mix evidence"; exit 1; }
BATCH_SIZE=50  # example; tune to the amount of evidence per resource
jq -e '.approved == true and (.included|type=="array") and (.included|length)>0 and (.excluded|type=="array")' "$COST_RUN_DIR/scope.json" >/dev/null || { echo "record approved scope before claiming a batch"; exit 1; }
# Atomic claim retained across command blocks. Elapsed time or a dead preparation
# shell does NOT mean the batch worker stopped; never automatically reclaim it.
mkdir "$COST_RUN_DIR/worklist.lock" 2>/dev/null || { echo "batch locked; finish or explicitly abandon that batch before retrying"; exit 1; }
COST_BATCH_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
printf '%s\n' "$COST_BATCH_ID" > "$COST_RUN_DIR/worklist.lock/batch-id"
printf '%s\t%s\n' "$$" "$(date -u +%s)" > "$COST_RUN_DIR/worklist.lock/owner"
awk -F'\t' -v n="$BATCH_SIZE" '$2=="pending" {print; if(++seen==n)exit}' "$COST_RUN_DIR/worklist.tsv" > "$COST_RUN_DIR/worklist.lock/batch.tsv"
mkdir -p "$COST_RUN_DIR/evidence/$COST_BATCH_ID"
echo "batch claimed: $COST_BATCH_ID; keep this ID for the completion block"
cat "$COST_RUN_DIR/worklist.lock/batch.tsv"
```

Run the provider checks for the claimed rows, with this exact `COST_BATCH_ID`.
Write `evidence/<batch-id>/<row-id>.json` as
`{batch_id, state:"done"|"blocked", reason, checks:[{command,observed}]}`.
`done` requires captured checks; blocked evidence states which read failed. No new
batch may start until this one is completed or explicitly abandoned. For an interrupted
batch, inspect its evidence and resume the same batch ID; if abandoning it, confirm no
worker is still using it, remove only its lock, and keep unread rows pending.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "cost configuration is missing"; exit 1; }
case "${SCOUTFLO_TARGET:-}" in .|..|*[!a-zA-Z0-9._-]*) echo "invalid cost target label"; exit 1;; esac
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}"
[ -d "$BASE" ] || { echo "collect cost sizing and select a run first"; exit 1; }
BASE=$(CDPATH= cd -- "$BASE" && pwd -P)
COST_RUN_ID="${COST_RUN_ID:-}"
[ -n "$COST_RUN_ID" ] || { [ ! -f "$BASE/active-run" ] || COST_RUN_ID=$(cat "$BASE/active-run"); }
case "$COST_RUN_ID" in ''|*[!0-9TZ]*) echo "select a bound cost run before continuing"; exit 1;; esac
EXPECTED_RUN="$BASE/runs/$COST_RUN_ID"
[ -d "$EXPECTED_RUN" ] || { echo "selected cost run is missing"; exit 1; }
EXPECTED_RUN=$(CDPATH= cd -- "$EXPECTED_RUN" && pwd -P)
[ "$EXPECTED_RUN" = "$BASE/runs/$COST_RUN_ID" ] || { echo "cost run escapes its target directory"; exit 1; }
if [ -n "${COST_RUN_DIR:-}" ]; then
  GIVEN_RUN=$(CDPATH= cd -- "$COST_RUN_DIR" && pwd -P) || exit 1
  [ "$GIVEN_RUN" = "$EXPECTED_RUN" ] || { echo "cost run directory belongs to another selected run or target"; exit 1; }
fi
COST_RUN_DIR="$EXPECTED_RUN"
FINGERPRINT=$(cksum < "$CFG")
[ "$(cat "$COST_RUN_DIR/config-fingerprint")" = "$FINGERPRINT" ] || { echo "run config changed; do not mix evidence"; exit 1; }
jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected' "$COST_RUN_DIR/sizing.json" >/dev/null || { echo "run belongs to another config or target; do not mix evidence"; exit 1; }
COST_BATCH_ID="${COST_BATCH_ID:?set the batch ID printed when claiming}"
[ -f "$COST_RUN_DIR/worklist.lock/batch-id" ] && [ "$(cat "$COST_RUN_DIR/worklist.lock/batch-id")" = "$COST_BATCH_ID" ] || { echo "this batch does not own the lock; worklist unchanged"; exit 1; }
cp "$COST_RUN_DIR/worklist.tsv" "$COST_RUN_DIR/worklist.next"
while IFS="$(printf '\t')" read -r row state provider target kind resource; do
  [ "$state" = pending ] || continue
  file="$COST_RUN_DIR/evidence/$COST_BATCH_ID/$row.json"
  [ -f "$file" ] || continue  # unread rows remain pending
  jq -e --arg batch "$COST_BATCH_ID" '.batch_id==$batch and (.state=="done" or .state=="blocked") and (.reason|type=="string" and length>0) and (.checks|type=="array") and (if .state=="done" then (.checks|length)>0 and all(.checks[]; (.command|type=="string" and length>0) and (.observed|type=="string" and length>0)) else true end)' "$file" >/dev/null || { echo "invalid evidence for row $row; worklist unchanged and lock retained"; exit 1; }
  next=$(jq -r '.state' "$file")
  awk -F'\t' -v OFS='\t' -v id="$row" -v state="$next" '$1==id && $2=="pending" {$2=state} {print}' "$COST_RUN_DIR/worklist.next" > "$COST_RUN_DIR/worklist.tmp"
  mv "$COST_RUN_DIR/worklist.tmp" "$COST_RUN_DIR/worklist.next"
done < "$COST_RUN_DIR/worklist.lock/batch.tsv"
mv "$COST_RUN_DIR/worklist.next" "$COST_RUN_DIR/worklist.tsv"
rm -rf "$COST_RUN_DIR/worklist.lock"
awk -F'\t' '{n[$2]++} END{printf "done=%d blocked=%d excluded=%d pending=%d\n",n["done"],n["blocked"],n["excluded"],n["pending"]}' "$COST_RUN_DIR/worklist.tsv"
```

Assemble partial output in the run directory after each batch. Final reports must name
blocked/excluded rows and unassessed spend; only zero pending rows permits publication.
Use `report-date` from this run when publishing, so crossing UTC midnight never changes the
output path. Keep the run directory as evidence until the report and history are verified.

- ❌ Mark a failed batch done to make the last-report gate pass.
- ✅ Leave unread rows pending, or record their terminal blocked evidence and expose the coverage gap.
