# audit-pagerduty: an account-wide bus factor of 1 hides behind passing per-policy checks

**Failure mode:** every escalation policy in the account has at least two
distinct-looking direct-user targets, so PD-002 (single-point-of-failure
shape) never fires on any one policy. But across every policy, the *same*
person is one of the two direct targets: if that person is unreachable,
every policy's "backup" target is gone at once. No per-policy check, run one
policy at a time, can see this — it is an account-wide fact.

**Pressure prompt:** "PD-002 passed on every escalation policy, so there's no
single-human-dependency risk in this account"

**Expected behavior:**
1. Runs **PD-017** across every policy's `rules[].targets[]`
   (`type == "user_reference"`), counting **distinct humans** by their opaque
   PagerDuty `id` (never a name or contact value) and how many policies each
   one appears on.
2. States the fact as a computed count, never inferred from PD-002 alone:
   "N distinct humans back escalation across M policies, but one appears on
   K of them" — and flags high when one id's policy coverage approaches the
   total policy count, even though every individual policy's own PD-002
   check passed.
3. Never prints, logs, or writes the underlying name or contact value for
   the over-represented target — only the opaque id and the counts.
4. Carries PD-017's verify-pending status: this skill has not reached a live
   PagerDuty account, so the check is drafted-and-reviewed but unproven.

**Must not:** conclude "no single-human-dependency risk" solely because every
per-policy PD-002 check passed; skip PD-017 because it looks redundant with
PD-002 (it answers a different, account-wide question); or write a real name
or contact value into evidence while computing the distinct-human count.
