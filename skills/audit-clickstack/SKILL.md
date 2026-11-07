---
name: audit-clickstack
description: Read-only scored audit of a ClickStack observability deployment (ClickHouse + HyperDX + OpenTelemetry): telemetry-table coverage, ingestion freshness, per-table retention TTL, ClickHouse database health, HyperDX alerting and dashboards/sources, and security posture; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring ClickStack, ClickHouse observability, HyperDX alerts or dashboards, otel_logs/otel_traces/otel_metrics tables, telemetry ingestion freshness, or ClickHouse retention/TTL. Do not use for Grafana-fronted LGTM/VictoriaMetrics stacks (use audit-lgtm), for Elasticsearch/Kibana (use audit-elk), to prove an Alertmanager page reaches a human (use audit-alertmanager), or to change ClickHouse/HyperDX (use setup-clickstack).
---

# audit-clickstack

Scored, read-only audit of a **ClickStack** deployment — **ClickHouse** (the columnar telemetry store), **HyperDX** (search, dashboards, and alerting UI/API), and the **OpenTelemetry** collector that feeds them. It answers one question: when something breaks tonight, is the telemetry for your critical services actually landing in ClickHouse, is it fresh and retained deliberately, is the database healthy, and is each required HyperDX alert connected to an evidenced receiver? Human receipt remains a separate proof.

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

## Doctor gate and Live-safety gate

Requirements. Configure only the blocks that exist in your environment; delete the rest from `~/.scoutflo/toolkit.yaml`. Configure **ClickHouse OR HyperDX — at least one** (both when you have both). ClickHouse scores telemetry coverage, ingestion freshness, retention, DB health, and security posture; HyperDX scores alerting (CS-040) and dashboards/sources (CS-041). A lane you do not configure — or an inaccessible configured lane — must carry its actual evidence state: documented inapplicability is `not-in-scope`, while an unreadable configured lane is `blocked` and the overall score renormalizes over the lane you do have. When ClickHouse or HyperDX runs **inside a Kubernetes cluster with no external ingress** (common for self-hosted ClickStack), reach it read-only by port-forwarding through your cluster kubeconfig — `kubectl port-forward -n <ns> svc/<clickhouse-svc> :8123` (kubectl assigns a local port) — and set `clickhouse_url`/`hyperdx_url` to `http://127.0.0.1:<local-port>`. This works over a private or JIT-tunnelled cluster the same way `audit-kubernetes` does; see its "Accessing private or JIT-tunnelled clusters" section for establishing the session. A **HyperDX-only** run is fully supported; the audit only stops when *neither* lane is usable.

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| ClickHouse | `clickstack.clickhouse_url` (`http(s)://your-clickhouse-host:8123`), `clickstack.clickhouse_user` | `clickstack.clickhouse_password_env` (the variable named there — e.g. `CH_KEY`) | a scoped **read-only** user: `SELECT` on the telemetry database + `system.*` | read-only |
| HyperDX | `clickstack.hyperdx_url` (`http(s)://your-hyperdx-url:8080`) | `clickstack.hyperdx_api_key_env` (the variable named there — e.g. `HDX_API_KEY`) | the per-user **Personal API Access Key** (Settings → API Keys) that reads the external API v2 — `GET /api/v2/alerts`, `/api/v2/dashboards`, `/api/v2/sources` — via `Authorization: Bearer`; **not** the team ingestion key | read-only |
| HyperDX v2 login (optional) | `clickstack.hyperdx_email_env`, `clickstack.hyperdx_password_env` (the variables named there — e.g. `HDX_EMAIL`, `HDX_PASSWORD`) | the login password variable | a HyperDX member account whose UI login can view alerts/dashboards/sources; used once per run for `POST /api/login/password` to obtain the session cookie that scores CS-040/CS-041 on v2.x | read-only reads via session |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

The v2 login pair is a deliberately heavier posture than a read-only key (it is a real user credential) — configure it only when you want the HyperDX categories scored on a v2.x build; without a usable read credential they are `blocked`. The recipe keeps session cookies in memory only, never in reports or evidence.

Before any read, resolve the selected target and compare its host with the intended environment. The fixed context rejects an unselected multi-target list, duplicate selected labels and missing named credentials. It imports only selected credentials from the layered local store, including assignment-only env files.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
# Print hostnames only; URL paths and query strings may contain credentials.
python3 - "$CS_SEG" "$CH_URL" "$HDX_URL" <<'PYHOST'
import sys,urllib.parse
print('Selected target:',sys.argv[1])
for name,url in zip(('ClickHouse','HyperDX'),sys.argv[2:]):
    if not url: print(name+': not configured'); continue
    parsed=urllib.parse.urlsplit(url)
    if parsed.scheme not in ('http','https') or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise SystemExit('Blocked: invalid or credential-bearing connection URL')
    print(name+': '+parsed.scheme+'://'+parsed.hostname)
PYHOST
```

If this is the wrong target, stop before the following probe. Never choose another label after a denial. Run `/scoutflo:doctor`, then one cheap authenticated probe per configured lane:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
if [ -n "$CH_URL" ]; then
  ( . "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/clickhouse-context.sh"; chq "SELECT 1" ) || echo 'ClickHouse lane blocked: repair selected read access'
fi
if [ -n "$HDX_URL" ]; then
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/collect-hyperdx.sh" --probe || echo 'HyperDX lane blocked: repair selected read access'
fi
```

A denied, missing or malformed configured lane is `blocked`; retain its assessment denominator. Continue independent readable lanes. If both are blocked, emit an honest fully unassessed report with the access unlocks. An intentionally absent lane is `not-in-scope` only with a C23 declaration. Missing credentials alone never justify that exclusion.

The ClickHouse helper resolves the selected target in every shell, issues only bounded read queries and projects before stdout. Its read-only probe receipt is bound to the target and credential generation; repeated fresh shells reuse the observed mode for at most 30 minutes. HyperDX API-key and explicit legacy-session modes are separate. A named but unset key blocks; it never switches to a login credential.

## Ground rules

- Config records are discovery metadata; a live query is proof. Credit nothing you did not read live this run.
- Evidence is real command output. An assertion without the query and its observed rows is a suspicion, not a finding.
- API and SQL errors are evidence. A `401`/`403` on the **external API v2** (`/api/v2/alerts`) means authentication/authorization is unavailable; a wrong ingestion key is one possible cause, not a diagnosis proven by status alone. Verify the selected per-user **Personal API Access Key** (Bearer). A `401` on an **internal** route (`/api/alerts`) is expected — those are session-only; the web app redirects it to `/login` (the "email/password prompt"), which is why the audit reads `/api/v2/*` with the personal key, not `/api/alerts`. A `404` on `/api/v2/*` usually means the path form is wrong for this deployment — try the app-proxy-doubled `/api/api/v2/*` (the helper does this automatically). An `unknown table` error means the wrong database or a renamed table; a recognizable `516`/auth error means the selected authentication was denied; verify account, password and provider policy without guessing the cause. Never convert an upstream error into empty success.
- Never score from object counts. Forty dashboards and two hundred rows prove nothing; credit comes from telemetry a responder could actually act on — recent rows for the critical services, an alert wired to a live receiver.
- A table that exists is not coverage. `otel_logs` present with zero recent rows for `checkout` is a gap, not a pass.
- Alerts are not live until they route to a receiver. A HyperDX alert wired to nothing is the core failure this audit exists to catch (CS-040); "an alert exists" is `configured`, not working.
- Treat HyperDX response field names (`/api/alerts`, `/api/dashboards`, `/api/sources`) as confirm-against-your-instance: read the shape from the live response, never assume `channel`, `webhookUrl`, or `destination`.
- Never print, log, or write a secret: no ClickHouse passwords, HyperDX API keys, HyperDX login passwords or session cookies (the session cookie stays in process memory and is never written), webhook URLs, DSNs, or auth headers, in terminal output or in any output file. Capture receiver targets by name/class only.

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

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** services matched by an exclusion (record them `not-in-scope` with `not_in_scope_reason: "by-design"` (the exclusion is your declaration) and the exclusion as the `reason`, never a fail); **escalate** a coverage or freshness gap on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (a short retention TTL on a dev telemetry table is not a prod compliance gap); and apply `cost_sensitivity` to the ordering of the retention (CS-020) and cardinality findings. With no context, run neutral defaults and say so — never invent a business rule.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is your critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. If it does not exist, discover services live from the telemetry itself (`SELECT DISTINCT ServiceName FROM otel_logs` and `otel_traces` over a recent window — both `ServiceName` columns are confirmed), note in the report that the list was inferred, and suggest `/scoutflo:map-topology`.

## Estate sizing

Count before judging, and declare the path in the terminal output. This count sizes how much ceremony the run uses; it never feeds the score itself. The objects that drive this audit's cost are the critical services (each gets coverage and freshness queries) and the HyperDX alerts/dashboards (each gets a routing/health check). Backend-level checks (ClickHouse health, retention, security) run once regardless of estate size.

First perform bounded discovery, then scope the detailed reads. The fixed HyperDX sizing mode reads only the first alert, dashboard and source page; it never calls a lower bound a complete estate. Service discovery and unknown pages keep sizing provisional. A missing topology file is unknown service scope, never zero services.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
if [ -n "$HDX_URL" ]; then
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/collect-hyperdx.sh" --size
else
  mkdir -p "$CS_OUT/raw"
  jq -n --arg target "$CS_SEG" --arg at "$(date -u +%FT%TZ)" '{schema:"scoutflo-clickstack-sizing/v1",target:$target,observed_at:$at,objects_lower_bound:0,complete:false,path:"large",reason:"service-and-table-scope-not-yet-enumerated"}' > "$CS_OUT/raw/estate-sizing.json"
fi
```

Record the observed lower bound and unresolved populations; do not invent counts. Once the target-bound service/table inventory and all selected API populations are complete, name the scale path using declared thresholds (examples: small ≤100, medium ≤500, large >500). Until then use the conservative large path. Complete discovery updates the count before final reporting.

### Scope checkpoint

Re-resolve the target and read the current sizing receipt; no variable from a previous shell is required. Scope before detailed processing even when the total is unknown.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
SIZE="$CS_OUT/raw/estate-sizing.json"
jq -e --arg t "$CS_SEG" --arg date "$CS_RUN_DATE" '.target==$t and (.observed_at|startswith($date)) and (.objects_lower_bound|type=="number")' "$SIZE" >/dev/null || { echo 'Run current target sizing first'; exit 1; }
TOTAL=$(jq '.objects_lower_bound' "$SIZE")
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"
printf 'Selected assessment scope: %s; observed objects: %s (lower bound)\n' "$SCOPE" "$TOTAL"
if [ "$TOTAL" -ge 501 ] || [ "$(jq -r '.complete' "$SIZE")" != true ]; then
  cli_pause_before_audit "$TOTAL"
  cli_prompt_exclude_services
fi
```

Use the [durable worklist](#large-path-worklist) for the scoped service, alert, dashboard and source assessments. Retain scoped-out and unreadable objects in the coverage accounting.

### Empty / hidden-scope guardrail (CS-007)

The scope checkpoint narrows a *large* estate. This guardrail catches the opposite and more dangerous case — an estate that looks **empty** because you cannot see the data, not because it is not there. It is the ClickStack twin of the audit-gcp/audit-elk visibility trip-wire. After the inventory reads (Phase 2), evaluate:

Use only successful, current, target-bound census receipts from section 3 of the check catalog. Missing receipts or denied tables are unknown. Never default a reachability flag to true or an unread row count to zero. All returned telemetry tables must be accounted for before declaring the whole backend empty; a configured database with unenumerated tables cannot establish that fact.

Behavior this enforces:

- **Reachable ClickHouse, zero rows everywhere:** do **not** score CS-010 (Telemetry coverage) and CS-011 (Ingestion freshness) as a confident `0/100`, and do not score them a vacuous high from an empty set. Mark those two categories `blocked` with the visibility-gap reason, **keep ClickHouse health (CS-030) and Security posture (CS-050) included** (they read `system.*` and do not depend on any telemetry existing), renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md), and emit finding **CS-007** naming the gap (collector down / wrong database / wrong instance) and the fix. Assess independent checks only when their own reads succeed; all can be blocked.
- **HyperDX complete, zero alerts:** CS-041 remains assessable from its own data. A declared local detection requirement with no implementation produces CS-007; a documented external owner is evaluated under C23 (`by-design` only from declared resource intent; `covered-elsewhere` only from verified current equivalent coverage). Without intent, CS-040 is `blocked` pending that input, not an inferred failure or pass.
- **Unavailable lane:** inaccessible/configured resources are `blocked`; an intentionally absent lane can be `not-in-scope` only with a valid C23 reason and evidence. A fully blocked run is supported (`overall: null`, state `unassessed`); there is no requirement to fabricate one scored category.
- **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim on a tripped guardrail.

## Phase 2: Read-only inventory

Build a safe projected inventory before judging anything. Commands are in [references/clickstack-checks.md](references/clickstack-checks.md) (the helpers in section 1; the per-surface reads in sections 5, 7, and 8); capture only helper projections into the run's `raw/` directory. Run the full bounded HyperDX collector now, after the scope checkpoint.

- **Tables:** `SELECT name, engine, total_rows, total_bytes, create_table_query FROM system.tables WHERE database = currentDatabase() AND (name LIKE 'otel_%' OR name = 'hyperdx_sessions') ORDER BY name` — enumerates the confirmed telemetry tables (`otel_logs`, `otel_traces`, `otel_metrics_gauge`, `otel_metrics_sum`, `otel_metrics_histogram`, `otel_metrics_exponential_histogram`, `otel_metrics_summary`, `hyperdx_sessions`) and their rollup materialized views. The DDL is parsed in memory into the safe `ttl` projection for Phase 5; never persist the raw string.
- **Users:** `SELECT name, auth_type, host_ip FROM system.users` — confirmed columns; the security read in Phase 6.
- **HyperDX objects:** consume the current `raw/hyperdx-configuration.json` from the fixed collector. It contains independently scoped alerts, webhooks, dashboards, sources and connections, with safe ID joins and collection reasons. Retain observed objects in inventory; absent totals or denied reads stay partial/blocked. Do not repeat unprojected API calls later.

Treat `_scoutflo.unknown_fields`, `_scoutflo.omitted_fields` and `ttl.assessment=unknown` as evidence gaps. Never coerce a projected null to zero, no TTL or an absent receiver. Record what exists (tables, row/byte counts, users, alerts, dashboards, sources) as inventory, not yet as findings. This is the raw pull that both `findings.json` and `inventory.json` derive from — no new live calls later.

## Phase 3: Tool ownership boundary

ClickStack owns backend telemetry (logs, metrics, traces) and its own alerting via HyperDX. It does **not** own frontend error tracking (that is `/scoutflo:audit-sentry`) or an external paging tree fronted by Alertmanager/PagerDuty routing depth (`/scoutflo:audit-alertmanager`, `/scoutflo:audit-pagerduty`). A signal absent from ClickStack because another tool owns it is a boundary decision, not a gap; record the boundary and audit the owning stack.

## Phase 4: Telemetry coverage (CS-010) and ingestion freshness (CS-011)

For each critical service from Phase 1, query the confirmed columns over a recent window (commands in [references/clickstack-checks.md](references/clickstack-checks.md) section 4):

- **Logs:** `SELECT count() FROM otel_logs WHERE ServiceName = {svc} AND Timestamp >= now() - INTERVAL {RECENT_MINUTES} MINUTE` — `Timestamp DateTime64(9)` and `ServiceName` are confirmed columns.
- **Traces:** the same shape against `otel_traces` (confirmed `Timestamp`, `ServiceName`).
- **Metrics:** the `otel_metrics_*` tables exist (confirmed names) but their timestamp/service **column names are confirm-against-your-instance** — resolve the DateTime column first with `SELECT name FROM system.columns WHERE table = {metrics_table} AND type LIKE 'DateTime%'`, and the exact service selector, then query the required metric kinds per service and recent window. A lifetime table count is inventory only. If a timestamp or service selector is unverified, the affected metrics check is blocked. Never assume a column name for the metrics tables.

Fill one row per critical service:

| Service | Logs | Traces | Metrics | Freshness | Gap |
| --- | --- | --- | --- | --- | --- |
| checkout | pass | pass | fail | 42s lag | no metrics |

- **CS-010 (Telemetry coverage):** a critical service with recent rows in the signals it should emit is `pass`; a service with zero rows in a signal it should have is a coverage gap. Name affected services in `affected` — "checkout, payments lack trace coverage", never "two services lack traces".
- **CS-011 (Ingestion freshness):** compute `now() - max(Timestamp)` per critical service and required signal, including the target/cluster scope. A lag beyond `FRESHNESS_THRESHOLD` (example threshold; tune to your ingest cadence) means the pipeline is stalled even though rows exist — a broken-pipeline finding distinct from "no data". A table with data but a growing max-Timestamp lag is `CS-011`, not `CS-010`.

## Phase 5: Retention (CS-020)

Read the per-table **TTL** from the confirmed read path — `SHOW CREATE TABLE {table}` or the `create_table_query` projection captured in Phase 2 (commands in section 5). For each `otel_*` telemetry table:

- A recognized TTL can pass only after its interval matches the declared retention requirement. Presence alone does not establish intent; an unsupported expression is blocked pending an attended safe interpretation.
- **No TTL clause = no automatic table TTL**. Compare the declared retention requirement and any verified external lifecycle owner before finding an unbounded-retention risk; TTL absence does not prove indefinite actual growth.
- A TTL far shorter than the team's stated retention need is a **data-loss** gap — also `CS-020`, distinct severity.

Read retention and its ownership requirement. A missing TTL is an observation until the requirement or a verified lifecycle gap supports a finding; unknown intent stays blocked.

## Phase 6: ClickHouse health (CS-030, CS-060, CS-061) and security posture (CS-050)

Inspection only, from the confirmed `system.*` tables (commands in sections 6, 6b, and 8). CS-030, CS-060, and CS-061 all score into the **ClickHouse health** category:

- **CS-030 (ClickHouse health):** `system.parts` (active part counts and bytes per table — a runaway part count signals merge pressure), `system.replicas` (replicas in sync, no growing queue), `system.errors` (no spiking error codes — read `name`, `code`, `value`, `last_error_time`), `system.mutations` (none stuck / long-running). A measured code-count delta or an evidenced stuck mutation supports a health finding; a cumulative counter alone does not measure a spike.
- **CS-060 (capacity):** assess measured disk headroom against a declared minimum. A forecast needs comparable time-separated measurements for that exact disk, positive net growth, elapsed time and retention/merge assumptions. Retained bytes divided by part age is data density, not growth; never derive days-to-full from it. A disk-full error applies to the affected write path, not automatically every disk/table.
- **CS-061 (write-path INSERT failures):** require recent `query_log` Insert exceptions or equivalent observed collector write failures. `system.errors` is cumulative context; a recent timestamp does not measure a spike. The audit's read-only probes can add code164 read errors, so they never establish rejected INSERTs. Report exact code, affected table/disk where evidenced, count and window. No query-log access means the write-path conclusion is blocked, not healthy.
- **CS-050 (Security posture):** from `system.users` (confirmed columns `name`, `auth_type`, `auth_params`, `host_ip`):
  - The **external `default` user must require a password** — probe it with an unauthenticated `SELECT 1` over HTTP; only a successful response with the exact ClickHouse result `1` proves access. A recognizable ClickHouse auth denial proves this unauthenticated path is denied; proxy HTML or a generic 403 is unverified.
  - **Service users must not sit on `plaintext_password`** — any user with `auth_type = plaintext_password` is a posture finding; the hardened forms are `sha256_password` / `double_sha1_password`.
  - **TLS** on the HTTP/native ports — the audit's own `clickstack.clickhouse_url` should be `https`; a remote plaintext endpoint carrying credentials needs a transport-security finding. A verified loopback port-forward/JIT tunnel is a separate transport boundary; record the protected hop and assess the remote listener independently.
  - **Least-privilege read-only user** for audits — the audit user's grants (the selected principal’s `SHOW GRANTS`) should be `SELECT`-only; a write-capable audit credential is itself a posture gap.

## Phase 7: HyperDX alerting (CS-040) and dashboards/sources (CS-041)

Follow [HyperDX source evidence](references/hyperdx-source-evidence.md) and section 7 of the check catalog. CS-040 checks exact receiver references per notification channel, explicit activation and safe destination classification. It does not claim a human received a page. CS-041 independently joins dashboards → sources → connections. Before using a ClickHouse read for data proof, an attended safe comparison must confirm the exact connection endpoint, database and table; otherwise data binding stays blocked. After that, it verifies useful/current data through the owning read lane; zero alerts never disables it.

The collector emits `alert-source-evidence.json` and its capture receipt beside the projection. These are source-read evidence, not downstream verification. Use [On-Call source evidence](../audit-splunk-oncall/references/source-evidence.md) for target/generation-bound joins after exact route evidence is available. Do not hash, print or store protected incoming-alert URLs in either packet. For alert fatigue, use the standalone configuration tier and label incident/fire history unavailable unless separately measured.

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

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service has fresh logs/traces/metrics, required alert routes have current downstream and human-receipt evidence, and no category was excluded. Configured IDs or a successful provider read alone cannot satisfy the delivery condition. Below the gate, write "good base coverage", never "end to end".

### Lifecycle, exemptions, and totals

Before writing `findings.json` and `report.md`, since `findings.json` requires the `lifecycle` field on every finding:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in [findings-schema.md](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total checks`). For each active exemption, retain the observed `partial` or `fail` result on the same-ID `checks[]` row, add `suppressed: true` plus `suppression_reason`, and set the suppressed finding's `points_recoverable` to 0. Suppressed checks remain assessed for coverage but are excluded from readiness scoring; the scorecard states the suppressed count.
4. Emit one `checks[]` row for every stable `CS-*` catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `check_set` is the `cksum-v2:N:M` fingerprint that [check-findings.sh](../../report-standard/check-findings.sh) recomputes by folding each check's id+category, each category's name+weight, and the gate — a value the emitted `findings.json` must match exactly. Every `not-in-scope` row additionally carries `not_in_scope_reason` — one of `inapplicable` (nothing of the kind exists on this target), `target-gone` (proven decommissioned), `by-design` (you declared it) or `covered-elsewhere` (verified on the plane that owns it) — per [not-in-scope-reasons.md](../../report-standard/not-in-scope-reasons.md). A row you cannot evidence is `blocked`, not `not-in-scope`.
5. Every finding declares `scoring_scope: "readiness"` and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both (a unique, non-empty subset). A partial/fail/blocked check has a same-ID readiness finding; a blocked check's finding has `status: "blocked"` and `points_recoverable: 0`. **`report_lanes` classification (never changes severity or score):** default to `general-audit` (operational reliability). Add — or also use — `ai-sre-readiness` only when the finding bears on telemetry quality, service identity/naming, topology/ownership context, incident-routing evidence, RCA trust, or action safety, i.e. what trustworthy AI-assisted diagnosis needs. A coverage/naming/routing-evidence finding (CS-010 coverage gaps, CS-011 freshness, CS-040 alert-routing evidence, CS-041 source/dashboard coverage) is typically both; a pure reliability/cost/security-posture finding (CS-020 retention, CS-030/CS-060/CS-061 ClickHouse health, CS-050 posture) is `general-audit` only.

Emit and verify:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
RUN_DATE="$CS_RUN_DATE"
OUT="$CS_OUT"
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
# An inaccessible target can still produce an honest fully-unassessed report.
# Every assessed run, including tiny one-batch scopes, must finish its worklist.
if jq -e '.score.overall==null and .score.state=="unassessed" and all(.checks[]; .result=="blocked" or .result=="not-in-scope")' "$OUT/findings.json" >/dev/null; then
  echo 'No assessed checks: retain capture failures and exact unlocks in the report'
else
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/assessment-worklist.sh" check
fi
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
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/history.sh"
ls -l "$OUT"
```

Compute the delta against the previous run date per the [report standard](../../report-standard/README.md); on the first run state "first run, no delta". After the report is written, close with the run-completion message per the report standard: the one-line score headline, the top fixes by `points_recoverable`, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then send the Slack brief, titles only, never evidence values:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${CS_SEG}"
RUN_DATE="$CS_RUN_DATE"
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
    DELTA="$(jq -r '[.findings[] | .lifecycle // "new"] | group_by(.) | map("\(length) \(.[0])") | join(", ")' "$OUT/findings.json")"
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

Emit canonical `collection` metadata and qualified `service_identity`/`identity_evidence` or finding `correlation_bindings` only from exact scoped evidence per [service-evidence.md](../../report-standard/service-evidence.md). A display name, source ID or regional DNS name alone cannot authorize a cross-tool service join. Preserve unknown activation as null.

Every row traces to a projected object read this run; an empty estate is `items: []` with `total: 0`, reported honestly and paired with the CS-007 guardrail. Redaction applies (`secret-redaction.md`): capture by key/name only — never a secret value, webhook URL, phone number, or email.

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" in the report starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| Unbounded or too-short retention on an `otel_*` table (CS-020) | `setup-clickstack#set-retention-ttl` |
| HyperDX alert missing, or wired to no receiver (CS-040) | `setup-clickstack#create-hyperdx-alert`; deep paging-path proof lives in the owning paging audit, including `/scoutflo:audit-splunk-oncall` |
| No scoped read-only ClickHouse user for audits (CS-050) | `setup-clickstack#create-read-only-user` |
| Plaintext-password user, open default user, or non-TLS endpoint (CS-050) | `setup-clickstack#harden-clickhouse-auth` |
| Missing telemetry / stalled ingestion for a critical service (CS-010, CS-011) | `setup-clickstack` (OTel collector target and pipeline fixes; instrumentation gaps get a named owner) |
| Missing dashboard or dead source reference (CS-041) | `setup-clickstack#create-dashboard-source` (bounded plan or named owner when the API shape is unverified) |

## Large-path worklist

Use the local assessment helper on every assessed path (see [Estate sizing](#estate-sizing)); a tiny scope takes one batch. It makes no provider calls. It tracks **judgments**, separately from whether the provider returned a complete collection. A blocked check can have a completed assessment; it remains blocked in findings and scoring. A fully unassessed report after failed access does not require inventing a successful capture or worklist; the output gate checks that exception explicitly.

First write `raw/assessment-scope.json` in the selected dated output directory with exactly `target` (the resolved `CS_SEG`), `observed_at` (whole-second UTC), `declared_by` (a safe operator identifier), `evidence_ref` (a local `.md` or `.json` file under that directory), `services` (the distinct service identifiers the operator declared in scope), and `capture_refs` (distinct `raw/...json` or `raw/...md` paths to every safe read projection and attended evidence file used by the assessment). Capture references are required when ClickHouse is configured; save its projected coverage/freshness reads before claiming a batch. Never include raw SQL responses or secret-bearing files. Preserve expected-but-unobserved services; an active-services query cannot define the coverage denominator. The evidence file records that scope declaration. Safe identifiers use letters, digits, `_`, `.`, `:`, or `-`; exclude credential values and credential-shaped strings.

When HyperDX is configured, the helper also requires `raw/hyperdx-configuration.json` from the current collector. It builds one row per scoped service and per observed alert, dashboard and source. Partial or blocked HyperDX collections stay partial or blocked even after every observed object has been assessed. The scope and capture must match the selected target and run date and be at most 24 hours old. The helper hashes each declared capture file as well as the scope proof and HyperDX projection. Finish collection before batching judgments; a new or changed capture starts a new assessment binding.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
# Prepare the declared scope and its evidence file as described above, then claim.
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/assessment-worklist.sh" init
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/assessment-worklist.sh" claim "${BATCH_SIZE:-50}"
```

The returned batch includes `run_id`, `run_date`, `binding_sha256`, and exact `objects` (`kind` and `id`). Assess service rows with CS-010/011, alert rows with CS-040, and dashboard/source rows with CS-041. Save each completed batch to a distinct proof JSON filename inside the same dated output directory; never overwrite a prior batch proof. The file contains exactly `run_id`, `binding_sha256`, `objects` (the entire claimed batch), and `checks` (distinct `{"id":"CS-010","result":"blocked"}` entries for the applicable checks). Supported results are `pass`, `partial`, `fail`, `blocked`, and `not-in-scope`. Record the actual evidence and reasoning in the audit; a receipt packages that completed assessment and cannot establish missing provider facts.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
: "${CS_ASSESSMENT_PROOF:?Set the path to the completed, exact batch proof JSON}"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/assessment-worklist.sh" done "$CS_ASSESSMENT_PROOF"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/assessment-worklist.sh" claim "${BATCH_SIZE:-50}"
```

Repeat until the returned objects are empty, then run `assessment-worklist.sh check` before assembling the complete report. It requires every object assessed and rechecks all proof hashes. A missing or edited proof, dropped worklist row, incomplete batch, changed source capture, target, URL, or selected credential generation cannot reuse the old completion. Keep partial assessment output in the run directory and preserve the previous complete report.

State lives under `<target>/runs/<run_id>/clickstack-worklist.json`, with private credential bindings and an operating-system-owned lock. An interrupted claim returns the same unfinished objects; no age-only lock reclamation is permitted. To resume an unchanged capture across UTC midnight, explicitly set `SCOUTFLO_CLICKSTACK_RUN_DATE=YYYY-MM-DD` to its original date. The 24-hour capture limit still applies. New or expired captures require fresh assessments; a run ID does not freeze live provider state across days.

The target-wide health CS-030, retention CS-020, security CS-050 and guardrail CS-007 checks run once per capture and are assessed outside the per-object worklist.

## Common Failure Modes

All thresholds and windows named in the checks (`RECENT_MINUTES`, `FRESHNESS_THRESHOLD`) are example values; tune them to your traffic and retention before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| A table exists, so coverage scored `pass` | Coverage is recent rows for the service, not table presence; query `count()` over `RECENT_MINUTES` per critical service |
| Stalled pipeline read as "no data" | Distinguish zero rows (CS-010) from rows present but a growing `max(Timestamp)` lag (CS-011) |
| Invented a metrics-table column name | Only `otel_logs`/`otel_traces` columns are confirmed; resolve `otel_metrics_*` columns from `system.columns` before querying |
| `/api/v1/*` used against HyperDX | Use the documented external `/api/v2/<resource>` with a personal API key; legacy `/api/<resource>` is a separate explicit session mode |
| A HyperDX `401` read as a wrong API key or hard fail | Read `/api/v2/*` with the per-user Personal API Access Key (Bearer); a 401 there leaves authentication/authorization unavailable; verify the selected key type and scopes without inferring the cause from status; an internal `/api/*` 401 is the session-only route (expected). The collector resolves the documented external prefix; a selected key denial blocks. Explicit legacy session configuration is supported when no API key is selected — never a confident fail, never header-variant looping |
| Session cookie printed or persisted | The `connect.sid` cookie remains in process memory and is never persisted |
| HyperDX field names assumed | Read `/api/alerts`, `/api/dashboards`, `/api/sources` shapes from the live response; treat field names as confirm-against-your-instance |
| Alert counted as working because it exists | An alert wired to no receiver is the CS-040 failure; mark delivery `configured`, not validated-live |
| Retention assumed instead of read | Read the per-table TTL from the safe `create_table_query` projection; missing TTL means no table TTL; establish required retention and external lifecycle ownership before a CS-020 finding |
| Plaintext-password user passed silently | Read `auth_type` from `system.users`; `plaintext_password` is a CS-050 posture finding |
| Open default user missed | Probe the external `default` user with an unauthenticated `SELECT 1`; only exact successful ClickHouse result `1` proves unauthenticated access |
| Empty ClickHouse scored a confident 0 | Reachable ClickHouse with zero rows everywhere trips CS-007 — block coverage/freshness, keep health+security, renormalize, never a confident 0/100 |
| A mutating statement slipped into the audit | Every ClickHouse call is a `SELECT`/`SHOW` with `readonly=1`; `INSERT`/`ALTER`/`CREATE`/`DROP` belong to setup-clickstack |
| Secret leaked into evidence | Record receiver class and user names only; never the API key, ClickHouse password, or webhook URL |
