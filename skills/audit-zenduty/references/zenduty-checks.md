# audit-zenduty: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-zenduty](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Base is `https://www.zenduty.com/api`. Zenduty is now branded Xurrent IMR (branding-only; the API host is unchanged).
- Auth is `Authorization: Token <key>` — the **literal word `Token`**, not `Bearer`. Presence-check `ZENDUTY_TOKEN` only; never echo, log, or write it. There is no read-only key scope; a Bot Token (Beta) with view-only permissions is the least-privilege credential.
- Versioning is mixed and per-resource: teams, services, integrations, alert rules (`transformers`), escalation policies, schedules, and maintenance are unversioned under `/api/account/...`; incidents are under `/api/incidents/...`; **analytics, global routing (`events/router`), and on-call are `/api/v2/account/...`**. On-call has both a v1 and a v2 path — this audit uses v2 (richer shape).
- **Rate limits are tight and per-endpoint-class — pace every call.** Section 9 has the published table and the retry rule. This is the defining operational constraint; a large audit is paced, not fast.
- Every command here is read-only: GET, plus two documented read-by-POST calls — `POST /api/incidents/filter/` (lists incidents by filter, changes nothing) and the `POST /api/v2/account/analytics/*` endpoints (server-side aggregation). The forbidden-verb list is section 13.
- `curl -fsS --max-time 30 -H "Authorization: Token ${ZENDUTY_TOKEN}"` is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it.
- A team's scope key is its **`unique_id`** (a UUID); use it as `{team_id}` in per-team calls. A list response may be a bare array or a paginated `{results: [...]}` — the commands handle both.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| ZD-001 | Escalation/on-call | Every audited team has an escalation; no production team is one rule, one target, `repeat_policy: 0` | critical |
| ZD-002 | Escalation/on-call | Escalation levels and repeat deliberate, not a one-shot | high |
| ZD-003 | Escalation/on-call | Every escalation policy's on-call resolves to a staffed rotation now (no empty `oncalls`) | high |
| ZD-004 | Escalation/on-call | Schedules referenced are non-empty and cover the window | high |
| ZD-005 | Escalation/on-call | No integration on a live ingestion path is `is_enabled: false` | critical |
| ZD-010 | Alert noise | Per-service `collation` on where a service is chatty (time-based dedup) | medium |
| ZD-011 | Alert noise | Suppress alert rules present and not over-broad (no always-true drop-all) | high |
| ZD-012 | Alert noise | "Seconds Since Last Similar Incident" flapping guard where a source re-fires | medium |
| ZD-013 | Alert noise | Delay-notification rules deliberate, not blanket off-hours muting | medium |
| ZD-014 | Alert noise | Stable, non-blank `entity_id` so default dedup collapses repeats | medium |
| ZD-015 | Alert noise | Auto-ack/auto-resolve working (sources emit resolve `alert_type`s) | medium |
| ZD-016 | Alert noise | No open-ended recurring maintenance window (`repeat_interval` set, `repeat_until: null`) | high |
| ZD-020 | Coverage/hygiene | Global routing has no overlapping/duplicate routes and has a default route | medium |
| ZD-021 | Coverage/hygiene | Critical services from topology each covered by a team, service, and escalation path | high |
| ZD-022 | Coverage/hygiene | Teams audited named; teams not audited named as uncovered, not silently dropped | medium |
| ZD-023 | Coverage/hygiene | No integration on the deprecated "API-Integration" ingestion type (stopped 2025-05-15) | medium |
| ZD-024 | Coverage/hygiene | Teams are visible in the account (zero teams visible to this key is `blocked`, not a plain fail — a likely token permission/visibility gap: the paging config lives in teams the key cannot see; widen the token to a Bot Token with view-only team access) | high |
| ZD-030 | Actionability | Unacknowledged incidents older than the aging threshold | high |
| ZD-031 | Actionability | MTTA against target from analytics `mtta_seconds` where humans acked | medium |
| ZD-032 | Actionability | MTTR against target from `mttr_seconds`, with the acked/resolved share | medium |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Escalation and on-call**: every audited team has a multi-level escalation with a repeat, every escalation's on-call resolves to a staffed rotation, referenced schedules cover the window, and no live-path integration is disabled — a page always reaches a reachable human.
- **Alert noise**: chatty services have time-based collation on, suppress and flapping-guard rules are present and narrow, delay is scoped, sources set a stable `entity_id` and emit resolve events, and no maintenance window is an open-ended recurring blackout.
- **Coverage and hygiene**: global routing is unambiguous with a default route, every critical service has a team/service/escalation path, every team is audited or named as uncovered, and no integration sits on the dead API-Integration ingestion type.
- **Actionability**: few incidents age unacknowledged, and the vendor's own MTTA/MTTR are within target with a healthy acked/resolved share — pages are worth taking, from Zenduty's own analytics.

## 4. Inventory (all categories)

Resolve the teams to audit, then capture per team and account-wide. **Pace by the rate-limit rule (section 9): a `sleep 1` between list GETs, more between alert/incident GETs.**

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
AUTH="Authorization: Token ${ZENDUTY_TOKEN}"
# Normalize a list response (bare array or {results:[...]}) to an array.
norm() { jq 'if type=="array" then . else (.results // []) end'; }

# Discover every team this key can see — the DISCOVERED set and the coverage denominator —
# then resolve the AUDITED set. Both are materialized as unique_id files that the empty/hidden-
# teams guardrail reads (mirrors audit-elk's spaces-discovered.txt / spaces.txt), so the run can
# never score a confident 0/100 when the key simply cannot see the teams. unique_id is the scope key.
curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/" | norm \
  | jq -r '.[] | "\(.unique_id)\t\(.name)"' > "${RAW_DIR}/teams-all.tsv"
cut -f1 "${RAW_DIR}/teams-all.tsv" | sort -u > "${RAW_DIR}/teams-discovered.txt"
# AUDITED = zenduty.teams when set (validate each unique_id against teams-discovered.txt; a
# configured team the key cannot see is a scope gap, reported `skipped`, never silently dropped),
# else all discovered. With no zenduty.teams configured, audit all discovered:
cp "${RAW_DIR}/teams-all.tsv" "${RAW_DIR}/teams.tsv"
cut -f1 "${RAW_DIR}/teams.tsv" | sort -u > "${RAW_DIR}/teams-audited.txt"
echo "teams discovered: $(tr '\n' ' ' < "${RAW_DIR}/teams-discovered.txt")"
echo "teams to audit:"; cat "${RAW_DIR}/teams.tsv"

# Account-wide: global alert routers and their rulesets (v2).
curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/v2/account/events/router/" | norm \
  | jq '[.[] | {unique_id, name}]' > "${RAW_DIR}/routers.json"; sleep 1

# Per-team captures. Pace between calls.
while IFS="$(printf '\t')" read -r TID TNAME; do
  [ -n "$TID" ] || continue
  tdir="${RAW_DIR}/teams/${TID}"; mkdir -p "$tdir"
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/${TID}/escalation_policies/" | norm \
    | jq '[.[] | {unique_id, name, repeat_policy, move_to_next,
        rules: [.rules[]? | {position, delay, target_count: ((.targets // []) | length),
          targets: [.targets[]? | {target_type, target_id}]}]}]' > "${tdir}/escalations.json"; sleep 1
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/v2/account/teams/${TID}/oncall/" | norm \
    | jq '[.[] | {ep: .unique_id, name,
        oncall_user_count: ([.oncalls[]?.oncalls[]?] | length)}]' > "${tdir}/oncall.json"; sleep 1
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/${TID}/schedules/" | norm \
    | jq '[.[] | {unique_id, name}]' > "${tdir}/schedules.json"; sleep 1
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/${TID}/services/" | norm \
    | jq '[.[] | {unique_id, name, collation, collation_time, status, under_maintenance,
        auto_resolve_timeout, escalation_policy}]' > "${tdir}/services.json"; sleep 1
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/${TID}/maintenance/" | norm \
    | jq '[.[] | {unique_id, name, start_time, end_time, repeat_interval, repeat_until,
        service_count: ((.services // []) | length)}]' > "${tdir}/maintenance.json"; sleep 1
done < "${RAW_DIR}/teams.tsv"

echo "inventory captured under ${RAW_DIR}"
```

Per-service integrations and their alert rules are pulled in section 6 (they are the noisiest read path and need the tightest pacing). Expected: per-team escalation/oncall/schedule/service/maintenance files plus account-wide routers. A 401/403 is an auth finding; a 429 is a pacing signal — sleep and retry per section 9, then mark `blocked`.

## 5. Escalation and on-call (ZD-001 to ZD-005)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"   # per-team; loop over teams.tsv in the real run

# ZD-001 + ZD-002: escalation presence and SPOF shape.
jq '[.[] | {unique_id, name, repeat_policy,
    rule_count: (.rules | length),
    min_targets: ([.rules[].target_count] | min)}]' "${tdir}/escalations.json"
# An empty escalations.json ([]) on a team is ZD-001 critical. A policy with rule_count 1,
# min_targets 1, and repeat_policy 0 is the SPOF shape (ZD-001 high). Multi-level or repeat
# deliberate = ZD-002 pass; a one-shot single level with no repeat is the ZD-002 finding.

# ZD-003: on-call staffed now. oncall_user_count 0 on an escalation policy pages nobody.
jq '[.[] | select(.oncall_user_count == 0) | {ep, name}]' "${tdir}/oncall.json"
# Expect: []. Each hit is an escalation policy whose current on-call has no users (ZD-003 high).

# ZD-004: schedules present (empty schedule list on a team that relies on rotations is a gap).
jq 'length as $n | {schedule_count: $n}' "${tdir}/schedules.json"
# Pair with oncall: a team with escalation policies targeting schedules but zero schedules,
# or schedules that yield no on-call, is ZD-004. Judge against the team's paging intent.

# ZD-005: disabled integrations on a live path (needs the per-service integration pull, section 6).
# See section 6's is_enabled read; a service whose only integration is is_enabled:false can be
# paged by nothing (ZD-005 critical). Judge a deliberately-retired integration as ZD-023 drift.
```

## 6. Alert noise (ZD-010 to ZD-016)

Per-service integrations and alert rules are the tightest-paced reads. Pull them here, pacing hard.

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
AUTH="Authorization: Token ${ZENDUTY_TOKEN}"
norm() { jq 'if type=="array" then . else (.results // []) end'; }
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"

# ZD-010: per-service collation (time-based dedup). collation 0 = off, 1 = time-based.
jq '[.[] | {unique_id, name, collation, collation_time,
    dedup: (if .collation == 1 then "time-based" elif .collation == 0 then "off" else "other" end)}]' \
  "${tdir}/services.json"
# collation 0 on a chatty service is ZD-010: every alert becomes its own incident. Note in the
# report that content-based / AI correlation are NOT exposed via collation, so this reads
# time-based-vs-off only; absence of content-based is "not API-readable", never a fail.

# Per-service integrations + alert rules (transformers). Pace: sleep between each.
for SID in $(jq -r '.[].unique_id' "${tdir}/services.json"); do
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/account/teams/${TID}/services/${SID}/integrations/" | norm \
    | jq --arg sid "$SID" '[.[] | {service: $sid, unique_id, name, is_enabled,
        ingestion: (.application_reference.extension // .application_reference.name // null)}]' \
    > "${tdir}/svc-${SID}-integrations.json"
  sleep 1
  for IID in $(jq -r '.[].unique_id' "${tdir}/svc-${SID}-integrations.json"); do
    curl -fsS --max-time 30 -H "$AUTH" \
      "${ZD_API}/account/teams/${TID}/services/${SID}/integrations/${IID}/transformers/" | norm \
      | jq --arg iid "$IID" '[.[] | {integration: $iid, unique_id, description,
          action_count: ((.actions // []) | length),
          actions: [.actions[]? | {action_type, key}]}]' > "${tdir}/int-${IID}-rules.json"
    sleep 1
  done
done

# ZD-005 input: disabled integrations.
cat "${tdir}"/svc-*-integrations.json 2>/dev/null | jq -s 'add | [.[] | select(.is_enabled == false)]'
# ZD-023 input: deprecated API-Integration ingestion type still present.
cat "${tdir}"/svc-*-integrations.json 2>/dev/null | jq -s 'add | [.[] | select((.ingestion // "") | test("api"; "i"))]'
# ZD-011/012/013/014: alert-rule actions. Action names are documented; the numeric action_type
# is not officially mapped, so read the human action off the rule where possible and describe it.
# A suppress rule with an always-true / empty condition is ZD-011 high (accidental drop-all).
# A "Change Entity Id" action setting a blank value disables dedup (ZD-014).
```

**ZD-015 (auto-ack/auto-resolve)** is observed from the incident/alert stream: whether an integration's incidents close without human action (sources emitting resolve `alert_type`s) versus only ever triggering. Sample within the tight alert-GET limit (1/second) and state it is a sample, not a full-history count.

**ZD-016 (open-ended recurring maintenance)** reads the maintenance capture from section 4:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"
jq '[.[] | select((.repeat_interval // 0) != 0 and .repeat_until == null)
    | {unique_id, name, repeat_interval, service_count}]' "${tdir}/maintenance.json"
# A recurring window (repeat_interval != 0) with repeat_until null recurs forever, silencing
# its services indefinitely (ZD-016 high). A bounded window, or a recurring one with an end, is fine.
```

## 7. Coverage and hygiene (ZD-020 to ZD-023)

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
AUTH="Authorization: Token ${ZENDUTY_TOKEN}"
norm() { jq 'if type=="array" then . else (.results // []) end'; }

# ZD-020: global routing rulesets per router. Overlapping conditions fan one alert to many
# services; a missing catch-all (no empty/always-true rule_json) leaves unmatched alerts unrouted.
for RID in $(jq -r '.[].unique_id' "${RAW_DIR}/routers.json"); do
  curl -fsS --max-time 30 -H "$AUTH" "${ZD_API}/v2/account/events/router/${RID}/rulesets/" | norm \
    | jq --arg rid "$RID" '[.[] | {router: $rid, unique_id, name, position,
        rule_json, target_count: ((.actions // []) | length)}]' > "${RAW_DIR}/router-${RID}-rules.json"
  sleep 1
done
# Inspect rule_json across rules by position for duplicate/overlapping match conditions, and
# whether any rule is a catch-all default. No default = ZD-020 (unmatched alerts have no route).

# ZD-023: deprecated API-Integration ingestion (see section 6's ingestion capture).
# Any integration whose ingestion type is the legacy API-Integration is migration debt: that
# ingestion path stopped working 2025-05-15; the replacement is the Generic Integration.
```

**ZD-021 (critical-service coverage)** is a judgment cross-map: for each critical service from `topology.md`, confirm a Zenduty team and service exist and an escalation path reaches a staffed on-call. Name affected services; "three services have no paging path" is not a finding, "checkout, payments, and search have no Zenduty escalation path" is. **ZD-022** is the honesty row: state the teams audited (from `zenduty.teams`) and name every team from `/api/account/teams/` not audited as uncovered in the denominators.

## 8. Actionability (ZD-030 to ZD-032)

Zenduty exposes server-side analytics, so MTTA/MTTR are the vendor's own measured statistics. Unacked aging comes from the incident filter (a read-by-POST).

```bash
set -eu
ZD_API="https://www.zenduty.com/api"
AUTH="Authorization: Token ${ZENDUTY_TOKEN}"
AGING_HOURS="4"   # example, tune to your paging SLA

# ZD-030: unacknowledged (triggered) incidents. status 1 = triggered/unacked.
# POST filter is a read-by-filter (no mutation). Pace: incident GET class is 3/s, 30/min.
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${ZD_API}/incidents/filter/" \
  -d '{"status":1,"all_teams":1}' \
  | jq '{unacked: ((.results // .) | length),
      oldest: ((.results // .) | map(.creation_date) | min // null)}'
# Every triggered incident older than AGING_HOURS (now - creation_date) is a page nobody took
# (ZD-030 high). acknowledged_date null confirms it was never acked.

# ZD-031 + ZD-032: MTTA/MTTR from analytics (POST, server-side aggregation, changes nothing).
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${ZD_API}/v2/account/analytics/service_analytics/" \
  -d '{"from_date":"2026-06-25","to_date":"2026-07-25","time_zone":"UTC"}' \
  | jq '{all: (.all_services // {} | {total_incidents, total_acknowledged, total_resolved,
          mtta_seconds, mttr_seconds}),
      per_service: [(.service_records // [])[] | {service: .service.name,
          total_incidents, total_acknowledged, total_resolved, mtta_seconds, mttr_seconds}]}'
# ZD-031: mtta_seconds vs MTTA_TARGET_MIN per service where total_acknowledged > 0. ZD-032:
# mttr_seconds vs MTTR_TARGET_MIN plus the acked/resolved share. All figures carry the analytics
# window (from_date/to_date) in evidence and are the vendor's own numbers, never fabricated.
```

## 9. Rate-limit handling (all sections) — the defining constraint

Zenduty publishes tight, per-endpoint-class limits. Pace every call and back off on `429`; there is no documented `Retry-After` header, so use a fixed wait (about a minute) plus exponential backoff, and on a second `429` record the affected checks as `blocked` with the reason rather than hammering.

| Endpoint class | Per second | Per minute |
| --- | ---: | ---: |
| Incident GET (incl. filter) | 3 | 30 |
| Alert GET | 1 | 20 |
| On-call GET | 2 | 40 |
| List GETs (teams, schedules, escalation policies, applications, bots) | 5 | 40 |
| Incident Stats report | 5 | 40 |

Service/team/user analytics are not explicitly in the published table; treat them conservatively at the report class (about 5/second, 40/minute) and pace accordingly. On the large path, batch by team against the worklist per skill-authoring-conventions.md so a throttle pauses one batch, not the whole run. The per-service integration and alert-rule pulls in section 6 are the densest; a `sleep 1` between each is the floor, more on a large estate.

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, resolve its Zenduty team, service, escalation path, and collation state, then fill the matrix row from sections 5-8: escalation (ZD-001), on-call (ZD-003), noise (ZD-010/011), actionability (ZD-031/032). Name affected services and the team each finding is in.

## 11. Reserved

(No section 11 content; numbering preserved so section anchors stay stable if a category is added later.)

## 12. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `AGING_HOURS` | 4 | hours a triggered incident may sit unacknowledged before ZD-030 flags it |
| `MTTA_TARGET_MIN` | 15 | target mean-time-to-acknowledge in minutes for ZD-031 |
| `MTTR_TARGET_MIN` | 120 | target mean-time-to-resolve in minutes for ZD-032 |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. The only POSTs allowed are the two documented read-by-effect calls: `POST /api/incidents/filter/` (lists incidents) and `POST /api/v2/account/analytics/*` (server-side aggregation). Never run:

- Any `POST` that creates or triggers an incident (`POST /api/incidents/`), acknowledges, resolves, snoozes, or merges one.
- Any `PUT`/`PATCH`/`DELETE` against services, integrations, alert rules (`transformers`), escalation policies, schedules, maintenance windows, or global routers.
- Any alert-ingestion `POST` to `events.zenduty.com` (that creates a real alert).
- Any write to Noise Reduction / `collation`, or any bot/API-key management call.
