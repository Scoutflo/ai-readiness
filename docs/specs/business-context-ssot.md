# Business Context SSOT — v0.1.67+

**Single Source of Truth for customer-specific operational guardrails, SLAs, SLOs, exclusions, and custom rules.**

This document defines how customers provide their business context during setup, and how all Scoutflo skills read and apply it.

---

## What is Business Context SSOT?

Like `CLAUDE.md` or `AGENTS.md` in other systems, customers create **`business_context.md`** in their audit root directory:

```bash
~/.scoutflo/business_context.md
```

This file contains:
- **SLAs / SLOs:** Service-level agreements and objectives
- **Environment rules:** Production vs staging vs dev distinctions
- **Cost sensitivity:** How aggressively to optimize (high=ROI-first, low=impact-first)
- **Region/Account exclusions:** Which regions/accounts to avoid or never modify
- **Resource restrictions:** Which resources are off-limits
- **Risky operations:** What NOT to do (e.g., "never auto-terminate instances in prod")
- **Token consumption rules:** Acceptable budget per audit cycle
- **Custom runbooks:** Team-specific procedures, approval gates, escalation paths

---

## Example: business_context.md

```markdown
# Business Context — Production Scoutflo Environment

## Environment

- **Name:** Production
- **Stage:** prod
- **Region Strategy:** Multi-region (us-west-2 primary, eu-central-1 secondary)
- **Risk Level:** High (customer-facing services)
- **Approval Gate:** All changes require ops team approval

## SLAs / SLOs

| Service | SLA | SLO (Error Budget) |
|---|---|---|
| payment-svc | 99.99% | 4m32s/month downtime allowed |
| api-gateway | 99.9% | 43m20s/month downtime allowed |
| database-svc | 99.95% | 21m36s/month downtime allowed |
| internal-tools | 95% | 7h20m/month downtime allowed |

## Cost Sensitivity

- **Primary:** High (every $100/month waste = $1200/year)
- **Strategy:** ROI-first (highest annual savings recommendations first)
- **Budget:** $500/month identifiable waste acceptable; >$500 requires escalation

## Critical Services (Never Auto-Fix)

Require explicit approval before ANY changes:
- `payment-svc` (revenue impact)
- `api-gateway` (customer-facing)
- `database-svc` (data integrity risk)

Staging equivalents (`payment-svc-staging`, etc) require team notification only.

## Exclusions (Never Audit or Modify)

### Regions
- `cn-*` (China regions, legal/compliance)
- `us-gov-*` (Government regions, restricted)

### Accounts
- `sandbox` (development testing, ignore)
- `legacy-prod` (being decommissioned, read-only only)

### Services
- `deprecated-service` (sunset in Q3 2026, ignore cost findings)
- `vendor-managed-*` (third-party SaaS, ignore)

### Resources
- EC2 instances matching tag `cost-allocation:shared-lab` (shared testing, ignore)
- RDS databases in `legacy-db-subnet` (temporary, being migrated)
- VPCs matching `vpc-experimental-*` (sandbox VPCs, ignore)

## Risky Operations (Blocked by Default)

These operations REQUIRE escalation to ops team:

1. **Terminate EC2 instances in production** → Approval from ops manager
2. **Delete RDS snapshots** → Requires 7-day audit trail check first
3. **Remove Security Group ingress rules** → Requires network team approval
4. **Modify IAM roles on prod services** → Requires security team approval
5. **Auto-fix alerts without dry-run** → Requires dry-run output review + approval

## Token Consumption Rules

- **Max per audit cycle:** 50K tokens/week for unchanged estates
- **Threshold:** If approaching 50K, audit skips non-critical services and focuses on critical-services-only
- **Escalation:** Runs >75K tokens/week require escalation

## Audit Strategy

### Scheduling
- **Frequency:** Daily (9am UTC) during business hours only
- **Skip Windows:** 
  - Fridays 4pm-Sunday midnight (maintenance window)
  - During deployments (check Slack #deployments channel)
- **On-Demand:** Available anytime with `--force` flag

### Scope Selection
- **Default:** Audit all regions + all services
- **Cost-focused runs:** Audit only critical-services (Wed/Sat, cost optimization focus)
- **Compliance runs:** Audit security groups + IAM every Monday (compliance audit)

### Approval Requirements
- **Findings in critical services:** Require ops team approval before fix
- **Findings in staging:** Team notification only (Slack #infrastructure)
- **Findings in deprecated services:** Ignore and document as "out-of-scope"

## Notification Preferences

- **Success:** Silent (no notification)
- **Skip (unchanged):** Silent
- **New findings in prod:** Slack notification + team email
- **Critical service findings:** PagerDuty alert + ops approval gate
- **Deprecated service findings:** Log only (no notification)

## Custom Runbooks (Team Procedures)

### Payment Service Outage Procedure
If payment-svc appears in findings with critical severity:
1. Alert ops team immediately
2. Wait for approval before any changes
3. If fix approved: dry-run first, show output to team, require 2 approvals before apply
4. Post-fix: run compliance audit to verify no side effects

### Cascade Failure Handling
If correlation engine detects cascade (e.g., database crash → monitoring down → backups fail):
1. Fix root cause FIRST (database issue)
2. DO NOT independently fix cascade effects
3. Wait 15 minutes for cascade effects to auto-resolve
4. If effects persist after 15min, escalate to database team

## Compliance & Audit

- **Audit trail:** All changes logged to audit.log in ~/.scoutflo/
- **Compliance:** All changes subject to monthly security review
- **Retention:** Keep audit logs for 90 days minimum
- **Reporting:** Monthly cost analysis sent to finance team

---

## How Skills Use business_context.md

Every Scoutflo skill **reads and applies** this file:

### Step 1: Load in Doctor Gate
```bash
load_business_context() {
  if [ -f "$HOME/.scoutflo/business_context.md" ]; then
    # Parse markdown sections into ENV vars
    COST_SENSITIVITY=$(grep "^- \*\*Primary:\*\*" business_context.md | cut -d' ' -f3)
    CRITICAL_SERVICES=$(grep "^- \`" business_context.md | grep -A10 "Critical Services" | cut -d'`' -f2)
    EXCLUDED_REGIONS=$(grep "^- \`" business_context.md | grep -A5 "Regions" | cut -d'`' -f2)
  fi
}
```

### Step 2: Check Guardrails Before Action
```bash
check_guardrails() {
  SERVICE="$1"
  ACTION="$2"  # e.g., "terminate-instance", "delete-snapshot"
  
  # If service is critical AND action is risky → require approval
  if echo "$CRITICAL_SERVICES" | grep -q "$SERVICE"; then
    if echo "$RISKY_OPERATIONS" | grep -q "$ACTION"; then
      echo "⚠️  $ACTION on $SERVICE requires approval"
      ask_for_approval "$SERVICE" "$ACTION"
    fi
  fi
  
  # If region excluded → skip
  if echo "$EXCLUDED_REGIONS" | grep -q "$REGION"; then
    echo "⏭️  Skipping excluded region: $REGION"
    return 1  # SKIP
  fi
}
```

### Step 3: Apply Context to Findings
```bash
apply_context_to_findings() {
  # If finding in deprecated-service → mark as out-of-scope
  # If finding in staging → change severity to low
  # If finding in critical-service → escalate severity to high
}
```

---

## During `/scoutflo:connect`: Offer Interactive Capture

```bash
# Step 1: Ask if they want to provide business context
read -p "Provide business context file? (y/n): " answer
if [ "$answer" = "y" ]; then
  echo "Options:"
  echo "  1. Paste markdown content (ctrl+D to end)"
  echo "  2. Provide file path"
  read -p "Choose (1 or 2): " choice
  
  if [ "$choice" = "1" ]; then
    # Capture pasted markdown
    cat > ~/.scoutflo/business_context.md
  else
    # Copy file
    read -p "File path: " filepath
    cp "$filepath" ~/.scoutflo/business_context.md
  fi
fi
```

---

## Validation: business_context.md Schema

When a new business_context.md is created, validate:

```bash
validate_business_context() {
  [ -f ~/.scoutflo/business_context.md ] || return 1
  
  # Check required sections
  grep -q "^## Environment" || { echo "Missing: ## Environment"; return 1; }
  grep -q "^## Cost Sensitivity" || { echo "Missing: ## Cost Sensitivity"; return 1; }
  grep -q "^## Exclusions" || { echo "Missing: ## Exclusions"; return 1; }
  grep -q "^## Risky Operations" || { echo "Missing: ## Risky Operations"; return 1; }
  
  echo "✓ business_context.md valid"
  return 0
}
```

---

## Comparison: business_context.md vs topology.json

| Aspect | business_context.md (SSOT) | topology.json (Legacy) |
|---|---|---|
| **Format** | Markdown (human-readable) | JSON (machine-readable) |
| **Purpose** | Guardrails + procedures + SLAs | Resource inventory + business context |
| **Ownership** | Customer (version control) | Auto-generated (don't commit) |
| **Visibility** | Team-wide (Git), documented | Hidden in config dir |
| **Validation** | Markdown parser checks sections | Schema validation only |
| **Evolution** | Lives with codebase, versioned | Temporary, discarded per run |
| **Precedence** | Primary (checked first) | Fallback (if business_context missing) |

**Migration:** business_context.md is PRIMARY. topology.json acts as optional override for runtime discovery (resource counts, scan_scope paths). business_context.md ALWAYS takes precedence for guardrails and rules.

---

## For v0.1.68+: Enhanced Capture

1. **GitHub-hosted templates** — offer pre-built business_context.md for common environments (AWS prod, multi-cloud, startup, enterprise)
2. **Slack integration** — ask for approval via Slack thread when guardrails trigger
3. **Jira sync** — log all guardrail violations to a Jira ticket for compliance
4. **Version tracking** — detect when business_context.md changes, auto-re-validate all running audits

---

## Rollout Plan for v0.1.67+

**Phase 1 (v0.1.67):** 
- [ ] Add business_context.md template
- [ ] Update `/scoutflo:connect` to offer capture
- [ ] Update all skills to read + validate
- [ ] Document in skill SKILL.md files

**Phase 2 (v0.1.68):**
- [ ] GitHub-hosted templates
- [ ] Slack approval integration
- [ ] Jira compliance logging

**Phase 3 (v0.1.69+):**
- [ ] Timeline-aware audits (skip during maintenance windows)
- [ ] Cost budget enforcement (auto-skip if budget exceeded)
- [ ] Custom runbook execution (auto-escalate on cascade detection)
