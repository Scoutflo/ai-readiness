---
name: audit-kubernetes
description: Read-only scored audit of a Kubernetes cluster's security and operational posture — Pod Security Admission enforcement, RBAC over-permissioning, network-policy coverage, workload resource limits, and PodDisruptionBudget/replica resilience; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring a Kubernetes/EKS/GKE/AKS cluster, pod security, cluster RBAC, network policies, missing resource limits, or single-replica critical workloads. Do not use to change the cluster (there is no in-cluster mutation here; findings name the fix), for in-cluster Prometheus/Grafana telemetry (use audit-lgtm / audit-grafana), or for cloud-provider control-plane alarms (use audit-aws / audit-gcp).
---

# audit-kubernetes

Scored, read-only audit of a Kubernetes cluster's security and reliability posture: whether pods run under an enforced security standard, whether any workload identity holds far more RBAC than it needs, whether the pod network is segmented, whether workloads declare resource limits, and whether critical workloads can survive a node drain. It answers one question: if this cluster is attacked or loses a node tonight, does its own configuration contain the blast radius, or amplify it?

This audit reads cluster **objects** (via `kubectl get`/`auth can-i`). Whether the in-cluster observability stack is healthy is `audit-lgtm`/`audit-grafana`; the cloud provider's own control-plane monitoring is `audit-aws`/`audit-gcp`. This audit stops at the cluster's own security and workload configuration.

Every command is read-only: `kubectl get`, `kubectl auth can-i`, `kubectl api-resources`, `kubectl version`. No `apply`, `create`, `edit`, `patch`, `delete`, `label`, `annotate`, `scale`, `cordon`, or `exec` — the full forbidden list is in [references/kubernetes-checks.md](references/kubernetes-checks.md) section 9. `setup-kubernetes` performs the confirm-then-verify fixes; this audit only names them.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/kubernetes/<context>/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `K8S-NNN`. The `<context>` directory segment exists because one machine's kubeconfig routinely reaches several clusters; each cluster gets its own history.
- `./scoutflo-audits/kubernetes/<context>/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md)
- One appended line in `./scoutflo-audits/kubernetes/<context>/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Kubernetes | `kubernetes.context` | none (identity comes from the kubeconfig context) | built-in `view` ClusterRole (`get`/`list` on pods, deployments, services, networkpolicies, roles, rolebindings, clusterroles, clusterrolebindings, poddisruptionbudgets, namespaces) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done

# kubernetes.context names the exact context to audit. It is passed explicitly on
# EVERY kubectl call; the current/active context is never used for targeting, so a
# stray `kubectl config use-context` elsewhere cannot silently redirect this audit.
KUBE_CONTEXT="my-cluster"   # kubernetes.context
kubectl config get-contexts -o name | grep -qx "$KUBE_CONTEXT" \
  || { echo "context '$KUBE_CONTEXT' not in kubeconfig; run kubectl config get-contexts, fix kubernetes.context"; exit 1; }
kubectl --context "$KUBE_CONTEXT" auth can-i get pods -A >/dev/null 2>&1 \
  || { echo "context reaches no cluster or lacks read RBAC; bind the view ClusterRole (connect references/providers.md)"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same `auth can-i` probe standalone.

## Live-safety gate

Print what you are pointed at and confirm it before the first real check:

```bash
set -eu
KUBE_CONTEXT="my-cluster"   # kubernetes.context
SERVER="$(kubectl --context "$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
VER="$(kubectl --context "$KUBE_CONTEXT" version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"')"
NS_COUNT="$(kubectl --context "$KUBE_CONTEXT" get ns -o json | jq '.items | length')"
echo "context=${KUBE_CONTEXT} server=${SERVER} k8s=${VER} namespaces=${NS_COUNT}"
echo "live-safety gate: pass — confirm this is the cluster you intend to audit"
```

The context selects the cluster; there is no ambient default in this audit. The server URL and version are the human confirmation, and the version drives the Pod Security check below (PSP vs PSA).

## Ground rules

- Configuration is metadata; observed behavior is proof. A namespace with a `pod-security.kubernetes.io/enforce` label is `configured`; a workload actually admitted under that standard is `validated-live`.
- **PodSecurityPolicy was removed in Kubernetes 1.25.** Detect the server version first. On 1.25+ (every currently-supported cluster) the pod-security check evaluates **Pod Security Admission** — the `pod-security.kubernetes.io/{enforce,audit,warn}` labels on namespaces — and a "missing PSP" result is meaningless and must not be emitted. Only on a server genuinely older than 1.25 does the check fall back to PSP discovery.
- Never score from object counts.
  - ❌ `Scored security 90: RBAC has 200 bindings.`
  - ✅ `Scored security 40: 200 bindings exist, but one workload ServiceAccount is bound to a `*/*/*` ClusterRole and three application namespaces carry no enforce label; credit stops at partial.`
- RBAC severity is about *who* holds the grant. A wildcard ClusterRole bound to a human break-glass group is a posture note; the same grant bound to a **workload ServiceAccount** (especially one reachable from a public ingress) is high — a pod compromise becomes cluster compromise.
- Errors are evidence. An RBAC `Forbidden` on a specific list means the audit credential lacks that `view` grant; record `blocked` for that check with the exact resource, never convert it to a pass.
- Captures keep object names, namespaces, kinds, and RBAC verbs/resources. Never capture Secret *values*; this audit never reads Secret data (`kubectl get secret -o yaml` is forbidden — only names/types via `get secret` without `-o yaml`).

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
KUBE_CONTEXT="my-cluster"   # kubernetes.context
OBJ="$(kubectl --context "$KUBE_CONTEXT" get pods,deploy,sts,ds,svc,networkpolicy,pdb -A -o json 2>/dev/null | jq '.items | length')"
if   [ "$OBJ" -lt 200 ];  then P=small
elif [ "$OBJ" -lt 1000 ]; then P=medium
elif [ "$OBJ" -lt 4000 ]; then P=large
else P=xlarge; fi
echo "estate: ${OBJ} objects, ${P} path"
```

Record `estate: {objects, path}` in `findings.json`. On `xlarge`, scope by namespace (ask the user which namespaces matter) rather than listing every object cluster-wide in one pass.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# audit-kubernetes sizing counts objects into OBJ, not TOTAL; set TOTAL from the estate object count computed above.
TOTAL="${OBJ:?estate sizing must set OBJ (the estate object count) before the scope checkpoint}"
: "${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` or a business-context file names critical services, load them (see [Metadata Load](#metadata-load-v0168) below). They set which workloads make the Reliability checks high vs medium and which namespaces are "application namespaces" for the network-policy check. Without them, treat every non-system namespace as an application namespace and every workload equally.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/kubernetes-checks.md](references/kubernetes-checks.md) section 2: server version; namespaces with their `pod-security.kubernetes.io/*` labels; ClusterRoles/ClusterRoleBindings/Roles/RoleBindings; NetworkPolicies per namespace; Deployments/StatefulSets/DaemonSets with their container resource requests/limits; PodDisruptionBudgets and replica counts. Judgment starts in Phase 3.

## Phase 3: Pod security (K8S-001)

Commands in section 3. On 1.25+, judge Pod Security Admission: every application namespace should carry a `pod-security.kubernetes.io/enforce` label at `baseline` or `restricted` (`K8S-001`, high when no application namespace enforces any standard — pods run unconstrained). Note privileged/hostNetwork/hostPID workloads that would violate `baseline` as supporting evidence. On <1.25, fall back to PSP presence and note the cluster is on an unsupported version.

## Phase 4: RBAC (K8S-002)

Commands in section 4. Find subjects with cluster-wide wildcard power: ClusterRoles granting `*` verbs on `*` resources in `*` API groups, and who they are bound to (`K8S-002`, high when bound to a workload ServiceAccount, critical when that workload is also exposed via a public ingress). Flag direct `cluster-admin` bindings to ServiceAccounts, and ServiceAccounts with cluster-wide `secrets` `get`/`list` (`K8S-006`). Break-glass human/group bindings are recorded as posture notes, not high findings.

## Phase 5: Network segmentation (K8S-003)

Commands in section 5. Per application namespace: at least one NetworkPolicy selecting its pods, and a default-deny ingress posture rather than a flat open network (`K8S-003`, high when application namespaces have zero NetworkPolicies — any pod can reach any other). Egress policies are a plus, not required for a pass.

## Phase 6: Workload resource governance (K8S-004)

Commands in section 6. Deployments/StatefulSets/DaemonSets whose containers set neither requests nor limits (`K8S-004`, medium — an unbounded container can starve a node; the ingress controller and other shared-path workloads are the highest-value cases). Requests-without-limits is a partial, not a full pass.

## Phase 7: Resilience (K8S-005)

Commands in section 7. Critical workloads (from Phase 1, else all application Deployments) that run a single replica **and** have no PodDisruptionBudget (`K8S-005`, medium — a node drain or upgrade takes the service down with no minAvailable guard). A single replica *with* a PDB, or multiple replicas, passes.

## Phase 8: Coverage matrix and topology readiness

Per the report standard, render the per-service coverage matrix and the Scoutflo Topology Readiness section for the critical services named in Phase 1: for each, does it have an enforced pod-security namespace, a NetworkPolicy, resource limits, and PDB/replica resilience. A service missing all four is `0 of 4`; state the count in plain language (see [topology-readiness.md](../../report-standard/topology-readiness.md)).

## Phase 9: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0); `not-in-scope` (e.g. the PSP branch on a 1.25+ server) leaves the denominator. Category score is the credit ratio × 100 floored; overall is the weight-normalized sum over included categories, conservatively.

| Category | Weight | Checks |
| --- | --- | --- |
| Security | 40 | K8S-001 (pod security), K8S-002 (RBAC), K8S-006 (secret-reader SAs) |
| Network | 30 | K8S-003 (network policies) |
| Reliability | 30 | K8S-004 (resource limits), K8S-005 (PDB/replicas) |

Full check catalog and target profile at the top of [references/kubernetes-checks.md](references/kubernetes-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects (namespace/kind/name) enumerated in `affected`. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings carry 0. The executive summary states the gap to target and the two or three highest-`points_recoverable` findings as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base posture", never "end to end".

Write `findings.json` first (canonical), then regenerate `report.md`, the history line, and the Slack brief from it. Validate `findings.json` with `report-standard/check-findings.sh` (score reconciles with the scorecard, schema complete) and the report with `report-standard/check-report.sh` (shape).

## Metadata Load (v0.1.68+)

This skill reads optional business context metadata to apply intelligent filtering:

```bash
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
CONTEXT="${HOME}/.scoutflo/business_context.md"
LOAD_METADATA_MODE="none"

if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="v0168"
elif [ -f "$CONTEXT" ]; then
  LOAD_METADATA_MODE="v0167"
fi
```

When metadata is available: mark the critical services (raising their Reliability findings to high), skip namespaces flagged as excluded, and honor declared ownership for the coverage matrix. See [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md) for patterns.

## Remediation pointers

| Finding family | Fix path |
| --- | --- |
| No pod-security enforcement (K8S-001) | Label application namespaces `pod-security.kubernetes.io/enforce=baseline` (then `restricted` once workloads comply) — `setup-kubernetes#enforce-pod-security` |
| Over-permissioned workload RBAC (K8S-002, K8S-006) | Replace the wildcard/cluster-admin binding with a least-privilege Role scoped to the namespace and verbs the workload needs — `setup-kubernetes#tighten-rbac` |
| Flat pod network (K8S-003) | Add a default-deny ingress NetworkPolicy per application namespace, then allow-list the flows — `setup-kubernetes#add-network-policies` |
| Missing resource limits (K8S-004) | Set requests and limits on the flagged workloads (or a LimitRange on the namespace) — `setup-kubernetes#set-resource-limits` |
| Single-replica critical service, no PDB (K8S-005) | Raise replicas and add a PodDisruptionBudget with minAvailable — `setup-kubernetes#add-disruption-budgets` |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Audit completed (findings may exist) |
| 1 | kubectl or jq not installed |
| 2 | `kubernetes.context` not found in kubeconfig, or unreachable |
| 3 | RBAC denied (insufficient `view` permissions to complete the audit) |

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Auditing PodSecurityPolicy on a 1.25+ cluster | Detect server version first; on 1.25+ evaluate Pod Security Admission labels, never PSP; PSP branch is not-in-scope and excluded from the score |
| Using the active kube-context instead of the configured one | Every kubectl call passes `--context "$KUBE_CONTEXT"` explicitly; the live-safety gate prints the server URL for confirmation |
| Scoring RBAC by binding count | Severity is set by whether a wildcard grant lands on a workload ServiceAccount (and public exposure), not by how many bindings exist |
| Reading Secret values | This audit lists Secret names/types only; `kubectl get secret -o yaml` is on the forbidden list |
| An RBAC `Forbidden` recorded as a pass | A denied `view` on a resource is `blocked` for that check, named with the exact resource, never silent success |
| A single replica with a PDB flagged as unresilient | K8S-005 fails only when single-replica AND no PDB; either replicas>1 or a PDB present is a pass |

---

**v0.1.65+** — Standalone audit
**v0.1.69+** — Runs under `/scoutflo:audit-all`
**v0.1.76+** — Rebuilt to fleet parity: Pod Security Admission (not removed PSP), standard schema + report, full check catalog, explicit-context safety
