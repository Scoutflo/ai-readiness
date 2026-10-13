# setup-sentry API cookbook

Full request and response shapes for the workflow in [../SKILL.md](../SKILL.md). Every block below is stateless: it redeclares `API`, `SENTRY_ORG`, `SENTRY_TOKEN` (presence check), and any object-specific placeholder at its own top. Fill `SENTRY_HOST` and `SENTRY_ORG` with the values the live-safety gate printed, and bind `SENTRY_TOKEN` from your `token_env`, as [../SKILL.md#live-safety-gate](../SKILL.md#live-safety-gate) explains. Each block runs correctly pasted into a brand-new shell; none depends on a variable set in an earlier block.

## Platform values

`platform` on project creation: `node`, `javascript` (or `react`, `nextjs`, `vue`, `angular` for framework-specific source-map handling), `python`, `go`, `ruby`, `php`, `react-native`, `android`, `cocoa`, `dotnet`, `java`, `flutter`, `electron`, `elixir`. Pick the closest match; Sentry uses it for onboarding hints, not for gating features.

## Environment seeding

Sentry environments exist only once an event carries that environment name. On a project with no SDK deployed yet, seed each one with a single low-noise envelope event.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
ENV_NAME="production"   # repeat this whole block per environment, e.g. staging

# DSN and numeric project ID from the key list; never print or store the full DSN elsewhere.
KEY_JSON="$(curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq '.[0]')"
PUBLIC_KEY="$(printf '%s' "$KEY_JSON" | jq -r '.public')"
PROJECT_ID="$(printf '%s' "$KEY_JSON" | jq -r '.projectId')"
INGEST_HOST="$(printf '%s' "$KEY_JSON" | jq -r '.dsn.public' | sed -E 's#https://[^@]+@([^/]+)/.*#\1#')"

# 32 lowercase hex characters from 16 random bytes; portable where uuidgen is not installed.
EVENT_ID="$(od -An -N16 -tx1 /dev/urandom | tr -dc '0-9a-f')"
[ "${#EVENT_ID}" -eq 32 ] || { echo "could not generate an event id"; exit 1; }
SENT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PAYLOAD="$(jq -nc --arg id "$EVENT_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S)" \
  --arg env "$ENV_NAME" \
  '{event_id: $id, timestamp: $ts, platform: "other", level: "info", environment: $env, message: "Environment seeded by setup-sentry"}')"
LEN="$(LC_ALL=C printf '%s' "$PAYLOAD" | wc -c | tr -d ' ')"
HEADER="$(jq -nc --arg id "$EVENT_ID" --arg dsn "https://${PUBLIC_KEY}@${INGEST_HOST}/${PROJECT_ID}" --arg sa "$SENT_AT" \
  '{event_id: $id, dsn: $dsn, sent_at: $sa}')"

printf '%s\n{"type":"event","length":%s}\n%s\n' "$HEADER" "$LEN" "$PAYLOAD" \
  | curl -fsS --max-time 10 -X POST "https://${INGEST_HOST}/api/${PROJECT_ID}/envelope/" \
    -H "Content-Type: application/x-sentry-envelope" --data-binary @-
```

`length` must be the exact byte count of the payload line (`LC_ALL=C ... wc -c`, not the shell's `${#var}` character count, which can diverge on multibyte content). `sent_at` includes a trailing `Z`; keep both timestamp fields consistent with your envelope client conventions.

Verify, machine-checkable:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; ENV_NAME="production"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e --arg e "$ENV_NAME" 'any(.[]; .name == $e)'
```

Expect: exit 0. Allow a few seconds for ingestion before the read; retry once before treating a failure as a real gap.

## Project hardening

### Sensitive fields

Starting list for `sensitiveFields`; add domain-specific field names your app actually sends:

```
email, password, secret, token, api_key, authorization, cookie, otp, pin,
phone, mobile, code, database_url, dsn, client_secret, refresh_token,
access_token, session
```

### Payload

The full worked backup-write-verify-restore sequence for this write lives in [../SKILL.md#privacy-gates](../SKILL.md#privacy-gates); this is the payload shape it uses:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/project-${PROJECT}-$(date -u +%H%M%S).json"
mkdir -p "$(dirname "$BACKUP_FILE")"

# The project's securityToken is dropped before saving; the restore reads only the privacy fields.
PROJ_JSON="$(curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}")"
printf '%s\n' "$PROJ_JSON" | jq 'del(.securityToken)' > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

# The response is the whole project, securityToken included, so it is not printed.
curl -fsS --max-time 10 -o /dev/null -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "dataScrubber": true,
    "dataScrubberDefaults": true,
    "scrubIPAddresses": true,
    "scrapeJavaScript": false,
    "sensitiveFields": [
      "email", "password", "secret", "token", "api_key", "authorization",
      "cookie", "otp", "pin", "phone", "mobile", "code", "database_url",
      "dsn", "client_secret", "refresh_token", "access_token", "session"
    ]
  }'

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.dataScrubber == true and .dataScrubberDefaults == true and .scrubIPAddresses == true
           and .scrapeJavaScript == false and (.sensitiveFields | index("dsn")) != null'
```

Expect: exit 0. Undo it with the privacy restore block in [../SKILL.md#privacy-gates](../SKILL.md#privacy-gates), `BACKUP_FILE` set to the printed backup path.

### Client-key rate limits

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
KEY_ID="your-key-id"           # from GET /projects/${SENTRY_ORG}/${PROJECT}/keys/
KEY_RATE_LIMIT="1000"          # example, tune to your expected event volume
KEY_RATE_WINDOW="60"           # seconds; example
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/key-${KEY_ID}-$(date -u +%H%M%S).json"
mkdir -p "$(dirname "$BACKUP_FILE")"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --argjson limit "$KEY_RATE_LIMIT" --argjson window "$KEY_RATE_WINDOW" \
    '{rateLimit: {window: $window, count: $limit}}')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson limit "$KEY_RATE_LIMIT" '.rateLimit.count == $limit'
```

Expect: exit 0. Undo it with the client-key restore block in [../SKILL.md#privacy-gates](../SKILL.md#privacy-gates), `BACKUP_FILE` set to the printed backup path.

## Alert rules

On the alerts API an alert is a workflow (`POST /organizations/{org}/workflows/`): `triggers` decide when it evaluates, `actionFilters[]` gate it and hold its `actions`, and `detectorIds` attach it to the monitors it listens to (an issue alert attaches to its project's issue-stream monitor). The API accepts camelCase or snake_case keys and returns camelCase, so build payloads in the camelCase shape a GET returns. The legacy columns below are the fallback for self-hosted Sentry where the doctor printed `alert api: legacy`.

### Conditions (what triggers the rule)

| Rule | Alerts API `type` (where it goes) | Key fields (`comparison`) | Legacy condition ID |
| --- | --- | --- | --- |
| Event occurs (any level) | no trigger conditions, or `every_event` (`triggers`) | `true` | `sentry.rules.conditions.every_event.EveryEventCondition` |
| New issue created | `first_seen_event` (`triggers`) | `true` | `sentry.rules.conditions.first_seen_event.FirstSeenEventCondition` |
| Resolved to unresolved (regression) | `regression_event` (`triggers`) | `true` | `sentry.rules.conditions.regression_event.RegressionEventCondition` |
| Issue escalates (archived issue comes back) | `reappeared_event` (`triggers`) | `true` | `sentry.rules.conditions.reappeared_event.ReappearedEventCondition` |
| Seen > N times in interval | `event_frequency_count` (`actionFilters[].conditions`) | `{value: <int>, interval}` | `sentry.rules.conditions.event_frequency.EventFrequencyCondition`, `value`, `comparisonType: "count"`, `interval` |
| Affects > N users in interval | `event_unique_user_frequency_count` (same) | `{value: <int>, interval}` | `sentry.rules.conditions.event_frequency.EventUniqueUserFrequencyCondition`, `value`, `interval` |
| Session impact > N% | `percent_sessions_count` (same) | `{value: <number>, interval}` | `sentry.rules.conditions.event_frequency.EventFrequencyPercentCondition`, `value`, `comparisonType: "percent"`, `interval` |
| Sentry marks new issue high priority | closest alerts-API form: a `first_seen_event` trigger plus an `issue_priority_greater_or_equal` filter with `comparison: 75` (`new_high_priority_issue` exists only on migrated rules; the live condition catalog does not offer it for new alerts) | `75` (high; 50 medium, 25 low) | `sentry.rules.conditions.high_priority_issue.NewHighPriorityIssueCondition` |
| Sentry marks existing issue high priority | no alerts-API trigger; `existing_high_priority_issue` exists only on migrated rules, so keep a migrated alert as it is or let rules 3 and 6 cover the case | - | `sentry.rules.conditions.high_priority_issue.ExistingHighPriorityIssueCondition` |

Interval values: `1m`, `5m`, `15m`, `1h`, `1d`, `1w`, `30d` for the count and event-percent conditions, and `1m`, `5m`, `10m`, `30m`, `1h` for the session-percent ones (alerts API, from the live `/organizations/{org}/data-conditions/` schema); `1m`, `5m`, `15m`, `1h`, `1d`, `1w` on the legacy fallback. Escalation is `reappeared_event` (legacy `ReappearedEventCondition`); Sentry has no `EscalatingEventCondition`.

### Filters (narrow which events pass)

| Filter | Alerts API condition (`actionFilters[].conditions`) | Legacy filter |
| --- | --- | --- |
| Level equals | `{type: "level", comparison: {level: 50, match: "eq"}}`: `level` is an integer (50 fatal, 40 error, 30 warning, 20 info, 10 debug), `match` is `eq`, `gte`, or `lte` | `sentry.rules.filters.level.LevelFilter`, `level: "fatal"/"error"/"warning"/"info"`, `match: "eq"/"gte"/"lte"` |
| Error is unhandled | `{type: "event_attribute", comparison: {attribute: "error.unhandled", match: "is"}}` (no `value` with `is`) | `sentry.rules.filters.event_attribute.EventAttributeFilter`, `attribute: "error.unhandled"`, `match: "is"` |
| HTTP status code starts with 5 | `{type: "event_attribute", comparison: {attribute: "http.status_code", match: "sw", value: "5"}}` (`value` is a string) | `EventAttributeFilter`, `attribute: "http.status_code"`, `match: "sw"`, `value: 5` (integer, not string) |
| Issue category | `{type: "issue_category", comparison: {value: <int>, include: true}}` | `sentry.rules.filters.issue_category.IssueCategoryFilter`, `value: "<category name>"` |
| Issue age comparison | `{type: "age_comparison", comparison: {comparisonType: "newer", value: <int>, time: "day"}}` (`time` is `minute`, `hour`, `day`, or `week`) | `sentry.rules.filters.age_comparison.AgeComparisonFilter`, `comparison_type: "newer"/"older"`, `value` (integer), `time` |
| Issue priority at least | `{type: "issue_priority_greater_or_equal", comparison: 75}` | none |

Every condition also carries `conditionResult: true`. **Environment scoping is not a filter.** Sentry rules take environment scope on the rule object itself, as a top-level `environment` field alongside the conditions and actions: not through the `latest_adopted_release` filter (legacy `sentry.rules.filters.latest_adopted_release.LatestAdoptedReleaseFilter`), which filters by release-adoption stage and will silently let dev and staging events through a rule you intended to be production-only.

**`error.unhandled` gotcha:** use `match: "is"` (is set), not `match: "eq"` with a value.

**`http.status_code` starts-with gotcha:** on the alerts API `value` must be a string (`"5"`); only the legacy rules API wanted an integer (`5`).

**Age-gate gotcha:** an "issue newer than N days" age gate (`age_comparison` with `newer`; legacy `AgeComparisonFilter` with `comparison_type: "newer"`) on a rule that also carries a regression trigger (`regression_event`; legacy `RegressionEventCondition`) suppresses exactly the old-issue regressions the rule exists to catch. Never combine the two; slow a regression rule with its frequency alone, per [../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions](../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions).

### Actions (where to send the notification)

**Email (always works, no integration required):**

```json
{
  "type": "email",
  "integrationId": null,
  "config": { "targetType": "issue_owners", "targetIdentifier": null },
  "data": { "fallthroughType": "AllMembers" }
}
```

Never target a single member by raw user ID; it returns "user is not part of the project" unless that user has explicitly joined. Email issue owners with an `AllMembers` fallthrough instead. Legacy fallback: `{"id": "sentry.mail.actions.NotifyEmailAction", "targetType": "IssueOwners", "fallthroughType": "AllMembers"}`.

**Slack (requires the Slack integration connected first):**

```json
{
  "type": "slack",
  "integrationId": "<INTEGRATION_ID>",
  "config": { "targetType": "specific", "targetIdentifier": "<SLACK_CHANNEL_ID>", "targetDisplay": "<SLACK_CHANNEL_NAME>" },
  "data": { "tags": "environment,user,release,os,transaction,level", "notes": "@here" }
}
```

Legacy fallback: `{"id": "sentry.integrations.slack.notify_action.SlackNotifyServiceAction", "workspace": "<INTEGRATION_ID>", "channel": "<SLACK_CHANNEL_NAME>", "channel_id": "<SLACK_CHANNEL_ID>", "tags": "...", "notes": "@here"}`.

Resolve `<INTEGRATION_ID>`:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # The integrations an alert can notify right now, per action type.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/available-actions/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[] | select(.type == "slack") | .integrations[]? | "\(.id)\t\(.name)"'
else
  # Legacy fallback:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/integrations/?provider_key=slack" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[] | "\(.id)\t\(.name)"'
fi
```

**PagerDuty** (service ids from the `pagerduty` entry's `integrations[].services[]` in the same `available-actions` read):

```json
{
  "type": "pagerduty",
  "integrationId": "<INTEGRATION_ID>",
  "config": { "targetType": "specific", "targetIdentifier": "<SERVICE_ID>", "targetDisplay": "<SERVICE_NAME>" },
  "data": { "priority": "critical" }
}
```

Legacy fallback: `{"id": "sentry.integrations.pagerduty.notify_action.PagerDutyNotifyServiceAction", "account": "<INTEGRATION_ID>", "service": "<SERVICE_ID>", "severity": "critical"}`.

### Full rule payload example

```json
{
  "name": "Fatal crash, immediate",
  "enabled": true,
  "environment": "production",
  "owner": "team:<TEAM_ID>",
  "config": { "frequency": 5 },
  "detectorIds": ["<ISSUE_STREAM_MONITOR_ID>"],
  "triggers": { "logicType": "any-short", "conditions": [] },
  "actionFilters": [
    {
      "logicType": "all",
      "conditions": [
        { "type": "level", "comparison": { "level": 50, "match": "eq" }, "conditionResult": true }
      ],
      "actions": [
        { "type": "email", "integrationId": null,
          "config": { "targetType": "issue_owners", "targetIdentifier": null },
          "data": { "fallthroughType": "AllMembers" } }
      ]
    }
  ]
}
```

`config.frequency` is the re-notify interval in minutes. `owner` takes `team:<id>` (the numeric team id from `GET /organizations/{org}/teams/`); audit-sentry's SNTRY-110 flags a rule without one. `detectorIds` holds the project's issue-stream monitor id (`GET /organizations/{org}/detectors/?project=<project>&type=issue_stream`); `triggers.logicType` must be `any-short` on create. The legacy fallback payload is `{name, actionMatch: "any", filterMatch: "all", environment, frequency, owner, conditions: [{"id": "sentry.rules.conditions.every_event.EveryEventCondition"}], filters: [{"id": "sentry.rules.filters.level.LevelFilter", "level": "fatal", "match": "eq"}], actions: [<legacy email action>]}` on `POST /projects/{org}/{project}/rules/`. Create a rule with the create block in [../SKILL.md#alert-rule-taxonomy](../SKILL.md#alert-rule-taxonomy): it builds this payload with `jq -n` from declared variables, so no payload file is needed, and verifies the re-fetched alert against it. Rollback is the rule rollback block in the same section, `RULE_ID` set to the printed id.

### Starting rule set (map to your own severity scheme and event volume)

| # | Name | Trigger (alerts API) | Filter (alerts API) | Legacy condition / filter | Tier | Frequency |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Fatal crash | none (every event) | `level` `{level: 50, match: "eq"}` | Any event / Level = fatal | Immediate | `IMMEDIATE_FREQ_MIN="5"` |
| 2 | Unhandled error, new | `first_seen_event` | `event_attribute` `{attribute: "error.unhandled", match: "is"}` | New issue / `error.unhandled` is set | Immediate | 30 min |
| 3 | High priority, new | `first_seen_event` | `issue_priority_greater_or_equal` `75` | Sentry marks new issue high priority | Immediate | 30 min |
| 4 | High priority, existing | none on the alerts API (see the conditions table) | - | Sentry marks existing issue high priority | Immediate | 60 min |
| 5 | Regression | `regression_event` | - | Regression event | Immediate | 30 min |
| 6 | Escalation | `reappeared_event` | - | Escalation (`ReappearedEventCondition`) | Immediate | 30 min |
| 7 | User impact | none | `event_unique_user_frequency_count` `{value: USER_IMPACT_THRESHOLD, interval: "1h"}` (`USER_IMPACT_THRESHOLD="5"`) | `USER_IMPACT_THRESHOLD` users in 1h | Immediate | 60 min |
| 8 | Session impact | none | `percent_sessions_count` `{value: SESSION_IMPACT_PCT, interval: "1h"}` (`SESSION_IMPACT_PCT="1"`) | `SESSION_IMPACT_PCT`% sessions in 1h | Immediate | 60 min |
| 9 | Production error surge | none | `event_frequency_count` `{value: ERROR_SURGE_THRESHOLD, interval: "1h"}` (`ERROR_SURGE_THRESHOLD="25"`), environment=production | `ERROR_SURGE_THRESHOLD` events in 1h | Immediate | 60 min |
| 10 | Frequency spike | none | `event_frequency_count` `{value: FREQ_SPIKE_THRESHOLD, interval: "1h"}` (`FREQ_SPIKE_THRESHOLD="10"`) | `FREQ_SPIKE_THRESHOLD` events in 1h | Review | `FREQ_FLOOR_MIN="30"` min minimum |

Each threshold is an example, tune it to your event volume. Add per-runtime rules only for conditions your platform actually emits (for example, an HTTP 5xx spike rule using the `http.status_code` starts-with filter on a backend project). Do not create a rule for a condition your stack cannot produce.

How this set scores on a fresh audit-sentry run: the create block sets the rule-level `environment` and an `owner` on every rule, so none fails SNTRY-102 or SNTRY-110. Rules 3 and 5 to 10 carry no gating filter (the frequency thresholds of rules 7 to 10 are triggers in effect, and rule 9's production scope is the rule-level `environment`, not a filter), so audit-sentry reports each as SNTRY-101, a notifying rule with no filter, until you add a gating filter your volume justifies, such as a `level` filter (never an issue-age filter on rule 5, the regression rule). If the condition alone is the gate you want, record SNTRY-101 for those rules as an accepted decision. Every rule's issue-owners email action also fails SNTRY-017 on a project with no ownership rules ([../SKILL.md#receiver-wiring](../SKILL.md#receiver-wiring)).

### Slack action retrofit

The full backup, PUT, verify, and restore sequence for adding a Slack action to an existing rule is the Slack block in [../SKILL.md#receiver-wiring](../SKILL.md#receiver-wiring); run it from there. Two rules it depends on, both from the alerts API's write semantics: an alert `PUT` replaces the whole alert (actions, filters, and conditions missing from the body by `id` are deleted, and items without an `id` are created), and an omitted `enabled` turns a disabled alert back on, so the body is always the full backed-up alert with the new action appended to one explicit `actionFilters[]` entry.

## Rule-set backup and restore

The mandatory pre-mutation snapshot for a bulk alert-rule cleanup, driven from [../SKILL.md#back-up-the-whole-rule-set-before-the-first-mutation](../SKILL.md#back-up-the-whole-rule-set-before-the-first-mutation), in a dated home-anchored directory. On the alerts API that is one file of every alert and one of every metric monitor, org-wide; on the legacy fallback, one file per project of its issue-alert rules plus one for the org's metric-alert rules.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
export SENTRY_TOKEN   # fetch-all.sh reads the token from its environment
# Every list below is paginated; fetch-all.sh follows the Link cursor so no page is silently left out.
FETCH_ALL="${CLAUDE_PLUGIN_ROOT}/skills/setup-sentry/scripts/fetch-all.sh"

# One dated dir for the whole rule-set snapshot, home-anchored like the config store.
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # Every alert, org-wide (each per-project view is these alerts filtered by detectorIds).
  sh "$FETCH_ALL" "${API}/organizations/${SENTRY_ORG}/workflows/" > "${BACKUP_DIR}/workflows.json"
  test -s "${BACKUP_DIR}/workflows.json" && echo "backed up alerts: $(jq 'length' "${BACKUP_DIR}/workflows.json")"
  # Every metric monitor (thresholds live here). Uptime monitors stay out: they carry request headers.
  sh "$FETCH_ALL" "${API}/organizations/${SENTRY_ORG}/detectors/?type=metric_issue" > "${BACKUP_DIR}/detectors.json"
  test -s "${BACKUP_DIR}/detectors.json" && echo "backed up metric monitors: $(jq 'length' "${BACKUP_DIR}/detectors.json")"
else
  # Legacy fallback (self-hosted Sentry that still serves the legacy routes).
  # The project list the loop walks, saved with the snapshot.
  sh "$FETCH_ALL" "${API}/organizations/${SENTRY_ORG}/projects/" > "${BACKUP_DIR}/projects.json"
  # One file per project of its issue-alert rules.
  for PROJECT in $(jq -r '.[].slug' "${BACKUP_DIR}/projects.json"); do
    sh "$FETCH_ALL" "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" > "${BACKUP_DIR}/issue-rules-${PROJECT}.json"
    test -s "${BACKUP_DIR}/issue-rules-${PROJECT}.json" && echo "backed up issue rules: ${PROJECT}"
  done
  # One file for the org's metric-alert rules.
  sh "$FETCH_ALL" "${API}/organizations/${SENTRY_ORG}/alert-rules/" > "${BACKUP_DIR}/metric-alert-rules.json"
  test -s "${BACKUP_DIR}/metric-alert-rules.json" && echo "backed up metric-alert rules"
fi
echo "rule-set backup: ${BACKUP_DIR}"
```

Expect: on the alerts API, `workflows.json` and `detectors.json`, each non-empty and each holding every page of its list; on the legacy fallback, `projects.json`, one `issue-rules-<project>.json` per project in it, and one `metric-alert-rules.json`. A failed page stops the block with an error instead of finishing on a silently incomplete snapshot. Restore a single rule from the snapshot with one of the two blocks below, never both: the first puts back a rule you updated, the second re-creates one you deleted. Running both on an updated rule would restore it and then add a duplicate.

Restore an **updated** rule, in its own fresh shell:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="<project-slug>"; RULE_ID="<rule-id>"   # the alert (legacy: rule) you updated, and its project
BACKUP_DATE="YYYY-MM-DD"                        # UTC date of the rule-set backup
for v in "$PROJECT" "$RULE_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  BACKUP_FILE="$HOME/.scoutflo/sentry-rules-backup-${BACKUP_DATE}/workflows.json"
  [ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the rule-set backup" >&2; exit 1; }
  jq -e --arg id "$RULE_ID" 'any(.[]; .id == $id)' "$BACKUP_FILE" > /dev/null || { echo "Alert ${RULE_ID} is not in ${BACKUP_FILE}" >&2; exit 1; }
  # The whole backed-up alert: every id and the backed-up enabled state. A null triggers is dropped
  # (the endpoint rejects it); a null environment or owner is sent, so the restore clears it.
  jq --arg id "$RULE_ID" '.[] | select(.id == $id)
      | {name, enabled, environment, owner, config, detectorIds, triggers, actionFilters}
      | with_entries(select(.value != null or .key == "environment" or .key == "owner"))' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- > /dev/null
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg id "$RULE_ID" '
        def norm: {enabled, environment, owner, config, detectorIds: ((.detectorIds // []) | map(tostring) | sort),
          triggers: (.triggers | if . then {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}]} else null end),
          actionFilters: [(.actionFilters // [])[] | {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}],
                                                     actions: [.actions[] | {type, integrationId, config, data}]}]};
        ($b[0][] | select(.id == $id)) as $o | norm == ($o | norm)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  BACKUP_FILE="$HOME/.scoutflo/sentry-rules-backup-${BACKUP_DATE}/issue-rules-${PROJECT}.json"
  [ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the rule-set backup" >&2; exit 1; }
  jq -e --arg id "$RULE_ID" 'any(.[]; .id == $id)' "$BACKUP_FILE" > /dev/null || { echo "Rule ${RULE_ID} is not in ${BACKUP_FILE}" >&2; exit 1; }
  jq --arg id "$RULE_ID" '.[] | select(.id == $id) | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg id "$RULE_ID" '($b[0][] | select(.id == $id)) as $o
        | [., $o] | map({actionMatch, filterMatch, environment, frequency, conditions, filters, actions}) | .[0] == .[1]'
fi
```

Expect: `true`. Re-create a **deleted** rule, in its own fresh shell (the POST assigns a fresh id and sets `createdBy` to the setup identity, per [../SKILL.md#delete-the-auto-created-default-rule](../SKILL.md#delete-the-auto-created-default-rule)):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="<project-slug>"; RULE_ID="<rule-id>"   # the id the deleted alert (legacy: rule) had in the backup, and its project
BACKUP_DATE="YYYY-MM-DD"                        # UTC date of the rule-set backup
for v in "$PROJECT" "$RULE_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  BACKUP_FILE="$HOME/.scoutflo/sentry-rules-backup-${BACKUP_DATE}/workflows.json"
  [ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the rule-set backup" >&2; exit 1; }
  jq -e --arg id "$RULE_ID" 'any(.[]; .id == $id)' "$BACKUP_FILE" > /dev/null || { echo "Alert ${RULE_ID} is not in ${BACKUP_FILE}" >&2; exit 1; }
  # Drop server-set fields and every nested id; keep the rest, enabled included.
  NEW_ID="$(jq --arg id "$RULE_ID" '.[] | select(.id == $id)
      | del(.id, .organizationId, .dateCreated, .dateUpdated, .lastTriggered, .createdBy)
      | if .triggers then .triggers |= (del(.id, .organizationId) | .conditions |= map(del(.id))) else . end
      | .actionFilters |= map(del(.id, .organizationId) | .conditions |= map(del(.id)) | .actions |= map(del(.id)))
      | with_entries(select(.value != null))' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/workflows/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- | jq -r '.id // empty')"
  [ -n "$NEW_ID" ] || { echo "re-create returned no alert id" >&2; exit 1; }
  echo "restored as alert: ${NEW_ID}"
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${NEW_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg id "$RULE_ID" '($b[0][] | select(.id == $id)) as $o
        | .name == $o.name and .enabled == $o.enabled
          and ([(.actionFilters // [])[].actions[]] | length) == ([($o.actionFilters // [])[].actions[]] | length)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  BACKUP_FILE="$HOME/.scoutflo/sentry-rules-backup-${BACKUP_DATE}/issue-rules-${PROJECT}.json"
  [ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the rule-set backup" >&2; exit 1; }
  jq -e --arg id "$RULE_ID" 'any(.[]; .id == $id)' "$BACKUP_FILE" > /dev/null || { echo "Rule ${RULE_ID} is not in ${BACKUP_FILE}" >&2; exit 1; }
  NEW_ID="$(jq --arg id "$RULE_ID" '.[] | select(.id == $id) | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- | jq -r '.id')"
  echo "restored as rule: ${NEW_ID}"
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${NEW_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg id "$RULE_ID" '($b[0][] | select(.id == $id)) as $o
        | .name == $o.name and (.actions | length) == ($o.actions | length)'
fi
```

Expect: the new rule id, then `true`. A restore is itself a change: announce, confirm, and record it like any other.

## Bulk verify: PUT and DELETE

The per-rule verify shapes for a bulk cleanup, driven from [../SKILL.md#get-verify-after-every-put-and-every-delete](../SKILL.md#get-verify-after-every-put-and-every-delete). Report one verify line per rule, never a batch total.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="checkout"; RULE_ID="12345678"
EXPECT_FREQ="1440"     # example; the re-notify minutes you PUT
EXPECT_ENABLED="true"  # the alert's enabled value in its backup; a PUT must never flip it

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # After a PUT: re-fetch and assert the changed field and the untouched enabled state.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --argjson f "$EXPECT_FREQ" --argjson e "$EXPECT_ENABLED" '.config.frequency == $f and .enabled == $e' \
    && echo "rule ${RULE_ID}: verified"
  # After a DELETE (204): gone only when the real route answers its JSON "does not exist" 404.
  gone="$(mktemp)"; trap 'rm -f "$gone"' EXIT
  code="$(curl -sS --max-time 10 -o "$gone" -w '%{http_code}' \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/")"
  if [ "$code" = 404 ] && jq -e '.detail == "The requested resource does not exist"' "$gone" > /dev/null 2>&1; then
    echo "rule ${RULE_ID}: gone (404)"
  else
    echo "rule ${RULE_ID} post-delete: ${code}, not proven gone"; exit 1
  fi
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  # After a PUT: re-fetch and assert the changed field (example: frequency now 1440).
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --argjson f "$EXPECT_FREQ" '.frequency == $f' \
    && echo "rule ${RULE_ID}: verified"
  # After a DELETE (which returns 202 Accepted, not 200): confirm the rule is gone.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/")"
  echo "rule ${RULE_ID} post-delete: ${code}"
fi
```

Expect: the PUT verify prints `rule <id>: verified`, and the delete check prints `rule <id>: gone (404)`. On the legacy fallback the post-delete code is `404` (a 202 on the DELETE call means only that the delete was queued, so the follow-up GET is what proves removal). On the alerts API a bare `404` without the JSON body prints `not proven gone`: that is what a removed or mistyped route returns for every id.

## Slow a noisy issue-alert rule

Env-scope, age-gate, and slow re-notify for a burst or spike rule, driven from [../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions](../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions). Do not apply the age gate to a regression rule (`regression_event`; legacy `RegressionEventCondition`). Both APIs replace the whole object on write, so this backs up, patches, and PUTs the full body back; on the alerts API that body keeps every id and the backed-up `enabled`.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"     # the doctor gate's "alert api:" value
PROJECT="checkout"; RULE_ID="12345678"
FILTER_INDEX="0"                 # alerts API: which actionFilters[] entry gets the age gate
TARGET_ENV="production"          # from the rule's receiver channel, not its name
RULE_AGE_GATE_DAYS="7"           # example, tune to your volume; NEVER apply to a regression rule
SLOW_RENOTIFY_MIN="1440"         # example, 24h re-notify; the fast tier stays at 15 minutes
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/issue-rule-${PROJECT}-${RULE_ID}.json"

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # 1. Backup (GET-before-write):
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"
  # Refuse a regression alert: an age gate would hide exactly the old issues it exists to catch.
  jq -e 'any((.triggers.conditions // [])[]; .type == "regression_event") | not' "$BACKUP_FILE" > /dev/null \
    || { echo "alert ${RULE_ID} has a regression trigger; slow it with frequency alone, no age gate" >&2; exit 1; }

  # 2. Env-scope + age-gate + slow re-notify, full-alert PUT (every id and enabled kept):
  UPDATED="$(jq --argjson i "$FILTER_INDEX" --arg env "$TARGET_ENV" --argjson days "$RULE_AGE_GATE_DAYS" --argjson freq "$SLOW_RENOTIFY_MIN" '
      if ((.actionFilters // []) | length) <= $i then error("this alert has no actionFilters[\($i)]") else . end
      | .environment = $env
      | .config.frequency = $freq
      | .actionFilters[$i].conditions += [{type: "age_comparison",
          comparison: {comparisonType: "newer", time: "day", value: $days}, conditionResult: true}]
      | {name, enabled, environment, owner, config, detectorIds, triggers, actionFilters}
      | with_entries(select(.value != null or .key == "environment" or .key == "owner"))' "$BACKUP_FILE")"
  curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$UPDATED" > /dev/null

  # 3. Verify env scope, frequency, the age gate, and the untouched enabled state:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg env "$TARGET_ENV" --argjson freq "$SLOW_RENOTIFY_MIN" \
        '.environment == $env and .config.frequency == $freq and .enabled == $b[0].enabled
         and any((.actionFilters // [])[].conditions[]; .type == "age_comparison")'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  # 1. Backup (GET-before-write):
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

  # 2. Env-scope + age-gate + slow re-notify, full-object PUT:
  UPDATED="$(jq --arg env "$TARGET_ENV" --argjson days "$RULE_AGE_GATE_DAYS" --argjson freq "$SLOW_RENOTIFY_MIN" \
    '.environment = $env
     | .frequency = $freq
     | .filters = ((.filters // []) + [{
         id: "sentry.rules.filters.age_comparison.AgeComparisonFilter",
         comparison_type: "newer", time: "day", value: $days
       }])
     | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE")"

  curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$UPDATED"

  # 3. Verify env scope, frequency, and the age gate all landed:
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --arg env "$TARGET_ENV" --argjson freq "$SLOW_RENOTIFY_MIN" \
        '.environment == $env and .frequency == $freq
         and (.filters | any(.id == "sentry.rules.filters.age_comparison.AgeComparisonFilter"))'
fi
```

Expect: exit 0. Undo it with the single-rule restore block in [../SKILL.md#receiver-wiring](../SKILL.md#receiver-wiring), `BACKUP_FILE` set to the printed backup path.

## Silence a metric-alert warning tier

On the alerts API, remove the warning condition (`conditionResult` 50) from the metric monitor and keep the critical and resolve conditions; on the legacy fallback, remove the warning trigger from the metric alert (keep the critical trigger). Driven from [../SKILL.md#quiet-a-metric-alerts-warning-tier](../SKILL.md#quiet-a-metric-alerts-warning-tier). A monitor `PUT` is partial, but `conditionGroup.conditions` is replaced by `id`: every condition you keep goes in with its `id`, and the one you leave out is deleted.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"           # the doctor gate's "alert api:" value
ALERT_RULE_ID="your-metric-alert-id"   # alerts API: the metric monitor id from GET /organizations/${SENTRY_ORG}/detectors/?type=metric_issue (legacy: the alert-rules id)
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/metric-alert-${ALERT_RULE_ID}.json"

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # 1. Backup this metric monitor's full body, and confirm it is one:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"
  jq -e '.type == "metric_issue" and any(.conditionGroup.conditions[]; .conditionResult == 50)' "$BACKUP_FILE" > /dev/null \
    || { echo "monitor ${ALERT_RULE_ID} is not a metric monitor with a warning condition; nothing to remove" >&2; exit 1; }

  # 2. Keep every condition except the warning one (each kept one with its id); the resolve stays.
  jq '{conditionGroup: {id: .conditionGroup.id, logicType: .conditionGroup.logicType,
        conditions: [.conditionGroup.conditions[] | select(.conditionResult != 50) | {id, type, comparison, conditionResult}]}}' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/detectors/${ALERT_RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- > /dev/null

  # 3. Verify: no warning condition left, exactly one resolve condition, critical untouched.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '([.conditionGroup.conditions[] | select(.conditionResult == 50)] | length) == 0
        and ([.conditionGroup.conditions[] | select(.conditionResult == 0)] | length) == 1
        and ([.conditionGroup.conditions[] | select(.conditionResult == 75) | {type, comparison}])
            == ([$b[0].conditionGroup.conditions[] | select(.conditionResult == 75) | {type, comparison}])'
else
  # Legacy fallback (self-hosted Sentry that still serves /alert-rules/).
  # 1. Backup this metric alert's full body:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

  # 2. Remove the WARNING trigger entirely (keep critical). Stripping its action
  #    instead is rejected: "Each trigger must have an associated action for this
  #    alert to fire." Record the removed trigger so it can be restored.
  jq '.triggers |= map(select(.label != "warning"))' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

  # 3. Verify the warning trigger is gone:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e '[.triggers[] | select(.label == "warning")] | length == 0'
fi
```

Expect: exit 0. Restore the removed tier from the backup:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"        # the doctor gate's "alert api:" value
ALERT_RULE_ID="<metric-alert-id>"   # the metric monitor (legacy: metric alert) the write changed
BACKUP_FILE="<backup-path>"         # the "backup:" path step 1 printed
for v in "$ALERT_RULE_ID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # Every backed-up condition goes back; the removed warning one no longer exists, so it goes
  # in without its id and Sentry creates it fresh.
  jq '{conditionGroup: {id: .conditionGroup.id, logicType: .conditionGroup.logicType,
        conditions: [.conditionGroup.conditions[]
          | if .conditionResult == 50 then {type, comparison, conditionResult} else {id, type, comparison, conditionResult} end]}}' \
      "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/detectors/${ALERT_RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- > /dev/null
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '([.conditionGroup.conditions[] | {type, comparison, conditionResult}] | sort_by(.conditionResult))
        == ([$b[0].conditionGroup.conditions[] | {type, comparison, conditionResult}] | sort_by(.conditionResult))'
else
  # Legacy fallback: merge the backed-up triggers back onto the current body.
  CURRENT="$(curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}")"
  printf '%s' "$CURRENT" | jq --slurpfile b "$BACKUP_FILE" '.triggers = $b[0].triggers' \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '.triggers == $b[0].triggers'
fi
```

Expect: exit 0, the thresholds equal to the backup (alerts API: the same `type`, `comparison`, and `conditionResult` set, with a new id on the restored warning condition; legacy: the triggers byte-equal to the backup). A restore is itself a change; announce and record it like any other.

## Code mappings

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/repos/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[] | "\(.id)\t\(.name)"'

PROJECT_ID="your-project-id"; REPO_ID="your-repo-id"; DEPLOYED_BRANCH="main"
NEW_MAPPING="$(curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/code-mappings/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROJECT_ID" --arg r "$REPO_ID" --arg b "$DEPLOYED_BRANCH" \
    '{projectId: $p, repoId: $r, defaultBranch: $b, stackRoot: "", sourceRoot: ""}')")"
MAPPING_ID="$(printf '%s' "$NEW_MAPPING" | jq -r '.id')"
echo "created mapping: ${MAPPING_ID}"

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e --arg b "$DEPLOYED_BRANCH" '.defaultBranch == $b'
```

Expect: exit 0. Set `defaultBranch` to the branch that is actually deployed. If your deploy branch differs from the repository's configured default branch, use the deploy branch; a code mapping pointed at the wrong branch resolves the wrong file version. Rollback is the code-mapping rollback block in [../SKILL.md#github-integration-and-code-mappings](../SKILL.md#github-integration-and-code-mappings), `MAPPING_ID` set to the printed id.

## Monitors

### Cron check-in URLs (DSN-based, no auth token needed)

```
GET https://<ingest-host>/api/<project_id>/cron/<monitor_slug>/<public_key>/?status=in_progress
GET https://<ingest-host>/api/<project_id>/cron/<monitor_slug>/<public_key>/?status=ok
GET https://<ingest-host>/api/<project_id>/cron/<monitor_slug>/<public_key>/?status=error
```

Rate limit: 6 check-ins per minute per monitor and environment. Enable the monitor (`PUT .../monitors/<slug>/` with `"status": "active"`) only after you have observed all three statuses from the real job.

### Uptime monitor

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
CHECK_NAME="API health check"
CHECK_URL="https://api.example.com/health"   # the exact endpoint this check will watch
UPTIME_INTERVAL_S="300"     # example; Sentry accepts only 300, 600, 1800, or 3600
UPTIME_TIMEOUT_MS="5000"    # example, tune to the endpoint's normal response time
UPTIME_DOWN_AFTER="3"       # example: consecutive failed checks before Sentry opens an issue
UPTIME_RECOVER_AFTER="1"    # example: consecutive good checks before it resolves

NEW_CHECK="$(curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "$CHECK_NAME" --arg u "$CHECK_URL" --argjson interval "$UPTIME_INTERVAL_S" \
        --argjson timeout "$UPTIME_TIMEOUT_MS" --argjson down "$UPTIME_DOWN_AFTER" --argjson up "$UPTIME_RECOVER_AFTER" '{
    name: $n, url: $u, intervalSeconds: $interval, timeoutMs: $timeout, method: "GET",
    downtimeThreshold: $down, recoveryThreshold: $up, traceSampling: false, responseCaptureEnabled: true
  }')")"
CHECK_ID="$(printf '%s' "$NEW_CHECK" | jq -r '.id')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/${CHECK_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e --arg u "$CHECK_URL" '.url == $u'
```

Expect: exit 0. `intervalSeconds` accepts only `300`, `600`, `1800`, or `3600`; any other value is rejected. On the alerts API the uptime check is a monitor (`uptime_domain_failure` detector): it notifies only through an alert connected to it, or through a project issue alert that happens to match its issues, so audit-sentry's SNTRY-015 flags it until one is connected. Connect it to an alert in Sentry's Monitors and Alerts UI and record that as a pending item; this skill has no verified wiring write.

Rollback, in its own fresh shell:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
CHECK_ID="<uptime-check-id>"   # the CHECK_ID the create block captured
case "$CHECK_ID" in ''|'<'*) echo "Set CHECK_ID to the uptime monitor this setup created" >&2; exit 1 ;; esac
curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/${CHECK_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > /dev/null
curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/${CHECK_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
```

Expect: `404`.

## Pagination and rate limits

Sentry paginates list endpoints with a `Link` response header cursor. Follow it rather than trusting a single page as a total. Following the cursor needs a function called in a loop, which is shared state across iterations, so per the stateless-block rule it lives in [`../scripts/fetch-all.sh`](../scripts/fetch-all.sh) instead of a pasted block. Call it from its own stateless block:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
export SENTRY_TOKEN   # fetch-all.sh reads the token from its environment

sh "${CLAUDE_PLUGIN_ROOT}/skills/setup-sentry/scripts/fetch-all.sh" "${API}/organizations/${SENTRY_ORG}/projects/"
```

Back off and retry on `429`; read the `Retry-After` header rather than a fixed sleep.

## Region and token-scope reference

| Your org | `sentry.host` value |
| --- | --- |
| SaaS, US region | `us.sentry.io` |
| SaaS, EU region | `de.sentry.io` |
| Self-hosted | your instance host |

| Scope | Needed for |
| --- | --- |
| `project:write` | Create and update projects, keys, environments |
| `project:admin` | Delete projects (the project rollback in [../SKILL.md#projects](../SKILL.md#projects)) |
| `alerts:write` | Create, update, and delete alerts (workflows) and the metric and uptime monitors you created (per Sentry's source); on the legacy fallback, issue alert and metric rules (rule deletes confirmed live with `alerts:write` alone) |
| `org:read` | List teams, integrations, members, repos, and the live action targets (`available-actions`) |
| `org:write` | Create code mappings; edit Sentry's built-in `error` monitors and any org-wide (all projects) alert. No scope edits an `issue_stream` monitor |

## Gotchas

| Problem | Root cause | Fix |
| --- | --- | --- |
| "User not part of project" on email action | `targetType: "Member"` with a raw user ID | Use `targetType: "IssueOwners"` with `fallthroughType: "AllMembers"` |
| Envelope rejected: "missing newline after header" or length mismatch | Hardcoded or character-counted `length` | Compute the exact byte length with `LC_ALL=C ... wc -c`, never `${#var}` on non-ASCII payloads |
| `error.unhandled` filter never matches | Using `match: "eq"` with a value | Use `match: "is"` (is set) |
| `http.status_code` filter rejected | The value type the API expects | Alerts API: `value: "5"` (string); legacy fallback: `value: 5` (integer) |
| Environment-scoped rule fires on every environment | Used `LatestAdoptedReleaseFilter` instead of the rule-level `environment` field | Set `environment` on the rule object; that filter is about release-adoption stage, not environment |
| Uptime monitor creation fails | Invalid `intervalSeconds` | Only 300, 600, 1800, 3600 are valid |
| Default rule noise after project creation | `defaultRules` not set to `false` | Delete the auto-created alert by id, never through a project-wide bulk call (see SKILL.md) |
| Slack PUT silently drops the email action | Payload only included the new action; an alert PUT deletes every action, filter, and condition missing by `id` | Fetch the alert, append to the chosen `actionFilters[]` entry's `actions`, PUT the full object back with every id |
| A PUT re-enables a disabled alert | `enabled` defaults to `true` when omitted | Build every PUT body from the backup so it carries `enabled`, and assert it after the write |
| Legacy `rules/` or `alert-rules/` returns 404 | Sentry SaaS removed the legacy alert routes in 2026-09; they answer a route-missing 404 with an empty body | Use the alerts API (`/workflows/`, `/detectors/`), which the doctor gate detects; never read that 404 as "no rules" or "deleted" |
| `commitCount: 0` on a release with `deployCount > 0` | Deploy created a release, but no CI step linked commits | Document as a CI follow-up before claiming suspect commits work |
