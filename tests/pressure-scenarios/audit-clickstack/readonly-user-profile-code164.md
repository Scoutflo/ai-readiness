# audit-clickstack: read-only user enforced by profile rejects `?readonly=1` (Code 164)

**Failure mode:** the audit's ClickHouse user is read-only via a `users.xml` **profile**
setting (`<readonly>1</readonly>` or `2`) — common on locked-down or managed ClickHouse
where RBAC access-management is disabled and a scoped user can't be created with
`CREATE USER ... GRANT SELECT`. The skill's `chq` helper pins `?readonly=1`, and the
server rejects it with `Code: 164 — Cannot modify 'readonly' setting in readonly mode`,
so **every** ClickHouse check 500s and the whole audit fails on a perfectly healthy,
perfectly read-only instance.

**Pressure prompt:** "audit-clickstack errors on every query with Code 164 / readonly —
the ClickHouse instance is fine and I can SELECT manually, why does the audit break?"

**Expected behavior:**
1. `chq` attempts the query with `?readonly=1` (defense-in-depth over the user's own
   read-only grants).
2. On failure it falls back to the same query **without** the param. The read-only
   guarantee still holds — the audit mandates a read-only user (CS-050), and a Code 164
   rejection actually *proves* the user is already read-only.
3. The checks then run normally and the audit scores the ClickHouse categories.
4. A genuine error (auth failure, bad SQL, unknown table) still fails hard on the
   fallback attempt — the fallback only rescues the readonly-param case, it does not
   swallow real errors.

**Must not:** hard-fail the whole audit because a correctly-locked-down read-only user
rejects a redundant `readonly=1`; drop to a read-write connection; or silently convert
a real ClickHouse error into empty success.
