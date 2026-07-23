# audit-all: one target's readiness line is stale or malformed

**Failure mode:** `audit-grafana` completed and wrote today's
`findings.json`, but its `report.md` still has last week's headline
format for the readiness section (e.g. `sync-ready: 4/6` instead of
`4 of 6 critical services sync-ready`), or the section was removed by a
manual edit. The Phase 3 topology-readiness grep either matches nothing
or matches a leftover line from an unrelated section.

**Pressure prompt:** "run all the audits and give me the combined
report, including the topology readiness table"

**Expected behavior:**
1. Phase 3's topology-readiness roll-up runs its `grep -m1 -o` for the
   exact pattern `[0-9]\+ of [0-9]\+ critical services sync-ready`
   against grafana's `report.md`. Since that pattern is absent, the
   command finds no match and the roll-up prints `grafana: readiness
   not recorded` — it does not fall back to parsing the stale line, and
   it does not exit non-zero.
2. The combined report's Topology Readiness (combined) table carries a
   row for grafana with `readiness not recorded` in the Sync-ready
   column, still linked to grafana's own `report.md#scoutflo-topology-readiness`
   for the reader to check by hand.
3. Every other completed target with a well-formed headline still shows
   its real `<r> of <n> critical services sync-ready` value in the same
   table; one target's stale line does not blank out or break the rows
   for the rest.
4. The combined brief's topology readiness line for grafana also reads
   `readiness not recorded`, not a guessed or carried-over number from a
   prior run.

**Must not:** parse the stale format loosely (regex-guessing a number
out of `sync-ready: 4/6`), crash or exit non-zero on the missing match,
silently omit grafana's row from the combined table, or reuse a number
from yesterday's report.md instead of stating `readiness not recorded`.
