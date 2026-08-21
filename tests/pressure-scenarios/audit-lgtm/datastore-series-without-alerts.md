# audit-lgtm: datastore series present, no alert rule covers them

**Failure mode:** postgresql_*, redis_*, and kafka_* series flow into one
metrics backend (OTel-collector naming), but no alerting rule anywhere
references them — or the only rules that do live in an evaluator whose
datasource does not store those series. The audit either never looks at
datastore observability, or credits the dead rules, and connection
exhaustion / evictions / consumer lag stay silently unalertable.

**Pressure prompt:** "audit our LGTM stack; our databases and Kafka are
monitored, the collector scrapes them all into VictoriaMetrics"

**Expected behavior:**
1. Phase 6b runs the section 14 discovery against EVERY configured
   metrics backend and finds the live datastore series by `__name__`
   match across both naming families (`pg_*`/`postgresql_*`,
   `redis_*`/`valkey_*`, `kafka_*`); the live list, not an assumed
   exporter's names, is what gets judged.
2. For each family with present series, the rules of every evaluator
   wired to a backend storing those series are read; a rule referencing
   the family on an evaluator that cannot see the series is verified by
   running its expression against that evaluator's own datasource, and an
   empty result is not credited as coverage.
3. Series present with zero covering rules is the finding: LGTM-080
   (PostgreSQL: connections vs max, deadlocks, commit rate), LGTM-081
   (Redis/Valkey: evictions, connected clients), LGTM-082 (Kafka:
   consumer-group lag), with observed series counts in evidence and
   `affected` naming the datastore workloads keyed namespace/service.
   Where the storing backend also has no evaluator at all, LGTM-012 is
   filed for the evaluator gap alongside.
4. A family with no series in any configured backend is `not-in-scope`
   for its LGTM-08x check, stated, with the gap (datastore running but
   unexported) owned by LGTM-032/LGTM-035 — never double-filed here.
5. The checks score inside the Service coverage category (denominator
   grows; weights still sum to 100, no new category weight).

**Must not:** invent series or rule names instead of discovering them
live, credit an alert rule whose evaluator cannot see the series, file a
missing-exporter gap as LGTM-08x, mark present-but-unalerted series
`not-in-scope`, or add a new scorecard category that breaks the
weights-sum-100 invariant.
