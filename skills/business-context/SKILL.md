---
name: business-context
description: Capture team, environment, SLA, and cost metadata. Saves to topology.json for use by audit and setup skills to adjust finding severity and prioritization. Use once per workspace to establish context; subsequent audits read and reuse the saved metadata.
---

# Business Context: Team & Environment Metadata

Capture business context once, reuse across all audits. Audit skills adjust finding severity per environment (staging gaps are lower priority); setup skills use this to prioritize remediation for critical services.

## Prerequisites

| Requirement | Check |
| --- | --- |
| `jq` | Installed |
| `~/.scoutflo/topology.json` | Created automatically if missing |

## Interactive Prompts

```
Team name (e.g., platform-engineering): 
Environment (staging|production|dr|dev): 
Uptime SLA (95.0-99.99%): 
Cost sensitivity (low|medium|high): 
Billing owner (email): 
```

All fields required. Email must be valid format.

## Saved Schema

Context is saved to `~/.scoutflo/topology.json`:

```json
{
  "business_context": {
    "team": "platform-engineering",
    "environment": "production",
    "uptime_sla": 99.9,
    "cost_sensitivity": "high",
    "billing_owner": "jane@example.com",
    "captured_at": "2026-07-30T17:15:30Z"
  }
}
```

## Usage by Audit Skills

**Severity adjustment:**
- Staging environment → staging-only gaps marked as `low` severity
- Production environment → all gaps are real issues (normal priority)

**Routing:**
- Setup skills read `cost_sensitivity` to prioritize high-cost fixes first
- Topology-guided setup uses `team` to find relevant runbooks/escalation channels

## Standalone Usage

```bash
/scoutflo:business-context
```

Prompts for team/environment/SLA/cost/billing, saves to topology.json.

## Reset / Update

```bash
/scoutflo:business-context --update
```

Prompts again and overwrites saved values. Useful if environment or team changes.

## Integration

- **Called by** `/scoutflo:audit-all` before running audits (if not already captured)
- **Output** `~/.scoutflo/topology.json:business_context` (persisted across sessions)
- **Read by** every audit skill to adjust finding severity

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Context captured and saved successfully |
| 1 | User cancelled at prompt |
| 2 | Validation failed (invalid email, invalid environment, SLA out of range) |

---

**v0.1.65+**
