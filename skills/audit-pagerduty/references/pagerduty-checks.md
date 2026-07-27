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
| PD-010 | Service hygiene | No orphaned services: every active service has at least one integration | medium |
| PD-011 | Service hygiene | No stale services: activity within the staleness window or a recorded reason | low |
| PD-012 | Service hygiene | Service status reviewed: no service parked in maintenance indefinitely | medium |
| PD-013 | Service hygiene | Business services exist and technical services map to them | low |
| PD-014 | Service hygiene | Rulesets/Event Rules migration debt named (EOL toward Event Orchestration) | medium |
| PD-015 | Service hygiene | PagerDuty native Standards score read and disagreements with this audit named | info |
| PD-020 | Alert grouping and noise | Alert grouping configured per production service, type and window recorded | high |
| PD-021 | Alert grouping and noise | `auto_resolve_timeout` set deliberately, not defaulted to never | medium |
| PD-022 | Alert grouping and noise | Auto-Pause Incident Notifications (transient-alert pause) posture recorded | medium |
| PD-023 | Alert grouping and noise | Event Orchestration suppress/pause rules reviewed; no accidental drop-alls | high |
| PD-024 | Alert grouping and noise | Maintenance windows: none permanent, none stale | medium |
| PD-025 | Alert grouping and noise | Dedup posture: incidents show `alert_counts` grouping actually working | medium |
| PD-030 | Incident health | No triggered incidents older than the acknowledgement-aging threshold | high |
| PD-031 | Incident health | Priorities configured and actually used on recent incidents | low |
| PD-032 | Incident health | Urgency mapping deliberate: production services page high-urgency | medium |
| PD-040 | Actionability | Auto-resolved share of incidents below the noise threshold per service | high |
| PD-041 | Actionability | MTTA within target on paging services | medium |
| PD-042 | Actionability | Sleep-hour interruptions reviewed per service | medium |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Escalation and on-call**: every active service escalates to a policy with at least two distinct human targets or a deliberate loop, schedules covering 100 percent of the audit window, every referenced schedule live with participants, and every responder reachable by push, SMS, or phone in addition to email.
- **Service hygiene**: every service carries a live integration, activity or a recorded dormancy reason, a business-service mapping, no ruleset migration debt, and the vendor's own Standards score read and reconciled with this audit's view.
- **Alert grouping and noise**: grouping enabled and tuned per production service (or its absence recorded as a plan-gate fact), auto-resolve deliberate, transient-alert pause posture recorded, orchestration suppression reviewed rule by rule, and no permanent or stale maintenance windows.
- **Incident health**: nothing triggered and unacknowledged past the aging threshold, priorities in real use, urgency deliberate per service tier.
- **Actionability**: the auto-resolved share, MTTA, and sleep-hour interruption counts per service read from the Analytics API and judged against stated thresholds — or the whole category excluded with the doctor-probe reason when Analytics is unavailable to this key or plan.

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

## 7. Alert grouping and noise (PD-020 to PD-025)

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

## 10. Actionability via Analytics (PD-040 to PD-042)

POST endpoints, read-only by effect (filter body, no mutation). **Gated**: run only when the doctor matrix's `pagerduty analytics` row is `pass`; on `skipped`, exclude the whole Actionability category with the doctor reason. Data lags up to 24 hours; state that in the report.

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

## 13. Forbidden commands

This is an audit: read-only by effect, no exceptions. Never run, however convenient:

- Any `POST`, `PUT`, `PATCH`, or `DELETE` outside the two Analytics endpoints in section 10 and the doctor probe (which are POST-with-filter-body reads).
- `POST /incidents` (creating), incident `PUT` updates (ack/resolve/snooze/merge), responder requests, or status updates.
- Creating, editing, or deleting services, integrations, escalation policies, schedules, overrides, maintenance windows, event orchestrations, rulesets, or extensions.
- `POST /schedules/preview` (harmless-looking but setup-lane: it validates a schedule body you would be composing).
- Sending test events to any integration endpoint (`events.pagerduty.com` is entirely out of scope for audits).

The one write-shaped-but-read surface in this skill is Analytics; everything else with a mutating verb is setup-lane work behind its confirmation gate.
