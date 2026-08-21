---
name: correlation-engine
description: 'Harness skill (run it directly, or let audit-all run it for you): after any audit(s) (audit-all, sequential, or targeted 2-3), builds correlation.json that detects redundant monitoring (AWS + Grafana monitoring same metric), cascade risks (A fails → B disabled → C undetected), and business context filtering (staging gaps marked intentional, critical services prioritized). Works incrementally with partial coverage. Run automatically by audit-all (Phase 3.5); its output is also consumed by rca and the topology-guided-setup helper.'
---

# Correlation Engine

After you run any audit (full audit-all, or sequential audits over days, or targeted 2-3 audits), the correlation engine analyzes findings across all skills to detect overlaps, cascade risks, and apply business context intelligence.

Output: `scoutflo-audits/correlation.json` — machine-readable deduplication + prioritization. It is written once at the audit-dir root (not under a per-date subdir); the per-audit `findings.json` files it reads are target-first (`<target>/<date>/findings.json`).

## How it works

### Scenario 1: Full audit-all run
```bash
/scoutflo:audit-all
→ 13 audit skills produce findings.json
→ correlation engine runs automatically
→ correlation.json written with all overlaps + cascades detected
```

### Scenario 2: Sequential audits over time
```text
Day 1: /scoutflo:audit-aws
→ AWS findings → correlation.json (v1)

Day 2: /scoutflo:audit-grafana
→ Grafana findings + existing AWS findings → correlation.json (v2, merged)
→ New overlaps detected: "AWS CloudWatch + Grafana rule both monitor payment-svc"

Day 3: /scoutflo:audit-sentry
→ Sentry findings + existing AWS + Grafana → correlation.json (v3, merged)
→ New cascade detected: "Sentry can't route alerts if AWS SNS is misconfigured"
```

### Scenario 3: Targeted 2-3 audits
```bash
/scoutflo:audit-aws /scoutflo:audit-grafana /scoutflo:audit-kubernetes
→ Only these 3 audits run
→ Correlation engine detects overlaps + cascades within this subset
→ Cost-aware: "You only need to fix K8s network policy (Grafana rules already cover networking)"
```

## What correlation.json contains

### Overlaps: Redundant Monitoring

```json
{
  "overlap_id": "OVL-001",
  "type": "redundant_monitoring",
  "services": ["payment-svc"],
  "findings": [
    {
      "skill": "audit-aws",
      "finding_id": "AWS-023",
      "title": "CloudWatch Alarms Not Configured"
    },
    {
      "skill": "audit-grafana",
      "finding_id": "GRAFANA-045",
      "title": "Alert Rule Missing for Payment Service"
    }
  ],
  "redundancy_level": "full",
  "recommendation": "Keep Grafana as primary (lower noise), remove CloudWatch duplicate"
}
```

**Interpretation:** Both AWS and Grafana are alerting on the same metric. You only need one. Keeping the lower-noise source (Grafana) and removing AWS reduces alert fatigue.

### Cascades: Dependency Chains

```json
{
  "cascade_id": "CASC-001",
  "chain_length": 3,
  "root_cause": {
    "finding_id": "AWS-055",
    "title": "MySQL Master Instance Unhealthy",
    "service": "database-svc",
    "impact": "Database unavailable"
  },
  "effects": [
    {
      "step": 1,
      "finding_id": "GRAFANA-022",
      "title": "Alert Rule Disabled",
      "condition": "if root_cause happens"
    },
    {
      "step": 2,
      "finding_id": "PAGERDUTY-008",
      "title": "Incident Cannot Be Created",
      "condition": "if monitoring is down"
    }
  ]
}
```

**Interpretation:** Fixing the root cause (MySQL) prevents cascading failures. Fix order matters: prioritize root-cause findings.

## Business Context Applied

If you ran `/scoutflo:business-context`, correlation engine uses it:

| Setting | Effect on Correlation |
|---------|----------------------|
| `environment: "staging"` | Staging gaps marked LOW (intentional). Prod gaps stay CRITICAL. |
| `critical_dependencies: ["payment-svc", "checkout-svc"]` | Findings on these services bubble to top. Setup uses "approve before fix" mode. |
| `cost_sensitivity: "high"` | Overlaps sorted by cost ROI (most expensive redundancy first). |

### Safe Defaults (if business-context not set)

If you've never run `/scoutflo:business-context`, correlation engine uses:
- `environment: "production"` (conservative; all issues real)
- `cost_sensitivity: "medium"` (balanced prioritization)
- `critical_dependencies: []` (no special treatment)
- `sla: 99.9%` (industry standard)

**Effect:** Findings severity NOT adjusted. Running business-context later will re-weight findings on next audit.

## Integration with Topology-Guided Setup

After correlation.json is written:

```bash
/scoutflo:setup-aws --finding AWS-023 --topology-guided
```

Setup skill reads correlation.json:
1. Find AWS-023 in overlaps → "This overlaps with GRAFANA-045"
2. Check cascades → "Fixing this prevents downstream Sentry failures"
3. Read business_context → "payment-svc is critical; dry-run first"
4. Calculate tokens → "15K tokens, $0.08. OK to proceed? (y/n)"

## Output Structure

```
scoutflo-audits/
  correlation.json       ← machine-readable overlaps + cascades (audit-dir root)
  aws/
    <date>/
      findings.json
      report.md
  grafana/
    <date>/
      findings.json
      report.md
  ...
```

correlation.json schema (exactly what the lib writes):

```json
{
  "version": "2.0",
  "generated_at": "2026-07-30T14:30:00Z",
  "audit_date": "2026-07-30",
  "total_findings_raw": 87,
  "total_findings_deduplicated": 42,
  "total_overlaps_detected": 23,
  "total_cascades_detected": 5,
  "overlaps": [ {...} ],
  "cascades": [ {...} ],
  "method": "same-affected-service overlap grouping + database-to-alerting cascade heuristic; every referenced finding_id exists in this run"
}
```

There is no `confidence` or `business_context_applied` field — the engine does not assign a confidence percentage; it groups by shared `affected` service and joins cascades on shared resources, and `method` states exactly how.

## When correlation engine runs

**Automatic:**
- After `/scoutflo:audit-all` completes
- After `/scoutflo:audit-<service>` with existing earlier findings

**Manual (if needed):**
```bash
# Force re-correlate all findings from date
correlation_run 2026-07-30
```

## Limitations

- **Overlaps** are exact: two findings are grouped only when they name the same `affected` service, so a grouped overlap is a real shared-resource match, not a guess. The engine assigns no confidence percentage.
- **Cascade detection uses heuristics** (database → monitoring → incident response) and is not exhaustive.
- **Cross-date correlations** (audit-aws on day 1 vs audit-grafana on day 5) still work but skip time-based cascade detection.
- Requires `jq` on PATH.
- Every referenced `finding_id` in the output exists in the current run's findings (no invented references) — that is the grounding guarantee, verified by the `method` note above.

## See also

- `/scoutflo:start` — orientation + skill catalog
- `/scoutflo:setup-aws --finding <ID> --topology-guided` — use correlation to guide fixes
- `/scoutflo:business-context` — metadata that weights correlation prioritization
