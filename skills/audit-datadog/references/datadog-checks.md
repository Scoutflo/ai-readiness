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
| DD-005 | Monitor delivery | Critical-service monitors carry a `priority` (P1-P5) so paging can be tiered, not flat | medium |
| DD-010 | Monitor noise | Recovery thresholds set where a monitor has a warning/critical threshold (`critical_recovery`) | medium |
| DD-011 | Monitor noise | No-data handling deliberate (`notify_no_data`, `no_data_timeframe`, `on_missing_data`) | medium |
| DD-012 | Monitor noise | Renotification bounded, not unlimited (`renotify_interval`, `renotify_occurrences`) | low |
| DD-013 | Monitor noise | Evaluation delay / new-group delay set where the query needs late data | low |
| DD-014 | Monitor noise | Auto-resolve (`timeout_h`) deliberate per monitor type | low |
| DD-015 | Monitor noise | Datadog's own `quality_issues[]` reviewed and reconciled with this audit | info |
| DD-016 | Monitor noise | Receiver noise concentration: the real pages share a handle with many noisy monitors | high |
| DD-017 | Monitor noise | No monitor stuck in `Alert` state so long it can never re-page a new breach | medium |
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/datadog/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
DD_AUTH="-H DD-API-KEY:${DATADOG_API_KEY} -H DD-APPLICATION-KEY:${DATADOG_APP_KEY}"

# All monitors, with the fields every later section keys off. Message carries the
# @handles; options carries the noise controls. No secret is in this payload.
curl -fsS --max-time 60 -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://${DD_HOST}/api/v1/monitor?page_size=1000" \
  | jq '[.[] | {id, name, type, message, query, priority, draft_status: (.draft_status // "published"),
      overall_state, last_triggered_ts: (.overall_state_modified // null),
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
# `last_triggered_ts` — DD-017 reads that key (there is NO `overall_state_modified`
# key retained in this projection, so any check must read `last_triggered_ts`).

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

## 5. Monitor delivery (DD-001 to DD-005)

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

## 6. Monitor noise (DD-010 to DD-017)

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

## 7. Muting and downtime (DD-020 to DD-022)

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

## 8. Coverage and staleness (DD-030 to DD-034)

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
  − monitors with no @handle                 (DD-001 set)
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
        and (($mon.message // "") | test("@"))                       # has an @handle
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

## 13. Forbidden commands

This is an audit: read-only, no exceptions. Never run:

- Any `POST`, `PUT`, `PATCH`, or `DELETE` — Datadog has no read-by-effect POST in this skill's surface (unlike PagerDuty analytics), so every mutating verb is out.
- Creating, editing, deleting, muting, or resolving monitors; `POST /api/v1/monitor/{id}/mute` or `/unmute`; creating or canceling downtimes.
- Editing SLOs, notification rules, config policies, integrations, or dashboards.
- `POST /api/v1/monitor/validate` (validates a monitor body you would be composing; setup-lane).
- Sending any test notification or event (`POST /api/v1/events`).
