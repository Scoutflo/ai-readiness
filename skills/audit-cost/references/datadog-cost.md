# audit-cost (Datadog): Deep Per-Resource Cost Check Catalog

Runnable, read-only checks for the Datadog provider phase of [audit-cost](../SKILL.md). This is the deep, per-resource cost audit — it queries Datadog's **own usage and billing surfaces live** (which host, which custom metric, which log index, which APM service is driving spend), not a re-aggregation of the reliability audit. It deepens the non-scored `DDOPT-*` thinking in [audit-datadog](../../audit-datadog/references/datadog-checks.md#11-cost--resource-optimization-non-scored-ddopt-nnn) into a first-class per-resource catalog with permanent `COST-DD-NNN` IDs. Every finding carries `area: cost-optimization` and `points_recoverable: 0`; nothing here enters a 0–100 score. Money is **ranked**, never scored (the standard's perverse-incentive rule).

> **Maturity (v1 honesty).** The Datadog provider phase is authored but **not yet live-proven end to end** — AWS and GCP are the live-proven targets. Treat every field path below as "verify against the live response before crediting it"; when a documented field is absent or shaped differently in the real payload, record the check `blocked` with the raw response as evidence, never guess a number to fill the gap.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding only when the number is copied **verbatim** from a provider-native recommendation API. **Datadog has no savings-recommendation API** — its usage/billing endpoints (`/api/v1/usage/*`, `/api/v2/usage/*`) return what you are *currently spending*, not what you would *save* by trimming. So for Datadog:

- No Datadog finding ever carries `estimated_monthly_savings_usd`. The savings from cutting custom-metric cardinality, dropping a log-retention tier, or trimming APM hosts is **not** a number Datadog computes, and recomputing it from a usage count against a price list is exactly the fabrication this rule forbids.
- The one native dollar figure Datadog *does* give is the **current cost** of a product line, straight from `estimated_cost` / `historical_cost`. That is reported verbatim in a distinct `estimated_monthly_cost_usd` field (cost-at-risk, current spend), clearly labelled as spend and never as savings. This matches the `estimated_monthly_cost_usd` precedent in [audit-datadog §11](../../audit-datadog/references/datadog-checks.md#11-cost--resource-optimization-non-scored-ddopt-nnn).
- Every other check — cardinality counts, log event counts, span counts, host counts, retention tiers — is a **presence/absence fact** reported with no dollar figure at all. It names the concrete resource and cross-references the relevant product-line cost from `COST-DD-001` for context, but attaches no independent number.

Applied to cost, an unverified number is worse than no number, because it gets pasted into a budget conversation.

- ❌ `COST-DD-004: metric app.request.latency carries ~48,000 custom timeseries; at Datadog's $0.05 per 100 custom metrics that is roughly $288/mo you could save by trimming.`
- ✅ `COST-DD-004: metric app.request.latency is the #1 custom-metric cardinality contributor at avg_metric_hour 48,213 (copied from usage[].avg_metric_hour); no dollar figure attached — Datadog does not compute a per-metric cost or a savings number. Context: the custom_metrics product line is $X this month per COST-DD-001, copied verbatim from estimated_cost.`
- ❌ `COST-DD-001: custom metrics cost $412/mo, so trimming the top 10 saves ~$412/mo.` (cost is not savings)
- ✅ `COST-DD-001: estimated_cost reports product_name "custom_metrics" at estimated_monthly_cost_usd 412.00 (charge_type "estimated", copied verbatim from data[].attributes.charges[].cost); reported as current spend, not savings.`

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Signal | Source API (read-only) | Dollar figure |
| --- | --- | --- | --- |
| COST-DD-001 | Estimated month-to-date cost broken out per product line (the native-$ anchor) | `GET /api/v2/usage/estimated_cost` | **Native $ (current cost)** — `charges[].cost` verbatim |
| COST-DD-002 | Cost trend / month-over-month change per product line | `GET /api/v2/usage/historical_cost` | **Native $ (current cost)** — `charges[].cost` verbatim |
| COST-DD-003 | Infra host count vs committed plan (on-demand overage) | `GET /api/v1/usage/billable-summary`, `GET /api/v2/usage/hourly_usage` | Presence fact (host count vs configured commit); infra cost line from COST-DD-001 |
| COST-DD-004 | Top custom metrics by cardinality (cardinality contributors) | `GET /api/v1/usage/top_avg_metrics` | Presence fact (`avg_metric_hour` count) |
| COST-DD-005 | High-cardinality tags inflating a custom metric's timeseries | `GET /api/v2/metrics/{metric}/estimate`, `/all-tags` | Presence fact (estimated output series, tag count) |
| COST-DD-006 | Unused or duplicate custom metrics (configured but ~zero volume, or near-identical siblings) | `GET /api/v2/metrics?filter[configured]=true`, `top_avg_metrics` | Presence fact |
| COST-DD-007 | Indexed-log volume by index + retention tier | `GET /api/v1/usage/logs_by_index` | Presence fact (`event_count`, `retention`); logs cost line from COST-DD-001 |
| COST-DD-008 | APM ingested vs indexed spans + APM host count | `GET /api/v2/usage/hourly_usage`, `GET /api/v1/usage/billable-summary` | Presence fact (span + host counts); APM cost line from COST-DD-001 |
| COST-DD-009 | Product-line cost spike vs prior month (which line grew) | `GET /api/v2/usage/historical_cost` + `estimated_cost` | Presence fact (delta %); per-line native $ from COST-DD-001/002 |

Native-$ checks (a provider-native dollar figure, reported as **current cost**, never savings): **COST-DD-001, COST-DD-002**. Every other check is a **presence fact** with no dollar figure.

## 3. Doctor-gate dependency

Every check here depends on the doctor gate's optional `datadog cost-permissions` probe (`skills/doctor/scripts/doctor.sh`). That probe makes one cheap read (`GET /api/v2/usage/estimated_cost` for the current month) and never fails the main doctor gate. Cost scope on Datadog is narrower than the reliability scope:

- The `estimated_cost` / `historical_cost` endpoints require the API+app key pair to belong to an org with **usage/billing visibility** (typically the parent org and an app key with the `usage_read` scope). A valid monitoring key that is scoped to a **sub-org** returns `403` on these endpoints — that is a scope finding, not a clean pass.
- A missing cost scope (403 on the probe), or `datadog.cost_checks: false` in `~/.scoutflo/toolkit.yaml`, means the whole Datadog cost section reports itself `excluded` with the doctor's exact reason, rather than running some checks and guessing at the rest.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # written by the doctor gate this run, or the most recent doctor run
[ -f "$MATRIX" ] || { echo "no doctor matrix found; run the doctor gate before the Datadog cost phase"; exit 1; }
awk -F'\t' '$1 == "datadog" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"
```

Expected: `pass -` when cost checks can run, or `skipped <reason>` when they cannot. A `skipped` result means the section renders exactly one line: "Datadog Cost & Resource Optimization: excluded, reason: `<the exact hint from the matrix row>`", and none of COST-DD-001 through COST-DD-009 runs this cycle.

**Partial-scope split (state it explicitly, like audit-aws).** The presence-fact checks that need only `usage_read` — COST-DD-004 (`top_avg_metrics`), COST-DD-006 (`/api/v2/metrics`), COST-DD-007 (`logs_by_index`), COST-DD-008 (`billable-summary`/`hourly_usage`) — and the metric-cardinality reads COST-DD-005 (`/api/v2/metrics/{m}/estimate`) may still run when only the billing scope (`estimated_cost`/`historical_cost`) is missing. In that case COST-DD-001, COST-DD-002, and COST-DD-009 report `excluded, reason: "estimated_cost/historical_cost not readable (403 — key scoped below billing org)"`, the presence facts still fire, and their findings state plainly that no product-line cost figure was available this run. Do not exclude the whole section when only the dollar anchor is blocked.

## 4. Conventions (all sections)

- Every call sends the key **pair**: `DD-API-KEY: <api key>` and `DD-APPLICATION-KEY: <app key>`, from the variables named by `datadog.api_key_env` and `datadog.app_key_env`. Presence-check both; never echo, log, or write either value.
- The API host is `api.<site>` from `datadog.site` (e.g. `api.datadoghq.com`, `api.us5.datadoghq.com`, `api.datadoghq.eu`, `api.ap1.datadoghq.com`). Every block declares `DD_HOST` at the top. A valid key on the wrong site returns 403, so a 403 is a site check before it is a scope check.
- Every command here is a read-only **GET** on usage, billing, and metric-metadata endpoints. There are no read-by-effect POSTs in this catalog. The forbidden-command list is section 12.
- `curl -fsS --max-time 30` is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it. `set -o pipefail` is required so a 403/404 piped into `jq` aborts under `set -e` instead of writing an empty file and passing.
- Rate limits are per-endpoint (`X-RateLimit-*` headers). On `429`, sleep for `X-RateLimit-Reset` seconds once and retry; a second `429` records the affected check `blocked`.
- Month/window values and every threshold below are **examples** — tune to the org. Committed-plan numbers are **not** in the usage API; they are marked config placeholders.

## 5. Native cost anchor — estimated_cost + historical_cost (COST-DD-001, COST-DD-002)

This is the only place a Datadog dollar figure enters a finding, and it is a **current-cost** figure, copied verbatim. It breaks spend out per product line, so every downstream presence fact (custom metrics, logs, APM, hosts) can cite the cost of the line it drills into without inventing a number.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"                 # datadog.site  (config placeholder)
DD_HOST="api.${DD_SITE}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
THIS_MONTH="$(date -u +%Y-%m)"
PREV_MONTH="$(date -u -v-1m +%Y-%m 2>/dev/null || date -u -d 'last month' +%Y-%m)"

# COST-DD-001: estimated (month-to-date) cost, one row per product line. charge_type is one of
# "estimated" / "committed" / "on_demand" / "total"; product_name is the billable product.
# Copy .cost verbatim into estimated_monthly_cost_usd — never recompute it.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/usage/estimated_cost?view=summary&start_month=${THIS_MONTH}&end_month=${THIS_MONTH}" \
  | tee "${RAW_DIR}/estimated-cost.json" \
  | jq -r '.data[]?.attributes | .date as $d | .charges[]?
      | select(.charge_type != "total")
      | [$d, .product_name, .charge_type, .cost] | @tsv' \
  || echo "COST-DD-001 excluded: estimated_cost not readable (403 = key scoped below billing org, or usage_read missing)"

# COST-DD-002: historical cost for the previous full month, same shape — the trend baseline.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/usage/historical_cost?view=summary&start_month=${PREV_MONTH}&end_month=${PREV_MONTH}" \
  | tee "${RAW_DIR}/historical-cost.json" \
  | jq -r '.data[]?.attributes | .date as $d | .charges[]?
      | select(.charge_type != "total")
      | [$d, .product_name, .charge_type, .cost] | @tsv' \
  || echo "COST-DD-002 excluded: historical_cost not readable"
```

Expected: one line per `(product line, charge type)` with its `cost`. Report each `product_name` whose `charge_type` is `on_demand` as an overage signal, and copy `.cost` verbatim into `estimated_monthly_cost_usd`. When the endpoint returns 403, the row is `excluded` with the reason above — never a `$0` line, which would falsely read as "nothing to save".

## 6. Infra host count vs committed plan (COST-DD-003)

The committed host count is a contract number **not present in the usage API**; supply it as a config placeholder and compare the live billable count against it. Persistent on-demand overage above the commit is the finding, named with the concrete numbers.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
COMMITTED_INFRA_HOSTS="0"                                   # config placeholder: the contracted host commit; 0 = unknown, then report count only
THIS_MONTH="$(date -u +%Y-%m)"

# Billable host counts for the month. Each *_sum field is an object; .usage_count is the billed count.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/billable-summary?month=${THIS_MONTH}" \
  | jq -r '.usage[]? | {
      infra_hosts: (.infra_host_sum.usage_count // null),
      apm_hosts:   (.apm_host_sum.usage_count // null),
      apm_fargate: (.apm_fargate_average.usage_count // null),
      custom_ts:   (.custom_ts_sum.usage_count // null),
      logs_indexed:(.logs_indexed_events_sum.usage_count // null)}' \
  || echo "COST-DD-003 blocked: billable-summary not readable (usage_read missing)"

# Cross-check the live top-of-hour host count over the last few hours (v2 hourly usage).
START_HR="$(date -u -v-6H +%Y-%m-%dT%H:00:00 2>/dev/null || date -u -d '6 hours ago' +%Y-%m-%dT%H:00:00)"
curl -gfsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/usage/hourly_usage?filter[product_families]=infra_hosts&filter[timestamp][start]=${START_HR}" \
  | jq -r '.data[]?.attributes | .product_family as $p | .usage[]? | [$p, .usage_type, .value] | @tsv' \
  || echo "COST-DD-003 hourly cross-check unavailable"
```

Expected: a billed `infra_hosts` count. When `COMMITTED_INFRA_HOSTS > 0` and the billed count exceeds it, the finding names both numbers ("billed 214 infra hosts vs committed 180 — 34 on-demand") and cites the `infra_hosts` cost line from COST-DD-001 for the dollar context; it never multiplies the overage by a list price to invent a savings figure. When the commit is unknown (`0`), report the count as a presence fact and say the commit was not supplied. `-g` (globoff) is required because the v2 param names literally contain `[` `]`.

## 7. Custom-metric cardinality (COST-DD-004, COST-DD-005, COST-DD-006)

Custom-metric cardinality is Datadog's most common surprise cost. These are all presence facts: they name *which* metric and *why* it is expensive (how many timeseries, which tag explodes it), and cite the `custom_metrics` cost line from COST-DD-001 for context. They never attach a per-metric dollar figure — Datadog does not compute one.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# COST-DD-004: top custom metrics by average hourly cardinality. avg_metric_hour is the
# billed dimension for custom metrics — the ranking IS the cost driver, but it is a COUNT.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/top_avg_metrics?limit=50" \
  | tee "${RAW_DIR}/top-avg-metrics.json" \
  | jq -r '.usage[]? | [.metric_name, .avg_metric_hour, .max_metric_hour, (.metric_category // "custom")] | @tsv' \
  | sort -t"$(printf '\t')" -k2 -nr | head -20 \
  || echo "COST-DD-004 blocked: top_avg_metrics not readable (usage_read missing)"
```

**COST-DD-005 (high-cardinality tags).** For the top contributors from COST-DD-004, ask Datadog's own cardinality estimator which tag is inflating the timeseries. The estimate endpoint returns Datadog's projected `estimated_output_series` for a tag/aggregation configuration — a count, reported as a presence fact.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
METRIC_NAME="app.request.latency"                          # config placeholder: a top contributor from COST-DD-004

# Active tags currently emitted for this metric (which keys exist on the live series).
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/metrics/${METRIC_NAME}/all-tags" \
  | jq '{metric: .data.id, active_tags: (.data.attributes.active_tags // .data.attributes.tags // [])}' \
  || echo "COST-DD-005: all-tags not readable for ${METRIC_NAME}"

# Datadog's OWN cardinality estimate. estimated_output_series is the projected timeseries count;
# report it verbatim as a presence fact. If the field name differs in the live payload, record
# the raw response as evidence and mark blocked — never guess a cardinality number.
curl -gfsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/metrics/${METRIC_NAME}/estimate?filter[num_aggregations]=1&filter[timespan_h]=24" \
  | jq '{metric: .data.id, estimate_type: .data.attributes.estimate_type,
         estimated_output_series: .data.attributes.estimated_output_series, date: .data.attributes.date}' \
  || echo "COST-DD-005: estimate not readable for ${METRIC_NAME}"
```

Expected: the active tag set, plus Datadog's projected series count. A metric whose cardinality is dominated by one unbounded tag key (a request ID, a user ID, a raw URL path) is the finding — name the metric and the offending tag key. No dollar figure; cite the `custom_metrics` cost line from COST-DD-001.

**COST-DD-006 (unused / duplicate custom metrics).** A metric with a live tag configuration but no meaningful volume in `top_avg_metrics`, or a pair of near-identical metric names (a `.count` and a `.total` of the same thing), is billable cardinality with no query value.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# List every metric with a tag configuration (window[seconds] scopes "actively reporting").
curl -gfsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/metrics?filter[configured]=true&window[seconds]=2592000" \
  | jq -r '.data[]?.id' | sort > "${RAW_DIR}/configured-metrics.txt" \
  || echo "COST-DD-006 blocked: /api/v2/metrics not readable"

# Metrics that are configured but do NOT appear among the top cardinality contributors
# (candidate low/zero-volume configs to review). This is a candidate list, not a verdict —
# a metric can be low-cardinality and still valuable; confirm intent before flagging.
jq -r '.usage[]? | .metric_name' "${RAW_DIR}/top-avg-metrics.json" 2>/dev/null | sort > "${RAW_DIR}/active-metrics.txt" || true
comm -23 "${RAW_DIR}/configured-metrics.txt" "${RAW_DIR}/active-metrics.txt" 2>/dev/null | head -30 || true
```

Expected: a candidate list of configured-but-quiet metrics and any near-duplicate name pairs. Report each as a presence fact naming the metric; a low-cardinality metric that is genuinely used is not a finding — confirm intent (a `service:` tag with no matching monitor or dashboard is corroboration), never flag on volume alone.

## 8. Indexed-log volume + retention tier (COST-DD-007)

Indexed logs are billed on event count × retention. `logs_by_index` gives both per index, so the finding can name the exact index, its event count, and its retention days — a presence fact, cross-referencing the logs cost line from COST-DD-001.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
# start_hr/end_hr are ISO 8601 hours; last 30 days as an example window.
START_HR="$(date -u -v-30d +%Y-%m-%dT%H:00:00 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT%H:00:00)"
END_HR="$(date -u +%Y-%m-%dT%H:00:00)"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/logs_by_index?start_hr=${START_HR}&end_hr=${END_HR}" \
  | jq -r '.usage[]? | [.index_name, .index_id, .event_count, .retention] | @tsv' \
  | sort -t"$(printf '\t')" -k3 -nr \
  || echo "COST-DD-007 blocked: logs_by_index not readable (usage_read missing)"
```

Expected: one line per index sorted by event count, each with its `retention` in days. A high-volume index sitting on the longest retention tier — or a debug/verbose index indexed at all when it could be filtered before indexing — is the finding. Name the index, its event count, and its retention; cite the logs cost line from COST-DD-001. No independent dollar figure and no assumed retention default: report the retention the API returns.

## 9. APM ingested vs indexed spans + host count (COST-DD-008)

APM is billed on host count and on indexed spans (a subset of ingested spans, selected by retention filters). A large gap between ingested and indexed, or a high APM host count, is the finding — presence facts, cross-referencing the APM cost line from COST-DD-001.

```bash
set -euo pipefail
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"          # datadog.site
START_HR="$(date -u -v-24H +%Y-%m-%dT%H:00:00 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:00:00)"

# Hourly usage for the three APM families. value is the usage per hour for each usage_type.
curl -gfsS --max-time 45 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/usage/hourly_usage?filter[product_families]=apm_hosts,ingested_spans,indexed_spans&filter[timestamp][start]=${START_HR}" \
  | jq -r '.data[]?.attributes | .product_family as $p | .timestamp as $t | .usage[]? | [$t, $p, .usage_type, .value] | @tsv' \
  || echo "COST-DD-008 blocked: hourly_usage not readable"

# Monthly billed APM host sum as the stable count for the finding.
THIS_MONTH="$(date -u +%Y-%m)"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/billable-summary?month=${THIS_MONTH}" \
  | jq '.usage[]? | {apm_hosts: (.apm_host_sum.usage_count // null), apm_fargate: (.apm_fargate_average.usage_count // null)}' \
  || echo "COST-DD-008: billable-summary APM counts unavailable"
```

Expected: hourly `ingested_spans` vs `indexed_spans` values and the billed APM host count. A very high ingested-to-indexed ratio with no tightened retention filter, or APM hosts far above the count of services that actually carry traces, is the finding — named with the numbers, no dollar figure, citing the APM cost line from COST-DD-001.

## 10. Product-line cost spike vs prior month (COST-DD-009)

Compare each product line's `estimated_cost` (this month) against `historical_cost` (prior full month) from section 5. A line that grew sharply is the finding; the per-line dollars are the verbatim native figures already captured in COST-DD-001/002, and the delta is reported as a percentage — never a fabricated "you overspent by $N".

```bash
set -euo pipefail
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
# Join this-month vs prev-month cost per product_name and show the delta. Costs are verbatim.
jq -rn --slurpfile cur "${RAW_DIR}/estimated-cost.json" --slurpfile prev "${RAW_DIR}/historical-cost.json" '
  ($cur[0].data[]?.attributes.charges[]? | select(.charge_type=="estimated")
     | {(.product_name): .cost}) as $c
  | ($prev[0].data[]?.attributes.charges[]? | select(.charge_type=="total" or .charge_type=="estimated")
     | {(.product_name): .cost}) as $p
  | [$c, $p]' 2>/dev/null \
  || echo "COST-DD-009: needs both estimated-cost.json and historical-cost.json (COST-DD-001/002 must have run)"
```

Expected: per-product current vs prior cost, verbatim. Report the line(s) that grew most as a presence-fact spike with the two dollar figures (both provider-sourced) and the percentage change; the recommendation is "investigate what drove product_name X up N%", not a savings claim. When only one month is readable, report the single figure and say the trend was unavailable.

## 11. Rendering the section

Every finding uses `area: cost-optimization`, `points_recoverable: 0`, and is **report-only**: the `recommendation` names the concrete action and the Datadog console / API path, and carries no `setup-*` remediation pointer — trimming a metric, dropping a retention tier, or deleting an index from a cost signal is materially riskier than a reliability fix and stays a human decision (v1 never automates it). Findings render under the Datadog heading of audit-cost's ranked report, not in any scored Findings table.

**Open the section with the savings-summary line**, per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule — but honor the Datadog reality that the native figures are **costs, not savings**:

> **Datadog spend under review: ~$<sum>/month** across **<n>** product lines with a Datadog-sourced cost figure (from `estimated_cost`); **<m>** per-resource opportunities found with no dollar figure (presence facts — top custom metrics, log indexes, APM spans, listed below). Largest cost line: **$<max>/mo** — `<product_name>`. Datadog does not compute a savings figure, so no dollar savings is claimed; the presence facts below name the concrete resources driving each line.

Rules for the summary line: sum only `estimated_monthly_cost_usd` values copied verbatim from `estimated_cost`/`historical_cost`; label them **spend under review**, never "savings" (Datadog computes no savings number). State the count of product lines *with* a cost figure separately from the count of per-resource facts *without* one, so the reader never mistakes the cost total for a savings total. If `estimated_cost` was blocked (403), write "N per-resource cost opportunities found; no Datadog-sourced cost figure available this run (billing scope missing) — each is a presence fact to review", never `$0`.

Then render the per-row table, columns `Finding | Resource | Signal source | Current metric (count/cardinality/retention) | Product cost line (Datadog-sourced) | Action`. `Product cost line` shows the verbatim `estimated_monthly_cost_usd` of the product this resource drives (from COST-DD-001), or `-` when the billing scope was blocked. A per-resource row never prints its own invented dollar figure — the count columns carry the evidence, the cost column carries only the product-line figure Datadog returned.

## 12. Forbidden commands

This is an audit: read-only, no exceptions. For Datadog, never run:

- Any `POST`, `PUT`, `PATCH`, or `DELETE` on any endpoint — there is no read-by-effect POST in this catalog's surface.
- Editing metric tag configurations: `POST/PATCH/DELETE /api/v2/metrics/{metric}/tags` and `POST /api/v2/metrics/{metric}/bulk-tags` (the `manage_tags` mutating path — that trims cardinality, which is a setup-lane change, never an audit action).
- Submitting or deleting metrics: `POST /api/v1/series`, `POST /api/v2/series`, `POST /api/v1/distribution_points`.
- Editing log pipelines, indexes, or retention: `PUT/POST /api/v1/logs/config/indexes/{name}`, `PUT /api/v1/logs/config/pipelines/*` (changing an index's retention or filter changes the bill).
- Editing APM retention filters or span-ingestion controls: `POST/PATCH/DELETE /api/v2/apm/config/retention-filters/*`.
- Creating, editing, or deleting cost/usage attribution tags, budgets, or monthly-usage-attribution config: `PUT /api/v1/usage/cost_by_org` and any `POST` under `/api/v2/cost/*`.
- Creating, muting, or resolving monitors, downtimes, SLOs, dashboards, or notebooks; sending any test event (`POST /api/v1/events`).

If a read returns `403`/`404`/`429`, record the affected check `blocked` with the status code as evidence and move on — never retry with a different verb, and never fall back to a mutating call to "confirm" a resource.
