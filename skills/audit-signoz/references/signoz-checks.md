# audit-signoz: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-signoz](../SKILL.md) workflow covers. SigNoz is an OpenTelemetry-native observability platform — metrics, traces, and logs — built on **ClickHouse**, with a query-service/frontend (the `signoz` pod, HTTP `:8080`), a bundled Alertmanager, Zookeeper, and an OTel collector that feeds ingestion. This audit reads two surfaces: the **SigNoz REST/query API** under `/api/v1/*` and `/api/v3/query_range` (authenticated with a VIEWER PAT), and — on the optional deep lane — the **SigNoz ClickHouse** read surface over HTTP `:8123`. Each section lists the catalog IDs it serves, the exact read command, the healthy target, the finding it emits, and the mutations forbidden on that surface. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- The endpoints, auth model, ClickHouse databases, and error-code semantics below were **confirmed on a live read** of a SigNoz **v0.138** instance. Anything marked **confirm-live** (the JSON response shapes of `/api/v1/rules`, `/api/v1/channels`, `/api/v1/dashboards`, and `/api/v1/settings/ttl`; the `POST /api/v3/query_range` request body; and every SigNoz ClickHouse column name) needs verifying against your instance with a working credential before the skill asserts it. Never invent an endpoint, table, column, or field beyond what is confirmed.
- **SigNoz API auth:** every authenticated call sends the header `SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}`, where the PAT is a **VIEWER-role** Personal Access Token created in SigNoz Settings → API Keys. Two endpoints are **open (no auth)** and are the reachability/liveness probes: `GET /api/v1/version` (returns `{"version":"v0.138.0","ee":"Y","setupCompleted":...}`) and `GET /api/v1/health` (returns `{"status":"ok"}`) — both HTTP 200. The authed endpoints `GET /api/v1/rules`, `GET /api/v1/channels`, `GET /api/v1/dashboards`, and `GET /api/v1/settings/ttl`, plus `POST /api/v3/query_range`, return HTTP `401` JSON `{"status":"error","error":{"type":"unauthenticated",...}}` without the PAT — that 401 confirms the endpoint exists and requires auth; it is not a broken path.
- **SigNoz ClickHouse read surface (optional deep lane):** HTTP on `:8123`. Every ClickHouse block authenticates as a **least-privilege read-only user** (see [SIG-050](#8-security-posture-sig-050-and-query-api-health-sig-001)) — that user is the read-only guarantee. The HTTP `readonly=1` setting is pinned as *defense-in-depth* on top of it; a user that is **already read-only by profile** rejects `?readonly=1` with `Code: 164 — Cannot modify 'readonly' setting in readonly mode`, which itself proves the user is read-only, so `chq` falls back to the query without the param. Probe the `readonly=1` form **once** per session and remember which form works — retrying it on every call lands a Code-164 row per query in `system.errors`, which SIG-030 would then read back as "spiking READONLY errors" (the audit polluting the signal it audits). The SQL is sent as the raw POST body with `--data-binary`; nothing is stored.
- Presence-check tokens and passwords only; never echo, log, or write a secret value anywhere. Rendered channel configs and API responses can embed webhook URLs with secrets — record their shape and host class (loopback, private, public, placeholder), never the full URL.
- `curl -fsS --max-time 20` is the default. Where a status code is itself the evidence (the unauthenticated ClickHouse default-user probe in SIG-050, and the no-PAT SigNoz probe), `-f` is dropped deliberately and `-w '%{http_code}'` is used; those blocks say so.
- Time windows and thresholds are examples; tune to your ingest volume: `RECENT="INTERVAL 1 HOUR"` for coverage, `FRESH_LAG_S=900` for freshness, part-count and error-spike thresholds per your cluster size.
- The single-node build has **no replicas and no sharding**, so `system.replicas` is empty there — that is expected, not a finding. Replica checks apply to clustered ClickHouse.

SigNoz API helper (declare once per session; every SigNoz block below calls `sig_get`):

```bash
set -eu
SIG_URL="https://your-signoz-host:8080"     # signoz.url
SIG_URL="${SIG_URL%/}"
SIGNOZ_API_KEY="${SIGNOZ_API_KEY:-}"         # signoz.api_key_env; presence-checked by the doctor gate
[ -n "$SIGNOZ_API_KEY" ] || { echo "no SigNoz PAT set (signoz.api_key_env); authed checks unavailable — run /scoutflo:connect"; exit 1; }

# sig_get <path> — the ONE way every SigNoz block below reads the API; GET only.
sig_get() {
  curl -fsS --max-time 20 -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" "${SIG_URL}$1"
}

# sig_query <json-body-file> — the read-only query API. POST is the documented verb for
# /api/v3/query_range; it carries a query builder body and returns server-side aggregation.
# It creates/changes nothing. The body shape is confirm-live: build it from the live instance
# (the SigNoz UI's own network calls are the reference) and read the response shape live.
sig_query() {
  curl -fsS --max-time 30 -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" \
    -H 'Content-Type: application/json' --data-binary @"$1" "${SIG_URL}/api/v3/query_range"
}
```

ClickHouse helper (declare once per session; every ClickHouse block below calls `chq`; only when the deep lane is configured):

```bash
set -eu
CH_URL="http://your-clickhouse-host:8123"    # signoz.clickhouse_url
CH_USER="${CH_USER:-signoz_ro}"              # signoz.clickhouse_user (the read-only audit user)
CH_KEY="${SIGNOZ_CH_KEY:-}"                  # signoz.clickhouse_password_env; presence-checked by the doctor gate

# One read-only SELECT. readonly=1 is defense-in-depth over the user's own read-only grants;
# -f turns any write attempt, auth failure, or error into a hard non-zero exit. If the server
# rejects readonly=1 (Code 164 — the user is already read-only by profile), retry without the
# param: the read-only guarantee still holds from the scoped user, so this is safe, not a downgrade.
# Probe the readonly=1 form ONCE per session and remember which form works.
CHQ_FORM=""   # set on first call: "ro" (readonly=1 accepted) or "plain" (profile-readonly user)
chq() {
  if [ -z "$CHQ_FORM" ]; then
    if curl -fsS --max-time 20 -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_KEY}" \
         "${CH_URL}/?readonly=1" --data-binary "SELECT 1" >/dev/null 2>&1; then
      CHQ_FORM="ro"
    else
      CHQ_FORM="plain"   # user is already read-only by profile (Code 164 on the param)
    fi
  fi
  if [ "$CHQ_FORM" = "ro" ]; then
    curl -fsS --max-time 20 -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_KEY}" \
      "${CH_URL}/?readonly=1" --data-binary "$1"
  else
    curl -fsS --max-time 20 -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_KEY}" \
      "${CH_URL}/" --data-binary "$1"
  fi
}
```

Doctor reachability + liveness (open endpoints, then one authed probe). Self-contained so it runs standalone or after the `sig_get` helper:

```bash
set -eu
SIG_URL="${SIG_URL:-https://your-signoz-host:8080}"; SIG_URL="${SIG_URL%/}"   # signoz.url
SIGNOZ_API_KEY="${SIGNOZ_API_KEY:-}"                                          # signoz.api_key_env
[ -n "$SIGNOZ_API_KEY" ] || { echo "no SigNoz PAT set (signoz.api_key_env) — run /scoutflo:connect"; exit 1; }
# Open endpoints — reachability, no auth (both 200 on a healthy instance):
curl -fsS --max-time 10 "${SIG_URL}/api/v1/version" | jq -e '.version and (.setupCompleted != null)' >/dev/null \
  && echo "version endpoint ok" || { echo "GET /api/v1/version did not answer as expected; wrong host/port"; exit 1; }
curl -fsS --max-time 10 "${SIG_URL}/api/v1/health" | jq -e '.status == "ok"' >/dev/null \
  && echo "health ok" || echo "WARN: /api/v1/health did not report ok"
# Authed probe — the PAT actually works (SIG-001 evidence):
RC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" "${SIG_URL}/api/v1/rules")"
case "$RC" in
  200) echo "authed query API ok (GET /api/v1/rules -> 200 with the PAT)";;
  401) echo "GET /api/v1/rules -> 401 unauthenticated: the PAT is missing, wrong, or not VIEWER-capable — run /scoutflo:connect"; exit 1;;
  *)   echo "GET /api/v1/rules -> ${RC}; verify signoz.url and the PAT"; exit 1;;
esac
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge real impact in your environment. Registered prefix: **SIG**.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| SIG-007 | Scope guardrail | Reachable SigNoz with **zero telemetry across logs/traces/metrics**, or **zero alert rules**, is a visibility/ingestion gap — blocks the coverage/alerting-dependent categories, never a confident 0 | info |
| SIG-001 | Query API health | The authenticated read path answers with the PAT (`GET /api/v1/rules` → 200; the query API `POST /api/v3/query_range` resolves) — proves the surface the whole audit depends on works | high |
| SIG-010 | Telemetry coverage | Logs, traces, and metrics carry recent data for the critical services (via `/api/v3/query_range` or the `signoz_*` tables) | high |
| SIG-011 | Ingestion freshness | `max(<ts_col>)` lag on logs/traces/metrics within threshold (stale = broken pipeline) | high |
| SIG-020 | Retention | Each signal (traces/metrics/logs) has a deliberate TTL (via `/api/v1/settings/ttl` and/or the ClickHouse table TTL); unbounded = cost/compliance gap, too-short = data-loss gap | high |
| SIG-030 | ClickHouse health | Part counts sane, replicas in sync, no spiking `system.errors` codes (discount the single `READONLY` (164) row the section-1 probe may add), no stuck mutations | high |
| SIG-040 | Alerting | Alert rules exist **and** evaluate **and** route to a live channel; a rule wired to no channel, a dead channel, or a placeholder destination is the core failure | critical |
| SIG-041 | Dashboards | Dashboards exist and their panel queries resolve for the critical services | medium |
| SIG-050 | Security posture | SigNoz endpoint requires auth (not publicly readable); ClickHouse `default` user requires a password; service users off `plaintext_password`; TLS on the wire; least-privilege read-only CH user + VIEWER PAT for audits | high |
| SIG-060 | Capacity headroom | Disk headroom vs telemetry growth — days-to-read-only before the disk fills and every INSERT is rejected (243 `NOT_ENOUGH_SPACE`) | high |
| SIG-061 | Write-path failures | Collector writes rejected by ClickHouse (`query_log` Insert exceptions; 243 `NOT_ENOUGH_SPACE`, 252 `TOO_MANY_PARTS`, 164 `READONLY`, 201 `QUOTA_EXCEEDED`) | high |

## 3. SIG-007 — empty / hidden-scope guardrail (run first)

Run this **before scoring any coverage or alerting category**. A reachable backend with no data, or no alert rules, is a visibility or ingestion gap, not a confident `0/100`.

Alert-rule census (any rules at all?):

```bash
sig_get /api/v1/rules | jq 'if type=="array" then length elif has("data") then (.data|length) elif has("rules") then (.rules|length) else 0 end'
# response shape confirm-live: the top-level key is confirm-against-your-instance; the census is "any rules at all?"
```

Telemetry census — on the ClickHouse lane, count rows across the confirmed telemetry databases (a `count()` on a MergeTree table is cheap; discover the exact table names first so nothing is assumed):

```bash
# Enumerate the telemetry tables that actually exist before counting them.
chq "SELECT database, name FROM system.tables
     WHERE database IN ('signoz_traces','signoz_logs','signoz_metrics','signoz_meter')
       AND engine LIKE '%MergeTree%'
     ORDER BY database, name FORMAT TabSeparatedWithNames"
# Then count() the log/trace/metric tables the enumeration confirmed (substitute the confirmed names):
chq "SELECT 'logs' AS signal, count() AS total FROM signoz_logs.logs_v2
     UNION ALL SELECT 'metric_samples', count() FROM signoz_metrics.samples_v4
     ORDER BY total DESC FORMAT TabSeparatedWithNames"
# (the traces span table name is confirm-live — read it from the enumeration above, then count it)
```

Without the ClickHouse lane, the census is the query API instead — `POST /api/v3/query_range` for a coarse count over the recent window across each signal (body confirm-live).

- **Healthy target:** at least one signal carries rows, and at least one alert rule exists.
- **Finding (SIG-007):** if SigNoz is reachable (`/api/v1/health` ok, PAT works) but **every** telemetry signal returns `0` in the recent window, emit SIG-007 and mark the coverage-dependent categories (**SIG-010, SIG-011**) `blocked`. If SigNoz is reachable but returns **zero alert rules**, emit SIG-007 and mark the alerting-dependent categories (**SIG-040, SIG-041**) `blocked`. In both cases keep **Security posture (SIG-050)** — and, on the ClickHouse lane, **DB health (SIG-030)** — scorable, then **renormalize** the overall over the categories that remain. Never report a confident `0/100` from an empty read; the likely cause is that ingestion or the collector is down, the read path cannot see the database, or the PAT cannot see the intended data — not that observability is confidently absent.
- **Forbidden on both surfaces here:** SELECT / GET only; see section 9.

## 4. Telemetry: coverage and freshness (SIG-010, SIG-011)

Two lanes — the SigNoz query API (always available with the PAT) and the ClickHouse deep lane (when configured). Prefer ClickHouse for per-service depth because its rows are exact; use the query API when the ClickHouse lane is not configured.

### SIG-010 — telemetry coverage

**SigNoz query API lane.** The `/api/v3/query_range` body is confirm-live — build the minimal query builder payload that counts events per service over the recent window against the live instance, then read the result rows from the live response. A defensive skeleton (adjust field names to your instance's response):

```bash
# body.json is a query-builder payload you confirm against your instance (the UI's own
# network call to /api/v3/query_range is the reference). Do NOT assume its field names.
sig_query body.json | jq '.'   # inspect the live response shape once, then extract per-service counts
```

**ClickHouse lane.** Resolve the service column and timestamp column FIRST (never assume `serviceName` / `timestamp`):

```bash
# Discover columns before use (never-invent-a-column).
chq "SELECT table, name, type FROM system.columns
     WHERE database IN ('signoz_logs','signoz_traces','signoz_metrics')
       AND (name ILIKE '%service%' OR type LIKE 'DateTime%')
     ORDER BY database, table, name FORMAT TabSeparatedWithNames"
# Then, substituting the confirmed <svc_col> and window, recent rows per service on logs:
# chq "SELECT <svc_col> AS service, count() AS logs
#      FROM signoz_logs.logs_v2 WHERE <ts_col> >= now() - INTERVAL 1 HOUR
#      GROUP BY service ORDER BY logs DESC FORMAT TabSeparatedWithNames"
# ... and the same shape against the signoz_traces span table and signoz_metrics.samples_v*.
```

- **Healthy target:** every critical service from `topology.md` appears with recent rows in the signals it should emit.
- **Finding (SIG-010):** a critical service absent from the census (zero recent rows) with the collector otherwise healthy is a coverage gap — name the service in `affected`. All signals empty for a service under a confirmed non-empty backend makes it critical. Zero because the backend genuinely holds no rows anywhere routes to SIG-007, not a confident SIG-010 fail.
- **Forbidden:** SELECT / GET / read-only query only; see section 9.

### SIG-011 — ingestion freshness

Compute the newest-event lag per signal. On the ClickHouse lane (discover `<ts_col>` first, as above):

```bash
# chq "SELECT 'logs' AS signal, max(<ts_col>) AS latest,
#             dateDiff('second', max(<ts_col>), now()) AS lag_s FROM signoz_logs.logs_v2
#      FORMAT TabSeparatedWithNames"
# repeat for the signoz_traces span table and signoz_metrics.samples_v* with each table's own <ts_col>.
```

On the query API lane, read the newest event timestamp per signal from a `/api/v3/query_range` response (body confirm-live) and compute the lag against `now()`.

- **Healthy target:** `lag_s` on each active signal is below `FRESH_LAG_S` (example `900`s); `latest` is recent.
- **Finding (SIG-011):** a lag far above threshold on a signal that should be live means the ingestion pipeline (OTel collector or the ClickHouse writer) has stalled — the store is reachable but no longer current, which silently ages out every downstream signal and freezes every "last N minutes" alert. Record the signal, `latest`, and `lag_s` as evidence. A signal that is legitimately empty (not stale) is SIG-007/SIG-010 territory, not SIG-011.
- **Forbidden:** SELECT / GET / read-only query only; see section 9.

## 5. Retention (SIG-020)

SigNoz manages retention per signal. Read it from the settings API first, and confirm against the ClickHouse table TTL on the deep lane.

```bash
# Preferred: the SigNoz-managed per-signal TTL (response shape confirm-live).
sig_get /api/v1/settings/ttl | jq '.'

# Deep lane: the TTL clause on the MergeTree tables (engine_full carries it).
chq "SELECT database, name, engine_full FROM system.tables
     WHERE database LIKE 'signoz_%' AND engine LIKE '%MergeTree%'
     ORDER BY database, name FORMAT TabSeparatedWithNames"
# Per-table full DDL when you need the exact TTL expression:
# chq "SHOW CREATE TABLE signoz_logs.logs_v2 FORMAT TabSeparatedRaw"
```

- **Healthy target:** every signal (traces/metrics/logs) has a deliberate TTL that matches the customer's stated policy.
- **Finding (SIG-020):** a signal with **no TTL** is unbounded retention — a real cost and compliance gap; a TTL far **shorter** than the stated policy is a data-loss gap. Quote the signal and the presence/absence and value of the TTL. Remediation is the inline SigNoz Settings → General (Retention Period) per signal (no `setup-signoz` ships yet).
- **Forbidden:** GET / SELECT / SHOW only — never a settings write, never `ALTER TABLE ... MODIFY TTL` from the audit; see section 9.

## 6. ClickHouse health (SIG-030)

ClickHouse lane only. `system.parts`, `system.replicas`, `system.errors`, and `system.mutations` exist; `system.errors` columns (`name`, `code`, `value`, `last_error_time`) are confirmed. For `parts`, `replicas`, and `mutations`, confirm the exact column names against your version first:

```bash
chq "SELECT table, name FROM system.columns
     WHERE database = 'system' AND table IN ('parts','replicas','mutations','errors')
     ORDER BY table, name FORMAT TabSeparatedWithNames"
```

Part pressure per telemetry table (too many active parts means merges are falling behind):

```bash
chq "SELECT database, table, count() AS active_parts, sum(rows) AS rows
     FROM system.parts
     WHERE active AND database LIKE 'signoz_%'
     GROUP BY database, table ORDER BY active_parts DESC FORMAT TabSeparatedWithNames"
```

Error codes, spiking or recent (confirmed columns):

```bash
chq "SELECT name, code, value, last_error_time
     FROM system.errors
     WHERE last_error_time >= now() - INTERVAL 1 HOUR
     ORDER BY value DESC LIMIT 20 FORMAT TabSeparatedWithNames"
```

Stuck mutations and lagging replicas (confirm the filter columns from the discovery read above):

```bash
chq "SELECT database, table, mutation_id, is_done, latest_fail_reason
     FROM system.mutations WHERE is_done = 0 FORMAT TabSeparatedWithNames"
chq "SELECT database, table, is_readonly, absolute_delay, queue_size
     FROM system.replicas
     WHERE is_readonly OR absolute_delay > 60 OR queue_size > 100
     FORMAT TabSeparatedWithNames"
```

- **Healthy target:** active-part counts per table within your merge budget; no recently-spiking `system.errors` code tied to ingestion or storage; no mutation stuck with `is_done = 0` and a `latest_fail_reason`; on a clustered install, no read-only replica and delay/queue near zero.
- **Finding (SIG-030):** a table with runaway active parts (merge backlog), a spiking error `code` with a fresh `last_error_time`, a stuck mutation, or a lagging/read-only replica each names a specific ClickHouse health problem — quote the row(s). An empty `system.replicas` on a single-node build is not a finding. When reading 164 `READONLY`, discount the single row the section-1 `readonly=1` probe itself may add on a profile-readonly user.
- **Forbidden:** SELECT only — never `OPTIMIZE`, `SYSTEM ...`, or a mutation; see section 9.

## 6b. Capacity headroom and write-path failures (SIG-060, SIG-061)

ClickHouse lane only. Two failure modes SIG-030 (part counts/errors now) and SIG-011 (freshness) each only half-see: the disk trending toward full, and INSERTs being actively rejected. `system.disks` and the `system.parts` columns (`min_time`, `bytes_on_disk`, `active`, `database`, `table`) are standard; the discovery read still runs first, since column presence varies by version.

```bash
# Confirm columns before use (never-invent-a-column).
chq "SELECT name FROM system.columns WHERE database='system' AND table='parts'
     AND name IN ('min_time','bytes_on_disk','active','database','table') FORMAT TabSeparated"

# SIG-060: disk headroom, per-table footprint, observed growth -> days-to-read-only.
chq "SELECT name, free_space, total_space, round(100*(total_space-free_space)/total_space,1) AS used_pct
     FROM system.disks ORDER BY used_pct DESC FORMAT TabSeparatedWithNames"
chq "SELECT database, table, sum(bytes_on_disk) AS bytes, min(min_time) AS oldest, max(min_time) AS newest
     FROM system.parts WHERE active AND database LIKE 'signoz_%'
     GROUP BY database, table ORDER BY bytes DESC FORMAT TabSeparatedWithNames"
# days_to_full = free_space / daily_growth, where daily_growth = bytes / age_days (newest-oldest).
chq "SELECT name, value FROM system.merge_tree_settings
     WHERE name IN ('parts_to_throw_insert','parts_to_delay_insert','max_parts_in_total') FORMAT TabSeparatedWithNames"

# SIG-061: the exact codes that reject a write. system.errors shows codes that have OCCURRED (value>0).
# Write-path rejection codes: 243 NOT_ENOUGH_SPACE (disk full), 252 TOO_MANY_PARTS (merge backlog),
# 164 READONLY (profile-readonly user, OR a replica in Keeper-readonly state), 201 QUOTA_EXCEEDED.
# When reading 164, discount the single READONLY row the section-1 readonly=1 probe itself adds.
chq "SELECT name, code, value, last_error_time FROM system.errors
     WHERE last_error_time >= now() - INTERVAL 1 HOUR AND code IN (243,252,164,201,241,394)
     ORDER BY value DESC FORMAT TabSeparatedWithNames"
# Fresh rejected INSERTs from query_log (needs log_queries=1):
chq "SELECT event_time, exception_code, count() AS n FROM system.query_log
     WHERE type='ExceptionWhileProcessing' AND query_kind='Insert' AND event_time >= now() - INTERVAL 1 HOUR
     GROUP BY event_time, exception_code ORDER BY event_time DESC LIMIT 20 FORMAT TabSeparatedWithNames"
```

- **Healthy (SIG-060):** every disk's days-to-full is comfortably beyond your retention window. **Finding (SIG-060, high):** a disk will hit read-only in N days at the observed growth rate — state the disk, `used_pct`, the dominant `signoz_*` table by bytes, and the computed days-to-full. Blast radius: at 243 `NOT_ENOUGH_SPACE` **every** `signoz_*` INSERT is rejected at once, not one table. Fix inline: expand the disk / tiered storage / `keep_free_space`, or shorten retention (SIG-020) to reclaim.
- **Healthy (SIG-061):** no fresh Insert exceptions; no recent write-path error code. **Finding (SIG-061, high):** fresh Insert `ExceptionWhileProcessing` rows or a spiking write-path code — name the code and what it means (243 disk-full → SIG-060; 252 too-many-parts → merge pressure; 164 profile/replica readonly; 201 quota). This is the check that distinguishes "collector stopped sending" (SIG-011 stale, no insert exceptions) from "collector still sending, ClickHouse rejecting every write" (fresh exceptions).
- **Forbidden:** SELECT only — never `ALTER`, `OPTIMIZE`, `SYSTEM`, or a mutation; see section 9.

## 7. SigNoz alerting and dashboards (SIG-040, SIG-041)

SigNoz API through `sig_get`. Response shapes are **confirm-live**: enumerate them against your instance and confirm the field names before crediting a check.

### SIG-040 — alerting reaches a human (flagship)

```bash
sig_get /api/v1/rules    | jq .   # shape confirm-live: read the rule's enabled state, query, and channel linkage
sig_get /api/v1/channels | jq .   # shape confirm-live: read each channel's name and destination
```

Field names are confirm-live, so inspect the raw JSON once, confirm which field carries the rule's channel linkage (SigNoz commonly names channels on the rule by name — verify), then assemble the **per-service paging path** for each critical service: a rule exists → the rule is **enabled and evaluates** (has a query, a threshold, and a non-disabled evaluation/`for` window) → it names a channel that **matches an object in `/api/v1/channels`** → that channel's destination is **live** (a real Slack/webhook/PagerDuty host, not empty, not loopback, not a placeholder like `example.com`/`webhook.site`). Record only the channel **name and host class**, never the full URL. A defensive scan that does not assume a single field name:

```bash
# Does each rule reference SOME channel/receiver? Confirm the real key names against the raw JSON above.
sig_get /api/v1/rules \
  | jq -r '(if type=="array" then . else (.data // .rules // []) end)[]
           | tostring | test("channel|slack|webhook|pagerduty|receiver|preferredChannels";"i") as $wired
           | "\($wired)"' | sort | uniq -c
```

- **Healthy target:** every critical service has at least one enabled, evaluating rule **and** every such rule resolves to a live channel.
- **Finding (SIG-040):** a rule that references no channel, references a channel absent from `/api/v1/channels`, or points at an empty/loopback/placeholder destination is the core failure — the rule evaluates and pages nobody. A rule that is disabled or has no threshold/evaluation window evaluates never. Record the rule name and the channel's host class (e.g. "channel target is a loopback address"), never the full URL. Zero rules entirely routes to SIG-007, not a confident SIG-040 fail. Reading the config proves the path is **configured**, not `validated-live` — the test-fire that would prove delivery is a mutation this audit never performs. Fix inline: SigNoz Alerts → the rule → Notification Channels, and Settings → Alert Channels to create/repair a channel.
- **Forbidden:** GET only — never `POST`/`PUT`/`PATCH`/`DELETE` on `/api/v1/rules` or `/api/v1/channels` (no test alerts, no "quick fix"); see section 9.

### SIG-041 — dashboards

```bash
sig_get /api/v1/dashboards | jq .   # shape confirm-live
```

- **Healthy target:** at least one dashboard exists for the critical services, and its panel queries resolve against a live telemetry source.
- **Finding (SIG-041):** no dashboard for a critical service, or a panel querying a service/signal that Phase 4 found empty (a dead panel), is a correlation gap — responders have nothing to open during an incident. Name the service or panel in `affected`. Confirm field names against the raw JSON before asserting a panel is dead. Fix inline: SigNoz Dashboards → New Dashboard for the uncovered service.
- **Forbidden:** GET only — never `POST`/`PUT`/`PATCH`/`DELETE`; see section 9.

## 8. Security posture (SIG-050) and query API health (SIG-001)

**SIG-001 (query API health).** The successful authed reads elsewhere in this run are the evidence: `GET /api/v1/rules` → 200 with the PAT, and `POST /api/v3/query_range` resolving a minimal query. A 401 with `{"error":{"type":"unauthenticated"}}` on the authed path is a `blocked` SIG-001 (and blocks the categories that need the query API), never a confident fail.

**SIG-050 (security posture).** The SigNoz endpoint must require auth — the confirmed `401` on `/api/v1/rules` without a PAT is the good state; prove it (this probe sends **no** header, so the status code is the evidence and `-f` is dropped):

```bash
curl -s -o /dev/null -w 'unauth SigNoz rules probe: %{http_code}\n' --max-time 10 "${SIG_URL}/api/v1/rules"
# 401 = good (auth required); 200 = the authed resource is publicly readable — critical exposure.
```

On the ClickHouse lane, read the user inventory and prove the external `default` user is not open (this probe sends no credentials, so `-f` is dropped deliberately):

```bash
chq "SELECT name, auth_type, host_ip FROM system.users ORDER BY name FORMAT TabSeparatedWithNames"
chq "SHOW GRANTS FOR ${CH_USER} FORMAT TabSeparatedRaw"   # confirm the audit user is read-only
curl -s -o /dev/null -w 'unauth default-user query: %{http_code}\n' --max-time 10 "${CH_URL}/?query=SELECT%201"
```

TLS on the wire — confirm the audit reaches SigNoz and ClickHouse over TLS rather than plaintext:

```bash
printf '%s\n' "$SIG_URL" | grep -qE '^https://' && echo "TLS: SigNoz endpoint is https" || echo "TLS: SigNoz endpoint is plaintext http — confirm a TLS listener/ingress exists"
```

- **Healthy target:** the SigNoz authed probe returns `401` (not `200`); the unauthenticated ClickHouse `default`-user probe returns an auth-required status (e.g. `403`/`516`), not `200`; service users use `sha256_password`/`double_sha1_password`, not `plaintext_password`; the audit reaches both surfaces over TLS; a dedicated least-privilege read-only ClickHouse user exists for audits; and the audit PAT is VIEWER role (declared at connect — a PAT cannot self-introspect its role).
- **Finding (SIG-050):** a `200` from the unauthenticated SigNoz authed-resource probe (public readability) is critical exposure. A `200` from the ClickHouse `default`-user probe means the `default` user has no password — critical. A service user on `auth_type = plaintext_password` is a real posture finding. Plaintext HTTP across an untrusted network is a transport-security finding. No scoped read-only CH user, or an admin-scoped audit PAT, is a least-privilege finding. Record the user name and `auth_type`, never any `auth_params` value. Fix inline: require the CH `default`-user password / move plaintext users to sha256 / front the endpoints with TLS / issue a VIEWER PAT.
- **Forbidden:** SELECT / SHOW / GET only — never `CREATE USER`, `ALTER USER`, `GRANT`, `REVOKE`, or a PAT/channel write from the audit; see section 9.

## 9. Forbidden mutations (both surfaces)

This audit is strictly read-only. Every command above is a `GET` on the SigNoz `/api/v1/*` API, the read-only `POST /api/v3/query_range` query (a server-side aggregation body that creates/changes nothing), or a `SELECT`/`SHOW` over ClickHouse HTTP `:8123` (as the read-only user, with `readonly=1` pinned). The following are **never** issued from audit-signoz — they are the operator's inline fix (no `setup-signoz` ships yet), under a confirm-then-verify change protocol:

- **SigNoz API:** any `POST` (other than the read-only `/api/v3/query_range` query), `PUT`, `PATCH`, or `DELETE` on any `/api/*` resource — no creating or editing an alert rule, no creating/editing a channel, no test alert, no dashboard edit, no settings/TTL write, no "harmless" change. Firing a test alert to prove delivery end to end is a mutation and is forbidden.
- **ClickHouse (DDL/DML/admin):** `INSERT`, `ALTER`, `CREATE`, `DROP`, `TRUNCATE`, `RENAME`, `OPTIMIZE`, `DETACH`, `ATTACH`, `SYSTEM ...`, and any `CREATE USER` / `ALTER USER` / `GRANT` / `REVOKE`. The `readonly=1` HTTP setting is the server-side belt that rejects these even if a command leaks in; the read-only user's grants are the braces.

A write attempt is a bug in the skill, not a finding; if any block above ever needs a mutation to produce evidence, that is the wrong command — read the state instead, and route the change to the operator's inline fix.
