# START HERE — Scoutflo AI Readiness v0.1.65-0.1.68

**Internal Execution System — Local Development Only**

This is your complete execution SSOT for v0.1.65-0.1.68 implementation.

---

## In 30 Seconds

You have:
- ✅ **8 features to build** (v0.1.65)
- ✅ **Complete implementation specs** (schema, algorithms, state machines)
- ✅ **Exact verification criteria** (pass/fail tests per feature)
- ✅ **Metrics instrumentation plan** (how to measure north star)
- ✅ **Rollback & incident procedures** (what if something breaks)
- ✅ **Always-live execution system** (SSOT updated every commit, not batch-processed)

**Everything is local-only. Not for customers.**

---

## What to Read (In Order)

### 1. Understanding the System (10 min)

Read **SSOT-READY.md**
- What you have (documents + specs)
- What to build (8 v0.1.65 features summary)
- How to get started (3 simple steps)
- North star metrics (what success looks like)

### 2. How to Use the SSOT (15 min)

Read **EXECUTION-RUNBOOK.md**
- Before you start a feature (3-step checklist)
- Common patterns (handling blockers, token measurement, drift investigation)
- Git workflow (local commits, no GitHub)
- Real example walkthrough (Checkpoint feature, day by day)

### 3. Understanding the Architecture (Optional, 20 min)

Read **SSOT-ARCHITECTURE.md**
- Why 3 documents (LIVE-CLEAN, RUNBOOK, ARCHITECTURE)
- Daily workflow diagram
- Common mistakes to avoid
- How they work together

### 4. Ready to Build? (Pick Your Feature)

Read **IMPLEMENTATION-READY.md**
- Complete file structure
- What's ready to build (all 8 features have specs)
- How to start Day 1 (5-step checklist)
- Quality gates (before releasing)

---

## Primary Documents (Always Open These)

### **EXECUTION-ROADMAP-LIVE-CLEAN.md** (THE MOST IMPORTANT)

This is the **single source of truth** for current execution state.

**Update after every commit:**
- Add live event (what changed?)
- Mark verification items ✓
- If reality ≠ plan → add [DRIFT] entry

**Read every morning:**
- Current status dashboard
- Live events log (what changed yesterday?)
- Drift log (any surprises?)
- Blockers (anything stuck?)

**Read at phase end:**
- All verification items passing?
- Drifts all resolved?
- Ready for production?

---

### **Specs Directory** (sre-toolkit/docs/specs/)

Use these to understand exact implementation details:

| Spec | When to Read | Size |
|------|---|---|
| `doctor-state-schema.md` | Building Doctor Persistence feature | 4 KB |
| `correlation-engine-spec.md` | Building Correlation Engine (v0.1.66) | 8 KB |
| `business-context-schema.md` | Building Business Context Skill | 6 KB |
| `metrics-instrumentation-plan.md` | Setting up token/metric measurement | 7 KB |
| `v0165-verification-checklist.md` | Understanding what "done" means for v0.1.65 | 13 KB |
| `rollback-incident-response.md` | When something breaks (incident procedures) | 9 KB |

---

## The 8 v0.1.65 Features (What You're Building)

### 1. **Inventory Checkpoint (Interactive Selection)**
User selects which services to audit before spending tokens. Saves scope to topology.json for reuse.

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 1  
**Acceptance Criteria:** 6 items (prompts, scope save, load, batching, reset, backward compat)

### 2. **Inventory Checkpoint (Batching)**
Large estates batched at query-time. 1000 objects → 5 batches of 200.

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 1  
**Acceptance Criteria:** 1 item (batching sizes verified)

### 3. **Doctor Persistence**
Record doctor findings to ~/.scoutflo/doctor-state.json. Skip passing checks on re-runs. Auto-update when user fixes issues.

**Spec:** [doctor-state-schema.md](specs/doctor-state-schema.md)  
**Acceptance Criteria:** 5 items (state creation, save, skip logic, auto-fix, persistence)

### 4. **Business Context Skill**
New skill: `/scoutflo:business-context`. Prompts for team, environment, SLA, cost sensitivity. Audit skills read this to adjust findings.

**Spec:** [business-context-schema.md](specs/business-context-schema.md)  
**Acceptance Criteria:** 4 items (prompts, save, read+use, persist)

### 5. **Redaction Guardrail**
Global regex-based redaction. Find & redact API keys, tokens, AWS secrets in reports.

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 4  
**Acceptance Criteria:** 4 items (100+ logs, false positives, report+slack, all secret types)

### 6. **K8s Skill Exposure**
Add `/scoutflo:audit-kubernetes` to start catalog. Wire into audit-all. Output to scoutflo-audits/kubernetes/<cluster>/<date>/report.md.

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 5  
**Acceptance Criteria:** 3 items (catalog, no errors, output location)

### 7. **Interactive CLI Confirmations**
Before big operations, pause and let user exclude services/regions/statuses.

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 6  
**Acceptance Criteria:** 4 items (pause, exclude services, regions, statuses)

### 8. **Finding Cross-References**
Each finding links to related findings in other audits. E.g., AWS-023 → GRAFANA-018 (both monitor same service).

**Spec:** [v0165-verification-checklist.md](specs/v0165-verification-checklist.md) → Feature 7  
**Acceptance Criteria:** 3 items (linking, section, resolved links)

---

## Day 1: Quick Start

### Step 1: Understand the System (10 min)

```bash
cd ~/ScoutfloWork/ScoutPlug/sre-toolkit/docs/
cat SSOT-READY.md
```

### Step 2: Pick Your First Feature

Example: Start with **Doctor Persistence**

### Step 3: Read the Spec

```bash
cat specs/doctor-state-schema.md
# Understand: schema + state machine + auto-fix logic
```

### Step 4: Read the Verification Criteria

```bash
cat specs/v0165-verification-checklist.md | grep -A 30 "Feature 2: Doctor"
# Understand: what "done" means for this feature
```

### Step 5: Start Coding

Follow TDD:
1. Write failing test (e.g., "test_doctor_state_creation")
2. Run test (should fail)
3. Implement minimal code
4. Run test (should pass)
5. Commit locally
6. Update EXECUTION-ROADMAP-LIVE-CLEAN.md with live event

**Every commit = 2 min SSOT update + code**

---

## Key Principles

### ✅ Always-Live, Not Batch-Processed

```
Traditional:
  Monday: planning
  Tue-Thu: build
  Friday: retrospective
  Next Monday: apply learning
  (Problems compound, context lost)

This approach:
  While building: update SSOT immediately
  Hit problem? [DRIFT] entry same-day
  Make decision? Decision log entry same-day
  Measure metrics? Capture live
  (Problems caught early, context captured, learning applied immediately)
```

### ✅ Continuous Verification, Not End-of-Phase

Verification checklist is part of the feature definition. You don't build it and then test it. You verify as you build.

```
Per feature:
  ✓ Spec defines acceptance criteria
  ✓ Implementation tests criteria as you code
  ✓ Mark items ✓ as they pass
  ✓ Commit only when items passing
```

### ✅ Local-Only, No Public Repo

All work is local development + local testing. Nothing goes to GitHub or customers.

```
Commit locally:
  git add specs/doctor-state.md skills/doctor/
  git commit -m "feat: doctor persistence + state machine"
  
Don't:
  git push origin (stays local)
  Document in customer README (internal only)
```

---

## Measuring Success

### North Star Metrics

| Metric | Target | Measure On |
|--------|--------|---|
| Token efficiency (audit) | 50% save | Full estate audit (600K→300K) |
| Token efficiency (second run) | 75% save | Checkpoint + doctor (600K→150K) |
| Token efficiency (setup) | 70% save | Topology-guided setup (50K→15K) |
| Finding dedup | 87→42 | Correlation engine output |
| Cascade risks | 5+ | Real estate analysis |

**All measured on real data (CoinDCX estate), not estimates.**

---

## Phase Gates (Go/No-Go)

### Before v0.1.65 Ships

```
✓ All 8 features implemented
✓ All 40+ acceptance criteria passing
✓ All 12 audit skills tested (no regressions)
✓ Token efficiency measured (45-56% target)
✓ Finding dedup accuracy >= 95%
✓ No secrets leaked in reports
✓ E2E workflow verified (checkpoint → audit → doctor → report)
✓ Tech lead approval (Kalpesh)
```

If all ✓: **GO to v0.1.66**  
If any ✗: **Investigate, fix, re-verify**

---

## If Something Goes Wrong

Read **specs/rollback-incident-response.md**

```
Incident detected?
  1. Confirm severity (P1/P2/P3/P4)
  2. Declare incident + notify
  3. Gather evidence
  4. Identify root cause
  5. Decide: rollback vs patch vs feature flag disable
```

All procedures documented, tested, ready to execute.

---

## Next Steps

### Right Now

- [ ] Read SSOT-READY.md (this file + 10 min read)

### Today

- [ ] Read EXECUTION-RUNBOOK.md (15 min)
- [ ] Pick first v0.1.65 feature
- [ ] Read relevant spec + verification criteria
- [ ] Write failing test
- [ ] Start implementing

### Every Commit

- [ ] Update EXECUTION-ROADMAP-LIVE-CLEAN.md (2 min)
- [ ] Commit code + SSOT together

### Phase End (After v0.1.65 Done)

- [ ] Mark all verification items ✓
- [ ] Review drift log (all resolved?)
- [ ] Review decision log (all documented?)
- [ ] Make go/no-go decision
- [ ] Move to v0.1.66

---

## Questions?

**How do I use the SSOT?**
→ [EXECUTION-RUNBOOK.md](EXECUTION-RUNBOOK.md)

**What exactly do I need to build?**
→ [IMPLEMENTATION-READY.md](IMPLEMENTATION-READY.md) + specs/

**Why is this architecture like this?**
→ [SSOT-ARCHITECTURE.md](SSOT-ARCHITECTURE.md)

**What if it breaks?**
→ [specs/rollback-incident-response.md](specs/rollback-incident-response.md)

**What does "done" look like for my feature?**
→ [specs/v0165-verification-checklist.md](specs/v0165-verification-checklist.md)

---

**Ready to start?**

1. Open [EXECUTION-ROADMAP-LIVE-CLEAN.md](EXECUTION-ROADMAP-LIVE-CLEAN.md)
2. Find v0.1.65 section
3. Pick Feature 1, 2, 3, or 8 (smallest scope to start)
4. Read verification criteria
5. Write failing test
6. Build to pass

**Go.** 🚀

