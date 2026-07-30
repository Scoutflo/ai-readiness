# v0.1.68 Skill Update Template

**For Audit and Setup Skills:** Copy this template to your skill and fill in the blanks

**File to update:** `skills/YOURSKILL/scripts/` or directly in SKILL.md doctor section

---

## Template: Doctor Gate Metadata Loading

Add this section to every audit/setup skill's doctor gate:

```bash
# ============================================================================
# Load Business Context (v0.1.68 metadata OR v0.1.67 fallback)
# ============================================================================

LOAD_METADATA_MODE="none"  # "v0168", "v0167", or "none"

load_business_context_or_metadata() {
  local METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  local CONTEXT="${HOME}/.scoutflo/business_context.md"
  
  # Check for v0.1.68 metadata (preferred)
  if [ -f "$METADATA" ]; then
    LOAD_METADATA_MODE="v0168"
    # Validate it's readable
    if jq -e '.' "$METADATA" >/dev/null 2>&1; then
      return 0  # SUCCESS: v0.1.68 metadata loaded
    else
      echo "⚠ WARNING: computed_metadata.jsonl exists but is not valid JSON, falling back to business_context.md"
    fi
  fi
  
  # Fallback to v0.1.67 business_context.md (backward compat)
  if [ -f "$CONTEXT" ]; then
    LOAD_METADATA_MODE="v0167"
    # [KEEP EXISTING PARSING CODE HERE - see v0.1.67 SKILL.md for patterns]
    return 0  # SUCCESS: v0.1.67 fallback loaded
  fi
  
  # No guardrails available
  LOAD_METADATA_MODE="none"
  return 0  # Not an error; audit proceeds without business context
}

# In doctor gate, call this early:
load_business_context_or_metadata
case "$LOAD_METADATA_MODE" in
  v0168) echo "✓ Loaded v0.1.68 computed metadata" ;;
  v0167) echo "✓ Loaded v0.1.67 business_context (fallback mode)" ;;
  none)  echo "✓ No business context configured" ;;
esac
```

---

## Pattern 1: Skip Resources

**When to use:** Before auditing a resource, check if it should be skipped

```bash
should_audit_resource() {
  local resource_id="$1"
  local METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  
  if [ "$LOAD_METADATA_MODE" != "v0168" ]; then
    # v0.1.67 fallback: use existing exclusion logic
    # [KEEP EXISTING CODE]
    return 0  # Default: audit it
  fi
  
  # v0.1.68: Check metadata action field
  if jq -e --arg id "$resource_id" '.[] | select(.resource_id == $id and .action == "skip")' "$METADATA" >/dev/null 2>&1; then
    return 1  # SKIP
  fi
  
  return 0  # AUDIT
}

# Usage in audit loop:
for instance in $(aws ec2 describe-instances | jq -r '.Reservations[].Instances[].InstanceId'); do
  if ! should_audit_resource "$instance"; then
    echo "⏭️  Skipping $instance (excluded by business context)"
    continue
  fi
  
  # Audit this instance
done
```

---

## Pattern 2: Escalate Critical Services

**When to use:** When reporting findings, escalate severity for critical services

```bash
get_escalation_level() {
  local resource_id="$1"
  local METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  
  if [ "$LOAD_METADATA_MODE" != "v0168" ]; then
    # v0.1.67 fallback: use existing criticality logic
    # [KEEP EXISTING CODE]
    echo "STANDARD"
    return
  fi
  
  # v0.1.68: Query metadata
  jq -r --arg id "$resource_id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"' "$METADATA" 2>/dev/null || echo "STANDARD"
}

# Usage when finding an issue:
escalation=$(get_escalation_level "$service_name")
case "$escalation" in
  CRITICAL)
    finding_severity="critical"
    echo "🔴 [CRITICAL] $service_name requires approval per business context"
    ;;
  STANDARD)
    finding_severity="medium"
    echo "🟡 [STANDARD] Issue found in $service_name"
    ;;
esac
```

---

## Pattern 3: Apply Cost Sensitivity

**When to use:** In cost-analysis skill, sort findings by cost_sensitivity

```bash
get_primary_cost_sensitivity() {
  local METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  
  if [ "$LOAD_METADATA_MODE" != "v0168" ]; then
    # v0.1.67 fallback: use existing COST_SENSITIVITY variable
    # [KEEP EXISTING CODE]
    return
  fi
  
  # v0.1.68: Aggregate from metadata
  jq -s 'map(.cost_sensitivity) | group_by(.) | max_by(length)[0]' "$METADATA" 2>/dev/null || echo "high"
}

# Usage in cost-analysis:
primary_cost_sens=$(get_primary_cost_sensitivity)
case "$primary_cost_sens" in
  high)
    # Sort by annual savings (highest first)
    jq -s 'sort_by(.annual_savings | tonumber) | reverse' findings.json
    ;;
  medium|low)
    # Sort by customer impact
    jq -s 'sort_by(.severity) | reverse' findings.json
    ;;
esac
```

---

## Pattern 4: Backward Compatibility Check

**Use this to verify both paths work:**

```bash
test_backward_compatibility() {
  echo "Testing v0.1.68 path..."
  
  # Test v0.1.68 metadata loading
  if [ -f "$HOME/.scoutflo/computed_metadata.jsonl" ]; then
    if jq -e '.' "$HOME/.scoutflo/computed_metadata.jsonl" >/dev/null 2>&1; then
      echo "✓ v0.1.68 metadata loads"
    else
      echo "✗ v0.1.68 metadata invalid"
      return 1
    fi
  fi
  
  echo "Testing v0.1.67 fallback..."
  
  # Test v0.1.67 business_context fallback
  if [ -f "$HOME/.scoutflo/business_context.md" ]; then
    if grep -q "## Global SLAs" "$HOME/.scoutflo/business_context.md"; then
      echo "✓ v0.1.67 fallback works"
    else
      echo "✗ v0.1.67 fallback invalid"
      return 1
    fi
  fi
  
  echo "✓ Backward compatibility verified"
  return 0
}
```

---

## Checklist: For Each Skill (audit-aws, audit-gcp, etc.)

- [ ] Add metadata load function to doctor gate
- [ ] Add fallback to v0.1.67 business_context.md
- [ ] Add skip-resource pattern (use `action` field)
- [ ] Add escalation pattern (use `escalation` field)
- [ ] Update SKILL.md to mention v0.1.68 integration
- [ ] Test with v0.1.68 metadata path
- [ ] Test with v0.1.67 fallback path
- [ ] Test with no guardrails (neither file exists)
- [ ] leak-scan passes
- [ ] Manual test: `./skills/YOURSKILL/... --help` shows usage

---

## Implementation Order (Suggested for Parallelization)

**High Priority (Most Used):**
1. audit-aws (example implementation)
2. audit-gcp
3. audit-lgtm (uses both audit and setup patterns)

**Medium Priority (Frequently Used):**
4. cost-analysis (unique pattern: uses cost_sensitivity)
5. setup-aws
6. doctor.sh (baseline for all skills)

**Lower Priority (Specialized):**
7. audit-grafana
8. audit-sentry
9. audit-datadog
10. audit-k8s

**Can Skip for v0.1.68 (Optional):**
- audit-alert-routing (doesn't need business context)
- Other specialized audits (not in core flow)

---

## Quick Verification

After updating each skill:

```bash
# 1. Syntax check
bash -n skills/YOURSKILL/scripts/*.sh || echo "Syntax error"

# 2. Doctor gate check
grep -q "load_business_context_or_metadata\|LOAD_METADATA_MODE" skills/YOURSKILL/scripts/doctor.sh && echo "✓ Doctor gate updated"

# 3. Backward compat pattern check
grep -q "v0167\|business_context.md" skills/YOURSKILL/scripts/*.sh && echo "✓ Fallback pattern present"

# 4. Metadata pattern check
grep -q "computed_metadata.jsonl\|jq.*\.action\|\.escalation" skills/YOURSKILL/scripts/*.sh && echo "✓ Metadata pattern present"
```

---

## Reference: Query Examples for All Patterns

**Skip Resources:**
```bash
jq -r --arg id "$id" '.[] | select(.resource_id == $id and .action == "skip")'
```

**Get Escalation:**
```bash
jq -r --arg id "$id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"'
```

**Get SLA:**
```bash
jq -r --arg id "$id" '.[] | select(.resource_id == $id) | .sla'
```

**Get Cost Sensitivity:**
```bash
jq -r --arg id "$id" '.[] | select(.resource_id == $id) | .cost_sensitivity'
```

**Aggregate Cost Sensitivity (for primary value):**
```bash
jq -s 'map(.cost_sensitivity) | group_by(.) | max_by(length)[0]'
```

**Get All Critical Services:**
```bash
jq -s '[.[] | select(.escalation=="CRITICAL")] | map(.resource_id)'
```

**Get All Resources to Skip:**
```bash
jq -s '[.[] | select(.action=="skip")] | map(.resource_id)'
```

---

## Example: Complete Integrated Skill (audit-aws snippet)

See `BUSINESS-CONTEXT-INTEGRATION-v0168.md` for full audit-aws and setup-aws examples.

---

**Use this template for all 10 skills. Changes are minimal: doctor gate load + 3 decision patterns.**
