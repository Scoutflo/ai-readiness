---
name: setup-gcp
description: Guided hardening of Google Cloud Monitoring from audit-gcp findings; creates and repairs notification channels, uptime checks, alert policies, logs-based metrics, and dashboards, announcing each change, waiting for confirmation, then verifying live. Monitoring-plane writes only. Use when the user asks to fix a GCP-NNN finding, wire GCP alert routing, add uptime checks or alert policies, or create logs-based metrics. Do not use for read-only assessment (use audit-gcp), for in-cluster stacks (use setup-lgtm), or for Ops Agent installs and VM, GKE, load balancer, firewall, or IAM changes (planned here, never executed).
disable-model-invocation: true
---

# setup-gcp

Fixes findings from an `audit-gcp` run. Input is one or more finding IDs from the latest `./scoutflo-audits/gcp/<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-gcp#fix-uptime-coverage`.

| Finding ID | Fix section |
| --- | --- |
| GCP-001, GCP-003, GCP-005 | [Fix notification channels](#fix-notification-channels) |
| GCP-002 | [Attach channels to policies](#attach-channels-to-policies) |
| GCP-004 | [Prove channel delivery](#prove-channel-delivery) |
| GCP-006 | [Review snoozes](#review-snoozes) |
| GCP-010 to GCP-015 | [Fix uptime coverage](#fix-uptime-coverage) |
| GCP-020, GCP-023, GCP-024 | [Add VM pressure policies](#add-vm-pressure-policies) |
| GCP-021, GCP-022 | [Gate memory and disk on the Ops Agent](#gate-memory-and-disk-on-the-ops-agent) |
| GCP-031, GCP-032, GCP-033 | [Add GKE health policies](#add-gke-health-policies) |
| GCP-041, GCP-042 | [Add LB alert policies](#add-lb-alert-policies) |
| GCP-050, GCP-051, GCP-052 | [Create logs-based metrics and their alerts](#create-logs-based-metrics) |
| GCP-060, GCP-061, GCP-062 | [Improve alert documentation](#improve-alert-documentation) |
| GCP-070, GCP-071 | [Build dashboards](#build-dashboards) |
| GCP-030, GCP-040, GCP-043, GCP-053 | [Plan out-of-scope changes](#plan-out-of-scope-changes) (plan only) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**Write scope: the Monitoring plane only.** This skill creates and updates notification channels, uptime checks, alert policies, logs-based metrics, and dashboards. Out of write scope, always: Ops Agent installs, GKE cluster or node pool changes (including telemetry component enablement), log sink changes, load balancer, backend, health-check, firewall, IAM, DNS, and certificate changes, and any VM mutation. Those are controlled rollouts or traffic-impacting changes owned by the people who own those surfaces; this skill records a plan with a named owner instead ([Plan out-of-scope changes](#plan-out-of-scope-changes)). It also never mutates local gcloud state: no `gcloud config set`, no `configurations activate`; every command carries explicit flags.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the command or JSON payload with real values filled in (webhook URLs and tokens excepted; announce channel display names, never label values), its risk class, and its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change (an API rejects a field, a flag differs on your gcloud version), stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `jq -e` or a captured HTTP code. A write is unverified until a read proves it.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

Order discipline, kept from hard experience: routing before alerts (channels first, then policies that reference them), logs-based metrics before log-alert policies, dashboards last. A policy created before its channel exists pages nobody and verifies dirty. Where you run parallel environments, fix the non-production environment first and confirm the result before touching production.

## Doctor gate

Elevated tier: this skill mutates Cloud Monitoring and Cloud Logging metric state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| GCP | `gcp.project`, optional `gcp.region`, optional `gcp.credentials_env` | key-file path variable when used; presence only | `roles/monitoring.editor`, plus `roles/logging.configWriter` when logs-based metrics are in scope | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in gcloud curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  [ -f "$GOOGLE_APPLICATION_CREDENTIALS" ] || { echo "GOOGLE_APPLICATION_CREDENTIALS names a missing file"; exit 1; }
  TOKEN="$(gcloud auth application-default print-access-token)"
  export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"
else
  TOKEN="$(gcloud auth print-access-token)"
fi
gcloud projects describe "$GCP_PROJECT" --format='value(projectId)'
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1")"
echo "monitoring api: ${code}"
```

Expected: the project id and `monitoring api: 200`. Editor-tier permission cannot be introspected cheaply, so the first write of the run is the scope test: a `403` on it means the identity lacks `monitoring.editor` (or `logging.configWriter` for metric writes). Stop, report which role is missing, and point at `/scoutflo:connect`; do not keep trying other writes to find one that works.

## Live-safety gate

Resolve the target project from `toolkit.yaml` itself, not from a value typed into the block, then compare it against what `gcloud` actually resolves live. The comparison value has to come from the config file or the gate can pass on whatever the operator happened to type:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve gcp.project the same way doctor.sh's cfg() reads two-level keys:
# yq when present, a sed fallback otherwise. Never hand-typed.
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CONFIG" >/dev/null 2>&1; then
  GCP_PROJECT="$(yq -r '.gcp.project // ""' "$CONFIG")"
else
  GCP_PROJECT="$(sed -n '/^gcp:/,/^[A-Za-z_]/p' "$CONFIG" \
    | sed -n 's/^[[:space:]]\{1,\}project:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]#.*$//' -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/[[:space:]]*$//')"
fi
[ -n "$GCP_PROJECT" ] || { echo "gcp.project is not set in $CONFIG; run /scoutflo:connect"; exit 1; }
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  echo "identity: $(jq -r '.client_email // "unknown"' "$GOOGLE_APPLICATION_CREDENTIALS") (key file)"
else
  echo "identity: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
fi
echo "config target (gcp.project): ${GCP_PROJECT}"
LIVE_PROJECT="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectId)')"
echo "live project (gcloud projects describe): ${LIVE_PROJECT}"
[ "$LIVE_PROJECT" = "$GCP_PROJECT" ] || { echo "STOP: gcloud resolved project ${LIVE_PROJECT}, which does not match toolkit.yaml gcp.project (${GCP_PROJECT})"; exit 1; }
echo "live-safety gate passed: gcloud resolves the project toolkit.yaml names"
```

Expected: the final line prints and nothing stops the block. `GCP_PROJECT` is re-read from `toolkit.yaml` in this same block every time, never carried over from a prior block or from what an operator remembers typing, so the gate cannot pass on the wrong target by construction. If the identity is not the one your team intends for setup work, or the project does not resolve, stop and report the mismatch. Never proceed on "probably the right project". Every object in this skill is addressed by the full resource name captured from the audit run (`projects/<id>/alertPolicies/<id>`), never by display-name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-gcp first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown; deletions (a channel, a policy, a snooze cancellation) are still re-confirmed individually at their announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-fetch the failed object's current state, report what happened, and re-announce the remainder only after the user decides. A half-applied policy (created but with no channels attached) is worse than no policy; verify or roll back the failed object before anything else runs.

**Backups are GET-before-write.** Before any update, capture the object's current JSON into `BACKUP_DIR` with a plain GET. Channel backups contain label values (webhook URLs, tokens): they stay local, out of version control, and out of every announcement. Rollback is re-applying the backup or deleting the created object; every section names its restore command, and one worked restore pair lives in [Attach channels to policies](#attach-channels-to-policies).

gcloud flag names shift across versions: for every gcloud write in this skill, check the subcommand's `--help` before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags.

## Fix notification channels

For `GCP-001`, `GCP-003`, `GCP-005`. Monitoring-plane writes; nothing redeploys. Name channels per environment (`<team> <environment> alerts`) even when they route to the same workspace, so a page's origin is readable before its body. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of notification channels; they are different webhooks with different jobs.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="payments production alerts"   # <team> <environment> alerts naming pattern
CHANNEL_EMAIL="oncall@example.org"          # the address your team actually watches
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)"
mkdir -p "$WORK_DIR"
jq -n --arg dn "$CHANNEL_NAME" --arg em "$CHANNEL_EMAIL" \
  '{type:"email", displayName:$dn, labels:{email_address:$em}, enabled:true}' > "${WORK_DIR}/channel.json"
NEW_CHANNEL="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d @"${WORK_DIR}/channel.json" "${MON_API}/projects/${GCP_PROJECT}/notificationChannels" | jq -r '.name')"
echo "created: ${NEW_CHANNEL}"
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_CHANNEL}" \
  | jq -e '.enabled == true and .type == "email"'
```

Expected: the new channel's resource name and a final `jq -e` exit 0. For webhook, Slack, or PagerDuty channel types the sensitive value (URL, token, service key) goes into the payload file from an unechoed variable, is never printed, and the announcement shows the display name and type only. Rollback: `curl -fsS -X DELETE -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_CHANNEL}"`, then a GET asserting `404`. For `GCP-005`, replacing a dead channel means creating the good one, re-pointing every referencing policy ([next section](#attach-channels-to-policies)), verifying, and only then deleting the dead channel, confirmed individually.

## Attach channels to policies

For `GCP-002`. Update the policy's `notificationChannels` field only, with an explicit `updateMask` so nothing else moves. This is also the worked backup-and-restore pair for every PATCH in this skill.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
POLICY_NAME="projects/your-project-id/alertPolicies/1234567890"   # full resource name from the audit capture
CHANNEL_NAME="projects/your-project-id/notificationChannels/987654321"   # the channel to attach
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/policy-$(basename "$POLICY_NAME").json"
# 1. Backup (GET-before-write):
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"
# 2. Patch the one field, announced first:
jq -n --arg ch "$CHANNEL_NAME" '{notificationChannels: [$ch]}' \
  | curl -fsS --max-time 30 -X PATCH -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d @- "${MON_API}/${POLICY_NAME}?updateMask=notificationChannels" >/dev/null
# 3. Verify by re-fetch:
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" \
  | jq -e --arg ch "$CHANNEL_NAME" '.notificationChannels | index($ch)'
```

Expected: exit 0. To attach without dropping existing channels, build the array from the backup: `jq '{notificationChannels: (.notificationChannels + ["NEW"])}' "$BACKUP_FILE"`. **Restore pair, run as written when a patch must be undone:**

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
POLICY_NAME="projects/your-project-id/alertPolicies/1234567890"   # same policy
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)/backups/policy-1234567890.json"  # the step-1 backup
jq '{notificationChannels: (.notificationChannels // [])}' "$BACKUP_FILE" \
  | curl -fsS --max-time 30 -X PATCH -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d @- "${MON_API}/${POLICY_NAME}?updateMask=notificationChannels" >/dev/null
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '.notificationChannels == ($b[0].notificationChannels // [])'
```

Expected: exit 0, the field byte-equal to the backup. A restore is a change; announce and record it like any other.

## Prove channel delivery

For `GCP-004`. Two levels, recorded separately and never conflated:

1. **Channel verification, where the type supports it.** Some channel types accept a Monitoring-issued verification code (`sendVerificationCode` / `verify` on the channel resource). This posts a visible message to the destination; announce it and get confirmation first. Success flips `verificationStatus` to `VERIFIED`, asserted with a re-fetch and `jq -e '.verificationStatus == "VERIFIED"'`. This proves the channel accepts Monitoring traffic, nothing more.
2. **Observed Monitoring-generated notification.** Only Cloud Monitoring firing a real policy proves the path end to end: use the next natural threshold event or planned maintenance signal, have a human confirm the message arrived, and record the timestamp. Never fabricate load or force an incident to generate one; with no natural event due, `GCP-004` stays `configured` and the wait becomes a pending item with an owner.

- ❌ `Verification code accepted, so GCP-004 is fixed and routing is validated-live.`
- ✅ `verificationStatus VERIFIED recorded; GCP-004 stays configured until a Monitoring-generated notification is seen at the destination, pending item owned by the on-call lead.`

## Review snoozes

For `GCP-006`. Ending a snooze early un-mutes alerting; that is a Monitoring-plane write, announced with the snooze body quoted and confirmed individually. Shorten the snooze by PATCHing its `interval.endTime` to now (REST `snoozes` resource), then verify with a GET asserting the new end time is in the past. Leave deliberate maintenance snoozes alone; the fix for a valid-but-undocumented snooze is a documented expiry and owner in the change record, not a cancellation.

## Fix uptime coverage

For `GCP-010` to `GCP-015`. Two objects per endpoint, in strict order: the uptime check, then the alert policy on its `check_passed` metric; a check without a policy notifies nobody (`GCP-011`). Before creating any check, prove the exact target answers `200` in this session; a wrong target pages people at 3am:

```bash
set -eu
TARGET_HOST="www.example.com"   # the exact host the check will watch
TARGET_PATH="/healthz"          # the exact path
BODY="$(mktemp)"
code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 15 "https://${TARGET_HOST}${TARGET_PATH}")" || code="000"
echo "GET https://${TARGET_HOST}${TARGET_PATH} -> ${code}"
head -c 200 "$BODY"; echo; rm -f "$BODY"
```

Expected: `200` right now. A `401` (auth-only), `3xx` to a login page, `404`, or timeout stops this section: fix the endpoint or pick another path first. Do not create checks for auth-only endpoints unless you deliberately configure expected-status matching, announced as such. Then create and verify (GA gcloud group; check `--help` on your version first):

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
TARGET_HOST="www.example.com"
TARGET_PATH="/healthz"
CHECK_NAME="checkout production uptime"   # name it for the service and environment
UPTIME_PERIOD=1        # example: MINUTES between checks. gcloud --period is an integer count of minutes (default 1) — NOT a duration string like "60s", which current gcloud rejects. Tune to your traffic.
UPTIME_TIMEOUT=10      # example: SECONDS to wait for the request. gcloud --timeout is an integer count of seconds (default 60) — NOT a duration string like "10s".
gcloud monitoring uptime create "$CHECK_NAME" --project "$GCP_PROJECT" \
  --resource-type=uptime-url --resource-labels="host=${TARGET_HOST},project_id=${GCP_PROJECT}" \
  --protocol=https --port=443 --path="$TARGET_PATH" --period="$UPTIME_PERIOD" --timeout="$UPTIME_TIMEOUT"
gcloud monitoring uptime list-configs --project "$GCP_PROJECT" --format=json \
  | jq -e --arg h "$TARGET_HOST" --arg p "$TARGET_PATH" \
      'any(.[]; .monitoredResource.labels.host == $h and .httpCheck.path == $p)'
```

Expected: exit 0. Capture the new check id (`.name` tail) and create its alert policy via the REST POST in [Add VM pressure policies](#add-vm-pressure-policies), with the condition filter on `monitoring.googleapis.com/uptime_check/check_passed` scoped to `metric.labels.check_id`, a `REDUCE_COUNT_FALSE` aggregation, and your notification channel attached; verify the policy re-fetch shows the channel and the filter. SSL-expiry visibility (`GCP-012`) is one more policy on `uptime_check/time_until_ssl_cert_expires`. Retiring a dead check (`GCP-015`) deletes a detection path: confirm individually with the audit's DNS and status-code evidence quoted, `gcloud monitoring uptime delete` it, verify absence in the re-list, and record where the target lives now. Rollback for creations: delete the created check and policy, verify absence.

## Add VM pressure policies

For `GCP-020`, `GCP-023`, `GCP-024`. Gate first, create second: run the audit's series probe ([audit-gcp references section 7](../audit-gcp/references/gcp-checks.md)) on the exact condition filter you are about to ship; zero series means the policy would be born dead (`GCP-023`), and a `metadata.user_labels` scope that returns nothing means the label shape is wrong (`GCP-024`). Announce the full policy JSON, then:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="projects/your-project-id/notificationChannels/987654321"   # from Fix notification channels
CPU_WARN_PCT="0.80"     # example warning tier as a ratio, tune to your baseline
CPU_WINDOW="300s"       # example
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)"
mkdir -p "$WORK_DIR"
jq -n --arg ch "$CHANNEL_NAME" --arg thr "$CPU_WARN_PCT" --arg win "$CPU_WINDOW" '{
  displayName: "production vm cpu WARNING",
  combiner: "OR",
  conditions: [{
    displayName: "cpu utilization above warning tier",
    conditionThreshold: {
      filter: "metric.type = \"compute.googleapis.com/instance/cpu/utilization\" AND resource.type = \"gce_instance\"",
      comparison: "COMPARISON_GT",
      thresholdValue: ($thr | tonumber),
      duration: $win,
      aggregations: [{alignmentPeriod: "60s", perSeriesAligner: "ALIGN_MEAN"}]
    }
  }],
  notificationChannels: [$ch],
  documentation: {content: "production gce_instance WARNING cpu above threshold for window | capture CPU chart, load and process state, container or app status, recent deploy, LB 5xx and latency, dependency health", mimeType: "text/markdown"}
}' > "${WORK_DIR}/cpu-warn-policy.json"
NEW_POLICY="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d @"${WORK_DIR}/cpu-warn-policy.json" "${MON_API}/projects/${GCP_PROJECT}/alertPolicies" | jq -r '.name')"
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_POLICY}" \
  | jq -e '.enabled != false and ((.notificationChannels // []) | length) >= 1'
```

Expected: exit 0. Repeat for the saturation tier (a second policy at `CPU_SAT_PCT`, for example 0.95; both examples, tune per workload) and scope the filter to your serving VMs by label once the label probe passed. This same POST-create-verify shape serves uptime, GKE, LB, and log policies; only the filter, threshold, and documentation change. Rollback: `curl -X DELETE` the created policy name, verify `404` on re-fetch.

## Gate memory and disk on the Ops Agent

For `GCP-021`, `GCP-022`. Memory and disk policies are created here only for VMs where the agent metrics are proven live this session (the `agent.googleapis.com/agent/uptime` probe in the audit reference, per VM). For proven VMs, create policies on `agent.googleapis.com/memory/percent_used` and `agent.googleapis.com/disk/percent_used` with the create-verify shape above. For unproven VMs, the fix is installing the Ops Agent, and that is a VM-level controlled rollout out of this skill's write scope: record it in [Plan out-of-scope changes](#plan-out-of-scope-changes) with the VM list from the finding and a named owner, and leave `GCP-021` open until the agent metrics exist.

- ❌ `Created memory policies for all six VMs; the agent will be installed next week anyway.`
- ✅ `Created memory and disk policies for the two VMs with live agent metrics; filed the Ops Agent install plan for the other four with the platform owner; GCP-021 stays open for them.`

## Add GKE health policies

For `GCP-031`, `GCP-032`, `GCP-033`. Policies on `kubernetes.io/container/restart_count` (restart spike per workload), pod pending and unschedulable conditions, and node pressure, using the create-verify shape with filters validated by the series probe first; scope filters by `resource.labels.cluster_name` and namespace. If the series probe returns nothing because cluster telemetry components are off (`GCP-030`) or Managed Prometheus is absent where the plan expects it (`GCP-032` when enablement is the fix), the prerequisite is a cluster update: out of write scope, plan it with the cluster owner. Never create a policy whose metric the cluster does not ship yet; that is the false confidence the audit exists to catch.

## Add LB alert policies

For `GCP-041`, `GCP-042`. Same create-verify shape: a 5xx-ratio policy on `loadbalancing.googleapis.com/https/request_count` filtered to `response_code_class = 500` against total request rate (starting ratio `LB_5XX_RATIO`, example 0.05), and a latency policy on `loadbalancing.googleapis.com/https/backend_latencies` (starting p95 `LB_LATENCY_MS`, example 1000 ms; both tuned after observing baselines, and a request-anomaly policy only once a baseline exists). Validate each filter against live series first; a forwarding rule with no traffic yields zero series and an honest pause, not a dead policy. Health-check attachment (`GCP-040`) and get-health IAM (`GCP-043`) are LB and IAM changes: plan only.

## Create logs-based metrics

For `GCP-050`, `GCP-051`, `GCP-052`. Strict order: prove the filter matches, create the metric, then the policy. The service roster comes from topology.md, one error-count metric per critical service.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
SERVICE_NAME="checkout"         # canonical name from topology.md
LOG_FILTER='resource.type="gce_instance" AND severity>=ERROR AND jsonPayload.service="checkout"'  # tune to your log shape
METRIC_NAME="${SERVICE_NAME}-error-count"
# 1. Gate: the filter must match something recent before it becomes a metric.
gcloud logging read "$LOG_FILTER" --project "$GCP_PROJECT" --limit 1 --freshness=24h --format='value(timestamp)'
# 2. Create (announced first), then verify:
gcloud logging metrics create "$METRIC_NAME" --project "$GCP_PROJECT" \
  --description="error count for ${SERVICE_NAME}" --log-filter="$LOG_FILTER"
gcloud logging metrics describe "$METRIC_NAME" --project "$GCP_PROJECT" --format=json \
  | jq -e --arg f "$LOG_FILTER" '.filter == $f'
```

Expected: a timestamp from step 1 (empty output stops the section: fix the filter or accept that the service logs no errors, in writing), then exit 0. An empty gate result on a service you know errors means the filter is wrong; shipping it anyway creates the `GCP-051` decoration this section exists to prevent. Then create the alert policy on `logging.googleapis.com/user/<METRIC_NAME>` with the create-verify shape (`GCP-052`), rate over `LOG_ERROR_RATE_WINDOW` (example 300s, tune per service). Rollback: `gcloud logging metrics delete "$METRIC_NAME"` after deleting the policy, each verified by absence. Sink changes (`GCP-053`) are out of write scope: plan them.

## Improve alert documentation

For `GCP-060`, `GCP-061`, `GCP-062`. PATCH `documentation` (and `userLabels` for severity) with `updateMask`, using the backup-restore pair's mechanics. Confirmed live: the Monitoring API rejects any write where `documentation.content` is non-empty but `documentation.mimeType` is missing (`400 INVALID_ARGUMENT: "non-empty content requires non-empty MIME type and vice versa"`) — always set both together (`text/markdown` is a safe default) whether creating a policy or PATCHing this field on an existing one. Documentation shape, one line then capture list:

`<environment> <resource kind> <resource name> <severity tier> <metric> <threshold/window> | capture <datapoint>, <datapoint>, <datapoint>`

Severity tiers are yours to name (`WARNING`, `SATURATION`, `DOWN` is a working starter set). Datapoints to capture first, per surface; these decide whether the incident is capacity, routing, app, provider, deploy, or a noisy threshold:

| Surface | Capture first |
| --- | --- |
| Uptime | URL, status code, latency, SSL state, DNS resolution, checker region, recent deploy window, backend service, target VM, app logs |
| Compute CPU | CPU chart, load and process state, container or app status, recent deploy, LB 5xx and latency, dependency health |
| Compute memory/disk | memory percent, disk percent, inode and disk growth, process pressure, app logs (only exists after agent proof) |
| GKE | cluster, namespace, workload, pod, node, node pool, restart count, last termination reason, pending and unschedulable pods, pressure, recent rollout |
| Load balancer | host, URL map, backend service, health check, instance group or NEG, backend health, 5xx count, p95 and p99 latency, request volume, deploy window |
| Log alerts | log query, service, environment, VM or cluster, container, request id, trace id, deploy id, error class and message, rate over the window |

For `GCP-062`, retuning a threshold is a PATCH on the condition with the baseline stated in the announcement; removing a duplicate or noisy policy deletes a detection path and is confirmed individually with the policy body quoted.

## Build dashboards

For `GCP-070`, `GCP-071`. Dashboards come last, after routing and policies exist; a dashboard is not an alert and never closes an alerting finding. Author the layout JSON per critical service (uptime, pressure, LB traffic, error-log rate side by side), announce it, then:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
DASH_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)/checkout-dashboard.json"  # the announced layout
DASH_NAME="checkout service overview"   # displayName inside the file
gcloud monitoring dashboards create --project "$GCP_PROJECT" --config-from-file="$DASH_FILE"
gcloud monitoring dashboards list --project "$GCP_PROJECT" --format=json \
  | jq -e --arg dn "$DASH_NAME" 'any(.[]; .displayName == $dn)'
```

Expected: exit 0. Rollback: `gcloud monitoring dashboards delete` with the created resource name, verified by absence.

## Plan out-of-scope changes

For `GCP-030`, `GCP-040`, `GCP-043`, `GCP-053`, and every Ops Agent install from [Gate memory and disk](#gate-memory-and-disk-on-the-ops-agent). No command in this section executes; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, maintenance window if any, and a named owner. GKE telemetry enablement and Ops Agent installs are controlled rollouts on surfaces this skill does not own; backend health checks, get-health IAM grants, sink routing, firewall, DNS, and certificate work can affect traffic or log delivery and deserve their own approval cycle. Recording the plan here keeps the finding traceable without smuggling a cluster change through a "monitoring tweak" approval.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact command or payload applied; channel label values never included>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (delivery proof waits, Ops Agent installs, cluster and LB plans), and a fresh `/scoutflo:audit-gcp` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Policy created before its channel exists | Order discipline: channels, then policies, then dashboards; a policy with zero channels fails its own verify |
| Local gcloud config "fixed" to reach the project | Never `gcloud config set`; explicit `--project` and the documented auth paths only |
| Policy shipped whose filter matches zero series | Run the series probe on the exact filter before every create; zero series stops the announcement |
| Memory or disk policy created ahead of the agent | Per-VM agent proof gates creation; unproven VMs go to the plan section, not the API |
| Uptime check created for an unverified target | Capture a live 200 from the exact host and path immediately before create |
| Logs metric created from an unmatched filter | `gcloud logging read` gate first; empty output stops the section |
| PATCH without updateMask rewrites the whole policy | Every PATCH names its updateMask; the full-object backup is for restore, not for blind re-PUT |
| Channel label values leak into announcements or records | Announce display names and types; sensitive labels ride unechoed variables into payload files that stay local |
| Verification code success closes GCP-004 | Two levels recorded separately; only an observed Monitoring-generated notification closes delivery |
| Batch continues past a failed create | Mid-batch failure rule: stop, re-fetch the failed object, re-announce the remainder |
| Deletion slipped into a batch approval | Channels, policies, checks, and snooze cancellations are deleted only with individual confirmation and the body quoted |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Cluster or VM change smuggled in as monitoring work | Write scope is the Monitoring plane; everything else becomes a plan with a named owner |
