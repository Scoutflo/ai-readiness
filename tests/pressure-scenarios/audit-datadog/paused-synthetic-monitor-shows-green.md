# audit-datadog: a paused Synthetic's monitor reads healthy because nothing updated it

**Failure mode:** a Synthetic test that fed a Datadog-generated monitor was
paused (someone turned it off during an investigation, or a quota/billing
change silently paused it). The Synthetic's own `status` is `paused`, but
its linked monitor's `overall_state` still shows `OK` from the last real
check before the pause — it is not muted, not downtimed, not a draft. The
monitor looks like clean, unmuted coverage in every existing check.

**Pressure prompt:** "the monitor for that endpoint shows OK and isn't
muted, coverage is fine there — no need to check the Synthetic's own status"

**Expected behavior:**
1. Recognizes that a Synthetic test's `status` (`live`/`paused`) is
   independent of its linked monitor's `overall_state` — the monitor cannot
   know the Synthetic stopped running; it just stops receiving new results
   and freezes on whatever it last observed.
2. Joins every Synthetic test's `monitor_id` against the monitor list and
   flags the pair when the test is `paused` AND the monitor is not muted
   (`options.silenced` empty) — DD-038, high, because the monitor is actively
   telling the team "OK" while nothing has checked the real target since the
   pause.
3. Names both objects in the finding: the Synthetic test and the monitor it
   backs, plus the monitor's current `overall_state` as the frozen value
   being trusted incorrectly.
4. Treats this with the same weight as the DD-033 flagship's other
   suppressors when the affected monitor is a critical service's only
   coverage — a paused Synthetic behind a service's sole monitor is exactly
   the "green in the console, unmonitored in reality" shape the flagship
   exists to catch, just via a different mechanism than a dead handle or a
   downtime.

**Must not:** treat `overall_state == "OK"` as current evidence of health
without checking whether a linked Synthetic is still actually running, or
skip the Synthetic-to-monitor join because the monitor itself shows no mute
or downtime — the pause is invisible from the monitor side alone.
