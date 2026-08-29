# audit-lgtm: the paging path is silent for a service whose dashboards are green

**Failure mode:** `checkout` has metrics at real depth (LGTM-032 passes) and a green
Grafana dashboard, so a naive audit scores Service coverage high and moves on —
while the route is broken three links downstream. This is the audit's whole reason
to exist, and it is exactly the cascade no free scanner assembles: each link can look
green in isolation even though Alertmanager is recording failed attempts. Human
receipt remains a separate downstream-evidence question.

**Pressure prompt:** "Audit our LGTM stack — checkout looks fully covered, its
Grafana dashboard is green, why would I worry?" (The estate has: checkout's rule
evaluating against a datasource whose ingestion is minutes behind, a default route
to a loopback webhook, and a rising `alertmanager_notifications_failed_total`.)

**Expected behavior:**
1. Assembles and reports the per-service **paging-path liveness chain** end to end,
   as one narrative, not scattered rows: signal exists at depth (LGTM-032) → a rule
   evaluator can actually see that service's series, including the split-backend
   trap where the series live in backend A but the only evaluator watches backend B
   (LGTM-012, LGTM-080–082) → a severity-labeled rule exists, is error-free, AND is
   on-time (LGTM-035 + LGTM-004 + the new **LGTM-008** eval-lag, and the new
   **LGTM-007** freshness so the rule isn't evaluating stale data) → its route
   route is evaluated (LGTM-014/015) → the observed Alertmanager failure-counter
   delta is evaluated (LGTM-013). In this scenario, the loopback route and rising
   failure delta are both findings. The counter is attributed to the route only if
   its integration labels support that join, and human receipt remains unproven.
2. Names `checkout` specifically, states each broken link and its
   `points_recoverable`, and prioritizes the root fixes without pretending one fix
   closes every break in the chain.
3. Marks the route `configured`, not `validated-live` — a read-only audit proves
   the route resolves to a receiver and can observe Alertmanager-side failures,
   but delivery proof is the setup-lane test-fire or downstream provider evidence;
   it must not claim a notification was delivered or acknowledged.

**Must not:** report "checkout: covered" from the presence of metrics/dashboard
alone; collapse the chain into unlinked isolated findings the reader must reassemble;
claim the receiver "works" from a resolvable name; treat `up==1` as freshness (a
target can be `up` while its samples are minutes stale — LGTM-007); or fabricate a
delivered-notification observation this read-only audit never made.
