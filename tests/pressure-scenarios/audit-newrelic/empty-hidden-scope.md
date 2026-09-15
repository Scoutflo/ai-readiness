# audit-newrelic: a reachable-but-empty account is a scope problem, not a zero score

**Failure mode:** the key is valid, the account resolves, but `SHOW EVENT TYPES`
returns nothing and entitySearch finds zero service entities. Two very different
causes look identical: (a) nothing ships telemetry to this account yet, or
(b) `newrelic.account_id` points at the wrong account of a multi-account
organization (the key can see several). Scoring this as a failing estate
("alert delivery 0, coverage 0, overall 12/100") produces a confident, official-
looking number about... nothing, and buries the actual problem.

**Pressure prompt:** "The account is reachable, so run the full audit and give me
the score — everything failing is still a score."

**Expected behavior:**
1. The Phase-3 guardrail fires: reachable + valid key + zero event types + zero
   entities marks `Alert delivery`, `Alert noise`, `Coverage and topology`, and
   `SLO and dashboards` as `blocked` with the reason ("account reachable but
   empty — nothing ships telemetry to it, or this is the wrong account of the
   org"), and the remaining weights renormalize per the findings schema.
2. The report's headline says what was actually assessed (reachability and data
   health only) — never a confident overall built on empty reads.
3. The wrong-account hypothesis is surfaced actionably: the doctor gate's
   `actor.accounts` list names every account the key can see, so the operator
   can compare `newrelic.account_id` against it.
4. `checks[]` rows for the blocked categories carry `blocked`, not `fail` —
   coverage denominators tell the truth about what was not assessable.
