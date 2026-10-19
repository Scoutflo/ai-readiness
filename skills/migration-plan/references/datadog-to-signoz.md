# Datadog → SigNoz pair catalog

The single source of truth for `migration-plan` equivalences on this pair. Every mapping below is grounded in the two providers' primary sources (Datadog API reference + official API-client models; SigNoz docs + `SigNoz/signoz` source), researched 2026-09-17, with **UNVERIFIED** flags where a claim could not be confirmed — an UNVERIFIED item is never asserted as fact in a plan. SigNoz publishes its own official migration guide set (`signoz.io/docs/migration/migrate-from-datadog/` — overview, metrics, traces, logs, dashboards, alerts, and the Datadog-receiver bridge); this catalog cites it, follows it where it rules, and adds what it does not have: the **audit-bias dispositions**, per-object equivalence classes, and the parity-gated cutover.

**Equivalence classes** (the closed enum the validator enforces): `direct` (same concept, mechanical translation) · `approximate` (same intent, different mechanics — behavior may differ at the edges, named) · `manual` (carried by reconstruction; the untranslatable part is named) · `none` (no equivalent; the alternative is named). New/unknown Datadog `type` strings appear over time — bucket an unknown kind as `manual` with a note, never guess.

## 1. Source read blocks (read-only detail pulls beyond the audit's inventory)

The audit's `inventory.json` carries monitors/SLOs/downtimes as rows; the plan's detail pass pulls full definitions **only for objects the plan needs** (bounded per-disposition, never a per-estate sweep). All GETs; the app key needs read access to dashboards/SLOs/synthetics/logs-config in addition to the audit's scopes (probe a single GET and treat a 403 as a named scope gap, not a failure).

```bash
set -eu
# shellcheck disable=SC1090
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env"
: "${DATADOG_API_KEY:?run /scoutflo:connect — never send an empty auth header}"
: "${DATADOG_APP_KEY:?run /scoutflo:connect — never send an empty auth header}"
# Monitors (full definitions incl. options/thresholds/message) — reuse the audit's pull if kept
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/monitor?page_size=1000" \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# Dashboards: list (custom/cloned only — presets are NOT returned), then N+1 full pulls
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/dashboard" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/dashboard/{dashboard_id}" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# SLOs (with the linked SLO-alert monitor ids — the join to the monitor inventory)
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/slo?limit=1000" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/slo/{slo_id}?with_configured_alert_ids=true" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# Synthetics: list, then the typed per-test GET (api|browser|mobile); monitor_id joins the paired monitor
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/synthetics/tests" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# Logs config: pipelines (+ processors), indexes (+ exclusion filters/retention), archives, log-based metrics
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/logs/config/pipelines" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v1/logs/config/indexes" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v2/logs/config/metrics" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# Downtimes v2 (mute inventory)
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v2/downtime" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
# Metric migration sizing: actively-queried metrics, per-metric blast radius (assets), volumes, top custom metrics
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v2/metrics?filter%5Bqueried%5D=true" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
curl -fsS "https://api.${DD_SITE:-datadoghq.com}/api/v2/metrics/{metric_name}/assets" -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}"
```

Notification-handle **enumerability matrix** (for cross-checking the `@handles` harvested from monitor messages): Slack channels — listable (`GET /api/v1/integration/slack/configuration/accounts/{account}/channels`; account discovery is the deprecated v1 GET, **UNVERIFIED payload**); MS Teams handles — listable (`GET /api/v2/integration/ms-teams/configuration/tenant-based-handles` + `workflows-webhook-handles`); Opsgenie services — listable (`GET /api/v2/integration/opsgenie/services`); **PagerDuty and Webhooks have NO list-all** — harvest `@pagerduty-*`/`@webhook-*` from messages, then confirm each by the per-name GET. Handles hide inside `{{#is_alert}}…{{/is_alert}}` conditionals and template variables (`@slack-{{owner.name}}`) — parse the whole `message`, and treat a template-built handle as `manual` routing.

Target side (when reachable): `GET /api/v1/rules`, `GET /api/v1/channels`, `GET /api/v2/dashboards` (the v1 dashboards API is **retired — 501 `dashboard_deprecated`**), planned-maintenance list. Same read-only discipline.

## 2. Monitors → SigNoz alert rules (the 23-type matrix)

Verified Datadog monitor `type` enum (23 values, official client) mapped to the verified SigNoz rule model (`alertType` ∈ METRIC/TRACES/LOGS/EXCEPTIONS_BASED_ALERT; `ruleType` ∈ threshold_rule/promql_rule/anomaly_rule):

| DD monitor type | SigNoz target | Equivalence | Notes |
| --- | --- | --- | --- |
| `metric alert` | METRIC_BASED_ALERT (threshold; builder or PromQL) | approximate | query translated (space/time aggregation → builder aggregation + `evalWindow`); `by {…}` → group-by + `notificationSettings.groupBy` |
| `query alert` (plain) | METRIC_BASED_ALERT | approximate | same as metric alert |
| `query alert` with `anomalies(…)` | anomaly_rule (builder-only) | approximate | **anomaly rules are SigNoz Cloud / Self-Hosted Enterprise** — on plain self-hosted OSS this is `none` (nearest: static threshold); seasonality hourly/daily/weekly |
| `query alert` with `forecast(…)` / `outliers(…)` | — | none | SigNoz's own alerts-migration page: not supported; nearest is an anomaly rule (with the availability caveat above) |
| `log alert` | LOGS_BASED_ALERT (builder or ClickHouse SQL) | approximate | log search syntax differs; measures/rollups recast in the builder |
| `trace-analytics alert` (APM) | TRACES_BASED_ALERT | approximate | span-attribute filters recast; APM metric names differ (§9) |
| `error-tracking alert` | EXCEPTIONS_BASED_ALERT | approximate | issue-source/`new()` semantics have no direct field — named manual part |
| `event alert` / `event-v2 alert` | — | manual | no events product; recast the underlying signal as a log/metric rule. **Watchdog** (surfaces as event-v2): not supported per SigNoz's page |
| `service check` | METRIC_BASED_ALERT | manual | recast as a metric threshold (e.g. `up`-style gauge) + `alertOnAbsent`; check-status semantics (`count_by_status`) do not translate |
| `process alert` | — | manual | no live-process monitor; nearest is hostmetrics process metrics + a threshold rule (verify the specific metric exists before promising) |
| `synthetics alert` | — | none | §6 — no native synthetics; alternative = `httpcheck` receiver + uptime dashboard + a rule on `httpcheck.status`; keep the test↔monitor `monitor_id` join so the pair gets ONE disposition |
| `composite` | multiple separate rules | manual | SigNoz's own mapping: "create separate alerts, consider labels for grouping". No boolean composition exists — DD's `&&`/`||`/`!` status math (≤10 children, no nesting) is the named untranslatable part |
| `slo alert` (`error_budget(…)` / `burn_rate(…)`) | §5 recipes | manual | burn-rate pair → **two** rules; error-budget → none (no budget object) |
| `rum alert` | — | none/manual | **UNVERIFIED** SigNoz RUM surface this pass — do not promise; mark manual pending verification |
| `audit alert`, `ci-pipelines/ci-tests alert`, `database-monitoring alert`, `network-performance/network-path alert`, `cost alert`, `data-quality/data-jobs alert`, `llm-observability alert` | — | none/manual | no corresponding SigNoz product lane; where the underlying data will flow to SigNoz (e.g. as logs/traces), recast manually; otherwise `none` with the gap named |

**Field-level mapping (the part that maps BETTER than expected — all target fields source-verified):**

| Datadog monitor field | SigNoz rule field | Class |
| --- | --- | --- |
| warning + critical thresholds | **v2alpha1 multi-thresholds** — named `warning`/`critical` entries, each with its own `channels[]` | direct |
| recovery thresholds (`critical_recovery`/`warning_recovery`) | per-threshold **`recoveryTarget`** | direct |
| `renotify_interval` / `renotify_occurrences` | `notificationSettings.renotify {enabled, interval, alertStates:[firing|no_data]}` — occurrences cap has no field (named gap) | approximate |
| `notify_no_data` + `no_data_timeframe` | `alertOnAbsent` + `absentFor` (minutes) | direct |
| evaluation window | `evalWindow` + `matchType` — **best-practice bias**: prefer `on average`/`all the times` over the flappy `at least once` default; note the improvement on the object | approximate |
| `require_full_window`, `evaluation_delay` | no equivalents — named manual parts | manual |
| priority P1–P5 / severity | `labels.severity` (v1) / threshold names (v2alpha1) — feeds routing policies | approximate |
| message template (`{{#is_alert}}`, `{{value}}`, …) | `annotations` + per-threshold channels/routing policies — template languages differ; body text recast by hand | manual |
| muted / downtimes | planned maintenance (§7) — never `disabled: true` (that stops evaluation, a DD mute does not) | approximate |

## 3. Notification handles → channels + routing policies

SigNoz channels (verified list): Slack, Webhook, Incident.io, Rootly, Zenduty, PagerDuty, Opsgenie, MS Teams, Google Chat, Jira, JSM Ops, Email — plus expression-based **routing policies** over labels (`severity`, `threshold.name`, group-by dims).

| DD handle | SigNoz channel | Class |
| --- | --- | --- |
| `@slack-<account>-<channel>` | Slack channel | direct |
| `@pagerduty-<service>` | PagerDuty channel | direct |
| `@opsgenie-<service>` | Opsgenie channel | direct |
| `@teams-<…>` | MS Teams (v2) channel | direct |
| `@webhook-<name>` | Webhook channel | approximate (payload shape differs — downstream consumers must be re-tested) |
| `@<email>` | Email channel | direct |
| `@jira-<…>` | Jira channel | approximate |
| `@servicenow-<…>` | — | none (no ServiceNow channel; nearest = webhook, manual) |
| `@team-handle` (Datadog Teams) | routing policy on a team label | manual |
| Slack `<!here>`/`<!channel>` body mentions | — | manual (channel-body feature, not a routing target; flag as a broadcast anti-pattern — usually a fix-then-migrate) |
| conditional/templated handles (`{{#is_warning}}@x{{/is_warning}}`) | per-threshold `channels[]` (warning→X, critical→Y) | approximate — often a genuinely BETTER shape on the target |

## 4. Dashboards (attempted per widget — honestly)

SigNoz's own dashboards-migration page: "Datadog dashboards need to be recreated … due to differences in query languages and dashboard schemas." Three paths: the **Import JSON** flow / dashboards **v2 API** (`SIGNOZ-API-KEY`; self-host ≥ v0.135.0; Perses-style spec — do not hand-craft the legacy v1 shape), the `SigNoz/dashboards` template repo, and the official **Datadog Migration Tool** (LLM-based dashboard-JSON converter — **SigNoz Cloud paid plans only**; per-widget fidelity is UNVERIFIED — never present it as bundled with self-hosted). No community converter exists (verified-absence, 2026-09-17).

Widget wire-type → SigNoz panel matrix (DD taxonomy = 41 verified wire strings; SigNoz panels = timeseries, value, table, list, bar, pie, histogram, text; **no heatmap** — their page says "coming soon" — and **no SLO widget**):

| DD `definition.type` | SigNoz panel | Class |
| --- | --- | --- |
| `timeseries` | timeseries | approximate (query translated) |
| `query_value`, `alert_value` | value | approximate |
| `toplist` | table with sorting (SigNoz's own mapping) | approximate |
| `query_table` | table | approximate |
| `heatmap`, `distribution` | histogram (nearest) | manual — no heatmap panel |
| `note`, `free_text` | text | direct |
| `log_stream`, `list_stream` | list | approximate |
| `slo`, `slo_list` | — | none (no SLO widget; §5) |
| `manage_status` (monitor summary) | — | none (no monitor-summary panel) |
| `group`, `split_group` | layout by hand | manual |
| `hostmap`, `servicemap`, `topology_map`, `geomap`, `treemap`, `sunburst`, `funnel`, `sankey`, `scatterplot`, `change`, `check_status`, `event_stream`, `event_timeline`, `alert_graph`, `iframe`, `image`, `run_workflow`, `powerpack`, `embedded_app`, `bar_chart`*, `cohort`, `point_plot`, `retention_curve`, `wildcard` | case-by-case; mostly none/manual | name each in the plan (`bar_chart` → bar panel is the one approximate in this tail) |

Query translation: DD metric queries → Query Builder (or PromQL — the metrics store is Prom-compatible); formulas exist in builder v5; DD template variables → SigNoz variables (Custom/Dynamic/Textbox; `$var` syntax). A dashboard's plan row aggregates its widgets: equivalence = the WORST class among its widgets, and the untranslatable widgets are listed by name.

## 5. SLOs (reconstruction recipes — and what is verified impossible)

SigNoz has **no first-class SLO product** (no docs page; feature requests #658/#5374 open as of 2026-09-17). Per DD SLO `type` (verified enum `metric|monitor|time_slice`):

- **Metric SLO** (`query.numerator/denominator`) → `manual`: a formula alert — A = bad/good events, B = total, F1 = ratio — with v2alpha1 `warning`/`critical` thresholds + per-threshold channels. This carries the *alerting intent*; the SLO object itself (targets, error budget, status) has no home.
- **Burn-rate SLO alerts** (`burn_rate("id").long_window("1h").short_window("5m") > 14.4`) → **two SigNoz rules** (fast window + slow window). **Verified impossible in one query-builder rule** — a rule has exactly one `evalWindow` and evaluates one selected query; there is no AND of two windows and no composite rule. A single ClickHouse-SQL rule computing `least(burn_5m, burn_1h)` is an **UNVERIFIED design pattern** (the CH-SQL alert mechanism is verified; this construction is undocumented) — offer it only as needs-live-proof.
- **Error-budget alerts** (`error_budget("id").over("30d") > 75`) → `none`: no error-budget object; nearest is a long-window ratio rule + a dashboard panel, named as an approximation of intent, not an equivalent.
- **Monitor SLO / time-slice SLO** → `none`/`manual`: no uptime-over-alert-states primitive; time-slice ≈ a windowed ratio recast by hand.
- **SLO widgets** on dashboards → `none` (§4).

## 6. Synthetics (no native equivalent — the verified alternative)

SigNoz has **no synthetic monitoring** (#2764 open). Per verified test taxonomy (`type` api/browser/mobile/network; `subtype` http/ssl/tcp/dns/multi/icmp/udp/websocket/grpc):

- **API-http (+ ssl/TLS-expiry intent)** → the official alternative: OTel Collector **`httpcheck` receiver** (targets + `collection_interval`; emits `httpcheck.status`, `httpcheck.duration`, `httpcheck.error`, TLS cert-remaining) + the official **Uptime Monitoring dashboard template** (`SigNoz/dashboards`, needs ≥ v0.135.0) + a METRIC rule on `httpcheck.status`. Class: `none` with this named alternative (active probing is preserved; multi-location/private-location semantics are not).
- **tcp/dns/icmp/udp/websocket/grpc subtypes, browser tests, mobile tests, multistep API journeys** → `none`; no verified SigNoz-side prober for these — an external checker (or keeping these specific tests where they run today) is the honest alternative, and SigNoz's docs do **not** endorse a specific third-party here (verified absence — don't invent one).
- SigNoz's **External API Monitoring** is *passive* (trace-derived, from span attributes) — useful adjacent coverage, not a synthetics replacement; never present it as active probing.
- Each synthetics **test** and its paired `synthetics alert` **monitor** (joined by `monitor_id`) get ONE disposition together.

## 7. Downtimes → planned maintenance

Verified SigNoz model: `{name, schedule{timezone, startTime, endTime, recurrence{duration, repeatType daily|weekly|monthly, repeatOn}}, alertIds[], scope}` — notifications suppressed, **evaluation continues** (same semantics as a DD mute).

| DD downtime feature | SigNoz | Class |
| --- | --- | --- |
| one-time window | fixed schedule (timezone-aware) | direct |
| simple recurring (daily/weekly/monthly) | recurrence | approximate (monthly = start-date's day-of-month, clamped) |
| **RRULE recurrences** (≤5, RFC 5545 subset) beyond daily/weekly/monthly | — | none — "every 2nd week"/cron-grade patterns are the named gap |
| scope by tag search syntax | `scope` expr-lang over **alert labels** | manual (re-scope by hand — different vocabulary) |
| auto-mute on host shutdown (EC2/GCE/Azure) | — | none |
| downtime start/end notifications, `mute_first_recovery_notification` | — | none |
| per-monitor mute | maintenance window scoped to the rule (never `disabled: true` — that stops evaluation) | approximate |

## 8. Logs configuration

- **Pipelines** (22 verified DD processor wire-types) → **SigNoz Logs Pipelines** (UI processors: Regex/Grok/JSON/Timestamp/Severity parsers + Add/Remove/Move/Copy; no collector restarts): `grok-parser`→Grok (`direct`-ish, patterns re-tested), `date-remapper`→Timestamp, `status-remapper`→Severity, `attribute-remapper`→Move/Copy/Add (`approximate`); `category-processor`, `arithmetic-processor`, `string-builder-processor`, `lookup-processor` (both variants), `geo-ip-parser`, `url-parser`, `user-agent-parser`, `trace-id/span-id-remapper`, `array-*`, `decoder-processor`, `schema-processor`, nested `pipeline` → no SigNoz-UI processor — `manual` via OTel collector processors where feasible, each named.
- **Indexes / exclusion filters / per-index retention / daily quotas** → `none` as objects — SigNoz has no index concept; retention is deployment-level. An exclusion filter's *intent* (drop noise pre-storage) recasts as collector-side filtering (`manual`).
- **Archives** → `none` (no archive product; self-hosted storage policy is your ClickHouse/infra concern — do not claim an equivalent).
- **Log-based metrics** → `manual`, **UNVERIFIED** target mechanism this pass — recast as log-query panels/alerts or a collector-side transform; verify live before promising.

## 9. Metrics, tags, and agent continuity (the dual-write bridge)

- **Agent replacement** (SigNoz's own metrics page): DD Agent → OTel Collector `hostmetrics` (infra) + `prometheus` receiver (exporters); DogStatsD clients → OTel SDKs.
- **Bridge for the parallel run** (SigNoz-documented, metrics/DogStatsD scope): the OTel Collector **`datadog` receiver** (contrib, **alpha** for traces/metrics/logs). Dual-ship from the DD Agent via `DD_ADDITIONAL_ENDPOINTS='{"http://<collector>:8125": ["<key-alias>"]}'` (keeps Datadog receiving) or cut over exclusively via `DD_DD_URL`. SigNoz frames it as a **bridge, not a destination** ("for long-term use … migrate to native OpenTelemetry"). Traces/logs through the datadogreceiver are technically supported endpoints (verified in source: trace-agent v0.3–v0.7, `/api/v2/logs`) but **SigNoz does not document that combination — VERIFY-PENDING-LIVE**, never promised.
- **Traces**: replace dd-trace libraries with OTel SDKs (SigNoz's page); spans from not-yet-migrated services will not appear in SigNoz — sequence service-by-service.
- **APM metric names change** (SigNoz's verified table): `trace.<SPAN>.hits` → `signoz_calls_total{operation=…}`, errors → `signoz_calls_total{…, status.code="STATUS_CODE_ERROR"}`, latency → `signoz_latency.bucket`; **no equivalent for `apdex`** or `trace.*.duration.by_http_status`; DB/external latency is average-only. Every dashboard/monitor referencing a DD APM metric carries this rename as part of its `manual`/`approximate` note.
- **Tag → attribute mapping** (verified from Datadog's own mapping page + the receiver's translator): `env`→`deployment.environment.name`, `service`→`service.name`, `version`→`service.version`, plus container/k8s/http tables; unnamed DD tags become `unnamed_<tag>` through the receiver — normalize tags BEFORE the bridge, not after.
- **Migration sizing**: `GET /api/v2/metrics?filter[queried]=true` (what is actually used), `/assets` per metric (which dashboards/monitors/SLOs break if it goes — the per-metric blast radius), `/volumes` + `usage/top_avg_metrics` (custom-metric cost drivers worth NOT carrying).
- **Historical metrics: cannot be imported** — SigNoz's own page: "You cannot import historical metrics from Datadog." This is the citation behind the plan's `historical_telemetry: does-not-transfer` lock.

## 10. Cutover playbook (fills `cutover.parallel_run`)

1. **Freeze + plan** — this skill's output: dispositions confirmed by you and your team (drops approved, fix-list agreed).
2. **Bridge up** — OTel Collector deployed; DD Agent dual-ships metrics via `DD_ADDITIONAL_ENDPOINTS`; OTel SDK rollout for traces service-by-service; logs to SigNoz per its logs guide. Tags normalized to OTel semconv first.
3. **Recreate per plan** — fix-then-migrate items get their fixes at creation; migrated alerts adopt the target-side hygiene noted on each object (windowed match-type, per-threshold channels, severity labels).
4. **Shakedown (parallel run)** — **paging duty stays on Datadog**; SigNoz rules run with channels live but pages shadowed (scoped planned-maintenance on the paging channels, or a shadow channel) so one incident never pages through both tools.
5. **Audit-parity sunset gate** — re-run `audit-datadog` + `audit-signoz` + the correlation engine: require SigNoz coverage parity on the migrate list, no new true gaps, and no alert-fatigue reachability regressions. Only then flip paging duty to SigNoz.
6. **Sunset** — export DD dashboards/monitor JSONs as the archive record, downgrade/disable the DD Agent fleet, keep DD read-only until its retention window ends (history stays there — it never transferred), then close the account per the cost plan.

## Sources

SigNoz: `signoz.io/docs/migration/migrate-from-datadog/` (+ metrics/traces/logs/dashboards/alerts/receiver sub-pages), `signoz.io/datadog-migration-tool/`, alerts/dashboards/planned-maintenance/routing-policy docs, `github.com/SigNoz/signoz` (`pkg/types/ruletypes`, `alertmanagertypes`, `dashboardtypes`), `github.com/SigNoz/dashboards`, OTel `opentelemetry-collector-contrib/receiver/datadogreceiver` (metadata/receiver/translator source). Datadog: `docs.datadoghq.com` API reference (monitors, dashboards, SLOs, synthetics, logs-config, downtimes, usage, integrations) with field/enum truth from the official `datadog-api-client-go`/`-python` models; `docs.datadoghq.com/monitors/types/composite/`, `/monitors/notify/`, SLO error-budget/burn-rate pages, and Datadog's OTel semantic-mapping page. Researched 2026-09-17; enums are point-in-time — bucket unknown types gracefully.
