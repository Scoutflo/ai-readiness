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

Each audit (audit-aws, audit-gcp, audit-datadog, etc) already produces:

```json
{
  "target": "aws",
  "findings": [...],
  "cost_section": {
    "captured_at": "2026-07-30T14:30:00Z",
    "data_source": "AWS Cost Explorer + Compute Optimizer",
    "findings": [
      {"id": "COST-AWS-001", "type": "stopped_instances", "monthly_cost": 320},
      {"id": "COST-AWS-002", "type": "underutilized_rds", "monthly_cost": 120}
    ],
    "total_identifiable_waste": 440
  }
}
```

**This data is already fresh.** No cost-analysis API calls needed; just read these sections.

**Stage 2: Cost-Analysis Aggregates (This Skill)**

```
For each audit findings.json:
  ├─ Extract cost_section
  └─ Add source target metadata

Merge all cost_sections → one array

Check correlation.json:
  ├─ Any findings marked as overlaps?
  ├─ Mark deduplicated=true with reason
  └─ Keep dedup_count for scoring

Sort findings by ROI (this is a ranked-savings axis, NOT a 0–100 score):
  ├─ If cost_sensitivity=high: sort by annual_savings (highest first)
  └─ If cost_sensitivity=medium/low: sort by monthly_waste

Output:
  ├─ cost-analysis.json: the deduplicated findings, ranked by savings
  └─ cost-analysis.jsonl: append one history line (total-savings trend tracking)
```

## Report Structure

**File:** `scoutflo-audits/cost-analysis/<YYYY-MM-DD>/findings.json`

```json
{
  "audit_date": "2026-07-30",
  "timestamp": "2026-07-30T15:00:00Z",
  "environment": "production",
  "findings": [
    {
      "id": "COST-AWS-001",
      "title": "Stopped instances not terminated",
      "type": "stopped_instances",
      "source": "aws",
      "monthly_cost": 320,
      "roi_annual": 3840,
      "fix_priority": "high",
      "effort_minutes": 5
    },
    {
      "id": "COST-AWS-002",
      "title": "3 RDS instances <20% utilization",
      "type": "underutilized_rds",
      "source": "aws",
      "monthly_cost": 120,
      "roi_annual": 1440,
      "fix_priority": "medium",
      "effort_minutes": 15
    }
  ],
  "summary": {
    "total_findings": 2,
    "total_monthly_waste": 440,
    "total_annual_impact": 5280,
    "high_priority": 1,
    "medium_priority": 1,
    "low_priority": 0
  },
  "trend": {
    "last_5_runs": [
      {"date": "2026-07-26", "monthly_waste": 580},
      {"date": "2026-07-27", "monthly_waste": 550},
      {"date": "2026-07-30", "monthly_waste": 440}
    ],
    "direction": "improving",
    "momentum": "-$140/mo since first run"
  }
}
```

**File:** `scoutflo-audits/cost-analysis.jsonl` (appended each run)

```jsonl
{"date":"2026-07-26","monthly_waste":580,"state":"analyzed"}
{"date":"2026-07-27","monthly_waste":550,"state":"analyzed"}
{"date":"2026-07-30","monthly_waste":440,"state":"analyzed"}
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

This roll-up does **not** compute a 0–100 health score — cost is a ranked-savings axis, not a reliability grade, and inventing a "cost score" would be an invented number. It presents the deduplicated findings **ranked by dollar savings**, using `cost_sensitivity` to choose the sort key:

- `cost_sensitivity: high` → rank by **annual** savings (biggest total impact first).
- `cost_sensitivity: medium`/`low` → rank by **monthly** waste.

The only headline figures are provider-native, copied verbatim: `total_monthly_waste` and `total_annual_impact` (the sum of the ranked findings' own numbers), plus the count by `fix_priority`. Overlaps flagged by `correlation.json` are marked `deduplicated=true` so a dollar is never counted twice. The trend line tracks `monthly_waste` over runs, not a score.

## Business Context Integration

**Cost Sensitivity: high** → Sort findings by ROI (annual savings) first
**Cost Sensitivity: medium** → Sort by monthly impact
**Cost Sensitivity: low** → Show impact but don't re-prioritize

Example from `topology.json`:
```json
{
  "business_context": {
    "environment": "production",
    "cost_sensitivity": "high",
    "team": "platform",
    "critical_dependencies": ["payment-svc"]
  }
}
```

→ cost-analysis sorts by annual ROI, shows token cost for each fix.

## Run behavior — always regenerate, zero API calls

- **Always runs.** Every invocation rebuilds the roll-up from the findings present now; there is no skip and no `--force`. Removing the old 24h skip removes the only path that could serve a stale roll-up.
- **Zero API calls.** It reads local `findings.json` and `correlation.json` only — it never calls a provider. (The deep, live provider queries belong to `/scoutflo:audit-cost` and the individual audits, not here.)
- **Log output:** `[cost-analysis] Starting analysis for <date>` → `[cost-analysis] Report complete: …/cost-analysis/<date>/findings.json`, or `[cost-analysis] No cost findings available` when no audit emitted a cost-optimization finding.

Because it makes no API calls, there is nothing to cache: the token cost is only re-reading local JSON, so always regenerating is both correct and cheap. History (`cost-analysis.jsonl`) is still appended for the trend line; it is never used to skip a run.

## Graceful Degradation

**If correlation.json not available:**
- Still aggregates findings from all audits
- Skips deduplication pass
- Falls back to default scoring
- Logs: `[cost-analysis] Correlation data not available; scoring without dedup`

**If no business_context set:**
- Uses safe defaults (production / medium / 99.9 / [])
- Still sorts by monthly impact
- Logs: `[cost-analysis] Using safe defaults for business context`

**If no audit findings available:**
- Exits gracefully
- Logs: `[cost-analysis] No cost findings available`

## See also

- `/scoutflo:audit-all` — Phase 4: runs cost-analysis after correlation-engine
- `/scoutflo:correlation-engine` — detects overlaps + cascades
- `/scoutflo:business-context` — sets team/env/cost sensitivity
- Individual skills (audit-aws, audit-gcp, etc) — produce cost_section in findings.json
