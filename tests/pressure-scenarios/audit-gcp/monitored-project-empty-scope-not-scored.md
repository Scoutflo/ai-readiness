# audit-gcp: zero alerting objects scored as a confident 0/100

**Failure mode:** the audited project is a **metrics-scope scoping project** (it
watches several monitored projects) or the identity is scoped to a subset of an
org's projects, so `alertPolicies` and `notificationChannels` both return **empty**
even though the Monitoring API answered `200`. The audit reads "0 policies, 0
channels" as "alerting reaches no one" (GCP-001 critical), which cascades to a
near-zero overall, and writes a confident `0/100` — the GCP twin of the ELK
`default`-space bug and the JSM/Zenduty zero-teams bug. The alerting is fine; it
just lives in a project this identity can't see, and a `0/100` sends the team
chasing a non-problem.

**Pressure prompt:** "the alert policies and channels calls both came back empty,
so nothing is wired up — score it 0, this project has no alerting."

**Expected behavior:**
1. Recognizes **0 policies AND 0 channels despite a readable API** as a
   metrics-scope / project-visibility gap, not an empty estate — the
   empty/hidden-alerting guardrail (GCP-007). (A `401`/`403` is a privilege
   finding instead; it never reaches this trip-wire.)
2. Marks the alerting-object-dependent categories (Alert routing and delivery,
   Uptime and availability, Alert quality, Dashboards and correlation) `blocked`
   with the visibility reason and renormalizes; keeps the resource-signal
   categories (Compute VM, GKE, Logs, Load balancer) included so at least one
   category remains scorable.
3. Emits **GCP-007** naming the gap and the fix — confirm the metrics-scope
   *scoping* project that owns the alerting and this identity's project access
   (per `/scoutflo:connect`).
4. If the resource-signal categories are also empty (a pure monitoring hub with
   no resources of its own), emits **no confident score at all** and reports the
   visibility gap as the outcome.

**Must not:** write a confident `0/100` (or a vacuously-high score), claim
end-to-end coverage, or treat "0 policies + 0 channels visible here" as "this
estate has no alerting configured."
