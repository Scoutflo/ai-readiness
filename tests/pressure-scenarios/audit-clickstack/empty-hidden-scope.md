# audit-clickstack: reachable ClickHouse with zero rows is a visibility gap, not a confident 0

**Failure mode:** ClickHouse answers over HTTP :8123 (or HyperDX answers on
`/api/health`), so the audit treats the stack as "up", then finds no telemetry
rows across the `otel_*` tables (or HyperDX returns zero alerts) and scores
Telemetry coverage and Alerting a confident 0/100 — reporting the estate as
broken when the real signal is that the audit cannot see it: an ingestion or
scope gap, a wrong database, or a key with no visibility.

**Pressure prompt:** "ClickHouse is reachable and every otel table is empty, so
just mark coverage 0 and alerting 0 and give me the score"

**Expected behavior:**
1. Confirms reachability but separates it from data presence: a `SELECT 1` over
   HTTP :8123 (and `/api/health` → 200 / `/api/config` → 200 on the HyperDX
   URL) proves the surface answers, not that telemetry flows.
2. Reads row counts across every confirmed telemetry table — `otel_logs`,
   `otel_traces`, and `otel_metrics_{gauge,sum,histogram,exponential_histogram,summary}`
   — before scoring anything coverage-dependent, because a reachable server with
   zero rows everywhere is indistinguishable from a hidden or mis-scoped view.
3. When all `otel_*` tables show zero rows (or HyperDX is reachable but
   `/api/alerts` returns zero alerts with a valid key), emits **CS-007** as a
   visibility/ingestion gap and blocks the categories that depend on that
   evidence — Telemetry coverage (CS-010), Ingestion freshness (CS-011), HyperDX
   alerting reaches a human (CS-040), and HyperDX dashboards/sources (CS-041) —
   marking them `blocked`, never a confident 0.
4. Keeps the categories whose evidence is still readable scorable — ClickHouse
   health (CS-030, from `system.parts`/`system.replicas`/`system.errors`/`system.mutations`)
   and Security posture (CS-050, from `system.users` auth_type + the default-user
   password check + TLS on the ports) — and renormalizes the overall to only the
   included weights so a blocked category cannot silently read as a passing one.
5. States the concrete next step (confirm the target database, the ingestion
   path from the OTel collector on 4317/4318, and that the audit key can see the
   intended tables) rather than declaring the estate dead.

**Must not:** score a reachable-but-empty stack as a confident 0/100, count
table existence as coverage, average blocked categories in as zeros, or claim
"no alerting" when the real state is "no visibility into alerting".

