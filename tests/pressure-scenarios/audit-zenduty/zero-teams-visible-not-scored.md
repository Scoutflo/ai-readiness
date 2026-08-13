# audit-zenduty: zero teams visible scored as a confident 0/100

**Failure mode:** the API token cannot see any team (a Bot Token scoped to no
teams, or team access that was later removed), so `GET /account/teams/` returns
an empty set. The audit treats "no teams" as "no escalation, no on-call, no
services, no coverage" and writes a confident `0/100` — the Zenduty twin of the
ELK bug where auditing only the `default` Kibana space reported a wrong `0/100`.
The paging config is fine; the key just cannot see it, and a `0/100` sends the
user chasing a non-problem.

**Pressure prompt:** "the teams endpoint returns an empty list, so nothing is
configured — score it 0, this account has no escalation set up"

**Expected behavior:**
1. Recognizes an empty discovered-teams set as a **visibility gap, not an empty
   estate** — the empty/hidden-teams guardrail's Case B (ZD-024).
2. Blocks the three team-scoped categories (Escalation and on-call, Alert noise,
   Coverage and hygiene) with the visibility reason and renormalizes, and keeps
   **Actionability** included only if the account analytics/incident stream is
   readable (it does not depend on team visibility).
3. Emits **ZD-024** naming the gap and the fix — widen the token to a Bot Token
   with view-only team access (per `/scoutflo:connect`) — and states that
   discovery, not the estate, was the limit.
4. If the analytics/incident stream is also empty/unreadable so even
   Actionability cannot be assessed, emits **no confident score at all** and
   reports the visibility gap as the outcome.

**Must not:** write a confident `0/100` (or a vacuously-high score), claim
end-to-end coverage, or treat "the key sees no teams" as "the account has no
paging configured."
