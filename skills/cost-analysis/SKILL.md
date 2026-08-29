---
name: cost-analysis
description: 'Internal roll-up harness (v0.1.67+): inside /scoutflo:audit-all, aggregates the cost-optimization findings the individual audits already wrote (area cost-optimization — AWSOPT-*, DDOPT-*), de-duplicates them via correlation.json, and writes a combined cost roll-up. It ALWAYS regenerates (no skip, no cache) and re-reads existing findings only; it does NOT query providers. For a DEEP, live, per-resource cost analysis, use /scoutflo:audit-cost. Wired into /scoutflo:audit-all after the correlation engine.'
---

# Cost Analysis (roll-up harness)

Aggregates the cost-optimization findings the individual audits already wrote into one combined, de-duplicated roll-up. This is a lightweight post-run roll-up, **not** a deep cost analysis.

> **For a real cost audit, run [`/scoutflo:audit-cost`](../audit-cost/SKILL.md).** That skill queries each provider's live cost surfaces (AWS Compute Optimizer / Cost Explorer / Cost Optimization Hub, GCP Recommender, Datadog usage, Kubernetes requests-vs-usage, DigitalOcean billing), produces per-resource findings ranked by provider-native dollar savings, and writes a full `report.md`. This roll-up only re-reads findings other audits already produced — by design it makes zero provider calls and adds no new findings. It never scores 0–100 (cost is a ranked-savings axis, not a health score) and never invents a dollar figure.

**When it runs:**
- Automatically inside `/scoutflo:audit-all` after the correlation engine, to give one combined cost view across whatever audits ran.
- It is not the place to start a cost investigation — `/scoutflo:audit-cost` is.

## How it works

### Always regenerates — no skip, no stale roll-up

This roll-up **always rebuilds** from the findings present in the current run. It re-reads only local `findings.json` files (zero API calls), so there is nothing worth caching — and a "skip if <24h old" cache could hand back a stale roll-up, the exact "past data overpowers the output" bias that was removed from the deep cost path. There is no skip and no `--force`: every invocation aggregates whatever findings exist now, then appends one history line for the trend.

For a **deep, live, per-resource** cost analysis (querying Cost Explorer / Compute Optimizer / GCP Recommender / Datadog usage / K8s / DO billing), run [`/scoutflo:audit-cost`](../audit-cost/SKILL.md) — that skill always runs live too and has no cache to force past.

### Data Flow: Individual Audits → Master Report

**Stage 1: Individual Audits (Existing, No Change)**

Each audit (audit-aws, audit-gcp, audit-datadog, etc) already writes its
cost-optimization findings into the normal `findings[]` array, tagged
`area: "cost-optimization"` (IDs like `AWSOPT-*`, `DDOPT-*`). A provider-native
dollar figure rides in `estimated_monthly_savings_usd` when the audit copied one
verbatim; a presence-fact finding leaves it `null`:

```json
{
  "target": "aws",
  "findings": [
    {
      "id": "AWSOPT-001",
      "title": "3 stopped EC2 instances still billing for EBS",
      "area": "cost-optimization",
      "affected": ["ec2/i-0abc", "ec2/i-0def"],
      "estimated_monthly_savings_usd": 320
    },
    {
      "id": "AWSOPT-002",
      "title": "RDS instance under 20% utilization",
      "area": "cost-optimization",
      "affected": ["rds/prod-db-1"],
      "estimated_monthly_savings_usd": null
    }
  ]
}
```

**This data is already fresh.** No cost-analysis API calls needed; this skill just
reads every audit's `area: "cost-optimization"` findings.

**Stage 2: Cost-Analysis Aggregates (This Skill)**

```
For each audit findings.json (skips the all/ and cost-analysis/ dirs):
  ├─ Select findings where area == "cost-optimization"
  └─ Tag each with its source_target

Merge all cost findings → one array

Check correlation.json:
  ├─ Any finding ID in an overlap group?
  ├─ Mark deduplicated=true with the overlap recommendation
  └─ Keep it visible (annotated, never dropped)

Rank by provider-native savings (a ranked-savings axis, NOT a 0–100 score):
  └─ estimated_monthly_savings_usd, largest first; presence facts (null) after

Output:
  ├─ cost-analysis/<date>/findings.json: the deduplicated findings, ranked by savings
  └─ cost-analysis.jsonl: append one history line (monthly_savings_identified trend)
```

## Report Structure

**File:** `scoutflo-audits/cost-analysis/<YYYY-MM-DD>/findings.json`

```json
{
  "audit_date": "2026-07-30",
  "generated_at": "2026-07-30T15:00:00Z",
  "environment": "production",
  "cost_sensitivity": "medium",
  "findings": [
    {
      "id": "AWSOPT-001",
      "title": "3 stopped EC2 instances still billing for EBS",
      "source_target": "aws",
      "affected": ["ec2/i-0abc", "ec2/i-0def"],
      "estimated_monthly_savings_usd": 320,
      "roi_annual": 3840,
      "imported_at": "2026-07-30T15:00:00Z",
      "deduplicated": false,
      "dedup_reason": "No overlap"
    },
    {
      "id": "DDOPT-002",
      "title": "High-cardinality custom metrics dominate ingestion",
      "source_target": "datadog",
      "affected": ["go_gc_heap_allocs_by_size_bytes.bucket"],
      "estimated_monthly_savings_usd": null,
      "roi_annual": null,
      "imported_at": "2026-07-30T15:00:00Z",
      "deduplicated": false,
      "dedup_reason": "No overlap"
    }
  ],
  "summary": {
    "total_findings": 2,
    "findings_with_native_savings_figure": 1,
    "presence_fact_findings": 1,
    "monthly_savings_identified": 320,
    "annual_savings_identified": 3840,
    "deduplicated_overlaps": 0
  },
  "note": "Savings totals sum only provider-native recommendation figures (Compute Optimizer, Cost Explorer, Datadog usage). Presence-fact findings carry no invented dollar value.",
  "trend": {
    "last_5_runs": [
      {"date": "2026-07-27", "monthly_savings_identified": 550, "state": "analyzed"},
      {"date": "2026-07-30", "monthly_savings_identified": 320, "state": "analyzed"}
    ]
  }
}
```

**File:** `scoutflo-audits/cost-analysis.jsonl` (appended each run)

```jsonl
{"date":"2026-07-27","total_findings":3,"monthly_savings_identified":550,"state":"analyzed"}
{"date":"2026-07-30","total_findings":2,"monthly_savings_identified":320,"state":"analyzed"}
```

## Deduplication Example

**Without dedup:**
```
AWS audit: "stopped instances = $320/mo"
GCP audit: "unused resources = $200/mo"
Cost-analysis without dedup: sees both, total = $520
But correlation.json says AWS instances also monitored by Grafana → 50% redundant
Cost without dedup: $520 (WRONG)
```

**With dedup via correlation:**
```
AWS: "stopped instances = $320/mo" [primary per correlation]
GCP: "unused resources = $200/mo" [secondary, already counted]
Cost-analysis: $320 (only count once, mark GCP as deduplicated)
```

## Ranking (not a 0–100 score)

This roll-up does **not** compute a 0–100 health score — cost is a ranked-savings axis, not a reliability grade, and inventing a "cost score" would be an invented number. It presents the deduplicated findings **ranked by provider-native monthly savings** (`estimated_monthly_savings_usd`, largest first); presence-fact findings with no figure (`null`) sort to the end. Each finding also carries a derived `roi_annual` (its monthly figure × 12), so ranking by monthly or annual savings yields the same order. `cost_sensitivity` is read from business context and recorded in the output, but the current roll-up does not re-sort by it.

The only headline figures are provider-native, copied verbatim: `monthly_savings_identified` and `annual_savings_identified` (the sum of the ranked findings' own `estimated_monthly_savings_usd` / `roi_annual`), plus the `findings_with_native_savings_figure` vs `presence_fact_findings` split. Overlaps flagged by `correlation.json` are marked `deduplicated=true` so a dollar is never counted twice. The trend line tracks `monthly_savings_identified` over runs, not a score.

## Business Context Integration

Business context is read from `~/.scoutflo/business_context.json` (the derived SSOT
projection), falling back to the legacy `topology.json` `business_context` block, then
to safe defaults. It contributes:

- `environment` and `cost_sensitivity` — recorded verbatim in the roll-up's top-level
  fields for context. The current roll-up always ranks by provider-native monthly
  savings; `cost_sensitivity` is captured but does not change that ordering.
- `critical_dependencies` — loaded for downstream consumers; the roll-up does not
  re-weight dollar figures by it.

Example `business_context.json` (or the same keys under the legacy `topology.json`
`business_context` block):
```json
{
  "environment": "production",
  "cost_sensitivity": "high",
  "critical_dependencies": ["payment-svc"]
}
```

## Run behavior — always regenerate, zero API calls

- **Always runs.** Every invocation rebuilds the roll-up from the findings present now; there is no skip and no `--force`. Removing the old 24h skip removes the only path that could serve a stale roll-up.
- **Zero API calls.** It reads local `findings.json` and `correlation.json` only — it never calls a provider. (The deep, live provider queries belong to `/scoutflo:audit-cost` and the individual audits, not here.)
- **Log output:** `[cost-analysis] Starting analysis for <date>` → `[cost-analysis] Report complete: …/cost-analysis/<date>/findings.json`, or `[cost-analysis] No cost findings available` when no audit emitted a cost-optimization finding.

Because it makes no API calls, there is nothing to cache: the token cost is only re-reading local JSON, so always regenerating is both correct and cheap. History (`cost-analysis.jsonl`) is still appended for the trend line; it is never used to skip a run.

## Graceful Degradation

**If correlation.json not available:**
- Still aggregates findings from all audits
- Skips the deduplication pass (findings pass through unannotated)
- No score is involved either way — this roll-up never scores

**If no business_context set:**
- Uses safe defaults (production, medium cost sensitivity, no critical dependencies)
- Still ranks by provider-native monthly savings

**If no audit findings available:**
- Exits gracefully
- Logs: `[cost-analysis] No cost findings available`

## See also

- `/scoutflo:audit-all` — Phase 3.7: runs cost-analysis after correlation-engine and the alert-fatigue roll-up
- `/scoutflo:correlation-engine` — detects overlaps + cascades
- `/scoutflo:business-context` — sets env / cost sensitivity / critical dependencies
- Individual skills (audit-aws, audit-gcp, etc) — produce `area: "cost-optimization"` findings in findings.json
