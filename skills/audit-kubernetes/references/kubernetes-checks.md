# audit-kubernetes: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-kubernetes](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and — per the [depth doctrine](../../report-standard/depth-doctrine.md) — the **blast radius** each failure carries and the **correlation chains** it belongs to. A finding here never stops at "X is missing": it names the exact object and value, what an attacker or a node drain actually reaches through it, and the specific fix. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. Every command passes `--context "$KUBE_CONTEXT"` explicitly.

## 1. Conventions

- `KUBE_CONTEXT` is `kubernetes.context` from toolkit.yaml and is passed on **every** call. The active/current context is never used for targeting.
- Every command is read-only: `kubectl get`, `kubectl auth can-i`, `kubectl api-resources`, `kubectl version`, `kubectl config view`. The live-runtime snapshot (section 10) additionally uses the read-only `top` verb and `get events`, only through the guarded `le_kubectl` wrapper from the shared live-evidence library. No mutating verb appears anywhere (forbidden list, section 9).
- Secret **values** are never read. `kubectl get secret` (names/types) is allowed; `kubectl get secret -o yaml`/`-o json` with `.data` is forbidden.
- `-o json | jq` is the parsing path. A `Forbidden` from the API server on a specific `get`/`list` means the audit credential lacks that `view` grant → record `blocked` for the check naming the exact resource.
- Thresholds/namespace classifications are examples; tune to your cluster. Named defaults live in section 8.
- **`auth can-i --as=` is the reachability tool.** Several checks confirm what a ServiceAccount's token can actually do rather than inferring it from role text. `auth can-i` is a read-only subjectaccessreview; it never mutates. This is how a finding earns a real blast radius instead of an assertion.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Five scored categories; the parallel non-scored live-runtime snapshot IDs (`K8SRT-NNN`) are in section 10.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| K8S-001 | Workload hardening | Application namespaces enforce a Pod Security Admission standard (`pod-security.kubernetes.io/enforce`) | high |
| K8S-007 | Workload hardening | No workload runs with a host-namespace or node-escape surface (`privileged`, `hostNetwork`/`hostPID`/`hostIPC`, `hostPath`, `SYS_ADMIN`/`NET_ADMIN`) | high (critical if internet-exposed) |
| K8S-008 | Workload hardening | Containers meet the restricted baseline (`runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, drop `ALL` caps) | medium |
| K8S-002 | Identity & access | No workload ServiceAccount holds cluster-wide wildcard (`*/*/*`) or cluster-admin RBAC | high (critical if publicly exposed) |
| K8S-006 | Identity & access | No ServiceAccount has cluster-wide `secrets get/list` beyond what it needs | high |
| K8S-009 | Identity & access | Workloads that never call the API server disable `automountServiceAccountToken` (a mounted token is only as safe as its SA's RBAC) | medium (high when the SA can read secrets or the pod is exposed) |
| K8S-003 | Network | Application namespaces have at least one NetworkPolicy selecting their pods (not a flat open network) | high |
| K8S-011 | Network | Application namespaces have a **default-deny** ingress baseline, not just some policies (a pod no policy selects is still open) | medium |
| K8S-010 | Network | Internet-facing Services/Ingress are inventoried and their reachable blast radius is bounded (exposure + RBAC + no netpol is an external→cluster path) | high (critical when the exposed pod's SA is privileged) |
| K8S-004 | Resource governance | Deployments/StatefulSets/DaemonSets set container resource requests and limits | medium |
| K8S-014 | Resource governance | Application namespaces have a ResourceQuota and a LimitRange (no namespace can starve the cluster) | medium |
| K8S-005 | Reliability | Critical single-replica workloads have a PodDisruptionBudget | medium (high for critical services) |
| K8S-012 | Reliability | Workloads define readiness and liveness probes (rollout sends traffic only to ready pods; wedged pods self-heal) | medium |
| K8S-013 | Reliability | Multi-replica critical workloads spread across nodes (`topologySpreadConstraints` or pod anti-affinity) — replicas that co-locate are not actually HA | medium (high for critical services) |

## 3. Workload hardening (K8S-001, K8S-007, K8S-008)

### K8S-001 — Pod Security Admission

```bash
# Server version FIRST — decides PSA (1.25+) vs PSP (<1.25).
kubectl --context "$KUBE_CONTEXT" version -o json | jq -r '.serverVersion.gitVersion'

# PSA: enforce label per namespace (1.25+). Empty enforce = unconstrained.
kubectl --context "$KUBE_CONTEXT" get ns -o json \
  | jq -r '.items[] | "\(.metadata.name)\tenforce=\(.metadata.labels["pod-security.kubernetes.io/enforce"] // "none")\twarn=\(.metadata.labels["pod-security.kubernetes.io/warn"] // "none")"'
```

Healthy: every application namespace has `enforce=baseline` or `restricted`. Fail (K8S-001): application namespaces show `enforce=none`. On a `<1.25` server, instead check `kubectl get psp` and note the cluster is on an unsupported version; on 1.25+ `psp` returns `the server doesn't have a resource type "podsecuritypolicies"` — that is expected, not a finding. **Blast radius:** a namespace with no enforced standard admits privileged, host-mounting, root pods with no gate — so K8S-001 is the upstream cause that lets K8S-007/K8S-008 exist; cite the specific violating workloads that section 3's next two checks find as the proof that "enforce=none" is not theoretical here.

### K8S-007 — Host-namespace and node-escape surface

```bash
# Pod-level escapes: host namespaces and hostPath mounts (the container sees the node).
# NOTE: `any(has("hostPath"))`, NOT `(.spec.volumes[]? | has("hostPath"))` — the streaming
# form re-emits the pod once per matching volume (a 3-hostPath pod printed 3 identical lines
# in live testing). `any` evaluates the select exactly once per pod.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json | jq -r '
  .items[] | select(.spec.hostNetwork==true or .spec.hostPID==true or .spec.hostIPC==true
      or ((.spec.volumes // []) | any(has("hostPath"))))
  | "\(.metadata.namespace)/\(.metadata.name)\thostNet=\(.spec.hostNetwork // false)\thostPID=\(.spec.hostPID // false)\thostIPC=\(.spec.hostIPC // false)\thostPaths=\([.spec.volumes[]? | select(has("hostPath")) | .hostPath.path] | join(","))"' \
  | sort -u

# Container-level escapes: privileged, or adding dangerous Linux capabilities.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json | jq -r '
  .items[] | . as $p | (.spec.containers[], (.spec.initContainers // [])[])
  | select(.securityContext.privileged==true
      or ((.securityContext.capabilities.add // []) | any(. == "SYS_ADMIN" or . == "NET_ADMIN" or . == "ALL")))
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\(.name)\tprivileged=\(.securityContext.privileged // false)\tcapsAdded=\((.securityContext.capabilities.add // []) | join(","))"'
```

Healthy: no application workload sets `privileged`, a host namespace, a `hostPath` mount, or `SYS_ADMIN`/`NET_ADMIN`. Fail (K8S-007): any does. **Blast radius — this is the check a linter's "privileged: true" row never computes:** a `privileged` or `hostPath: /` container is a root shell on the node one RCE away — it reads every other pod's secrets off the kubelet, the node's cloud-instance credentials (IMDS), and can schedule itself cluster-wide. State which node-class the workload runs on and what shares it. **Correlate:** if the same workload is internet-exposed (K8S-010) or its SA is privileged (K8S-002), raise to critical and name the full external→node→cluster path.

**Classify by workload identity, not just namespace (this is the judgment the check lives or dies on).** A whole class of workloads *legitimately* needs host access and must be recorded as a **posture note, never a K8S-007 finding**, even when they run outside `kube-system`: node agents and observability collectors — CNI/CSI drivers, `kube-proxy`, `node-exporter`, Promtail/Fluent Bit/Vector (they tail `/var/log/pods` and `/var/lib/docker/containers`), eBPF agents like Beyla/Pixie/Cilium/Falco (they need `hostPID` + `privileged` + `/sys/fs/cgroup` to instrument the kernel), and the metrics/OTel node collectors. Recognize them by name/image and DaemonSet shape, not by namespace — in live estates they sit in `monitoring`, `lgtm`, `observability`, etc. A K8S-007 *finding* is an **application** workload (a service that serves business traffic) that took host access it doesn't need — that is the lazy `privileged: true` a scanner can't tell apart from a legitimate agent, and telling them apart is the value. When unsure, record it as a note and say why, never as a high finding.

### K8S-008 — Container restricted-baseline hardening

```bash
kubectl --context "$KUBE_CONTEXT" get pods -A -o json | jq -r '
  .items[] | . as $p | .spec.containers[] | . as $c
  | ($p.spec.securityContext.runAsNonRoot // $c.securityContext.runAsNonRoot) as $nonroot
  | select(($nonroot != true)
      or (($c.securityContext.readOnlyRootFilesystem // false) != true)
      or (($c.securityContext.allowPrivilegeEscalation // true) != false)
      or (((($c.securityContext.capabilities.drop // []) | map(ascii_upcase)) | any(. == "ALL")) | not))
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\($c.name)\trunAsNonRoot=\($nonroot // "unset")\treadOnlyRootFS=\($c.securityContext.readOnlyRootFilesystem // "unset")\tallowPrivEsc=\($c.securityContext.allowPrivilegeEscalation // "unset")\tdropsALL=\((($c.securityContext.capabilities.drop // []) | map(ascii_upcase) | any(. == "ALL")))"'
```

Healthy: application containers run as non-root, with a read-only root filesystem, `allowPrivilegeEscalation: false`, and drop `ALL` capabilities. Fail (K8S-008): one or more of those is unset/false. **Blast radius:** a container running as UID 0 with a writable root filesystem is the substrate for a cryptominer or ransomware payload after any code-exec bug — the attacker writes and executes freely and can `setuid`-escalate. A writable rootfs also means a compromised process persists across probes. Enumerate the highest-value cases first (internet-facing and shared-path workloads). This is `medium` on its own, but a container that is *both* root and privileged (K8S-007) is the same workload failing two gates — cite both in one attack narrative.

## 4. Identity & access (K8S-002, K8S-006, K8S-009)

### K8S-002 / K8S-006 — Cluster-wide RBAC power

```bash
# ClusterRoles granting wildcard verbs on wildcard resources.
kubectl --context "$KUBE_CONTEXT" get clusterroles -o json \
  | jq -r '.items[] | select(.rules[]? | (.verbs[]?=="*") and (.resources[]?=="*") and (.apiGroups[]?=="*")) | .metadata.name' | sort -u

# Who is each wildcard/cluster-admin ClusterRole bound to? Flag ServiceAccount subjects.
kubectl --context "$KUBE_CONTEXT" get clusterrolebindings -o json \
  | jq -r '.items[] | . as $b | .subjects[]? | select(.kind=="ServiceAccount") | "\($b.roleRef.name) -> sa:\(.namespace)/\(.name)"'

# K8S-006: ClusterRoles granting cluster-wide secrets get/list, and their SA subjects.
kubectl --context "$KUBE_CONTEXT" get clusterroles -o json \
  | jq -r '.items[] | select(.rules[]? | (.resources[]?=="secrets") and ((.verbs[]?=="get") or (.verbs[]?=="list") or (.verbs[]?=="*"))) | .metadata.name'

# CONFIRM the reachability rather than infer it (read-only subjectaccessreview):
kubectl --context "$KUBE_CONTEXT" auth can-i list secrets --all-namespaces \
  --as="system:serviceaccount:${NS}:${SA}"
```

Healthy: no `*/*/*` ClusterRole bound to a workload ServiceAccount; no workload SA can list secrets cluster-wide. Fail (K8S-002): a binding like `platform-cr -> sa:app-ns/app-sa` where `platform-cr` is `*/*/*`. Fail (K8S-006): `auth can-i list secrets --all-namespaces` returns `yes` for a workload SA. **Blast radius — verified, not inferred:** the `auth can-i` result *is* the blast radius — "the token in pod `app-ns/app-sa` can list secrets in all N namespaces" means any RCE in that pod exfiltrates every credential in the cluster. Raise K8S-002 to critical when that SA's workload sits behind a public ingress (cross-check K8S-010): that is a straight external-to-cluster-admin path. A wildcard bound only to a human group (`system:masters`, an SSO admin group) is a posture note, not a workload finding.

### K8S-009 — ServiceAccount token exposure

```bash
# Workloads whose pods mount an SA token (automount not disabled at pod OR sa level).
kubectl --context "$KUBE_CONTEXT" get pods -A -o json | jq -r '
  .items[] | select((.spec.automountServiceAccountToken // true) == true)
  | "\(.metadata.namespace)\t\(.spec.serviceAccountName // "default")\t\(.metadata.name)"' | sort -u

# The SAs themselves may disable automount too — check both layers.
kubectl --context "$KUBE_CONTEXT" get sa -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\tautomount=\(.automountServiceAccountToken // "unset(true)")"'
```

Healthy: workloads that never call the Kubernetes API set `automountServiceAccountToken: false` (at the pod or SA level). Fail (K8S-009): a workload mounts a token it does not use. **Blast radius — the correlation is the whole point:** an unused mounted token is harmless *only if* its SA is powerless. Join every mounting workload to its SA's `auth can-i` result from K8S-002/006: a mounted token whose SA can `list secrets` (or is `cluster-admin`) turns any RCE in that pod into cluster-secret theft with zero extra steps. Rank findings by the SA's actual power, not by count — a `default` SA with no bindings that mounts a token is `low`; the payments pod mounting a secrets-reader token is `high`. The fix is `automountServiceAccountToken: false` **and** narrowing the SA's RBAC — name both.

## 5. Network segmentation (K8S-003, K8S-011, K8S-010)

### K8S-003 — NetworkPolicy presence

```bash
NP_TMP="${TMPDIR:-/tmp}/k8s003.$$"
kubectl --context "$KUBE_CONTEXT" get ns -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | sort > "${NP_TMP}.all"
kubectl --context "$KUBE_CONTEXT" get networkpolicy -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u > "${NP_TMP}.with"
comm -23 "${NP_TMP}.all" "${NP_TMP}.with"
rm -f "${NP_TMP}.all" "${NP_TMP}.with"
```

Healthy: each application namespace appears with ≥1 NetworkPolicy. Fail (K8S-003): application namespaces (e.g. the one running checkout/orders/payments) appear in the zero-policy list — any pod can reach any other. System namespaces (`kube-system`, `kube-node-lease`) are excluded. **Blast radius — name the reachable datastore, not "flat network":** in a zero-policy namespace, list the workloads a compromised pod can open a TCP connection to, and call out the datastores by pod/port (`payments-db-0:5432`, `redis-0:6379`). "Any pod can reach `payments-db` on 5432" is a blast radius; "no network policy" is a linter line.

### K8S-011 — Default-deny baseline

```bash
# Namespaces that HAVE a default-deny ingress policy (empty podSelector + Ingress policyType).
kubectl --context "$KUBE_CONTEXT" get networkpolicy -A -o json | jq -r '
  .items[] | select(((.spec.podSelector.matchLabels // {}) | length) == 0
      and ((.spec.policyTypes // []) | any(. == "Ingress")))
  | .metadata.namespace' | sort -u
```

Healthy: every application namespace with any policy also carries a default-deny (the list above includes it). Fail (K8S-011): a namespace has NetworkPolicies but no default-deny — every pod that no policy explicitly selects is still wide open (allow-by-omission). **Blast radius:** name the pods in the namespace that no `podSelector` covers; those are the silent holes a reader would never spot from "we have network policies." This is the difference between "has policies" (K8S-003 passes) and "is actually segmented" — a namespace can pass K8S-003 and fail K8S-011.

### K8S-010 — External exposure surface

```bash
# Internet-facing Services (LoadBalancer / NodePort) with their selector and external address.
kubectl --context "$KUBE_CONTEXT" get svc -A -o json | jq -r '
  .items[] | select(.spec.type=="LoadBalancer" or .spec.type=="NodePort")
  | "\(.metadata.namespace)/\(.metadata.name)\ttype=\(.spec.type)\tports=\([.spec.ports[]? | "\(.port)/\(.protocol)"] | join(","))\tselector=\((.spec.selector // {}) | to_entries | map("\(.key)=\(.value)") | join(","))\textIP=\([.status.loadBalancer.ingress[]? | (.ip // .hostname)] | join(","))"'

# Ingress objects: which hosts route to which backend services.
kubectl --context "$KUBE_CONTEXT" get ingress -A -o json | jq -r '
  .items[] | "\(.metadata.namespace)/\(.metadata.name)\thosts=\([.spec.rules[]?.host] | join(","))\tbackends=\([.spec.rules[]?.http.paths[]?.backend.service.name] | join(","))"'
```

Healthy: exposure is deliberate and minimal — the ingress controller and intended public services only. Fail (K8S-010): an application workload is directly internet-reachable in a way its owner did not intend, **or** an exposed workload is also privileged/over-permissioned. **Blast radius — the flagship correlation:** for each exposed Service, resolve its selector to the backing workload, then join K8S-007 (is it privileged/host?), K8S-002/006/009 (what can its SA do?), and K8S-003 (is its namespace segmented?). State the whole path in one sentence: *"`store-front` is a LoadBalancer on 0.0.0.0:80 → its pod mounts an SA token → that SA can list secrets cluster-wide → its namespace has no NetworkPolicy: an RCE in this one public pod reaches every credential and every datastore in the cluster."* No scanner assembles that chain; it is the single most valuable line the audit can produce.

## 6. Resource governance (K8S-004, K8S-014)

### K8S-004 — Requests and limits

```bash
kubectl --context "$KUBE_CONTEXT" get deploy,sts,ds -A -o json \
  | jq -r '.items[] | . as $w | $w.spec.template.spec.containers[] | select((.resources.limits==null)) | "\($w.kind)/\($w.metadata.namespace)/\($w.metadata.name): container \(.name) has no limits (requests=\(.resources.requests != null))"'
```

Healthy: shared-path and application workloads set both requests and limits. Fail (K8S-004): the ingress controller or an application Deployment has `limits==null`. Requests-set-but-no-limits is a partial. **Blast radius:** an unbounded container is a per-node noisy-neighbor — name the node-shared workloads it can starve, and cross-reference K8SRT-002 (if it has already been OOMKilled, this is `validated-live`, not hypothetical). The ingress controller and any shared-path workload are the highest-value cases because a memory spike there degrades every request.

### K8S-014 — Namespace quotas and LimitRanges

```bash
# Namespaces that HAVE a ResourceQuota and/or a LimitRange.
kubectl --context "$KUBE_CONTEXT" get resourcequota -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u
kubectl --context "$KUBE_CONTEXT" get limitrange   -A -o jsonpath='{.items[*].metadata.namespace}' | tr ' ' '\n' | sort -u
# Compare against the application-namespace list (comm), report those with neither.
```

Healthy: each application namespace has a ResourceQuota (a ceiling) and a LimitRange (per-container defaults). Fail (K8S-014): an application namespace has neither. **Blast radius — the correlation with K8S-004:** a namespace with no LimitRange *and* workloads with no limits (K8S-004) is truly unbounded — a single runaway pod can consume the whole node pool and there is no admission-time backstop. A LimitRange also retro-fits sane defaults onto the K8S-004 offenders without editing every workload, so name it as the cheap first move. Scope to application namespaces; a quota on `kube-system` is often intentionally absent.

## 7. Reliability & resilience (K8S-005, K8S-012, K8S-013)

### K8S-005 — Disruption budgets on single-replica critical workloads

```bash
kubectl --context "$KUBE_CONTEXT" get pdb -A --no-headers 2>/dev/null | wc -l
kubectl --context "$KUBE_CONTEXT" get deploy -A -o json \
  | jq -r '.items[] | select((.spec.replicas // 1) == 1) | "\(.metadata.namespace)/\(.metadata.name): replicas=1"'
```

Healthy: critical workloads have replicas>1 or a PDB with `minAvailable`. Fail (K8S-005): a critical service is `replicas=1` and no PDB selects it. **Blast radius:** a routine node drain (cluster upgrade, autoscaler scale-down) takes it fully offline with no minAvailable guard — state that it is not a failure scenario but a *scheduled maintenance* scenario, which is why it bites. Cross-reference the critical-service list from Phase 1; a single-replica non-critical batch job is at most low.

### K8S-012 — Health probes

```bash
kubectl --context "$KUBE_CONTEXT" get deploy,sts,ds -A -o json | jq -r '
  .items[] | . as $w | $w.spec.template.spec.containers[]
  | select((.readinessProbe==null) or (.livenessProbe==null))
  | "\($w.kind)/\($w.metadata.namespace)/\($w.metadata.name)\t\(.name)\treadiness=\(.readinessProbe!=null)\tliveness=\(.livenessProbe!=null)"'
```

Healthy: application workloads define readiness and liveness probes. Fail (K8S-012): a workload is missing one or both. **Blast radius — two distinct failure modes, name the one that applies:** no *readiness* probe means every rolling update sends live traffic to pods that are still starting → user-visible 502s on every deploy (the most common silent cause of "errors during deploys"). No *liveness* probe means a deadlocked or wedged process is never restarted → a slow, invisible brownout until someone notices. For a critical service, missing readiness is the higher-severity of the two. Requests-only-no-limits is not this check; this is purely the probe stanzas.

### K8S-013 — Replica spread (HA that is actually HA)

```bash
kubectl --context "$KUBE_CONTEXT" get deploy,sts -A -o json | jq -r '
  .items[] | select((.spec.replicas // 1) > 1)
  | select((.spec.template.spec.topologySpreadConstraints==null)
      and (.spec.template.spec.affinity.podAntiAffinity==null))
  | "\(.kind)/\(.metadata.namespace)/\(.metadata.name)\treplicas=\(.spec.replicas)\tno topologySpread / no podAntiAffinity"'

# Live corroboration: are the replicas actually on distinct nodes right now?
kubectl --context "$KUBE_CONTEXT" get pods -A -o wide --no-headers 2>/dev/null \
  | awk '{print $1"\t"$8}' | sort | uniq -c   # count pods per (namespace,node) — same node = co-located
```

Healthy: multi-replica critical workloads set `topologySpreadConstraints` or pod anti-affinity so replicas land on different nodes. Fail (K8S-013): `replicas: 3` with no spread rule — the scheduler may (and often does) place all three on one node. **Blast radius — the "HA that isn't HA" trap a replica count hides:** `replicas: 3` reads as highly available, but with no spread rule a single node failure or drain takes all three down at once, exactly like a single replica. Use the live `-o wide` corroboration to say whether the replicas are co-located *right now* — if they are, mark the finding `validated-live`: this is not a hypothetical, the outage is one node-loss away today. This is why K8S-005 passing (replicas>1) is not the end of the resilience story.

## 8. Named defaults

| Knob | Default | Why |
| --- | --- | --- |
| Enforced PSA standard | `baseline` (target `restricted`) | baseline blocks the worst pod escapes without breaking most workloads |
| Application namespace | any ns not `kube-system`/`kube-node-lease`/`kube-public`/`gke-*`/`gmp-*`/provider-system | scopes network/PSA/quota/exposure findings to workloads you own |
| Critical single-replica severity | medium (high if named critical in business context) | node drains are routine; a single replica is a real availability gap |
| Host agent exemption | node agents + observability collectors by **identity**: CNI/CSI, kube-proxy, node-exporter, Promtail/Fluent Bit/Vector, eBPF agents (Beyla/Pixie/Cilium/Falco), OTel/metrics node collectors — in ANY namespace (`monitoring`, `lgtm`, …), not just system ones | legitimately need host access; a posture note, never a K8S-007 finding. A finding is an *application* workload that took host access it doesn't need |
| SA power ranking for K8S-009 | rank by the SA's `auth can-i` result, not by count | a mounted token matters only as much as its RBAC allows |

## 9. Forbidden commands (read-only guarantee)

Never run any of these — they mutate the cluster:

`kubectl apply`, `create`, `edit`, `patch`, `replace`, `delete`, `label`, `annotate`, `scale`, `rollout`, `set`, `cordon`, `drain`, `uncordon`, `taint`, `exec`, `cp`, `port-forward` (as a mutation path), `auth reconcile`, and `kubectl get secret -o yaml`/`-o json` (reads Secret values). This audit only ever `get`/`list`/`auth can-i`/`version`/`api-resources`/`config view`, plus — in the live-runtime snapshot (section 10) only, through the guarded `le_kubectl` wrapper — the read-only `top` verb. `auth can-i --as=` is a read-only subjectaccessreview and is explicitly allowed; it changes nothing. The wrapper's allowlist contains no mutating verb, and `ci/liveness-readonly-check.sh` enforces that mechanically.

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

This section has no pass/fail. A probe that returns nothing, times out, or is RBAC-denied is recorded `skipped, reason: <exact error>` — verdict unknown, never healthy. `top` on a cluster without metrics-server (no `metrics.k8s.io` API) is the expected shape on many clusters: skip with that reason; it is not an error and not a finding. Where metrics-server exists, its default RBAC aggregates `system:aggregated-metrics-reader` into the `view` ClusterRole, so the audit credential from the doctor gate usually covers `top`; a denial is still just a skip. A bare `restartCount` with no terminated reason or Warning event is a symptom row in the snapshot table, never a K8SRT finding. This section never calls `logs`; previous-container log depth belongs to `/scoutflo:rca`.
