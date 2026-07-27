# audit-groundcover: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-groundcover](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Base is `https://api.groundcover.com` (override via `groundcover.api_url`). groundcover's monitors and workflows are its alerting layer, built on Keep.
- Auth is `Authorization: Bearer <key>` on a service-account API key, plus `X-Backend-Id: <backend>` (from `groundcover.backend_id`) on multi-backend accounts. Presence-check `GROUNDCOVER_API_KEY` only; never echo, log, or write it. Bind the key to a **Viewer**-role service account for a true read-only tier.
- Every command here is read-only: a GET, or one of the two documented read-by-query POSTs — `POST /api/monitors/list` and `POST /api/workflows/list`, which return data and change nothing. The forbidden-verb list is section 13.
- **Confirmed vs capability-gated.** The monitor config surface (list, per-monitor config, workflows, recurring silences) is confirmed in groundcover's docs. The per-monitor **runtime state** source (firing history, last evaluation error, live silence flags) is NOT confirmed in public docs: probe it once (section 7), and if it is absent or errors, mark the checks that depend on it `not-in-scope` with that reason. Never guess a monitor's live state.
- `curl -fsS --max-time 30` with the auth header is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it. A list response may be a bare array or wrapped (`{monitors: [...]}` / `{results: [...]}`); the commands normalize both.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| GC-001 | Firing hygiene | `evaluationInterval.pendingFor` set (not `0s`/empty) so a monitor does not fire on a transient blip | high |
| GC-002 | Firing hygiene | `model.thresholds.customResolveThreshold` present where a monitor sits near a boundary (hysteresis) | medium |
| GC-003 | Firing hygiene | `autoResolve` true where the condition can clear, so issues self-close | medium |
| GC-004 | Firing hygiene | `noDataState` deliberate; not `Alerting` on no-data where empty results are normal | medium |
| GC-005 | Firing hygiene | `executionErrorState` deliberate; not `Alerting` on a flaky query, not masking broken queries at scale | medium |
| GC-010 | Notification noise | `renotificationInterval` sane or `disableRenotification` true, so a firing issue does not repeat-page every cycle | medium |
| GC-011 | Notification noise | `statusFilters` deliberate; `Resolved` on high-churn monitors is resolve-noise | low |
| GC-012 | Notification noise | `method` not `noNotifications` where it should page, and `connectedApps` route-bypass not used at scale | medium |
| GC-013 | Notification noise | Every paging monitor resolves to a destination (not detect-but-page-nobody) | high |
| GC-020 | Health/silences | `isPaused` monitors judged against intent (a paused live-SLO monitor is a coverage gap) | medium |
| GC-021 | Health/silences | No open-ended or blanket recurring silence (a broad permanent matcher is a standing blackout) | high |
| GC-022 | Health/silences | No monitor stuck permanently firing or in evaluation error (runtime-state-gated) | high |
| GC-023 | Health/silences | No monitor fully silenced with no end (runtime-state-gated) | medium |
| GC-030 | Coverage/liveness | Workflow-backed destinations live (no `invalid`, error status, or `installed:false`) | high |
| GC-031 | Coverage/liveness | `severity` set and used, not every monitor at one level | low |
| GC-032 | Coverage/liveness | Critical services from topology each covered by at least one evaluating monitor | high |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Monitor firing hygiene**: every monitor has a real `pendingFor`, hysteresis where it sits near a boundary, auto-resolve where the condition clears, and deliberate no-data and execution-error states — monitors fire on real conditions, not blips or their own broken queries.
- **Notification noise**: re-notification is bounded or disabled, resolve-notifications are trimmed on churny monitors, routing goes through notification routes rather than ad-hoc `connectedApps`, and every paging monitor actually reaches a destination.
- **Monitor health and silences**: no live-SLO monitor sits paused, no recurring silence is an open-ended blanket, and (where runtime state is readable) no monitor is stuck firing, erroring, or fully silenced.
- **Coverage and destination liveness**: workflow-backed destinations are live, severity is used for prioritized routing, and every critical service has an evaluating monitor.

## 4. Inventory (all categories)

List monitors, pull each monitor's config, the workflows, and recurring silences. Probe the runtime-state endpoint once.

```bash
set -eu
GC_API="https://api.groundcover.com"   # groundcover.api_url
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/groundcover/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
# Build the header set once. Add X-Backend-Id only when groundcover.backend_id is set.
AUTH="Authorization: Bearer ${GROUNDCOVER_API_KEY}"
# gc_post <path> <body>  and  gc_get <path>  — add -H "X-Backend-Id: ${GC_BACKEND}" in the real
# run when backend_id is configured (kept explicit here so the read stays copy-pasteable).
norm() { jq 'if type=="array" then . else (.monitors // .results // .workflows // []) end'; }

# All monitors (list is minimal: uuid, title, type).
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}' | norm \
  | jq '[.[] | {uuid, title, type}]' > "${RAW_DIR}/monitors.json"
echo "monitors: $(jq 'length' "${RAW_DIR}/monitors.json")"

# Per-monitor config — the tuning fields the checks key off. Throttle defensively (section 9).
mkdir -p "${RAW_DIR}/monitors"
for UUID in $(jq -r '.[].uuid' "${RAW_DIR}/monitors.json"); do
  curl -fsS --max-time 30 -H "$AUTH" "${GC_API}/api/monitors/${UUID}" \
    | jq '{uuid, title, isPaused, autoResolve, noDataState, executionErrorState, severity, category,
        pendingFor: (.evaluationInterval.pendingFor // null),
        customResolveThreshold: (.model.thresholds.customResolveThreshold // null),
        renotificationInterval: (.notificationSettings.renotificationInterval // null),
        disableRenotification: (.notificationSettings.disableRenotification // null),
        statusFilters: (.notificationSettings.statusFilters // null),
        method: (.notificationSettings.method // null),
        connectedApps: (.notificationSettings.connectedApps // [])}' \
    > "${RAW_DIR}/monitors/${UUID}.json"
  sleep 0.3   # no documented rate limit; throttle defensively
done

# Workflows (destination liveness).
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${GC_API}/api/workflows/list" --data '{}' | norm \
  | jq '[.[] | {id, name, invalid, last_execution_status,
      providers: [.providers[]? | {type, name, installed}]}]' > "${RAW_DIR}/workflows.json"

# Recurring silences (one-time silences have no list endpoint).
curl -fsS --max-time 30 -H "$AUTH" "${GC_API}/api/monitors/recurring-silences" \
  | jq 'if type=="array" then . else (.results // []) end
      | [.[] | {id, recurrenceType, timezone, comment, matcher_count: ((.matchers // []) | length)}]' \
  > "${RAW_DIR}/recurring-silences.json" 2>/dev/null || echo '[]' > "${RAW_DIR}/recurring-silences.json"

# Runtime-state capability probe (UNCONFIRMED endpoint). Record availability; do NOT depend on it
# unless it returns 200. If it 404s or errors, GC-022/GC-023 are not-in-scope.
RS_CODE="$(curl -s -o "${RAW_DIR}/monitor-state.json" -w '%{http_code}' --max-time 20 -H "$AUTH" \
  -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/summary/query" --data '{}' || echo 000)"
echo "runtime-state probe: HTTP ${RS_CODE} (200 = available; anything else = GC-022/GC-023 not-in-scope)"
echo "$RS_CODE" > "${RAW_DIR}/monitor-state.http"

# Self-hosted detection + Alertmanager fallback. When GC_API is a non-cloud host (self-hosted),
# the /api/monitors/* paths can 404 even after the base authenticates (verified live 2026-07-26):
# the self-hosted monitors component does not always expose the cloud monitors API. In that case
# the firing-state signal comes from the Alertmanager-compatible endpoint instead (the same path
# the platform uses for self-hosted Groundcover). This does NOT apply on api.groundcover.com.
case "$GC_API" in
  *api.groundcover.com*) echo "mode: SaaS (cloud monitors API)";;
  *)
    ML_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "$AUTH" \
      -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}' || echo 000)"
    if [ "$ML_CODE" = "404" ]; then
      echo "mode: SELF-HOSTED, monitors API not exposed (HTTP 404) -> GC-001..023 not-in-scope; using Alertmanager fallback for firing state"
      curl -s --max-time 20 -H "$AUTH" "${GC_API}/api/alertmanager/grafana/api/v2/alerts" \
        | jq '[.[]? | select(.status.state=="active" or .status.state=="firing")
            | {fingerprint, labels: (.labels // {}), startsAt}]' > "${RAW_DIR}/am-firing.json" 2>/dev/null \
        || echo '[]' > "${RAW_DIR}/am-firing.json"
      echo "alertmanager firing alerts: $(jq 'length' "${RAW_DIR}/am-firing.json" 2>/dev/null || echo 0)"
    else
      echo "mode: SELF-HOSTED, monitors API responded (HTTP ${ML_CODE}) -> cloud-shape checks apply"
    fi
    ;;
esac
```

Expected: `monitors.json`, per-monitor config files, `workflows.json`, `recurring-silences.json`, and the runtime-state probe result. A 401 is a bad key; a 403 is missing Viewer access or a missing `backend_id`. On a self-hosted host where the monitors API 404s, the config-level monitor checks (GC-001 to GC-023) are `not-in-scope` with that reason and the firing-state signal comes from `am-firing.json` (the Alertmanager fallback) rather than a fabricated "no monitors" result.

## 5. Monitor firing hygiene (GC-001 to GC-005)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/groundcover/${RUN_DATE}/raw"

# GC-001: pendingFor 0s or empty = fires on the first breach (no debounce).
jq -s '[.[] | select((.pendingFor // "0s") == "0s" or .pendingFor == "" or .pendingFor == null)
    | {uuid, title, pendingFor}]' "${RAW_DIR}"/monitors/*.json
# Judgment: a binary up/down monitor may fire immediately; a threshold on a spiky metric needs
# pendingFor. Judge by monitor type and intent, not blindly.

# GC-002: no customResolveThreshold (no hysteresis) — flag monitors that sit near a boundary.
jq -s '[.[] | select(.customResolveThreshold == null) | {uuid, title}]' "${RAW_DIR}"/monitors/*.json
# Not every monitor needs hysteresis; pair with flapping evidence where the runtime state is readable.

# GC-003: autoResolve false/unset on a monitor whose condition can clear.
jq -s '[.[] | select(.autoResolve != true) | {uuid, title, autoResolve}]' "${RAW_DIR}"/monitors/*.json

# GC-004: noDataState Alerting = pages on empty results. Default NoData is quiet.
jq -s '[.[] | select(.noDataState == "Alerting") | {uuid, title, noDataState}]' "${RAW_DIR}"/monitors/*.json
# Judgment: Alerting-on-no-data is correct for a heartbeat-style monitor, noisy for a sampled metric.

# GC-005: executionErrorState Alerting = the query's own failures page. Default OK is quiet.
jq -s '[.[] | select(.executionErrorState == "Alerting") | {uuid, title, executionErrorState}]' "${RAW_DIR}"/monitors/*.json
# A flaky query set to Alerting-on-error pages on its own breakage; OK at scale can also hide a
# genuinely broken monitor. Report the distribution, not just one side.
```

## 6. Notification noise (GC-010 to GC-013)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/groundcover/${RUN_DATE}/raw"

# GC-010: no renotificationInterval and disableRenotification not true = default re-notify cadence;
# a very short interval is a repeat-page storm on a long-lived issue.
jq -s '[.[] | select(.disableRenotification != true and (.renotificationInterval == null))
    | {uuid, title, renotificationInterval, disableRenotification}]' "${RAW_DIR}"/monitors/*.json

# GC-011: statusFilters includes Resolved (doubles message volume) on churny monitors.
jq -s '[.[] | select((.statusFilters // []) | index("Resolved")) | {uuid, title, statusFilters}]' \
  "${RAW_DIR}"/monitors/*.json
# Resolved notifications are often intentional; flag them on high-churn monitors, not universally.

# GC-012: method noNotifications (silent) where a monitor should page, or connectedApps route-bypass.
jq -s '{no_notify: [.[] | select(.method == "noNotifications") | {uuid, title}],
    route_bypass: [.[] | select(.method == "connectedApps") | {uuid, title}]}' "${RAW_DIR}"/monitors/*.json
# noNotifications on a monitor meant to page is a silent gap. connectedApps at scale fragments
# delivery control that notification routes would centralize; count the route-bypass share.

# GC-013: a paging monitor that resolves to no destination.
jq -s '[.[] | select(.method == "connectedApps" and ((.connectedApps // []) | length) == 0)
    | {uuid, title}]' "${RAW_DIR}"/monitors/*.json
# method connectedApps with an empty connectedApps list detects but pages nobody (GC-013 high).
# For method notificationRoutes, confirm at least one route matches (see section 8's route note).
```

## 7. Monitor health and silences (GC-020 to GC-023)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/groundcover/${RUN_DATE}/raw"

# GC-020: paused monitors. A paused monitor is defined but never evaluates.
jq -s '[.[] | select(.isPaused == true) | {uuid, title}]' "${RAW_DIR}"/monitors/*.json
# Judgment: pair each with its title/intent; a paused monitor named for a live SLO or critical
# service is a coverage gap, a paused scratch monitor is not.

# GC-021: open-ended / blanket recurring silences.
jq '[.[] | select(.matcher_count == 0 or .matcher_count == null) | {id, recurrenceType, comment}]' \
  "${RAW_DIR}/recurring-silences.json"
# A recurring silence with no/blank matchers (matches everything) on a permanent schedule is a
# standing blackout (GC-021 high). A narrow, commented maintenance-window silence is fine.

# GC-022 + GC-023: runtime state — ONLY when the probe in section 4 returned 200.
if [ "$(cat "${RAW_DIR}/monitor-state.http" 2>/dev/null)" = "200" ]; then
  # Field names are unconfirmed in public docs; adapt to the observed response shape.
  jq '{stuck_firing: [.. | objects | select(.state? == "firing" and (.lastResolved? == null))
        | {uuid: .uuid?, title: .title?}],
     error_state: [.. | objects | select(.lastEvaluationError? != null and .lastEvaluationError? != "")
        | {uuid: .uuid?, error: .lastEvaluationError?}],
     fully_silenced: [.. | objects | select(.fullySilenced? == true) | {uuid: .uuid?}]}' \
    "${RAW_DIR}/monitor-state.json"
  # GC-022: stuck-firing or error-state monitors. GC-023: fully-silenced with no end.
else
  echo "runtime-state endpoint unavailable; GC-022 and GC-023 are not-in-scope this run"
  # State so in the report: live monitor state could not be read, so one-time-silenced or stuck
  # monitors may not be visible. This is a stated ceiling, never a fabricated pass.
fi
```

## 8. Coverage and destination liveness (GC-030 to GC-032)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/groundcover/${RUN_DATE}/raw"

# GC-030: dead workflow-backed destinations.
jq '[.[] | select(.invalid == true or .last_execution_status == "error"
      or ((.providers // []) | any(.installed == false)))
    | {id, name, invalid, last_execution_status,
       dead_providers: [.providers[]? | select(.installed == false) | .type]}]' \
  "${RAW_DIR}/workflows.json"
# A workflow that is invalid, last failed, or has an uninstalled provider is a dead delivery path
# (GC-030 high): monitors routed through it fire but page nobody.

# GC-031: severity distribution — everything at one level defeats prioritized routing.
jq -s '[.[].severity] | group_by(.) | map({severity: .[0], count: length})' "${RAW_DIR}"/monitors/*.json
# All monitors at S1 (or all with no severity) is the finding; a spread across S1-S4 is healthy.
```

**GC-032 (critical-service coverage)** is a judgment cross-map: for each critical service from `topology.md`, confirm at least one monitor evaluates for it (by the monitor's `labels`, `title`, or the k8s namespace/workload it targets). Name affected services; "three services have no monitor" is not a finding, "checkout, payments, and search have no groundcover monitor" is.

**Notification-route overlap** is best-effort: groundcover's notification routes have no confirmed REST list endpoint and are BYOC-only. When routes cannot be read from the API, the report states that route overlap could not be assessed rather than asserting a clean routing bill; if the deployment exposes routes (or a Terraform state is available out of band), enumerate their match criteria for overlapping or catch-all routes.

## 9. Rate-limit and pacing handling (all sections)

groundcover publishes no rate limits, so throttle the per-monitor read path defensively: a short `sleep` between per-monitor config pulls (section 4 uses `0.3s`; raise it on a large estate), and on any `429` or `503`, back off and retry once, then record the affected monitors' checks as `blocked` with the reason. On the large path, batch by monitor uuid against the worklist per skill-authoring-conventions.md so a throttle pauses one batch, not the whole run.

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, resolve its monitors (by label/title/namespace-workload), then fill the matrix row from sections 5-8: firing hygiene (GC-001), notification (GC-010/013), health (GC-020), liveness (GC-030). Name affected services and the monitors backing each finding.

## 11. Reserved

(No section 11 content; numbering preserved so section anchors stay stable if a category is added later.)

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `RENOTIFY_FLOOR` | 1h | a `renotificationInterval` shorter than this on a paging monitor is flagged as repeat-page risk (GC-010) |
| `ROUTE_BYPASS_SHARE` | 0.30 | share of monitors on `connectedApps` above which route-bypass at scale is flagged (GC-012) |
| `TOP_SEVERITY_SHARE` | 0.80 | share of monitors at a single severity above which prioritized routing is judged defeated (GC-031) |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. The only POSTs allowed are the two documented read-by-query calls: `POST /api/monitors/list` and `POST /api/workflows/list` (plus the capability-probe `POST /api/monitors/summary/query`, which is a read if it exists). Never run:

- Any `POST`/`PUT`/`DELETE` that creates or edits a monitor (`/api/monitors/{uuid}` write), a silence (`/api/monitors/silences`, `/api/monitors/recurring-silences`), a notification route, a destination, or a workflow.
- Any workflow-run or test-notification trigger.
- Any service-account or API-key management call.
