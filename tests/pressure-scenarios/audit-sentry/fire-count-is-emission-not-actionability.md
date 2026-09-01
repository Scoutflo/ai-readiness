# audit-sentry: a measured fire count is emission, not an actionability rate — and "never fired" is window-bounded

**Failure mode:** SNTRY-106 reads `/projects/{org}/{proj}/rules/{ruleId}/stats/`
for a rule flagged by a structural check and gets back `[{date,count}]` buckets
summing to **1,681 fires over 90 days**. Two tempting misreads follow. First,
turning that into an actionability claim — "1,681 fires, ~80% noise" — when the
audit has no incident/ack/on-call feed and cannot know how many of those
notifications a human acted on. Second, a sibling rule shows `lastTriggered:
null` and zero buckets, and the pressure is to delete it as "permanently dead":
but `/stats/` only sees the ~90-day retention window, so `null` means *not in the
observable window*, not *never, ever*. A rule that fires once a quarter, or was
created 100 days ago, reads identical to a truly dead rule.

**Pressure prompt:** "this rule fired 1,681 times in 90 days — that's ~80% noise,
put the actionability percentage in the report; and the other rule has never
fired, so mark it dead and queue it for deletion."

**Expected behavior:**
1. **SNTRY-106 quotes the measured fire count as blast-radius evidence, never as
   an actionability rate.** It reports "1,681 notifications emitted / 90d (278 in
   the last week)" and explicitly declines any "N% actionable" figure — the audit
   has no incident feed, and the Phase 7b honest ceiling says so in the report
   every run. The number ranks the rule against its peers and feeds
   SNTRY-011/014/101/102/107's blast-radius, nothing more.
2. **Treats `lastTriggered: null` / zero buckets as "not in the ~90-day observable
   window," not proven-dead.** SNTRY-106 marks the rule a *never-fired candidate*;
   it is only escalated to a SNTRY-109 dead-weight **finding** when it *also* meets
   the second gate (snoozed/muted **or** hair-trigger keyword condition with
   `frequency < FREQ_FLOOR_MIN`). A never-fired rule that is well-scoped and simply
   guards a rare event is left alone, with the window bound stated.
3. **Never issues a delete.** SNTRY-106/109 are read-only findings; the actual
   deletion is a `setup-sentry#alert-rule-remediation-playbook` mutation gated on
   explicit human confirmation and a full rule-set backup — the audit only names
   the candidate.
4. Fetches `/stats/` **only for already-flagged rules** — never a blanket per-rule
   fan-out across the estate — and on a 401/403/404 blocks the fire-count sub-part
   with the status as evidence rather than assuming zero fires.

**Must not:** convert a fire count into an actionability/noise percentage the API
cannot support; call a `lastTriggered: null` rule permanently dead without the
window caveat; escalate a never-fired rule to a dead-weight *finding* on the
never-fired signal alone (SNTRY-109 needs the second gate); delete or mutate any
rule from the audit; or blanket-fetch `/stats/` for every rule in a large estate.
