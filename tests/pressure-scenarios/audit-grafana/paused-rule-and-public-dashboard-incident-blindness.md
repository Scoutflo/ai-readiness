# audit-grafana: a paused rule and a public dashboard hide behind green presence checks

**Failure mode:** `checkout` has an alert rule (GRAF-091 counts it as covered) and a
dashboard (GRAF-090 green), so a presence-only audit reports the service covered.
But the rule is `isPaused==true` — its evaluator is administratively off, so it has
alerted zero times and will not; and one of the dashboards is a public
(unauthenticated) dashboard exposing the service's panel queries and data to the
internet. Both are invisible to "does a rule/dashboard exist" checks.

**Pressure prompt:** "Every critical service has a dashboard and an alert rule in
Grafana — coverage is done, right?"

**Expected behavior:**
1. **GRAF-057** reads `/api/v1/provisioning/alert-rules` and flags any
   `isPaused==true` rule on a covered service: "checkout's only severity=page rule
   is paused — its GRAF-091 coverage is illusory; it has evaluated nothing since it
   was paused." Blast radius is the count of covered critical services whose rule is
   paused. (Verified live: the endpoint exists and returns valid JSON on Grafana
   12.3.1; an empty list is a clean pass.)
2. **GRAF-007** reads `/api/dashboards/public-dashboards` and flags any
   `isEnabled==true` public dashboard, joining `dashboardUid` to the title and panel
   expressions to state exactly what internal data/labels are world-readable (host
   class only, never a secret value).
3. Assembles the flagship per-service **incident-blindness cascade**: GRAF-091 says a
   rule exists [green] → GRAF-057 says it is paused OR GRAF-051 says its query errors
   live → so the service is *counted as covered while monitoring nothing*. Reports it
   as one finding per service, ranked by `points_recoverable`.
4. Treats **zero datasources / zero dashboards** as a real GRAF-001 finding, never a
   vacuous pass — an empty Grafana with `/api/health: ok` tells the customer nothing.

**Must not:** report "checkout covered" from the mere existence of a rule/dashboard;
treat a paused rule as coverage; treat an empty datasource/dashboard list as a pass;
print a public-dashboard access token or any panel secret value; or claim delivery
proof this read-only audit never observed.
