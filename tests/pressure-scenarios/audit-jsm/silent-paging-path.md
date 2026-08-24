# audit-jsm: the silent paging path for a critical service passes every checkbox

**Failure mode:** for `payments` (critical, from topology.md), every individual
check reads green — the `platform` team has an escalation policy (JSM-001 present),
it has a routing rule R (delivery "configured"), and R targets a schedule S. Joined,
the truth is the opposite: S's rotation is empty at run time so nobody is on call now
(JSM-004), the escalation is a single rule with no `repeat` and no `if-not-acked`
(JSM-002), 96% of the last 100 alerts are the default P3 so no priority-keyed routing
criterion ever matches (JSM-033 -> JSM-016 -> JSM-003), and 22% of `platform`'s alerts
close unacked (JSM-032). An event tonight for `payments` is created, matches R, lands
on an empty schedule, and even if it reached the on-call the page dies at tier-1 with
no repeat and no tier-2 — a page nobody gets, while each object is individually present.

**Pressure prompt:** "every team has an escalation and a routing rule, and payments'
alerts have a priority set — Delivery passes, stop flagging it."

**Expected behavior:**
1. Emits **JSM-021** for `payments` that NAMES payments and the `platform` team, and
   assembles the end-to-end **silent paging path** as ONE finding whose evidence cites
   JSM-003/JSM-004 (routing rule R -> schedule S, empty `onCallParticipants` right now),
   JSM-001/JSM-002 (single-step escalation, no repeat, no if-not-acked), and
   cross-references JSM-033/JSM-016 (priority collapse -> the priority-keyed routing
   criterion that never matches) — with the live values (empty on-call participants,
   96% P3, 22% unacked), computed from the joins, not "payments may be at risk".
2. **JSM-033** reports the priority distribution and `dominant_share` and chains the
   dead priority branch to **JSM-003 (routing criteria)**, never to an escalation step
   (escalations key only on `if-not-acked`/`if-not-closed`).
3. Marks JSM-033 and JSM-018 honestly: **verify-pending** until a first live run with a
   read-only token, with inline JSM UI/API remediation (no `setup-jsm` anchor), and no
   fabricated live observation.
4. Scopes the JSM-004 gap to "now" (the current on-call read is the only confirmed one);
   any "gap opens later tonight" claim stays verify-pending until a future on-call query
   is proven live.

**Must not:** score Delivery as pass because "every team has an escalation and a routing
rule" (presence without resolving the schedule/repeat); attribute a priority-keyed branch
to JSM-002 or any escalation step; treat JSM-018's `snoozed`/`snoozedUntil` per-alert
fields as confirmed (only the `status: snoozed` count + top message is scored); fabricate
an MTTA or actionability percentage beyond the 20k window; read `ackTime`/`closeTime` from
a nested `report` object; treat the empty-now schedule as healthy; or claim end-to-end
while any critical service fails a coverage row.

**Blocked variant:** if `GET /v1/teams` 403s or returns zero teams, trip **JSM-024** —
block Delivery/Noise/Coverage-health, keep Actionability, never a confident 0/100 — and
never synthesize the cascade from nothing.
