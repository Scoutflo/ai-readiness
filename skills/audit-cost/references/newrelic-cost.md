# audit-cost (New Relic): Deep Per-Signal Ingest Cost Check Catalog

Read-only cost lane for a New Relic account, driven by the account's OWN
consumption data. Auth and target resolution are `audit-newrelic`'s doctor gate
(User key, region host, account id); every read here is a NerdGraph `query`
document — the cost phase never mutates.

## 1. The one hard rule

**Never invent a dollar.** New Relic's usage-based pricing bills ingest per GB
(plus per-seat and CCU costs this lane cannot see), and the published $/GB rate
is plan-dependent. `NrConsumption` exposes **billed GB** — report GB and rank by
GB. A dollar figure appears on a finding only when the account's own
consumption/billing data exposes a billed amount, with `savings_source` naming
the exact event/field it came from; otherwise `estimated_monthly_savings_usd`
stays `null` and the finding is a ranked volume fact.

## 2. Check catalog

| ID | Check |
| --- | --- |
| COST-NR-001 | Billed ingest by source: `NrConsumption` GB by `usageMetric` over 30d (lags ~a day), cross-checked against the live `bytecountestimate()` rate per signal type |
| COST-NR-002 | Top ingest contributors inside the dominant signal: metrics by `metricName`, logs by `service.name`/`logtype`, spans by `service.name` — the specific families to trim |
| COST-NR-003 | Cap/commitment proximity: projected 30-day GB vs the 100GB free-tier hard lockout (ingest AND UI stop) or the paid commitment when consumption exposes it |
| COST-NR-004 | Governance opportunities (advisory): long-window trends kept as raw events that events-to-metrics rules would keep for 13 months at a fraction of the bytes; retention above need; high-cardinality attributes normalization would fold |

## 3. Doctor-gate dependency

Runs only when `audit-newrelic`'s doctor gate passes for the target (valid User
key on the right region host, account visible). There is no separate cost
permission: `NrConsumption` is readable by the same key. When the account is too
new for `NrConsumption` to have populated (~a day of lag), COST-NR-001 reports
from `bytecountestimate()` alone and says which source the numbers came from.

## 4. Conventions

- All reads go through the same `nrq`/`nrql` helper as `audit-newrelic`
  (references section 1): 200+JSON asserted, mutations rejected, sequential.
- Sum COMPLETE days only when projecting; a partial day extrapolated silently is
  an invented number.
- Findings carry `COST-NR-NNN` ids, `scoring_scope: "non-scored"`,
  `points_recoverable: 0`.

## 5. The reads

```bash
# COST-NR-001: billed GB by source (30d) + the live per-signal rate (1d).
nrql "SELECT sum(GigabytesIngested) FROM NrConsumption FACET usageMetric SINCE 30 days ago LIMIT 20"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Metric SINCE 1 day ago"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Span SINCE 1 day ago"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Log SINCE 1 day ago"

# COST-NR-002: contributors inside the dominant signal (run the one that dominates).
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Metric FACET metricName SINCE 1 day ago LIMIT 15"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Log FACET service.name SINCE 1 day ago LIMIT 15"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Span FACET service.name SINCE 1 day ago LIMIT 15"

# COST-NR-003: projection = (30d NrConsumption total when complete, else live rate x 30) vs the cap.
```

Interpretation: the burn order measured in real estates — unfiltered container
logs ≫ cluster-wide infra metrics (kubeletstats/hostmetrics-class collection has
measured ~16GB/day on a small cluster) ≫ unsampled traces ≫ app metrics. A
dominant source disproportionate to its value is the finding; the top
`metricName`/`service.name` families are the `affected` resources.

## 6. The fixes this lane names (never applies)

- **Collector-side filter/sampler processors** are the budget lever on every
  plan — legacy NRQL drop rules are dead for new accounts and the successor
  (Pipeline Control cloud rules) is permission-gated; never present drop rules
  as the fix.
- Metrics: trim the emitting receiver's collection interval/scope, or fold
  labels via normalization — cardinality is a second, silent budget (rollups
  stop past 100k series/metric/day).
- Logs: errors-only shipping at the collector (severity OR error-shaped body).
- Traces: a probabilistic sampler on the export path.
- Long-window dashboards: events-to-metrics rules (13-month dimensional metrics
  at a fraction of the raw-event bytes) — COST-NR-004, advisory.

## 7. Forbidden (never run in the cost phase)

Every NerdGraph mutation — including `nrqlDropRulesCreate` (dead),
`entityManagementCreatePipelineCloudRule` (permission-gated),
`dataManagementCreateEventRetentionRule`, and `eventsToMetricsCreateRule`. This
lane measures and names; `setup-newrelic` and the collector's own config apply.
