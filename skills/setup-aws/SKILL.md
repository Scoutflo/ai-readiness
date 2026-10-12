---
name: setup-aws
description: Guided hardening of AWS observability from audit-aws findings; fixes CloudWatch alarms, SNS routing, RDS backups, uptime alarms, and log retention and forwarding, announcing each change, waiting for confirmation, then verifying live. Use when the user asks to fix an AWS-NNN finding, wire AWS alert routing, or add CloudWatch alarms. Do not use for read-only assessment (use audit-aws), for LGTM or Grafana on EKS (use setup-lgtm or setup-grafana), to change Alertmanager routing (use setup-lgtm), or for AWSOPT-* cost findings (never automated).
disable-model-invocation: true
---

# setup-aws

Fixes reliability findings from an `audit-aws` run. Input is one or more finding IDs from the latest `./scoutflo-audits/aws/<date>/findings.json` (`aws/<label>/<date>/` for a labeled target); you usually arrive here from a finding's `remediation` pointer, for example `setup-aws#add-cloudwatch-alarms`.

| Finding ID | Fix section |
| --- | --- |
| AWS-001 to AWS-007, AWS-060 to AWS-064 | [Add CloudWatch alarms](#add-cloudwatch-alarms) |
| AWS-010, AWS-011, AWS-012, AWS-014, AWS-065 | [Fix alert routing](#fix-alert-routing) |
| AWS-013 | [Prove alert delivery](#prove-alert-delivery) |
| AWS-020 to AWS-028 | [Add compute health alarms](#add-compute-health-alarms) |
| AWS-030 to AWS-035 | [Harden managed databases](#harden-managed-databases) |
| AWS-040 to AWS-043 | [Fix uptime coverage](#fix-uptime-coverage) |
| AWS-050 to AWS-056 | [Enable account observability](#enable-account-observability) |
| AWSOPT-001 to AWSOPT-011 | [Plan cost optimizations](#plan-cost-optimizations) (read-only guidance, no write) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**v1 is reliability-fix only.** This skill writes CloudWatch alarms and dashboards, SNS topics and subscriptions, CloudWatch Logs retention and subscription filters, Route53 health checks, the enabled state of an existing EventBridge rule that routes alarm state changes, and two RDS config fields that never fail over the instance (backup retention, storage-autoscaling ceiling). It never writes anything against an `AWSOPT-*` finding: no resize, no deletion, no Reserved Instance or Savings Plan purchase. Deleting or resizing live infrastructure to save money is a materially different risk profile than fixing a missing alarm, and mixing the two would blur the backup/restore and mid-batch-failure guarantees this skill's change protocol depends on. That decision is deliberate and out of scope to revisit here.

Also out of write scope, always, per the same four change-risk classes `audit-aws` uses: RDS Multi-AZ conversion, ASG/ECS desired-count changes, EC2 instance-type resize, security group/VPC/DNS/IAM changes, enabling Container Insights, turning on CloudTrail/AWS Config/VPC Flow Logs account-wide, and editing an ALB/NLB target group's own health-check parameters. Each of those becomes a written plan with a named owner inside the relevant fix section, never an execution here.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the command with real values filled in, its risk class, and its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one resource at a time. If reality forces a different change (the CLI rejects a flag, a value differs from the backup), stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `jq -e` or a captured exit code. A write is unverified until a read proves it.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

## The four change-risk classes

Same classes `audit-aws` scores against; every announcement in this skill names its class.

| Class | In this skill | Extra gate |
| --- | --- | --- |
| Read-only | snapshots, verification reads, everything in [Plan cost optimizations](#plan-cost-optimizations) | none |
| Monitoring-plane write | Create/update a CloudWatch alarm or dashboard, create/subscribe an SNS topic, set CloudWatch Logs retention or a subscription filter, create a Route53 health check, enable or disable an existing EventBridge rule, the RDS storage-autoscaling ceiling and backup retention | announce and confirm; turning RDS automated backups on or off (retention 0 to N, or back) also causes a brief outage, so the announcement names that outage and the window you run it in |
| Controlled rollout | Enable Container Insights, turn on CloudTrail/AWS Config/VPC Flow Logs account-wide, edit an ASG's health-check type or grace period | out of `setup-aws`'s write scope; plan only, recorded with a named owner |
| Traffic-impacting | RDS Multi-AZ conversion, ASG/ECS desired-count changes, EC2 resize, security group/VPC/DNS/IAM changes, editing a live target group's health-check parameters, any `AWSOPT-*` resize or deletion | out of write scope everywhere; plan only, never automated |

- ❌ `The finding says "missing Multi-AZ," so run rds modify-db-instance --multi-az under the same batch approval as the CloudWatch alarms.`
- ✅ `Multi-AZ conversion is traffic-impacting (triggers a brief failover); it goes to the change record as a plan with current state, blast radius, and a named owner, never an executed command in this skill.`

## Doctor gate

Elevated tier: this skill mutates CloudWatch, SNS, CloudWatch Logs, Route53, and RDS state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Minimum scope | Tier |
| --- | --- | --- | --- |
| AWS | `aws.account_id` and `aws.region` (both required here), optional `aws.profile`; with a labeled `aws:` list, `SCOUTFLO_TARGET` names the item | write policy covering `cloudwatch:PutMetricAlarm`/`PutDashboard`/`DeleteAlarms`/`DeleteDashboards`, `sns:CreateTopic`/`Subscribe`/`Unsubscribe`/`DeleteTopic`/`Publish`, `logs:PutRetentionPolicy`/`DeleteRetentionPolicy`/`PutSubscriptionFilter`/`DeleteSubscriptionFilter`, `events:EnableRule`/`DisableRule`, `route53:CreateHealthCheck`/`DeleteHealthCheck`, `rds:ModifyDBInstance` (scoped to backup/storage fields only if your policy supports resource-level condition keys), plus the read-only `Describe*`/`List*`/`Get*` set `audit-aws` already documents | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # If you run prod and nonprod, you may have no default toolkit.yaml, only named variants
  # (toolkit-prod.yaml, toolkit-nonprod.yaml). They are listed so you can pick one, but an
  # environment is never auto-picked: changing the wrong one is worse than asking.
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done || true)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
for bin in aws curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# The target comes from toolkit.yaml through the shared enumerator, never typed by hand: the one
# aws block, or the SCOUTFLO_TARGET item of a labeled list (never auto-picked from several).
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
[ "${AWS_N:-0}" -ge 1 ] || { echo "no aws target configured in $CFG; run /scoutflo:connect"; exit 1; }
AWS_IDX=0
if [ "$AWS_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$AWS_N" -gt 1 ]; }; then
  AWS_IDX=""; _i=0
  while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$AWS_IDX" ] || { echo "set SCOUTFLO_TARGET to one of the aws labels in $CFG:"; sh "$TT" "$CFG" aws labels | sed 's/^/  - /'; exit 1; }
fi
AWS_ACCOUNT=$(sh "$TT" "$CFG" aws get "$AWS_IDX" account_id)    # aws.account_id
AWS_PROFILE_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" profile)   # aws.profile; empty means the active credential chain
AWS_REGION_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" region)     # aws.region
[ -n "$AWS_ACCOUNT" ] && [ -n "$AWS_REGION_CFG" ] \
  || { echo "set aws.account_id and aws.region for this target in $CFG (this skill changes live resources); run /scoutflo:connect"; exit 1; }

aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}

STS_OUT="$(aws_cli sts get-caller-identity --output json)"
[ -n "$STS_OUT" ] || { echo "sts get-caller-identity printed no output; the AWS CLI is broken or unauthenticated"; exit 1; }
echo "identity: $(echo "$STS_OUT" | jq -r '.Arn')"
aws_cli cloudwatch describe-alarms --max-records 1 >/dev/null
echo "doctor gate: pass, identity resolved and CloudWatch reachable"
```

Expected: the identity line prints and the `describe-alarms` call exits 0. Elevated write scope cannot be introspected cheaply and this gate never performs a real write to test for it: the doctor gate stays read-only by design, exactly like every sibling setup skill, so that no AWS action of any kind happens before the Live-safety gate below has confirmed which account is live. The first real write of the run is therefore the scope test: a denial on the first announced-and-confirmed change means the identity lacks the write permission for that action. Stop, report which permission is missing (the table above names each required action), point at `/scoutflo:connect`, and do not keep trying other writes to find one that works. These blocks never assume `aws.role_env` themselves; to act through a role, point `aws.profile` at a profile that assumes it, and the Live-safety gate checks the account that profile resolves to.

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` and `skills/doctor/scripts/doctor.sh` run the same read-only identity and CloudWatch-reachability probes (search `doctor.sh` for `# --- aws (aws CLI identity, not a static bearer token) ---`) that gate `audit-aws`; running doctor first is a fast fail before this skill's own copy of the same checks even starts.

## Live-safety gate

Independent of the doctor gate and of anything the operator claims: resolve the target account from `toolkit.yaml` itself, then compare it against what `aws sts get-caller-identity` actually resolves live. The comparison value comes from the config file, never from an echo of what was typed:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Read the target from toolkit.yaml by command, with the same selection as the doctor gate.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CONFIG" aws kind); AWS_N=$(sh "$TT" "$CONFIG" aws count)
[ "${AWS_N:-0}" -ge 1 ] || { echo "no aws target configured in $CONFIG; run /scoutflo:connect"; exit 1; }
AWS_IDX=0
if [ "$AWS_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$AWS_N" -gt 1 ]; }; then
  AWS_IDX=""; _i=0
  while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CONFIG" aws label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$AWS_IDX" ] || { echo "live-safety gate failed: set SCOUTFLO_TARGET to one of the aws labels in $CONFIG:"; sh "$TT" "$CONFIG" aws labels | sed 's/^/  - /'; exit 1; }
fi
AWS_LABEL=$(sh "$TT" "$CONFIG" aws label "$AWS_IDX")
AWS_ACCOUNT=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" account_id)    # aws.account_id
AWS_PROFILE_CFG=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" profile)   # aws.profile; empty means the active credential chain
AWS_REGION_CFG=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" region)     # aws.region
[ -n "$AWS_ACCOUNT" ] || { echo "live-safety gate failed: target '${AWS_LABEL}' sets no aws.account_id in $CONFIG; a skill that changes live resources must assert the account, so set it (run /scoutflo:connect) and re-run"; exit 1; }
[ -n "$AWS_REGION_CFG" ] || { echo "live-safety gate failed: target '${AWS_LABEL}' sets no aws.region in $CONFIG; every change here names its region, so set it (run /scoutflo:connect) and re-run"; exit 1; }

aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}

STS_OUT="$(aws_cli sts get-caller-identity --output json)"
RESOLVED_ACCOUNT="$(echo "$STS_OUT" | jq -r '.Account')"
RESOLVED_ARN="$(echo "$STS_OUT" | jq -r '.Arn')"
echo "identity: ${RESOLVED_ARN}"
echo "aws target: ${AWS_LABEL} profile: ${AWS_PROFILE_CFG:-<credential-chain>} region: ${AWS_REGION_CFG}"
echo "resolved account: ${RESOLVED_ACCOUNT} config account: ${AWS_ACCOUNT}"
[ "$RESOLVED_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "live-safety gate failed: sts resolved account '${RESOLVED_ACCOUNT}', config names '${AWS_ACCOUNT}'; stop: fix the credentials or aws.profile, or correct aws.account_id, then re-run"; exit 1; }
echo "live-safety gate: pass, target confirmed; use this profile and region in every block below"
```

The gate reads `aws.account_id`, `aws.profile`, and `aws.region` from `toolkit.yaml` through the shared enumerator every time it runs, never from a prior block or from what an operator remembers switching to, and it stops when the target names no account. With several `aws` targets it acts only on the one `SCOUTFLO_TARGET` names. The gate cannot pass on the wrong target by construction: it is a live API call compared against the config file, not a printed value a human eyeballs. Never proceed on "probably the right account" or "I already switched profiles", and re-run the gate whenever the credentials or `SCOUTFLO_TARGET` change: the write blocks below name the profile and region it printed but do not re-check the account (every rollback does). Every resource this skill touches is addressed by the exact ID or ARN captured from the audit run, never by name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
# audit-aws writes <audit-dir>/aws/<date>/ for one aws block and <audit-dir>/aws/<label>/<date>/
# for a labeled list; pick the target the same way the live-safety gate does.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CONFIG" aws kind); AWS_N=$(sh "$TT" "$CONFIG" aws count)
[ "${AWS_N:-0}" -ge 1 ] || { echo "no aws target configured in $CONFIG; run /scoutflo:connect"; exit 1; }
AWS_IDX=0
if [ "$AWS_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$AWS_N" -gt 1 ]; }; then
  AWS_IDX=""; _i=0
  while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CONFIG" aws label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$AWS_IDX" ] || { echo "set SCOUTFLO_TARGET to one of the aws labels in $CONFIG"; exit 1; }
fi
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/$(sh "$TT" "$CONFIG" aws label "$AWS_IDX")"; else AWS_SEG="aws"; fi
# Audit runs only: date-named folders that hold a findings.json. This skill's own setup-<date>/
# folder, runs/, and label folders never match; the glob sorts, so the last match is the latest.
LATEST_RUN=""
for d in "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/; do
  if [ -f "${d}findings.json" ]; then LATEST_RUN="$d"; fi
done
[ -n "$LATEST_RUN" ] || { echo "no audit run found under ${AWS_SEG}/; run /scoutflo:audit-aws first"; exit 1; }
echo "findings: ${LATEST_RUN}findings.json"
# Suppressed findings are covered by an exemption and blocked ones were never assessed (unlock the
# evidence and re-run the audit); neither enters the plan, and neither does any AWSOPT-* finding.
jq -r '.findings[] | select(.area != "cost-optimization")
  | select((.lifecycle // "") != "suppressed" and (.status // "") != "blocked")
  | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
jq -r '[.findings[] | select(.lifecycle == "suppressed" or .status == "blocked") | .id]
  | "left out, suppressed or blocked: \(if length == 0 then "none" else join(", ") end)"' "${LATEST_RUN}findings.json"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Reliability findings (`AWS-*`) only; `AWSOPT-*` findings never enter this plan (see [Plan cost optimizations](#plan-cost-optimizations)). Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown. If only some rows are approved, only those execute. A decline ends the run with zero changes. Order safety first: routing before delivery proof, alarms before dashboards, deletions last and confirmed individually.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-fetch the failed object's current state, report what happened, and re-announce the remainder only after the user decides. A half-applied alarm (created but with zero `AlarmActions`) or a half-attached SNS subscription is worse than no change; verify or roll back the failed object before anything else runs.

**Backups are GET-before-write.** Before any write, capture the object's current state into `BACKUP_DIR` with a plain `describe-*`/`get-*` call. Backups may contain resource ARNs and configuration detail; `./scoutflo-audits/` stays out of version control. Every section below names its restore command; three carry a fully worked backup-and-restore pair.

Full command payloads for every section below are in [references/aws-fix-commands.md](references/aws-fix-commands.md); this section states the write scope and risk-class boundary for each, the reference file holds the runnable detail.

### Add CloudWatch alarms

For `AWS-001` to `AWS-007` and `AWS-060` to `AWS-064`. Monitoring-plane writes: `cloudwatch put-metric-alarm` per resource (RDS, ALB/NLB, ASG-fronted EC2, Lambda), `cloudwatch put-dashboard` for coverage gaps, and correcting an `AWS-004` dimension filter by re-putting the alarm with the fixed dimension. Full templates, verification, and a worked backup-and-restore pair are in [references/aws-fix-commands.md section 1](references/aws-fix-commands.md#1-add-cloudwatch-alarms-aws-001-to-aws-006).

Each template checks with `cloudwatch list-metrics` that its exact dimension has live data before it writes. An `AWS-001` or `AWS-004` alarm fix stays `configured` in the change record until `describe-alarms` shows the alarm in `OK` or `ALARM`, which proves its dimension matched a live metric; an alarm still in `INSUFFICIENT_DATA` is a pending item, not a fix.

- ❌ `Created the RDS CPU alarm with no AlarmActions; the finding said "add an alarm," not "route it."`
- ✅ `Created the alarm with AlarmActions pointed at the SNS topic from Fix alert routing and verified ActionsEnabled and the topic; AWS-001 stays configured until the alarm leaves INSUFFICIENT_DATA.`

The rest of this range are monitoring-plane changes by class, recorded in v1 as plans with the alarm's owner and never executed here:

- `AWS-007`: adding a burn-rate configuration changes the Application Signals SLO itself; record the SLO, its goal, and the burn-rate alarm it needs.
- `AWS-060`, `AWS-062`: M-of-N evaluation (`DatapointsToAlarm` below `EvaluationPeriods`) or a longer `Period` changes when the alarm pages, a call for whoever knows the metric's normal noise.
- `AWS-061`: `TreatMissingData`, `InsufficientDataActions`, and low-sample percentile handling decide whether a data gap pages, which the owner settles per metric.
- `AWS-063`: re-enabling a muted alarm pages at once if it sits in `ALARM`, and only its owner knows whether the mute is still wanted.
- `AWS-064`: which child alarms collapse into one composite alarm is a design call; record the candidate group and its owner.

### Fix alert routing

For `AWS-010`, `AWS-011`, `AWS-012`, `AWS-014`, `AWS-065`. Monitoring-plane writes: `sns create-topic` for severity-tiered destinations, `sns subscribe`, and re-pointing an existing alarm's `AlarmActions` at the new topic without dropping existing actions. For `AWS-065`, the same attach step adds the topic to the alarm's `OKActions`, so a return to OK resolves the page downstream. Full commands, the attach step, the worked backup-and-restore pair, and the EventBridge rule-enable path are in [references/aws-fix-commands.md section 2](references/aws-fix-commands.md#2-fix-alert-routing-aws-010-aws-011-aws-012-aws-014).

Email and SMS subscriptions need a human to click the confirmation link before `SubscriptionArn` stops reading the literal string `PendingConfirmation`; that stays a pending item with an owner, never something this skill can complete unattended.

- ❌ `Subscription created, SubscriptionArn shows PendingConfirmation; marked AWS-011 fixed.`
- ✅ `Subscription created; SubscriptionArn is PendingConfirmation until oncall@example.org clicks confirm. AWS-011 stays open, pending item owned by the on-call lead, re-verify after confirmation.`

### Prove alert delivery

For `AWS-013`. Two levels, recorded separately and never conflated, same discipline as the DO and GCP setup skills:

1. **`sns publish` smoke test.** Posts a visible message to the topic's confirmed subscribers; announce it and get confirmation first. Command in [references/aws-fix-commands.md section 3](references/aws-fix-commands.md#3-prove-alert-delivery-aws-013). This proves the topic delivers, nothing more.
2. **Observed CloudWatch-generated notification.** Only a real alarm state transition proves the path end to end: read `cloudwatch describe-alarm-history`, have a human confirm the message arrived, and record the timestamp. Never fabricate load or force an incident to generate one; with no natural event due, `AWS-013` stays `configured` and the wait becomes a pending item with an owner.

- ❌ `Smoke test returned a MessageId, so AWS-013 is fixed and routing is validated-live.`
- ✅ `Smoke test MessageId recorded; AWS-013 stays configured until alarm-history shows a real ALARM transition observed at the destination, pending item owned by the on-call lead.`

### Add compute health alarms

For `AWS-020` to `AWS-028`. Monitoring-plane writes, alarms only: EC2 `StatusCheckFailed`, ECS running tasks below the service's floor, and Lambda error/throttle/concurrency/duration alarms. Templates in [references/aws-fix-commands.md section 4](references/aws-fix-commands.md#4-add-compute-health-alarms-aws-020-to-aws-026).

The ECS alarm (`AWS-022`) reads `ECS/ContainerInsights` metrics, which exist only when Container Insights is already on for that cluster. This skill never turns it on, so on a cluster without it the template stops before writing and the ECS alarm joins the Container Insights plan below.

Two items in this finding range are controlled rollouts, out of write scope here: enabling Container Insights on an EKS cluster (`AWS-023`) installs a CloudWatch agent add-on cluster-wide, and editing an ASG's `HealthCheckType`/`HealthCheckGracePeriod` (`AWS-021`) can make AWS replace instances it now judges unhealthy. Both go to the change record as a plan with the resource list from the finding and a named owner; only the alarm-creation half of this section executes. Two more are plans:

- `AWS-027`: resuming a suspended ASG process (`autoscaling resume-processes`) can make AWS replace or scale instances at once, a controlled rollout like the health-check edit.
- `AWS-028`: adding a dead-letter queue or an on-failure destination changes the Lambda function's configuration and usually its execution role, a controlled rollout whose IAM grant is traffic-impacting.

- ❌ `Flipped the ASG's HealthCheckType from EC2 to ELB to close AWS-021, then created the alarms in the same batch.`
- ✅ `Created the ECS and Lambda alarms this run; filed the ASG health-check-type change as a plan with the platform owner, since it can trigger instance replacement and is a controlled rollout, not a monitoring-plane write.`

### Harden managed databases

For `AWS-030` to `AWS-035`. Two RDS config writes plus alarms: `backup-retention-period` and `max-allocated-storage` via `rds modify-db-instance --apply-immediately`, then CPU/connections/freeable-memory/replication-lag alarms with the same `put-metric-alarm` shape as [Add CloudWatch alarms](#add-cloudwatch-alarms). Neither write reboots or fails over the instance, and the storage ceiling and a retention change between two non-zero values apply with no outage. Turning automated backups on (retention 0 to N, the `AWS-031` fix) or off causes a brief outage, an I/O suspension on the instance, Single-AZ or Multi-AZ: the announcement names that outage and the window you run it in. Full backup-before-write and the worked restore pair are in [references/aws-fix-commands.md section 5](references/aws-fix-commands.md#5-harden-managed-databases-aws-030-to-aws-034).

These writes are for standalone RDS instances. Aurora and DocumentDB keep backup retention on the cluster, which this skill records as a plan rather than changing.

`AWS-030`, Multi-AZ conversion, is traffic-impacting (it triggers a brief failover during conversion) and never executes here: record current state, blast radius, a maintenance window, and a named owner in the change record instead. `AWS-035`, an RDS or DocumentDB event subscription, is a monitoring-plane change by class with no command in v1: record the source type, the categories `describe-event-categories` lists for that engine, the confirmed topic, and an owner as a plan.

- ❌ `Recommend: enable Multi-AZ on db-primary; treated it as a quick monitoring setting alongside the backup-retention change.`
- ✅ `Backup retention and storage autoscaling applied and verified this run, in the window the DB owner accepted for the brief outage of turning backups on. Multi-AZ recorded as a plan: current single-AZ state, brief-failover blast radius during conversion, owner: platform team.`

### Fix uptime coverage

For `AWS-040` to `AWS-043`. Monitoring-plane writes: `route53 create-health-check` on a target verified live this session, plus a CloudWatch alarm on the check's `HealthCheckStatus`, which Route53 publishes only in `us-east-1`, so that alarm and its SNS topic live in `us-east-1` whatever region you configured; for `AWS-041`, a CloudWatch alarm on the target group's `UnHealthyHostCount` metric rather than editing the target group's own health-check settings; for `AWS-042`, an alarm on the canary's `SuccessPercent`. Full commands in [references/aws-fix-commands.md section 6](references/aws-fix-commands.md#6-fix-uptime-coverage-aws-040-to-aws-043).

Editing a live ALB/NLB target group's health-check path, interval, or threshold can eject currently-healthy targets from rotation; that stays traffic-impacting and out of write scope here, recorded as a plan instead of an executed command. The same holds for a target group whose health check is off: `UnHealthyHostCount` stays at zero without one, so turning it on is that plan. `AWS-043`, a check or canary watching a dead or migrated target, is fixed by repointing or retiring it, never by an alarm: a Route53 check that DNS failover routing references changes traffic when edited or deleted (traffic-impacting), and a canary edit is outside this skill's write scope, so both are plans; for an unreferenced Route53 check, create its replacement against the verified live target with the section 6 create and alarm blocks, and record the old check's deletion as a plan for its owner.

- ❌ `Target group has no health check finding; ran elbv2 modify-target-group to add one under the batch approval for the Route53 checks.`
- ✅ `Created the Route53 health check with its HealthCheckStatus alarm in us-east-1, and an UnHealthyHostCount alarm on the target group, this run. Filed the target-group health-check-parameter edit as a plan, since changing live health-check settings can eject healthy targets from rotation.`

### Enable account observability

For `AWS-050` to `AWS-056`. Monitoring-plane writes for `AWS-050`/`AWS-051`: `logs put-subscription-filter` to the team's named central sink and `logs put-retention-policy` on critical log groups, decision-gated on backend/retention/redaction/owner the same way DO's logsink section is. Full commands and the retention rollback are in [references/aws-fix-commands.md section 7](references/aws-fix-commands.md#7-enable-account-observability-aws-050-aws-051-aws-055-write-capable-aws-052-to-aws-054-plan-only).

`AWS-052` (CloudTrail), `AWS-053` (AWS Config recorder), and `AWS-054` (VPC Flow Logs) are account- or VPC-wide controlled rollouts: they change what the account records about itself, out of this skill's write scope. Each is recorded as a plan (current state, proposed target, blast radius, owner). `AWS-055` is the decision record itself, captured in the change record whether or not the technical write above already ran. `AWS-056`, a log anomaly detector stuck in `FAILED` or `PAUSED`, is a monitoring-plane change by class with no command in v1: record the detector, its log groups, and an owner to restart or delete it.

- ❌ `Ran cloudtrail update-trail and start-logging to close AWS-052 alongside the log-retention fix, since it is "just a logging setting."`
- ✅ `Set retention and the subscription filter this run (AWS-050, AWS-051). Filed CloudTrail account-wide enablement as a plan with a named owner; it is a controlled rollout on an account-level control, out of this skill's write scope.`

### Plan cost optimizations

For `AWSOPT-001` to `AWSOPT-011`. **Read-only. No announce/confirm/execute/verify loop runs here, ever, and no command in this section mutates anything.** A reader arriving from this anchor is not getting a guided fix; they are getting pointed at how to act on the finding themselves, outside this skill.

Resizing, deleting, or purchasing against a cost-optimization recommendation is a cost-tradeoff decision only the account owner can make, weighing workload risk against savings; it also carries the same traffic-impacting risk profile as the changes this skill already refuses to automate elsewhere (an RDS resize, an EC2 instance-type change, deleting a volume someone forgot is a cold-standby target). This skill's change protocol, backups, and mid-batch-failure rule are built for "restore reliability," not "remove infrastructure to save money," and mixing the two would blur both guarantees. That scope decision is deliberate and not revisited by asking harder or louder.

To act on an `AWSOPT-*` finding yourself:

1. Open the finding in the latest `audit-aws` report and read its source: Compute Optimizer, Cost Optimization Hub, Cost Explorer, Trusted Advisor, or a plain presence fact (unattached volume, idle load balancer, stopped instance, snapshot sprawl).
2. Review the recommendation directly where AWS presents it: the Compute Optimizer, Cost Optimization Hub, or Cost Explorer console, or read-only via `aws compute-optimizer get-ec2-instance-recommendations` / `aws compute-optimizer get-rds-database-recommendations` / `aws cost-optimization-hub list-recommendations` / `aws ce get-savings-plans-coverage` / `aws ce get-reservation-coverage` (read shapes only, in [references/aws-fix-commands.md section 8](references/aws-fix-commands.md#8-cost-guidance-commands-read-only-never-executed-here) and [audit-aws's aws-cost-checks.md](../audit-aws/references/aws-cost-checks.md)).
3. Resize, delete, or purchase manually, through the AWS Console or your own change-management process, with your own backup and rollback plan for that specific resource.
4. If you want it tracked, record the decision (act now / defer / accept the cost) in the change record with a named owner, the same as any other plan-only item in this skill.

- ❌ `The user asked to "just delete the idle instance to save money," so ran ec2 terminate-instances after a quick confirmation.`
- ✅ `AWSOPT findings are read-only guidance in this skill; pointed the user at Plan cost optimizations and the Compute Optimizer console to make and execute that call themselves.`

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact command applied>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (delivery proof waits, controlled-rollout and traffic-impacting plans, unconfirmed SNS subscriptions), and a fresh `/scoutflo:audit-aws` run to re-score; its delta shows which findings moved to fixed. `AWSOPT-*` findings never appear in this delta as "fixed" by this skill; they close only when the account owner acts outside it and a later audit observes the change.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| `PendingConfirmation` subscription marked as delivery | Read the literal `SubscriptionArn` value; only a real ARN plus an observed CloudWatch-generated notification closes `AWS-013` |
| `sns publish` smoke test recorded as delivery proof | Two levels, recorded separately; only an observed alarm-history transition at the destination closes `AWS-013` |
| Multi-AZ conversion run under the same batch as an alarm fix | Multi-AZ is traffic-impacting by name in the four change-risk classes; it is a plan, never an executed command, whatever else is in the batch |
| Container Insights or ASG health-check-type edited to "just close the finding" | Both are controlled rollouts out of write scope; only the alarm-creation half of Add compute health alarms executes |
| Target-group health-check parameters edited instead of adding an alarm | Editing live health-check settings can eject healthy targets; use an `UnHealthyHostCount` alarm instead, edit the target group only as a recorded plan |
| CloudTrail/Config/Flow Logs enabled to close AWS-052/053/054 | Account- and VPC-wide controls are controlled rollouts; recorded as a plan with a named owner, never executed here |
| `AWSOPT-*` finding "fixed" by resizing or deleting a resource | Cost & Resource Optimization is read-only guidance in this skill by design; point at Plan cost optimizations, never execute a mutating command against it |
| Batch continues past a failed alarm or SNS write | Mid-batch failure rule: stop, re-fetch the failed object, re-announce the remainder |
| Wrong AWS account mutated | The live-safety gate reads `aws.account_id` from `toolkit.yaml` by command and compares it with a live `sts get-caller-identity` call, so it cannot pass on an operator's claim about which profile is active; every block names the profile and region it printed, and every rollback re-checks the live account first |
| `put-metric-alarm` drops existing `AlarmActions` when adding a new topic | Use the attach block: it re-puts the alarm's current definition with the new topic added, never a bare re-put with only the new ARN |
| Second setup run picks its own folder or another target's run as "latest" | Load findings reads only date-named folders holding a `findings.json` under the target segment the live-safety gate selected |
| Route53 health-check alarm created in your configured region | `HealthCheckStatus` exists only in `us-east-1`; create that alarm and its SNS topic there |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Secrets or full ARNs leak into the change record's summary | Account IDs and resource ARNs may appear in local backups and the change record; never in a Slack brief or any external channel |
