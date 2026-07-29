# SSOT Architecture: Three Documents, One System

**Purpose:** Explain how the SSOT documents work together during execution  
**Audience:** Tech lead (Kalpesh) + anyone coordinating the work  
**Status:** Reference architecture  

---

## The Three Documents

### 1. EXECUTION-ROADMAP-LIVE.md (The Mirror)

**What:** Live state verification document. Always reflects reality, updated in real-time.

**Contains:**
- Current execution status (what phase are we in?)
- Live events log (what actually happened today?)
- Continuous verification checklists (did this feature work?)
- Drift detection (did reality match the plan?)
- Risk register (updated as risks materialize)
- Feedback log (what did we learn?)
- Decision log (what changed and why?)

**Updated:** After every commit, whenever something important happens

**Read By:** Everyone, every day (to see current state)

**Purpose:** "What is true RIGHT NOW?"

---

### 2. EXECUTION-RUNBOOK.md (The How-To)

**What:** Practical guide for using the Live SSOT during implementation.

**Contains:**
- Quick start checklist
- Patterns for common situations (feature completion, handling blockers, token measurement)
- Git workflow commands
- FAQ
- Real example walkthrough

**Updated:** Only when the process itself needs clarification (rarely)

**Read By:** Engineers when they start a feature or hit an unfamiliar situation

**Purpose:** "How do I use the SSOT?"

---

### 3. EXECUTION-ROADMAP.md (Original, Keep for Context)

**What:** The original static roadmap. Kept for historical reference.

**Updated:** Only after phase completion (retrospective, decision capture)

**Read By:** New team members (for context on how we planned this)

**Purpose:** "What did we originally intend?"

---

## How They Work Together

```
EXECUTION-ROADMAP.md (The Plan)
    ↓
    Engineers start implementation
    ↓
    [Reality unfolds every day]
    ↓
EXECUTION-ROADMAP-LIVE.md (The Mirror)
    ↑
    Real-time updates as things happen
    ↑
    Continuous verification as we build
    ↑
    [When stuck, consult]
    ↓
EXECUTION-RUNBOOK.md (The How-To)
    ↑
    [Patterns for common situations]
    ↑
    After commit, update Live SSOT immediately
    ↑
    [At phase boundary]
    ↓
EXECUTION-ROADMAP.md (Update with Retrospective)
    ↑
    Phase complete + decision log + lessons learned
```

---

## Daily Workflow

### Morning (Every Day)

```
1. Open EXECUTION-ROADMAP-LIVE.md
2. Check:
   - Current status dashboard
   - Live events log (what changed since yesterday?)
   - Drift log (any surprises?)
   - Blockers (anything stuck?)
3. If everything looks good → start work
4. If something's off → investigate immediately (don't batch problems)
```

### During Work (Continuously)

```
1. Implement feature
2. Run verification checklist items (from Live SSOT)
3. Tests pass? Measurements done? Yes → continue
4. Hit a problem?
   - Add [DRIFT] entry to Live SSOT
   - Investigate root cause immediately
   - Fix it in same session if possible
5. Make a decision that changes the plan?
   - Add to decision log (Live SSOT)
   - Update any affected plan sections
6. Ready to commit?
   - Run full verification checklist for feature
   - Commit code + Live SSOT updates together
   - Include verification results in commit message
```

### When Committing

```
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md [feature files]
git commit -m "feat: [feature name]

[What changed]
- Unit tests passing
- Integration tests passing
- Verification checklist items: [list what passed]

[Any drift?]
- No drifts | OR | [DRIFT: TYPE] description

[Ready to move on?]
- Status: X/Y days done
- Next: [what comes next]

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### End of Week (Friday or Phase End)

```
1. Verify all features in phase are complete
2. Check all continuous verification checklists (mark completed items)
3. Review drift log (are outstanding issues resolved?)
4. Review feedback log (was all feedback actioned?)
5. If phase is done:
   - Mark go/no-go decision in Live SSOT
   - Update EXECUTION-ROADMAP.md with retrospective (decision log, lessons learned)
   - Tag release
   - Celebrate 🎉
```

---

## Real Example: Checkpoint Feature

### Day 1: Feature Starts

**Live SSOT Updates:**
```markdown
[2026-07-30 08:00 IST] Eng A: Starting checkpoint work
  Commit: abc1234
  Status: 0% → 10% (created skill structure)
  Next: Interactive prompts
  Blockers: None
```

**Runbook Used:** "Before You Start a Feature" section

---

### Day 1 Afternoon: First Commit

**Engineer runs verification checklist:**
- [ ] Prompts correctly for service selection — Not done yet
- [ ] Saves scope to topology.json — Not done yet
- [✓] Skill structure created and tests written

**Commits:**
```bash
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/skills/inventory-checkpoint/
git commit -m "feat: checkpoint skill structure and tests

[Verification Passing]
  [✓] SKILL.md written
  [✓] Test infrastructure in place
  [✓] Initial prompts designed

[Not Yet Done]
  [ ] Interactive prompts working
  [ ] topology.json save function
  [ ] Integration with audit-all

Status: 10% complete, on track.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Live SSOT Updated:**
```markdown
[2026-07-30 14:30 IST] Eng A: Checkpoint structure committed
  Commit: abc1234
  Status: 10% → 25% (basic structure, tests ready)
  Next: Implement interactive prompts
  Blockers: None
```

---

### Day 2: Problem Discovered

**Engineer finds issue:** Batching 1000 objects takes 45 seconds (planned: instant)

**Immediately updates Live SSOT with [DRIFT] entry:**
```markdown
[2026-07-31 DRIFT: DESIGN] Checkpoint batching slower than planned
- Planned: Instant response
- Actual: 45 seconds
- Root cause: jq nested filtering performance
- Impact: UX concern, but not blocking
- Action: Add progress indicator
```

**Investigates + fixes in same session:**
- Analyzes jq performance
- Adds progress bar to show "X of Y batches"
- Tests with 1000 object batch

**Commits with drift resolution:**
```bash
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/skills/inventory-checkpoint/scripts/
git commit -m "fix: checkpoint batching performance + progress indicator

[DRIFT RESOLVED] Batching was slower than planned
- Added progress bar to show batch progress
- Users now see feedback instead of hanging UI
- Still takes 45 seconds (acceptable with feedback)

[Verification Passing]
  [✓] Progress indicator shows 'X of Y batches'
  [✓] Tested on 1000 object batch
  [✓] User feedback improved

Status: 50% complete, on track (drift mitigated).

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Live SSOT Updated:**
```markdown
[2026-07-31 DRIFT RESOLVED] Added progress indicator for UX
- Commit: def5678
- Status: 50% complete
- Next: Integration testing
```

---

### Day 3: Complete Feature

**Engineer verifies full checklist:**
- [✓] Prompts correctly for service selection
- [✓] Saves scope to topology.json (verified with jq)
- [✓] Loads scope on next audit run (verified in logs)
- [✓] Batching: 1000 → 5 batches at 200 each
- [✓] --reset-scope flag works
- [✓] No regressions in existing audits

**Commits with full verification:**
```bash
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/skills/inventory-checkpoint/
git commit -m "feat: checkpoint feature complete

[Continuous Verification: ALL PASSING]
  [✓] Prompts correctly for service selection
  [✓] Saves scope to topology.json (verified: jq .audit_scope topology.json)
  [✓] Loads scope on next audit run (verified: logs show scope loaded)
  [✓] Batching works: 1000 → 5 batches of 200 each
  [✓] --reset-scope flag works (verified: full estate scan after reset)
  [✓] No regressions: all 12 audits still work without scope set
  [✓] Integration tests pass: checkpoint → apply → audit full flow

Status: 100% complete, ready for integration.
Next: Wiring into audit-all.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

**Live SSOT Updated:**
```markdown
[2026-08-01 10:00 IST] Eng A: Checkpoint feature complete
  Commit: ghi9012
  Status: 100% (all verification items passing)
  Feature table: Status [✓] | % Done 100%
  Next: Integration phase with other features
  Blockers: None
```

---

## Phase Boundary: Go/No-Go Decision

### When All Features in Phase Are Done

**Tech Lead (Kalpesh):**
1. Reads Live SSOT front-to-front
2. Checks all verification checklists
3. Reviews drift log (are all drifts resolved?)
4. Reviews feedback log (was all feedback actioned?)
5. Decides: GO / CONDITIONAL-GO / NO-GO

**Example Decision:**
```
[2026-08-05 PHASE COMPLETE] v0.1.65 Verification

Features Complete:
  [✓] Inventory Checkpoint (100%)
  [✓] Doctor Persistence (100%)
  [✓] Business Context Skill (100%)
  [✓] Redaction Guardrail (100%)
  [✓] K8s Skill Exposure (100%)
  [✓] Batching Strategy (100%)
  [✓] Cross-References (100%)

Verification Checklists: ALL ITEMS PASSING
  [✓] Checkpoint Logic (7/7 items)
  [✓] Doctor Persistence (5/5 items)
  [✓] Business Context (3/3 items)
  [✓] Redaction (4/4 items)
  [✓] K8s Exposure (3/3 items)
  [✓] Batching (4/4 items)
  [✓] Backward Compatibility (1/1 item)
  [✓] Integration Tests (1/1 item)

North Star Metrics:
  [✓] Token efficiency: 50% savings (meets target)
  [✓] Business context: working, fixtures persist
  [✓] No regressions: v0.1.64 intact

Drift Log: All drifts resolved
  [✓] Checkpoint batching (resolved with progress indicator)
  [✓] Doctor schema enhancement (implemented, working)
  [✓] Business context persistence (fixed, verified)

Feedback Log: All feedback actioned
  [✓] CoinDCX token measurement (verified and documented)
  [✓] Redaction false positives (whitelist approach implemented)
  [✓] Doctor flag naming (--full renamed to --recheck-all)

Decision: [✓] GO to v0.1.66

Reason: All success criteria met, metrics verified, zero unresolved issues.

Status: Proceeding to Correlation Engine phase.
```

**Updates both docs:**
```bash
git add sre-toolkit/docs/EXECUTION-ROADMAP-LIVE.md sre-toolkit/docs/EXECUTION-ROADMAP.md
git add sre-toolkit/.claude-plugin/plugin.json sre-toolkit/CHANGELOG.md
git commit -m "release: v0.1.65 shipped (go/no-go PASSED)

[v0.1.65 VERIFICATION SUMMARY]
Duration: 10 days (planned 8, +2 drift documented and resolved)
Go/No-Go: [✓] GO

All features complete, all verification items passing.
North star metrics: on target.
CoinDCX ready to advance to v0.1.66.

Lessons learned added to EXECUTION-ROADMAP.md.
Next phase: Correlation Engine (v0.1.66).

Co-Authored-By: Claude <noreply@anthropic.com>"

git tag -a v0.1.65 -m "v0.1.65 Foundation: Checkpoint + Doctor + Context"
```

---

## Why This Architecture Works

### Real-Time Feedback
- Problems are caught immediately (not batched until end of week)
- Drifts are investigated on the day they happen (when memory is fresh)
- Decisions are documented as they're made (not reconstructed later)

### Always-Up-To-Date Context
- Live SSOT is the source of truth for "what is true right now"
- New engineer can read Live SSOT + git log and catch up instantly
- No guessing: the doc shows exactly what happened and when

### Built-In Quality Gates
- Verification checklists are part of the feature definition (not afterthought)
- Can't commit without updating SSOT (habit-forming)
- North star metrics are always measured (not estimated)

### Continuous Learning
- Drifts become decision log entries (why did we change course?)
- Feedback is captured as it arrives (not forgotten by Friday)
- Lessons are applied to next phase immediately (not stored for retrospective)

### Clear Accountability
- Every entry is timestamped + attributed
- Every decision has a reason (not "we changed it")
- Every measurement has evidence (not "we think so")

---

## Common Mistakes to Avoid

### ❌ "I'll update the SSOT at the end of the day"
**Problem:** You forget what happened, or lose details  
**Fix:** Update immediately after commit (takes 2 minutes)

### ❌ "This drift doesn't matter, I'll mention it in retrospective"
**Problem:** By Friday, you've forgotten the root cause  
**Fix:** Add [DRIFT] entry immediately, investigate same day

### ❌ "I'll wait for the full verification checklist at the end"
**Problem:** You ship features that don't actually work  
**Fix:** Verify as you build, check items off incrementally

### ❌ "The plan is wrong, let me ignore it and just build"
**Problem:** Team doesn't know you've changed direction  
**Fix:** Add decision log entry (why), then proceed

### ❌ "New engineer, let me explain verbally instead of using the SSOT"
**Problem:** Information is lost, not repeatable  
**Fix:** Point them to Live SSOT + Runbook (they catch up in 20 min)

---

## Checklist: Is Your SSOT Working?

Every week, ask yourself:

- [ ] Did we catch problems on the day they happened (not Friday)?
- [ ] Is the Live SSOT accurate compared to git log?
- [ ] Can a new engineer read Live SSOT + understand current state?
- [ ] Are there uncommitted changes to the SSOT? (should be committed with code)
- [ ] Are north star metrics measured or guessed?
- [ ] Is every drift investigated (not just noted)?
- [ ] Is every decision documented with why?
- [ ] Can we trace any feature status back to commit + verification?

If you answer "no" to any of these, you're not using the SSOT correctly. Fix it.

---

**Document Author:** Kalpesh  
**Last Updated:** 2026-07-29  
**Pairs With:** EXECUTION-ROADMAP-LIVE.md, EXECUTION-RUNBOOK.md

