# RCA neighbor signals — what to pull in the fire window vs baseline

Phase 4.5 of [rca](../SKILL.md#phase-45-temporal-delta-on-the-telemetry-backends-what-moved-and-before-what) compares a fire window to a baseline window for the target and each ranked upstream suspect. This table lists, per resource scope, the neighbor signals worth pulling and *why each matters*. Pull the row matching the alert/target's most specific scope; cap at ~6 signals per suspect to stay bounded. Every signal is read read-only from whichever backend the topology observation edge (`SENDS_METRICS_TO` / `MONITORED_BY`) names for that service — reuse that provider's existing `audit-*` read path; do not invent a query engine. A signal whose backend is unreachable is an honest gap, never "flat".

Baseline = same hour, previous day (fire_start − 24h, same duration); 7-day same-time-of-day median fallback when the prior-day window is contaminated (overlaps another fire of the same signal, or a deploy within 24h). `delta_pct = (fire − baseline)/max(baseline, epsilon)×100`; rank by absolute delta. A signal that moves *with* the symptom but with no temporal ordering is a **co-occurring signal**, not a cause.

## Service scope (the target is a service / `service.name`)

| Signal | Why it matters |
|---|---|
| Error rate (errored requests ÷ total) | A sympathetic move usually points at an upstream/downstream cascade — the strongest service-level cause signal. |
| p95 latency | Latency rising *with* errors → resource saturation or downstream slowness; latency *without* errors → queue/buffer fill. |
| p99 latency | Catches tail-only regressions invisible to p95. |
| Request throughput (rate) | A drop means an upstream stopped sending; a spike means a retry storm or load shift. |
| Dependency error rate (outbound calls, grouped by dependency) | Surfaces *which* downstream the service is failing on — turns "service is unhealthy" into "service is timing out on payments". |
| Container CPU / memory (if the backend has it) | Saturation explains a latency/error correlation; flat CPU + errors implies a non-resource cause. |

## Host / VM scope (`host.name`)

| Signal | Why it matters |
|---|---|
| CPU utilization | Often the alert metric itself; pull anyway to relate peak to threshold. |
| Memory pressure / swap | OOM and swap activity. |
| Disk I/O wait | Disk saturation frequently masquerades as CPU pressure. |
| Network I/O | Saturation or NIC errors. |
| Load average (1m) | Catches contention not visible in raw CPU%. |
| Service signals filtered to this host | Identifies which workload drove the host pressure. |

## Kubernetes scope (pod / namespace / workload)

| Signal | Why it matters |
|---|---|
| Pod restart count (fire vs baseline) | Crash loops dominate every other signal — **surface first**. |
| CPU vs requests/limits | Throttling shows up here even when raw CPU% looks healthy. |
| Memory vs limit | OOMKilled is the most common k8s failure. |
| Node pressure conditions | Node-level exhaustion bleeds into every pod scheduled there. |
| Recent rollout (replicas-updated change in window) | A rollout overlapping the fire is the single strongest cause signal. |
| App-layer errors / latency (scoped to the workload) | The application view of the same problem. |

## No resource scope identified (e.g. a global error-log alert)

Pull top services by error rate and by error-log volume, identify the service driving the global signal, then re-run the matching row above against that service. Weaker than a scoped comparison — say so.
