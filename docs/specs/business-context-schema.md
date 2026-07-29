# Business Context Skill Specification

**Internal Spec Only — Local Development**

Skill: `/scoutflo:business-context`

---

## Purpose

Capture organizational context (team, environment, SLAs, cost sensitivity) once, use across all audits and setups.

Stored in `topology.json:business_context` and persisted across sessions.

---

## Skill Behavior

### Prompt Flow

```
/scoutflo:business-context

→ "Team/Department?"
  User: "payments-team"

→ "Environment?"
  User: "production"

→ "SLA Uptime Target (e.g., 99.9%, 99.99%)?"
  User: "99.99%"

→ "Cost Sensitivity (low, medium, high)?"
  User: "high"

→ "Billing Owner Email?"
  User: "payments-team-lead@company.com"

→ "Critical Dependencies (comma-separated service names)?"
  User: "api-gateway, checkout-svc"

→ Saved to topology.json
  [saved] Business context updated.
  
[user exits]
```

---

## Saved Schema (topology.json)

```json
{
  "business_context": {
    "team": "payments-team",
    "environment": "production",
    "sla": {
      "uptime_percent": 99.99,
      "response_time_ms": 200,
      "error_rate_percent": 0.01
    },
    "cost_sensitivity": "high",
    "billing_owner": "payments-team-lead@company.com",
    "critical_dependencies": [
      "api-gateway",
      "checkout-svc"
    ],
    "updated_at": "2026-07-30T14:30:00Z",
    "notes": "PCI-DSS compliance required"
  }
}
```

---

## Field Reference

| Field | Type | Meaning | Constraints |
|-------|------|---------|-----------|
| `team` | string | Team/department name | Required, alphanumeric + hyphens |
| `environment` | string | Deployment environment | One of: `staging`, `production`, `dr`, `dev` |
| `sla.uptime_percent` | float | Target uptime SLA | 95.0 - 99.99 |
| `sla.response_time_ms` | integer | Target p99 latency | > 0 |
| `sla.error_rate_percent` | float | Target error rate | 0.0 - 1.0 |
| `cost_sensitivity` | string | Cost priority | One of: `low`, `medium`, `high` |
| `billing_owner` | string | Contact email | Valid email format |
| `critical_dependencies` | array | Critical downstream services | List of service names |
| `updated_at` | ISO timestamp | When context was last updated | Auto-generated |
| `notes` | string | Free-text notes (compliance, etc.) | Optional |

---

## How Audit Skills Use This

### Severity Adjustment (Business Context Filtering)

```javascript
// audit-aws.sh reads business_context

if (business_context.environment === "staging") {
    if (finding_title.includes("HTTPS Not Enforced")) {
        // Known staging-only gap
        finding.severity_original = "high"
        finding.severity_adjusted = "low"
        finding.reason = "Staging environment, intentional"
        finding.wontfix = true
    }
}

if (business_context.sla.uptime_percent === "99.99%") {
    if (finding.impacts_availability) {
        // Stricter SLA means higher severity
        finding.severity_adjusted = upgrade_severity(finding.severity_adjusted)
    }
}

if (business_context.cost_sensitivity === "high") {
    if (finding.solution.monthly_cost_saving > 100) {
        // Highlight cost-saving fixes
        finding.cost_impact = "high"
        finding.priority_boost = true
    }
}
```

### Service Relationship Context

```javascript
// setup-aws.sh reads critical_dependencies

critical_deps = business_context.critical_dependencies
// ["api-gateway", "checkout-svc"]

for (each finding) {
    if (finding.service in critical_deps) {
        finding.criticality = "critical"
        finding.auto_fix_approval = "required"  // Don't fix without asking
    } else {
        finding.criticality = "standard"
        finding.auto_fix_approval = "optional"  // Can auto-fix
    }
}
```

---

## How Setup Skills Use This

### Topology-Guided Setup

```bash
/scoutflo:setup-aws --finding AWS-023 --topology-guided

→ Read business_context.critical_dependencies
→ Find AWS-023 affects: "payment-svc"
→ Is "payment-svc" critical?
  YES → "Critical service. Proceed with dry-run first? (y/n)"
  NO → "Non-critical. Auto-fixing with 15K tokens saved."
```

### Cost-Aware Setup

```bash
/scoutflo:cost-analysis

→ For each finding, show:
  - monthly_cost_save
  - monthly_tokens_to_fix
  - roi = cost_save / tokens_to_fix
  
→ If cost_sensitivity = "high":
  Sort by ROI descending (highest savings first)
```

---

## Update Behavior

### First Run (No Existing Context)

```bash
/scoutflo:checkpoint

→ If business_context not in topology.json:
    ask: "Run /scoutflo:business-context first? (y/n)"
    if yes:
        spawn /scoutflo:business-context
        wait for completion
    if no:
        use defaults (production, 99.9% SLA, medium cost_sensitivity)
```

### Existing Context (Update)

```bash
/scoutflo:business-context --update

→ Load current business_context from topology.json
→ Show current values
→ Prompt: "Update <field>? (press enter to skip)"
→ Only update changed fields
→ Preserve team, environment (won't change mid-audit)
```

### Validation

```bash
// Before saving, validate:

if team.length < 1:
    error: "Team name required"

if environment not in ["staging", "production", "dr", "dev"]:
    error: "Invalid environment"

if sla.uptime_percent < 95 or > 99.99:
    error: "SLA must be 95.0 - 99.99"

if cost_sensitivity not in ["low", "medium", "high"]:
    error: "Cost sensitivity must be low/medium/high"

if billing_owner doesn't match email regex:
    error: "Billing owner must be valid email"

// If all valid:
save to topology.json
log: "[saved] Business context updated for payments-team"
```

---

## Examples

### Example 1: Production Critical Service

```json
{
  "team": "payments-team",
  "environment": "production",
  "sla": {
    "uptime_percent": 99.99,
    "response_time_ms": 100,
    "error_rate_percent": 0.001
  },
  "cost_sensitivity": "high",
  "billing_owner": "payments-lead@company.com",
  "critical_dependencies": [
    "api-gateway",
    "checkout-svc",
    "payment-processor"
  ],
  "updated_at": "2026-07-30T14:30:00Z",
  "notes": "PCI-DSS compliance required. No downtime tolerance."
}
```

**Impact on audits:**
- High severity for availability-related findings
- Cost-saving findings get priority boost
- Critical dependencies won't auto-fix without approval

---

### Example 2: Staging Low Priority

```json
{
  "team": "data-team",
  "environment": "staging",
  "sla": {
    "uptime_percent": 95.0,
    "response_time_ms": 500,
    "error_rate_percent": 0.1
  },
  "cost_sensitivity": "low",
  "billing_owner": "data-lead@company.com",
  "critical_dependencies": [],
  "updated_at": "2026-07-30T14:30:00Z",
  "notes": "Non-production. Can be experimental."
}
```

**Impact on audits:**
- HTTPS/cert findings marked as wontfix (staging testing)
- All findings can auto-fix
- Cost-saving findings deprioritized (staging spend not tracked)

---

### Example 3: Disaster Recovery (Read-Only)

```json
{
  "team": "platform-sre",
  "environment": "dr",
  "sla": {
    "uptime_percent": 99.5,
    "response_time_ms": 1000,
    "error_rate_percent": 0.05
  },
  "cost_sensitivity": "medium",
  "billing_owner": "sre-oncall@company.com",
  "critical_dependencies": [
    "api-gateway",
    "auth-svc",
    "payment-svc"
  ],
  "updated_at": "2026-07-30T14:30:00Z",
  "notes": "DR environment. Read-only access only. Setup-* skills blocked."
}
```

**Impact on audits:**
- All setup skills read: "DR environment detected. Dry-run mode only."
- Fix recommendations made, but not auto-applied
- Users get full audit results for planning

---

## Testing

### Unit Tests

```bash
test_business_context_save:
  - Run /scoutflo:business-context
  - Enter: payments-team, production, 99.99, high, email@company.com
  - Assert topology.json:business_context contains all fields
  - Assert updated_at timestamp set

test_business_context_load:
  - Create topology.json with business_context
  - Run /scoutflo:checkpoint
  - Assert business context loaded
  - Assert severity adjustments applied (staging gaps marked low)

test_severity_adjustment:
  - business_context.environment = staging
  - Finding: "HTTPS Not Enforced"
  - Assert severity_adjusted = low
  - Assert wontfix = true

test_cost_sensitivity:
  - business_context.cost_sensitivity = high
  - Finding: "Stopped EC2 instances = $200/month savings"
  - Assert cost_impact = high
  - Assert priority_boost = true

test_critical_dependency:
  - business_context.critical_dependencies = ["payment-svc"]
  - Finding affects payment-svc
  - Assert criticality = critical
  - Assert auto_fix_approval = required

test_validation:
  - Invalid email → error
  - Invalid environment → error
  - Invalid SLA → error
  - Valid input → saved
```

---

## Notes for Implementation

1. **Persistence:** Save to topology.json, not separate file
2. **Backward compat:** If business_context missing, use defaults (production, 99.9%, medium sensitivity)
3. **Propagation:** All audit skills must read business_context before generating findings
4. **Update flow:** `/scoutflo:business-context --update` to change mid-session
5. **Validation:** Validate all fields before saving (no partial saves)

---

**This is internal spec. Not shipped to customers.**

