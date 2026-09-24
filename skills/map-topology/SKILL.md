---
name: map-topology
description: Builds a read-only service topology map from the best available source — Istio or plain Kubernetes when a cluster is configured, and otherwise cloud inventories (AWS ECS/EC2/Lambda/ALB, DigitalOcean), APM-derived service maps (New Relic entities + span-derived call edges, Sentry projects), or a guided capture — and, on AWS/DigitalOcean/Azure/GCP estates, Cloud Mode maps the resources behind services (databases, caches, queues, buckets) with evidence-classed service→resource connections reviewed in batches — plus an APM overlay that adds observed database edges on any estate including Kubernetes. Writes topology.md plus a Scoutflo-aligned topology-export.json with routes, entry points, resources, connections, and re-run deltas. Use when the user asks to map services, the cluster, or a non-Kubernetes estate, map which service uses which database or resource, build or refresh a service map or topology, list entry points or who calls whom, or update topology.md after a deploy. Do not use to score observability coverage (use audit-all or an audit-* skill); it never changes any live state.
---

# map-topology

Maps how traffic moves through your estate and writes the result to `./scoutflo-audits/topology.md`. The map comes from the **best source you actually have** — Kubernetes is the richest, not the requirement:

- **Istio on Kubernetes**: read directly from the Istio CRDs (`VirtualServices`, `DestinationRules`, `Gateways`, `ServiceEntries`, sidecar coverage) via `kubectl get`/`list` (and `istioctl proxy-status` where available). No Kiali, no dashboard, no Prometheus needed.
- **Plain Kubernetes**: Services, Ingresses, workloads, and Endpoints.
- **No Kubernetes at all**: services from your cloud inventory (AWS ECS/EC2/Lambda + ALB entry points, DigitalOcean apps), call edges from an APM that observes them (New Relic's span-derived service map), and platform-grade correlation anchors from Sentry projects — merged into one honest map. A rule of thumb the merge follows: infrastructure sources name the services; APM sources connect them.
- **Nothing configured**: a guided capture builds an operator-asserted map instead of a dead-end.
- **Cloud Mode (AWS, DigitalOcean, Azure, GCP)**: beyond the services
  themselves, map the resources they depend on — databases, caches, queues,
  topics, buckets — and the service→resource connections, every edge carrying
  its evidence class (declared / observed / permitted / reachable) and
  reviewed with you in batches before it lands in the map (Phase 2E). An APM
  overlay adds observed database edges on ANY estate — including a pure
  Kubernetes one.

Every operation is read-only (`get`/`list`/GraphQL-and-REST reads only); the only write is the local `topology.md` file.

Full command recipes live in [references/istio-queries.md](references/istio-queries.md) (the Kubernetes/Istio paths), [references/non-k8s-sources.md](references/non-k8s-sources.md) (the cloud/APM/guided paths, merge rules, and non-Kubernetes export rules), and the Cloud Mode cookbooks — [references/cloud-mode-aws.md](references/cloud-mode-aws.md) (also home of the shared rules: evidence composition, access tiers, redaction), [references/cloud-mode-digitalocean.md](references/cloud-mode-digitalocean.md), [references/cloud-mode-azure.md](references/cloud-mode-azure.md), [references/cloud-mode-gcp.md](references/cloud-mode-gcp.md), [references/cloud-mode-apm-overlay.md](references/cloud-mode-apm-overlay.md), and [references/cloud-mode-fallbacks.md](references/cloud-mode-fallbacks.md) (every denial's next move). This file holds the workflow; go to the cookbooks for the exact blocks each phase names.

## What topology.md is used for

`topology.md` is the shared service map for the whole toolkit:

- Every audit skill loads it (`audit-lgtm`, `audit-grafana`, `audit-sentry`, `audit-alertmanager`, `audit-aws`, `audit-gcp`, and all the others, plus `audit-all`). Its service list becomes the critical-service list, and its names become the canonical service names in findings, coverage matrices, and `affected` arrays.
- Triage starts here: the entry points section shows where user traffic lands, the traffic map shows who calls whom, and the watchpoints table shows which monitoring backend to open for each service.
- Only this skill and you edit the file. Audits may propose updates when live discovery contradicts the map, but they never write it.

It describes **one** cluster. With a multi-cluster estate (a labeled `kubernetes` list), keep a separate map per cluster — see [Prerequisites](#prerequisites) — so no audit ever reads the wrong cluster's services.

Refresh cadence (example, tune to your release rhythm):

- Re-run after any deploy that adds, removes, or renames a service.
- Re-run after ingress, gateway, or mesh routing changes.
- Re-run before you establish a new scheduled-audit baseline with `schedule-audits`.
- Monthly as a backstop, even when nothing changed on purpose.

Keep `./scoutflo-audits/` out of public version control. The map names your namespaces, hosts, and internal routes.

## Prerequisites

| Requirement | Why | Required |
| --- | --- | --- |
| `jq` | JSON parsing, every path | yes |
| **At least one topology source** in `~/.scoutflo/toolkit.yaml`: `kubernetes` (richest), or any of `aws`, `digitalocean`, `azure`, `gcp`, `newrelic`, `sentry` — or a metrics store (`prometheus`/`mimir`/`victoriametrics`) carrying Tempo service-graph data | names what to map; Phase 0 routes to the best configured source (a metrics store counts only when its one-metric probe finds service-graph data) | yes — with **none**, the guided capture runs instead of a dead-end |
| `kubectl` | every cluster read | only on the Kubernetes path |
| `istioctl` | proxy sync status on the mesh path | no; the mesh path degrades to `kubectl`-only checks, the other paths never need it |
| provider CLI/keys for a non-Kubernetes source (`aws` CLI + profile, `doctl`, the New Relic User key, the Sentry token) | the cloud/APM discovery reads | only for the sources you route through; each is the same read-only credential its audit already uses |

Credentials on the Kubernetes path: none beyond your kubeconfig. The kubeconfig user needs `get` and `list` on namespaces, pods, services, endpoints, deployments, statefulsets, daemonsets, and ingresses, plus the `networking.istio.io` resources when the mesh path runs. This is the read-only tier; no elevated access, no secrets, no `*_env` variables.

Managed clusters (EKS, GKE, AKS) whose context is not yet in your kubeconfig: fetch it once with the provider CLI as shown in `/scoutflo:connect` (Kubernetes → Fetching a cluster context). AKS with Microsoft Entra integration also needs `kubelogin` (`az aks install-cli`). Once the context exists this skill maps it unchanged — AKS is just another context.

map-topology is **per-cluster**: one run maps one cluster and writes one `topology.md`. A single `kubernetes` block is the whole story — nothing below changes for it. When `kubernetes` is instead a **labeled list** of contexts — the same shape `audit-kubernetes` iterates — run map-topology **once per labeled context**: select the target with `SCOUTFLO_TARGET=<label>` and resolve its `context` through the shared enumerator `report-standard/toolkit-targets.sh` (`count`/`label`/`get`), never a single `kubernetes.context` scalar (Phase 0 does exactly this). Give each cluster its **own** map by pointing `SCOUTFLO_AUDIT_DIR` at a per-cluster directory, so each run writes its own `topology.md` and `topology-export.json` instead of overwriting the last (audits read both from that same `SCOUTFLO_AUDIT_DIR` root, so a per-cluster workspace keeps map and audits aligned). One shared `topology.md` reused across clusters would describe the wrong cluster for all but one — the same-service-name-across-clusters hazard the Common Failure Modes table already warns about.

If `/scoutflo:doctor` is set up, run it first; it validates the same context this skill depends on.

## Phase 0: Preflight, source routing, and live-safety gate

**Route to a source first — never assume Kubernetes, never dead-end without it.**

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SOURCES=""
for src in kubernetes aws digitalocean azure gcp newrelic sentry prometheus mimir victoriametrics; do
  n=$(sh "$TT" "$CFG" "$src" count 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] && SOURCES="$SOURCES $src"
done
SOURCES="${SOURCES# }"
if [ -z "$SOURCES" ]; then
  echo "no topology source configured (kubernetes, aws, digitalocean, newrelic, or sentry) — running the GUIDED CAPTURE instead: the map will be built from your answers, marked operator-asserted (see references/non-k8s-sources.md, Guided capture), and upgraded automatically when a source is connected later"
else
  echo "topology sources configured: ${SOURCES}"
  case " $SOURCES " in
    *" kubernetes "*) echo "route: Kubernetes path (richest) — Phases 1-2C; other sources may add out-of-cluster services in Phase 2D" ;;
    *) echo "route: non-Kubernetes path — Phase 2D discovery from: ${SOURCES} (see references/non-k8s-sources.md)" ;;
  esac
fi
```

With `kubernetes` among the sources, continue below exactly as before. Without it, skip to [Phase 2D](#phase-2d-non-kubernetes-discovery) after verifying each routed source's identity the same way its audit's doctor gate does (AWS: `sts get-caller-identity` with the config's own profile/region; New Relic/Sentry: the authed JSON probe from the cookbook — every probe keeps the body and content-type and fails closed on non-JSON). Never map an account you have not positively identified — the wrong-account hazard is the same off-cluster as on.

**Kubernetes path only, from here to Phase 2C.** Never map a cluster you have not positively identified. Every command pins `--context "${KUBE_CONTEXT}"`; the ambient kubeconfig default is never trusted.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"

# Resolve the kubernetes context through the shared enumerator so a single block (one `context`)
# and a labeled LIST of targets read the SAME way — never assume a single `kubernetes.context`
# scalar, no yq required. A single block returns its own `context` (behaves identically to before);
# a labeled list returns the SCOUTFLO_TARGET-selected item's `context`. map-topology maps ONE
# cluster per run — re-run once per label for a multi-cluster estate (see Prerequisites).
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
K8S_N=$(sh "$TT" "$CFG" kubernetes count)
[ "${K8S_N:-0}" -ge 1 ] || { echo "no kubernetes target configured in $CFG — this block is the Kubernetes route; use the Phase-0 source routing (a non-Kubernetes estate maps via Phase 2D, never a dead-end)"; exit 1; }
K8S_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$K8S_N" ]; do [ "$(sh "$TT" "$CFG" kubernetes label "$_i")" = "$SCOUTFLO_TARGET" ] && { K8S_IDX=$_i; break; }; _i=$((_i+1)); done; fi
K8S_LABEL=$(sh "$TT" "$CFG" kubernetes label "$K8S_IDX"); KUBE_CONTEXT=$(sh "$TT" "$CFG" kubernetes get "$K8S_IDX" context)
[ -n "$KUBE_CONTEXT" ] || { echo "kubernetes target '${K8S_LABEL:-?}' has no context in $CFG; run /scoutflo:connect"; exit 1; }
[ "${K8S_N}" -gt 1 ] && echo "note: ${K8S_N} kubernetes targets configured — mapping '${K8S_LABEL}' only; re-run once per label (SCOUTFLO_TARGET=<label>), each with its own SCOUTFLO_AUDIT_DIR" || true

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
KUBE_CONTEXT="your-kube-context"   # the context resolved in Phase 0 (single block, or the SCOUTFLO_TARGET-selected list item)
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
KUBE_CONTEXT="your-kube-context"   # the context resolved in Phase 0 (single block, or the SCOUTFLO_TARGET-selected list item)

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

## Phase 2D: Non-Kubernetes discovery

Runs when the Phase-0 routing selected non-Kubernetes sources — and also after
2A-2C when other sources are configured alongside a cluster (a Lambda or a
legacy VM lives outside the cluster; the cluster map alone would miss it).
Exact blocks, per-source honesty ceilings, and the merge rules are in
[references/non-k8s-sources.md](references/non-k8s-sources.md); the workflow:

1. **Services from infrastructure**: AWS ECS services, Lambda functions, EC2
   instances grouped by their Name/service tag (the grouping tag is recorded in
   the map header; `untagged` rows stay visible as exactly that), DigitalOcean
   App Platform components and droplets. On Azure and GCP the app enumerations
   in their Cloud Mode cookbooks are the service source — App Service /
   Function Apps / Container Apps and Cloud Run / Cloud Functions
   respectively (each cookbook's "Declared configuration" section lists them);
   GKE and AKS clusters stay on the Kubernetes path.
2. **Services and call edges from APM**: New Relic service entities from BOTH
   entity domains (OpenTelemetry `EXT` + agent `APM` — one alone misses half an
   estate), and its span-derived `CALLS` relationships; and Tempo
   service-graph metrics read from the estate's metrics store (one probe
   query yields service names AND call edges — the second call-observing
   source). These are the non-Kubernetes sources that give the Traffic map
   real edges. Sentry projects join as
   service identities whose `project`/`environment` attributes are
   platform-accepted correlation anchors.
3. **Merge** per the cookbook's rules: infrastructure names the services, APM
   connects them; every service row records its `sources`; name conflicts are
   surfaced as open questions, never guessed; edges come only from sources that
   observe calls — co-location, shared tags, and naming similarity are never
   edges.
4. **Entry points** from internet-facing ALBs/NLBs (listeners + target groups)
   and App Platform ingress, in place of Ingress/Gateway rows.
5. **Guided capture** when nothing is configured: build the map from the
   operator's answers, every row marked `asserted`, the header stating so. An
   asserted map still gives every audit its canonical service names — most of
   this file's daily value.

The Phase-3 export on this path follows the cookbook's **non-Kubernetes export
rules**: services, integration backends, and evidenced edges are emitted;
`kubernetes_*` workload resources and `DEPLOYED_AS` edges are **never
fabricated** for cloud workloads (the platform import's workload types are
Kubernetes-only today — an invented "deployment" would be a lie the platform
then trusts). The Topology Readiness section renders the consequence honestly:
workload mapping reads as a current platform limit for these services, while a
Sentry-anchored service still reaches full match confidence.

## Phase 2E: Cloud Mode — resources and service→resource edges

Runs when a **cloud source** is configured (`aws`, `digitalocean`, `azure`,
`gcp` — with or without a cluster), and its **APM overlay** step runs on ANY
estate with `newrelic` configured, Kubernetes included: after 2D's service
rows exist, map the **resources** behind them — databases, caches, queues,
topics, buckets — and the **service→resource edges**, each edge carrying its
evidence. These are not call edges: the Traffic map's rules are untouched,
and an edge with no join evidence does not exist.

One cookbook per cloud holds the exact blocks; the shared rules (evidence
classes, composition, review tiers, redaction) are defined once in the AWS
cookbook and apply verbatim everywhere:

| Cloud | Cookbook | Live-proof status (see its header) |
| --- | --- | --- |
| AWS | [references/cloud-mode-aws.md](references/cloud-mode-aws.md) | live-proven |
| DigitalOcean | [references/cloud-mode-digitalocean.md](references/cloud-mode-digitalocean.md) | live-proven |
| Azure | [references/cloud-mode-azure.md](references/cloud-mode-azure.md) | live-proven core (app-lane first rows owed) |
| GCP | [references/cloud-mode-gcp.md](references/cloud-mode-gcp.md) | live-proven (core lanes; Memorystore/Functions rows owed) |
| APM overlay (any estate) | [references/cloud-mode-apm-overlay.md](references/cloud-mode-apm-overlay.md) | CALLS lane live-proven; datastore rows verify-on-first-live-row |

0. **Access gate + scope checkpoint.** Run the cloud's identity gate — AWS
   also probes its permission tier (cookbook: "Identity and access-tier
   gate"); DigitalOcean/Azure/GCP verify account/subscription/project
   (cookbook: "Identity and access gate") — then the cheap counts: the
   endpoint catalog (cookbook: "Resource endpoint catalog", per cloud) plus
   2D's service list — and pause before any per-service read, exactly like
   the audits' estate checkpoint: show `services / resources / regions`,
   offer full scope or a selection (`cli_pause_before_audit` +
   `cli_prompt_exclude_services`). The announced access posture is written
   into the map header and decides which lanes below run. **Every denial or
   missing source follows the fallback playbook** (cookbook: "The fallback
   matrix"): the user is told what CAN be mapped right now, the single
   smallest unlock for more, and the workaround — never a dead end, never
   "access denied" as the headline.
1. **Declared lane** (access permitting): per in-scope service, read config
   declarations — AWS task definitions and functions (cookbook: "Declared
   configuration: ECS" and "Declared configuration: Lambda"), resource-side
   wiring (cookbook: "Reverse event wiring") and resolution hops (cookbook:
   "Resolution chains"); DigitalOcean app specs, Azure Service Connector /
   Container Apps, GCP Cloud Run specs (each cloud's cookbook: "Declared
   configuration"). Extraction is redaction-first — keys/hosts/refs only,
   never values (cookbook: "Redaction discipline for configuration values").
2. **Corroboration lanes**: identity permissions per distinct principal —
   AWS roles (cookbook: "Permitted lane: IAM"), Azure managed identities and
   GCP service accounts (their cookbooks: "Permitted lane"), DigitalOcean
   trusted sources (cookbook: "Permitted and reachable lane: trusted
   sources") — wildcard/default-principal demotion is a hard rule
   everywhere. Network reachability per cloud (AWS cookbook: "Reachable
   lane: security groups and VPC endpoints"; the others: "Reachable lane").
   Observed probes run once and skip cleanly when the estate has them
   disabled (AWS cookbook: "Observed lane: opportunistic probes"; Azure/GCP:
   "Observed lane"). When `repo-map.json` exists, the IaC lane adds declared
   joins with zero live-config access (cookbook: "IaC-in-repo lane").
2b. **APM overlay** (any estate shape, including pure Kubernetes): when
   `newrelic` is configured, read each in-scope service's observed datastore
   connections (cookbook: "New Relic datastore edges"); when the estate's
   Tempo service-graphs are reachable, add its database edges (cookbook:
   "Grafana Tempo service-graph edges"). Observed edges expire — carry
   `valid_from` and re-verify on re-runs; on a Kubernetes estate this step
   simply enriches the existing K8s map with resource edges.
2c. **Cross-cloud attribution** (runs only when two or more clouds are
   configured): a resource in one cloud is often reached by a service in
   another, and the only evidence is an IP allowlist entry — a DigitalOcean
   managed DB trusting a raw `ip_addr`, a Cloud SQL authorized network, an AWS
   security-group CIDR — that each cloud's own reachable lane could only record
   as an *unattributed* opening. Build one combined `IP → owner` catalog across
   the configured clouds and resolve those openings against it
   (cookbook: "Cross-cloud IP attribution"): a hit becomes a `reachable`-class
   service→resource edge; a host `/32` that matches no owner stays an
   unattributed opening (a finding, never a guessed edge). `reachable` class
   only — never upgraded on IP evidence alone — and wide CIDRs are demoted, not
   expanded per owner.
3. **Synthesize edges** (cookbook: "Declared-edge synthesis" then "Evidence
   composition and confidence"): one edge per service↔resource pair, lanes
   appended as evidence on the same edge, confidence per the composition
   table.
4. **Review — in batches, never an interrogation.** Present three groups:
   - **Tier A** (declared+corroborated, ESM/reverse-wired): one table, each
     row showing its join thread (`checkout → payments-db: env DATABASE_URL
     host = <rds endpoint> [declared+reachable]`) — one bulk confirm with
     per-row opt-outs.
   - **Tier B** (single-witness: permitted-only, reachable-only,
     logical-name-only): candidates confirmed per group; never silently drawn.
   - **Tier C** (refutations: declared but unresolvable/no network path):
     surfaced as probable-stale-config questions — never silently drawn AND
     never silently dropped.
   Confirmed rows get `evidence: asserted` appended (the user's answer is
   evidence); rejected rows are recorded as rejected so re-runs do not
   re-propose them unchanged.
5. **The two orphan lists, one batched question each**: resources with no
   edge ("unclaimed — cost/orphan candidates; also read by audit-cost") and
   in-scope services with no resource edge ("stateless, or a gap at this
   access tier?"). Answers land in the map, marked asserted.
6. **Guided capture for connections** (extends 2D's guided capture): when a
   tier or a permission leaves discovery blind for some service, offer —
   pick-from-catalog (numbered list of discovered resources), paste
   keys/hosts in the operator's own words, import an existing catalog file,
   or skip. Everything captured this way is `asserted`, upgraded
   automatically when a later run finds real evidence. For a zero-access
   estate, also offer the self-serve script the operator runs inside their
   own boundary (cookbook: "Zero-access discovery pack") — its output
   imports through the same review, never around it.
7. **Tag propagation**: capture each resource's `env`/`team`/`service` tags
   and its containment (account/VPC), and record top-level tags once — a tag
   set on the VPC/account propagates to contained resources in the map
   (overridable per resource, precedence resource > container > global, the
   same precedence business-context's computed metadata uses). Untagged
   groups get ONE batched question, never per-resource interrogation.

On a large estate (in-scope services above the same large-path threshold
Phase 1 uses — example, tune to your estate), the per-service declared lane
runs through the same run-directory worklist/lock/resume mechanism as the
large cluster path, with one row per service instead of per namespace — an
interrupted cloud mapping resumes at the service that failed, never from
zero.

Multi-target discipline: with a labeled cloud list (`aws` profiles, `azure`
subscriptions), Phase 2E runs per label through the shared enumerator exactly
as Phase 0 does — one map per target, never a merged account soup. A
single-block `digitalocean` (one token) or `gcp` (one project) is one target
by construction.

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

Two artifacts, same inventory: `topology.md` for humans and audits, and `./scoutflo-audits/topology-export.json`, the machine-readable form aligned to the Scoutflo platform's topology import contract. Compose the JSON per [references/scoutflo-export.md](references/scoutflo-export.md): every service with its correlation attributes (`service_name`, `namespace`, `cluster_id`, `app`), every workload resource with its four mandatory attributes plus its optional `image`, `image_digest`, and `source_repo_evidence[]` (the Tier-3 candidates from Phase 2C — a build-origin breadcrumb for `map-repos` to verify, never a repo identity by itself), one resource per watchpoints backend, and the edge families (`DEPLOYED_AS`, `PART_OF`, `ROUTES_TO`, `CALLS`, `SENDS_METRICS_TO`, `SENDS_LOGS_TO`, `SENDS_TRACES_TO`, `MONITORED_BY`, `USES`). When Phase 2E ran, also emit the cloud resources and the reviewed service→resource connections per the export cookbook's **Cloud Mode** section (additive; Tier-C questions and unconfirmed low-tier candidates are never exported as edges). Validate with `jq empty` before moving it into place. Audits read this file for the Scoutflo Topology Readiness section of their reports.

**Inventory (by environment) — the "what exists" view, saved and reused.** After the export is written and validated, render a complete per-environment inventory into `topology.md` from it — never hand-write it, regenerate it (same rule as the export): `sh report-standard/render-report-viz.sh topology-inventory "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"` produces the `## Inventory (by environment)` section — per-environment server/datastore counts and **environment twins** (a base name that appears in only one environment is flagged, "intended, or a missing environment?"). Place it right after the Services section. It is the complete catalog **independent of edges** (a server is listed whether or not a connection was found for it), so a lopsided or mislabeled estate is visible at a glance; it is derived from the saved `topology-export.json`, so a re-run refreshes it deterministically and never drifts from the map.

When Phase 2E produced service→resource connections, also render the **service map** from the same export — never hand-write it: `sh report-standard/render-report-viz.sh mermaid-mesh "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology-export.json"` writes a `## Service map (service → datastore)` section — a Mermaid diagram with **directional arrows labelled by connection type and evidence class** (`STORES_DATA_IN · declared+reachable`), **datastore cylinders carrying `engine · port` config**, and **nodes coloured by environment**. It renders inline on GitHub/Obsidian and exports to PNG with any Mermaid tool, so it is the shareable "who depends on which datastore" picture. Both the inventory and the service map read only the export, so neither can disagree with the map.

Compose the new map in a temp file first (`${TMP}/topology.new.md`); Phase 4 needs both old and new before the final write. On the large path, compose from the step TSVs in the run directory, and only after the worklist shows zero pending rows. Structure:

~~~markdown
# Service Topology

| | |
| --- | --- |
| Topology sources | <KUBE_CONTEXT> \| aws+newrelic+sentry \| guided capture (asserted) |
| Mesh | istio <version> \| none \| CRDs present, control plane not running \| n/a (non-Kubernetes) |
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

## Cloud resources and connections

Access tier: full-read. Confirmed 12 of 14 proposed connections (2 opted out);
2 open questions below.

| Service | Resource | Kind | Relation | Evidence | Join thread | Status |
| --- | --- | --- | --- | --- | --- | --- |
| checkout | payments-db | database (postgres) | STORES_DATA_IN | declared+reachable | env DATABASE_URL host = rds endpoint | confirmed |
| worker | order-events | message_queue (sqs) | SUBSCRIBES_TO | declared (esm) | lambda event source mapping | confirmed |
| reports | analytics-db | database (mysql) | STORES_DATA_IN | permitted | role may read, no config visible | candidate |

Unclaimed resources (no service connects): legacy-cache (cache), old-exports
(object_storage) — cost/orphan candidates, also read by /scoutflo:cost-analysis.
Open questions: orders declares db host `db.legacy.internal` which resolves to
nothing (stale config?); api has no resource edge (stateless, or a gap at this
access tier?).

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
- The Cloud resources and connections section appears only when Phase 2E ran;
  its header states the access tier verbatim and the confirm/opt-out counts.
  `Status` is `confirmed` (user accepted), `candidate` (Tier B, awaiting an
  answer), or `question` (Tier C refutations and the orphan lists) — a
  candidate is never silently promoted. Kubernetes-only estates: the section
  is absent, not empty.

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
4. **Connection carry-forward (Cloud Mode)**: keyed on `service + resource`.
   A `confirmed` or opted-out row whose evidence still holds carries forward
   as-is — the user is never re-asked. A carried row whose evidence CHANGED
   (the join thread disappeared, the endpoint moved, a lane was refuted)
   resurfaces in the review with the old and new evidence side by side. New
   pairs enter as Tier A/B/C per Phase 2E; nothing previously rejected is
   re-proposed unless its evidence changed.
5. Write the final `topology.md`: new inventory sections, carried-forward watchpoints and connections, and the Changes section with the previous run date from the old header.

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

This skill is the only place in the toolkit that can check [topology-readiness.md](../../report-standard/topology-readiness.md)'s T1 (service identity) and T2 (workload attributes) without any live provider call — everything both checks need is already in `topology-export.json`, because this skill just wrote it. Every audit skill re-derives the same T1/T2 verdict later per critical service; running it once here means you see an identity or workload gap immediately; on the first map, not after connecting a provider and waiting for an audit to reach that service.

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

State the count in the terminal close-out ("N of M services pass T1/T2 structural checks"; when Phase 2E ran, add the connection line: "K confirmed resource connections across J services; L candidates / open questions pending in the map") and, when any service fails, name it and the exact missing field — this is what you fix before an audit's own Topology Readiness section can move past `not-ready` for that service, since T1/T2 gate T3-T6 (a `not-ready` verdict never evaluates the observability-edge checks). Do not compute T3-T6 here: those need each provider's live state, which only the matching audit skill can verify.

### Environment coverage: catch a lopsided or mislabeled map

An estate usually runs the same stack in more than one environment (`prod`
alongside `pre-prod`/`staging`/`testing`), near-symmetric but for config. A run
that maps prod thoroughly and only skims a non-prod twin ships a sparse
pre-prod that reads as "few dependencies" when it is really the same shape —
live-caught on our own estate. Compute per-environment coverage and corroborate
each entity's environment from THREE signals — name convention, platform label,
and what it actually connects to — never one (cookbook: "Environment coverage").
The platform label is the weakest and is never trusted on its own: a real
DigitalOcean estate reported `environment: Production` for pre-prod apps, and a
naive `*prod*` name match buckets `preprod` as prod — the matcher tests
`pre-prod`/`pp` before `prod` for exactly that reason.

Surface four questions for the batched review, never an automatic edit: a twin
whose one environment shows `NO-EDGES` beside a sibling's `edges` ("under-mapped
twin, or a real config difference?"); a label-vs-name conflict ("the platform
said X, the name says Y"); a service whose edges land mostly in a *different*
environment ("mislabeled, or a genuine cross-env dependency" — a `testing`
service reaching `prod` datastores is a security finding, not a mapping quirk);
and, when the estate is otherwise twinned, a **prod base with no non-prod twin**
("prod runs this and pre-prod does not — intended, or a whole service missed?").
That last one is the direct answer to "why does pre-prod look smaller than prod"
— it names exactly which prod services have no pre-prod counterpart.
State the per-environment counts in the close-out; when a twin is flagged
`NO-EDGES`, say so plainly rather than presenting the thin side as complete.
When all three signals fail together — no name marker, a label that can't be
trusted, and no connectivity because the edges themselves were access-denied
(empty allowlist plus config/networking/`.env` reads the tier refuses) — the
environment is `unconfirmed`, never guessed: it enters the same batched review
and guided capture Phase 2E uses (labeled with what was tried, what was denied,
and the smallest unlock), and the operator's answer is recorded as `asserted`
(cookbook: "Environment coverage").

Close by telling the user, in the terminal:

- The resolved **absolute** paths of `topology.md` and `topology-export.json` (resolve `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}` first) with the OS open command (macOS `open`, Linux `xdg-open`, Windows `start`), plus mesh or fallback path taken, namespaces scanned and excluded.
- Sizing path taken (small, medium, or large) with the namespace and workload counts that drove it.
- Service, entry-point, and external-dependency counts.
- The T1/T2 pre-check summary above.
- The environment-coverage summary: the per-environment counts and any twin,
  label-conflict, or cross-environment flags (or "single environment").
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
| A non-Kubernetes estate treated as "can't proceed" | Phase-0 routing maps from aws/digitalocean/newrelic/sentry, or runs the guided capture — the kubernetes block is the richest source, not a prerequisite |
| A workload object fabricated for an ECS/Lambda/VM service | The platform import's workload types are Kubernetes-only today; the export ships services + evidenced edges and states the limit — never an invented `kubernetes_deployment` |
| An edge inferred from placement (shared SG/subnet/tag/name) | Only call-observing sources (Istio, New Relic spans) produce Traffic-map edges; infrastructure proximity is placement, not traffic |
| New Relic queried on one entity domain only | OTel services are `EXT`, agent services are `APM` — query both or half the estate is invisible |
| A service→resource edge drawn from a name guess or tag co-location | Cloud Mode edges exist only with a join thread (host/logical-name/ref match, ESM, IAM ARN, SG path); intent-class signals never materialize an edge (cookbook: "Evidence composition and confidence") |
| A raw task definition / function config (env values included) written to disk or echoed | Extraction is in-stream: key + host + port + db name survive, values never do; temp files deleted in-block (cookbook: "Redaction discipline for configuration values") |
| An IAM `Resource: "*"` statement fanned out into edges to every queue/table in the account | Wildcard demotion is a hard rule — at most one intent-class note on the service, never per-resource edges |
| A declared edge whose endpoint no longer resolves (or has no network path) silently drawn — or silently dropped | Tier C: surfaced as a probable-stale-config question in the review; the user decides |
| Every proposed edge asked one by one — twenty questions for a twelve-edge estate | Review runs in tier batches: one bulk confirm for Tier A with per-row opt-outs; Tier B per group; re-runs never re-ask unchanged confirmations (connection carry-forward) |
| AccessDenied on config reads retried, worked around, or treated as a bug | The access-tier gate treats denial as an answer: the run degrades to the tier's lanes and the map header states the ceiling (cookbook: "Identity and access-tier gate") |
| `secretsmanager:GetSecretValue` / `ssm:GetParameter` called to "complete" a join | Never called, any lane, any tier — secret references are join keys by name; values are out of scope by construction |
| A raw `doctl databases list -o json` dump printed or saved — it contains the connection PASSWORD | Every DigitalOcean recipe pipes to a jq field selection in the same command; the password field never survives (cookbook: "Traps") |
| Azure app settings read "because the credential worked" | The elevated lane is explicit opt-in per run — a working credential is not consent; Reader-tier is the default posture and a denial is the expected answer |
| GCP default compute service account's bindings fanned out into edges to everything | Default-SA demotion is a hard rule — one intent-class note, never per-resource edges (same class as the AWS wildcard rule) |
| An APM-observed datastore edge kept forever after traffic stopped | Observed edges carry `valid_from` and expire; absence of traffic is not absence of dependency, and stale observed evidence degrades to whatever other lanes support |
| Tempo service-graph `server` label treated as a hostname | Under the default label mapping it often carries a LOGICAL database name — join at logical-name tier (one review tier weaker), verify the label shape per estate |
