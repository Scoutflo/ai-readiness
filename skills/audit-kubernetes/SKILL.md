---
name: audit-kubernetes
description: Read-only scored audit of a Kubernetes cluster's security and operational posture — Pod Security Admission enforcement, RBAC over-permissioning, network-policy coverage, workload resource limits, and PodDisruptionBudget/replica resilience — that also reports a separate NON-SCORED live-runtime snapshot (current pod restarts and waiting reasons, recent warning events, node/pod usage when metrics-server answers) through guarded read-only probes; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring a Kubernetes/EKS/GKE/AKS cluster, pod security, cluster RBAC, network policies, missing resource limits, or single-replica critical workloads. Do not use to change the cluster (there is no in-cluster mutation here; findings name the fix), for in-cluster Prometheus/Grafana telemetry (use audit-lgtm / audit-grafana), for cloud-provider control-plane alarms (use audit-aws / audit-gcp), or for a root-cause verdict on a failing workload (use rca; the snapshot here is evidence, not an RCA).
---

# audit-kubernetes

Scored, read-only audit of a Kubernetes cluster's security and reliability posture: whether pods run under an enforced security standard, whether any workload identity holds far more RBAC than it needs, whether the pod network is segmented, whether workloads declare resource limits, and whether critical workloads can survive a node drain. It answers one question: if this cluster is attacked or loses a node tonight, does its own configuration contain the blast radius, or amplify it?

This audit reads cluster **objects** (via `kubectl get`/`auth can-i`). Whether the in-cluster observability stack is healthy is `audit-lgtm`/`audit-grafana`; the cloud provider's own control-plane monitoring is `audit-aws`/`audit-gcp`. This audit stops at the cluster's own security and workload configuration.

Every command is read-only: `kubectl get`, `kubectl auth can-i`, `kubectl api-resources`, `kubectl version`. The live-runtime snapshot (Phase 8) additionally uses the read-only `top` verb and `get events`, and only through the guarded `le_kubectl` wrapper in the shared live-evidence library (allowlisted read verbs, mechanically enforced by `ci/liveness-readonly-check.sh`). No `apply`, `create`, `edit`, `patch`, `delete`, `label`, `annotate`, `scale`, `cordon`, or `exec` — the full forbidden list is in [references/kubernetes-checks.md](references/kubernetes-checks.md) section 9. `setup-kubernetes` performs the confirm-then-verify fixes; this audit only names them.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/kubernetes/<context>/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), scored posture finding IDs `K8S-NNN`, plus `K8SRT-NNN` for the parallel non-scored live-runtime snapshot section (Phase 8; `area: live-runtime`, always severity `info` and `points_recoverable: 0`, never in `score.categories` or `score.excluded`). The `<context>` directory segment exists because one machine's kubeconfig routinely reaches several clusters; each cluster gets its own history.
- `./scoutflo-audits/kubernetes/<context>/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/kubernetes/<context>/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-1 catalog — one item per namespace, workload (Deployment/StatefulSet/DaemonSet), NetworkPolicy, RBAC binding, and PodDisruptionBudget — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/kubernetes/<context>/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Kubernetes | `kubernetes.context` | none (identity comes from the kubeconfig context) | built-in `view` ClusterRole (`get`/`list` on pods, deployments, services, networkpolicies, roles, rolebindings, clusterroles, clusterrolebindings, poddisruptionbudgets, namespaces) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

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
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in kubectl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done

# kubernetes.context names the exact context to audit. It is passed explicitly on
# EVERY kubectl call; the current/active context is never used for targeting, so a
# stray `kubectl config use-context` elsewhere cannot silently redirect this audit.
KUBE_CONTEXT="my-cluster"   # kubernetes.context
kubectl config get-contexts -o name | grep -qx "$KUBE_CONTEXT" \
  || { echo "context '$KUBE_CONTEXT' not in kubeconfig; run kubectl config get-contexts, fix kubernetes.context"; exit 1; }
# Entra-integrated AKS contexts authenticate through a kubelogin exec plugin. If
# this context needs it and it is missing, say so plainly now instead of failing
# below with a cryptic exec error. A cert/local-account AKS context (no
# exec.command) or an EKS/GKE context (whose exec.command is aws / gke-gcloud-auth-plugin,
# not kubelogin) falls through and skips this. This mirrors the /scoutflo:doctor probe.
EXEC_CMD="$(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.users[*].user.exec.command}' 2>/dev/null || true)"
case "$EXEC_CMD" in
  *kubelogin*) command -v kubelogin >/dev/null \
    || { echo "context '$KUBE_CONTEXT' uses the kubelogin exec plugin (Entra-integrated AKS) but kubelogin is not installed; run: az aks install-cli"; exit 1; } ;;
esac
if ! kubectl --context "$KUBE_CONTEXT" auth can-i get pods -A >/dev/null 2>&1; then
  # A failed can-i on an exec-plugin context is usually an EXPIRED CREDENTIAL, not a
  # missing RBAC binding — so name the reauth path per exec plugin BEFORE the generic
  # RBAC message (mirrors the kubelogin branch above). Only a non-exec context falls
  # through to the RBAC fallback.
  case "$EXEC_CMD" in
    *gke-gcloud-auth-plugin*) echo "context '$KUBE_CONTEXT' (GKE) could not authenticate — the gke-gcloud-auth-plugin credential is likely expired, not an RBAC gap; run: gcloud auth login (then gcloud container clusters get-credentials <cluster> to refresh the token), then retry"; exit 1 ;;
    *aws*)                    echo "context '$KUBE_CONTEXT' (EKS) could not authenticate — the aws exec-plugin credential is likely expired, not an RBAC gap; run: aws sso login (or otherwise refresh your AWS credentials), then retry"; exit 1 ;;
    *kubelogin*)              echo "context '$KUBE_CONTEXT' (Entra AKS) could not authenticate — the kubelogin credential is likely expired, not an RBAC gap; run: az login to refresh it (or az aks install-cli if kubelogin is missing), then retry"; exit 1 ;;
    *)                        echo "context reaches no cluster or lacks read RBAC; bind the view ClusterRole (connect references/providers.md)"; exit 1 ;;
  esac
fi
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
- **Never print or write a secret value.** Webhook URLs, API tokens, bearer/auth headers, cloud keys, and connection strings are captured by key name or type only, never by value — not into the terminal, evidence, `findings.json`, `report.md`, or a Slack brief. Follow the shared [secret-redaction discipline](../../report-standard/secret-redaction.md); the redaction filter (`skills/redaction/lib/redaction.sh`, `redact_file`) masks any residual secret in a written artifact as defense-in-depth.
- **Per-service loops key on namespace + name, never bare service name.** One estate routinely runs the same service name in two namespaces (a `redis` in two application namespaces, staging and prod copies side by side); a name-only key silently collapses them into one coverage row or one probe target. Every loop over topology services reads `attributes.namespace` together with `name` from the export, and `<namespace>/<name>` is the unit for coverage rows, live-runtime probes, and `affected` entries.

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

Resolve each critical service to its `<namespace>/<name>` pair here, once — `attributes.namespace` plus `name` from `topology-export.json` — and carry that pair through every later phase (per the ground rule above). Two services that share a name in different namespaces are two entries from this point on, never one.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/kubernetes-checks.md](references/kubernetes-checks.md) section 2: server version; namespaces with their `pod-security.kubernetes.io/*` labels; ClusterRoles/ClusterRoleBindings/Roles/RoleBindings; NetworkPolicies per namespace; Deployments/StatefulSets/DaemonSets with their container resource requests/limits; PodDisruptionBudgets and replica counts. Judgment starts in Phase 3.

Phases 3–7 are the five scored categories. Each finding must clear the [depth doctrine](../../report-standard/depth-doctrine.md): name the exact object and value, compute the blast radius **from this cluster** (who reaches what, what goes down), state the correlation chain when one exists, and give the specific fix. "X is missing" is a linter line, not a finding. Commands and the per-check blast-radius/correlation notes are in [references/kubernetes-checks.md](references/kubernetes-checks.md) sections 3–7.

## Phase 3: Workload hardening (K8S-001, K8S-007, K8S-008)

Commands in section 3. **K8S-001** — on 1.25+, every application namespace should enforce a `pod-security.kubernetes.io/enforce` standard at `baseline` or `restricted` (high when none is enforced — pods run unconstrained). **K8S-007** — no application workload runs `privileged`, a host namespace (`hostNetwork`/`hostPID`/`hostIPC`), a `hostPath` mount, or `SYS_ADMIN`/`NET_ADMIN` capabilities (high — a node-escape surface; critical when the same workload is internet-exposed per K8S-010 or its SA is privileged per K8S-002). CNI/CSI/node-exporter DaemonSets in system namespaces legitimately need host access — a posture note, never a finding. **K8S-008** — application containers meet the restricted baseline (`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop `ALL` caps); a root container with a writable rootfs is the substrate for a post-exploit payload (medium; cite alongside K8S-007 when the same workload fails both). K8S-001 is the upstream cause — cite the specific K8S-007/008 violators as proof that `enforce=none` is not theoretical.

## Phase 4: Identity & access (K8S-002, K8S-006, K8S-009)

Commands in section 4. **K8S-002** — ClusterRoles granting `*` verbs on `*` resources in `*` API groups, and their ServiceAccount subjects (high when bound to a workload SA, critical when that workload is public per K8S-010). **K8S-006** — a workload SA that can `list secrets` cluster-wide; **confirm it with `auth can-i list secrets --all-namespaces --as=system:serviceaccount:<ns>:<sa>`** — the returned `yes`/count *is* the blast radius, not an inference (high). **K8S-009** — workloads that never call the API server should set `automountServiceAccountToken: false`; a mounted token matters exactly as much as its SA's RBAC, so **rank K8S-009 findings by each SA's `auth can-i` result**: a `default` SA with no bindings mounting a token is low; the payments pod mounting a secrets-reader token is high, and its fix names both the automount flag and the RBAC to narrow. Break-glass human/group bindings are posture notes.

## Phase 5: Network segmentation (K8S-003, K8S-011, K8S-010)

Commands in section 5. **K8S-003** — each application namespace has ≥1 NetworkPolicy selecting its pods (high when a namespace has zero — any pod reaches any other; name the reachable datastores by pod/port, not "flat network"). **K8S-011** — a namespace with policies but no **default-deny** ingress is allow-by-omission: every pod no policy selects is still open (medium; name the uncovered pods). A namespace can pass K8S-003 and fail K8S-011. **K8S-010** — inventory internet-facing Services (LoadBalancer/NodePort) and Ingress, resolve each to its backing workload, and compute the external→cluster path by joining K8S-007 (privileged?), K8S-002/006/009 (SA power?), and K8S-003 (segmented?). The one-sentence path — public Service → token-mounting pod → secrets-reader SA → unsegmented namespace — is the flagship finding no scanner assembles (high, critical when the exposed pod's SA is privileged).

## Phase 6: Resource governance (K8S-004, K8S-014)

Commands in section 6. **K8S-004** — Deployments/StatefulSets/DaemonSets whose containers set no limits (medium; requests-without-limits is a partial). Name the node-shared workloads an unbounded container can starve; if K8SRT-002 shows it already OOMKilled, mark `validated-live`. **K8S-014** — application namespaces with neither a ResourceQuota nor a LimitRange (medium). The correlation with K8S-004 is the point: no LimitRange *and* no per-workload limits is truly unbounded with no admission backstop — and a LimitRange retro-fits sane defaults onto the K8S-004 offenders in one object, so name it as the cheap first move.

## Phase 7: Reliability & resilience (K8S-005, K8S-012, K8S-013)

Commands in section 7. **K8S-005** — critical single-replica workloads with no PodDisruptionBudget (medium, high for critical services); frame it as a *scheduled-maintenance* outage (a routine node drain takes it down), not a rare failure. **K8S-012** — workloads missing readiness or liveness probes (medium): missing readiness sends deploy-time traffic to not-ready pods (user-visible 502s on every rollout); missing liveness leaves a wedged process unrestarted (silent brownout) — name which mode applies. **K8S-013** — multi-replica critical workloads with no `topologySpreadConstraints` or pod anti-affinity (medium, high for critical): `replicas: 3` reads as HA but the scheduler may co-locate all three, so one node loss is a full outage; use the live `-o wide` per-node count to say whether they are co-located *right now* and mark `validated-live` if they are. This is why K8S-005 passing is not the end of resilience.

## Phase 8: Live-runtime snapshot (K8SRT — evidence, not scored)

The scored checks above judge **configuration**: what this cluster would do under attack or a node drain. This phase captures what the cluster is **doing right now** — current container restarts and waiting reasons, recent Warning events, and node/pod usage when metrics-server answers. It is a snapshot, not a trend and not a posture judgment, so it is a parallel non-scored section per the [report template](../../report-standard/report-template.md)'s pattern (the same way Scoutflo Topology Readiness and audit-aws's Cost section work): finding IDs `K8SRT-NNN`, `area: live-runtime`, always severity `info` and `points_recoverable: 0`, never present in `score.categories` or `score.excluded`. A crash-looping pod observed here moves no score in either direction — the scored posture gap (for example K8S-004, no memory limit) carries the points; the snapshot carries the current proof.

Every probe routes through the guarded wrapper in the shared live-evidence library ([skills/live-evidence/lib/live-evidence.sh](../live-evidence/lib/live-evidence.sh)): allowlisted read verbs only, `--context` pinned explicitly, every call bounded by `--request-timeout`, probe output redacted. The read-only guarantee is enforced mechanically by `ci/liveness-readonly-check.sh`, not by promise. This phase uses `get`, `get events`, and `top` only; it never calls `logs` — that depth belongs to `/scoutflo:rca`.

**Runs-anywhere fallback.** When probes are unavailable — kubectl missing, context unresolvable, RBAC denied, cluster unreachable — the section renders `skipped, reason: <the exact reason>` and nothing else. A skipped snapshot is never a finding, never a fail, and never invented output; the scored audit is complete without it. The same rule applies per probe: `top` on a cluster without metrics-server is skipped with that reason, never estimated.

```bash
set -eu
KUBE_CONTEXT="my-cluster"   # kubernetes.context
SNAP_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"   # tag every fact below [live@${SNAP_TS}]
# Redaction first, then the guarded probe lib (le_kubectl allows read verbs only).
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh" 2>/dev/null || true
. "${CLAUDE_PLUGIN_ROOT}/skills/live-evidence/lib/live-evidence.sh"
if ! REASON="$(le_can_probe "$KUBE_CONTEXT" 2>&1 >/dev/null)"; then
  echo "live-runtime snapshot: skipped, reason: ${REASON:-no live access}"; exit 0
fi
echo "live-runtime snapshot @ ${SNAP_TS} (read-only, not scored)"

# 1. Containers restarting or stuck in a waiting state right now (K8SRT-001/002 evidence).
le_kubectl "$KUBE_CONTEXT" get pods -A -o json 2>/dev/null | jq -r '
  .items[] | . as $p | .status.containerStatuses[]?
  | select((.restartCount // 0) > 0 or ((.state.waiting.reason // "") != ""))
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\(.name)\trestarts=\(.restartCount // 0)\twaiting=\(.state.waiting.reason // "-")\tlast=\(.lastState.terminated.reason // "-")/exit=\(.lastState.terminated.exitCode // "-")"' \
  || echo "pod snapshot: blocked (record the exact error; verdict unknown, never healthy)"

# 2. Recent Warning events, newest last (K8SRT-003 evidence).
le_kubectl "$KUBE_CONTEXT" get events -A --field-selector type=Warning --sort-by=.lastTimestamp -o json 2>/dev/null \
  | jq -r '.items[-20:] | .[] | "\(.lastTimestamp)\t\(.involvedObject.namespace // "-")/\(.involvedObject.name)\t\(.reason)\tcount=\(.count // 1)"' \
  || echo "warning events: blocked (record the exact error; verdict unknown, never healthy)"

# 3. Node/pod usage (K8SRT-004 evidence) — only when metrics-server answers.
if le_kubectl "$KUBE_CONTEXT" top nodes >/dev/null 2>&1; then
  le_kubectl "$KUBE_CONTEXT" top nodes 2>/dev/null || true
  le_kubectl "$KUBE_CONTEXT" top pods -A --sort-by=memory 2>/dev/null | head -15 || true
else
  echo "top nodes/pods: skipped, reason: metrics-server (metrics.k8s.io) not answering on this cluster, or RBAC denies it"
fi

# 4. Per-critical-service rollout state, keyed on namespace + name (never bare name).
TOPO="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"
if [ -f "$TOPO" ]; then
  jq -r '.services[]? | select(.business_criticality == "critical" or .business_criticality == "high")
    | "\(.attributes.namespace // "default") \(.name)"' "$TOPO" | sort -u \
  | while read -r NS SVC; do
      [ -n "${SVC:-}" ] || continue
      echo "== ${NS}/${SVC} =="
      # probe_* return rc=0 with EMPTY stdout when blocked (the lib swallows errors),
      # so an `||` fallback is dead code — check output emptiness instead.
      _ro="$(probe_rollout "$KUBE_CONTEXT" "$NS" "$SVC" 2>/dev/null || true)"
      if [ -n "$_ro" ]; then printf '%s\n' "$_ro"; else echo "rollout probe blocked for ${NS}/${SVC} (verdict unknown, never healthy)"; fi
      _ev="$(probe_events "$KUBE_CONTEXT" "$NS" "$SVC" 2>/dev/null || true)"
      [ -n "$_ev" ] && printf '%s\n' "$_ev" || echo "events probe returned nothing for ${NS}/${SVC} (no recent events, or probe blocked)"
    done
else
  echo "per-service probes: skipped, reason: no topology-export.json (run /scoutflo:map-topology); the cluster-wide snapshot above still stands"
fi
```

When the export's `DEPLOYED_AS` edge or `attributes.app` names a workload different from the service name, probe that workload name instead; a probe that finds no object is recorded as unknown for that `<namespace>/<name>`, never as healthy and never re-guessed against another namespace.

**When does a snapshot row become a K8SRT finding?** Only when the exact taxonomy field is present, per the shared failure taxonomy in [k8s-liveness-probes.md](../live-evidence/references/k8s-liveness-probes.md); the catalog and skip rules are in [references/kubernetes-checks.md](references/kubernetes-checks.md) section 10. `K8SRT-001`: a container in a crash/backoff waiting state now (cite the waiting reason plus `lastState.terminated` reason/exit code). `K8SRT-002`: OOMKilled in the last termination (cite exit code 137; when K8S-004 flagged the same workload, also cite this observation in K8S-004's evidence and mark that finding `validated-live` — the posture finding carries the severity, the snapshot carries the proof). `K8SRT-003`: a Warning-event burst in an application namespace (cite reason, object, count). `K8SRT-004`: node/pod pressure from `top` output (only when metrics-server answered). A bare `restartCount` with no terminated reason or event is a **symptom**: it stays a snapshot table row, never a finding. A blocked probe is recorded `skipped, reason:` — verdict unknown, never healthy.

Render the section in `report.md` under its own heading, after Scoutflo Topology Readiness, per the report template's parallel non-scored section pattern. Open it with the mode line (`[live@<SNAP_TS>]`, or the skip line with its reason), then the snapshot tables, then any K8SRT findings. Close with the pointer: for a verdict on anything distressed here, run `/scoutflo:rca <namespace>/<service>` — this section is evidence, not an RCA.

## Phase 9: Coverage matrix and topology readiness

Per the report standard, render the per-service coverage matrix and the Scoutflo Topology Readiness section for the critical services named in Phase 1. Judge each service against six posture columns: **hardened** (namespace enforces pod security AND the workload is non-privileged/non-root — K8S-001/007/008), **least-privilege** (its SA holds no wildcard/secret-reader power and mounts a token only if it needs one — K8S-002/006/009), **network-isolated** (a NetworkPolicy selects it AND its namespace has a default-deny — K8S-003/011), **resource-bounded** (requests + limits, under a namespace LimitRange — K8S-004/014), **resilient** (PDB/replicas AND spread across nodes — K8S-005/013), and **health-probed** (readiness + liveness — K8S-012). A service missing all six is `0 of 6`; state the count in plain language (see [topology-readiness.md](../../report-standard/topology-readiness.md)). Every matrix row is keyed `<namespace>/<name>` (per the ground rule): two same-named services in different namespaces get two rows, each judged against its own namespace's labels, policies, PDBs, and spread rules.

## Phase 10: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0); `not-in-scope` (e.g. the PSP branch on a 1.25+ server) leaves the denominator. Category score is the credit ratio × 100 floored; overall is the weight-normalized sum over included categories, conservatively.

| Category | Weight | Checks |
| --- | --- | --- |
| Workload hardening | 25 | K8S-001 (pod security admission), K8S-007 (host-namespace/privileged escape), K8S-008 (container restricted baseline) |
| Identity & access | 20 | K8S-002 (wildcard/cluster-admin RBAC), K8S-006 (cluster-wide secret readers), K8S-009 (service-account token exposure) |
| Network segmentation | 20 | K8S-003 (network policy presence), K8S-011 (default-deny baseline), K8S-010 (external exposure surface) |
| Reliability & resilience | 20 | K8S-005 (PDB/replicas), K8S-012 (health probes), K8S-013 (replica spread) |
| Resource governance | 15 | K8S-004 (requests + limits), K8S-014 (namespace quota/LimitRange) |

Full check catalog and target profile at the top of [references/kubernetes-checks.md](references/kubernetes-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects (namespace/kind/name) enumerated in `affected`. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings carry 0. Live-runtime (`K8SRT-*`) findings are always `info` with `points_recoverable: 0` and never enter this arithmetic — the snapshot can corroborate a posture finding's evidence (and upgrade its `status` to `validated-live`), but it never moves the score in either direction. The executive summary states the gap to target and the two or three highest-`points_recoverable` findings as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base posture", never "end to end".

Write `findings.json` first (canonical), then regenerate `report.md`, the history line, and the Slack brief from it. Then run the report-standard self-validation, exactly as every other audit does — `check-findings.sh` (score reconciles with the scorecard, schema invariants hold) before `check-report.sh` (shape):

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context — the same per-cluster segment the outputs section declares
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/kubernetes/${KUBE_CONTEXT}/${RUN_DATE}"   # per-cluster segment, matching the declared outputs
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline (with movement and the "good base posture" / not-end-to-end label), the top fixes by `points_recoverable`, the **absolute** `report.md` path, the OS-specific open command, and the leak-safe share pointer (the Slack brief). Then send the Slack brief — titles only, never evidence values, no namespaces or object names:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/kubernetes"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RT_LINE=""   # optional; set only when live-runtime (K8SRT) observations exist this run
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  # Top findings are the scored posture levers; the non-scored live-runtime snapshot gets its own count line.
  TOP="$(jq -r '[.findings[] | select(.area != "live-runtime") | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  RT_COUNT="$(jq -r '[.findings[] | select(.area == "live-runtime")] | length' "$OUT/findings.json")"
  [ "$RT_COUNT" -gt 0 ] && RT_LINE="Live-runtime: ${RT_COUNT} runtime observations (snapshot, not scored)"
  # Date-named run dirs only (the previous run's baseline for movement + delta).
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*-[0-9]*' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-kubernetes ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg rt "$RT_LINE" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + ($rt | if . == "" then "" else "\n" + . end) + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # derived from business_context.md (the SSOT)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver
LOAD_METADATA_MODE="none"
if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="per-resource"
elif [ -f "$BC_JSON" ] && jq -e '.' "$BC_JSON" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="workspace"
fi
echo "metadata mode: $LOAD_METADATA_MODE"
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** namespaces/resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service (raise Reliability findings to high, mark it in the coverage matrix); reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

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
| Entra-integrated AKS context failing with a cryptic exec-plugin error | The doctor gate detects a `kubelogin` exec context and stops with `az aks install-cli` guidance before any check runs; cert/local-account AKS and EKS/GKE contexts skip the probe |
| A GKE/EKS exec-plugin credential expiry mis-reported as an RBAC gap | On a failed `auth can-i`, the doctor gate branches on the exec command first: `gke-gcloud-auth-plugin` → `gcloud auth login` / token refresh, `aws` → `aws sso login` / credential refresh; only a non-exec context falls through to the "bind the view ClusterRole" RBAC message |
| A live crash-loop dropped into the scorecard | K8SRT findings are a parallel non-scored section: `area: live-runtime` never appears in `score.categories` or `score.excluded`, severity is always `info`, `points_recoverable` is always 0; the scored posture finding (e.g. K8S-004) carries the points, the snapshot carries the proof |
| Unavailable live probes faked, or scored as a failure | `le_can_probe` gates the section; without kubectl/context/RBAC/reachability it renders `skipped, reason: <exact reason>` — never a finding, never invented output, and the scored audit completes without it. `top` without metrics-server is skipped with that reason, never estimated |
| A snapshot probe mutating the cluster | Every Phase 8 probe routes through the guarded `le_kubectl` wrapper (allowlisted read verbs only, pinned `--context`, bounded `--request-timeout`), mechanically enforced by `ci/liveness-readonly-check.sh`; no mutating verb exists on the allowlist |
| Two same-named services in different namespaces collapsed into one row or probe | Per-service loops key on `namespace + name` from the topology export; `<namespace>/<name>` is the unit for coverage rows, K8SRT probes, and `affected` entries |

---

**v0.1.65+** — Standalone audit
**v0.1.69+** — Runs under `/scoutflo:audit-all`
**v0.1.76+** — Rebuilt to fleet parity: Pod Security Admission (not removed PSP), standard schema + report, full check catalog, explicit-context safety
**v0.1.123+** — Live-runtime snapshot section (`K8SRT-NNN`, parallel non-scored) via the shared guarded live-evidence library; per-service loops keyed on namespace + name
