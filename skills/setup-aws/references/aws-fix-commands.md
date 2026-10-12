# setup-aws: Fix Command Cookbook

Runnable payloads for every write-capable section of [SKILL.md](../SKILL.md). Every block here is stateless: it redeclares every variable it uses, never assumes an earlier block ran in the same shell. Placeholder values are examples; replace them with the real IDs and ARNs captured from the audit run before announcing. Thresholds and windows are examples, tune to your workloads.

## 0. Conventions

Every block wraps `aws` the same way as `audit-aws`, explicit `--profile`/`--region`, never the ambient default:

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile
AWS_REGION_CFG="us-east-1"    # aws.region
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

`aws` CLI flag names shift across versions: check the subcommand's `--help` before announcing, and if your installed version differs from what is written here, stop and re-announce with the corrected flags.

## 1. Add CloudWatch alarms (AWS-001 to AWS-006)

Backup any alarm you are about to update (create-only alarms have nothing to back up; put a note in the change record instead):

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"   # from the audit's alarm inventory, or a new name you are about to create
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# Keep the first backup of the day: re-running after the change must not overwrite the prior state.
[ -s "${BACKUP_DIR}/alarm-${ALARM_NAME}.json" ] \
  || aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json > "${BACKUP_DIR}/alarm-${ALARM_NAME}.json"
test -s "${BACKUP_DIR}/alarm-${ALARM_NAME}.json" && echo "backup: ${BACKUP_DIR}/alarm-${ALARM_NAME}.json"
```

Per-resource `put-metric-alarm` templates (examples, tune thresholds per workload):

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
DB_ID="db-main"          # RDS instance identifier
RDS_CPU_WARN_PCT="80"    # example warning tier
RDS_WINDOW="300"         # seconds

# RDS CPU (repeat for DatabaseConnections and FreeableMemory with their own thresholds)
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "prod-${DB_ID}-cpu-warning" \
  --alarm-description "PROD RDS ${DB_ID} WARNING cpu above ${RDS_CPU_WARN_PCT}% for ${RDS_WINDOW}s | capture CPU chart, connections, slow queries" \
  --namespace "AWS/RDS" --metric-name CPUUtilization \
  --dimensions "Name=DBInstanceIdentifier,Value=${DB_ID}" \
  --statistic Average --period "$RDS_WINDOW" --evaluation-periods 2 \
  --threshold "$RDS_CPU_WARN_PCT" --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN" --ok-actions "$SNS_TOPIC_ARN"

# EC2 StatusCheckFailed
INSTANCE_ID="i-0123456789abcdef0"
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "prod-${INSTANCE_ID}-status-check-failed" \
  --alarm-description "PROD EC2 ${INSTANCE_ID} CRITICAL system/instance status check failed | capture instance console output, recent deploy, LB health" \
  --namespace "AWS/EC2" --metric-name StatusCheckFailed \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic Maximum --period 60 --evaluation-periods 2 \
  --threshold 0 --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"

# ALB 5xx ratio (metric math example: needs put-metric-alarm --metrics for a ratio; single-metric form shown for target 5xx count)
LB_NAME="app/prod-alb/1234567890abcdef"
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "prod-${LB_NAME##*/}-5xx" \
  --alarm-description "PROD ALB ${LB_NAME} WARNING elevated 5xx count | capture target health, deploy window, backend error logs" \
  --namespace "AWS/ApplicationELB" --metric-name HTTPCode_Target_5XX_Count \
  --dimensions "Name=LoadBalancer,Value=${LB_NAME}" \
  --statistic Sum --period 300 --evaluation-periods 2 \
  --threshold 25 --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"

# Verify any of the above:
aws_cli cloudwatch describe-alarms --alarm-names "prod-${DB_ID}-cpu-warning" --output json \
  | jq -e '.MetricAlarms[0] | (.ActionsEnabled == true) and ((.AlarmActions // []) | length >= 1)'
```

Expected: final `jq -e` exits 0. Fixing an `AWS-004` INSUFFICIENT_DATA alarm is the same `put-metric-alarm` call with the corrected `--dimensions` value; re-announce the diff between the backed-up dimension and the corrected one. **Restore, the worked pair for this section:**

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the alarm lives in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
ALARM_NAME="<alarm-name>"          # the alarm this setup created or updated
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the backup step (its setup-<date>/backups folder)
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$ALARM_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day the backup ran" >&2; exit 1; }
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
if jq -e '.MetricAlarms | length == 0' "$BACKUP_FILE" > /dev/null; then
  # The alarm did not exist before: restore by deletion.
  aws_cli cloudwatch delete-alarms --alarm-names "$ALARM_NAME"
  aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json | jq -e '.MetricAlarms | length == 0'
else
  # Re-put the exact prior definition: every PutMetricAlarm input the backup holds.
  RESTORE_FILE="${BACKUP_FILE%.json}.restore.json"
  jq '.MetricAlarms[0] | {AlarmName, AlarmDescription, ActionsEnabled, OKActions, AlarmActions, InsufficientDataActions,
      MetricName, Namespace, Statistic, ExtendedStatistic, Dimensions, Period, Unit, EvaluationPeriods,
      DatapointsToAlarm, Threshold, ComparisonOperator, TreatMissingData, EvaluateLowSampleCountPercentile,
      Metrics, ThresholdMetricId} | with_entries(select(.value != null))' "$BACKUP_FILE" > "$RESTORE_FILE"
  aws_cli cloudwatch put-metric-alarm --cli-input-json "file://${RESTORE_FILE}"
  aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
    | jq -e --slurpfile b "$BACKUP_FILE" '[.MetricAlarms[0], $b[0].MetricAlarms[0]]
        | map({Dimensions, AlarmActions, OKActions, Threshold, Period, EvaluationPeriods, ComparisonOperator, TreatMissingData})
        | .[0] == .[1]'
fi
```

Expected: `true`, from the deletion check or from the restored alarm matching its backup on dimensions, actions, threshold, period, evaluation periods, comparison, and missing-data treatment.

Dashboards (`AWS-005`). Create only when no dashboard of that name exists, so the rollback's delete can never remove one your team built:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
DASHBOARD_NAME="checkout-overview"   # <service>-overview
DASHBOARD_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/checkout-dashboard.json"   # the announced body
[ -s "$DASHBOARD_FILE" ] || { echo "No dashboard body at ${DASHBOARD_FILE}" >&2; exit 1; }
aws_cli cloudwatch list-dashboards --dashboard-name-prefix "$DASHBOARD_NAME" --output json \
  | jq -e --arg n "$DASHBOARD_NAME" 'all(.DashboardEntries[]?; .DashboardName != $n)' > /dev/null \
  || { echo "A dashboard named ${DASHBOARD_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
aws_cli cloudwatch put-dashboard --dashboard-name "$DASHBOARD_NAME" --dashboard-body "file://${DASHBOARD_FILE}"
aws_cli cloudwatch get-dashboard --dashboard-name "$DASHBOARD_NAME" --output json | jq -e '.DashboardBody | length > 0'
```

Expected: an empty `DashboardValidationMessages` list, then `true`. Rollback, in its own fresh shell:

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the dashboard was created in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
DASHBOARD_NAME="<dashboard-name>"  # the dashboard this setup created
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$DASHBOARD_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
aws_cli cloudwatch delete-dashboards --dashboard-names "$DASHBOARD_NAME"
aws_cli cloudwatch list-dashboards --dashboard-name-prefix "$DASHBOARD_NAME" --output json \
  | jq -e --arg n "$DASHBOARD_NAME" 'all(.DashboardEntries[]?; .DashboardName != $n)'
```

Expected: `true`.

## 2. Fix alert routing (AWS-010, AWS-011, AWS-012, AWS-014)

Severity-tiered topic creation, backup-before-write, subscribe, verify, **restore pair**:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
TOPIC_NAME="prod-critical-alerts"        # <environment>-<severity>-alerts naming pattern
ALERT_EMAIL="oncall@example.org"         # the recipient your team actually watches
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"

# 1. Backup (GET-before-write): capture existing topics so a restore knows what existed.
#    Keep the first one of the day: create-topic returns an existing same-named topic, and the
#    restore must be able to tell a topic your team already had from one this setup made.
[ -s "${BACKUP_DIR}/sns-topics-before.json" ] || aws_cli sns list-topics --output json > "${BACKUP_DIR}/sns-topics-before.json"

# 2. Create the topic (announced first), then subscribe:
TOPIC_ARN="$(aws_cli sns create-topic --name "$TOPIC_NAME" --output json | jq -r '.TopicArn')"
echo "created: ${TOPIC_ARN}"
SUB_ARN="$(aws_cli sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" --output json | jq -r '.SubscriptionArn')"
echo "subscription: ${SUB_ARN}"

# 3. Verify: a real subscription exists, even while it is PendingConfirmation (email requires
#    a human click; that is why AWS-011 checks the *literal* SubscriptionArn value at audit time).
aws_cli sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json \
  | jq -e --arg e "$ALERT_EMAIL" 'any(.Subscriptions[]; .Endpoint == $e)'
```

Expected: exit 0. Email and SMS subscriptions still need a human to click the confirmation link before `SubscriptionArn` stops reading the literal string `PendingConfirmation`; state that as a pending item with an owner, the same as DO's channel-bound-webhook caveat. Attach the new topic to an existing alarm's `AlarmActions` by re-running `put-metric-alarm` with the backed-up parameters plus the new ARN appended (never drop existing actions).

**Restore, worked pair:**

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the topic lives in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
TOPIC_ARN="<topic-arn>"            # the "created:" value from the block above
SUB_ARN="<subscription-arn>"       # the "subscription:" value; may be the literal string PendingConfirmation
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the change (its setup-<date>/backups folder)
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$TOPIC_ARN" "$SUB_ARN"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/sns-topics-before.json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the change" >&2; exit 1; }
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
# An unconfirmed email/SMS subscription's ARN is the literal string PendingConfirmation, and
# unsubscribe on it fails live with "InvalidParameter: An ARN must have at least 6 elements, not 1".
case "$SUB_ARN" in PendingConfirmation|"pending confirmation") CONFIRMED="no" ;; *) CONFIRMED="yes" ;; esac
if jq -e --arg t "$TOPIC_ARN" 'any(.Topics[]?; .TopicArn == $t)' "$BACKUP_FILE" > /dev/null; then
  # The topic existed before this setup: remove only the subscription it added, never the topic.
  if [ "$CONFIRMED" = "yes" ]; then
    aws_cli sns unsubscribe --subscription-arn "$SUB_ARN"
    aws_cli sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json \
      | jq -e --arg s "$SUB_ARN" 'all(.Subscriptions[]?; .SubscriptionArn != $s)'
  else
    echo "Topic kept. The pending subscription cannot be removed while unconfirmed: ask its recipient not to confirm it."
  fi
else
  # This setup created the topic: deleting it removes every subscription on it, pending or not.
  aws_cli sns delete-topic --topic-arn "$TOPIC_ARN"
  aws_cli sns list-topics --output json | jq -e --arg t "$TOPIC_ARN" 'all(.Topics[]?; .TopicArn != $t)'
fi
```

Expected: `true`, from the subscription gone from a topic your team already had, or the topic gone when this setup created it. Confirmed live: `sns delete-topic` alone is sufficient cleanup for a topic this setup created even when the subscription was never confirmed, since deleting the topic removes every subscription on it, pending or not. `AWS-012` (severity tiering): create separate `<env>-critical-alerts` and `<env>-warning-alerts` topics rather than routing every severity into one; re-point alarms per severity using the same attach step.

`AWS-014`: enable the existing EventBridge rule that routes alarm state changes:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
RULE_NAME="alarm-state-to-oncall"   # the disabled rule from the audit evidence
aws_cli events describe-rule --name "$RULE_NAME" --output json | jq -e '.State == "DISABLED"'
aws_cli events enable-rule --name "$RULE_NAME"
aws_cli events describe-rule --name "$RULE_NAME" --output json | jq -e '.State == "ENABLED"'
```

Expected: `true` twice: the rule was disabled before, and is enabled now. Rollback, in its own fresh shell:

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the rule lives in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
RULE_NAME="<rule-name>"            # the rule this setup enabled
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$RULE_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
aws_cli events disable-rule --name "$RULE_NAME"
aws_cli events describe-rule --name "$RULE_NAME" --output json | jq -e '.State == "DISABLED"'
```

Expected: `true`.

## 3. Prove alert delivery (AWS-013)

Two levels, recorded separately, mirroring DO's webhook-smoke-test-versus-observed-event split:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-critical-alerts"
# 1. Smoke test: announce this exact publish first and get confirmation; it posts a visible
#    message to every confirmed subscriber on the topic.
aws_cli sns publish --topic-arn "$TOPIC_ARN" \
  --subject "Controlled routing test from setup-aws" \
  --message "Controlled routing test from setup-aws. Safe to ignore." \
  --output json | jq -r '.MessageId'
```

Expected: a `MessageId`. This proves the topic can deliver to its confirmed subscribers, nothing more. Level 2, an observed CloudWatch-generated notification, uses alarm history, never a fabricated incident:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"
aws_cli cloudwatch describe-alarm-history --alarm-name "$ALARM_NAME" --history-item-type StateUpdate --max-records 5 --output json \
  | jq '[.AlarmHistoryItems[] | {timestamp: .Timestamp, summary: .HistorySummary}]'
```

Expected: at least one `ALARM` transition a human confirms reached the topic's destination. An empty history keeps `AWS-013` at `configured`, a pending item owned by the on-call lead, never `validated-live` from the smoke test alone.

## 4. Add compute health alarms (AWS-020 to AWS-026)

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"
CLUSTER="prod-cluster"; SERVICE="checkout"
LAMBDA_NAME="checkout-webhook"
LAMBDA_ERROR_RATE_PCT="5"   # example, percent of invocations

# ECS desired-vs-running gap
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "prod-ecs-${SERVICE}-running-count" \
  --alarm-description "PROD ECS ${SERVICE} WARNING running task count below desired | capture service events, task stop reasons, recent deploy" \
  --namespace "ECS/ContainerInsights" --metric-name RunningTaskCount \
  --dimensions "Name=ClusterName,Value=${CLUSTER}" "Name=ServiceName,Value=${SERVICE}" \
  --statistic Minimum --period 300 --evaluation-periods 2 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"

# Lambda errors (repeat for Throttles, ConcurrentExecutions, Duration on latency-sensitive functions)
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "prod-lambda-${LAMBDA_NAME}-errors" \
  --alarm-description "PROD Lambda ${LAMBDA_NAME} WARNING error rate above ${LAMBDA_ERROR_RATE_PCT}% | capture recent invocations, error logs, dependency health, recent deploy" \
  --namespace "AWS/Lambda" --metric-name Errors \
  --dimensions "Name=FunctionName,Value=${LAMBDA_NAME}" \
  --statistic Sum --period 300 --evaluation-periods 2 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"

aws_cli cloudwatch describe-alarms --alarm-names "prod-lambda-${LAMBDA_NAME}-errors" --output json \
  | jq -e '.MetricAlarms[0].ActionsEnabled == true'
```

Expected: exit 0. EKS Container Insights enablement (`AWS-023`) and ASG `HealthCheckType`/`HealthCheckGracePeriod` edits (`AWS-021`) are controlled rollouts per the four change-risk classes: enabling Container Insights installs a CloudWatch agent add-on across the cluster, and flipping an ASG's health-check type can trigger AWS to replace instances it now judges unhealthy. Neither executes here; both go to the change record as a plan with a named owner, EC2/ECS/Lambda alarm creation proceeds independently. X-Ray sampling rules (`AWS-026`) are read-only review, no write in this skill.

## 5. Harden managed databases (AWS-030 to AWS-034)

Backup-before-write, non-failover config change, alarms, **restore pair**:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
DB_ID="db-main"
BACKUP_RETENTION_DAYS="7"     # example, tune to your recovery-point objective
MAX_ALLOCATED_STORAGE_GB="500"  # example ceiling for storage autoscaling
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"

# 1. Backup (GET-before-write). Keep the first one of the day so a re-run never overwrites the prior state:
[ -s "${BACKUP_DIR}/rds-${DB_ID}.json" ] \
  || aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json > "${BACKUP_DIR}/rds-${DB_ID}.json"
test -s "${BACKUP_DIR}/rds-${DB_ID}.json" && echo "backup: ${BACKUP_DIR}/rds-${DB_ID}.json"

# 2. Write: backup retention and storage autoscaling apply without a failover or reboot
#    (unlike Multi-AZ conversion, which is traffic-impacting and stays plan-only, see below).
aws_cli rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --backup-retention-period "$BACKUP_RETENTION_DAYS" \
  --max-allocated-storage "$MAX_ALLOCATED_STORAGE_GB" \
  --apply-immediately

# 3. Verify:
aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json \
  | jq -e --argjson r "$BACKUP_RETENTION_DAYS" --argjson m "$MAX_ALLOCATED_STORAGE_GB" \
      '.DBInstances[0] | (.BackupRetentionPeriod == $r) and (.MaxAllocatedStorage == $m)'
```

Expected: exit 0. **Restore, run as written when the change must be undone:**

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the instance lives in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
DB_ID="<db-instance-id>"           # the instance this setup changed
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the backup step (its setup-<date>/backups folder)
ALLOW_BACKUP_DELETION="no"         # yes only after announcing that restoring retention 0 deletes every automated backup
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$DB_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/rds-${DB_ID}.json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day the backup ran" >&2; exit 1; }
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
PREV_RETENTION="$(jq -er '.DBInstances[0].BackupRetentionPeriod' "$BACKUP_FILE")"
[ "$PREV_RETENTION" != "0" ] || [ "$ALLOW_BACKUP_DELETION" = "yes" ] \
  || { echo "The prior retention is 0: restoring it turns automated backups off and deletes them all. Announce that, then set ALLOW_BACKUP_DELETION=yes" >&2; exit 1; }
PREV_MAX_STORAGE="$(jq -r '.DBInstances[0].MaxAllocatedStorage // empty' "$BACKUP_FILE")"
# No ceiling in the backup means autoscaling was off: turn it off again by setting the ceiling to
# the storage allocated now (it may have grown since the backup).
[ -n "$PREV_MAX_STORAGE" ] || PREV_MAX_STORAGE="$(aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].AllocatedStorage' --output text)"
aws_cli rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --backup-retention-period "$PREV_RETENTION" \
  --max-allocated-storage "$PREV_MAX_STORAGE" \
  --apply-immediately
aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json \
  | jq -e --argjson r "$PREV_RETENTION" '.DBInstances[0].BackupRetentionPeriod == $r'
```

Expected: `true`. Then CPU/connections/freeable-memory/replication-lag alarms follow the same `put-metric-alarm` shape as section 1, metric names `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReplicaLag` (the last only on read replicas), dimensions `Name=DBInstanceIdentifier,Value=<id>`. `AWS-030` Multi-AZ conversion is traffic-impacting (triggers a brief failover) and never executes here: record it as a plan with current state, blast radius, maintenance window, and a named owner.

## 6. Fix uptime coverage (AWS-040 to AWS-043)

Verify the live target before creating anything watching it, same discipline as `audit-aws` and the DO/GCP setup skills:

```bash
set -eu
TARGET_HOST="www.example.com"   # the exact host the check will watch
TARGET_PATH="/healthz"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${TARGET_HOST}${TARGET_PATH}")" || code="000"
echo "GET https://${TARGET_HOST}${TARGET_PATH} -> ${code}"
```

Expected: `200` right now; anything else stops this section. Then create and verify:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
TARGET_HOST="www.example.com"
TARGET_PATH="/healthz"
CHECK_INTERVAL="30"   # example seconds; Route53 accepts 10 or 30

HC_ID="$(aws_cli route53 create-health-check --caller-reference "checkout-prod-$(date -u +%s)" \
  --health-check-config "FullyQualifiedDomainName=${TARGET_HOST},Port=443,Type=HTTPS,ResourcePath=${TARGET_PATH},RequestInterval=${CHECK_INTERVAL},FailureThreshold=3" \
  --output json | jq -r '.HealthCheck.Id')"
echo "created: ${HC_ID}"
aws_cli route53 get-health-check --health-check-id "$HC_ID" --output json \
  | jq -e --arg h "$TARGET_HOST" '.HealthCheck.HealthCheckConfig.FullyQualifiedDomainName == $h'
```

Expected: exit 0. A Route53 health check alone has no destination; also create a CloudWatch alarm on its `HealthCheckStatus` metric (`Namespace=AWS/Route53, MetricName=HealthCheckStatus, Dimensions=Name=HealthCheckId,Value=<HC_ID>, Statistic=Minimum, Threshold=1, ComparisonOperator=LessThanThreshold`) using the section 1 shape, and attach the SNS topic from [Fix alert routing](#2-fix-alert-routing-aws-010-aws-011-aws-012-aws-014). For `AWS-041`/`AWS-043`, add a CloudWatch alarm on the target group's `UnHealthyHostCount` (`Namespace=AWS/ApplicationELB` or `AWS/NetworkELB`) rather than editing the target group's own health-check parameters: changing an ALB/NLB target group's health-check path, interval, or threshold can eject currently-healthy targets from rotation, which is traffic-impacting and stays out of this skill's write scope; record that edit as a plan with a named owner instead. Synthetics canary alarms (`AWS-042`) follow the same `put-metric-alarm` shape against `SuccessPercent`.

Rollback, in its own fresh shell (same explicit profile and region as every block here, never the ambient default):

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the create block ran with
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
HC_ID="<health-check-id>"          # the id the create block printed as "created:"
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$HC_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
aws_cli route53 delete-health-check --health-check-id "$HC_ID"
aws_cli route53 get-health-check --health-check-id "$HC_ID" 2>&1 | grep -c NoSuchHealthCheck
```

Expected: `1` (`NoSuchHealthCheck`). Signed in to any other account, the block stops before the delete.

## 7. Enable account observability (AWS-050, AWS-051, AWS-055 write-capable; AWS-052 to AWS-054 plan-only)

Decision-gated, same as DO's logsink section: name the backend, retention, redaction, and owner before shipping.

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
LOG_GROUP="/ecs/checkout"                   # from the audit's critical-log-group list
DEST_ARN="arn:aws:logs:us-east-1:123456789012:destination:central-sink"   # the named central sink
RETENTION_DAYS="365"                        # example, tune to your compliance and cost posture
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"

# Key the backup by the full group name (groups sharing a last path segment must not collide),
# and keep the first one of the day so a re-run never overwrites the prior state.
GROUP_KEY="$(printf '%s' "$LOG_GROUP" | tr -c 'A-Za-z0-9._-' '_')"
GROUP_BACKUP="${BACKUP_DIR}/loggroup-${GROUP_KEY}.json"
[ -s "$GROUP_BACKUP" ] || aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json > "$GROUP_BACKUP"
jq -e --arg g "$LOG_GROUP" 'any(.logGroups[]; .logGroupName == $g)' "$GROUP_BACKUP" > /dev/null \
  || { echo "Log group ${LOG_GROUP} not found" >&2; exit 1; }
# The rollback deletes the central-sink filter, so never put one over a filter that already has that name.
aws_cli logs describe-subscription-filters --log-group-name "$LOG_GROUP" --output json \
  | jq -e 'all(.subscriptionFilters[]?; .filterName != "central-sink")' > /dev/null \
  || { echo "${LOG_GROUP} already has a central-sink filter: announce an edit of it instead" >&2; exit 1; }
aws_cli logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$RETENTION_DAYS"
aws_cli logs put-subscription-filter --log-group-name "$LOG_GROUP" --filter-name "central-sink" \
  --filter-pattern "" --destination-arn "$DEST_ARN"
aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json \
  | jq -e --argjson r "$RETENTION_DAYS" '.logGroups[0].retentionInDays == $r'
aws_cli logs describe-subscription-filters --log-group-name "$LOG_GROUP" --output json \
  | jq -e 'any(.subscriptionFilters[]; .filterName == "central-sink")'
```

Expected: both `jq -e` calls exit 0. Rollback removes the filter and restores the backed-up retention, in its own fresh shell:

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="<region>"          # aws.region: the region the log group lives in
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"         # aws.account_id: the account the live-safety gate printed
LOG_GROUP="<log-group-name>"       # the log group changed above
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the change (its setup-<date>/backups folder)
for v in "$AWS_REGION_CFG" "$AWS_ACCOUNT" "$LOG_GROUP"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
GROUP_KEY="$(printf '%s' "$LOG_GROUP" | tr -c 'A-Za-z0-9._-' '_')"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/loggroup-${GROUP_KEY}.json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the change" >&2; exit 1; }
# A group missing from its backup is an error, never a sign that it had no retention.
jq -e --arg g "$LOG_GROUP" 'any(.logGroups[]; .logGroupName == $g)' "$BACKUP_FILE" > /dev/null \
  || { echo "${LOG_GROUP} is not in ${BACKUP_FILE}; refusing to guess its retention" >&2; exit 1; }
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
# After a mid-batch stop the filter may never have been added: remove it only when present.
if aws_cli logs describe-subscription-filters --log-group-name "$LOG_GROUP" --output json \
     | jq -e 'any(.subscriptionFilters[]?; .filterName == "central-sink")' > /dev/null; then
  aws_cli logs delete-subscription-filter --log-group-name "$LOG_GROUP" --filter-name central-sink
fi
PREV="$(jq -r --arg g "$LOG_GROUP" '.logGroups[] | select(.logGroupName == $g) | .retentionInDays // empty' "$BACKUP_FILE")"
# The group is in the backup, so an absent retentionInDays means "Never expire".
if [ -n "$PREV" ]; then
  aws_cli logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$PREV"
else
  aws_cli logs delete-retention-policy --log-group-name "$LOG_GROUP"
fi
aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json \
  | jq -e --arg g "$LOG_GROUP" --arg p "$PREV" '[.logGroups[] | select(.logGroupName == $g) | ((.retentionInDays // "") | tostring)] == [$p]'
aws_cli logs describe-subscription-filters --log-group-name "$LOG_GROUP" --output json \
  | jq -e 'all(.subscriptionFilters[]?; .filterName != "central-sink")'
```

Expected: `true` twice: retention back to the backed-up value, and no `central-sink` filter left.

`AWS-052` (CloudTrail), `AWS-053` (AWS Config recorder), and `AWS-054` (VPC Flow Logs) are account- or VPC-wide controlled rollouts per the four change-risk classes: they change what the account observes about itself and each deserves its own review outside this skill. Record each as a plan (current state, proposed target, blast radius, owner); never `aws cloudtrail update-trail`, `aws cloudtrail start-logging`, `aws configservice start-configuration-recorder`, or `aws ec2 create-flow-logs` from this skill. `AWS-055` is the decision record itself: backend, retention, redaction, and owner, captured in the change record even when the technical write above already ran.

## 8. Cost guidance commands (read-only, never executed here)

Reference only, for [Plan cost optimizations](../SKILL.md#plan-cost-optimizations): `aws compute-optimizer get-ec2-instance-recommendations`, `aws compute-optimizer get-rds-database-recommendations`, `aws ce get-savings-plans-coverage`, `aws ce get-reservation-coverage`. Full read shapes are in [audit-aws's aws-cost-checks.md](../../audit-aws/references/aws-cost-checks.md); nothing in this section 8 or in `#plan-cost-optimizations` ever mutates a resource.
