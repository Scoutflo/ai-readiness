# Business Context v0.1.68 Integration Guide

**How to Update Audit and Setup Skills to Use computed_metadata.jsonl**

**Target Audience:** Skill developers and maintainers  
**Version:** v0.1.68  
**Date:** 2026-07-31

---

## Overview

Starting in v0.1.68, all audit and setup skills read **pre-computed resource metadata** from `~/.scoutflo/computed_metadata.jsonl` instead of parsing `business_context.md` manually. This integration guide shows you:

1. **What changed** — Old: manual parsing per skill. New: centralized metadata discovery.
2. **How to integrate** — Code patterns and examples for each skill type.
3. **Backward compatibility** — How to handle customers on v0.1.67 (no regression).

---

## What Changed: Before vs After

### Before v0.1.68 (Manual Parsing)

```bash
# audit-aws (old, v0.1.67)
load_business_context() {
  CONTEXT="$HOME/.scoutflo/business_context.md"
  
  # Each skill manually parsed:
  CRITICAL_SERVICES=$(grep "^- \`" "$CONTEXT" | grep -A10 "Critical Services" | cut -d'`' -f2)
  COST_SENSITIVITY=$(grep "^- \*\*Primary:\*\*" "$CONTEXT" | cut -d' ' -f3)
  EXCLUDED_REGIONS=$(grep "^- \`" "$CONTEXT" | grep -A5 "Regions" | cut -d'`' -f2)
  
  # Problems:
  # - Duplicated parsing logic across all skills
  # - Inconsistent if customer format differs slightly
  # - No guarantee all skills read the same data
  # - New skills had to reimplement the parser
}
```

**Problems:**
- 12 different audit skills each parsing manually
- If one skill gets the parsing wrong, it silently disagrees with others
- Adding a new field required updating every skill
- Customers with custom business_context.md format broke all skills

### After v0.1.68 (Centralized Metadata)

```bash
# audit-aws (new, v0.1.68)
load_metadata() {
  METADATA="$HOME/.scoutflo/computed_metadata.jsonl"
  
  # All skills read the same pre-computed metadata:
  # {"resource_id":"payment-svc","team":"payment",...,"escalation":"CRITICAL",...}
  
  # Single source of truth:
  # - One resolver generates metadata once
  # - All skills read the same file
  # - No duplication, no inconsistency
  # - New skills just read the same format
}
```

**Benefits:**
- Single source of truth (computed_metadata.jsonl)
- All skills read consistent data
- New metadata fields auto-available to all skills
- Customer format issues handled once (in resolver)

---

## Integration Pattern: Doctor Gate

Every audit skill needs to load `computed_metadata.jsonl` in its doctor gate (the startup checks).

### Step 1: Add Metadata Load to Doctor Gate

**File:** `skills/audit-YOURSKILL/scripts/doctor.sh` (or inline)

```bash
# ============================================================================
# Load pre-computed resource metadata (v0.1.68+)
# ============================================================================

load_metadata() {
  METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  
  # Fallback to v0.1.67 business_context.md if metadata not available
  BUSINESS_CONTEXT="${HOME}/.scoutflo/business_context.md"
  
  if [ ! -f "$METADATA" ]; then
    # v0.1.68 metadata not found, try v0.1.67 business_context
    if [ -f "$BUSINESS_CONTEXT" ]; then
      echo "⚠ computed_metadata.jsonl not found, falling back to business_context.md (v0.1.67 mode)"
      # Legacy fallback: manually parse (keep old code for compatibility)
      COST_SENSITIVITY=$(grep "^- \*\*Primary:\*\*" "$BUSINESS_CONTEXT" | cut -d' ' -f3 || echo "high")
      return 1  # Signal: using legacy mode
    else
      echo "✓ No business context found (audit proceeds without guardrails)"
      return 0  # No guardrails, but not a failure
    fi
  fi
  
  # v0.1.68 metadata found, use it
  return 0
}

# In doctor gate:
if load_metadata; then
  echo "✓ Business context loaded (v0.1.68 metadata)"
else
  echo "⚠ Business context loaded (v0.1.67 fallback mode)"
fi
```

### Step 2: Use Metadata in Decision Points

**Pattern 1: Skip Resources**

```bash
# Old (v0.1.67): Manual check
if echo "$EXCLUDED_REGIONS" | grep -q "$region"; then
  echo "Skipping region: $region"
  continue
fi

# New (v0.1.68): Use metadata
skip_resource() {
  local resource_id="$1"
  local action=$(jq -r --arg id "$resource_id" '.[] | select(.resource_id == $id) | .action' "$METADATA" 2>/dev/null || echo "audit")
  
  if [ "$action" = "skip" ]; then
    return 0  # SKIP
  fi
  return 1  # AUDIT
}

# Usage:
if skip_resource "$service"; then
  echo "Skipping $service (excluded by business context)"
  continue
fi
```

**Pattern 2: Escalate Critical Services**

```bash
# Old (v0.1.67): Manual check
if echo "$CRITICAL_SERVICES" | grep -q "$service"; then
  severity="critical"
fi

# New (v0.1.68): Use metadata
get_escalation_level() {
  local resource_id="$1"
  jq -r --arg id "$resource_id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"' "$METADATA" 2>/dev/null || echo "STANDARD"
}

# Usage:
escalation=$(get_escalation_level "$service")
if [ "$escalation" = "CRITICAL" ]; then
  echo "CRITICAL service: $service (approval required)"
  # Gate any risky operations
fi
```

**Pattern 3: Apply Cost Sensitivity**

```bash
# Old (v0.1.67): Global value
if [ "$COST_SENSITIVITY" = "high" ]; then
  # Sort findings by annual savings
fi

# New (v0.1.68): Per-resource or aggregated
get_cost_sensitivity() {
  jq -s '[.[] | .cost_sensitivity] | group_by(.) | max_by(length)[0]' "$METADATA" 2>/dev/null || echo "high"
}

# Usage:
primary_cost_sens=$(get_cost_sensitivity)
if [ "$primary_cost_sens" = "high" ]; then
  # Sort findings by ROI (annual_savings)
fi
```

---

## Integration by Skill Type

### Audit Skills (audit-aws, audit-gcp, audit-k8s, etc.)

**What to update:**
1. Doctor gate: Load metadata
2. Service/resource scope: Check `action == "skip"` for each resource
3. Finding severity: Use `escalation` level from metadata
4. Reporting: Include business context applied (e.g., "CRITICAL service per business context")

**Example: audit-aws**

```bash
# In doctor gate:
load_metadata() {
  METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  [ -f "$METADATA" ] || echo "⚠ No metadata; business context unavailable"
}

# In audit loop (for each EC2 instance):
should_audit_instance() {
  local instance_id="$1"
  
  # Check if resource should be skipped
  if jq -e --arg id "$instance_id" '.[] | select(.resource_id == $id and .action == "skip")' "$METADATA" >/dev/null 2>&1; then
    echo "Skipping $instance_id (action: skip)"
    return 1
  fi
  
  return 0
}

# When reporting findings:
escalation=$(jq -r --arg id "$instance_id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"' "$METADATA")
if [ "$escalation" = "CRITICAL" ]; then
  echo "🔴 [CRITICAL] Issue found in critical service $instance_id (requires approval per business context)"
else
  echo "🟡 [STANDARD] Issue found in $instance_id"
fi
```

### Setup Skills (setup-aws, setup-gcp, setup-lgtm)

**What to update:**
1. Doctor gate: Load metadata (same as audit skills)
2. Pre-flight check: Use `escalation` to gate risky operations
3. Approval flow: Require approval for CRITICAL services or high-risk operations

**Example: setup-aws**

```bash
# In doctor gate:
load_metadata() {
  METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  [ -f "$METADATA" ] || return 1
}

# Before performing risky operation (e.g., terminate instance):
check_risky_operation() {
  local resource_id="$1"
  local operation="$2"  # e.g., "terminate"
  
  # Check if service is critical
  escalation=$(jq -r --arg id "$resource_id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"' "$METADATA")
  
  if [ "$escalation" = "CRITICAL" ]; then
    echo "⚠️  CRITICAL SERVICE: This operation requires approval"
    read -p "Do you approve terminating a critical service? (type 'yes' to confirm): " approval
    if [ "$approval" != "yes" ]; then
      echo "❌ Operation cancelled"
      return 1
    fi
  fi
  
  return 0
}

# Usage:
if check_risky_operation "$instance_id" "terminate"; then
  # Proceed with operation
fi
```

### Cost Analysis Skill

**What to update:**
1. Load metadata to determine cost_sensitivity
2. Sort findings by ROI when cost_sensitivity="high"
3. Sort findings by impact when cost_sensitivity="low"

**Example: cost-analysis**

```bash
# In doctor gate:
load_metadata() {
  METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  [ -f "$METADATA" ] || return 1
}

# When sorting findings:
sort_findings() {
  local findings_file="$1"  # JSON file with findings
  
  # Get primary cost sensitivity
  primary_cost_sens=$(jq -s '[.[] | .cost_sensitivity] | group_by(.) | max_by(length)[0]' "$METADATA" 2>/dev/null || echo "high")
  
  if [ "$primary_cost_sens" = "high" ]; then
    # Sort by annual savings (highest first)
    jq -s 'sort_by(.annual_roi | tonumber) | reverse' "$findings_file"
  else
    # Sort by customer impact (critical first)
    jq -s 'sort_by(.severity) | reverse' "$findings_file"
  fi
}
```

---

## Backward Compatibility (v0.1.67 Support)

**Must support both paths:**
1. **New path (v0.1.68):** computed_metadata.jsonl exists → use it
2. **Old path (v0.1.67):** business_context.md exists → parse it manually
3. **No guardrails:** Neither file exists → proceed without business context

**Implementation:**

```bash
load_business_context_or_metadata() {
  METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  CONTEXT="${HOME}/.scoutflo/business_context.md"
  
  if [ -f "$METADATA" ]; then
    # v0.1.68: Use pre-computed metadata
    MODE="v0.1.68"
    return 0
  elif [ -f "$CONTEXT" ]; then
    # v0.1.67: Use manual business_context.md
    MODE="v0.1.67"
    # (run legacy parsing code)
    return 0
  else
    # No guardrails
    MODE="none"
    return 0
  fi
}

# Usage:
load_business_context_or_metadata
case "$MODE" in
  v0.1.68)
    echo "✓ Using v0.1.68 metadata"
    # Use new metadata-based code paths
    ;;
  v0.1.67)
    echo "✓ Using v0.1.67 business_context"
    # Use legacy parsing code
    ;;
  none)
    echo "✓ No business context"
    # Proceed without guardrails
    ;;
esac
```

---

## Metadata Format Reference

Every line in `computed_metadata.jsonl` is valid JSON:

```json
{
  "resource_id": "payment-svc",
  "team": "payment",
  "environment": "prod",
  "sla": "99.95%",
  "escalation": "CRITICAL",
  "cost_sensitivity": "high",
  "action": "audit",
  "resolved_at": "2026-07-31T12:00:00Z"
}
```

**Fields:**
- `resource_id` — Service or resource name (unique identifier)
- `team` — Team ownership (from K8s label or AWS tag)
- `environment` — Environment (prod, staging, dev, sandbox, etc.)
- `sla` — Service level agreement (e.g., "99.9%", "99.95%")
- `escalation` — Criticality level ("CRITICAL" or "STANDARD")
- `cost_sensitivity` — Cost priority ("high", "medium", or "low")
- `action` — Whether to audit ("audit") or skip ("skip") this resource
- `resolved_at` — ISO 8601 timestamp when metadata was generated

---

## Query Patterns

### Get All Critical Services

```bash
jq -s '[.[] | select(.escalation=="CRITICAL")] | map(.resource_id)' "$METADATA"
```

### Get Resources to Skip

```bash
jq -s '[.[] | select(.action=="skip")] | map(.resource_id)' "$METADATA"
```

### Get Cost Sensitivity Distribution

```bash
jq -s 'group_by(.cost_sensitivity) | map({cost_sens: .[0].cost_sensitivity, count: length})' "$METADATA"
```

### Get Team-Level SLA

```bash
jq -s --arg team "payment" '[.[] | select(.team==$team)] | .[0].sla' "$METADATA"
```

### Filter Resources by Team

```bash
jq -s --arg team "payment" '[.[] | select(.team==$team)]' "$METADATA"
```

---

## Testing the Integration

### Test 1: Metadata Loads Correctly

```bash
#!/bin/bash
METADATA="$HOME/.scoutflo/computed_metadata.jsonl"

if [ ! -f "$METADATA" ]; then
  echo "❌ FAIL: Metadata file not found"
  exit 1
fi

# Verify it's valid JSONL
if jq -s '.' "$METADATA" >/dev/null 2>&1; then
  echo "✓ Metadata is valid JSON"
else
  echo "❌ FAIL: Metadata is not valid JSON"
  exit 1
fi
```

### Test 2: Skill Reads Metadata Correctly

```bash
#!/bin/bash
METADATA="$HOME/.scoutflo/computed_metadata.jsonl"

# Test querying a resource
if jq -e '.[0].escalation' "$METADATA" >/dev/null 2>&1; then
  echo "✓ Can query escalation field"
else
  echo "❌ FAIL: Cannot query escalation field"
  exit 1
fi
```

### Test 3: Backward Compatibility Works

```bash
#!/bin/bash
# Remove metadata to trigger v0.1.67 fallback
rm "$HOME/.scoutflo/computed_metadata.jsonl"

# Skill should still work with business_context.md
if /scoutflo:audit-aws >/dev/null 2>&1; then
  echo "✓ Backward compatibility works"
else
  echo "❌ FAIL: Backward compatibility broken"
  exit 1
fi
```

---

## Migration Checklist

For each skill (audit-aws, audit-gcp, audit-k8s, cost-analysis, setup-aws, etc.):

- [ ] Doctor gate updated to load metadata
- [ ] Metadata loading has fallback to v0.1.67 business_context.md
- [ ] Resource skip logic uses `action` field from metadata
- [ ] Finding severity uses `escalation` field from metadata
- [ ] Cost sensitivity uses field from metadata
- [ ] Tests pass (backward compat + new path)
- [ ] SKILL.md updated to mention v0.1.68 integration
- [ ] Manual skill test completed
- [ ] E2E test with both v0.1.68 metadata and v0.1.67 fallback

---

## See Also

- [business-context-resolver SKILL.md](../skills/business-context-resolver/SKILL.md) — Full resolver documentation
- [business-context-v0168-metadata-driven.md](specs/business-context-v0168-metadata-driven.md) — v0.1.68 architecture
- [business-context-ssot.md](specs/business-context-ssot.md) — v0.1.67 SSOT (legacy reference)

---

**Questions?** See the resolver SKILL.md or v0.1.68 architecture spec. This guide covers integration only; for resolver operation, see those docs.
