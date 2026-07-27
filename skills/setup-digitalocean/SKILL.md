---
name: setup-digitalocean
description: Guided hardening of DigitalOcean observability from audit-digitalocean findings; provisions alert destinations, uptime checks, App Platform alert rules and health checks, database alert policies, and log forwarding, announcing each change, waiting for confirmation, then verifying live. Use when the user asks to fix a DO-NNN finding, wire DO alert routing, add uptime checks, or harden App Platform or managed-database alerting. Do not use for read-only assessment (use audit-digitalocean) or for DOKS in-cluster stacks (use setup-lgtm).
disable-model-invocation: true
---

# setup-digitalocean

Fixes findings from an `audit-digitalocean` run. Input is one or more finding IDs from the latest `./scoutflo-audits/digitalocean/<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-digitalocean#harden-health-checks`.

| Finding ID | Fix section |
| --- | --- |
| DO-001, DO-002, DO-003, DO-005 | [Fix alert routing](#fix-alert-routing) |
| DO-004 | [Prove alert delivery](#prove-alert-delivery) |
| DO-010 to DO-015 | [Fix uptime coverage](#fix-uptime-coverage) |
| DO-020 to DO-025 | [Add App Platform alerts](#add-app-platform-alerts) |
| DO-030, DO-031 | [Harden health checks](#harden-health-checks) |
| DO-032, DO-033, DO-044, DO-045, DO-046 | [Plan traffic-impacting changes](#plan-traffic-impacting-changes) |
| DO-040 to DO-043, DO-048 | [Set database alert policies](#set-database-alert-policies) |
| DO-047 | [Configure database logsinks](#configure-database-logsinks) |
| DO-050, DO-051, DO-052 | [Enable app log forwarding](#enable-app-log-forwarding) |
| DO-060, DO-061 | [Retire stale monitoring](#retire-stale-monitoring) |
| DO-062 | [Move secret env vars](#move-secret-env-vars) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

In scope: alert destinations and policy text, uptime checks and their alert rules, App Platform alert rules, health checks, log forwarding, database alert policies and logsinks, and retiring stale monitoring. Out of write scope, always: autoscaling, instance counts, database resize or standby nodes, database firewalls, and DNS or domain changes; those are traffic-impacting and get a written plan with an owner, never an execution here.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the command or spec diff with real values filled in, its risk class, and its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one resource at a time. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `jq -e` or a captured HTTP code. A write is unverified until a read proves it.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

## The four change-risk classes

Every announcement names its class; the class decides the ceremony.

| Class | In this skill | Extra gate |
| --- | --- | --- |
| Read-only | snapshots, verification reads | none |
| Non-disruptive write | uptime checks and their alerts, DO Monitoring policy create/update/delete, app alert destination updates, database logsinks | announce and confirm |
| Controlled rollout | any app spec change: alert rules, health checks, log destinations, env types | snapshot first, `propose` validation, one app at a time, staging app before production, `--wait`, endpoint verification |
| Traffic-impacting | autoscaling, instance counts, DB resize or standby, DB firewall, DNS | out of write scope; plan only |

The trap this table exists for: **App Platform spec edits trigger a new deployment.** Adding "just an alert rule" rebuilds and redeploys the app, and a private build failure can take it down. Never bundle a controlled rollout inside a batch approved as "monitoring tweaks".

- ❌ `The user approved "fix the alerting findings", so add health checks to all six apps in one pass.`
- ✅ `Destination updates run as one approved non-disruptive batch; each health check is a controlled rollout announced per app with its spec diff, staging first.`

## Doctor gate

Elevated tier: this skill mutates DO monitoring, uptime, app, and database state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| DigitalOcean | `digitalocean.token_env`, optional `digitalocean.team` | `DIGITALOCEAN_ACCESS_TOKEN` | custom-scoped token with create/update/delete on monitoring, uptime, and apps, plus databases when logsinks are in scope; full-access only when custom scopes are unavailable | elevated |

```bash
set -eu
[ -f "$HOME/.scoutflo/toolkit.yaml" ] || { echo "missing ~/.scoutflo/toolkit.yaml; run /scoutflo:connect"; exit 1; }
for bin in doctl curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# digitalocean.token_env names the variable; presence check only, never print the value.
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set; run /scoutflo:connect"; exit 1; }
doctl account get --format Status --no-header
```

Expected: `active`. The DO API cannot introspect token scopes, so the first write of the run is the scope test: if it returns `403`, stop, report which scope is missing, and point at `/scoutflo:connect`. Do not keep trying other writes to find one that works.

## Live-safety gate

Resolve the target team from `toolkit.yaml` itself, not from a value typed into the block, then compare it against the team `doctl` is actually authenticated against. The comparison value has to come from the config file or the gate can pass on whatever the operator happened to type:

```bash
set -eu
CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve digitalocean.team the same way doctor.sh's cfg() reads two-level
# keys: yq when present, a sed fallback otherwise. "personal" when the key
# is absent, matching doctl's own default.
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CONFIG" >/dev/null 2>&1; then
  DO_TEAM="$(yq -r '.digitalocean.team // "personal"' "$CONFIG")"
else
  DO_TEAM="$(sed -n '/^digitalocean:/,/^[A-Za-z_]/p' "$CONFIG" \
    | sed -n 's/^[[:space:]]\{1,\}team:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]#.*$//' -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/[[:space:]]*$//')"
  [ -n "$DO_TEAM" ] || DO_TEAM="personal"
fi
LIVE_TEAM="$(doctl account get -o json \
  | jq -r '(if type=="array" then .[0] else . end) | .team.uuid // "personal"')"
echo "config target (digitalocean.team): ${DO_TEAM}"
echo "live team (doctl account get):     ${LIVE_TEAM}"
[ "$LIVE_TEAM" = "$DO_TEAM" ] || { echo "STOP: doctl is authenticated to team ${LIVE_TEAM}, but toolkit.yaml names ${DO_TEAM}. Fix DIGITALOCEAN_ACCESS_TOKEN or digitalocean.team before continuing."; exit 1; }
echo "live-safety gate passed: doctl matches the team toolkit.yaml names"
```

Expected: the final line prints and nothing stops the block. `DO_TEAM` is re-read from `toolkit.yaml` in this same block every time, never carried over from a prior block or from what an operator remembers typing, so the gate cannot pass on the wrong target by construction. If the two values differ, stop and report the mismatch; never proceed on "probably the right account". Every app and database in this skill is addressed by ID captured from the audit run, never by name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-digitalocean first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown, except that each controlled-rollout row is re-confirmed at its own announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes. Order safety first: routing fixes before delivery proof, non-disruptive rows before controlled rollouts, deletions last and confirmed individually.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Verify the failed object's current state, report what happened, and re-announce the remainder only after the user decides. For a failed app deployment, first confirm the previous deployment is still active and serving (commands in [Add App Platform alerts](#add-app-platform-alerts)) before touching anything else.

**Backups are GET-before-write.** Before any write, capture the object's current state into `BACKUP_DIR`: the app spec, the policy JSON, the uptime alert list. Backups contain env values and channel names; `./scoutflo-audits/` stays out of version control. Rollback is re-applying the backup; every section names its restore command.

## Fix alert routing

For `DO-001`, `DO-002`, `DO-003`, `DO-005`. Non-disruptive writes: destination and description changes redeploy nothing.

Slack incoming webhooks are channel-bound: the webhook posts to the channel it was installed in, and a payload `channel` field does not re-route it. Fixing wrong-channel routing means installing or obtaining a webhook for the correct channel, then pointing the policy at it. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of DO destinations; they are different webhooks with different jobs.

DO Monitoring policies (databases and other DO Monitoring surfaces). `doctl monitoring alert update` replaces the policy, so announce and pass the full desired flag set, copied from the backup, not only the field you are changing:

```bash
set -eu
POLICY_UUID="your-policy-uuid"                       # from the audit's alert-policies capture
POLICY_TYPE="v1/dbaas/alerts/database_cpu_alerts"    # copy .type from the backup JSON below
POLICY_COMPARE="GreaterThan"                         # copy .compare from the backup
POLICY_VALUE="80"                                    # copy .value from the backup
POLICY_WINDOW="5m"                                   # copy .window from the backup
ENTITY_IDS="your-database-uuid"                      # copy .entities from the backup, comma-joined
ALERT_EMAIL="oncall@example.org"                     # the recipient your team actually watches
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
doctl monitoring alert get "$POLICY_UUID" -o json > "${BACKUP_DIR}/policy-${POLICY_UUID}.json"
doctl monitoring alert update "$POLICY_UUID" \
  --type "$POLICY_TYPE" --compare "$POLICY_COMPARE" --value "$POLICY_VALUE" --window "$POLICY_WINDOW" \
  --entities "$ENTITY_IDS" \
  --description "PROD db-main WARNING cpu above threshold | capture CPU chart, connections, slow queries" \
  --emails "$ALERT_EMAIL"
doctl monitoring alert get "$POLICY_UUID" -o json \
  | jq -e --arg m "$ALERT_EMAIL" '(if type=="array" then .[0] else . end) | .alerts.email | index($m)'
```

Expected: the final `jq -e` exits 0. Slack destinations add `--slack-channels` and `--slack-urls`; the URL goes into a shell variable read from your secret store, is never echoed, and never appears in the announcement (announce the channel name instead). doctl flag names shift across versions: for every write in this skill, check the subcommand's `--help` before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags.

App Platform alert destinations use the destination-only command, which avoids a spec rollout. Write the destinations JSON to a file, announce it with URLs redacted, then:

```bash
set -eu
APP_ID="your-app-id"; ALERT_ID="your-app-alert-id"   # from the audit's per-app alerts capture
DEST_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/dest-${ALERT_ID}.json"
doctl apps update-alert-destinations "$APP_ID" "$ALERT_ID" --app-alert-destinations "$DEST_FILE"
doctl apps list-alerts "$APP_ID" -o json \
  | jq -e --arg a "$ALERT_ID" '[.[] | select(.id == $a)][0] | ((.emails // []) | length) + ((.slack_webhooks // []) | length) >= 1'
```

Expected: exit 0. Rollback for both: re-apply the backed-up destinations the same way.

For `DO-005`, set descriptions to the responder-ready shape: environment, resource, severity tier, metric, threshold and window, then the datapoints to capture first, so the responder can decide between capacity, query pressure, provider incident, and noisy threshold. Per-engine starting rosters (examples, tune per workload):

| Engine | Datapoints to capture first |
| --- | --- |
| PostgreSQL / MySQL | connections, slow queries, locks, replication lag, disk growth rate |
| Redis / Valkey | ops per second, evictions, blocked clients, memory versus maxmemory, failover state |
| MongoDB | slow queries, connections, lock and current-op state, cache pressure, replication state |
| Kafka | consumer lag, under-replicated partitions, broker disk, request latency |
| OpenSearch | cluster status, JVM heap, indexing and search latency, shard health |

App Platform alert rules take no custom text; keep their capture checklist (CPU and memory charts, instance count, restarts, deployment ID and recent deploy status, request and error rate, p95 latency, dependency health) in your runbook instead of forcing a spec rollout to add text.

## Prove alert delivery

For `DO-004`. Two levels, recorded separately and never conflated:

1. **Webhook smoke test.** Posts a visible message to the channel; announce it and get confirmation first. Read the webhook URL into a variable from the backed-up policy JSON without echoing it, then: `code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' --data '{"text":"Controlled routing test from setup-digitalocean. Safe to ignore."}' "$WEBHOOK_URL")"; echo "smoke: ${code}"`. Expected `200`. This proves the webhook accepts a message in its bound channel, nothing more.
2. **DO-generated event.** Only DigitalOcean firing a real alert proves the path: use the next planned deployment's lifecycle alert or a real threshold event, have a human confirm the message arrived in the channel, and record the timestamp. Never fabricate an incident to force one; with no natural event due, `DO-004` stays `configured` and the wait becomes a pending item with an owner.

- ❌ `Smoke test returned 200, so DO-004 is fixed and routing is validated-live.`
- ✅ `Smoke 200 recorded; DO-004 stays configured until the next DO-generated alert is seen in-channel, pending item owned by the on-call lead.`

## Fix uptime coverage

For `DO-010` to `DO-015`. Non-disruptive, but a check against a wrong target pages people at 3am; verify the exact target immediately before creating anything:

```bash
set -eu
TARGET_URL="https://www.example.com/"   # the exact URL the check will watch
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$TARGET_URL")" || code="000"
echo "GET ${TARGET_URL} -> ${code}"
```

Expected: `200` right now. Anything else stops this section: fix the target or the app first, or route ownership questions through the audit's `DO-060` evidence. Then create and verify:

```bash
set -eu
CHECK_NAME="checkout-prod"                 # name it for the service and environment
TARGET_URL="https://www.example.com/"
REGIONS="us_east,eu_west"                  # example, tune to where your users are
ALERT_EMAIL="oncall@example.org"           # the recipient your team actually watches
UPTIME_DOWN_WINDOW="2m"                    # example, tune to your traffic
SSL_EXPIRY_DAYS="21"                       # example
UPTIME_LATENCY_MS="1000"                   # example, set from observed latency
doctl monitoring uptime create "$CHECK_NAME" --target "$TARGET_URL" --type https --regions "$REGIONS"
CHECK_ID="$(doctl monitoring uptime list -o json | jq -r --arg t "$TARGET_URL" '.[] | select(.target == $t) | .id' | head -1)"
[ -n "$CHECK_ID" ] || { echo "check not found after create; stop"; exit 1; }
doctl monitoring uptime alert create "$CHECK_ID" --name "${CHECK_NAME}-down" --type down \
  --period "$UPTIME_DOWN_WINDOW" --emails "$ALERT_EMAIL"
doctl monitoring uptime alert create "$CHECK_ID" --name "${CHECK_NAME}-ssl" --type ssl_expiry \
  --threshold "$SSL_EXPIRY_DAYS" --comparison less_than --period "$UPTIME_DOWN_WINDOW" --emails "$ALERT_EMAIL"
doctl monitoring uptime alert create "$CHECK_ID" --name "${CHECK_NAME}-latency" --type latency \
  --threshold "$UPTIME_LATENCY_MS" --comparison greater_than --period 10m --emails "$ALERT_EMAIL"
doctl monitoring uptime alert list "$CHECK_ID" -o json \
  | jq -e '[.[].type] | (index("down") != null) and (index("ssl_expiry") != null) and (index("latency") != null)'
```

Expected: final `jq -e` exits 0 printing `true`. Slack destinations add `--slack-channels` plus `--slack-urls` with the URL held in an unechoed variable. Rollback: `doctl monitoring uptime delete "$CHECK_ID"` (confirmed live: unlike `doctl monitoring alert delete`, this subcommand has no `-f`/`--force` flag at all — passing `-f` fails with "unknown shorthand flag"; it also needs none, since it deletes immediately with no confirmation prompt), then verify the list no longer contains the target.

## Add App Platform alerts

For `DO-020` to `DO-025`. Controlled rollout: this edits the app spec and triggers a deployment. One app at a time, staging app before production when one exists, and each app is its own announcement.

1. **Snapshot (GET-before-write), run as written:**

```bash
set -eu
APP_ID="your-app-id"   # from the audit inventory
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/app-${APP_ID}-$(date -u +%H%M%S).yaml"
doctl apps spec get "$APP_ID" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "snapshot: $BACKUP_FILE"
```

The spec contains env values (SECRET-type values appear encrypted and round-trip safely on restore). The backup stays local and out of version control.

2. **Edit a copy.** Copy `BACKUP_FILE` to `NEW_SPEC`, add the alert rules: lifecycle rules (`DEPLOYMENT_FAILED`, `DEPLOYMENT_LIVE`, `DOMAIN_FAILED`, `DOMAIN_LIVE`) under top-level `alerts`, resource rules (`CPU_UTILIZATION`, `MEM_UTILIZATION`, `RESTART_COUNT`) under each service's `alerts` with `operator`, `value`, and `window` from the starting set in [audit-digitalocean references section 12](../audit-digitalocean/references/do-checks.md) (examples, tune per workload). Request-rate and p95 rules only when a recorded baseline sets the threshold.

3. **Validate enums before trusting them.** Documented rule names and API-accepted names have diverged; `propose` is the arbiter:

```bash
set -eu
APP_ID="your-app-id"
NEW_SPEC="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/app-${APP_ID}-new.yaml"
doctl apps propose --spec "$NEW_SPEC" --app "$APP_ID" >/dev/null && echo "spec accepted"
```

Expected: `spec accepted`. A rejection names the invalid field or enum; when one rule name is rejected and another spelling is accepted, record both in the change record so future automation uses the accepted one. `propose` validates only; it deploys nothing.

4. **Announce** the `diff -u "$BACKUP_FILE" "$NEW_SPEC"` output, the risk class (controlled rollout, will redeploy), and the rollback. Wait for confirmation on this app specifically.

5. **Execute and verify, run as written:**

```bash
set -eu
APP_ID="your-app-id"
NEW_SPEC="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/app-${APP_ID}-new.yaml"
PUBLIC_URL="https://www.example.com/"   # the app's live URL from the audit inventory
PREV_DEPLOY="$(doctl apps get "$APP_ID" -o json | jq -r '(if type=="array" then .[0] else . end).active_deployment.id')"
doctl apps update "$APP_ID" --spec "$NEW_SPEC" --wait
doctl apps get "$APP_ID" -o json | jq -e --arg prev "$PREV_DEPLOY" \
  '(if type=="array" then .[0] else . end).active_deployment | (.id != $prev) and (.phase == "ACTIVE")'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_URL")"; echo "post-deploy: ${code}"
doctl apps list-alerts "$APP_ID" -o json | jq -e '[.[] | select(.disabled | not) | .rule] | index("DEPLOYMENT_FAILED") != null'
```

Expected: `jq -e` exits 0, post-deploy code `200`, and the new rules listed. If `update --wait` fails or the phase is not `ACTIVE`: stop the batch (mid-batch failure rule), confirm the previous deployment still serves (`active_deployment.id` equals `PREV_DEPLOY` and the endpoint answers), collect the failure from `doctl apps list-deployments "$APP_ID"`, and re-announce before anything else runs.

6. **Rollback, the worked pair for every spec change in this skill:**

```bash
set -eu
APP_ID="your-app-id"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups/app-${APP_ID}-HHMMSS.yaml"  # the snapshot from step 1
PUBLIC_URL="https://www.example.com/"
doctl apps update "$APP_ID" --spec "$BACKUP_FILE" --wait
doctl apps get "$APP_ID" -o json | jq -e '(if type=="array" then .[0] else . end).active_deployment.phase == "ACTIVE"'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_URL")"; echo "post-rollback: ${code}"
```

Expected: `ACTIVE` and `200`. A rollback is itself a deployment; it needs the same announcement it just proved the need for.

## Harden health checks

For `DO-030`, `DO-031`. Controlled rollout, same six steps as [Add App Platform alerts](#add-app-platform-alerts); the delta is the payload and one extra gate: verify the exact path live before it enters the spec. A wrong health check marks a healthy app unhealthy and can restart it in a loop.

```bash
set -eu
PUBLIC_URL="https://www.example.com"   # the app's live URL
HEALTH_PATH="/healthz"                 # the candidate path; must need no auth, Origin, or session
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${PUBLIC_URL}${HEALTH_PATH}")" || code="000"
echo "GET ${PUBLIC_URL}${HEALTH_PATH} -> ${code}"
```

Expected: `200` from a plain unauthenticated GET. A `3xx` to a login page, `401`, `403`, or `404` disqualifies the path; fix the app or pick another path first. Then add to the service in the spec copy, with starting values (examples, tune per service): `http_path` set to the verified path, `initial_delay_seconds: 30`, `period_seconds: 10`, `timeout_seconds: 5`, `failure_threshold: 3`, and continue from step 3 of the previous section.

## Set database alert policies

For `DO-040` to `DO-043` and `DO-048`. Non-disruptive: DO Monitoring policies live outside the cluster config. Take accepted `type` strings from the audit's policy capture or `doctl monitoring alert list` output rather than memory, and validate on create.

```bash
set -eu
DB_UUID="your-database-uuid"        # doctl databases list
DB_WARN_PCT="80"                    # example warning tier, tune per engine and workload
DB_WINDOW="5m"                      # example
ALERT_EMAIL="oncall@example.org"    # the recipient your team actually watches
NEW_UUID="$(doctl monitoring alert create \
  --type "v1/dbaas/alerts/database_cpu_alerts" \
  --compare GreaterThan --value "$DB_WARN_PCT" --window "$DB_WINDOW" \
  --entities "$DB_UUID" \
  --description "PROD db-main WARNING cpu >${DB_WARN_PCT}% for ${DB_WINDOW} | capture CPU chart, connections, slow queries" \
  --emails "$ALERT_EMAIL" -o json | jq -r '(if type=="array" then .[0] else . end).uuid')"
doctl monitoring alert get "$NEW_UUID" -o json \
  | jq -e --arg e "$DB_UUID" '(if type=="array" then .[0] else . end) | (.entities | index($e)) and .enabled'
```

Expected: exit 0. If the `type` string is rejected, list existing policies for the accepted spelling on your account, record the doc-versus-API mismatch, and re-announce; the exact enum set varies by engine. Repeat per metric and tier: warning at `DB_WARN_PCT` and saturation at a higher tier (99 is a common example) for CPU, memory, and disk. Rollback: `doctl monitoring alert delete "$NEW_UUID" -f`, then `jq -e` that the UUID is gone from the list.

For `DO-043`, removing a noisy or duplicate policy deletes a detection path: confirm each deletion individually with the policy body quoted, never inside a batch approval. Keep the named tiers, delete the generic duplicate, and verify:

```bash
set -eu
DUP_UUID="the-duplicate-policy-uuid"
doctl monitoring alert delete "$DUP_UUID" -f
doctl monitoring alert list -o json | jq -e --arg u "$DUP_UUID" '[.[] | select(.uuid == $u)] | length == 0'
```

- ❌ `Deleted three "is running high" policies under the batch approval for routing fixes.`
- ✅ `Announced each duplicate with its metric, threshold, and the named tier that supersedes it; the user confirmed each; deletion verified by absence in the re-fetched list.`

For `DO-048`, where the engine exposes no native policy for a signal (connection saturation, replication lag, slow queries), record the gap and its compensating control in the change record with an owner instead of inventing a policy the surface cannot support.

## Configure database logsinks

For `DO-047`. Non-disruptive write, but decision-gated: name the backend, retention, redaction, index naming, and owner in the announcement, or record `DO-047` as blocked on that decision instead of shipping logs somewhere unowned. Database logsinks support a different destination list from app log forwarding (historically rsyslog, Elasticsearch, OpenSearch); verify the accepted types against current DO docs at run time.

```bash
set -eu
DB_UUID="your-database-uuid"
SINK_NAME="db-main-logs"
doctl databases logsink create "$DB_UUID" --sink-name "$SINK_NAME" --sink-type opensearch \
  --sink-config '{"url":"https://logs.example.com:9200","index_prefix":"db-main"}'
doctl databases logsink list "$DB_UUID" -o json | jq -e --arg n "$SINK_NAME" 'any(.[]; .sink_name == $n)'
```

Expected: exit 0. The sink config carries credentials on some backends; keep them in the config argument from an unechoed variable and out of every announcement and record. Older doctl versions lack the logsink group; use the API route from the audit reference in that case, announced the same way. Rollback: `doctl databases logsink delete "$DB_UUID" <sink-id>` and verify absence.

## Enable app log forwarding

For `DO-050` to `DO-052`. Controlled rollout: `log_destinations` live in the app spec, so this follows the six steps of [Add App Platform alerts](#add-app-platform-alerts) with two additions. First, the same backend decision gate as logsinks: backend, retention, redaction, naming, owner, announced before the diff. Second, credential handling: app log destinations embed their credential (an API key or token) in the spec itself, which means it lands in snapshots and in DO's stored spec. Say so in the announcement, source the value from an unechoed variable when building the spec copy, and never print the rendered destination block. App destinations and database logsinks accept different backends (`DO-052`); do not promise one universal path until both lists are verified against current docs. Verify after rollout: the deployment is `ACTIVE`, the endpoint answers, and log lines appear in the destination backend within one flush interval; the arrival check in the destination is the `jq -e` equivalent here and belongs in the change record.

## Retire stale monitoring

For `DO-060`, `DO-061`. Deleting a check or policy removes a detection path even when the target is a ghost; confirm each deletion individually with the audit evidence quoted (the DNS answer and status code that proved the move). Delete the uptime check (`doctl monitoring uptime delete <check-id>` — no `-f` flag exists for this subcommand, confirmed live; it needs none, it deletes immediately), its alert rules go with it, and any DO Monitoring policy scoped only to the retired resource (`doctl monitoring alert delete <uuid> -f` — this subcommand does support `-f`). Verify each absence with a re-list and `jq -e`. Record where the service actually lives now and who owns its monitoring there; retiring the DO side without naming the new owner trades noise for blindness.

## Move secret env vars

For `DO-062`. Controlled rollout: changing an env var's `type` from `GENERAL` to `SECRET` is a spec edit. Follow the six steps of [Add App Platform alerts](#add-app-platform-alerts); in the spec copy, set `type: SECRET` on each affected key, leaving the value untouched. After the rollout, DO stores the value encrypted and the spec shows it as an encrypted blob. Verify with the redacted env listing (audit reference section 7): every flagged key now reports `SECRET`, asserted with `jq -e`. Rotate any value that sat in plaintext if your policy treats exposure time as compromise; record the rotation as a pending item with an owner, since rotation touches the consuming app's configuration too.

## Plan traffic-impacting changes

For `DO-032`, `DO-033`, `DO-044`, `DO-045`, `DO-046`. No command in this section executes; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, baseline needed (for autoscaling: observed CPU, request, and latency baselines first), maintenance window, and a named owner. Instance counts, standby nodes, resizes, firewall edits, and DNS moves can drop traffic or sever connectivity; they deserve their own change plan and their own approval cycle outside this skill. Backup gaps (`DO-044`) that doctl shows as empty on a backup-capable engine go to the plan with a support-escalation owner.

## Record and wrap up

Append one entry per executed change to `./scoutflo-audits/digitalocean/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact command or spec diff applied>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (delivery proof waits, traffic-impacting plans, rotations), and a fresh `/scoutflo:audit-digitalocean` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| "Just an alert rule" redeploys the app | Classify every change first; any spec field edit is a controlled rollout with snapshot, propose, and per-app confirmation |
| Spec updated from a doc-remembered enum, API rejects mid-rollout | `doctl apps propose` validates before announce; record accepted spellings when they differ from docs |
| Batch continues past a failed deploy | Mid-batch failure rule: stop, confirm the prior deployment still serves, re-announce the remainder |
| Webhook smoke test recorded as delivery proof | Two levels, recorded separately; only an observed DO-generated event closes DO-004 |
| Slack payload channel override trusted | Webhooks are channel-bound; fix routing by installing a webhook in the right channel |
| Uptime check created for an unverified target | Capture a live 200 from the exact target immediately before create |
| Health check added to a path needing auth or Origin | Probe the path with a plain unauthenticated GET first; anything but 200 disqualifies it |
| Policy update silently drops fields | `monitoring alert update` replaces the policy; always pass the full desired flag set from the backup |
| Duplicate policy deleted inside a batch | Deletions are confirmed individually with the policy body quoted |
| Secrets leak via spec snapshots or sink configs | Backups stay out of version control; credentials live in unechoed variables; announcements show channel names and key names only |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Rollback treated as free | A spec rollback is itself a deployment; announce and verify it like any other change |
