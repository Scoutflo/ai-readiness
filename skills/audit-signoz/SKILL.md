---
name: audit-signoz
description: Read-only scored audit of a SigNoz observability deployment (OpenTelemetry-native metrics/traces/logs on ClickHouse): telemetry coverage for critical services, ingestion freshness, per-signal retention TTL, ClickHouse backend health, alert rules that evaluate and route to a live channel, dashboards, and security posture; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring SigNoz, SigNoz alert rules or channels, the signoz_traces/signoz_logs/signoz_metrics ClickHouse databases, OTel telemetry ingestion freshness, SigNoz retention/TTL, or whether a SigNoz alert reaches a human. Do not use for HyperDX-fronted ClickStack (use audit-clickstack), for Grafana-fronted LGTM/VictoriaMetrics (use audit-lgtm), to prove an Alertmanager page reaches a human (use audit-alertmanager), or to change SigNoz.
---

# audit-signoz

Scored, read-only audit of a **SigNoz** deployment — the OpenTelemetry-native observability platform (metrics, traces, and logs) built on **ClickHouse**. Its components are the query-service/frontend (the `signoz` pod, HTTP on `:8080`), ClickHouse (the columnar telemetry store), Zookeeper, an OTel collector that feeds ingestion, and a bundled Alertmanager. This audit answers one question: when something breaks tonight, is the telemetry for your critical services actually landing in ClickHouse, is it fresh and retained deliberately, is the database healthy, and does a SigNoz alert rule evaluate and reach a human on a channel that will deliver?

Every command in this audit is read-only: SigNoz REST `GET` calls carrying the `SIGNOZ-API-KEY` header (a Service Account token with a read-granting role), the SigNoz query API `POST /api/v3/query_range` (a query body — server-side aggregation, nothing is created or changed), and, on the optional deep-backend lane, ClickHouse `SELECT`/`SHOW` statements over the HTTP interface (`:8123`) issued as a least-privilege read-only user with `readonly=1` pinned. It creates or modifies no resource (see the forbidden-mutations section of the check catalog). Nothing is inserted, altered, created, dropped, silenced, or notified. A mutating call (`POST`/`PUT`/`PATCH`/`DELETE` on a SigNoz resource, a test alert, or an `INSERT`/`ALTER`/`CREATE`/`DROP` in ClickHouse) is not part of this audit — **no `setup-signoz` ships yet**, so every finding names the concrete inline SigNoz UI/API fix location instead of a setup anchor. Firing a test alert to prove delivery end to end is also a mutation and is never done here.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

**Scope — multiple SigNoz targets, one run:** `signoz` may be a single block (one `url` + `api_key_env`, optionally the ClickHouse deep-lane keys) or a **list of labeled targets**, each with its own connection params. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> signoz labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `signoz/<label>/<date>/` for a labeled list, or the unchanged `signoz/<url-host>/<date>/` for a single block (the single-block path — nested by the slugged host of `signoz.url` — is byte-identical to today). Every command resolves that target's own `url`, its `api_key_env` token-variable name, and (on the deep lane) `clickhouse_url`/`clickhouse_user`/`clickhouse_password_env` through the enumerator; no ambient default is read.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/signoz/<label-or-url-host>/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `SIG-NNN`
- `./scoutflo-audits/signoz/<label-or-url-host>/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/signoz/<label-or-url-host>/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per SigNoz `alert_rule`, `contact_point` (channel), and `dashboard`, per telemetry `table`, and per ClickHouse `user` — each built from the raw pull, never invented, redacted at capture.
- One appended line in `./scoutflo-audits/signoz/<label-or-url-host>/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

Provenance note: the SigNoz endpoint/auth model and ClickHouse read surface cited below were **confirmed on a live read** against SigNoz **v0.138**. Unauthenticated (both HTTP 200): `GET /api/v1/version` → `{"version":"v0.138.0","ee":"Y","setupCompleted":...}`, `GET /api/v1/health` → `{"status":"ok"}`. Authenticated with a **`signoz-viewer`** service-account token (`SIGNOZ-API-KEY`): `GET /api/v1/rules`, `GET /api/v1/channels`, and `GET /api/v1/alerts` each return **HTTP 200 JSON**; dashboards are served at **`GET /api/v2/dashboards`** → `{"status":"success","data":{"dashboards":[...]}}` — the legacy `/api/v1/dashboards` is **deprecated on v0.138 and returns HTTP `501` `dashboard_deprecated`**, so this audit uses v2; and `GET /api/v1/settings/ttl?type=<traces|metrics|logs>` returns the per-signal TTL (e.g. `{"traces_ttl_duration_hrs":360,...}`) — the `type` param is **required** (a bare call returns 400). Without a token those authed paths return `401 {"error":{"type":"unauthenticated"}}`; with a token but **no role assigned** they return `403 authz_forbidden` (a service account starts with zero roles — assign `signoz-viewer`). The ClickHouse databases `signoz_traces`, `signoz_metrics`, `signoz_logs`, `signoz_meter`, `signoz_metadata`, and `signoz_analytics` are present with Replicated/Distributed MergeTree tables (`logs_v2`, `samples_v2`/`samples_v4`, the traces span table) carrying TTL. The **exact JSON field names** of the responses, the `POST /api/v3/query_range` request body, and the SigNoz ClickHouse **column names** are **confirm-against-your-instance** — resolve them from the live response and from `system.columns` this run, never assume a field or column name.

## Doctor gate

Requirements. Configure only the blocks that exist in your environment; delete the rest from `~/.scoutflo/toolkit.yaml`. The SigNoz API must be configured for this audit to be worth running; the ClickHouse deep-backend lane is configured additionally when you want the backend-health and write-path categories scored directly against ClickHouse.

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| SigNoz API | `signoz.url` (`http(s)://your-signoz-host:8080`) | `signoz.api_key_env` (the variable named there — e.g. `SIGNOZ_API_KEY`) | a **Service Account token** (SigNoz Settings → Service Accounts) assigned at least the **`signoz-viewer`** role (read-only; Viewer/Editor/Admin all grant read, Viewer is the least-privilege that works); used as the header `SIGNOZ-API-KEY: <token>` on every authed `GET` and on `POST /api/v3/query_range` | read-only |
| SigNoz ClickHouse (optional deep lane) | `signoz.clickhouse_url` (`http(s)://your-clickhouse-host:8123`), `signoz.clickhouse_user` | `signoz.clickhouse_password_env` (the variable named there — e.g. `SIGNOZ_CH_KEY`) | a scoped **read-only** user: `SELECT` on the `signoz_*` databases + `system.*` | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

The ClickHouse lane is a deliberately heavier posture than the API Service Account token (a direct database credential) — configure it only when you want SIG-030/SIG-060/SIG-061/SIG-070 (ClickHouse health, capacity, write-path, metric cardinality) scored against the backend directly; without it those checks are marked `not-in-scope`, never failed, and retention (SIG-020) is read from the SigNoz settings API instead of the ClickHouse table TTL.

Preflight. A failed check stops the audit with the exact failure and the fix (usually `/scoutflo:connect`). Never downgrade a doctor failure into a finding.

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
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. This mirrors /scoutflo:doctor, so
# doctor and this audit agree on what is configured.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
command -v curl >/dev/null || { echo "curl not installed"; exit 1; }
command -v jq   >/dev/null || { echo "jq not installed"; exit 1; }

# Resolve the CURRENT signoz target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). Every authed call below
# uses THIS target's own url + token; output nests under SIG_SEG (signoz/<url-host> for a single block,
# signoz/<label> for a labeled list). No ambient default is read.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_KIND=$(sh "$TT" "$CFG" signoz kind); SIG_N=$(sh "$TT" "$CFG" signoz count)
[ "${SIG_N:-0}" -ge 1 ] || { echo "signoz block not configured in $CFG; this audit has nothing to read — run /scoutflo:connect or run a different audit"; exit 1; }
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_LABEL=$(sh "$TT" "$CFG" signoz label "$SIG_IDX")
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"
[ -n "$SIG_URL" ] || { echo "signoz target '${SIG_LABEL:-?}' has no url in $CFG; run /scoutflo:connect"; exit 1; }
SIG_HOST="$(printf '%s' "${SIG_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[:/].*$##' -e 's#[^A-Za-z0-9._-]#-#g')"; [ -n "$SIG_HOST" ] || SIG_HOST="signoz-host"
if [ "$SIG_KIND" = seq ]; then SIG_SEG="signoz/${SIG_LABEL}"; else SIG_SEG="signoz/${SIG_HOST}"; fi
echo "signoz target: ${SIG_LABEL} (${SIG_URL}) -> ${SIG_SEG}/"
# For every configured *_env key: presence only, never the value. signoz.api_key_env names the
# token variable (default SIGNOZ_API_KEY) and signoz.clickhouse_password_env the optional CH
# password variable (default SIGNOZ_CH_KEY); read each with printenv (its NAME, never its value),
# so references/signoz-checks.md and doctor resolve the same variable per target.
SIG_KEY_VAR=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" api_key_env); [ -n "$SIG_KEY_VAR" ] || SIG_KEY_VAR="SIGNOZ_API_KEY"
SIGNOZ_API_KEY=$(printenv "$SIG_KEY_VAR" 2>/dev/null || true)
[ -n "${SIGNOZ_API_KEY:-}" ] || { echo "signoz target '${SIG_LABEL}' configured but its Service Account token variable (${SIG_KEY_VAR}, from signoz.api_key_env) is not set; the authed SigNoz endpoints need a read-role service-account token — add it to ~/.scoutflo/env (echo 'export ${SIG_KEY_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
CH_KEY_VAR=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" clickhouse_password_env); [ -n "$CH_KEY_VAR" ] || CH_KEY_VAR="SIGNOZ_CH_KEY"
SIGNOZ_CH_KEY=$(printenv "$CH_KEY_VAR" 2>/dev/null || true)
if [ -n "${SIGNOZ_CH_KEY:-}" ]; then
  echo "SigNoz ClickHouse deep-backend lane configured — SIG-030/SIG-060/SIG-061/SIG-070 will be scored directly against ClickHouse"
else
  echo "SigNoz ClickHouse lane not configured (signoz.clickhouse_password_env unset); SIG-030/SIG-060/SIG-061/SIG-070 will be marked not-in-scope and retention (SIG-020) read from the SigNoz settings API"
fi
```

Then one cheap live call per configured integration: the open `GET /api/v1/version` (200) and `GET /api/v1/health` (`{"status":"ok"}`) for reachability, followed by one authenticated call — `GET /api/v1/rules` with the `SIGNOZ-API-KEY` header (a **200 with a JSON body** proves the token works; a 401 means it is missing/invalid; a **403 `authz_forbidden`** means the service account holds no read role — assign it `signoz-viewer`; a **200 with an HTML body** means the request fell through to the SPA/login page and is **not** verified) — and, when the ClickHouse lane is configured, a ClickHouse `SELECT 1` over HTTP with the read-only session flag. Exact commands are in [references/signoz-checks.md](references/signoz-checks.md) section 1. `/scoutflo:doctor` runs the same checks standalone.

## Live-safety gate

Before the first real read, print exactly what you are pointed at and compare it to the config. Print host and URL only — never the Service Account token or the ClickHouse password:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Resolve the CURRENT signoz target (single block, or the SCOUTFLO_TARGET-selected list item); never hand-typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_KIND=$(sh "$TT" "$CFG" signoz kind); SIG_N=$(sh "$TT" "$CFG" signoz count)
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_LABEL=$(sh "$TT" "$CFG" signoz label "$SIG_IDX")
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"     # signoz.url
SIG_HOST="$(printf '%s' "${SIG_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[:/].*$##' -e 's#[^A-Za-z0-9._-]#-#g')"; [ -n "$SIG_HOST" ] || SIG_HOST="signoz-host"
if [ "$SIG_KIND" = seq ]; then SIG_SEG="signoz/${SIG_LABEL}"; else SIG_SEG="signoz/${SIG_HOST}"; fi
CH_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" clickhouse_url); CH_URL="${CH_URL%/}"   # signoz.clickhouse_url (optional deep lane)
CH_USER=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" clickhouse_user); [ -n "$CH_USER" ] || CH_USER="scoutflo_ro"   # signoz.clickhouse_user (defaults to the connect recipe's CREATE USER name)
# CH lane presence: read the clickhouse_password_env variable (its NAME, never its value) after loading the store.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
CH_KEY_VAR=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" clickhouse_password_env); [ -n "$CH_KEY_VAR" ] || CH_KEY_VAR="SIGNOZ_CH_KEY"
SIGNOZ_CH_KEY=$(printenv "$CH_KEY_VAR" 2>/dev/null || true)
echo "signoz target   : ${SIG_LABEL} -> ${SIG_SEG}/"
echo "SigNoz API      : ${SIG_URL}"
[ -n "${SIGNOZ_CH_KEY:-}" ] && echo "SigNoz ClickHouse: ${CH_URL}  (user: ${CH_USER})"
# Confirm this is the SigNoz instance you intend to audit before any read.
VER="$(curl -fsS --max-time 10 "${SIG_URL%/}/api/v1/version" | jq -r '.version // "unknown"')" || VER="unreachable"
echo "reported version: ${VER}   (expected the SigNoz build you deploy, e.g. v0.138.x)"
case "$SIG_URL" in https://*) : ;; *) echo "WARN: SigNoz API is not TLS (https) — see SIG-050" ;; esac
```

If the resolved host, URL, or reported version differs from what `toolkit.yaml` names or from the instance you intend to audit, stop and report the mismatch. Never proceed on "probably the right instance". Every command in this skill (and in [references/signoz-checks.md](references/signoz-checks.md)) names its target explicitly: SigNoz reads go through the `sig_get` helper — `curl` against `${SIG_URL}/api/...` with the `SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}` header — and ClickHouse reads go through the `chq` helper (`curl` against `${CH_URL}/?readonly=1` with `X-ClickHouse-User`/`X-ClickHouse-Key` headers and the SQL as the POST body).

## Ground rules

- Config records are discovery metadata; a live query is proof. Credit nothing you did not read live this run.
- Evidence is real command output. An assertion without the query and its observed rows is a suspicion, not a finding.
- API and SQL errors are evidence. A `401` with the `{"error":{"type":"unauthenticated"}}` body on `/api/v1/rules` means the token is missing or invalid; a `403` with `{"error":{"type":"forbidden","code":"authz_forbidden","message":"only viewers/editors/admins can access this resource"}}` means the token authenticated but its service account holds **no read role** (below viewer — on v0.138 a service account starts with zero roles) — assign it the read-only `signoz-viewer` role; Viewer is sufficient — in either case record it and mark the affected categories `blocked`, never convert it into empty success. A `404` on a `/api/*` path means the wrong path (only `/api/v1/version`, `/api/v1/health`, `/api/v1/rules`, `/api/v1/channels`, `/api/v2/dashboards`, `/api/v1/settings/ttl`, and `POST /api/v3/query_range` are treated as confirmed — resolve anything else against the live instance before using it). An `unknown table`/`unknown database` error from ClickHouse means the wrong `signoz_*` database or a renamed table; a `516`/auth error over HTTP means the ClickHouse user or password is wrong.
- Never score from object counts. Forty dashboards and two hundred alert rules prove nothing; credit comes from telemetry a responder could actually act on — recent rows for the critical services, a rule that evaluates and routes to a live channel.
- A table that exists is not coverage. `signoz_logs.logs_v2` present with zero recent rows for `checkout` is a gap, not a pass.
- Alert rules are not live until they evaluate **and** route to a channel. A SigNoz alert rule wired to no channel, or to a broken/placeholder channel, is the core failure this audit exists to catch (SIG-040); "a rule exists" is `configured`, not working.
- Treat SigNoz response field names (`/api/v1/rules`, `/api/v1/channels`, `/api/v2/dashboards`), the `POST /api/v3/query_range` request/response shape, and every SigNoz ClickHouse column name as **confirm-against-your-instance**: read the shape from the live response and resolve columns via `system.columns` before you use them — never assume `preferredChannels`, `serviceName`, or a timestamp column name.
- Never print, log, or write a secret: no SigNoz PATs, ClickHouse passwords, channel webhook URLs, connection strings, or auth headers, in terminal output or in any output file. **Capture receiver/channel targets by name and host class only** (loopback / private / public / placeholder), never the full URL. Secret values are redacted at capture, and the written `report.md` is masked once more as defense-in-depth per [secret-redaction.md](../../report-standard/secret-redaction.md).

## Metadata Load

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # workspace projection, derived from the SSOT
BC_MD="${HOME}/.scoutflo/business_context.md"          # the SSOT itself (authoritative)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver

# The workspace layer and the per-resource layer load TOGETHER, not either/or.
HAVE_PER_RESOURCE=0; HAVE_WORKSPACE=0
[ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1 && HAVE_PER_RESOURCE=1
[ -f "$BC_JSON" ]  && jq -e '.' "$BC_JSON"  >/dev/null 2>&1 && HAVE_WORKSPACE=1
# Workspace source: the derived json, else the markdown SSOT directly (ssot-md fallback).
BC_SRC=""
if [ "$HAVE_WORKSPACE" -eq 1 ]; then BC_SRC="$BC_JSON"; elif [ -f "$BC_MD" ]; then BC_SRC="$BC_MD"; fi
if   [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ "$HAVE_WORKSPACE" -eq 1 ]; then LOAD_METADATA_MODE="per-resource+workspace"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ];                                then LOAD_METADATA_MODE="per-resource"
elif [ "$HAVE_WORKSPACE" -eq 1 ];                                   then LOAD_METADATA_MODE="workspace"
elif [ -n "$BC_SRC" ];                                              then LOAD_METADATA_MODE="ssot-md"
else                                                                     LOAD_METADATA_MODE="none"; fi
echo "metadata mode: $LOAD_METADATA_MODE"

# Load the workspace rules the apply step below honors. All fields optional; absence = neutral default.
if [ "$HAVE_WORKSPACE" -eq 1 ]; then
  ENVIRONMENT="$(jq -r '.environment // "production"' "$BC_JSON" 2>/dev/null || echo production)"
  COST_SENSITIVITY="$(jq -r '.cost_sensitivity // "medium"' "$BC_JSON" 2>/dev/null || echo medium)"
  CRITICAL="$(jq -r '.critical_dependencies[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  EXCLUSIONS="$(jq -r '.exclusions // {} | [.accounts?, .regions?, .services?, .resources?] | add // [] | .[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  jq -r --arg e "$ENVIRONMENT" '.environment_map[]? | select(.environment==$e)' "$BC_JSON" 2>/dev/null || true  # per-env profile/project/context + uptime_sla
  jq -r '.service_slas[]? | "\(.service)=\(.sla)"' "$BC_JSON" 2>/dev/null || true                               # per-service SLA (wins over the env default)
elif [ "$LOAD_METADATA_MODE" = "ssot-md" ]; then
  # Only business_context.md exists (json not derived): read the same rules from the SSOT directly.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** services matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** a coverage or freshness gap on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (a short retention TTL on a dev telemetry signal is not a prod compliance gap); and apply `cost_sensitivity` to the ordering of the retention (SIG-020) and capacity (SIG-060) findings. With no context, run neutral defaults and say so — never invent a business rule.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover services live from the telemetry itself — resolve the service dimension from the live SigNoz instance (`POST /api/v3/query_range` grouping by the service attribute, or from the `signoz_traces`/`signoz_logs` tables on the ClickHouse lane after discovering the service column via `system.columns`), note in the report that the list was inferred, and suggest `/scoutflo:map-topology`.

## Estate sizing

Count before judging, and declare the path in the terminal output. This count sizes how much ceremony the run uses; it never feeds the score itself. The objects that drive this audit's cost are the critical services (each gets coverage and freshness queries) and the SigNoz alert rules (each gets a routing/evaluation check). Backend-level checks (ClickHouse health, retention, security) run once regardless of estate size.

```bash
set -eu
# Resolve the CURRENT signoz target (single block or SCOUTFLO_TARGET-selected list item) and declare
# the SigNoz helper inline, so this block runs standalone. sig_get uses THIS target's own url + token.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_N=$(sh "$TT" "$CFG" signoz count)
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
SIG_KEY_VAR=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" api_key_env); [ -n "$SIG_KEY_VAR" ] || SIG_KEY_VAR="SIGNOZ_API_KEY"
SIGNOZ_API_KEY=$(printenv "$SIG_KEY_VAR" 2>/dev/null || true)
sig_get() { curl -fsS --max-time 20 -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" "${SIG_URL}$1"; }
SMALL_MAX_OBJECTS="100"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="500"   # example, tune to your environment
SERVICES=0
if [ -f "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md" ]; then
  SERVICES="$(awk '/^## Services$/{f=1;next} /^## /{f=0} f' "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/topology.md" \
    | grep -E '^\| ' \
    | grep -vE '^\| *Service *\||^\| *-{2,}' \
    | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2!="") print $2}' \
    | sort -u | grep -c . || true)"
fi
# SigNoz alert rules (guard the fetch: an auth failure must surface, not silently
# count as zero). Declare the SigNoz helper from references/signoz-checks.md section 1
# first (sig_get sends the SIGNOZ-API-KEY header):
RULES=0
if ! RULES="$(sig_get /api/v1/rules | jq 'if type=="array" then length elif has("data") then (.data|length) elif has("rules") then (.rules|length) else 0 end' 2>/dev/null)"; then
  echo "WARN: GET /api/v1/rules failed — rule count unknown; estate sizing is a floor, not the truth."
  RULES=0
fi
TOTAL=$((SERVICES + RULES))
path="large"
[ "${TOTAL}" -le "${MEDIUM_MAX_OBJECTS}" ] && path="medium"
[ "${TOTAL}" -le "${SMALL_MAX_OBJECTS}" ] && path="small"
echo "estate: services=${SERVICES} alert_rules=${RULES} scored_objects=${TOTAL} sizing-path=${path}"
```

Record `estate: {objects: TOTAL, path: path}` in `findings.json` per the [findings schema](../../report-standard/findings-schema.md). Never silently truncate a large estate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set, batched against a durable worklist per [Large-path worklist](#large-path-worklist); the report names anything scoped out.

### Empty / hidden-scope guardrail (SIG-007)

The scope checkpoint narrows a *large* estate. This guardrail catches the opposite and more dangerous case — an estate that looks **empty** because you cannot see the data, not because it is not there. It is the SigNoz twin of the audit-gcp/audit-elk/audit-clickstack visibility trip-wire. After the inventory reads (Phase 2), evaluate:

```bash
set -eu
# Set from the Phase-2 reads: total recent rows across every signoz_* telemetry
# source, and the SigNoz alert-rule count (or -1 if not queried).
SIGNOZ_ROWS="${SIGNOZ_ROWS:-0}"      # sum of recent-window counts across logs/traces/metrics
SIG_RULES="${SIG_RULES:--1}"         # -1 = not queried; >=0 = queried
SIG_REACHABLE="${SIG_REACHABLE:-1}"  # 1 = /api/v1/health returned ok and the token works this run
if [ "${SIG_REACHABLE}" -eq 1 ] && [ "${SIGNOZ_ROWS}" -eq 0 ]; then
  echo "[guard] SigNoz is reachable but ZERO telemetry rows across logs/traces/metrics in the recent window — visibility/ingestion gap, NOT a confident 0 (SIG-007)"
  echo "[guard] the OTel collector may be down, mis-targeted, or writing to a different database; confirm the ingest path before scoring coverage as failed"
fi
if [ "${SIG_RULES}" -eq 0 ]; then
  echo "[guard] SigNoz is reachable but ZERO alert rules exist — visibility/coverage gap, NOT a confident 0 (SIG-007)"
fi
```

Behavior this enforces:

- **Reachable SigNoz, zero telemetry everywhere:** do **not** score SIG-010 (Telemetry coverage) and SIG-011 (Ingestion freshness) as a confident `0/100`, and do not score them a vacuous high from an empty set. Mark those two categories `blocked` with the visibility-gap reason, **keep Security posture (SIG-050) and — when the ClickHouse lane is configured — ClickHouse health (SIG-030) included** (they do not depend on any telemetry existing), renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md), and emit finding **SIG-007** naming the gap (collector down / wrong database / wrong instance) and the fix. Keeping at least one scored category always remains is what `check-findings.sh` requires.
- **SigNoz reachable, zero alert rules:** exclude SIG-040 (alerting) and SIG-041 (dashboards) as `blocked` with the reason, renormalize, and emit **SIG-007** — an instance with no alert rules at all is a coverage gap to fix, never a confident zero.
- **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim on a tripped guardrail.

## Phase 2: Read-only inventory

Build the raw picture before judging anything. Commands are in [references/signoz-checks.md](references/signoz-checks.md) (the helpers in section 1; the per-surface reads in sections 4-8); capture into the run's `raw/` directory, redacted. The successful authed reads here are themselves the evidence for **SIG-001 (query API health)** — the authenticated read path the whole audit depends on actually answers with the Service Account token.

- **Alert rules:** `GET /api/v1/rules` through `sig_get` — enumerates each configured rule. Field names (the rule's channel linkage, enabled/disabled state, `for`/evaluation window) are confirm-against-your-instance; read them from the live response.
- **Channels:** `GET /api/v1/channels` through `sig_get` — the notification channels an alert rule can route to (Slack, webhook, PagerDuty, email, …). Capture the channel name and destination **host class only**, never the full URL.
- **Dashboards:** `GET /api/v2/dashboards` through `sig_get` — the dashboards and the queries/panels they carry.
- **Telemetry sources (if the ClickHouse lane is configured):** `SELECT name, engine, total_rows, total_bytes, engine_full FROM system.tables WHERE database IN ('signoz_traces','signoz_logs','signoz_metrics','signoz_meter') ORDER BY database, name` — enumerates the confirmed telemetry databases and their tables (`logs_v2`, `samples_v2`/`samples_v4`, the traces span table). The `engine_full` string carries the retention TTL read in Phase 5.
- **Users (if the ClickHouse lane is configured):** `SELECT name, auth_type, host_ip FROM system.users` — the security read in Phase 6.

Record what exists (rules, channels, dashboards, tables, row/byte counts, users) as inventory, not yet as findings. This is the raw pull that both `findings.json` and `inventory.json` derive from — no new live calls later.

## Phase 3: Tool ownership boundary

SigNoz owns backend telemetry (logs, metrics, traces) and its own alerting via its bundled Alertmanager and channels. It does **not** own frontend error tracking (that is `/scoutflo:audit-sentry`) or an external paging tree fronted by PagerDuty routing depth (`/scoutflo:audit-pagerduty`), or a separate Prometheus/Alertmanager stack's routing tree (`/scoutflo:audit-alertmanager`). A signal absent from SigNoz because another tool owns it is a boundary decision, not a gap; record the boundary and audit the owning stack.

## Phase 4: Telemetry coverage (SIG-010) and ingestion freshness (SIG-011)

For each critical service from Phase 1, query the live SigNoz telemetry over a recent window (commands in [references/signoz-checks.md](references/signoz-checks.md) section 4). Two lanes; use whichever is configured, and prefer the ClickHouse lane for per-service depth because its rows are exact:

- **SigNoz query API (always available with the Service Account token):** `POST /api/v3/query_range` with a composite query grouped by the service attribute over the recent window. **The exact request body is confirm-against-your-instance** — build the minimal query builder payload against the live instance (the SigNoz UI's own network calls are the reference), and read the response shape from the live response; never assume a field name. Zero result rows for a service it should emit is a coverage gap.
- **ClickHouse deep lane (when configured):** count recent rows per critical service against `signoz_logs.logs_v2`, the `signoz_traces` span table, and `signoz_metrics.samples_v*`. **Resolve the service column and the timestamp column first** with `SELECT name, type FROM system.columns WHERE database = {db} AND table = {tbl}` — the SigNoz column names are NOT assumed. Then `count()` over the recent window per service and `max(<ts_col>)` for freshness.

Fill one row per critical service:

| Service | Logs | Traces | Metrics | Freshness | Gap |
| --- | --- | --- | --- | --- | --- |
| checkout | pass | pass | fail | 42s lag | no metrics |

- **SIG-010 (Telemetry coverage):** a critical service with recent rows in the signals it should emit is `pass`; a service with zero rows in a signal it should have is a coverage gap. Name affected services in `affected` — "checkout, payments lack trace coverage", never "two services lack traces".
- **SIG-011 (Ingestion freshness):** compute `now() - max(<ts_col>)` per signal that has data. A lag beyond `FRESHNESS_THRESHOLD` (example threshold; tune to your ingest cadence) means the pipeline (OTel collector or the writer into ClickHouse) has stalled even though rows exist — a broken-pipeline finding distinct from "no data". A signal with data but a growing max-timestamp lag is `SIG-011`, not `SIG-010`.

If neither lane can confirm a service's coverage (the query_range payload cannot be resolved and the ClickHouse lane is not configured), mark SIG-010/SIG-011 `blocked` with the reason — never a confident fail.

## Phase 5: Retention (SIG-020)

SigNoz sets retention per signal (traces / metrics / logs), each with a deliberate TTL. Read it from the SigNoz settings API first, and confirm against the ClickHouse table TTL when the deep lane is configured (commands in section 5):

- **SigNoz settings API (preferred):** `GET /api/v1/settings/ttl` through `sig_get` — the per-signal TTL SigNoz manages. Read the response shape from the live instance; the per-signal keys are confirm-against-your-instance.
- **ClickHouse table TTL (deep lane):** `SELECT name, engine_full FROM system.tables WHERE database LIKE 'signoz_%' AND ...` or `SHOW CREATE TABLE` — the `TTL` clause on the MergeTree table (e.g. `TTL toDateTime(timestamp) + toIntervalDay(30)`).

- A deliberate TTL per signal is `pass` — retention is bounded and intentional.
- **No TTL = unbounded retention** — a real cost and compliance finding (`SIG-020`), because the signal's storage grows without limit.
- A TTL far shorter than the team's stated retention need is a **data-loss** gap — also `SIG-020`, distinct severity.

Read retention; never guess it. A missing TTL is a finding, not an assumption of "probably fine".

## Phase 6: ClickHouse health (SIG-030), capacity/write-path (SIG-060, SIG-061), metric cardinality (SIG-070), and security posture (SIG-050)

These read the SigNoz ClickHouse `system.*` and metrics tables directly and therefore run only when the ClickHouse deep lane is configured; without it, SIG-030/SIG-060/SIG-061/SIG-070 are `not-in-scope` (excluded and renormalized) and SIG-050 falls back to the transport/endpoint checks the SigNoz API surface allows. Inspection only (commands in sections 6 and 8); discover any uncertain column via `system.columns` before use — the `signoz_*` schema is versioned and column names differ across builds.

- **SIG-030 (ClickHouse health):** `system.parts` (active part counts and bytes per `signoz_*` table — a runaway part count signals merge pressure), `system.replicas` (replicas in sync, no growing queue — empty on a single-node build, expected), `system.errors` (no spiking codes — read `name`, `code`, `value`, `last_error_time`; discount the single `READONLY` (164) row the section-1 `readonly=1` probe itself may add on a profile-readonly user), `system.mutations` (none stuck / long-running). A spiking error code or a stuck mutation is a health finding.
- **SIG-060 (capacity headroom):** `system.disks` free/total and per-table `bytes_on_disk` from `system.parts` (columns confirmed via `system.columns` first) yield **days-to-read-only** at the observed growth rate. Blast radius: at **243 `NOT_ENOUGH_SPACE`** *every* `signoz_*` INSERT is rejected at once, not one table.
- **SIG-061 (write-path failures):** fresh Insert exceptions and spiking write-path codes in `system.errors`/`system.query_log` — **243 `NOT_ENOUGH_SPACE`** (disk full → SIG-060), **252 `TOO_MANY_PARTS`** (merge backlog), **164 `READONLY`** (profile-readonly user or a replica in Keeper-readonly state), **201 `QUOTA_EXCEEDED`**. This distinguishes "collector stopped sending" (SIG-011 stale, no insert exceptions) from "collector still sending, ClickHouse rejecting every write" (fresh exceptions). When reading 164, discount the audit's own `readonly=1` probe row.
- **SIG-070 (metric cardinality health):** for the top metrics by sample volume, read distinct label-value counts from the metrics store and classify each label (unbounded / identifier / accumulating / high-but-bounded / deployment-dependent — full profiles + attribute lists in [references/signoz-checks.md §6c](references/signoz-checks.md#6c-metric-cardinality-health-sig-070)). An unbounded/identifier label (e.g. `trace_id`, `user.id`, `url.full`) or an accumulating one (`k8s.pod.uid`) is the finding regardless of today's count; the fix names `metricstransform aggregate_labels` (merge series), never a raw drop. **Never** call a `system.*`/`k8s.*`/`signoz_*` metric "safe to drop" (it powers the Hosts/Kubernetes/APM pages) — reduce its label cardinality instead. Series count is the ingestion-cost + query-latency driver; the ranked cost view of the same reads is [audit-cost signoz-cost.md](../../audit-cost/references/signoz-cost.md).
- **SIG-050 (security posture):** the external `default` ClickHouse user must require a password (probe it with an unauthenticated `SELECT 1` — a `200` means open, critical); service users must not sit on `plaintext_password` (`sha256_password`/`double_sha1_password` are the hardened forms); **the SigNoz API endpoint must require auth** — the confirmed `401` on `/api/v1/rules` without a Service Account token is the good state, a `200` on an authed resource without a header is a critical exposure; TLS on the wire (the audit's own `signoz.url` and `signoz.clickhouse_url` should be `https`); and the audit's ClickHouse user should be least-privilege read-only (`SHOW GRANTS FOR currentUser()` shows only `SELECT`/`SHOW`), and the SigNoz service-account token should hold the **least role that still grants read** — on v0.138 that is **`signoz-viewer`** (read-only; Viewer/Editor/Admin all pass the `ViewAccess` gate, so Viewer is the floor); flag an over-broad **Admin** token where the read-only `signoz-viewer` role would suffice (the role is declared at connect, not self-introspectable).

## Phase 7: SigNoz alerting (SIG-040) and dashboards (SIG-041)

Via the SigNoz API through `sig_get` (commands in section 7). The confirmed authed paths are `/api/v1/rules`, `/api/v1/channels`, and `/api/v2/dashboards`; treat field names as confirm-against-your-instance and read them from the live response.

- **SIG-040 (alerting reaches a human) — the flagship.** Assemble the per-service **paging path** and score it end to end: a critical service has an alert rule → the rule is **enabled and evaluates** (it has a query, a threshold, and a `for`/evaluation window that is not disabled) → it **routes to a channel** named in `/api/v1/channels` that is **live** (a real Slack/webhook/PagerDuty destination, not empty, not a loopback/placeholder host). Resolve the rule→channel linkage from the live JSON (the field carrying the channel name is confirm-against-your-instance), match each referenced channel to a channel object, and read its destination **host class only**. The core failure this category exists to catch: an alert rule wired to **no channel**, to a channel that no longer exists, or to a placeholder/loopback destination — the rule evaluates and pages nobody. Reading the rule and channel config proves the path is **configured**; it does not prove delivery — mark delivery `configured`, not `validated-live`, since the controlled test-fire that would upgrade it is a mutation this audit never performs. Capture channel targets by name/class only, never the webhook URL.
- **SIG-041 (dashboards):** `GET /api/v2/dashboards`. Dashboards should exist for the critical services, and their panel queries should resolve against a live telemetry source (a panel querying a service/signal that Phase 4 found empty is a dead panel). A critical service with no dashboard is a `SIG-041` gap. Confirm field names against the raw JSON before asserting a panel is dead.

## Phase 7c: Scoutflo Topology Readiness

Render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only, and report it parallel to the score (never folded into the 0-100). An observation edge this audit verified live — a `SENDS_LOGS_TO`/`SENDS_METRICS_TO`/`SENDS_TRACES_TO` edge to the SigNoz backend that Phase 4 confirmed carries fresh, retained telemetry for that service, or a `MONITORED_BY` edge to the SigNoz resource — counts toward T4/T6 exactly as the standard defines; do not assert any SigNoz-specific edge attribute or schema key beyond what topology-readiness.md specifies. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action-plan table. If `topology-export.json` or `topology.md` is missing, or describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), render the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); never guess, never a bare "unavailable".

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is `floor(((checks_passed*2)+checks_partial)*50/assessed)` where `assessed = passed+partial+failed` (0 when a category has no assessed check); overall is the weight-normalized sum over categories with at least one assessed check, rounded down. Show assessment coverage separately. A category with zero assessed checks is excluded, renormalized, and stated (this is exactly the SIG-007 path, and the ClickHouse-lane-not-configured path for SIG-030/060/061). A fully blocked run is `unassessed` with `overall: null`, never 0/100. Assign each category a maturity value (`reactive`, `proactive`, `systematic`). Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action.

| Category | Weight | ID range |
| --- | ---: | --- |
| Query API health | 5 | SIG-001 |
| Telemetry coverage | 20 | SIG-010, SIG-007 |
| Ingestion freshness | 15 | SIG-011 |
| Retention | 10 | SIG-020 |
| ClickHouse health | 15 | SIG-030, SIG-060, SIG-061, SIG-070 |
| Alerting | 20 | SIG-040 |
| Dashboards | 5 | SIG-041 |
| Security posture | 10 | SIG-050 |

Weights sum to 100. The full check catalog, one permanent ID per check with typical failure severity, is at the top of [references/signoz-checks.md](references/signoz-checks.md). IDs are stable; the same defect gets the same ID every run, which is what makes deltas exact. One finding per failed check, with every affected service enumerated in `affected`. Every scored finding must clear the [depth doctrine](../../report-standard/depth-doctrine.md): the exact object and wrong value, a live-computed blast radius, the correlation chain it belongs to, the exact fix, and a verification step — never "X is missing".

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service has fresh logs/traces/metrics, alert rules route to a live channel, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `points_recoverable` to 0. Suppressed checks remain assessed for coverage but are excluded from readiness scoring; the scorecard states the suppressed count.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `SIG-*` catalog check (SIG-001, SIG-007, SIG-010, SIG-011, SIG-020, SIG-030, SIG-040, SIG-041, SIG-050, SIG-060, SIG-061), including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. A `blocked` or `not-in-scope` row requires a non-empty `reason`; the SIG-007 guardrail path marks SIG-010/SIG-011 (and, without the ClickHouse lane, SIG-030/060/061) `blocked` with the visibility/lane reason, and the ClickHouse-lane-off path marks SIG-030/060/061 `not-in-scope`.
5. Every finding declares `scoring_scope: "readiness"` and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Referential integrity: every `partial`/`fail`/`blocked` check has exactly one same-ID readiness finding, and every readiness finding points back to a same-ID `partial`/`fail`/`blocked` row (never a `pass` or `not-in-scope` row); a `blocked` finding carries `status: "blocked"` and `points_recoverable: 0`. Use the AI SRE lane only when the evidence shows impact to telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety — a coverage/freshness/naming/routing-evidence finding (SIG-007, SIG-010, SIG-011, SIG-040, SIG-041) is typically **both**, while a pure reliability/cost/security-posture finding (SIG-020, SIG-030, SIG-050, SIG-060, SIG-061) is `general-audit` only. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_KIND=$(sh "$TT" "$CFG" signoz kind); SIG_N=$(sh "$TT" "$CFG" signoz count)
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_LABEL=$(sh "$TT" "$CFG" signoz label "$SIG_IDX")
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"
SIG_HOST="$(printf '%s' "${SIG_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[:/].*$##' -e 's#[^A-Za-z0-9._-]#-#g')"; [ -n "$SIG_HOST" ] || SIG_HOST="signoz-host"
if [ "$SIG_KIND" = seq ]; then SIG_SEG="signoz/${SIG_LABEL}"; else SIG_SEG="signoz/${SIG_HOST}"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SIG_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (scoutflo-findings/v2 with a complete checks[] ledger — one row per
# SIG-* catalog check — lifecycle + scoring_scope + report_lanes set per finding, estate object
# from sizing; ".target" is the per-target slug $SIG_SEG — "signoz/<url-host>" for a single block,
# "signoz/<label>" for a labeled list, so audit-all/correlation/render disambiguate multiple
# instances), inventory.json (kinds: alert_rule, contact_point, dashboard, table, user; ".target"
# also $SIG_SEG), and report.md per the report standard, then verify:
jq -e --arg seg "$SIG_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.checks | type == "array" and length > 0)
  and (.findings | type == "array")
  and (.findings | all(has("lifecycle") and (.scoring_scope == "readiness") and (.report_lanes | type == "array" and length > 0)))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog, built from the raw
# pull, redacted. counts.total must reconcile with items; the ## Inventory section IS this render.
jq -e --arg seg "$SIG_SEG" '.schema == "scoutflo-inventory/v1" and .target == $seg and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "$OUT/findings.json" >/dev/null && echo "findings-by-purpose section renders"
grep -qxF '## Findings by purpose' "$OUT/report.md" && echo "findings-by-purpose section present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
# Defense-in-depth: mask any secret that slipped capture before the report is shared.
. "${CLAUDE_PLUGIN_ROOT}/skills/redaction/lib/redaction.sh"
redact_file "$OUT/report.md"
has_secrets "$OUT/report.md" && echo "[redaction] WARNING: residual secret pattern — investigate capture" || echo "[redaction] report clean"
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by `points_recoverable`, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then append the derived history row after findings/report validation; a same-date rerun replaces that date's row instead of duplicating it, and the row carries `state`, `check_set`, and `assessment.coverage_percent` so a re-weighted run is treated as incomparable rather than plotted as a real delta:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_KIND=$(sh "$TT" "$CFG" signoz kind); SIG_N=$(sh "$TT" "$CFG" signoz count)
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_LABEL=$(sh "$TT" "$CFG" signoz label "$SIG_IDX")
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"
SIG_HOST="$(printf '%s' "${SIG_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[:/].*$##' -e 's#[^A-Za-z0-9._-]#-#g')"; [ -n "$SIG_HOST" ] || SIG_HOST="signoz-host"
if [ "$SIG_KIND" = seq ]; then SIG_SEG="signoz/${SIG_LABEL}"; else SIG_SEG="signoz/${SIG_HOST}"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SIG_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-signoz", overall:.score.overall, state:.score.state,
    scoring_model:.score.scoring_model, check_set:.score.check_set,
    assessment_coverage_percent:.score.assessment.coverage_percent, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and ((.overall|type)=="number" or .overall==null) and .scoring_model and .check_set' >/dev/null && echo "history.jsonl updated"
```

Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SIG_KIND=$(sh "$TT" "$CFG" signoz kind); SIG_N=$(sh "$TT" "$CFG" signoz count)
SIG_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SIG_N:-0}" ]; do [ "$(sh "$TT" "$CFG" signoz label "$_i")" = "$SCOUTFLO_TARGET" ] && { SIG_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SIG_LABEL=$(sh "$TT" "$CFG" signoz label "$SIG_IDX")
SIG_URL=$(sh "$TT" "$CFG" signoz get "$SIG_IDX" url); SIG_URL="${SIG_URL%/}"
SIG_HOST="$(printf '%s' "${SIG_URL:-}" | sed -e 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' -e 's#[:/].*$##' -e 's#[^A-Za-z0-9._-]#-#g')"; [ -n "$SIG_HOST" ] || SIG_HOST="signoz-host"
if [ "$SIG_KIND" = seq ]; then SIG_SEG="signoz/${SIG_LABEL}"; else SIG_SEG="signoz/${SIG_HOST}"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${SIG_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  SCORE_STATE="$(jq -r '.score.state' "$OUT/findings.json")"
  CUR_MODEL="$(jq -r '.score.scoring_model' "$OUT/findings.json")"
  CUR_SET="$(jq -r '.score.check_set' "$OUT/findings.json")"
  ASSESSMENT="$(jq -r '.score.assessment | "\(.assessed_checks)/\(.applicable_checks) (\(.coverage_percent)%) assessed, \(.scored_checks) scored, \(.blocked_checks) blocked, \(.suppressed_checks) suppressed"' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | select((.lifecycle // "new") != "suppressed") | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*-[0-9]*' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    PREV_MODEL="$(jq -r '.score.scoring_model // ""' "$PREV/findings.json")"
    PREV_SET="$(jq -r '.score.check_set // ""' "$PREV/findings.json")"
    PREV_SCORE="$(jq -r 'if (.score.overall|type)=="number" then .score.overall else "" end' "$PREV/findings.json")"
    if [ "$SCORE_STATE" = "assessed" ] && [ -n "$PREV_SCORE" ] && [ "$PREV_MODEL" = "$CUR_MODEL" ] && [ "$PREV_SET" = "$CUR_SET" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    fi
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  if [ "$SCORE_STATE" = "unassessed" ]; then
    HEAD="audit-signoz ${RUN_DATE}: readiness unassessed; ${ASSESSMENT}. ${COUNTS}."
  else
    HEAD="audit-signoz ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}; ${ASSESSMENT}. ${COUNTS}."
  fi
  jq -n --arg head "$HEAD" \
        --arg top "$TOP" --arg delta "$DELTA" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Inventory

`report.md`'s `## Inventory` section is the `render-report-viz.sh inventory` render of `inventory.json` — never hand-write it, regenerate it. Build one item per object the audit read, per the [inventory schema](../../report-standard/inventory-schema.md), using these SigNoz kinds:

| kind | source | key `attrs` |
| --- | --- | --- |
| `alert_rule` | `GET /api/v1/rules` | `routes_to` = channel class/name (never the URL); `enabled`; `covers` = service |
| `contact_point` | `GET /api/v1/channels` | `routes_to` = destination host class (loopback/private/public/placeholder), never the URL |
| `dashboard` | `GET /api/v2/dashboards` | `covers` = service, `panels` count |
| `table` | `system.tables` (`signoz_*`) | `rows`, `bytes`, `retention_days` (parsed from the TTL), `engine` |
| `user` | `system.users` | `auth_type`, `host_scope` (never `auth_params` values) |

Every row traces to a raw object read this run; an empty estate is `items: []` with `total: 0`, reported honestly and paired with the SIG-007 guardrail. Redaction applies (`secret-redaction.md`): capture by key/name only — never a secret value, webhook URL, phone number, or email.

## Findings by purpose

`report.md`'s `## Findings by purpose` section is the `render-report-viz.sh lanes` render of `findings.json` — never hand-write it, regenerate it. It splits every finding by its `report_lanes` so a reader sees the two audiences separately: **general audit** (operational reliability, retention/cost, ClickHouse health, security posture) and **AI SRE readiness** (whether telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, and action safety are sufficient for trustworthy AI-assisted diagnosis). A finding that bears on both — most SIG-007/SIG-010/SIG-011 coverage-and-freshness findings and every SIG-040/SIG-041 routing/dashboard finding — appears in both lanes; a pure reliability/cost/security-posture finding (SIG-020/SIG-030/SIG-050/SIG-060/SIG-061) appears only under general audit. The lane split is presentation and ownership, never a second severity or score. The Phase-8 emit block asserts this section renders and is present.

## Remediation pointers

**No `setup-signoz` ships yet**, so every finding's `remediation` field names the concrete inline SigNoz UI/API fix location instead of a setup anchor. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Unbounded or too-short retention on a signal (SIG-020) | SigNoz UI: Settings → General (Retention Period) per signal, or the settings TTL API — set a deliberate TTL per traces/metrics/logs |
| Alert rule missing, or wired to no live channel (SIG-040) | SigNoz UI: Alerts → the rule → Notification Channels; Settings → Alert Channels to create/repair a channel; deep paging-path proof lives in `/scoutflo:audit-alertmanager` |
| No notification channel configured at all (SIG-040) | SigNoz UI: Settings → Alert Channels — add a Slack/webhook/PagerDuty/email channel and bind it to the rules |
| Missing telemetry / stalled ingestion for a critical service (SIG-010, SIG-011) | Fix the OTel collector target and pipeline (the SigNoz collector config / the app's OTLP exporter endpoint on 4317/4318); instrumentation gaps get a named owner |
| Missing dashboard for a critical service (SIG-041) | SigNoz UI: Dashboards → New Dashboard (or import a service dashboard) for the uncovered service |
| ClickHouse merge pressure, stuck mutation, spiking errors (SIG-030) | ClickHouse operator/admin: address the merge backlog or failed mutation on the `signoz_*` table (a mutation this audit never performs) |
| Disk filling toward read-only / write-path rejections (SIG-060, SIG-061) | Expand the ClickHouse disk / tiered storage / `keep_free_space`, or shorten retention (SIG-020) to reclaim space |
| Open ClickHouse `default` user, plaintext-password user, non-TLS endpoint (SIG-050) | ClickHouse admin: require the `default`-user password, move `plaintext_password` users to `sha256_password`, front the endpoints with TLS |
| Over-privileged audit token where a narrower role would work (SIG-050) | SigNoz UI: Settings → Service Accounts + Roles — issue a service-account token on the least read-granting role — **`signoz-viewer`** (read-only, sufficient for every read endpoint the audit uses; **Admin** is broader than needed) — and revoke the over-scoped one |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Large-path worklist

Runs on the large path only (see [Estate sizing](#estate-sizing)). All state lives under a run-ID-keyed directory `./scoutflo-audits/signoz/<label-or-url-host>/runs/<RUN_ID>/` (the per-target segment is the resolved `SIG_SEG` — `signoz/<label>` for a labeled multi-target list, `signoz/<url-host>` for a single block), not a calendar-date directory, so a run still batching when the UTC date rolls over keeps writing to the same place.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/signoz/<label-or-url-host>/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per critical service counted in Estate sizing (for the Phase 4 per-service coverage + freshness checks) and one per SigNoz alert rule (for the Phase 7 routing check), status `pending` or `done`. A resumed run continues its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the matching checks against just that batch — Phase 4 coverage/freshness for a service row, Phase 7 routing for a rule row. A row is marked `done` **only after its reads succeed**, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

The subscription-wide cheap checks (ClickHouse health SIG-030, retention SIG-020, security posture SIG-050, and the SIG-007 guardrail) are single passes; they run once per run regardless of path and are never batched.

## Common Failure Modes

All thresholds and windows named in the checks (`RECENT_WINDOW`, `FRESHNESS_THRESHOLD`) are example values; tune them to your traffic and retention before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| A table exists, so coverage scored `pass` | Coverage is recent rows for the service, not table presence; count over `RECENT_WINDOW` per critical service via `/api/v3/query_range` or the ClickHouse lane |
| Stalled pipeline read as "no data" | Distinguish zero rows (SIG-010) from rows present but a growing `max(<ts_col>)` lag (SIG-011) |
| Invented a SigNoz ClickHouse column name | The `signoz_*` column names are not assumed; resolve the service and timestamp columns from `system.columns` before querying |
| Assumed the `/api/v3/query_range` request body | The query-builder payload is confirm-against-your-instance; build it from the live instance and read the response shape live |
| A `401` read as a broken endpoint | `401 {"error":{"type":"unauthenticated"}}` on `/api/v1/rules` means the token is missing or invalid (`401`) — and a `403 authz_forbidden` means its service account has no read role (assign it the read-only `signoz-viewer`) — a `blocked` category with the reason, not a confident fail; the open `/api/v1/version` + `/api/v1/health` still prove reachability |
| SigNoz field names assumed | Read `/api/v1/rules`, `/api/v1/channels`, `/api/v2/dashboards` shapes from the live response; the rule→channel linkage field is confirm-against-your-instance |
| Alert rule counted as working because it exists | A rule wired to no channel, a dead channel, or a placeholder destination is the SIG-040 failure; mark delivery `configured`, not validated-live |
| Retention assumed instead of read | Read the per-signal TTL from `GET /api/v1/settings/ttl` (and the ClickHouse table TTL on the deep lane); a missing TTL is unbounded retention (SIG-020), not "probably fine" |
| SIG-030/060/061 failed when the ClickHouse lane is not configured | Those checks read `system.*`; without `signoz.clickhouse_*` they are `not-in-scope` (excluded, renormalized), never a fail |
| Plaintext-password / open default ClickHouse user missed | Read `auth_type` from `system.users`; probe the external `default` user with an unauthenticated `SELECT 1` — a 200 is critical |
| Empty SigNoz scored a confident 0 | Reachable SigNoz with zero telemetry everywhere (or zero alert rules) trips SIG-007 — block the coverage/alerting categories, keep security (+ CH health), renormalize, never a confident 0/100 |
| A mutating call slipped into the audit | Every SigNoz call is a `GET` (or the read-only `POST /api/v3/query_range` query); every ClickHouse call is a `SELECT`/`SHOW` with `readonly=1`; test alerts, `INSERT`/`ALTER`/`CREATE`/`DROP`, and any resource `POST`/`PUT`/`PATCH`/`DELETE` are forbidden |
| Secret leaked into evidence | Record channel class and user names only; never the token, ClickHouse password, or channel webhook URL |
