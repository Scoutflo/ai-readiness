# audit-elk: Check Catalog and Commands

Runnable, read-only checks for every surface the [audit-elk](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked.

## 1. Conventions

- Auth is `Authorization: ApiKey <encoded>` with the encoded Elasticsearch API key from the variable named by `elk.token_env`. Presence-check it only; never echo, log, or write the value. One ES API key works on both the Elasticsearch and Kibana APIs; alerting rules are a **Kibana** API.
- `KIBANA_URL` is `elk.kibana_url` — the Kibana host, not Elasticsearch. Every block declares it. A 404 on an alerting path usually means the URL points at Elasticsearch, or a space/base-path prefix is wrong.
- **Rules are space-isolated.** Every alerting and connector read is scoped to a space: the default space uses `/api/alerting/...`; a named space uses `/s/<space_id>/api/alerting/...`. This skill iterates the spaces in `elk.spaces` (default: `["default"]`) and every coverage denominator names which spaces were audited.
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
| ELK-010 | Rule health | No rule stuck in `execution_status: error` | critical |
| ELK-011 | Rule health | No rule in `execution_status: warning` (timeout, maxAlerts, maxQueuedActions) | high |
| ELK-012 | Rule health | `last_run.outcome` is `succeeded` for every enabled rule | high |
| ELK-013 | Rule health | No disabled rule that was meant to be a live control | medium |
| ELK-020 | Alert noise | Flapping detection on where a rule can toggle (`flapping` object or space default) | medium |
| ELK-021 | Alert noise | `alert_delay.active` set where a rule needs FOR-like debounce | medium |
| ELK-022 | Alert noise | Actions throttled or `onActionGroupChange`, not `onActiveAlert` every interval | medium |
| ELK-023 | Alert noise | Action summary used on high-cardinality rules instead of per-alert fan-out | low |
| ELK-024 | Alert noise | No rule snoozed indefinitely or `mute_all` with no end (`snooze_schedule`, `mute_all`) | high |
| ELK-025 | Alert noise | Maintenance windows are not permanent (9.2+ only; version-gated) | medium |
| ELK-030 | Coverage | Rule-type coverage: the rule types present cover the critical services | high |
| ELK-031 | Coverage | Critical services from topology have at least one alerting rule | high |
| ELK-032 | Coverage | Legacy Watcher vs Kibana Alerting split identified (no silent Watcher-only coverage) | medium |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Rule delivery**: every enabled rule fires to at least one live connector, no connector has missing secrets or is deprecated, no orphaned connectors, and the alerting framework itself is healthy and securely configured.
- **Rule health**: no rule in error or warning execution state, every enabled rule's last run succeeded, and no rule that should be live sits disabled.
- **Alert noise**: flapping detection on, FOR-like debounce where needed, actions throttled or status-change-gated rather than re-notifying every interval, summaries on high-cardinality rules, no indefinite snoozes or permanent maintenance windows.
- **Coverage**: rule types and rules actually cover the critical services, and any legacy Watcher coverage is identified rather than silently trusted or missed.

## 4. Space discovery and inventory (all categories)

Resolve which spaces to audit, then capture rules and connectors per space.

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

# Spaces to audit: elk.spaces from config, default ["default"]. Written to a file the
# per-space loop reads, so this stays stateless.
printf '%s\n' "default" > "${RAW_DIR}/spaces.txt"   # replace with elk.spaces entries, one per line

while read -r space; do
  [ -n "$space" ] || continue
  if [ "$space" = "default" ]; then base="${KIBANA_URL}"; else base="${KIBANA_URL}/s/${space}"; fi
  sdir="${RAW_DIR}/spaces/${space}"; mkdir -p "$sdir"

  # All rules in this space. per_page bounded; paginate via page= when total_count exceeds it.
  curl -fsS --max-time 60 -H "$AUTH" "${base}/api/alerting/rules/_find?per_page=100&page=1" \
    | jq '{total: .total, rules: [.data[] | {id, name, rule_type_id, enabled, mute_all,
        muted_alert_ids, snooze_schedule,
        execution_status: .execution_status.status,
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

## 5. Rule delivery (ELK-001 to ELK-004)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"   # per-space; loop over spaces.txt in the real run
sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-001: enabled rules with no actions (detect but notify nobody)
jq '[.rules[] | select(.enabled == true and (.actions | length) == 0) | {id, name, rule_type_id}]' "${sdir}/rules.json"
# Expect: []. An enabled rule with zero actions raises an alert in Kibana that pages no one.

# ELK-002 input: connectors with missing secrets or deprecated
jq '[.[] | select(.is_missing_secrets == true or .is_deprecated == true)
    | {id, name, connector_type_id, is_missing_secrets, is_deprecated}]' "${sdir}/connectors.json"
# A rule whose action targets one of these connector ids is ELK-002 (high): the alert
# fires but the notification cannot be delivered. Cross-reference action.id against these.

# ELK-003: orphaned connectors (referenced by zero rules) — drift, low severity
jq '[.[] | select(.referenced_by_count == 0) | {id, name, connector_type_id}]' "${sdir}/connectors.json"

# ELK-004: alerting framework health
jq '{secure: .is_sufficiently_secure, key: .has_permanent_encryption_key,
     framework: .alerting_framework_health}' "${RAW_DIR}/alerting-health.json"
# is_sufficiently_secure=false (Kibana not behind TLS) or has_permanent_encryption_key=false
# (rules break across restarts) is a high finding: alerting is not durably or securely wired.
```

## 6. Rule health (ELK-010 to ELK-013)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/elk/${RUN_DATE}/raw"
SPACE="default"; sdir="${RAW_DIR}/spaces/${SPACE}"

# ELK-010: rules in execution error (the rule itself is broken, detecting nothing)
jq '[.rules[] | select(.execution_status == "error") | {id, name, rule_type_id}]' "${sdir}/rules.json"
# Expect: []. An errored rule is silent coverage — it looks configured, detects nothing.

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
    | {id, name, mute_all, snooze_schedule}]' "${sdir}/rules.json"
# mute_all=true keeps the rule evaluating but suppresses ALL actions indefinitely — a stuck
# blind spot. A time-bounded snooze is fine; an open-ended one is the finding.
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
    | jq '[.data[]? | {id, title, enabled, r_rule: .r_rule, status}]'
  # A maintenance window with no end / an unbounded recurrence is a permanent alerting
  # blackout (ELK-025). A bounded recurring window is healthy.
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

Every check in sections 5-8 runs once per space in `elk.spaces`. On the large path (many rules across many spaces), batch by space against the worklist per skill-authoring-conventions.md. Kibana returns 429 under load; on 429, sleep 10s once and retry, then record the affected space's checks as `blocked`.

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
