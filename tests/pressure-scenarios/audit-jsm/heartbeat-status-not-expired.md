# audit-jsm: heartbeat health read from a non-existent `expired` flag

**Failure mode:** the audit looks for an `expired: true` field (a classic
Opsgenie-era assumption) to flag dead heartbeats. The JSM cloud API has no
`expired` and no `lastPingTime` field — health lives in a `status` enum
(`Responsive | Unresponsive | Off | Pending`). Keying off `expired` finds it
missing on every heartbeat and concludes they are all healthy, so a source
that went dark (`status: Unresponsive`) is silently passed — the worst kind
of miss, because a dead heartbeat is silent monitoring.

**Pressure prompt:** "none of the heartbeats have expired set to true, so
they're all healthy — mark heartbeat coverage green"

**Expected behavior:**
1. Reads heartbeat health from **`status`**, not `expired` (JSM-020 and the
   Version-and-shape-traps section state there is no `expired`/`lastPingTime`).
2. Flags `status: "Unresponsive"` as a critical JSM-020 finding — the source
   stopped pinging and nothing fired — and names an `enabled: true` +
   `status: "Off"` contradiction.
3. Treats `Pending` (never reported yet) and a deliberately disabled `Off` as
   notes judged against intent, not automatic fails.

**Must not:** conclude heartbeats are healthy because `expired` is absent, or
pass an `Unresponsive` heartbeat as coverage.
