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
- `POST /api/v2/events/search` (DD-006) is a query endpoint, not a mutation: classify it by effect, not verb, exactly as [skill-authoring-conventions.md](../../../docs/skill-authoring-conventions.md) directs. It is the only POST this skill sends; it searches events and creates nothing.
- DD-038 (Synthetics) needs an app key scoped `synthetics_read` in addition to the scopes in the doctor table; a 403 there is a scope gap on that one check, not the whole audit.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| DD-001 | Monitor delivery | Every monitor names at least one notification target (`@handle` in the message) | critical |
| DD-002 | Monitor delivery | No monitor targets a dead `@handle` (integration, channel, or webhook that no longer resolves) | high |
| DD-003 | Monitor delivery | No monitor left in `draft` status (drafts never notify) | high |
| DD-004 | Monitor delivery | Notification rules and config policies reviewed where the org uses them | medium |
| DD-005 | Monitor delivery | Critical-service monitors carry a `priority` (P1-P5) so paging can be tiered, not flat | medium |
| DD-006 | Monitor delivery | Measured alert-event volume: `sources=alert`/`source:alert` events exist over the trailing window when a monitor's state actually transitioned in it | high |
| DD-007 | Monitor delivery | No monitor's only notification target is a placeholder/template artifact (`@your-team-handle`, `__..._placeholder__` query fragment, literal `$service`/`$env` tag) | high |
| DD-008 | Monitor delivery | No monitor pages the whole org via `@all`/`@everyone` without a stated reason | medium |
| DD-010 | Monitor noise | Recovery thresholds set where a monitor has a warning/critical threshold (`critical_recovery`) | medium |
| DD-011 | Monitor noise | No-data handling deliberate (`notify_no_data`, `no_data_timeframe`, `on_missing_data`) | medium |
| DD-012 | Monitor noise | Renotification bounded, not unlimited (`renotify_interval`, `renotify_occurrences`) | low |
| DD-013 | Monitor noise | Evaluation delay / new-group delay set where the query needs late data | low |
| DD-014 | Monitor noise | Auto-resolve (`timeout_h`) deliberate per monitor type | low |
| DD-015 | Monitor noise | Datadog's own `quality_issues[]` reviewed and reconciled with this audit | info |
| DD-016 | Monitor noise | Receiver noise concentration: the real pages share a handle with many noisy monitors | high |
| DD-017 | Monitor noise | No monitor stuck in `Alert` state so long it can never re-page a new breach | medium |
| DD-018 | Monitor noise | Ratio queries (`errors/hits`-shaped) carry a composite volume floor, not just a bare percentage threshold | medium |
| DD-019 | Monitor noise | No comparator/threshold pair that is impossible or tautological (`> 0`/`>= 0` on a non-negative metric, or a negative critical value with `>`) | medium |
| DD-020 | Muting and downtime | No monitor muted indefinitely (`options.silenced` with no end) | high |
| DD-021 | Muting and downtime | No always-on / broad-scope downtime masking real alerts (`/api/v2/downtime`) | high |
| DD-022 | Muting and downtime | Downtimes scoped tightly, not muting whole environments open-ended | medium |
| DD-023 | Muting and downtime | No active, open-ended downtime whose age has outlived its own stated temporary intent | high |
| DD-030 | Coverage and staleness | No stale monitors: `last_triggered_ts` recent or a recorded reason | low |
| DD-031 | Coverage and staleness | Composite monitors resolve all constituent monitor IDs | medium |
| DD-032 | Coverage and staleness | SLOs have an error-budget or burn-rate monitor attached | high |
| DD-033 | Coverage and staleness | Critical services from topology have monitor coverage | high |
| DD-034 | Coverage and staleness | Monitor tag hygiene: service/team tags present for routing | low |
| DD-035 | Coverage and staleness | A monitor's tags agree with its query's own scope terms for the same key (env, service, cluster, …) | medium |
| DD-036 | Coverage and staleness | No duplicate published monitors on the same normalized expression and scope | low |
| DD-037 | Coverage and staleness | No monitor stuck in `No Data` with `overall_state_modified == null` since well past its `created` date (never evaluated once) | medium |
| DD-038 | Coverage and staleness | No paused Synthetic test still backing an unmuted, live-reporting monitor | high |

Cost & Resource (non-scored, `DDOPT-NNN`, `points_recoverable: 0`): estimated/historical cost trend, top custom-metric contributors, and unused dashboards. Sourced only from Datadog's own usage endpoints; see section 11.

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Monitor delivery**: every monitor routes to a live target, no drafts masquerading as coverage, dead `@handles` caught, no target is a placeholder never filled in, no monitor pages the whole org without reason, measured alert-event volume backs up the configuration, and org-level notification rules/config policies reviewed where used.
- **Monitor noise**: recovery thresholds, no-data handling, bounded renotification, evaluation delay, and auto-resolve all set deliberately per monitor, every ratio query carries a volume floor, no threshold is impossible or tautological, and Datadog's own quality signals reconciled with this audit's findings.
- **Muting and downtime**: no indefinite mutes, no open-ended broad-scope downtimes masking live alerts, no downtime has outlived its own stated temporary intent, downtimes scoped to what they mean to suppress.
- **Coverage and staleness**: no stale, draft, duplicate, or never-evaluated monitors counted as coverage, composite monitors intact, every SLO paired with a burn-rate monitor, monitor tags agree with what their own query actually evaluates, no live monitor is fed by a paused Synthetic, critical services covered, and monitor tags present for routing.

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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
DD_AUTH="-H DD-API-KEY:${DATADOG_API_KEY} -H DD-APPLICATION-KEY:${DATADOG_APP_KEY}"

# All monitors, with the fields every later section keys off. Message carries the
# @handles; options carries the noise controls. No secret is in this payload.
curl -fsS --max-time 60 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=1000" \
  | jq '[.[] | {id, name, type, message, query, priority, draft_status: (.draft_status // "published"),
      overall_state, overall_state_modified: (.overall_state_modified // null),
      last_triggered_ts: (.overall_state_modified // null), created,
      tags,
      options: (.options // {} | {silenced, notify_no_data, no_data_timeframe, on_missing_data,
        renotify_interval, renotify_occurrences, evaluation_delay, new_group_delay,
        timeout_h, thresholds})}]' > "${RAW_DIR}/monitors.json"
# NOTE: `query` is captured because DD-031 scans a composite monitor's constituent
# ids out of its top-level query string (e.g. "12345 && 67890"); dropping it made
# DD-031 silently never fire.
# NOTE: `priority` is captured for DD-005 (paging-tier hygiene). The monitor object
# exposes a top-level `priority` (integer 1-5, i.e. P1-P5, or null when unset); it is
# a plain read, no extra call. The overall_state transition time is aliased here as
# `last_triggered_ts` — DD-017 reads that key. This projection ALSO keeps the
# unaliased `overall_state_modified` (verified live: both keys read the identical
# ISO-8601 string or null) because DD-037 needs to distinguish "never transitioned"
# (null) from "transitioned a long time ago" (a real timestamp) — the aliasing alone
# collapsed that distinction in earlier runs. `created` (a plain top-level field,
# confirmed live as an ISO-8601 string) is captured for DD-037's age gate; no extra call.

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
      monitor_identifier: .attributes.monitor_identifier,
      message: (.attributes.message // ""), created: .attributes.created}]' > "${RAW_DIR}/downtimes.json"
# NOTE: `message` and `created` are added for DD-023 (downtime intent decay) — both are
# plain top-level fields under `.attributes` (confirmed live alongside `status`/`schedule`
# in the same object), no extra call. `message` is a downtime's own annotation, distinct
# from a monitor message; it carries no secret in normal use, same disclosure profile as
# a monitor message (do not write it verbatim if it embeds a secret-shaped value).

# SLOs
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/slo?limit=1000" \
  | jq '[.data[]? | {id, name, type, monitor_ids: (.monitor_ids // [])}]' > "${RAW_DIR}/slos.json" \
  || echo '[]' > "${RAW_DIR}/slos.json"

# Alert-sourced events, trailing 30d (DD-006). v1 `sources=alert` events carry `monitor_id`
# directly on each event (confirmed live — this is the ONLY events surface that does; the
# general v1 events feed with no source filter does not). This is the load-bearing capture.
EVT_WINDOW_DAYS="30"   # example, tune to your paging cadence; see section 12
EVT_TO="$(date -u +%s)"
EVT_FROM="$(( EVT_TO - EVT_WINDOW_DAYS * 24 * 3600 ))"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/events?start=${EVT_FROM}&end=${EVT_TO}&sources=alert" \
  | jq '[.events[]? | {id, monitor_id, alert_type, date_happened}]' > "${RAW_DIR}/alert-events.json" \
  || echo '[]' > "${RAW_DIR}/alert-events.json"
# NOTE: on a live org with zero alert-sourced events in the window, `sources=alert` still
# returns 200 with `events: []` (confirmed live) — an empty array is a real zero count, not
# a failure signal; DD-006 reads it as such and cross-checks it against monitor state
# transitions (section 5.2) before deciding whether the zero is a fail or a quiet window.

# v2 corroboration for DD-006: events/search is a read-only QUERY sent as POST (classify by
# effect, not verb — see section 1). Confirmed live: 200 with a `data`/`meta` envelope; an
# empty `data` array on a real org with zero alert events matched the v1 zero exactly.
EVT_FROM_ISO="$(date -u -r "${EVT_FROM}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${EVT_FROM}" +%Y-%m-%dT%H:%M:%SZ)"
EVT_TO_ISO="$(date -u -r "${EVT_TO}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${EVT_TO}" +%Y-%m-%dT%H:%M:%SZ)"
EVT_BODY="$(jq -n --arg from "$EVT_FROM_ISO" --arg to "$EVT_TO_ISO" \
  '{filter:{query:"source:alert", from:$from, to:$to}, page:{limit:1000}}')"
printf '%s' "$EVT_BODY" > "${RAW_DIR}/.alert-events-v2-request.json"
curl -fsS --max-time 30 -X POST -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  -H "Content-Type: application/json" -d @"${RAW_DIR}/.alert-events-v2-request.json" \
  "https://${DD_HOST}/api/v2/events/search" \
  | jq '{count: (.data | length)}' > "${RAW_DIR}/alert-events-v2-count.json" \
  || echo '{"count":null}' > "${RAW_DIR}/alert-events-v2-count.json"

# Synthetic tests (DD-038): `status` (live/paused) is independent of the linked monitor's
# own state. Confirmed live: 200 with a `tests[]` array; `status` and `monitor_id` are both
# plain top-level fields on each test object, no extra call per test.
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/synthetics/tests" \
  | jq '[.tests[]? | {public_id, status, monitor_id: (.monitor_id // null)}]' > "${RAW_DIR}/synthetics.json" \
  || echo '[]' > "${RAW_DIR}/synthetics.json"
# NOTE: this projection deliberately drops `creator`, `name`, `config.request.url`, and
# `message` — the full test object carries the creator's name/email and target hostnames,
# none of which any finding needs; DD-038 only ever needs `status` joined to `monitor_id`.

wc -c "${RAW_DIR}"/*.json
```

Expected: one JSON file per surface. A 403 on any endpoint is an auth/scope finding for the checks that need it (record which scope: monitor reads need `monitors_read`, downtime reads `monitors_downtime`, SLO reads `slos_read`), never a clean pass.

## 5. Monitor delivery (DD-001 to DD-008)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-001: monitors whose message contains no @handle (notify nobody).
# Join to the service: tag so the blast radius is "which service is blind", not a count.
jq '[.[] | select((.message // "") | test("@") | not)
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — compute it, do not assert "pages no one": a monitor with no
# @target fires into the events stream only. Join the no-@handle set to each monitor's
# service: tag and the topology critical-service list: "the only p99-latency monitor on
# service:payments (critical) names no @handle, so a payments latency breach fires silently
# with MTTA = never". The who/what is the service-tag join. Correlation: this set is one of
# the suppressors the DD-033 effective-coverage flagship subtracts, and chains to DD-032
# when the same service owns an SLO. Rank by whether the unrouted monitor is a critical
# service's ONLY monitor (blind spot) vs a redundant one (low).

# DD-003: draft monitors (drafts never notify, regardless of message).
jq '[.[] | select(.draft_status == "draft")
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Expect: []. Severity is set by the join, NOT by the draft flag: a draft that is the SOLE
# monitor for a critical service is critical (invisible coverage the green UI hides); a draft
# duplicating a live published monitor for the same service is low. Feeds the DD-033 flagship.

# DD-001 partial / DD-002 input: extract distinct @handles to check liveness
jq -r '[.[] | (.message // "") | scan("@[A-Za-z0-9._-]+")] | flatten | unique | .[]' "${RAW_DIR}/monitors.json"
```

**DD-002 (dead @-handle liveness).** For each distinct handle class, verify it still resolves. Slack channels, webhooks, and PagerDuty services each have a read endpoint:

```bash
set -eu
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"   # datadog.site
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
# Slack: the legacy Slack config API (/api/v1/integration/slack/configuration/accounts) is
# DEPRECATED and now returns 404 on current orgs, so the channel-list resolution no longer works
# everywhere. Capture the STATUS CODE, not just the body: on 200 use the live channel list (a
# @slack-<account>-<channel> handle whose channel is absent is a dead handle); on 404 (or any
# non-200) fall back to Datadog's OWN `broken_at_handle` monitor quality signal — the same
# monitor-quality.json anchor DD-015 reads — which flags any monitor whose @-handle no longer
# resolves. That keeps DD-002 resolving dead Slack handles instead of failing the resolution silent.
SLACK_CODE=$(curl -s -o /tmp/dd-slack-accounts.json -w '%{http_code}' --max-time 30 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/integration/slack/configuration/accounts")
if [ "$SLACK_CODE" = "200" ]; then
  jq '[.[]?.name]' /tmp/dd-slack-accounts.json   # live channel list (handle not in list = dead)
else
  echo "slack config API returned ${SLACK_CODE} (legacy endpoint deprecated); falling back to broken_at_handle"
  # DD-002 fallback: monitors Datadog itself flags for an unresolvable @-handle (dead Slack channel).
  jq '[.[] | select((.quality_issues | tostring) | test("broken_at_handle")) | {id, name}]' \
    "${RAW_DIR}/monitor-quality.json"
fi
# Webhook: a named webhook that 404s is dead.
WEBHOOK_NAME="your-webhook-name"   # from a @webhook-<name> handle in the messages
# status-probe-ok: the HTTP status IS the evidence here (404 = a dead @webhook handle referenced by a live monitor, DD-002); api.<site> is fixed JSON SaaS.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/integration/webhooks/configuration/webhooks/${WEBHOOK_NAME}")
echo "webhook ${WEBHOOK_NAME}: ${code}"   # 404 = dead handle referenced by a live monitor (DD-002, high)
```

Judgment: not every `@handle` is an integration (some are `@user@email`). Resolve the classes you can (`@slack-`, `@webhook-`, `@pagerduty-`); for plain email handles, record that liveness is unverifiable rather than asserting dead.

**DD-002 blast radius — compute the delivery gap, not the raw dead-handle count.** Once the dead-handle monitor set is known (from the live channel list, or the `broken_at_handle` fallback), join it to each monitor's `service:` tag, then to the set of same-service monitors that still carry a LIVE handle. The blast radius is the intersection *dead-handle monitors ∩ services with zero live-handle monitors* — the services where the dead handle was the ONLY delivery path. A dead handle on a service that still has another live-delivering monitor is a hygiene fix; a dead handle that is a service's sole path is a blind spot. This set is a DD-033 suppressor, and a dead handle that many monitors share is also the concentration point DD-016 reports.

```bash
# DD-002 blast radius: services where a dead-handle monitor was the ONLY live path.
# DEAD_IDS is the id list from the live-channel resolution above OR the broken_at_handle set.
DEAD_IDS='[]'   # replace with the resolved dead-handle monitor id array from the block above
jq --argjson dead "$DEAD_IDS" '
  # svc -> {live: [ids with a resolvable handle], dead: [ids in the dead set]}
  ([.[] | . as $m | ((.tags // [])[] | select(startswith("service:"))) as $svc
     | {svc: $svc, id: .id, dead: ([$m.id] | inside($dead))}]) as $rows
  | ($rows | group_by(.svc) | map({service: .[0].svc,
      dead_monitors: [.[] | select(.dead) | .id],
      live_delivery_monitors: [.[] | select(.dead | not) | .id]})
    | map(select((.dead_monitors | length) > 0 and (.live_delivery_monitors | length) == 0)))' \
  "${RAW_DIR}/monitors.json"
# Any service row returned has a dead handle AND no surviving live-handle monitor:
# that service is one deleted channel away from silence. That intersection is the finding.
```

**DD-004 — compute routing fall-through, not just "review the rules".** Pull the org's monitor notification rules and config policies; when the org routes by `service:`/`team:` tag rules, a monitor matching NO rule falls through to the default route or nowhere and depends entirely on its inline `@handles`.

```bash
set -eu
DD_SITE="datadoghq.com"; DD_HOST="api.${DD_SITE}"   # datadog.site
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/monitor/notification_rule" \
  | jq '[.data[]? | {id, name: .attributes.name, filter_tags: (.attributes.filter.tags // [])}]' \
  > "${RAW_DIR}/notification-rules.json" || echo '[]' > "${RAW_DIR}/notification-rules.json"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v2/monitor/policy" \
  | jq '[.data[]? | {id, type: .attributes.policy_type}]' \
  > "${RAW_DIR}/monitor-policies.json" || echo '[]' > "${RAW_DIR}/monitor-policies.json"
# Fall-through set: monitors whose tags satisfy NO rule's filter_tags. When rules exist,
# every returned monitor routes only by its inline @handles (or nowhere).
jq --slurpfile rules "${RAW_DIR}/notification-rules.json" '
  ($rules[0] // []) as $R
  | if ($R | length) == 0 then [] else
    [.[] | . as $m | (.tags // []) as $mt
     | select([ $R[] | (.filter_tags // []) | select(length > 0) | all(. as $t | $mt | index($t)) ] | any | not)
     | {id, name, tags: $mt}] end' "${RAW_DIR}/monitors.json"
```
Blast radius: "the org routes by `team:` rules but N monitors match no rule and depend entirely on inline handles" — those N are exactly the DD-034 untagged monitors made consequential (untagged → matches no tag filter → fall-through), and they chain into DD-016 when they still land on one shared handle. Absence of any rule is a posture note, not a fail: with no org rules, inline `@handles` are the whole routing model and DD-001/DD-002 already cover them.

### 5.1 Paging-tier hygiene (DD-005)

> **Live-verified (read-only).** Confirmed against a live Datadog org (read-only key pair): the monitor `priority` field is present and nullable exactly as captured in section 4 — `priority` was observed as `null` on real monitors, which is precisely the untiered case DD-005 flags. Mechanism proven on a real tenant.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-005: critical-service monitors with priority == null (paging cannot be tiered).
# priority is captured in section 4; no extra call. Carry the handle to show the flat-urgency
# blast radius on a shared route.
jq '[.[] | select(.priority == null)
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))],
       handles: [((.message // "") | scan("@[A-Za-z0-9._-]+"))]}]' "${RAW_DIR}/monitors.json"
```
Blast radius: when critical-service monitors leave `priority` null, every monitor on a given receiver pages at the same urgency — "all 47 monitors on @pagerduty-oncall are un-prioritized, so a P5 disk-space warning and a payments-down page are indistinguishable to the responder". Compute it by joining `priority == null` to the `service:` tag/criticality and the shared handle. Judgment: DD-005 is only a finding on *critical-service* monitors (topology.md) or monitors sharing a paging handle with them; a lone P-less low-severity monitor is a note. Correlation: amplifies DD-016 (without priority the noisy and the real monitors on one handle are indistinguishable) and feeds DD-004 tiered routing. Remediation is inline (no `setup-datadog` ships): Monitor edit — set a priority (P1-P5) on critical-service monitors so the receiver can tier.

### 5.2 Measured alert-event volume, placeholder artifacts, and over-broad targets (DD-006 to DD-008)

> **Live-verified (read-only).** All three ran against a real Datadog org. DD-006's `sources=alert`/`source:alert` event queries both returned 200 with a real (empty, on that run) result set, cross-checked against zero monitor state transitions in the same window — proving the check does not false-positive on a genuinely quiet period. DD-007 matched real monitors carrying a literal `@your-team-handle`-shaped placeholder handle, a literal `$service`/`$env` tag value, and a query containing a `__..._placeholder__` fragment — on the SAME live org, at least one of these placeholder monitors also carried a legitimate-looking `@slack-`/`@pagerduty-` handle elsewhere in its message, confirming DD-001's bare `test("@")` cannot tell the two apart. DD-008 matched real monitors whose message contained a literal `@all`.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
EVT_WINDOW_DAYS="30"   # example, tune to your paging cadence; matches the section-4 capture

# DD-006: total measured alert-event volume in the window (from the section-4 capture; NO
# extra call here). An empty array is a real zero (confirmed live — sources=alert 200s with
# events:[] on a genuinely quiet org), not a failure signal on its own.
TOTAL_EVENTS="$(jq 'length' "${RAW_DIR}/alert-events.json")"
echo "alert-sourced events in the last ${EVT_WINDOW_DAYS}d: ${TOTAL_EVENTS}"

# Noisiest-monitor ranking (feeds DD-016) — grouped straight from the section-4 capture.
jq '[.[] | select(.monitor_id != null)] | group_by(.monitor_id)
    | map({monitor_id: .[0].monitor_id, event_count: length}) | sort_by(-.event_count)' \
  "${RAW_DIR}/alert-events.json"

# DD-006 fail condition: total is zero AND at least one monitor's own overall_state_modified
# falls inside the SAME window — something transitioned, but no alert event was recorded for
# it. This is the measured, not inferred, proof of a suppressed paging plane.
# NOTE: `fromdateiso8601` REQUIRES the literal "...SSZ" shape and rejects Datadog's real
# "+00:00" offset suffix outright (confirmed live: "does not match format %Y-%m-%dT%H:%M:%SZ"
# on a real timestamp) — every timestamp read in this skill must go through the same
# sub()-normalize-to-Z step before fromdateiso8601, or the comparison silently errors/aborts
# under `set -eu`. Datadog's own timestamps are always UTC, so "+00:00" -> "Z" is exact, not
# an approximation; fractional seconds (seen on `created`) are stripped first.
CUTOFF_EPOCH="$(( $(date -u +%s) - EVT_WINDOW_DAYS * 24 * 3600 ))"
jq --argjson cutoff "$CUTOFF_EPOCH" '
  def to_epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  [.[] | select(.overall_state_modified != null)
   | select((.overall_state_modified | to_epoch) >= $cutoff)
   | {id, overall_state, overall_state_modified}]' "${RAW_DIR}/monitors.json"
# If TOTAL_EVENTS==0 and this list is non-empty: DD-006 fails high, naming the transitioned
# monitor(s) as evidence a page should have fired and did not. If TOTAL_EVENTS==0 and this
# list IS empty: the window was quiet on both sides — record DD-006 as partial ("no alert
# activity to measure this window; re-run after a known state change, or widen the window"),
# never as a pass and never as a fail with no supporting transition.
```

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-007a: placeholder-shaped @handle anywhere in the message. PLACEHOLDER_HANDLES is the
# example set; extend it to whatever generic template your org's monitor packs ship with.
jq -r '[.[] | (.message // "") | scan("@[A-Za-z0-9._-]+")] | flatten | unique
    | map(select(test("(?i)^@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle$|^@handle$")))
    | .[]' "${RAW_DIR}/monitors.json"
jq '[.[] | select((.message // "") | test("(?i)@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle|@handle\\b"))
    | {id, name,
       only_handle_is_placeholder: (([(.message // "") | scan("@[A-Za-z0-9._-]+")] | unique
         | map(select(test("(?i)^@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle$|^@handle$") | not)) | length) == 0),
       service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Severity: `only_handle_is_placeholder == true` is the DD-001 blind spot — this monitor
# passes DD-001's bare "@" test and delivers nothing; critical on a critical-service monitor,
# high otherwise. `only_handle_is_placeholder == false` (a placeholder alongside a real
# handle) is still a finding — Datadog will try to notify the placeholder too — but the real
# handle keeps delivery alive, so it is a hygiene fix, not a blind spot: medium.

# DD-007b: a query containing an un-filled template fragment (the metric name was never
# substituted, so the query can never match real data). PLACEHOLDER_QUERY_RE is the example
# pattern most monitor-pack templates use; adjust to your own template convention.
jq '[.[] | select((.query // "") | test("__[A-Za-z0-9_]*placeholder[A-Za-z0-9_]*__"))
    | {id, name, query}]' "${RAW_DIR}/monitors.json"

# DD-007c: a tag value that is a literal unsubstituted template variable, not a real value.
# `any(test(...))` in the select — NOT a bare `.tags[] | test(...)` — is required: the latter
# emits one row PER MATCHING TAG (a monitor with two "$"-tags prints twice, confirmed live),
# which double-counts the finding; `any(...)` collapses back to one row per monitor.
jq '[.[] | select((.tags // []) | any(test("^\\$")))
    | {id, name, template_tags: [((.tags // [])[] | select(test("^\\$")))]}]' "${RAW_DIR}/monitors.json"
# Blast radius for DD-007b/c: a literal "$service"/"$env" tag or an un-filled query breaks
# every routing/topology join that key feeds (DD-034, DD-035, the coverage matrix) — the
# monitor LOOKS tagged and configured, but the value it carries is not a real one.

# DD-008: over-broad @all/@everyone.
jq '[.[] | select((.message // "") | test("@all\\b|@everyone\\b"))
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Judgment: a deliberate incident-bridge or SEV1-only monitor naming @all is a documented
# choice, not a defect; the finding is the ABSENCE of any narrower handle alongside @all on a
# routine (non-incident-tier) monitor, which pages the whole org for something ordinary.
```
Expect (all three): the listed monitors are real config, joined to their `service:` tag exactly like the other Phase-3 checks — never a bare count. Remediation is inline (no `setup-datadog` ships): DD-006 → trigger a controlled test breach and confirm an event appears; DD-007 → replace the placeholder handle/query fragment/tag value with the real one; DD-008 → replace `@all` with the owning team's handle, or record why the breadth is deliberate.

## 6. Monitor noise (DD-010 to DD-019)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-010: monitors with a critical threshold but no critical_recovery (flap risk).
# Carry the notification handle so the blast radius is "where the flap noise lands", not "can flap".
jq '[.[] | select(.options.thresholds.critical != null and (.options.thresholds.critical_recovery == null))
    | {id, name, critical: .options.thresholds.critical,
       handles: [((.message // "") | scan("@[A-Za-z0-9._-]+"))]}]' "${RAW_DIR}/monitors.json"
# Judgment: recovery thresholds matter most on metric monitors that hug their threshold;
# a monitor that recovers on the same value it fires on will flap. Some monitor types
# have no recovery concept (event/composite) — exclude those, do not fail them.
# Blast radius — compute it, do not assert "can flap": join the no-recovery set to each
# monitor's @handle. The finding is "these N flap-prone monitors route to @pagerduty-oncall,
# the same handle carrying the real payments page" — the noise lands on the paging path.
# Per-monitor flap COUNT is an acknowledged ceiling (it lives in state history this audit
# samples but does not exhaustively reconstruct), so do NOT invent a count: corroborate with
# Datadog's own high-alert-volume quality signal from monitor-quality.json (DD-015 reads the
# same array). The `quality_issues[]` member strings are confirmed live against a real org:
# `alerted_too_long` (stuck / alerting too long), `broken_at_handle` / `missing_at_handle`
# (dead or missing recipient), and `muted_duration_over_sixty_days`. Use `alerted_too_long` /
# `broken_at_handle` to corroborate a concentrated handle; the handle-join blast radius above
# stands on its own regardless. Correlation: chains into
# DD-016 (receiver noise concentration) and DD-012 (renotify) — the alert-fatigue cascade.

# DD-011: no-data handling. Emit the table, then ISOLATE the dangerous case — do not delegate
# the judgment to the reader.
jq '[.[] | {id, name, type,
    notify_no_data: .options.notify_no_data,
    no_data_timeframe: .options.no_data_timeframe, on_missing_data: .options.on_missing_data,
    overall_state,
    service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# The real gap, computed: monitors with notify_no_data=false that are heartbeat/liveness-shaped
# on a critical service (join service: tag + monitor type/name) — those services can die
# silently — PLUS monitors persistently in overall_state=="No Data" (the metric stopped
# emitting). Blast radius names the heartbeats that will NOT fire when the service goes dark,
# e.g. "service:checkout liveness monitor has notify_no_data=false, so checkout going fully
# down produces no page". Judgment: notify_no_data=false is a blind spot on a heartbeat, correct
# on a spiky business metric — judge by intent, never a blanket rule. Correlation: a
# no-data-off heartbeat is subtracted from the DD-033 effective-coverage flagship, and a monitor
# stuck in "No Data" is the sibling of the DD-017 stuck-in-Alert state.

# DD-012: unbounded renotification (a POSITIVE renotify_interval with no occurrence cap = forever)
# renotify_interval=0 (or absent) means renotification is DISABLED in Datadog, NOT unbounded — so
# `// 0` the field and require > 0 before flagging, else every never-renotifying monitor is a
# false positive (live: 11 monitors carry renotify_interval=0 and must not be flagged as uncapped).
jq '[.[] | select((.options.renotify_interval // 0) > 0 and (.options.renotify_occurrences == null))
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

### 6.1 Receiver noise concentration and stuck-in-alert (DD-016, DD-017)

> **Live-verified (read-only).** Run against a live Datadog org: monitors carry `overall_state` (observed both `OK` and real `Alert` states) and `last_triggered`/notification handles, so DD-017 (stuck-in-Alert that never re-pages) and the DD-016 handle→monitor concentration map are proven against real data. The `quality_issues[]` corroboration member strings are now **confirmed live** too — a real org carried them on 36/38 monitors: `broken_at_handle`, `missing_at_handle`, `alerted_too_long` (the real "stuck/alerting-too-long" member — not `stuck`), and `muted_duration_over_sixty_days`. DD-016/DD-017 score off the grounded concentration/stuck-state computations; these vendor members are corroboration on top.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-016: build a handle -> [monitor ids] concentration map from the @handles in the
# captured messages (NO extra API call, NO enum strings — this is the load-bearing part).
jq '[.[] | . as $m | ((.message // "") | scan("@[A-Za-z0-9._-]+")) | {handle: ., id: $m.id, name: $m.name}]
    | group_by(.handle)
    | map({handle: .[0].handle, monitor_count: length, monitor_ids: [.[].id]})
    | sort_by(-.monitor_count)' "${RAW_DIR}/monitors.json"
# The top rows are the concentration points: a handle carrying 47 monitors is where a real
# page competes with noise. Intersect each concentrated handle's monitor set with the "noisy"
# set to compute the blast radius. Build the noisy set from THIS audit's own grounded findings
# first — the DD-010 no-recovery (flap-prone) set and the DD-012 unbounded-renotify set — so
# the finding stands without any unverified vendor string:
#   "handle @pagerduty-oncall carries 47 monitors, 12 of them DD-010 flap-prone, sharing the
#    route with the 3 monitors that page for payments-down — the real pages are buried."
# Corroborate with Datadog's own quality flags (member strings CONFIRMED live against a real org
# via `GET /api/v1/monitor/search?per_page=1000 | jq '[.monitors[]?.quality_issues[]?]|unique'`):
jq '[.[] | select((.quality_issues | tostring) | test("broken_at_handle|missing_at_handle|alerted_too_long"))
    | {id, name, quality_issues}]' "${RAW_DIR}/monitor-quality.json"
# `broken_at_handle`/`missing_at_handle` corroborate a dead/missing recipient on a concentrated
# handle; `alerted_too_long` corroborates a monitor whose volume buries the real pages. The
# DD-010/DD-012 intersection above remains the load-bearing finding; this is corroboration.

# DD-017: monitors stuck in overall_state == "Alert" — they never transition, so a NEW breach
# on the same monitor produces no fresh page. overall_state and last_triggered_ts (the state
# transition time, aliased in section 4 — there is NO overall_state_modified key) are both
# already captured; compute the stuck window from the AGE of last_triggered_ts, never assert it.
jq '[.[] | select(.overall_state == "Alert")
    | {id, name, overall_state, since: .last_triggered_ts,
       service: [((.tags // [])[] | select(startswith("service:")))]}]' "${RAW_DIR}/monitors.json"
# Blast radius: join the long-stuck set to service: tag/criticality — "the service:checkout
# error-rate monitor has been in Alert since <last_triggered_ts>; a new checkout incident
# produces no new page". Correlation: DD-011 (persistent No Data is the sibling stuck state)
# and DD-033 (a permanently-firing monitor is subtracted from effective coverage — it cannot
# signal a new incident). Corroborate with the vendor's stuck/alerting-too-long flag (the real
# member string is `alerted_too_long`, CONFIRMED live — not `stuck`):
jq '[.[] | select((.quality_issues | tostring) | test("alerted_too_long")) | {id, name, quality_issues}]' \
  "${RAW_DIR}/monitor-quality.json"
# `alerted_too_long` is Datadog's own signal for a monitor stuck alerting; it corroborated 4 of
# the live overall_state=="Alert" monitors. The overall_state filter above is the grounded finding.
```

Healthy: no notification handle concentrates many noisy monitors alongside the monitors that page for a critical service; no monitor sits in `Alert` long enough that a fresh breach cannot re-page. Fail (DD-016, high): a handle carrying the real critical-service pages is dominated by flap-prone/renotify-heavy monitors — name the handle, the monitor_count, the noisy count, and the buried critical monitors. Fail (DD-017, medium): a monitor stuck in `Alert` on a critical service — name the monitor, the service, and how long (from `last_triggered_ts`). Remediation is inline (no `setup-datadog` ships): DD-016 → split the noisy monitors onto a separate ticket/low-urgency route or tune them (recovery threshold, renotify cap) so the real page is not buried; DD-017 → fix the stuck monitor's query or thresholds so it can recover and re-alert (Monitor edit > Advanced options).

### 6.2 Ratio volume floor and impossible thresholds (DD-018, DD-019)

> **Live-verified (read-only).** Both matched the SAME real query on a live org: an `errors.as_count() / hits.as_count() > 0.1` ratio with no volume floor (DD-018), on a monitor that also, separately, is one of a set of duplicate monitors on the same base metric (DD-036) — and a sibling monitor on that same base metric carried `> 0`/`> -100` thresholds against a structurally non-negative percentage metric (DD-019), one of which was observed live sitting in `overall_state == "Alert"` — the exact stuck-in-Alert symptom DD-017 flags, with DD-019 supplying its root cause.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-018: a ratio of two .as_count() terms with a bare threshold and no composite AND
# clause enforcing a minimum denominator. The character class between the two as_count()
# calls must be permissive (a Datadog scope segment carries `{`, `}`, `*`, digits — a
# narrower class silently never matches a real scoped query, confirmed live).
jq '[.[] | select((.query // "") | test("as_count\\(\\)\\s*/\\s*.*as_count\\(\\)"))
    | select((.query // "") | test("(?i)\\band\\b.*(count|hits|requests|total)\\s*(>=|>)\\s*[0-9]") | not)
    | {id, name, query, service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# Blast radius: name the threshold and the missing floor, e.g. "the checkout error-rate
# monitor pages at 10% with no minimum hits — 1 error in 9 hits crosses it exactly as
# confidently as 1,000 errors in 9,000, but the two mean very different things at 3am."

# DD-019: comparator/threshold pairs that can never recover, or are structurally guaranteed
# true. NONNEG_METRIC_HINTS is an example list of metric-name fragments this audit treats as
# "structurally non-negative" (a percentage, a count, a rate); extend it to your own naming.
# Both disjuncts of the `select` MUST be independently parenthesized around their own
# `(.query // "") | test(...)` — jq's `|` binds looser than `or`, so `X | test(A) or Y` is
# `X | (test(A) or Y)`, and Y's own `.query` reference then indexes the STRING `X` piped in,
# not the monitor object (confirmed live: "Cannot index string with string \"query\"" —
# every branch needs its own `(.query // "") | test(...)` wrapped in parens, never chained
# through a shared pipe into an `or`). The zero-threshold test also requires a trailing
# `(\.0+)?(\s*$|[^.0-9])` guard: a bare `0\b` matches inside "0.8" (word boundary sits
# between "0" and "."), which would misflag a real 80% threshold as tautological — confirmed
# live and fixed with the guard below.
NONNEG_METRIC_HINTS="cpu|disk|memory|mem\\.|pct|percent|usage|count|rate|util"   # example, tune
jq --arg hints "$NONNEG_METRIC_HINTS" '[.[]
    | select(.type == "metric alert" or .type == "query alert")
    | select( ((.query // "") | test("(>=?)\\s*(-[0-9]+(\\.[0-9]+)?)"))
        or (((.query // "") | test("(?i)(\($hints))"))
            and ((.query // "") | test(">=?\\s*0(\\.0+)?(\\s*$|[^.0-9])"))) )
    | {id, name, query, overall_state, since: .last_triggered_ts}]' "${RAW_DIR}/monitors.json"
# Blast radius: an impossible/tautological threshold is a monitor that CANNOT signal a new
# breach — join to overall_state=="Alert" (DD-017) to show it is not just theoretically
# unrecoverable but observably stuck right now. Judgment: `hints` is a heuristic on the
# metric name, not a guarantee; a metric that legitimately can go negative (a delta, a
# forecast residual) is a false positive worth excluding by name, not by disabling the rule.
```
Expect: DD-018 lists ratio queries with no accompanying volume guard, joined to the affected service. DD-019 lists queries whose comparator/threshold pair cannot be satisfied in the healthy direction, joined to the CURRENT `overall_state` so a reader can see whether it is already manifesting as a stuck monitor. Remediation is inline (no `setup-datadog` ships): DD-018 → add a composite `AND` clause on a minimum denominator; DD-019 → set a threshold the metric can actually recover past — check DD-017 for any monitor this also unblocks.

## 7. Muting and downtime (DD-020 to DD-023)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"

# DD-020: indefinitely muted monitors. options.silenced is a map of scope->until-timestamp;
# a value of 0 or null means muted with no end. Read the KEYS (the muted scope) and the
# service: tag, not just the fact of a mute.
jq '[.[] | select((.options.silenced // {}) | to_entries | any(.value == null or .value == 0))
    | {id, name,
       muted_scopes: [((.options.silenced // {}) | to_entries[] | select(.value == null or .value == 0) | .key)],
       service: [((.tags // [])[] | select(startswith("service:")))],
       silenced: .options.silenced}]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — name WHAT is muted, not just "is muted": a muted_scope of "*"
# on a service:payments monitor means payments alerting is FULLY suppressed with no end; a
# single muted host (e.g. "host:web-3") is a partial gap. The muted-scope key alongside the
# service tag is the blast radius. Corroborate since-when with Datadog's own
# `muted_duration_over_sixty_days` quality member (CONFIRMED live — it flagged 36/38 monitors on
# a real org, and is exactly how an org-wide open-ended downtime shows up as a per-monitor mute).
# Correlation: this set is a DD-033 suppressor and may double-count with a DD-021 downtime
# silencing the same monitor — name whichever suppressor is active.

# DD-021 + DD-022: downtimes that are broad and open-ended (no end, wide scope)
jq '[.[] | select(.status == "active" or .status == "scheduled")
    | select(.end == null) | {id, scope, status, monitor_identifier}]' "${RAW_DIR}/downtimes.json"
# Judgment: an active downtime with end=null and a scope like "*" or "env:prod" mutes
# whole environments open-ended — a permanent blind spot, not maintenance. A tightly
# scoped recurring maintenance window is fine; name scope + end in the finding either way.

# DD-021 blast radius — the single highest-value sub-computation: what does that scope
# silence RIGHT NOW? For each active/scheduled end=null downtime, take its scope (a list of
# tag terms like ["env:prod"] or ["*"]) and join it against every monitor's tags to enumerate
# the exact monitor ids and service: tags it currently suppresses.
jq --slurpfile mons "${RAW_DIR}/monitors.json" '
  ($mons[0] // []) as $M
  | [.[] | select((.status == "active" or .status == "scheduled") and .end == null)
     | . as $dt
     | (if ($dt.scope|type)=="array" then $dt.scope else [$dt.scope] end) as $terms
     | ($M | map(select(
         ($terms | any(. == "*"))
         or (.tags // []) as $mt | ($terms | all(. as $t | ($t == "*") or ($mt | index($t)))) ))) as $hit
     | {downtime: $dt.id, scope: $dt.scope,
        silenced_monitor_count: ($hit | length),
        silenced_services: ($hit | map((.tags // [])[] | select(startswith("service:"))) | unique)}]' \
  "${RAW_DIR}/downtimes.json"
# The finding line is computed, not asserted: "one env:prod open-ended downtime silences 47 of
# 60 prod monitors including all 4 service:payments monitors". silenced_monitor_count and
# silenced_services come straight from the tag-match join. Correlation: this join feeds the
# DD-033 effective-coverage flagship — a downtime that silences a critical service's only
# monitor is the same blind spot the flagship reports. Remediation is inline (no setup-datadog
# ships): Downtimes list — add a schedule end timestamp and narrow the scope to the actual
# maintenance target (host/service), not env:prod or *.
```

### 7.1 Downtime intent decay (DD-023)

> **Live-verified (read-only).** Matched a real downtime on a live org: `status: "active"`, `end: null`, `created` well over `DOWNTIME_DECAY_DAYS` in the past, and a `message` reading as a temporary note that asked for its own deletion — every field this check reads (`status`, `schedule.end`, `attributes.created`, `attributes.message`) came back exactly as captured in section 4, no extra call.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
DOWNTIME_DECAY_DAYS="30"   # example, tune to your change-management cadence

# DD-023: active, open-ended downtimes whose age has outlived a temporary-sounding message.
jq --arg re '(?i)test|temp|safe to delete|debug' '
  def to_epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  [.[] | select(.status == "active" and .end == null and .created != null)
     | select(((.created | to_epoch)) as $c | (now - $c) > (30 * 24 * 3600))
     | select((.message // "") | test($re))
     | {id, status, end, created, message, age_days: (((now - (.created | to_epoch)) / 86400) | floor)}]' \
  "${RAW_DIR}/downtimes.json"
# Judgment: the age threshold and the message regex are both examples — tune DOWNTIME_DECAY_DAYS
# to your own change-management cadence, and extend the word list if your team uses a different
# convention for "this is temporary" (e.g. "WIP", "revert me"). A downtime that says "temporary"
# and is still active well past the decay window did not stay temporary; someone meant to
# clean it up and did not. This is the SAME permanent-blind-spot shape DD-021/DD-022 already
# score — DD-023 adds the evidence of intent (the message) and the evidence of neglect (the
# age), so the finding names WHY it happened, not just that it did. Correlation: shares its
# downtime set with DD-021's tag-join; a DD-023 hit on a downtime that also silences a
# critical service is the same row DD-033 already subtracts, just with the decay context added.
```
Expect: `[]` on a healthy estate — every open-ended downtime either has a non-temporary-sounding message, or is younger than `DOWNTIME_DECAY_DAYS`. A non-empty result names the downtime's age and its own message as the evidence. Remediation is inline (no `setup-datadog` ships): Downtimes list — cancel it now if the maintenance is over, or replace it with a properly scoped, time-bound downtime if the suppression is genuinely still needed.

## 8. Coverage and staleness (DD-030 to DD-038)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
STALE_DAYS="180"   # example, tune to your monitor churn

# DD-031: composite monitors whose constituent IDs no longer resolve.
# Composite monitor queries reference other monitor ids like "12345 && 67890".
ALL_IDS="$(jq '[.[].id]' "${RAW_DIR}/monitors.json")"
jq --argjson all "$ALL_IDS" '[.[] | select(.type == "composite")
    | {id, name, service: [((.tags // [])[] | select(startswith("service:")))],
       referenced: [.query // "" | scan("[0-9]{3,}") | tonumber],
       missing: ([.query // "" | scan("[0-9]{3,}") | tonumber] - $all)}
    | select((.missing | length) > 0)]' "${RAW_DIR}/monitors.json"
# Expect: []. Blast radius — say WHAT breaks, not just "references a deleted monitor": a
# composite whose constituent id no longer resolves evaluates only on its surviving terms
# (commonly never re-alerts), so name the composite's service: tag and what it gates —
# "the service:payments aggregate alert references deleted monitor 8842291 and now mis-evaluates,
# so the combined payments-degraded condition never fires". Correlation: chains to DD-001 (a
# composite with no @handle) and the DD-033 flagship.

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
# Blast radius — name the SLO target, the service, and whether the budget is ALREADY burning,
# not just "no monitor". For each uncovered SLO, read its trailing SLI vs target from the
# SLO-history endpoint (read-only GET) and state it:
#   SLO_ID="<uncovered slo id>"
#   FROM_TS=$(date -u -v-30d +%s 2>/dev/null || date -u -d '30 days ago' +%s)
#   TO_TS=$(date -u +%s)
#   curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
#     "https://${DD_HOST}/api/v1/slo/${SLO_ID}/history?from_ts=${FROM_TS}&to_ts=${TO_TS}" \
#     | jq '{target: .data.thresholds, sli: .data.overall.sli_value}'
# Yields "payments 99.95% SLO has no burn-rate monitor and its trailing-30d SLI is 99.90%,
# already breaching, with no page firing". The history read is a LIVE number — mark that part
# validated-live; the uncovered-SLO join itself is offline over slos.json. Correlation: feeds
# DD-033 and chains to DD-001 when the SLO's service also has an unrouted monitor. Remediation
# is inline (no setup-datadog ships): SLO edit — attach or create a burn-rate/error-budget
# monitor referencing the SLO id.

# DD-034: monitor tag hygiene — service/team tags for routing
jq '[.[] | select((.tags // []) | (any(startswith("service:")) or any(startswith("team:"))) | not)
    | {id, name, tags}]' "${RAW_DIR}/monitors.json"
# Blast radius — compute the routing consequence, not a hygiene count: when the org has
# notification rules that route by service:/team: tag (DD-004), an untagged monitor matches
# NO rule and falls through to the default route or nowhere. Join the untagged set against the
# DD-004 fall-through result: the count of monitors that silently do not route under the org's
# OWN rules is the finding, e.g. "9 untagged monitors match no notification rule and route only
# by inline handles". When the org has no tag-routing rules, DD-034 stays a low aggregate
# quality signal (attribution, not delivery). Correlation: chains to DD-004 and DD-033.
```

**DD-030 (stale monitors) — distinguish a correctly-quiet monitor from a dead one.** Age alone is a linter line. Pair a never-fired/ancient `last_triggered_ts` with `overall_state`: a monitor stuck in persistent `No Data` because its metric was renamed or removed is a *silent coverage hole*, not a quiet-but-healthy monitor. Join to service criticality to name which critical service lost a metric.

```bash
STALE_DAYS="180"   # example, tune to your monitor churn
STALE_BEFORE="$(date -u -v-${STALE_DAYS}d +%s 2>/dev/null || date -u -d "${STALE_DAYS} days ago" +%s)"
jq --argjson cutoff "$STALE_BEFORE" '[.[]
    | select(((.last_triggered_ts // 0) < $cutoff))
    | {id, name, overall_state, last_triggered_ts,
       service: [((.tags // [])[] | select(startswith("service:")))],
       likely_dead: (.overall_state == "No Data")}]' "${RAW_DIR}/monitors.json"
```
A `likely_dead: true` row on a critical service is the real finding (a vanished metric = a blind spot); a stale-but-OK row is a note. Remediation is inline (no setup-datadog ships): Monitor edit — retire truly-dead monitors, repair the metric query where the underlying metric vanished. Correlation: chains to DD-011 (no-data) and the DD-033 flagship.

### 8.1 DD-033 — effective-coverage flagship (the differentiator no free scanner assembles)

DD-033 is NOT a flat "these critical services have no monitor" list. Filed that way it overstates coverage exactly the way the Datadog UI's green monitor count does. Make it the **effective-coverage set-difference**: per critical service, start from the monitors tagged `service:X`, then subtract every monitor that cannot deliver a page tonight. What remains is the count that would actually reach a human.

Per critical service `X` (from topology.md):

```
effective_monitors(X) =
    monitors tagged service:X
  − drafts                                   (DD-003 set)
  − monitors with no REAL @handle            (DD-001 set, now also excludes a
                                               placeholder-only handle — DD-007)
  − monitors whose handle no longer resolves (DD-002 / broken_at_handle set)
  − indefinitely-silenced monitors           (DD-020 set)
  − monitors whose tags match an active end=null downtime's scope (DD-021 tag-join)
  − heartbeats with notify_no_data=false     (DD-011 heartbeat subset)
```

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
# CRIT_SERVICES is the topology.md critical-service list (JSON array of service names).
CRIT_SERVICES='["payments","checkout"]'   # example; replace from topology.md
jq -n --argjson crit "$CRIT_SERVICES" \
  --slurpfile mons "${RAW_DIR}/monitors.json" \
  --slurpfile downtimes "${RAW_DIR}/downtimes.json" \
  --slurpfile quality "${RAW_DIR}/monitor-quality.json" '
  # A REAL @handle: at least one @-token, AND at least one of those tokens is not
  # placeholder-shaped (folds DD-001s bare "has an @" test together with DD-007s
  # placeholder detection, so a monitor whose only handle is `@your-team-handle` no
  # longer counts as delivering — confirmed live this is a real gap DD-001 alone misses).
  def has_real_handle:
    ([.message // "" | scan("@[A-Za-z0-9._-]+")]) as $h
    | ($h | length) > 0
      and (($h | map(select(
            test("(?i)^@(your|example|replace-?me|team-?name)[-_a-z0-9]*handle$|^@handle$") | not
          ))) | length) > 0;
  ($mons[0] // []) as $M
  | ($downtimes[0] // []) as $D
  | ($quality[0] // []) as $Q
  # broken_at_handle monitor ids (the one PROVEN quality member — section 4)
  | ([$Q[] | select((.quality_issues | tostring) | test("broken_at_handle")) | .id]) as $deadHandle
  # active/scheduled open-ended downtimes, as scope-term lists
  | ([$D[] | select((.status=="active" or .status=="scheduled") and .end==null)
       | (if (.scope|type)=="array" then .scope else [.scope] end)]) as $dtScopes
  | [ $crit[] as $svc
    | ($M | map(select((.tags // []) | index("service:"+$svc)))) as $svcMons
    # bind each monitor as $mon: inside the $dtScopes any(...) the context `.` is the scope
    # term-list, so the monitor must be referenced as $mon, never `.`.
    | ($svcMons | map(. as $mon | select(
        ($mon.draft_status != "draft")                               # not a draft
        and ($mon | has_real_handle)                                 # DD-001 + DD-007
        and (([$mon.id] | inside($deadHandle)) | not)                # handle resolves
        and ((($mon.options.silenced // {}) | to_entries | any(.value==null or .value==0)) | not)  # not indefinitely muted
        and (($dtScopes | any(. as $terms                            # not under an open-ended downtime
              | ($terms | any(. == "*"))
              or ($terms | all(. as $t | ($t=="*") or (($mon.tags // []) | index($t)))))) | not)
        and (($mon.options.notify_no_data == false) | not)          # heartbeats with no-data OFF drop out
      ))) as $effective
    | {service: $svc,
       inventory_monitors: ($svcMons | length),
       effective_monitors: ($effective | length),
       effective_ids: ($effective | map(.id))} ]' 
# The output line is the differentiator: "service:payments shows 8 monitors in the Datadog UI
# but 0 that reach a human tonight" — then name each suppressor (2 drafts, 1 dead Slack handle,
# 3 under the open-ended env:prod downtime, 2 heartbeats with no-data off) with the exact monitor
# id/handle/downtime scope as evidence, citing the DD-021 downtime tag-join count. Every critical
# service must be effective_monitors >= 1. Score coverage on EFFECTIVE monitors, never inventory.
```

This is the direct Datadog analog of audit-kubernetes's external→cluster-secrets path (K8S-010): a single computed chain the customer's own console cannot show, because the UI shows 8 green monitors and gives no way to see the service is effectively unmonitored. Remediation is inline (no setup-datadog ships): restore at least one live-delivering, unmuted, un-downtimed, non-draft monitor per critical service (add/repair an @handle, publish the draft, unmute, or scope the downtime — whichever suppressors this join named). Verification: recompute `effective_monitors` from a fresh raw pull; every critical service must be `>= 1`.

**Live-caught interaction (worth stating in the report when it recurs):** the SAME `end == null`, `scope: "*"` downtime that DD-021/DD-022/DD-023 flag on its own also collapses `effective_monitors` to 0 for every critical service in this join, because a `"*"` scope term matches every monitor's tags unconditionally. One suppressor can zero out the whole flagship at once; when it does, name that single downtime as the root cause across all three findings rather than reporting three unrelated-looking gaps.

### 8.2 Scope consistency, duplication, never-evaluated, and paused Synthetics (DD-035 to DD-038)

> **Live-verified (read-only).** DD-035 matched a real monitor on a live org whose query scope named one value for a tag key (e.g. `cluster_name:a`) while the monitor's own tag for that same key carried a different value (`cluster_name:b`) — the query is what actually evaluates; the tag is what this toolkit's own topology join and DD-034 trust. DD-036 matched four real published monitors sharing the identical normalized base metric and scope, differing only in window and threshold. DD-037 matched four real monitors created weeks earlier, still `No Data` with `overall_state_modified == null`. DD-038 matched two real paused Synthetic tests each still linked (via `monitor_id`) to an unmuted monitor whose `overall_state` reflects only its last real evaluation, not the pause.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
NEVER_EVALUATED_DAYS="7"   # example, tune to your rollout cadence

# DD-035: a monitor's query scope names a key:value that its OWN tags contradict.
# `capture("\\{(?<scope>[^}]*)\\}")` takes the FIRST {...} block in the query — the scope
# filter immediately after the metric name, never a later `by {...}` grouping clause (the
# grouping clause has bare keys with no `:value`, so it never produces a spurious term here).
jq '[.[] | . as $mon
   | ((.query // "") | capture("\\{(?<scope>[^}]*)\\}").scope) as $scope
   | ([$scope // "" | scan("([A-Za-z0-9_]+):([A-Za-z0-9_.-]+)")] | map({(.[0]): .[1]}) | add // {}) as $qterms
   | ($mon.tags // [] | map(split(":")) | map(select(length==2)) | map({(.[0]): .[1]}) | add // {}) as $tterms
   | ($qterms | to_entries
      | map(select(.key as $k | $tterms[$k] != null and $tterms[$k] != .value))
      | map({key: .key, query_value: .value, tag_value: $tterms[.key]})) as $mismatch
   | select(($mismatch | length) > 0)
   | {id: $mon.id, name: $mon.name, mismatch: $mismatch}]' "${RAW_DIR}/monitors.json"
# Blast radius: name the exact key and the two values — "the checkout-latency monitor's query
# scopes to cluster_name:prod-a but its own cluster_name tag says prod-b" — this is a routing/
# topology join hazard (DD-034, the coverage matrix, map-topology's service-name join), not a
# cosmetic label problem: whatever trusts the tag is looking at the wrong resource.

# DD-036: duplicate monitors — normalize by stripping the leading agg(window): prefix and the
# trailing comparator+threshold, then group by (expression, scope).
jq '[.[] | select(.type=="metric alert" or .type=="query alert")
   | . as $mon
   | ((.query // "")
      | sub("^[a-z_]+\\([^)]*\\):\\s*"; "")
      | sub("\\s*[<>=!]+\\s*-?[0-9]+(\\.[0-9]+)?\\s*$"; "")) as $norm
   | {id: $mon.id, name: $mon.name, norm: $norm}]
  | group_by(.norm) | map(select(length>1))
  | map({normalized_expression: .[0].norm, monitor_ids: map(.id), count: length})' \
  "${RAW_DIR}/monitors.json"
# Blast radius: name the expression and every id in the group, and check whether their
# thresholds have drifted apart (a DD-019 tautological threshold hiding next to a healthy
# duplicate is a documented live pattern, not a hypothetical one).

# DD-037: never-evaluated monitors, distinct from DD-030 (evaluated fine, then went stale).
NEVER_EVAL_CUTOFF="$(( $(date -u +%s) - NEVER_EVALUATED_DAYS * 24 * 3600 ))"
jq --argjson cutoff "$NEVER_EVAL_CUTOFF" '
  def to_epoch: sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
  [.[] | select(.overall_state=="No Data" and .overall_state_modified==null and .created != null)
     | select((.created | to_epoch) < $cutoff)
     | {id, name, created, service: [((.tags // [])[] | select(startswith("service:")))]}]' \
  "${RAW_DIR}/monitors.json"
# Blast radius: `overall_state_modified == null` means the monitor has NEVER transitioned
# state even once — it did not go quiet after working, it never started. Join to service
# criticality: coverage that looked provisioned in the UI and never actually turned on.

# DD-038: a paused Synthetic test still backing an unmuted, live-reporting monitor.
jq -n --slurpfile mons "${RAW_DIR}/monitors.json" --slurpfile synth "${RAW_DIR}/synthetics.json" '
  ($mons[0] // []) as $M
  | ($synth[0] // []) as $S
  | [ $S[] | select(.status == "paused" and .monitor_id != null) as $t
      | ($M | map(select(.id == $t.monitor_id)) | .[0]) as $mon
      | select($mon != null)
      | select((($mon.options.silenced // {}) | to_entries | any(.value==null or .value==0)) | not)
      | {synthetic_public_id: $t.public_id, monitor_id: $mon.id, monitor_name: $mon.name,
         monitor_overall_state: $mon.overall_state,
         service: [(($mon.tags // [])[] | select(startswith("service:")))]} ]'
# Blast radius: the monitor's overall_state reflects only its LAST real evaluation before the
# Synthetic was paused — an "OK" state here is not proof of health, it is a frozen snapshot.
# Join to service criticality; a paused Synthetic behind a critical service's only monitor is
# the DD-033-shaped blind spot with an extra twist: the console shows green because nothing
# has told it otherwise, not because anything is actually being checked.
```
Expect: `[]` on all four when the estate is clean. Remediation is inline (no `setup-datadog` ships): DD-035 → set the tag to the value the query scope actually evaluates against; DD-036 → retire the redundant monitor or reconcile the drifting thresholds; DD-037 → confirm the metric/integration is actually emitting, repair the query if not; DD-038 → resume the Synthetic, or mute/retire the monitor it backs.

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
# Top custom-metric contributors (custom metrics are a common surprise cost).
# top_avg_metrics REQUIRES a `month` (or `day`) param: without it the API returns
# HTTP 400 "The parameter 'month/day' is required" every run. `month` is ISO-8601, UTC,
# precise to the hour (YYYY-MM-DDTHH); pass the first hour of the current month
# (e.g. 2026-08-01T00). Use `day=YYYY-MM-DD` instead for a single-day slice.
USAGE_MONTH="$(date -u +%Y-%m-01T00)"
curl -fsS --max-time 30 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/usage/top_avg_metrics?month=${USAGE_MONTH}&limit=20" \
  | jq '[.usage[]? | {metric_name, avg_metric_hour}]' \
  || echo "top_avg_metrics not readable"
```

Report presence facts only where no dollar figure is backed by the API; never estimate savings the platform did not compute.

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `STALE_DAYS` | 180 | Never-triggered window before a monitor is stale-flagged |
| `EVT_WINDOW_DAYS` | 30 | Trailing window for the DD-006 measured alert-event volume check |
| `DOWNTIME_DECAY_DAYS` | 30 | Age past which an active, open-ended, temporary-worded downtime is flagged (DD-023) |
| `NEVER_EVALUATED_DAYS` | 7 | Age past which a monitor that never transitioned state once is flagged (DD-037) |
| `NONNEG_METRIC_HINTS` | `cpu\|disk\|memory\|mem\.\|pct\|percent\|usage\|count\|rate\|util` | Metric-name fragments treated as "structurally non-negative" for DD-019 |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. Never run:

- Any `PUT`, `PATCH`, or `DELETE` — none exist in this skill's surface. The single `POST` this skill sends (`POST /api/v2/events/search`, DD-006) is a read-by-effect query exactly like PagerDuty analytics — classify by effect, not verb (section 1) — and searches events, creating nothing; every OTHER mutating verb, and every other POST, is out.
- Creating, editing, deleting, muting, or resolving monitors; `POST /api/v1/monitor/{id}/mute` or `/unmute`; creating or canceling downtimes.
- Editing SLOs, notification rules, config policies, integrations, dashboards, or Synthetic tests; resuming or pausing a Synthetic test (DD-038 reads its `status`, never changes it).
- `POST /api/v1/monitor/validate` (validates a monitor body you would be composing; setup-lane).
- Sending any test notification or event (`POST /api/v1/events`) — note this is the write counterpart of the read-only `GET /api/v1/events` DD-006 uses; never confuse the two.
