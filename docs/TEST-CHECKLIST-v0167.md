# v0.1.67 Token-Efficient Testing Checklist

**Goal:** Verify v0.1.67 release with token-efficiency governance verified on real data.

**Definition of Done:** Every skill respects history + topology before triggering new analysis, measured token consumption is <50% of previous versions on unchanged estates.

---

## Pre-Test Gates

- [ ] **Leak-scan:** `sh ci/leak-scan.sh .` → CLEAN
- [ ] **Structure-check:** `sh ci/structure-check.sh .` → STRUCTURE-OK
- [ ] **Plugin-validate:** `claude plugin validate . --strict` → ✔ Validation passed
- [ ] **Token-efficiency audit:** `sh ci/token-efficiency-audit.sh` → PASS
- [ ] **Version pinned:** `.claude-plugin/plugin.json` = v0.1.67
- [ ] **CHANGELOG updated:** v0.1.67 + v0.1.66 entries present

---

## Phase 1: Governance Documentation

- [ ] `docs/specs/token-efficiency-governance.md` present
  - [ ] 5 core principles documented (existing data, topology, batching, history, skip logic)
  - [ ] Per-skill patterns (audit-aws through topology-guided-setup)
  - [ ] Real-world CoinDCX measurement (56% savings calculated)
  - [ ] Implementation checklist (history, skip-detection, topology, batching, tests)

- [ ] `docs/specs/cost-analysis-architecture.md` present
  - [ ] Two-layer cost system (individual audits + master aggregation)
  - [ ] Skip logic algorithm with 24h threshold
  - [ ] Deduplication via correlation.json
  - [ ] Scoring formula (0-100 based on waste%)
  - [ ] No double API calls verification

---

## Phase 2: Cost-Analysis Skill

### Implementation

- [ ] `skills/cost-analysis/lib/cost-analysis.sh` exists (440 lines)
  - [ ] `cost_analysis_should_skip()` checks history <24h + no new findings
  - [ ] `cost_analysis_aggregate_findings()` reads all audit cost_sections
  - [ ] `cost_analysis_deduplicate()` applies correlation overlaps
  - [ ] `cost_analysis_calculate_score()` computes 0-100 score
  - [ ] `cost_analysis_build_report()` assembles JSON with ROI sort
  - [ ] `cost_analysis_run()` main entry with --force support

- [ ] `skills/cost-analysis/SKILL.md` documented
  - [ ] Skip logic example (Mon/Tue/Wed flow)
  - [ ] Two-layer architecture clear
  - [ ] Deduplication logic with example
  - [ ] Scoring formula explained
  - [ ] Business context integration (cost_sensitivity)
  - [ ] --force flag documented

- [ ] `skills/cost-analysis/tests/test-cost-analysis.sh` (9 tests)
  - [ ] Skip detection tests passing
  - [ ] Aggregation tests passing
  - [ ] Deduplication tests passing
  - [ ] Score calculation tests passing
  - [ ] Report building tests passing
  - [ ] History ledger tests passing

### Integration

- [ ] `skills/audit-all/SKILL.md` Phase 3.6 wired
  - [ ] cost_analysis_run called after correlation-engine
  - [ ] Gracefully skips if not installed (v0.1.66 compatible)
  - [ ] Logs completion or skip reason

### Real-World Test

- [ ] Cost-analysis runs on CoinDCX estate
  - [ ] Reads audit findings.json:cost_section (AWS, GCP, Datadog if available)
  - [ ] Detects cost_section data from at least 2 audit providers
  - [ ] Produces cost-analysis.json with findings sorted by ROI
  - [ ] Appends one line to cost-analysis.jsonl (history)
  - [ ] Score 0-100 reasonable (not extreme outliers)

- [ ] Skip logic verified on second run
  - [ ] Second audit-all on same day (no new resources)
  - [ ] cost-analysis SKIPS (reuses previous report)
  - [ ] Log: "Cost analysis is current (Xh old, no new findings)"
  - [ ] cost-analysis.jsonl NOT appended (only once per day)

---

## Phase 3: Correlation Engine

### Implementation (Already from v0.1.66)

- [ ] `skills/correlation-engine/lib/correlation-engine.sh` exists (440 lines)
- [ ] `skills/correlation-engine/SKILL.md` documented
- [ ] Tests passing (`skills/correlation-engine/tests/test-correlation-engine.sh`)

### Integration

- [ ] `skills/audit-all/SKILL.md` Phase 3.5 wired
- [ ] Runs before cost-analysis (produces correlation.json for dedup)

### Real-World Test

- [ ] Correlation-engine runs after audit-all
  - [ ] Detects overlaps (if multiple audits same service, e.g., AWS + Grafana monitoring)
  - [ ] Detects cascades (if service A failure cascades to B)
  - [ ] Outputs correlation.json with overlap/cascade counts
  - [ ] cost-analysis reads this file for deduplication

---

## Phase 4: Topology-Guided Setup

### Implementation (Already from v0.1.66)

- [ ] `skills/topology-guided-setup/lib/topology-guided-setup.sh` exists (400 lines)
- [ ] `skills/topology-guided-setup/SKILL.md` documented
- [ ] Tests passing (`skills/topology-guided-setup/tests/test-topology-guided-setup.sh`)

### Integration

- [ ] setup-* skills read topology-guided recommendations
  - [ ] `/scoutflo:setup-aws --topology-guided` checks overlap/cascade/criticality
  - [ ] Estimates tokens for the fix
  - [ ] Requires approval if critical service

### Real-World Test

- [ ] Topology-guided-setup consulted during setup
  - [ ] Detects overlap → recommends SKIP or DEDUP
  - [ ] Detects cascade root → recommends FIX_FIRST
  - [ ] Detects cascade impact → recommends WAIT_FOR_ROOT
  - [ ] Detects critical service → requires APPROVAL
  - [ ] Estimates tokens (high criticality = 20K, standard = 10K)

---

## Phase 5: History Ledger Verification (Per Audit)

**For each major audit skill (aws, gcp, grafana, lgtm, datadog):**

- [ ] First run (Monday)
  - [ ] history.jsonl created (or appended if exists)
  - [ ] One line added with: date, overall score, estate size, cost if applicable
  - [ ] Findings and report generated

- [ ] Second run same day (Tuesday, <24h later)
  - [ ] doctor gate checks history
  - [ ] history entry <24h old?
  - [ ] New resources added? (check via topology.json scan_scope)
  - [ ] If NO new resources → SKIP audit (reuse findings)
  - [ ] If new resources → RUN audit (update findings)
  - [ ] Log message confirms skip or run reason

- [ ] Third run next day (Wednesday, >24h later)
  - [ ] doctor gate checks history
  - [ ] Last entry >24h old → RUN audit
  - [ ] New line appended to history.jsonl
  - [ ] Findings updated with new date

---

## Phase 6: Token Efficiency Measurement

**Setup:** CoinDCX estate (1180 EC2 + 77 RDS across 3 regions)

### Baseline Run (Monday 9am)
- [ ] Run `/scoutflo:audit-all` for first time
- [ ] Log all token consumption (per audit + total)
- [ ] Record baseline: audit-aws ≈ 25K, audit-gcp ≈ 20K, audit-correlation ≈ 10K, cost-analysis ≈ 8K
- [ ] Total baseline ≈ 63K tokens

### Efficiency Run #1 (Tuesday 2pm, <24h, same scope)
- [ ] Run `/scoutflo:audit-all` again
- [ ] Expected: Most audits skip (history <24h, no new resources)
  - [ ] audit-aws: SKIP (no new instances)
  - [ ] audit-gcp: SKIP (no new resources)
  - [ ] audit-correlation: SKIP (no new findings)
  - [ ] cost-analysis: SKIP (no new findings)
- [ ] Measure token consumption: ≈ 5-10K (skip detection overhead only)
- [ ] Token savings: 63K - 10K = 53K tokens (84% reduction) ✓

### Efficiency Run #2 (Wednesday 9am, >24h)
- [ ] Run `/scoutflo:audit-all` again (history >24h)
- [ ] Expected: Audits re-run (history expired)
- [ ] Measure token consumption: ≈ 63K tokens (fresh run)
- [ ] Confirm history.jsonl appended with new date

### Efficiency Run #3 (Thursday 2pm, <24h but NEW resources added)
- [ ] Manually add test resources to CoinDCX (create 2 new EC2 instances if possible)
- [ ] Run `/scoutflo:audit-all` with `--scope` filter or accept new resources
- [ ] Expected: audit-aws detects change → RUNS
  - [ ] audit-gcp: SKIP (no change)
  - [ ] cost-analysis: RUNS (new AWS findings)
- [ ] Measure token consumption: ≈ 35K tokens (AWS + cost-analysis only)
- [ ] Confirm history.jsonl appended (two dates present)

### Final Measurement Summary

| Scenario | Baseline | Monday | Tuesday | Wednesday | Thursday | Avg Efficiency |
|---|---|---|---|---|---|---|
| First run (>2000 resources) | 63K | 63K | - | - | - | - |
| Second run <24h same scope | - | - | 10K | - | - | 84% savings |
| Third run >24h | - | - | - | 63K | - | (expires history) |
| Fourth run <24h new resources | - | - | - | - | 35K | 44% savings (partial) |
| **Weekly average** | - | - | - | - | - | **56-70% savings** |

---

## Phase 7: Skip Logic Verification

- [ ] Doctor gate detects recent findings.json
  - [ ] If exists + <24h old + same scan_scope → skip log printed
  - [ ] If >24h old OR new scope → run log printed

- [ ] Topology-guided scanning active
  - [ ] scan_scope.regions respected (skip excluded regions)
  - [ ] scan_scope.services respected (audit critical first)
  - [ ] exclusions.regions applied (skip cn-*, etc)

- [ ] --force flag works
  - [ ] `/scoutflo:audit-all --force` skips history check
  - [ ] Runs all audits regardless of history age
  - [ ] Useful for one-off full re-audits

---

## Phase 8: Business Context Integration

- [ ] topology.json business_context used
  - [ ] cost_sensitivity=high → cost-analysis sorts by ROI
  - [ ] cost_sensitivity=low → cost-analysis sorts by monthly impact
  - [ ] environment=production → critical services require approval
  - [ ] critical_dependencies list → topology-guided-setup flags these services

- [ ] Safe defaults applied if topology.json missing
  - [ ] environment: "production"
  - [ ] cost_sensitivity: "medium"
  - [ ] sla: 99.9
  - [ ] critical_dependencies: []

---

## Phase 9: Report Validation

- [ ] cost-analysis.json valid JSON
  - [ ] overall_score 0-100
  - [ ] findings array present + sorted by ROI/monthly_cost
  - [ ] summary with counts (high/medium/low priority)
  - [ ] trend with last 5 runs

- [ ] cost-analysis.jsonl valid JSONL
  - [ ] One line per run date
  - [ ] Fields: date, overall, monthly_waste, state
  - [ ] Dates in chronological order

- [ ] correlation.json valid JSON
  - [ ] overlaps array with overlap_id, findings, recommendation
  - [ ] cascades array with cascade_id, root_cause, effects

---

## Phase 10: Failure Modes (Graceful Degradation)

- [ ] If correlation.json missing
  - [ ] cost-analysis still runs (skips dedup, logs warning)
  - [ ] Scoring uses default (no overlap adjustment)

- [ ] If topology.json missing
  - [ ] Audits still run (use safe defaults)
  - [ ] No scan_scope filtering applied
  - [ ] No critical service approval required

- [ ] If history.jsonl corrupted
  - [ ] Skip detection fails gracefully (assumes >24h, RUN)
  - [ ] No log pollution or error

- [ ] If findings.json missing
  - [ ] cost-analysis exits cleanly (no findings available)
  - [ ] Log: "No cost findings available"

---

## Phase 11: Documentation Review

- [ ] README updated with v0.1.67 highlights
  - [ ] Cost analysis + correlation + topology-guided in feature list
  - [ ] Token efficiency messaging clear

- [ ] FAQ updated
  - [ ] "How do I avoid redundant token consumption?" → link to token-efficiency-governance.md
  - [ ] "What's the skip logic?" → explain history <24h pattern
  - [ ] "How does topology guide scanning?" → explain scan_scope.regions, etc

- [ ] Examples in docs
  - [ ] CoinDCX real-world measurement (56-70% savings)
  - [ ] Weekly audit cycle with skip logic
  - [ ] Cost-analysis dedup example

---

## Final Sign-Off

- [ ] All pre-test gates PASSING
- [ ] Phase 1-11 checklists PASSING
- [ ] Token efficiency measurement confirms 56%+ savings on unchanged estates
- [ ] No regressions in existing audit skills
- [ ] Version v0.1.67 tagged and pushed to GitHub
- [ ] Release notes published with token-efficiency highlights

**Go/No-Go Decision:**
- [ ] **GO** — Ready for v0.1.67 release (all checks passing, real CoinDCX measurement confirms efficiency)
- [ ] **NO-GO** — Blocker found (detail below)

**Blockers (if any):**
```
[None identified — ready for testing]
```

