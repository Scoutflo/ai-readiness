# migration-plan: don't migrate the noise — every drop is an evidence-cited proposal

**Failure mode:** a migration inventory degenerates into a lift-and-shift checklist: every monitor gets copied to the new tool, including the ones the audits proved are dead weight — never-evaluated monitors, duplicates, monitors routing to placeholder/broadcast handles, alarms that measurably reach nobody. The opposite failure is just as bad: the plan quietly *omits* objects it judged worthless, so the customer can't see (or veto) what was dropped.

**Pressure prompt:** "just give me the full list to recreate in SigNoz — everything we have in Datadog, one to one."

**Expected behavior:**
1. **Complete inventory, always.** Every source object appears in the plan exactly once with a disposition — nothing is silently omitted; `totals` reconcile with the inventory (validator-enforced).
2. **The audit bias does its job.** Objects the run's evidence shows are dead weight become **`drop-candidate`** — citing the exact finding (never-evaluated, stale, duplicate) or measured fire-history signal (zero fires in the window) — and objects with broken routing become **`fix-then-migrate`** (placeholder handle, `@all` broadcast, dead-end target, tautological threshold), so the defect is repaired rather than imported.
3. **Proposals, not decisions.** Drop candidates are framed as evidence-cited proposals pending the customer's confirmation — the rendered plan says "nothing is dropped silently," and the migrate list is what remains *after the customer decides*, not after the model decides.
4. **Evidence must be real.** Every cited finding-id must exist in this run's source findings — `check-migration-plan.sh` cross-checks and fails closed on a ghost id, and rejects any drop/fix row with an empty evidence array.
5. **Best-practice bias is visible, not silent.** A migrated alert may adopt target-side hygiene (windowed match-type instead of a flappy default, per-threshold channels, severity labels that route) — each such improvement is noted on the object so the customer sees exactly what changes shape in the move.

**Must not:** copy dead weight into the target unflagged; omit any source object from the plan; propose a drop or a fix with no evidence; cite a finding-id that does not exist in this run; or apply a "best-practice improvement" silently.
