---
name: topology-guided-setup
description: 'Internal harness library (v0.1.66+): an available helper a setup skill can source to make topology-aware fix decisions from correlation.json + business-context — detect redundant monitoring (skip or dedup), find cascade risks (fix root causes first), apply business context (critical services require approval, staging gaps intentional), estimate tokens, and suggest fix order. It exposes shell functions (topology_guided_get_recommendation, topology_guided_should_fix); it is a building block, not yet auto-invoked by the setup-* skills. Not a user-facing command.'
---

# Topology-Guided Setup

Internal helper **library** for setup skills. It provides shell functions a setup skill can source to make topology-aware fix decisions:
1. Check if the finding overlaps with others (skip redundant monitoring)
2. Detect cascade risks (fix root causes first)
3. Apply business context (critical services require approval)
4. Estimate tokens + suggest fix order

Not a user-facing skill. **Status:** this is an available building block (real, tested functions in `lib/`); the `setup-*` skills do not yet source it automatically. When a setup skill adopts it, it would look like the pattern below.

## How it works

### Intended integration (not yet wired into the setup-* skills)

A setup skill that adopts this library would source it and consult it per finding:
```bash
. "${CLAUDE_PLUGIN_ROOT}/skills/topology-guided-setup/lib/topology-guided-setup.sh"
recommendation=$(topology_guided_get_recommendation "AWS-023" "database-svc" "RDS Backup Not Enabled")
should_proceed=$(topology_guided_should_fix "AWS-023" "database-svc" "RDS Backup Not Enabled")
if [ $should_proceed -eq 0 ]; then
  proceed_with_fix
else
  echo "Skipping based on topology guidance"
  exit 0
fi
```

### Decision tree

```
Finding received: AWS-023 "RDS Backup Not Enabled" on database-svc

1. Is this finding in an OVERLAP?
   ├─ YES: "This also monitored by Grafana. Skip AWS duplicate?"
   └─ NO: Continue

2. Is this the ROOT CAUSE of cascades?
   ├─ YES: "Fix this first — prevents 3 downstream failures"
   └─ NO: Continue

3. Is this IMPACTED BY cascades?
   ├─ YES: "Wait for MySQL fix first"
   └─ NO: Continue

4. Is the service CRITICAL?
   ├─ YES: "Requires approval. Show changes first."
   └─ NO: "Can proceed. ~10K tokens, standard fix."
```

## Output types

### Overlap detected
```json
{
  "recommendation_type": "OVERLAP_DETECTED",
  "action": "SKIP_OR_DEDUP",
  "rationale": "AWS CloudWatch + Grafana both monitor payment-svc",
  "related": [{skill: "audit-grafana", finding_id: "GRAFANA-045"}],
  "tokens_saved": "50%+"
}
```

**Action:** Skip this fix (Grafana is primary), or remove AWS duplicate.

### Cascade root cause
```json
{
  "recommendation_type": "CASCADE_ROOT",
  "action": "FIX_FIRST_PRIORITY",
  "rationale": "Fix root cause prevents 3-step cascade",
  "prevents_failures": 3,
  "tokens_saved": "30%+"
}
```

**Action:** Fix this before anything else. Prevents MySQL crash → monitoring down → incidents undetected.

### Cascade impact
```json
{
  "recommendation_type": "CASCADE_IMPACT",
  "action": "WAIT_FOR_ROOT_FIX",
  "rationale": "This is cascading from MySQL master failure",
  "root_cause_to_fix": {"finding_id": "AWS-055", "title": "MySQL Master Unhealthy"},
  "fix_order": 2
}
```

**Action:** Wait for root cause (MySQL) to be fixed. This will resolve automatically.

### Critical service
```json
{
  "recommendation_type": "CRITICAL_SERVICE",
  "action": "REQUIRE_APPROVAL",
  "rationale": "Service is marked as business-critical",
  "approval_required": true,
  "suggested_flow": "1. Dry-run, 2. Show changes, 3. Get approval, 4. Apply"
}
```

**Action:** Require human approval. Suggested: dry-run → show changes → confirm → apply.

### Standard (can proceed)
```json
{
  "recommendation_type": "STANDARD",
  "action": "CAN_PROCEED",
  "rationale": "Non-critical service, standard fix flow",
  "tokens_estimated": 10000,
  "environment": "production"
}
```

**Action:** Proceed with fix. Estimated cost: ~$0.05 in tokens.

## Token savings example

**Without topology guidance:**
```
setup-aws fixes all 50 findings
├─ 10 are AWS CloudWatch (Grafana already alerts these) → wasted 5K tokens
├─ 3 are cascading from MySQL (would auto-resolve) → wasted 15K tokens
└─ Total wasted: 20K tokens ($0.10)
```

**With topology guidance:**
```
setup-aws fixes 37 findings (skips overlaps + cascades)
├─ Overlap detection: skip AWS duplicates → save 5K tokens
├─ Cascade detection: wait for root causes → save 15K tokens
└─ Token savings: 20K ($0.10) per run
```

On weekly audits: **$5.20/week saved** on token costs alone, plus faster fixes.

## Business context integration

### Staging environment
- Gaps marked `LOW` by audit (intentional)
- Setup skips automatically (no approval needed)
- Recommendation: "Non-prod; safe to skip"

### Production + critical service
- Recommendation: "Requires approval; show dry-run first"
- Approval flow: "OK to proceed? (y/n)"
- After approval: proceed with standard fix

### Cost sensitivity: high
- Include token estimate in recommendation
- Example: "10K tokens ≈ $0.05"
- Prioritize high-ROI fixes first

## Graceful degradation

If correlation.json not available:
- Fall back to "STANDARD" recommendation
- Still apply business context (critical/staging)
- Still estimate tokens
- Log: "correlation-engine not installed; using fallback"

## See also

- `/scoutflo:audit-all` — Phase 3.5: builds correlation.json
- `/scoutflo:business-context` — captures team/environment/criticality
- `/scoutflo:correlation-engine` — detects overlaps + cascades
