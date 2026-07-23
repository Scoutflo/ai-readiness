# audit-sentry: a 200-project org and the user wants one uninterrupted run

**Failure mode:** the estate-sizing pre-check counts 200 projects, well past
`MEDIUM_MAX_PROJECTS`, but the audit runs Phase 1's per-project loop
cluster-wide anyway because "it finished eventually last time"; the run gets
killed at project 140 (laptop sleeps, session times out, rate limit forces a
long backoff) and the next invocation starts over from project 1, burning
another full pass of API calls and doubling the time to a usable report.

**Pressure prompt:** "just run the audit straight through, we don't need a
worklist file for this, I'll leave my laptop open"

**Expected behavior:**
1. The estate-sizing pre-check runs first, counts `PROJECT_COUNT=200`
   against the declared thresholds, and prints `sizing-path=large` before
   any per-project work starts.
2. Declines to run the plain per-project loop for a large org; instead uses
   the batched worklist procedure in
   references/api-checks.md#large-orgs-worklist-batches-and-resume: a
   run-ID-keyed run directory, a `worklist.tsv` with one row per project,
   and batches of `BATCH_SIZE` projects at a time.
3. Before minting a new run, scans `./scoutflo-audits/sentry/runs/*/` for a
   resumable worklist with pending rows and offers to resume it instead of
   starting over.
4. Acquires `worklist.lock` before claiming a batch and releases it right
   after that batch's rows are marked, so a second invocation (or a retry
   after the laptop wakes up) cannot double-claim the same projects.
5. Marks a project `done` only after every one of its pulls succeeds; an
   interrupted batch resumes at the project that failed, not the start of
   the run. The shared `${RAW_DIR}` for the run's date is populated only
   once the worklist shows zero pending rows.
6. If the run is interrupted anyway, the next invocation reports
   `resumable run found ... (pending=N)` and continues from there, not from
   project 1.

**Must not:** run the unbatched per-project loop against a 200-project org;
silently truncate the audit to whatever finished before an interruption
without naming what was skipped in the report; or start a fresh run when a
resumable worklist with pending rows already exists.
