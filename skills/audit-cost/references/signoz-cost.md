# audit-cost (SigNoz): Deep Per-Signal Cost Check Catalog

Runnable, read-only checks for the SigNoz provider phase of [audit-cost](../SKILL.md). This is the deep, per-signal/per-metric cost audit — it queries SigNoz's **own ingestion Cost Meter and metrics store live** (which signal, which metric, which environment is driving spend), not a re-aggregation of the reliability audit. It complements the cardinality *health* check `SIG-070` in [audit-signoz](../../audit-signoz/references/signoz-checks.md#6c-metric-cardinality-health-sig-070) by turning the same reads into a ranked cost view. Every finding carries `area: cost-optimization` and `points_recoverable: 0`; nothing here enters a 0–100 score. Money is **ranked**, never scored (the standard's perverse-incentive rule).

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding only when the number is copied **verbatim** from a provider-native recommendation API. **SigNoz has no savings-recommendation API** — its Cost Meter (`signoz.meter.*` metrics, `source: "meter"`) and metrics store return what you are *currently ingesting* (bytes for logs/traces, samples for metrics), not what you would *save* by trimming. So for SigNoz:

- No SigNoz finding ever carries `estimated_monthly_savings_usd`. The savings from merging high-cardinality series, trimming histogram buckets, or capping a non-prod environment is **not** a number SigNoz computes; recomputing it from an ingest volume against a price list is exactly the fabrication this rule forbids.
- SigNoz does **not** publish a per-signal dollar cost either (billing is plan/tier dependent and, for self-hosted, is your own infra). So `estimated_monthly_cost_usd` is also `null` here. What is real and reportable is the **ingest volume** (the billable dimension: GB for logs/traces, samples for metrics) as a **presence fact**, plus which signal/metric/env drives it.
- Orientation only, never emitted as a finding number: SigNoz Cloud lists traces/logs at roughly **$0.30/GB** and metrics at roughly **$0.10 per million samples**. Use these solely to decide *which signal to name as the driver* (weight the volumes); never multiply them into a savings or cost figure on a finding.

### Wrong vs right

- ❌ `COST-SIG-001: logs ingest 812 GB/7d ⇒ ~$243/mo, save ~$120/mo by dropping debug logs.` (fabricated dollars + fabricated savings)
- ✅ `COST-SIG-001: logs are the top ingest driver at 812 GB over 7d (Cost Meter signoz.meter.* source=meter, hourly sum, partial buckets excluded); metrics 41M samples, traces 96 GB. Reported as ingest volume (the billable dimension); no SigNoz-native dollar figure, so estimated_monthly_savings_usd and estimated_monthly_cost_usd are null.`

## 2. Check catalog

| ID | Driver | What it names | Native $? |
| --- | --- | --- | --- |
| COST-SIG-001 | Per-signal ingest volume | The signal (logs / traces / metrics) driving ingest, by billable dimension over a trailing 7d window | no (volume presence fact) |
| COST-SIG-002 | Top metrics by samples | The individual metrics burning the most samples; histogram `*.bucket` families called out (one sample per boundary per scrape) | no (sample count) |
| COST-SIG-003 | Non-prod ingest share | A non-production environment (`staging`/`dev`/`test`/`qa`/`sandbox`/`preview`/`uat`) exceeding a share threshold of total ingest — cap it before touching prod signals | no (share %) |
| COST-SIG-004 | High-cardinality label contributors | Labels inflating series count (cross-reference to `SIG-070`); the fix that cuts cost is `metricstransform aggregate_labels` (merge series), never `delete_key` | no (series count) |

## 3. Doctor-gate dependency

The SigNoz cost phase runs only when the `signoz` block is configured and reachable per [audit-signoz's doctor gate](../../audit-signoz/references/signoz-checks.md#1-conventions) (host/org/token, or the ClickHouse read user). If the Cost Meter is not queryable (older self-hosted builds may not expose `signoz.meter.*`), COST-SIG-001/003 are recorded `excluded` with that reason and the run falls back to the metrics-store reads (COST-SIG-002/004) — never a `$0`/`0 GB` line, which would falsely read as "nothing to trim". A 401/403 on the query API excludes the whole SigNoz cost phase with the status as evidence.

## 4. Conventions (all sections)

- Every command is a read: `POST /api/v3/query_range` (the documented read-by-POST query envelope), `GET /api/v1/*`, or a `SELECT` against the ClickHouse metrics store. The forbidden list in §7 names what is never run.
- All findings: `area: cost-optimization`, `scoring_scope: "non-scored"`, `points_recoverable: 0`, `estimated_monthly_savings_usd: null`, `estimated_monthly_cost_usd: null`.
- Volume is the evidence: quote the raw count and its dimension (GB / samples / series / %), the window, and the exact query. Rank by the billable dimension, orientation-weighted, but emit no derived money.
- **Exclude `partial: true` buckets** from every Cost Meter sum — a partial (still-filling) hourly bucket under-reports and would skew the driver ranking.

## 5. Per-signal ingest driver — the Cost Meter (COST-SIG-001, COST-SIG-003)

The Cost Meter is the source of truth for what is actually being ingested. Query it via the builder-query envelope with `source: "meter"` (NOT the regular metrics query path) over a rolling 7-day window, hourly buckets summed.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml (signoz.host/org, token via signoz.token_env).
API="https://${SIGNOZ_HOST}/api/0"   # example; the audit resolves the real host/path live
# COST-SIG-001: per-signal ingest over 7d from the Cost Meter. signoz.meter.* metrics carry the
# billable dimension (bytes for logs/traces, samples for metrics). Sum COMPLETE hourly buckets only.
# Shape is illustrative — discover the exact meter metric names live via the metrics list; never
# hardcode-assert a meter metric name that this build may not expose.
#   builder query: aggregation timeAggregation=sum, stepInterval=3600, source=meter,
#   group by signal/data_type, order __result desc, exclude buckets flagged partial:true
```

Report the signal with the largest orientation-weighted volume as the driver (COST-SIG-001), quoting all three signals' raw volumes. For COST-SIG-003, group the same meter read by the environment resource attribute; if a non-prod environment (name in `staging|dev|test|qa|sandbox|preview|uat`) exceeds **40%** of total ingest, name it — the cheapest lever is an ingestion limit on that environment key, applied *before* any signal-level or cardinality change to prod.

## 6. Top metrics by samples + cardinality contributors (COST-SIG-002, COST-SIG-004)

Samples are the billable unit for metrics, so the ranking IS the cost driver — but it is a COUNT, never a dollar.

```bash
# COST-SIG-002: top metrics by ingested samples over the window (from the metrics store /
# the meter, whichever this build exposes). Histograms (a *.bucket / *_bucket family) are usually
# the top contributors: each histogram bucket boundary is a separate sample per scrape. Call the
# histogram family out explicitly — trimming bucket boundaries cuts cost with little P99 impact.
# COST-SIG-004: for the top contributors, read distinct label-value counts (the same read SIG-070
# does) and name the label inflating the series. The fix that actually cuts cost is the
# metricstransform processor `aggregate_labels` (MERGE series — samples are billable), NEVER a
# `transform`/`delete_key` (which leaves the same sample count and creates colliding series).
```

**Do-not-drop guard (shared with SIG-070, load-bearing here).** A metric being a top sample contributor does **not** make it droppable. The following families power SigNoz's own product pages and must be reported as *dependencies*, never as "safe to trim", even though they may carry no user dashboard/alert:
- **Hosts view:** `system.cpu.*` (incl. `system.cpu.load_average.*`), `system.memory.*`, `system.disk.*`, `system.network.*`, `system.filesystem.*`, `system.paging.*`, `system.processes.*`, `host.cpu.usage`.
- **Kubernetes view:** `k8s.*` and `container.*` families (pod/container/node/deployment/replicaset/statefulset/daemonset/job/cronjob/hpa/volume/namespace/cluster), plus the `.uid`+`.name` entity-resolution attributes and `k8s.pod.start_time` (Pod Age).
- **APM / Services page:** the span-derived RED metrics `signoz_calls_total`, `signoz_latency_bucket/count/sum`, `signoz_db_latency_*`, `signoz_external_call_latency_*`. **Never** recommend trace sampling as a cost lever — it makes APM undercount all traffic.

A drop/merge candidate is only ever named when it is neither in the do-not-drop set nor referenced by a dashboard or alert; a metric whose usage cannot be confirmed is reported as "usage unknown — verify manually", never as "unused".

## 7. Forbidden (never run in the cost phase)

No `POST`/`PUT`/`PATCH`/`DELETE` that mutates SigNoz (no rule/dashboard/view/pipeline create or edit), no `ALTER`/`INSERT`/`DROP`/`OPTIMIZE`/`TRUNCATE` against ClickHouse, no `metricstransform`/pipeline application (findings *name* the fix; applying it is a `setup-*` action behind confirmation), and no test event/ingest. Every call is a read.
