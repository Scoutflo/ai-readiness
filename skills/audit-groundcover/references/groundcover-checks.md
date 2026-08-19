# audit-groundcover: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-groundcover](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Base is `https://api.groundcover.com` (override via `groundcover.api_url`). groundcover's monitors and workflows are its alerting layer, built on Keep.
- Auth is `Authorization: Bearer <key>` on a service-account API key, plus `X-Backend-Id: <backend>` (from `groundcover.backend_id`) on multi-backend accounts. Presence-check `GROUNDCOVER_API_KEY` only; never echo, log, or write it. Bind the key to a **Viewer**-role service account for a true read-only tier.
- Every command here is read-only: a GET, or one of the documented read-by-query POSTs — `POST /api/monitors/list`, `POST /api/monitors/summary/query`, and `POST /api/workflows/list`, which return data and change nothing. The forbidden-verb list is section 13.
- **Confirmed vs capability-gated.** The monitor list, workflows, and recurring silences are confirmed in groundcover's docs. On SaaS the per-monitor **config + runtime state** (severity, isPaused, state, silenced, pendingFor, lastEvaluationError, alertingCount) comes from `POST /api/monitors/summary/query`, confirmed live (HTTP 200). The per-monitor `GET /api/monitors/{uuid}` returns **YAML** (never pipe it to jq) and its config surface is thin — no `notificationSettings`/`autoResolve`/`customResolveThreshold` — so the fields it alone carries are best-effort enrichment (and `model.thresholds` there is an array). When `summary/query` is not 200, or a config field is genuinely absent, mark the dependent checks (GC-002/003/004/005/010-013, GC-022/023) `not-in-scope` with that reason. Never guess a monitor's live state.
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

List monitors, pull each monitor's config and runtime state (`POST /api/monitors/summary/query`), the workflows, and recurring silences.

```bash
set -eu
GC_API="https://api.groundcover.com"   # groundcover.api_url
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}/raw"
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

# Primary config + runtime source. On SaaS (api.groundcover.com) POST /api/monitors/summary/query
# returns rich JSON — verified HTTP 200 — with per monitor: uuid, title, severity, isPaused, state,
# silenced, interval.for, lastEvaluationError, alertingCount. It is a documented read-by-query POST
# and changes nothing (section 13). This is the reliable source because the per-monitor
# GET /api/monitors/{uuid} returns YAML, NOT JSON — piping it to jq fails "parse error: Invalid
# literal at line 1" — and that YAML config surface omits notificationSettings / autoResolve /
# customResolveThreshold entirely (0/69 observed live), so the config+runtime checks key off
# summary/query, not the GET.
mkdir -p "${RAW_DIR}/monitors"
RS_CODE="$(curl -s -o "${RAW_DIR}/monitor-state.json" -w '%{http_code}' --max-time 30 -H "$AUTH" \
  -H "Content-Type: application/json" -X POST "${GC_API}/api/monitors/summary/query" --data '{}' || echo 000)"
echo "summary/query: HTTP ${RS_CODE} (200 = config+runtime available; else GC-022/GC-023 not-in-scope)"
echo "$RS_CODE" > "${RAW_DIR}/monitor-state.http"

# Per-monitor files the section 5-8 checks read, built from summary/query: pendingFor from
# interval.for, plus isPaused / severity / state / silenced / lastEvaluationError.
if [ "$RS_CODE" = "200" ]; then
  jq -c 'if type=="array" then . else (.monitors // .results // .summaries // []) end
      | .[] | select(.uuid != null)
      | {uuid, title, severity, isPaused, state,
         silenced: (.silenced // null),
         pendingFor: (.interval.for // null),
         lastEvaluationError: (.lastEvaluationError // null),
         alertingCount: (.alertingCount // null)}' "${RAW_DIR}/monitor-state.json" \
  | while IFS= read -r rec; do
      printf '%s\n' "$rec" > "${RAW_DIR}/monitors/$(printf '%s' "$rec" | jq -r '.uuid').json"
    done
fi

# Optional enrichment: the fields summary/query does NOT carry (autoResolve, customResolveThreshold,
# noDataState, executionErrorState, notificationSettings.*) live only in the per-monitor GET, which
# is YAML — so parse it with a YAML tool (yq) into JSON first, NEVER pipe it to jq. model.thresholds
# there is an ARRAY, so hysteresis is read across the array, never as .model.thresholds.customResolveThreshold.
# Skipped cleanly when yq is absent; any field still null afterwards is genuinely not exposed and its
# check (GC-002/003/004/005/010-013) is not-in-scope-from-this-endpoint (sections 5-6), never a blanket finding.
if command -v yq >/dev/null 2>&1; then
  for UUID in $(jq -r '.[].uuid' "${RAW_DIR}/monitors.json"); do
    F="${RAW_DIR}/monitors/${UUID}.json"
    [ -f "$F" ] || jq -n --arg u "$UUID" '{uuid:$u}' > "$F"
    curl -fsS --max-time 30 -H "$AUTH" "${GC_API}/api/monitors/${UUID}" | yq -o=json '.' 2>/dev/null \
      | jq --slurpfile base "$F" '
          ($base[0]) + {
            autoResolve: .autoResolve, noDataState: .noDataState,
            executionErrorState: .executionErrorState, category: .category,
            customResolveThreshold: ([ (.model.thresholds // [])[]?.customResolveThreshold // empty ] | first // null),
            renotificationInterval: .notificationSettings.renotificationInterval,
            disableRenotification: .notificationSettings.disableRenotification,
            statusFilters: .notificationSettings.statusFilters,
            method: .notificationSettings.method,
            connectedApps: .notificationSettings.connectedApps }' > "${F}.tmp" \
      && mv "${F}.tmp" "$F" || rm -f "${F}.tmp"
    sleep 0.3   # no documented rate limit; throttle defensively
  done
else
  echo "yq absent: per-monitor YAML config not parsed; GC-002/003/004/005/010-013 not-in-scope-from-this-endpoint (summary/query does not carry those fields)"
fi

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

# (Runtime + config state was already pulled above via POST /api/monitors/summary/query into
# monitor-state.json / monitor-state.http; GC-022/GC-023 gate on that HTTP 200 in section 7.)

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

Expected: `monitors.json`, `monitor-state.json` (from `summary/query`) plus the per-monitor files derived from it, `workflows.json`, and `recurring-silences.json`. A 401 is a bad key; a 403 is missing Viewer access or a missing `backend_id`. The per-monitor `GET /api/monitors/{uuid}` is YAML, so it is parsed with a YAML tool (never piped to jq) and only enriches config-only fields. On a self-hosted host where the monitors API 404s, the config-level monitor checks (GC-001 to GC-023) are `not-in-scope` with that reason and the firing-state signal comes from `am-firing.json` (the Alertmanager fallback) rather than a fabricated "no monitors" result.

## 5. Monitor firing hygiene (GC-001 to GC-005)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}/raw"
# GC-002/003/004/005 key off config fields (customResolveThreshold, autoResolve, noDataState,
# executionErrorState) that /api/monitors/summary/query does NOT carry — they exist only when the
# per-monitor YAML config was parsed in section 4. When a field is null on EVERY monitor it was not
# exposed this run, so its check is not-in-scope-from-this-endpoint, never a blanket finding.
field_present() { jq -s --arg f "$1" -e 'any(.[]; .[$f] != null)' "${RAW_DIR}"/monitors/*.json >/dev/null 2>&1; }

# GC-001: pendingFor 0s or empty = fires on the first breach (no debounce). Always from summary/query.
jq -s '[.[] | select((.pendingFor // "0s") == "0s" or .pendingFor == "" or .pendingFor == null)
    | {uuid, title, pendingFor}]' "${RAW_DIR}"/monitors/*.json
# Judgment: a binary up/down monitor may fire immediately; a threshold on a spiky metric needs
# pendingFor. Judge by monitor type and intent, not blindly.

# GC-002: no customResolveThreshold (no hysteresis) — flag monitors that sit near a boundary.
if field_present customResolveThreshold; then
  jq -s '[.[] | select(.customResolveThreshold == null) | {uuid, title}]' "${RAW_DIR}"/monitors/*.json
else
  echo "GC-002 not-in-scope-from-this-endpoint: customResolveThreshold not exposed (no per-monitor YAML config parsed)"
fi
# Not every monitor needs hysteresis; pair with flapping evidence where the runtime state is readable.

# GC-003: autoResolve false/unset on a monitor whose condition can clear.
if field_present autoResolve; then
  jq -s '[.[] | select(.autoResolve != true) | {uuid, title, autoResolve}]' "${RAW_DIR}"/monitors/*.json
else
  echo "GC-003 not-in-scope-from-this-endpoint: autoResolve not exposed (no per-monitor YAML config parsed)"
fi

# GC-004: noDataState Alerting = pages on empty results. Default NoData is quiet.
if field_present noDataState; then
  jq -s '[.[] | select(.noDataState == "Alerting") | {uuid, title, noDataState}]' "${RAW_DIR}"/monitors/*.json
else
  echo "GC-004 not-in-scope-from-this-endpoint: noDataState not exposed (no per-monitor YAML config parsed)"
fi
# Judgment: Alerting-on-no-data is correct for a heartbeat-style monitor, noisy for a sampled metric.

# GC-005: executionErrorState Alerting = the query's own failures page. Default OK is quiet.
if field_present executionErrorState; then
  jq -s '[.[] | select(.executionErrorState == "Alerting") | {uuid, title, executionErrorState}]' "${RAW_DIR}"/monitors/*.json
else
  echo "GC-005 not-in-scope-from-this-endpoint: executionErrorState not exposed (no per-monitor YAML config parsed)"
fi
# A flaky query set to Alerting-on-error pages on its own breakage; OK at scale can also hide a
# genuinely broken monitor. Report the distribution, not just one side.
```

## 6. Notification noise (GC-010 to GC-013)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}/raw"
# GC-010..013 all key off notificationSettings, which /api/monitors/summary/query does NOT carry —
# it exists only when the per-monitor YAML config was parsed in section 4. When no monitor has any
# notification field, these are not-in-scope-from-this-endpoint, never blanket findings.
notif_present() { jq -s -e 'any(.[]; [.renotificationInterval,.disableRenotification,.statusFilters,.method,.connectedApps] | any(. != null))' "${RAW_DIR}"/monitors/*.json >/dev/null 2>&1; }

if notif_present; then
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
else
  echo "GC-010..013 not-in-scope-from-this-endpoint: notificationSettings not exposed by /api/monitors/summary/query (no per-monitor YAML config parsed)"
fi
```

## 7. Monitor health and silences (GC-020 to GC-023)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}/raw"

# GC-020: paused monitors. A paused monitor is defined but never evaluates.
jq -s '[.[] | select(.isPaused == true) | {uuid, title}]' "${RAW_DIR}"/monitors/*.json
# Judgment: pair each with its title/intent; a paused monitor named for a live SLO or critical
# service is a coverage gap, a paused scratch monitor is not.

# GC-021: open-ended / blanket recurring silences.
jq '[.[] | select(.matcher_count == 0 or .matcher_count == null) | {id, recurrenceType, comment}]' \
  "${RAW_DIR}/recurring-silences.json"
# A recurring silence with no/blank matchers (matches everything) on a permanent schedule is a
# standing blackout (GC-021 high). A narrow, commented maintenance-window silence is fine.

# GC-022 + GC-023: runtime state — ONLY when the summary/query pull in section 4 returned 200.
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/groundcover/${RUN_DATE}/raw"

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

This is an audit: read-only, no exceptions. The only POSTs allowed are the documented read-by-query calls: `POST /api/monitors/list`, `POST /api/monitors/summary/query` (the primary config + runtime read), and `POST /api/workflows/list`. Never run:

- Any `POST`/`PUT`/`DELETE` that creates or edits a monitor (`/api/monitors/{uuid}` write), a silence (`/api/monitors/silences`, `/api/monitors/recurring-silences`), a notification route, a destination, or a workflow.
- Any workflow-run or test-notification trigger.
- Any service-account or API-key management call.
