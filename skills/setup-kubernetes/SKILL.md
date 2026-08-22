---
name: setup-kubernetes
description: Guided hardening of a Kubernetes cluster from audit-kubernetes findings; labels namespaces for Pod Security Admission, tightens over-permissioned workload RBAC, adds default-deny NetworkPolicies, sets workload resource limits, and adds PodDisruptionBudgets — announcing each change, waiting for explicit confirmation, then re-reading and verifying live. Use when the user asks to fix a K8S-NNN finding, enforce pod security, tighten cluster RBAC, add network policies, set resource limits, or add disruption budgets. Do not use for read-only assessment (use audit-kubernetes), for in-cluster LGTM/Grafana telemetry (use setup-lgtm/setup-grafana), or for cloud control-plane changes (use setup-aws/setup-gcp).
disable-model-invocation: true
---

# setup-kubernetes

Fixes security and reliability findings from an `audit-kubernetes` run. Input is one or more finding IDs from the latest `./scoutflo-audits/kubernetes/<context>/<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-kubernetes#enforce-pod-security`.

| Finding ID | Fix section |
| --- | --- |
| K8S-001 | [Enforce pod security](#enforce-pod-security) |
| K8S-002, K8S-006 | [Tighten RBAC](#tighten-rbac) |
| K8S-003 | [Add network policies](#add-network-policies) |
| K8S-004 | [Set resource limits](#set-resource-limits) |
| K8S-005 | [Add disruption budgets](#add-disruption-budgets) |

> **Maturity note (v0.1.76):** this skill is authored to the setup-lane change
> protocol but has **not yet been proven against a live cluster end to end**.
> Treat every fix section as confirm-then-verify (which it is by construction),
> apply changes one at a time, and expect to validate on a non-production
> cluster first. It is shipped so `audit-kubernetes` remediation pointers
> resolve to a real, safe procedure — not as a battle-tested automation.

**v1 is guarded, reversible hardening only.** This skill writes namespace PSA
labels, namespaced Roles/RoleBindings, NetworkPolicies, workload resource
requests/limits, and PodDisruptionBudgets. It never deletes a workload, never
changes replica counts downward, never touches Secrets, never edits the CNI or
admission-webhook configuration, and never applies a `restricted` PSA enforce
level in one step on a running namespace (that can evict non-compliant pods).
Each of those is a written plan with a named owner, not an executed change here.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact manifest/command with real values filled in (namespace, name, the resource it targets), its risk class, and its rollback (the reverse `kubectl` or the backed-up object).
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change (a field differs from the backup, the apply is rejected), stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `kubectl get -o json | jq -e`. A write is unverified until a read proves it — and for PSA, until a test pod or the `warn`-mode output shows the standard is actually admitting/rejecting as intended.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

Backups are GET-before-write: `kubectl get <kind> <name> -n <ns> -o yaml > backup.yaml` before any change to an existing object. New objects record the delete command as their rollback. `./scoutflo-audits/` stays out of version control.

## The change-risk classes

| Class | In this skill | Extra gate |
| --- | --- | --- |
| Read-only | snapshots, verification reads | none |
| Guarded write | PSA label at `baseline`, namespaced Role/RoleBinding, default-deny + allow-list NetworkPolicy, resource requests/limits on a workload, a PodDisruptionBudget | announce and confirm |
| Disruptive | `enforce=restricted` on a running namespace, removing an existing ClusterRoleBinding a workload currently uses, a default-deny policy with no allow-list yet | announce with explicit blast-radius warning; apply only with a second, specific confirmation |
| Out of scope | deleting workloads, scaling replicas down, editing CNI/webhooks/Secrets, `kubectl drain` | plan only, named owner, never executed here |

- ❌ `The finding says pod security is off, so label every namespace enforce=restricted in one batch.`
- ✅ `Apply enforce=baseline first (blocks the worst escapes, admits most workloads), watch warn=restricted for violations, and only then plan the move to restricted per namespace — the restricted jump is disruptive and gets its own confirmation.`

## Doctor gate

Elevated tier: this skill mutates namespace labels, RBAC, NetworkPolicies, and workload specs. A failed check stops the skill with the exact failure and the fix.

| Integration | Config keys | Minimum scope | Tier |
| --- | --- | --- | --- |
| Kubernetes | `kubernetes.context` | write RBAC covering `patch`/`create` on namespaces (label), `roles`/`rolebindings`, `networkpolicies`, `poddisruptionbudgets`, and `patch` on `deployments`/`statefulsets`/`daemonsets` for resource limits — plus the read-only `view` set `audit-kubernetes` documents | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
for bin in kubectl jq; do command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }; done
KUBE_CONTEXT="my-cluster"   # kubernetes.context
kubectl config get-contexts -o name | grep -qx "$KUBE_CONTEXT" \
  || { echo "context '$KUBE_CONTEXT' not in kubeconfig; run /scoutflo:connect"; exit 1; }
# Elevated write scope cannot be introspected cheaply; this gate stays read-only
# by design. The first real write is the scope test — a Forbidden on an
# announced-and-confirmed change means the identity lacks that verb. Stop,
# report which RBAC verb is missing, point at /scoutflo:connect.
kubectl --context "$KUBE_CONTEXT" auth can-i get pods -A >/dev/null 2>&1 \
  || { echo "context unreachable or lacks read; run /scoutflo:connect"; exit 1; }
echo "doctor gate: pass"
```

## Live-safety gate

Print the target cluster and confirm it before the first write:

```bash
set -eu
KUBE_CONTEXT="my-cluster"   # kubernetes.context
SERVER="$(kubectl --context "$KUBE_CONTEXT" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
echo "context=${KUBE_CONTEXT} server=${SERVER}"
echo "live-safety gate: pass — confirm this is the cluster you intend to CHANGE (writes follow)"
```

Every `kubectl` write passes `--context "$KUBE_CONTEXT"` explicitly; the active context is never used, so a stray `use-context` cannot redirect a write to the wrong cluster.

## Load findings and build the change plan

```bash
set -eu
KUBE_CONTEXT="my-cluster"
LATEST="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/kubernetes/*/*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST" ] || { echo "no audit run found; run /scoutflo:audit-kubernetes first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title] | @tsv' "${LATEST}findings.json"
```

Take the finding IDs you were asked to fix; announce the full plan as one table (finding, object, risk class, exact change, rollback) and wait for approval. Order safety first: RBAC tightening before it can lock out the very change that needs it is wrong — verify your own access survives each RBAC change before applying the next.

## Enforce pod security

K8S-001. Guarded write. Label each application namespace for Pod Security Admission, starting at `baseline` and `warn=restricted` (warn is non-enforcing — it surfaces future violations without blocking anything):

```bash
# ANNOUNCE this exact command per namespace; rollback = kubectl label ns <ns> pod-security.kubernetes.io/enforce-
kubectl --context "$KUBE_CONTEXT" label namespace <ns> \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted --overwrite
# VERIFY:
kubectl --context "$KUBE_CONTEXT" get ns <ns> -o json \
  | jq -e '.metadata.labels["pod-security.kubernetes.io/enforce"]=="baseline"'
```

`enforce=restricted` is **disruptive** (can reject running workloads' pods on their next admission) — never applied in the same step; it is a separate, per-namespace plan after `warn=restricted` shows zero violations.

## Harden container security contexts

K8S-007, K8S-008. Guarded → disruptive. Remove the node-escape surface and bring containers to the restricted baseline. These are workload-owner changes (they edit the pod template), so they go through the deploying repo/Helm values, announced, not `kubectl edit`:

```yaml
# ANNOUNCE this securityContext block for the flagged container; rollback = revert the manifest.
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities: { drop: ["ALL"] }   # add back only the specific caps the app proves it needs
# and at pod level: remove privileged, hostNetwork/hostPID/hostIPC, and hostPath volumes.
```

Order matters: `readOnlyRootFilesystem: true` and dropping `ALL` caps can break an app that writes to `/` or needs a specific capability — announce a `warn=restricted` PSA dry-run (Enforce pod security, above) or a staging rollout first, verify the pod still starts and passes its probes, **then** apply. Removing `privileged`/`hostPath` from a legitimate host agent will break it — confirm the workload is an application workload, not a CNI/CSI/node-exporter DaemonSet, before flagging. Verify: the flagged container's `securityContext` shows the hardened values and the pod is `Running` and `Ready`.

## Tighten RBAC

K8S-002, K8S-006, K8S-009. Guarded → disruptive. Replace a workload ServiceAccount's wildcard/cluster-admin binding with a least-privilege namespaced Role. Announce the new Role, confirm, apply, verify the workload's SA can still do what it legitimately needs, **then** remove the over-broad binding (removing it first is disruptive — it can break the running workload):

```bash
# 1. Announce + apply a scoped Role/RoleBinding (guarded). 2. Verify the SA retains needed access:
VERB="get"; RESOURCE="pods"; NS="your-namespace"; SA="your-serviceaccount"   # what the workload legitimately needs
kubectl --context "$KUBE_CONTEXT" auth can-i "$VERB" "$RESOURCE" \
  --as="system:serviceaccount:${NS}:${SA}" -n "$NS"
# 3. Only then announce removal of the wildcard ClusterRoleBinding (DISRUPTIVE, second confirmation):
#    rollback = re-apply the backed-up ClusterRoleBinding yaml.
# 4. Verify the reduction took (this must now return "no"):
kubectl --context "$KUBE_CONTEXT" auth can-i list secrets --all-namespaces \
  --as="system:serviceaccount:${NS}:${SA}"
```

**K8S-009 (token exposure).** For a workload that never calls the Kubernetes API, set `automountServiceAccountToken: false` on the ServiceAccount (or the pod template) — announced as a manifest change, verified by the pod restarting healthy without the token mount. Do this *and* narrow the SA's RBAC: an unused token on a powerless SA is harmless, but the fix for a mounting pod whose SA can read secrets is both — remove the automount and cut the RBAC.

## Add network policies

K8S-003, K8S-011, K8S-010. Guarded → disruptive. Apply a default-deny-ingress policy **with the allow-list in the same apply**, never default-deny alone (that severs all traffic until allows exist — disruptive):

```yaml
# ANNOUNCE this manifest; rollback = kubectl delete networkpolicy <name> -n <ns>
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: <ns> }
spec:
  podSelector: {}
  policyTypes: [Ingress]
  # plus the specific allow-from rules the app needs, shown and confirmed together
```
Verify: `kubectl get networkpolicy -n <ns>` shows the policy and the app's known flows still connect. The empty `podSelector: {}` above is exactly the **default-deny baseline (K8S-011)** — a namespace with only per-app allow policies and no default-deny still leaks; this manifest closes it. For **external exposure (K8S-010)**, the fix is usually *not* a new policy but a review: confirm each LoadBalancer/NodePort Service is meant to be public, front it with the ingress controller + WAF rather than a raw LoadBalancer where possible, and ensure the exposed workload is hardened (Harden container security contexts) and least-privileged (Tighten RBAC) — an internet-facing pod is the one place K8S-007/008/009 are never optional.

## Add health probes

K8S-012. Guarded write (workload-owner change through the manifest). Add readiness and liveness probes to the flagged container:

```yaml
# ANNOUNCE for the flagged container; rollback = revert the manifest.
readinessProbe: { httpGet: { path: /healthz, port: 8080 }, initialDelaySeconds: 5, periodSeconds: 10 }
livenessProbe:  { httpGet: { path: /livez,  port: 8080 }, initialDelaySeconds: 15, periodSeconds: 20 }
```

Use the app's real health endpoints and tune the thresholds to its startup time — a too-aggressive liveness probe restart-loops a slow-starting app (use `startupProbe` for those). Verify: the workload rolls out `Ready`, and a rollout no longer sends traffic to not-ready pods.

## Spread replicas across failure domains

K8S-013. Guarded write (workload-owner change). Add `topologySpreadConstraints` (or pod anti-affinity) so replicas land on distinct nodes:

```yaml
# ANNOUNCE for the workload's pod template; rollback = revert the manifest.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway   # DoNotSchedule only when you have spare nodes to absorb it
    labelSelector: { matchLabels: { app: <app> } }
```

`whenUnsatisfiable: DoNotSchedule` on a cluster without spare node capacity leaves pods `Pending` — start with `ScheduleAnyway` and verify placement. Verify: `kubectl get pods -l app=<app> -o wide` shows the replicas on different nodes.

## Set namespace quotas and LimitRanges

K8S-014. Guarded write. Give each application namespace a LimitRange (per-container defaults) and a ResourceQuota (a namespace ceiling). The LimitRange is the cheap retro-fit for K8S-004 offenders — it applies defaults without editing every workload:

```yaml
# ANNOUNCE both; rollback = kubectl delete limitrange <name> -n <ns> / delete resourcequota <name> -n <ns>
apiVersion: v1
kind: LimitRange
metadata: { name: default-limits, namespace: <ns> }
spec:
  limits:
    - type: Container
      default:        { cpu: "500m", memory: "512Mi" }
      defaultRequest: { cpu: "100m", memory: "128Mi" }
```

A `ResourceQuota` that is set below current usage rejects new pods until usage drops — size it from observed usage first (`kubectl top pods -n <ns>`), announce the number, then apply. Verify: `kubectl get limitrange,resourcequota -n <ns>` shows both and new pods inherit the defaults.

## Set resource limits

K8S-004. Guarded write. Patch the flagged workload's containers with requests and limits (or apply a namespace LimitRange). Announce the exact patch and the values; verify with `kubectl get <kind> <name> -n <ns> -o json | jq -e '.spec.template.spec.containers[].resources.limits'`.

## Add disruption budgets

K8S-005. Guarded write. Add a PodDisruptionBudget with `minAvailable` for the critical workload (and raise replicas via the workload's own owner if it is single-replica — replica increase is announced, not silent):

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: <app>-pdb, namespace: <ns> }
spec:
  minAvailable: 1
  selector: { matchLabels: { app: <app> } }
```
Rollback = `kubectl delete pdb <app>-pdb -n <ns>`. Verify the PDB selects the right pods (`kubectl get pdb <app>-pdb -n <ns> -o json | jq '.status.expectedPods'`).

## Record and wrap up

Append every applied change with its verification output, plus every disruptive item deferred to a plan with a named owner, to the change record below. Re-run `/scoutflo:audit-kubernetes` to confirm the findings clear.

## <UTC timestamp> | <finding IDs>

(Change record appended per run: what was announced, confirmed, applied, verified; and what was deferred as a plan.)

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Applying `enforce=restricted` in one step | Start at `baseline` + `warn=restricted`; the restricted jump is disruptive and gets its own per-namespace confirmation after warn shows zero violations |
| Removing a wildcard binding before proving the scoped Role works | Apply and verify the least-privilege Role first; remove the over-broad binding only on a second confirmation, with the backup as rollback |
| Default-deny NetworkPolicy with no allow-list | Deny + allow-list are announced and applied together; deny-alone is disruptive and never shipped bare |
| A write assumed successful | Every change re-reads the object and asserts with `jq -e`; PSA changes also confirm admit/reject behaviour, not just the label |
| Writing to the active context instead of the configured one | Every `kubectl` write passes `--context "$KUBE_CONTEXT"`; the live-safety gate prints the server URL first |
| Scaling replicas down or deleting a workload to "fix" resilience | Out of scope; replica *increases* are announced, decreases/deletes are never done here |

---

**v0.1.76+** — Pairs with the rebuilt `audit-kubernetes`; confirm-then-verify hardening. Not yet live-proven end to end (see maturity note).
