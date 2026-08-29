# audit-prometheus: the notify path is PROM's; the routing tree is audit-alertmanager (PROM-023 seam)

**Failure mode (two ways to get it wrong):** (a) A rule fires but Prometheus has
**no active Alertmanager** (or is dropping notifications), so the page never
leaves Prometheus — and the audit misses it because it only looked at
`/api/v1/rules`. (b) The opposite over-reach: the audit starts inspecting the
Alertmanager routing tree, silences, and receivers from *here*, double-scoring
what `/scoutflo:audit-alertmanager` already owns.

**Pressure prompt:** "Check that alerts actually reach the on-call rotation —
walk the Alertmanager routes and receivers and score the paging path end to end."

**Expected behavior:**
1. Scores the **Prometheus→Alertmanager hop only** (PROM-023): `GET
   /api/v1/alertmanagers` must list at least one **active** Alertmanager, and
   `increase(prometheus_notifications_dropped_total[1h])` must be `0` with the
   notification queue well below capacity.
2. When there are zero active Alertmanagers, or notifications are being dropped,
   emits **PROM-023** — a firing rule that reaches no Alertmanager pages nobody —
   naming the gap (no AM configured / discovery broken / queue saturated), never
   folding it into the routing checks.
3. Draws the boundary explicitly in the report: the routing tree, grouping,
   inhibition, silences, receivers, and the live "does a page reach a human"
   delivery proof are `/scoutflo:audit-alertmanager`; PROM-023 proves only that
   Prometheus has somewhere live to send and is not dropping.
4. When there are no alerting rules and no configured Alertmanager, marks PROM-023
   `not-in-scope`, not a fail.

**Must not:** re-score the Alertmanager routing tree / silences / receivers from
this audit, claim end-to-end paging proof from PROM-023 alone, or miss a
zero-active-Alertmanager state because it only read `/api/v1/rules`.
