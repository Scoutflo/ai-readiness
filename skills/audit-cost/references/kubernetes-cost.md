# audit-cost: Kubernetes Cost & Resource-Efficiency Check Catalog

Runnable, read-only checks for the Kubernetes provider section of [audit-cost](../SKILL.md). This provider is **not scored** and does not enter any `score.categories`/`score.excluded`: every finding carries `points_recoverable: 0` and `area: cost-optimization`. IDs are `COST-K8S-NNN`, a permanent registered prefix; a retired check keeps its number and it is never reused.

**Maturity note (v1):** the Kubernetes cost provider is authored but **not yet live-proven** end to end (AWS and GCP are the proven targets). Treat its commands as correct-by-construction and verify against your cluster before quoting a finding.

Kubernetes bills nothing on its own — the money lives in the cloud nodes and disks underneath it. So this catalog is almost entirely **presence and ratio facts about over-provisioning**: a container that reserves ten times what it uses, a workload that reserves nothing at all, a disk nobody mounts, a node pool that could bin-pack onto fewer machines. The *only* place a dollar figure may appear is when a cluster-cost integration (Kubecost / OpenCost) is installed and returns one — and even then it is copied verbatim, never derived.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when a cluster-cost integration (Kubecost's own savings/right-sizing API, or an OpenCost allocation endpoint) returns that number, copied verbatim. Kubernetes core exposes **no** cost figure, so every check that reads only `kubectl`/metrics-server/Prometheus is a presence or ratio fact: report the request-to-usage ratio, the object count, the allocated-vs-used gap — never a dollar. The tempting fabrication here is multiplying a wasted-vCPU or wasted-GB number by a node/EBS price you looked up. Do not. A ratio is verifiable from the cluster; a dollar assembled from a price table is a guess that lands in a budget conversation.

- ❌ `COST-K8S-001: orders-api requests 2000m CPU but uses ~150m; that wastes 1.85 vCPU, and at $0.04/vCPU-hour that is roughly $54/mo.`
- ✅ `COST-K8S-001: Deployment payments/orders-api container app requests 2000m CPU, observed p95 150m over 7d = 7.5% of request (13.3x over-provisioned); reported as a request-to-usage ratio with NO estimated_monthly_savings_usd, because Kubernetes exposes no native cost figure — the ratio is the finding.`
- ✅ `COST-K8S-008: Kubecost request-sizing recommends orders-api CPU 200m; estimated_monthly_savings_usd is 41.20, copied verbatim from the Kubecost savings API's monthlySavings field — the one and only place a dollar is allowed here.`

## 2. Check catalog

| ID | Signal | Source API | Savings figure |
| --- | --- | --- | --- |
| COST-K8S-001 | Containers with requests set but sustained CPU/memory usage far below request (over-provisioned) | metrics-server (`kubectl top`) **or** Prometheus (`kube-state-metrics` + cAdvisor) | None — ratio fact (request-to-usage) |
| COST-K8S-002 | Workloads with **no** CPU/memory requests at all (unpredictable bin-packing, node bloat) | `kubectl get deploy,sts,ds,cronjob -o json` | None (presence fact) |
| COST-K8S-003 | Oversized or idle PVCs (allocated capacity far above used, or bound but mounted by no running pod) | `kubectl get pvc/pods` + Prometheus `kubelet_volume_stats_*` | None — ratio/presence fact |
| COST-K8S-004 | Replica count / HPA floor far above observed load | `kubectl get deploy,hpa` + Prometheus usage | None — ratio fact |
| COST-K8S-005 | Orphaned Released / never-bound Available PersistentVolumes still holding a billable backing disk | `kubectl get pv -o json` | None (presence fact) |
| COST-K8S-006 | Completed / failed Jobs (and their Pods) never cleaned up (no `ttlSecondsAfterFinished`) | `kubectl get jobs,pods -o json` | None (presence fact) |
| COST-K8S-007 | Under-packed nodes / node-pool headroom (summed pod requests far below allocatable across the pool) | `kubectl get nodes` + `kubectl top nodes` + Prometheus | None — ratio fact (surplus node count) |
| COST-K8S-008 | Cluster / namespace / workload cost allocation, and a right-sizing figure where the source offers one | **On GKE, the cloud's own billing export** (COST-GCP-024 — nodes are Compute Engine VMs, so their real cost is already billed; GKE cost allocation adds the namespace/workload labels). **Or** an existing Kubecost `/model/*` / OpenCost `/allocation/*` endpoint | **Native $** — verbatim from the billing export, or from Kubecost `monthlySavings`; OpenCost `totalCost` is verbatim actual spend. Never a figure derived by multiplying a rate by a quantity |

| COST-K8S-009 | **Where a cluster's money actually goes**: net spend attributed per namespace and workload, ranked, with each one's request-vs-usage ratio beside it | COST-GCP-024 (the cloud's billing export + cost-allocation labels) joined to this cluster's requests/usage | **Native $** — verbatim export spend per namespace; the *saving* stays indicative or unpriced |
| COST-K8S-010 | Node-pool economics: capacity type, machine family and zone spread versus what the workload needs | `kubectl get nodes` labels (instance type, spot/preemptible, zone) + the node pool's own billed spend | **Indicative** for a priced capacity-type or family change; presence fact for zone spread |
| COST-K8S-011 | **The orphan chain**: one dead workload billing across several resource types at once, rolled into a single finding | Joins this file's own COST-K8S-003/005/006 to the cloud's disk and snapshot findings (COST-GCP-005/020/022) by backing-volume identity | Sums only the **already-sourced** figures from the joined findings; invents nothing, and the chain is marked `deduplicated` so nothing is double-counted |

Only **COST-K8S-008 and COST-K8S-009** can ever carry a dollar, and only when a cost source is present and returns one. **COST-K8S-001 through COST-K8S-007 are presence/ratio facts and carry no `$` under any circumstance.**

## 3. Doctor-gate dependency

Every check here depends on the doctor gate's Kubernetes reachability probe plus a cost-specific probe row, `kubernetes cost-metrics` (`skills/doctor/scripts/doctor.sh`). That probe is informational and **never fails the run**; a missing scope **excludes the affected check with the reason**, it never guesses. The dependency splits three ways, so state the split explicitly rather than excluding the whole provider when only part of it is blocked:

- **Ratio checks (COST-K8S-001, -003 usage ratio, -004, -007)** need a windowed metrics source, resolved in this order: (1) an explicit `kubernetes.prometheus_url` scraping `kube-state-metrics` + cAdvisor; (2) **on GKE, Cloud Monitoring** — `kubernetes.io/container/*` is already there under the `roles/monitoring.viewer` this audit holds, with roughly six weeks of retention, so **no extra setup and nothing to install** (section 6b); (3) metrics-server answering `kubectl top`, which is a **snapshot** and must be labelled one (section 4). If none is reachable → `excluded, reason: "no metrics source (Prometheus / Cloud Monitoring / metrics-server) reachable"`. Never fabricate usage.
- **Plain-`get` presence checks (COST-K8S-002, -003 idle/bound, -005, -006)** need only `list`/`get` view RBAC already covered by the base Kubernetes doctor probe, so they still run even when no metrics source exists.
- **COST-K8S-008** needs a cost source, resolved in this order: (1) **on GKE, the Cloud Billing export** via COST-GCP-024 (`gcp.billing_bq_dataset`, plus `gcp.billing_project` when the export lives in another project, + GKE cost allocation on the cluster) — first-party, nothing to install; (2) an **existing** Kubecost/OpenCost endpoint at `kubernetes.cost_integration_url`. Absent both → `excluded, reason: "no cost source: neither a GCP billing export with GKE cost allocation nor a Kubecost/OpenCost endpoint"`. **Never assume an integration is installed, and never ask a customer to install one so that we can audit them** — on a managed cloud the billing data is already ours to read.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # written by the doctor gate this run, or the most recent doctor run
[ -f "$MATRIX" ] || { echo "no doctor matrix found; run the doctor gate before the Kubernetes cost phase"; exit 1; }
# Base reachability (must pass before anything runs) and the two optional cost scopes.
awk -F'\t' '$1 == "kubernetes" && $2 == "reachability"   {print "reachability:", $5, $7}' "$MATRIX"
awk -F'\t' '$1 == "kubernetes" && $2 == "cost-metrics"    {print "metrics:",      $5, $7}' "$MATRIX"
awk -F'\t' '$1 == "kubernetes" && $2 == "cost-integration" {print "kubecost:",     $5, $7}' "$MATRIX"
```

Expected: `reachability: pass -`. A `skipped <reason>` on `metrics` renders the ratio checks as `excluded` with that exact reason and runs only the presence checks. A `skipped <reason>` on `kubecost` excludes only COST-K8S-008. If base `reachability` is `skipped`, the entire Kubernetes provider section reports `excluded` with the doctor's reason and no check runs this cycle.

## 4. Conventions

- `KUBE_CONTEXT` is `kubernetes.context` from `toolkit.yaml`, passed on **every** call. The active/current context is never used for targeting (auditing the wrong cluster is worse than no report).
- Every command is read-only: `kubectl get`, `kubectl top`, `kubectl describe`, `kubectl version`, `kubectl api-resources`, and read-only HTTP `GET`s to a cost endpoint. No mutating verb appears anywhere (forbidden list, section 13).
- `-o json | jq` is the parsing path. A `Forbidden` from the API server on a specific `get`/`list` means the audit credential lacks that `view` grant → record `blocked` for the check naming the exact resource, never silently skip it.
- **Every finding names the concrete resource**: `kind/namespace/name`, the container, the PVC/PV name, the node name and instance type, the size/capacity, the request value, the observed usage, the ratio, and the age. Never "the cluster has waste".
- **`kubectl top` is a point-in-time snapshot, not a window.** A single snapshot is a weak signal; a sustained over-provisioning claim needs either Prometheus over a real window (`WINDOW`, e.g. `7d`) or several sampled snapshots. When only metrics-server is available, label the ratio a *snapshot* and say so in the finding — do not present one `kubectl top` reading as sustained.
- Thresholds and namespace classifications below are **examples, tune to your cluster**; named defaults live in section 12. All placeholders are marked with a trailing comment tying them to a `toolkit.yaml` key.

```bash
# --- config placeholders (from toolkit.yaml) — set before running any block ---
KUBE_CONTEXT="my-cluster"                 # kubernetes.context (REQUIRED, explicit target)
PROM_URL="http://localhost:9090"          # kubernetes.prometheus_url (optional; enables windowed ratios)
COST_URL="http://localhost:9090/model"    # kubernetes.cost_integration_url (optional; Kubecost /model or OpenCost /allocation base)
WINDOW="7d"                               # observation window for sustained-usage claims
OVERPROVISION_RATIO="0.30"                # usage/request below this over WINDOW = over-provisioned (example)
IDLE_PVC_USED_RATIO="0.10"                # used/capacity below this = oversized PVC (example)
SYS_NS_REGEX='^(kube-system|kube-node-lease|kube-public|gke-.*|.*-system)$'  # namespaces excluded from findings
```

## 5. Request-vs-actual over-provisioning (COST-K8S-001)

The core Kubernetes cost signal: a container **reserves** far more CPU/memory than it ever **uses**. Requests are what the scheduler bin-packs against, so an over-request directly inflates the node count and the cloud bill, whether or not the pod is busy.

**Prometheus path (preferred — a real window).** Per-container p95 CPU usage over `WINDOW` divided by its request:

```bash
set -eu
PROM_URL="http://localhost:9090"   # kubernetes metrics source (Prometheus); or use kubectl top
WINDOW="7d"                        # analysis window; tune to your workloads
OVERPROVISION_RATIO="0.3"          # flag when usage < this fraction of requests over WINDOW; tune
# CPU: p95 usage over WINDOW vs request, per pod/container. Ratio well below 1.0 = over-provisioned.
curl -sG "$PROM_URL/api/v1/query" \
  --data-urlencode "query=
    quantile_over_time(0.95,
      rate(container_cpu_usage_seconds_total{container!=\"\",container!=\"POD\",namespace!=\"\"}[5m])[${WINDOW}:5m]
    )
    / on(namespace,pod,container) group_left
    kube_pod_container_resource_requests{resource=\"cpu\"}" \
  | jq -r '.data.result[] | select((.value[1]|tonumber) < '"$OVERPROVISION_RATIO"')
           | "\(.metric.namespace)/\(.metric.pod)/\(.metric.container)\tcpu_usage/request=\(.value[1]|tonumber|.*1000|round/1000)"'

# Memory: max working-set over WINDOW vs request (memory is not compressible — use max, not p95).
curl -sG "$PROM_URL/api/v1/query" \
  --data-urlencode "query=
    max_over_time(container_memory_working_set_bytes{container!=\"\",container!=\"POD\",namespace!=\"\"}[${WINDOW}])
    / on(namespace,pod,container) group_left
    kube_pod_container_resource_requests{resource=\"memory\"}" \
  | jq -r '.data.result[] | select((.value[1]|tonumber) < '"$OVERPROVISION_RATIO"')
           | "\(.metric.namespace)/\(.metric.pod)/\(.metric.container)\tmem_max/request=\(.value[1]|tonumber|.*1000|round/1000)"'
```

**Cloud Monitoring path (GKE — a real window, with nothing to install).** When no
`kubernetes.prometheus_url` is set and the cluster is GKE, do **not** fall through to the
snapshot: `kubernetes.io/container/*` utilisation is already in Cloud Monitoring, retained for
roughly six weeks, readable with the `roles/monitoring.viewer` this audit already requires. Same
identity preamble and the same `timeSeries` GET shape as
`audit-gcp/references/gcp-checks.md` — keep them in step.

```bash
set -eu
# Resolve the CURRENT gcp target through the shared enumerator — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list. A list with no target selected STOPS: these
# utilisation windows anchor per-namespace cost, so the wrong project would misattribute spend.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG lists several projects, and cloud spend is per project, so this lane will not choose one for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "the selected gcp target names no project in $CFG; run /scoutflo:connect"; exit 1; }
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
# Portable 7-day window: BSD date first, GNU fallback; both labeled.
START="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# CPU: hourly MEAN from the API, then the p95 ACROSS those hourly points computed here.
# Why not ALIGN_PERCENTILE_95: live-caught HTTP 400 —
#   "The aligner cannot be applied to metrics with kind GAUGE and value type DOUBLE."
# Percentile aligners only accept DISTRIBUTION metrics, and request_utilization is a double
# gauge. So align hourly and take the percentile client-side; `hours` is reported alongside so
# a short or gappy series is visible rather than silently averaged away.
curl -fsSG --max-time 90 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/timeSeries" \
  --data-urlencode 'filter=metric.type = "kubernetes.io/container/cpu/request_utilization"' \
  --data-urlencode "interval.startTime=${START}" --data-urlencode "interval.endTime=${END}" \
  --data-urlencode 'aggregation.alignmentPeriod=3600s' \
  --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MEAN' \
  | jq -r '.timeSeries[]?
      | ([.points[].value.doubleValue] | sort) as $p | ($p | length) as $n
      | select($n > 0)
      | "\(.resource.labels.cluster_name)/\(.resource.labels.namespace_name)/\(.resource.labels.pod_name)/\(.resource.labels.container_name)\tcpu_p95_of_request=\(($p[(((($n-1)*95)/100) | floor)] * 1000 | round / 1000))\thours=\($n)"'
# Memory: MAX of request_utilization (memory is not compressible — peak, never p95).
curl -fsSG --max-time 60 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/timeSeries" \
  --data-urlencode 'filter=metric.type = "kubernetes.io/container/memory/request_utilization"' \
  --data-urlencode "interval.startTime=${START}" --data-urlencode "interval.endTime=${END}" \
  --data-urlencode 'aggregation.alignmentPeriod=3600s' \
  --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MAX' \
  | jq -r '.timeSeries[]? | "\(.resource.labels.cluster_name)/\(.resource.labels.namespace_name)/\(.resource.labels.pod_name)/\(.resource.labels.container_name)\tmem_max_of_request=\([.points[].value.doubleValue] | max)"'
```

Expected: a ratio per container already expressed as a fraction of its request, so a value of
`0.075` is the same 13.3x over-provisioning the Prometheus query reports. Basis is
`p95 of hourly means over 7d (Cloud Monitoring)` for CPU and `max over 7d (Cloud Monitoring)`
for memory — record that basis verbatim in the finding, and say "of hourly means" rather than a
bare "p95": the API aligns to the hour before this percentile is taken, so it is a percentile over
168 hourly values, not over raw samples. **Check `hours` before trusting a ratio**: a series
covering 6 hours of a 7-day window is a partial reading and belongs in the snapshot lane, not the
windowed one. An **empty** result is not "no over-provisioning":
GKE system metrics can be switched off per cluster to save cost (`enableComponents` in
`audit-gcp`'s `gke-clusters.json`), so an empty series means this cluster has no monitoring
data — say so and fall through to the snapshot path, labelled.

**metrics-server path (last fallback — a snapshot).** When neither a Prometheus URL nor Cloud
Monitoring data is available, read the current usage from `kubectl top` and the requests from
the pod spec, then compute the ratio yourself. Label it a snapshot:

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
# Current per-container usage (instantaneous). Header dropped; columns: NAMESPACE POD NAME CPU(cores) MEM(bytes).
kubectl --context "$KUBE_CONTEXT" top pod -A --containers --no-headers
# Per-container requests to compare against.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json \
  | jq -r '.items[] | . as $p | $p.spec.containers[]
           | "\($p.metadata.namespace)/\($p.metadata.name)/\(.name)\tcpu_req=\(.resources.requests.cpu // "none")\tmem_req=\(.resources.requests.memory // "none")"'
```

Expected: entries where sustained usage is a small fraction of the request. **Report the ratio per container** (e.g. `usage/request = 0.075`, i.e. 13.3x over-provisioned), naming `kind/namespace/name`, the container, the request value, and the observed usage. No dollar. For memory specifically, flag only when `max` (not p95) over the window is well under request — trimming a memory request to below peak causes OOMKills, so the finding is "requested >> peak", never "requested >> average". A workload whose request already matches usage is healthy; do not flag it.

## 6. Workloads with no resource requests (COST-K8S-002)

A container with **no** CPU/memory request is scheduled as BestEffort/Burstable with a zero floor: the scheduler cannot bin-pack it, so it lands unpredictably and forces conservative over-provisioning of the whole node pool, and it is first to be evicted under pressure. This is a cost-*predictability* finding as much as a waste finding.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
SYS_NS_REGEX="^(kube-system|kube-node-lease|kube-public|gke-|gmp-|gke-managed-)"  # system namespaces excluded from findings
kubectl --context "$KUBE_CONTEXT" get deploy,sts,ds,cronjob -A -o json \
  | jq -r '.items[]
      | . as $w
      | ($w.spec.template.spec.containers // $w.spec.jobTemplate.spec.template.spec.containers // [])[]?
      | select(.resources.requests.cpu == null or .resources.requests.memory == null)
      | "\($w.kind)/\($w.metadata.namespace)/\($w.metadata.name)\tcontainer=\(.name)\tcpu_req=\(.resources.requests.cpu // "NONE")\tmem_req=\(.resources.requests.memory // "NONE")"' \
  | grep -Ev "$SYS_NS_REGEX" || true
```

Expected: an empty result is healthy. Any line names a workload, container, and which request is missing (`NONE`). Report each as a presence fact, no dollar. Exclude system namespaces via `SYS_NS_REGEX`. A workload missing only limits (requests present) is out of scope for cost — that is a reliability concern handled by `audit-kubernetes` K8S-004, not here.

## 7. Oversized and idle PVCs (COST-K8S-003)

Two distinct signals on the same object, both billable disk:

**7a. Idle PVCs — bound but mounted by no running pod (presence fact, `get` only):**

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
# All PVCs with capacity and phase.
kubectl --context "$KUBE_CONTEXT" get pvc -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\tphase=\(.status.phase)\tcap=\(.status.capacity.storage // .spec.resources.requests.storage)\tsc=\(.spec.storageClassName // "default")"' \
  | sort > /tmp/all-pvcs.tsv
# PVCs actually referenced by a pod volume.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json \
  | jq -r '.items[] | .metadata.namespace as $ns | .spec.volumes[]? | select(.persistentVolumeClaim) | "\($ns)/\(.persistentVolumeClaim.claimName)"' \
  | sort -u > /tmp/mounted-pvcs.tsv
# The difference: bound PVCs no running pod mounts (candidate idle disk).
awk -F'\t' 'NR==FNR{m[$1]=1; next} !($1 in m)' /tmp/mounted-pvcs.tsv /tmp/all-pvcs.tsv
```

**7b. Oversized PVCs — allocated capacity far above used (ratio fact, needs Prometheus kubelet volume stats):**

```bash
set -eu
PROM_URL="http://localhost:9090"   # kubernetes metrics source (Prometheus); or use kubectl top
WINDOW="7d"                        # analysis window; tune to your workloads
IDLE_PVC_USED_RATIO="0.1"          # flag a PVC when used < this fraction of capacity; tune
curl -sG "$PROM_URL/api/v1/query" \
  --data-urlencode "query=
    max_over_time(kubelet_volume_stats_used_bytes[${WINDOW}])
    / on(namespace,persistentvolumeclaim) group_left
    kubelet_volume_stats_capacity_bytes" \
  | jq -r '.data.result[] | select((.value[1]|tonumber) < '"$IDLE_PVC_USED_RATIO"')
           | "\(.metric.namespace)/\(.metric.persistentvolumeclaim)\tused/capacity=\(.value[1]|tonumber|.*1000|round/1000)"'
```

Expected (7a): PVCs whose claim never appears in a pod volume — name each with capacity, storageClass, and phase. A `StatefulSet` PVC intentionally retained between rollouts is *not* automatically idle; cross-check whether a matching StatefulSet exists before flagging. Expected (7b): PVCs whose peak used bytes are a small fraction of capacity — report the `used/capacity` ratio, the PVC name, and its capacity. No dollar in either case: the PVC's cost lives in the cloud disk it binds, which Kubernetes does not price.

## 8. Replica count / HPA floor above observed load (COST-K8S-004)

A statically over-scaled Deployment, or an HPA whose `minReplicas` never lets it scale down, keeps idle replicas running. Each replica multiplies the workload's request footprint against the node pool.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
SYS_NS_REGEX="^(kube-system|kube-node-lease|kube-public|gke-|gmp-|gke-managed-)"  # system namespaces excluded from findings
# Static replica counts.
kubectl --context "$KUBE_CONTEXT" get deploy -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\treplicas=\(.spec.replicas // 1)\tready=\(.status.readyReplicas // 0)"' \
  | grep -Ev "$SYS_NS_REGEX" || true
# HPAs: is the controller pinned at its floor the whole time?
kubectl --context "$KUBE_CONTEXT" get hpa -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)\tmin=\(.spec.minReplicas // 1)\tmax=\(.spec.maxReplicas)\tcurrent=\(.status.currentReplicas)\tdesired=\(.status.desiredReplicas)"'
```

Confirm sustained low load before flagging (Prometheus — is aggregate usage a small fraction of the fleet's total request over `WINDOW`?):

```bash
set -eu
PROM_URL="http://localhost:9090"   # kubernetes metrics source (Prometheus); or use kubectl top
WINDOW="7d"                        # analysis window; tune to your workloads
# Per-workload: aggregate CPU usage vs (replicas x per-pod request), over WINDOW, expressed as a fraction.
curl -sG "$PROM_URL/api/v1/query" \
  --data-urlencode "query=
    sum by (namespace) (quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{container!=\"\",container!=\"POD\"}[5m])[${WINDOW}:5m]))
    / on(namespace) group_left
    sum by (namespace) (kube_pod_container_resource_requests{resource=\"cpu\"})" \
  | jq -r '.data.result[] | "\(.metric.namespace)\tfleet_usage/request=\(.value[1]|tonumber|.*1000|round/1000)"'
```

Expected: a Deployment with `replicas=10, ready=10` whose fleet p95 usage is a small fraction of its total request, or an HPA where `min == current == desired` for the whole window with per-pod utilization far below the HPA target — the floor is set too high. **Report the replica count, the observed fleet-usage-to-request ratio, and (for HPAs) that `desired` has been pinned at `min`.** No dollar. A deliberately over-provisioned floor for burst headroom or quorum (e.g. a 3-node etcd/Zookeeper) is *not* a finding — note the intent when the workload is clearly stateful/quorum-bound.

## 9. Orphaned PersistentVolumes (COST-K8S-005)

A PV in `Released` (its PVC was deleted but the PV's reclaim policy is `Retain`) or `Available` (provisioned, never bound) keeps its **backing cloud disk allocated and billing**, invisibly, because no PVC references it. This is the storage equivalent of an unattached EBS volume.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
kubectl --context "$KUBE_CONTEXT" get pv -o json \
  | jq -r '.items[]
      | select(.status.phase=="Released" or .status.phase=="Available")
      | "\(.metadata.name)\tphase=\(.status.phase)\tcap=\(.spec.capacity.storage)\treclaim=\(.spec.persistentVolumeReclaimPolicy)\tsc=\(.spec.storageClassName // "")\tdisk=\((.spec.csi.volumeHandle // .spec.awsElasticBlockStore.volumeID // .spec.gcePersistentDisk.pdName // "n/a"))\tcreated=\(.metadata.creationTimestamp)"'
```

Expected: an empty result is healthy. Each line names the PV, its phase, capacity, reclaim policy, the **backing disk handle** (so the reader can find the actual cloud disk), storageClass, and age. `Released` + `Retain` is the clearest waste — the disk survives on purpose and nothing will ever reclaim it automatically. Report each as a presence fact, no dollar; the dollar lives on the cloud disk (cross-reference the AWS/GCP catalogs' unattached-disk checks via correlation.json rather than pricing it here).

## 10. Uncleaned completed / failed Jobs (COST-K8S-006)

Finished Jobs and their Pods that have no `ttlSecondsAfterFinished` linger indefinitely, holding etcd objects, node scheduling records, and — for failed pods that still reference volumes — occasionally pinning PVCs. This is primarily a control-plane hygiene and predictability finding; it becomes a cloud-cost finding only when the leftover pods pin a PVC or block scale-down (cross-reference, do not assume).

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
# Finished Jobs with no TTL to auto-clean them.
kubectl --context "$KUBE_CONTEXT" get jobs -A -o json \
  | jq -r '.items[]
      | select(((.status.succeeded // 0) >= 1) or ((.status.failed // 0) >= 1))
      | select(.spec.ttlSecondsAfterFinished == null)
      | "\(.metadata.namespace)/\(.metadata.name)\tsucceeded=\(.status.succeeded // 0)\tfailed=\(.status.failed // 0)\tcompleted=\(.status.completionTime // "n/a")\tttl=none"'
# Leftover terminal pods still occupying etcd/scheduler records.
echo "Succeeded pods: $(kubectl --context "$KUBE_CONTEXT" get pods -A --field-selector=status.phase=Succeeded -o json | jq '.items | length')"
echo "Failed pods:    $(kubectl --context "$KUBE_CONTEXT" get pods -A --field-selector=status.phase=Failed    -o json | jq '.items | length')"
```

Expected: an empty Job list and low terminal-pod counts are healthy. Report each finished Job with no TTL (name, succeeded/failed counts, completion time) and the terminal-pod totals as a presence fact, no dollar. A CronJob's `successfulJobsHistoryLimit`/`failedJobsHistoryLimit` intentionally keeps a small number of recent Jobs — do not flag those retained within the configured limit; flag only accumulation beyond the limit or Jobs from CronJobs with no history limit set.

## 11. Under-packed nodes / node-pool headroom (COST-K8S-007)

Where the actual cloud dollars are: nodes whose summed pod **requests** (and observed usage) sit far below their allocatable capacity across the pool mean the same workloads could bin-pack onto fewer, and the surplus nodes could be removed. Report the **headroom ratio and the surplus node count with instance types** — never a node price times a count.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
PROM_URL="http://localhost:9090"   # kubernetes metrics source (Prometheus); or use kubectl top
# Per-node allocatable and instance type.
kubectl --context "$KUBE_CONTEXT" get nodes -o json \
  | jq -r '.items[] | "\(.metadata.name)\ttype=\(.metadata.labels["node.kubernetes.io/instance-type"] // .metadata.labels["beta.kubernetes.io/instance-type"] // "unknown")\tcpu_alloc=\(.status.allocatable.cpu)\tmem_alloc=\(.status.allocatable.memory)"'
# Actual per-node usage (metrics-server snapshot).
kubectl --context "$KUBE_CONTEXT" top nodes --no-headers 2>/dev/null || echo "kubectl top nodes unavailable — metrics-server not installed; COST-K8S-007 uses the reservation ratio below only"
# Cluster-wide reservation ratio over WINDOW (Prometheus): total pod CPU requests / total allocatable CPU.
curl -sG "$PROM_URL/api/v1/query" \
  --data-urlencode "query=
    sum(kube_pod_container_resource_requests{resource=\"cpu\", node!=\"\"})
    / sum(kube_node_status_allocatable{resource=\"cpu\"})" \
  | jq -r '.data.result[] | "cluster cpu requests/allocatable = \(.value[1]|tonumber|.*1000|round/1000)"'
# node!="" is load-bearing: kube_pod_container_resource_requests includes PENDING/unschedulable
# pods (node="") whose requests are not actually reserved on any node. Counting them (confirmed
# live: 64 cores of pending requests made the ratio 6.08 > 1) inverts the surplus-node formula
# below to a negative node count. Only scheduled-pod requests reserve real capacity.
```

Expected: a reservation ratio near 1.0 means the pool is well-packed. A low ratio (much of the allocatable CPU/memory is neither requested nor used across the pool) is the finding — report the ratio, the total node count, and how many nodes' worth of allocatable capacity is idle (`(1 - ratio) x node_count`, as a **node count**, not dollars), listing the candidate under-utilized nodes by name and instance type. **On GKE the dollar is legitimately available and must be used:** these nodes are Compute Engine VMs, so their real billed cost is already in the Cloud Billing export. Join the surplus-node count and each node's `instance-type` from this section to the per-cluster net spend from COST-GCP-024, and cite that export as the `savings_source` — it is a verbatim provider figure, not a derived one. Report it under COST-K8S-008; this check stays a node-count ratio. Off a managed cloud (or with no export configured) there is **no dollar**: the node price belongs to the provider's catalog, reached through correlation.json, and is never invented here by multiplying a rate by a quantity. Respect anti-affinity, DaemonSet, and taint constraints before claiming a node is removable — a node kept for a GPU/spot/zonal constraint is not surplus.

## 12. Cluster-cost integration — Kubecost / OpenCost (COST-K8S-008)

The **only** native-dollar check, and only when `kubernetes.cost_integration_url` is configured. Never assume the integration exists — a missing endpoint excludes this check (section 3), it does not fabricate one.

**Kubecost** exposes actual allocated cost *and* a right-sizing recommendation with a savings figure:

```bash
set -eu
COST_URL="${KUBECOST_URL:-http://localhost:9090/model}"   # kubernetes.cost_integration_url; never assume it exists (section 3)
WINDOW="7d"                                                # analysis window; tune to your workloads
# Actual allocated spend per namespace over WINDOW (verbatim native $ — context, not a saving).
curl -sG "$COST_URL/allocation" \
  --data-urlencode "window=$WINDOW" --data-urlencode "aggregate=namespace" \
  | jq -r '.data[0] | to_entries[] | "\(.key)\ttotalCost=\(.value.totalCost)\tcpuEfficiency=\(.value.cpuEfficiency)"'
# Request right-sizing recommendation WITH Kubecost's own projected saving — copy the savings field verbatim.
curl -sG "$COST_URL/savings/requestSizingV2" \
  --data-urlencode "window=$WINDOW" --data-urlencode "algorithmCPU=max" \
  | jq -r '.Recommendations[]? | "\(.namespace)/\(.controllerKind)/\(.controllerName)\tmonthlySavings=\(.monthlySavings)"'
```

**OpenCost** exposes allocation/efficiency but **no** savings recommendation — its `totalCost` is verbatim actual spend, usable as context, and efficiency is a ratio:

```bash
set -eu
COST_URL="${OPENCOST_URL:-http://localhost:9003}"   # kubernetes.cost_integration_url; never assume it exists (section 3)
WINDOW="7d"                                          # analysis window; tune to your workloads
# OpenCost allocation API (default port 9003). totalCost is verbatim actual spend; cpuEfficiency is a ratio.
curl -sG "$COST_URL/allocation/compute" \
  --data-urlencode "window=$WINDOW" --data-urlencode "aggregate=namespace" \
  | jq -r '.data[0] | to_entries[] | "\(.key)\ttotalCost=\(.value.totalCost)\tcpuEfficiency=\(.value.cpuCoreUsageAverage)/\(.value.cpuCoreRequestAverage)"'
```

Expected and the money rule: from **Kubecost**, `estimated_monthly_savings_usd` is copied **verbatim** from the savings API's per-workload `monthlySavings` field (its exact name varies by Kubecost version — copy it, never rename or recompute it). From **OpenCost**, `totalCost` is verbatim *actual spend* reported as context only; **do not** multiply `totalCost x (1 - efficiency)` to manufacture a "wasted dollars" number — that is exactly the forbidden recompute, and OpenCost publishes no savings figure to copy. When only OpenCost is present, COST-K8S-008 reports the per-namespace actual cost and efficiency ratio as facts, with no `estimated_monthly_savings_usd` field.

- ❌ `COST-K8S-008: OpenCost reports staging namespace totalCost $900/mo at 20% efficiency, so ~$720/mo is wasted.`
- ✅ `COST-K8S-008: OpenCost reports staging namespace totalCost 900.00 (verbatim, actual spend) at cpuEfficiency 0.20 — reported as actual-cost + efficiency-ratio facts, NO estimated_monthly_savings_usd, because OpenCost publishes no savings figure to copy.`
- ✅ `COST-K8S-008: Kubecost right-sizing recommends staging/Deployment/web CPU 250m; estimated_monthly_savings_usd is 63.10, copied verbatim from the savings API monthlySavings field.`

## 12b. Where a cluster's money actually goes (COST-K8S-009)

"This cluster costs X" is a bill. "This namespace is most of X, and it reserves twelve times what
it uses" is a decision. This check is the join that turns one into the other, and it is the single
most useful thing in this file for a large cluster — because without it a team optimises whatever
they happen to remember, not the thing that costs the most.

It needs no third-party tool: the per-namespace spend comes from the cloud's own billing export
(COST-GCP-024 on GCP), and the per-namespace request-vs-usage ratio is already computed in section
5. Join them on namespace.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context — passed on every kubectl call
WINDOW="7d"                        # the ratio window; must match the basis you report
# Per-namespace CPU requested, from the cluster itself. Pair each line with that namespace's
# net spend from COST-GCP-024 (same cluster label, same month) before ranking.
kubectl --context "$KUBE_CONTEXT" get pods -A -o json \
  | jq -r '[.items[] | select(.status.phase=="Running" or .status.phase=="Pending")
            | {ns: .metadata.namespace,
               cpu: ([.spec.containers[].resources.requests.cpu // "0"] | map(
                      if test("m$") then (sub("m$";"") | tonumber / 1000) else tonumber end) | add)}]
           | group_by(.ns) | map({namespace: .[0].ns, requested_cores: (map(.cpu) | add | . * 1000 | round / 1000)})
           | sort_by(-.requested_cores)[] | "\(.namespace)\trequested_cores=\(.requested_cores)"'
```

Expected: namespaces ranked by reserved CPU, each joined to its billed spend and its observed
usage ratio from section 5. Report the top namespaces by **spend**, not by request — the two differ
whenever one namespace runs expensive machine types — and give each the same `basis` you used for
the ratio. The dollar on the line is **actual spend**, so label it as such: the saving is what
right-sizing would recover, which stays indicative or unpriced. Where the export has no
cost-allocation labels, say the namespace split is unavailable and report cluster-level spend with
the per-namespace *requests* only, clearly marked as a reservation share rather than a cost share.
A namespace that is a large share of reserved capacity but a small share of usage is the finding;
a namespace that is large because it genuinely runs the product is not.

## 12c. Node-pool economics (COST-K8S-010)

Right-sizing requests changes how much capacity you need; this check changes what that capacity
costs. The three levers are visible from node labels alone, and all three are decisions the
customer must make — so report the trade-off, never just the cheaper option.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context
# Capacity type, machine family and zone per node, grouped into pools.
kubectl --context "$KUBE_CONTEXT" get nodes -o json \
  | jq -r '[.items[] | {
      pool: (.metadata.labels["cloud.google.com/gke-nodepool"] // .metadata.labels["eks.amazonaws.com/nodegroup"] // "unknown"),
      type: (.metadata.labels["node.kubernetes.io/instance-type"] // .metadata.labels["beta.kubernetes.io/instance-type"] // "unknown"),
      zone: (.metadata.labels["topology.kubernetes.io/zone"] // "unknown"),
      spot: ((.metadata.labels["cloud.google.com/gke-spot"] // .metadata.labels["cloud.google.com/gke-preemptible"] // .metadata.labels["karpenter.sh/capacity-type"] // "on-demand") | tostring)
    }]
    | group_by(.pool) | map({pool: .[0].pool, nodes: length,
        types: (map(.type) | unique | join(",")), zones: (map(.zone) | unique | length),
        spot: (map(.spot) | unique | join(","))})[]
    | "\(.pool)\tnodes=\(.nodes)\ttypes=\(.types)\tzones=\(.zones)\tcapacity=\(.spot)"'
```

Expected: one line per node pool. Three findings, each paired with that pool's billed spend:

**Capacity type.** A pool running only on-demand nodes whose workloads are stateless, replicated
and interruption-tolerant is a spot/preemptible candidate — the published on-demand-minus-spot rate
delta is an exact indicative figure. But say the cost plainly: spot nodes are reclaimed with little
warning, so this is unsafe for stateful sets, single-replica services, long media sessions that
cannot migrate, or anything without a disruption budget. Recommend it only where the workload
already tolerates a node drain.

**Machine family.** A pool on an older or general-purpose family where a newer generation offers
the same vCPU and memory at a lower published rate is a priced, low-risk change; name both families
and the published delta. Where the workload is pinned to a family for a real reason — a specific
CPU platform, local SSD, GPU or sustained single-thread performance — record that as the reason and
drop the finding.

**Zone spread.** More zones than the availability target needs adds inter-zone traffic and, for
small pools, a minimum node per zone. This is a **presence fact**: report nodes per zone and the
stated availability requirement, and never recommend collapsing zones without it. For
public-IP-per-node workloads such as media relays, zone spread is usually deliberate.

## 12d. The orphan chain (COST-K8S-011)

A workload that was deleted or scaled to zero does not leave one piece of billing behind — it leaves
a chain. The StatefulSet goes to zero replicas, its PVCs stay Bound, the PVs behind them go Released
with a Retain policy, the cloud disks behind *those* keep billing, and any snapshot schedule keeps
snapshotting them. Reported separately that is four or five modest findings in four different
sections, each easy to defer. Reported as one chain it is a single named dead workload with one
total next to it, and it gets actioned.

This check **invents nothing**: it is a join over findings the other checks already produced, and
it sums only figures that already carry a provider-native or indicative source.

```bash
set -eu
KUBE_CONTEXT="my-cluster"          # kubernetes.context
# The join key is the backing volume handle: a Released PV names both the claim it belonged to
# and the cloud disk still being billed.
kubectl --context "$KUBE_CONTEXT" get pv -o json \
  | jq -r '.items[]
      | select(.status.phase=="Released" or .status.phase=="Available")
      | {pv: .metadata.name,
         phase: .status.phase,
         reclaim: .spec.persistentVolumeReclaimPolicy,
         capacity: .spec.capacity.storage,
         handle: (.spec.csi.volumeHandle // .spec.gcePersistentDisk.pdName // .spec.awsElasticBlockStore.volumeID // "none"),
         was: ((.spec.claimRef.namespace // "?") + "/" + (.spec.claimRef.name // "?"))}
      | "\(.pv)\tphase=\(.phase)\treclaim=\(.reclaim)\tsize=\(.capacity)\twas=\(.was)\thandle=\(.handle)"'
```

Expected: every orphaned PV with the claim it belonged to and the backing volume handle. Build the
chain per dead workload:

1. Take the workload name from the PV's `claimRef` (strip the StatefulSet ordinal), and confirm the
   owner is gone or at zero replicas — a **scaled-to-zero StatefulSet whose PVCs are deliberately
   retained is not an orphan**, it is a paused service, and that distinction is the whole check.
2. Attach its PVCs (COST-K8S-003), its PVs (COST-K8S-005), any uncleaned Jobs in the same namespace
   (COST-K8S-006), and — matching on the volume handle — the cloud disk findings
   (COST-GCP-005 priced, COST-GCP-022 presence) and any snapshots of those disks (COST-GCP-020).
3. Sum **only** the figures that already carry a source. Where part of the chain has no figure, say
   so: "three of five links priced" is honest and still persuasive.
4. Mark every contributing finding `deduplicated: true` and name the chain id, so the same disk is
   never counted twice between its own finding and the chain. The correlation engine's overlap rules
   apply here exactly as they do across audits.

Report the chain as: the dead workload, how long it has been dead (oldest link's age), the resource
types it still bills across, the summed sourced figure, and the **deletion order** — snapshot first
if the data might be wanted, then the PV object, then the backing disk, then the PVC. Getting that
order wrong is how a Retain-policy volume becomes unrecoverable, so the order is part of the finding,
not a footnote. A chain whose owner still exists at non-zero replicas is a bug in the join, not a
finding: drop it and say the owner was live.

## 13. Named defaults

| Knob | Default (example) | Why |
| --- | --- | --- |
| Observation window `WINDOW` | `7d` | one full week captures weekday/weekend and nightly-batch cycles; a shorter window over-flags bursty workloads |
| Over-provision ratio `OVERPROVISION_RATIO` | usage/request `< 0.30` sustained | below ~30% of request over a week is a clear reservation the scheduler can never use; tune per SLO headroom |
| Idle-PVC used ratio `IDLE_PVC_USED_RATIO` | used/capacity `< 0.10` | a disk under 10% full over the window is materially oversized |
| Memory over-provision basis | **max**, not p95/avg | memory is non-compressible; trimming below peak causes OOMKills, so flag only requested >> peak |
| System namespaces `SYS_NS_REGEX` | `kube-system`, `kube-node-lease`, `kube-public`, `gke-*`, `*-system` | scopes findings to workloads you own, not platform components |
| Metrics source preference | Prometheus window > `kubectl top` snapshot | a snapshot cannot prove sustained over-provisioning; state which was used in every ratio finding |

## 14. Rendering the section

Every finding here uses `area: cost-optimization`, `points_recoverable: 0`, and a plan-only remediation pointer (v1 never resizes a request, deletes a PV/PVC/Job, drains a node, or edits an HPA from a recommendation — those are setup-lane, confirm-then-verify actions).

**Open the section with the savings-summary line**, per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule. Because Kubernetes core exposes no dollars, the summary is built **only** from COST-K8S-008 Kubecost `monthlySavings` figures when that integration is present, and otherwise states plainly that there is no provider-sourced dollar figure:

> **Potential savings: ~$<sum>/month (~$<sum×12>/year)** across **<n>** opportunities with a Kubecost-sourced figure; **<m> more** found with no dollar figure (over-provisioning ratio / presence facts, listed below). Largest single lever: **$<max>/mo** — right-size `<workload>` (Kubecost recommendation).

If **no** row carries a Kubecost figure (the common case — Kubecost/OpenCost not installed), write instead:

> **<m> resource-efficiency opportunities found; no provider-sourced dollar figures available** — Kubernetes exposes no native cost API, so each is an over-provisioning ratio or presence fact to review. Largest lever by ratio: **`<workload>` at <ratio> usage/request (<Nx> over-provisioned)**.

Never print `$0`, and never sum a ratio into a dollar. Then render the per-row table, columns `Finding | Resource | Signal source | Current → observed | Est. monthly savings (Kubecost-sourced) | Action`. `Current → observed` shows the reservation-vs-reality shape (e.g. `req 2000m → p95 150m`, `cap 100Gi → used 4Gi`, `replicas 10 → fleet usage 8%`, `PV Released, disk retained`); the savings column prints `-` for every non-COST-K8S-008 row so it reads as "checked, no native number available" rather than blank. Every ratio carries its basis (`p95 over 7d`, `snapshot`), so a reader can tell a windowed claim from a single reading.

## 15. Forbidden commands (read-only guarantee)

Never run any of these against the target cluster — they mutate state, and this audit only ever reads:

`kubectl apply`, `create`, `edit`, `patch`, `replace`, `delete`, `label`, `annotate`, `scale`, `autoscale`, `rollout`, `set` (`set resources`, `set image`, ...), `cordon`, `drain`, `uncordon`, `taint`, `exec`, `cp`, `attach`, `debug`, `port-forward` (as a mutation path), and `auth reconcile`. Specifically for this cost catalog: **never delete the orphaned PVs (COST-K8S-005), never delete the finished Jobs/Pods (COST-K8S-006), never scale a Deployment or edit an HPA (COST-K8S-004), never resize a PVC or a container request** — every one of those is a finding to *report*, and remediation is a confirm-then-verify setup-lane action, never taken by the audit. HTTP calls to a Kubecost/OpenCost endpoint are read-only `GET`s only; never `POST`/`PUT`/`DELETE` to a cost-integration API. This audit uses only `kubectl get`/`top`/`describe`/`version`/`api-resources` and read-only `GET`s.
