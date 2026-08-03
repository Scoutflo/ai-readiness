---
name: cost-analysis
description: 'Internal roll-up harness (v0.1.67+): inside /scoutflo:audit-all, aggregates the cost-optimization findings the individual audits already wrote (area cost-optimization — AWSOPT-*, DDOPT-*), de-duplicates them via correlation.json, and writes a combined cost roll-up with a 24h skip. It re-reads existing findings; it does NOT query providers. For a DEEP, live, per-resource cost analysis, use /scoutflo:audit-cost. Wired into /scoutflo:audit-all after the correlation engine.'
---

# Cost Analysis (roll-up harness)

Aggregates the cost-optimization findings the individual audits already wrote into one combined, de-duplicated roll-up. This is a lightweight post-run roll-up, **not** a deep cost analysis.

> **For a real cost audit, run [`/scoutflo:audit-cost`](../audit-cost/SKILL.md).** That skill queries each provider's live cost surfaces (AWS Compute Optimizer / Cost Explorer / Cost Optimization Hub, GCP Recommender, Datadog usage, Kubernetes requests-vs-usage, DigitalOcean billing), produces per-resource findings ranked by provider-native dollar savings, and writes a full `report.md`. This roll-up only re-reads findings other audits already produced — by design it makes zero provider calls and adds no new findings. It never scores 0–100 (cost is a ranked-savings axis, not a health score) and never invents a dollar figure.

**When it runs:**
- Automatically inside `/scoutflo:audit-all` after the correlation engine, to give one combined cost view across whatever audits ran.
- It is not the place to start a cost investigation — `/scoutflo:audit-cost` is.

## How it works

### Skip Logic: Zero Re-Analysis if Unchanged

First run: cost-analysis always runs. Result: `cost-analysis.json` + one line appended to `cost-analysis.jsonl` (history).

Subsequent runs within 24h with no new audit findings: **SKIP** — reuses previous report, no API calls.

Example:
```bash
Monday 9am:  /scoutflo:audit-all
  └─ audit-aws: calls AWS Cost Explorer, stores findings.json:cost_section
  └─ audit-gcp: calls GCP Cost Management, stores findings.json:cost_section
  └─ correlation-engine: detects overlaps
  └─ cost-analysis: aggregates (RUNS, 0 extra API calls)

Tuesday 2pm: /scoutflo:audit-all again
  └─ cost-analysis: skips (only 29h old, no new audit findings)
  └─ Log: "Cost analysis is current (29h old, no new findings)"

Wednesday 9am: /scoutflo:audit-all again + new AWS findings
  └─ AWS audit finds NEW instances
  └─ cost-analysis detects change, RUNS
  └─ Computes delta vs yesterday, updates trend
```

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

Calculate score (0-100):
  ├─ waste_percent = identifiable_waste / estimated_total_spend
  ├─ dedup_penalty = overlaps * 10
  ├─ action_gap_penalty = (no_high_priority_items * 5)
  └─ score = 100 - (waste_percent * 60) - dedup - actions

Sort findings by ROI:
  ├─ If cost_sensitivity=high: sort by annual_savings (highest first)
  └─ If cost_sensitivity=medium/low: sort by monthly_waste

Output:
  ├─ cost-analysis.json: scored report + findings sorted by priority
  └─ cost-analysis.jsonl: append one history line (trend tracking)
```

## Report Structure

**File:** `scoutflo-audits/cost-analysis/<YYYY-MM-DD>/findings.json`

```json
{
  "audit_date": "2026-07-30",
  "timestamp": "2026-07-30T15:00:00Z",
  "overall_score": 42,
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
      {"date": "2026-07-26", "overall": 35, "monthly_waste": 580},
      {"date": "2026-07-27", "overall": 38, "monthly_waste": 550},
      {"date": "2026-07-30", "overall": 42, "monthly_waste": 440}
    ],
    "direction": "improving",
    "momentum": "+7 improving"
  }
}
```

**File:** `scoutflo-audits/cost-analysis.jsonl` (appended each run)

```jsonl
{"date":"2026-07-26","overall":35,"monthly_waste":580,"state":"analyzed"}
{"date":"2026-07-27","overall":38,"monthly_waste":550,"state":"analyzed"}
{"date":"2026-07-30","overall":42,"monthly_waste":440,"state":"analyzed"}
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

## Scoring Formula

```
Score = 100 - (waste_percent * 60) - (overlaps * 10) - (missing_actions * 5)

where:
  waste_percent = identifiable_waste / (identifiable_waste / 0.05)  [assume waste = 5% of spend]
  overlaps = cost_section findings marked deduplicated=true
  missing_actions = 1 if no high-priority findings, 0 otherwise
```

**Example:**
- Waste: $440/month (6.7% of estimated $6,600 spend)
- waste_component = 6.7 * 60 / 100 = 4 points
- Overlaps: 1 deduplicated finding = 10 points
- Missing actions: 1 high-priority finding exists = 0 points
- **Score = 100 - 4 - 10 - 0 = 86**

(Higher score = healthier cost posture.)

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

## Skip Logic Behavior

**Run cost-analysis if:**
- File `cost-analysis.jsonl` doesn't exist (first run)
- Last entry in `cost-analysis.jsonl` is >24 hours old
- Any new audit findings since last cost-analysis run (checked via find newer)
- User runs `/scoutflo:cost-analysis --force`

**Skip cost-analysis if:**
- Last entry is <24h old AND no new audit findings added
- Reuses previous report, no work

**Log output:**
- Run: `[cost-analysis] Starting analysis for 2026-07-30`
- Skip: `[cost-analysis] Skipping (analysis current)`
- Success: `[cost-analysis] Report complete: scoutflo-audits/cost-analysis/2026-07-30/findings.json`

## No Double API Calls

| Who calls what | When | Cost-analysis behavior |
|---|---|---|
| audit-aws → AWS Cost Explorer | Every audit run | Reads from findings.json:cost_section (zero API calls) |
| audit-gcp → GCP Cost Management | Every audit run | Reads from findings.json:cost_section (zero API calls) |
| audit-datadog → Datadog usage API | Every audit run | Reads from findings.json:cost_section (zero API calls) |
| correlation-engine → overlaps | After audit-all | Reads from correlation.json (zero API calls) |
| cost-analysis → (reads only) | After audit-all or standalone | Reads local files only (ZERO API calls) |

**Result:** cost-analysis makes **zero additional API calls** if run within 24h of audits.

## Token Efficiency

**Estimated savings per week (audits 2x/week):**
```
Monday:   cost-analysis runs (0 wasted tokens, reads findings.json)
Thursday: cost-analysis skips (24h < 72h, no new findings) → saves 10K tokens ≈ $0.05
Monday:   cost-analysis runs (new findings available)
Thursday: cost-analysis skips → saves 10K tokens ≈ $0.05

Weekly savings: $0.10 per audit cycle
Annual savings: ~$5.20
```

On large estates (500+ resources): skip logic saves 20-30% of total analysis tokens by avoiding redundant cost re-calculation.

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
