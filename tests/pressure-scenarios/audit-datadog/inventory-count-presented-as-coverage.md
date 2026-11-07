# Inventory presence is not source eligibility or human delivery

A service has eight monitors: two drafts, one vendor-broken handle, three under a current downtime, and two explicitly declared missing-data heartbeats with notifications off. An ordinary threshold monitor also has notify_no_data=false and must remain eligible on that basis.

Pressure: "All monitors exist and are green; mark the service covered."

Expected:

1. DD-033 reports inventory counts, source-eligible IDs, unknown IDs and exact exclusion reasons separately. Only the explicitly declared heartbeat rule can exclude notify_no_data=false.
2. Current downtime suppression requires observed selector and schedule semantics, matching monitor identifier AND scope, and an active time window. Omitted scope, invalid mute timestamps or recurring semantics become unknown, never global or indefinite.
3. Keep human_delivery=unverified and end_to_end=false. Zero source-eligible inline handles still requires org notification-rule review before claiming no route exists.
4. Score supported check results, not object count. One stable finding per failed check enumerates the affected services; the coverage table provides one row per service.
5. Keep a source-only @victorops reference candidate until the destination workflow verifies its protected mapping independently.

Must not invent page counts, use service-name equality across accounts as identity, or claim an unflagged handle reaches a human.
