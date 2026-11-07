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
  # config/auth contain writes as well as reads. Only these read subcommands
  # are part of the probe contract; a verb-only allowlist is not sufficient.
  case "$le_verb:${1:-}" in
    config:view|config:get-contexts|auth:can-i) ;;
    config:*|auth:*) echo "live-evidence: refusing non-read kubectl subcommand" >&2; return 2 ;;
  esac
  # A later global flag overrides the context pinned below. Do not let a probe
  # switch identity, endpoint, credentials or kubeconfig through its arguments.
  for le_arg do
    case "$le_arg" in
      --request-timeout|--request-timeout=*|--context|--context=*|--kubeconfig|--kubeconfig=*|--cluster|--cluster=*|--user|--user=*|--server|--server=*|-s|-s=*|-s?*|--as|--as=*|--as-group|--as-group=*|--as-uid|--as-uid=*|--token|--token=*|--username|--username=*|--password|--password=*|--client-certificate|--client-certificate=*|--client-key|--client-key=*|--certificate-authority|--certificate-authority=*|--insecure-skip-tls-verify|--insecure-skip-tls-verify=*|--tls-server-name|--tls-server-name=*|--raw|--raw=*)
        echo "live-evidence: refusing a credential, target or raw-output override" >&2; return 2 ;;
    esac
  done
  kubectl --context "$le_ctx" --request-timeout=15s "$le_verb" "$@"
}

# le_redact — pass stdin through the shared secret-redaction filter if available,
# or fail closed; free text must never use a weaker fallback.
le_redact() {
  # Never fall back to a narrower pattern set for free-text provider evidence.
  if ! command -v redact_content >/dev/null 2>&1; then
    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -r "$CLAUDE_PLUGIN_ROOT/skills/redaction/lib/redaction.sh" ]; then
      . "$CLAUDE_PLUGIN_ROOT/skills/redaction/lib/redaction.sh"
    else
      echo 'live-evidence: shared redaction unavailable; free-text evidence withheld' >&2
      return 1
    fi
  fi
  redact_content
}

# Project first, redact while still in memory, validate before stdout. An error
# cannot turn an invalid projection or failed filter into successful empty data.
le_safe_json() {
  ls_raw=$(cat) || return 1
  ls_safe=$(printf '%s' "$ls_raw" | le_redact) || return 1
  printf '%s' "$ls_safe" | jq -ce -s 'select(length==1) | .[0]' 2>/dev/null
}

# Capture provider status before jq: an empty or partial failed read cannot
# become a successful empty projection through a pipeline.
le_read_json() {
  le_json="$(le_kubectl "$@" 2>/dev/null)" || { echo "live-evidence: provider read failed" >&2; return 1; }
  printf '%s' "$le_json" | jq -ce -s 'select(length==1) | .[0] | select(type=="object")' 2>/dev/null \
    || { echo "live-evidence: provider returned no valid JSON object" >&2; return 1; }
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
  pp_json="$(le_read_json "$1" get pod "$3" -n "$2" -o json)" || return 1
  printf '%s' "$pp_json" | jq -e 'select(.status|type=="object") | {
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
  pe_json="$(le_read_json "$1" get events -n "$2" \
    --field-selector "involvedObject.name=$3,type=Warning" \
    --sort-by=.lastTimestamp -o json)" || return 1
  pe_projection=$(printf '%s' "$pe_json" | jq -ce 'select(.items|type=="array") | [ .items[]? | {reason, message, count, lastTimestamp} ] | .[-20:]' 2>/dev/null) || return 1
  printf '%s' "$pe_projection" | le_safe_json
}

# probe_rollout <context> <namespace> <deployment>
# Workload-level view: desired vs ready vs unavailable replicas and conditions.
probe_rollout() {
  pr_json="$(le_read_json "$1" get deploy "$3" -n "$2" -o json)" || return 1
  pr_projection=$(printf '%s' "$pr_json" | jq -ce 'select(.status|type=="object") | {
    replicas: (.status.replicas // 0),
    ready: (.status.readyReplicas // 0),
    updated: (.status.updatedReplicas // 0),
    unavailable: (.status.unavailableReplicas // 0),
    conditions: [ .status.conditions[]? | {type, status, reason, message} ]
  }' 2>/dev/null) || return 1
  printf '%s' "$pr_projection" | le_safe_json
}

# probe_owner <context> <namespace> <pod>
# Ownership chain for target resolution (pod -> ReplicaSet -> Deployment),
# reported as "Kind/name" lines. Uses only identity metadata, never blames it.
probe_owner() {
  po_ctx="$1"; po_ns="$2"; po_pod="$3"
  po_json="$(le_read_json "$po_ctx" get pod "$po_pod" -n "$po_ns" -o json)" || return 1
  printf '%s' "$po_json" | jq -e '.metadata|type=="object"' >/dev/null || return 1
  po_owner="$(printf '%s' "$po_json" | jq -r '[.metadata.ownerReferences[]? | "\(.kind)/\(.name)"][0] // empty')" || return 1
  [ -n "$po_owner" ] || return 0
  po_parent=
  case "$po_owner" in
    ReplicaSet/*)
      po_rs="${po_owner#ReplicaSet/}"
      po_json="$(le_read_json "$po_ctx" get rs "$po_rs" -n "$po_ns" -o json)" || return 1
      printf '%s' "$po_json" | jq -e '.metadata|type=="object"' >/dev/null || return 1
      po_parent="$(printf '%s' "$po_json" | jq -r '[.metadata.ownerReferences[]? | "\(.kind)/\(.name)"][0] // empty')" || return 1 ;;
  esac
  printf '%s\n' "$po_owner"
  [ -z "$po_parent" ] || printf '%s\n' "$po_parent"
}

# probe_logs_previous <context> <namespace> <pod> [container] [tail]
# The previous container's logs (why it died last), redacted and --tail capped.
# Never emits raw logs: every line passes through le_redact. Default cap 50.
probe_logs_previous() {
  pl_ctx="$1"; pl_ns="$2"; pl_pod="$3"; pl_container="${4:-}"; pl_tail="${5:-50}"
  case "$pl_tail" in ''|*[!0-9]*) echo "live-evidence: log tail must be a nonnegative bound" >&2; return 2 ;; esac
  if [ -n "$pl_container" ]; then
    pl_text="$(le_kubectl "$pl_ctx" logs "$pl_pod" -n "$pl_ns" -c "$pl_container" --previous --tail="$pl_tail" 2>/dev/null)" \
      || { echo "live-evidence: previous log read failed" >&2; return 1; }
  else
    pl_text="$(le_kubectl "$pl_ctx" logs "$pl_pod" -n "$pl_ns" --previous --tail="$pl_tail" 2>/dev/null)" \
      || { echo "live-evidence: previous log read failed" >&2; return 1; }
  fi
  printf '%s\n' "$pl_text" | le_redact
}

# le_can_probe <context> — degrade-not-block readiness for the live path.
# 0 when kubectl exists, the context resolves in kubeconfig, and a read is
# authorized; non-zero otherwise (caller falls back to report-only). Read-only:
# `auth can-i get pods` and `config get-contexts` mutate nothing.
le_can_probe() {
  lc_ctx="$1"
  command -v kubectl >/dev/null 2>&1 || { echo "live-evidence: kubectl not installed" >&2; return 1; }
  [ -n "$lc_ctx" ] || { echo "live-evidence: no kubernetes.context configured" >&2; return 1; }
  lc_contexts="$(le_kubectl "$lc_ctx" config get-contexts -o name 2>/dev/null)" \
    || { echo "live-evidence: context lookup failed" >&2; return 1; }
  printf '%s\n' "$lc_contexts" | grep -Fqx -- "$lc_ctx" \
    || { echo "live-evidence: context '$lc_ctx' not in kubeconfig" >&2; return 1; }
  le_kubectl "$lc_ctx" auth can-i get pods >/dev/null 2>&1 \
    || { echo "live-evidence: not authorized to get pods on '$lc_ctx'" >&2; return 1; }
  return 0
}
