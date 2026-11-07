# audit-clickstack: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-clickstack](../SKILL.md) workflow covers. ClickStack is ClickHouse (columnar store + query engine) + HyperDX (search, dashboards, alerts, session replay) + an OpenTelemetry collector, with MongoDB holding HyperDX app state in the OSS build. This audit reads two surfaces: the **ClickHouse** read surface over HTTP `:8123`, and the **HyperDX** API under `/api/<resource>`. Each section lists the catalog IDs it serves, the exact read command, the healthy target, the finding it emits, and the mutations forbidden on that surface. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- The tables, columns, system tables, and endpoint/auth model below were **confirmed on a live read** of a ClickStack all-in-one instance. Anything marked **confirm-live** (HyperDX JSON response shapes, some resource paths, the exact HyperDX auth header, and any ClickHouse system-table column not named here) needs verifying against your instance with a working credential (the Personal API Access Key, or the legacy session login below) before the skill asserts it. Never invent a table, column, endpoint, or field beyond what is confirmed.
- **ClickHouse read surface:** HTTP on `:8123` (native `:9000` is not used by this audit). Every ClickHouse block authenticates as a **least-privilege read-only user** (see [CS-050](#8-security-posture-cs-050)) — that user is the read-only guarantee. The HTTP `readonly=1` setting is pinned as *defense-in-depth* on top of it, but note: a user that is **already read-only by profile** (a `users.xml` profile with `<readonly>1</readonly>` or `2`, common on locked-down/managed ClickHouse where RBAC access-management is disabled and a scoped user can't be created via SQL) will reject `?readonly=1` with `Code: 164 — Cannot modify 'readonly' setting in readonly mode`. That error itself proves the user is read-only, so `chq` falls back to the query without the param. The fixed transport sends the SELECT/SHOW body, rejects redirects, caps response bytes and projects JSON before stdout; raw provider responses are never stored.
- **HyperDX API auth (confirmed live on a v2.x all-in-one + against the v2.29 source):** HyperDX exposes **two** REST surfaces. (1) The **external API v2** — `/api/v2/alerts`, `/api/v2/dashboards`, `/api/v2/sources` — authenticates with the per-user **Personal API Access Key** (Settings → API Keys → the "Personal API Access Key" card, the user `accessKey`) sent as **`Authorization: Bearer`**; this is the audit's **primary** path. (2) The **internal** routes `/api/alerts|dashboards|sources` are **browser-session only** — they ignore a Bearer token (`401`), and HyperDX's web app then redirects any `401` to `/login` (this is the "email/password prompt" users hit when they try a token against these paths); they are only the **legacy session-login fallback**. The team **ingestion key** is a *different* token (OTLP ingest only) and returns `401` on `/api/v2` — never use it for reads. `/api/health` and `/api/config` are open; `/api/v1/*` external API does not exist on self-hosted v2 (that path is HyperDX Cloud only). **Path nuance (confirmed live):** reach the external API either directly on the API-server port (`<url>/api/v2/...`) or through the app proxy, which strips one leading `/api` so the working path is the **doubled** `<url>/api/api/v2/...`; the helper probes both and keeps whichever returns JSON (`HDX_V2`). **Legacy session fallback:** when only `clickstack.hyperdx_email_env` + `clickstack.hyperdx_password_env` are set, `POST /api/login/password` with `{email, password}` answers `303` and sets a `connect.sid` cookie that reads the internal routes; the fixed recipe holds the cookie in memory only and never prints, logs or persists it. With no working credential, CS-040/CS-041 are `blocked` with the exact read-access unlock. Missing credentials never prove inapplicability.
- Presence-check tokens and passwords only; never echo, log, or write a secret value anywhere. Rendered configs and API responses can embed webhook URLs with secrets — record their shape and host class (loopback, private, public), never the full URL. The HyperDX login password and the `connect.sid` session cookie are secrets under the same rule: the password is read only from the variable the config names, the cookie exists only in process memory, and neither ever appears in terminal output, evidence, `raw/`, the report, or any persistent file.
- The fixed ClickHouse transport enforces bounded reads and exact result/JSON shape checks; HTTP status alone is never data proof.
- Time windows and thresholds are examples; tune to your ingest volume: `RECENT_MINUTES=60` for coverage, `FRESH_LAG_S=900` for freshness, part-count and error-spike thresholds per your cluster size.
- The all-in-one/single-node build has **no replicas and no sharding**, so `system.replicas` is empty there — that is expected, not a finding. Replica checks apply to clustered ClickHouse.

ClickHouse helper (source anew in each shell; the private target/credential-bound probe receipt lasts at most 30 minutes):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT 1"
```

HyperDX collection is a fixed recipe; do not pipe unprojected API responses to a terminal or file. Run the [bounded source collection](hyperdx-source-evidence.md) after the doctor gate. It re-resolves the selected target and credential names in every fresh shell, distinguishes external v2 from legacy session routes, and writes only a safe projection. The API key mode uses `/api/v2` (or the documented same-origin proxy prefix); a selected key's denial is blocked, never a silent login-credential fallback. Session mode is selected only when no API key is configured, with cookies in memory.

```bash
set -eu
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/collect-hyperdx.sh"
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| CS-007 | Telemetry coverage | Reachable ClickHouse with **zero rows across every `otel_*` table**, or a declared local detection requirement missing from a complete HyperDX list, is a visibility/ingestion gap — blocks the coverage/alerting-dependent categories, never a confident 0 | info |
| CS-010 | Telemetry coverage | Logs, traces, and metrics tables carry recent data for the critical services | high |
| CS-011 | Ingestion freshness | `max(Timestamp)` lag on `otel_logs` / `otel_traces` / `otel_metrics_*` within threshold (stale = broken pipeline) | high |
| CS-020 | Retention | Each `otel_*` table has a deliberate TTL (unbounded = cost/compliance gap; too-short = data-loss gap) | high |
| CS-030 | ClickHouse health | Part counts sane, replicas in sync, no spiking `system.errors` codes (read-probe code164 counts are diagnostic metadata, never evidence of a rejected INSERT), no stuck mutations | high |
| CS-040 | HyperDX alerting | Every required configured alert channel resolves to the expected receiver; downstream delivery needs separate proof | critical |
| CS-041 | Dashboards and sources | Dashboards exist and sources are connected for the critical services | medium |
| CS-050 | Security posture | External `default` user requires a password; service users off `plaintext_password`; TLS on the wire; a least-privilege read-only user exists for audits | high |
| CS-060 | ClickHouse health | Measured disk headroom; forecast only with comparable time-separated disk measurements and stated assumptions | high |
| CS-061 | ClickHouse health | Write-path INSERT failures — collector writes rejected by ClickHouse (`query_log` Insert exceptions; disk-full 243, merge backlog 252 `TOO_MANY_PARTS`, profile/replica 164 `READONLY`, quota 201 `QUOTA_EXCEEDED`) | high |

## 3. CS-007 — empty / hidden-scope guardrail (run first)

Run this **before scoring any coverage or alerting category**. It is the ClickStack twin of the empty-estate guardrail: a reachable backend with no data is a visibility or ingestion gap, not a confident `0/100`.

Row census across every confirmed telemetry table (`count()` on a MergeTree table is cheap):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT table, total FROM (
  SELECT 'otel_logs'                          AS table, count() AS total FROM otel_logs
  UNION ALL SELECT 'otel_traces',                       count() FROM otel_traces
  UNION ALL SELECT 'otel_metrics_gauge',                count() FROM otel_metrics_gauge
  UNION ALL SELECT 'otel_metrics_sum',                  count() FROM otel_metrics_sum
  UNION ALL SELECT 'otel_metrics_histogram',            count() FROM otel_metrics_histogram
  UNION ALL SELECT 'otel_metrics_exponential_histogram',count() FROM otel_metrics_exponential_histogram
  UNION ALL SELECT 'otel_metrics_summary',              count() FROM otel_metrics_summary
) ORDER BY total DESC FORMAT JSON"
```

HyperDX alert census comes from `raw/hyperdx-configuration.json`, only after checking its exact target, observation time and `resources.alerts.status`. The safe collection recipe names the current count and completeness; missing, denied, malformed or partially paged reads are not zero.

- **ClickHouse empty:** when every successful table read is zero, emit CS-007 and block CS-010/CS-011 pending ingest/scope evidence. Keep independent health and security checks assessable. A denied table is unknown, not zero.
- **HyperDX empty:** a complete zero-alert list is a configuration fact. Keep CS-041 assessable from its own sources, connections and dashboards. Apply declared alerting intent: required local detection absent → CS-007 with exact missing requirement; explicitly delegated alerting → CS-040 `not-in-scope` only with the C23 declaration or verified external coverage; unknown ownership → CS-040 `blocked` with an intent/evidence unlock. Do not infer the requirement from the organization label or from the existence of another tool.
- **Forbidden:** no mutation or test notification from this audit.

## 4. ClickHouse telemetry: coverage and freshness (CS-010, CS-011)

### CS-010 — telemetry coverage

Recent rows per critical service, on the tables whose `ServiceName` column is confirmed (`otel_logs`, `otel_traces`):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT ServiceName, count() AS logs
     FROM otel_logs WHERE Timestamp >= now() - INTERVAL ${RECENT_MINUTES} MINUTE
     GROUP BY ServiceName ORDER BY logs DESC FORMAT JSON"

chq "SELECT ServiceName, count() AS spans
     FROM otel_traces WHERE Timestamp >= now() - INTERVAL ${RECENT_MINUTES} MINUTE
     GROUP BY ServiceName ORDER BY spans DESC FORMAT JSON"
```

Metrics table row counts are inventory only. Discover exact timestamp and service columns from `system.columns`; field names alone do not establish the intended service semantics. Record the confirmed per-table mapping and evidence in the current target's local `raw/metrics-service-map.json`, with `target`, `observed_at` and `mappings` entries containing `table`, `timestamp_column`, `service_column`, and `semantic_evidence_ref` and literal `service_semantics_confirmed: true`. This is an attended input, not generated from guesses. Run the fixed [metrics service read](../scripts/read-metrics-services.sh) only after that mapping is verified. Missing maps block the affected metrics checks.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT table, name, type FROM system.columns
     WHERE database = currentDatabase() AND table LIKE 'otel_metrics_%'
     ORDER BY table, name FORMAT JSON"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/read-metrics-services.sh"
```

- **Healthy target:** every critical service from `topology.md` appears with recent rows in logs and traces; each required metric kind has recent rows for that exact service. Unknown expected kinds or an unverified service selector are blocked, not passed from a table count.
- **Finding (CS-010):** a critical service absent from the logs/traces census (zero recent rows) with the collector otherwise healthy is a coverage gap — name the service in `affected`. All signals empty for a service under a confirmed non-empty backend makes it critical. Zero because the backend genuinely holds no rows anywhere routes to CS-007, not a confident CS-010 fail.
- **Forbidden:** SELECT only; see section 8.

### CS-011 — ingestion freshness

`otel_logs` and `otel_traces` carry a confirmed `Timestamp DateTime64(9)`:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT 'otel_logs' AS tbl, ServiceName, max(Timestamp) AS latest,
            dateDiff('second', max(Timestamp), now()) AS lag_s FROM otel_logs
     GROUP BY ServiceName
     UNION ALL
     SELECT 'otel_traces', ServiceName, max(Timestamp),
            dateDiff('second', max(Timestamp), now()) FROM otel_traces
     GROUP BY ServiceName FORMAT JSON"
```

Metrics use the verified per-service mapping and fixed recipe from CS-010. Compare every critical service and required signal, not just rows returned: a missing service in a fully assessed current scope is a gap; incomplete visibility is blocked. The query deliberately preserves old service maxima, so another busy service cannot hide a stale one.

- **Healthy target:** each required service/signal has a non-future timestamp and lag below declared `FRESH_LAG_S` (example 900 seconds). Tune this to the declared emission cadence, including intentionally idle services.
- **Finding (CS-011):** report exact service, target, table and measured lag against that threshold. No recent data with a known healthy sender supports a pipeline gap; absent sender expectation is an input gap. A global maximum cannot pass every service.
- **Forbidden:** SELECT only; see section 9.

## 5. ClickHouse retention (CS-020)

Read table DDL only through `chq`, which retains raw DDL in memory and projects `ttl: {present,days,assessment}`. No engine definition or DDL string may be printed or saved, because engine arguments can contain credentials.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT name, create_table_query FROM system.tables
     WHERE database = currentDatabase() AND name LIKE 'otel_%'
     ORDER BY name FORMAT JSON"
```

- **Healthy target:** a recognized retention interval matches the declared policy or another current, evidenced lifecycle owner provides equivalent retention. `ttl.assessment=unknown` requires an attended interpretation of the expression; no inferred interval.
- **Finding (CS-020):** no automatic TTL where the declared policy requires it, or a verified interval shorter/longer than that policy. TTL absence alone does not prove that actual storage grows forever. Record table, parsed interval and policy delta; never quote raw DDL. Point at [set-retention-ttl](../../setup-clickstack/SKILL.md#set-retention-ttl).
- **Forbidden:** no ALTER or other change from this audit.

## 6. ClickHouse health (CS-030)

The SSOT confirms `system.parts`, `system.replicas`, `system.errors`, and `system.mutations` exist, and confirms `system.errors` columns (`name`, `code`, `value`, `last_error_time`). For `parts`, `replicas`, and `mutations`, confirm the exact column names against your version first — this discovery read invents nothing:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT table, name FROM system.columns
     WHERE database = 'system' AND table IN ('parts','replicas','mutations','errors')
     ORDER BY table, name FORMAT JSON"
```

Part pressure per telemetry table (`active` and `rows` are the confirmed part attributes; too many active parts means merges are falling behind):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT table, count() AS active_parts, sum(rows) AS rows
     FROM system.parts
     WHERE active AND database = currentDatabase() AND table LIKE 'otel_%'
     GROUP BY table ORDER BY active_parts DESC FORMAT JSON"
```

Error codes, spiking or recent (confirmed columns):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT name, code, value, last_error_time
     FROM system.errors
     WHERE last_error_time >= now() - INTERVAL ${RECENT_MINUTES} MINUTE
     ORDER BY value DESC LIMIT 20 FORMAT JSON"
```

Stuck mutations and lagging replicas — the filter columns below are the standard ClickHouse names; confirm them from the discovery read above, since the SSOT confirms the table, not each column:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
# Mutations still running / failed:
chq "SELECT database, table, mutation_id, is_done, latest_fail_reason
     FROM system.mutations WHERE is_done = 0 FORMAT JSON"

REPLICA_DELAY_S="${REPLICA_DELAY_S:-60}"; REPLICA_QUEUE_MAX="${REPLICA_QUEUE_MAX:-100}"
case "$REPLICA_DELAY_S:$REPLICA_QUEUE_MAX" in *[!0-9:]*|:*|*:) echo "Invalid numeric replica thresholds"; exit 1 ;; esac
# Replica health (clustered only; empty on the single-node/all-in-one build, which is expected):
chq "SELECT database, table, is_readonly, absolute_delay, queue_size
     FROM system.replicas
     WHERE is_readonly OR absolute_delay > ${REPLICA_DELAY_S} OR queue_size > ${REPLICA_QUEUE_MAX}
     FORMAT JSON"
```

- **Healthy target:** active-part counts per table are within your merge budget; `system.errors` count deltas show no unexpected increase tied to ingestion or storage; a single cumulative snapshot is context only; no mutation stuck with `is_done = 0` and projected `fail_reason_present=true`; on a clustered install, no read-only replica and delay/queue near zero.
- **Finding (CS-030):** a table with runaway active parts (merge backlog), a measured error-count increase across comparable samples for an exact `code`, a stuck mutation, or a lagging/read-only replica each names a specific ClickHouse health problem — quote the safe projected row(s) as evidence. An empty `system.replicas` on a single-node build is not a finding.
- **Forbidden:** SELECT only — never `OPTIMIZE`, `SYSTEM ...`, or a mutation from the audit; see section 8.

## 6b. Capacity headroom and write-path failures (CS-060, CS-061)

Read headroom and retained footprint separately. These snapshots cannot measure net growth or identify which client caused a historical error. `MIN_FREE_PERCENT` (example 15) is a declared, tuneable headroom target; `ERROR_WINDOW_MINUTES` (example 60) sets the observed error window.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
ERROR_WINDOW_MINUTES="${ERROR_WINDOW_MINUTES:-60}"
case "$ERROR_WINDOW_MINUTES" in ''|*[!0-9]*) echo 'Invalid numeric error window'; exit 1 ;; esac
chq "SELECT name, free_space, total_space, round(100*(total_space-free_space)/nullIf(total_space,0),1) AS used_pct
     FROM system.disks ORDER BY used_pct DESC FORMAT JSON"
chq "SELECT table, sum(bytes_on_disk) AS bytes
     FROM system.parts WHERE active AND database=currentDatabase() AND table LIKE 'otel_%'
     GROUP BY table ORDER BY bytes DESC FORMAT JSON"
chq "SELECT name, value FROM system.merge_tree_settings
     WHERE name IN ('parts_to_throw_insert','parts_to_delay_insert','max_parts_in_total') FORMAT JSON"
chq "SELECT name, code, value, last_error_time FROM system.errors
     WHERE last_error_time >= now() - INTERVAL ${ERROR_WINDOW_MINUTES} MINUTE AND code IN (243,252,164,201,241,394)
     ORDER BY value DESC FORMAT JSON"
chq "SELECT event_time, exception_code, count() AS n FROM system.query_log
     WHERE type IN ('ExceptionWhileProcessing','ExceptionBeforeStart') AND query_kind='Insert'
       AND event_time >= now() - INTERVAL ${ERROR_WINDOW_MINUTES} MINUTE
     GROUP BY event_time, exception_code ORDER BY event_time DESC LIMIT 20 FORMAT JSON"
```

- **CS-060:** report each measured disk's free percent versus the declared target and the observed table footprint. If comparable same-disk samples exist, calculate net used-byte change divided by elapsed time, explicitly accounting for retention, merges, other writers and disk resizing. A positive sustained slope may support a conditional forecast; otherwise forecast is unverified. **Never use retained bytes / part age as growth or predict a full date from it.** Failure affects the evidenced disk/write path; do not claim every table fails without a disk-to-table mapping.
- **CS-061:** actual recent Insert exceptions support rejected-write findings. Record code, count and window. A cumulative `system.errors` counter, even with a recent timestamp, cannot establish either a spike or a failed collector INSERT. Read-only probes can generate code164; the helper's target-bound probe receipt exposes their count, and those read errors never become write-path evidence. If query logging is disabled or inaccessible, keep this check blocked pending equivalent collector evidence.
- Remediate through [manage-storage-capacity](../../setup-clickstack/SKILL.md#manage-storage-capacity), [manage-merge-pressure](../../setup-clickstack/SKILL.md#manage-merge-pressure) or [fix-collector-pipeline](../../setup-clickstack/SKILL.md#fix-collector-pipeline) only for the evidenced cause. No mutation from this audit.

## 7. HyperDX alerting and dashboards (CS-040, CS-041)

Use [hyperdx-source-evidence.md](hyperdx-source-evidence.md) and the safe projection. It handles the current external-v2 `channel.webhookId` and `channels[]` forms separately from legacy session lists. Configured channels, receiver resolution, downstream routing, incident creation and human receipt are separate proof stages.

### CS-040 — configured alert destination integrity

For each observed alert and each channel, use the exact `receiver_id` join:

- `missing-id` is a defective configured webhook channel. `absent` means the ID is absent from a fully paged, reconciled webhook list. Record the alert ID/channel, impact and receiver repair. Neither means every alternative channel fails.
- `blocked` means the shape, collection or ID resolution is unknown. A partial/denied list cannot prove absence. An unrecognized channel is blocked rather than silently dropped.
- `resolved` means that exact configuration object exists. Loopback/placeholder destinations require review and a declared intentional-test exception if retained. Private hosts can be valid intermediaries; inspect their onward mapping under the appropriate source audit. No hostname proves an enabled, reachable downstream policy or a human receipt.
- `enabled` is an observed boolean only when the API state has known semantics; unknown state stays null. `DISABLED` is not active coverage. Current multi-channel alerts are checked once per channel; the legacy mirrored `channel` is not a second channel.

A CS-040 pass establishes complete applicable **configuration** assessment only. Report downstream delivery `unverified` until separately evidenced. Use [setup-clickstack#create-hyperdx-alert](../../setup-clickstack/SKILL.md#create-hyperdx-alert) for confirmed receiver repairs. The source packet feeds On-Call's bound verification only after exact protected-route evidence is supplied; an intermediary host or VictorOps-looking handle remains a candidate. Never GET an incoming-alert URL to test it.

Zero alerts follows CS-007's intent rule; it does not make CS-041 fail or disappear. An inaccessible HyperDX plane is `blocked`, not an exclusion justified by missing credentials.

### CS-041 — dashboards, sources and connections

Assess independently of the alert count. Follow dashboard tile `config.sourceId` to a returned source and its `connection` to the exact returned connection ID. The safe projection retains these references; sources/connections with no server total support positive joins only, not confident absence. `meta.skipped` on connections makes omitted objects explicit. Missing or duplicate IDs, malformed pages and inaccessible resources stay blocked.

A resolved connection ID proves configured linkage, **not** connectivity, table existence, signal freshness or dashboard usefulness. Before using any ClickHouse read as source-data proof, compare the exact HyperDX connection endpoint, database and table with the selected ClickHouse target in an attended, redacted view. Record the comparison result and source/connection IDs only. The safe packet intentionally omits endpoint/database/table values; its `data_binding` stays unverified until that exact comparison exists. A source attached to another regional endpoint must not inherit this target's data proof. Then verify the specific service/signal through the confirmed owning lane. A source/query shape outside the supported projection needs an attended, redacted read; never print raw SQL, filters, connection credentials or full URLs to discover it. A critical service without a useful dashboard/source is a finding only when its requirement and collection scope are established. Retest repaired source/destination IDs through a fresh collection and the relevant safe data read.

## 8. Security posture (CS-050)

Read the user inventory from `system.users` (confirmed columns include `name`, `auth_type`, `host_ip`, `host_names*`, `default_roles_*`, `grantees_*`, `valid_until`, `default_database`):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq "SELECT name, auth_type, host_ip FROM system.users ORDER BY name FORMAT JSON"

# Confirm the audit user is genuinely least-privilege (read-only grants only):
chq "SHOW GRANTS FOR ${CH_USER} FORMAT JSON"
```

Probe the unauthenticated path with the fixed bounded helper. It sends no credential and requires an exact ClickHouse response, not just HTTP 200:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"
RECENT_MINUTES="${RECENT_MINUTES:-60}" # example, tune to signal cadence
case "$RECENT_MINUTES" in ''|*[!0-9]*) echo 'Invalid recent window'; exit 2 ;; esac
chq_default_probe
```

Classify the configured transport in a fresh shell without making a query:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
case "$CH_URL" in
  https://*) echo 'Configured audit endpoint uses HTTPS; this does not prove other listeners are secured' ;;
  http://*) echo 'Configured audit endpoint uses HTTP; assess actual loopback/tunnel/trust boundary before finding insecure transport' ;;
  *) echo 'Transport unverified: no valid ClickHouse endpoint'; exit 1 ;;
esac
```

- **Healthy target:** `default_user_access=denied` means this unauthenticated ClickHouse query was denied; it does not prove a particular password policy. `unverified` (including HTML 200 or a generic proxy denial) is blocked. Service authentication, grants and transport are assessed from their own observations and declared trust boundary.
- **Finding (CS-050):** `accessible` proves this unauthenticated query returned the exact ClickHouse result `1`; assess exposure from the actual listener and network boundary. `plaintext_password` is a credential-storage posture finding. Raw grants and `auth_params` are never persisted: use projected privilege metadata and host-scope classification. An unknown privilege or policy expression blocks the least-privilege conclusion.
- **Forbidden:** no CREATE/ALTER USER, GRANT or REVOKE. Use [harden-clickhouse-auth](../../setup-clickstack/SKILL.md#harden-clickhouse-auth) or [create-read-only-user](../../setup-clickstack/SKILL.md#create-read-only-user) for confirmed gaps.

## 9. Forbidden mutations (both surfaces)

This audit is strictly read-only. Every command above is a `SELECT`/`SHOW` over ClickHouse HTTP `:8123` (as the read-only user, with `readonly=1` pinned) or a `GET` on the HyperDX `/api/<resource>` API. The following are **never** issued from audit-clickstack — they belong to `setup-clickstack`, under its confirm-then-verify change protocol:

- **ClickHouse (DDL/DML/admin):** `INSERT`, `ALTER`, `CREATE`, `DROP`, `TRUNCATE`, `RENAME`, `OPTIMIZE`, `DETACH`, `ATTACH`, `SYSTEM ...`, and any `CREATE USER` / `ALTER USER` / `GRANT` / `REVOKE`. The `readonly=1` HTTP setting is the server-side belt that rejects these even if a command leaks in; the read-only user's grants are the braces.
- **HyperDX API:** any `POST`, `PUT`, `PATCH`, or `DELETE` on any `/api/*` resource — no test alerts, no dashboard edits, no source changes, no "harmless" writes — with **exactly one deliberate exception**: the fixed recipe's `POST /api/login/password`, an *authentication handshake, not a resource write*. It exists only because HyperDX v2.x gates its read endpoints behind a session; it creates or modifies no alert, dashboard, source, or any other observability object, runs at most once per recipe invocation (never in a retry loop), its request body is never logged, and the resulting session cookie remains only in memory for that invocation. Any other non-GET against HyperDX remains a bug in the skill.

A write attempt is a bug in the skill, not a finding; if any block above ever needs a mutation to produce evidence, that is the wrong command — read the state instead, and route the change to `setup-clickstack`.
