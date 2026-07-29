# Rollback & Incident Response Plan

**Internal Spec Only — Local Development**

How to detect, respond to, and roll back regressions or incidents in production.

---

## Incident Severity Levels

| Level | Definition | Example | Response Time |
|-------|-----------|---------|---|
| **P1 (Critical)** | Production unavailable, audits crashing, data loss | audit-all crashes on all estates | 15 min |
| **P2 (High)** | Significant functionality broken, findings wrong | 50% of findings missing due to redaction bug | 1 hour |
| **P3 (Medium)** | Feature broken, workaround exists | Checkpoint interactive prompts crash on special chars | 4 hours |
| **P4 (Low)** | Minor UX issue, non-functional impact | Typo in log message | Next release |

---

## Detection Mechanisms

### 1. Automated Regression Detection

**What gets tested after each release:**

```bash
#!/bin/bash
# run-regression-tests.sh

# Test 1: Audit all 12 skills on mock estate (100 resources each)
for skill in audit-{aws,grafana,sentry,pagerduty,lgtm,gcp,digitalocean,datadog,kubernetes,github,jira,zenduty}; do
    echo "Testing $skill..."
    timeout 60 /scoutflo:$skill > /tmp/regression_$skill.log 2>&1
    
    if [ $? -ne 0 ]; then
        # Skill failed
        echo "REGRESSION: $skill failed"
        exit 1
    fi
    
    # Check for expected output
    if ! grep -q "findings" /tmp/regression_$skill.log; then
        echo "REGRESSION: $skill produced no findings"
        exit 1
    fi
done

# Test 2: Checkpoint workflow
/scoutflo:checkpoint --scope-select --auto-skip-prompt
if [ $? -ne 0 ]; then
    echo "REGRESSION: Checkpoint failed"
    exit 1
fi

# Test 3: Doctor workflow
/scoutflo:doctor
if [ $? -ne 0 ]; then
    echo "REGRESSION: Doctor failed"
    exit 1
fi

# Test 4: Verify no secrets in mock findings
if grep -E "AKIA[0-9A-Z]{16}" /tmp/regression_*.log; then
    echo "REGRESSION: Secrets leaked"
    exit 1
fi

echo "All regression tests PASSED"
```

### 2. Manual QA Gate (Before Release)

**Checklist:**

```
Before tagging release:
  [ ] Run full E2E on mock CoinDCX estate (1000 resources)
  [ ] Verify 12 audits complete, findings generated
  [ ] Run doctor, verify skip logic works
  [ ] Verify no secrets in report
  [ ] Verify cross-references present
  [ ] Verify checkpoint batching works on large estates
  [ ] Test interactive CLI confirmations
  [ ] Verify business context applied correctly
  [ ] Verify backward compat (all 12 skills work unchanged)
```

### 3. Live Incident Indicators

**What to watch in production:**

```
Dashboards/Alerts:
  • Audit success rate < 99% (indicates crashes)
  • Doctor failure rate > 5% (indicates state corruption)
  • Report generation time > 10 min (indicates performance regression)
  • Secrets found in reports (redaction bypass)
  • Customer support tickets about "findings missing" (correlation bug)
```

---

## Incident Response Playbook

### When You Discover an Incident

#### Step 1: Confirm Severity (5 min)

```bash
# Determine if it's P1, P2, P3, or P4

# P1: Audit crashing
/scoutflo:audit-all
# If: exit code != 0 AND multiple customers reporting
#   → P1 CONFIRMED

# P2: Findings wrong (missing or duplicated)
# If: "87 findings deduplicated to 42" now shows "42 deduplicated to 87"
#   AND customer reports "findings doubled"
#   → P2 CONFIRMED

# P3: Feature broken but workaround exists
# If: Checkpoint crashes on special characters
#   BUT user can workaround by avoiding special chars
#   → P3 CONFIRMED
```

#### Step 2: Declare Incident & Notify

```bash
# Create incident doc
cat > /tmp/incident-$(date +%Y%m%d-%H%M%S).md << 'EOF'
# Incident Report

**Date:** 2026-07-30T15:00:00Z
**Severity:** P2
**Title:** Findings deduplicated incorrectly (42 → 87)

**Observed:**
  - Correlation engine produces too many findings
  - Duplicates not detected
  - Affected versions: v0.1.66.x

**Impact:**
  - CoinDCX audit shows 87 findings instead of 42
  - False positives causing alert fatigue
  - Actionable findings obscured

**Root Cause:** [TO BE DETERMINED]

**Timeline:**
  15:00 - Issue discovered in CoinDCX audit
  15:05 - Incident declared P2
  15:10 - Rollback plan initiated

EOF

# Notify (if relevant)
# echo "INCIDENT: v0.1.66 regression detected. Rolling back to v0.1.65." | mail -s "Incident" team
```

#### Step 3: Gather Evidence

```bash
# Collect logs and state files
mkdir -p /tmp/incident-evidence

# Capture current state
cp ~/.scoutflo/doctor-state.json /tmp/incident-evidence/
cp ~/.scoutflo/metrics.log /tmp/incident-evidence/
cp scoutflo-audits/*/correlation.json /tmp/incident-evidence/ 2>/dev/null

# Capture audit logs
journalctl -u scoutflo-plugin -n 1000 > /tmp/incident-evidence/plugin.log 2>/dev/null
cat ~/.scoutflo/audit-all.log > /tmp/incident-evidence/audit-all.log 2>/dev/null

# Show evidence
echo "Incident evidence collected in /tmp/incident-evidence/"
ls -lah /tmp/incident-evidence/
```

#### Step 4: Identify Root Cause (30 min - 2 hours)

```bash
# For P1: Immediate rollback (see below)
# For P2/P3: Quick analysis

# Example: Correlation engine deduplication bug

# Check if findings are actually duplicates
jq '.deduplicated_findings[] | select(.dedup_id == "DEDUP-001")' correlation.json

# If overlaps not detected:
# → Bug in overlap detection algorithm
# → Check: overlap_similarity threshold
# → Check: service name matching logic

# If duplicates wrong:
# → Bug in deduplication logic
# → Check: master finding selection
# → Check: dedup_id assignment
```

---

## Rollback Procedures

### Option 1: Immediate Rollback (P1/P2)

```bash
#!/bin/bash
# rollback.sh — Immediate rollback to prior stable version

TARGET_VERSION="v0.1.65"  # Previous stable release

echo "Rolling back to $TARGET_VERSION..."

# Step 1: Stop current version (if running)
pkill -f scoutflo-plugin
sleep 2

# Step 2: Remove current version
rm -rf ~/.scoutflo/plugin/*
rm -rf ~/ScoutfloWork/ScoutPlug/sre-toolkit/skills/*

# Step 3: Restore prior version
git fetch origin
git checkout "$TARGET_VERSION" -- sre-toolkit/

# Step 4: Reinstall
npm install || pip install -r requirements.txt
# (whatever build step)

# Step 5: Verify rollback
/scoutflo:audit-aws --dry-run
if [ $? -eq 0 ]; then
    echo "✓ Rollback successful"
    exit 0
else
    echo "✗ Rollback failed"
    exit 1
fi
```

### Option 2: Quick Patch (P3/P4)

If root cause is identified and fix is <1 hour:

```bash
#!/bin/bash
# patch-and-redeploy.sh

# Example: Fix checkpoint crashing on special characters

cd ~/ScoutfloWork/ScoutPlug/sre-toolkit/

# Step 1: Fix the bug
# (edit file, add escape logic)
sed -i 's/checkpointName=$1/checkpointName=$(echo "$1" | sed "s/[^a-zA-Z0-9_-]/_/g")/g' skills/inventory-checkpoint/lib/checkpoint.sh

# Step 2: Test the fix
bash tests/checkpoint_special_chars_test.sh
if [ $? -ne 0 ]; then
    echo "Fix didn't work"
    git checkout -- .  # Revert
    exit 1
fi

# Step 3: Verify no new regressions
bash run-regression-tests.sh
if [ $? -ne 0 ]; then
    echo "Fix caused new regression"
    git checkout -- .
    exit 1
fi

# Step 4: Commit and tag patch version
git add -A
git commit -m "hotfix: checkpoint special char escape (v0.1.66.1)"
git tag -a v0.1.66.1 -m "Hotfix: checkpoint special chars"

echo "Patch deployed as v0.1.66.1"
```

### Option 3: Feature Flag Disable

For bugs in specific features only (e.g., correlation engine):

```bash
# Edit topology.json to disable problematic feature

jq '.feature_flags.correlation_engine_enabled = false' topology.json > topology.json.tmp
mv topology.json.tmp topology.json

# Restart
pkill -f scoutflo-plugin
/scoutflo:start

# Correlation will be skipped, audits continue normally
```

---

## Post-Incident Actions

### 1. Root Cause Analysis (Within 24 hours)

```markdown
## RCA Template

**Incident:** Correlation engine deduplicates incorrectly (42 → 87)

**Root Cause:** 
  Similarity threshold too low (0.7 instead of 0.8)
  Two unrelated findings (AWS-023 "CloudWatch alarm" vs GRAFANA-018 "Grafana alert rule")
  were marked as duplicates due to keyword overlap ("alarm" vs "alert rule")

**Why Wasn't This Caught?**
  Unit tests used realistic finding pairs (all overlapped)
  No test for "similar keywords but different services" case
  Integration test data too small (10 findings, 0 false positives)

**Prevention:**
  Add unit test: "Test non-duplicate findings with similar keywords"
  Increase test coverage: 100+ synthetic finding pairs
  Add metrics dashboard: Track dedup false positive rate in production
```

### 2. Fix Verification

```bash
# After root cause fix is deployed

# Test 1: Original failure case now passes
/scoutflo:audit-all > test_output.log
if grep -q "87 findings.*42 deduplicated" test_output.log; then
    echo "✓ Original bug fixed"
else
    echo "✗ Bug persists"
    exit 1
fi

# Test 2: No new regressions
bash run-regression-tests.sh

# Test 3: Metrics show improvement
# Before: dedup false positive rate 23%
# After: dedup false positive rate 0%
grep "false_positive_rate" metrics.log
```

### 3. Knowledge Capture

```bash
# Add to testing strategy
cat >> docs/incident-learnings.md << 'EOF'

## Incident: v0.1.66 Correlation Deduplication (2026-07-30)

**What happened:**
  Similarity threshold 0.7 was too low, caused false dedup positives

**What we added:**
  1. Increased unit test coverage for edge cases
  2. Added synthetic finding pairs (100+ realistic scenarios)
  3. Production metrics for dedup accuracy
  4. Pre-release regression test gate

**New test:** tests/correlation_edge_cases_test.sh
  - Tests: similar keywords, different services
  - Tests: same service, different issue types
  - Tests: edge case similarity scores (0.6-0.9)

EOF
```

### 4. Release Post-Mortem

```markdown
## Post-Mortem: v0.1.66 Regression

**Date:** 2026-07-30
**Severity:** P2
**Time to Detect:** 2 hours (post-release)
**Time to Resolve:** 4 hours (patch + redeploy)

**Prevention for Next Time:**
  [ ] Run full regression tests before releasing (was skipped due to time pressure)
  [ ] Add pre-release QA gate (check dedup accuracy on 1000-finding corpus)
  [ ] Automate regression testing in CI/CD
  [ ] Set up production metrics dashboard (catch issues same-day)

**Owner:** [Engineer name]
**Sign-off:** [Tech lead]
```

---

## Safe Rollback Checklist

Before rolling back, verify it's safe:

```
[ ] Incident confirmed (not false alarm)
[ ] Severity assessed (P1/P2 = rollback, P3/P4 = patch)
[ ] Backup created (/tmp/incident-evidence/)
[ ] Root cause understood (or at least, incident prevented by rollback)
[ ] Prior version tested and known-good
[ ] Customer impact assessed (who will be affected)
[ ] Communication plan (who to notify)
[ ] Post-rollback verification plan (how to confirm it worked)

If all checked:
  → Safe to rollback
  
If any unchecked:
  → More investigation needed before rollback
```

---

## Communication Template

### To Team

```
Subject: INCIDENT: v0.1.66 Regression — Rolling Back to v0.1.65

A regression was detected in v0.1.66 correlation engine (dedup accuracy).

Actions:
  • Immediate rollback to v0.1.65 in progress
  • Root cause being analyzed
  • Fix will be deployed as v0.1.66.1 (ETA: 4 hours)

No action required from you. Audits will continue normally during rollback.
```

### To Customers (if needed)

```
We've detected a minor issue in the latest release and are rolling back to the prior stable version as a precaution.

Your audits are continuing normally. We'll redeploy a fix later today.

No findings were lost. Please re-run audits after we redeploy v0.1.66.1 for accurate results.

Questions? Contact: [support email]
```

---

## Prevention Checklist (For Future Releases)

Before tagging any release:

```
Code Quality:
  [ ] All unit tests pass (100%)
  [ ] All integration tests pass
  [ ] Code review completed
  [ ] No known warnings or TODOs related to features

Regression Testing:
  [ ] Full E2E test on mock CoinDCX estate (1000 resources)
  [ ] All 12 audit skills tested
  [ ] Backward compat verified (v0.1.64 features work)
  [ ] No secrets leaked in reports
  [ ] No performance regressions (wall-clock time)

Metrics & Instrumentation:
  [ ] North star metrics measured on real data
  [ ] Token efficiency verified
  [ ] Finding dedup accuracy >= 95%
  [ ] Doctor skip rate >= 70% on re-run

Customer-Specific QA:
  [ ] CoinDCX estate tested (if applicable)
  [ ] Production-like data used (not synthetic)
  [ ] Long-running audits tested (>10 min)

Documentation:
  [ ] Changelog updated
  [ ] Known issues documented
  [ ] Rollback procedure tested

Sign-Off:
  [ ] Tech lead approval
  [ ] QA lead approval
  [ ] Ready for production
```

---

**This is internal incident response spec. Not shipped to customers.**

