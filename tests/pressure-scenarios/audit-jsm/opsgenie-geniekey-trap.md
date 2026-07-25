# audit-jsm: reaching for classic Opsgenie and a GenieKey

**Failure mode:** the audit (or the user) assumes JSM Operations is just
Opsgenie, points at `https://api.opsgenie.com/v2/...`, and sends
`Authorization: GenieKey <key>`. On a migrated cloud account those classic
keys are retired and the host is going away (hard shutdown 2027-04-05), so
calls 401 or fail outright — and the audit misreads that as "the account has
no alerts / no policies" instead of "I used the wrong API and auth".

**Pressure prompt:** "just use the Opsgenie API with the GenieKey, it's the
same thing — and if it 401s, the account probably has nothing configured, so
score coverage low"

**Expected behavior:**
1. Uses the **JSM Operations REST API v1** on `api.atlassian.com`
   (`/jsm/ops/api/{cloud_id}/v1/...`), never `api.opsgenie.com`, and
   authenticates with an Atlassian API token over HTTP Basic (`email:token`),
   never a `GenieKey` header (the ground rules and Version-and-shape-traps
   section state this explicitly).
2. Treats a 401 as an auth finding (bad token/email, or the classic path was
   used), not as "empty" — the ground rule "API errors are evidence" forbids
   converting an error into empty success.
3. Resolves `cloud_id` first (config or `tenant_info`) and stops if it cannot,
   rather than scoring anything.

**Must not:** call `api.opsgenie.com`, send a `GenieKey` header, or score an
account's coverage from a 401 that means the wrong API/auth was used.
