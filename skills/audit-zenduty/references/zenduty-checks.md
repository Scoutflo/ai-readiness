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
| ZD-006 | Escalation/on-call | No escalation level targets a named individual instead of a schedule/rotation (single-human dependency) — **verify-pending** | high |
| ZD-010 | Alert noise | Per-service `collation` on where a service is chatty (time-based dedup) | medium |
| ZD-011 | Alert noise | Suppress alert rules present and not over-broad (no always-true drop-all) | high |
| ZD-012 | Alert noise | "Seconds Since Last Similar Incident" flapping guard where a source re-fires | medium |
| ZD-013 | Alert noise | Delay-notification rules deliberate, not blanket off-hours muting | medium |
| ZD-014 | Alert noise | Stable, non-blank `entity_id` so default dedup collapses repeats | medium |
| ZD-015 | Alert noise | Auto-ack/auto-resolve working (sources emit resolve `alert_type`s) | medium |
| ZD-016 | Alert noise | No open-ended recurring maintenance window (`repeat_interval` set, `repeat_until: null`) | high |
| ZD-017 | Alert noise | No alert rule downgrades a critical-service incident's urgency to non-paging (silent urgency-downgrade) — **verify-pending** | high |
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

- **Escalation and on-call**: every audited team has a multi-level escalation with a repeat, every escalation's on-call resolves to a staffed rotation, referenced schedules cover the window, no live-path integration is disabled, and every escalation level targets a rotation/schedule rather than a lone named individual — a page always reaches a reachable human, not a single phone.
- **Alert noise**: chatty services have time-based collation on, suppress and flapping-guard rules are present and narrow, delay is scoped, sources set a stable `entity_id` and emit resolve events, no maintenance window is an open-ended recurring blackout, and no alert rule silently downgrades a critical-service incident's urgency below the paging threshold.
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
        service_count: ((.services // []) | length),
        services: [.services[]? | {unique_id: (.unique_id // .service // .), name: (.name // null)}]}]' \
    > "${tdir}/maintenance.json"; sleep 1
done < "${RAW_DIR}/teams.tsv"

echo "inventory captured under ${RAW_DIR}"
```

Per-service integrations and their alert rules are pulled in section 6 (they are the noisiest read path and need the tightest pacing). Expected: per-team escalation/oncall/schedule/service/maintenance files plus account-wide routers. A 401/403 is an auth finding; a 429 is a pacing signal — sleep and retry per section 9, then mark `blocked`.

**Capture-completeness note (required for the dead-path blast radii).** Three joins the flagship cascade and its deepened checks depend on are only computable if the capture keeps the join keys, so the `jq` shapes above and in section 8 retain them deliberately — do not "simplify" them back to counts:

- `maintenance.json` keeps the full `services[]` (each `unique_id` and `name`), not just `service_count`, so **ZD-016** can resolve *which* covered services are critical rather than only how many.
- `services.json` keeps `escalation_policy` (the EP `unique_id` each service routes through), so **ZD-001/ZD-002/ZD-006/ZD-030** can join a service to the escalation policy that pages for it.
- The incident-filter capture (section 8) keeps per-incident `service`/`service_ids` and `sla_object`, so **ZD-030** can join each aging incident to its service's escalation policy and **ZD-031** can read the service's own acknowledge SLA. The old shape (unacked count + oldest only) discarded both and could not compute the per-service cause — section 8 now retains them.

## 5. Escalation and on-call (ZD-001 to ZD-005)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"   # per-team; loop over teams.tsv in the real run

# ZD-001 + ZD-002: escalation presence, SPOF shape, and whether escalation actually advances.
jq '[.[] | {unique_id, name, repeat_policy, move_to_next,
    rule_count: (.rules | length),
    min_targets: ([.rules[].target_count] | min)}]' "${tdir}/escalations.json"
# An empty escalations.json ([]) on a team is ZD-001 critical. A policy with rule_count 1,
# min_targets 1, and repeat_policy 0 is the SPOF shape (ZD-001 high). ZD-002 is the advance
# check: a multi-level policy with move_to_next:false NEVER progresses past level 1 on a no-ack,
# so its level-2+ targets are decorative — that is the ZD-002 finding (distinct from ZD-001,
# which is "no level 2 exists at all"). A one-shot single level with no repeat is also ZD-002.

# BLAST RADIUS (both) — do not stop at "this policy is shaped badly". Join services.json's
# .escalation_policy back to the offending policy's unique_id to count who actually pages
# through it, then intersect with the critical-service list from topology.md.
EP_ID="EP_UNIQUE_ID"   # a flagged policy's unique_id from the query above
jq -s --arg ep "$EP_ID" 'add | map(select(.escalation_policy == $ep)) | {ep:$ep,
    services_routing: length, service_names: [.[].name]}' "${tdir}"/services.json 2>/dev/null
# State it as a computed reach, never an adjective: "the payments EP is 1 rule / 1 target /
# repeat_policy 0; 6 services route through it (services.json escalation_policy join), 2 of them
# critical (checkout, payments per topology) — a missed ack is never re-sent and there is no
# level 2, so those 6 services have no paging backstop tonight." For ZD-002 name the same reach:
# "the platform EP has 3 levels but move_to_next:false — the 4 services routing to it escalate to
# nobody beyond level 1." Chains with ZD-003 (does that single target's on-call resolve to a
# staffed user now?) and ZD-030 (aging unacked incidents on those same services are the live
# proof the backstop already failed). Leg of the flagship dead-paging-path cascade (section 14).

# ZD-003: on-call staffed now. oncall_user_count 0 on an escalation policy pages nobody.
jq '[.[] | select(.oncall_user_count == 0) | {ep, name}]' "${tdir}/oncall.json"
# Expect: []. Each hit is an escalation policy whose current on-call has no users (ZD-003 high).

# ZD-004: schedules present (empty schedule list on a team that relies on rotations is a gap).
jq 'length as $n | {schedule_count: $n}' "${tdir}/schedules.json"
# Pair with oncall: a team with escalation policies targeting schedules but zero schedules,
# or schedules that yield no on-call, is ZD-004. Judge against the team's paging intent.

# ZD-005: disabled integrations on a live path (needs the per-service integration pull, section 6).
# See section 6's is_enabled read. BLAST RADIUS: don't stop at "an integration is off" — count
# is_enabled:true integrations per service; a service whose enabled count is 0 is FULLY DARK (no
# monitoring tool can open an incident on it). Intersect the dark services with topology critical
# services: "checkout's only integration (Prometheus, is_enabled:false) is off — nothing can open
# an incident on checkout; checkout is critical (topology), so it is invisible to paging and ZD-030
# cannot even show aging because zero incidents are ever created." That silent-no-stream case is
# worse than aging. Judge a deliberately-retired integration as ZD-023 drift, not ZD-005. Leg of
# the flagship dead-paging-path cascade (section 14); silent-loss sibling of ZD-017/ZD-023.
```

### ZD-006 — Escalation level targets a named individual, not a rotation (single-human dependency)

> **Verify-pending.** Drafted against Zenduty's documented API and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token. The `target_type`/`target_id` fields on an escalation rule are real (section 5 capture), but the integer `target_type` → `{user, schedule}` enum mapping is **UNVERIFIED** against a live account; confirm the enum before flagging.

An escalation level whose every target is a specific user (rather than an on-call schedule/rotation) pages nobody the moment that individual is on leave, changes phone, or leaves — there is no rotation to fall back to. This is distinct from ZD-003 (a rotation exists but is empty *now*) and ZD-001 (count-based SPOF: one rule / one target of any kind).

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"

# Enumerate each escalation level's target kinds from the section-5 capture (read-only).
jq '[.[] | {ep: .name, unique_id,
    rules: [.rules[]? | {position,
        targets: [.targets[]? | {target_type, target_id}]}]}]' "${tdir}/escalations.json"
# target_type is an integer; the int -> {user, schedule} mapping is UNVERIFIED (see the
# verify-pending banner). Once the enum is confirmed live, filter to rules whose EVERY target is
# the USER value (no schedule anywhere on the level): that level is a single-human dependency.

# BLAST RADIUS: same services.json join as ZD-001 — count who depends on the offending EP.
EP_ID="EP_UNIQUE_ID"   # the user-targeting policy's unique_id
jq -s --arg ep "$EP_ID" 'add | map(select(.escalation_policy == $ep)) | {ep:$ep,
    services_routing: length, service_names: [.[].name]}' "${tdir}"/services.json 2>/dev/null
# State it: "the payments EP level 1 targets user U directly (not a schedule); 6 services route
# through it (join), 2 critical — when U is off, all 6 lose level-1 paging with no rotation
# backstop." Chains with ZD-001 (both single-point escalation failures; different root: shape vs
# target-kind) and ZD-030 (aging incidents on the affected services when U is unavailable).
# Remediation is inline (no setup-zenduty ships): Zenduty > Teams > (team) > Escalation Policies —
# repoint the level at an On-Call Schedule instead of a user. Verification: re-pull
# GET .../escalation_policies/ and confirm each level names a schedule target, not a lone user.
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
# collation 0 on a chatty service is ZD-010. BLAST RADIUS: don't assert "chatty" — PROVE it from
# the section-8 service_analytics envelope. Join the collation:0 service to its analytics record
# (per_service[].service == the service name) and read total_incidents vs total_acknowledged over
# the window: "checkout has collation:0 and generated 412 incidents in 30 days but only 27 were
# acknowledged (service_analytics) — with no time-based collation every duplicate is its own page,
# so the real pages are buried and MTTA reflects the noise, not response." That live count is the
# finding; "collation is off" alone is a scanner line. Correlation: directly explains ZD-031 (high
# MTTA on the same service) and ZD-030 (real aging pages lost in the flood); distinct from ZD-014
# (entity_id dedup), the upstream default-dedup layer. Note in the report that content-based / AI
# correlation are NOT exposed via collation, so this reads time-based-vs-off only; absence of
# content-based is "not API-readable", never a fail.

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

### ZD-017 — Alert rule downgrades incident urgency to non-paging on a critical service (silent urgency-downgrade)

> **Verify-pending.** Drafted against Zenduty's documented API and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token. The "Change Incident Urgency" alert-rule action is real (named in the verified action list) and the transformer/action payload is captured in `int-*-rules.json`, but the integer `action_type` → action-name enum mapping is **UNVERIFIED** against a live account; read the action by its `key`/name and confirm the enum before flagging.

A "Change Incident Urgency → low" alert-rule action *keeps* the incident but makes it a silent notification instead of a page. On a critical service, real incidents are created and visible in the stream but never wake anyone. This is the silent-notification case a suppress-rule scan misses: distinct from ZD-011 (suppress DROPS the alert entirely; ZD-017 keeps it but de-fangs it).

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"

# Transformers (alert rules) are already pulled per integration in section 6 as int-*-rules.json.
# Read each action by its key/name; the numeric action_type is UNVERIFIED (see the banner).
cat "${tdir}"/int-*-rules.json 2>/dev/null \
  | jq -s 'add | [.[] | . as $r | .actions[]?
      | select(((.key // "") | test("urgency"; "i")))
      | {integration: $r.integration, action_key: .key, action_type}]'
# Flag a "Change Incident Urgency" action that sets urgency to low/non-paging on an integration
# whose service is critical. BLAST RADIUS: join the integration's service (svc-*-integrations.json
# -> service) to topology critical services: "checkout's integration has a rule downgrading all
# incidents to low urgency — checkout incidents create but never page; this is why ZD-030 shows no
# AGING pages yet the service clearly has incidents." Correlation: silent-loss family with ZD-005
# (disabled), ZD-023 (dead ingestion), ZD-011 (over-broad suppress); explains a ZD-030/ZD-031
# anomaly (incidents exist, MTTA looks fine, but nobody was paged). Remediation is inline (no
# setup-zenduty ships): Integration > Alert Rules — remove or scope the Change-Incident-Urgency
# action so critical-service incidents keep high/paging urgency. Verification: re-pull the
# transformers and confirm no urgency-downgrade action applies to a critical-service integration.
```

**ZD-015 (auto-ack/auto-resolve)** is observed from the incident/alert stream: whether an integration's incidents close without human action (sources emitting resolve `alert_type`s) versus only ever triggering. Sample within the tight alert-GET limit (1/second) and state it is a sample, not a full-history count.

**ZD-016 (open-ended recurring maintenance)** reads the maintenance capture from section 4:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/zenduty/${RUN_DATE}/raw"
TID="TEAM"; tdir="${RAW_DIR}/teams/${TID}"
jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[.[]
    | select((.repeat_interval // 0) != 0 and .repeat_until == null)
    | {unique_id, name, repeat_interval, start_time,
       covered_services: [.services[]? | .name],
       elapsed_days: (((($now | fromdateiso8601) - ((.start_time // $now) | fromdateiso8601)) / 86400) | floor)}]' \
  "${tdir}/maintenance.json"
# A recurring window (repeat_interval != 0) with repeat_until null recurs forever (ZD-016 high).
# BLAST RADIUS: don't stop at "open-ended window exists" — expand services[] (now retained in the
# capture) to the covered service names, intersect with topology critical services, and compute how
# long the blackout has already run from start_time: "maintenance window W recurs forever
# (repeat_interval!=0, repeat_until:null), covers checkout + payments (2 critical), silenced since
# 2026-03-01 (176 days) — every real incident on both has been suppressed the entire time."
# Correlation: explains a ZD-030 blind spot (no aging incidents because they are suppressed at the
# window) — a service can pass every escalation check and still page nobody because a stale window
# eats the alert. Leg of the flagship dead-paging-path cascade (section 14). Remediation is inline
# (no setup-zenduty ships): Team > Maintenance — set a repeat_until bound or delete the recurrence;
# if intentional, narrow services[] to the specific non-critical ones. Verification: re-pull the
# window and confirm repeat_until non-null (or repeat_interval 0), and under_maintenance:false on
# the previously-covered critical services.
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
# BLAST RADIUS (ZD-020) — don't stop at "overlapping routes / no default", which is presence-only.
# Diff rule_json across rulesets by position: two rules whose match conditions intersect and whose
# actions target DIFFERENT services double-page one alert — NAME both target services (duplicate
# fan-out). And absence of any empty/always-true rule_json means unmatched alerts have no route —
# NAME that as a dropped class. State it: "router R has two rules matching {service:api} routing to
# both payments-svc and platform-svc — one upstream alert pages two teams; and no catch-all rule
# exists, so any alert not matching the 4 explicit rules is silently unrouted." Correlation: the
# duplicate fan-out inflates ZD-032's incident counts and MTTA noise; the missing-default drop is
# the same silent-loss family as ZD-005/ZD-017/ZD-023. Remediation is inline (no setup-zenduty
# ships): Account > Global Alert Routing — deduplicate the overlapping ruleset conditions and add a
# catch-all default rule pointing at a triage service. Verification: re-pull the rulesets and
# confirm no two rules share an intersecting rule_json with divergent targets and one always-true
# rule_json exists as default.

# ZD-023: deprecated API-Integration ingestion (see section 6's ingestion capture).
# Any integration whose ingestion type is the legacy API-Integration stopped working 2025-05-15;
# the replacement is the Generic Integration. BLAST RADIUS — more dangerous than ZD-005 because
# is_enabled stays TRUE and it LOOKS monitored: "checkout integration prometheus-legacy is on the
# API-Integration ingestion type (dead 2025-05-15) — checkout still LISTS the integration as
# enabled, so it looks monitored, but every event that source sends is dropped at ingestion;
# checkout is critical (topology)." Name the service and intersect with critical services.
# Correlation: silent-loss family with ZD-005 (disabled) and ZD-017 (urgency-downgrade); explains a
# ZD-030 gap (no incidents from that source). Remediation is inline (no setup-zenduty ships):
# migrate the integration to a Generic Integration (events.zenduty.com) and update the sending
# tool's endpoint — the API-Integration path cannot be revived. Verification: re-pull the service
# integrations and confirm no ingestion type matches the API-Integration type.
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
# CAPTURE CHANGE (required): retain per-incident service/service_ids AND sla_object — the old shape
# (unacked count + oldest only) discarded both, so ZD-030 could not join an aging incident to its
# service's escalation policy and ZD-031 could not read the service's own SLA. Keep them:
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${ZD_API}/incidents/filter/" \
  -d '{"status":1,"all_teams":1}' \
  | jq '(.results // .) as $inc
      | {unacked: ($inc | length),
         oldest: ($inc | map(.creation_date) | min // null),
         incidents: [$inc[] | {incident_number, creation_date, acknowledged_date,
             service: (.service.name // .service // null),
             service_id: (.service.unique_id // (.service_ids[0]?) // null),
             sla_object}]}'
# To scope to specific services, add "service_ids":["<sid>",...] to the filter body (still a read).
# Every triggered incident older than AGING_HOURS (now - creation_date) is a page nobody took
# (ZD-030 high). acknowledged_date null confirms it was never acked.
#
# BLAST RADIUS (ZD-030) — join each aging incident to WHY, so it reads as a cause not a count. For
# each triggered incident, carry its service, resolve that service's escalation_policy (services.json),
# and join oncall.json oncall_user_count for that EP: "9 incidents on checkout have sat triggered
# >4h; checkout's EP resolves to an on-call with oncall_user_count:0 (ZD-003) — they age because the
# rotation is empty, not because they are noise." Where the aging service instead has collation:0
# (ZD-010), note the alternate cause (buried in noise). This turns ZD-030 into the LIVE PROOF leg of
# the flagship dead-paging-path cascade (section 14): the observed consequence of ZD-003/ZD-005/
# ZD-016/ZD-017 upstream. Remediation splits by cause (inline; no setup-zenduty ships): empty-rotation
# agings -> staff the schedule (ZD-003); noise-buried agings -> enable collation (ZD-010/ZD-014).
# Verification: re-run the filter status:1 for the service after the fix and confirm the aging count
# drops; confirm oncall_user_count>0 for its EP.

# ZD-031 + ZD-032: MTTA/MTTR from analytics (POST, server-side aggregation, changes nothing).
curl -fsS --max-time 30 -H "$AUTH" -H "Content-Type: application/json" \
  -X POST "${ZD_API}/v2/account/analytics/service_analytics/" \
  -d '{"from_date":"2026-06-25","to_date":"2026-07-25","time_zone":"UTC"}' \
  | jq '{all: (.all_services // {} | {total_incidents, total_acknowledged, total_resolved,
          mtta_seconds, mttr_seconds}),
      per_service: [(.service_records // [])[] | {service: .service.name,
          total_incidents, total_acknowledged, total_resolved, mtta_seconds, mttr_seconds}]}'
# ZD-032: mttr_seconds vs MTTR_TARGET_MIN plus the acked/resolved share.
#
# ZD-031 is a TWO-SOURCE join, not a single-default comparison. sla_object.acknowledge_time is a
# per-INCIDENT field on the POST /api/incidents/filter/ response (captured above); it is NOT on
# services.json and service_analytics carries no SLA field. So compare the analytics mtta_seconds
# for a service against that service's OWN sla_object.acknowledge_time from the incident filter, and
# fall back to the documented MTTA_TARGET_MIN only when sla_object is absent. Then ATTRIBUTE the
# miss by correlating with ZD-010/ZD-014 for the same service: "checkout mtta 2140s (36m) over 30d
# on 88 acked incidents against its own SLA acknowledge_time of 900s (incident sla_object) — and
# checkout has collation:0 (ZD-010), so the miss is a noise problem, not a staffing one." Downstream
# of ZD-010/ZD-014 (noise inflates MTTA) and ZD-003 (empty rotation delays ack). All figures carry
# the analytics window (from_date/to_date) in evidence and are the vendor's own numbers, never
# fabricated. Remediation is inline (no setup-zenduty ships): attribute-then-fix — noise-driven ->
# fix collation/entity_id; staffing-driven -> fix the rotation/escalation delays.
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
| `MTTA_TARGET_MIN` | 15 | fallback target mean-time-to-acknowledge (minutes) for ZD-031, used only when the incident `sla_object.acknowledge_time` is absent; prefer the service's own SLA |
| `MTTR_TARGET_MIN` | 120 | target mean-time-to-resolve in minutes for ZD-032 |

## 13. Forbidden commands

This is an audit: read-only, no exceptions. The only POSTs allowed are the two documented read-by-effect calls: `POST /api/incidents/filter/` (lists incidents) and `POST /api/v2/account/analytics/*` (server-side aggregation). Never run:

- Any `POST` that creates or triggers an incident (`POST /api/incidents/`), acknowledges, resolves, snoozes, or merges one.
- Any `PUT`/`PATCH`/`DELETE` against services, integrations, alert rules (`transformers`), escalation policies, schedules, maintenance windows, or global routers.
- Any alert-ingestion `POST` to `events.zenduty.com` (that creates a real alert).
- Any write to Noise Reduction / `collation`, or any bot/API-key management call.

## 14. The dead-paging-path cascade (flagship correlation)

The one traversal of the paging graph no free Zenduty view assembles — Zenduty's analog of the k8s external→cluster path. For a named CRITICAL service from `topology.md`, walk the full paging graph and pinpoint the exact link where a page dies tonight, then prove it with the live incident stream. Every leg is computed from joins the raw capture already keys (services.json `.escalation_policy`, oncall.json `oncall_user_count`, maintenance.json `services[]`, the incident filter, service_analytics):

1. **Critical service** (ZD-021, from topology) →
2. its Zenduty service's only integration is `is_enabled:false` **or** on the dead API-Integration ingestion type (**ZD-005 / ZD-023**: nothing can create an incident), **or**
3. the incident routes to an escalation policy that is a SPOF / `move_to_next:false` / targets a lone user (**ZD-001 / ZD-002 / ZD-006**) →
4. whose on-call rotation is empty right now (**ZD-003**), **or**
5. a stale open-ended maintenance window silences the service outright (**ZD-016**), **or**
6. an alert rule downgrades urgency to non-paging (**ZD-017**) →
7. and the LIVE PROOF the path is already broken is **ZD-030**'s aging unacked incidents joined to that exact escalation policy's empty on-call.

The single differentiating sentence to assemble as one named finding-chain (each leg naming the others in its evidence): *"checkout is critical; its page routes to the payments EP, which is one rule / one user with an empty rotation now, and 9 checkout incidents have already sat triggered >4h unacknowledged — this specific critical service's page is dying at this specific link, and here are the incidents that already proved it."* Rank it by `points_recoverable` and lead the executive summary with it. Every scored leg's blast radius is a service/incident count from a real join, never an adjective; ZD-006 and ZD-017 are **verify-pending** legs (their enum mappings are unproven live), so mark them so and never fabricate a live observation.
