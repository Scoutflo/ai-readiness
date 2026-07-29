# Audit-All Wiring Checklist — v0.1.65 Final Phase

**Status:** All integration layers complete and tested. Wiring into audit-all is next.  
**Effort:** ~3–4 hours  
**Blocker:** None

---

## Pre-Wiring: Verify Test Suite

Run all 35 new tests to confirm baseline:

```bash
cd /Users/admin/ScoutfloWork/ScoutPlug/sre-toolkit

# If bats installed:
bats skills/doctor/tests/test-doctor-integration.sh
bats skills/redaction/tests/test-redaction-integration.sh
bats skills/cli-interactive/tests/test-cli-interactive-integration.sh
bats skills/business-context/tests/test-business-context-integration.sh
bats skills/checkpoint/tests/test-checkpoint-integration.sh
bats skills/audit-all/tests/test-v0165-integration-end-to-end.sh

# Expected: 35/35 passing
```

---

## Wiring Tasks

### Task 1: Audit-All Startup — Checkpoint + Business Context (45 min)

**File:** `skills/audit-all/SKILL.md` (Phase 1: Build the run plan)

**Add to Phase 1 after "List the top-level integration keys":**

```bash
# v0.1.65: Load checkpoint scope + business context
CHECKPOINT_LIB="${SKILLS_LIB}/checkpoint/lib"
BUSINESS_CONTEXT_LIB="${SKILLS_LIB}/business-context/lib"

. "${CHECKPOINT_LIB}/checkpoint.sh"
. "${BUSINESS_CONTEXT_LIB}/business-context.sh"

# Load or prompt for checkpoint scope
checkpoint_init_topology
audit_scope=$(checkpoint_load_scope)
if [ "$audit_scope" != "all" ]; then
  note "audit-all: scope = $audit_scope"
fi

# Prompt for business context if not set
business_context_init_topology
if ! jq -e '.business_context.team' ~/.scoutflo/topology.json >/dev/null 2>&1; then
  note "audit-all: capturing business context for first-time setup..."
  business_context_prompt
fi

# Show plan with scope and context
note "audit-all: Environment=$(business_context_get environment)"
```

**Acceptance Criteria:**
- [ ] Checkpoint scope loads (or defaults to "all")
- [ ] Business context prompts if missing (interactive)
- [ ] Both values displayed in audit plan
- [ ] Test: E2E integration test passes (test-v0165-integration-end-to-end.sh)

---

### Task 2: Audit-All Startup — CLI Interactive Confirmations (30 min)

**File:** `skills/audit-all/SKILL.md` (Phase 1, after checkpoint/context)

**Add after business context section:**

```bash
# v0.1.65: Interactive CLI confirmations
CLI_INTERACTIVE_LIB="${SKILLS_LIB}/cli-interactive/lib"
. "${CLI_INTERACTIVE_LIB}/cli-interactive.sh"

# Count total resources to audit
resource_count=$(calculate_estate_size "$audit_scope")  # existing function

# Pause if big operation
cli_pause_before_audit "$resource_count"

# Ask for exclusions
excluded_services=$(cli_prompt_exclude_services)
excluded_regions=$(cli_prompt_exclude_regions)
excluded_statuses=$(cli_prompt_exclude_statuses)

# Build filter
exclusion_filter=$(cli_build_exclusion_filter "$excluded_services" "$excluded_regions" "$excluded_statuses")
if [ -n "$exclusion_filter" ]; then
  note "audit-all: Applying exclusions: $exclusion_filter"
fi
```

**Acceptance Criteria:**
- [ ] Pause appears before large audits (>1000 resources)
- [ ] User can skip by pressing N (audit exits gracefully)
- [ ] Exclusion prompts work (comma-separated input accepted)
- [ ] Filters are built correctly
- [ ] Test: test-cli-interactive-integration.sh passes

---

### Task 3: Per-Audit Redaction (45 min)

**File:** `skills/audit-all/SKILL.md` (Phase 2: Run each audit)

**Modify "After each audit completes" section:**

```bash
# Standard: Run the audit
"$AUDIT_SKILL" --out "$AUDIT_OUTPUT_DIR"

# v0.1.65: Redact findings + report after audit completes
REDACTION_LIB="${SKILLS_LIB}/redaction/lib"
. "${REDACTION_LIB}/redaction-integration.sh"

if [ -f "$AUDIT_OUTPUT_DIR/findings.json" ]; then
  redaction_integration_findings "$AUDIT_OUTPUT_DIR/findings.json"
fi

if [ -f "$AUDIT_OUTPUT_DIR/report.md" ]; then
  redaction_integration_report "$AUDIT_OUTPUT_DIR/report.md"
fi
```

**Acceptance Criteria:**
- [ ] findings.json redacted in-place (no raw AWS keys, Stripe keys)
- [ ] report.md redacted (no Bearer tokens, API keys)
- [ ] No error if file missing (graceful skip)
- [ ] Test: test-redaction-integration.sh passes
- [ ] Verify manually: grep for "AKIA" or "sk_live_" in findings files (should find none)

---

### Task 4: K8s Skill Integration (20 min)

**File:** `skills/audit-all/SKILL.md` (Phase 2, after existing audits)

**Add new block after the audit loop:**

```bash
# v0.1.65: Kubernetes audit (if available)
if command -v kubectl >/dev/null 2>&1; then
  K8S_LIB="${SKILLS_LIB}/audit-kubernetes/lib"
  . "${K8S_LIB}/k8s-audit.sh"
  
  KUBE_CLUSTER=$(k8s_get_cluster_info)
  KUBE_AUDIT_DIR="${AUDITS_DIR}/${RUN_DATE}/audit-kubernetes/${KUBE_CLUSTER}"
  
  note "audit-all: auditing Kubernetes cluster: $KUBE_CLUSTER"
  k8s_audit_findings "$KUBE_CLUSTER" "$KUBE_AUDIT_DIR"
  k8s_audit_report "$KUBE_CLUSTER" "$KUBE_AUDIT_DIR"
  
  # Redact K8s findings too
  if [ -f "$KUBE_AUDIT_DIR/findings.json" ]; then
    redaction_integration_findings "$KUBE_AUDIT_DIR/findings.json"
  fi
else
  note "audit-all: kubectl not found; skipping Kubernetes audit"
fi
```

**Acceptance Criteria:**
- [ ] K8s audit skipped gracefully if kubectl unavailable
- [ ] K8s audit runs when kubectl available
- [ ] Output appears in correct directory structure
- [ ] Findings redacted automatically
- [ ] Test: E2E integration test passes

---

### Task 5: Doctor Persistence in Audit-All (15 min)

**File:** `skills/audit-all/SKILL.md` (Phase 1, before audit loop)

**Add doctor initialization:**

```bash
# v0.1.65: Initialize doctor persistence
DOCTOR_LIB="${SKILLS_LIB}/doctor/lib"
. "${DOCTOR_LIB}/doctor-persistence.sh"
. "${DOCTOR_LIB}/doctor-integration.sh"

if [ -f "${DOCTOR_LIB}/doctor-integration.sh" ]; then
  doctor_integration_init
  note "audit-all: doctor persistence enabled (state: ~/.scoutflo/doctor-state.json)"
fi
```

**Note:** doctor.sh itself already wired. This just ensures state is initialized before audit-all if run standalone.

**Acceptance Criteria:**
- [ ] doctor-state.json created if missing
- [ ] doctor.sh runs normally (skipping passed checks automatically)
- [ ] Test: test-doctor-integration.sh passes

---

### Task 6: Cross-References (30 min)

**File:** `skills/audit-all/SKILL.md` (Phase 5: Collect results)

**Add after collecting findings:**

```bash
# v0.1.65: Add cross-references across all findings
XREF_LIB="${SKILLS_LIB}/cross-references/lib"
. "${XREF_LIB}/cross-references.sh"

RUN_DATE="$(date -u +%F)"

# Build cross-reference links for each audit
for findings_file in "$AUDITS_DIR"/*/"$RUN_DATE"/findings.json; do
  [ -e "$findings_file" ] || continue
  
  audit_name=$(basename "$(dirname "$(dirname "$findings_file")")")
  xref_add_to_findings "$findings_file" "$RUN_DATE"
  
  report_file="$(dirname "$findings_file")/report.md"
  if [ -f "$report_file" ]; then
    # Extract first finding ID from this audit for report linking
    first_id=$(jq -r '.findings[0].id // empty' "$findings_file" 2>/dev/null || true)
    if [ -n "$first_id" ]; then
      xref_add_to_report "$first_id" "$report_file" "$RUN_DATE"
    fi
  fi
done

note "audit-all: cross-references built (each finding linked to related findings in other audits)"
```

**Acceptance Criteria:**
- [ ] related_findings array added to each finding in findings.json
- [ ] Cross-ref section appended to each report.md
- [ ] No errors if no related findings exist
- [ ] Test: test-v0165-integration-end-to-end.sh passes

---

### Task 7: Slack Brief Redaction (15 min)

**File:** `skills/audit-all/SKILL.md` (Phase 5, when sending Slack brief)

**Modify the Slack brief section:**

```bash
# v0.1.65: Redact Slack brief before sending
REDACTION_LIB="${SKILLS_LIB}/redaction/lib"
. "${REDACTION_LIB}/redaction-integration.sh"

SLACK_BRIEF="... (existing brief construction) ..."

# Redact the brief
SLACK_BRIEF=$(redaction_integration_slack_brief "$SLACK_BRIEF")

# Then send as normal
curl -X POST "$SLACK_WEBHOOK" \
  -H 'Content-Type: application/json' \
  --data "{\"text\": \"$SLACK_BRIEF\"}"
```

**Acceptance Criteria:**
- [ ] Slack brief redacted before posting (no secrets visible)
- [ ] Brief still readable after redaction
- [ ] Test: test-redaction-integration.sh passes

---

## Wiring Verification

After each task, run the corresponding test:

| Task | Test File | Verify |
| --- | --- | --- |
| 1. Checkpoint | test-v0165-integration-end-to-end.sh | Phase 1 section |
| 2. CLI Interactive | test-cli-interactive-integration.sh | All 6 tests |
| 3. Redaction | test-redaction-integration.sh | All 6 tests |
| 4. K8s | test-v0165-integration-end-to-end.sh | K8s section |
| 5. Doctor | test-doctor-integration.sh | All 5 tests |
| 6. Cross-Refs | test-v0165-integration-end-to-end.sh | Xref section |
| 7. Slack | test-redaction-integration.sh | Slack brief test |

---

## Final Integration Test

After all tasks complete:

```bash
cd /Users/admin/ScoutfloWork/ScoutPlug/sre-toolkit
bats skills/audit-all/tests/test-v0165-integration-end-to-end.sh

# Should pass all checks:
# ✓ checkpoint initializes topology
# ✓ checkpoint saves scope
# ✓ business context captures metadata
# ✓ doctor initializes and saves state
# ✓ doctor skip logic prevents re-runs
# ✓ redaction removes secrets from findings
# ✓ redaction removes secrets from reports
# ✓ cli interactive filter builder
# ✓ cross-references creates linkage
# ✓ full integration checkpoint to redaction
```

---

## Production Measurement

Once all wiring complete:

```bash
# Run audit-all on full estate (or mock of 1500 resources)
/scoutflo:audit-all

# Check outputs
ls -lah ~/.scoutflo/doctor-state.json
ls -lah ~/.scoutflo/topology.json
ls -lah ./scoutflo-audits/2026-07-30/*/findings.json

# Verify redaction worked
grep -r "AKIA" ./scoutflo-audits/2026-07-30/*/findings.json
# Should find nothing (if secrets existed before, they're now redacted)

# Measure token efficiency
# Baseline: 720K tokens (v0.1.64 full audit)
# With checkpoint scope: 720K → ~360K (50% save)
# On 2nd run with doctor skip: 360K → ~72K (80% skip save)
```

---

## Rollback Plan

If wiring breaks existing audits:

```bash
# Remove wiring additions one by one
# Start with checkpoint (least critical)
# Then business-context, CLI, redaction, K8s, xref, doctor

# Each removal is clean (no shared state, no side effects)
# doctor.sh wiring has fallback: if doctor-state missing, runs normally
# redaction wiring has fallback: if file missing, skips gracefully
# All backward compatible (if scope not set, defaults to "all")
```

---

## Acceptance Criteria (Overall)

- [x] All 35 unit tests passing (baseline)
- [x] All integration layers separated and tested
- [x] doctor.sh wired (half of Task 5 done)
- [ ] audit-all startup wired (Tasks 1–2)
- [ ] Per-audit redaction wired (Task 3)
- [ ] K8s skill wired (Task 4)
- [ ] Doctor integration in audit-all (Task 5 completion)
- [ ] Cross-references wired (Task 6)
- [ ] Slack brief redaction wired (Task 7)
- [ ] E2E test passes (test-v0165-integration-end-to-end.sh)
- [ ] No regressions in existing audits
- [ ] North star metrics measured on real data

---

## Timeline

| Task | Time | Cumulative |
| --- | --- | --- |
| 1. Checkpoint + Context | 45 min | 45 min |
| 2. CLI Interactive | 30 min | 75 min |
| 3. Redaction | 45 min | 120 min |
| 4. K8s Skill | 20 min | 140 min |
| 5. Doctor in audit-all | 15 min | 155 min |
| 6. Cross-Refs | 30 min | 185 min |
| 7. Slack Brief | 15 min | 200 min |
| **Total** | **3h 20min** | **3h 20min** |

Plus 30 min for testing + bugfixes = **~4 hours total**

---

## Deployment

After wiring complete + all tests passing:

```bash
cd /Users/admin/ScoutfloWork/ScoutPlug/sre-toolkit

# Run gates
sh ci/leak-scan.sh .
sh ci/structure-check.sh .
claude plugin validate . --strict

# Bump version (v0.1.65)
jq '.version = "0.1.65"' .claude-plugin/plugin.json > plugin.tmp
mv plugin.tmp .claude-plugin/plugin.json

# Update changelog
echo "## v0.1.65 (2026-07-30)
- Doctor persistence: state saved to ~/.scoutflo/doctor-state.json
- Checkpoint scope: interactive service selection + batching
- Business context: team/environment/SLA metadata
- Redaction guardrail: secrets removed from findings + reports
- K8s audit exposure: /scoutflo:audit-kubernetes integrated
- Cross-references: findings linked across audits
- CLI interactive: pause + filter before large audits" >> CHANGELOG.md

# Commit
git add .
git commit -m "feat: v0.1.65 — all integration layers wired + production ready"
git tag v0.1.65
git push origin main --tags
```

---

**Status:** Ready to execute. No blockers.

**Next:** Start Task 1 (Checkpoint + Business Context wiring). Estimated completion: Today EOD or tomorrow morning.
