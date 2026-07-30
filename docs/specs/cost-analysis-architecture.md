# Cost Analysis Architecture — v0.1.67

**Master Skill Integration with Individual Audit Cost Sections**

---

## Problem Statement

Risk: Master `/scoutflo:cost-analysis` skill could:
1. **Re-analyze** cost data already computed by individual audit skills
2. **Duplicate** API calls to providers (AWS Cost Explorer, GCP Cost Management, Datadog usage API)
3. **Waste** tokens on redundant cost calculations when only 1-2 audits changed
4. **Miss** existing cost insights from individual audit "Cost & Resource Optimization" sections

This document specifies how to avoid these issues.

---

## Architecture: Two-Layer Cost System

### Layer 1: Individual Audit Skill Cost Sections (Non-Scored)

**Purpose:** Per-provider cost data, captured during audit execution.

**Where:** Each audit's `findings.json` under `cost_section`:

```json
{
  "target": "aws",
  "findings": [...],
  "cost_section": {
    "captured_at": "2026-07-30T14:30:00Z",
    "data_source": "AWS Cost Explorer + Compute Optimizer",
    "findings": [
      {
        "id": "COST-AWS-001",
        "type": "stopped_instances",
        "monthly_cost": 320,
        "description": "8 stopped instances not terminated"
      },
      {
        "id": "COST-AWS-002",
        "type": "underutilized_rds",
        "monthly_cost": 120,
        "description": "3 RDS instances <20% utilization"
      }
    ],
    "total_identifiable_waste": 440,
    "data_freshness": "current_run"
  }
}
```

**Who computes it:** Individual audit skill (audit-aws, audit-datadog, audit-gcp, etc.)
**Who owns it:** The audit skill; never modified by cost-analysis
**When updated:** Every time the audit runs (along with regular findings)
**Cost:** Included in audit's own token budget (no extra API calls if already fetched)

### Layer 2: Master Cost-Analysis Skill (Scored 0-100)

**Purpose:** Aggregate, deduplicate, prioritize, and score cross-provider cost data.

**Where:** Dedicated `cost-analysis.json` with scorecard, history, and recommendations.

**Reads from:**
1. Individual audit `findings.json:cost_section` (already computed)
2. `correlation.json` (dedup overlaps — "Grafana already tracks this, don't double-count AWS cost")
3. `cost-analysis.jsonl` history (skip re-runs within 24h, compute delta)
4. `business_context` (sort by cost_sensitivity: high → ROI first, low → impact first)

**Writes:**
- `cost-analysis.json` (today's scored, deduplicated report)
- `cost-analysis.jsonl` appended with one line (score trend over time)

---

## History & Skip Logic

### cost-analysis.jsonl

Same pattern as `findings.jsonl`, but for cost trends:

```jsonl
{"date":"2026-07-29","overall":38,"monthly_waste":520,"identifiable_waste":440,"state":"trend_rising"}
{"date":"2026-07-30","overall":42,"monthly_waste":500,"identifiable_waste":410,"state":"improving"}
```

### Skip Logic: When to Re-Run Cost Analysis

**Run cost-analysis if:**
- `cost-analysis.jsonl` does not exist (first run)
- Last entry in `cost-analysis.jsonl` is >24h old
- Any new audit findings since last cost-analysis run (check timestamps)
- User explicitly runs `/scoutflo:cost-analysis --force`

**Skip cost-analysis if:**
- Last entry is <24h old AND no new audit findings added
- Log: "Cost analysis up-to-date (last run 2h ago). Run with --force to refresh."

### Skip Detection Algorithm

```bash
cost_analysis_should_skip() {
  cost_history_file="$AUDITS_DIR/cost-analysis.jsonl"
  
  # No history = first run
  [ ! -f "$cost_history_file" ] && return 1
  
  # Get timestamp of last cost-analysis run
  last_run=$(tail -1 "$cost_history_file" | jq -r '.date')
  last_run_epoch=$(date -d "$last_run" +%s)
  now_epoch=$(date +%s)
  hours_ago=$(( (now_epoch - last_run_epoch) / 3600 ))
  
  # Skip if <24h old
  if [ "$hours_ago" -lt 24 ]; then
    # Check if any NEW audit findings since last cost-analysis
    new_findings=$(find "$AUDITS_DIR" -name "findings.json" \
      -newer "$cost_history_file" | wc -l)
    
    if [ "$new_findings" -eq 0 ]; then
      echo "Cost analysis is current (${hours_ago}h old, no new findings)"
      return 0  # SKIP
    fi
  fi
  
  return 1  # RUN
}
```

---

## Deduplication: Individual Costs + Correlation

### Problem: Counting AWS Waste Twice

Scenario:
- AWS audit finds: "stopped instances = $320/mo"
- Cost-analysis sees same via AWS Cost Explorer API = "$320/mo"
- **Without dedup:** $320 + $320 = $640 (wrong)

### Solution: Use Individual Audit Cost Sections + Correlation

```bash
cost_analysis_aggregate() {
  audit_date="$1"
  
  # Collect cost_section from each individual audit
  for audit_report in "$AUDITS_DIR"/*/"$audit_date"/findings.json; do
    [ -e "$audit_report" ] || continue
    target=$(jq -r '.target' "$audit_report")
    
    # Extract cost section (already computed, fresh)
    cost=$(jq '.cost_section // {}' "$audit_report")
    
    # Add target metadata
    echo "$cost" | jq --arg target "$target" '. + {source_target: $target}'
  done | jq -s 'add'  # Merge all cost sections
  
  # Apply correlation deduplication
  # For each cost finding, check correlation.json for overlaps
  # If AWS-COST-001 "stopped instances" overlaps with GRAFANA finding,
  # mark as "already detected by Grafana, count once"
}
```

### Dedup Logic in cost-analysis.json

```json
{
  "findings": [
    {
      "id": "COST-AWS-001",
      "title": "Stopped instances not terminated",
      "monthly_waste": 320,
      "source": "aws",
      "deduplicated": false,
      "reasoning": "AWS only cost-finding for this resource"
    },
    {
      "id": "COST-GCP-002",
      "title": "Unused disk snapshots",
      "monthly_waste": 45,
      "source": "gcp",
      "deduplicated": true,
      "reasoning": "Overlaps with COST-AWS-003 (same resource, counted in AWS)"
    }
  ]
}
```

---

## Scoring with History

### Dynamic Scoring (0-100)

```
Score = 100 - (identifiable_waste_percent * 60) - (trend_direction * 20) - (overlaps * 10) - (no_action_items * 10)

identifiable_waste_percent = identifiable_waste / total_cloud_spend
trend_direction = current - previous (rising = -5, stable = 0, improving = +5)
overlaps = duplicate findings across audits
no_action_items = cost findings with <5 min fix time
```

### History Trend Line

```json
{
  "trend_last_5_runs": [
    {"date": "2026-07-26", "overall": 35, "monthly_waste": 580},
    {"date": "2026-07-27", "overall": 38, "monthly_waste": 550},
    {"date": "2026-07-28", "overall": 40, "monthly_waste": 520},
    {"date": "2026-07-29", "overall": 38, "monthly_waste": 540},  // regression
    {"date": "2026-07-30", "overall": 42, "monthly_waste": 500}   // recovery
  ],
  "direction": "improving",
  "momentum": "+4 points this week"
}
```

---

## Delta Computation: What Changed?

### New Cost Findings

```bash
cost_analysis_compute_delta() {
  prev_cost_file="$AUDITS_DIR/cost-analysis/$(date -d yesterday +%Y-%m-%d)/findings.json"
  curr_cost_file="$AUDITS_DIR/cost-analysis/$(date +%Y-%m-%d)/findings.json"
  
  # New findings: in current but not in previous
  jq -n \
    --slurpfile prev "$([ -f "$prev_cost_file" ] && echo "$prev_cost_file" || echo /dev/null)" \
    --slurpfile curr "$curr_cost_file" \
    '
    (if $prev | length > 0 then $prev[0].findings else [] end) as $prev_findings |
    $curr[0].findings as $curr_findings |
    {
      new: ($curr_findings - $prev_findings),
      resolved: ($prev_findings - $curr_findings),
      unchanged: ($curr_findings | map(select(. as $c | $prev_findings | index($c)))),
      delta_waste: (($curr_findings | map(.monthly_waste) | add) - ($prev_findings | map(.monthly_waste) | add))
    }
    '
}
```

### Example Output

```json
{
  "delta": {
    "monthly_waste_change": "-$40 (from $540 to $500)",
    "new_findings": 2,
    "resolved_findings": 3,
    "status": "improving"
  }
}
```

---

## API Call Efficiency

### No Double API Calls

| Data Source | Who calls API | When | Re-use in cost-analysis |
|---|---|---|---|
| AWS Cost Explorer | audit-aws | Every audit run | Read from findings.json:cost_section |
| GCP Cost Management | audit-gcp | Every audit run | Read from findings.json:cost_section |
| Datadog usage API | audit-datadog | Every audit run | Read from findings.json:cost_section |
| Correlation data | correlation-engine | After audit-all | Read from correlation.json |
| Business context | N/A (local) | On-demand | Read from topology.json |

**Result:** cost-analysis makes **ZERO additional API calls** if run within 24h of audits.

---

## Practical Example: Weekly Audit Cycle

```
Monday 9am:  Run /scoutflo:audit-all
  └─ AWS audit: AWS Cost Explorer → findings.json:cost_section: AWS-only findings
  └─ GCP audit: GCP Cost Management → findings.json:cost_section: GCP-only findings
  └─ Correlation engine: detects overlaps
  └─ Cost-analysis: aggregates, dedupes, scores (0 extra API calls)
  └─ Result: cost-analysis.json + cost-analysis.jsonl appended

Tuesday 2pm: Run /scoutflo:audit-all again
  └─ Cost-analysis skips (only 29h old, no new audits)
  └─ Log: "Cost analysis up-to-date (last run 29h ago)"

Wednesday 9am: Run /scoutflo:audit-all + cost analysis
  └─ AWS audit finds NEW waste (stopped instances grew)
  └─ Cost-analysis detects change, re-runs
  └─ Computes delta: "AWS waste +$60 this week"
  └─ Updates score: 42 → 38 (regressed)
  └─ Appends to cost-analysis.jsonl

Friday 5pm: User asks for fresh cost report
  └─ Run /scoutflo:cost-analysis --force
  └─ Skips 24h check, re-aggregates all audits
```

---

## Implementation Checklist for v0.1.67

- [ ] cost-analysis.sh reads individual audit `findings.json:cost_section` (no API calls)
- [ ] Deduplication logic: if finding X overlaps with Y, count once
- [ ] History file: `cost-analysis.jsonl` with date, overall, monthly_waste, state
- [ ] Skip detection: skip if <24h AND no new findings
- [ ] Delta computation: new vs resolved vs unchanged
- [ ] Scoring: 0-100 based on waste % + trend + overlaps
- [ ] Correlation integration: reference correlation.json for overlaps
- [ ] Business context: sort by cost_sensitivity (high=ROI, low=impact)
- [ ] Test: cost-analysis on full CoinDCX estate (real AWS Cost Explorer data)
- [ ] Measure: token efficiency (0 extra API calls if <24h old)
- [ ] Document: how to re-run with --force, how history works, when it skips
