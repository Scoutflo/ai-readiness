#!/bin/sh
# Persist sizing and bounded audit progress. Judgment stays in SKILL.md; this
# helper never changes a cluster and never invents check results.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for candidate in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
  [ -f "$candidate" ] && { CFG=$candidate; break; }
done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'missing toolkit config; run /scoutflo:connect' >&2; exit 1; }
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f ./.scoutflo/env ]; then SCOUTFLO_ENV=./.scoutflo/env; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
# Load access material only in the read subprocess. The already-resolved target
# is passed as an argument, so store exports cannot redirect config/run/output
# routing in this helper or in its caller.
k8s_cli() (
  [ ! -f "$SCOUTFLO_ENV" ] || . "$SCOUTFLO_ENV"
  command kubectl "$@"
)
TT="$ROOT/report-standard/toolkit-targets.sh"
COUNT=$(sh "$TT" "$CFG" kubernetes count)
KIND=$(sh "$TT" "$CFG" kubernetes kind)
[ "$COUNT" -ge 1 ] || { echo 'no Kubernetes target configured' >&2; exit 1; }
IDX=0
if [ "$KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'select SCOUTFLO_TARGET from:' >&2; sh "$TT" "$CFG" kubernetes labels >&2; exit 1; }
  IDX=-1; i=0
  while [ "$i" -lt "$COUNT" ]; do
    [ "$(sh "$TT" "$CFG" kubernetes label "$i")" = "$SCOUTFLO_TARGET" ] && IDX=$i
    i=$((i+1))
  done
  [ "$IDX" -ge 0 ] || { echo 'SCOUTFLO_TARGET matches no Kubernetes label' >&2; exit 1; }
fi
CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$IDX" context)
LABEL=$(sh "$TT" "$CFG" kubernetes label "$IDX")
[ -n "$CONTEXT" ] || { echo 'selected Kubernetes target has no context' >&2; exit 1; }
[ "$KIND" = seq ] || LABEL=$CONTEXT
case "/$LABEL/" in *'/../'*|*'/./'*|*'//'*) echo 'unsafe target directory segment' >&2; exit 1;; esac
SEG="kubernetes/$LABEL"
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/$SEG"
SIZE="$BASE/sizing.json"
ACTION="${1:-}"; [ "$#" -eq 0 ] || shift
umask 077
mkdir -p "$BASE"
fail() { echo "$*" >&2; exit 1; }
size_ok() {
  [ -f "$SIZE" ] && jq -e --arg c "$CONTEXT" --arg t "$SEG" \
    '.status=="ok" and .context==$c and .target==$t and (.items|type)=="array" and .objects==(.items|length)' "$SIZE" >/dev/null \
    || fail 'no successful sizing for this target; run the sizing block first'
}
load_run() {
  RUN_ID="${SCOUTFLO_K8S_RUN_ID:-$(cat "$BASE/active-run" 2>/dev/null || true)}"
  case "$RUN_ID" in ''|*[!A-Za-z0-9._-]*|.*) fail 'missing or unsafe run id; start or select a resumable run';; esac
  RUN="$BASE/runs/$RUN_ID"
  [ -f "$RUN/meta.json" ] && jq -e --arg c "$CONTEXT" --arg t "$SEG" \
    '.context==$c and .target==$t' "$RUN/meta.json" >/dev/null \
    || fail 'run belongs to a different target or context; never reuse its evidence'
}
lock_run() {
  mkdir "$RUN/worklist.lock" 2>/dev/null || fail 'worklist is locked; verify the other writer has stopped before removing its lock'
  trap 'rmdir "$RUN/worklist.lock"' EXIT
  trap 'exit 1' HUP INT TERM
}
receipt_ok() {
  identity=$(awk -F '\t' -v k="$1" '$1==k{print $2 "\t" $3 "\t" $4}' "$RUN/worklist.tsv")
  jq -e --arg c "$CONTEXT" --arg t "$SEG" --arg k "$1" --arg identity "$identity" '
    .context==$c and .target==$t and .key==$k
    and ([.object.kind,.object.namespace,.object.name] | join("\t"))==$identity
    and (.read_exit|type)=="number" and .read_exit>=0 and .read_exit<=255 and (.read_exit|floor)==.read_exit
    and (.evidence|type)=="string" and (.evidence|length)>0
    and (.checks|type)=="array" and (.checks|length)>0
    and all(.checks[]; (.id|test("^K8S-(00[1-9]|01[0-4])$"))
      and (.result|IN("pass","partial","fail","blocked","not-in-scope"))
      and (if .result=="blocked" then (.reason|type)=="string" and (.reason|length)>0 else true end))
    and (if .read_exit!=0 then all(.checks[]; .result=="blocked") else true end)
  ' "$2" >/dev/null
}
ready() {
  [ -s "$RUN/worklist.tsv" ] || fail 'worklist missing or empty'
  [ "$(awk -F '\t' '$5!="done"{n++} END{print n+0}' "$RUN/worklist.tsv")" -eq 0 ] || fail 'pending work remains; keep partial output in the run directory'
  while IFS="$(printf '\t')" read -r key object_kind namespace name status; do
    receipt_ok "$key" "$RUN/receipts/$key.json" || fail "missing or invalid evidence receipt for $key"
  done < "$RUN/worklist.tsv"
}
resumable() {
  for prior in "$BASE"/runs/*/meta.json; do
    [ -f "$prior" ] || continue
    if [ ! -f "$(dirname "$prior")/published" ] && jq -e --arg c "$CONTEXT" --arg t "$SEG" '.context==$c and .target==$t' "$prior" >/dev/null; then
      basename "$(dirname "$prior")"
    fi
  done
}
case "$ACTION" in
  read-list)
    # These reference checks need raw responses only in a pipe/shell variable;
    # never persist raw Pod specs. Capture the producer status and require one
    # List response: jq on empty stdin alone would otherwise succeed silently.
    case "${1:-}" in pods|serviceaccounts|networkpolicies|namespaces) :;; *) fail 'unsupported posture read';; esac
    LIST=$(k8s_cli --context "$CONTEXT" --request-timeout=30s get "$1" -A -o json) || fail 'Kubernetes read blocked; no successful List response'
    printf '%s\n' "$LIST" | jq -e -s 'if length==1 and (.[0]|type)=="object" and (.[0].items|type)=="array" then .[0] else error("expected one Kubernetes List") end' \
      || fail 'Kubernetes read blocked; response was empty, malformed or not a List' ;;
  size)
    TASK_TMP=$(mktemp -d "$BASE/.sizing.XXXXXX")
    trap 'rm -rf "$TASK_TMP"' EXIT
    trap 'exit 1' HUP INT TERM
    # No raw Pod spec is written: the pipe emits only names, kinds and namespaces.
    # Save kubectl's OWN status; jq returning 0 on empty input is not evidence.
    (
      rc=0
      k8s_cli --context "$CONTEXT" --request-timeout=30s get \
        pods,deployments,statefulsets,daemonsets,services,ingresses,networkpolicies,poddisruptionbudgets,resourcequotas,limitranges,namespaces,roles,rolebindings,clusterroles,clusterrolebindings,serviceaccounts \
        -A -o json 2>"$TASK_TMP/read.err" || rc=$?
      printf '%s\n' "$rc" > "$TASK_TMP/read.rc"
    ) | jq -e 'if (.items|type)=="array" then
      [.items[] | {kind:.kind, namespace:(.metadata.namespace // ""), name:.metadata.name}]
      | if all(.[]; (.kind|type)=="string" and (.namespace|type)=="string" and (.name|type)=="string" and (.name|length)>0) then . else error("invalid identity row") end
      else error("not a Kubernetes List") end' > "$TASK_TMP/items.json" 2>/dev/null || true
    if [ "$(cat "$TASK_TMP/read.rc" 2>/dev/null || true)" != 0 ] || ! jq -e 'type=="array"' "$TASK_TMP/items.json" >/dev/null 2>&1; then
      jq -n --arg c "$CONTEXT" --arg t "$SEG" '{status:"blocked",context:$c,target:$t,reason:"Kubernetes sizing read failed or returned invalid JSON; count is unknown"}' > "$TASK_TMP/sizing.json"
      mv "$TASK_TMP/sizing.json" "$SIZE"
      fail 'Kubernetes sizing blocked; count is unknown. Check the selected context, reachability and list permissions; no zero count was saved.'
    fi
    jq -n --slurpfile items "$TASK_TMP/items.json" --arg c "$CONTEXT" --arg t "$SEG" --arg d "$(date -u +%Y-%m-%d)" \
      '{status:"ok",context:$c,target:$t,run_date:$d,items:$items[0],objects:($items[0]|length)}
       | .path=(if .objects<=100 then "small" elif .objects<=500 then "medium" elif .objects<=2000 then "large" else "xlarge" end)' > "$TASK_TMP/sizing.json"
    mv "$TASK_TMP/sizing.json" "$SIZE"
    jq -r '"estate: \(.objects) objects, \(.path) path; sizing saved"' "$SIZE" ;;
  sizing) size_ok; cat "$SIZE" ;;
  meta) load_run; cat "$RUN/meta.json" ;;
  resumable) resumable ;;
  begin)
    size_ok
    mkdir "$BASE/start.lock" 2>/dev/null || fail 'another scope/resume selection is in progress; do not race the active-run pointer'
    trap 'rmdir "$BASE/start.lock"' EXIT
    trap 'exit 1' HUP INT TERM
    SCOPE="${1:-all}"; RESUME="${2:-}"
    if [ -n "$RESUME" ]; then
      SCOUTFLO_K8S_RUN_ID=$RESUME; load_run
      [ ! -f "$RUN/published" ] || fail 'this run is already published; start a new run'
      printf '%s\n' "$RUN_ID" > "$BASE/active-run"
      echo "resumed $RUN_ID; saved scope and completed rows retained"; exit 0
    fi
    AVAILABLE=$(resumable)
    if [ -n "$AVAILABLE" ]; then
      printf 'resume available: %s (use begin all <run-id>; saved scope wins)\n' "$AVAILABLE" >&2
      exit 3
    fi
    if [ "$(jq '.objects' "$SIZE")" -le 500 ]; then
      rm -f "$BASE/active-run"
      echo 'small/medium path: no worklist required'; exit 0
    fi
    scope_json=$(printf '%s' "$SCOPE" | jq -R 'split(",") | map(gsub("^ +| +$";""))')
    if [ "$SCOPE" != all ]; then
      jq -e --argjson wanted "$scope_json" '([.items[] | select(.kind=="Namespace") | .name] + [.items[].namespace | select(length>0)] | unique) as $available
        | ($wanted|length)>0 and all($wanted[]; . as $n | ($available|index($n))!=null)' "$SIZE" >/dev/null || fail 'scope must name existing namespaces, or all'
    fi
    mkdir -p "$BASE/runs"
    RUN=$(mktemp -d "$BASE/runs/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
    RUN_ID=$(basename "$RUN")
    jq --arg scope "$SCOPE" --arg id "$RUN_ID" '. + {scope:$scope,run_id:$id}' "$SIZE" > "$RUN/meta.json"
    jq -r --arg scope "$SCOPE" --argjson wanted "$scope_json" '
      .items | map(select($scope=="all" or
        (if .kind=="Namespace" then .name as $n | ($wanted|index($n))!=null
         elif .namespace=="" then true
         else .namespace as $n | ($wanted|index($n))!=null end)))
      | to_entries[] | [(.key|tostring),.value.kind,(if .value.namespace=="" then "-" else .value.namespace end),.value.name,"pending"] | @tsv' "$SIZE" > "$RUN/worklist.tsv"
    mkdir "$RUN/receipts" "$RUN/draft"
    printf '%s\n' "$RUN_ID" > "$BASE/active-run"
    echo "started $RUN_ID; scope=$SCOPE; $(wc -l < "$RUN/worklist.tsv" | tr -d ' ') objects" ;;
  next)
    load_run; lock_run
    BATCH_SIZE="${1:-100}"
    case "$BATCH_SIZE" in ''|*[!0-9]*) fail 'batch size must be 1..100';; esac
    [ "$BATCH_SIZE" -ge 1 ] && [ "$BATCH_SIZE" -le 100 ] || fail 'batch size must be 1..100'
    # The short mutex serializes claims. The durable batch directory survives a
    # shell/session exit and prevents a second invocation claiming the same rows.
    mkdir "$RUN/batch" 2>/dev/null || fail 'a batch is already claimed; finish it, or verify its worker stopped and release it explicitly'
    awk -F '\t' -v n="$BATCH_SIZE" '$5=="pending" && seen++<n' "$RUN/worklist.tsv" > "$RUN/batch/rows.tsv"
    if [ ! -s "$RUN/batch/rows.tsv" ]; then rm -rf "$RUN/batch"; exit 0; fi
    cat "$RUN/batch/rows.tsv" ;;
  done)
    load_run; lock_run
    KEY="${1:-}"; RECEIPT="${2:-}"
    case "$KEY" in ''|*[!0-9]*) fail 'invalid worklist key';; esac
    [ -f "$RUN/batch/rows.tsv" ] && awk -F '\t' -v k="$KEY" '$1==k{found=1} END{exit !found}' "$RUN/batch/rows.tsv" || fail 'key is not in the claimed batch for this run'
    [ -f "$RECEIPT" ] && receipt_ok "$KEY" "$RECEIPT" || fail 'receipt must name this target/context/key, actual read exit, evidence and check results; failed reads must be blocked'
    cp "$RECEIPT" "$RUN/receipts/$KEY.json.tmp"
    mv "$RUN/receipts/$KEY.json.tmp" "$RUN/receipts/$KEY.json"
    awk -F '\t' -v OFS='\t' -v k="$KEY" '$1==k{$5="done"} {print}' "$RUN/worklist.tsv" > "$RUN/worklist.tsv.tmp"
    mv "$RUN/worklist.tsv.tmp" "$RUN/worklist.tsv"
    if awk -F '\t' 'NR==FNR{claimed[$1]=1; next} claimed[$1] && $5!="done"{pending=1} END{exit pending}' "$RUN/batch/rows.tsv" "$RUN/worklist.tsv"; then rm -rf "$RUN/batch"; fi ;;
  release-batch)
    load_run; lock_run
    [ "${1:-}" = --confirm-abandoned ] || fail 'verify the batch worker stopped, then pass --confirm-abandoned; never steal an active batch'
    rm -rf "$RUN/batch"
    echo 'batch claim released; completed rows retained, unfinished rows remain pending' ;;
  ready) load_run; ready; echo 'all worklist rows have assessed or explicitly blocked evidence' ;;
  output|final-path|published-path)
    size_ok
    if [ -n "${SCOUTFLO_K8S_RUN_ID:-}" ] || [ -f "$BASE/active-run" ]; then
      load_run
      [ "$ACTION" != published-path ] || [ -f "$RUN/published" ] || fail 'this run is not published; do not send a completion brief'
      if [ "$ACTION" = output ]; then printf '%s\n' "$RUN/draft"; else printf '%s/%s\n' "$BASE" "$(jq -r '.run_date' "$RUN/meta.json")"; fi
    else
      [ "$(jq '.objects' "$SIZE")" -le 500 ] || fail 'large run needs its confirmed scope and worklist first'
      printf '%s/%s\n' "$BASE" "$(jq -r '.run_date' "$SIZE")"
    fi ;;
  publish)
    load_run; lock_run; ready
    [ ! -f "$RUN/published" ] || fail 'run already published'
    jq -e --slurpfile meta "$RUN/meta.json" '.schema=="scoutflo-findings/v2"
      and .target==$meta[0].target and .run_date==$meta[0].run_date
      and .estate.objects==$meta[0].objects and .estate.path==$meta[0].path' \
      "$RUN/draft/findings.json" >/dev/null || fail 'draft schema, target, date or estate differs from the saved run'
    jq -e --arg t "$SEG" '.schema=="scoutflo-inventory/v1" and .target==$t' "$RUN/draft/inventory.json" >/dev/null || fail 'missing or mismatched draft inventory'
    sh "$ROOT/report-standard/check-findings.sh" "$RUN/draft/findings.json"
    sh "$ROOT/report-standard/check-report.sh" "$RUN/draft/report.md"
    DEST="$BASE/$(jq -r '.run_date' "$RUN/meta.json")"
    [ ! -e "$RUN/previous-complete" ] || fail 'previous publication backup exists; inspect it before retrying'
    # Retain the prior complete directory. On a failed rename or caught signal,
    # restore it before releasing the lock. Even an uncatchable process kill
    # leaves it intact in previous-complete for recovery, never partially edited.
    rollback_publication() {
      if [ ! -f "$RUN/published" ] && [ -e "$RUN/previous-complete" ]; then
        [ ! -e "$DEST" ] || mv "$DEST" "$RUN/unpublished-output"
        mv "$RUN/previous-complete" "$DEST"
      fi
      rmdir "$RUN/worklist.lock"
    }
    trap 'rollback_publication' EXIT
    [ ! -e "$DEST" ] || mv "$DEST" "$RUN/previous-complete"
    if ! mv "$RUN/draft" "$DEST"; then
      fail 'publication failed; previous completed report restored'
    fi
    : > "$RUN/published"
    echo "published $DEST" ;;
  *) fail 'usage: run-state.sh size|sizing|meta|resumable|begin [all|namespaces] [resume-id]|next [1..100]|done KEY RECEIPT|release-batch --confirm-abandoned|ready|output|final-path|published-path|publish' ;;
esac
