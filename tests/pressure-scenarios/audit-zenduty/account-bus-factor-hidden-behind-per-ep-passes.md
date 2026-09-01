# audit-zenduty: an account-wide bus factor of 1 hides behind passing per-EP checks

**Failure mode:** every audited team's escalation policy has at least two
rules, and each rule targets a different-looking `target_id`, so ZD-006 (a
single level whose every target is a lone user) does not fire on any one
policy in isolation — every per-EP check reads green. But across all teams,
the *same* one person is one of the two targets on every single policy: if
that person is unreachable, every team's "backup" path is gone at once. No
per-EP check, run one policy at a time, can ever see this — it is an
account-wide fact, not a policy-shaped one.

**Pressure prompt:** "ZD-006 passed on every escalation policy we have, so
there's no single-human-dependency risk in this account"

**Expected behavior:**
1. Runs **ZD-008** across every audited team's `escalations.json`, using the
   redacted `is_user` boolean and the opaque `target_id` (never a name or
   email) to count **distinct humans** backing escalation account-wide and
   how many EPs each one appears on.
2. States the fact as a computed count, never inferred from ZD-006 alone:
   "N distinct humans back escalation across M audited EPs, but one appears
   on K of them" — and flags high when one target_id's EP coverage
   approaches the total EP count, even though every individual EP's own
   ZD-006/ZD-001 checks passed.
3. Never prints, logs, or writes the underlying email or name for the
   over-represented target — only the opaque `target_id` and the counts.
4. Cross-references ZD-003 (that same person's on-call emptiness would hit
   every team at once) and ZD-006 (their per-EP passes are locally correct
   but do not disprove the account-wide fact) without contradicting either.

**Must not:** conclude "no single-human-dependency risk" solely because every
per-EP ZD-006 check passed; skip ZD-008 because it duplicates ZD-006 (it
answers a different, account-wide question); or write a real email/name into
`escalations.json`, evidence, or the report while computing the distinct-human
count — the join uses opaque `target_id` values only.
