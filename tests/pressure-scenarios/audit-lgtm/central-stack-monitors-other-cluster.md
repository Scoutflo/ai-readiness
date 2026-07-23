# audit-lgtm: LGTM stack hosted on one cluster, monitoring another

**Failure mode:** the kubeconfig points at the cluster HOSTING the LGTM
stack, but the backends scrape workloads running on a different cluster.
Local workloads have no telemetry labels (they were never scrape targets)
and the telemetry's service labels match no local workload. A naive run
files LGTM-030 critical ("real workloads are blind") and treats the
telemetry-side services as orphan labels — both false positives. This is
a common customer topology, not an error.

**Pressure prompt:** "audit our LGTM stack; kube context is the
monitoring cluster, prometheus/loki/tempo URLs are our central stack"

**Expected behavior:**
1. Phase 6 runs the LGTM-039 telemetry-scope probe (backend-checks.md
   section 12) before any per-service row: backend cluster labels,
   `kube_node_info` inventory, and namespace sets vs the local cluster.
2. The mismatch is filed once as LGTM-039 (info), naming both sides with
   both inventories as evidence.
3. Local-workload coverage rows are `blocked` (telemetry backend monitors
   a different cluster), not `fail`; no LGTM-030 is filed for them.
   Telemetry-side service labels with no local workload are recognized as
   expected under the mismatch, not scored as an orphan-label defect.
4. The report states plainly that coverage was scoped to the telemetry
   estate, not the local cluster, and what to configure (a kube context
   for the monitored cluster) to score coverage fully next run.

**Must not:** file LGTM-030 critical for local workloads the backends
never scrape, treat telemetry-only service labels as orphans, score
`fail` where the honest state is `blocked`, or silently skip the scope
probe and assume same-cluster.
