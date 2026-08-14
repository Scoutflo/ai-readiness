#!/bin/sh
# live-evidence.sh — shared READ-ONLY live-evidence probe library.
#
# Purpose: gather current runtime/liveness signal for a Kubernetes workload so a
# skill (rca today; audit-kubernetes runtime-health later) can name an accurate,
# evidence-cited cause instead of reasoning only over stale report files.
#
# SAFETY BY CONSTRUCTION — this library is the one place live calls happen, so the
# read-only guarantee is enforced here and mechanically checked by
# ci/liveness-readonly-check.sh:
#   * Every kubectl invocation goes through le_kubectl(), which refuses any verb
#     not on LE_ALLOWED_VERBS (get/describe/list/logs/top/events/version/
#     api-resources/auth/config) — all read-only. No apply/create/edit/patch/
#     delete/scale/rollout/exec/cp/port-forward/annotate/label/debug ever.
#   * --context is ALWAYS passed explicitly by the caller (never the ambient
#     kube-context — repeated service names across clusters make ambient unsafe),
#     and --request-timeout bounds every call.
#   * Secret values never reach the caller: log slices pass through the shared
#     redaction filter and are --tail capped; `get secret -o yaml|json` is not
#     an operation this library offers.
#
# Sourced (not executed): defines functions only, sets no shell options on the
# caller. Reuses skills/redaction/lib/redaction.sh (redact_content) when present.

# Read-only kubectl verbs this library will run. Nothing else is permitted.
LE_ALLOWED_VERBS="get describe list logs top events version api-resources auth config"

# le_verb_ok <verb> — 0 if the verb is an allowlisted read verb, 1 otherwise.
le_verb_ok() {
  le_v="$1"
  for le_a in $LE_ALLOWED_VERBS; do
    [ "$le_v" = "$le_a" ] && return 0
  done
  return 1
}

# le_kubectl <context> <verb> [args...] — the ONLY path to kubectl in this lib.
# Refuses a non-read verb (defense in depth behind the CI static check), always
# pins --context explicitly, and bounds the call with --request-timeout.
le_kubectl() {
  le_ctx="$1"; le_verb="$2"; shift 2
  [ -n "$le_ctx" ] || { echo "live-evidence: refusing kubectl with no explicit --context" >&2; return 2; }
  le_verb_ok "$le_verb" || { echo "live-evidence: refusing non-read kubectl verb '$le_verb'" >&2; return 2; }
  kubectl --context "$le_ctx" --request-timeout=15s "$le_verb" "$@"
}

# le_redact — pass stdin through the shared secret-redaction filter if available,
# otherwise a conservative built-in fallback so a slice is never emitted raw.
le_redact() {
  if command -v redact_content >/dev/null 2>&1; then
    redact_content
  else
    sed -E 's/(AKIA|ASIA)[0-9A-Z]{16}/\1[REDACTED]/g; s/(sk_live_|sk_test_|github_pat_)[A-Za-z0-9]{20,}/\1[REDACTED]/g; s/Bearer [A-Za-z0-9._-]{40,}/Bearer [REDACTED]/g'
  fi
}

# --- probes ------------------------------------------------------------------
# Each probe is read-only, pins --context, and emits a compact JSON record on
# stdout (or, for logs, a redacted text slice). A failed/blocked call prints
# nothing on stdout and a reason on stderr — the caller records that as a gap
# with verdict=unknown, never as "healthy".

# probe_pod_status <context> <namespace> <pod>
# The core liveness signal: phase, per-container restartCount, current waiting
# reason (CrashLoopBackOff/ImagePullBackOff/CreateContainerError), and the last
# terminated state (reason=OOMKilled + exitCode=137, etc.).
probe_pod_status() {
  le_kubectl "$1" get pod "$3" -n "$2" -o json 2>/dev/null | jq '{
    phase: .status.phase,
    startTime: .status.startTime,
    containers: [ .status.containerStatuses[]? | {
      name, ready, restartCount,
      waiting_reason:   (.state.waiting.reason // null),
      terminated_reason:(.lastState.terminated.reason // null),
      exit_code:        (.lastState.terminated.exitCode // null),
      finished_at:      (.lastState.terminated.finishedAt // null)
    } ],
    conditions: [ .status.conditions[]? | {type, status, reason} ]
  }' 2>/dev/null
}

# probe_events <context> <namespace> <object-name>
# Recent Warning events for the object (bounded), newest last. FailedScheduling,
# BackOff, Unhealthy (probe failures), Failed (image pull) all surface here.
probe_events() {
  le_kubectl "$1" get events -n "$2" \
    --field-selector "involvedObject.name=$3,type=Warning" \
    --sort-by=.lastTimestamp -o json 2>/dev/null \
    | jq '[ .items[]? | {reason, message, count, lastTimestamp} ] | .[-20:]' 2>/dev/null
}

# probe_rollout <context> <namespace> <deployment>
# Workload-level view: desired vs ready vs unavailable replicas and conditions.
probe_rollout() {
  le_kubectl "$1" get deploy "$3" -n "$2" -o json 2>/dev/null | jq '{
    replicas: (.status.replicas // 0),
    ready: (.status.readyReplicas // 0),
    updated: (.status.updatedReplicas // 0),
    unavailable: (.status.unavailableReplicas // 0),
    conditions: [ .status.conditions[]? | {type, status, reason, message} ]
  }' 2>/dev/null
}

# probe_owner <context> <namespace> <pod>
# Ownership chain for target resolution (pod -> ReplicaSet -> Deployment),
# reported as "Kind/name" lines. Uses only identity metadata, never blames it.
probe_owner() {
  po_ctx="$1"; po_ns="$2"; po_pod="$3"
  po_owner="$(le_kubectl "$po_ctx" get pod "$po_pod" -n "$po_ns" -o json 2>/dev/null \
    | jq -r '.metadata.ownerReferences[]? | "\(.kind)/\(.name)"' 2>/dev/null | head -1)"
  [ -n "$po_owner" ] || return 0
  echo "$po_owner"
  case "$po_owner" in
    ReplicaSet/*)
      po_rs="${po_owner#ReplicaSet/}"
      le_kubectl "$po_ctx" get rs "$po_rs" -n "$po_ns" -o json 2>/dev/null \
        | jq -r '.metadata.ownerReferences[]? | "\(.kind)/\(.name)"' 2>/dev/null | head -1 ;;
  esac
}

# probe_logs_previous <context> <namespace> <pod> [container] [tail]
# The previous container's logs (why it died last), redacted and --tail capped.
# Never emits raw logs: every line passes through le_redact. Default cap 50.
probe_logs_previous() {
  pl_ctx="$1"; pl_ns="$2"; pl_pod="$3"; pl_container="${4:-}"; pl_tail="${5:-50}"
  if [ -n "$pl_container" ]; then
    le_kubectl "$pl_ctx" logs "$pl_pod" -n "$pl_ns" -c "$pl_container" --previous --tail="$pl_tail" 2>/dev/null | le_redact
  else
    le_kubectl "$pl_ctx" logs "$pl_pod" -n "$pl_ns" --previous --tail="$pl_tail" 2>/dev/null | le_redact
  fi
}

# le_can_probe <context> — degrade-not-block readiness for the live path.
# 0 when kubectl exists, the context resolves in kubeconfig, and a read is
# authorized; non-zero otherwise (caller falls back to report-only). Read-only:
# `auth can-i get pods` and `config get-contexts` mutate nothing.
le_can_probe() {
  lc_ctx="$1"
  command -v kubectl >/dev/null 2>&1 || { echo "live-evidence: kubectl not installed" >&2; return 1; }
  [ -n "$lc_ctx" ] || { echo "live-evidence: no kubernetes.context configured" >&2; return 1; }
  le_kubectl "$lc_ctx" config get-contexts -o name 2>/dev/null | grep -qx "$lc_ctx" \
    || { echo "live-evidence: context '$lc_ctx' not in kubeconfig" >&2; return 1; }
  le_kubectl "$lc_ctx" auth can-i get pods >/dev/null 2>&1 \
    || { echo "live-evidence: not authorized to get pods on '$lc_ctx'" >&2; return 1; }
  return 0
}
