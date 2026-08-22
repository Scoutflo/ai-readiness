---
name: setup-clickstack
description: Guided hardening of a ClickStack (ClickHouse + HyperDX + OpenTelemetry) stack from audit-clickstack findings. Sets deliberate per-table retention TTL on the otel_* telemetry tables, creates a HyperDX alert wired to a live receiver, creates a scoped read-only ClickHouse user for audits, and hardens ClickHouse auth (plaintext_password to sha256_password, default-user password). States each change, waits for your confirmation, executes one object at a time, then re-reads and verifies live. Use when the user asks to fix a CS-NNN finding, set otel_* retention, wire a HyperDX alert to a receiver, create a read-only ClickHouse audit user, or move a ClickHouse user off plaintext_password. Do not use for read-only assessment (use audit-clickstack), for Grafana-fronted dashboards (use setup-grafana), or for the Alertmanager paging path (use audit-alert-routing).
disable-model-invocation: true
---

# setup-clickstack

Fixes findings from an `audit-clickstack` run against your ClickStack deployment: ClickHouse (columnar store, HTTP `:8123` / native `:9000`), HyperDX (UI + API on `:8080` under `/api/<resource>`), and the OpenTelemetry collector that ingests into the `otel_*` tables. Input is one or more finding IDs from the latest `./scoutflo-audits/clickstack/<date>/findings.json`. You usually arrive here from a finding's `remediation` pointer, for example `setup-clickstack#set-retention-ttl`.

| Finding | Fix section |
| --- | --- |
| CS-020 (retention unbounded or wrong) | [Set retention TTL](#set-retention-ttl) |
| CS-040 (alert reaches nobody) | [Create HyperDX alert](#create-hyperdx-alert) |
| CS-050 (no least-privilege audit user) | [Create read-only user](#create-read-only-user) |
| CS-050 (plaintext_password / no default password) | [Harden ClickHouse auth](#harden-clickhouse-auth) |

**Write scope is deliberately narrow: ClickHouse DDL for retention and users, plus HyperDX alert config.** Everything else is out of scope and recorded as a plan with a named owner. This skill never drops or alters the schema of an `otel_*` table, never touches the OpenTelemetry collector config or the MongoDB app-state store, never changes HyperDX dashboards or sources, and never enables TLS on the ClickHouse ports (a server-config change, not DDL). Missing instrumentation is an application change; it is recorded as pending, never patched here.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact statement before touching anything: the ClickHouse `ALTER`/`CREATE`/`GRANT`/`DROP` DDL or the HyperDX API call with real values filled in, its risk class, and its rollback command. Passwords are the exception: announce that a password comes from a named env var, never the value.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, **one object at a time**. If reality forces a different statement (a column differs on your ClickHouse version, an API field name differs on your HyperDX instance), stop and re-announce.
4. **Verify.** Re-read the modified object and assert the outcome with a machine-checkable command: a `jq -e` test on the re-fetched object, or the exact TTL clause read back from `system.tables.engine_full`. A write is unverified until a read proves it; "the field should now hold the value" as prose is not verification.
5. **Record.** Append the change, its verification evidence, and any pending items with a named owner to the change record.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-fetch the failed object's current state, record which earlier rows already applied (and where their backups live), and never continue past the failed row. Diagnose, then re-announce the remaining rows for a fresh approval; the earlier approval does not carry over to a re-announced plan.

## The change-risk classes

Every announcement names its class. The class decides the extra gate.

| Class | In this skill | Confirmed source for verify | Extra gate |
| --- | --- | --- | --- |
| Read-only | `SHOW CREATE TABLE`, `system.*` reads, `GET /api/health`, `GET /api/config`, every verification read | the audit's read surface | none |
| ClickHouse DDL — users/grants | `CREATE USER`, `GRANT SELECT`, `ALTER USER`, `DROP USER` | `system.users` (`name`, `auth_type`), `SHOW GRANTS` | announce + confirm |
| HyperDX alert config | `POST /api/alerts` (and its `DELETE` rollback) | `GET /api/alerts` with an API key | announce + confirm |
| ClickHouse DDL — retention (**disruptive**) | `ALTER TABLE default.otel_* MODIFY TTL` | `system.tables.engine_full`, `system.mutations.is_done` | announce + confirm + **second confirmation**: `MODIFY TTL` on a large table runs a mutation that rewrites parts (large blast radius, high I/O, hours on a big table). Announce the estimated part/byte count and get a distinct second yes before executing. |
| Out of write scope (plan only) | TLS on `:8123`/`:9000`, OTel collector config, dropping/altering `otel_*` schema, HyperDX dashboards/sources, MongoDB state | n/a | recorded as a plan with a named owner; never executed here |

## Doctor gate

Run before any real work. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`. This skill uses the **elevated** credential tier for ClickHouse (it runs DDL) and needs a HyperDX API key for the alert section. Keep the elevated ClickHouse user separate from the read-only audit user; `audit-clickstack` checks the audit user for least privilege and a shared admin user would fail that check for a reason.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ClickHouse | `clickhouse.http_url`, `clickhouse.database` | `clickhouse.user_env`, `clickhouse.password_env` | `ALTER`/`CREATE USER`/`GRANT`/`ALTER USER` on `default.*` and access management for the user/grant and retention sections | elevated |
| HyperDX | `hyperdx.url` | `hyperdx.api_key_env` | read + write on `/api/alerts` | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
# Pick up any credential added to the home-anchored store, even mid-session.
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
for bin in curl jq; do command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }; done

# Resolved from ~/.scoutflo/toolkit.yaml
CH_URL="https://your-clickhouse-host:8123"   # clickhouse.http_url
CH_DB="default"                              # clickhouse.database
HDX_URL="https://your-hyperdx-url:8080"      # hyperdx.url
# clickhouse.user_env / clickhouse.password_env / hyperdx.api_key_env name the
# variables; presence check only, never print the values.
[ -n "${CH_USER:-}" ] && [ -n "${CH_PASSWORD:-}" ] || { echo "CH_USER/CH_PASSWORD not set; run /scoutflo:connect"; exit 1; }
[ -n "${HDX_API_KEY:-}" ] || echo "note: HDX_API_KEY not set; the HyperDX alert section is unavailable until it is"

# One cheap ClickHouse read proves reachability + auth (HTTP :8123 requires a password).
curl -fsS --max-time 15 "${CH_URL}/" \
  -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT 1 FORMAT TabSeparated"

# HyperDX: /api/health is open (200); /api/alerts requires the key (401 without it).
echo "hyperdx health: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${HDX_URL}/api/health")"
[ -z "${HDX_API_KEY:-}" ] || echo "hyperdx alerts: $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts")"
```

Expected: `1` from ClickHouse, `hyperdx health: 200`, and (with a key) `hyperdx alerts: 200`. A ClickHouse `516`/auth error means the user or password is wrong; a HyperDX `401` on `/api/alerts` means the API key is missing or wrong. DDL permission cannot be introspected cheaply, so the first `CREATE`/`ALTER` of the run is the scope test: an access-denied error means the user lacks access management, so stop and reconnect with an elevated user. Never keep trying statements to find one that works.

## Live-safety gate

This gate must be able to fail. It fetches an independent view of what the connection actually reaches and compares it to config, rather than echoing config back at itself.

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"   # clickhouse.http_url
CH_DB="default"                              # clickhouse.database

# Independent live fetch: which server, which user, and does it hold otel_* tables?
LIVE="$(curl -fsS --max-time 15 "${CH_URL}/" \
  -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT hostName() AS host, version() AS version, currentUser() AS user FORMAT JSON")"
echo "target url:  ${CH_URL}"
printf '%s' "$LIVE" | jq -r '.data[0] | "live host=\(.host) version=\(.version) user=\(.user)"'

OTEL_TABLES="$(curl -fsS --max-time 15 "${CH_URL}/" \
  -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT count() AS n FROM system.tables WHERE database='${CH_DB}' AND name LIKE 'otel_%' FORMAT JSON")"
printf '%s' "$OTEL_TABLES" | jq -e '.data[0].n | tonumber > 0'
```

Expected: the live host/version/user line names the instance and the elevated user you intend to change, and the `otel_*` table count is greater than zero. If the count is zero, this may be the wrong ClickHouse instance or an empty/hidden scope (the CS-007 condition audit-clickstack flags); stop and confirm the target before any write. Never proceed on "probably the right server".

## Load findings and build the change plan

1. Read the latest audit run and list open findings:

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/[0-9]*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-clickstack first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
```

2. Select scope. Take the finding IDs you were asked to fix, or, for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section below.

3. Create the working directory and snapshot targets before any change:

```bash
set -eu
RUN_DATE="$(date -u +%F)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
CHANGE_LOG="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/changes.md"
mkdir -p "$BACKUP_DIR"
echo "backups: ${BACKUP_DIR}"
```

A "backup" here is the exact prior state captured to a file (a `SHOW CREATE TABLE` output, a `SHOW GRANTS` output, or the alert body), never a sentence claiming one exists. `./scoutflo-audits/` stays out of version control; backups can embed receiver URLs and other sensitive config.

4. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown. A retention `MODIFY TTL` row still takes its own second confirmation at its announcement, never inside the batch. A decline ends the run with zero changes. Execute approved rows one at a time, verifying each before the next. Order: additive and low-risk first (create the read-only user, create an alert), auth hardening next (coordinate the new secret with the service owner first), the disruptive retention rewrite last.

## Set retention TTL

For CS-020 (an `otel_*` table with missing/unbounded TTL, or a TTL that is too short and silently deleting data). Retention is read from the per-table TTL clause and set with `ALTER TABLE ... MODIFY TTL`. **Risk class: ClickHouse DDL — retention (disruptive).**

1. Capture the current TTL as the backup and quote it in the announcement:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; CH_DB="default"
TABLE="otel_logs"                 # the otel_* table from the finding
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/ttl-${TABLE}-$(date -u +%H%M%S).txt"

curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT engine_full FROM system.tables WHERE database='${CH_DB}' AND name='${TABLE}' FORMAT TabSeparatedRaw" \
  > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup (prior TTL): ${BACKUP_FILE}"
```

The prior TTL clause is inside `engine_full` (for example `TTL toDateTime(Timestamp) + toIntervalDay(30)`, the confirmed shape on `otel_logs`). If there is no `TTL` in `engine_full`, retention is unbounded — that is the CS-020 finding.

2. Announce the exact `MODIFY TTL`, its estimated blast radius, and get the second confirmation. Read the part/byte estimate first:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; CH_DB="default"; TABLE="otel_logs"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT count() AS parts, sum(rows) AS rows, formatReadableSize(sum(bytes_on_disk)) AS size
                 FROM system.parts WHERE database='${CH_DB}' AND table='${TABLE}' AND active FORMAT JSON"
```

`MODIFY TTL` schedules a mutation that re-evaluates every active part; on a large table this rewrites parts for hours and drives heavy I/O. State the part/row/size numbers in the announcement and get a distinct second yes. Some ClickHouse versions support running the `ALTER` with `materialize_ttl_after_modify=0` so only new data adopts the TTL and existing parts are not rewritten — confirm that setting exists on your version before offering it as the lower-blast-radius option.

3. Execute the announced statement (retention value is an example, tune to compliance/cost):

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; CH_DB="default"
TABLE="otel_logs"; RETENTION_DAYS="30"     # example, tune to your environment
curl -fsS --max-time 60 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "ALTER TABLE ${CH_DB}.${TABLE} MODIFY TTL toDateTime(Timestamp) + toIntervalDay(${RETENTION_DAYS})"
```

4. Verify the new TTL is present and watch the mutation finish:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; CH_DB="default"; TABLE="otel_logs"; RETENTION_DAYS="30"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT engine_full FROM system.tables WHERE database='${CH_DB}' AND name='${TABLE}' FORMAT JSON" \
  | jq -e --arg d "toIntervalDay(${RETENTION_DAYS})" '.data[0].engine_full | contains($d)'
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT is_done FROM system.mutations WHERE database='${CH_DB}' AND table='${TABLE}' ORDER BY create_time DESC LIMIT 1 FORMAT JSON" \
  | jq -r '.data[0].is_done'
```

Expected: the `jq -e` exits 0 (new interval present in `engine_full`) and the latest mutation reports `is_done` moving to `1`. **Rollback:** re-apply the `TTL ...` clause captured in step 1 from the backup file with another `MODIFY TTL`. Reducing retention deletes expired data as the mutation runs and does not come back; that is exactly why a reduction takes the second confirmation with the data loss stated.

## Create HyperDX alert

For CS-040 — the core failure is an alert wired to nothing. This section creates a HyperDX alert that routes to a live receiver (webhook, Slack, or PagerDuty). HyperDX serves its API on `:8080` under `/api/<resource>` (the `/api/v1/*` form 404s); `/api/alerts` requires an API key. **Risk class: HyperDX alert config.**

The endpoint set and auth model are confirmed; the request/response body shapes of `/api/alerts` are **confirm-against-your-instance**. Read one existing alert first to learn the shape your instance uses, including the receiver/webhook field names, then mirror it:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
HDX_URL="https://your-hyperdx-url:8080"    # hyperdx.url
[ -n "${HDX_API_KEY:-}" ] || { echo "HDX_API_KEY not set; run /scoutflo:connect"; exit 1; }
curl -fsS --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts" | jq '.[0] // "no alerts yet"'
```

Announce the alert you will create with the receiver named, using the field names you just observed. The receiver reference (a webhook/Slack/PagerDuty channel id or url) is what makes this alert reach a human; an alert with no receiver is the CS-040 failure and must not be created as a "fix". Then create and verify:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
HDX_URL="https://your-hyperdx-url:8080"
[ -n "${HDX_API_KEY:-}" ] || { echo "HDX_API_KEY not set; run /scoutflo:connect"; exit 1; }
# Body shape is confirm-against-your-instance; fill the fields your GET above showed,
# and include the receiver/channel reference so the alert routes to a live human.
NEW_ALERT="$(curl -fsS --max-time 15 -X POST "${HDX_URL}/api/alerts" \
  -H "Authorization: Bearer ${HDX_API_KEY}" -H "Content-Type: application/json" \
  -d @hyperdx-alert.json)"                 # your instance's confirmed alert body
ALERT_ID="$(printf '%s' "$NEW_ALERT" | jq -r '.id // ._id')"
echo "created alert: ${ALERT_ID}"

curl -fsS --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts" \
  | jq -e --arg id "$ALERT_ID" 'any(.[]; (.id // ._id) == $id)'
```

Expected: exit 0 (the alert is present in the live list). A HyperDX alert that lists a receiver is `configured`; only a delivered test notification proves the receiver is live. Trigger a controlled test through the receiver and record who confirmed receipt before marking CS-040 fixed. **Rollback** (this is a create; rollback deletes and verifies absence):

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
HDX_URL="https://your-hyperdx-url:8080"; ALERT_ID="the-id-just-created"
[ -n "${HDX_API_KEY:-}" ] || { echo "HDX_API_KEY not set; run /scoutflo:connect"; exit 1; }
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts/${ALERT_ID}"
curl -fsS --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL}/api/alerts" \
  | jq -e --arg id "$ALERT_ID" '[.[] | select((.id // ._id) == $id)] | length == 0'
```

Expected: exit 0. Confirm the `DELETE` path against your instance the same way you confirmed the create body.

## Create read-only user

For CS-050 — an audit needs its own least-privilege ClickHouse user rather than the elevated DDL user or a service user. This creates a `sha256_password` user with `SELECT` on the telemetry database and the `system` tables the audit reads. **Risk class: ClickHouse DDL — users/grants.** The password comes from a named env var and is never printed; ClickHouse masks credentials in `system.query_log` by default.

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; CH_DB="default"
AUDIT_USER="scoutflo_audit"
# CH_AUDIT_PASSWORD is set in ~/.scoutflo/env by /scoutflo:connect; never inline it.
[ -n "${CH_AUDIT_PASSWORD:-}" ] || { echo "CH_AUDIT_PASSWORD not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "CREATE USER IF NOT EXISTS ${AUDIT_USER} IDENTIFIED WITH sha256_password BY '${CH_AUDIT_PASSWORD}'"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "GRANT SELECT ON ${CH_DB}.* TO ${AUDIT_USER}"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "GRANT SELECT ON system.* TO ${AUDIT_USER}"
```

Verify the user exists with the right auth type, and that its grants are read-only:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; AUDIT_USER="scoutflo_audit"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT name, auth_type FROM system.users WHERE name='${AUDIT_USER}' FORMAT JSON" \
  | jq -e '.data[0].auth_type == "sha256_password"'
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SHOW GRANTS FOR ${AUDIT_USER} FORMAT TabSeparatedRaw"
```

Expected: the `jq -e` exits 0 and `SHOW GRANTS` lists only `SELECT` grants (no `INSERT`, `ALTER`, or access-management privilege). **Rollback:**

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; AUDIT_USER="scoutflo_audit"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "DROP USER IF EXISTS ${AUDIT_USER}"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT count() AS n FROM system.users WHERE name='${AUDIT_USER}' FORMAT JSON" \
  | jq -e '.data[0].n == 0'
```

Expected: exit 0 (the user is gone). Then record the new user + its env-var password name in `/scoutflo:connect`'s read-only tier so the next `audit-clickstack` uses it.

## Harden ClickHouse auth

For CS-050 — a service user on `auth_type = plaintext_password` (validation observed `worker`, `api`, and `default` all on plaintext), or a `default` user with no password. This moves a user to `sha256_password` with `ALTER USER ... IDENTIFIED WITH sha256_password`. **Risk class: ClickHouse DDL — users/grants**, but with a real service-availability blast radius: changing a service user's credential breaks every client that authenticates as that user until they are updated with the new secret. Coordinate the new secret with the owning service first, and treat it like the disruptive class — get an explicit second confirmation, ideally in a maintenance window.

1. Capture the current auth type as the backup and confirm the target:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/setup-$(date -u +%F)/backups"; mkdir -p "$BACKUP_DIR"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT name, auth_type FROM system.users ORDER BY name FORMAT JSON" \
  | tee "${BACKUP_DIR}/users-auth-$(date -u +%H%M%S).json" | jq -r '.data[] | "\(.name)\t\(.auth_type)"'
```

The prior `auth_type` (for example `plaintext_password`) is the backup. Note the old plaintext value is **not** readable from `system.users` (`auth_params` does not expose it), so rollback re-sets a password the service owner supplies, it cannot restore an unknown old one.

2. Announce, get the second confirmation, and execute (the new secret comes from a named env var, not inline):

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"
TARGET_USER="worker"                       # the plaintext_password user from step 1
[ -n "${CH_NEW_PASSWORD:-}" ] || { echo "CH_NEW_PASSWORD not set; coordinate it with the service owner first"; exit 1; }
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "ALTER USER ${TARGET_USER} IDENTIFIED WITH sha256_password BY '${CH_NEW_PASSWORD}'"
```

For the `default` user with no password, the same `ALTER USER default IDENTIFIED WITH sha256_password BY '...'` requires a password on `:8123` (validation observed `default` already requiring one — confirm it on your instance before assuming it is open).

3. Verify the auth type changed:

```bash
set -eu
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
CH_URL="https://your-clickhouse-host:8123"; TARGET_USER="worker"
curl -fsS --max-time 15 "${CH_URL}/" -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_PASSWORD}" \
  --data-binary "SELECT auth_type FROM system.users WHERE name='${TARGET_USER}' FORMAT JSON" \
  | jq -e '.data[0].auth_type == "sha256_password"'
```

Expected: exit 0 (`auth_type` is `sha256_password`, no longer `plaintext_password`). Then confirm with the service owner that the service authenticates successfully with the new secret; the change is not done until that client works again. **Rollback:** `ALTER USER ${TARGET_USER} IDENTIFIED WITH sha256_password BY '<owner-supplied>'` to a value the owner controls, then re-run the verify. TLS on the HTTP/native ports is the other half of CS-050 posture; it is a server-config change out of this skill's write scope, so record it as a plan with a named owner.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/clickstack/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact DDL or API call applied, passwords as env-var names>
- Verified: <the read-back command and the value it showed>
- Rollback: <the exact statement or backup file it reads from>
- Pending: <item> (owner: <team or person>)
```

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's write scope (TLS on the ClickHouse ports, OTel collector changes, HyperDX dashboards/sources, application instrumentation), each with a named owner.
3. A fresh `/scoutflo:audit-clickstack` run to re-score; its delta shows which findings moved to fixed. For CS-040, also confirm a human received the test notification before trusting the delta.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| `MODIFY TTL` run on a large table as a plain write, hours of part rewrites and I/O | It is the disruptive class: read the part/byte estimate, announce the blast radius, take a distinct second confirmation, and consider `materialize_ttl_after_modify=0` if your version supports it |
| Retention reduced and expired data deleted immediately | A reduction is destructive; state the data loss and confirm individually, never inside a batch |
| Service user moved to `sha256_password`, the service can no longer authenticate | Coordinate the new secret with the owning service first; verify the client works again before calling CS-050 fixed |
| Rollback of an auth change assumed to restore the old password | The old plaintext value is not readable from `system.users`; rollback re-sets an owner-supplied password, it cannot recover the unknown old one |
| HyperDX alert created against a guessed body shape | Read an existing alert with the API key first and mirror the confirmed field names; the request/response shapes are confirm-against-your-instance |
| Alert marked fixed because it exists | An alert with no receiver is the CS-040 failure; require a receiver reference and a human confirming a test notification arrived |
| `/api/v1/alerts` used and 404s | HyperDX serves `/api/<resource>`, not `/api/v1/*`; the `v1` form does not exist |
| Read-only audit user granted more than `SELECT` | Grant only `SELECT` on the telemetry DB and `system.*`; verify with `SHOW GRANTS` that no write or access-management privilege is present |
| Password printed in an announcement or written to a backup | Passwords come from named env vars only; ClickHouse masks credentials in `query_log`, and announcements name the variable, never the value |
| Change applied to the wrong ClickHouse instance | Run the live-safety gate: fetch `hostName()`/`currentUser()` live and confirm the `otel_*` table count is greater than zero before any write |
| Batch continues past a failed write | Mid-batch failure rule: stop immediately, record what already applied and its backups, re-announce the remainder for a fresh approval |
| TLS or OTel collector change smuggled through as a "monitoring tweak" | Those are out of write scope; record them as a plan with a named owner, never execute them here |
