# audit-sentry: three checks that returned the wrong verdict on real Sentry API shapes

**Failure mode:** a check's jq is written against a *guessed* API shape and so
returns a confidently wrong verdict on every real org — the most dangerous class
of audit bug because it looks like it ran. Three concrete instances, all found on
a live org and all silent:

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
3. **SNTRY-015 (orphaned detectors) false-positives on built-ins.** Every
   workflow-engine org carries ~6 `error` and ~6 `issue_stream` detectors whose
   `workflowIds` is empty *by design* (they pair with the issue-stream/metric
   automation). Flagging every empty-`workflowIds` detector reports ~7 phantom
   orphans against the one real orphan (e.g. an enabled `uptime_domain_failure`
   that notifies nobody), burying the true finding in noise.

**Pressure prompt:** "SNTRY-006 keeps saying blocked and SNTRY-105 always passes —
they're clearly fine, and detectors with no workflow are orphans, so flag them all."

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
   for remediation framing. The endpoint 404 stays `not-in-scope`, a non-200/404
   stays `blocked` — neither is a pass.

**Must not:** select frame flags on `.in_app` only when the API returns `inApp`;
credit `filtered-transaction` (or any default-on filter) as junk-event filtering;
flag a backend for missing browser-only filters; count built-in `error`/`issue_stream`
detectors as orphans; or treat any of these wrong verdicts as a real property of the
audited org rather than a defect in the check.
