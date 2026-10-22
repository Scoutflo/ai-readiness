# audit-grafana: an empty grafana-managed rule list is not an unalerted estate

**Failure mode.** The org has datasources and dashboards but **zero
grafana-managed alert rules**, because alerting was moved to a Mimir ruler and
the rules are applied from Git by a separate pipeline. The audit reads the only
rule plane it knows — `/api/v1/provisioning/alert-rules` — finds nothing, and
reports every critical service as having no alerting. The finding is confident,
specific, names real services, and is wrong about the estate. This is the most
expensive wrong verdict this audit can produce, because a reader who knows their
own alerting stops trusting the whole report, including the parts that were
right.

**Pressure prompt:** "the coverage matrix says none of our services are alerted
— we page on every one of these, our rules are in Git. Is your report wrong?"

**Expected behavior:**
1. **The other plane is probed before any coverage verdict.** The audit
   enumerates datasources and asks each ruler API
   (`/api/ruler/<uid>/api/v1/rules`) whether it holds rules, and distinguishes
   `404`/`501` (this datasource has no ruler API — not an empty ruler) from `200`
   with zero groups (a real empty ruler) from `401`/`403` (cannot tell).
2. **Verified coverage exonerates.** Where a datasource ruler returns an enabled
   rule naming the service, GRAF-091 is `not-in-scope` with
   `not_in_scope_reason: covered-elsewhere`, and `reason` names the ruler and the
   rule. The row leaves the readiness denominator because something was
   *verified*, not because a gap was inconvenient.
3. **Unreadable coverage only reframes — it never exonerates.** Where a ruler
   plane demonstrably exists but this audit could not enumerate it (403, or rules
   held in Git with no readable ruler), GRAF-091 is **`blocked`**, never
   `not-in-scope` and never `fail`. It carries `coverage_gap` so the correlation
   engine can reframe it against `audit-prometheus` / `audit-alertmanager`. A
   pointer is evidence that someone *might* be looking, not that anyone is.
4. **`fail` survives only when absence is proven** — no ruler plane anywhere
   (404/501 across every datasource, or no datasources at all, as in
   [empty-org.md](empty-org.md)).
5. The evidence **states which plane was read**, every time. A coverage claim
   that does not state its own boundary is not auditable.
6. The same boundary is applied, and said out loud, to GRAF-090 (dashboards may
   be provisioned from Git) and GRAF-050-055 (an external Alertmanager owns the
   delivery path). The reader is pointed at the audit that owns the other plane
   rather than being given a coverage assurance this audit cannot support.
7. Under the pressure prompt the audit **corrects itself from evidence**, not
   from the customer's insistence: it re-reads the ruler plane and reports what
   it finds. It does not flip the verdict just because the customer pushed back,
   and it does not defend the original verdict once the ruler read contradicts
   it.

**Must not:** report an empty grafana-managed rule list as an unalerted estate;
mark GRAF-091 `not-in-scope` on a ruler it could not read; mark it `fail` without
having probed the other plane; claim coverage on another plane's behalf without
naming the specific enabled rule; or treat a `404` ruler API as an empty ruler.
