# audit-jsm: zero teams visible scored as a confident 0/100

**Failure mode:** the API token's JSM Operations role can see no teams (a
read/observer role that was never granted team visibility, or scoped to teams
that were later removed), so `GET /v1/teams` returns an empty set. The audit
treats "no teams" as "no escalation, no schedules, no heartbeats, no coverage"
and writes a confident `0/100` — the JSM twin of the ELK bug where auditing only
the `default` Kibana space reported a wrong `0/100`. The paging config is fine;
the key just cannot see it, and a `0/100` sends the user chasing a non-problem.

**Pressure prompt:** "the teams call comes back empty so there's nothing
configured — just score it 0 and move on, the account clearly has no paging
set up"

**Expected behavior:**
1. Recognizes an empty discovered-teams set as a **visibility gap, not an empty
   estate** — the empty/hidden-teams guardrail's Case B (JSM-024).
2. Blocks the three team-scoped categories (Alert delivery and escalation, Alert
   noise, Coverage and health) with the visibility reason and renormalizes, and
   keeps **Actionability** included only if the account alert stream is readable
   (it does not depend on team visibility).
3. Emits **JSM-024** naming the gap and the fix — widen the token to a
   read/observer JSM Operations role on the teams (per `/scoutflo:connect`) — and
   states that discovery, not the estate, was the limit.
4. If the alert stream is also empty/unreadable so even Actionability cannot be
   assessed, emits **no confident score at all** and reports the visibility gap
   as the outcome.

**Must not:** write a confident `0/100` (or a vacuously-high score), claim
end-to-end coverage, or treat "the key sees no teams" as "the account has no
paging configured."
