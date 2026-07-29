# Execution Runbook: How to Use the Live SSOT

**Purpose:** Practical guide for using `EXECUTION-ROADMAP-LIVE.md` during implementation  
**Audience:** Engineers implementing v0.1.65-0.1.68 features  
**Status:** Reference doc — always open alongside the SSOT  

---

## Quick Start

### Before You Start a Feature

```bash
# 1. Open the SSOT
less sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md

# 2. Find your phase + feature
#    Example: v0.1.65, Feature 1 (Inventory Checkpoint)

# 3. Read "Continuous Verification Checklist" for your feature
#    These are your acceptance criteria

# 4. Start coding
```

### Every Time You Commit

```bash
# 1. Run verification checklist items (the ones relevant to your work)
#    Example: tests pass? jq works? state persists?

# 2. Add a live event entry to EXECUTION-ROADMAP-LIVE.md
#    Format: [TIMESTAMP] ENGINEER: BRIEF_DESC
#           - What changed?
#           - Commit: abc123
#           - Status: X/Y done
#           - Blockers: none or specific blocker

# 3. If reality != plan, add a [DRIFT] entry
#    Format: [DRIFT: TYPE] Description of mismatch
#           - Planned: X
#           - Actual: Y
#           - Root cause: Z
#           - Action: what we're doing about it

# 4. Commit everything (including SSOT updates)
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "feat: checkpoint UX improvements

- Added progress indicator for batch processing
- Tests pass on 1000 object estate
- Token counting working correctly

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Pattern: The Daily Update

### Every Morning (Or Before Sync)

**Time: 5 minutes**

```bash
# 1. Check SSOT status dashboard
#    What changed since yesterday?

# 2. Review live events log
#    Any new drifts or blockers?

# 3. Review drift log specifically
#    Are there outstanding issues?

# 4. If you see a problem → investigate NOW (don't batch it)
#    Update decision log if you change course
```

### When You Hit a Problem

**Don't batch problems. Catch them in real-time.**

```bash
# Example: Redaction catches "password reset" as a secret

# 1. Update SSOT IMMEDIATELY
#    [2026-08-02 DRIFT: DESIGN] Redaction too aggressive
#    - Planned: Catch API keys only
#    - Actual: Catches "password reset" as false positive
#    - Root cause: Regex too broad
#    - Impact: Breaking legitimate debug logs
#    - Action: Switch to whitelist approach

# 2. Investigate root cause
#    - What regex pattern is matching?
#    - Why is it too broad?
#    - What's the right approach?

# 3. Fix it (same session if possible)
#    - Implement whitelist patterns
#    - Test on sample logs
#    - Add unit tests to prevent recurrence

# 4. Update SSOT again
#    [2026-08-02] DRIFT RESOLVED: Redaction whitelist implemented
#    - Commit: ghi9012
#    - Tests: 100 sample logs, 0 false positives
#    - Status: Ready for integration

# 5. Commit everything together
```

---

## Pattern: Feature Completion

### When You Finish a Feature

**Checklist:**

```bash
# 1. Complete the continuous verification checklist
#    Go through EVERY item (not just the ones you think matter)
#    Mark each as [ ] Not Done or [✓] Done with evidence

# 2. Add final live event
#    [2026-08-02 16:30 IST] Engineer C: Redaction feature complete
#    - Commit: ghi9012
#    - Status: All verification items passed
#    - Evidence: 100+ logs tested, 0 false positives, unit tests added
#    - Blockers: None
#    - Next: Ready for integration with audit pipeline

# 3. Update feature table for your phase
#    Status: [✓] | % Done: 100% | Owner: Eng C

# 4. Commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/skills/redaction.sh
git commit -m "feat: redaction guardrail complete

[Redaction Feature Verification]
  [✓] 100+ logs redacted, 0 secrets exposed
  [✓] False positives minimized (whitelist approach)
  [✓] Redacted in report.md AND Slack briefs
  [✓] No API keys, AWS secrets, tokens visible

All verification items passed.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Pattern: Handling Blockers

### When You Get Stuck

**Don't debug silently. Update SSOT, then escalate.**

```bash
# 1. Document the blocker in SSOT
#    - What's blocking?
#    - What did you try?
#    - What failed?

# 2. Example: Doctor state save not working

# Add to Dependencies & Blockers section:
# | Doctor persistence test failing | v0.1.65 | Doctor Persistence | Investigating | Eng B fix tomorrow | TBD |

# Add to live events:
# [2026-08-02 BLOCKER] Doctor state save failing
# - Feature: Doctor persistence
# - Issue: jq save to ~/.scoutflo/doctor-state.json not executing
# - Error: "jq: parse error" (syntax issue)
# - Tried: Different quoting, different paths
# - Next: Need fresh eyes, escalating to Kalpesh
# - Owner: Eng B
# - Status: Blocked, but not critical path

# 3. Commit (with WIP marker if not ready)
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "docs: doctor-state save blocker, escalating

[BLOCKER] jq save function not working
- Error: parse error on JSON generation
- Root cause: Unknown (likely quoting issue)
- Impact: Blocks doctor-state persistence feature
- Owner: Eng B, escalating to Kalpesh

Co-Authored-By: Claude <noreply@anthropic.com>"

# 4. Message Kalpesh/team with link to commit
#    "Blocker on doctor-state save — see commit abc123 for details"

# 5. Team unblocks within 1-2 hours (because it's not batched)
```

---

## Pattern: Token Measurement

### When You Measure Tokens

**Token data is precious. Capture it immediately.**

```bash
# Example: First audit run shows 298K tokens (vs 600K planned)

# 1. Calculate actual vs planned
#    - Planned: 600K
#    - Measured: 298K
#    - Variance: 50% savings (vs 50-70% target)
#    - Status: ON TARGET ✓

# 2. Add to North Star Metrics section
#    | Full estate audit (1000+ resources) | 600K → 300K (50% save) | 298K MEASURED ✓ | [✓] Measured | Commit abc123 | 2026-08-02 |

# 3. Update live events
#    [2026-08-02 10:15 IST] Token savings verified!
#    - Feature: Inventory checkpoint
#    - Measurement: Scoped audit 600K → 298K (50% savings, exceeds target)
#    - Evidence: Commit abc123, audit log output
#    - Impact: North star metric confirmed achievable
#    - Next: Document in release notes

# 4. Commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "data: token savings measured and verified

First audit run with inventory checkpoint shows 50% token savings:
- Full estate: 600K tokens
- Scoped (critical services only): 298K tokens
- Savings: 50% (meets target)
- Confidence: High

Updated EXECUTION-ROADMAP-LIVE.md with measurement.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Pattern: Drift Investigation

### When You Discover a Mismatch

**Always ask: "Why did reality differ from plan?"**

```bash
# Scenario: Checkpoint took 3 days, not 1 day

# 1. Add [DRIFT] entry immediately
#    [DRIFT: TIME] Checkpoint took 3x longer than estimated
#    - Planned: 1 day
#    - Actual: 3 days (Eng A's commits on Aug 1, 2, 3)
#    - Root cause: Interactive prompt logic more complex than expected
#                  jq performance on nested filtering
#                  User testing revealed UX issues with initial design
#    - Impact: v0.1.65 overrun by 2 days
#    - Mitigation: Reduce filtering complexity, use simpler logic
#    - Decision: Accept overrun, adjust remaining features
#    - Next: Update v0.1.66 start date +1 day

# 2. Root-cause analysis
#    - Look at commits
#    - Look at test failures
#    - Talk to the engineer
#    - Understand what was unexpected

# 3. Update decision log
#    | 2026-08-03 | Adjust v0.1.65 timeline +2 days | 8 days → 10 days | Checkpoint complexity higher than modeled | Eng A + Kalpesh | Approved |

# 4. Decide: keep going or pause?
#    - If drift is manageable → adjust plan, keep shipping
#    - If drift is critical → pause, fix, re-estimate
#    - Example: +2 days is OK, we can absorb it in non-critical path

# 5. Update north star metrics if needed
#    - Were targets affected? Update them
#    - Was scope affected? Update it
#    - Was team/timeline affected? Update it

# 6. Commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "docs: v0.1.65 timeline adjusted (+2 days)

[DRIFT ANALYSIS] Checkpoint implementation took 3x longer than estimated
Root causes:
- Interactive prompt design more complex than modeled
- jq performance on nested object filtering
- User testing revealed UX issues (added progress indicator)

Decision: Adjust v0.1.65 from 8 days to 10 days. Non-critical path item (batching) deferred.

Remaining features still on track. v0.1.66 start adjusted from 2026-08-08 to 2026-08-10.

Co-Authored-By: Claude <noreply@anthropic.com>"

# 7. Inform team immediately (don't wait for sync)
#    Slack: "Checkpoint timeline adjusted +2 days (see commit abc123). v0.1.66 starts Aug 10 instead of Aug 8."
```

---

## Pattern: Phase Completion & Go/No-Go

### When Phase Is Done

**Don't ship until gate is checked.**

```bash
# 1. Verify all features in phase are complete
#    [ ] Feature 1: done
#    [ ] Feature 2: done
#    [ ] Feature 3: done
#    [ ] Feature N: done

# 2. Go through continuous verification checklist line by line
#    This is NOT optional. Check everything.

# 3. Update phase section with go/no-go decision
#    Go/No-Go Decision: [✓] GO

# 4. Document any conditional go items
#    If there are minor issues:
#    Go/No-Go Decision: [✓] CONDITIONAL GO
#    Notes: "Redaction has 1 known false positive on pattern X. 
#            Whitelist fix scheduled for v0.1.66. Does not block foundation features."

# 5. Commit phase completion
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/.claude-plugin/plugin.json sre-toolkit/CHANGELOG.md
git commit -m "release: v0.1.65 complete, passing go/no-go gate

[v0.1.65 VERIFICATION SUMMARY]

Phase Duration: 10 days (planned 8, +2 drift documented in SSOT)

Verification Checklist: ALL ITEMS PASSING
  [✓] Checkpoint Logic: All items verified
  [✓] Doctor Persistence: All items verified
  [✓] Business Context: All items verified
  [✓] Redaction: 100+ logs, 0 secrets (1 minor false positive, whitelisted)
  [✓] K8s Exposure: Audit visible in catalog
  [✓] Batching Strategy: 1180 EC2 → 6 batches
  [✓] Backward Compatibility: All 12 audits work

North Star Metrics:
  [✓] Token efficiency: 600K → 298K (50% savings, meets target)
  [✓] Findings dedup: 87 → 42 (pending correlation engine)
  [✓] No regressions: v0.1.64 features intact

Go/No-Go Decision: [✓] GO

Ready for v0.1.66 (Correlation). Unblocks next phase.

Co-Authored-By: Claude <noreply@anthropic.com>"

# 6. Tag release
git tag -a v0.1.65 -m "v0.1.65 Foundation: Checkpoint + Doctor + Context

Features:
- Inventory checkpoint (50% token savings)
- Doctor persistent state (auto-detect fixes)
- Business context skill (find prioritization)
- Redaction guardrail (prevent secret leaks)
- K8s skill exposure (audit Kubernetes)
- Batching strategy (handle 1000+ estates)
- Cross-references (link findings)

Metrics verified:
- Token savings: 50% (vs 50-70% target)
- Backward compatible: 100%
- Quality: All verification items passing

Team: Eng A (checkpoint), Eng B (doctor + context), Eng C (redaction + K8s)
Duration: 10 days (2 days drift documented)

Ready for production v0.1.67."

git push origin v0.1.65
```

---

## Command Reference

### Quick Git Workflow

```bash
# Standard feature commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md [feature files]
git commit -m "feat: checkpoint interactive prompts

- Prompts user for service selection
- Saves scope to topology.json
- Tests passing: 50 unit tests
- Verified: Batching works on 1000 object estate

Co-Authored-By: Claude <noreply@anthropic.com>"

# Drift/blocker commit (when things don't match plan)
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "docs: checkpoint performance drift (+2 days)

[DRIFT: TIME] Checkpoint took 3x longer than estimated
- Planned: 1 day
- Actual: 3 days
- Root cause: UX complexity + jq performance tuning

Updated timeline: v0.1.65 now 10 days (was 8).
Non-critical features (batching) deferred 1 day.

Co-Authored-By: Claude <noreply@anthropic.com>"

# Token measurement commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md
git commit -m "data: token efficiency verified at 50% savings

Measured on CoinDCX staging (1180 EC2 estate):
- Full audit: 600K tokens
- Scoped to critical services: 298K tokens
- Savings: 50% (meets target)

Updated EXECUTION-ROADMAP-LIVE.md north star metrics.

Co-Authored-By: Claude <noreply@anthropic.com>"

# Phase completion commit
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md [version bump files]
git commit -m "release: v0.1.65 complete, go/no-go gate PASSED

[Phase Verification]
- 10 days elapsed (planned 8, +2 documented)
- All features complete
- Continuous verification checklist: 100% passing
- North star metrics: on target

Commit to production v0.1.66.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## FAQ: Using the Live SSOT

### Q: "How often should I update the SSOT?"

**A:** After every meaningful commit. "Meaningful" means:
- You implemented a feature
- You fixed a blocker
- You measured something
- You discovered a mismatch
- You made a decision

Updates should take ~2 minutes. Don't over-document, just capture the delta.

### Q: "What if I forget to update the SSOT?"

**A:** Next person (or you tomorrow) will notice the doc is stale compared to git log. You'll update it then. But don't batch updates — if you notice during standup that yesterday's commit isn't in the SSOT, add it immediately.

### Q: "Should every single test result go in the SSOT?"

**A:** No. Only things that:
- Verify a checklist item (e.g., "100+ logs tested, 0 false positives")
- Impact the plan (e.g., "took 2x longer than expected")
- Validate a metric (e.g., "token count measured: 298K")

Don't add: "ran unit tests, 5 passed" (that's in git log already).

### Q: "What if the plan needs to change?"

**A:** Document it in decision log with why. Then update the plan itself if it's significant. Keep history visible.

### Q: "Can multiple engineers update the same SSOT?"

**A:** Yes, but coordinate on large changes. Use git merge to handle conflicts. Each engineer adds their own live events + discoveries, so conflicts should be rare.

### Q: "When do we look back at this document?"

**A:** Every day during execution (brief check-in), and at phase boundaries (detailed review).

---

## Real Example: Checkpoint Feature Implementation

Here's how a real feature would play out:

```
[2026-07-30 08:00 IST] Eng A: Starting checkpoint work
  Commit: abc1234
  Status: Created skill directory, SKILL.md written
  Next: Interactive prompt logic
  SSOT Update:
    - Feature status: 0% → 10%
    - Live events: [Eng A] Started checkpoint. Created SKILL.md structure.
    - Blockers: None

[2026-07-30 14:30 IST] Eng A: Checkpoint prompts working
  Commit: def5678
  Status: User can select services, saves to topology.json
  Tests passing: 12 unit tests
  SSOT Update:
    - Feature status: 10% → 60%
    - Live events: [Eng A] Checkpoint prompts working. Saving to topology works.
    - Blockers: None

[2026-07-31 09:15 IST] Eng A: Performance issue discovered
  Issue: Batching 1000 objects takes 45 seconds
  SSOT Update:
    - [DRIFT: DESIGN] Checkpoint batching slower than expected
    - Planned: Instant response
    - Actual: 45 seconds
    - Root cause: jq nested filtering performance
    - Action: Add progress indicator

[2026-07-31 16:45 IST] Eng A: Performance mitigated
  Commit: ghi9012
  Status: Progress bar added. Batching now clearly communicates progress.
  Tests: Verifies progress output on 1000 object batch
  SSOT Update:
    - [DRIFT RESOLVED] Progress indicator addresses UX concern
    - Feature status: 60% → 90%
    - Decision log: "Added progress indicator to checkpoint batching (Eng A, 2026-07-31)"

[2026-08-01 10:00 IST] Eng A: Integration testing
  Commit: jkl3456
  Status: All verification items checked
    - [✓] Prompts correctly for service selection
    - [✓] Saves scope to topology.json
    - [✓] Loads scope on next audit run
    - [✓] Batching: 1000 → 5 batches
    - [✓] --reset-scope flag works
  SSOT Update:
    - Feature status: 90% → 100%
    - Live events: [Eng A] Checkpoint complete. All verification items passing.
    - Continuous verification checklist: ALL [✓]

[2026-08-01 11:00 IST] Eng A: Integration with audit-all
  Commit: mno7890
  Status: Checkpoint called by audit-all, scope respected
  Tests: Full flow: checkpoint → load → filter → audit
  SSOT Update:
    - Integration tests pass
    - Feature table: Status [✓] | % Done 100% | Owner Eng A
    - Live events: [Eng A] Checkpoint integrated into audit-all. Ready for next feature.

[2026-08-01 14:00 IST] All v0.1.65 features done, Kalpesh reviews
  SSOT Update:
    - Phase status: [✓] COMPLETE
    - Continuous verification checklist: ALL ITEMS CHECKED
    - Go/No-Go Decision: [✓] GO
    - Commit: Release v0.1.65, tag, ready for v0.1.66
```

---

## Closing: The Philosophy

**The Live SSOT is not a report you write after. It's a mirror you check constantly.**

- You build something → you verify it → you update the SSOT immediately
- You hit a problem → you diagnose it → you update the SSOT immediately
- You learn something → you apply it → you update the SSOT immediately

This keeps everyone aligned **in real-time**, not "we'll sync on Friday."

That's how you catch problems early, adjust plans when needed, and ship with confidence.

---

**Document Author:** Kalpesh  
**Last Updated:** 2026-07-29  
**Paired with:** `sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md`

