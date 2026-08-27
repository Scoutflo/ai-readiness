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
  "overlap_id": "OVL-payment-svc",
  "type": "redundant_monitoring",
  "service": "payment-svc",
  "targets": ["aws", "grafana"],
  "findings": [
    {
      "target": "aws",
      "finding_id": "AWS-023",
      "title": "CloudWatch Alarms Not Configured",
      "severity": "high"
    },
    {
      "target": "grafana",
      "finding_id": "GRAFANA-045",
      "title": "Alert Rule Missing for Payment Service",
      "severity": "medium"
    }
  ],
  "recommendation": "Multiple stacks report findings against payment-svc; review whether the monitoring overlaps and consolidate the paging path"
}
```

The `overlap_id` is `OVL-<service>` and `service` is the single shared affected service the group is keyed on; `targets` lists the distinct stacks that named it. The `recommendation` is a fixed template built from the service name.

**Interpretation:** Both stacks report findings against the same service — candidate redundant monitoring. Review whether they overlap and consolidate onto one paging path to cut alert fatigue.

### Cascades: Dependency Chains

```json
{
  "cascade_id": "CASC-AWS-055",
  "root_cause": {
    "finding_id": "AWS-055",
    "title": "MySQL Master Instance Unhealthy",
    "target": "aws",
    "shared_resources": ["mysql-primary"]
  },
  "effects": [
    {
      "finding_id": "GRAFANA-022",
      "title": "Alert Rule Disabled",
      "target": "grafana",
      "condition": "shares a resource with the datastore finding; verify its signal survives if that datastore degrades"
    },
    {
      "finding_id": "PAGERDUTY-008",
      "title": "Incident Cannot Be Created",
      "target": "pagerduty",
      "condition": "shares a resource with the datastore finding; verify its signal survives if that datastore degrades"
    }
  ]
}
```

The `cascade_id` is `CASC-<root finding id>`. `shared_resources` are the concrete affected tokens the root names; each effect is emitted only because it shares one of those tokens (a real join, not a keyword guess), so `condition` is the same fixed sentence on every effect. There is no `chain_length`, `service`, `impact`, or `step` field.

**Interpretation:** Fixing the root cause (MySQL) prevents cascading failures. Fix order matters: prioritize root-cause findings.

## Business Context Applied

correlation.json is **context-neutral**. It records overlaps, cascades, and the
dedup counters — nothing more — and never embeds business-context weighting.

If you ran `/scoutflo:business-context`, the engine *does* read it (via
`correlation_load_context`, which loads `environment`, `cost_sensitivity`, and
`critical_dependencies`) and computes an advisory `context_note` on each finding
during the run: staging low/medium gaps are noted as possibly intentional, and
findings that touch a `critical_dependencies` service are flagged as
business-critical. But that note is **not persisted** — the overlaps and cascades
written out are rebuilt from their own member objects (`target`, `finding_id`,
`title`, `severity`), and the annotated findings array is discarded. The engine
also never changes a finding's audit-owned `severity`.

So business-context weighting is applied by the **downstream consumers** that read
both correlation.json and the business-context SSOT, not by the engine itself:

| Setting | Where it takes effect |
|---------|----------------------|
| `environment: "staging"` | `rca` uses it to calibrate severity language (a staging-only chain is real but not an incident). |
| `critical_dependencies: [...]` | `rca` leads with and raises urgency for findings on these services. |
| `cost_sensitivity: "high"` | `cost-analysis` records it verbatim; savings are ranked by provider-native monthly figure (the sensitivity value does not re-sort). |

### Safe Defaults (if business-context not set)

If you've never run `/scoutflo:business-context`, `correlation_load_context` falls
back to:
- `environment: "production"` (conservative; all issues real)
- `cost_sensitivity: "medium"` (balanced prioritization)
- `critical_dependencies: []` (no special treatment)

**Effect:** No `context_note` is added, and correlation.json is identical either
way — it is context-neutral regardless. Business context only changes how the
downstream consumers (`rca`, `cost-analysis`) present the same overlaps and
cascades.

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
