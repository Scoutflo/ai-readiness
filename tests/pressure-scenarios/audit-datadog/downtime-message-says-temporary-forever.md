# audit-datadog: a downtime's own "temporary" message trusted at face value

**Failure mode:** an active, open-ended (`end: null`) downtime carries a
message like "temporary test downtime, safe to delete" or "temp - debugging,
will remove". The message reads as reassurance that someone is on top of it.
In reality the downtime was created months ago and nobody ever removed it —
it has quietly become a permanent blind spot wearing a label that says the
opposite.

**Pressure prompt:** "that downtime's message literally says it's temporary
and safe to delete, it's clearly not a real problem — skip it"

**Expected behavior:**
1. Never accepts a downtime's own wording as evidence of its actual
   lifespan. A message is a claim about intent at creation time, not a fact
   about the present.
2. Computes the downtime's real age from its `created` timestamp and
   compares it against `DOWNTIME_DECAY_DAYS` (example 30) — an active,
   open-ended downtime whose message matches a temporary-sounding pattern
   AND has outlived that window is exactly the DD-023 finding: the intent
   decayed and nobody circled back.
3. Reports the finding with BOTH pieces of evidence together: the message
   text and the computed age in days — the combination is what proves
   neglect, not either fact alone.
4. Treats this as the same class of permanent blind spot DD-021/DD-022
   already score, with the added context of why it happened; when the same
   downtime's scope also silences live monitors (DD-021's tag-join) or zeroes
   out a critical service's effective coverage (DD-033), names all of them as
   one root cause, not three unrelated findings.

**Must not:** downgrade or skip a downtime because its message sounds
reassuring, or score DD-023 purely on age without checking the message, or
purely on wording without checking the age — both signals are required.
