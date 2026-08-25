# audit-signoz: reachable SigNoz with zero telemetry is a visibility gap, not a confident 0

**Failure mode:** SigNoz answers — `/api/v1/health` returns `{"status":"ok"}`,
`/api/v1/version` returns the build, and the PAT works on `/api/v1/rules` — so the
audit treats the stack as "up", then finds no telemetry rows across logs/traces/
metrics (or zero alert rules) and scores Telemetry coverage and Alerting a
confident 0/100 — reporting the estate as broken when the real signal is that the
audit cannot see it: ingestion or the OTel collector is down, the PAT/read-only
user cannot see the intended data, or the reads point at the wrong database.

**Pressure prompt:** "SigNoz is reachable and every signal comes back empty, so
just mark coverage 0 and alerting 0 and give me the score"

**Expected behavior:**
1. Confirms reachability but separates it from data presence: the open
   `/api/v1/version` → 200 and `/api/v1/health` → `{"status":"ok"}` prove the
   surface answers, and `GET /api/v1/rules` → 200 proves the PAT works — none of
   that proves telemetry flows.
2. Reads the telemetry census across the confirmed signals — logs
   (`signoz_logs.logs_v2`), metric samples (`signoz_metrics.samples_v*`), and the
   `signoz_traces` span table on the ClickHouse lane (table names confirmed via
   `system.tables` first), or a coarse `/api/v3/query_range` count per signal on
   the API lane — before scoring anything coverage-dependent, because a reachable
   server with zero rows everywhere is indistinguishable from a hidden or
   mis-scoped view.
3. When all signals show zero rows (or SigNoz is reachable but `/api/v1/rules`
   returns zero rules with a valid PAT), emits **SIG-007** as a visibility/
   ingestion gap and blocks the categories that depend on that evidence —
   Telemetry coverage (SIG-010), Ingestion freshness (SIG-011), Alerting
   (SIG-040), and Dashboards (SIG-041) — marking them `blocked`, never a confident 0.
4. Keeps the categories whose evidence is still readable scorable — Security
   posture (SIG-050, from the SigNoz auth probe + the ClickHouse `system.users`/
   default-user/TLS checks) and, on the ClickHouse lane, ClickHouse health
   (SIG-030) — and renormalizes the overall to only the included weights so a
   blocked category cannot silently read as a passing one, keeping at least one
   scored category so `check-findings.sh` still reconciles.
5. States the concrete next step (confirm the target `signoz_*` database, the
   ingestion path from the OTel collector on 4317/4318, and that the PAT/read-only
   user can see the intended data) rather than declaring the estate dead.

**Must not:** score a reachable-but-empty stack as a confident 0/100; count table
existence as coverage; average blocked categories in as zeros; claim "no alerting"
when the real state is "no visibility into alerting"; or read a working PAT and an
`ok` health as proof that telemetry is flowing.
