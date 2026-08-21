# audit-clickstack: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-clickstack](../SKILL.md) workflow covers. ClickStack is ClickHouse (columnar store + query engine) + HyperDX (search, dashboards, alerts, session replay) + an OpenTelemetry collector, with MongoDB holding HyperDX app state in the OSS build. This audit reads two surfaces: the **ClickHouse** read surface over HTTP `:8123`, and the **HyperDX** API under `/api/<resource>`. Each section lists the catalog IDs it serves, the exact read command, the healthy target, the finding it emits, and the mutations forbidden on that surface. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- The tables, columns, system tables, and endpoint/auth model below were **confirmed on a live read** of a ClickStack all-in-one instance. Anything marked **confirm-live** (HyperDX JSON response shapes, some resource paths, the exact HyperDX auth header, and any ClickHouse system-table column not named here) needs verifying against your instance with a working credential (a REST API key, or the v2 session login below) before the skill asserts it. Never invent a table, column, endpoint, or field beyond what is confirmed.
- **ClickHouse read surface:** HTTP on `:8123` (native `:9000` is not used by this audit). Every ClickHouse block authenticates as a **least-privilege read-only user** (see [CS-050](#7-cs-050--security-posture)) — that user is the read-only guarantee. The HTTP `readonly=1` setting is pinned as *defense-in-depth* on top of it, but note: a user that is **already read-only by profile** (a `users.xml` profile with `<readonly>1</readonly>` or `2`, common on locked-down/managed ClickHouse where RBAC access-management is disabled and a scoped user can't be created via SQL) will reject `?readonly=1` with `Code: 164 — Cannot modify 'readonly' setting in readonly mode`. That error itself proves the user is read-only, so `chq` falls back to the query without the param. The SQL is sent as the raw POST body with `--data-binary`; nothing is stored.
- **HyperDX API:** served on `:8080` under `/api/<resource>` — the `/api/v1/*` form 404s, do not use it. `/api/health` and `/api/config` are open; `/api/alerts`, `/api/dashboards`, `/api/sources`, `/api/me` are auth-gated. The exact auth header scheme is **confirm-live**; `Authorization: Bearer <key>` is the assumed form below. **Important, confirmed live against HyperDX v2.35:** in HyperDX **v2.x** these REST endpoints authenticate by **session cookie** (user login), *not* a static API key — the team `apiKey` is an **ingestion-only** key (the OTLP `authorization` header), and every static-key header (`Bearer`, `x-api-key`, raw, `?apiKey=`) returns `401` on `/api/alerts`. An API key only scores HyperDX on a build that issues a REST API key. **Optional session login (confirmed live against a v2 build):** when `clickstack.hyperdx_email_env` + `clickstack.hyperdx_password_env` are configured, the helper below authenticates the way the UI does — `POST /api/login/password` with `{email, password}` answers with a redirect (`303` observed live) and sets a `connect.sid` session cookie, and a session-cookie `GET /api/alerts` returns `200` — making CS-040/CS-041 scorable on v2.x. The cookie lives only in a `mktemp` jar (`chmod 600`), is deleted on exit, and is never printed, logged, or persisted anywhere. This is a deliberately heavier posture than a read-only key — opt in per estate via `/scoutflo:connect`. With no login credentials configured, a v2.x instance's HyperDX categories (CS-040, CS-041) remain **not scorable** and must be marked `not-in-scope` with that reason — never treated as a wrong-key config error, and never a confident fail.
- Presence-check tokens and passwords only; never echo, log, or write a secret value anywhere. Rendered configs and API responses can embed webhook URLs with secrets — record their shape and host class (loopback, private, public), never the full URL. The HyperDX login password and the `connect.sid` session cookie are secrets under the same rule: the password is read only from the variable the config names, the cookie exists only inside the `0600` `mktemp` jar, and neither ever appears in terminal output, evidence, `raw/`, the report, or any persistent file.
- `curl -fsS --max-time 20` is the default. Where a status code is itself the evidence (the unauthenticated default-user probe in CS-050), `-f` is dropped deliberately and `-w '%{http_code}'` is used; that block says so.
- Time windows and thresholds are examples; tune to your ingest volume: `RECENT="INTERVAL 1 HOUR"` for coverage, `FRESH_LAG_S=900` for freshness, part-count and error-spike thresholds per your cluster size.
- The all-in-one/single-node build has **no replicas and no sharding**, so `system.replicas` is empty there — that is expected, not a finding. Replica checks apply to clustered ClickHouse.

ClickHouse helper (declare once per session; every ClickHouse block below calls `chq`):

```bash
set -eu
CH_URL="http://your-clickhouse-host:8123"   # clickstack.clickhouse_url
CH_USER="${CH_USER:-scoutflo_ro}"           # clickstack.clickhouse_user (the read-only audit user)
CH_KEY="${CH_KEY:-}"                        # clickstack.clickhouse_password_env; presence-checked by the doctor gate

# One read-only SELECT. readonly=1 is defense-in-depth over the user's own read-only grants;
# -f turns any write attempt, auth failure, or error into a hard non-zero exit. If the server
# rejects readonly=1 (Code 164 — the user is already read-only by profile), retry without the
# param: the read-only guarantee still holds from the scoped user, so this is safe, not a downgrade.
# Probe the readonly=1 form ONCE per session and remember which form works.
# Retrying readonly=1 on every call would land a Code-164 rejection per query in
# system.errors — which CS-030 then reads back as "spiking READONLY errors": the
# audit polluting the very signal it audits. One probe, then a stable form.
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

HyperDX helper (declare once per session; every HyperDX block below calls `hdx_get`):

```bash
set -eu
HDX_URL="https://your-hyperdx-url"          # clickstack.hyperdx_url (:8080 in the all-in-one build)
HDX_URL="${HDX_URL%/}"
HDX_API_KEY="${HDX_API_KEY:-}"              # clickstack.hyperdx_api_key_env; presence-checked by the doctor gate
HDX_EMAIL="${HDX_EMAIL:-}"                  # clickstack.hyperdx_email_env (optional: v2.x session login)
HDX_PASSWORD="${HDX_PASSWORD:-}"            # clickstack.hyperdx_password_env (optional; secret — never printed)
[ -n "$HDX_API_KEY" ] || [ -n "$HDX_EMAIL" ] || { echo "no HyperDX credential set (neither an API key nor login email+password); HyperDX checks unavailable — run /scoutflo:connect"; exit 1; }

# hdx_get <path> — the ONE way every HyperDX block below reads the API; GET only.
# HDX_MODE decides auth: "key" = Bearer header (a build that issues a REST key);
# "session" = the connect.sid cookie jar from the v2 login below.
hdx_get() {
  if [ "$HDX_MODE" = "session" ]; then
    curl -fsS --max-time 20 -b "$HDX_JAR" "${HDX_URL}$1"
  else
    curl -fsS --max-time 20 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}$1"
  fi
}

# Probe once before running the HyperDX checks — never loop trying header variants,
# and never turn an auth failure into a confident CS-040/CS-041 fail.
HDX_MODE="none"; HDX_IN_SCOPE=0; HDX_JAR=""
if [ -n "$HDX_API_KEY" ]; then
  HDX_PROBE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts") || HDX_PROBE="000"
  if [ "$HDX_PROBE" = "200" ]; then HDX_MODE="key"; HDX_IN_SCOPE=1; fi
fi

# v2.x session fallback (confirmed live): the key 401s because on v2 the apiKey is
# ingestion-only. With login credentials configured, authenticate the way the UI does:
# POST /api/login/password with {email, password} answers with a redirect (303 observed
# live) and sets a connect.sid session cookie. The cookie lands in a mktemp jar
# (chmod 600), is deleted on exit, and is NEVER printed, logged, echoed, or written to
# any output file, report, or evidence — the jar path is the only thing the shell holds.
if [ "$HDX_MODE" = "none" ] && [ -n "$HDX_EMAIL" ] && [ -n "$HDX_PASSWORD" ]; then
  HDX_JAR="$(mktemp)"; chmod 600 "$HDX_JAR"
  trap 'rm -f "$HDX_JAR"' EXIT INT TERM
  jq -n --arg e "$HDX_EMAIL" --arg p "$HDX_PASSWORD" '{email: $e, password: $p}' \
    | curl -s -o /dev/null --max-time 10 -c "$HDX_JAR" \
        -H 'Content-Type: application/json' --data-binary @- \
        "${HDX_URL}/api/login/password" || true
  # Success is proven by the session working, not by the login status code (a redirect):
  HDX_SESS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -b "$HDX_JAR" "${HDX_URL}/api/alerts") || HDX_SESS="000"
  if [ "$HDX_SESS" = "200" ]; then
    HDX_MODE="session"; HDX_IN_SCOPE=1
    echo "HyperDX v2 session login OK (GET /api/alerts -> 200 with the session cookie) — CS-040/CS-041 are scorable this run"
  else
    echo "HyperDX session login did not yield a working session (GET /api/alerts -> ${HDX_SESS}); check the variables hyperdx_email_env/hyperdx_password_env name. CS-040/CS-041 = not-in-scope (reason: HyperDX v2 session login failed). Not a fail — never retry-loop the login."
  fi
fi

if [ "$HDX_IN_SCOPE" = "0" ] && { [ -z "$HDX_EMAIL" ] || [ -z "$HDX_PASSWORD" ]; }; then
  echo "HyperDX /api/alerts -> ${HDX_PROBE:-no-key} with a static key: HyperDX v2.x REST is session-cookie auth (the apiKey is ingestion-only). CS-040/CS-041 = not-in-scope (reason: v2 REST API is session-authenticated; no login credentials configured). Optional: set clickstack.hyperdx_email_env + hyperdx_password_env via /scoutflo:connect to score them. Not a fail."
fi
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| CS-007 | Scope guardrail | Reachable ClickHouse with **zero rows across every `otel_*` table**, or HyperDX reachable with **zero alerts**, is a visibility/ingestion gap — blocks the coverage/alerting-dependent categories, never a confident 0 | info |
| CS-010 | Telemetry coverage | Logs, traces, and metrics tables carry recent data for the critical services | high |
| CS-011 | Ingestion freshness | `max(Timestamp)` lag on `otel_logs` / `otel_traces` / `otel_metrics_*` within threshold (stale = broken pipeline) | high |
| CS-020 | Retention | Each `otel_*` table has a deliberate TTL (unbounded = cost/compliance gap; too-short = data-loss gap) | high |
| CS-030 | ClickHouse health | Part counts sane, replicas in sync, no spiking `system.errors` codes (discount the single `READONLY` (164) entry the section-1 probe itself may add on a profile-readonly user), no stuck mutations | high |
| CS-040 | HyperDX alerting | Alerts exist **and** route to a live receiver (webhook/Slack/PagerDuty); an alert wired to nothing is the core failure | critical |
| CS-041 | HyperDX dashboards/sources | Dashboards exist and sources are connected for the critical services | medium |
| CS-050 | Security posture | External `default` user requires a password; service users off `plaintext_password`; TLS on the wire; a least-privilege read-only user exists for audits | high |

## 3. CS-007 — empty / hidden-scope guardrail (run first)

Run this **before scoring any coverage or alerting category**. It is the ClickStack twin of the empty-estate guardrail: a reachable backend with no data is a visibility or ingestion gap, not a confident `0/100`.

Row census across every confirmed telemetry table (`count()` on a MergeTree table is cheap):

```bash
chq "SELECT table, total FROM (
  SELECT 'otel_logs'                          AS table, count() AS total FROM otel_logs
  UNION ALL SELECT 'otel_traces',                       count() FROM otel_traces
  UNION ALL SELECT 'otel_metrics_gauge',                count() FROM otel_metrics_gauge
  UNION ALL SELECT 'otel_metrics_sum',                  count() FROM otel_metrics_sum
  UNION ALL SELECT 'otel_metrics_histogram',            count() FROM otel_metrics_histogram
  UNION ALL SELECT 'otel_metrics_exponential_histogram',count() FROM otel_metrics_exponential_histogram
  UNION ALL SELECT 'otel_metrics_summary',              count() FROM otel_metrics_summary
) ORDER BY total DESC FORMAT TabSeparatedWithNames"
```

HyperDX alert census:

```bash
hdx_get /api/alerts | jq 'if type=="array" then length else (.data // .alerts // [] | length) end'
# response shape confirm-live: the top-level key is confirm-against-your-instance; the census is "any alerts at all?"
# (hdx_get is the section-1 helper: Bearer key, or the v2 session cookie when that path engaged)
```

- **Healthy target:** at least one `otel_*` table carries rows, and at least one HyperDX alert exists.
- **Finding (CS-007):** if ClickHouse is reachable but **every** `otel_*` table returns `0`, emit CS-007 and mark the coverage-dependent categories (**CS-010, CS-011**) `blocked`. If HyperDX is reachable but returns **zero alerts**, emit CS-007 and mark the alerting-dependent categories (**CS-040, CS-041**) `blocked`. In both cases keep **CS-030 (DB health)** and **CS-050 (security)** scorable — they do not depend on telemetry rows — then **renormalize** the overall score over the categories that remain scorable. Never report a confident `0/100` from an empty read; the likely cause is that ingestion or the collector is down, or the read-only user cannot see the database, not that observability is confidently absent.
- **Forbidden on both surfaces here:** SELECT / GET only; see section 8.

## 4. ClickHouse telemetry: coverage and freshness (CS-010, CS-011)

### CS-010 — telemetry coverage

Recent rows per critical service, on the tables whose `ServiceName` column is confirmed (`otel_logs`, `otel_traces`):

```bash
chq "SELECT ServiceName, count() AS logs
     FROM otel_logs WHERE Timestamp >= now() - INTERVAL 1 HOUR
     GROUP BY ServiceName ORDER BY logs DESC FORMAT TabSeparatedWithNames"

chq "SELECT ServiceName, count() AS spans
     FROM otel_traces WHERE Timestamp >= now() - INTERVAL 1 HOUR
     GROUP BY ServiceName ORDER BY spans DESC FORMAT TabSeparatedWithNames"
```

Metrics presence — the `otel_metrics_*` column names are not confirmed, so coverage there is existence per table, not per service:

```bash
chq "SELECT 'gauge' AS kind, count() AS rows FROM otel_metrics_gauge
     UNION ALL SELECT 'sum',                 count() FROM otel_metrics_sum
     UNION ALL SELECT 'histogram',           count() FROM otel_metrics_histogram
     UNION ALL SELECT 'exp_histogram',       count() FROM otel_metrics_exponential_histogram
     UNION ALL SELECT 'summary',             count() FROM otel_metrics_summary
     FORMAT TabSeparatedWithNames"
```

- **Healthy target:** every critical service from `topology.md` appears with recent rows in logs and traces; the metrics tables are non-empty for the metric kinds the services emit.
- **Finding (CS-010):** a critical service absent from the logs/traces census (zero recent rows) with the collector otherwise healthy is a coverage gap — name the service in `affected`. All signals empty for a service under a confirmed non-empty backend makes it critical. Zero because the backend genuinely holds no rows anywhere routes to CS-007, not a confident CS-010 fail.
- **Forbidden:** SELECT only; see section 8.

### CS-011 — ingestion freshness

`otel_logs` and `otel_traces` carry a confirmed `Timestamp DateTime64(9)`:

```bash
chq "SELECT 'otel_logs'  AS tbl, max(Timestamp) AS latest,
            dateDiff('second', max(Timestamp), now()) AS lag_s FROM otel_logs
     UNION ALL
     SELECT 'otel_traces',        max(Timestamp),
            dateDiff('second', max(Timestamp), now())          FROM otel_traces
     FORMAT TabSeparatedWithNames"
```

For the `otel_metrics_*` tables, the timestamp column name is **confirm-live** — discover it from `system.columns` (a standard system table) instead of assuming one:

```bash
# Discover the DateTime-typed column(s) on the metrics tables, then read max() of the one you confirm:
chq "SELECT table, name, type FROM system.columns
     WHERE database = currentDatabase() AND table LIKE 'otel_metrics_%'
       AND type LIKE 'DateTime%'
     ORDER BY table, name FORMAT TabSeparatedWithNames"
# Then, substituting the confirmed column (shown here as <TS_COL>):
# chq "SELECT max(<TS_COL>) AS latest, dateDiff('second', max(<TS_COL>), now()) AS lag_s FROM otel_metrics_gauge FORMAT TabSeparatedWithNames"
```

- **Healthy target:** `lag_s` on each active table is below `FRESH_LAG_S` (example `900`s); `latest` is recent.
- **Finding (CS-011):** a lag far above threshold on a table that should be live means the ingestion pipeline (OTel collector or the writer into ClickHouse) has stalled — the store is reachable but no longer current, which silently ages out every downstream signal. Record the table, `latest`, and `lag_s` as evidence. A table that is legitimately empty (not stale) is CS-007/CS-010 territory, not CS-011.
- **Forbidden:** SELECT only; see section 8.

## 5. ClickHouse retention (CS-020)

Retention on ClickStack telemetry is the per-table **TTL** clause, read from `system.tables.engine_full` (confirmed to carry the TTL, e.g. `TTL toDateTime(Timestamp) + toIntervalDay(30)` with `ttl_only_drop_parts = 1`) or from `SHOW CREATE TABLE`:

```bash
chq "SELECT name, engine_full FROM system.tables
     WHERE database = currentDatabase() AND name LIKE 'otel_%'
     ORDER BY name FORMAT TabSeparatedWithNames"

# Per-table full DDL when you need the exact TTL expression:
chq "SHOW CREATE TABLE otel_logs FORMAT TabSeparatedRaw"
```

- **Healthy target:** every `otel_*` telemetry table's `engine_full` contains a deliberate `TTL ...` clause with a retention period that matches the customer's stated policy.
- **Finding (CS-020):** a telemetry table with **no TTL** is unbounded retention — a real cost and compliance gap; a TTL far **shorter** than the stated policy is a data-loss gap. Quote the table name and the presence/absence and value of the TTL clause. Remediation points at **[setup-clickstack#set-retention-ttl](../../setup-clickstack/SKILL.md#set-retention-ttl)** (`ALTER TABLE ... MODIFY TTL`).
- **Forbidden:** SELECT / SHOW only — never `ALTER TABLE ... MODIFY TTL` from the audit; see section 8.

## 6. ClickHouse health (CS-030)

The SSOT confirms `system.parts`, `system.replicas`, `system.errors`, and `system.mutations` exist, and confirms `system.errors` columns (`name`, `code`, `value`, `last_error_time`). For `parts`, `replicas`, and `mutations`, confirm the exact column names against your version first — this discovery read invents nothing:

```bash
chq "SELECT table, name FROM system.columns
     WHERE database = 'system' AND table IN ('parts','replicas','mutations','errors')
     ORDER BY table, name FORMAT TabSeparatedWithNames"
```

Part pressure per telemetry table (`active` and `rows` are the confirmed part attributes; too many active parts means merges are falling behind):

```bash
chq "SELECT table, count() AS active_parts, sum(rows) AS rows
     FROM system.parts
     WHERE active AND database = currentDatabase() AND table LIKE 'otel_%'
     GROUP BY table ORDER BY active_parts DESC FORMAT TabSeparatedWithNames"
```

Error codes, spiking or recent (confirmed columns):

```bash
chq "SELECT name, code, value, last_error_time
     FROM system.errors
     WHERE last_error_time >= now() - INTERVAL 1 HOUR
     ORDER BY value DESC LIMIT 20 FORMAT TabSeparatedWithNames"
```

Stuck mutations and lagging replicas — the filter columns below are the standard ClickHouse names; confirm them from the discovery read above, since the SSOT confirms the table, not each column:

```bash
# Mutations still running / failed:
chq "SELECT database, table, mutation_id, is_done, latest_fail_reason
     FROM system.mutations WHERE is_done = 0 FORMAT TabSeparatedWithNames"

# Replica health (clustered only; empty on the single-node/all-in-one build, which is expected):
chq "SELECT database, table, is_readonly, absolute_delay, queue_size
     FROM system.replicas
     WHERE is_readonly OR absolute_delay > 60 OR queue_size > 100
     FORMAT TabSeparatedWithNames"
```

- **Healthy target:** active-part counts per table are within your merge budget; `system.errors` shows no recently-spiking code tied to ingestion or storage; no mutation stuck with `is_done = 0` and a `latest_fail_reason`; on a clustered install, no read-only replica and delay/queue near zero.
- **Finding (CS-030):** a table with runaway active parts (merge backlog), a spiking error `code` with a fresh `last_error_time`, a stuck mutation, or a lagging/read-only replica each names a specific ClickHouse health problem — quote the row(s) as evidence. An empty `system.replicas` on a single-node build is not a finding.
- **Forbidden:** SELECT only — never `OPTIMIZE`, `SYSTEM ...`, or a mutation from the audit; see section 8.

## 7. HyperDX alerting and dashboards (CS-040, CS-041)

HyperDX endpoints are auth-gated: run them only when the section-1 helper resolved an auth mode (`HDX_IN_SCOPE=1` — a working REST key, or the v2 session cookie), and always through `hdx_get`. Response shapes and some resource paths are **confirm-live**: enumerate them against your instance and confirm the field names before crediting a check.

### CS-040 — alerting reaches a human

```bash
hdx_get /api/alerts | jq .
```

Field names are confirm-live, so inspect the raw JSON once, confirm which field carries the destination, then follow each alert to its receiver. **Receiver resolution (confirmed live against v2.35):** an alert's channel carries `{type: "webhook", webhookId: "<id>"}` — the id alone says nothing about the destination. Resolve it with `GET /api/webhooks` (same auth as the alerts call): match the `webhookId` to the webhook object's id and read its `url`. Record only the **host class** of that url (loopback / private / public / placeholder — e.g. a `webhook.site` or `example.com` host is a placeholder, a real finding), never the full URL. A defensive scan that does not assume a single field name:

```bash
# Does each alert reference SOME live channel/receiver? Confirm the real key names against the raw JSON above.
hdx_get /api/alerts \
  | jq -r '(if type=="array" then . else (.data // .alerts // []) end)[]
           | tostring | test("webhook|slack|pagerduty|channel|destination|receiver";"i") as $wired
           | "\($wired)"' | sort | uniq -c
```

- **Healthy target:** at least one alert exists **and** every alert resolves to a live receiver — a webhook, Slack, or PagerDuty destination that is real (not empty, not a loopback/placeholder host).
- **Finding (CS-040):** an alert that references no receiver, or a receiver whose target is empty / a loopback / a placeholder, is the core failure — the alert evaluates and pages nobody. Record the alert name and the receiver's host class (e.g. "receiver target is a loopback address"), never the full webhook URL. Zero alerts entirely routes to CS-007, not a confident CS-040 fail. **If the section-1 helper ended with `HDX_IN_SCOPE=0` (the key 401s on HyperDX v2.x and no login credentials are configured, or the v2 session login failed), mark CS-040 `not-in-scope` with the matching reason — "HyperDX v2.x REST API is session-authenticated; the apiKey is ingestion-only" or "HyperDX v2 session login failed" — and renormalize the score over the remaining categories; never a fail, never a wrong-key error. With `HDX_MODE=session` the category scores normally through `hdx_get`.** Remediation points at **[setup-clickstack#create-hyperdx-alert](../../setup-clickstack/SKILL.md#create-hyperdx-alert)**.
- **Forbidden:** GET only — never `POST`/`PUT`/`PATCH`/`DELETE` on `/api/alerts` (no test alerts, no "quick fix"); see section 8.

### CS-041 — dashboards and sources

The `/api/dashboards` and `/api/sources` paths and their response shapes are **confirm-live** — confirm both against your instance:

```bash
hdx_get /api/dashboards | jq .   # path + shape confirm-live
hdx_get /api/sources    | jq .   # path + shape confirm-live
```

- **Healthy target:** at least one dashboard exists for the critical services, and the sources they read from are connected (each source points at a reachable ClickHouse table/database).
- **Finding (CS-041):** no dashboard for a critical service, or a source that is disconnected / points at a table with no data, is a correlation gap — responders have nothing to open during an incident. Name the service or source in `affected`. Confirm field names against the raw JSON before asserting a source is disconnected.
- **Forbidden:** GET only — never `POST`/`PUT`/`PATCH`/`DELETE`; see section 8.

## 8. Security posture (CS-050)

Read the user inventory from `system.users` (confirmed columns include `name`, `auth_type`, `host_ip`, `host_names*`, `default_roles_*`, `grantees_*`, `valid_until`, `default_database`):

```bash
chq "SELECT name, auth_type, host_ip FROM system.users ORDER BY name FORMAT TabSeparatedWithNames"

# Confirm the audit user is genuinely least-privilege (read-only grants only):
chq "SHOW GRANTS FOR ${CH_USER} FORMAT TabSeparatedRaw"
```

Prove the external `default` user is not open — this probe sends **no** credentials, so the status code is the evidence and `-f` is dropped deliberately:

```bash
curl -s -o /dev/null -w 'unauth default-user query: %{http_code}\n' --max-time 10 \
  "${CH_URL}/?query=SELECT%201"
```

TLS on the wire — confirm the audit is reaching ClickHouse over a TLS listener rather than plaintext across an untrusted network (the specific secure port is instance-specific; do not assume one):

```bash
# If CH_URL is http:// on a non-loopback host, that is the posture concern to record.
printf '%s\n' "$CH_URL" | grep -qE '^https://' && echo "TLS: audit endpoint is https" || echo "TLS: audit endpoint is plaintext http — confirm a TLS listener exists"
```

- **Healthy target:** the unauthenticated `default`-user probe returns an auth-required status (e.g. `403`/`516`), not `200`; service users use `sha256_password` / `double_sha1_password`, not `plaintext_password`; the audit reaches ClickHouse over TLS; and a dedicated least-privilege read-only user exists for audits (its `SHOW GRANTS` shows only `SELECT`/`SHOW`-class grants).
- **Finding (CS-050):** a `200` from the unauthenticated probe means the external `default` user has no password — critical exposure. A service user on `auth_type = plaintext_password` is a real posture finding (credentials stored recoverable). Plaintext HTTP to ClickHouse across an untrusted network is a transport-security finding. No scoped read-only user (audits running as an over-privileged account) is a least-privilege finding. Record the user name and `auth_type`, never any `auth_params` value. Remediation points at **[setup-clickstack#harden-clickhouse-auth](../../setup-clickstack/SKILL.md#harden-clickhouse-auth)** (move a `plaintext_password` user to sha256; require the `default`-user password) and **[setup-clickstack#create-read-only-user](../../setup-clickstack/SKILL.md#create-read-only-user)** (a scoped read-only ClickHouse user for audits).
- **Forbidden:** SELECT / SHOW only — never `CREATE USER`, `ALTER USER`, `GRANT`, or `REVOKE` from the audit; those are setup-clickstack's job; see section 9.

## 9. Forbidden mutations (both surfaces)

This audit is strictly read-only. Every command above is a `SELECT`/`SHOW` over ClickHouse HTTP `:8123` (as the read-only user, with `readonly=1` pinned) or a `GET` on the HyperDX `/api/<resource>` API. The following are **never** issued from audit-clickstack — they belong to `setup-clickstack`, under its confirm-then-verify change protocol:

- **ClickHouse (DDL/DML/admin):** `INSERT`, `ALTER`, `CREATE`, `DROP`, `TRUNCATE`, `RENAME`, `OPTIMIZE`, `DETACH`, `ATTACH`, `SYSTEM ...`, and any `CREATE USER` / `ALTER USER` / `GRANT` / `REVOKE`. The `readonly=1` HTTP setting is the server-side belt that rejects these even if a command leaks in; the read-only user's grants are the braces.
- **HyperDX API:** any `POST`, `PUT`, `PATCH`, or `DELETE` on any `/api/*` resource — no test alerts, no dashboard edits, no source changes, no "harmless" writes — with **exactly one deliberate exception**: the section-1 helper's `POST /api/login/password`, an *authentication handshake, not a resource write*. It exists only because HyperDX v2.x gates its read endpoints behind a session; it creates or modifies no alert, dashboard, source, or any other observability object, runs at most once per audit session (never in a retry loop), its request body is never logged, and the resulting session cookie lives only in the `0600` `mktemp` jar deleted on exit. Any other non-GET against HyperDX remains a bug in the skill.

A write attempt is a bug in the skill, not a finding; if any block above ever needs a mutation to produce evidence, that is the wrong command — read the state instead, and route the change to `setup-clickstack`.
