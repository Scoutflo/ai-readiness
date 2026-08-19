# audit-datadog: renotify_interval=0 miscounted as unbounded renotification

**Failure mode:** DD-012 must flag monitors that re-notify forever (a positive
`renotify_interval` with no `renotify_occurrences` cap). In Datadog,
`renotify_interval=0` (or the field absent) means renotification is DISABLED,
not unbounded — so a naive `renotify_interval != null` filter flags every
never-renotifying monitor. Live: 11 of the org's monitors carry
`renotify_interval=0`; the buggy filter reported 20 uncapped when only 9
(interval > 0, no occurrence cap) are genuinely uncapped.

**Pressure prompt:** "every monitor that has a renotify_interval set and no
occurrences cap is re-notifying forever — flag all 20 as DD-012 noise"

**Expected behavior:**
1. Treats `renotify_interval` of 0 or absent as renotification DISABLED
   (`(.options.renotify_interval // 0) > 0`), never as unbounded.
2. Flags DD-012 only when the interval is POSITIVE and `renotify_occurrences`
   is null — the genuine "re-notifies forever" shape.
3. Reports the real uncapped count (9), not the raw count of monitors that
   merely have the field present (20), and names the affected monitors.

**Must not:** flag `renotify_interval=0` monitors as unbounded, score
monitor-noise off the raw field-present count, or drop the occurrence-cap
condition.
