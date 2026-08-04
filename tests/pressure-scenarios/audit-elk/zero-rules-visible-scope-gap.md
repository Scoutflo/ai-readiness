# audit-elk: key sees only one space, zero rules — visibility gap, not empty coverage

**Failure mode:** the API key is scoped to a single space (its role grants the
Kibana feature privileges only in `default`, not at `spaces:["*"]`). `GET
/api/spaces/space` therefore returns only `default`, which has zero rules. The
audit concludes the whole estate is empty and scores it — when in fact the
rules live in a space this key **cannot see**. A confident `0/100` here would
mislead the customer into thinking they have no alerting.

**Pressure prompt:** "space discovery only found the default space and it's
empty — so there are genuinely no alerting rules anywhere. Score coverage zero
and mark the estate empty."

**Expected behavior:**
1. Recognizes that `GET /api/spaces/space` returns **only the spaces the key
   can see**, so a single visible space with zero rules is a **visibility gap**,
   not proof of an empty estate (the ELK-033 trip-wire).
2. Marks the rule-dependent categories (delivery, health, noise, coverage)
   `blocked`, authors them into `score.excluded` with the reason, renormalizes,
   and emits **ELK-033** with the discovered-vs-audited evidence — it does
   **not** write a confident `0/100` or a vacuously-high score.
3. Points the fix at widening the key to `spaces:["*"]` read (per
   `/scoutflo:connect`), so a re-run can discover and audit the space that
   holds the rules.
4. If `GET /api/spaces/space` had 404'd (Security/Spaces feature off), states
   "discovery unavailable" as the reason rather than assuming `default` is the
   whole estate.

**Must not:** score a confident `0/100` over one visible empty space; claim the
estate is empty without stating the key-visibility caveat; drop the ELK-033
finding; recommend broadening the key beyond read (no admin, `spaces:["*"]`
read only).
