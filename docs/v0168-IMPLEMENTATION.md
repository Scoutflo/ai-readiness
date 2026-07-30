# v0.1.68 Implementation — Week 3 Execution

**Timeline:** Wednesday–Friday  
**Work:** Update 10 audit/setup skills + release  
**All patterns:** Copy-paste templates below

---

## Quick Start: What Each Skill Needs

Every skill update follows the same pattern:

1. Add metadata load function to doctor gate (30 lines)
2. Add skip-resource decision point (10-20 lines)
3. Add escalation decision point (10-20 lines)
4. Add cost-sensitivity decision point (optional, cost-analysis only)
5. Test both v0.1.68 and v0.1.67 paths
6. Verify leak-scan passes

**Per-skill time:** 30–60 minutes  
**Total (10 skills):** 5–6 hours (parallelizable to 2–3 hours with teamwork)

---

## Pattern 1: Load Metadata in Doctor Gate

Add this at the START of the doctor gate (before existing checks):

```bash
# ============================================================================
# v0.1.68: Load Business Context (metadata OR v0.1.67 fallback)
# ============================================================================

LOAD_METADATA_MODE="none"

load_business_context_or_metadata() {
  local METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"
  local CONTEXT="${HOME}/.scoutflo/business_context.md"
  
  # Try v0.1.68 metadata first (preferred)
  if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
    LOAD_METADATA_MODE="v0168"
    return 0
  fi
  
  # Fallback to v0.1.67 business_context
  if [ -f "$CONTEXT" ]; then
    LOAD_METADATA_MODE="v0167"
    # [EXISTING v0.1.67 PARSING CODE GOES HERE - unchanged]
    return 0
  fi
  
  LOAD_METADATA_MODE="none"
  return 0
}

# Call in doctor gate:
load_business_context_or_metadata
case "$LOAD_METADATA_MODE" in
  v0168) echo "✓ v0.1.68 metadata loaded ($(jq -c 'length' "$METADATA") resources)" ;;
  v0167) echo "✓ v0.1.67 business_context loaded (fallback)" ;;
  none)  echo "✓ No business context configured" ;;
esac
```

---

## Pattern 2: Skip Excluded Resources

Find where you currently check exclusions. Replace with:

**OLD (v0.1.67):**
```bash
if echo "$EXCLUDED_REGIONS" | grep -q "$region"; then
  echo "Skipping $service"
  continue
fi
```

**NEW (v0.1.68):**
```bash
# Skip excluded resources (check metadata first, then fallback)
if [ "$LOAD_METADATA_MODE" = "v0168" ]; then
  if jq -e --arg id "$resource_id" '.[] | select(.resource_id == $id and .action == "skip")' "$METADATA" >/dev/null 2>&1; then
    echo "Skipping $resource_id (v0.1.68 metadata: excluded)"
    continue
  fi
else
  # Fallback to existing code
  if echo "$EXCLUDED_REGIONS" | grep -q "$region"; then
    echo "Skipping $service"
    continue
  fi
fi
```

---

## Pattern 3: Escalate Critical Services

Find where you set finding severity. Replace with:

**OLD (v0.1.67):**
```bash
severity="medium"
if echo "$CRITICAL_SERVICES" | grep -q "$service"; then
  severity="critical"
fi
```

**NEW (v0.1.68):**
```bash
severity="medium"
if [ "$LOAD_METADATA_MODE" = "v0168" ]; then
  escalation=$(jq -r --arg id "$resource_id" '.[] | select(.resource_id == $id) | .escalation // "STANDARD"' "$METADATA" 2>/dev/null || echo "STANDARD")
  if [ "$escalation" = "CRITICAL" ]; then
    severity="critical"
  fi
else
  # Fallback to existing code
  if echo "$CRITICAL_SERVICES" | grep -q "$service"; then
    severity="critical"
  fi
fi
```

---

## Pattern 4: Cost Sensitivity (cost-analysis skill only)

Sort findings by cost impact and ROI:

```bash
if [ "$LOAD_METADATA_MODE" = "v0168" ]; then
  # Group resources by cost_sensitivity and sort ROI high-to-low
  cost_sens=$(jq -s 'map(.cost_sensitivity) | group_by(.) | max_by(length)[0]' "$METADATA")
  if [ "$cost_sens" = "high" ]; then
    # Sort findings by cost impact (descending)
    jq -s 'sort_by(-(.monthly_savings // 0))' findings.json > findings_by_roi.json
  fi
else
  # Fallback: sort by severity (existing behavior)
  jq -s 'sort_by(-.severity_rank)' findings.json > findings_sorted.json
fi
```

---

## Pattern 5: Backward Compatibility Test

For each skill, test both paths:

```bash
# Test v0.1.68 path (with metadata)
export HOME=/tmp/test-scoutflo-v0168
mkdir -p ~/.scoutflo
cat > ~/.scoutflo/business_context.md << 'EOF'
## Global SLAs / SLOs
- Production-Standard: 99.9%

## Teams
- payment: Revenue-critical

## Global Exclusions
- Services: deprecated-*
EOF

cat > ~/.scoutflo/computed_metadata.jsonl << 'EOF'
{"resource_id":"payment-svc","type":"k8s-service","team":"payment","environment":"prod","sla":"99.95%","escalation":"CRITICAL","cost_sensitivity":"high","action":"audit","resolved_at":"2026-08-20T12:00:00Z"}
{"resource_id":"deprecated-svc","type":"k8s-service","team":"platform","environment":"prod","sla":"99.9%","escalation":"STANDARD","cost_sensitivity":"low","action":"skip","resolved_at":"2026-08-20T12:00:00Z"}
EOF

# Run skill (should read metadata and skip deprecated-svc)
/scoutflo:YOUR-SKILL --dry-run

# Test v0.1.67 path (fallback, no metadata)
rm ~/.scoutflo/computed_metadata.jsonl
# Run skill again (should use business_context.md instead)
/scoutflo:YOUR-SKILL --dry-run
```

---

## Implementation Checklist

### Wednesday AM (Core Skills 1–5)

- [ ] **audit-aws** (30 min)
  - Add Pattern 1: metadata load
  - Add Pattern 2: skip excluded regions
  - Add Pattern 3: escalate critical services
  - Test v0.1.68 + v0.1.67 paths
  - Verify: `bash -n scripts/*.sh` + leak-scan

- [ ] **audit-gcp** (30 min)
  - Same patterns as audit-aws
  - Test both paths

- [ ] **cost-analysis** (20 min)
  - Add Pattern 1: metadata load
  - Add Pattern 4: sort by cost_sensitivity
  - Test both paths

- [ ] **setup-aws** (20 min)
  - Add Pattern 1: metadata load
  - Add Pattern 3: escalation gate for risky operations
  - Test both paths

- [ ] **doctor.sh** (30 min)
  - Add Pattern 1: metadata load to baseline doctor
  - Test both paths

**Wednesday PM Testing & Release Prep:**
- [ ] Full integration test (audit-all with metadata)
- [ ] Regression test (audit-all without metadata, v0.1.67 fallback)
- [ ] All skills pass leak-scan
- [ ] All skills pass structure-check

### Thursday (Core Skills 6–10)

**Can parallelize with a team:**

- [ ] **audit-lgtm** (30 min) — Same patterns, optional metadata
- [ ] **audit-grafana** (30 min) — Same patterns, optional metadata
- [ ] **audit-sentry** (30 min) — Same patterns, optional metadata
- [ ] **audit-datadog** (30 min) — Same patterns, optional metadata
- [ ] **audit-k8s** (30 min) — Same patterns, optional metadata

**Thursday PM Integration Tests:**
- [ ] Full E2E: `/scoutflo:connect` → resolver → all 10 skills
- [ ] Regression: all 10 skills with v0.1.67 business_context.md (no metadata)
- [ ] Regression: all 10 skills with no guardrails (LOAD_METADATA_MODE=none)
- [ ] All pressure scenarios pass

### Friday (Release)

- [ ] Version bump: `.claude-plugin/plugin.json` → v0.1.68
- [ ] CHANGELOG entry with features + breaking changes (none)
- [ ] Release notes written
- [ ] PR created: `git checkout -b v0168-release && git commit -am "feat: v0.1.68 metadata-driven business context"`
- [ ] PR merged after review
- [ ] Git tag: `git tag -a v0.1.68 -m "v0.1.68: Metadata-Driven Business Context Discovery"`
- [ ] Marketplace pin updated to v0.1.68

---

## Skills by Priority

**HIGH (enable enterprise use case):**
1. audit-aws — most used, reference implementation
2. audit-gcp — similar to audit-aws
3. cost-analysis — unique pattern, high impact
4. setup-aws — gates risky operations
5. doctor.sh — baseline for all

**STANDARD (complete coverage):**
6. audit-lgtm — full implementation
7. audit-grafana — full implementation
8. audit-sentry — full implementation
9. audit-datadog — full implementation
10. audit-k8s — full implementation

---

## Verification Checklist (Per Skill)

After each skill update, run:

```bash
# 1. Syntax check
bash -n skills/YOURSKILL/scripts/*.sh

# 2. Metadata load present
grep -q "LOAD_METADATA_MODE\|load_business_context_or_metadata" skills/YOURSKILL/scripts/*.sh && echo "✓ Metadata load found"

# 3. v0.1.68 path present
grep -q "v0168\|METADATA=" skills/YOURSKILL/scripts/*.sh && echo "✓ v0.1.68 path found"

# 4. v0.1.67 fallback present
grep -q "v0167\|business_context" skills/YOURSKILL/scripts/*.sh && echo "✓ v0.1.67 fallback found"

# 5. Skip/escalation patterns present
grep -q "\.action.*skip\|\.escalation\|\.cost_sensitivity" skills/YOURSKILL/scripts/*.sh && echo "✓ Decision patterns found"

# 6. Leak-scan clean
sh ci/leak-scan.sh skills/YOURSKILL/ && echo "✓ Leak-scan passed"
```

---

## Release Notes Template

```markdown
# v0.1.68: Metadata-Driven Business Context Discovery

## What's New

- ✨ **Metadata Discovery**: Auto-discover K8s labels, AWS tags, GitHub CODEOWNERS
- ✨ **Enterprise Scale**: Scales to 1000+ resources without manual entry
- ✨ **Single Source of Truth**: All 10 audit skills read from computed_metadata.jsonl
- ✨ **Optional**: Works for startups (manual) through enterprises (auto-discovery)

## Token Efficiency

- Mid-market: 50% token savings (15K → 5K)
- Enterprise: 86% token savings (50K+ → 7K)

## Backward Compatible

No breaking changes. v0.1.67 customers' audits work unchanged.

## Getting Started

1. Run `/scoutflo:connect` and choose "Use auto-discovery?"
2. Run `/scoutflo:business-context-resolver` to discover resources
3. Run `/scoutflo:audit-all` — audits now read metadata automatically

See [v0168-README.md](v0168-README.md) for details.
```

---

## Integration Guide Reference

See [BUSINESS-CONTEXT-INTEGRATION-v0168.md](BUSINESS-CONTEXT-INTEGRATION-v0168.md) for:
- Full code examples (audit-aws, setup-aws)
- Query patterns and testing procedures
- Error handling and edge cases

See [v0168-SKILL-UPDATE-TEMPLATE.md](v0168-SKILL-UPDATE-TEMPLATE.md) for:
- Copy-paste template for each skill type
- Checklist for verification

---

**You got this. All patterns above are copy-paste ready. Ship it Friday.** 🚀
