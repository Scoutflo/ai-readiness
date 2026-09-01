# audit-pagerduty: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-pagerduty](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Auth is `Authorization: Token token=<key>` with the key from the variable named by `pagerduty.token_env` in `~/.scoutflo/toolkit.yaml`. Presence-check it only; never echo, log, or write the value anywhere.
- The API base is `https://api.pagerduty.com` (US) or `https://api.eu.pagerduty.com` (EU), from `pagerduty.region`. Every block declares `PD_API` at the top.
- Every command here is read-only **by effect**. Most are GET. The Analytics endpoints (section 10) are POST requests that carry a filter body and change nothing; they are classified read-only by effect per the live-safety rules, and their availability is gated by the doctor analytics probe, never assumed.
- List endpoints paginate with `limit`/`offset` and return a `more` boolean. The helper pattern in section 4 pages until `more` is false. `limit` max is 100 for classic pagination.
- Rate limit is 960 requests/minute per key. Honor 429 + the `ratelimit-reset` header with a sleep-and-retry once; a second 429 on the same call is recorded as `blocked`, never silently dropped.
- Incident list queries cap the `since`/`until` range at 6 months; Analytics data lags up to 24 hours. Both limits are stated in the report wherever they bound a check.
- Webhook and integration objects can embed endpoint URLs. Captures in this file keep integration `type` and `id` and drop config bodies; never write a raw integration config to evidence.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| PD-001 | Escalation and on-call | Every active service has an escalation policy | critical |
| PD-002 | Escalation and on-call | No single-point-of-failure escalation policy on production services | high |
| PD-003 | Escalation and on-call | Escalation policies loop or terminate deliberately (`num_loops`, final rule) | medium |
| PD-004 | Escalation and on-call | On-call schedules have no coverage gaps in the audit window | high |
| PD-005 | Escalation and on-call | Every schedule referenced by an escalation policy resolves and has participants | high |
| PD-006 | Escalation and on-call | Responders are reachable beyond email alone (contact-method hygiene) | medium |
| PD-007 | Escalation and on-call | No invited-but-never-active responders inside escalation targets | medium |
| PD-008 | Escalation and on-call | High-urgency notification rules do not impose a start delay before the first page | high |
| PD-009 | Escalation and on-call | No production escalation target is a single-participant rotation (human SPOF) | high |
| PD-010 | Service hygiene | No orphaned services: every active service has at least one integration | medium |
| PD-011 | Service hygiene | No stale services: activity within the staleness window or a recorded reason | low |
| PD-012 | Service hygiene | Service status reviewed: no service parked in maintenance indefinitely | medium |
| PD-013 | Service hygiene | Business services exist and technical services map to them | low |
| PD-014 | Service hygiene | Rulesets/Event Rules migration debt named (EOL toward Event Orchestration) | medium |
| PD-015 | Service hygiene | PagerDuty native Standards score read and disagreements with this audit named | info |
| PD-016 | Escalation and on-call | No escalation policy is orphaned (referenced by no service) — **verify-pending** | medium |
| PD-017 | Escalation and on-call | Account-level bus factor: more than one distinct human backs escalation across all policies — **verify-pending** | high |
| PD-020 | Alert grouping and noise | Alert grouping configured per production service, type and window recorded | high |
| PD-021 | Alert grouping and noise | `auto_resolve_timeout` set deliberately, not defaulted to never | medium |
| PD-022 | Alert grouping and noise | Auto-Pause Incident Notifications (transient-alert pause) posture recorded | medium |
| PD-023 | Alert grouping and noise | Event Orchestration suppress/pause rules reviewed; no accidental drop-alls | high |
| PD-024 | Alert grouping and noise | Maintenance windows: none permanent, none stale | medium |
| PD-025 | Alert grouping and noise | Dedup posture: incidents show `alert_counts` grouping actually working | medium |
| PD-026 | Alert grouping and noise | `acknowledgement_timeout` set deliberately, not defaulted to never — **verify-pending** | medium |
| PD-030 | Incident health | No triggered incidents older than the acknowledgement-aging threshold | high |
| PD-031 | Incident health | Priorities configured and actually used on recent incidents | low |
| PD-032 | Incident health | Urgency mapping deliberate: production services page high-urgency | medium |
| PD-040 | Actionability | Auto-resolved share of incidents below the noise threshold per service | high |
| PD-041 | Actionability | MTTA within target on paging services | medium |
| PD-042 | Actionability | Sleep-hour interruptions reviewed per service | medium |
| PD-043 | Actionability | GET-only per-service ack-ratio fallback from `GET /incidents` `acknowledgements[]`, used when the Analytics POST is unavailable — **verify-pending** | high |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Escalation and on-call**: every active service escalates to a policy with at least two distinct human targets or a deliberate loop, schedules covering 100 percent of the audit window, every referenced schedule live with participants, every responder reachable by push, SMS, or phone in addition to email, no escalation policy sits unused by any service, and more than one distinct human backs escalation account-wide.
- **Service hygiene**: every service carries a live integration, activity or a recorded dormancy reason, a business-service mapping, no ruleset migration debt, and the vendor's own Standards score read and reconciled with this audit's view.
- **Alert grouping and noise**: grouping enabled and tuned per production service (or its absence recorded as a plan-gate fact), auto-resolve AND acknowledgement-timeout posture both deliberate, transient-alert pause posture recorded, orchestration suppression reviewed rule by rule, and no permanent or stale maintenance windows.
- **Incident health**: nothing triggered and unacknowledged past the aging threshold, priorities in real use, urgency deliberate per service tier.
- **Actionability**: the auto-resolved share, MTTA, and sleep-hour interruption counts per service read from the Analytics API and judged against stated thresholds — or, when Analytics is unavailable to this key or plan, the same acked/resolved-never-acked/still-open ratios computed straight from the plain `GET /incidents` `acknowledgements[]` field, so the category is never silently lost to a plan gate.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings. Pagination helper pattern used throughout:

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region: us -> api.pagerduty.com, eu -> api.eu.pagerduty.com
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# pd_get_all <path> <query> <jq-collection-key> -> pages until more=false, emits one JSON array
pd_get_all() {
  pga_path="$1"; pga_query="$2"; pga_key="$3"
  pga_offset=0; pga_out="[]"
  while :; do
    pga_page="$(curl -fsS --max-time 30 \
      -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
      -H "Content-Type: application/json" \
      "${PD_API}${pga_path}?limit=100&offset=${pga_offset}${pga_query:+&${pga_query}}")"
    pga_out="$(jq -n --argjson a "$pga_out" --argjson b "$(printf '%s' "$pga_page" | jq ".${pga_key}")" '$a + $b')"
    printf '%s' "$pga_page" | jq -e '.more == true' >/dev/null || break
    pga_offset=$((pga_offset + 100))
  done
  printf '%s' "$pga_out"
}

# Services with the fields every later section keys off. alert_grouping_parameters
# rides along via include[]; integration bodies are NOT captured (ids and types only).
pd_get_all "/services" "include%5B%5D=integrations&include%5B%5D=alert_grouping_parameters" "services" \
  | jq '[.[] | {id, name, status, created_at, updated_at,
      escalation_policy: (.escalation_policy.id // null),
      alert_creation, alert_grouping_parameters,
      auto_resolve_timeout, acknowledgement_timeout,
      last_incident_timestamp,
      integrations: [.integrations[]? | {id, type, summary}]}]' > "${RAW_DIR}/services.json"

pd_get_all "/escalation_policies" "" "escalation_policies" \
  | jq '[.[] | {id, name, num_loops,
      rules: [.escalation_rules[] | {delay: .escalation_delay_in_minutes,
        targets: [.targets[] | {id, type}]}],
      services: [.services[]?.id]}]' > "${RAW_DIR}/escalation-policies.json"

pd_get_all "/schedules" "" "schedules" \
  | jq '[.[] | {id, name, type, description}]' > "${RAW_DIR}/schedules.json"

pd_get_all "/users" "include%5B%5D=contact_methods&include%5B%5D=notification_rules" "users" \
  | jq '[.[] | {id, name, role, invitation_sent,
      contact_method_types: ([.contact_methods[]?.type] | unique),
      notification_rule_count: ([.notification_rules[]?] | length)}]' > "${RAW_DIR}/users.json"

pd_get_all "/priorities" "" "priorities" \
  | jq '[.[] | {id, name}]' > "${RAW_DIR}/priorities.json" \
  || echo '[]' > "${RAW_DIR}/priorities.json"   # 404 when the priorities feature is off; that absence is itself the PD-031 signal

pd_get_all "/business_services" "" "business_services" \
  | jq '[.[] | {id, name}]' > "${RAW_DIR}/business-services.json" \
  || echo '[]' > "${RAW_DIR}/business-services.json"

pd_get_all "/rulesets" "" "rulesets" \
  | jq '[.[] | {id, name, type}]' > "${RAW_DIR}/rulesets.json" \
  || echo '[]' > "${RAW_DIR}/rulesets.json"

pd_get_all "/maintenance_windows" "" "maintenance_windows" \
  | jq '[.[] | {id, start_time, end_time, description,
      services: [.services[]?.id]}]' > "${RAW_DIR}/maintenance-windows.json" \
  || echo '[]' > "${RAW_DIR}/maintenance-windows.json"

wc -c "${RAW_DIR}"/*.json
```

Expected: one JSON array file per surface. A 403 on any endpoint is an auth-scope finding for the checks that need it (record which), never a clean pass. A 404 on `priorities`, `business_services`, or `rulesets` means the feature is unused or unavailable on the plan; the empty-file fallback records that honestly.

## 5. Escalation and on-call (PD-001 to PD-007)

Policy shape checks run on the Phase 2 captures; live on-call and schedule coverage need fresh reads.

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"

# PD-001: active services with no escalation policy
jq '[.[] | select(.status == "active" and .escalation_policy == null) | .name]' "${RAW_DIR}/services.json"
# Expect: []. Any name listed is a critical finding: incidents on that service page nobody.

# PD-002 + PD-003: SPOF shape — one rule, one target, no loop
jq '[.[] | select((.rules | length) == 1 and (.rules[0].targets | length) == 1 and (.num_loops // 0) == 0)
    | {id, name}]' "${RAW_DIR}/escalation-policies.json"
# Expect: []. Each hit is one unreachable human away from a silent page.
# Judgment: a single-rule policy targeting a *schedule* with multiple participants is
# weaker than two rules but stronger than a single-user target; record which shape it is.

# PD-004: rendered schedule coverage over the audit window.
# rendered_coverage_percentage is null unless since/until are passed — always pass them.
SCHED_WINDOW_DAYS="14"   # example, tune to your rotation length
SINCE="$(date -u -v-${SCHED_WINDOW_DAYS}d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "${SCHED_WINDOW_DAYS} days ago" +%Y-%m-%dT00:00:00Z)"
UNTIL="$(date -u +%Y-%m-%dT00:00:00Z)"
jq -r '.[].id' "${RAW_DIR}/schedules.json" | while read -r sid; do
  curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
    "${PD_API}/schedules/${sid}?since=${SINCE}&until=${UNTIL}" \
    | jq --arg sid "$sid" '{id: $sid, name: .schedule.name,
        coverage: .schedule.final_schedule.rendered_coverage_percentage}'
done
# Expect: coverage 100 per schedule. Below 100 means uncovered hours in the window;
# name the schedule and the percentage in the finding (PD-004, n/100 in the evidence).

# PD-005: escalation targets that reference schedules — verify each resolves and has on-call now
jq -r '[.[] | .rules[].targets[] | select(.type == "schedule_reference") | .id] | unique | .[]' \
  "${RAW_DIR}/escalation-policies.json" | while read -r sid; do
  # status-probe-ok: the HTTP status IS the evidence (404 = a dead schedule reference inside a live escalation policy, PD-005); api.pagerduty.com is fixed JSON SaaS.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: Token token=${PAGERDUTY_TOKEN}" "${PD_API}/schedules/${sid}")
  echo "schedule ${sid}: http ${code}"
done
# Expect: 200 per schedule. A 404 is a dead reference inside a live escalation policy (PD-005, high).

# Current on-call check per escalation policy (empty = nobody on call right now)
pd_oncall_offset=0
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/oncalls?limit=100&offset=${pd_oncall_offset}" \
  | jq '[.oncalls[] | {policy: .escalation_policy.summary, level: .escalation_level,
      user: (.user.summary // "none"), until: .end}] | length'
# Expect: > 0 across the account when any schedule-based policy exists. Cross-reference
# per policy: a policy whose levels return no oncall rows is PD-005 evidence.

# PD-006 + PD-007: responder reachability and never-active invitees, from the users capture
jq '[.[] | select(.contact_method_types == ["email_contact_method"])
    | {name, role}]' "${RAW_DIR}/users.json"
# Expect: []. Email-only responders acknowledge nothing at 03:00; push has the highest
# delivery reliability per the vendor's own notification-rules doc.
jq '[.[] | select(.invitation_sent == true) | {name, role}]' "${RAW_DIR}/users.json"
# Expect: []. invitation_sent=true means the account never logged in; inside an
# escalation target that is a phantom responder (PD-007).
```

### 5.1 Notification-rule delay and human-SPOF rotations (PD-008, PD-009)

> **Verify-pending.** These two checks are drafted against the documented PagerDuty REST API and adversarially reviewed, but have **not** been run against a live PagerDuty (none exists in the benchmark estate). Treat their status as unproven until a first live run against a real account with a read-only `PAGERDUTY_TOKEN` (see the doctor gate); the endpoints and fields below are from PagerDuty's public API docs, not confirmed against a live tenant here.

Both extend the same escalation-target join PD-006 uses (users/schedules referenced by policies that active critical services point at), so they carry a real per-service blast radius rather than a global count.

```bash
# PD-008: a high-urgency notification rule with start_delay_in_minutes > 0 delays the FIRST page.
# users.json was captured with notification_rules included (section 4). For each escalation-target
# user, the minimum high-urgency start delay is the latency added before they are paged at all.
jq -r '.[] | . as $u
  | (([.notification_rules[]? | select(.urgency=="high")] ) as $hr
     | if ($hr|length)==0 then "\($u.name): NO high-urgency rule (never paged high-urgency)"
       else ($hr | map(.start_delay_in_minutes // 0) | min) as $d
            | select($d > 0) | "\($u.name): high-urgency first page delayed \($d)m" end)' \
  "${RAW_DIR}/users.json"
# Blast radius: join the delayed users to the escalation targets of policies referenced by active
# critical services (same set as PD-006); state the added MTTA minutes. Compounds PD-006 (email-only)
# and PD-002 (single-target SPOF): a SPOF target who is also delay-configured means the entire
# first-page path for that service starts N minutes late by design.

# PD-009: an escalation target schedule with only one distinct participant is a human SPOF —
# PD-004 still renders 100% coverage for it, so PD-004 alone reads healthy; PD-009 is what catches it.
# For each schedule that is a target of a critical service's policy:
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/schedules/${SCHEDULE_ID}" \
  | jq '{id: .schedule.id, name: .schedule.name,
         distinct_participants: ([.schedule.users[]?.id] | unique | length)}'
# Blast radius: distinct_participants == 1 means one person is the sole responder for that service's
# pages 24/7 — their phone off, PTO, or an untracked override gap and the page reaches nobody. Chains
# with PD-004 (single-participant rotations still show 100% coverage) and PD-002.
```

Healthy: no escalation-target user delays their high-urgency first page; every critical-service schedule has ≥2 distinct participants (or a documented, staffed secondary layer). Fail (PD-008, high): a delayed first-page path on a critical service — state the minutes and the service. Fail (PD-009, high): a single-participant rotation on a critical service's escalation target — name the schedule, the service, and the sole participant (name only, never contact details). Remediation is inline (no `setup-pagerduty` ships): PD-008 → *User Profile > Notification Rules*, add a 0-minute high-urgency push/phone rule; PD-009 → *People > Schedules*, add a second participant or a staffed secondary layer/escalation level.

### 5.2 Orphaned escalation policy and account bus factor (PD-016, PD-017)

> **Verify-pending.** Both drafted against the documented PagerDuty REST API and adversarially reviewed, but **not** run against a live PagerDuty account (the PagerDuty credential available to this work is a stale/401 token; no live PagerDuty estate was reachable). Treat their status as unproven until a first live run against a real account with a read-only `PAGERDUTY_TOKEN` — the endpoints and fields below are from PagerDuty's public API docs and the shapes this skill already captures, not confirmed live here.

PD-016 is the Zenduty-ZD-007 parallel: `escalation-policies.json` (section 4) already retains each policy's `services: [.services[]?.id]`, so an orphaned policy — one no service references — is computable with no new call. PD-017 is the account-wide sibling of PD-002/PD-009: neither check, run per policy, can see that the *same* person is the human target across most of the account.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"

# PD-016: an escalation policy with an empty services[] join — nothing routes through it.
jq '[.[] | select((.services | length) == 0) | {id, name}]' "${RAW_DIR}/escalation-policies.json"
# Expect: []. Each hit is dead config: a policy that exists, is not shaped like a SPOF, and pages
# nobody because no service points at it. Distinct from PD-001 (a service with NO policy) and
# PD-002 (a policy real services depend on, shaped as a SPOF) — this is a policy real services do
# NOT depend on. State it: "escalation policy 'legacy-oncall' has services:[] — it is unused dead
# config, not a working backup path; either wire a service to it or delete it." Remediation is
# inline (no setup-pagerduty ships): People > Escalation Policies — delete the unused policy or
# attach it to the service it was meant for. Verification: re-pull /escalation_policies and confirm
# the policy is gone, or its services[] is non-empty.

# PD-017: distinct humans across ALL escalation policies' targets, account-wide (not just the
# policies backing one service). type == "user_reference" identifies a direct user target (as
# opposed to "schedule_reference"); id is an opaque PagerDuty object id, never a name or contact
# value, so this aggregation is safe to retain and compare for uniqueness.
jq -s '
  add
  | [.[] | .id as $ep | .rules[]?.targets[]? | select(.type == "user_reference") | {ep: $ep, id}]
  | group_by(.id)
  | {distinct_humans: length,
     coverage: (map({id: .[0].id, ep_count: (map(.ep) | unique | length)}) | sort_by(-.ep_count))}' \
  "${RAW_DIR}/escalation-policies.json"
# Expect: distinct_humans > 1, with no single id's ep_count equal to the total policy count. A
# distinct_humans of 1, or one id's ep_count matching (or nearly matching) the total, means one
# human is the de facto escalation backstop for the whole account — the account-level bus factor is
# 1, even though every individual policy's own PD-002/PD-009 checks might pass in isolation. State
# it as a count, never an adjective: "4 distinct humans back escalation across 11 policies, but one
# (opaque id, not named) is a direct target on 9 of them — the account's real bus factor is 1."
# Remediation is inline (no setup-pagerduty ships): People > Escalation Policies / Schedules —
# spread direct-user targets across more of the team, or replace them with staffed schedules so no
# one human backs most of the account's paging. Verification: re-run the aggregation and confirm
# distinct_humans grew or no id's ep_count approaches the total.
```

## 6. Service hygiene (PD-010 to PD-015)

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"
STALE_DAYS="90"   # example, tune to your release cadence

# PD-010: active services with zero integrations (nothing can ever page them)
jq '[.[] | select(.status == "active" and (.integrations | length) == 0) | .name]' "${RAW_DIR}/services.json"
# Expect: []. An integration-less service is decoration, not monitoring.

# PD-011: stale services — no incident since the staleness window
STALE_BEFORE="$(date -u -v-${STALE_DAYS}d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "${STALE_DAYS} days ago" +%Y-%m-%dT00:00:00Z)"
jq --arg cutoff "$STALE_BEFORE" '[.[] | select(.status == "active")
    | select((.last_incident_timestamp // "1970-01-01") < $cutoff)
    | {name, last_incident_timestamp}]' "${RAW_DIR}/services.json"
# Judgment: quiet can mean healthy or dead-integration. Pair with PD-010 and the
# service's alert_creation mode before filing; a healthy-but-quiet service is a note, not a fail.

# PD-012: services parked in maintenance or disabled status
jq '[.[] | select(.status == "maintenance" or .status == "disabled") | {name, status}]' "${RAW_DIR}/services.json"
# Expect: []. Judgment: cross-check against maintenance-windows.json — a service inside a
# current window is fine; one in maintenance status with no window is silently muted.

# PD-013: business-service coverage
jq 'length' "${RAW_DIR}/business-services.json"
# 0 = no business context anywhere (PD-013, low). When > 0, spot-check the dependency
# wiring for the critical services from topology.md:
# curl -fsS -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
#   "${PD_API}/service_dependencies/technical_services/<SERVICE_ID>" | jq '.relationships | length'

# PD-014: rulesets EOL debt (officially sunsetting toward Event Orchestration)
jq '[.[] | {id, name}]' "${RAW_DIR}/rulesets.json"
# Expect: []. Every remaining ruleset is migration debt with a vendor-announced EOL;
# name each in the finding and point at the vendor migration guide in the remediation.

# PD-015: the vendor's own per-service Standards scores (native corroboration anchor)
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/standards/scores/technical_services" \
  | jq '[.resources[]? | {id: .resource_id, score: .score}]' > "${RAW_DIR}/standards-scores.json" \
  || echo '[]' > "${RAW_DIR}/standards-scores.json"
jq 'length' "${RAW_DIR}/standards-scores.json"
# Where the vendor scores a service healthy and this audit files a finding on it (or the
# reverse), name the disagreement in PD-015 — disagreement is itself a finding (info).
```

## 7. Alert grouping and noise (PD-020 to PD-026)

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"

# PD-020: grouping per service, from the include[] capture. Four types exist:
# time, content_based, intelligent, content_based_intelligent (Unified). null = ungrouped.
jq '[.[] | select(.status == "active")
    | {name, grouping: (.alert_grouping_parameters.type // "none"),
       config: (.alert_grouping_parameters.config // {} | {timeout: (.timeout // null), aggregate: (.aggregate // null), fields: (.fields // null), time_window: (.time_window // null)})}]' \
  "${RAW_DIR}/services.json"
# "none" on a high-volume production service is the noisy default: every alert becomes
# its own incident. IMPORTANT plan gate: all grouping types require the AIOps add-on
# (or legacy Event Intelligence). Probe entitlement before filing a fail — see the
# enablements call below; without the entitlement, record "not available on this plan"
# (excluded), never a misconfiguration.

# AIOps entitlement probe, per service (documented to warn when unentitled):
SERVICE_ID="PXXXXXX"   # one production service id from services.json
curl -fsS --max-time 15 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/services/${SERVICE_ID}/enablements" | jq '.'
# A warning body or 4xx here = the account lacks AIOps; PD-020/PD-022 become plan-gate rows.

# PD-021: auto_resolve_timeout — null means incidents stay open forever unless a human closes them
jq '[.[] | select(.status == "active")
    | {name, auto_resolve_timeout, acknowledgement_timeout}]' "${RAW_DIR}/services.json"
# Judgment: null auto-resolve is DEFENSIBLE for paging services (a page should be closed
# by a human); it is noise debt on low-urgency intake services where stale incidents pile
# up. Judge against the service's urgency posture from PD-032, never in isolation.

# PD-022: Auto-Pause Incident Notifications posture (transient-alert pause; AIOps-gated)
jq '[.[] | select(.status == "active")
    | {name, auto_pause: (.auto_pause_notifications_parameters.enabled // false)}]' "${RAW_DIR}/services.json"
# Record posture; with no AIOps entitlement this is a plan-gate row like PD-020.

# PD-023: Event Orchestration suppress/pause review.
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/event_orchestrations" | jq '[.orchestrations[]? | {id, name}]' > "${RAW_DIR}/orchestrations.json" \
  || echo '[]' > "${RAW_DIR}/orchestrations.json"
# For each orchestration, review router + service rules for suppress:true / pause actions.
# The read endpoints are per-orchestration:
#   GET /event_orchestrations/<id>/router
#   GET /services/<service-id>/orchestration/active   (per-service active/inactive posture)
# A suppress rule with a condition like 'always' or an over-broad matcher is an
# accidental drop-all (PD-023, high): alerts silently vanish before ever becoming incidents.
# Advanced orchestration actions (suppress/pause conditions beyond basic routing) are
# AIOps-gated; apply the same plan-gate rule as PD-020 before filing.

# PD-024: maintenance windows — permanent or stale
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '[.[] | select(.end_time > $now) | {id, start_time, end_time, description, services}]' \
  "${RAW_DIR}/maintenance-windows.json"
# Judgment: a window ending years out is a permanent mute wearing a maintenance costume.
# Also list recently-expired windows still being extended repeatedly if the description
# or cadence suggests it; that pattern belongs in the finding narrative.

# PD-025: is grouping actually collapsing anything? Sample recent incidents' alert counts.
SINCE_7D="$(date -u -v-7d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT00:00:00Z)"
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/incidents?since=${SINCE_7D}&limit=100&sort_by=created_at:desc" \
  | jq '[.incidents[] | {service: .service.summary, alerts: (.alert_counts.all // 1)}]
      | group_by(.service) | map({service: .[0].service, incidents: length,
          avg_alerts_per_incident: (([.[].alerts] | add) / length)})'
# avg_alerts_per_incident ~1.0 on a service with grouping enabled and real alert volume
# means grouping is configured but not collapsing; pair with PD-020's config to say why.
```

### 7.1 Acknowledgement-timeout posture (PD-026)

> **Verify-pending.** Drafted against the documented PagerDuty REST API and adversarially reviewed, but not run against a live PagerDuty account (the credential available to this work is stale/401; see section 5.2's banner). Treat as unproven until a first live run.

PD-021 already judges `auto_resolve_timeout` (does an incident ever close itself). `acknowledgement_timeout` is the other half of the same posture question — does an *acknowledged-but-not-worked* incident ever re-escalate — and the `services.json` capture (section 4) already retains the raw field; today's skill reads it for PD-021 but never judges it on its own.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"

jq '[.[] | select(.status == "active" and (.acknowledgement_timeout // null) == null)
    | {name, auto_resolve_timeout, acknowledgement_timeout}]' "${RAW_DIR}/services.json"
# A null acknowledgement_timeout means an acked incident never automatically re-triggers if the
# acker goes silent — the escalation loop (PD-003) never gets a second chance to fire. Judgment,
# same as PD-021: null is DEFENSIBLE on some paging services (a human ack is trusted); it is debt
# when PAIRED with auto_resolve_timeout ALSO null (PD-021) on the same service — that combination
# means an acked-then-abandoned incident has no timeout on either side and can sit open forever.
# State it: "checkout has acknowledgement_timeout:null AND auto_resolve_timeout:null — an
# acknowledged-but-abandoned incident on checkout has no timeout backstop of any kind." Correlation:
# joins PD-021 (the sibling timeout) and PD-030 (the live proof: aging incidents on the same
# service). Remediation is inline (no setup-pagerduty ships): Service Settings > Incident Behavior
# — set a deliberate acknowledgement timeout so a silent ack re-escalates. Verification: re-pull the
# service and confirm acknowledgement_timeout is set, or the null is a reviewed, deliberate choice.
```

## 8. Incident health (PD-030 to PD-032)

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
UNACKED_AGING_HOURS="4"   # example, tune to your on-call SLA

# PD-030: triggered (never acknowledged) incidents older than the aging threshold.
# statuses[]=triggered returns only un-acked incidents; age = now - created_at.
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/incidents?statuses%5B%5D=triggered&limit=100&sort_by=created_at:asc" \
  | jq --arg now "$(date -u +%s)" --arg maxh "$UNACKED_AGING_HOURS" \
    '[.incidents[] | {id: .incident_number, service: .service.summary, created_at,
       age_hours: ((($now | tonumber) - (.created_at | fromdateiso8601)) / 3600 | floor)}
     | select(.age_hours >= ($maxh | tonumber))]'
# Expect: []. Every row is a page nobody took. Note: the incidents list caps since/until
# at 6 months; anything older is invisible to this check and the report says so.

# PD-031: priorities in real use, not just configured
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"
SINCE_30D="$(date -u -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT00:00:00Z)"
PRIORITY_COUNT="$(jq 'length' "${RAW_DIR}/priorities.json")"
curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  "${PD_API}/incidents?since=${SINCE_30D}&limit=100" \
  | jq --argjson pc "$PRIORITY_COUNT" '{priorities_configured: $pc,
      sampled: (.incidents | length),
      with_priority: ([.incidents[] | select(.priority != null)] | length)}'
# priorities_configured 0 = the feature is unused (PD-031, low, posture note).
# Configured but with_priority ~0 = configured-and-ignored; name that shape instead.

# PD-032: urgency posture per service — production services paging low-urgency is the trap
jq '[.[] | select(.status == "active") | {name, urgency: (.incident_urgency_rule.type // "unrecorded")}]' \
  "${RAW_DIR}/services.json" 2>/dev/null \
  || echo 'incident_urgency_rule not in capture; re-fetch per service: GET /services/<id> and read .service.incident_urgency_rule'
# Judgment: use_support_hours or constant/low on a production paging service means
# real incidents arrive as non-paging notifications; verify against topology.md tiers.
```

## 9. Rate-limit handling (all sections)

Fixed pattern wherever a call may 429; run as written, do not tighten the sleep:

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
PD_PATH="/services?limit=100"        # the call being retried
RESP_CODE="$(curl -s -o /tmp/pd-body.json -w '%{http_code}' --max-time 30 \
  -H "Authorization: Token token=${PAGERDUTY_TOKEN}" "${PD_API}${PD_PATH}")"
if [ "$RESP_CODE" = "429" ]; then
  echo "429 received; sleeping 60s once and retrying"
  sleep 60
  RESP_CODE="$(curl -s -o /tmp/pd-body.json -w '%{http_code}' --max-time 30 \
    -H "Authorization: Token token=${PAGERDUTY_TOKEN}" "${PD_API}${PD_PATH}")"
fi
[ "$RESP_CODE" = "200" ] || echo "still ${RESP_CODE} after one retry: record the affected check as blocked with this code"
```

## 10. Actionability via Analytics (PD-040 to PD-043)

POST endpoints, read-only by effect (filter body, no mutation). PD-040/041/042 are **gated**: run only when the doctor matrix's `pagerduty analytics` row is `pass`. Data lags up to 24 hours; state that in the report. PD-043 (10.1 below) is the un-gated GET-only fallback — it runs regardless of the analytics gate and keeps the category assessable when analytics is `skipped`.

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/pagerduty/${RUN_DATE}/raw"
ANALYTICS_WINDOW_DAYS="30"   # example, tune to your review cadence
AUTO_RESOLVE_NOISE_PCT="30"  # example: >30% auto-resolved = noise signal, tune it
MTTA_TARGET_SECONDS="300"    # example: 5 minutes, tune to your on-call SLA
SINCE="$(date -u -v-${ANALYTICS_WINDOW_DAYS}d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "${ANALYTICS_WINDOW_DAYS} days ago" +%Y-%m-%dT00:00:00Z)"

# Per-service aggregated metrics: one POST, all services, server-side aggregation.
curl -fsS --max-time 60 -X POST \
  -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"filters\":{\"created_at_start\":\"${SINCE}\"}}" \
  "${PD_API}/analytics/metrics/incidents/services" \
  | jq '[.data[] | {service: .service_name,
      incidents: .total_incident_count,
      acked: .total_incidents_acknowledged,
      auto_resolved: .total_incidents_auto_resolved,
      mtta_s: .mean_seconds_to_first_ack,
      mttr_s: .mean_seconds_to_resolve,
      escalations: .total_escalation_count,
      sleep_hour_interruptions: .total_sleep_hour_interruptions}]' > "${RAW_DIR}/analytics-services.json"

# PD-040: auto-resolved share per service against the noise threshold
jq --argjson pct "$AUTO_RESOLVE_NOISE_PCT" \
  '[.[] | select(.incidents > 0)
    | . + {auto_resolved_pct: ((.auto_resolved / .incidents * 100) | floor)}
    | select(.auto_resolved_pct >= $pct)
    | {service, incidents, auto_resolved_pct}]' "${RAW_DIR}/analytics-services.json"
# A high auto-resolved share means incidents open and close with no human in the loop:
# the closest honest, vendor-data-backed proxy for "these pages were noise". This is a
# measured share from the vendor's own analytics, never a fabricated actionability rate.

# PD-041: MTTA against target, only where humans actually acked something
jq --argjson target "$MTTA_TARGET_SECONDS" \
  '[.[] | select(.acked > 0 and .mtta_s != null and .mtta_s > $target)
    | {service, mtta_s, incidents}]' "${RAW_DIR}/analytics-services.json"

# PD-042: sleep-hour interruptions (vendor-defined sleep hours), reviewed per service
jq '[.[] | select(.sleep_hour_interruptions > 0)
    | {service, sleep_hour_interruptions, incidents}] | sort_by(-.sleep_hour_interruptions)' \
  "${RAW_DIR}/analytics-services.json"
# Judgment: interruptions on a genuinely critical 24x7 service are the job; the finding
# is high sleep-hour volume on services whose incidents are then mostly auto-resolved
# (cross-reference PD-040) — waking humans for noise.
```

### 10.1 GET-only per-service ack-ratio fallback (PD-043)

> **Verify-pending.** Drafted against the documented PagerDuty REST API and adversarially reviewed, but not run against a live PagerDuty account (the credential available to this work is stale/401; see section 5.2's banner). Treat as unproven until a first live run.

PD-040/041/042 lose the whole Actionability category when the Analytics endpoint is plan-gated or the read-only key can't reach it. `GET /incidents` (already used for PD-025/PD-030) carries an `acknowledgements[]` array per incident, so the same acked/resolved-never-acked/still-open shape ZD-033 computes for Zenduty is computable here too, with no Analytics call — a **fallback**, not a duplicate: when Analytics is reachable, PD-040/041/042 stay primary and PD-043 is corroborating evidence, cited alongside them rather than filed as a second finding on the same cause.

```bash
set -eu
PD_API="https://api.pagerduty.com"   # pagerduty.region
FALLBACK_WINDOW_DAYS="30"   # example, tune to your review cadence
SINCE="$(date -u -v-${FALLBACK_WINDOW_DAYS}d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "${FALLBACK_WINDOW_DAYS} days ago" +%Y-%m-%dT00:00:00Z)"

# Page /incidents since the window; acknowledgements[] is empty when nobody ever acked.
# limit/offset pages the same way as the pd_get_all helper in section 4.
pd_offset=0; OUT="$(mktemp)"; > "$OUT"
while :; do
  PAGE="$(curl -fsS --max-time 30 -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
    "${PD_API}/incidents?since=${SINCE}&limit=100&offset=${pd_offset}")"
  printf '%s' "$PAGE" | jq -c '.incidents[] | {service: .service.id, status,
      acked: ((.acknowledgements // []) | length > 0),
      resolved: (.status == "resolved")}' >> "$OUT"
  printf '%s' "$PAGE" | jq -e '.more == true' >/dev/null || break
  pd_offset=$((pd_offset + 100))
done

jq -s '
  group_by(.service) | map({
    service_id: .[0].service,
    total: length,
    acked_share: ((map(select(.acked)) | length) * 100 / length | floor),
    resolved_never_acked_share: ((map(select(.resolved and (.acked|not))) | length) * 100 / length | floor),
    still_open_share: ((map(select(.status == "triggered" and (.acked|not))) | length) * 100 / length | floor)
  }) | sort_by(-.total)' "$OUT"
rm -f "$OUT"
# Expect (healthy): acked_share high, resolved_never_acked_share and still_open_share low.
# PD-043 fails a service whose resolved_never_acked_share or still_open_share is high — incidents
# created but never touched by a human either way, the same signal PD-040/041 read from Analytics.
# State it: "service <id>: 340 incidents in the sample (GET /incidents, ${FALLBACK_WINDOW_DAYS}d,
# N pages), 12% acked, 81% resolved without ever being acknowledged — computed without the
# Analytics endpoint, so Actionability is not lost when Analytics is plan-gated or unreachable."
# Remediation is inline (no setup-pagerduty ships): same as PD-040/041 — fix the sending tool's
# grouping/thresholds or the on-call rotation; this check only changes where the evidence came
# from. Verification: none beyond re-running the same pull after the fix and confirming the shares
# improved.
```

## 11. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, resolve the PagerDuty service by name match (record unmatched names honestly), then fill the matrix row from the section 5 to 10 captures: escalation (PD-001/002), on-call now (PD-005), grouping (PD-020), unacked aging (PD-030), actionability (PD-040 when the category runs). Name affected services in findings; "three services lack grouping" is not a finding, "checkout, payments, and search lack grouping" is.

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `SCHED_WINDOW_DAYS` | 14 | Window for rendered schedule coverage |
| `STALE_DAYS` | 90 | No-incident window before a service is stale-flagged |
| `UNACKED_AGING_HOURS` | 4 | Triggered-incident age that counts as a missed page |
| `ANALYTICS_WINDOW_DAYS` | 30 | Analytics aggregation window |
| `AUTO_RESOLVE_NOISE_PCT` | 30 | Auto-resolved share that flags a service as noisy |
| `MTTA_TARGET_SECONDS` | 300 | Acknowledgement target for paging services |
| `FALLBACK_WINDOW_DAYS` | 30 | Window for the PD-043 GET-only ack-ratio fallback |

## 13. Forbidden commands

This is an audit: read-only by effect, no exceptions. Never run, however convenient:

- Any `POST`, `PUT`, `PATCH`, or `DELETE` outside the two Analytics endpoints in section 10 and the doctor probe (which are POST-with-filter-body reads).
- `POST /incidents` (creating), incident `PUT` updates (ack/resolve/snooze/merge), responder requests, or status updates.
- Creating, editing, or deleting services, integrations, escalation policies, schedules, overrides, maintenance windows, event orchestrations, rulesets, or extensions.
- `POST /schedules/preview` (harmless-looking but setup-lane: it validates a schedule body you would be composing).
- Sending test events to any integration endpoint (`events.pagerduty.com` is entirely out of scope for audits).

The one write-shaped-but-read surface in this skill is Analytics; everything else with a mutating verb is setup-lane work behind its confirmation gate.
