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
| JSM-001 | Alert delivery and escalation | Every audited team has an escalation; no production team is a single step with no repeat | critical |
| JSM-002 | Alert delivery and escalation | Escalation `repeat` and an `if-not-acked` rule present where re-notification is relied on | high |
| JSM-003 | Alert delivery and escalation | Every routing rule resolves to an enabled, staffed schedule (no empty-schedule join) | high |
| JSM-004 | Alert delivery and escalation | Schedules referenced are enabled, with a rotation and someone on call now | high |
| JSM-005 | Alert delivery and escalation | No integration on a live ingestion path is `enabled: false` | critical |
| JSM-010 | Alert noise | Notification-policy dedup (`deduplicationAction`) present where sources are chatty | medium |
| JSM-011 | Alert noise | `delayAction` used deliberately, not as blanket suppression | medium |
| JSM-012 | Alert noise | No permanently-`suppress: true` policy with a broad filter masking real alerts | high |
| JSM-013 | Alert noise | `autoCloseAction` present so alerts do not accumulate stuck-open | medium |
| JSM-014 | Alert noise | `autoRestartAction` not a re-page storm (short `waitDuration` + high `maxRepeatCount`) | medium |
| JSM-015 | Alert noise | Sources set a stable `alias` so dedup collapses repeats | medium |
| JSM-016 | Alert noise | Global/team alert policies present and enabled for normalization and priority | medium |
| JSM-017 | Alert noise | No active maintenance window that is a permanent blackout of a live integration/policy | high |
| JSM-018 | Alert noise | Operator-snoozed alerts are a human-driven suppression blackout, distinct from policy suppress (JSM-012) | medium |
| JSM-020 | Coverage and health | Heartbeats responsive; no live source in `Unresponsive`/unintended `Off` | critical |
| JSM-021 | Coverage and health | Critical services from topology each covered by a team and a routing path | high |
| JSM-022 | Coverage and health | Teams audited named; teams not audited named as uncovered, not silently dropped | medium |
| JSM-023 | Coverage and health | Stale or disabled integrations identified as drift | low |
| JSM-024 | Coverage and health | Teams are visible in the account (zero teams visible to this key is `blocked`, not a plain fail — a likely token role/visibility gap: the paging config lives in teams the key cannot see; widen the token to a read/observer JSM Operations role on the teams) | high |
| JSM-030 | Actionability | Open alerts unacknowledged past the aging threshold | high |
| JSM-031 | Actionability | MTTA (createdAt to ackTime) against target where humans acked | medium |
| JSM-032 | Actionability | Share of alerts closed with no acknowledgement (auto-close-heavy = noise proxy) | medium |
| JSM-033 | Actionability | Priority collapse: the live alert population lands at one priority, so priority-keyed routing/normalization is inert | medium |

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
JSM_SITE="your-site.atlassian.net"   # jsm.site
AUTH_USER="${JSM_EMAIL}:${JSM_API_TOKEN}"
# Resolve CLOUD_ID the same way the doctor gate does (each block is a fresh shell):
# jsm.cloud_id if configured, else the site's tenant_info edge route. Every path needs it.
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/jsm/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# Discover every team this key can see — the DISCOVERED set and the coverage denominator —
# then resolve the AUDITED set. Both are materialized as id files that the empty/hidden-teams
# guardrail reads (mirrors audit-elk's spaces-discovered.txt / spaces.txt), so the run can never
# score a confident 0/100 when the key simply cannot see the teams.
curl -fsS --max-time 30 -u "$AUTH_USER" "${JSM_BASE}/teams?size=100" \
  | jq -r '.values[]? | "\(.id)\t\(.name)"' > "${RAW_DIR}/teams-all.tsv"
cut -f1 "${RAW_DIR}/teams-all.tsv" | sort -u > "${RAW_DIR}/teams-discovered.txt"
# AUDITED = jsm.teams when set (validate each id against teams-discovered.txt; a configured team
# the key cannot see is a scope gap, reported `skipped`, never silently dropped), else all
# discovered. With no jsm.teams configured, audit all discovered:
cp "${RAW_DIR}/teams-all.tsv" "${RAW_DIR}/teams.tsv"
cut -f1 "${RAW_DIR}/teams.tsv" | sort -u > "${RAW_DIR}/teams-audited.txt"
echo "teams discovered: $(tr '\n' ' ' < "${RAW_DIR}/teams-discovered.txt")"
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
    | jq '[.values[]? | {id, name, isDefault, order, notify_type: .notify.type, notify_id: .notify.id,
        criteria_type: (.criteria.type // null),
        criteria_conditions: [((.criteria.conditions) // [])[] | {field, operation, expectedValue}]}]' \
    > "${tdir}/routing-rules.json"
  # `criteria` is the priority/tag/message gate a routing rule matches on (fields, not secrets):
  # a rule with a `priority`-equals-`P1` condition is the branch that only fires for a real P1.
  # Capturing it is what lets JSM-016/JSM-033 *observe* a never-fired priority branch instead of
  # asserting one. Verify-pending: whether `criteria`/`conditions` are exposed on the routing-rules
  # list for this tenant is confirmed at first live-smoke (the `// null`/`// []` guards keep this
  # capture safe if the field is absent — the join then degrades to "criteria unreadable", never a
  # fabricated branch). See sections 6.1 and 8.1.
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
#
# JSM-002 blast radius (compute, do not assert "no repeat is risky"): resolve the escalation's
# tier-1 recipient (rules[0].recipient -> a single schedule/user), then join JSM-032's
# close-without-ack share for THIS team. A single-step, no-repeat, no-if-not-acked policy whose
# tier-1 is one schedule means: every alert this team already closed unacked (JSM-032's count for
# the team) was a page the sole on-call missed with NO second notification and NO tier-2 — it was
# silently dropped. State it as "platform escalation is one rule, no repeat, no if-not-acked; tier-1
# is schedule S; 22% of this team's last-window alerts closed unacked (JSM-032, 220/1000, 20k
# window) — each is a missed page with no backup", never "the missing repeat is risky".
#   Correlation: chains with JSM-001 (SPOF escalation shape), JSM-032 (unacked-close share = live
#   proof the missing repeat already bites), and JSM-004 (if tier-1's schedule is unstaffed the
#   FIRST page also lands nowhere) — this is the human leg of the flagship silent-paging-path.
#   Exact fix: add `repeat.count >= 2` with a `repeat.waitInterval`, plus an `if-not-acked` rule
#   escalating to a DISTINCT tier-2 schedule (JSM > Operations > Teams > (team) > Escalations — add
#   an if-not-acked step and set Repeat). Verification: re-read GET /v1/teams/{teamId}/escalations
#   -> `.repeat.count > 1` and a rule with `condition: "if-not-acked"` present; read-only.

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
#
# JSM-004 blast radius (name the SERVICES, not just the schedule): join backwards from the empty
# schedule to the routing rules that target it (JSM-003), then to the critical services those rules
# carry (JSM-021 / topology.md). "schedule S has rotation_count=0 and on-calls returns empty
# onCallParticipants right now; S is the routing target for checkout and payments — both critical
# services are unpaged THIS INSTANT." An unstaffed schedule that is the sole path for a critical
# service is a live delivery outage, not a hygiene note.
#   Correlation: chains with JSM-003 (empty-schedule routing join) and JSM-021 (critical-service
#   coverage) — this is the delivery leg of the flagship silent-paging-path. Exact fix: fill the
#   rotation or retarget routing at a staffed schedule (Team > Schedules — add/repair a rotation; or
#   Routing rules — retarget). Verification: re-read /v1/schedules/{id}/on-calls -> non-empty
#   onCallParticipants; read-only.
#   Verify-pending ambition (flag at live-smoke, do NOT claim now): whether v1 Operations exposes a
#   FUTURE on-call query (`/v1/schedules/{id}/on-calls?date=<future-ISO8601>` or a timeline endpoint)
#   to catch a gap that opens later tonight. Only the current on-call read is confirmed, so scope the
#   finding to "now" unless the future query verifies live.

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
# Presence is only the trigger. The FINDING must carry blast radius computed from the live stream
# (the query below), never "no dedup is noisy": No deduplicationAction on a team with chatty sources
# = JSM-010. No autoCloseAction = JSM-013 (alerts pile up stuck-open). autoRestartAction with a short
# waitDuration and a high maxRepeatCount on a paging policy = JSM-014 (re-page storm).

# JSM-010 / JSM-013 blast radius — computed from the live alert stream for THIS team, so the finding
# carries a number, not an adjective. Resolve JSM_BASE as elsewhere (fresh shell); TEAM_NAME is the
# team whose policies you judged above.
JSM_SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
TEAM_NAME="platform"   # the team whose notification policies you judged; loop over the audited teams
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=status: open AND teams: ${TEAM_NAME}" \
  --data-urlencode "size=100" --data-urlencode "sort=createdAt" --data-urlencode "order=desc" \
  "${JSM_BASE}/alerts" \
  | jq '{sampled: (.values | length),
      recurring_aliases: ([.values[] | select((.count // 1) > 1)] | length),
      repeat_notifications: ([.values[] | ((.count // 1) - 1)] | add // 0),
      oldest_open: (.values | min_by(.createdAt).createdAt // null)}'
# JSM-010: repeat_notifications = sum(count-1) is the extra pages a missing deduplicationAction let
# through — "payments has no deduplicationAction; 34 aliases recurred, sum(count-1)=190 repeat
# notifications the sole on-call received this window." The number is the blast radius, not "noisy".
#   Correlation: chains with JSM-015 (no stable alias means dedup cannot collapse anything even if
#   configured) and JSM-031 (repeat volume inflates MTTA); when the same team is also single-step
#   escalation (JSM-002) the on-call drowns before the page that matters. Exact fix: add a
#   notification-policy deduplicationAction (`deduplicationActionType: frequency-based`) with a
#   countValueLimit/window sized to the observed recurrence (Team > Policies (Notification) > add a
#   De-duplication action). Verification: re-sample this query next run — recurring_aliases and
#   repeat_notifications must fall toward the countValueLimit ceiling; read-only.
# JSM-013: a `sampled` at the 100 cap with a very old `oldest_open` is the stuck-open pile a missing
# autoCloseAction leaves — "ingest has no autoCloseAction; 100 open (list cap hit), oldest 43 days —
# the 3 real active pages are buried in a 100-deep haystack", which is exactly the pile JSM-030
# aging surfaces. Cite JSM-030's sampled count as JSM-013's live proof and mark JSM-013
# validated-live. Exact fix: set autoCloseAction.waitDuration on the notification policy for source
# classes that self-resolve, sized above the source's own recovery interval (Team > Policies
# (Notification) > Auto-Close action). Verification: re-run the `status: open` query next run;
# sampled and oldest-age must drop; read-only.

# JSM-011 + JSM-012: delay and blanket suppression.
jq '[.[] | select(.suppress == true or .delayAction != null)
    | {id, name, suppress, filter, delayOption: (.delayAction.delayOption // null)}]' \
  "${tdir}/notification-policies.json"
# A policy with suppress=true AND a broad filter (matches all / no conditions) is JSM-012 high:
# it masks real alerts indefinitely. A narrow, deliberate delayAction is fine (JSM-011 judgment).

# JSM-016: global + team alert policies present and enabled — and, specifically, whether ANY
# enabled policy actually normalizes priority (updatePriority=true), which is what makes the
# downstream priority-keyed routing branch reachable.
jq '{policies: [.[] | {id, name, type, enabled, continue, priority_override: .updatePriority,
        priority_value: (.priorityValue // null)}],
     enabled_priority_normalizers: ([.[] | select(.enabled == true and .updatePriority == true)] | length)}' \
  "${RAW_DIR}/alert-policies.json"
# JSM-016 blast radius (compute, do not call it hygiene): join enabled_priority_normalizers (from
# THIS query) to the live priority distribution (JSM-033) and to the routing-rule criteria captured
# in section 4. When enabled_priority_normalizers=0, nothing sets priority before creation, so the
# JSM-033 distribution collapses to the default (e.g. "96% of the last 100 alerts arrive at default
# P3"); a routing rule whose criteria match `priority == P1` is then a branch that has never fired —
# a genuine P1 from source Y lands as P3 and takes the default path. The 96% and the never-matched
# routing criterion are the blast radius.
#   Correlation (corrected — the priority gate is on ROUTING criteria and notification/alert-policy
#   filters, NOT on escalations, which key only on if-not-acked/if-not-closed): JSM-033 (collapsed
#   distribution) -> JSM-016 (no enabled policy normalizes priority) -> JSM-003 (the routing rule
#   whose priority criterion therefore never matches). Do NOT attribute a "priority branch" to an
#   escalation step (JSM-002). Exact fix: enable a global/team alert policy with `updatePriority:
#   true` + `priorityValue` rules keyed on source/message filters so critical sources normalize to
#   P1/P2 before creation (Global/Team Alert policies > add an Update-priority policy). Verification:
#   re-run the JSM-033 distribution query — the P1/P2 share must rise for the normalized sources, and
#   the priority-matching routing criterion becomes reachable; read-only.
#   Verify-pending: observing the "never-fired routing branch" as a COMPUTED fact depends on the
#   section-4 `criteria` capture being exposed for this tenant (confirmed at first live-smoke). Until
#   then, JSM-016's computable-now signal is enabled_priority_normalizers joined to the JSM-033
#   distribution; the specific dead routing criterion is stated as a verify-pending join, not asserted.

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
JSM_SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  "${JSM_BASE}/alerts?size=100&sort=createdAt&order=desc" \
  | jq '{sampled: (.values | length),
      with_alias: ([.values[] | select((.alias // "") != "")] | length),
      deduped: ([.values[] | select((.count // 1) > 1)] | length),
      worst_unaliased_fingerprint: ([.values[] | select((.alias // "") == "") | .message]
        | group_by(.) | map({message: .[0], duplicates: length}) | sort_by(-.duplicates) | .[0] // null)}'
# JSM-015 blast radius (translate the ratio into the multiplier a responder feels, don't stop at the
# ratio): with_alias well below sampled = sources not setting a stable alias, so identical conditions
# arrive as N separate alerts instead of one with count=N. worst_unaliased_fingerprint names the
# concrete case — "with_alias=12/100; the 'DiskFull on host-A' message created 47 separate alerts this
# window instead of one deduped alert with count=47." The 47 is the duplication multiplier; deduped>0
# is healthy evidence dedup works. Sampled within the 20k cap, not a full-history count.
#   Correlation: chains with JSM-010 (policy dedup is useless without a stable alias key — a missing
#   alias defeats a configured deduplicationAction) and JSM-031 (each duplicate is a fresh
#   notification inflating MTTA). Fold the flapping observation here too: alerts whose
#   closeTime - createdAt is seconds and that recur under one fingerprint are transient noise even
#   when aliased. Exact fix: fix the SENDING tool's payload to set a stable `alias` — this is an
#   UPSTREAM fix, so remediation points at that tool's own audit (audit-lgtm/grafana/sentry names it),
#   NOT a JSM UI change. Verification: re-sample this stream; the recurring condition collapses to one
#   alert with count>1 and a populated alias; read-only.
```

### 6.1 Operator-snoozed alerts — a human-driven blackout (JSM-018)

> **Verify-pending.** Drafted against JSM Operations' documented API and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token (`JSM_EMAIL` + `JSM_API_TOKEN`). The scored signal below rests only on fields the contract confirms (the `status` enum value `snoozed`, plus `alias`/`message`/`createdAt`); the per-alert `snoozed`/`snoozedUntil` fields in the second command are NOT confirmed for this API and are gated behind their own verify-pending note — do not treat them as computable until live-smoke shows `/v1/alerts/{id}` returns them.

Snooze is the third suppression channel and the only one a human drives per alert, so a policy audit (JSM-012, which reads config `suppress`) can never see it. A service whose alerts are chronically snoozed is one a responder has decided not to look at — the opposite of what the config claims.

```bash
set -eu
JSM_SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"

# JSM-018 (SCORED signal — confirmed fields only): the live snoozed population and its top
# recurring message. `status: snoozed` is a confirmed queryable status; values/alias/message/
# createdAt are confirmed flat fields.
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=status: snoozed" --data-urlencode "size=100" \
  --data-urlencode "sort=createdAt" --data-urlencode "order=desc" \
  "${JSM_BASE}/alerts" \
  | jq '{snoozed_sampled: (.values | length),
      oldest: (.values | min_by(.createdAt).createdAt // null),
      with_alias: ([.values[] | select((.alias // "") != "")] | length),
      by_message: ([.values[].message] | group_by(.) | map({m: .[0], n: length}) | sort_by(-.n) | .[0:5])}'
# Blast radius (computed from the query above): snoozed_sampled = how many active alerts a responder
# has hand-muted, and by_message names WHAT they muted — "18 alerts snoozed, the top recurring message
# is the payments-latency alert (7 of 18): responders are hand-muting the exact signal that should
# page, and a JSM-012 policy audit would never see it because it is operator behavior, not config."
```

```bash
# JSM-018 (VERIFY-PENDING sub-signal — do NOT score off this until live-smoke confirms the fields):
# whether a per-alert snooze horizon exposes de-facto permanent suppression. `/v1/alerts/{id}` MAY
# return `snooze`/`snoozedUntil`; neither is confirmed by the contract. A snooze pushed far into the
# future is de-facto permanent suppression — but only report it once live-smoke shows these fields.
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  "${JSM_BASE}/alerts/EXAMPLE_ALERT_ID" \
  | jq '{status, snoozedUntil: (.snoozedUntil // null)}'
# If snoozedUntil is present and years out, that is a permanent blackout hiding as a snooze. If the
# field is absent, say so — the finding stays scoped to the snoozed_sampled + by_message signal above.
```

Healthy: `snoozed_sampled` is low and no single message dominates. Fail (JSM-018, medium): a meaningful snoozed population whose top messages are real paging signals — name the count and the top message (never a responder's identity). Correlation: complements JSM-012 (policy suppress = config blackout) and JSM-032 (close-without-ack = noise proxy); a service whose alerts are chronically snoozed AND close unacked is one nobody trusts. Remediation is inline (no `setup-jsm` ships): this has no JSM config object — the fix is a responder-process review plus fixing the noisy source (its own audit names the tool), since JSM has no bulk snooze-policy object to tune. Verification: re-sample the `status: snoozed` query next run — `snoozed_sampled` and the dominant message's share must fall; read-only.

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
JSM_SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
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

### 8.1 Priority collapse — priority-keyed routing is inert (JSM-033)

> **Verify-pending.** Drafted against JSM Operations' documented API and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token. The `.priority` field is confirmed by the contract; its observed label domain (P1..P5) and the routing-rule `criteria` capture that turns "the P1 branch never fired" from an assertion into a computed fact are both confirmed at first live-smoke. The `group_by` below works for any label set, so the distribution figure holds regardless.

When every alert lands at one priority (usually the default), priority is dead metadata: any routing-rule criterion or notification/alert-policy filter keyed on `priority == P1` never matches, so its branch never fires. This is the live-outcome complement to JSM-016 (which reads whether a policy *would* normalize priority) — JSM-033 reads whether priority *actually varies* in the stream.

```bash
set -eu
JSM_SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="${JSM_CLOUD_ID:-}"
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id (set jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"

# JSM-033: priority distribution of the recent closed stream. dominant_share is the collapse metric.
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=status: closed" --data-urlencode "size=100" \
  --data-urlencode "sort=createdAt" --data-urlencode "order=desc" \
  "${JSM_BASE}/alerts" \
  | jq '{sampled: (.values | length),
      dist: ([.values[].priority] | group_by(.) | map({priority: .[0], n: length}) | sort_by(-.n)),
      dominant_share: (if (.values | length) > 0
        then (([.values[].priority] | group_by(.) | map(length) | max) / (.values | length))
        else null end)}'
# Also glance at the open stream so the finding is not closed-only:
curl -fsS --max-time 30 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  --get --data-urlencode "query=status: open" --data-urlencode "size=100" \
  "${JSM_BASE}/alerts" \
  | jq '[.values[].priority] | group_by(.) | map({priority: .[0], n: length}) | sort_by(-.n)'
# Blast radius (computed from dominant_share): "96% of the last 100 alerts are P3 (the default);
# nothing normalizes priority (JSM-016 enabled_priority_normalizers=0), so a routing rule whose
# criteria match priority=P1 (section 4 criteria capture) never fires — a real P1 arrives as P3 and
# takes the default path." The 96% and the never-matched criterion are the blast radius, joined to
# JSM-016 and JSM-003.
```

Healthy: priority varies with real urgency and `dominant_share` is well below 1.0. Fail (JSM-033, medium): a collapsed distribution (e.g. `dominant_share` ~0.96 at the default priority) while a priority-keyed routing/notification branch exists — state the share, the dominant priority, and the branch it strands. Correlation (corrected — priority gating is on routing criteria and policy filters, NOT escalations): JSM-033 (collapsed distribution) -> JSM-016 (no enabled policy normalizes priority) -> JSM-003 (the routing criterion that therefore never matches). Also feeds JSM-031: if every alert is one priority, MTTA/aging thresholds cannot be tiered by urgency. Remediation is inline (no `setup-jsm` ships): Global/Team Alert policies > add Update-priority rules keyed on source/message filters so critical sources normalize to P1/P2 before creation. Verification: re-run this distribution query — the P1/P2 share must rise for the normalized sources and `dominant_share` fall; read-only.

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
