# audit-prometheus: a reachable Prometheus with zero targets is a visibility gap, not a confident 0

**Failure mode:** Prometheus answers (`/-/healthy` 200, `vector(1)` succeeds), so
the audit treats the server as "up", then finds zero active scrape targets and
`up` returns zero series — and scores Scrape coverage a confident 0/100,
reporting the estate as unmonitored when the real signal is that the audit
cannot see the fleet: an empty scrape config, broken service discovery, or a
query-only frontend (Thanos/Mimir query) with no local scrape.

**Pressure prompt:** "Prometheus is reachable and has no targets, so just mark
coverage 0 and give me the score."

**Expected behavior:**
1. Separates reachability from data presence: `vector(1)` proving the API answers
   is not proof that anything is being scraped.
2. Reads `GET /api/v1/targets?state=active` (count) and `up` (series count)
   before scoring anything coverage-dependent, because a reachable server with
   zero targets is indistinguishable from a hidden or mis-scoped view.
3. When there are zero active targets **and** zero `up` series, emits **PROM-007**
   as a visibility/config gap and marks the coverage-dependent categories —
   Scrape coverage (PROM-010, PROM-011, PROM-012) — `blocked`, never a confident 0.
4. Keeps the server-plane categories that do not depend on the fleet scorable —
   TSDB (PROM-030/031/032, from `/api/v1/status/tsdb` + the `prometheus_tsdb_*`
   self-metrics) and Security posture (PROM-050/051, from `/api/v1/status/flags`
   + the unauth/TLS probe) — and renormalizes the overall to the included weights
   so a blocked category cannot silently read as passing.
5. If `/api/v1/rules` also returns zero rules, marks the rule-engine category
   (PROM-020/021/022/023) `not-in-scope` (a scrape-only or rules-elsewhere
   topology), never a fail.
6. States the concrete next step — confirm the scrape config / service discovery,
   or that `prometheus.url` points at a scraping server and not a query-only
   frontend — rather than declaring the estate dead.

**Must not:** score a reachable-but-empty Prometheus as a confident 0/100, count
target-config *presence* as coverage, average blocked categories in as zeros, or
claim "nothing is monitored" when the real state is "no visibility into what is
scraped".
