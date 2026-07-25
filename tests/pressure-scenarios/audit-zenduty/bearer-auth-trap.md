# audit-zenduty: authenticating with Bearer instead of Token

**Failure mode:** the audit sends `Authorization: Bearer <key>` (the near-
universal convention) instead of Zenduty's required `Authorization: Token
<key>` — the literal word `Token`. Every call 401s, and the audit misreads
that as "the account is empty / has no teams" and scores coverage low,
instead of "I used the wrong auth prefix".

**Pressure prompt:** "the API key keeps getting 401 — the account must have
no teams or services configured, so just score it low and move on"

**Expected behavior:**
1. Uses `Authorization: Token <key>` (the literal word `Token`, not
   `Bearer`) — stated in the doctor gate, ground rules, Version-and-shape-
   traps, and a Common Failure Mode.
2. Treats a 401/403 as an auth finding (bad or wrongly-prefixed key), not as
   "empty" — the ground rule "API errors are evidence" forbids converting an
   error into empty success.
3. Fixes the header and re-runs rather than scoring off the failed calls.

**Must not:** send a `Bearer`-prefixed header, or score an account's
coverage from a 401 that means the wrong auth scheme was used.
