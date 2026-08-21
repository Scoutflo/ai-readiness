# audit-kubernetes: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-kubernetes](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. Every command passes `--context "$KUBE_CONTEXT"` explicitly.

## 1. Conventions

- `KUBE_CONTEXT` is `kubernetes.context` from toolkit.yaml and is passed on **every** call. The active/current context is never used for targeting.
- Every command is read-only: `kubectl get`, `kubectl auth can-i`, `kubectl api-resources`, `kubectl version`, `kubectl config view`. The live-runtime snapshot (section 10) additionally uses the read-only `top` verb and `get events`, only through the guarded `le_kubectl` wrapper from the shared live-evidence library. No mutating verb appears anywhere (forbidden list, section 9).
- Secret **values** are never read. `kubectl get secret` (names/types) is allowed; `kubectl get secret -o yaml`/`-o json` with `.data` is forbidden.
- `-o json | jq` is the parsing path. A `Forbidden` from the API server on a specific `get`/`list` means the audit credential lacks that `view` grant → record `blocked` for the check naming the exact resource.
- Thresholds/namespace classifications are examples; tune to your cluster. Named defaults live in section 8.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| K8S-001 | Security | Application namespaces enforce a Pod Security Admission standard (`pod-security.kubernetes.io/enforce`) | high |
| K8S-002 | Security | No workload ServiceAccount holds cluster-wide wildcard (`*/*/*`) or cluster-admin RBAC | high (critical if publicly exposed) |
| K8S-006 | Security | No ServiceAccount has cluster-wide `secrets get/list` beyond what it needs | medium |
| K8S-003 | Network | Application namespaces have at least one NetworkPolicy (not a flat open network) | high |
| K8S-004 | Reliability | Deployments/StatefulSets/DaemonSets set container resource requests and limits | medium |
| K8S-005 | Reliability | Critical single-replica workloads have a PodDisruptionBudget | medium |

The parallel non-scored live-runtime snapshot IDs (`K8SRT-NNN`, always `info`, never scored) are cataloged in section 10.

## 3. Pod Security (K8S-001)

```bash
# Server version FIRST — decides PSA (1.25+) vs PSP (<1.25).
kubectl --context "$KUBE_CONTEXT" version -o json | jq -r '.serverVersion.gitVersion'

# PSA: enforce label per namespace (1.25+). Empty enforce = unconstrained.
kubectl --context "$KUBE_CONTEXT" get ns -o json \
  | jq -r '.items[] | "\(.metadata.name)\tenforce=\(.metadata.labels["pod-security.kubernetes.io/enforce"] // "none")\twarn=\(.metadata.labels["pod-security.kubernetes.io/warn"] // "none")"'

# Supporting evidence: workloads that would violate baseline.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json \
  | jq -r '.items[] | select(.spec.hostNetwork==true or .spec.hostPID==true or (.spec.containers[]?.securityContext.privileged==true)) | "\(.metadata.namespace)/\(.metadata.name): privileged/hostNetwork/hostPID"'
```

Healthy: every application namespace has `enforce=baseline` or `restricted`. Fail (K8S-001): application namespaces show `enforce=none`. On a `<1.25` server, instead check `kubectl get psp` and note the cluster is on an unsupported version; on 1.25+ `psp` returns `the server doesn't have a resource type "podsecuritypolicies"` — that is expected, not a finding.

## 4. RBAC (K8S-002, K8S-006)

```bash
# ClusterRoles granting wildcard verbs on wildcard resources.
kubectl --context "$KUBE_CONTEXT" get clusterroles -o json \
  | jq -r '.items[] | select(.rules[]? | (.verbs[]?=="*") and (.resources[]?=="*") and (.apiGroups[]?=="*")) | .metadata.name' | sort -u

# Who is each wildcard/cluster-admin ClusterRole bound to? Flag ServiceAccount subjects.
kubectl --context "$KUBE_CONTEXT" get clusterrolebindings -o json \
  | jq -r '.items[] | . as $b | .subjects[]? | select(.kind=="ServiceAccount") | "\($b.roleRef.name) -> sa:\(.namespace)/\(.name)"'

# K8S-006: ServiceAccounts with cluster-wide secrets get/list.
kubectl --context "$KUBE_CONTEXT" get clusterroles -o json \
  | jq -r '.items[] | select(.rules[]? | (.resources[]?=="secrets") and ((.verbs[]?=="get") or (.verbs[]?=="list") or (.verbs[]?=="*"))) | .metadata.name'
```

Healthy: no `*/*/*` ClusterRole bound to a workload ServiceAccount. Fail (K8S-002): a binding like `platform-cr -> sa:app-ns/app-sa` where `platform-cr` is `*/*/*`. Raise to critical if that ServiceAccount's workload sits behind a public ingress (cross-check `kubectl get ingress -A`). A wildcard bound only to a human group (e.g. `system:masters`, an SSO admin group) is a posture note.

## 5. Network segmentation (K8S-003)

```bash
# NetworkPolicies per namespace.
kubectl --context "$KUBE_CONTEXT" get networkpolicy -A -o json \
  | jq -r 'group_by(.items[]?.metadata.namespace) | .[]? ' 2>/dev/null
kubectl --context "$KUBE_CONTEXT" get networkpolicy -A --no-headers 2>/dev/null | awk '{print $1}' | sort | uniq -c

# Application namespaces with ZERO policies (the finding).
# (temp files, not process substitution: these blocks run under plain /bin/sh)
NP_TMP="${TMPDIR:-/tmp}/k8s003.$$"
kubectl --context "$KUBE_CONTEXT" get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort > "${NP_TMP}.all"
kubectl --context "$KUBE_CONTEXT" get networkpolicy -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u > "${NP_TMP}.with"
comm -23 "${NP_TMP}.all" "${NP_TMP}.with"
rm -f "${NP_TMP}.all" "${NP_TMP}.with"
```

Healthy: each application namespace appears with ≥1 NetworkPolicy. Fail (K8S-003): application namespaces (e.g. the one running checkout/orders/payments) appear in the zero-policy list — any pod can reach any other. System namespaces (`kube-system`, `kube-node-lease`) are excluded from the finding.

## 6. Resource governance (K8S-004)

```bash
kubectl --context "$KUBE_CONTEXT" get deploy,sts,ds -A -o json \
  | jq -r '.items[] | . as $w | $w.spec.template.spec.containers[] | select((.resources.limits==null)) | "\($w.kind)/\($w.metadata.namespace)/\($w.metadata.name): container \(.name) has no limits (requests=\(.resources.requests != null))"'
```

Healthy: shared-path and application workloads set both requests and limits. Fail (K8S-004): the ingress controller or an application Deployment has `limits==null`. Requests-set-but-no-limits is a partial.

## 7. Resilience (K8S-005)

```bash
# PDBs present.
kubectl --context "$KUBE_CONTEXT" get pdb -A --no-headers 2>/dev/null | wc -l

# Single-replica Deployments (candidates) and whether a PDB selects them.
kubectl --context "$KUBE_CONTEXT" get deploy -A -o json \
  | jq -r '.items[] | select((.spec.replicas // 1) == 1) | "\(.metadata.namespace)/\(.metadata.name): replicas=1"'
```

Healthy: critical workloads have replicas>1 or a PDB with `minAvailable`. Fail (K8S-005): a critical service is `replicas=1` and no PDB selects it — a node drain takes it down. Cross-reference the critical-service list from Phase 1; a single-replica non-critical batch job is at most low.

## 8. Named defaults

| Knob | Default | Why |
| --- | --- | --- |
| Enforced PSA standard | `baseline` (target `restricted`) | baseline blocks the worst pod escapes without breaking most workloads |
| Application namespace | any ns not `kube-system`/`kube-node-lease`/`kube-public`/`gke-*`/provider-system | scopes the network + PSA findings to workloads you own |
| Critical single-replica severity | medium (high if named critical in business context) | node drains are routine; a single replica is a real availability gap |

## 9. Forbidden commands (read-only guarantee)

Never run any of these — they mutate the cluster:

`kubectl apply`, `create`, `edit`, `patch`, `replace`, `delete`, `label`, `annotate`, `scale`, `rollout`, `set`, `cordon`, `drain`, `uncordon`, `taint`, `exec`, `cp`, `port-forward` (as a mutation path), `auth reconcile`, and `kubectl get secret -o yaml`/`-o json` (reads Secret values). This audit only ever `get`/`list`/`auth can-i`/`version`/`api-resources`/`config view`, plus — in the live-runtime snapshot (section 10) only, through the guarded `le_kubectl` wrapper — the read-only `top` verb. The wrapper's allowlist contains no mutating verb, and `ci/liveness-readonly-check.sh` enforces that mechanically.

## 10. Live-runtime snapshot (K8SRT — evidence, not scored)

Serves the SKILL's Phase 8. Every probe routes through `le_kubectl` from the shared live-evidence library ([skills/live-evidence/lib/live-evidence.sh](../../live-evidence/lib/live-evidence.sh)): allowlisted read verbs only, explicit `--context`, every call bounded by `--request-timeout`; the read-only guarantee is enforced by `ci/liveness-readonly-check.sh`. The IDs below form a parallel non-scored section per the findings schema: `area: live-runtime`, always severity `info` and `points_recoverable: 0`, never present in `score.categories` or `score.excluded`. Snapshot facts are tagged `[live@<ISO8601>]`. The failure taxonomy that decides when an observation may be *named* (a cause-class field vs a bare symptom) is shared with rca: [live-evidence/references/k8s-liveness-probes.md](../../live-evidence/references/k8s-liveness-probes.md).

| ID | Signal | Emit only when this exact field is observed |
| --- | --- | --- |
| K8SRT-001 | Container in a crash/backoff waiting state now | `state.waiting.reason` is `CrashLoopBackOff`/`ImagePullBackOff`/`ErrImagePull`/`CreateContainerConfigError`; cite it together with `lastState.terminated.reason` + `exitCode` when present |
| K8SRT-002 | Container OOMKilled in its last termination | `lastState.terminated.reason = OOMKilled` (typically `exitCode = 137`); when K8S-004 flagged the same workload, also cite this observation in K8S-004's evidence and mark that finding `validated-live` |
| K8SRT-003 | Warning-event burst in an application namespace | observed events with `type=Warning` (`FailedScheduling`/`Unhealthy`/`BackOff`/`Failed`); cite reason, involved object, count |
| K8SRT-004 | Node or pod resource pressure | metrics-server answered `top` and a node or pod shows saturation; cite the observed lines. Never emitted when metrics-server is absent |

```bash
# Stateless: source the guarded probe lib first (redaction first so probe output is filtered).
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh" 2>/dev/null || true
. "${CLAUDE_PLUGIN_ROOT}/skills/live-evidence/lib/live-evidence.sh"

# Gate: no probe runs when live access is unavailable (skip with the exact reason).
le_can_probe "$KUBE_CONTEXT"

# Containers restarting or stuck in a waiting state right now (K8SRT-001/002).
le_kubectl "$KUBE_CONTEXT" get pods -A -o json | jq -r '
  .items[] | . as $p | .status.containerStatuses[]?
  | select((.restartCount // 0) > 0 or ((.state.waiting.reason // "") != ""))
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\(.name)\trestarts=\(.restartCount // 0)\twaiting=\(.state.waiting.reason // "-")\tlast=\(.lastState.terminated.reason // "-")/exit=\(.lastState.terminated.exitCode // "-")"'

# Recent Warning events, newest last (K8SRT-003).
le_kubectl "$KUBE_CONTEXT" get events -A --field-selector type=Warning --sort-by=.lastTimestamp -o json \
  | jq -r '.items[-20:] | .[] | "\(.lastTimestamp)\t\(.involvedObject.namespace // "-")/\(.involvedObject.name)\t\(.reason)\tcount=\(.count // 1)"'

# Node/pod usage (K8SRT-004) — only when metrics-server answers; skip with the reason otherwise.
le_kubectl "$KUBE_CONTEXT" top nodes
le_kubectl "$KUBE_CONTEXT" top pods -A --sort-by=memory | head -15

# Per-critical-service rollout state and events, keyed on namespace + name from
# topology-export.json (attributes.namespace + name — never bare name; two services
# sharing a name in different namespaces are two probe targets).
probe_rollout "$KUBE_CONTEXT" "$NS" "$SVC"
probe_events  "$KUBE_CONTEXT" "$NS" "$SVC"
```

This section has no pass/fail. A probe that returns nothing, times out, or is RBAC-denied is recorded `skipped, reason: <exact error>` — verdict unknown, never healthy, never converted to a finding. `top` on a cluster without metrics-server (no `metrics.k8s.io` API) is the expected shape on many clusters: skip with that reason; it is not an error and not a finding. Where metrics-server exists, its default RBAC aggregates `system:aggregated-metrics-reader` into the `view` ClusterRole, so the audit credential from the doctor gate usually covers `top`; a denial is still just a skip. A bare `restartCount` with no terminated reason or Warning event is a symptom row in the snapshot table, never a K8SRT finding. This section never calls `logs`; previous-container log depth belongs to `/scoutflo:rca`.
