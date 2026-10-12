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

Back up every alarm you are about to create or update. For a new alarm the backup records that none existed, which is what lets the restore below delete it, and every alarm write block below refuses to run without it:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"   # from the audit's alarm inventory, or a new name you are about to create
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# Keep the first backup of the day: re-running after the change must not overwrite the prior state.
[ -s "${BACKUP_DIR}/alarm-${ALARM_NAME}.json" ] \
  || aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json > "${BACKUP_DIR}/alarm-${ALARM_NAME}.json"
test -s "${BACKUP_DIR}/alarm-${ALARM_NAME}.json" && echo "backup: ${BACKUP_DIR}/alarm-${ALARM_NAME}.json"
```

Per-resource `put-metric-alarm` templates, one alarm per block so only approved rows run. Each block first checks with `list-metrics` that its exact dimension has live data, since a dimension that matches nothing leaves the alarm in `INSUFFICIENT_DATA` (`AWS-004`). Every number is an example; tune it per workload. RDS CPU (repeat for `DatabaseConnections` and `FreeableMemory` with their own thresholds):

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
DB_ID="db-main"            # RDS instance identifier
RDS_CPU_WARN_PCT="80"      # example warning tier, tune it
RDS_WINDOW="300"           # example, tune it: seconds per evaluation period
RDS_EVAL_PERIODS="2"       # example, tune it: breaching periods before the alarm fires
ALARM_NAME="prod-${DB_ID}-cpu-warning"   # or the existing alarm's name when correcting its dimension (AWS-004)
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "AWS/RDS" --metric-name CPUUtilization \
  --dimensions "Name=DBInstanceIdentifier,Value=${DB_ID}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No CPUUtilization data for ${DB_ID}: check the instance id" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD RDS ${DB_ID} WARNING cpu above ${RDS_CPU_WARN_PCT}% for ${RDS_EVAL_PERIODS}x${RDS_WINDOW}s | capture CPU chart, connections, slow queries" \
  --namespace "AWS/RDS" --metric-name CPUUtilization \
  --dimensions "Name=DBInstanceIdentifier,Value=${DB_ID}" \
  --statistic Average --period "$RDS_WINDOW" --evaluation-periods "$RDS_EVAL_PERIODS" \
  --threshold "$RDS_CPU_WARN_PCT" --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN" --ok-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

EC2 `StatusCheckFailed`:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
INSTANCE_ID="i-0123456789abcdef0"   # the instance from the finding
EC2_PERIOD_SECS="60"       # example, tune it
EC2_EVAL_PERIODS="2"       # example, tune it: failed periods before the alarm fires
ALARM_NAME="prod-${INSTANCE_ID}-status-check-failed"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "AWS/EC2" --metric-name StatusCheckFailed \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No StatusCheckFailed data for ${INSTANCE_ID}: check the instance id" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD EC2 ${INSTANCE_ID} CRITICAL system/instance status check failed | capture instance console output, recent deploy, LB health" \
  --namespace "AWS/EC2" --metric-name StatusCheckFailed \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic Maximum --period "$EC2_PERIOD_SECS" --evaluation-periods "$EC2_EVAL_PERIODS" \
  --threshold 0 --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

ALB target 5xx count (a 5xx ratio needs a metric-math `--metrics` alarm instead). The load balancer publishes 5xx counts only when 5xx responses happen, so the check proves the `LoadBalancer` dimension with any of its metrics, and missing data counts as not breaching:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
LB_NAME="app/prod-alb/1234567890abcdef"   # the load balancer's ARN suffix
ALB_5XX_MAX="25"           # example, tune it to your traffic: 5xx responses per period before paging
ALB_PERIOD_SECS="300"      # example, tune it
ALB_EVAL_PERIODS="2"       # example, tune it
ALARM_NAME="prod-${LB_NAME##*/}-5xx"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "AWS/ApplicationELB" \
  --dimensions "Name=LoadBalancer,Value=${LB_NAME}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No AWS/ApplicationELB data for ${LB_NAME}: check the load balancer's ARN suffix" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD ALB ${LB_NAME} WARNING more than ${ALB_5XX_MAX} target 5xx per ${ALB_PERIOD_SECS}s | capture target health, deploy window, backend error logs" \
  --namespace "AWS/ApplicationELB" --metric-name HTTPCode_Target_5XX_Count \
  --dimensions "Name=LoadBalancer,Value=${LB_NAME}" \
  --statistic Sum --period "$ALB_PERIOD_SECS" --evaluation-periods "$ALB_EVAL_PERIODS" \
  --threshold "$ALB_5XX_MAX" --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

Expected: each block prints `true`; a block that stops at its `list-metrics` check wrote nothing. Fixing an `AWS-004` INSUFFICIENT_DATA alarm is the same block with the existing alarm's name and the corrected `--dimensions` value; re-announce the diff between the backed-up dimension and the corrected one. Until the alarm has evaluated live data, record its `AWS-001` or `AWS-004` fix as `configured`, then re-check:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the alarm's region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"   # each alarm this setup created or corrected
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e '.MetricAlarms | length == 1 and (.[0].StateValue == "OK" or .[0].StateValue == "ALARM")'
```

Expected: `true` once the alarm has evaluated a full period of live data. `false` means it still sits in `INSUFFICIENT_DATA`: the fix stays `configured`, a pending item with the alarm's owner. **Restore, the worked pair for this section:**

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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
TOPIC_NAME="prod-critical-alerts"        # <environment>-<severity>-alerts naming pattern
ALERT_EMAIL="oncall@example.org"         # the recipient your team actually watches
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"

# 1. Backup (GET-before-write): capture existing topics so a restore knows what existed.
#    Keep the first one of the day: create-topic returns an existing same-named topic, and the
#    restore must be able to tell a topic your team already had from one this setup made.
#    Topic lists are per region, so the backup is keyed by region.
TOPICS_BACKUP="${BACKUP_DIR}/sns-topics-before-${AWS_REGION_CFG}.json"
[ -s "$TOPICS_BACKUP" ] || aws_cli sns list-topics --output json > "$TOPICS_BACKUP"

# 2. Create the topic (announced first), then subscribe:
TOPIC_ARN="$(aws_cli sns create-topic --name "$TOPIC_NAME" --output json | jq -r '.TopicArn')"
echo "created: ${TOPIC_ARN}"
# SNS hands back the existing subscription for an endpoint already on the topic, so record the
# subscriptions first: the restore must never remove one your team already had.
SUBS_BACKUP="${BACKUP_DIR}/sns-subs-before-${AWS_REGION_CFG}-${TOPIC_NAME}.json"
[ -s "$SUBS_BACKUP" ] || aws_cli sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json > "$SUBS_BACKUP"
SUB_ARN="$(aws_cli sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$ALERT_EMAIL" --output json | jq -r '.SubscriptionArn')"
echo "subscription: ${SUB_ARN}"

# 3. Verify: a real subscription exists, even while it is PendingConfirmation (email requires
#    a human click; that is why AWS-011 checks the *literal* SubscriptionArn value at audit time).
aws_cli sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json \
  | jq -e --arg e "$ALERT_EMAIL" 'any(.Subscriptions[]; .Endpoint == $e)'
```

Expected: exit 0. Email and SMS subscriptions still need a human to click the confirmation link before `SubscriptionArn` stops reading the literal string `PendingConfirmation`; state that as a pending item with an owner, the same as DO's channel-bound-webhook caveat.

Attach the topic to an existing alarm. `put-metric-alarm` replaces the whole alarm, so this block re-puts the alarm's current definition with only the topic added and never drops an existing action. Run the section 1 backup block for the alarm first; the section 1 restore is this step's rollback:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the alarm's region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
ALARM_NAME="prod-db-main-cpu-warning"   # the existing alarm to re-point
TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-critical-alerts"   # the "created:" value from the block above
ACTION_LIST="AlarmActions"              # AlarmActions, or OKActions to also send the resolve (AWS-065)
case "$ACTION_LIST" in AlarmActions|OKActions) ;; *) echo "ACTION_LIST must be AlarmActions or OKActions" >&2; exit 1 ;; esac
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)"
[ -s "${WORK_DIR}/backups/alarm-${ALARM_NAME}.json" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first" >&2; exit 1; }
mkdir -p "${WORK_DIR}/edits"
EDIT_FILE="${WORK_DIR}/edits/alarm-${ALARM_NAME}.json"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg l "$ACTION_LIST" --arg t "$TOPIC_ARN" '.MetricAlarms
      | if length == 1 then .[0] else error("no metric alarm by that name") end
      | {AlarmName, AlarmDescription, ActionsEnabled, OKActions, AlarmActions, InsufficientDataActions,
         MetricName, Namespace, Statistic, ExtendedStatistic, Dimensions, Period, Unit, EvaluationPeriods,
         DatapointsToAlarm, Threshold, ComparisonOperator, TreatMissingData, EvaluateLowSampleCountPercentile,
         Metrics, ThresholdMetricId} | with_entries(select(.value != null))
      | .[$l] = ((.[$l] // []) | if any(.[]; . == $t) then . else . + [$t] end)' > "$EDIT_FILE"
aws_cli cloudwatch put-metric-alarm --cli-input-json "file://${EDIT_FILE}"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --slurpfile want "$EDIT_FILE" '[.MetricAlarms[0], $want[0]]
      | map({AlarmActions: ((.AlarmActions // []) | sort), OKActions: ((.OKActions // []) | sort),
             Dimensions, Threshold, Period, EvaluationPeriods, ActionsEnabled})
      | .[0] == .[1]'
```

Expected: `true`: the live alarm carries every action it had plus the topic, with its dimensions, threshold, and evaluation unchanged.

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
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/sns-topics-before-${AWS_REGION_CFG}.json"
SUBS_BACKUP="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-${BACKUP_DATE}/backups/sns-subs-before-${AWS_REGION_CFG}-${TOPIC_ARN##*:}.json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day of the change" >&2; exit 1; }
LIVE_ACCOUNT="$(aws_cli sts get-caller-identity --query Account --output text)"
[ "$LIVE_ACCOUNT" = "$AWS_ACCOUNT" ] || { echo "Signed in to account ${LIVE_ACCOUNT}, not ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
# An unconfirmed email/SMS subscription's ARN is the literal string PendingConfirmation, and
# unsubscribe on it fails live with "InvalidParameter: An ARN must have at least 6 elements, not 1".
case "$SUB_ARN" in PendingConfirmation|"pending confirmation") CONFIRMED="no" ;; *) CONFIRMED="yes" ;; esac
if jq -e --arg t "$TOPIC_ARN" 'any(.Topics[]?; .TopicArn == $t)' "$BACKUP_FILE" > /dev/null; then
  # The topic existed before this setup: remove only the subscription it added, never the topic.
  [ -s "$SUBS_BACKUP" ] || { echo "No subscription backup at ${SUBS_BACKUP}; refusing to guess which subscription is new" >&2; exit 1; }
  if jq -e --arg s "$SUB_ARN" 'any(.Subscriptions[]?; .SubscriptionArn == $s)' "$SUBS_BACKUP" > /dev/null; then
    echo "Subscription existed before this setup: nothing to remove."
  elif [ "$CONFIRMED" = "yes" ]; then
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

Expected: `true`, from the subscription gone from a topic your team already had (or a note that it was already there before the setup), or the topic gone when this setup created it. Confirmed live: `sns delete-topic` alone is sufficient cleanup for a topic this setup created even when the subscription was never confirmed, since deleting the topic removes every subscription on it, pending or not. `AWS-012` (severity tiering): create separate `<env>-critical-alerts` and `<env>-warning-alerts` topics rather than routing every severity into one; re-point alarms per severity using the same attach step.

`AWS-014`: enable the existing EventBridge rule that routes alarm state changes:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-critical-alerts"
# 1. Smoke test: announce this exact publish first and get confirmation; it posts a visible
#    message to every confirmed subscriber on the topic.
aws_cli sns publish --topic-arn "$TOPIC_ARN" \
  --subject "Controlled routing test from setup-aws" \
  --message "Controlled routing test from setup-aws. Safe to ignore." \
  --output json | jq -er '.MessageId'
```

Expected: a `MessageId`. This proves the topic can deliver to its confirmed subscribers, nothing more. Level 2, an observed CloudWatch-generated notification, uses alarm history, never a fabricated incident:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
ALARM_NAME="prod-db-main-cpu-warning"
aws_cli cloudwatch describe-alarm-history --alarm-name "$ALARM_NAME" --history-item-type StateUpdate --max-records 5 --output json \
  | jq -e '[.AlarmHistoryItems[] | {timestamp: .Timestamp, summary: .HistorySummary}]'
```

Expected: at least one `ALARM` transition a human confirms reached the topic's destination. A failed read (for example `AccessDenied`) exits non-zero instead of printing an empty history. An empty history keeps `AWS-013` at `configured`, a pending item owned by the on-call lead, never `validated-live` from the smoke test alone.

## 4. Add compute health alarms (AWS-020 to AWS-026)

EC2 `StatusCheckFailed` uses the section 1 block. ECS running tasks below the service's floor: `RunningTaskCount` exists only when Container Insights is already on for the cluster, so the block stops before writing when it is off, and the alarm joins the Container Insights plan:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
CLUSTER="prod-cluster"; SERVICE="checkout"   # from the AWS-022 evidence
ECS_MIN_RUNNING_TASKS="2"  # example, tune it: the service's fixed desired count, or its autoscaling minimum
ECS_PERIOD_SECS="300"      # example, tune it
ECS_EVAL_PERIODS="2"       # example, tune it
ALARM_NAME="prod-ecs-${SERVICE}-running-count"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "ECS/ContainerInsights" --metric-name RunningTaskCount \
  --dimensions "Name=ClusterName,Value=${CLUSTER}" "Name=ServiceName,Value=${SERVICE}" --output json \
  | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No ECS/ContainerInsights data for ${CLUSTER}/${SERVICE}: Container Insights is off for this cluster, so record this alarm in the Container Insights plan" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD ECS ${SERVICE} WARNING fewer than ${ECS_MIN_RUNNING_TASKS} running tasks | capture service events, task stop reasons, recent deploy" \
  --namespace "ECS/ContainerInsights" --metric-name RunningTaskCount \
  --dimensions "Name=ClusterName,Value=${CLUSTER}" "Name=ServiceName,Value=${SERVICE}" \
  --statistic Minimum --period "$ECS_PERIOD_SECS" --evaluation-periods "$ECS_EVAL_PERIODS" \
  --threshold "$ECS_MIN_RUNNING_TASKS" --comparison-operator LessThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

Lambda errors (repeat for `Throttles`, `ConcurrentExecutions`, and `Duration` on latency-sensitive functions). This alarm counts errors per period; an error rate needs a metric-math alarm on `Errors` over `Invocations` instead:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
LAMBDA_NAME="checkout-webhook"   # the function from the finding
LAMBDA_ERRORS_MIN="1"      # example, tune it to the function's traffic: errors per period that page
LAMBDA_PERIOD_SECS="300"   # example, tune it
LAMBDA_EVAL_PERIODS="2"    # example, tune it
ALARM_NAME="prod-lambda-${LAMBDA_NAME}-errors"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first" >&2; exit 1; }
# Any metric for the function proves its FunctionName dimension is live.
aws_cli cloudwatch list-metrics --namespace "AWS/Lambda" \
  --dimensions "Name=FunctionName,Value=${LAMBDA_NAME}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No AWS/Lambda data for ${LAMBDA_NAME} in the last two weeks: check the function name (a function that has not run has none)" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD Lambda ${LAMBDA_NAME} WARNING ${LAMBDA_ERRORS_MIN} or more errors per ${LAMBDA_PERIOD_SECS}s | capture recent invocations, error logs, dependency health, recent deploy" \
  --namespace "AWS/Lambda" --metric-name Errors \
  --dimensions "Name=FunctionName,Value=${LAMBDA_NAME}" \
  --statistic Sum --period "$LAMBDA_PERIOD_SECS" --evaluation-periods "$LAMBDA_EVAL_PERIODS" \
  --threshold "$LAMBDA_ERRORS_MIN" --comparison-operator GreaterThanOrEqualToThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

Expected: each block prints `true`. EKS Container Insights enablement (`AWS-023`) and ASG `HealthCheckType`/`HealthCheckGracePeriod` edits (`AWS-021`) are controlled rollouts per the four change-risk classes: enabling Container Insights installs a CloudWatch agent add-on across the cluster, and flipping an ASG's health-check type can trigger AWS to replace instances it now judges unhealthy. Neither executes here; both go to the change record as a plan with a named owner, and turning Container Insights on for an ECS cluster joins the same plan. EC2 and Lambda alarm creation proceeds independently, and so does the ECS alarm on a cluster that already has Container Insights. X-Ray sampling rules (`AWS-026`) are read-only review, no write in this skill.

## 5. Harden managed databases (AWS-030 to AWS-034)

Backup-before-write, the config change, alarms, **restore pair**. Neither field fails over or reboots the instance, but turning automated backups on (retention 0 to N, the `AWS-031` fix) or off causes a brief outage, an I/O suspension on the instance: announce that outage and the window you run it in first.

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
DB_ID="db-main"   # a standalone RDS instance; Aurora and DocumentDB keep retention on the cluster (plan only)
BACKUP_RETENTION_DAYS="7"     # example, tune to your recovery-point objective
MAX_ALLOCATED_STORAGE_GB="500"  # example ceiling for storage autoscaling
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"

# 1. Backup (GET-before-write). Keep the first one of the day so a re-run never overwrites the prior state:
[ -s "${BACKUP_DIR}/rds-${DB_ID}.json" ] \
  || aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json > "${BACKUP_DIR}/rds-${DB_ID}.json"
test -s "${BACKUP_DIR}/rds-${DB_ID}.json" && echo "backup: ${BACKUP_DIR}/rds-${DB_ID}.json"

# 2. Write. The storage ceiling, and a retention change between two non-zero values, apply with no
#    outage; retention 0 to N briefly suspends I/O. Multi-AZ conversion stays plan-only, see below.
aws_cli rds modify-db-instance --db-instance-identifier "$DB_ID" \
  --backup-retention-period "$BACKUP_RETENTION_DAYS" \
  --max-allocated-storage "$MAX_ALLOCATED_STORAGE_GB" \
  --apply-immediately

# 3. Verify:
aws_cli rds describe-db-instances --db-instance-identifier "$DB_ID" --output json \
  | jq -e --argjson r "$BACKUP_RETENTION_DAYS" --argjson m "$MAX_ALLOCATED_STORAGE_GB" \
      '.DBInstances[0] | (.BackupRetentionPeriod == $r) and (.MaxAllocatedStorage == $m)'
```

Expected: exit 0. **Restore, run as written when the change must be undone.** Restoring a prior retention of 0 turns automated backups off again, with the same brief outage, and deletes them, so the block refuses it until you set `ALLOW_BACKUP_DELETION=yes`:

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
  | jq -e --argjson r "$PREV_RETENTION" --argjson m "$PREV_MAX_STORAGE" \
      '.DBInstances[0] | (.BackupRetentionPeriod == $r) and ((.MaxAllocatedStorage // .AllocatedStorage) == $m)'
```

Expected: `true`: retention and the storage ceiling are back to the backed-up values (with autoscaling off, RDS may report no ceiling, which reads as the allocated storage). Then CPU/connections/freeable-memory/replication-lag alarms follow the same `put-metric-alarm` shape as section 1, metric names `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReplicaLag` (the last only on read replicas), dimensions `Name=DBInstanceIdentifier,Value=<id>`. `AWS-030` Multi-AZ conversion is traffic-impacting (triggers a brief failover) and never executes here: record it as a plan with current state, blast radius, maintenance window, and a named owner.

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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
TARGET_HOST="www.example.com"
TARGET_PATH="/healthz"
CHECK_INTERVAL="30"   # example seconds; Route53 accepts 10 or 30
HC_FAILURE_THRESHOLD="3"   # example, tune it: consecutive failed checks before Route53 marks the target unhealthy

HC_ID="$(aws_cli route53 create-health-check --caller-reference "checkout-prod-$(date -u +%s)" \
  --health-check-config "FullyQualifiedDomainName=${TARGET_HOST},Port=443,Type=HTTPS,ResourcePath=${TARGET_PATH},RequestInterval=${CHECK_INTERVAL},FailureThreshold=${HC_FAILURE_THRESHOLD}" \
  --output json | jq -r '.HealthCheck.Id')"
echo "created: ${HC_ID}"
aws_cli route53 get-health-check --health-check-id "$HC_ID" --output json \
  | jq -e --arg h "$TARGET_HOST" '.HealthCheck.HealthCheckConfig.FullyQualifiedDomainName == $h'
```

Expected: exit 0. A Route53 health check alone has no destination, so alarm on its `HealthCheckStatus`. Route53 publishes that metric only in `us-east-1`, so this alarm and its SNS topic live in `us-east-1` whatever your configured region; create the topic there with the section 2 block, its region set to `us-east-1`, and run the section 1 backup block for this alarm the same way:

```bash
set -eu
AWS_PROFILE_CFG=""                 # aws.profile
AWS_REGION_CFG="us-east-1"         # not aws.region: HealthCheckStatus exists only in us-east-1
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
HC_ID="<health-check-id>"          # the "created:" value from the block above
SNS_TOPIC_ARN="<topic-arn>"        # a topic in us-east-1
TARGET_HOST="www.example.com"      # the host that check watches
HC_PERIOD_SECS="60"                # example, tune it
HC_EVAL_PERIODS="2"                # example, tune it: unhealthy periods before paging
for v in "$HC_ID" "$SNS_TOPIC_ARN"; do case "$v" in ''|'<'*) echo "Fill in every <...> value first" >&2; exit 1 ;; esac; done
case "$SNS_TOPIC_ARN" in arn:*:sns:us-east-1:*) ;; *) echo "The topic must be in us-east-1, where this alarm lives" >&2; exit 1 ;; esac
ALARM_NAME="prod-route53-${HC_ID}-unhealthy"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first, its region set to us-east-1" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "AWS/Route53" --metric-name HealthCheckStatus \
  --dimensions "Name=HealthCheckId,Value=${HC_ID}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No HealthCheckStatus data for ${HC_ID} in us-east-1 yet: a new check takes a few minutes to report, so wait and re-run" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD ${TARGET_HOST} CRITICAL Route53 health check ${HC_ID} failing | capture the endpoint status, recent deploy, DNS and certificate changes" \
  --namespace "AWS/Route53" --metric-name HealthCheckStatus \
  --dimensions "Name=HealthCheckId,Value=${HC_ID}" \
  --statistic Minimum --period "$HC_PERIOD_SECS" --evaluation-periods "$HC_EVAL_PERIODS" \
  --threshold 1 --comparison-operator LessThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

For `AWS-041`, alarm on the target group's `UnHealthyHostCount` rather than editing the target group's own health-check parameters: changing an ALB/NLB target group's health-check path, interval, or threshold can eject currently-healthy targets from rotation, which is traffic-impacting and stays out of this skill's write scope; record that edit as a plan with a named owner instead. The metric counts only what the target group's health check reports, so a target group with its health check off needs that plan before this alarm can fire:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the values the live-safety gate printed
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
LB_NAMESPACE="AWS/ApplicationELB"  # AWS/NetworkELB for an NLB
LB_NAME="app/prod-alb/1234567890abcdef"                     # the load balancer's ARN suffix
TARGET_GROUP="targetgroup/prod-checkout/0123456789abcdef"   # the target group's ARN suffix
UNHEALTHY_HOSTS_MAX="0"            # example, tune it: unhealthy targets tolerated before paging
UHH_PERIOD_SECS="60"               # example, tune it
UHH_EVAL_PERIODS="3"               # example, tune it
case "$LB_NAMESPACE" in AWS/ApplicationELB|AWS/NetworkELB) ;; *) echo "LB_NAMESPACE must be AWS/ApplicationELB or AWS/NetworkELB" >&2; exit 1 ;; esac
ALARM_NAME="prod-${TARGET_GROUP##*/}-unhealthy-hosts"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "$LB_NAMESPACE" \
  --dimensions "Name=TargetGroup,Value=${TARGET_GROUP}" "Name=LoadBalancer,Value=${LB_NAME}" --output json \
  | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No ${LB_NAMESPACE} data for ${TARGET_GROUP} on ${LB_NAME}: check both ARN suffixes" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD ${TARGET_GROUP} WARNING more than ${UNHEALTHY_HOSTS_MAX} unhealthy targets | capture target health reasons, recent deploy, instance status" \
  --namespace "$LB_NAMESPACE" --metric-name UnHealthyHostCount \
  --dimensions "Name=TargetGroup,Value=${TARGET_GROUP}" "Name=LoadBalancer,Value=${LB_NAME}" \
  --statistic Maximum --period "$UHH_PERIOD_SECS" --evaluation-periods "$UHH_EVAL_PERIODS" \
  --threshold "$UNHEALTHY_HOSTS_MAX" --comparison-operator GreaterThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

For `AWS-042`, alarm on the canary's `SuccessPercent`:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region: the canary's region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:123456789012:prod-warning"   # from Fix alert routing
CANARY_NAME="checkout-homepage"    # the canary from the finding
CANARY_SUCCESS_MIN_PCT="90"        # example, tune it: success rate below which the alarm pages
CANARY_PERIOD_SECS="300"           # example, tune it: at least the canary's run interval
CANARY_EVAL_PERIODS="2"            # example, tune it
ALARM_NAME="prod-canary-${CANARY_NAME}-failing"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/setup-$(date -u +%Y-%m-%d)/backups/alarm-${ALARM_NAME}.json"
[ -s "$BACKUP_FILE" ] || { echo "Run the section 1 backup block for ${ALARM_NAME} first" >&2; exit 1; }
aws_cli cloudwatch list-metrics --namespace "CloudWatchSynthetics" --metric-name SuccessPercent \
  --dimensions "Name=CanaryName,Value=${CANARY_NAME}" --output json | jq -e '.Metrics | length > 0' > /dev/null \
  || { echo "No SuccessPercent data for canary ${CANARY_NAME}: check the name and that the canary runs" >&2; exit 1; }
aws_cli cloudwatch put-metric-alarm \
  --alarm-name "$ALARM_NAME" \
  --alarm-description "PROD canary ${CANARY_NAME} WARNING success below ${CANARY_SUCCESS_MIN_PCT}% | capture the failed run's screenshot and logs, recent deploy, endpoint status" \
  --namespace "CloudWatchSynthetics" --metric-name SuccessPercent \
  --dimensions "Name=CanaryName,Value=${CANARY_NAME}" \
  --statistic Average --period "$CANARY_PERIOD_SECS" --evaluation-periods "$CANARY_EVAL_PERIODS" \
  --threshold "$CANARY_SUCCESS_MIN_PCT" --comparison-operator LessThanThreshold \
  --alarm-actions "$SNS_TOPIC_ARN"
aws_cli cloudwatch describe-alarms --alarm-names "$ALARM_NAME" --output json \
  | jq -e --arg t "$SNS_TOPIC_ARN" '.MetricAlarms[0] | (.ActionsEnabled == true) and any(.AlarmActions[]?; . == $t)'
```

Expected: each block prints `true`. Each alarm rolls back with the section 1 restore, run in the alarm's region (`us-east-1` for the health-check alarm). `AWS-043` (a check or canary watching a dead or migrated target) is repointed or retired, never fixed with an alarm; see [Fix uptime coverage](../SKILL.md#fix-uptime-coverage) for which part is a plan.

Health-check rollback, in its own fresh shell (same explicit profile and region as every block here, never the ambient default):

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
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"   # aws.profile, aws.region
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
AWS_ACCOUNT="<account-id>"   # aws.account_id: the account the live-safety gate printed
case "$AWS_ACCOUNT" in ''|'<'*) echo "Set AWS_ACCOUNT to the account the live-safety gate printed" >&2; exit 1 ;; esac
[ "$(aws_cli sts get-caller-identity --query Account --output text)" = "$AWS_ACCOUNT" ] || { echo "Signed in to a different account than ${AWS_ACCOUNT}; stopping" >&2; exit 1; }
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
aws_cli logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --output json \
  | jq -e --argjson r "$RETENTION_DAYS" '.logGroups[0].retentionInDays == $r'
aws_cli logs put-subscription-filter --log-group-name "$LOG_GROUP" --filter-name "central-sink" \
  --filter-pattern "" --destination-arn "$DEST_ARN"
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

Reference only, for [Plan cost optimizations](../SKILL.md#plan-cost-optimizations): `aws compute-optimizer get-ec2-instance-recommendations`, `aws compute-optimizer get-rds-database-recommendations`, `aws cost-optimization-hub list-recommendations` (its endpoint is in `us-east-1`), `aws ce get-savings-plans-coverage`, `aws ce get-reservation-coverage`. Full read shapes are in [audit-aws's aws-cost-checks.md](../../audit-aws/references/aws-cost-checks.md); nothing in this section 8 or in `#plan-cost-optimizations` ever mutates a resource.
