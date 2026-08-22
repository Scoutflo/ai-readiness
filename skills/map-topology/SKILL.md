---
name: map-topology
description: Builds a read-only service topology map from Istio or plain Kubernetes and writes topology.md plus a Scoutflo-aligned topology-export.json with routes, entry points, and re-run deltas. Use when the user asks to map services or the cluster, build or refresh a service map or topology, list entry points, ingress routes, or who calls whom, or update topology.md after a deploy. Do not use to score observability coverage (use audit-all or an audit-* skill); it never changes cluster state.
---

# map-topology

Maps how traffic moves through your cluster and writes the result to `./scoutflo-audits/topology.md`. When Istio is installed, the map is read **directly from the Istio CRDs in your cluster** — `VirtualServices`, `DestinationRules`, `Gateways`, `ServiceEntries`, and sidecar coverage on pods — via `kubectl get`/`list` (and `istioctl proxy-status` where available). It does **not** use Kiali, a service-mesh dashboard, Prometheus, or any external topology source; if you don't run Kiali, that changes nothing here. Without a mesh, the map comes from plain Kubernetes: Services, Ingresses, workloads, and Endpoints. Every cluster operation is read-only (`get` and `list` only); the only write is the local `topology.md` file.

Full command recipes live in [references/istio-queries.md](references/istio-queries.md). This file holds the workflow; go to the cookbook for the exact `kubectl`, `istioctl`, and `jq` blocks each phase names.

## What topology.md is used for

`topology.md` is the shared service map for the whole toolkit:

- Every audit skill loads it (`audit-lgtm`, `audit-grafana`, `audit-sentry`, `audit-alert-routing`, `audit-aws`, `audit-gcp`, and all the others, plus `audit-all`). Its service list becomes the critical-service list, and its names become the canonical service names in findings, coverage matrices, and `affected` arrays.
- Triage starts here: the entry points section shows where user traffic lands, the traffic map shows who calls whom, and the watchpoints table shows which monitoring backend to open for each service.
- Only this skill and you edit the file. Audits may propose updates when live discovery contradicts the map, but they never write it.

Refresh cadence (example, tune to your release rhythm):

- Re-run after any deploy that adds, removes, or renames a service.
- Re-run after ingress, gateway, or mesh routing changes.
- Re-run before you establish a new scheduled-audit baseline with `schedule-audits`.
- Monthly as a backstop, even when nothing changed on purpose.

Keep `./scoutflo-audits/` out of public version control. The map names your namespaces, hosts, and internal routes.

## Prerequisites

| Requirement | Why | Required |
| --- | --- | --- |
| `kubectl` | every cluster read | yes |
| `jq` | JSON parsing | yes |
| `istioctl` | proxy sync status on the mesh path | no; the mesh path degrades to `kubectl`-only checks, the fallback path never needs it |
| `kubernetes.context` in `~/.scoutflo/toolkit.yaml` | names the cluster to map | yes |

Credentials: none beyond your kubeconfig. The kubeconfig user needs `get` and `list` on namespaces, pods, services, endpoints, deployments, statefulsets, daemonsets, and ingresses, plus the `networking.istio.io` resources when the mesh path runs. This is the read-only tier; no elevated access, no secrets, no `*_env` variables.

Managed clusters (EKS, GKE, AKS) whose context is not yet in your kubeconfig: fetch it once with the provider CLI as shown in `/scoutflo:connect` (Kubernetes → Fetching a cluster context). AKS with Microsoft Entra integration also needs `kubelogin` (`az aks install-cli`). Once the context exists this skill maps it unchanged — AKS is just another context.

If `/scoutflo:doctor` is set up, run it first; it validates the same context this skill depends on.

## Phase 0: Preflight and live-safety gate

Never map a cluster you have not positively identified. Every command in this skill pins `--context "${KUBE_CONTEXT}"`; the ambient kubeconfig default is never trusted.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context

command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 1; }
command -v jq >/dev/null      || { echo "jq not installed"; exit 1; }

kubectl config get-contexts -o name | grep -qx "${KUBE_CONTEXT}" \
  || { echo "context ${KUBE_CONTEXT} not in kubeconfig; run /scoutflo:connect"; exit 1; }

echo "config context:  ${KUBE_CONTEXT}"
echo "current default: $(kubectl config current-context 2>/dev/null || echo '(none)')"
kubectl --context "${KUBE_CONTEXT}" cluster-info | head -n 1

# A GKE/EKS/AKS context authenticates through an exec plugin; an expired credential
# fails with a cryptic exec error, not an RBAC one. Detect the plugin so a failed
# reachability check names the REAUTH path instead of a generic "fix kubernetes.context"
# (mirrors the audit-kubernetes doctor gate / the /scoutflo:doctor probe).
EXEC_CMD="$(kubectl config view --minify --context "${KUBE_CONTEXT}" -o jsonpath='{.users[*].user.exec.command}' 2>/dev/null || true)"
if kubectl --context "${KUBE_CONTEXT}" auth can-i list services -A; then :; else
  case "${EXEC_CMD}" in
    *gke-gcloud-auth-plugin*) echo "context ${KUBE_CONTEXT} (GKE) could not authenticate — the gke-gcloud-auth-plugin credential is likely expired; run: gcloud auth login (then gcloud container clusters get-credentials <cluster> to refresh), not a kubernetes.context change"; exit 1 ;;
    *aws*)                    echo "context ${KUBE_CONTEXT} (EKS) could not authenticate — the aws exec-plugin credential is likely expired; run: aws sso login (or otherwise refresh your AWS credentials), not a kubernetes.context change"; exit 1 ;;
    *kubelogin*)              echo "context ${KUBE_CONTEXT} (Entra AKS) could not authenticate — refresh the kubelogin credential (re-run az login), or run az aks install-cli if kubelogin is missing"; exit 1 ;;
    *)                        echo "context ${KUBE_CONTEXT} reaches no cluster or lacks read RBAC; verify kubernetes.context and that your kubeconfig user can list services"; exit 1 ;;
  esac
fi
```

Expected: the `can-i` line prints `yes` and `cluster-info` shows the API endpoint of the cluster you intend to map. If the endpoint is not the cluster you expect, stop and fix `kubernetes.context` before scanning anything. A default context that differs from the config context is fine, because no later command uses the default; a config context that resolves to the wrong cluster is not.

## Phase 1: Size the estate and detect the mesh

Two decisions come out of this phase, both printed before any deep collection runs: the sizing path (how much ceremony the estate justifies) and the mesh path (where the topology comes from).

### Estate sizing

One cheap call counts what the run will map. The thresholds are named variables with example defaults; tune them to your environment.

Before sizing, pick the `NS_EXCLUDE` preset for your provider — GKE, EKS, AKS, or vanilla (cookbook: "Namespace-exclude presets") — then extend it; the vanilla default leaves managed-cluster system namespaces (`gke-managed-*`, `gmp-system`, `aws-observability`, `gatekeeper-system`, ...) in the map and in these counts, and the same value must be used in every block of the run.

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
NS_EXCLUDE="^(kube-system|kube-public|kube-node-lease|istio-system)$"   # vanilla preset; pick your provider's (cookbook: "Namespace-exclude presets"), then extend
SMALL_MAX_WORKLOADS="30"     # single-pass ceiling; example, tune to your environment
MEDIUM_MAX_WORKLOADS="150"   # one-run ceiling; example, tune to your environment

counts=$(kubectl --context "${KUBE_CONTEXT}" get namespaces,deployments,statefulsets,daemonsets -A -o json \
| jq -r --arg ex "${NS_EXCLUDE}" '
    ([.items[] | select(.kind == "Namespace") | select(.metadata.name | test($ex) | not)] | length) as $ns
    | ([.items[] | select(.kind != "Namespace") | select(.metadata.namespace | test($ex) | not)] | length) as $wl
    | "\($ns) \($wl)"')
ns_count=${counts% *}; wl_count=${counts#* }
path="large"
[ "${wl_count}" -le "${MEDIUM_MAX_WORKLOADS}" ] && path="medium"
[ "${wl_count}" -le "${SMALL_MAX_WORKLOADS}" ] && path="small"
echo "estate: namespaces=${ns_count} workloads=${wl_count} sizing-path=${path}"
```

Expected: one line, for example `estate: namespaces=14 workloads=52 sizing-path=medium`. Print the chosen path and the counts that drove it; the same line goes into the map header in Phase 3.

| Path | When | How the run behaves |
| --- | --- | --- |
| small | workloads at most `SMALL_MAX_WORKLOADS` | Phases run as written: cluster-wide calls, intermediates in a throwaway temp dir, one sitting. No worklist, no batching. |
| medium | workloads at most `MEDIUM_MAX_WORKLOADS` | Same cluster-wide calls, still one run, but declare `TMP="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology/$(date -u +%F)"` in every block instead of the mktemp default, so a failed collection step is redone alone instead of restarting the run. |
| large | above `MEDIUM_MAX_WORKLOADS` | Namespace batches against a durable worklist with resume support; see [Large clusters: worklist, batches, and resume](#large-clusters-worklist-batches-and-resume). |

Proportionality is a rule in both directions:

- ❌ Built a worklist and ran namespace batches for a cluster with 12 workloads.
- ✅ 12 workloads is under `SMALL_MAX_WORKLOADS`; declared the small path and mapped everything in one pass, no worklist file.

### Detect the mesh

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context

if kubectl --context "${KUBE_CONTEXT}" get crd virtualservices.networking.istio.io >/dev/null 2>&1; then
  echo "istio CRDs: present"
else
  echo "istio CRDs: absent"
fi
kubectl --context "${KUBE_CONTEXT}" get deploy -A -l app=istiod \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ready={.status.readyReplicas}{"\n"}{end}'
istioctl --context "${KUBE_CONTEXT}" version 2>/dev/null || echo "istioctl not installed (optional)"
```

Decision rule:

- CRDs present **and** at least one `istiod` deployment with `ready >= 1`: take the mesh path (Phase 2A).
- CRDs present but no running `istiod`: take the fallback path (Phase 2B) and record "Istio CRDs present, control plane not running" in the map header. Orphaned CRDs are common after a partial uninstall; an empty mesh inventory from them is not a topology.
- No CRDs: take the fallback path.

Note the mesh mode: namespaces labeled `istio.io/dataplane-mode=ambient` run without sidecars, so an empty sidecar list there is expected, not a gap.

## Phase 2A: Istio inventory (mesh path)

Collect, in order, using the cookbook sections named here:

1. **Namespaces in scope** (cookbook: "Namespace scan"). Apply the `NS_EXCLUDE` filter and record injection labels (`istio-injection`, `istio.io/rev`, `istio.io/dataplane-mode`) per namespace.
2. **Sidecar coverage** (cookbook: "Sidecar coverage"). Pods carrying an `istio-proxy` container, plus `istioctl proxy-status` for sync state when `istioctl` is available. A workload in an injection-enabled namespace with no sidecar is worth a note in the map.
3. **Workloads and versions** (cookbook: "Workloads and versions"). Deployments, StatefulSets, DaemonSets with their version, resolved by precedence: `version` pod label, then `app.kubernetes.io/version`, then a non-`latest` image tag, else `unknown`.
4. **Service-to-workload mapping** (cookbook: "Service-to-workload join"). Same join as the fallback path; the mesh does not replace it.
5. **VirtualServices** (cookbook: "VirtualService routes"). One row per route destination: hosts, bound gateways (`mesh` when unset), destination host, subset, weight. Check `tcp` and `tls` route blocks too, not just `http`.
6. **DestinationRules** (cookbook: "DestinationRule subsets"). Subset names and their labels; subsets are the version axis of the traffic map.
7. **Gateways** (cookbook: "Istio Gateways"). Always query `gateways.networking.istio.io` by full name so the Kubernetes Gateway API resource of the same short name cannot be swept in silently. Servers give hosts, ports, protocols; VirtualServices bound to each gateway give the "routes to" column.
8. **ServiceEntries** (cookbook: "ServiceEntries"). External dependencies; they become `-> external` rows in the traffic map.

Derive from this: the service list, the route table (who -> whom, with subset and weight), the entry points (gateways plus any plain Ingress that also exists), and the version/subset picture per service.

On the large path, feed each collection filter from the merged batch pulls per [Large clusters: worklist, batches, and resume](#large-clusters-worklist-batches-and-resume) instead of live cluster-wide calls. The filters and the derivations do not change.

## Phase 2B: Plain Kubernetes inventory (fallback path)

Collect, using the cookbook sections named here:

1. **Namespaces in scope** (cookbook: "Namespace scan").
2. **Workloads and versions** (cookbook: "Workloads and versions").
3. **Service-to-workload mapping** (cookbook: "Service-to-workload join"). Services join to workloads whose pod-template labels satisfy the Service selector, within the same namespace. `ExternalName` services are external dependencies, not workloads.
4. **Endpoint backing** (cookbook: "Endpoint backing check"). Every Service is checked for ready endpoint addresses. A Service whose selector matches nothing is listed explicitly as backendless; do not guess a workload for it.
5. **Ingress** (cookbook: "Ingress entry points"). Hosts, paths, and backend services become the entry points and the ingress rows of the traffic map.

Without a mesh there is no declared service-to-service routing, so the traffic map holds what Kubernetes actually knows: entry points -> Services (from Ingress backends) and Services -> workloads (from selectors). Do not invent call graphs from naming conventions.

On the large path, feed each collection filter from the merged batch pulls per the next section instead of live cluster-wide calls.

## Phase 2C: Source-repo evidence (Tier 3, both paths)

Capture a **heuristic** source-repository candidate for each workload from data already in hand — no new cluster access, no new credentials. This is the free tier of the tiered evidence model ([references/scoutflo-export.md](references/scoutflo-export.md#source_repo_evidence--tiered-typed-servicerepo-evidence-optional-additive)); it feeds `map-repos`' candidate ranking and the platform's future automation resolver from one captured set.

Run the cookbook's **"Source-repo evidence (Tier 3: image-path candidate)"** block: for each workload, record the full `image`, its `image_digest`, and a `source_repo_evidence` entry whose `candidate_repo` is the registry path's last two segments (`evidence_source: image_registry_path`, `confidence: heuristic`, `subpath: null`). A bare single-segment image (e.g. `postgres:18.4`) yields no candidate — that is correct, not a gap.

These are **candidates, not mappings**. This skill never verifies them against GitHub and never writes a `USES` edge from a heuristic candidate — `map-repos` does the live verification. The authoritative tiers cost more and ship later:

- **Tier 1 — OCI `org.opencontainers.image.source` + `.revision`** (authoritative): run the cookbook's **"Source-repo evidence (Tier 1: OCI image labels)"** block — a registry **config-blob** fetch via `crane` (not `kubectl`), reading the source-repo URL and the commit SHA straight from the image the workload is actually running. Yields an `oci_image_source` `source_repo_evidence` entry (`confidence: authoritative`) and, when the image carries a 40-hex `org.opencontainers.image.revision`, the workload-level `deployed_revision` — no ArgoCD required. `crane` absent, or an image without the labels, skips cleanly (Tiers 2-3 still run); a private registry needs `crane auth login` first.
- **Tier 2 — ArgoCD Application CRs** (authoritative; carries `subpath`, `branch_ref`, and — when the app has synced — `deployed_revision`): no ArgoCD API or new config needed — when the cluster runs ArgoCD, the Application CRs are readable with the same kubeconfig this skill already uses (`kubectl get applications.argoproj.io -A`, read-only; needs `get`/`list` on that CRD). Run the cookbook's **"Source-repo evidence (Tier 2: ArgoCD Applications)"** block. Evidence reaches workloads through the block's `managed_workloads` join (from `status.resources`): Phase 3 attaches each Application's evidence to the export workloads it actually manages, by `namespace`+`workload_name`+`workload_type`; a never-synced Application joins to nothing and is recorded as an unattached note, never guessed onto a workload. Helm-chart sources are skipped (a chart registry is not a source repo). `deployed_revision` is recorded **only** when the synced revision is a real 40-hex SHA — a never-synced Application echoes its target ref there, which is branch context (`branch_ref`), never a revision. Absence of the CRD is normal (skip silently); this skill never creates, syncs, or touches an Application.

Until those are wired, capture Tier 3 only; a workload with no resolvable candidate simply carries an empty `source_repo_evidence` array.

## Large clusters: worklist, batches, and resume

Runs on the large path only. All state lives under a run-ID-keyed run directory `./scoutflo-audits/map-topology/runs/<RUN_ID>/` (see [Run-ID keying](#run-id-keying) below), not a calendar-date directory: the worklist, the raw per-namespace pulls, the step TSVs, and the partial map. It is working state, not a report; delete the run directory after `topology.md` is written, or delete it to force a fresh start.

0. **Find a resumable run, or start a new one** (cookbook: "Worklist build and resume"). Before minting a new `RUN_ID`, scan `./scoutflo-audits/map-topology/runs/*/worklist.tsv` for one with pending rows and offer to resume it. Only mint a fresh `RUN_ID` when nothing resumable is found.
1. **Build or resume the worklist** (cookbook: "Worklist build and resume"). One row per in-scope namespace, status `pending` or `done`. If the resumed run's worklist already exists, the run continues from it: it prints done and pending counts and continues with pending namespaces only. Never rebuild an existing worklist; rebuilding forgets progress.
2. **Lock, then pull one batch** (cookbook: "Worklist lock" and "Batch pull"). Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes, example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending namespaces and pull raw JSON per namespace for the kinds the chosen path needs. A namespace is marked `done` only after all of its pulls succeed, so an interrupted batch resumes at the namespace that failed. Release the lock once the batch's rows are marked.
3. **Merge and collect** (cookbook: "Merge raw pulls"). Merge the raw pulls into the same JSON shape the cluster-wide calls produce, then run the same collection filters against the merged files. Producer swap only; the filter bodies do not change.
4. **Assemble incrementally.** After each batch, recompose `topology.partial.md` in the run directory from all step TSVs accumulated so far, and print progress (`done=X pending=Y`). Repeat from step 2 until the worklist has zero pending rows.

### Run-ID keying

A calendar-date run directory breaks when a run crosses midnight UTC mid-batch: the date rolls over and the next batch either lands in a fresh, empty directory or the skill has to guess which date directory is "still mine". This skill keys its run directory by `RUN_ID`, the first-seen timestamp of that specific run, generated once and reused for every command block in the run:

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}/raw"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

Before running the block above, scan for a resumable run so an interrupted mapping does not restart from namespace one:

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology"
resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$2 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d}"
    echo "resumable run found: ${d} (pending=${pending})"
  done
fi
[ -n "${resumable}" ] && echo "resume ${resumable}? offer this to the user before proceeding" \
  || echo "no resumable run found; safe to start a new one"
```

Two hard rules:

- Cluster-scoped inventory is never batched. The namespace label scan, the istiod check, `istioctl proxy-status`, and `gateways.networking.istio.io` are single cheap calls; pull each once per run.
- The shared `./scoutflo-audits/topology.md` is replaced only by a run whose worklist has zero pending rows. Audits treat that file as canonical, so a partial map never overwrites it. If you stop early, the partial map and the worklist in the run directory are the resume point, and the shared map stays as it was.

## Phase 3: Write topology.md and topology-export.json

Two artifacts, same inventory: `topology.md` for humans and audits, and `./scoutflo-audits/topology-export.json`, the machine-readable form aligned to the Scoutflo platform's topology import contract. Compose the JSON per [references/scoutflo-export.md](references/scoutflo-export.md): every service with its correlation attributes (`service_name`, `namespace`, `cluster_id`, `app`), every workload resource with its four mandatory attributes plus its optional `image`, `image_digest`, and `source_repo_evidence[]` (the Tier-3 candidates from Phase 2C — a build-origin breadcrumb for `map-repos` to verify, never a repo identity by itself), one resource per watchpoints backend, and the edge families (`DEPLOYED_AS`, `PART_OF`, `ROUTES_TO`, `CALLS`, `SENDS_METRICS_TO`, `SENDS_LOGS_TO`, `SENDS_TRACES_TO`, `MONITORED_BY`, `USES`). Validate with `jq empty` before moving it into place. Audits read this file for the Scoutflo Topology Readiness section of their reports.

Compose the new map in a temp file first (`${TMP}/topology.new.md`); Phase 4 needs both old and new before the final write. On the large path, compose from the step TSVs in the run directory, and only after the worklist shows zero pending rows. Structure:

~~~markdown
# Service Topology

| | |
| --- | --- |
| Cluster context | <KUBE_CONTEXT> |
| Mesh | istio <version> \| none \| CRDs present, control plane not running |
| Generated (UTC) | <YYYY-MM-DD> |
| Generated by | /scoutflo:map-topology |
| Estate | <ns> namespaces, <wl> workloads; <small \| medium \| large> path |
| Namespaces scanned | <list> |
| Namespaces excluded | <NS_EXCLUDE value> |

Audits and triage load this file. Re-run /scoutflo:map-topology after
deploys or routing changes; only the Integration watchpoints section
is yours to edit, everything else is regenerated.

## Services

| Service | Namespace | Workload | Version | Sidecar |
| --- | --- | --- | --- | --- |
| checkout | shop | deployment/checkout | 1.4.2 | yes |

## Traffic map

| From | To | Via | Detail |
| --- | --- | --- | --- |
| gateway shop/public-gw | checkout | VirtualService shop/checkout-vs | host=checkout, subset=v2, weight=100 |
| checkout | payments | VirtualService shop/payments-vs | mesh route, subset=v1 |
| checkout | external | ServiceEntry shop/psp-api | hosts=psp.example.com |

## Entry points

| Entry point | Kind | Hosts | Ports | Routes to |
| --- | --- | --- | --- | --- |
| shop/public-gw | istio gateway | shop.example.com | 443/HTTPS | checkout, search |

## Integration watchpoints

Fill these in: which monitoring covers which service. Audits use the
rows to focus coverage checks; triage uses them to open the right
backend first. Rows you fill are carried forward on re-runs, keyed on Namespace + Service (never Service alone — two same-named services in different namespaces are different rows and must never collapse or swap).

| Service | Namespace | Metrics | Logs | Traces | Errors | Alert route | Owner |
| --- | --- | --- | --- | --- | --- | --- | --- |
| checkout | shop | unknown | unknown | unknown | unknown | unknown | unknown |

## Changes since <previous run date>

- Added (n): <service, ...>
- Removed (n): <service, ...>
- Rewired (n): <service: what changed, ...>
~~~

Rules:

- One Services row per Service/workload pair from the join; backendless Services get `Workload = none (backendless)`.
- Sidecar column: `yes`, `no`, `ambient`, or `n/a` (fallback path).
- Fallback-path traffic map: Ingress -> Service rows and Service -> workload rows only.
- Every service gets one pre-seeded watchpoints row with `unknown` in each cell.
- First run: the Changes section reads `First run, no previous map.`

## Phase 4: Delta on re-run

If `./scoutflo-audits/topology.md` already exists, copy it aside before writing anything, then compare (cookbook: "Delta helpers" for the exact extraction commands):

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md"
TMP="${TMP:-$(mktemp -d)}"
[ -f "${OUT}" ] && cp "${OUT}" "${TMP}/topology.prev.md" && echo "previous map saved" || echo "first run"
```

1. **Added / removed services**: extract `namespace/service` keys from the Services tables of both files, `sort`, `comm`. Added services appear in the new file only; removed in the old only.
2. **Rewired**: diff the Traffic map and Entry points sections. A service present in both runs whose route rows changed (different destination, subset, weight, gateway, or ingress backend) is rewired; name the service and the change in one line each.
3. **Watchpoints carry-forward**: extract the old Integration watchpoints rows. Keep every row whose service still exists, exactly as the user wrote it. Append fresh `unknown` rows for added services. List removed services' rows under the Changes section so the user deletes them deliberately; never drop user-entered data silently.
4. Write the final `topology.md`: new inventory sections, carried-forward watchpoints, and the Changes section with the previous run date from the old header.

## Phase 5: Verify and summarize

The write is unverified until re-read:

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md"
EXPORT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"
[ -f "${OUT}" ] || { echo "topology.md was not written"; exit 1; }
awk '/^## /' "${OUT}"
awk -F'|' '/^## Services/{f=1;next} /^## /{f=0} f && /^\|/ {n++} END {print n-2, "service rows"}' "${OUT}"
jq -e '.version == "scoutflo-topology-export/v1"' "${EXPORT}" >/dev/null || { echo "topology-export.json missing or invalid"; exit 1; }
jq -r '"export: \(.services|length) services, \(.resources|length) resources, \(.relationships|length) relationships"' "${EXPORT}"
```

Expected: all five section headers (`Services`, `Traffic map`, `Entry points`, `Integration watchpoints`, `Changes since ...`) and a service-row count matching the Phase 2 inventory. If the counts disagree, the compose step dropped rows; fix before reporting success.

On the large path, also prove the worklist finished before trusting the map:

```bash
set -eu
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/map-topology"
# RUN_DIR is the run-ID-keyed directory from this run (see Run-ID keying above); if this
# block runs in a fresh shell, fall back to the most recently modified run directory.
RUN_DIR="${RUN_DIR:-$(ls -dt "${AUDIT_ROOT}"/runs/*/ 2>/dev/null | head -n 1 | sed 's:/$::')}"
if [ -n "${RUN_DIR}" ] && [ -f "${RUN_DIR}/worklist.tsv" ]; then
  pending=$(awk -F'\t' '$2 == "pending"' "${RUN_DIR}/worklist.tsv" | wc -l | tr -d ' ')
  echo "worklist pending: ${pending}"
  [ "${pending}" -eq 0 ] || { echo "worklist incomplete; do not replace topology.md yet"; exit 1; }
else
  echo "no worklist (small or medium path); nothing to assert"
fi
```

Expected: `worklist pending: 0` on a completed large run, and exit 0. A nonzero pending count means the run must resume batching, not publish.

### T1/T2 pre-check: catch structural gaps before any audit runs

This skill is the only place in the toolkit that can check [topology-readiness.md](../../report-standard/topology-readiness.md)'s T1 (service identity) and T2 (workload attributes) without any live provider call — everything both checks need is already in `topology-export.json`, because this skill just wrote it. Every audit skill re-derives the same T1/T2 verdict later per critical service; running it once here means a customer sees an identity or workload gap immediately; on the first map, not after connecting a provider and waiting for an audit to reach that service.

```bash
set -eu
EXPORT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"
{
  printf 'service\tT1-identity\tT2-workload\n'
  jq -r '
    . as $root
    | .services[] as $svc
    | ($svc.attributes // {}) as $attr
    | (($svc.name != null) and ($svc.service_type != null) and ($svc.environment != null)
       and ($svc.business_criticality != null) and ($attr.service_name != null)
       and ($attr.namespace != null) and ($attr.cluster_id != null)) as $t1
    | ([$root.relationships[] | select(.relation == "DEPLOYED_AS" and .from.name == $svc.name)]) as $deploy_edges
    | (($deploy_edges | length) > 0) as $has_deploy_edge
    | (if $has_deploy_edge then
         ($deploy_edges[0].to.name) as $wl_name
         | (($root.resources[] | select(.name == $wl_name) | .attributes) // {}) as $wl_attr
         | (($wl_attr.cluster_id != null) and ($wl_attr.namespace != null)
            and ($wl_attr.workload_name != null) and ($wl_attr.workload_type != null))
       else false end) as $t2
    | "\($svc.name)\t\(if $t1 then "pass" else "fail" end)\t\(if $t2 then "pass" else "fail" end)"
  ' "$EXPORT"
} | column -t -s "$(printf '\t')"
```

Expected: one row per service. A service failing T1 is missing a required field or a correlation attribute (`service_name`/`namespace`/`cluster_id`) — usually a `service_type`, `environment`, or `business_criticality` that was never confirmed with the user (never invent these; ask once per run, per this skill's own rule above). A service failing T2 has no `DEPLOYED_AS` edge, or its workload resource is missing one of the four mandatory attributes — both mean the service-to-workload join in Phase 2B (or 2A) didn't find a backing object; check the Endpoint backing check output for that service.

State the count in the terminal close-out ("N of M services pass T1/T2 structural checks") and, when any service fails, name it and the exact missing field — this is what a customer fixes before an audit's own Topology Readiness section can move past `not-ready` for that service, since T1/T2 gate T3-T6 (a `not-ready` verdict never evaluates the observability-edge checks). Do not compute T3-T6 here: those need each provider's live state, which only the matching audit skill can verify.

Close by telling the user, in the terminal:

- The resolved **absolute** paths of `topology.md` and `topology-export.json` (resolve `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}` first) with the OS open command (macOS `open`, Linux `xdg-open`, Windows `start`), plus mesh or fallback path taken, namespaces scanned and excluded.
- Sizing path taken (small, medium, or large) with the namespace and workload counts that drove it.
- Service, entry-point, and external-dependency counts.
- The T1/T2 pre-check summary above.
- The delta summary (or "first run").
- The two follow-ups: fill the Integration watchpoints rows, and run an audit (`audit-all` or a specific one) so findings can use the new map.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Same service name repeats across two or more mapped clusters, and Scoutflo platform correlation resolves one service to a workload running in the *wrong* cluster | This is a real, confirmed platform-level failure mode, not hypothetical. When mapping 2+ clusters with any repeated service names, record which cluster each same-named service's workload actually lives in explicitly in `topology.md`, and flag the repeated name in the map header so a later Scoutflo Topology Readiness check knows to verify cluster-scoped resolution rather than assuming it |
| Wrong cluster mapped because the shell's default context differed from the config | Pin `--context "${KUBE_CONTEXT}"` on every command and compare `cluster-info` output against the intended cluster before scanning |
| A GKE/EKS/AKS exec-plugin credential expiry framed as "fix kubernetes.context" | Phase 0 detects the exec command and, on a failed reachability check, names the reauth path (`gcloud auth login` / `aws sso login` / re-run `az login`) instead of implying the context itself is wrong |
| Istio CRDs present but no control plane, so the mesh path returns an empty map | Require a ready `istiod` before choosing the mesh path; otherwise fall back and record why in the header |
| Kubernetes Gateway API `gateways` mixed into Istio gateway results | Query the full resource name `gateways.networking.istio.io`, never the `gateways` short name |
| Stale Service with a selector that matches nothing mapped to a guessed workload | Check Endpoints for every Service and list backendless Services explicitly |
| Re-run clobbers hand-filled Integration watchpoints | Copy the old file aside first and carry user rows forward; only add rows or flag removals |
| System and mesh namespaces flood the service list | Apply `NS_EXCLUDE` and print the excluded list in the map header so omissions are visible |
| Managed-cluster system namespaces (`gke-managed-*`, `gmp-system`, `aws-observability`, `gatekeeper-system`, ...) mapped as services because the vanilla `NS_EXCLUDE` default only knows vanilla Kubernetes — confirmed on a real GKE cluster | Pick the provider preset (GKE, EKS, AKS, or vanilla) from the cookbook's "Namespace-exclude presets" in Phase 1, extend it, and use the same value in every block of the run |
| Image tag `latest` recorded as a version | Resolve versions by label precedence and record `latest` or missing tags as `unknown` |
| Call graph invented from service naming conventions on the fallback path | Only emit traffic rows backed by an object: Ingress backend, Service selector, VirtualService, or ServiceEntry |
| Worklist and batches run on a tiny cluster | Size the estate first; at or below `SMALL_MAX_WORKLOADS` the small path runs one pass with no worklist file |
| Interrupted large run restarted from zero, re-pulling every namespace | Resume from `worklist.tsv` in the run directory; only pending namespaces are pulled again |
| Partial large-path map replaces the shared topology.md | Only a run whose worklist has zero pending rows may write `./scoutflo-audits/topology.md`; partial maps stay in the run directory |
| Run crosses UTC midnight and the next batch lands in a fresh, empty date directory, abandoning everything already pulled | Key the run directory by `RUN_ID` (first-seen timestamp of the run), never by calendar date |
| Two invocations pull the same batch of namespaces at once and corrupt the worklist | Acquire `worklist.lock` before claiming a batch; treat a lock older than `LOCK_STALE_MINUTES` as abandoned and reclaim it |
| Mesh path chosen correctly (CRDs present, istiod ready) but the cluster is mesh-inert everywhere except a small sandbox namespace, so mesh-derived rows are near-empty | The gate is right even when its yield is thin: sidecar coverage and VirtualService/DestinationRule/Gateway/ServiceEntry counts near zero outside one namespace mean the mesh is installed but barely adopted, not a bug. Report the true sidecar coverage ratio rather than assuming the mesh path implies mesh-wide routing data. Confirmed live: a real cluster with Istio CRDs + a ready istiod had 0 sidecars across 27 namespaces except one `istio-injection=enabled` test namespace, where all mesh objects (1 VirtualService, 1 DestinationRule, 1 Gateway, 1 ServiceEntry) also lived. |
| Two same-named Services in different namespaces collapse into one map row / one watchpoints row | Qualify every colliding service as `<service>.<namespace>` in the map and the export (`attributes.service_name` keeps the bare name); the watchpoints table carries a Namespace column and carry-forward keys on Namespace + Service |
