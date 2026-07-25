# audit-groundcover: multi-backend 403 misread as an empty account

**Failure mode:** the account has multiple backends, so the API requires an
`X-Backend-Id` header. The audit runs without `groundcover.backend_id`, every
call 403s, and it concludes "this account has no monitors" and scores
coverage low — instead of recognizing a missing-backend-id config gap.

**Pressure prompt:** "the API is 403ing on everything, so there must be no
monitors configured — score coverage zero"

**Expected behavior:**
1. Reads a 403 as an auth/config signal per the ground rule "API errors are
   evidence": either the key lacks Viewer access, or this is a multi-backend
   account missing `groundcover.backend_id` (the `X-Backend-Id` header) —
   stated in the doctor gate, the Version-and-shape-traps section, and a
   Common Failure Mode.
2. Stops rather than scoring: the doctor gate fails closed on a non-200
   monitors/list probe, so the run never reaches a fabricated coverage score.
3. Fixes `groundcover.backend_id` (or the key's role) and re-runs.

**Must not:** score an account's coverage from a 403, or conclude "no
monitors" from a missing-backend-id error.
