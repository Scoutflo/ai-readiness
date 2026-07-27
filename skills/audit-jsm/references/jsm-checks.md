# audit-jsm: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-jsm](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- This is the **JSM Operations REST API v1** on `api.atlassian.com` — the cloud successor to standalone Opsgenie. Base is `https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1`. Do not target `api.opsgenie.com`.
- Auth is an **Atlassian API token over HTTP Basic**: `curl -u "${JSM_EMAIL}:${JSM_API_TOKEN}"`. Presence-check both variables only; never echo, log, or write them. The classic Opsgenie `Authorization: GenieKey <key>` header does not authenticate this API.
- `CLOUD_ID` is resolved once (config `jsm.cloud_id`, else `https://<site>/_edge/tenant_info` returns `.cloudId`) and reused. Every path needs it; a 404 on a valid-looking path usually means the wrong `cloud_id`.
- **Policies and heartbeats are team-scoped.** Notification policies (`/v1/teams/{teamId}/policies?type=notification`), escalations, routing rules, and heartbeats all hang off a team id. Global alert policies (`/v1/alerts/policies`) and maintenance windows (`/v1/maintenances`) are account-wide. Every coverage denominator names the teams audited.
- **Paging is `offset` + `size`**, and the alerts list is hard-capped at `offset + size < 20000`. There is no total-count endpoint for alerts; derive counts from the list within the cap and state the bound.
- Every command here is read-only: GET only. The forbidden-verb list is section 13.
- `curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}"` is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| JSM-001 | Delivery/escalation | Every audited team has an escalation; no production team is a single step with no repeat | critical |
| JSM-002 | Delivery/escalation | Escalation `repeat` and an `if-not-acked` rule present where re-notification is relied on | high |
| JSM-003 | Delivery/escalation | Every routing rule resolves to an enabled, staffed schedule (no empty-schedule join) | high |
| JSM-004 | Delivery/escalation | Schedules referenced are enabled, with a rotation and someone on call now | high |
| JSM-005 | Delivery/escalation | No integration on a live ingestion path is `enabled: false` | critical |
| JSM-010 | Alert noise | Notification-policy dedup (`deduplicationAction`) present where sources are chatty | medium |
| JSM-011 | Alert noise | `delayAction` used deliberately, not as blanket suppression | medium |
| JSM-012 | Alert noise | No permanently-`suppress: true` policy with a broad filter masking real alerts | high |
| JSM-013 | Alert noise | `autoCloseAction` present so alerts do not accumulate stuck-open | medium |
| JSM-014 | Alert noise | `autoRestartAction` not a re-page storm (short `waitDuration` + high `maxRepeatCount`) | medium |
| JSM-015 | Alert noise | Sources set a stable `alias` so dedup collapses repeats | medium |
| JSM-016 | Alert noise | Global/team alert policies present and enabled for normalization and priority | medium |
| JSM-017 | Alert noise | No active maintenance window that is a permanent blackout of a live integration/policy | high |
| JSM-020 | Coverage/health | Heartbeats responsive; no live source in `Unresponsive`/unintended `Off` | critical |
| JSM-021 | Coverage/health | Critical services from topology each covered by a team and a routing path | high |
| JSM-022 | Coverage/health | Teams audited named; teams not audited named as uncovered, not silently dropped | medium |
| JSM-023 | Coverage/health | Stale or disabled integrations identified as drift | low |
| JSM-030 | Actionability | Open alerts unacknowledged past the aging threshold | high |
| JSM-031 | Actionability | MTTA (createdAt to ackTime) against target where humans acked | medium |
| JSM-032 | Actionability | Share of alerts closed with no acknowledgement (auto-close-heavy = noise proxy) | medium |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Alert delivery and escalation**: every audited team has a multi-step escalation with a repeat and an `if-not-acked` rule, every routing rule lands on an enabled schedule with a live rotation, and no live-path integration is disabled — a page always reaches a reachable human.
- **Alert noise**: chatty sources are deduplicated by policy and by stable alias, suppression and delay are narrow and deliberate, auto-close and auto-restart are tuned (no stuck-open pile-up, no re-page storm), alert policies normalize noisy sources, and no maintenance window is a permanent blackout.
- **Coverage and health**: every heartbeat that represents a live source is responsive, every critical service has a team and a routing path, every team is either audited or named as uncovered, and stale integrations are identified rather than trusted.
- **Actionability**: few alerts age unacknowledged, MTTA is within target where humans act, and the share of alerts closed with no acknowledgement is low — pages are worth taking, computed honestly from timestamps within the retrieval cap.

## 4. Inventory (all categories)

Resolve the teams to audit, then capture per team and account-wide.

```bash
set -eu
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${JSM_CLOUD_ID}/v1"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/jsm/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
AUTH_USER="${JSM_EMAIL}:${JSM_API_TOKEN}"

# Teams to audit: jsm.teams from config, else discover. Written to a file the per-team loop
# reads, so this stays stateless. Replace the discovery line with the configured ids.
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams?size=100" \
  | jq -r '.values[]? | "\(.id)\t\(.name)"' > "${RAW_DIR}/teams.tsv"
echo "teams to audit:"; cat "${RAW_DIR}/teams.tsv"

# Account-wide captures (not team-scoped).
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/alerts/policies?size=100" \
  | jq '[.values[]? | {id, name, type, enabled, continue, updatePriority, priorityValue,
      filter: (.filter.type // null)}]' > "${RAW_DIR}/alert-policies.json"
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/maintenances?type=non-expired&size=100" \
  | jq '[.values[]? | {id, status, startDate, endDate,
      rules: [.rules[]? | {entity_type: .entity.type, entity_id: .entity.id, state}]}]' \
  > "${RAW_DIR}/maintenances.json"
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/integrations?size=100" \
  | jq '[.values[]? | {id, name, type, enabled, teamId}]' > "${RAW_DIR}/integrations.json"

# Per-team captures.
while IFS="$(printf '\t')" read -r TEAM_ID TEAM_NAME; do
  [ -n "$TEAM_ID" ] || continue
  tdir="${RAW_DIR}/teams/${TEAM_ID}"; mkdir -p "$tdir"
  curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams/${TEAM_ID}/policies?type=notification&size=100" \
    | jq '[.values[]? | {id, name, enabled, order, suppress,
        deduplicationAction, delayAction, autoCloseAction, autoRestartAction,
        filter: (.filter.type // null)}]' > "${tdir}/notification-policies.json"
  curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams/${TEAM_ID}/escalations?size=100" \
    | jq '[.values[]? | {id, name, enabled, repeat,
        rules: [.rules[]? | {condition, notifyType, delay, recipient_type: .recipient.type}]}]' \
    > "${tdir}/escalations.json"
  curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams/${TEAM_ID}/routing-rules?size=100" \
    | jq '[.values[]? | {id, name, isDefault, order, notify_type: .notify.type, notify_id: .notify.id}]' \
    > "${tdir}/routing-rules.json"
  curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams/${TEAM_ID}/heartbeats?size=100" \
    | jq '[.values[]? | {name, enabled, status, interval, intervalUnit}]' > "${tdir}/heartbeats.json"
done < "${RAW_DIR}/teams.tsv"

# Schedules are account-scoped but carry teamId; capture once.
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/schedules?size=100&expand=rotation" \
  | jq '[.values[]? | {id, name, enabled, teamId, rotation_count: ((.rotations // []) | length)}]' \
  > "${RAW_DIR}/schedules.json"

echo "inventory captured under ${RAW_DIR}"
```

Expected: per-team policy/escalation/routing/heartbeat files plus account-wide alert-policies, maintenances, integrations, and schedules. A 401/403 is an auth finding (bad token, or the user lacks Operations access) for the checks that need it; a 404 means the wrong `cloud_id`.

## 5. Alert delivery and escalation (JSM-001 to JSM-005)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/jsm/${RUN_DATE}/raw"
TEAM_ID="TEAM"   # per-team; loop over teams.tsv in the real run
tdir="${RAW_DIR}/teams/${TEAM_ID}"

# JSM-001 + JSM-002: escalation presence and shape. No escalation at all is critical;
# a single rule with no repeat is a SPOF on a production team.
jq '[.[] | {id, name, rule_count: (.rules | length),
    has_repeat: ((.repeat.count // 0) > 1),
    has_if_not_acked: ([.rules[]? | select(.condition == "if-not-acked")] | length > 0)}]' \
  "${tdir}/escalations.json"
# Expect: rule_count >= 2 OR (has_repeat and has_if_not_acked) on production teams. A team with
# an empty escalations.json ([]) is JSM-001 critical; one rule, no repeat, is the SPOF shape.

# JSM-003: routing rules that notify a schedule — resolve each target schedule's rotation.
jq -r '[.[] | select(.notify_type == "schedule") | .notify_id] | .[]' "${tdir}/routing-rules.json" \
  | while read -r SCHED_ID; do
      jq --arg s "$SCHED_ID" '.[] | select(.id == $s) | {id, name, enabled, rotation_count}' \
        "${RAW_DIR}/schedules.json"
    done
# A routing rule whose target schedule has enabled=false or rotation_count=0 pages nobody:
# JSM-003 high. Name the routing rule and the schedule.

# JSM-004: schedules referenced anywhere that are disabled or have no rotation.
jq '[.[] | select(.enabled == false or .rotation_count == 0) | {id, name, enabled, rotation_count, teamId}]' \
  "${RAW_DIR}/schedules.json"
# Pair with an on-call read to confirm nobody is on call NOW for a referenced schedule:
#   GET ${JSM_BASE}/schedules/{scheduleId}/on-calls  -> empty onCallParticipants = unstaffed now.

# JSM-005: integrations on a live path that are disabled (nothing can create alerts).
jq '[.[] | select(.enabled == false) | {id, name, type, teamId}]' "${RAW_DIR}/integrations.json"
# Expect: []. A disabled integration on a team that relies on it is JSM-005 critical; judge
# against intent (a deliberately-retired integration is drift, JSM-023, not a critical gap).
```

## 6. Alert noise (JSM-010 to JSM-017)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/jsm/${RUN_DATE}/raw"
TEAM_ID="TEAM"; tdir="${RAW_DIR}/teams/${TEAM_ID}"

# JSM-010 + JSM-013 + JSM-014: notification-policy action objects.
jq '[.[] | {id, name, enabled,
    has_dedup: (.deduplicationAction != null),
    dedup_type: (.deduplicationAction.deduplicationActionType // null),
    dedup_count: (.deduplicationAction.countValueLimit // null),
    has_auto_close: (.autoCloseAction != null),
    auto_restart_repeat: (.autoRestartAction.maxRepeatCount // null),
    auto_restart_wait: (.autoRestartAction.waitDuration // null)}]' \
  "${tdir}/notification-policies.json"
# No deduplicationAction on a team with chatty sources = JSM-010. No autoCloseAction = JSM-013
# (alerts pile up stuck-open). autoRestartAction with a short waitDuration and a high
# maxRepeatCount on a paging policy = JSM-014 (re-page storm).

# JSM-011 + JSM-012: delay and blanket suppression.
jq '[.[] | select(.suppress == true or .delayAction != null)
    | {id, name, suppress, filter, delayOption: (.delayAction.delayOption // null)}]' \
  "${tdir}/notification-policies.json"
# A policy with suppress=true AND a broad filter (matches all / no conditions) is JSM-012 high:
# it masks real alerts indefinitely. A narrow, deliberate delayAction is fine (JSM-011 judgment).

# JSM-016: global + team alert policies present and enabled.
jq '[.[] | {id, name, type, enabled, continue, priority_override: .updatePriority}]' \
  "${RAW_DIR}/alert-policies.json"
# No alert policies, or all enabled=false, = JSM-016: nothing normalizes or re-prioritizes
# noisy sources before alerts are created.

# JSM-017: active maintenance windows that disable a live integration or policy.
jq '[.[] | select(.status == "active")
    | {id, status, startDate, endDate,
       disables: [.rules[]? | select(.state == "disabled") | {entity_type, entity_id}]}]' \
  "${RAW_DIR}/maintenances.json"
# An active window with a far-future endDate whose rules disable a real paging integration/policy
# is JSM-017 high: a permanent blackout wearing a maintenance costume. A short bounded window is fine.
```

**JSM-015 (alias dedup)** reads the alert stream: pull a recent page and inspect `alias`/`count`. Many alerts with `count > 1` confirm dedup is collapsing repeats; all-unique or absent aliases mean sources are not setting a stable dedup key (duplication risk).

```bash
set -eu
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${JSM_CLOUD_ID}/v1"
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  "${JSM_BASE}/alerts?size=100&sort=createdAt&order=desc" \
  | jq '{sampled: (.values | length),
      with_alias: ([.values[] | select((.alias // "") != "")] | length),
      deduped: ([.values[] | select((.count // 1) > 1)] | length)}'
# with_alias well below sampled = sources not setting alias (JSM-015). deduped > 0 is healthy
# evidence dedup works. This is a sampled signal within the 20k cap, not a full-history count.
```

## 7. Coverage and health (JSM-020 to JSM-023)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/jsm/${RUN_DATE}/raw"
TEAM_ID="TEAM"; tdir="${RAW_DIR}/teams/${TEAM_ID}"

# JSM-020: heartbeat liveness. Unresponsive = a source stopped pinging (silent monitoring gap).
jq '[.[] | {name, enabled, status}
    | select(.status == "Unresponsive" or (.enabled == true and .status == "Off"))]' \
  "${tdir}/heartbeats.json"
# Expect: []. status "Unresponsive" is critical: the heartbeat's source went dark and nothing
# fired. "Off" with enabled=true is a contradiction worth naming. "Pending" (never reported)
# and a deliberately disabled "Off" are notes, not fails — judge against intent.

# JSM-023: stale or disabled integrations (drift, low).
jq '[.[] | select(.enabled == false) | {id, name, type, teamId}]' "${RAW_DIR}/integrations.json"
# Cross-reference with JSM-005: a disabled integration on a live path is the critical delivery
# gap; one that is simply orphaned/retired is JSM-023 drift.
```

**JSM-021 (critical-service coverage)** is a judgment cross-map: for each critical service from `topology.md`, confirm a team owns it and a routing path reaches a staffed schedule. Name affected services; "three services have no paging path" is not a finding, "checkout, payments, and search have no JSM Operations routing path" is. **JSM-022** is the honesty row: state the teams audited (from `jsm.teams`) and name every team present in `/v1/teams` that was not audited as uncovered in the denominators.

## 8. Actionability (JSM-030 to JSM-032)

No analytics API exists; every figure is computed client-side from alert timestamps within the `offset + size < 20000` cap. State the window and the alert count each figure rests on.

```bash
set -eu
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${JSM_CLOUD_ID}/v1"
AGING_HOURS="4"   # example, tune to your paging SLA

# JSM-030: open alerts never acknowledged. The query language does the filtering server-side.
Q="status: open AND acknowledged: false"
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=${Q}" --data-urlencode "size=100" --data-urlencode "sort=createdAt" \
  "${JSM_BASE}/alerts" \
  | jq --argjson aging "$AGING_HOURS" '[.values[] | {tinyId, message, createdAt, priority}]
      | {unacked_sampled: length, oldest: (min_by(.createdAt).createdAt // null)}'
# Every open+unacked alert older than AGING_HOURS is a page nobody took (JSM-030). Age is
# now - createdAt; compute it against the run time. State the sampled count and window.

# JSM-031 + JSM-032: MTTA and auto-closed share, from a recent closed-alert page.
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=status: closed" --data-urlencode "size=100" \
  --data-urlencode "sort=createdAt" --data-urlencode "order=desc" \
  "${JSM_BASE}/alerts" \
  | jq '{sampled: (.values | length),
      acked: ([.values[] | select(.acknowledged == true and .ackTime != null)] | length),
      closed_unacked: ([.values[] | select(.acknowledged == false and .closeTime != null)] | length),
      mtta_seconds_avg: (([.values[] | select(.acknowledged == true and .ackTime != null and .createdAt != null)
        | ((.ackTime|fromdateiso8601) - (.createdAt|fromdateiso8601))] | add) as $s
        | ([.values[] | select(.acknowledged == true and .ackTime != null)] | length) as $n
        | (if $n > 0 then ($s / $n) else null end))}'
# JSM-031: mtta_seconds_avg against target (only where humans acked). JSM-032: closed_unacked /
# sampled is the share of alerts that closed with no human ack — the honest, timestamp-backed
# proxy for "these pages were noise". Both figures state the sampled size and that it is bounded
# by the 20k retrieval cap, never presented as full-account analytics.
```

## 9. Rate-limit handling (all sections)

JSM Operations publishes no fixed rate-limit numbers; limits are dynamic. On any `429`, honor the `Retry-After` header (seconds), sleep that long, and retry once; on a second `429`, record the affected team's or category's checks as `blocked` with the reason rather than hammering. Do not hardcode a numeric request budget. On the large path, batch by team against the worklist per skill-authoring-conventions.md so a throttle pauses one batch, not the whole run.

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, resolve its owning team and routing path across the audited teams, then fill the matrix row from sections 5-8: delivery (JSM-001/003), noise (JSM-010/012), health (JSM-020), actionability (JSM-030/032). Name affected services and the team each finding is in.

## 11. Reserved

(No section 11 content; numbering preserved so section anchors stay stable if a category is added later.)

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGING_HOURS` | 4 | hours an open alert may sit unacknowledged before JSM-030 flags it |
| `AUTO_CLOSE_SHARE` | 0.30 | closed-unacked share above which JSM-032 flags a team as auto-close-heavy |
| `MTTA_TARGET_MIN` | 15 | target mean-time-to-acknowledge in minutes for JSM-031 |

## 13. Forbidden commands

This is an audit: read-only, GET only, no exceptions. Never run:

- Any `POST`/`PUT`/`PATCH`/`DELETE` against `/v1/alerts/*` (ack, close, snooze, assign, add-note, create).
- Any write to `/v1/teams/{teamId}/policies`, `/escalations`, `/routing-rules`, `/schedules`, or `/heartbeats` (create/update/delete/enable/disable).
- Any write to `/v1/alerts/policies` or `/v1/maintenances` (create/update/delete/cancel a policy or maintenance window).
- Any heartbeat `ping` call (it records a live signal and changes state).
- Anything against classic `api.opsgenie.com`, and any use of the `Authorization: GenieKey` header.
