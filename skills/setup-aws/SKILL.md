---
name: setup-aws
description: Guided hardening of AWS reliability observability from audit-aws findings; creates and repairs CloudWatch alarms, SNS alert routing, compute health signals, RDS backup/storage-autoscaling config, Route53 and target-group uptime alarms, and CloudWatch Logs forwarding and retention, announcing each change, waiting for confirmation, then verifying live. Use when the user asks to fix an AWS-NNN finding, wire AWS alert routing, add CloudWatch alarms, or harden RDS/EC2/ECS/EKS/Lambda alerting. Do not use for read-only assessment (use audit-aws), for in-cluster LGTM or Grafana on EKS (use setup-lgtm or setup-grafana), for Alertmanager-specific routing (use audit-alert-routing), or to resize, delete, or purchase anything against an AWSOPT-* cost finding (this skill never automates cost writes; see Plan cost optimizations).
disable-model-invocation: true
---

# setup-aws

Fixes reliability findings from an `audit-aws` run. Input is one or more finding IDs from the latest `./scoutflo-audits/aws/<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-aws#add-cloudwatch-alarms`.

| Finding ID | Fix section |
| --- | --- |
| AWS-001 to AWS-006 | [Add CloudWatch alarms](#add-cloudwatch-alarms) |
| AWS-010, AWS-011, AWS-012, AWS-014 | [Fix alert routing](#fix-alert-routing) |
| AWS-013 | [Prove alert delivery](#prove-alert-delivery) |
| AWS-020 to AWS-026 | [Add compute health alarms](#add-compute-health-alarms) |
| AWS-030 to AWS-034 | [Harden managed databases](#harden-managed-databases) |
| AWS-040 to AWS-043 | [Fix uptime coverage](#fix-uptime-coverage) |
| AWS-050 to AWS-055 | [Enable account observability](#enable-account-observability) |
| AWSOPT-001 to AWSOPT-010 | [Plan cost optimizations](#plan-cost-optimizations) (read-only guidance, no write) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**v1 is reliability-fix only.** This skill writes CloudWatch alarms and dashboards, SNS topics and subscriptions, CloudWatch Logs retention and subscription filters, Route53 health checks, and two non-failover RDS config fields (backup retention, storage-autoscaling ceiling). It never writes anything against an `AWSOPT-*` finding: no resize, no deletion, no Reserved Instance or Savings Plan purchase. Deleting or resizing live infrastructure to save money is a materially different risk profile than fixing a missing alarm, and mixing the two would blur the backup/restore and mid-batch-failure guarantees this skill's change protocol depends on. That decision is deliberate and out of scope to revisit here.

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
| Monitoring-plane write | Create/update a CloudWatch alarm or dashboard, create/subscribe an SNS topic, set CloudWatch Logs retention or a subscription filter, create a Route53 health check, RDS backup-retention/storage-autoscaling config | announce and confirm |
| Controlled rollout | Enable Container Insights, turn on CloudTrail/AWS Config/VPC Flow Logs account-wide, edit an ASG's health-check type or grace period | out of `setup-aws`'s write scope; plan only, recorded with a named owner |
| Traffic-impacting | RDS Multi-AZ conversion, ASG/ECS desired-count changes, EC2 resize, security group/VPC/DNS/IAM changes, editing a live target group's health-check parameters, any `AWSOPT-*` resize or deletion | out of write scope everywhere; plan only, never automated |

- ❌ `The finding says "missing Multi-AZ," so run rds modify-db-instance --multi-az under the same batch approval as the CloudWatch alarms.`
- ✅ `Multi-AZ conversion is traffic-impacting (triggers a brief failover); it goes to the change record as a plan with current state, blast radius, and a named owner, never an executed command in this skill.`

## Doctor gate

Elevated tier: this skill mutates CloudWatch, SNS, CloudWatch Logs, Route53, and RDS state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Minimum scope | Tier |
| --- | --- | --- | --- |
| AWS | `aws.account_id`, optional `aws.region`, `aws.profile`, `aws.role_env` | write policy covering `cloudwatch:PutMetricAlarm`/`PutDashboard`/`DeleteAlarms`/`DeleteDashboards`, `sns:CreateTopic`/`Subscribe`/`Unsubscribe`/`DeleteTopic`/`Publish`, `logs:PutRetentionPolicy`/`PutSubscriptionFilter`/`DeleteSubscriptionFilter`, `route53:CreateHealthCheck`/`DeleteHealthCheck`, `rds:ModifyDBInstance` (scoped to backup/storage fields only if your policy supports resource-level condition keys), plus the read-only `Describe*`/`List*`/`Get*` set `audit-aws` already documents | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
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
AWS_ACCOUNT="123456789012"   # aws.account_id
AWS_PROFILE_CFG=""           # aws.profile; empty means the active credential chain
AWS_REGION_CFG="us-east-1"   # aws.region

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

Expected: the identity line prints and the `describe-alarms` call exits 0. Elevated write scope cannot be introspected cheaply and this gate never performs a real write to test for it — the doctor gate stays read-only by design, exactly like every sibling setup skill, so that no AWS action of any kind happens before the Live-safety gate below has confirmed which account is live. The first real write of the run is therefore the scope test: a denial on the first announced-and-confirmed change means the identity lacks the write permission for that action. Stop, report which permission is missing (the table above names the actions and their required actions), point at `/scoutflo:connect`, and do not keep trying other writes to find one that works.

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` and `skills/doctor/scripts/doctor.sh` run the same read-only identity and CloudWatch-reachability probes (search `doctor.sh` for `--- aws ---`) that gate `audit-aws`; running doctor first is a fast fail before this skill's own copy of the same checks even starts.

## Live-safety gate

Independent of the doctor gate and of anything the operator claims: resolve the target account from `toolkit.yaml` itself, then compare it against what `aws sts get-caller-identity` actually resolves live. The comparison value comes from the config file, never from an echo of what was typed:

```bash
set -eu
AWS_ACCOUNT="123456789012"   # aws.account_id
AWS_PROFILE_CFG=""           # aws.profile
AWS_REGION_CFG="us-east-1"   # aws.region

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
echo "resolved account: ${RESOLVED_ACCOUNT} config account: ${AWS_ACCOUNT}"
[ "$RESOLVED_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "live-safety gate failed: sts resolved account '${RESOLVED_ACCOUNT}', config names '${AWS_ACCOUNT}'; stop, this credential points at the wrong account"; exit 1; }
echo "live-safety gate: pass, target confirmed"
```

`AWS_ACCOUNT` is re-read from `toolkit.yaml` in this same block every time, never carried over from a prior block or from what an operator remembers switching to. The gate cannot pass on the wrong target by construction: it is a live API call compared against the config file, not a printed value a human eyeballs. Never proceed on "probably the right account" or "I already switched profiles". Every resource this skill touches is addressed by the exact ID or ARN captured from the audit run, never by name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/*/ 2>/dev/null | grep -v '/runs/' | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-aws first"; exit 1; }
jq -r '.findings[] | select(.area != "cost-optimization") | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
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

**Backups are GET-before-write.** Before any write, capture the object's current state into `BACKUP_DIR` with a plain `describe-*`/`get-*` call. Backups may contain resource ARNs and configuration detail; `./scoutflo-audits/` stays out of version control. Every section below names its restore command; two carry a fully worked backup-and-restore pair.

Full command payloads for every section below are in [references/aws-fix-commands.md](references/aws-fix-commands.md); this section states the write scope and risk-class boundary for each, the reference file holds the runnable detail.

### Add CloudWatch alarms

For `AWS-001` to `AWS-006`. Monitoring-plane writes: `cloudwatch put-metric-alarm` per resource (RDS, ALB/NLB, ASG-fronted EC2, Lambda), `cloudwatch put-dashboard` for coverage gaps, and correcting an `AWS-004` dimension filter by re-putting the alarm with the fixed dimension. Full templates, verification, and a worked backup-and-restore pair are in [references/aws-fix-commands.md section 1](references/aws-fix-commands.md#1-add-cloudwatch-alarms-aws-001-to-aws-006).

- ❌ `Created the RDS CPU alarm with no AlarmActions; the finding said "add an alarm," not "route it."`
- ✅ `Created the alarm with AlarmActions pointed at the SNS topic from Fix alert routing, then verified ActionsEnabled and a non-empty AlarmActions array before marking AWS-001 addressed.`

### Fix alert routing

For `AWS-010`, `AWS-011`, `AWS-012`, `AWS-014`. Monitoring-plane writes: `sns create-topic` for severity-tiered destinations, `sns subscribe`, and re-pointing an existing alarm's `AlarmActions` at the new topic without dropping existing actions. Full commands, the worked backup-and-restore pair, and the EventBridge rule-enable path are in [references/aws-fix-commands.md section 2](references/aws-fix-commands.md#2-fix-alert-routing-aws-010-aws-011-aws-012-aws-014).

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

For `AWS-020` to `AWS-026`. Monitoring-plane writes, alarms only: EC2 `StatusCheckFailed`, ECS desired-vs-running gap, and Lambda error-rate/throttle/concurrency/duration alarms. Templates in [references/aws-fix-commands.md section 4](references/aws-fix-commands.md#4-add-compute-health-alarms-aws-020-to-aws-026).

Two items in this finding range are controlled rollouts, out of write scope here: enabling Container Insights on an EKS cluster (`AWS-023`) installs a CloudWatch agent add-on cluster-wide, and editing an ASG's `HealthCheckType`/`HealthCheckGracePeriod` (`AWS-021`) can make AWS replace instances it now judges unhealthy. Both go to the change record as a plan with the resource list from the finding and a named owner; only the alarm-creation half of this section executes.

- ❌ `Flipped the ASG's HealthCheckType from EC2 to ELB to close AWS-021, then created the alarms in the same batch.`
- ✅ `Created the ECS and Lambda alarms this run; filed the ASG health-check-type change as a plan with the platform owner, since it can trigger instance replacement and is a controlled rollout, not a monitoring-plane write.`

### Harden managed databases

For `AWS-030` to `AWS-034`. Two non-failover RDS config writes plus alarms: `backup-retention-period` and `max-allocated-storage` via `rds modify-db-instance --apply-immediately` (neither triggers a reboot or failover), then CPU/connections/freeable-memory/replication-lag alarms with the same `put-metric-alarm` shape as [Add CloudWatch alarms](#add-cloudwatch-alarms). Full backup-before-write and the worked restore pair are in [references/aws-fix-commands.md section 5](references/aws-fix-commands.md#5-harden-managed-databases-aws-030-to-aws-034).

`AWS-030`, Multi-AZ conversion, is traffic-impacting (it triggers a brief failover during conversion) and never executes here: record current state, blast radius, a maintenance window, and a named owner in the change record instead.

- ❌ `Recommend: enable Multi-AZ on db-primary; treated it as a quick monitoring setting alongside the backup-retention change.`
- ✅ `Backup retention and storage autoscaling applied and verified this run (no failover, apply-immediately). Multi-AZ recorded as a plan: current single-AZ state, brief-failover blast radius during conversion, owner: platform team.`

### Fix uptime coverage

For `AWS-040` to `AWS-043`. Monitoring-plane writes: `route53 create-health-check` on a target verified live this session, plus a CloudWatch alarm on the check's `HealthCheckStatus`; for `AWS-041`/`AWS-043`, a CloudWatch alarm on the target group's `UnHealthyHostCount` metric rather than editing the target group's own health-check settings. Full commands in [references/aws-fix-commands.md section 6](references/aws-fix-commands.md#6-fix-uptime-coverage-aws-040-to-aws-043).

Editing a live ALB/NLB target group's health-check path, interval, or threshold can eject currently-healthy targets from rotation; that stays traffic-impacting and out of write scope here, recorded as a plan instead of an executed command.

- ❌ `Target group has no health check finding; ran elbv2 modify-target-group to add one under the batch approval for the Route53 checks.`
- ✅ `Created the Route53 health check and its UnHealthyHostCount alarm this run. Filed the target-group health-check-parameter edit as a plan, since changing live health-check settings can eject healthy targets from rotation.`

### Enable account observability

For `AWS-050` to `AWS-055`. Monitoring-plane writes for `AWS-050`/`AWS-051`: `logs put-subscription-filter` to the team's named central sink and `logs put-retention-policy` on critical log groups, decision-gated on backend/retention/redaction/owner the same way DO's logsink section is. Full commands and the retention rollback are in [references/aws-fix-commands.md section 7](references/aws-fix-commands.md#7-enable-account-observability-aws-050-aws-051-aws-055-write-capable-aws-052-to-aws-054-plan-only).

`AWS-052` (CloudTrail), `AWS-053` (AWS Config recorder), and `AWS-054` (VPC Flow Logs) are account- or VPC-wide controlled rollouts: they change what the account records about itself, out of this skill's write scope. Each is recorded as a plan (current state, proposed target, blast radius, owner). `AWS-055` is the decision record itself, captured in the change record whether or not the technical write above already ran.

- ❌ `Ran cloudtrail update-trail and start-logging to close AWS-052 alongside the log-retention fix, since it is "just a logging setting."`
- ✅ `Set retention and the subscription filter this run (AWS-050, AWS-051). Filed CloudTrail account-wide enablement as a plan with a named owner; it is a controlled rollout on an account-level control, out of this skill's write scope.`

### Plan cost optimizations

For `AWSOPT-001` to `AWSOPT-010`. **Read-only. No announce/confirm/execute/verify loop runs here, ever, and no command in this section mutates anything.** A reader arriving from this anchor is not getting a guided fix; they are getting pointed at how to act on the finding themselves, outside this skill.

Resizing, deleting, or purchasing against a cost-optimization recommendation is a cost-tradeoff decision only the account owner can make, weighing workload risk against savings; it also carries the same traffic-impacting risk profile as the changes this skill already refuses to automate elsewhere (an RDS resize, an EC2 instance-type change, deleting a volume someone forgot is a cold-standby target). This skill's change protocol, backups, and mid-batch-failure rule are built for "restore reliability," not "remove infrastructure to save money," and mixing the two would blur both guarantees. That scope decision is deliberate and not revisited by asking harder or louder.

To act on an `AWSOPT-*` finding yourself:

1. Open the finding in the latest `audit-aws` report and read its source: Compute Optimizer, Cost Explorer, Trusted Advisor, or a plain presence fact (unattached volume, idle load balancer, stopped instance, snapshot sprawl).
2. Review the recommendation directly where AWS presents it: the Compute Optimizer or Cost Explorer console, or read-only via `aws compute-optimizer get-ec2-instance-recommendations` / `aws compute-optimizer get-rds-database-recommendations` / `aws ce get-savings-plans-coverage` / `aws ce get-reservation-coverage` (read shapes only, in [references/aws-fix-commands.md section 8](references/aws-fix-commands.md#8-cost-guidance-commands-read-only-never-executed-here) and [audit-aws's aws-cost-checks.md](../audit-aws/references/aws-cost-checks.md)).
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
| Wrong AWS account mutated | Live-safety gate resolves `aws.account_id` from `toolkit.yaml` fresh every block and compares against a live `sts get-caller-identity` call; it cannot pass on an operator's claim about which profile is active |
| `put-metric-alarm` drops existing `AlarmActions` when adding a new topic | Always build the actions array from the backup (existing actions plus the new one), never a bare re-put with only the new ARN |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Secrets or full ARNs leak into the change record's summary | Account IDs and resource ARNs may appear in local backups and the change record; never in a Slack brief or any external channel |
