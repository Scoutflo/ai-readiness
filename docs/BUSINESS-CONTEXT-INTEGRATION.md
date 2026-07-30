# Business Context Integration — v0.1.67+ Design

**How to wire `business_context.md` SSOT into `/scoutflo:connect` and all skills.**

---

## File Structure

```
~/.scoutflo/
  ├── toolkit.yaml                          # Existing: integration credentials
  ├── business_context.md                   # NEW: SSOT for guardrails (optional but recommended)
  ├── topology.json                         # Existing: resource inventory (auto-generated)
  └── scoutflo-audits/
      ├── [provider]/history.jsonl         # Per-provider history
      └── correlation.json                  # Correlation engine output
```

---

## `/scoutflo:connect` Integration Flow

### Step 1: Welcome + Intro
```
Welcome to Scoutflo AI Readiness!

This setup will configure your audits for:
✓ Token efficiency (skip <24h unchanged data)
✓ Topology-guided scanning (only needed resources)
✓ Business context (SLAs, SLOs, guardrails, custom rules)

Continue? (y/n)
```

### Step 2: Standard Setup (Existing)
- Ask for integration credentials (AWS, GCP, Datadog, etc.)
- Validate with doctor gate
- Save to `toolkit.yaml`

### Step 3: NEW — Business Context Capture

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Business Context Setup (Optional but Recommended)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Your business context defines guardrails, SLAs, SLOs, and custom rules.
Examples:
  • Which services are critical (require approval before changes)
  • Which regions to exclude (compliance/cost)
  • Team procedures (cascade failure handling, escalation paths)
  • Cost budget limits

Provide business context? (Recommended for production)

Options:
  1. Use default (production, medium risk, no exclusions)
  2. Paste markdown content (copy-paste your business_context.md)
  3. Specify file path (provide existing file)
  4. Skip for now (can add later via ~/.scoutflo/business_context.md)

Choose (1-4): [User selects]
```

#### Option 1: Use Default
```bash
# Create safe defaults
cat > ~/.scoutflo/business_context.md << 'EOF'
# Business Context — Default (Production)

## Environment
- Name: Production
- Stage: prod
- Risk Level: Medium
- Approval Gate: None (proceed with audits)

## Cost Sensitivity
- Primary: Medium
- Budget: No limit (all findings reviewed)

## Critical Services
[None — all services treated equally]

## Exclusions
[None — audit all regions, accounts, services]

## Risky Operations
[None — all operations allowed]

## Token Consumption
[No limit — audit completely]

## Audit Strategy
- Frequency: Daily
- Scope: All services, all regions
EOF

echo "✓ Default business context created"
```

#### Option 2: Paste Markdown
```bash
echo "Paste your business_context.md (ctrl+D to end):"
cat > ~/.scoutflo/business_context.md

# Validate
sh ci/validate-business-context.sh
echo "✓ Business context saved and validated"
```

#### Option 3: Specify File Path
```bash
read -p "File path (absolute or relative): " file_path
cp "$file_path" ~/.scoutflo/business_context.md

# Validate
sh ci/validate-business-context.sh
echo "✓ Business context loaded and validated"
```

#### Option 4: Skip (Save Template)
```bash
cp templates/business_context_template.md ~/.scoutflo/business_context_template.md
echo "ℹ️  Template saved to ~/.scoutflo/business_context_template.md"
echo "💡 Edit it when ready and save as business_context.md"
```

### Step 4: Verification

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
✓ Setup Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Integrations configured:
  ✓ AWS (prod account)
  ✓ GCP (project-xyz)
  ✓ Datadog (US2 org)

Business context:
  ✓ Loaded from ~/.scoutflo/business_context.md
  ✓ Critical services: payment-svc, api-gateway, database-svc
  ✓ Excluded regions: cn-*, us-gov-*
  ✓ Cost sensitivity: high (ROI-first)
  ✓ Token budget: 50K/week for unchanged estates

Ready to run audits:
  /scoutflo:audit-all                    # Run all configured audits
  /scoutflo:cost-analysis                # Analyze cost findings
  /scoutflo:doctor                       # Check setup health

📚 Learn more:
  docs/TOKEN-EFFICIENCY-GOVERNANCE.md    # How token efficiency works
  docs/BUSINESS-CONTEXT-SSOT.md          # Detailed guardrails reference
  ~/.scoutflo/business_context.md        # Your custom rules
```

---

## Validation Gate: `validate-business-context.sh`

```bash
#!/bin/sh
# ci/validate-business-context.sh
# Validate business_context.md structure and content

validate_business_context() {
  CONTEXT="$HOME/.scoutflo/business_context.md"
  
  [ -f "$CONTEXT" ] || { echo "✗ business_context.md not found"; return 1; }
  
  # Check required sections
  grep -q "^## Environment" "$CONTEXT" || { echo "✗ Missing: ## Environment"; return 1; }
  grep -q "^## Cost Sensitivity" "$CONTEXT" || { echo "✗ Missing: ## Cost Sensitivity"; return 1; }
  
  # Optional but recommended
  grep -q "^## Critical Services" "$CONTEXT" || echo "⚠ Consider adding: ## Critical Services"
  grep -q "^## Exclusions" "$CONTEXT" || echo "⚠ Consider adding: ## Exclusions"
  
  echo "✓ business_context.md structure valid"
  return 0
}

validate_business_context
```

---

## Integration with All Skills

Every skill **reads and applies** business_context.md before acting:

### audit-aws (and all audit-* skills)
```bash
# In doctor gate:
load_business_context() {
  if [ -f "$HOME/.scoutflo/business_context.md" ]; then
    CRITICAL_SERVICES=$(grep "^- \`" business_context.md | grep -A5 "Critical Services" | cut -d'`' -f2)
    EXCLUDED_REGIONS=$(grep "^- \`" business_context.md | grep -A3 "Regions" | cut -d'`' -f2)
  fi
}

# Before discovery:
check_region_exclusion() {
  REGION="$1"
  echo "$EXCLUDED_REGIONS" | grep -q "$REGION" && return 1  # SKIP
  return 0
}
```

### cost-analysis
```bash
# Load cost_sensitivity to determine sorting:
COST_SENSITIVITY=$(grep "^- \*\*Primary:\*\*" business_context.md | cut -d' ' -f3)
if [ "$COST_SENSITIVITY" = "High" ]; then
  # Sort findings by ROI (annual_savings)
else
  # Sort findings by monthly_waste
fi
```

### topology-guided-setup
```bash
# Load critical services for approval gates:
CRITICAL_SERVICES=$(grep "^- \`" business_context.md | grep -A5 "Critical Services" | cut -d'`' -f2)

# If finding in critical service:
if echo "$CRITICAL_SERVICES" | grep -q "$SERVICE"; then
  topology_guided_get_recommendation() {
    return "CRITICAL_SERVICE"  # → Require approval
  }
fi
```

### setup-* skills (setup-aws, etc)
```bash
# Before applying fix:
check_risky_operations() {
  OPERATION="$1"  # e.g., "terminate-instance"
  SERVICE="$2"    # e.g., "payment-svc"
  
  # If risky operation on critical service → require approval
  if echo "$CRITICAL_SERVICES" | grep -q "$SERVICE"; then
    if grep -q "^$OPERATION" business_context.md; then
      ask_for_approval "Risky operation: $OPERATION on critical service $SERVICE"
    fi
  fi
}
```

---

## Documentation for Customers

When delivering business_context.md capability:

1. **Send template:** `templates/business_context_template.md`
2. **Send spec:** `docs/specs/business-context-ssot.md`
3. **Send example:** `docs/specs/business-context-ssot.md` (production example in that file)
4. **Point to integration:** `docs/BUSINESS-CONTEXT-INTEGRATION.md` (this file)

**Setup instructions:**
```markdown
## Setting Up Business Context

1. Run `/scoutflo:connect` and choose option 2 or 3 when asked
2. Paste your business_context.md or specify file path
3. Confirm validation passes
4. All audits will now respect your guardrails

If you already have it: just save it as `~/.scoutflo/business_context.md`
```

---

## Behavior Summary

| Scenario | Without business_context.md | With business_context.md |
|---|---|---|
| **Audit a critical service** | Proceeds normally | Requires approval if marked critical |
| **Audit excluded region** | Included | Skipped (logs reason) |
| **Cost finding >$200/mo** | ROI-sort if medium/low | ROI-sort (high sensitivity) |
| **Risky operation proposed** | Proceeds | Escalation gate |
| **Token budget exceeded** | Continues | Warn or skip non-critical services |

---

## Rollout Timeline

### v0.1.67 (THIS RELEASE)
- ✅ Add business_context.md SSOT spec
- ✅ Create template + example
- ✅ Update `/scoutflo:connect` to offer capture (add steps 3-4)
- ✅ All skills read business_context.md
- ✅ Validation gate created

### v0.1.68
- [ ] GitHub-hosted templates (AWS-prod, multi-cloud, etc)
- [ ] Slack approval integration (approve via thread)
- [ ] Jira sync (log all guardrail violations)

### v0.1.69+
- [ ] Timeline-aware audits (skip during maintenance windows)
- [ ] Cost budget enforcement (auto-skip if budget exceeded)
- [ ] Custom runbook execution (auto-escalate on cascade)
