---
name: setup-grafana
description: Guided hardening of Grafana datasources, dashboards, contact points, notification policies, and alert rules from audit-grafana findings; announces each change, waits for confirmation, applies, then verifies live. Use when the user asks to fix a GRAF-NNN finding, wire or repair contact points, clean up broken panels or datasources, or harden Grafana alerting. Do not use for backend stores like Loki or Mimir (use setup-lgtm) or for read-only assessment (use audit-grafana).
disable-model-invocation: true
---

# setup-grafana

Fixes findings from an `audit-grafana` run. Input is one or more finding IDs from the latest `./scoutflo-audits/grafana/<date>/findings.json`. You usually arrive here from a finding's `remediation` pointer, for example `setup-grafana#contact-points`. Starting from scratch works too: run `audit-grafana` first anyway. It produces the baseline score, the finding IDs, and the coverage gaps this skill closes.

In scope: the Grafana application layer. Datasources, folders, dashboards, Grafana-managed alert rules, contact points, notification policies, mute timings, usage and cost surfaces, and confirmed delivery test-fires. Boundaries:

- Backend store internals (Loki, Tempo, Mimir, VictoriaMetrics retention, HA, ingestion health, collector relabeling) belong to `setup-lgtm`. This skill touches backends only through Grafana datasources.
- Read-only proof that the paging path is live belongs to `audit-alert-routing`. The test-fires here are its mutating counterpart: they send real notifications, behind confirmation.
- Error-tracker fixes belong to `setup-sentry`.
- Missing application telemetry is a change inside your application code. Record those items as pending with a named owner instead of touching app repos.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the API call and payload with real values filled in (secrets as env-var names, never values), plus its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object with a read call and show the changed field holding the intended value. A write is unverified until re-read.
5. **Record.** Append the change, its verification evidence, and any pending items with a named owner to the change record.

## Doctor gate

This skill uses the elevated credential tier: it creates and modifies Grafana objects and sends real notifications. Keep this token separate from your read-only audit token; `audit-grafana` checks the audit token for least privilege (GRAF-006), and a shared elevated token would fail that check for a reason.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Grafana | `grafana.url`, `grafana.token_env` | named by `grafana.token_env` | Service account. With RBAC: `dashboards:write`, `folders:write`, `datasources:create`, `datasources:write`, `alert.provisioning:read`, `alert.provisioning:write`. Without RBAC: Org Admin (datasource and provisioning writes sit above Editor) | elevated |
| Slack (optional) | `slack.webhook_env` | named by `slack.webhook_env` | Post to one incoming webhook | optional |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
# grafana.token_env names the variable; presence check only, never print the value.
[ -f "$HOME/.scoutflo/toolkit.yaml" ] || { echo "missing ~/.scoutflo/toolkit.yaml; run /scoutflo:connect"; exit 1; }
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq   >/dev/null || { echo "jq is required"; exit 1; }

curl -fsS --max-time 10 "${GRAFANA_URL}/api/health" | jq -e '.database == "ok"' >/dev/null \
  || { echo "Grafana health check failed at ${GRAFANA_URL}/api/health"; exit 1; }
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
  "${GRAFANA_URL}/api/org" | jq '{org: .name, id: .id}'

# Elevated-tier probe: provisioning must at least be readable with this token.
code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules")"
[ "$code" = "200" ] || { echo "provisioning read returned HTTP ${code}; this token is below the tier setup needs. Run /scoutflo:connect with an elevated token"; exit 1; }
```

Expected: health passes silently, the org name and id print, and the probe passes. Write permission is proven only by the first write: if any announced change returns 403, stop, report the missing permission from the table above, and reconnect. Never proceed past a failed doctor check.

`GET /api/user` is not used here: on modern Grafana (confirmed live on 10.4.1), a real service-account token gets a hard `403 "Endpoint only available for users"` from `/api/user` regardless of its role, because that endpoint identifies an interactively logged-in user, not a service account — under `curl -fsS` and `set -eu` that crashes the gate before setup ever starts, even with a perfectly healthy elevated token. `/api/org` identifies the token's org correctly for service-account tokens.

## Live-safety gate

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/org" \
  | jq '{org: .name, id: .id}'
echo "target: ${GRAFANA_URL}"
```

Compare the printed URL and org against `grafana.url` in `~/.scoutflo/toolkit.yaml`. This skill mutates whatever it is pointed at: a staging token aimed at production, or the reverse, is exactly the mistake this gate exists to catch. On any mismatch, stop and report it. Never proceed on "probably the right instance".

Load `./scoutflo-audits/topology.md` if it exists; its service list defines which services the telemetry contract, dashboards, and alert rules below must cover, under its canonical names. If it does not exist, suggest `/scoutflo:map-topology` before building coverage.

## Load findings and build the change plan

1. Read the latest audit run and list open findings:

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/[0-9]*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-grafana first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
```

2. Select scope. Take the finding IDs you were asked to fix, or, if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section below.

3. Discover who owns each object before planning an edit. A change made below its owner gets rejected or reverted:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
GRAFANA_URL="https://grafana.example.com"   # grafana.url
[ -n "${GRAFANA_TOKEN:-}" ] || { echo "GRAFANA_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/datasources" \
  | jq -r '.[] | select(.readOnly == true) | "file-provisioned: \(.name) (\(.uid))"'
curl -fsS --max-time 15 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/v1/provisioning/alert-rules" \
  | jq -r '.[] | select((.provenance // "") == "file") | "file-provisioned rule: \(.title) (\(.uid))"'
```

File-provisioned objects reject API writes; change the provisioning file they come from, then verify live. If Terraform, Ansible, or another IaC tool owns your Grafana, make the change in that source; the protocol still applies, with "execute" meaning apply through the owner, then verify live. Decide provenance for new objects deliberately: writes through the provisioning API lock objects against UI edits unless you pass `X-Disable-Provenance: true` (details in [references/payloads.md](references/payloads.md#provenance-and-ownership)).

4. Create the working directory and back up every object before modifying it:

```bash
set -eu
RUN_DATE="$(date -u +%F)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
CHANGE_LOG="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/changes.md"
mkdir -p "$BACKUP_DIR"
```

Backups are the GET response of each target object taken immediately before the write. Secure fields come back masked, so a rollback that must restore a credential needs the value from your secret store, not from the backup. `./scoutflo-audits/` stays out of version control.

Two real rollback gotchas, confirmed live, not theoretical:

- **Stale `version` causes a `409 Conflict` on restore.** Grafana's datasource (and other) write APIs use optimistic concurrency keyed on the object's `version` field. PUT-ing the backed-up object verbatim after any successful write fails with `"Datasource has already been updated by someone else. Please reload and try again"`, because the backup's `version` is now behind the live object's. Before restoring, re-fetch the live object, read its current `version`, and splice that value into the backup payload before the restore PUT.
- **A file-provisioned (`readOnly: true`) object cannot be restored via the API at all**, even if a prior write changed one of its fields as a side effect. Confirmed live: setting a new default datasource caused Grafana to auto-unset `isDefault` on the previous, file-provisioned default — but restoring that object's `isDefault` back to `true` via the API failed with `403 "Cannot update read-only data source"`. If the original state you need to restore belongs to a file-provisioned object, the API-only rollback is incomplete; the fix is in the provisioning file/config that owns it, not a call this skill can make. Say so explicitly in the change record rather than reporting rollback as complete.

5. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Exact change | Rollback |
| --- | --- | --- | --- | --- |

Approval must be explicit and may cover the whole table because every row was shown. If you approve only some rows, only those execute. A decline ends the run with zero changes. Execute approved rows one at a time, verifying each before starting the next. Order by dependency and safety: datasources before dashboards and rules, contact points and policies before test-fires, additive changes before destructive ones. Deletions and test-fires are confirmed individually, never inside a batch.

**Mid-batch failure rule.** If row N of an approved batch fails its verification, stop the batch immediately: no row N+1 runs. Every row already applied keeps its backup in `BACKUP_DIR`, captured GET-before-write; those rows stay applied and recorded, they are not rolled back automatically. Re-fetch the failed object's current state, report exactly what happened (the call, the error, and what the live object now shows), and diagnose before doing anything else. Re-announce the remaining unexecuted rows as a fresh plan only after the user decides how to proceed; the earlier approval does not carry over to a re-announced batch. A half-applied change (a dashboard write with an unreplayed panel target, a policy tree PUT with a route added but never test-fired) is worse than no change; verify or roll back the failed row before anything else runs.

## Telemetry contract

Define the contract before provisioning anything; every panel and rule below is judged against it. Write it to `./scoutflo-audits/grafana/telemetry-contract.md`. A starting shape, tune to your environment:

- Resource attributes on every signal: `service.name`, `service.namespace`, `deployment.environment`, and `service.version` where release correlation matters.
- Log labels: low-cardinality only: `service`, `environment`, `component`, `level`. User IDs, request IDs, sessions, emails, IPs, and full URLs stay in log fields, never in labels.
- Request telemetry: route template, method, status code, duration, request ID, trace ID.
- Trace fields: span kind, HTTP route, status code, error flag, and the IDs that correlate traces with logs.
- App metrics per critical service: request rate, error rate, duration percentiles, dependency failures, queue depth, scheduled-job outcomes.

Verify the contract against live labels through the datasource proxy (label-value reads per signal; commands in [references/payloads.md](references/payloads.md#verification-reads)). Every gap is either a Grafana-side fix below or an application change recorded as pending with a named owner. Collector-level label enforcement belongs to `setup-lgtm`.

## Fix sections by finding family

| Audit finding family | Sections | Details |
| --- | --- | --- |
| GRAF-001..006 datasources | Datasources | [references/payloads.md](references/payloads.md#datasources) |
| GRAF-020..028 dashboard semantics | Dashboards | [references/dashboard-design.md](references/dashboard-design.md), [payloads](references/payloads.md#dashboards) |
| GRAF-050..056 alerting | Alert rules, Contact points, Notification policies, Test-fire delivery | [references/payloads.md](references/payloads.md#alerting) |
| GRAF-070..072 query hygiene | Query hygiene | - |
| GRAF-080..082 usage and cost | Usage, cost, and retention | [references/payloads.md](references/payloads.md#usage-and-cost) |
| GRAF-090..092 coverage | Service coverage | - |

### Datasources

For failing health checks (GRAF-001), plaintext credentials (GRAF-002), implicit defaults (GRAF-003), datasources returning no usable data (GRAF-004), and duplicates (GRAF-005).

1. New or repaired datasources get a stable UID you choose, credentials in `secureJsonData` only, and `access: proxy`. Build secret-bearing payloads with `jq` and pipe them straight into `curl`; the secret exists only in its env var and the request body, never in a file. Payloads in [references/payloads.md](references/payloads.md#datasources).
2. Moving a plaintext credential (GRAF-002) means re-supplying the value from your secret store into `secureJsonData` and deleting the plaintext key in the same announced update. Grafana does not migrate it for you. Announce key names only, never values.
3. Verify every datasource change three ways, in order: re-fetch by UID and confirm the changed fields (`secureJsonFields` now lists the moved key, `jsonData` is clean), run the health endpoint, then run one minimal query for data you know exists. A datasource that connects but returns nothing for its most basic query is configured, not useful.
4. Consolidating duplicates (GRAF-005) is destructive: repoint every dashboard and rule at the survivor first, verify their queries still replay, and only then delete the duplicate, confirmed individually.
5. For GRAF-006, create a dedicated Viewer-tier service account for future audits instead of reusing this elevated token.

Rollback: re-apply the backed-up definition; credentials must come back from your secret store.

### Dashboards

For GRAF-020 through GRAF-028 repairs and for new builds. Design rules, the dashboard catalog, panel-type guidance, and the build-time QA checklist are in [references/dashboard-design.md](references/dashboard-design.md).

1. Repairs: re-fetch the live JSON by UID, back it up, and announce the panel-level diff: the target, filter, reducer, or link you change and the finding that demands it.
2. New builds: announce folder, UID, title, and the panel list with each panel's intended question and scope. Build for incident decisions, split executive views from engineering views, and adapt imported panels to your real datasources and labels; never import blindly. Duplicate provisioned dashboards before editing so vendor updates do not overwrite your work.
3. Write with `overwrite: false` and the current `version` so you cannot clobber concurrent edits.
4. Verify every write the same way, no exceptions: re-fetch by UID, replay every panel target through `/api/ds/query`, confirm variables resolve to real values, and hold the live JSON to the build-time QA rules (scope filters, stable IDs, reducer validity, pagination, link scope). This is the same bar `audit-grafana` will score it against.

Rollback: rewrite the backed-up JSON with a version bump, or delete the dashboard when it was new.

### Alert rules

For rules with failing queries (GRAF-051), unexamined state handling (GRAF-052), missing labels (GRAF-053), and missing annotations (GRAF-054). Example tiering; map to your own severity scheme:

| Tier | Examples |
| --- | --- |
| critical | Service unavailable, critical user-path failure, payment or data-integrity breakage, total ingestion loss |
| high | Error-rate surge, queue or scheduled-job failure, database connection failure, provider outage |
| warning | Cost spike, elevated 4xx, degraded latency, non-critical dependency issues |
| paused guardrails | Rules whose telemetry the app does not emit yet, with the exact activation condition recorded |

Cover, per critical service: availability, request rate, errors, and latency; saturation; log error surges; trace-level errors where traces exist; ingestion and cost movement; SLO burn rates where you have agreed SLOs. Every rule carries `severity` and `service` labels (routing and the coverage matrix depend on them) plus `summary` and `runbook_url` annotations on anything that pages.

Workflow per rule: announce title, folder, group, query, threshold, labels, and annotations, with thresholds declared as tunable variables (`ERROR_RATE_THRESHOLD="0.05"` is an example, tune to your traffic). Confirm, create through the provisioning API, set the rule-group evaluation interval deliberately, and set `noDataState` and `execErrState` per rule, deciding what silence means. Verify: re-fetch the rule by UID, replay its query through `/api/ds/query`, and read its state from the rules endpoint. Payloads in [references/payloads.md](references/payloads.md#alerting).

Rollback: re-apply the backup, or delete the rule when it was new. Deleting a rule removes a detection path; confirm deletions individually.

### Contact points

For GRAF-050: routes to missing, empty, or placeholder receivers (a webhook to localhost, an example.com email). Replace them with receivers your team actually watches.

Webhook URLs and receiver API keys are secrets: export them in env vars, build the payload with `jq`, pipe into `curl`. Verify by re-fetching the contact point and confirming name, type, and settings shape; secure settings come back masked, so the receiver is `configured` until a test-fire proves delivery. Payloads in [references/payloads.md](references/payloads.md#alerting).

Rollback: re-apply the backup; secrets from your secret store.

### Notification policies

For GRAF-056 and routing-structure gaps. The policies endpoint replaces the entire tree in one PUT: GET the current tree into the backup first, edit that copy, and PUT the result. A hand-built partial tree silently deletes every route you did not mention.

Add severity routes that match your rule labels, and set `group_by`, `group_wait`, `group_interval`, and `repeat_interval` deliberately on high-volume routes; defaults everywhere predict alert fatigue. Add mute timings for maintenance windows. Verify by re-fetching the tree and diffing against the intended version. Payloads in [references/payloads.md](references/payloads.md#alerting).

Rollback: PUT the backed-up tree.

### Test-fire delivery

For GRAF-055 and for proving any receiver or route you just changed. A test-fire sends a real notification to real humans: tell your on-call before firing at any paging receiver, and announce every test-fire as its own individually confirmed change.

Two levels, weakest to strongest (commands in [references/payloads.md](references/payloads.md#test-fire-delivery)):

1. **Receiver test.** Post to the receiver-test endpoint using the stored contact point. Proves the receiver delivers, but bypasses the routing tree.
2. **Routed canary.** Create a temporary always-firing rule carrying the labels of the route under test, wait one evaluation cycle plus group wait, and confirm the notification arrived where that severity is supposed to land. This proves the full path: rule, labels, policy tree, receiver.

Delivery is proven by receipt, not by an HTTP 200: a named person confirms the message arrived, and you record who, where, and when in the change log. That evidence is what lets the next `audit-grafana` run move GRAF-055 from `configured` to validated, and what `audit-alert-routing` builds on. Always clean up: delete the canary rule and verify the read returns 404.

### Query hygiene

- **GRAF-070** (raw counters): rewrite the panel or rule expression with `rate()` or `increase()` through the Dashboards or Alert rules loop above.
- **GRAF-071** (repeated expensive expressions): back them with recording rules. Grafana-managed recording rules work through the same provisioning API where your version supports them; rules living in the backend belong to `setup-lgtm`.
- **GRAF-072** (high-cardinality log labels): the fix is at the collector, not in Grafana. Hand it to `setup-lgtm` (standardize service labels and collector config) and record it as pending here.

### Service coverage

Per critical service from topology.md:

- **GRAF-090** (no dashboard): build one through the Dashboards loop, scoped by the contract's `service` label.
- **GRAF-091** (no alert rule): create at least one severity-labeled rule through the Alert rules loop.
- **GRAF-092** (no ingestion): not fixable from Grafana. The service is not emitting, or the collector drops it. Record it as pending with the owning team, referencing the telemetry contract; collector-side fixes belong to `setup-lgtm`. Verify later with the proxy ingestion probe in [references/payloads.md](references/payloads.md#verification-reads).

### Usage, cost, and retention

- **GRAF-080** (no usage visibility): provision a usage dashboard through the Dashboards loop. On managed Grafana Cloud, query the provisioned usage datasource; self-hosted, build it from your backend ingestion metrics through existing datasources.
- **GRAF-081** (no cost alerts): create rules on ingestion movement (active series, log bytes per day, span volume). `INGEST_GROWTH_THRESHOLD="1.5"` (ratio week over week) is an example, tune to your billing model.
- **GRAF-082** (retention never decided): make retention a recorded decision with an owner. `RETENTION_DAYS="14"` suits short-lived debugging needs and `RETENTION_DAYS="30"` suits audit or replay needs; both are examples, tune to your compliance and cost requirements. Where it applies: managed plans change retention in the provider's plan settings (record the decision here, apply it there, and re-read the setting to verify); self-hosted backends change it through `setup-lgtm`. Sampling and drop rules for high-volume, low-value telemetry live in your collector; announce them as collector changes if you own the collector, otherwise record them as pending with the owner.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/grafana/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed>
- Command: <exact call and payload applied, secrets as env-var names>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

Before calling the run done, check: every touched datasource health-checks and returns data; the telemetry contract is written and checked against live labels; every touched dashboard re-fetched and every target replayed; every touched rule carries severity and service labels and its query replays; delivery is proven by confirmed receipt or explicitly pending with a named owner; every change has verification evidence and a rollback in the log.

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's reach (application instrumentation, collector changes, IaC-owned objects awaiting merge), each with a named owner.
3. A fresh `/scoutflo:audit-grafana` run to re-score; its delta shows which findings moved to fixed. If routing changed, `audit-alert-routing` proves the paging path end to end.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Payload containing `secureJsonData` written to disk | Build secret-bearing payloads with `jq` and pipe straight into `curl`; secrets exist only in env vars and the request body |
| Notification-policy PUT wipes routes you did not mention | The endpoint replaces the whole tree; GET it into a backup, edit the copy, PUT the result |
| Provisioned objects surprise-locked against UI edits | Decide provenance per object; pass `X-Disable-Provenance: true` when your team maintains objects in the UI |
| API write on a file-provisioned or IaC-owned object rejected or reverted | Check `readOnly` and `provenance` first; change the owning file or module, then verify live |
| Contact point declared working after a re-fetch | Secure settings come back masked; a re-fetch proves shape only. Delivery is proven by a confirmed test-fire receipt |
| Test-fire pages the on-call without warning | Tell your on-call before firing at any paging receiver; confirm every test-fire individually |
| Canary rule left firing after a routing test | Delete the canary, verify the read returns 404, and bound the test with a short evaluation interval |
| Dashboard write clobbers concurrent edits | `overwrite: false` with the current `version` in the payload; re-fetch immediately before writing |
| Dashboard validated against local JSON only | Re-fetch by UID after upload and replay every target through `/api/ds/query` |
| Imported dashboard ships broken panels | Adapt panels to your real datasources and labels; duplicate provisioned dashboards before editing |
| New datasource points at the wrong backend or tenant | Health check plus one minimal query for known data before building anything on it |
| Rule declared healthy because it exists in the rule list | Replay the rule's query via `/api/ds/query` and read its live state; object presence is not alert health |
| Backend problems fixed from the Grafana side | Retention, ingestion, HA, and collector labels belong to `setup-lgtm`; stay on the app layer |
