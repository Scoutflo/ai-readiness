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
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json > "${BACKUP_DIR}/alarm-${ALARM_NAME}.json"
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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"   # step-1 backup
# Empty backup (alarm did not exist before) restores by deletion:
if jq -e '.MetricAlarms | length == 0' "$BACKUP_FILE" >/dev/null 2>&1; then
  aws_cli cloudwatch delete-alarms --alarm-names "$ALARM_NAME"
  echo "restored: alarm did not exist before, deleted"
else
  # Non-empty backup restores by re-putting the exact prior parameters.
  jq -r '.MetricAlarms[0] | [.AlarmName, .Namespace, .MetricName, .Statistic, (.Period|tostring), (.EvaluationPeriods|tostring), (.Threshold|tostring), .ComparisonOperator] | @tsv' "$BACKUP_FILE"
  echo "re-run put-metric-alarm with these exact prior values, then verify with describe-alarms"
fi
```

Dashboards (`AWS-005`): `aws cloudwatch put-dashboard --dashboard-name "<service>-overview" --dashboard-body file://dashboard.json`, verified with `aws cloudwatch get-dashboard --dashboard-name ... | jq -e '.DashboardBody | length > 0'`. Rollback: `aws cloudwatch delete-dashboards --dashboard-names "<name>"`.

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
aws_cli sns list-topics --output json > "${BACKUP_DIR}/sns-topics-before.json"

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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-critical-alerts"   # the topic created above
SUB_ARN="arn:aws:sns:us-east-1:123456789012:prod-critical-alerts:abc-123"   # the subscription created above; may still be the literal string PendingConfirmation
# Only call unsubscribe when the subscription was actually confirmed; an unconfirmed
# email/SMS subscription's ARN is the literal string PendingConfirmation, not a real ARN,
# and unsubscribe on it fails live with "InvalidParameter: An ARN must have at least
# 6 elements, not 1". Deleting the topic removes pending subscriptions along with it,
# so skipping unsubscribe in that case is correct, not a shortcut.
if [ "$SUB_ARN" != "PendingConfirmation" ] && [ "$SUB_ARN" != "pending confirmation" ]; then
  aws_cli sns unsubscribe --subscription-arn "$SUB_ARN"
fi
aws_cli sns delete-topic --topic-arn "$TOPIC_ARN"
aws_cli sns list-topics --output json | jq -e --arg t "$TOPIC_ARN" '[.Topics[] | select(.TopicArn == $t)] | length == 0'
```

Expected: exit 0, the topic absent from the re-fetched list. Confirmed live: `sns delete-topic` alone is sufficient cleanup even when the subscription was never confirmed, since deleting the topic removes every subscription on it, pending or not. `AWS-012` (severity tiering): create separate `<env>-critical-alerts` and `<env>-warning-alerts` topics rather than routing every severity into one; re-point alarms per severity using the same attach step. `AWS-014`: for EventBridge rules targeting alarm state changes, `aws events enable-rule --name "<rule>"` and verify with `aws events describe-rule --name "<rule>" | jq -e '.State == "ENABLED"'`; rollback is `aws events disable-rule --name "<rule>"`.

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

# 1. Backup (GET-before-write):
aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json > "${BACKUP_DIR}/rds-${DB_ID}.json"
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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
DB_ID="db-main"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/rds-${DB_ID}.json"   # step-1 backup
PREV_RETENTION="$(jq -r '.DBInstances[0].BackupRetentionPeriod' "$BACKUP_FILE")"
PREV_MAX_STORAGE="$(jq -r '.DBInstances[0].MaxAllocatedStorage // 0' "$BACKUP_FILE")"
aws_cli rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --backup-retention-period "$PREV_RETENTION" \
  --max-allocated-storage "$PREV_MAX_STORAGE" \
  --apply-immediately
aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json \
  | jq -e --argjson r "$PREV_RETENTION" '.DBInstances[0].BackupRetentionPeriod == $r'
```

Expected: exit 0. Then CPU/connections/freeable-memory/replication-lag alarms follow the same `put-metric-alarm` shape as section 1, metric names `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReplicaLag` (the last only on read replicas), dimensions `Name=DBInstanceIdentifier,Value=<id>`. `AWS-030` Multi-AZ conversion is traffic-impacting (triggers a brief failover) and never executes here: record it as a plan with current state, blast radius, maintenance window, and a named owner.

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
  --health-check-config "IPAddress=,FullyQualifiedDomainName=${TARGET_HOST},Port=443,Type=HTTPS,ResourcePath=${TARGET_PATH},RequestInterval=${CHECK_INTERVAL},FailureThreshold=3" \
  --output json | jq -r '.HealthCheck.Id')"
echo "created: ${HC_ID}"
aws_cli route53 get-health-check --health-check-id "$HC_ID" --output json \
  | jq -e --arg h "$TARGET_HOST" '.HealthCheck.HealthCheckConfig.FullyQualifiedDomainName == $h'
```

Expected: exit 0. A Route53 health check alone has no destination; also create a CloudWatch alarm on its `HealthCheckStatus` metric (`Namespace=AWS/Route53, MetricName=HealthCheckStatus, Dimensions=Name=HealthCheckId,Value=<HC_ID>, Statistic=Minimum, Threshold=1, ComparisonOperator=LessThanThreshold`) using the section 1 shape, and attach the SNS topic from [Fix alert routing](#2-fix-alert-routing-aws-010-aws-011-aws-012-aws-014). For `AWS-041`/`AWS-043`, add a CloudWatch alarm on the target group's `UnHealthyHostCount` (`Namespace=AWS/ApplicationELB` or `AWS/NetworkELB`) rather than editing the target group's own health-check parameters: changing an ALB/NLB target group's health-check path, interval, or threshold can eject currently-healthy targets from rotation, which is traffic-impacting and stays out of this skill's write scope; record that edit as a plan with a named owner instead. Synthetics canary alarms (`AWS-042`) follow the same `put-metric-alarm` shape against `SuccessPercent`. Rollback: `aws route53 delete-health-check --health-check-id "$HC_ID"`, verified by a subsequent `get-health-check` returning `NoSuchHealthCheck`.

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

aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json > "${BACKUP_DIR}/loggroup-$(basename "$LOG_GROUP").json"
aws_cli logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days "$RETENTION_DAYS"
aws_cli logs put-subscription-filter --log-group-name "$LOG_GROUP" --filter-name "central-sink" \
  --filter-pattern "" --destination-arn "$DEST_ARN"
aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json \
  | jq -e --argjson r "$RETENTION_DAYS" '.logGroups[0].retentionInDays == $r'
aws_cli logs describe-subscription-filters --log-group-name "$LOG_GROUP" --output json \
  | jq -e 'any(.subscriptionFilters[]; .filterName == "central-sink")'
```

Expected: both `jq -e` calls exit 0. Rollback: `aws logs delete-subscription-filter --log-group-name "$LOG_GROUP" --filter-name central-sink`, and restore retention from the backup with `aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days <value from backup>` (or `aws logs delete-retention-policy` if the backup shows `retentionInDays` was absent, meaning "Never expire"). `AWS-052` (CloudTrail), `AWS-053` (AWS Config recorder), and `AWS-054` (VPC Flow Logs) are account- or VPC-wide controlled rollouts per the four change-risk classes: they change what the account observes about itself and each deserves its own review outside this skill. Record each as a plan (current state, proposed target, blast radius, owner); never `aws cloudtrail update-trail`, `aws cloudtrail start-logging`, `aws configservice start-configuration-recorder`, or `aws ec2 create-flow-logs` from this skill. `AWS-055` is the decision record itself: backend, retention, redaction, and owner, captured in the change record even when the technical write above already ran.

## 8. Cost guidance commands (read-only, never executed here)

Reference only, for [Plan cost optimizations](../SKILL.md#plan-cost-optimizations): `aws compute-optimizer get-ec2-instance-recommendations`, `aws compute-optimizer get-rds-database-recommendations`, `aws ce get-savings-plans-coverage`, `aws ce get-reservation-coverage`. Full read shapes are in [audit-aws's aws-cost-checks.md](../../audit-aws/references/aws-cost-checks.md); nothing in this section 8 or in `#plan-cost-optimizations` ever mutates a resource.
