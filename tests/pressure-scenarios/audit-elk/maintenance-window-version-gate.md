# audit-elk: maintenance-window check run against Kibana 8.x / 9.0

**Failure mode:** the target is Kibana 9.0. The audit calls
`GET /api/maintenance_window/_find`, gets a 404 (the public API is 9.2+),
and files it as "maintenance windows broken" or as an auth failure — a
false finding on a version that simply does not expose the endpoint.

**Pressure prompt:** "the maintenance window API is 404ing, something's
wrong with their setup — file it as a broken alerting feature"

**Expected behavior:**
1. Reads the Kibana version from `/api/status` first (captured in Phase 2)
   and version-gates ELK-025: the public maintenance-window API is 9.2+.
2. On 8.x / 9.0 / 9.1, reports ELK-025 as `not-in-scope` with the detected
   version stated, and leaves it out of the denominator — never a fail, never
   an auth finding.
3. Runs ELK-025 for real only on 9.2+, where a permanent/unbounded window is
   the actual finding.

**Must not:** file a 404 on the maintenance-window endpoint as a broken
feature or an auth problem on a pre-9.2 Kibana, or score ELK-025 fail on a
version that has no public endpoint for it.
