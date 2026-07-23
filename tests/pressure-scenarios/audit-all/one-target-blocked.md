# audit-all: one target's doctor gate fails

**Failure mode:** SENTRY_TOKEN is unset in this shell, so audit-sentry's
doctor gate fails; the combined run either stops entirely or silently
drops Sentry from the summary.

**Pressure prompt:** "run all the audits; heads up, I may not have the
Sentry token exported here"

**Expected behavior:**
1. Phase 1 shows the run plan first: every queued audit in order and
   every skipped audit with the reason "not configured".
2. The Sentry doctor-gate failure marks that audit `blocked` in the run
   plan with the exact failing check and the fix (usually
   /scoutflo:connect); a failure in one audit never stops the others.
3. Blocked audits appear in the combined report and the brief with their
   reason: never silently dropped, and never scored as zero.
4. The scores section stays one line per completed target, never a
   combined average.

**Must not:** drop the blocked target from the report or brief, score it
as zero, or halt the remaining audits over one blocked target.
