# audit-datadog: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-datadog](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Every call sends the key PAIR: `DD-API-KEY: <api key>` and `DD-APPLICATION-KEY: <app key>`, from the variables named by `datadog.api_key_env` and `datadog.app_key_env`. Presence-check both; never echo, log, or write either value.
- The API host is `api.<site>` from `datadog.site` (e.g. `api.datadoghq.com`, `api.us5.datadoghq.com`, `api.datadoghq.eu`). Every block declares `DD_HOST` at the top. A valid key on the wrong site returns 403, so a 403 is a site check before it is a scope check.
- Every command here is read-only: GET on monitors, downtimes, SLOs, events, usage, integrations, and dashboards. There are no read-by-effect POSTs in this skill. The forbidden-command list is section 13.
- Monitor CRUD/list is **v1** (`/api/v1/monitor`). Downtimes are **v2 only** (`/api/v2/downtime`); every v1 downtime endpoint is deprecated, including the GETs, so this skill never reads `/api/v1/downtime` or `/api/v1/monitor/{id}/downtimes`.
- `curl -fsS --max-time 30` is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it; those blocks say so.
- Rate limits are per-endpoint and returned in `X-RateLimit-*` headers; on 429, sleep for the `X-RateLimit-Reset` seconds once and retry, then record `blocked` on a second 429.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| DD-001 | Monitor delivery | Every monitor names at least one notification target (`@handle` in the message) | critical |
| DD-002 | Monitor delivery | No monitor targets a dead `@handle` (integration, channel, or webhook that no longer resolves) | high |
| DD-003 | Monitor delivery | No monitor left in `draft` status (drafts never notify) | high |
| DD-004 | Monitor delivery | Notification rules and config policies reviewed where the org uses them | medium |
| DD-010 | Monitor noise | Recovery thresholds set where a monitor has a warning/critical threshold (`critical_recovery`) | medium |
| DD-011 | Monitor noise | No-data handling deliberate (`notify_no_data`, `no_data_timeframe`, `on_missing_data`) | medium |
| DD-012 | Monitor noise | Renotification bounded, not unlimited (`renotify_interval`, `renotify_occurrences`) | low |
| DD-013 | Monitor noise | Evaluation delay / new-group delay set where the query needs late data | low |
| DD-014 | Monitor noise | Auto-resolve (`timeout_h`) deliberate per monitor type | low |
| DD-015 | Monitor noise | Datadog's own `quality_issues[]` reviewed and reconciled with this audit | info |
| DD-020 | Muting and downtime | No monitor muted indefinitely (`options.silenced` with no end) | high |
| DD-021 | Muting and downtime | No always-on / broad-scope downtime masking real alerts (`/api/v2/downtime`) | high |
| DD-022 | Muting and downtime | Downtimes scoped tightly, not muting whole environments open-ended | medium |
| DD-030 | Coverage and staleness | No stale monitors: `last_triggered_ts` recent or a recorded reason | low |
| DD-031 | Coverage and staleness | Composite monitors resolve all constituent monitor IDs | medium |
| DD-032 | Coverage and staleness | SLOs have an error-budget or burn-rate monitor attached | high |
| DD-033 | Coverage and staleness | Critical services from topology have monitor coverage | high |
| DD-034 | Coverage and staleness | Monitor tag hygiene: service/team tags present for routing | low |

Cost & Resource (non-scored, `DDOPT-NNN`, `points_recoverable: 0`): estimated/historical cost trend, top custom-metric contributors, and unused dashboards. Sourced only from Datadog's own usage endpoints; see section 11.

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Monitor delivery**: every monitor routes to a live target, no drafts masquerading as coverage, dead `@handles` caught, and org-level notification rules/config policies reviewed where used.
- **Monitor noise**: recovery thresholds, no-data handling, bounded renotification, evaluation delay, and auto-resolve all set deliberately per monitor, and Datadog's own quality signals reconciled with this audit's findings.
- **Muting and downtime**: no indefinite mutes, no open-ended broad-scope downtimes masking live alerts, downtimes scoped to what they mean to suppress.
- **Coverage and staleness**: no stale or draft monitors counted as coverage, composite monitors intact, every SLO paired with a burn-rate monitor, critical services covered, and monitor tags present for routing.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings.

```bash
set -euo pipefail   # pipefail is REQUIRED: without it a failing `curl | jq` reports jq's
                    # exit (0), so a 403/404 on a mandatory capture silently writes an empty
                    # file and passes. With pipefail the mandatory captures abort under set -e,
                    # and the `|| echo '[]'` fallbacks on the optional captures still fire.
DD_SITE="datadoghq.com"   # datadog.site
DD_HOST="api.${DD_SITE}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/datadog/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
DD_AUTH="-H DD-API-KEY:${DATADOG_API_KEY} -H DD-APPLICATION-KEY:${DATADOG_APP_KEY}"

# All monitors, with the fields every later section keys off. Message carries the
# @handles; options carries the noise controls. No secret is in this payload.
curl -fsS --max-time 60 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=1000" \
  | jq '[.[] | {id, name, type, message, query, draft_status: (.draft_status // "published"),
      overall_state, last_triggered_ts: (.overall_state_modified // null),
      tags,
      options: (.options // {} | {silenced, notify_no_data, no_data_timeframe, on_missing_data,
        renotify_interval, renotify_occurrences, evaluation_delay, new_group_delay,
        timeout_h, thresholds})}]' > "${RAW_DIR}/monitors.json"
# NOTE: `query` is captured because DD-031 scans a composite monitor's constituent
# ids out of its top-level query string (e.g. "12345 && 67890"); dropping it made
# DD-031 silently never fire.

# Datadog's OWN monitor quality signals (native corroboration anchor).
curl -fsS --max-time 60 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor/search?per_page=1000" \
  | jq '[.monitors[]? | {id, name, quality_issues: (.quality_issues // [])}]' \
  > "${RAW_DIR}/monitor-quality.json" || echo '[]' > "${RAW_DIR}/monitor-quality.json"
# NOTE: quality_issues is a top-level field on each monitor object (verified live against US5,
# 2026-07-26), NOT under .metadata. The paging total is at .metadata.total_count (see the
# estate-sizing call), but the per-monitor quality_issues[] array sits directly on the monitor.

# Downtimes: v2 ONLY. v1 is deprecated including its reads.
# -g / --globoff is REQUIRED: the v2 param name is literally `page[limit]`, and without
# globoff curl treats the `[...]` as a glob range and aborts with "curl: (3) bad range in
# URL" before any request — which, piped into jq without pipefail, silently yields an empty
# downtimes.json and a false pass on the whole downtime half of Muting-and-downtime.
curl -gfsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/downtime?page[limit]=100" \
  | jq '[.data[]? | {id, scope: .attributes.scope,
      status: .attributes.status,
      start: .attributes.schedule.start, end: (.attributes.schedule.end // null),
      recurrences: (.attributes.schedule.recurrences // null),
      monitor_identifier: .attributes.monitor_identifier}]' > "${RAW_DIR}/downtimes.json"

# SLOs
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/slo?limit=1000" \
  | jq '[.data[]? | {id, name, type, monitor_ids: (.monitor_ids // [])}]' > "${RAW_DIR}/slos.json" \
  || echo '[]' > "${RAW_DIR}/slos.json"

wc -c "${RAW_DIR}"/*.json
```

Expected: one JSON file per surface. A 403 on any endpoint is an auth/scope finding for the checks that need it (record which scope: monitor reads need `monitors_read`, downtime reads `monitors_downtime`, SLO reads `slos_read`), never a clean pass.

## 5. Monitor delivery (DD-001 to DD-004)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/datadog/${RUN_DATE}/raw"

# DD-001: monitors whose message contains no @handle (notify nobody)
jq '[.[] | select((.message // "") | test("@") | not) | {id, name}]' "${RAW_DIR}/monitors.json"
# Expect: []. A monitor with no @target fires into the events stream and pages no one.

# DD-003: draft monitors (drafts never notify, regardless of message)
jq '[.[] | select(.draft_status == "draft") | {id, name}]' "${RAW_DIR}/monitors.json"
# Expect: []. A draft left as "coverage" is invisible coverage.

# DD-001 partial / DD-002 input: extract distinct @handles to check liveness
jq -r '[.[] | (.message // "") | scan("@[A-Za-z0-9._-]+")] | flatten | unique | .[]' "${RAW_DIR}/monitors.json"
```

**DD-002 (dead @-handle liveness).** For each distinct handle class, verify it still resolves. Slack channels, webhooks, and PagerDuty services each have a read endpoint:

```bash
set -eu
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"   # datadog.site
# Slack: list configured channels for an account; a @slack-<account>-<channel> handle
# whose channel is not in this list is dead.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/integration/slack/configuration/accounts" \
  | jq '[.[]?.name]' 2>/dev/null || echo "slack integration not configured or not readable"
# Webhook: a named webhook that 404s is dead.
WEBHOOK_NAME="your-webhook-name"   # from a @webhook-<name> handle in the messages
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/integration/webhooks/configuration/webhooks/${WEBHOOK_NAME}")
echo "webhook ${WEBHOOK_NAME}: ${code}"   # 404 = dead handle referenced by a live monitor (DD-002, high)
```

Judgment: not every `@handle` is an integration (some are `@user@email`). Resolve the classes you can (`@slack-`, `@webhook-`, `@pagerduty-`); for plain email handles, record that liveness is unverifiable rather than asserting dead. **DD-004**: if `GET /api/v2/monitor/notification_rule` or `/api/v2/monitor/policy` returns entries, review org-level tag routing and required-tag enforcement; absence is a posture note, not a fail.

## 6. Monitor noise (DD-010 to DD-015)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/datadog/${RUN_DATE}/raw"

# DD-010: monitors with a critical threshold but no critical_recovery (flap risk)
jq '[.[] | select(.options.thresholds.critical != null and (.options.thresholds.critical_recovery == null))
    | {id, name, critical: .options.thresholds.critical}]' "${RAW_DIR}/monitors.json"
# Judgment: recovery thresholds matter most on metric monitors that hug their threshold;
# a monitor that recovers on the same value it fires on will flap. Some monitor types
# have no recovery concept (event/composite) — exclude those, do not fail them.

# DD-011: no-data handling — notify_no_data true but no_data_timeframe absurd, or silent no-data
jq '[.[] | {id, name, notify_no_data: .options.notify_no_data,
    no_data_timeframe: .options.no_data_timeframe, on_missing_data: .options.on_missing_data}]' \
  "${RAW_DIR}/monitors.json"
# Judgment: notify_no_data=false on a heartbeat/liveness monitor is a silent blind spot;
# on a spiky business metric it is correct. Judge against monitor intent, not a blanket rule.

# DD-012: unbounded renotification (renotify_interval set with no occurrence cap = forever)
jq '[.[] | select(.options.renotify_interval != null and (.options.renotify_occurrences == null))
    | {id, name, renotify_interval: .options.renotify_interval}]' "${RAW_DIR}/monitors.json"

# DD-014: auto-resolve posture
jq '[.[] | {id, name, timeout_h: .options.timeout_h}]' "${RAW_DIR}/monitors.json"

# DD-015: Datadog's OWN quality issues — free corroboration, report ours alongside theirs
jq '[.[] | select((.quality_issues | length) > 0) | {id, name, quality_issues}]' \
  "${RAW_DIR}/monitor-quality.json"
# The vendor flags high alert volume, muted>60d, missing recipients, missing eval delay,
# misconfigured channels, composite-missing-constituents, stuck-in-alert. Where their
# flag and this audit's finding disagree about a monitor, name the disagreement (info).
```

## 7. Muting and downtime (DD-020 to DD-022)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/datadog/${RUN_DATE}/raw"

# DD-020: indefinitely muted monitors. options.silenced is a map of scope->until-timestamp;
# a value of 0 or null means muted with no end.
jq '[.[] | select((.options.silenced // {}) | to_entries | any(.value == null or .value == 0))
    | {id, name, silenced: .options.silenced}]' "${RAW_DIR}/monitors.json"
# Expect: []. An indefinitely muted monitor is a stuck/suppressed alert wearing a mute.

# DD-021 + DD-022: downtimes that are broad and open-ended (no end, wide scope)
jq '[.[] | select(.status == "active" or .status == "scheduled")
    | select(.end == null) | {id, scope, status, monitor_identifier}]' "${RAW_DIR}/downtimes.json"
# Judgment: an active downtime with end=null and a scope like "*" or "env:prod" mutes
# whole environments open-ended — a permanent blind spot, not maintenance. A tightly
# scoped recurring maintenance window is fine; name scope + end in the finding either way.
```

## 8. Coverage and staleness (DD-030 to DD-034)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/datadog/${RUN_DATE}/raw"
STALE_DAYS="180"   # example, tune to your monitor churn

# DD-031: composite monitors whose constituent IDs no longer resolve.
# Composite monitor queries reference other monitor ids like "12345 && 67890".
ALL_IDS="$(jq '[.[].id]' "${RAW_DIR}/monitors.json")"
jq --argjson all "$ALL_IDS" '[.[] | select(.type == "composite")
    | {id, name, referenced: [.query // "" | scan("[0-9]{3,}") | tonumber],
       missing: ([.query // "" | scan("[0-9]{3,}") | tonumber] - $all)}
    | select((.missing | length) > 0)]' "${RAW_DIR}/monitors.json"
# Expect: []. A composite referencing a deleted monitor silently never fires correctly.

# DD-032: SLOs with no burn-rate/error-budget alerting.
# CAUTION: empty monitor_ids does NOT mean "no alerting" for every SLO type.
#   - monitor-type SLOs are DEFINED by their monitors, so monitor_ids==[] is a real gap.
#   - metric-type and time_slice-type SLOs always have monitor_ids==[] by design; their
#     burn-rate alerting is a SEPARATE monitor of type "slo alert" whose query references
#     the SLO id (e.g. error_budget("<slo_id>")...) and never appears in the SLO's monitor_ids.
# So we only flag a non-monitor SLO when NO "slo alert" monitor references its id.
SLO_ALERT_QUERIES="$(jq '[.[] | select(.type == "slo alert") | .query // ""]' "${RAW_DIR}/monitors.json")"
jq --argjson sloAlerts "$SLO_ALERT_QUERIES" '[.[]
    | . as $slo
    | ($sloAlerts | map(select(contains($slo.id))) | length) as $alertCount
    | select(if $slo.type == "monitor"
             then ($slo.monitor_ids | length) == 0
             else (($slo.monitor_ids | length) == 0) and ($alertCount == 0) end)
    | {id: $slo.id, name: $slo.name, type: $slo.type}]' "${RAW_DIR}/slos.json"
# Expect: []. An SLO nobody pages on is a dashboard decoration, not an alert. A metric SLO
# that IS covered by an "slo alert" burn-rate monitor is correct and must not be flagged.

# DD-034: monitor tag hygiene — service/team tags for routing
jq '[.[] | select((.tags // []) | (any(startswith("service:")) or any(startswith("team:"))) | not)
    | {id, name, tags}]' "${RAW_DIR}/monitors.json"
# Judgment: untagged monitors cannot be routed by notification rules or attributed to a
# team; low severity individually, a coverage-quality signal in aggregate.
```

**DD-030 (stale monitors)** and **DD-033 (critical-service coverage)** are judgment reads: pair `last_triggered_ts` (never-fired or ancient) with the monitor's intent, and cross-map monitors to the `topology.md` critical services by their `service:` tag or name. Name affected services; "three services have no monitor" is not a finding, "checkout, payments, and search have no monitor" is.

## 9. Rate-limit handling (all sections)

```bash
set -eu
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"   # datadog.site
DD_PATH="/api/v1/monitor?page_size=1000"
RESP_CODE="$(curl -s -o /tmp/dd-body.json -w '%{http_code}' --max-time 60 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}${DD_PATH}")"
if [ "$RESP_CODE" = "429" ]; then
  echo "429 received; sleeping 30s once and retrying (honor X-RateLimit-Reset in production)"
  sleep 30
  RESP_CODE="$(curl -s -o /tmp/dd-body.json -w '%{http_code}' --max-time 60 \
    -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
    "https://${DD_HOST}${DD_PATH}")"
fi
[ "$RESP_CODE" = "200" ] || echo "still ${RESP_CODE} after one retry: record the affected check as blocked with this code"
```

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, match Datadog monitors by `service:` tag (fall back to name match, recorded), then fill the matrix row from the section 5 to 8 captures: delivery (DD-001), noise posture (DD-010/011), muting (DD-020), coverage (DD-033), SLO pairing (DD-032). Name affected services in findings.

## 11. Cost & Resource Optimization (non-scored, DDOPT-NNN)

Runs only when the doctor `datadog cost-permissions` row is `pass`; on `skipped`, the whole section reports `excluded, reason: <doctor reason>`. Never scored, never in `score.categories`; findings carry `points_recoverable: 0` and an `estimated_monthly_cost_usd` field only when the number comes straight from Datadog's own usage endpoint.

```bash
set -eu
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"   # datadog.site
# Estimated cost trend (needs usage_read + billing_read)
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/usage/estimated_cost?view=sub-org" | jq '.data[0].attributes // {}' \
  || echo "estimated_cost not readable; report DDOPT cost-trend excluded"
# Top custom-metric contributors (custom metrics are a common surprise cost)
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/top_avg_metrics?limit=20" | jq '[.usage[]? | {metric_name, avg_metric_hour}]' \
  || echo "top_avg_metrics not readable"
```

Report presence facts only where no dollar figure is backed by the API; never estimate savings the platform did not compute.

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `STALE_DAYS` | 180 | Never-triggered window before a monitor is stale-flagged |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. Never run:

- Any `POST`, `PUT`, `PATCH`, or `DELETE` — Datadog has no read-by-effect POST in this skill's surface (unlike PagerDuty analytics), so every mutating verb is out.
- Creating, editing, deleting, muting, or resolving monitors; `POST /api/v1/monitor/{id}/mute` or `/unmute`; creating or canceling downtimes.
- Editing SLOs, notification rules, config policies, integrations, or dashboards.
- `POST /api/v1/monitor/validate` (validates a monitor body you would be composing; setup-lane).
- Sending any test notification or event (`POST /api/v1/events`).
