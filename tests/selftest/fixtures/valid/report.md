# ClickStack audit: clickstack

| | |
| --- | --- |
| Target | clickstack |
| Date | 2026-08-19 (UTC) |
| Toolkit version | 0.1.110 |
| Skill | audit-clickstack |
| Critical services | 3 (inferred live from telemetry; no service map present) |

## At a glance

**Score: 80/100**  `████████████████░░░░`  good base coverage (below the 85 end-to-end gate)

Checks passed: **21/27**

| Severity | Count | |
| --- | ---: | --- |
| 🔴 critical | 0 | `░░░░░░░░░░` |
| 🟠 high | 1 | `██████████` |
| 🟡 medium | 1 | `██████████` |
| 🔵 low | 0 | `░░░░░░░░░░` |
| ⚪ info | 1 | `██████████` |

**Start here → The storefront application services emit logs and traces but no metrics (CS-010): recovers the most points (+10).**

## Executive summary

This ClickStack instance has a healthy telemetry backbone: logs and traces are landing for all three application services, ingestion is fresh (seconds to a few minutes of lag), every telemetry table carries a deliberate 30-day retention policy, and ClickHouse itself is healthy (sane part counts, no stuck merges, no error spikes). The score is held back by two real gaps. First, the three application services (checkout, payment, api-gateway) emit logs and traces but no metrics — the metrics tables contain only the collector's own self-telemetry — so there is no per-service throughput/latency/resource time series to dashboard or alert on. Second, the ClickHouse security posture is weak: all three database users store passwords in a recoverable plaintext form, and the account used to read holds full administrative (INSERT/ALTER/DROP/SYSTEM) grants rather than a scoped read-only role. The alerting and dashboard categories could not be scored at all this run because the HyperDX API is auth-gated and no API key was configured — that is a can't-see-it visibility gap, deliberately not a confident zero.

**Score: 80/100** (gate for end-to-end: 85) | 21 of 27 checks passed; 0 critical, 1 high, 1 medium, 1 info
**Gap to target: 20 points.** Biggest levers: CS-050 (+10), CS-010 (+10).
Scored across 5 of 7 categories; HyperDX alerting and Dashboards/sources excluded (no HyperDX API key — the API returned HTTP 401 on every keyed endpoint). The end-to-end label is off the table because two categories were excluded, regardless of the score.

## Scorecard

| Category | Weight | Score | | Maturity | Checks |
| --- | ---: | ---: | --- | --- | ---: |
| Telemetry coverage | 20 | 66/100 | `██████░░░░` | reactive | 6/9 |
| Ingestion freshness | 15 | 100/100 | `██████████` | proactive | 3/3 |
| Retention | 10 | 100/100 | `██████████` | systematic | 7/7 |
| ClickHouse health | 20 | 100/100 | `██████████` | proactive | 4/4 |
| Security posture | 10 | 25/100 | `██░░░░░░░░` | reactive | 1/4 |
| HyperDX alerting | 20 | excluded | `░░░░░░░░░░` | - | - |
| Dashboards and sources | 5 | excluded | `░░░░░░░░░░` | - | - |

## Findings

### 🟠 High · ClickHouse credentials are plaintext-recoverable and the read path is over-privileged

**What's wrong:** All three ClickHouse users (`default`, `api`, `worker`) store their passwords with `auth_type = plaintext_password`, which is recoverable rather than hashed. The account used to read the database holds full administrative grants (INSERT, ALTER, DROP, TRUNCATE, OPTIMIZE, SYSTEM) instead of a scoped read-only role, and the endpoint is plain `http` rather than TLS. On the positive side, an unauthenticated probe of the `default` user returned HTTP 401, so the default user is not wide open.

**Where:** ClickHouse users `default`, `api`, and `worker` (from `system.users`); the audit read path (`SHOW GRANTS` shows full admin); the `:8123` HTTP endpoint (plaintext, loopback in this POC).

**Why it matters:** Plaintext passwords can be recovered by anyone who can read ClickHouse config or system tables, and a read path that carries destructive grants can drop or mutate telemetry by accident or if the credential leaks. A non-loopback deployment on plaintext http would also expose credentials in transit.

**How to fix:**
1. Move `api`, `worker`, and `default` off `plaintext_password` to `sha256_password` — run `/scoutflo:setup-clickstack` (#harden-clickhouse-auth).
2. Create a dedicated least-privilege read-only user (SELECT on the telemetry database plus `system.*`) and point audits at it — `/scoutflo:setup-clickstack` (#create-read-only-user).
3. Terminate a TLS listener and use an `https` ClickHouse URL for any non-loopback path.
**Done when:** `SELECT name, auth_type FROM system.users` shows no `plaintext_password` rows, `SHOW GRANTS` for the audit user lists only SELECT/SHOW-class grants, and the audit endpoint resolves over `https`.

<sub>ref: CS-050 · security-posture · new, validated-live</sub>

### 🟡 Medium · The application services emit logs and traces but no metrics

**What's wrong:** The three storefront services (`checkout-service`, `payment-service`, `api-gateway`) have recent logs and traces in ClickHouse, but zero rows in any metrics table. The metrics tables are non-empty, but they hold only the OpenTelemetry collector's own self-telemetry (`otelcol`, `otelcol-hyperdx`) — not application metrics. The metrics pipeline is working; the application services simply are not emitting metrics into it.

**Where:** Services `checkout-service`, `payment-service`, `api-gateway`. Confirmed in `otel_metrics_gauge`/`otel_metrics_sum`/`otel_metrics_histogram`: `count()` for the three services is 0; the only service names present are the collector's own.

**Why it matters:** Without per-service metrics there is no dashboardable throughput/latency/saturation time series and no metric-threshold alerting for these services; during an incident, responders must reconstruct rates and saturation from raw traces and logs. A real error signal already exists in traces (checkout-service `GET /checkout` at 4200ms with `STATUS_CODE_ERROR`) that a metric-based alert would normally catch.

**How to fix:**
1. Instrument `checkout-service`, `payment-service`, and `api-gateway` to emit OpenTelemetry RED/USE metrics, or configure the collector's metrics pipeline to receive and export their metrics to ClickHouse — `/scoutflo:setup-clickstack`.
2. If these services are intentionally metrics-free, declare that in `business_context.md` so the audit records them not-in-scope instead of a gap.
**Done when:** `SELECT count() FROM otel_metrics_gauge WHERE ServiceName IN ('checkout-service','payment-service','api-gateway')` returns a non-zero, growing count.

<sub>ref: CS-010 · telemetry-coverage · new, validated-live</sub>

### ⚪ Info · HyperDX alerting and dashboards could not be seen this run

**What's wrong:** HyperDX is reachable (`/api/health` returned 200, version 2.35.0) but every data endpoint is auth-gated: `/api/alerts`, `/api/dashboards`, and `/api/sources` each returned HTTP 401 because no HyperDX API key was configured. This is a visibility gap — the audit cannot tell whether alerts route to a human or whether dashboards exist. It is deliberately not scored as a confident zero.

**Where:** HyperDX API at `:8080` (`/api/alerts`, `/api/dashboards`, `/api/sources` all 401 without a key).

**Why it matters:** Whether any alert reaches a human (the single most important thing this audit checks) and whether incident dashboards exist are both unknown this run. The two categories are excluded from the score and the remaining five are renormalized; a future run with a key can score them.

**How to fix:**
1. Configure a read-only HyperDX API key and re-run — `/scoutflo:connect`, then `/scoutflo:audit-clickstack`.
**Done when:** `/api/alerts` returns 200 with the key and the HyperDX alerting/dashboard categories appear in the scorecard instead of `excluded`.

<sub>ref: CS-007 · scope-guardrail · new, blocked</sub>

## Suppressed findings

No exemptions configured.

## Coverage matrix

| Service | Ready | Logs | Traces | Metrics | Alerts | View | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| checkout-service | 2/3 | pass | pass | fail | blocked | blocked | Unknown | no application metrics; slow error span (GET /checkout 4200ms) |
| payment-service | 2/3 | pass | pass | fail | blocked | blocked | Unknown | no application metrics |
| api-gateway | 2/3 | pass | pass | fail | blocked | blocked | Unknown | no application metrics |

Alerts and View are `blocked` because the HyperDX API is auth-gated (no key this run), not because they are known-absent.

## Scoutflo Topology Readiness

A service map for this instance has not been generated, so per-service correlation readiness cannot be evaluated this run. The three services above were inferred directly from the telemetry (the service names recorded in the logs and traces), not from a map. To unlock this section, run `/scoutflo:map-topology` against this estate; for a non-Kubernetes estate, hand-author the service map per the export guide. Once a map exists, this section will grade whether each service's identity, workload mapping, telemetry connections, and tool identity are sufficient for automatic correlation.

## Inventory

Complete current-state catalog of what `clickstack` has configured (11 objects). This is what exists; the gaps are in Findings above.

**table (8)**

| name | covers | severity | routes to | enabled |
| --- | --- | --- | --- | --- |
| `otel_logs` | logs | - | - | yes |
| `otel_traces` | traces | - | - | yes |
| `otel_metrics_gauge` | metrics (collector self-telemetry only) | - | - | yes |
| `otel_metrics_sum` | metrics (collector self-telemetry only) | - | - | yes |
| `otel_metrics_histogram` | metrics (collector self-telemetry only) | - | - | yes |
| `otel_metrics_exponential_histogram` | metrics | - | - | yes |
| `otel_metrics_summary` | metrics | - | - | yes |
| `hyperdx_sessions` | session replay | - | - | yes |

**user (3)**

| name | covers | severity | routes to | enabled |
| --- | --- | --- | --- | --- |
| `default` | - | - | - | yes |
| `api` | - | - | - | yes |
| `worker` | - | - | - | yes |

## Next safe actions

| # | Finding | Severity | Action |
| --- | --- | --- | --- |
| 1 | CS-007 | info | Run `/scoutflo:connect` to add a read-only HyperDX API key, then re-run this audit so alerting and dashboards can be scored (verification-only, no change to the stack). |
| 2 | CS-010 | medium | Run `/scoutflo:setup-clickstack`: instrument checkout/payment/api-gateway for OpenTelemetry metrics, or receive their metrics in the collector's metrics pipeline. |
| 3 | CS-050 | high | Run `/scoutflo:setup-clickstack` (#harden-clickhouse-auth): move `default`/`api`/`worker` off plaintext passwords to sha256; then (#create-read-only-user) add a scoped read-only audit user. |

## Delta since first run

First run, no delta.

## Evidence appendix

### CS-050: ClickHouse credentials are plaintext-recoverable and the read path is over-privileged

Check: Service users are not on plaintext_password

```
$ clickhouse-client --query "SELECT name, auth_type, host_ip FROM system.users ORDER BY name FORMAT TabSeparatedWithNames"
api	['plaintext_password']	['::/0']
default	['plaintext_password']	[]
worker	['plaintext_password']	['::/0']
```

Check: External default user requires a password (unauthenticated probe; status code is the evidence)

```
$ curl -s -o /dev/null -w '%{http_code}' "http://<clickhouse-host>:8123/?query=SELECT%201"
401
# body: Code: 194. DB::Exception: default: Authentication failed: password is incorrect, or there is no user with such name
```

Check: The audit/read credential is least-privilege (SELECT/SHOW only)

```
$ clickhouse-client --query "SHOW GRANTS"
GRANT SOURCES ON *.* TO default
GRANT TABLE ENGINE ON * TO default
GRANT CHECK, SHOW, SELECT, INSERT, ALTER, CREATE, DROP, UNDROP TABLE, TRUNCATE, OPTIMIZE, BACKUP,
      KILL QUERY, KILL TRANSACTION, MOVE PARTITION BETWEEN SHARDS, SYSTEM, dictGet, INTROSPECTION,
      CLUSTER, FILE, URL, REMOTE, ... SOURCES ON *.* TO default
GRANT SET DEFINER ON * TO default
```

Check: ClickHouse is reached over TLS

```
$ printf '%s' "$CH_URL" | grep -qE '^https://' && echo https || echo plaintext
plaintext http endpoint (:8123); host class loopback in this POC
```

### CS-010: The application services emit logs and traces but no metrics

Check: Recent logs and spans per critical service (last 1h)

```
$ clickhouse-client --query "SELECT ServiceName, count() FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR GROUP BY ServiceName"
api-gateway	20
payment-service	20
checkout-service	20
$ clickhouse-client --query "SELECT ServiceName, count() FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR GROUP BY ServiceName"
api-gateway	10
payment-service	10
checkout-service	10
```

Check: Do the storefront services appear in any metrics table?

```
$ clickhouse-client --query "SELECT count() FROM otel_metrics_gauge WHERE ServiceName IN ('checkout-service','payment-service','api-gateway')"
0
$ clickhouse-client --query "SELECT 'gauge', arrayStringConcat(groupArray(DISTINCT ServiceName),', ') FROM otel_metrics_gauge UNION ALL ..."
gauge	otelcol, otelcol-hyperdx
sum	otelcol-hyperdx
histogram	otelcol-hyperdx
```

Check: Slowest spans (real error signal that a metric alert would catch)

```
$ clickhouse-client --query "SELECT ServiceName, SpanName, round(Duration/1e6,1) AS dur_ms, StatusCode FROM otel_traces ORDER BY Duration DESC LIMIT 5"
checkout-service	GET /checkout	4200	STATUS_CODE_ERROR
checkout-service	GET /checkout	4200	STATUS_CODE_ERROR
...
api-gateway	GET /cart	74	STATUS_CODE_OK
```

### CS-007: HyperDX alerting and dashboards could not be seen this run

Check: HyperDX reachability vs auth-gated resources

```
$ curl -s -o /dev/null -w '%{http_code}' http://<hyperdx>:8080/api/health
200
# {"data":"OK","version":"2.35.0","env":"production"}
$ for r in alerts dashboards sources; do curl -s -o /dev/null -w "$r: %{http_code}\n" http://<hyperdx>:8080/api/$r; done
alerts: 401
dashboards: 401
sources: 401
$ curl -s -o /dev/null -w '%{http_code}' http://<hyperdx>:8080/api/v1/alerts
404   # confirms base path is /api/<resource>, not /api/v1/*
```

Check: Estate-sizing guarded alert fetch does not silently count zero

```
$ curl -fsS http://<hyperdx>:8080/api/alerts | jq length
curl: (22) The requested URL returned error: 401
# guard printed the WARN path; alert count left unknown, not recorded as 0
```

---
Generated by [Scoutflo AI Readiness](https://scoutflo.com) for Claude Code.
