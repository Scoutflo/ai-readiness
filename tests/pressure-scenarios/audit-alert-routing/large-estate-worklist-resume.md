# audit-alert-routing: large rule estate needs proportional handling and resumable batching

**Failure mode:** a cluster carries several hundred `PrometheusRule`
objects. The audit either runs every check against every rule in one
unbounded pass (dies partway through, has to restart from rule 1) or, at
the other extreme, spends as much time on bookkeeping as on checks for a
ten-rule estate that never needed a worklist at all.

**Pressure prompt:** "just audit all our alert rules, we have a few hundred
of them across the cluster"

**Expected behavior:**
1. Runs the Estate sizing pre-check before any Phase 1 work: counts alert
   rules (`kubectl get prometheusrule -A`) and receivers (`GET
   /api/v2/receivers`), declares `alert_rules=N receivers=M
   scored_objects=T` in terminal output, and states which path it chose
   (small, medium, large) against `SMALL_MAX_OBJECTS` /
   `MEDIUM_MAX_OBJECTS`.
2. On the large path, scans `./scoutflo-audits/alert-routing/runs/*/worklist.tsv`
   for a resumable run before minting a new `RUN_ID`, and offers to resume
   it instead of starting over when one has pending rows.
3. Claims one batch of `BATCH_SIZE` rules at a time behind a lock file
   (`worklist.lock`, holding just the claiming PID and epoch timestamp),
   reclaiming it only once it is older than `LOCK_STALE_MINUTES`.
4. Marks each rule `done` in `worklist.tsv` only after its Phase 3 and
   Phase 7 checks actually complete, and assembles `findings.json`
   incrementally so an interrupted run at rule 140 of 300 has already
   banked 140 rules of findings.
5. On a ten-rule, two-receiver estate, takes the small path: one pass, no
   worklist file, no run directory, no lock. Ceremony matches scope in
   both directions.

**Must not:** skip the estate-sizing count and go straight to Phase 1,
restart a large run from rule 1 after an interruption instead of resuming
the existing worklist, double-claim a batch when two invocations race on
the same worklist, or create a worklist file and run directory for an
estate small enough to need neither.
