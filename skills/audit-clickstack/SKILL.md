---
name: audit-clickstack
description: Read-only scored audit of a ClickStack observability deployment (ClickHouse + HyperDX + OpenTelemetry): telemetry-table coverage, ingestion freshness, per-table retention TTL, ClickHouse database health, HyperDX alerting and dashboards/sources, and security posture; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring ClickStack, ClickHouse observability, HyperDX alerts or dashboards, otel_logs/otel_traces/otel_metrics tables, telemetry ingestion freshness, or ClickHouse retention/TTL. Do not use for Grafana-fronted LGTM/VictoriaMetrics stacks (use audit-lgtm), for Elasticsearch/Kibana (use audit-elk), to prove an Alertmanager page reaches a human (use audit-alertmanager), or to change ClickHouse/HyperDX (use setup-clickstack).
---

# audit-clickstack

Scored, read-only audit of a **ClickStack** deployment — **ClickHouse** (the columnar telemetry store), **HyperDX** (search, dashboards, and alerting UI/API), and the **OpenTelemetry** collector that feeds them. It answers one question: when something breaks tonight, is the telemetry for your critical services actually landing in ClickHouse, is it fresh and retained deliberately, is the database healthy, and does a HyperDX alert reach a human on a receiver that will deliver?

Every command in this audit is read-only: ClickHouse `SELECT`/`SHOW` statements over the HTTP interface (port 8123), issued with the session flag `readonly=1`, and HyperDX `GET` calls only — plus, on HyperDX v2.x with the optional login credentials configured, exactly one authentication handshake (`POST /api/login/password`) that obtains the session cookie those GETs need; it creates or modifies no resource (see the forbidden-mutations section of the check catalog). Nothing is inserted, altered, created, dropped, or notified. A mutating SQL statement (`INSERT`, `ALTER`, `CREATE`, `DROP`, `TRUNCATE`, `OPTIMIZE`) belongs to `/scoutflo:setup-clickstack`, never here. Firing a HyperDX test alert to prove delivery end to end is also a mutation and lives in the setup lane.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

**Scope — multiple targets, one run:** `clickstack` may be a single block (one `clickhouse_url` + `hyperdx_url`) or a **list of labeled targets**, each with its own connection params. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> clickstack labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `clickstack/<label>/<date>/` for a list, or the flat `clickstack/<date>/` for a single block (the label defaults to the block name `clickstack`, so a single-block run is byte-identical to today). Every command resolves that target's own `clickhouse_url`/`clickhouse_user`/`hyperdx_url` and its `*_env` credential-variable names through the enumerator; no ambient default is read.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/clickstack/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md)
- `./scoutflo-audits/clickstack/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output) and the `## Findings by purpose` section (the `render-report-viz.sh lanes` output)
- `./scoutflo-audits/clickstack/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per HyperDX `alert`, `dashboard`, and `source`, per telemetry `table`, and per ClickHouse `user`, each built from the raw pull, never invented, redacted at capture.
- One appended line in `./scoutflo-audits/clickstack/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

Provenance note: the ClickHouse read surface and HyperDX endpoint/auth model cited below were **confirmed on a live read** against an official ClickStack build — including the v2 session-login path (`POST /api/login/password` answers with a redirect and a `connect.sid` cookie; a session `GET /api/alerts` returns `200`). The exact JSON field names of the HyperDX `/api/alerts`, `/api/dashboards`, and `/api/sources` responses are **confirm-against-your-instance** — resolve them from the live response this run, never assume a field name.

## Doctor gate

Requirements. Configure only the blocks that exist in your environment; delete the rest from `~/.scoutflo/toolkit.yaml`. Configure **ClickHouse OR HyperDX — at least one** (both when you have both). ClickHouse scores telemetry coverage, ingestion freshness, retention, DB health, and security posture; HyperDX scores alerting (CS-040) and dashboards/sources (CS-041). A lane you do not configure — or one whose endpoint is unreachable this run (e.g. a ClickHouse on a private network you cannot reach yet) — has its categories marked `not-in-scope` and the overall score renormalizes over the lane you do have. When ClickHouse or HyperDX runs **inside a Kubernetes cluster with no external ingress** (common for self-hosted ClickStack), reach it read-only by port-forwarding through your cluster kubeconfig — `kubectl port-forward -n <ns> svc/<clickhouse-svc> :8123` (kubectl assigns a local port) — and set `clickhouse_url`/`hyperdx_url` to `http://127.0.0.1:<local-port>`. This works over a private or JIT-tunnelled cluster the same way `audit-kubernetes` does; see its "Accessing private or JIT-tunnelled clusters" section for establishing the session. A **HyperDX-only** run is fully supported; the audit only stops when *neither* lane is usable.

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ClickHouse | `clickstack.clickhouse_url` (`http(s)://your-clickhouse-host:8123`), `clickstack.clickhouse_user` | `clickstack.clickhouse_password_env` (the variable named there — e.g. `CH_KEY`) | a scoped **read-only** user: `SELECT` on the telemetry database + `system.*` | read-only |
| HyperDX | `clickstack.hyperdx_url` (`http(s)://your-hyperdx-url:8080`) | `clickstack.hyperdx_api_key_env` (the variable named there — e.g. `HDX_API_KEY`) | the per-user **Personal API Access Key** (Settings → API Keys) that reads the external API v2 — `GET /api/v2/alerts`, `/api/v2/dashboards`, `/api/v2/sources` — via `Authorization: Bearer`; **not** the team ingestion key | read-only |
| HyperDX v2 login (optional) | `clickstack.hyperdx_email_env`, `clickstack.hyperdx_password_env` (the variables named there — e.g. `HDX_EMAIL`, `HDX_PASSWORD`) | the login password variable | a HyperDX member account whose UI login can view alerts/dashboards/sources; used once per run for `POST /api/login/password` to obtain the session cookie that scores CS-040/CS-041 on v2.x | read-only reads via session |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

The v2 login pair is a deliberately heavier posture than a read-only key (it is a real user credential) — configure it only when you want the HyperDX categories scored on a v2.x build; without it they are marked `not-in-scope`, never failed. The session cookie lives in a `0600` `mktemp` jar, is deleted on exit, and is never printed or persisted.

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

# Resolve the CURRENT clickstack target from $CFG — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). The audit iterates
# every target (the runner sets SCOUTFLO_TARGET=<label>); output nests under CS_SEG. Connection params
# and the *_env variable NAMES all come from THIS target — never an ambient default.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind); CS_N=$(sh "$TT" "$CFG" clickstack count)
CS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${CS_N:-0}" ]; do [ "$(sh "$TT" "$CFG" clickstack label "$_i")" = "$SCOUTFLO_TARGET" ] && { CS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/${CS_LABEL}"; else CS_SEG="clickstack"; fi
# For every configured *_env key: read the secret with printenv on the VARIABLE NAME the key holds
# (default to the fixed var when the key is absent), presence only, never the value. CH_KEY, HDX_API_KEY,
# HDX_EMAIL, and HDX_PASSWORD default to what clickstack.clickhouse_password_env, clickstack.hyperdx_api_key_env,
# and the optional clickstack.hyperdx_email_env / clickstack.hyperdx_password_env name; references/clickstack-checks.md
# resolves the same variables in every command block, so doctor and the checks agree.
CH_KEY_VAR=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_password_env); [ -n "$CH_KEY_VAR" ] || CH_KEY_VAR="CH_KEY"
CH_KEY=$(printenv "$CH_KEY_VAR" 2>/dev/null || true)
HDX_API_KEY_VAR=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_api_key_env); [ -n "$HDX_API_KEY_VAR" ] || HDX_API_KEY_VAR="HDX_API_KEY"
HDX_API_KEY=$(printenv "$HDX_API_KEY_VAR" 2>/dev/null || true)
HDX_EMAIL_VAR=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_email_env); [ -n "$HDX_EMAIL_VAR" ] || HDX_EMAIL_VAR="HDX_EMAIL"
HDX_EMAIL=$(printenv "$HDX_EMAIL_VAR" 2>/dev/null || true)
HDX_PASSWORD_VAR=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_password_env); [ -n "$HDX_PASSWORD_VAR" ] || HDX_PASSWORD_VAR="HDX_PASSWORD"
HDX_PASSWORD=$(printenv "$HDX_PASSWORD_VAR" 2>/dev/null || true)
echo "clickstack target: ${CS_LABEL} -> ${CS_SEG}/"
if [ "${CS_N:-0}" -lt 1 ]; then
  echo "clickstack block not configured in toolkit.yaml; this audit has nothing to read — configure it or run a different audit"; exit 1
fi
# ClickHouse OR HyperDX — at least one usable lane (a HyperDX-only run is supported). Require the
# ClickHouse password ONLY when clickhouse_url is set for THIS target; a missing password (or no
# clickhouse_url at all) marks the ClickHouse lane not-in-scope rather than aborting the run.
CH_URL_D=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_url)   # ClickHouse for THIS target (enumerator, not ambient)
CH_LANE=0
if [ -n "$CH_URL_D" ]; then
  if [ -n "${CH_KEY:-}" ]; then
    CH_LANE=1
  else
    echo "clickstack target '${CS_LABEL}': clickhouse_url is set but its password variable (${CH_KEY_VAR}, from clickstack.clickhouse_password_env) is not — the ClickHouse lane (telemetry coverage/freshness/retention/DB health/security) is not-in-scope this run; add ${CH_KEY_VAR} via /scoutflo:connect to enable it."
  fi
fi
HDX_LANE=0   # set to 1 by any working HyperDX read path below (Personal API Access Key, or session-login fallback)
if [ -n "${HDX_API_KEY:-}" ]; then
  # HyperDX REST auth (confirmed live + v2.29 source): the PRIMARY path is the per-user Personal
  # API Access Key (Bearer) against the external API v2 (/api/v2/*). Probe BOTH path forms — the
  # direct API-port form and the app-proxy-doubled form (the app strips one leading /api) — and
  # credit in-scope only on a real JSON body. The team ingestion key 401s here (wrong token); the
  # internal /api/* routes are session-only. Session-login is the legacy fallback.
  HDX_URL_D=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_url)   # hyperdx_url for THIS target (enumerator, not ambient)
  if [ -n "$HDX_URL_D" ]; then
    HDX_URL_D="${HDX_URL_D%/}"; _hdx_ok=0
    for _b in "/api/v2" "/api/api/v2"; do
      _hb="$(mktemp)"
      _meta=$(curl -s -o "$_hb" -w '%{http_code} %{content_type}' --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL_D}${_b}/alerts") || _meta="000 -"
      _c="${_meta%% *}"; _ct="${_meta#* }"
      if [ "$_c" = "200" ] && printf '%s' "$_ct" | grep -qi json && jq -e 'type=="array" or has("data") or has("alerts")' "$_hb" >/dev/null 2>&1; then
        echo "HyperDX in scope (Personal API Access Key -> GET ${_b}/alerts -> 200 JSON)"; _hdx_ok=1; HDX_LANE=1; rm -f "$_hb"; break
      fi
      rm -f "$_hb"
    done
    if [ "$_hdx_ok" = "0" ]; then
      if [ -n "${HDX_EMAIL:-}" ] && [ -n "${HDX_PASSWORD:-}" ]; then
        HDX_LANE=1
        echo "HyperDX Personal API Access Key did not authenticate the external API v2 (tried ${HDX_URL_D}/api/v2/alerts and ${HDX_URL_D}/api/api/v2/alerts), but login credentials are set — the audit falls back to a session (POST /api/login/password; cookie in a 0600 mktemp jar, deleted on exit, never printed) and scores CS-040/CS-041"
      else
        echo "HyperDX credential set but no working read path: the Personal API Access Key did not authenticate the external API v2 (tried ${HDX_URL_D}/api/v2/alerts and ${HDX_URL_D}/api/api/v2/alerts). Likely the configured token is the team INGESTION key, not the per-user 'Personal API Access Key' (Settings -> API Keys), or hyperdx_url does not reach the API. CS-040/CS-041 = not-in-scope (not a failure). Optional legacy fallback: set clickstack.hyperdx_email_env + hyperdx_password_env via /scoutflo:connect."
      fi
    fi
  fi
elif [ -n "${HDX_EMAIL:-}" ] && [ -n "${HDX_PASSWORD:-}" ]; then
  HDX_LANE=1
  echo "HyperDX API key not set but login credentials are — the audit scores CS-040/CS-041 via the v2 session login (presence-checked only; never printed)"
else
  echo "no HyperDX credential set (neither clickstack.hyperdx_api_key_env nor hyperdx_email_env + hyperdx_password_env); alerting (CS-040) and dashboards/sources (CS-041) will be marked not-in-scope"
fi
# At least one usable lane, or there is nothing to audit — the only hard stop.
if [ "$CH_LANE" = 0 ] && [ "$HDX_LANE" = 0 ]; then
  echo "clickstack target '${CS_LABEL}': neither lane is usable — no ClickHouse creds/URL AND no working HyperDX credential (Personal API Access Key or login). Nothing to audit; configure ClickHouse (clickhouse_url + password) or a HyperDX Personal API Access Key via /scoutflo:connect."; exit 1
fi
echo "clickstack target '${CS_LABEL}': lanes -> ClickHouse $([ "$CH_LANE" = 1 ] && echo in-scope || echo not-in-scope), HyperDX $([ "$HDX_LANE" = 1 ] && echo in-scope || echo not-in-scope). A not-in-scope lane's categories are blocked and the score renormalizes over the usable lane (CS-007)."
```

Then one cheap live call per configured integration: a ClickHouse `SELECT 1` over HTTP with the read-only session flag, and the open HyperDX `GET /api/health` (200) followed by one authenticated call (the keyed probe, or on v2.x the session-login probe from the helper). Exact commands are in [references/clickstack-checks.md](references/clickstack-checks.md) section 1. `/scoutflo:doctor` runs the same checks standalone.

## Live-safety gate

Before the first real read, print exactly what you are pointed at and compare it to the config. Print host and URL only — never the password or the API key:

```bash
set -eu
# Resolve the CURRENT clickstack target (single block or SCOUTFLO_TARGET-selected list item) via the
# shared enumerator; the host/URL/user come from THIS target's config, never a hand-typed placeholder.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind); CS_N=$(sh "$TT" "$CFG" clickstack count)
CS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${CS_N:-0}" ]; do [ "$(sh "$TT" "$CFG" clickstack label "$_i")" = "$SCOUTFLO_TARGET" ] && { CS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/${CS_LABEL}"; else CS_SEG="clickstack"; fi
CH_URL=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_url)     # clickstack.clickhouse_url
CH_USER=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" clickhouse_user); [ -n "$CH_USER" ] || CH_USER="scoutflo_ro"   # clickstack.clickhouse_user (the connect recipe's scoped RO user; never falls through to the server `default`)
HDX_URL=$(sh "$TT" "$CFG" clickstack get "$CS_IDX" hyperdx_url)       # clickstack.hyperdx_url
echo "clickstack target: ${CS_LABEL} -> ${CS_SEG}/"
echo "ClickHouse HTTP : ${CH_URL}  (user: ${CH_USER})"
echo "HyperDX API     : ${HDX_URL}"
# Confirm this is the ClickStack instance you intend to audit before any read.
case "$CH_URL" in https://*) : ;; *) echo "WARN: ClickHouse HTTP is not TLS (https) — see CS-050" ;; esac
```

If the resolved host or URL differs from what `toolkit.yaml` names, stop and report the mismatch. Never proceed on "probably the right instance". Every command in this skill (and in [references/clickstack-checks.md](references/clickstack-checks.md)) names its target explicitly: ClickHouse reads go through the `chq` helper — `curl` against `${CH_URL}/?readonly=1` with the `X-ClickHouse-User: ${CH_USER}` / `X-ClickHouse-Key: ${CH_KEY}` headers and the SQL as the POST body — and HyperDX reads go through the `hdx_get` helper, which authenticates with `Authorization: Bearer ${HDX_API_KEY}` on builds that issue a REST key (the exact header scheme is confirm-against-your-instance), or on HyperDX v2.x with the optional login credentials via the `connect.sid` session cookie (obtained once per run by `POST /api/login/password`, held in a `0600` `mktemp` jar, deleted on exit, never printed).

## Ground rules

- Config records are discovery metadata; a live query is proof. Credit nothing you did not read live this run.
- Evidence is real command output. An assertion without the query and its observed rows is a suspicion, not a finding.
- API and SQL errors are evidence. A `401`/`403` on the **external API v2** (`/api/v2/alerts`) means the wrong token — the team ingestion key 401s there; use the per-user **Personal API Access Key** (Bearer). A `401` on an **internal** route (`/api/alerts`) is expected — those are session-only; the web app redirects it to `/login` (the "email/password prompt"), which is why the audit reads `/api/v2/*` with the personal key, not `/api/alerts`. A `404` on `/api/v2/*` usually means the path form is wrong for this deployment — try the app-proxy-doubled `/api/api/v2/*` (the helper does this automatically). An `unknown table` error means the wrong database or a renamed table; a `516`/auth error over HTTP means the ClickHouse user or password is wrong. Never convert an upstream error into empty success.
- Never score from object counts. Forty dashboards and two hundred rows prove nothing; credit comes from telemetry a responder could actually act on — recent rows for the critical services, an alert wired to a live receiver.
- A table that exists is not coverage. `otel_logs` present with zero recent rows for `checkout` is a gap, not a pass.
- Alerts are not live until they route to a receiver. A HyperDX alert wired to nothing is the core failure this audit exists to catch (CS-040); "an alert exists" is `configured`, not working.
- Treat HyperDX response field names (`/api/alerts`, `/api/dashboards`, `/api/sources`) as confirm-against-your-instance: read the shape from the live response, never assume `channel`, `webhookUrl`, or `destination`.
- Never print, log, or write a secret: no ClickHouse passwords, HyperDX API keys, HyperDX login passwords or session cookies (the `connect.sid` jar is `mktemp` `0600`, deleted on exit, and never echoed or copied anywhere persistent), webhook URLs, DSNs, or auth headers, in terminal output or in any output file. Capture receiver targets by name/class only.

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

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** services matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** a coverage or freshness gap on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (a short retention TTL on a dev telemetry table is not a prod compliance gap); and apply `cost_sensitivity` to the ordering of the retention (CS-020) and cardinality findings. With no context, run neutral defaults and say so — never invent a business rule.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover services live from the telemetry itself (`SELECT DISTINCT ServiceName FROM otel_logs` and `otel_traces` over a recent window — both `ServiceName` columns are confirmed), note in the report that the list was inferred, and suggest `/scoutflo:map-topology`.

## Estate sizing

Count before judging, and declare the path in the terminal output. This count sizes how much ceremony the run uses; it never feeds the score itself. The objects that drive this audit's cost are the critical services (each gets coverage and freshness queries) and the HyperDX alerts/dashboards (each gets a routing/health check). Backend-level checks (ClickHouse health, retention, security) run once regardless of estate size.

```bash
set -eu
# Resolve the CURRENT clickstack target so sizing (and the report path CS_SEG it declares) tracks the
# target the runner selected with SCOUTFLO_TARGET; a labeled list sizes each target on its own pass.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind); CS_N=$(sh "$TT" "$CFG" clickstack count)
CS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${CS_N:-0}" ]; do [ "$(sh "$TT" "$CFG" clickstack label "$_i")" = "$SCOUTFLO_TARGET" ] && { CS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/${CS_LABEL}"; else CS_SEG="clickstack"; fi
echo "clickstack target: ${CS_LABEL} -> ${CS_SEG}/"
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
# HyperDX alerts (guard the fetch: an auth failure must surface, not silently count as
# zero). Declare the HyperDX helper from references/clickstack-checks.md section 1 first:
# it resolves the auth mode once (REST key, or the v2 session cookie) and sets
# HDX_IN_SCOPE + hdx_get, so sizing and the Phase-7 checks agree on scorability.
ALERTS=0
if [ "${HDX_IN_SCOPE:-0}" = "1" ]; then
  if ! ALERTS="$(hdx_get /api/alerts | jq 'if type=="array" then length elif has("data") then (.data|length) else 0 end' 2>/dev/null)"; then
    echo "WARN: GET /api/alerts failed — alert count unknown; estate sizing is a floor, not the truth."
    ALERTS=0
  fi
fi
TOTAL=$((SERVICES + ALERTS))
path="large"
[ "${TOTAL}" -le "${MEDIUM_MAX_OBJECTS}" ] && path="medium"
[ "${TOTAL}" -le "${SMALL_MAX_OBJECTS}" ] && path="small"
echo "estate: services=${SERVICES} hyperdx_alerts=${ALERTS} scored_objects=${TOTAL} sizing-path=${path}"
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

### Empty / hidden-scope guardrail (CS-007)

The scope checkpoint narrows a *large* estate. This guardrail catches the opposite and more dangerous case — an estate that looks **empty** because you cannot see the data, not because it is not there. It is the ClickStack twin of the audit-gcp/audit-elk visibility trip-wire. After the inventory reads (Phase 2), evaluate:

```bash
set -eu
# Set from the Phase-2 reads: total recent rows across every otel_* table, and
# the HyperDX alert count (or -1 if HyperDX was not in scope / unreachable).
OTEL_ROWS="${OTEL_ROWS:-0}"        # sum of recent-window counts across all otel_* tables
HDX_ALERTS="${HDX_ALERTS:--1}"     # -1 = not queried; >=0 = queried
CH_REACHABLE="${CH_REACHABLE:-1}"  # 1 = SELECT 1 succeeded this run
if [ "${CH_REACHABLE}" -eq 1 ] && [ "${OTEL_ROWS}" -eq 0 ]; then
  echo "[guard] ClickHouse is reachable but ZERO rows across every otel_* table in the recent window — visibility/ingestion gap, NOT a confident 0 (CS-007)"
  echo "[guard] the OTel collector may be down, mis-targeted, or writing to a different database; confirm the ingest path before scoring coverage as failed"
fi
if [ "${HDX_ALERTS}" -eq 0 ]; then
  echo "[guard] HyperDX is reachable but ZERO alerts exist — visibility/coverage gap, NOT a confident 0 (CS-007)"
fi
```

Behavior this enforces:

- **Reachable ClickHouse, zero rows everywhere:** do **not** score CS-010 (Telemetry coverage) and CS-011 (Ingestion freshness) as a confident `0/100`, and do not score them a vacuous high from an empty set. Mark those two categories `blocked` with the visibility-gap reason, **keep ClickHouse health (CS-030) and Security posture (CS-050) included** (they read `system.*` and do not depend on any telemetry existing), renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md), and emit finding **CS-007** naming the gap (collector down / wrong database / wrong instance) and the fix. Keeping DB-health and security included means at least one scored category always remains, which `check-findings.sh` requires.
- **HyperDX reachable, zero alerts:** exclude CS-040 (alerting) and CS-041 (dashboards/sources) as `blocked` with the reason, renormalize, and emit **CS-007** — an instance with no alerts at all is a coverage gap to fix, never a confident zero.
- **Whole lane not-in-scope (HyperDX-only, or ClickHouse-only, run):** when the doctor gate resolved only one usable lane (`CH_LANE`/`HDX_LANE`), mark **every** category of the absent lane `not-in-scope` and score over the lane you have. HyperDX-only (ClickHouse absent, no creds, or its endpoint unreachable — e.g. a private-network ClickHouse): block CS-010/CS-011/CS-020/CS-030/CS-050/CS-060/CS-061, **keep CS-040 (weight 20) + CS-041 (weight 5) scored**, renormalize over those two, and state plainly in the report that ClickHouse was not in scope this run and why (name the enable step: add `clickhouse_url` + its password var, or reach the private endpoint). ClickHouse-only (no working HyperDX credential): block CS-040/CS-041, keep the ClickHouse categories, renormalize. `check-findings.sh`'s "≥1 scored category" invariant always holds because at least one lane is usable (the gate exits when neither is). Never present a not-in-scope lane as a `0` or as end-to-end coverage.
- **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim on a tripped guardrail.

## Phase 2: Read-only inventory

Build the raw picture before judging anything. Commands are in [references/clickstack-checks.md](references/clickstack-checks.md) (the helpers in section 1; the per-surface reads in sections 5, 7, and 8); capture into the run's `raw/` directory, redacted.

- **Tables:** `SELECT name, engine, total_rows, total_bytes, engine_full FROM system.tables WHERE database = currentDatabase() AND (name LIKE 'otel_%' OR name = 'hyperdx_sessions') ORDER BY name` — enumerates the confirmed telemetry tables (`otel_logs`, `otel_traces`, `otel_metrics_gauge`, `otel_metrics_sum`, `otel_metrics_histogram`, `otel_metrics_exponential_histogram`, `otel_metrics_summary`, `hyperdx_sessions`) and their rollup materialized views. The `engine_full` string carries the retention TTL read in Phase 5.
- **Users:** `SELECT name, auth_type, host_ip FROM system.users` — confirmed columns; the security read in Phase 6.
- **HyperDX objects (if in scope):** `GET /api/alerts`, `GET /api/dashboards`, `GET /api/sources` through `hdx_get` (REST key, or the v2 session cookie). The base path `/api/<resource>` is confirmed; the exact resource path and field names are confirm-against-your-instance — read them from the live response.

Record what exists (tables, row/byte counts, users, alerts, dashboards, sources) as inventory, not yet as findings. This is the raw pull that both `findings.json` and `inventory.json` derive from — no new live calls later.

## Phase 3: Tool ownership boundary

ClickStack owns backend telemetry (logs, metrics, traces) and its own alerting via HyperDX. It does **not** own frontend error tracking (that is `/scoutflo:audit-sentry`) or an external paging tree fronted by Alertmanager/PagerDuty routing depth (`/scoutflo:audit-alertmanager`, `/scoutflo:audit-pagerduty`). A signal absent from ClickStack because another tool owns it is a boundary decision, not a gap; record the boundary and audit the owning stack.

## Phase 4: Telemetry coverage (CS-010) and ingestion freshness (CS-011)

For each critical service from Phase 1, query the confirmed columns over a recent window (commands in [references/clickstack-checks.md](references/clickstack-checks.md) section 4):

- **Logs:** `SELECT count() FROM otel_logs WHERE ServiceName = {svc} AND Timestamp >= now() - INTERVAL {RECENT_WINDOW}` — `Timestamp DateTime64(9)` and `ServiceName` are confirmed columns.
- **Traces:** the same shape against `otel_traces` (confirmed `Timestamp`, `ServiceName`).
- **Metrics:** the `otel_metrics_*` tables exist (confirmed names) but their timestamp/service **column names are confirm-against-your-instance** — resolve the DateTime column first with `SELECT name FROM system.columns WHERE table = {metrics_table} AND type LIKE 'DateTime%'`, then `max()` it. Never assume a column name for the metrics tables.

Fill one row per critical service:

| Service | Logs | Traces | Metrics | Freshness | Gap |
| --- | --- | --- | --- | --- | --- |
| checkout | pass | pass | fail | 42s lag | no metrics |

- **CS-010 (Telemetry coverage):** a critical service with recent rows in the signals it should emit is `pass`; a service with zero rows in a signal it should have is a coverage gap. Name affected services in `affected` — "checkout, payments lack trace coverage", never "two services lack traces".
- **CS-011 (Ingestion freshness):** compute `now() - max(Timestamp)` per table that has data. A lag beyond `FRESHNESS_THRESHOLD` (example threshold; tune to your ingest cadence) means the pipeline is stalled even though rows exist — a broken-pipeline finding distinct from "no data". A table with data but a growing max-Timestamp lag is `CS-011`, not `CS-010`.

## Phase 5: Retention (CS-020)

Read the per-table **TTL** from the confirmed read path — `SHOW CREATE TABLE {table}` or the `engine_full` column captured in Phase 2 (commands in section 5). For each `otel_*` telemetry table:

- A deliberate TTL (e.g. `TTL toDateTime(Timestamp) + toIntervalDay(30)`) is `pass` — retention is bounded and intentional.
- **No TTL clause = unbounded retention** — a real cost and compliance finding (`CS-020`), because the table grows without limit.
- A TTL far shorter than the team's stated retention need is a **data-loss** gap — also `CS-020`, distinct severity.

Read retention; never guess it. A missing TTL is a finding, not an assumption of "probably fine".

## Phase 6: ClickHouse health (CS-030, CS-060, CS-061) and security posture (CS-050)

Inspection only, from the confirmed `system.*` tables (commands in sections 6, 6b, and 8). CS-030, CS-060, and CS-061 all score into the **ClickHouse health** category:

- **CS-030 (ClickHouse health):** `system.parts` (active part counts and bytes per table — a runaway part count signals merge pressure), `system.replicas` (replicas in sync, no growing queue), `system.errors` (no spiking error codes — read `name`, `code`, `value`, `last_error_time`), `system.mutations` (none stuck / long-running). A spiking error code or a stuck mutation is a health finding.
- **CS-060 (capacity / days-to-read-only):** disk headroom vs telemetry growth (commands in section 6b) — compute days-to-full from `used_pct` and the observed `otel_*` growth rate. A disk that hits read-only in N days is a high finding; at 243 `NOT_ENOUGH_SPACE` **every** `otel_*` INSERT is rejected at once, not one table.
- **CS-061 (write-path INSERT failures):** collector writes rejected by ClickHouse (section 6b) — fresh `query_log` Insert exceptions or a spiking write-path code (243 disk-full → CS-060, 252 `TOO_MANY_PARTS`, 164 `READONLY`, 201 `QUOTA_EXCEEDED`). This is what distinguishes "collector stopped sending" (CS-011 stale, no insert exceptions) from "collector still sending, ClickHouse rejecting every write" (fresh exceptions).
- **CS-050 (Security posture):** from `system.users` (confirmed columns `name`, `auth_type`, `auth_params`, `host_ip`):
  - The **external `default` user must require a password** — probe it with an unauthenticated `SELECT 1` over HTTP; a `200` means the default user is open (critical), a `401`/auth error means it requires a password (good).
  - **Service users must not sit on `plaintext_password`** — any user with `auth_type = plaintext_password` is a posture finding; the hardened forms are `sha256_password` / `double_sha1_password`.
  - **TLS** on the HTTP/native ports — the audit's own `clickstack.clickhouse_url` should be `https`; a plaintext `http://` endpoint carrying credentials is a finding.
  - **Least-privilege read-only user** for audits — the audit user's grants (`SHOW GRANTS FOR currentUser()`) should be `SELECT`-only; a write-capable audit credential is itself a posture gap.

## Phase 7: HyperDX alerting (CS-040) and dashboards/sources (CS-041)

Via the HyperDX API through `hdx_get` — a REST key where the build issues one, or the v2 session cookie when the optional login credentials engaged (commands in section 7 of the check catalog; run these only when the helper ended with `HDX_IN_SCOPE=1`). The confirmed base path is `/api/<resource>`; treat field names as confirm-against-your-instance and read them from the live response.

- **CS-040 (alerting reaches a human):** `GET /api/alerts`. Alerts must exist **and** route to a live receiver — a webhook, Slack channel, or PagerDuty destination. An alert wired to nothing (no destination, or a placeholder) is the core failure this category exists to catch. Reading the alert config proves it is **configured**; it does not prove delivery — mark delivery `configured`, not `validated-live`, since the controlled test-fire that upgrades it lives in `setup-clickstack`. Capture receiver targets by name/class only, never the webhook URL.
- **CS-041 (dashboards and sources):** `GET /api/dashboards` and `GET /api/sources`. Dashboards should exist for the critical services, and each `source` should be connected to a live ClickHouse table/database (a source pointing at a table that does not exist in `system.tables` is a dead reference). A critical service with no dashboard and no source is a `CS-041` gap.

## Phase 7c: Scoutflo Topology Readiness

Render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only, and report it parallel to the score (never folded into the 0-100). An observation edge this audit verified live — a `SENDS_LOGS_TO`/`SENDS_METRICS_TO`/`SENDS_TRACES_TO` edge to the ClickStack backend that Phase 4 confirmed carries fresh, retained telemetry for that service, or a `MONITORED_BY` edge to the HyperDX/ClickHouse resource — counts toward T4/T6 exactly as the standard defines; do not assert any ClickStack-specific edge attribute or schema key beyond what topology-readiness.md specifies. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action-plan table. If `topology-export.json` or `topology.md` is missing, or describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), render the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); never guess, never a bare "unavailable".

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both the readiness and the assessment-coverage denominators. Category score is `floor(((passed*2)+partial)*50/assessed)` where `assessed = pass + partial + fail` (0 when a category has no assessed checks); overall is the weight-normalized sum over categories with at least one assessed check, rounded down. A whole category with zero assessed checks is moved to `excluded[]`, renormalized out, and stated (this is exactly the CS-007 path). Show assessment coverage separately. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action.

| Category | Weight | ID range |
| --- | ---: | --- |
| Telemetry coverage | 20 | CS-010, CS-007 |
| Ingestion freshness | 15 | CS-011 |
| Retention | 10 | CS-020 |
| ClickHouse health | 20 | CS-030, CS-060, CS-061 |
| HyperDX alerting | 20 | CS-040 |
| Dashboards and sources | 5 | CS-041 |
| Security posture | 10 | CS-050 |

The full check catalog, one permanent ID per check with typical failure severity, is at the top of [references/clickstack-checks.md](references/clickstack-checks.md). IDs are stable; the same defect gets the same ID every run, which is what makes deltas exact. One finding per failed check, with every affected service enumerated in `affected`.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service has fresh logs/traces/metrics, alerts route to a live receiver, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

### Lifecycle, exemptions, and totals

Before writing `findings.json` and `report.md`, since `findings.json` requires the `lifecycle` field on every finding:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in [findings-schema.md](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total checks`). For each active exemption, retain the observed `partial` or `fail` result on the same-ID `checks[]` row, add `suppressed: true` plus `suppression_reason`, and set the suppressed finding's `points_recoverable` to 0. Suppressed checks remain assessed for coverage but are excluded from readiness scoring; the scorecard states the suppressed count.
4. Emit one `checks[]` row for every stable `CS-*` catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `check_set` is the `cksum-v2:N:M` fingerprint that [check-findings.sh](../../report-standard/check-findings.sh) recomputes by folding each check's id+category, each category's name+weight, and the gate — a value the emitted `findings.json` must match exactly.
5. Every finding declares `scoring_scope: "readiness"` and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both (a unique, non-empty subset). A partial/fail/blocked check has a same-ID readiness finding; a blocked check's finding has `status: "blocked"` and `points_recoverable: 0`. **`report_lanes` classification (never changes severity or score):** default to `general-audit` (operational reliability). Add — or also use — `ai-sre-readiness` only when the finding bears on telemetry quality, service identity/naming, topology/ownership context, incident-routing evidence, RCA trust, or action safety, i.e. what trustworthy AI-assisted diagnosis needs. A coverage/naming/routing-evidence finding (CS-010 coverage gaps, CS-011 freshness, CS-040 alert-routing evidence, CS-041 source/dashboard coverage) is typically both; a pure reliability/cost/security-posture finding (CS-020 retention, CS-030/CS-060/CS-061 ClickHouse health, CS-050 posture) is `general-audit` only.

Emit and verify:

```bash
set -eu
# Resolve the CURRENT clickstack target so output lands in the per-target directory: flat
# clickstack/<date>/ for a single block, clickstack/<label>/<date>/ for a labeled list target.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind); CS_N=$(sh "$TT" "$CFG" clickstack count)
CS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${CS_N:-0}" ]; do [ "$(sh "$TT" "$CFG" clickstack label "$_i")" = "$SCOUTFLO_TARGET" ] && { CS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/${CS_LABEL}"; else CS_SEG="clickstack"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${CS_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (scoutflo-findings/v2, with one checks[] row per catalog check, lifecycle set
# per finding, report_lanes, and the estate object from sizing; ".target" is the per-target slug $CS_SEG
# — "clickstack" for a single block, "clickstack/<label>" for a labeled list target — so
# audit-all/correlation/render disambiguate multiple instances), inventory.json (kinds: alert, dashboard,
# source, table, user; ".target" also $CS_SEG), and report.md per the report standard, then verify:
jq -e --arg seg "$CS_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.checks | type == "array" and length > 0)
  and (.findings | type == "array")
  and (.findings | all(has("lifecycle") and (.scoring_scope == "readiness") and (.report_lanes | type == "array" and length > 0)))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog, built from the raw
# pull, redacted. counts.total must reconcile with items; the ## Inventory section IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "$OUT/findings.json" >/dev/null && echo "findings-by-purpose section renders"
grep -qxF '## Findings by purpose' "$OUT/report.md" && echo "findings-by-purpose section present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"

# Append the derived history row after findings/report validation. A same-date
# rerun replaces that date's row instead of duplicating it.
TARGET_DIR="$(dirname "$OUT")"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --arg skill "audit-clickstack" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:$skill, overall:.score.overall, state:.score.state,
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
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard: the one-line score headline, the top fixes by `points_recoverable`, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
# Resolve the CURRENT clickstack target so the brief reads this target's own dated run + history.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
CS_KIND=$(sh "$TT" "$CFG" clickstack kind); CS_N=$(sh "$TT" "$CFG" clickstack count)
CS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${CS_N:-0}" ]; do [ "$(sh "$TT" "$CFG" clickstack label "$_i")" = "$SCOUTFLO_TARGET" ] && { CS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
CS_LABEL=$(sh "$TT" "$CFG" clickstack label "$CS_IDX")
if [ "$CS_KIND" = seq ]; then CS_SEG="clickstack/${CS_LABEL}"; else CS_SEG="clickstack"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${CS_SEG}"
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
    HEAD="audit-clickstack ${RUN_DATE}: readiness unassessed; ${ASSESSMENT}. ${COUNTS}."
  else
    HEAD="audit-clickstack ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}; ${ASSESSMENT}. ${COUNTS}."
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

`report.md`'s `## Inventory` section is the `render-report-viz.sh inventory` render of `inventory.json` — never hand-write it, regenerate it. Build one item per object the audit read, per the [inventory schema](../../report-standard/inventory-schema.md), using these ClickStack kinds:

| kind | source | key `attrs` |
| --- | --- | --- |
| `table` | `system.tables` (`otel_*`) | `rows`, `bytes`, `retention_days` (parsed from the TTL), `engine` |
| `alert` | HyperDX `GET /api/alerts` | `routes_to` = receiver class/name (never the URL); `enabled` |
| `dashboard` | HyperDX `GET /api/dashboards` | `covers` = service, `panels` count |
| `source` | HyperDX `GET /api/sources` | `covers` = the ClickHouse table/db it points at, `connected` |
| `user` | `system.users` | `auth_type`, `host_scope` (never `auth_params` values) |

Every row traces to a raw object read this run; an empty estate is `items: []` with `total: 0`, reported honestly and paired with the CS-007 guardrail. Redaction applies (`secret-redaction.md`): capture by key/name only — never a secret value, webhook URL, phone number, or email.

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" in the report starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| Unbounded or too-short retention on an `otel_*` table (CS-020) | `setup-clickstack#set-retention-ttl` |
| HyperDX alert missing, or wired to no receiver (CS-040) | `setup-clickstack#create-hyperdx-alert`; deep paging-path proof lives in `/scoutflo:audit-alertmanager` |
| No scoped read-only ClickHouse user for audits (CS-050) | `setup-clickstack#create-read-only-user` |
| Plaintext-password user, open default user, or non-TLS endpoint (CS-050) | `setup-clickstack#harden-clickhouse-auth` |
| Missing telemetry / stalled ingestion for a critical service (CS-010, CS-011) | `setup-clickstack` (OTel collector target and pipeline fixes; instrumentation gaps get a named owner) |
| Missing dashboard or dead source reference (CS-041) | `setup-clickstack#create-hyperdx-alert` (dashboards/sources setup lives alongside alerting) |

## Large-path worklist

Runs on the large path only (see [Estate sizing](#estate-sizing)). All state lives under a run-ID-keyed directory `./scoutflo-audits/clickstack/[<label>/]runs/<RUN_ID>/` (the `[<label>/]` segment — the resolved `CS_SEG` — is present only for a labeled multi-target list), not a calendar-date directory, so a run still batching when the UTC date rolls over keeps writing to the same place.

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/clickstack/[<label>/]runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per critical service counted in Estate sizing (for the Phase 4 per-service coverage + freshness checks) and one per HyperDX alert (for the Phase 7 routing check), status `pending` or `done`. A resumed run continues its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the matching checks against just that batch — Phase 4 coverage/freshness for a service row, Phase 7 routing for an alert row. A row is marked `done` **only after its reads succeed**, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

The subscription-wide cheap checks (ClickHouse health CS-030, retention CS-020, security posture CS-050, and the CS-007 guardrail) are single passes; they run once per run regardless of path and are never batched.

## Common Failure Modes

All thresholds and windows named in the checks (`RECENT_WINDOW`, `FRESHNESS_THRESHOLD`) are example values; tune them to your traffic and retention before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| A table exists, so coverage scored `pass` | Coverage is recent rows for the service, not table presence; query `count()` over `RECENT_WINDOW` per critical service |
| Stalled pipeline read as "no data" | Distinguish zero rows (CS-010) from rows present but a growing `max(Timestamp)` lag (CS-011) |
| Invented a metrics-table column name | Only `otel_logs`/`otel_traces` columns are confirmed; resolve `otel_metrics_*` columns from `system.columns` before querying |
| `/api/v1/*` used against HyperDX | The confirmed API base is `/api/<resource>`; `/api/v1/*` returns 404 |
| A HyperDX `401` read as a wrong API key or hard fail | Read `/api/v2/*` with the per-user Personal API Access Key (Bearer); a 401 there = the ingestion key was used (wrong token) → point at the Personal API Access Key; an internal `/api/*` 401 is the session-only route (expected). The helper probes both `/api/v2` and `/api/api/v2`, then falls back to the optional session login, else marks CS-040/CS-041 `not-in-scope` — never a confident fail, never header-variant looping |
| Session cookie printed or persisted | The `connect.sid` jar is `mktemp` `chmod 600`, deleted on exit; it never appears in terminal output, evidence, `raw/`, the report, or any file that outlives the run |
| HyperDX field names assumed | Read `/api/alerts`, `/api/dashboards`, `/api/sources` shapes from the live response; treat field names as confirm-against-your-instance |
| Alert counted as working because it exists | An alert wired to no receiver is the CS-040 failure; mark delivery `configured`, not validated-live |
| Retention assumed instead of read | Read the per-table TTL from `SHOW CREATE TABLE` / `engine_full`; a missing TTL is unbounded retention (CS-020), not "probably fine" |
| Plaintext-password user passed silently | Read `auth_type` from `system.users`; `plaintext_password` is a CS-050 posture finding |
| Open default user missed | Probe the external `default` user with an unauthenticated `SELECT 1`; a 200 is critical |
| Empty ClickHouse scored a confident 0 | Reachable ClickHouse with zero rows everywhere trips CS-007 — block coverage/freshness, keep health+security, renormalize, never a confident 0/100 |
| A mutating statement slipped into the audit | Every ClickHouse call is a `SELECT`/`SHOW` with `readonly=1`; `INSERT`/`ALTER`/`CREATE`/`DROP` belong to setup-clickstack |
| Secret leaked into evidence | Record receiver class and user names only; never the API key, ClickHouse password, or webhook URL |
