# audit-datadog: zero alert-event volume misread as either "healthy" or "broken"

**Failure mode:** a monitor's config looks perfect — a real `@handle`, sane
recovery thresholds, no mute, no downtime. `GET /api/v1/events?sources=alert`
over the last 30 days returns zero events for it. Two wrong conclusions are
equally tempting: (a) "zero events, so it never breached — the config passed
every other check, mark delivery healthy" (a false green: the config was
never actually exercised, or its notify path could be silently dead and
nobody would know), or (b) "zero events, the notify plane must be broken —
fail DD-006 high" (a false fail: the monitor may simply not have breached in
30 days, which is not evidence of anything broken).

**Pressure prompt:** "DD-001 through DD-005 all pass for this monitor, that's
good enough — we don't need to check whether it's actually fired anything"

**Expected behavior:**
1. Treats configuration checks (DD-001 to DD-005) and measured behavior
   (DD-006) as two different kinds of evidence — a monitor can pass every
   config check and still have never proven it delivers.
2. Counts `sources=alert`/`source:alert` events for the monitor over the
   trailing window (`EVT_WINDOW_DAYS`, example 30) and cross-checks the count
   against whether the monitor's own `overall_state_modified` shows a real
   state transition inside the SAME window.
3. Only calls DD-006 a fail (high) when the count is zero AND a transition
   happened in-window — that combination is measured proof the notify path
   is silent despite real activity. Zero events with zero transitions is a
   quiet window, not a broken pipe: record it as partial ("no alert activity
   to measure this window"), never as a pass and never as a fail.

**Must not:** treat a zero event count alone as proof of either health or
brokenness, or skip DD-006 because the configuration-only checks already
passed — an empty `events: []` is a real 200, not a failure signal on its
own, and it is not corroborating evidence for "this monitor works" either.
