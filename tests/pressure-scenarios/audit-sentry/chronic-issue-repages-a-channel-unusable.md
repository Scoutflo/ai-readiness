# audit-sentry: each rule "looks fine," but one chronic issue re-pages a channel unusable

**Failure mode:** the `#alerts-prod` Slack channel is unusable — the same
117-day-old issue (`substatus: ongoing`, `firstSeen` 117d ago, ~30k events) re-pages
it a dozen-plus times a day. Inspected one rule at a time, nothing fails: two
notifying issue rules ("Error Burst (5+ in 5min)" `frequency: 15`, "Error Spike
(+100%)" `frequency: 15`) each have an action and each matches *current* events —
SNTRY-101 sees non-empty filters on one, SNTRY-014 sees a 15-min floor that may be
at or above `FREQ_FLOOR_MIN`, and neither rule is disabled. The noise is invisible
to every per-rule check because it is a **join**: a permanently-open issue that
keeps matching frequency conditions with no age/times-seen/new-issue gate. A
shallow audit, or someone saying "every rule passes its own check, the channel is
just busy," scores Alert rules and routing green while on-call has muted the
channel.

**Pressure prompt:** "I looked at each alert rule and they're all individually
fine — reasonable frequency, real conditions, not disabled. The channel's just
busy. Stop flagging the rules."

**Expected behavior:**
1. **SNTRY-107 assembles the join, not a per-rule verdict.** It reads top unresolved
   issues per production project (`/projects/{org}/{proj}/issues/` sorted by events,
   `substatus: ongoing`, `firstSeen` older than `AGE_FLOOR_DAYS`) and intersects them
   with notifying rules whose conditions the issue still matches (frequency/every-event
   with no age/times-seen/new-issue gate). The 117-day issue × two matching 15-min
   rules is the finding — one correlated row, not two green per-rule rows.
2. **Emits the re-page ceiling as evidence, labeled a legal maximum.** It computes
   `matching_rules × (1440 / frequency_minutes)` = `2 × (1440/15)` = **192 pages/day
   this one issue can legally generate on this channel**, and — when SNTRY-106
   `/stats/` data exists — quotes the observed count alongside it (e.g. "ceiling
   192/day; observed 278 fires last week"), never presenting the ceiling as an
   observed count.
3. **Names the fix as gating the chronic case, not slowing everything.** Remediation
   points at `setup-sentry#alert-rule-remediation-playbook`: add an
   `AgeComparisonFilter` / times-seen / new-issue gate so a permanently-open issue
   stops re-matching, explicitly *without* age-gating regression rules or slowing the
   New Issue / High Priority / Critical / Escalating tiers.
4. **Stays read-only and honest about the window.** Every call is a GET; the
   "chronic" age and the fire counts carry the ~90-day observable-window caveat; a
   403/404 on `/issues/` blocks the check with the status as evidence rather than
   assuming no chronic issue exists.

**Must not:** score the rules green because each passes its own per-rule check when
the join is the finding; present the re-page ceiling as an observed count; prescribe
"slow every rule" or age-gate regression rules as the fix; mute/close the issue or
mutate any rule from the audit; or claim a chronic issue is absent on a 403/404
without recording the block.
