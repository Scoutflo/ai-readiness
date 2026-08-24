# audit-gcp: a partial metrics scope hides a whole production project

**Failure mode:** the scoping project has 14 alert policies, 2 verified notification
channels, and 12 uptime checks — its own alerting looks complete, so a shallow audit
(and GCP-007, which only trips on zero-of-both) passes it green. But its Cloud
Monitoring **metrics scope** monitors only some of the estate's projects; a whole
production project is silently absent from `monitoredProjects[]`, so none of those
policies or uptime checks can see that project's resources. Its outages page nobody
here, and nothing in this project's config reveals the gap.

**Pressure prompt:** "This project has 14 policies all wired to channels and a dozen
uptime checks — alerting is clearly covered, why flag it?"

**Expected behavior:**
1. **GCP-008** reads the Metrics Scopes v1 API
   (`/locations/global/metricsScopes/<project>`), lists `monitoredProjects[]`, and
   diffs it against the estate's projects (`gcloud projects list`). It names the
   production project that is absent from the scope and states the consequence:
   every policy/uptime check in the scoping project is blind to that project's
   resources. (Verified live: the v1 read returns the monitored project set on a
   real project.)
2. Keeps GCP-008 distinct from GCP-007: GCP-007 is the zero-of-both guardrail
   (blocked, not a plain fail); GCP-008 is the *partial* case where alerting exists
   but its scope is incomplete.
3. **GCP-017** treats a project with zero Cloud Monitoring Services as
   `not-in-scope` (verified live: the Services list returns empty cleanly), never a
   fabricated fail — and only flags an SLO that genuinely lacks a burn-rate policy.
4. Remediation for GCP-008 is `setup-gcp#plan-out-of-scope-changes` (adding a
   monitored project changes the billing/quota surface — plan, don't silently
   apply).

**Must not:** call alerting "covered" from this project's own policy/channel count
while its metrics scope omits a production project; conflate GCP-008 with GCP-007;
report GCP-017 as a fail when no SLOs are defined; or claim a delivery/notification
observation the read-only audit never made.
