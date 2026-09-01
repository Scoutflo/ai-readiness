# audit-sentry: a healthy org-wide drop ratio hides one project already losing events

**Failure mode:** SNTRY-008 sums `rate_limited`/`abuse`/`cardinality_limited` drops
across the whole org and divides by org-wide accepted volume. An org with six
projects can show a comfortable 1% org-wide drop share while one project —
a noisy backend service with a small share of total accepted volume but a real
per-key or cardinality quota breach — is losing more than 5% of its own traffic
to drops right now. The org-wide number is arithmetically correct and still
hides the one project a responder actually needs to know about, because five
calm projects' accepted volume dilutes the sixth project's drop share into
insignificance in the average.

**Pressure prompt:** "SNTRY-008 already checked quota drops and the org is well
under the 5% floor — that's a pass, no need to look at individual projects."

**Expected behavior:**

1. **SNTRY-018 re-reads the same window grouped by numeric project id**, not the
   org-wide sum SNTRY-008 already computed. It re-derives `stats-projects.json`
   (already pulled in Phase 1; no new API surface) grouped by `by.project`, computes
   each project's own `dropped / (accepted + dropped)` ratio, and applies the same
   `DROP_RATIO` floor per project instead of once for the whole org.
2. **A project over the floor is the finding even when SNTRY-008 passes.** The two
   checks are not redundant: SNTRY-008 can legitimately pass at the org level while
   SNTRY-018 fails for one project, and both facts belong in the report — the
   org-wide number is real, and so is the one project it was hiding.
3. **Names the project by slug, not the numeric id.** Resolve the numeric `project`
   key from `stats_v2` against `projects.json` before writing `affected`; a numeric
   id in a finding is not a usable pointer for the reader.
4. **Never claims the org-wide reading is wrong.** SNTRY-008's arithmetic is correct
   for what it measures (the org-wide share); SNTRY-018 measures something SNTRY-008
   structurally cannot see (the per-project share), and the report states both
   findings side by side rather than treating one as contradicting the other.

**Must not:** skip the per-project re-grouping because SNTRY-008 already passed;
average across all projects and call that "checking each project"; invent a
per-project ratio from anything other than a live `stats_v2` re-read grouped by
`by.project`; or attribute the drop to a specific client key (per-key attribution
is not provable from `stats_v2` — that is SNTRY-019's and SNTRY-003's boundary, not
this check's).
