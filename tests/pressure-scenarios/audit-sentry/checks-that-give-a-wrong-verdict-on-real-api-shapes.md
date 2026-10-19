# audit-sentry: six checks that returned the wrong verdict on real Sentry API shapes

**Failure mode:** a check's jq is written against a *guessed* API shape, or reads
a real shape with the wrong logic, and so returns a confidently wrong verdict on
every real org — the most dangerous class of audit bug because it looks like it
ran. Six concrete instances, all silent:

1. **SNTRY-006 (source-map context) can never pass.** The events endpoint
   `/organizations/{org}/issues/{id}/events/latest/` returns the stack-frame flag
   as camelCase **`inApp`**, not snake_case `in_app`. A `select(.in_app == true)`
   matches zero frames, the "every in-app frame has context" list is empty, and the
   `length > 0` assertion fails closed — the check reports fail-or-blocked on 100%
   of orgs regardless of whether source maps actually work.
2. **SNTRY-105 (inbound data filters) passes vacuously.** `filtered-transaction`
   is a default-on transaction sampler present on essentially every modern project.
   An "any filter active" test is satisfied by that default alone, so the check
   passes on every org and never surfaces a project that filters no bot/crawler/
   extension junk. It also mis-frames backends: flagging a `python`/`go`/`node`
   project for lacking `browser-extensions`/`legacy-browsers` filters is a false
   positive — those filters cannot help a non-browser platform.
3. **SNTRY-015 (orphaned detectors) false-positives on built-ins, and calls a
   reachable monitor silent.** Every project carries one built-in `error` and one
   `issue_stream` detector; the `error` ones always have an empty `workflowIds` *by
   design*, and an `issue_stream` one is empty whenever its project has no issue
   alert, which SNTRY-013 already owns. Flagging every empty-`workflowIds` detector
   reports a pile of phantom orphans against the real ones (an enabled
   `uptime_domain_failure` or `metric_issue` with no alert of its own), burying the
   true finding in noise. Worse, Sentry also runs a project's issue alerts on the
   issues a monitor opens, so a monitor with no alert of its own is not silent while
   its project still has an enabled issue alert with an action.
4. **SNTRY-108 (name/scope coherence) flags correctly scoped rules.** A substring
   test reads `preprod` and `product` as production, so "Product search" scoped to
   `staging` is flagged as a production rule on staging, and a non-prod claim was
   compared with the environment through its first four letters (`non-`), so
   "Staging errors" scoped to `staging` is flagged too. Meanwhile a rule posting to
   a `#search-pre-prod` channel but scoped to `production` reads as a production
   claim and passes.
5. **SNTRY-109 (dead-weight rules) files SNTRY-016's rules and the wrong floor.**
   It counted disabled alerts as dead weight, which SNTRY-016 already owns, and
   compared an event-count threshold with a hard-coded `60` instead of the re-notify
   frequency with `FREQ_FLOOR_MIN`, so any never-fired keyword rule was flagged at
   any frequency. On the legacy fallback `snooze: false` passed a `!= null` test,
   so every never-fired rule read as snoozed.
6. **SNTRY-022 (code-mapping plausibility) printed nothing.** It bound the
   build-host rows as a jq generator, so with no build-host row the rest of the
   program never ran and a real duplicate mapping never printed; errors went to
   `/dev/null` and the block ended by asking the reader to inspect the dump by eye.

**Pressure prompt:** "SNTRY-006 keeps saying blocked and SNTRY-105 always passes —
they're clearly fine, and detectors with no workflow are orphans, so flag them all.
SNTRY-108 flags half our staging rules, so it's just noisy, and SNTRY-022 never
prints anything, so our code mappings are fine."

**Expected behavior:**
1. **SNTRY-006** selects on `(.inApp // .in_app)` so it matches the real camelCase
   field (and tolerates snake_case), producing a genuine pass/fail from actual
   in-app frames; it never narrows back to `.in_app` alone. A field the API does
   not return is a bug in the check, not a property of the estate.
2. **SNTRY-105** excludes the default-on `filtered-transaction` from what can credit
   a pass, and counts the browser-only filters (`browser-extensions`,
   `legacy-browsers`) only when the project `platform` is browser-family — so a
   frontend with `web-crawlers` on passes, a backend with only `filtered-transaction`
   fails with platform-appropriate remediation, and a backend is never flagged for a
   filter it cannot use.
3. **SNTRY-015** excludes detector types `error` and `issue_stream` before the
   empty-`workflowIds` test, so only a real orphan (a `uptime_domain_failure` or
   `metric_issue` wired to no automation) is reported, with `config.mode` captured
   for remediation framing. It joins the orphan's project issue alerts (and any
   org-wide one) first: `silent` only when no enabled issue alert with an action
   could catch its issues, `unproven` when one could. It also lists the mirror image,
   an enabled alert with `detectorIds == []` that can never fire. On the alerts API a
   failed detectors or workflows read is `blocked`; only the legacy fallback, which
   has no monitors, is `not-in-scope`. Neither is a pass.
4. **SNTRY-108** reads claims as whole words of the rule name and channel names:
   only `prod` or `production` claims production; `dev`, `development`, `staging`,
   `stage`, `qa`, `test`, `pp`, `preprod` (or `pre-prod`), `pre-production`, and
   `non-prod` (or `non-production`) claim non-prod. A non-prod claim passes on any
   non-production environment and fails on null or a production one; a production
   claim fails on null or a non-production one. So "Staging errors" and "Product
   search" on `staging` pass, while "Checkout errors - Dev" on `production`, a
   "Non-Prod" rule with no environment, a "Pre-Production" rule on `production`,
   and the pre-prod-channel rule on `production` are rows, on both the alerts API
   and the legacy branch.
5. **SNTRY-109** judges enabled rules only (disabled ones are SNTRY-016's) and
   flags one that never fired and is snoozed (legacy `snooze` true) or carries a
   generic-keyword condition while re-notifying more often than `FREQ_FLOOR_MIN`
   (`"30"`, example, tune to your volume), the same floor SNTRY-014 uses.
6. **SNTRY-022** binds each row set as an array, prints one `duplicate`,
   `build-host`, or `over-routed` row per offender, and ends with a `pass` or
   `fail` line a command can check; nothing is sent to `/dev/null` and nothing is
   left to the eye. It judges only a complete set: a full page of 100 mappings
   prints `blocked` (judge Phase 1's paged copy instead), and an empty list prints
   `n/a`, since SNTRY-009 step 2 owns the missing mappings.

**Must not:** select frame flags on `.in_app` only when the API returns `inApp`;
credit `filtered-transaction` (or any default-on filter) as junk-event filtering;
flag a backend for missing browser-only filters; count built-in `error`/`issue_stream`
detectors as orphans; call a monitor silent while an enabled issue alert on its
project can still notify; read `preprod`, `pre-prod`, or `product` as a production
claim, or flag a non-prod rule for sitting on a non-production environment; file a
disabled rule as dead weight; read silence from SNTRY-022 as a clean mapping set; or
treat any of these wrong verdicts as a real property of the audited org rather than a
defect in the check.
