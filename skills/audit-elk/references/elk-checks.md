# audit-elk: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-elk](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Auth is `Authorization: ApiKey <encoded>` with the encoded Elasticsearch API key from the variable named by `elk.token_env`. Presence-check it only; never echo, log, or write the value. One ES API key works on both the Elasticsearch and Kibana APIs; alerting rules are a **Kibana** API.
- `KIBANA_URL` is `elk.kibana_url` — the Kibana host, not Elasticsearch. Every block declares it. A 404 on an alerting path usually means the URL points at Elasticsearch, or a space/base-path prefix is wrong.
- **Rules are space-isolated, and spaces are discovered — never assumed.** Every alerting and connector read is scoped to a space: the default space uses `/api/alerting/...`; a named space uses `/s/<space_id>/api/alerting/...`. This skill **enumerates the live spaces** via `GET /api/spaces/space` (section 4a) and audits `elk.spaces` when it is set, else **every discovered space** — a blind `["default"]`-only default is gone, because a customer's rules commonly live in a non-default space and auditing only `default` reports an empty estate (a wrong 0/100 or a vacuously-high score). Every coverage denominator names which spaces were **discovered**, **audited**, and **skipped**.
- Every command here is read-only: GET on rules, connectors, rule types, health, and maintenance windows (9.2+); `POST /_watcher/_query/watches` is a read-by-query on the Elasticsearch side (it lists watches, changes nothing) used only for the legacy-Watcher split check. The forbidden-command list is section 12.
- **Version gates matter.** Legacy `/api/alerts/*` was removed in Kibana 9.0 — this skill uses `/api/alerting/rule(s)` only. The maintenance-window list API (`GET /api/maintenance_window/_find`) is public only from 9.2; on 8.x-9.1 it is internal, so that check version-gates itself and reports `not-in-scope` with the detected version rather than failing.
- `curl -fsS --max-time 30` is the default. Where the status code is the evidence, `-f` is dropped and `-w '%{http_code}'` captures it.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 11.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| ELK-001 | Rule delivery | Every enabled rule has at least one action (connector) | critical |
| ELK-002 | Rule delivery | No rule targets a connector with missing secrets or a deprecated connector | high |
| ELK-003 | Rule delivery | No orphaned connectors referenced by zero rules (informational drift) | low |
| ELK-004 | Rule delivery | Alerting framework health is green (`is_sufficiently_secure`, permanent encryption key) | high |
| ELK-005 | Rule delivery | No critical rule whose only action is a non-paging sink connector (`.server-log`/`.index`) — *verify-pending* | high |
| ELK-006 | Rule delivery | No connector fan-in single point of failure (one connector every critical rule depends on) — *verify-pending* | high |
| ELK-010 | Rule health | No rule stuck in `execution_status: error` | critical |
| ELK-011 | Rule health | No rule in `execution_status: warning` (timeout, maxAlerts, maxQueuedActions) | high |
| ELK-012 | Rule health | `last_run.outcome` is `succeeded` for every enabled rule | high |
| ELK-013 | Rule health | No disabled rule that was meant to be a live control | medium |
| ELK-014 | Rule health | No enabled rule that has stopped executing — stale `execution_status.last_execution_date` (scheduler/task-manager stall) — *verify-pending* | high |
| ELK-020 | Alert noise | Flapping detection on where a rule can toggle (`flapping` object or space default) | medium |
| ELK-021 | Alert noise | `alert_delay.active` set where a rule needs FOR-like debounce | medium |
| ELK-022 | Alert noise | Actions throttled or `onActionGroupChange`, not `onActiveAlert` every interval | medium |
| ELK-023 | Alert noise | Action summary used on high-cardinality rules instead of per-alert fan-out | low |
| ELK-024 | Alert noise | No rule snoozed indefinitely or `mute_all` with no end (`snooze_schedule`, `mute_all`) | high |
| ELK-025 | Alert noise | Maintenance windows are not permanent (9.2+ only; version-gated) | medium |
| ELK-030 | Coverage | Rule-type coverage: the rule types present cover the critical services | high |
| ELK-031 | Coverage | Critical services from topology have at least one alerting rule | high |
| ELK-032 | Coverage | Legacy Watcher vs Kibana Alerting split identified (no silent Watcher-only coverage) | medium |
| ELK-033 | Coverage | Alerting rules are visible in at least one discovered space (zero rules across every space this key can see is `blocked`, not a plain fail — a likely space-visibility gap: the rules may live in a space the key cannot see; widen the key to `spaces:["*"]` read) | high |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Rule delivery**: every enabled rule fires to at least one live connector, no connector has missing secrets or is deprecated, no orphaned connectors, and the alerting framework itself is healthy and securely configured.
- **Rule health**: no rule in error or warning execution state, every enabled rule's last run succeeded, and no rule that should be live sits disabled.
- **Alert noise**: flapping detection on, FOR-like debounce where needed, actions throttled or status-change-gated rather than re-notifying every interval, summaries on high-cardinality rules, no indefinite snoozes or permanent maintenance windows.
- **Coverage**: spaces are discovered live (not assumed), rules are visible in at least one discovered space, rule types and rules actually cover the critical services, and any legacy Watcher coverage is identified rather than silently trusted or missed.

## 4a. Space enumeration (do this first — never assume `default`)

Kibana alerting rules are **space-isolated**, and a customer's rules commonly live in a **non-default** space. Auditing only `default` when the rules are elsewhere reports an empty estate — a wrong `0/100`, or (worse) a vacuously-high score from checks that pass on zero rules. So the first inventory step is to **enumerate the spaces that actually exist**, via the global Spaces API, and drive the per-space loop from that — not from a hardcoded default.

```bash
set -eu
KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
KIBANA_URL="${KIBANA_URL%/}"
AUTH="Authorization: ApiKey ${KIBANA_API_KEY}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# GET /api/spaces/space is a GLOBAL endpoint (no /s/<space> prefix). It needs NO admin /
# kibana_admin privilege — any authenticated key can call it — but its response is FILTERED
# to only the spaces where the key holds at least one Kibana feature privilege. So a key
# scoped to a single space enumerates only that space (this is exactly how the wrong/empty
# space bug happens). For complete discovery the key's role must grant the three Read
# feature privileges (Stack Rules, Rules Settings, Actions and Connectors) at spaces:["*"]
# — still fully read-only, no admin. See /scoutflo:connect (references/providers.md).
SPACES_CODE="$(curl -s -o "${RAW_DIR}/spaces.json" -w '%{http_code}' --max-time 15 \
  -H "$AUTH" "${KIBANA_URL}/api/spaces/space")"

DISCOVERY="ok"
if [ "$SPACES_CODE" = "200" ] && jq -e 'type == "array"' "${RAW_DIR}/spaces.json" >/dev/null 2>&1; then
  jq -r '.[].id' "${RAW_DIR}/spaces.json" | sort -u > "${RAW_DIR}/spaces-discovered.txt"
else
  # 404 = Spaces feature / Security plugin absent (or a Serverless difference). Do NOT
  # silently assume the default space is the whole estate — record it and fall back.
  DISCOVERY="unavailable (HTTP ${SPACES_CODE}: Spaces API not reachable — Security plugin or Spaces feature may be off)"
  printf '%s\n' "default" > "${RAW_DIR}/spaces-discovered.txt"
fi
echo "space discovery: ${DISCOVERY}"
echo "discovered spaces: $(tr '\n' ' ' < "${RAW_DIR}/spaces-discovered.txt")"
```

Then resolve the **audited set**:

- If `elk.spaces` is set, audit exactly those — but validate each against `spaces-discovered.txt`. A configured space that is **not** in the discovered list is a privilege/scope gap (the key cannot see it): report it as `skipped` with that reason, never silently drop it.
- If `elk.spaces` is **unset**, audit **every discovered space**.
- Always record three sets for the report and the coverage denominators: **discovered**, **audited**, **skipped**.

```bash
# Audited set = elk.spaces ∩ discovered  (when elk.spaces set), else all discovered.
# ELK_SPACES holds the configured entries one per line, empty when unset.
: > "${RAW_DIR}/spaces.txt"
if [ -s "${RAW_DIR}/elk-spaces-config.txt" ]; then
  while read -r s; do
    [ -n "$s" ] || continue
    if grep -qxF "$s" "${RAW_DIR}/spaces-discovered.txt"; then
      printf '%s\n' "$s" >> "${RAW_DIR}/spaces.txt"
    else
      printf '%s\tconfigured-but-not-visible-to-this-key (widen to spaces:["*"] read)\n' "$s" \
        >> "${RAW_DIR}/spaces-skipped.txt"
    fi
  done < "${RAW_DIR}/elk-spaces-config.txt"
else
  cp "${RAW_DIR}/spaces-discovered.txt" "${RAW_DIR}/spaces.txt"
fi
echo "audited spaces: $(tr '\n' ' ' < "${RAW_DIR}/spaces.txt")"
[ -f "${RAW_DIR}/spaces-skipped.txt" ] && echo "skipped (not visible): $(cut -f1 "${RAW_DIR}/spaces-skipped.txt" | tr '\n' ' ')"
```

Edge cases to state, never hide: a **disabled Security plugin** returns all spaces unconditionally (discovery is trivially complete); a **404** means discovery was unavailable and the run fell back to `default` — say so in the report and treat a resulting zero-rule estate as a possible visibility gap (ELK-033), not a confident empty.

## 4. Per-space inventory (all categories)

The audited set now comes from `spaces.txt`, materialized by section 4a from **live enumeration** (never a hardcoded default). Capture rules, connectors, and rule types per space.

```bash
set -eu
KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"
AUTH="Authorization: ApiKey ${KIBANA_API_KEY}"

# Kibana version drives the version-gated checks (maintenance windows, legacy routes).
curl -fsS --max-time 15 -H "$AUTH" "${KIBANA_URL}/api/status" \
  | jq -r '.version.number // "unknown"' > "${RAW_DIR}/kibana-version.txt"
echo "kibana version: $(cat "${RAW_DIR}/kibana-version.txt")"

# Alerting framework health (ELK-004) — also the doctor probe.
curl -fsS --max-time 15 -H "$AUTH" "${KIBANA_URL}/api/alerting/_health" \
  | jq '{is_sufficiently_secure, has_permanent_encryption_key, alerting_framework_health}' \
  > "${RAW_DIR}/alerting-health.json"

# Spaces to audit come from ${RAW_DIR}/spaces.txt, which section 4a already materialized
# from live GET /api/spaces/space enumeration (intersected with elk.spaces when set).
# Do NOT hardcode "default" here — that is the wrong/empty-space bug. If section 4a did not
# run, run it first; spaces.txt must exist and be non-empty before this loop.
[ -s "${RAW_DIR}/spaces.txt" ] || { echo "spaces.txt missing/empty — run section 4a (space enumeration) first"; exit 1; }

while read -r space; do
  [ -n "$space" ] || continue
  if [ "$space" = "default" ]; then base="${KIBANA_URL}"; else base="${KIBANA_URL}/s/${space}"; fi
  sdir="${RAW_DIR}/spaces/${space}"; mkdir -p "$sdir"

  # All rules in this space. per_page bounded; paginate via page= when total_count exceeds it.
  curl -fsS --max-time 60 -H "$AUTH" "${base}/api/alerting/rules/_find?per_page=100&page=1" \
    | jq '{total: .total, rules: [.data[] | {id, name, rule_type_id, enabled, mute_all,
        muted_alert_ids, snooze_schedule,
        execution_status: .execution_status.status,
        last_execution_date: (.execution_status.last_execution_date // null),
        schedule_interval: (.schedule.interval // null),
        last_run_outcome: (.last_run.outcome // null),
        last_run_warning: (.last_run.warning // null),
        alerts_count: (.last_run.alerts_count // null),
        flapping,
        alert_delay: (.alert_delay // null),
        actions: [.actions[]? | {connector_type_id, id: .id, group,
          notify_when: (.frequency.notify_when // null),
          throttle: (.frequency.throttle // null),
          summary: (.frequency.summary // null)}]}]}' > "${sdir}/rules.json"

  # Connectors in this space.
  curl -fsS --max-time 30 -H "$AUTH" "${base}/api/actions/connectors" \
    | jq '[.[] | {id, name, connector_type_id, is_missing_secrets, is_deprecated,
        referenced_by_count: (.referenced_by_count // 0)}]' > "${sdir}/connectors.json"

  # Rule types available in this space (coverage denominator).
  curl -fsS --max-time 30 -H "$AUTH" "${base}/api/alerting/rule_types" \
    | jq '[.[] | {id, name, producer}]' > "${sdir}/rule-types.json"
done < "${RAW_DIR}/spaces.txt"

wc -l "${RAW_DIR}"/spaces/*/rules.json 2>/dev/null || echo "no rules captured"
```

Expected: per-space `rules.json`, `connectors.json`, `rule-types.json`, plus the version and health files. A 401/403 is an auth/privilege finding (the role lacks Kibana Read on Stack Rules or Actions and Connectors) for the checks that need it; a 404 on `/api/alerting/*` means the URL is Elasticsearch, not Kibana.

## 5. Rule delivery (ELK-001 to ELK-006)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"   # per-space; loop over spaces.txt in the real run
sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-001: enabled rules with no actions (detect but notify nobody)
jq '[.rules[] | select(.enabled == true and (.actions | length) == 0) | {id, name, rule_type_id}]' "${sdir}/rules.json"
# Expect: []. An enabled rule with zero actions raises an alert in Kibana that pages no one.
# Blast radius (compute it, do NOT stop at "pages nobody"): join each action-less enabled
# rule to the critical services it is the detector for. Match the rule name/tags/query
# index-pattern against the service name / serviceValue from topology-export.json, then
# report the NAMED set and count of critical services whose ONLY enabled rule is action-less:
#   jq -r '[.rules[]|select(.enabled and (.actions|length==0))|.name]' "${sdir}/rules.json"
# e.g. "checkout and payments each have exactly one enabled alerting rule and it has no
# connector — a checkout error tonight raises an in-Kibana alert seen by no one." The count
# of sole-detector critical services is the blast radius, not the raw rule count.
# Correlation: this is the HEAD of the flagship dark-critical-service chain (ELK-031 presence
# -> ELK-001/005/002 delivery -> ELK-010/014 health -> ELK-024/025 suppression). Name ELK-031
# in evidence when the action-less rule is a critical service's sole rule.
# Verification (read-only): re-run GET /api/alerting/rules/_find for the rule; confirm
# .actions|length>0 and every .actions[].connector_type_id is a paging type, and the target
# connector's is_missing_secrets==false.

# ELK-002 input: connectors with missing secrets or deprecated
jq '[.[] | select(.is_missing_secrets == true or .is_deprecated == true)
    | {id, name, connector_type_id, is_missing_secrets, is_deprecated, referenced_by_count}]' "${sdir}/connectors.json"
# A rule whose action targets one of these connector ids is ELK-002 (high): the alert
# fires but the notification cannot be delivered. Cross-reference action.id against these.
# Blast radius (fan OUT from the dead connector, do not file one finding per rule): list every
# rule whose .actions[].id equals the dead connector id, then join those rule names to critical
# services. referenced_by_count gives the raw rule count; the topology join names the services:
#   DEAD="<dead-connector-id>"; jq -r --arg c "$DEAD" '[.rules[]|select([.actions[]?.id]|any(.==$c))|.name]' "${sdir}/rules.json"
# e.g. "connector oncall-slack reports is_missing_secrets and is the sole action on 6 rules
# including the only rules for checkout, payments, and search — all three are dark on one broken
# connector." Correlation: this directly powers ELK-006 (fan-in SPOF) — one dead connector every
# critical rule depends on is a single point of paging failure, not N unrelated findings.
# Verification (read-only): re-GET /api/actions/connectors in the space; confirm the connector's
# is_missing_secrets==false and is_deprecated==false.

# ELK-003: orphaned connectors (referenced by zero rules) — drift, low severity
jq '[.[] | select(.referenced_by_count == 0) | {id, name, connector_type_id}]' "${sdir}/connectors.json"
# The inverse of ELK-006: a connector nothing references (dead weight) vs one connector
# everything references (a fan-in SPOF, section 5.1).

# ELK-004: alerting framework health
jq '{secure: .is_sufficiently_secure, key: .has_permanent_encryption_key,
     framework: .alerting_framework_health}' "${RAW_DIR}/alerting-health.json"
# is_sufficiently_secure=false (Kibana not behind TLS) or has_permanent_encryption_key=false
# is a high finding — but state the ESTATE-WIDE blast radius, not the adjective "not durably
# wired". When has_permanent_encryption_key==false, connector secrets and rule API keys (the
# encrypted saved objects) cannot be decrypted after the next Kibana restart — because Kibana
# generates a random key on each boot — so ALL enabled rules across ALL audited spaces silently
# stop notifying on the next restart. Compute the ENABLED count (do NOT reuse the estate-sizing
# TOTAL, which is .total = enabled+disabled and over-counts):
#   jq '[.rules[]|select(.enabled)]|length' "${sdir}/rules.json"   # sum across audited spaces
# e.g. "no permanent encryption key: all 42 enabled rules across 3 spaces silently stop
# notifying after any Kibana restart." is_sufficiently_secure==false means the same secrets
# travel without TLS. Correlation: cite ELK-004 as the systemic root when multiple connectors
# turn unhealthy after a restart (a mass ELK-002); it chains upstream to every delivery finding.
# Verification (read-only): re-GET /api/alerting/_health; confirm has_permanent_encryption_key
# ==true and is_sufficiently_secure==true.
```

### 5.1 Deep delivery — sink-only rules and connector fan-in (ELK-005, ELK-006)

> **Verify-pending.** These two checks are drafted against Kibana's documented Alerting/Actions REST API and adversarially reviewed, but have **not** been run against a live Kibana tenant — no Kibana Alerting API with a `KIBANA_API_KEY` is wired into the benchmark estate (it is LGTM/VictoriaMetrics/ClickStack/Grafana/Alertmanager). Treat their status as unproven until a first live run against a real deployment with a read-only `KIBANA_API_KEY` and a `topology-export.json` to join against. The `.server-log`/`.index` connector type ids, the fan-in grouping, and the fields below are from Kibana's public API docs, not confirmed against a live tenant here.

Both close the exact hole the presence/health checks leave: ELK-001 asks *does the rule have an action?* and ELK-002 asks *is the connector healthy?* — neither asks whether the connector **type can reach a human**, nor whether every critical rule leans on the **same** connector. Both join to critical services via `topology-export.json`, so each carries a per-service blast radius, not a global count.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"   # per-space; loop over spaces.txt in the real run

# ELK-005: enabled rules whose EVERY action is a non-paging sink type (.server-log / .index).
# .server-log writes to the Kibana server log; .index writes to an ES index — no human is paged.
jq '[.rules[] | select(.enabled == true)
    | {id, name, rule_type_id, action_types: [.actions[]?.connector_type_id]}
    | select((.action_types | length) > 0)
    | select([.action_types[] | select(. != ".server-log" and . != ".index")] | length == 0)]' \
  "${sdir}/rules.json"
# Expect: []. A hit PASSES ELK-001 (it has actions) and PASSES ELK-002 (the connector is
# healthy), yet pages no one. Blast radius: join the offending rule names to critical services
# from topology-export.json and count — "payments has one enabled rule and its only action is
# .index — the alert is written to an index nobody watches; payments pages no one." Blast radius
# = the NAMED critical services whose every action is a sink type. Correlation: the central node
# of the dark-critical-service chain between ELK-001 (action present?) and ELK-002 (connector
# healthy?); cite ELK-031 when the sink-only rule is a service's sole rule.
# Verification (read-only): re-GET the rule; confirm at least one .actions[].connector_type_id
# is a paging type (not .server-log / .index).

# ELK-006: connector fan-in single point of failure — one connector many enabled rules depend on.
jq -r '[.rules[] | . as $r | .actions[]? | {connector: .id, rule: $r.name, enabled: $r.enabled}]
    | map(select(.enabled))
    | group_by(.connector)
    | map({connector: .[0].connector, rule_count: length, rules: [.[].rule]})
    | sort_by(-.rule_count) | .[] | select(.rule_count > 1)' "${sdir}/rules.json"
# Cross the fan-in count with connector health (connectors.json has referenced_by_count):
jq '[.[] | {id, name, connector_type_id, is_missing_secrets, is_deprecated, referenced_by_count}]
    | sort_by(-.referenced_by_count)' "${sdir}/connectors.json"
# Blast radius: "connector oncall-slack (referenced_by_count=12) is the sole delivery path for
# every critical-service rule; if it breaks (see ELK-002) all 12 rules go dark at once — one
# connector failure blacks out checkout, payments, search, and orders simultaneously." This is
# the inverse of ELK-003 (orphaned, zero refs); the blast radius is the NAMED critical services
# sharing the one connector. Correlation: amplifies ELK-002 (a dead connector's true reach is
# its fan-in) and turns N per-rule delivery findings into one systemic SPOF finding.
# Verification (read-only): after diversifying, re-GET /api/alerting/rules/_find and confirm the
# critical-service rules no longer all resolve to a single connector id.
```

Healthy: no enabled critical-service rule routes only to a sink type, and no single connector is the sole delivery path for the whole critical-rule set. Fail (ELK-005, high): a critical service's only rule delivers only to `.server-log`/`.index` — name the service and the rule. Fail (ELK-006, high): one connector carries every (or nearly every) critical-service rule — name the connector, the fan-in count, and the services. Remediation is inline (no `setup-elk` ships): ELK-005 → *Kibana > Stack Management > Rules > the rule > Actions*, add an action targeting a live paging connector (PagerDuty/Opsgenie/Slack) and remove or keep the sink alongside it; ELK-006 → *Kibana > Connectors* + the critical rules' *Actions* tabs, add a second independent paging connector so a single connector failure cannot dark every critical service.

## 6. Rule health (ELK-010 to ELK-014)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-010: rules in execution error (the rule itself is broken, detecting nothing)
jq '[.rules[] | select(.execution_status == "error") | {id, name, rule_type_id, warning: .last_run_warning}]' "${sdir}/rules.json"
# Expect: []. An errored rule is silent coverage — it looks configured, detects nothing.
# Blast radius (an errored rule matters only as much as the service it was the SOLE detector
# for): resolve each errored rule to its critical service(s) via the ELK-031 name/tag/query
# mapping and rank by whether it is the ONLY enabled rule watching that service —
#   "rule payments-error-rate is in execution_status: error (last_run.warning: query timeout)
#    and is the only enabled rule watching payments — payments has had zero working detection
#    since the rule started erroring." Blast radius = the NAMED critical services with no OTHER
# healthy rule covering the same signal. Correlation: the core node of the flagship
# dark-critical-service chain — ELK-031 shows the rule EXISTS (presence passes), ELK-010 shows
# the paging path is broken (it detects nothing). Name ELK-031 in evidence; this is the exact
# "looks monitored, isn't" gap no scanner assembles.
# Verification (read-only): re-GET the rule; confirm execution_status=='ok' (not 'error') and
# last_run.outcome=='succeeded'.

# ELK-011: rules in warning (timeout, maxAlerts, maxQueuedActions hit)
jq '[.rules[] | select(.execution_status == "warning") | {id, name, warning: .last_run_warning}]' "${sdir}/rules.json"
# A rule hitting maxAlerts silently drops alerts beyond the cap; a timeout means it did
# not finish evaluating. Both are degraded detection, not healthy.

# ELK-012: last_run.outcome not succeeded on an enabled rule
jq '[.rules[] | select(.enabled == true and .last_run_outcome != null and .last_run_outcome != "succeeded")
    | {id, name, outcome: .last_run_outcome}]' "${sdir}/rules.json"

# ELK-013: disabled rules — judgment, some are deliberately off
jq '[.rules[] | select(.enabled == false) | {id, name, rule_type_id}]' "${sdir}/rules.json"
# Pair with the rule name/intent before filing; a disabled rule named for a live SLO or a
# critical service is a coverage gap, a disabled scratch rule is not.
```

### 6.1 Deep health — enabled rule not executing (ELK-014)

> **Verify-pending.** Drafted against Kibana's documented Alerting REST API and adversarially reviewed, but **not** run against a live Kibana tenant — status unproven until a first live run with a read-only `KIBANA_API_KEY`. The `execution_status.last_execution_date` field and the task-manager stall behavior below are from Kibana's public API docs, not confirmed against a live tenant here.

Distinct from ELK-010 (`status == "error"`): a rule can be **enabled** with a status that is *not* `error` yet simply **not be run**. Kibana alerting rides the Kibana task manager; when it saturates, rules silently stop executing while still showing enabled. The only read-only signal is `execution_status.last_execution_date` going stale relative to `schedule.interval` (both are captured in section 4).

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"   # per-space; loop over spaces.txt in the real run
STALE_SECONDS="3600"   # example, tune to your rules' schedule.interval (default flags > 1h since last run)

# last_execution_date is ISO8601 WITH milliseconds (…Thh:mm:ss.123Z); jq fromdateiso8601
# rejects fractional seconds, so strip them before parsing — WITHOUT this the command aborts
# on real Kibana output.
jq -r --argjson now "$(date -u +%s)" --argjson stale "$STALE_SECONDS" \
  '[.rules[]
    | select(.enabled == true)
    | select(.last_execution_date != null)
    | {id, name, status: .execution_status, last: .last_execution_date, interval: .schedule_interval,
       age_s: ($now - ((.last_execution_date | sub("\\.[0-9]+Z$"; "Z")) | fromdateiso8601))}
    | select(.age_s > $stale)]' "${sdir}/rules.json"
# Expect: []. A hit is an enabled, non-errored rule the scheduler has stopped running.
# Blast radius: the NAMED critical-service rules whose last execution is far older than their
# interval — "checkout-latency (interval 1m) last executed 4h ago: the scheduler is not running
# it; checkout is silently undetected despite an enabled, non-errored rule." When ALL rules are
# stale together, that is a task-manager backlog affecting every rule — correlate with ELK-004
# (framework health) as one systemic problem, not per rule. Correlation: a new health node in
# the dark-critical-service chain — a rule that presence-passes (ELK-031) and delivery-passes
# (ELK-001) but never fires because it never runs.
# Verification (read-only): re-GET the rule after the fix; confirm a fresh last_execution_date
# (age well under schedule.interval) and execution_status=='ok'.
```

Healthy: every enabled rule's `last_execution_date` is recent relative to its `schedule.interval`. Fail (ELK-014, high): an enabled rule's last execution is far older than its interval — name the rule, its interval, and the staleness. Remediation is inline (no `setup-elk` ships): *Kibana > Stack Management > Rules > the rule > execution log* to confirm the gap, then investigate Kibana task-manager health / capacity (`xpack.task_manager` settings, task-manager health API) — a fleet-wide stall is a task-manager capacity problem, a single stale rule is usually a stuck task.

## 7. Alert noise (ELK-020 to ELK-025)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-020: flapping — per-rule flapping.enabled=false explicitly disables the space default.
# The space default is ON, so the finding is a rule that turned it OFF, or set a wide
# look_back_window with a high status_change_threshold (weak protection).
jq '[.rules[] | select(.flapping != null and .flapping.enabled == false) | {id, name}]' "${sdir}/rules.json"
# Note: flapping null means "use the space default" (ON) — that is NOT a finding. Only an
# explicit enabled:false, or a per-rule flapping object with weak look_back/threshold, is.

# ELK-021: alert_delay.active <= 1 (or absent) = fires on first breach, no FOR-like debounce
jq '[.rules[] | select((.alert_delay.active // 1) <= 1) | {id, name, rule_type_id}]' "${sdir}/rules.json"
# Judgment: a threshold rule on a spiky metric needs alert_delay; a rule on a binary
# up/down signal may legitimately fire on the first breach. Judge by rule type and intent.

# ELK-022: actions that re-notify every interval (onActiveAlert with no throttle)
jq '[.rules[] | {id, name, noisy_actions: [.actions[]
    | select(.notify_when == "onActiveAlert" and (.throttle == null))]}
    | select((.noisy_actions | length) > 0)]' "${sdir}/rules.json"
# onActiveAlert + no throttle re-fires the action on every check interval while the alert
# stays active — repeat-page spam on a stuck alert. onActionGroupChange or a throttle fixes it.

# ELK-023: per-alert fan-out on high-cardinality rules (summary=false on every action)
jq '[.rules[] | select((.alerts_count // 0) > 10)
    | select([.actions[] | select(.summary == true)] | length == 0)
    | {id, name, alerts_count}]' "${sdir}/rules.json"
# A rule producing many alerts with summary=false on all actions fans out one notification
# per alert instance. HIGH_CARDINALITY (example 10, tune it) is the flag threshold.

# ELK-024: indefinite snooze or mute_all with no end
jq '[.rules[] | select(.mute_all == true
    or ((.snooze_schedule // []) | any(.duration == -1 or .rRule.until == null and .duration == null)))
    | {id, name, mute_all, muted_instance_count: ((.muted_alert_ids // []) | length), snooze_schedule}]' "${sdir}/rules.json"
# mute_all=true keeps the rule evaluating but suppresses ALL actions indefinitely — a stuck
# blind spot. A time-bounded snooze is fine; an open-ended one is the finding.
# Blast radius (name the services, not the adjective "stuck blind spot"): join each
# mute_all / indefinitely-snoozed rule to its critical service(s) via the ELK-031 mapping —
#   "rule prod-5xx is mute_all with no end and is the only rule for storefront — storefront
#    alerting is fully suppressed (indefinite)." Also surface partial mutes: muted_alert_ids
# silence specific alert instances; report the instance count. IMPORTANT (do not fabricate a
# duration): mute_all is a boolean with NO start timestamp in /api/alerting/rules/_find — there
# is no "muted since <date>" / "muted for N days" figure to state. Compute a bounded duration
# ONLY for snooze_schedule[] entries (their rRule.until / duration are present); for mute_all
# state "suppressed with no end (indefinite)" plus the named service(s) and the muted-instance
# count — never a duration. Correlation: the suppression tail of the dark-critical-service chain
# (a rule can be healthy AND delivered yet still page no one because it is muted); chains with
# ELK-031 and, estate-wide, with ELK-025.
# Verification (read-only): re-GET the rule; confirm mute_all==false and every snooze_schedule[]
# entry has a bounded rRule.until / duration.
```

**ELK-025 (maintenance windows) is version-gated.** Read the captured version first:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
VER="$(cat "${RAW_DIR}/kibana-version.txt")"
MAJOR="${VER%%.*}"; MINOR="$(printf '%s' "$VER" | cut -d. -f2)"
# Public maintenance-window API is 9.2+. On anything lower, report ELK-025 not-in-scope.
if [ "$MAJOR" -gt 9 ] || { [ "$MAJOR" -eq 9 ] && [ "${MINOR:-0}" -ge 2 ]; }; then
  curl -fsS --max-time 30 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
    "${KIBANA_URL}/api/maintenance_window/_find" \
    | jq '[.data[]? | {id, title, enabled, r_rule: .r_rule, status, scoped_query, category_ids}]'
  # A maintenance window with no end / an unbounded recurrence is a permanent alerting
  # blackout (ELK-025). A bounded recurring window is healthy.
  # Blast radius — an ESTATE-WIDE amplifier, higher radius than a single muted rule (ELK-024):
  # an enabled window with an unbounded r_rule suppresses notifications for every rule in its
  # SCOPE. Capture scoped_query and category_ids so you can tell scope apart before stating a
  # count — do NOT assert "all N rules" blindly:
  #   - UNSCOPED window (no scoped_query and no category filter): blast radius = ALL enabled
  #     rules in the space (computable) — "the always-on window Global-MW suppresses all 42
  #     enabled rules including checkout/payments/search — the whole estate is in a permanent
  #     alerting blackout while the window shows enabled." When present, cite it as the TOP lever;
  #     it can dark every critical service at once, dominating individual ELK-001/010/024 findings.
  #   - SCOPED window (scoped_query or category_ids set): intersect the scope with the enabled
  #     critical-service rules and report ONLY the intersected set — never "all N".
  # Correlation: estate-wide amplifier of the dark-critical-service chain; chains with ELK-024.
  # Verification (read-only): re-GET /api/maintenance_window/_find; confirm no window has an
  # unbounded/absent r_rule.until while enabled==true.
else
  echo "kibana ${VER} < 9.2: maintenance-window public API not available; ELK-025 not-in-scope this version"
fi
```

## 8. Coverage (ELK-030 to ELK-032)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-030: which rule types are actually in use vs available
jq -r '[.rules[].rule_type_id] | group_by(.) | map({type: .[0], count: length})' "${sdir}/rules.json"
jq -r '[.[].id]' "${sdir}/rule-types.json"
# Judgment: a space with only one rule type (e.g. only index-threshold, no log-threshold
# or APM rules) may have blind signal classes; name the gap against the critical services.
# Blast radius (name the service x missing-signal-class pair, not the hypothetical "may have
# blind spots"): map each critical service's EXPECTED signal classes — logs threshold, metric
# threshold, APM latency/error, uptime — against the rule types actually present FOR THAT SERVICE
# (per-service rule_type_id set from the ELK-031 rule->service mapping) —
#   "checkout is covered only by index-threshold (log-count) rules — it has no APM
#    transaction-error or latency rule, so a checkout latency regression that does not spike log
#    volume trips nothing." Blast radius = the NAMED service x missing-class pairs, from
# rule-types.json (available) vs the per-service rule_type_id census. Correlation: complements
# ELK-031 — ELK-031 asks "any rule?", ELK-030 asks "the RIGHT KIND of rule?"; a service can pass
# ELK-031 and still be blind to a whole failure mode. Feeds the coverage-matrix Gap column.
# Verification (read-only): re-run the per-service rule-type census
#   jq '[.rules[]|select(<service filter>)|.rule_type_id]|unique' "${sdir}/rules.json"
# and confirm the previously-missing class now appears for that service.

# ELK-032: legacy Watcher vs Kibana Alerting split. Watches are an Elasticsearch API,
# needs the monitor_watcher cluster privilege. A service covered only by a Watcher is
# invisible to a Kibana-Alerting-only view.
# Requires ES_URL (elk.es_url if configured) — Watcher is NOT a Kibana API.
ES_URL="https://elasticsearch.example.com"   # elk.es_url; skip this check if not configured
curl -fsS --max-time 30 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${ES_URL}/_watcher/stats" | jq '{watcher_state: .stats[0].watcher_state, watch_count: (.stats[0].watch_count // 0)}' \
  2>/dev/null || echo "watcher stats unavailable (no es_url configured, or monitor_watcher privilege missing) — ELK-032 blocked with that reason"
# watch_count > 0 means legacy Watcher coverage exists alongside Kibana Alerting; name it
# so a Kibana-only audit does not imply the Watcher-covered services are unmonitored.
```

**ELK-031 (critical-service coverage)** is a judgment cross-map: match each `topology.md` critical service to a rule by the service name appearing in the rule name, tags, or query. Name affected services; "three services have no rule" is not a finding, "checkout, payments, and search have no Kibana alerting rule" is.

## 9. Per-space iteration and rate handling

Every check in sections 5-8 runs once per **audited** space (the `spaces.txt` set that section 4a resolved from live enumeration — every discovered space, or the `elk.spaces` subset). On the large path (many rules across many spaces), batch by space against the worklist per skill-authoring-conventions.md. Kibana returns 429 under load; on 429, sleep 10s once and retry, then record the affected space's checks as `blocked`. If **zero** rules are found across every audited space, do not score it as empty coverage — that is the ELK-033 visibility trip-wire (section 4a): the rules may live in a space this key cannot see. Block the rule-dependent categories with that reason rather than emitting a confident `0/100` or a vacuously-high score.

## 10. Per-service coverage queries (coverage matrix)

For each critical service from `./scoutflo-audits/topology.md`, resolve its rules across the audited spaces, then fill the matrix row from sections 5-8: delivery (ELK-001), health (ELK-010/012), noise (ELK-020/022), coverage (ELK-031). Name affected services and the space each finding is in.

## 11. Starting thresholds (examples, tune every one)

| Variable | Default | Meaning |
| --- | --- | --- |
| `HIGH_CARDINALITY` | 10 | alerts_count above which per-alert fan-out (no summary) is flagged (ELK-023) |

## 12. Forbidden commands

This is an audit: read-only, no exceptions. Never run:

- Any `POST`/`PUT`/`PATCH`/`DELETE` against `/api/alerting/*` or `/api/actions/*` (create/update/delete/enable/disable/mute/unmute/snooze a rule or connector).
- `POST /api/alerting/rule/{id}/_enable` or `/_disable`, `_mute_all`, `_unmute_all`, `_snooze`, `_unsnooze`.
- `POST /api/actions/connector/{id}/_execute` (fires the connector — a real notification).
- Creating, editing, or deleting maintenance windows.
- Any Elasticsearch write; the only Elasticsearch calls are the read-by-query `_watcher/stats` and `_watcher/_query/watches` for the split check.
