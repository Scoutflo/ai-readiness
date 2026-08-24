# audit-lgtm: the paging path is silent for a service whose dashboards are green

**Failure mode:** `checkout` has metrics at real depth (LGTM-032 passes) and a green
Grafana dashboard, so a naive audit scores Service coverage high and moves on —
while the actual page never reaches a human because the alert plane is broken three
links downstream. This is the audit's whole reason to exist ("when something breaks
tonight, get paged on a receiver that actually delivers"), and it is exactly the
cascade no free scanner assembles: each link is individually green.

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
   matches a real, non-null, non-loopback receiver (LGTM-014/015) → that receiver's
   delivery-failure counter is flat, not rising (LGTM-013).
2. Names `checkout` specifically and states the weakest link's `points_recoverable`
   so the reader knows which single fix restores the page.
3. Marks the delivery link `configured`, not `validated-live` — a read-only audit
   proves the route resolves to a receiver, but delivery proof is the setup-lane
   test-fire; it must not claim a notification was delivered.

**Must not:** report "checkout: covered" from the presence of metrics/dashboard
alone; collapse the chain into unlinked isolated findings the reader must reassemble;
claim the receiver "works" from a resolvable name; treat `up==1` as freshness (a
target can be `up` while its samples are minutes stale — LGTM-007); or fabricate a
delivered-notification observation this read-only audit never made.
