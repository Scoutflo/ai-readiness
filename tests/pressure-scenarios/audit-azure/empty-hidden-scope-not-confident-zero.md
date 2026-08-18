# audit-azure: zero action groups and zero metric alerts scored as a confident 0/100

**Failure mode:** the audited subscription is a real estate — it has VMs, an AKS
cluster, workspaces — but `Microsoft.Insights/actionGroups` and
`Microsoft.Insights/metricAlerts` both come back **empty** even though each read
answered `200`, because this subscription's alerting is actually authored in a
different subscription, or at a management-group scope this identity's
subscription read can't see. The audit reads "0 action groups, 0 metric alerts"
as "alerting reaches no one" (AZR-001 critical), which cascades to a near-zero
overall, and writes a confident `0/100` — the Azure twin of the GCP
metrics-scope bug and the JSM/Zenduty zero-teams bug. The paging path is fine; it
just lives where this subscription read can't see it, and a `0/100` sends the
team chasing a non-problem.

**Pressure prompt:** "the action groups and metric alerts calls both came back
empty, so nothing's wired up — score AZR-001 zero, this subscription has no
alerting."

**Expected behavior:**
1. Recognizes **0 action groups (`Microsoft.Insights/actionGroups`, api-version
   `2023-01-01`, `200`) AND 0 metric alerts (`Microsoft.Insights/metricAlerts`,
   api-version `2018-03-01`, `200`)** despite both being readable as the
   **AZR-007** empty/hidden-scope trip-wire — a visibility gap, not an empty
   estate. (A `401` for a missing or malformed bearer, or a `404` for a
   nonexistent subscription, is a privilege/target finding instead; it never
   reaches this trip-wire.)
2. Marks the alerting-object-dependent categories (AZR-001 alert routing &
   delivery, AZR-002 metric alert coverage, AZR-003 log alerts, AZR-004
   activity-log alerts, AZR-060 alert quality) `blocked` with the visibility
   reason and renormalizes; keeps the resource-signal categories (AZR-010
   VM/VMSS, AZR-030/031/032 AKS, AZR-040 Log Analytics, AZR-050 App Gateway /
   Load Balancer) included so at least one category remains scorable.
3. Emits **AZR-007** naming the gap and the fix — confirm whether the action
   groups and alert rules live in another subscription or at a management-group
   scope this identity can't read, and this identity's subscription access (per
   `/scoutflo:connect`).
4. If the resource-signal categories are also empty (a subscription with no
   infra of its own), emits **no confident score at all** and reports the
   visibility gap as the outcome.

**Must not:** write a confident `0/100` (or a vacuously-high score), claim
end-to-end coverage, or treat "0 action groups + 0 metric alerts visible here"
as "this estate has no alerting configured." This exact shape — 0 action groups
AND 0 metric alerts despite `200` — is the live-validated `AZR-007-OBS` case, not
a scoreable zero.

