# Grafana Setup: Payload Cookbook

Payloads, verification reads, and provenance rules for [setup-grafana](../SKILL.md). Every block here is applied only through the change protocol: announce, confirm, execute, verify, record.

Every command block below redeclares the variables it uses, each with the `toolkit.yaml` key it resolves from, so it runs correctly pasted alone into a fresh shell. No block depends on an earlier block having run.

## Provenance and ownership

Every object carries a `provenance` (alerting) or `readOnly` (datasources, dashboards) marker. An API write against a file-provisioned or IaC-owned object is rejected or silently reverted at the next sync.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; presence check only, never print the value.
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Datasources: readOnly true means file-provisioned
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources" \
  | jq -r '.[] | select(.readOnly == true) | "\(.name) (\(.uid))"'

# Alert rules, contact points, policies: provenance field
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
  | jq -r '.[] | select((.provenance // "none") != "none") | "\(.title) (\(.uid)) provenance=\(.provenance)"'
```

| Provenance value | Meaning | Where the change goes |
| --- | --- | --- |
| `none` | Created or last edited through the UI or the plain API | This skill can write it directly |
| `file` | Provisioned from a dashboard/alerting provisioning file on disk | Change the source file, apply through your deploy path, then verify live |
| `api` | Written through the provisioning API with a stable identifier | This skill can write it directly through the same API |
| Terraform, Ansible, or another IaC tool manages the object | Not visible as a `provenance` value; discovered by convention (naming, a tag, a paired `.tf`/playbook file your team knows about) | Change in that source; the protocol still applies, with "execute" meaning apply through the tool, then verify live |

New objects this skill creates default to `provenance: none` unless created through the provisioning API, which locks them as `api` (immutable in the UI, editable only through the API). Decide this deliberately per object: pass the header below when your team wants to keep editing an object in the UI after this skill creates it.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Disable provenance locking on a provisioning-API create (alert rules, contact points, policies)
curl -fsS --max-time 15 -X POST \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
  -H "X-Disable-Provenance: true" \
  -d @payload.json "${GRAFANA_URL}/api/v1/provisioning/alert-rules"
```

## Verification reads

Reused across every fix section. Confirm the intended field holds the intended value; a write is unverified until re-read.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
# Re-fetch a datasource by UID
DS_UID="prom-uid"   # the datasource you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}" \
  | jq '{name, uid, url, secureJsonFields, jsonData}'

# Re-fetch a dashboard by UID and confirm the panel-level change
DASH_UID="abcd1234"   # the dashboard you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  | jq '.dashboard.version'

# Re-fetch an alert rule by UID
RULE_UID="rule-uid"   # the rule you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" \
  | jq '{title, labels, noDataState, execErrState}'

# Live label read through a datasource proxy, per critical service (GRAF-090..092 verification)
DS_UID="loki-uid"      # backend datasource uid
SERVICE="checkout"     # service name from topology.md
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode "query=sum(count_over_time({service=\"${SERVICE}\"}[15m]))" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${DS_UID}/loki/api/v1/query" \
  | jq '.data.result'
```

Expected shapes and their failure modes match [audit-grafana's cookbook](../../audit-grafana/references/api-checks.md#apidsquery-cookbook): a populated `error` field means the query is broken live, `frames: 0` with no error needs a second look, and a 403 means the token lacks access, not that the object is broken.

## Datasources

Create or repair a datasource. Credentials go in `secureJsonData` only; build the payload with `jq` and pipe straight into `curl` so the secret exists only in its env var and the request body.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_TOKEN_ENV="LOKI_DS_TOKEN"        # env var name from toolkit.yaml, e.g. loki.token_env
DS_UID="loki-checkout"              # a stable UID you choose; never let Grafana auto-generate one
DS_URL="https://loki.example.com"   # the backend URL from toolkit.yaml

jq -n --arg uid "$DS_UID" --arg url "$DS_URL" --arg token "${!DS_TOKEN_ENV}" '
  { name: "Loki", type: "loki", access: "proxy", uid: $uid, url: $url,
    jsonData: { httpHeaderName1: "Authorization" },
    secureJsonData: { httpHeaderValue1: ("Bearer " + $token) } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/datasources" \
| jq '{id, uid, name}'
```

Moving a plaintext credential (GRAF-002) out of `jsonData`: PUT the same shape with the plaintext key removed from `jsonData` and the value moved into `secureJsonData`, in the same announced change. Grafana does not migrate it for you.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_ID="7"   # numeric id from GET /api/datasources
curl -fsS --max-time 15 -X PUT \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
  -d @payload.json "${GRAFANA_URL}/api/datasources/${DS_ID}"
```

Health check and minimal query, in order, after every write:

```bash
set -eu
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="loki-checkout"   # the datasource you just wrote
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}/health" \
  | jq '{status, message}'
```

Then replay one minimal query for data you know exists, using [audit-grafana's `/api/ds/query` cookbook, pattern 2](../../audit-grafana/references/api-checks.md#apidsquery-cookbook). A datasource that health-checks but returns nothing for its most basic query is configured, not useful.

Delete a duplicate only after every dashboard and rule that referenced it has been repointed and its queries replay clean:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="loki-duplicate"   # the survivor keeps the original UID
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources/uid/${DS_UID}"
```

## Dashboards

Dashboard design rules, the panel catalog, and the build-time QA checklist live in [dashboard-design.md](dashboard-design.md). This section covers the write mechanics only.

Write with `overwrite: false` and the current `version`, so a stale local copy cannot clobber a concurrent edit:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
DASH_UID="abcd1234"   # existing UID for a repair, or a new one you choose for a build
FOLDER_UID="folder-uid"

# Repairs: re-fetch first, back up, then edit the JSON in place.
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/dashboards/uid/${DASH_UID}" \
  > "${BACKUP_DIR}/dashboard-${DASH_UID}.json"
CURRENT_VERSION="$(jq '.dashboard.version' "${BACKUP_DIR}/dashboard-${DASH_UID}.json")"

jq --argjson v "$CURRENT_VERSION" '
  .dashboard.version = $v
  | .overwrite = false
  | .folderUid = "'"$FOLDER_UID"'"
  # ... apply the announced panel-level edit here ...
' "${BACKUP_DIR}/dashboard-${DASH_UID}.json" \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/dashboards/db" \
| jq '{uid, version, status}'
```

Verify every write the same way, no exceptions: re-fetch by UID, replay every panel target through `/api/ds/query` ([audit-grafana pattern 1](../../audit-grafana/references/api-checks.md#apidsquery-cookbook)), and confirm template variables resolve:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="prom-uid"       # datasource backing the variable
VAR_QUERY="label_values(service)"   # the variable's own query
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode "query=$VAR_QUERY" \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${DS_UID}/api/v1/label/service/values" \
  | jq '.data'
```

Expected: a non-empty value list. An empty list blanks every panel under that variable.

## Alerting

### Alert rules

Provisioning-API create. Thresholds, evaluation windows, and label values below are examples; declare them as named variables and tune to your traffic.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
DS_UID="prom-uid"                         # datasource the rule queries
ERROR_RATE_THRESHOLD="0.05"               # example, tune to your traffic
FOLDER_UID="folder-uid"
RULE_GROUP="checkout-availability"
EVAL_INTERVAL="1m"                        # example, tune to your evaluation budget

jq -n --arg ds "$DS_UID" --argjson thresh "$ERROR_RATE_THRESHOLD" '
{
  title: "checkout error rate high",
  ruleGroup: "'"$RULE_GROUP"'",
  folderUID: "'"$FOLDER_UID"'",
  condition: "C",
  data: [
    { refId: "A", datasourceUid: $ds,
      model: { expr: "sum(rate(http_requests_total{service=\"checkout\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{service=\"checkout\"}[5m]))", instant: true } },
    { refId: "C", datasourceUid: "__expr__",
      model: { type: "threshold", expression: "A", conditions: [ { evaluator: { type: "gt", params: [$thresh] } } ] } }
  ],
  noDataState: "Alerting",
  execErrState: "Alerting",
  "for": "5m",
  labels: { severity: "high", service: "checkout" },
  annotations: { summary: "checkout error rate above threshold", runbook_url: "https://runbooks.example.com/checkout-errors" }
}' | curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
| jq '{uid, title}'
```

Verify: re-fetch by UID, replay the primary query through `/api/ds/query`, and read live state:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
RULE_UID="rule-uid"   # from the create response
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${RULE_UID}" \
  | jq '{title, labels, "for", noDataState, execErrState}'
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/prometheus/grafana/api/v1/rules" \
  | jq --arg t "checkout error rate high" '.data.groups[].rules[] | select(.name == $t) | {state, health}'
```

Rollback: PUT the backed-up rule body to the same UID, or DELETE it when it was new.

### Contact points

Webhook URLs and receiver API keys are secrets: export them, build the payload with `jq`, pipe into `curl`.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SLACK_WEBHOOK_ENV="TEAM_SLACK_WEBHOOK"   # env var name from toolkit.yaml

jq -n --arg url "${!SLACK_WEBHOOK_ENV}" '
{ name: "team-default", type: "slack",
  settings: { url: $url, title: "{{ .CommonLabels.alertname }}" } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/contact-points" \
| jq '{uid, name, type}'
```

Verify by re-fetching and confirming name, type, and settings shape. Secure settings come back masked, so this proves the receiver exists correctly configured, not that it delivers; delivery is proven only by a test-fire.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
CP_UID="cp-uid"   # from the create response
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}" \
  | jq '{name, type, settings}'
```

Rollback: PUT the backed-up definition; the secret comes from your secret store, not from the backup, since it comes back masked.

### Notification policies

The policies endpoint replaces the entire tree in one PUT. GET the current tree into the backup first, edit that copy, and PUT the result; a hand-built partial tree silently deletes every route you did not mention.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  > "${BACKUP_DIR}/policies.json"

jq '.routes += [
  { receiver: "team-pager", matchers: ["severity=critical"],
    group_by: ["alertname", "service"], group_wait: "30s", group_interval: "5m", repeat_interval: "4h" }
]' "${BACKUP_DIR}/policies.json" \
| curl -fsS --max-time 15 -X PUT \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/policies" \
| jq '{receiver, routes: (.routes | length)}'
```

`group_wait`, `group_interval`, and `repeat_interval` values above are examples; tune to how fast your team wants the first notification versus how much grouping you want on a storm. Verify by re-fetching the tree and diffing against the intended version:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-$(date -u +%F)/backups"   # the directory holding policies.json from the GET-before-write step
# Compose the intended tree from the backup (append your new route object), then diff
# against what the server now serves. Temp file, not process substitution: /bin/sh.
INTENDED="${TMPDIR:-/tmp}/policies-intended.$$"
jq '.routes += [{"receiver": "your-new-receiver"}]' "${BACKUP_DIR}/policies.json" > "$INTENDED"   # your real route object here
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/policies" \
  | diff - "$INTENDED"
rm -f "$INTENDED"
```

Rollback: PUT the backed-up tree.

## Test-fire delivery

A test-fire sends a real notification to real humans. Tell your on-call before firing at any paging receiver, and confirm every test-fire as its own individually announced change, never inside a batch.

**Receiver test** (weakest; bypasses the routing tree, proves only that the receiver itself delivers):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
CP_UID="cp-uid"   # the contact point under test
jq -n '{ alert: { labels: { alertname: "ToolkitReceiverTest" },
                   annotations: { summary: "Controlled receiver test from setup-grafana. Safe to acknowledge." } } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/contact-points/${CP_UID}/test"
```

**Routed canary** (stronger; proves rule, labels, policy tree, and receiver together):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
FOLDER_UID="folder-uid"
TEST_SEVERITY="critical"   # the route under test

jq -n --arg sev "$TEST_SEVERITY" '
{ title: "ToolkitRoutingCanary", ruleGroup: "toolkit-canary", folderUID: "'"$FOLDER_UID"'",
  condition: "C",
  data: [ { refId: "C", datasourceUid: "__expr__",
            model: { type: "math", expression: "1 == 1" } } ],
  noDataState: "OK", execErrState: "Alerting", "for": "0s",
  labels: { severity: $sev, service: "receiver-test" },
  annotations: { summary: "Controlled routing canary from setup-grafana. Safe to acknowledge." } }' \
| curl -fsS --max-time 15 -X POST \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
    -d @- "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
| jq '{uid, title}'
```

Wait one evaluation cycle plus the route's `group_wait`, then confirm with a named person that the notification arrived at the receiver the severity is supposed to reach. Delivery is proven by receipt, not by an HTTP 200. Always clean up:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
CANARY_UID="canary-rule-uid"   # from the create response
curl -fsS --max-time 10 -X DELETE -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${CANARY_UID}"
curl -sS --max-time 10 -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules/${CANARY_UID}"
```

Expected: `404` on the final read, confirming the canary is gone.

## Usage and cost

Usage dashboard query pattern (managed Grafana Cloud usage datasource, provisioned by the provider):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
USAGE_DS_UID="grafanacloud-usage"   # the provider-provisioned usage datasource uid
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  --get --data-urlencode 'query=sum(grafanacloud_org_metrics_instance_active_series)' \
  "${GRAFANA_URL}/api/datasources/proxy/uid/${USAGE_DS_UID}/api/v1/query" \
  | jq '.data.result'
```

Self-hosted: build the same view from your backend's own ingestion metrics (`prometheus_tsdb_head_series`, Loki's `loki_ingester_memory_streams`, Tempo's span-ingestion counters) through your existing datasources; no separate provisioning step.

Cost alert on ingestion growth. `INGEST_GROWTH_THRESHOLD` below is a ratio, week over week; it is an example starting point, tune to your billing model:

```bash
INGEST_GROWTH_THRESHOLD="1.5"   # example, tune to your billing model
```

Follow the alert-rule create pattern above with an expression comparing this week's active-series count to last week's, carrying `severity: warning` and `service: monitoring`.

Retention: on managed plans, retention lives in the provider's plan settings, not in a Grafana API call; record the decision here (`RETENTION_DAYS="30"` is an example, tune to your compliance and cost targets), apply it in the provider's console, and re-read the setting through the provider's API to verify. Self-hosted backend retention (Loki, Tempo, Mimir, VictoriaMetrics) changes through `setup-lgtm`.
