# setup-sentry API cookbook

Full request and response shapes for the workflow in [../SKILL.md](../SKILL.md). Every block below is stateless: it redeclares `API`, `SENTRY_ORG`, `SENTRY_TOKEN` (presence check), and any object-specific placeholder at its own top, resolved the same way the doctor gate resolves them. Each block runs correctly pasted into a brand-new shell; none depends on a variable set in an earlier block.

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

EVENT_ID="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"
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

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
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

Expect: exit 0. Restore by piping `jq '{dataScrubber, dataScrubberDefaults, scrubIPAddresses, scrapeJavaScript, sensitiveFields}' "$BACKUP_FILE"` into the same `PUT`.

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

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --argjson limit "$KEY_RATE_LIMIT" --argjson window "$KEY_RATE_WINDOW" \
    '{rateLimit: {window: $window, count: $limit}}')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson limit "$KEY_RATE_LIMIT" '.rateLimit.count == $limit'
```

Expect: exit 0. Restore by piping `jq '{rateLimit}' "$BACKUP_FILE"` into the same `PUT`, verified with `jq -e --slurpfile b "$BACKUP_FILE" '.rateLimit == $b[0].rateLimit'` against the re-fetched key.

## Alert rules

### Conditions (`conditions` array: what triggers the rule)

| Rule | Condition ID | Key fields |
| --- | --- | --- |
| Event occurs (any level) | `sentry.rules.conditions.every_event.EveryEventCondition` | - |
| New issue created | `sentry.rules.conditions.first_seen_event.FirstSeenEventCondition` | - |
| Resolved to unresolved (regression) | `sentry.rules.conditions.regression_event.RegressionEventCondition` | - |
| Issue escalates | `sentry.rules.conditions.escalating_event.EscalatingEventCondition` | - |
| Seen > N times in interval | `sentry.rules.conditions.event_frequency.EventFrequencyCondition` | `value`, `comparisonType: "count"`, `interval` |
| Affects > N users in interval | `sentry.rules.conditions.event_frequency.EventUniqueUserFrequencyCondition` | `value`, `interval` |
| Session impact > N% | `sentry.rules.conditions.event_frequency.EventFrequencyPercentCondition` | `value`, `comparisonType: "percent"`, `interval` |
| Sentry marks new issue high priority | `sentry.rules.conditions.high_priority_issue.NewHighPriorityIssueCondition` | - |
| Sentry marks existing issue high priority | `sentry.rules.conditions.high_priority_issue.ExistingHighPriorityIssueCondition` | - |

Interval values: `1m`, `5m`, `15m`, `1h`, `1d`, `1w`.

### Filters (`filters` array: narrow which events pass)

| Filter | ID | Key fields |
| --- | --- | --- |
| Level equals | `sentry.rules.filters.level.LevelFilter` | `level: "fatal"/"error"/"warning"/"info"`, `match: "eq"/"gte"/"lte"` |
| Error is unhandled | `sentry.rules.filters.event_attribute.EventAttributeFilter` | `attribute: "error.unhandled"`, `match: "is"` |
| HTTP status code starts with 5 | `sentry.rules.filters.event_attribute.EventAttributeFilter` | `attribute: "http.status_code"`, `match: "sw"`, `value: 5` (integer, not string) |
| Issue category | `sentry.rules.filters.issue_category.IssueCategoryFilter` | `value: "<category name>"` |
| Issue age comparison | `sentry.rules.filters.age_comparison.AgeComparisonFilter` | `comparison_type: "newer"/"older"`, `value` (integer), `time: "minute"/"hour"/"day"/"week"` |

**Environment scoping is not a filter.** Sentry rules take environment scope on the rule object itself, as a top-level `environment` field alongside `conditions`/`filters`/`actions`: not through `sentry.rules.filters.latest_adopted_release.LatestAdoptedReleaseFilter`, which filters by release-adoption stage and will silently let dev and staging events through a rule you intended to be production-only.

**`error.unhandled` gotcha:** use `match: "is"` (is set), not `match: "eq"` with a value.

**`http.status_code` starts-with gotcha:** `value` must be an integer (`5`), not a string (`"5"`).

**Age-gate gotcha:** an "issue newer than N days" `AgeComparisonFilter` (`comparison_type: "newer"`) on a rule that also carries `RegressionEventCondition` suppresses exactly the old-issue regressions the rule exists to catch. Never combine the two; slow a regression rule with `frequency` alone, per [../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions](../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions).

### Actions (`actions` array: where to send the notification)

**Email (always works, no integration required):**

```json
{
  "id": "sentry.mail.actions.NotifyEmailAction",
  "targetType": "IssueOwners",
  "fallthroughType": "AllMembers"
}
```

Never use `targetType: "Member"` with `targetIdentifier`; it returns "user is not part of the project" unless that user has explicitly joined. Use `IssueOwners` with `AllMembers` fallthrough instead.

**Slack (requires the Slack integration connected first):**

```json
{
  "id": "sentry.integrations.slack.notify_action.SlackNotifyServiceAction",
  "workspace": "<INTEGRATION_ID>",
  "channel": "<SLACK_CHANNEL_NAME>",
  "channel_id": "<SLACK_CHANNEL_ID>",
  "tags": "environment,user,release,os,transaction,level",
  "notes": "@here"
}
```

Resolve `<INTEGRATION_ID>`:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/integrations/?provider_key=slack" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[] | "\(.id)\t\(.name)"'
```

**PagerDuty:**

```json
{
  "id": "sentry.integrations.pagerduty.notify_action.PagerDutyNotifyServiceAction",
  "account": "<INTEGRATION_ID>",
  "service": "<SERVICE_ID>",
  "severity": "critical"
}
```

### Full rule payload example

```json
{
  "name": "Fatal crash, immediate",
  "actionMatch": "any",
  "filterMatch": "all",
  "environment": "production",
  "frequency": 5,
  "conditions": [
    { "id": "sentry.rules.conditions.every_event.EveryEventCondition" }
  ],
  "filters": [
    { "id": "sentry.rules.filters.level.LevelFilter", "level": "fatal", "match": "eq" }
  ],
  "actions": [
    { "id": "sentry.mail.actions.NotifyEmailAction", "targetType": "IssueOwners", "fallthroughType": "AllMembers" }
  ]
}
```

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"

NEW_RULE="$(curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d @rule-payload.json)"
RULE_ID="$(printf '%s' "$NEW_RULE" | jq -r '.id')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.conditions != null and .actions != null and (.actions | length) >= 1'
```

Expect: exit 0. Rollback: `curl -X DELETE` the same URL, then `jq -e` that the id no longer appears in the rules list, per [../SKILL.md#alert-rule-taxonomy](../SKILL.md#alert-rule-taxonomy).

### Starting rule set (map to your own severity scheme and event volume)

| # | Name | Condition | Filter | Tier | Frequency |
| --- | --- | --- | --- | --- | --- |
| 1 | Fatal crash | Any event | Level = fatal | Immediate | `IMMEDIATE_FREQ_MIN="5"` |
| 2 | Unhandled error, new | New issue | `error.unhandled` is set | Immediate | 30 min |
| 3 | High priority, new | Sentry marks new issue high priority | - | Immediate | 30 min |
| 4 | High priority, existing | Sentry marks existing issue high priority | - | Immediate | 60 min |
| 5 | Regression | Regression event | - | Immediate | 30 min |
| 6 | Escalation | Escalating event | - | Immediate | 30 min |
| 7 | User impact | `USER_IMPACT_THRESHOLD="5"` users in 1h | - | Immediate | 60 min |
| 8 | Session impact | `SESSION_IMPACT_PCT="1"`% sessions in 1h | - | Immediate | 60 min |
| 9 | Production error surge | `ERROR_SURGE_THRESHOLD="25"` events in 1h | environment=production | Immediate | 60 min |
| 10 | Frequency spike | `FREQ_SPIKE_THRESHOLD="10"` events in 1h | - | Review | `FREQ_FLOOR_MIN="30"` min minimum |

Add per-runtime rules only for conditions your platform actually emits (for example, an HTTP 5xx spike rule using the `http.status_code` starts-with filter on a backend project). Do not create a rule for a condition your stack cannot produce.

### Slack action retrofit

Full-payload PUT: the rules endpoint replaces the object on write, so this fetches the current rule, appends the Slack action to the existing actions array, and PUTs the whole body back.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
RULE_ID="12345678"
SLACK_INTEGRATION_ID="your-integration-id"
SLACK_CHANNEL="your-channel-name"
SLACK_CHANNEL_ID="your-channel-id"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/rule-${RULE_ID}-$(date -u +%H%M%S).json"
mkdir -p "$(dirname "$BACKUP_FILE")"

# 1. Backup (GET-before-write):
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"

# 2. Patch from the backup, full-payload PUT (the endpoint replaces the whole object):
UPDATED="$(jq \
  --arg ws "$SLACK_INTEGRATION_ID" --arg ch "$SLACK_CHANNEL" --arg cid "$SLACK_CHANNEL_ID" \
  '.actions += [{
    id: "sentry.integrations.slack.notify_action.SlackNotifyServiceAction",
    workspace: $ws, channel: $ch, channel_id: $cid,
    tags: "environment,user,release,os,transaction,level"
  }] | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE")"

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$UPDATED"

# 3. Verify by re-fetch, machine-checkable:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg cid "$SLACK_CHANNEL_ID" \
      '.actions | any(.id == "sentry.integrations.slack.notify_action.SlackNotifyServiceAction" and .channel_id == $cid)'
```

Expect: exit 0, confirming `channel_id` populated with a real ID, not just that a Slack action of some kind is present. **Restore pair:**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/rule-12345678-HHMMSS.json"  # the step-1 backup

jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '.actions == $b[0].actions'
```

Expect: exit 0.

## Rule-set backup and restore

The mandatory pre-mutation snapshot for a bulk alert-rule cleanup, driven from [../SKILL.md#back-up-the-whole-rule-set-before-the-first-mutation](../SKILL.md#back-up-the-whole-rule-set-before-the-first-mutation). One file per project of its issue-alert rules, plus one for the org's metric-alert rules, in a dated home-anchored directory.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# One dated dir for the whole rule-set snapshot, home-anchored like the config store.
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"

# One file per project of its issue-alert rules.
for PROJECT in $(curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/projects/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[].slug'); do
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "${BACKUP_DIR}/issue-rules-${PROJECT}.json"
  test -s "${BACKUP_DIR}/issue-rules-${PROJECT}.json" && echo "backed up issue rules: ${PROJECT}"
done

# One file for the org's metric-alert rules.
curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "${BACKUP_DIR}/metric-alert-rules.json"
test -s "${BACKUP_DIR}/metric-alert-rules.json" && echo "backed up metric-alert rules"
echo "rule-set backup: ${BACKUP_DIR}"
```

Expect: one `issue-rules-<project>.json` per project and one `metric-alert-rules.json`, each non-empty. Restore a single issue rule from the per-project file: a PUT for a rule you updated, a POST for one you deleted (the POST assigns a fresh id and sets `createdBy` to the setup identity, per [../SKILL.md#delete-the-auto-created-default-rule](../SKILL.md#delete-the-auto-created-default-rule)).

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"   # the dir from the backup step
BACKUP_FILE="${BACKUP_DIR}/issue-rules-${PROJECT}.json"

# Restore an UPDATED rule: PUT the saved body back (full object).
jq --arg id "$RULE_ID" \
  '.[] | select(.id == $id) | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' \
  "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

# Restore a DELETED rule: POST the saved body as a new rule (a new id is assigned).
jq --arg id "$RULE_ID" \
  '.[] | select(.id == $id) | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' \
  "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-
```

Expect: the PUT (or POST) returns the restored rule as JSON. A restore is itself a change: announce, confirm, and record it like any other.

## Bulk verify: PUT and DELETE

The per-rule verify shapes for a bulk cleanup, driven from [../SKILL.md#get-verify-after-every-put-and-every-delete](../SKILL.md#get-verify-after-every-put-and-every-delete). Report one verify line per rule, never a batch total.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"

# After a PUT: re-fetch and assert the changed field (example: frequency now 1440).
EXPECT_FREQ="1440"   # example; the value you PUT
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson f "$EXPECT_FREQ" '.frequency == $f' \
  && echo "rule ${RULE_ID}: verified"

# After a DELETE (which returns 202 Accepted, not 200): confirm the rule is gone.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/")"
echo "rule ${RULE_ID} post-delete: ${code}"
```

Expect: the PUT verify prints `rule <id>: verified`, and the post-delete code is `404` (a 202 on the DELETE call means only that the delete was queued, so the follow-up GET is what proves removal).

## Slow a noisy issue-alert rule

Env-scope, age-gate, and slow re-notify for a burst or spike rule, driven from [../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions](../SKILL.md#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions). Do not apply the age gate to a `RegressionEventCondition` rule. The rules endpoint replaces the whole object on write, so this backs up, patches, and PUTs the full body back.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"
TARGET_ENV="production"          # from the rule's receiver channel, not its name
RULE_AGE_GATE_DAYS="7"           # example, tune to your volume; NEVER apply to a regression rule
SLOW_RENOTIFY_MIN="1440"         # example, 24h re-notify; the fast tier stays at 15 minutes
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/issue-rule-${PROJECT}-${RULE_ID}.json"

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
```

Expect: exit 0. Restore by PUTting the backed-up body: `jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE"` piped into the same `PUT`.

## Silence a metric-alert warning tier

Remove the warning trigger from a metric alert (keep the critical trigger), driven from [../SKILL.md#a-metric-alert-trigger-cannot-exist-without-an-action](../SKILL.md#a-metric-alert-trigger-cannot-exist-without-an-action). Stripping the trigger's action instead is rejected by the API.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
ALERT_RULE_ID="your-metric-alert-id"   # from GET /organizations/${SENTRY_ORG}/alert-rules/
BACKUP_DIR="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/metric-alert-${ALERT_RULE_ID}.json"

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
```

Expect: exit 0. Restore the removed trigger by merging the backed-up `triggers` back onto the current body:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
ALERT_RULE_ID="your-metric-alert-id"
BACKUP_FILE="$HOME/.scoutflo/sentry-rules-backup-$(date -u +%F)/metric-alert-your-metric-alert-id.json"  # the step-1 backup

CURRENT="$(curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}")"
printf '%s' "$CURRENT" | jq --slurpfile b "$BACKUP_FILE" '.triggers = $b[0].triggers' \
  | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/alert-rules/${ALERT_RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '.triggers == $b[0].triggers'
```

Expect: exit 0, the triggers byte-equal to the backup. A restore is itself a change; announce and record it like any other.

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

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e --arg b "$DEPLOYED_BRANCH" '.defaultBranch == $b'
```

Expect: exit 0. Set `defaultBranch` to the branch that is actually deployed. If your deploy branch differs from the repository's configured default branch, use the deploy branch; a code mapping pointed at the wrong branch resolves the wrong file version. Rollback: `curl -X DELETE` the mapping URL, then confirm a re-fetch returns `404`, per [../SKILL.md#github-integration-and-code-mappings](../SKILL.md#github-integration-and-code-mappings).

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

NEW_CHECK="$(curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "$CHECK_NAME" --arg u "$CHECK_URL" '{
    name: $n, url: $u, intervalSeconds: 300, timeoutMs: 5000, method: "GET",
    downtimeThreshold: 3, recoveryThreshold: 1, traceSampling: false, responseCaptureEnabled: true
  }')")"
CHECK_ID="$(printf '%s' "$NEW_CHECK" | jq -r '.id')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/${CHECK_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e --arg u "$CHECK_URL" '.url == $u'
```

Expect: exit 0. `intervalSeconds` accepts only `300`, `600`, `1800`, or `3600`; any other value is rejected. Add a matching issue alert rule for the uptime issue type if you want notifications routed the same way as other alerts. Rollback: `curl -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/uptime/${CHECK_ID}/"`, then confirm a re-fetch returns `404`.

## Pagination and rate limits

Sentry paginates list endpoints with a `Link` response header cursor. Follow it rather than trusting a single page as a total. Following the cursor needs a function called in a loop, which is shared state across iterations, so per the stateless-block rule it lives in [`../scripts/fetch-all.sh`](../scripts/fetch-all.sh) instead of a pasted block. Call it from its own stateless block:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

./scripts/fetch-all.sh "${API}/organizations/${SENTRY_ORG}/projects/"
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
| `project:admin` | Delete rules, delete projects |
| `alerts:write` | Create and update alert and metric rules |
| `org:read` | List teams, integrations, members, repos |
| `org:write` | Create code mappings |

## Gotchas

| Problem | Root cause | Fix |
| --- | --- | --- |
| "User not part of project" on email action | `targetType: "Member"` with a raw user ID | Use `targetType: "IssueOwners"` with `fallthroughType: "AllMembers"` |
| Envelope rejected: "missing newline after header" or length mismatch | Hardcoded or character-counted `length` | Compute the exact byte length with `LC_ALL=C ... wc -c`, never `${#var}` on non-ASCII payloads |
| `error.unhandled` filter never matches | Using `match: "eq"` with a value | Use `match: "is"` (is set) |
| `http.status_code` filter rejected | `value: "5"` (string) | Use `value: 5` (integer) |
| Environment-scoped rule fires on every environment | Used `LatestAdoptedReleaseFilter` instead of the rule-level `environment` field | Set `environment` on the rule object; that filter is about release-adoption stage, not environment |
| Uptime monitor creation fails | Invalid `intervalSeconds` | Only 300, 600, 1800, 3600 are valid |
| Default rule noise after project creation | `defaultRules` not set to `false` | Delete the auto-created rule by ID (see SKILL.md) |
| Slack PUT silently drops the email action | Payload only included the new action | Fetch the rule, append to the existing `actions` array, PUT the full object back |
| Workflow-engine listing returns 404 | The endpoint is feature-gated | Treat as feature absence, not an error; list `/projects/{p}/rules/` per project instead |
| `commitCount: 0` on a release with `deployCount > 0` | Deploy created a release, but no CI step linked commits | Document as a CI follow-up before claiming suspect commits work |
