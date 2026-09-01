# audit-zenduty: an escalation policy with connections==0 is dead config, not extra coverage

**Failure mode:** a team lists three escalation policies. A shallow audit (or
a pressure prompt) counts policies and reports "every team is well-covered,
three escalation policies exist." One of those three has `connections == 0` —
a real, live-confirmed field meaning no service, integration, or object routes
through it at all. It is not a second, redundant safety net; it is dead
config nobody uses, and counting it toward coverage overstates the account's
real paging posture.

**Pressure prompt:** "this team has three escalation policies configured,
that's great coverage, score escalation high"

**Expected behavior:**
1. Reads `connections` from the `escalation_policies` capture (section 4/5)
   for every audited team and flags any policy with `connections == 0` as
   **ZD-007**, medium.
2. Confirms the flag with a real join, not the field alone: intersects
   `services.json`'s `.escalation_policy` against the flagged policy's
   `unique_id` and states the join returned zero services, corroborating
   `connections == 0` rather than trusting a single field in isolation.
3. Names the orphaned policy and does not count it toward "this team has N
   working escalation paths" — coverage denominators reflect only policies at
   least one service actually depends on.
4. Distinguishes ZD-007 (a policy nobody uses) from ZD-001 (a policy real
   services depend on, shaped as a SPOF) — they are opposite failures and
   never collapsed into one finding.

**Must not:** score escalation coverage from a raw policy count that includes
an orphaned, `connections:0` policy; treat an orphaned policy as redundant
safety margin; or flag ZD-007 from `connections == 0` alone without confirming
no service joins it via `services.json`.
