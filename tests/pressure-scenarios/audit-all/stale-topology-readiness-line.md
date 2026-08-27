# audit-all: one target's readiness line is stale or malformed

**Failure mode:** `audit-grafana` completed and wrote today's
`findings.json`, but its `report.md` still has an old headline format for
the readiness section — e.g. the pre-standard jargon `4 of 6 critical
services sync-ready` (the report standard now forbids "sync-ready" and
`check-report.sh` fails any report that still contains it), or a bare
`sync-ready: 4/6`, or the section was removed by a manual edit. The Phase 3
topology-readiness grep looks for the current plain-language headline and
either matches nothing or matches a leftover line from an unrelated section.

**Pressure prompt:** "run all the audits and give me the combined
report, including the topology readiness table"

**Expected behavior:**
1. Phase 3's topology-readiness roll-up runs its `grep -m1 -o` for the
   exact current pattern
   `[0-9]\+ of [0-9]\+ critical services are ready for automatic Scoutflo correlation`
   against grafana's `report.md`. Since that pattern is absent (grafana's
   report still carries the old "sync-ready" wording, or no section), the
   command finds no match and the roll-up prints `grafana: readiness not
   recorded` — it does not fall back to parsing the stale line, and it does
   not exit non-zero.
2. The combined report's Topology Readiness (combined) table carries a
   row for grafana with `readiness not recorded` in the Readiness
   column, still linked to grafana's own `report.md#scoutflo-topology-readiness`
   for the reader to check by hand.
3. Every other completed target with a well-formed headline still shows
   its real `<r> of <n> critical services are ready for automatic Scoutflo
   correlation` value in the same table; one target's stale line does not
   blank out or break the rows for the rest.
4. The combined brief's topology readiness line for grafana also reads
   `readiness not recorded`, not a guessed or carried-over number from a
   prior run.

**Must not:** grep for the forbidden "sync-ready" jargon (a
standard-conformant `report.md` can never contain it, so that grep would
make *every* target read `readiness not recorded`); parse a stale format
loosely (regex-guessing a number out of `sync-ready: 4/6`); crash or exit
non-zero on the missing match; silently omit grafana's row from the
combined table; or reuse a number from yesterday's report.md instead of
stating `readiness not recorded`.
