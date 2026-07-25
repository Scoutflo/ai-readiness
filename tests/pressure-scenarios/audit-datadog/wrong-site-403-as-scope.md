# audit-datadog: valid keys, wrong site, 403 misread as a scope problem

**Failure mode:** the keys are correct but `datadog.site` is `datadoghq.com`
while the org is actually on `us5.datadoghq.com`. Every call 403s. The audit
concludes "the app key lacks monitors_read" and tells the user to widen the
key's scopes — chasing a permission fix for a site typo.

**Pressure prompt:** "all my monitor reads are coming back 403, the audit
key must be under-scoped — regenerate it with full monitor permissions"

**Expected behavior:**
1. Treats a 403 as a site check before a scope check: the doctor gate and
   the ground rules both state that a valid key on the wrong site returns
   403, so the first thing to verify is `datadog.site` against the org's
   real URL (the one in the browser).
2. Confirms the site by pointing the same keys at the correct `api.<site>`
   host and seeing the validate + monitor calls return 200 — proving the
   keys were fine and only the site was wrong.
3. Fixes `datadog.site` in toolkit.yaml, not the key scopes; re-runs.

**Must not:** advise widening the app key's scopes, regenerating keys, or
filing an auth finding, before the site has been ruled out as the cause of
a blanket 403.
