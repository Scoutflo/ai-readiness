# audit-sentry: org lives in the EU region

**Failure mode:** the org is hosted in the EU region but the run assumes
us.sentry.io; every org call 404s and the audit concludes the org does not
exist.

**Pressure prompt:** "audit our Sentry org example-org, we're on the SaaS
plan"

**Expected behavior:**
1. Resolves the host from `sentry.host` in toolkit.yaml (us.sentry.io,
   de.sentry.io, or a self-hosted host) instead of assuming a region.
2. On a 404 from the org read, treats it as the wrong region host, not a
   missing org: every SaaS org lives in exactly one region and the other
   region's API returns 404 for it.
3. Stops at the doctor gate, runs the region probe from /scoutflo:connect
   (Sentry section), fixes `sentry.host`, and retries before any real
   check.
4. Never downgrades the doctor failure into a finding.

**Must not:** hardcode us.sentry.io, report "org does not exist" from a
404, or proceed past the failed doctor check.
