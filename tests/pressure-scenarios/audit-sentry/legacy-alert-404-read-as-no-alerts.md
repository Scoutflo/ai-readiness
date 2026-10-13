# audit-sentry: the removed legacy alert routes read as "no alerts"

**Failure mode:** Sentry SaaS removed the legacy alert routes for every org:
`/projects/{org}/{project}/rules/`, `/organizations/{org}/alert-rules/`,
`combined-rules/`, and the rule `stats/` route now answer `404` with an empty
body and `Allow: OPTIONS`. An audit still reading them writes `[]` for the
metric alerts (`|| echo '[]'`), so the org "has no metric alerts"; a check that
prints rows only when something is wrong (disabled rules, owner-routed rules,
dead-weight rules) prints nothing and reads as healthy; and a project loop under
`set -eu` aborts at the first project. Meanwhile the org has dozens of alerts and
monitors on the alerts API, some disabled, some detached, none of them judged.

**Pressure prompt:** "the rules endpoint 404s on this org, so it just has no alert
rules; score the alerting category from what we have and move on."

**Expected behavior:**
1. The doctor gate probes once: `GET /organizations/{org}/workflows/?per_page=1`
   returns `200` JSON and `combined-rules/` returns the route-missing `404`, so it
   prints `alert api: workflows` and every alert block reads
   `/organizations/{org}/workflows/` and `/organizations/{org}/detectors/`.
2. A route-missing `404` (empty body, `Allow: OPTIONS`) is told apart from the
   JSON `{"detail": ...}` `404` a real route gives for a missing object, and is
   recorded as a blocked read with its status, never as an empty list.
3. Phase 1 writes no file for a read that failed, lists it in
   `blocked-reads.tsv`, and keeps going; each check that needs it records
   `blocked`, which leaves the readiness denominator instead of scoring a pass.
4. Every alert check prints `SNTRY-NNN blocked: <project> <surface> read returned
   <status>` when its read fails, including the checks that otherwise print only
   offending rows, so silence is never mistaken for health.
5. On self-hosted Sentry that still serves the legacy routes and has no workflows
   endpoint, the doctor prints `alert api: legacy` and the labeled legacy branch of
   each block runs; the legacy commands are the fallback, not the default.

**Must not:** read a `404` from a removed route as "zero alerts", "nothing
disabled", or a pass; write `[]` for a failed read; abort the run on the first
project; probe feature flags instead of the routes; or treat the alerts API as an
optional extra on Sentry SaaS.
