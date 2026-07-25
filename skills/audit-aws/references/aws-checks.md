# audit-aws: Check Catalog and Commands

Runnable, read-only checks for every reliability surface the [audit-aws](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the commands, the expected healthy output, and what the common failure shapes mean. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. Cost & Resource Optimization checks (`AWSOPT-NNN`) live in [aws-cost-checks.md](aws-cost-checks.md), not here.

## 1. Conventions

- Every command carries `--profile "${AWS_PROFILE_CFG}"` (when configured) and `--region "${AWS_REGION_CFG}"` explicitly. Ambient `AWS_PROFILE`/`AWS_DEFAULT_REGION` are never trusted, and this audit never runs `aws configure`.
- `aws ... --output json` feeds `jq`. Every list call paginates by default in the CLI's own SDK layer for the calls used here (`describe-alarms`, `describe-db-instances`, and friends auto-paginate); where a call caps a single page (`--max-records`), the pagination loop is shown explicitly.
- Every command here is read-only: `describe-*`, `get-*`, `list-*`. The forbidden-command list is section 14.
- `curl -fsS --max-time 15` is the default. Where the status code is itself the evidence (endpoint probes), `-f` is dropped deliberately and `-w '%{http_code}'` captures the code; those blocks say so.
- Never print an access key, secret key, session token, or role ARN external ID. Account IDs and resource ARNs may appear in local evidence but never in the Slack brief.
- Thresholds and windows are examples; tune to your workloads. Named defaults live in section 12.
- Troubleshooting only: if `aws` times out while `curl` to public sites works, retry once with proxy variables cleared (`env -u HTTPS_PROXY -u https_proxy aws sts get-caller-identity`) before concluding permissions are broken.

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep their number. Severity listed is the typical severity when the check fails; judge the real impact in your environment.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| AWS-001 | Alerting coverage and configuration | Every critical RDS/ALB/NLB/ASG/Lambda resource has at least one alarm | critical |
| AWS-002 | Alerting coverage and configuration | Two-tier or composite/anomaly alarms where a static threshold is brittle | medium |
| AWS-003 | Alerting coverage and configuration | Alarm descriptions carry responder-ready metadata | medium |
| AWS-004 | Alerting coverage and configuration | No alarm stuck in INSUFFICIENT_DATA from a dead dimension filter | high |
| AWS-005 | Alerting coverage and configuration | Minimum dashboard coverage per critical service | low |
| AWS-006 | Alerting coverage and configuration | Composite/anomaly-detection alarms in use are reviewed for a sane trigger | info |
| AWS-007 | Alerting coverage and configuration | Application Signals SLOs have a burn-rate config and an alarm on it (not-in-scope when App Signals is unused) | medium |
| AWS-010 | Alert routing and delivery | Every alarm names at least one SNS topic in AlarmActions | critical |
| AWS-011 | Alert routing and delivery | Every referenced SNS topic has a confirmed (non-PendingConfirmation) subscription | high |
| AWS-012 | Alert routing and delivery | Severity-tiered topics, not one undifferentiated topic | medium |
| AWS-013 | Alert routing and delivery | Delivery proven by an observed CloudWatch-generated notification | high |
| AWS-014 | Alert routing and delivery | EventBridge rule targets enabled and reachable | medium |
| AWS-020 | Compute health and coverage | StatusCheckFailed alarm per serving EC2 instance | high |
| AWS-021 | Compute health and coverage | ASG health-check type and grace period configured | medium |
| AWS-022 | Compute health and coverage | ECS service desired-vs-running count alarm or documented view | high |
| AWS-023 | Compute health and coverage | Container Insights enabled per EKS cluster (presence only) | medium |
| AWS-024 | Compute health and coverage | Error-rate and throttle alarms per critical Lambda function | high |
| AWS-025 | Compute health and coverage | Concurrency/duration alarms where latency-sensitive or concurrency-capped | medium |
| AWS-026 | Compute health and coverage | X-Ray tracing reviewed where the team has adopted it | info |
| AWS-030 | Managed databases | Multi-AZ enabled per production RDS instance | high |
| AWS-031 | Managed databases | Automated backup retention window > 0 days | high |
| AWS-032 | Managed databases | Storage autoscaling enabled | medium |
| AWS-033 | Managed databases | Replication-lag alarm per read replica | medium |
| AWS-034 | Managed databases | CPU, connection, and freeable-memory alarms present | high |
| AWS-040 | Uptime and availability | Route53 health check per active public serving endpoint | high |
| AWS-041 | Uptime and availability | ALB/NLB target-group health check configured and probed live | high |
| AWS-042 | Uptime and availability | Synthetics canaries, where used, carry a failure alarm | medium |
| AWS-043 | Uptime and availability | No health check or canary watches a dead or migrated target | medium |
| AWS-050 | Log forwarding and account-level observability | Central log forwarding for critical log groups, or absence recorded | high |
| AWS-051 | Log forwarding and account-level observability | Finite retention set on critical log groups | medium |
| AWS-052 | Log forwarding and account-level observability | CloudTrail enabled account-wide, multi-region trail | high |
| AWS-053 | Log forwarding and account-level observability | AWS Config recorder on | medium |
| AWS-054 | Log forwarding and account-level observability | VPC Flow Logs enabled for VPCs carrying critical workloads | medium |
| AWS-055 | Log forwarding and account-level observability | Central-sink and retention decision complete with a named owner | low |
| AWS-056 | Log forwarding and account-level observability | No CloudWatch Logs anomaly detector stuck in FAILED or PAUSED | medium |
| AWS-060 | Alerting coverage and configuration | Paging alarms debounce single datapoints via M-of-N (DatapointsToAlarm < EvaluationPeriods) or an adequate Period | medium |
| AWS-061 | Alerting coverage and configuration | No paging alarm pages on data gaps or thin percentile samples (TreatMissingData not breaching, InsufficientDataActions not on a paging topic, EvaluateLowSampleCountPercentile=ignore) | medium |
| AWS-062 | Alerting coverage and configuration | No paging alarm flaps across the 30-day StateUpdate history | medium |
| AWS-063 | Alerting coverage and configuration | No paging alarm left indefinitely with ActionsEnabled=false (forgotten mute) | medium |
| AWS-064 | Alerting coverage and configuration | Composite alarms (AlarmRule + ActionsSuppressor) used for native correlation where child alarms fan out | medium |
| AWS-065 | Alerting coverage and configuration | Paging alarms wire OKActions so a return to OK resolves downstream incidents | info |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Alerting coverage and configuration**: every critical RDS instance, load balancer, ASG, and Lambda function has at least one alarm whose dimension filter matches live data, two-tier or anomaly-based where load varies, with responder-ready descriptions and dashboard coverage.
- **Alert routing and delivery**: every alarm names a confirmed SNS topic, severity-tiered rather than one catch-all, with at least one observed CloudWatch-generated delivery per topic class.
- **Compute health and coverage**: every serving EC2 instance, ASG, ECS service, EKS cluster, and critical Lambda function has a live health signal that pages someone, and Container Insights presence is confirmed on every EKS cluster.
- **Managed databases**: every production RDS instance runs Multi-AZ with real backup retention, storage autoscaling, replication-lag visibility, and resource-pressure alarms.
- **Uptime and availability**: every live public endpoint has a Route53 health check or a proven target-group health check, canaries page on failure, and no check watches a dead target.
- **Log forwarding and account-level observability**: critical log groups forward centrally with finite retention, and the account-wide controls (CloudTrail, Config, VPC Flow Logs) are on.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings.

```bash
set -eu
AWS_PROFILE_CFG=""           # aws.profile
AWS_REGION_CFG="us-east-1"   # aws.region
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

aws_cli cloudwatch describe-alarms --output json \
  | jq '[.MetricAlarms[] | {name: .AlarmName, state: .StateValue, actions: .AlarmActions,
      ok_actions: .OKActions, namespace: .Namespace, metric: .MetricName,
      dimensions: [.Dimensions[]? | {name: .Name, value: .Value}],
      description: (.AlarmDescription // "")}]' > "${RAW_DIR}/alarms.json"
aws_cli cloudwatch describe-alarms --alarm-types CompositeAlarm --output json \
  | jq '[.CompositeAlarms[]? | {name: .AlarmName, state: .StateValue, rule: .AlarmRule}]' > "${RAW_DIR}/composite-alarms.json"

aws_cli sns list-topics --output json | jq -r '.Topics[].TopicArn' | while read -r arn; do
  aws_cli sns list-subscriptions-by-topic --topic-arn "$arn" --output json \
    | jq --arg arn "$arn" '[.Subscriptions[] | {topic: $arn, protocol: .Protocol, subscription_arn: .SubscriptionArn}]'
done | jq -s 'add // []' > "${RAW_DIR}/sns-subscriptions.json"

aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=running' --output json \
  | jq '[.Reservations[].Instances[] | {id: .InstanceId, type: .InstanceType, tags: (.Tags // [])}]' > "${RAW_DIR}/ec2.json"
aws_cli autoscaling describe-auto-scaling-groups --output json \
  | jq '[.AutoScalingGroups[] | {name: .AutoScalingGroupName, health_check_type: .HealthCheckType,
      grace_period: .HealthCheckGracePeriod, desired: .DesiredCapacity}]' > "${RAW_DIR}/asgs.json"
aws_cli rds describe-db-instances --output json \
  | jq '[.DBInstances[] | {id: .DBInstanceIdentifier, multi_az: .MultiAZ,
      backup_retention_days: .BackupRetentionPeriod, storage_autoscaling: (.MaxAllocatedStorage != null),
      is_replica: (.ReadReplicaSourceDBInstanceIdentifier != null), status: .DBInstanceStatus}]' > "${RAW_DIR}/rds.json"
aws_cli ecs list-clusters --output json | jq -r '.clusterArns[]' | while read -r c; do
  aws_cli ecs list-services --cluster "$c" --output json | jq -r '.serviceArns[]?' | while read -r s; do
    aws_cli ecs describe-services --cluster "$c" --services "$s" --output json \
      | jq --arg c "$c" '.services[] | {cluster: $c, name: .serviceName, desired: .desiredCount, running: .runningCount}'
  done
done | jq -s '.' > "${RAW_DIR}/ecs-services.json"
aws_cli eks list-clusters --output json | jq -r '.clusters[]' | while read -r name; do
  aws_cli eks describe-cluster --name "$name" --output json \
    | jq '.cluster | {name: .name, logging: (.logging.clusterLogging // [])}'
done | jq -s '.' > "${RAW_DIR}/eks.json"
aws_cli lambda list-functions --output json \
  | jq '[.Functions[] | {name: .FunctionName, timeout: .Timeout, reserved_concurrency: (.ReservedConcurrentExecutions // null)}]' > "${RAW_DIR}/lambda.json"

aws_cli route53 list-health-checks --output json \
  | jq '[.HealthChecks[] | {id: .Id, target: (.HealthCheckConfig.FullyQualifiedDomainName // .HealthCheckConfig.IPAddress // "unknown")}]' > "${RAW_DIR}/route53-health-checks.json"
aws_cli elbv2 describe-target-groups --output json \
  | jq '[.TargetGroups[] | {arn: .TargetGroupArn, name: .TargetGroupName, health_check_enabled: .HealthCheckEnabled}]' > "${RAW_DIR}/target-groups.json"

aws_cli logs describe-log-groups --output json \
  | jq '[.logGroups[] | {name: .logGroupName, retention_days: (.retentionInDays // null)}]' > "${RAW_DIR}/log-groups.json"
aws_cli cloudtrail describe-trails --output json \
  | jq '[.trailList[] | {name: .Name, multi_region: .IsMultiRegionTrail, is_org_trail: .IsOrganizationTrail}]' > "${RAW_DIR}/cloudtrail.json"
aws_cli configservice describe-configuration-recorder-status --output json \
  | jq '[.ConfigurationRecordersStatus[] | {name: .name, recording: .recording}]' > "${RAW_DIR}/config-recorders.json" \
  || echo '[]' > "${RAW_DIR}/config-recorders.json"
aws_cli ec2 describe-flow-logs --output json \
  | jq '[.FlowLogs[] | {resource_id: .ResourceId, status: .FlowLogStatus}]' > "${RAW_DIR}/flow-logs.json"
```

Expected: one JSON file per surface. An empty `ecs-services.json` or `eks.json` on an account that genuinely runs neither means that portion of Compute health and coverage is `not-in-scope`, declared in the scorecard, not a failure. Any `AccessDenied` error is evidence of a missing role; record it and mark the affected checks `blocked`.

## 5. Alerting coverage and configuration (AWS-001 to AWS-007)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
# AWS-001: alarms grouped by the resource id in their dimensions, to find resources with zero alarms.
jq -r '.[] | .dimensions[]? | select(.name | test("DBInstanceIdentifier|LoadBalancer|AutoScalingGroupName|FunctionName")) | .value' \
  "${RAW_DIR}/alarms.json" | sort -u
# AWS-004: alarms currently stuck in INSUFFICIENT_DATA; each is a candidate dead-filter finding.
jq -r '.[] | select(.state == "INSUFFICIENT_DATA") | "\(.name): namespace=\(.namespace) metric=\(.metric)"' "${RAW_DIR}/alarms.json"
# AWS-003: alarms whose description is too short to be responder-ready (screen, not the judgment).
jq -r 'select((.description | length) < 40) | .name' "${RAW_DIR}/alarms.json"
```

Expected: cross-reference the first list's resource IDs against the section 4 inventories (`rds.json`, `target-groups.json`, `asgs.json`, `lambda.json`); any critical resource id absent from the list is the `AWS-001` finding, named exactly. `AWS-004` is not automatically a fail: an alarm in `INSUFFICIENT_DATA` because the resource is genuinely new or paused is a note, not a defect; an alarm in `INSUFFICIENT_DATA` for a live, serving resource because its dimension filter names the wrong resource id is the real finding. `AWS-002`, `AWS-005`, and `AWS-006` are judgment steps: read the alarm's `Threshold`/`ComparisonOperator` pair (or the composite alarm's `AlarmRule`) against the resource's known load pattern, and check `cloudwatch list-dashboards`/`get-dashboard` for a view naming this service.

**AWS-007 (Application Signals SLO burn-rate alarm).** Only where the account uses Application Signals; when `list-service-level-objectives` returns empty or the service is not enabled, AWS-007 is `not-in-scope`, never a fail.

```bash
set -eu
aws_cli() { aws "$@"; }   # your resolved profile/region wrapper from section 4
# List SLOs; for each, read its config and check for a burn-rate configuration.
aws_cli application-signals list-service-level-objectives --output json 2>/dev/null \
  | jq -r '.SloSummaries[]?.Arn' | while read -r arn; do
      aws_cli application-signals get-service-level-objective --id "$arn" --output json \
        | jq -r '.Slo | "\(.Name)\tburn_rate_configs=\((.BurnRateConfigurations // []) | length)"'
    done
# An SLO with burn_rate_configs=0 has no burn-rate metric (AWS-007). For SLOs WITH a burn-rate
# config, confirm an alarm actually watches it: the SLO object carries NO alarm reference, so
# cross-reference describe-alarms for an alarm whose metric is the SLO's burn-rate/attainment metric.
aws_cli cloudwatch describe-alarms --output json \
  | jq -r '.MetricAlarms[]? | select((.Namespace // "") | test("ApplicationSignals"; "i")) | .AlarmName'
```

Expected: every SLO shows `burn_rate_configs >= 1` AND appears (by its metric) among the Application Signals alarms. An SLO with `burn_rate_configs=0`, or one whose burn-rate metric no alarm watches, is the AWS-007 finding: the SLO tracks attainment on a dashboard but pages nobody when the budget burns. Presence of a `BurnRateConfigurations` entry alone is not proof of an alarm — the alarm must exist in `describe-alarms`.

- ❌ `AWS-003 pass: every alarm has a non-empty AlarmDescription field.`
- ✅ `AWS-003 partial: descriptions exist but none name the environment or a datapoint to check first; a responder reading "High CPU" alone learns nothing at 3am.`

## 5A. Alert hygiene: per-alarm noise controls and the native-correlation ceiling (AWS-060 to AWS-065)

Serves Phase 3's alert-hygiene checks, which fold into the **Alerting coverage and configuration** category. Every block is read-only (`describe-alarms`, `describe-alarm-history`) and reads the per-alarm fields the section 4 inventory did not capture. Honest ceiling, repeated because it belongs in the evidence: CloudWatch's strength is per-alarm threshold quality (M-of-N, `Period`, `TreatMissingData`, anomaly bands, low-sample percentile handling) plus a single correlation primitive (composite alarm `AlarmRule` + `ActionsSuppressor`); it has no native grouping, dedup window, rate-limiting/`repeat_interval`, scheduled mute, or severity routing tree, those live in SNS or a downstream pager. These are structural noise signals, not an actionability rate; the flap window is bounded at 30 days by `DescribeAlarmHistory` retention; and flapping faster than an alarm's `Period` is invisible. Apply the named thresholds (`SHORT_PERIOD_SECS`, `FLAP_TRANSITIONS`, etc.) as the reader, exactly as the rest of this audit does. Field definitions are authoritative in `API_PutMetricAlarm.html` and `alarm-evaluation.html`; `DescribeAlarmHistory` fields in `API_DescribeAlarmHistory.html`.

### 5A.1 Capture the hygiene fields

```bash
set -eu
AWS_PROFILE_CFG=""           # aws.profile
AWS_REGION_CFG="us-east-1"   # aws.region
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

aws_cli cloudwatch describe-alarms --alarm-types MetricAlarm --output json \
  | jq '[.MetricAlarms[] | {name: .AlarmName, state: .StateValue,
      alarm_actions: (.AlarmActions // []), ok_actions: (.OKActions // []),
      insufficient_data_actions: (.InsufficientDataActions // []),
      actions_enabled: .ActionsEnabled,
      period: .Period, evaluation_periods: .EvaluationPeriods,
      datapoints_to_alarm: (.DatapointsToAlarm // .EvaluationPeriods),
      treat_missing_data: (.TreatMissingData // "missing"),
      statistic: (.Statistic // .ExtendedStatistic // ""),
      evaluate_low_sample: (.EvaluateLowSampleCountPercentile // ""),
      threshold_metric_id: (.ThresholdMetricId // "")}]' > "${RAW_DIR}/alarm-hygiene.json"

aws_cli cloudwatch describe-alarms --alarm-types CompositeAlarm --output json \
  | jq '[.CompositeAlarms[]? | {name: .AlarmName, rule: .AlarmRule,
      actions_suppressor: (.ActionsSuppressor // ""),
      suppressor_wait: (.ActionsSuppressorWaitPeriod // null),
      actions_enabled: .ActionsEnabled, ok_actions: (.OKActions // [])}]' > "${RAW_DIR}/composite-hygiene.json"
```

Expected: two JSON files. `DatapointsToAlarm` is absent on consecutive-periods alarms and defaults to `EvaluationPeriods` (captured above), so `datapoints_to_alarm == evaluation_periods` means no M-of-N. An `AccessDenied` is a missing-permission finding; mark the affected checks `blocked`, never empty success.

### 5A.2 Single-datapoint debounce (AWS-060)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
SHORT_PERIOD_SECS="60"   # example, tune it: a Period at/below this with single-datapoint evaluation is spike-prone
jq -r --argjson short "$SHORT_PERIOD_SECS" '
  .[] | select((.alarm_actions | length) > 0)
  | select(.evaluation_periods == 1 and .datapoints_to_alarm == 1 and .period <= $short)
  | "\(.name): period=\(.period)s M-of-N=\(.datapoints_to_alarm)/\(.evaluation_periods) (single-datapoint, no debounce)"
' "${RAW_DIR}/alarm-hygiene.json"
```

Expected: no output. Each line is an AWS-060 candidate, a paging alarm that transitions to ALARM on one breaching datapoint on a short `Period`. Confirm the metric is spiky before filing; a genuinely step-change metric (a binary up/down status check) is a legitimate single-datapoint alarm, not a flap.

### 5A.3 Missing / low-sample data noise (AWS-061)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
# TreatMissingData=breaching on a paging alarm: a metric gap pages.
jq -r '.[] | select((.alarm_actions | length) > 0 and .treat_missing_data == "breaching")
  | "\(.name): TreatMissingData=breaching (a metric gap pages)"' "${RAW_DIR}/alarm-hygiene.json"
# InsufficientDataActions reusing a paging AlarmActions topic: data gaps page the on-call (set intersection A - (A - B)).
jq -r '.[] | select((.alarm_actions | length) > 0)
  | . as $x
  | ([$x.alarm_actions[]] - ([$x.alarm_actions[]] - [$x.insufficient_data_actions[]])) as $shared
  | select(($shared | length) > 0)
  | "\($x.name): InsufficientDataActions shares a paging topic with AlarmActions (data gaps page the on-call)"' "${RAW_DIR}/alarm-hygiene.json"
# Percentile-statistic alarm without low-sample suppression.
jq -r '.[] | select((.alarm_actions | length) > 0)
  | select(.statistic | test("^p[0-9]"))
  | select(.evaluate_low_sample != "ignore")
  | "\(.name): percentile statistic \(.statistic), EvaluateLowSampleCountPercentile=\(if .evaluate_low_sample == "" then "unset" else .evaluate_low_sample end) (fires on thin samples)"' "${RAW_DIR}/alarm-hygiene.json"
```

Expected: no output from any block. `breaching` on a metric that legitimately goes idle (a scaled-down ASG, a low-traffic queue) pages on the gap; `notBreaching` or `ignore` is the intent there. `EvaluateLowSampleCountPercentile` defaults to `evaluate`, which flips a `pNN` alarm on a handful of samples; `ignore` holds state until the sample count is significant. The AWS/DynamoDB namespace defaults `TreatMissingData` to `ignore` rather than `missing`; do not read that default as a defect.

- ❌ `AWS-061 pass: every alarm has TreatMissingData set.`
- ✅ `AWS-061 partial: TreatMissingData is set, but two paging alarms on a scaled-to-zero worker use "breaching", so every quiet period pages the on-call as an outage (named alarms listed).`

### 5A.4 Flap history (AWS-062)

```bash
set -eu
AWS_PROFILE_CFG=""           # aws.profile
AWS_REGION_CFG="us-east-1"   # aws.region
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
ALARM_NAME="your-alarm-name"     # each paging alarm from alarm-hygiene.json
FLAP_DAYS="30"                   # example, tune it: history window (CloudWatch retains 30 days max)
FLAP_TRANSITIONS="12"            # example, tune it: ALARM transitions over the window above which the alarm flaps
START="$(date -u -d "${FLAP_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${FLAP_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COUNT="$(aws_cli cloudwatch describe-alarm-history --alarm-name "$ALARM_NAME" \
  --history-item-type StateUpdate --start-date "$START" --end-date "$END" \
  --max-records 100 --output json \
  | jq '[.AlarmHistoryItems[] | select(.HistorySummary | test("to ALARM"))] | length')"
echo "${ALARM_NAME}: ${COUNT} ALARM transitions over ${FLAP_DAYS}d (flap threshold ${FLAP_TRANSITIONS})"
```

Expected: `COUNT` at or below `FLAP_TRANSITIONS` for each paging alarm. `HistoryItemType=StateUpdate` items whose `HistorySummary` records a transition into ALARM are the rising edges; a high count over the window is an AWS-062 flap. The `date` line covers both GNU (`-d`) and BSD (`-v`) `date`. Report the effective window (bounded at 30 days) and state that flapping faster than the alarm's `Period` is invisible to this read rather than implying the alarm is clean.

### 5A.5 Forgotten mute (AWS-063)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
jq -r '.[] | select((.alarm_actions | length) > 0 and .actions_enabled == false)
  | "\(.name): ActionsEnabled=false (actions muted; CloudWatch has no scheduled un-mute, so this stays silent until toggled back)"' "${RAW_DIR}/alarm-hygiene.json"
jq -r '.[] | select(.actions_enabled == false) | "\(.name): composite ActionsEnabled=false"' "${RAW_DIR}/composite-hygiene.json"
```

Expected: no output. `ActionsEnabled=false` is CloudWatch's only per-alarm mute and it is a manual toggle, not a scheduled silence, so an alarm left this way after a maintenance window is a silent gap. Cross-reference `describe-alarm-history` (section 5A.4, `HistoryItemType=ConfigurationUpdate`) for how long it has been muted where the history still holds it.

### 5A.6 Native correlation ceiling (AWS-064)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
# Composite alarms present, and whether they carry correlation logic and/or a suppressor.
jq -r '.[] | "\(.name): rule=\(.rule) suppressor=\(if .actions_suppressor == "" then "none" else .actions_suppressor end)"' "${RAW_DIR}/composite-hygiene.json"
# How many metric alarms page directly, with no composite in front.
jq -r '[.[] | select((.alarm_actions | length) > 0)] | length | "paging metric alarms: \(.)"' "${RAW_DIR}/alarm-hygiene.json"
```

Expected: judgment, not a threshold. Many paging metric alarms with zero composite alarms means a single root cause fans out into N simultaneous pages with no native way to collapse them. A composite alarm's `AlarmRule` with AND/OR/NOT logic (for example `NOT(deploymentInProgress)`) plus an `ActionsSuppressor` (a maintenance-window or parent-outage alarm) is the ceiling of native correlation and suppression. State in the report that grouping, dedup, and scheduled silence are not available here and must live in a downstream pager; do not score CloudWatch against them.

### 5A.7 Resolve wiring (AWS-065)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
jq -r '.[] | select((.alarm_actions | length) > 0 and (.ok_actions | length) == 0)
  | "\(.name): no OKActions (return to OK sends no resolve; a downstream incident may stay open)"' "${RAW_DIR}/alarm-hygiene.json"
```

Expected: judgment. A paging alarm with empty `OKActions` never signals a return to OK, so a downstream incident tracker or pager may leave the page open after the condition clears. This is `info` unless a downstream pager depends on the resolve to auto-close, where it rises to `medium`. `OKActions` pointing at a chatty topic is the opposite risk (resolve-noise); read the destination, not just presence.

## 6. Alert routing and delivery (AWS-010 to AWS-014)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
# AWS-010: alarms with zero actions attached.
jq -r '.[] | select((.actions // []) | length == 0) | .name' "${RAW_DIR}/alarms.json"
# AWS-011: subscriptions whose SubscriptionArn is literally "PendingConfirmation".
jq -r '.[] | select(.subscription_arn == "PendingConfirmation") | "\(.topic): \(.protocol) subscription unconfirmed"' \
  "${RAW_DIR}/sns-subscriptions.json"
```

Expected: no output from either. Every line from the first is an `AWS-010` finding, critical if the resource is a critical service; every line from the second is an `AWS-011` finding, and the topic behind it cannot deliver to that endpoint until a human clicks confirm. `AWS-012` is a judgment step: read the topic names and subscription endpoints and decide whether critical and warning severities share one topic; one topic named `alerts` receiving every alarm in the account is the finding.

`AWS-013`: reading `AlarmActions` and a confirmed subscription proves configuration, not delivery. Look for an observed CloudWatch-generated notification, an alarm state-history transition your team confirms reached the destination, or a documented past page. Without one, routing stays `configured` and `AWS-013` scores `partial` at best:

```bash
set -eu
AWS_PROFILE_CFG=""           # aws.profile
AWS_REGION_CFG="us-east-1"   # aws.region
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
ALARM_NAME="your-alarm-name"   # each alarm from the inventory
aws_cli cloudwatch describe-alarm-history --alarm-name "$ALARM_NAME" --history-item-type StateUpdate --max-records 5 --output json \
  | jq '[.AlarmHistoryItems[] | {timestamp: .Timestamp, summary: .HistorySummary}]'
```

Expected: at least one past `ALARM` transition your team can confirm reached the SNS destination. An empty history is not proof of failure, it may mean the alarm has never fired, but it means delivery stays unproven this run.

- ❌ `AWS-013 pass: four alarms exist, each with a confirmed SNS subscription.`
- ✅ `AWS-013 partial: alarms and confirmed subscriptions exist, but alarm-history shows no ALARM transition for any of them this quarter, so delivery has never actually been observed; routing stays configured.`

`AWS-014`: for EventBridge rules that target alarm state changes (`source: aws.cloudwatch`), confirm the rule's `State` is `ENABLED` and its targets resolve; a disabled rule or a target pointing at a deleted Lambda function is the finding.

## 7. Compute health and coverage (AWS-020 to AWS-026)

`AWS-020`: cross-reference `ec2.json` instance IDs against alarm dimensions naming `InstanceId` with a `StatusCheckFailed` or `StatusCheckFailed_System`/`StatusCheckFailed_Instance` metric; any serving instance absent from that set is the finding. `AWS-021`: from `asgs.json`, an ASG whose `health_check_type` is `EC2` when it fronts a load balancer (should be `ELB`) or whose `grace_period` is shorter than the service's own startup time is the finding. `AWS-022`: cross-reference `ecs-services.json` desired-vs-running counts against alarm dimensions naming `ServiceName`; a service with a persistent desired-running gap and no alarm is the finding.

`AWS-023`, Container Insights presence:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
jq -r '.[] | "\(.name): \([.logging[] | select(.types[]? == "api" or .types[]? == "controllerManager") | .enabled] | any)"' "${RAW_DIR}/eks.json"
```

Container Insights itself is a CloudWatch agent add-on, not a `describe-cluster` field; confirm it via `aws cloudwatch list-metrics --namespace ContainerInsights --dimensions Name=ClusterName,Value=<cluster>` returning at least one metric. An empty result on a serving cluster is the `AWS-023` finding. Depth beyond presence, per-pod or per-container metrics, belongs to `audit-lgtm`/`audit-grafana` when the customer runs that stack on EKS; this check never claims that depth.

`AWS-024`/`AWS-025`: cross-reference `lambda.json` function names against alarm dimensions naming `FunctionName` with `Errors`, `Throttles`, `ConcurrentExecutions`, or `Duration` metrics; a critical function with no `Errors` alarm is `AWS-024` fail, and a function with a `ReservedConcurrentExecutions` value set but no `ConcurrentExecutions` alarm is `AWS-025` fail. `AWS-026`: `aws xray get-sampling-rules` returning rules for a latency-sensitive service confirms adoption; absence is `info`, not a fail, since not every team has adopted X-Ray.

- ❌ `Scored compute coverage 100: alarms exist for CPU and errors on every resource type.`
- ✅ `Scored compute coverage 65: EC2 and Lambda are covered, but 2 of 3 ECS services have no desired-vs-running signal and the EKS cluster shows zero ContainerInsights metrics, so cluster health is unproven (AWS-022 fail, AWS-023 fail).`

## 8. Managed databases (AWS-030 to AWS-034)

From `rds.json`: `AWS-030` fails on any non-replica instance with `multi_az: false`. `AWS-031` fails on `backup_retention_days: 0`. `AWS-032` fails when `storage_autoscaling: false` (no `MaxAllocatedStorage` set). `AWS-033`: for every instance where `is_replica: true`, confirm an alarm exists on the `ReplicaLag` metric with a dimension matching that instance id; absence is the finding. `AWS-034`: cross-reference instance ids against alarm dimensions naming `DBInstanceIdentifier` with `CPUUtilization`, `DatabaseConnections`, and `FreeableMemory` metrics; any production instance missing one of the three is the finding, named per metric.

## 9. Uptime and availability (AWS-040 to AWS-043)

`AWS-040`: compare the service list's public hostnames against `route53-health-checks.json` targets; any active public hostname absent from the checked list is the finding. `AWS-041`: from `target-groups.json`, any `health_check_enabled: false` on a target group serving production traffic is the finding; then probe live health:

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
TARGET_GROUP_ARN="your-target-group-arn"   # each target group from the inventory
aws_cli elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN" --output json \
  | jq '[.TargetHealthDescriptions[] | {target: .Target.Id, state: .TargetHealth.State}]'
```

Expected: every target `healthy`. Any `unhealthy` or `unused` target on a group serving production traffic is evidence for the finding, quoted with its state. `AWS-042`: for each Synthetics canary in use (`aws synthetics describe-canaries`), confirm an alarm rides its `SuccessPercent` metric; a canary with no alarm is a dashboard widget, not alerting. `AWS-043`: probe every checked target live, the same discipline as the DO and GCP audits:

```bash
set -eu
TARGET_URL="https://www.example.com/healthz"   # each check's exact protocol, host, and path
BODY="$(mktemp)"
code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 15 "$TARGET_URL")" || code="000"
echo "GET ${TARGET_URL} -> ${code}"
head -c 200 "$BODY"; echo; rm -f "$BODY"
```

Expected: `200`. A `404`, `410`, or a parked page means the check watches a dead or migrated target; `000` means DNS or connect failure, either a real outage or a moved hostname, settle ownership before filing an outage.

## 10. Log forwarding and account-level observability (AWS-050 to AWS-056)

`AWS-050`: from `log-groups.json`, cross-reference critical-service log group names against `aws logs describe-subscription-filters --log-group-name <name>`; an empty result on a critical group's log group is the finding unless the team has a written decision that logs stay local to CloudWatch. `AWS-051`: any critical log group with `retention_days: null` (meaning "Never expire") is the finding. `AWS-052`: from `cloudtrail.json`, at least one trail with `multi_region: true` must exist and be actively logging (`aws cloudtrail get-trail-status --name <trail>` returns `IsLogging: true`); absence is a critical, account-wide gap. `AWS-053`: from `config-recorders.json`, any recorder with `recording: false`, or an empty list entirely, is the finding. `AWS-054`: from `flow-logs.json`, any VPC carrying critical workloads absent from the list, or present with `status` other than `ACTIVE`, is the finding. `AWS-055` is a judgment step over the team's own answers: which backend receives forwarded logs, what retention, what redaction, who owns cost and access; a backend with none of those answered is `partial`, not `pass`.

`AWS-056`: CloudWatch Logs anomaly detectors in a broken state. Read-only `list-log-anomaly-detectors`:

```bash
set -eu
aws_cli() { aws "$@"; }   # your resolved profile/region wrapper from section 4
aws_cli logs list-log-anomaly-detectors --output json 2>/dev/null \
  | jq -r '.anomalyDetectors[]? | "\(.detectorName // .anomalyDetectorArn)\t\(.anomalyDetectorStatus)"'
```

Expected: each detector's `anomalyDetectorStatus` is one of `INITIALIZING | TRAINING | ANALYZING | FAILED | DELETED | PAUSED`. A `FAILED` or `PAUSED` detector on a critical log group is the AWS-056 finding: it looks configured but surfaces no anomalies. Absence of any detector is not a finding (they are opt-in); only a broken one is. `INITIALIZING`/`TRAINING` are transient and informational.

- ❌ `Logs pass: CloudTrail is enabled.`
- ✅ `Logs partial: CloudTrail is enabled and multi-region (AWS-052 pass), but three production log groups have no retention set and no subscription filter, so incident logs age out silently with nothing centrally searchable (AWS-050 fail, AWS-051 fail, named log groups listed).`

## 11. Per-service coverage rows

Assemble one row per critical service from the raw captures; re-fetch any cell you are about to fail:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="./scoutflo-audits/aws/${RUN_DATE}/raw"
SERVICE_NAME="checkout"   # canonical name from topology.md
echo "compute matched by tag or name containing ${SERVICE_NAME}:"
jq -r --arg s "$SERVICE_NAME" '.[] | select([.tags[]?.Value] | any(test($s; "i"))) | .id' "${RAW_DIR}/ec2.json"
jq -r --arg s "$SERVICE_NAME" '.[] | select(.name | test($s; "i")) | .id' "${RAW_DIR}/rds.json"
```

The matrix cell vocabulary is `pass`, `partial`, `fail`, `blocked`, `not-in-scope`. A service with no resource of a given compute kind marks that sub-check `not-in-scope`, never a silent pass. When topology.md is absent, record the tag- or name-based mapping as inferred.

## 12. Starting alert set (tune per workload)

Conservative starting defaults, not prescriptions. Adjust thresholds and windows after observing each workload's baselines.

```bash
EC2_STATUS_CHECK_PERIOD="300"     # example, seconds
RDS_CPU_WARN_PCT="80"             # example warning tier, tune per engine and workload
RDS_CPU_SAT_PCT="95"              # example saturation tier
RDS_CONN_WARN_PCT="80"            # example, percent of max_connections
LAMBDA_ERROR_RATE_PCT="5"         # example, percent of invocations
LAMBDA_THROTTLE_COUNT="1"         # example, per evaluation window
ALB_5XX_RATIO="0.05"              # example 5xx ratio, tune after observing normal error rates
CANARY_SUCCESS_PCT="90"           # example, alert below this success percentage
LOG_RETENTION_DAYS="365"          # example, tune to your compliance and cost posture
```

| Surface | Starting point | Avoid |
| --- | --- | --- |
| EC2/ASG | StatusCheckFailed alarm evaluated every `EC2_STATUS_CHECK_PERIOD`s; ELB-type health checks behind a load balancer | EC2-type health checks silently killing slow-starting instances behind an LB |
| RDS | CPU warning at `RDS_CPU_WARN_PCT` and saturation at `RDS_CPU_SAT_PCT`; connections above `RDS_CONN_WARN_PCT` of max | single low thresholds copied between instance classes with different baselines |
| Lambda | error rate above `LAMBDA_ERROR_RATE_PCT`; any throttle above `LAMBDA_THROTTLE_COUNT` | alarms on functions with near-zero invocation volume, where any single error swings the rate wildly |
| Load balancer | 5xx ratio above `ALB_5XX_RATIO`; target-group health probed live every run | health checks alone mistaken for alerting |
| Synthetics | canary success below `CANARY_SUCCESS_PCT` | canaries running with no alarm at all |
| Logs | finite retention at `LOG_RETENTION_DAYS` or your compliance-driven value | "Never expire" left as the default on high-volume groups |

## 13. Large-path worklist: resources in batches

Runnable commands for the large path named in [SKILL.md's Estate sizing](../SKILL.md#estate-sizing) and worked through in [Large-path worklist: resources in batches](../SKILL.md#large-path-worklist-resources-in-batches). This is the same run-ID-keyed, lock-and-resume mechanism as `do-checks.md` section 13 and `gcp-checks.md` section 16, adapted to AWS resource kinds; every block here is stateless and redeclares its own inputs.

### 13.1 Find a resumable run, or start a new one

```bash
set -eu
AUDIT_ROOT="./scoutflo-audits/aws"

resumable=""
if [ -d "${AUDIT_ROOT}/runs" ]; then
  for d in "${AUDIT_ROOT}/runs"/*/; do
    [ -f "${d}worklist.tsv" ] || continue
    pending=$(awk -F'\t' '$3 == "pending"' "${d}worklist.tsv" | wc -l | tr -d ' ')
    [ "${pending}" -gt 0 ] || continue
    resumable="${d}"
    echo "resumable run found: ${d} (pending=${pending})"
  done
fi

if [ -n "${resumable}" ]; then
  echo "resume ${resumable} instead of starting a new run? offer this to the user before proceeding"
else
  echo "no resumable run found; safe to start a new one"
fi
```

### 13.2 Mint the run ID

```bash
set -eu
AUDIT_ROOT="./scoutflo-audits/aws"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

### 13.3 Build or resume the worklist

One row per resource, tab-separated: `kind` (`ec2`, `rds`, `ecs_service`, `eks_cluster`, or `lambda`), `id`, `status` (`pending` or `done`).

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
RUN_DIR="./scoutflo-audits/aws/runs/20260717T140500Z"   # example; resolved run directory from 13.1 or 13.2

WORKLIST="${RUN_DIR}/worklist.tsv"
if [ -f "${WORKLIST}" ]; then
  done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
  pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
  echo "resuming existing worklist: done=${done} pending=${pending}"
else
  : > "${WORKLIST}"
  aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].InstanceId' --output text \
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'ec2\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
  aws_cli rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text \
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'rds\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
  aws_cli ecs list-clusters --query 'clusterArns' --output text | tr '\t' '\n' | while read -r c; do
    aws_cli ecs list-services --cluster "$c" --query 'serviceArns' --output text | tr '\t' '\n' \
      | while read -r s; do [ -n "$s" ] && printf 'ecs_service\t%s\tpending\n' "$s" >> "${WORKLIST}"; done
  done
  aws_cli eks list-clusters --query 'clusters' --output text | tr '\t' '\n' \
    | while read -r name; do [ -n "$name" ] && printf 'eks_cluster\t%s\tpending\n' "$name" >> "${WORKLIST}"; done
  aws_cli lambda list-functions --query 'Functions[].FunctionName' --output text | tr '\t' '\n' \
    | while read -r name; do [ -n "$name" ] && printf 'lambda\t%s\tpending\n' "$name" >> "${WORKLIST}"; done
  total=$(wc -l < "${WORKLIST}" | tr -d ' ')
  echo "built worklist: ${total} rows, all pending"
fi
```

### 13.4 Lock the worklist before claiming a batch

```bash
set -eu
RUN_DIR="./scoutflo-audits/aws/runs/20260717T140500Z"   # example; resolved run directory
LOCK="${RUN_DIR}/worklist.lock"
LOCK_STALE_MINUTES="30"   # example, tune to your batch size and expected run length

now_epoch=$(date -u +%s)
if [ -f "${LOCK}" ]; then
  lock_pid=$(awk -F'\t' 'NR==1{print $1}' "${LOCK}")
  lock_epoch=$(awk -F'\t' 'NR==1{print $2}' "${LOCK}")
  age_minutes=$(( (now_epoch - lock_epoch) / 60 ))
  if [ "${age_minutes}" -lt "${LOCK_STALE_MINUTES}" ]; then
    echo "worklist locked by pid ${lock_pid}, age ${age_minutes}m; stop, do not claim a batch"
    exit 1
  fi
  echo "existing lock is ${age_minutes}m old (>= ${LOCK_STALE_MINUTES}m); treating as abandoned and reclaiming"
fi

printf '%s\t%s\n' "$$" "${now_epoch}" > "${LOCK}"
echo "lock acquired: pid=$$ at ${now_epoch}"
```

### 13.5 Claim a batch, pull its resources, mark done, release the lock

Claim happens while the lock (13.4) is held; release happens right after the batch's rows are marked, so another process can claim the next batch. For each row in the claimed batch, run the section 5 to 10 checks matching its kind, plus, when `aws.cost_checks` is on, the matching [aws-cost-checks.md](aws-cost-checks.md) checks for that kind, writing raw captures under `${RUN_DIR}/raw/<kind>/<id>/` and appending results to `${RUN_DIR}/findings-partial.jsonl`. A row is marked `done` only after its pulls succeed without error.

```bash
set -eu
RUN_DIR="./scoutflo-audits/aws/runs/20260717T140500Z"   # example; resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"
LOCK="${RUN_DIR}/worklist.lock"
BATCH_SIZE="10"   # example, tune it; matches the value declared in SKILL.md's Estate sizing

BATCH_FILE="${RUN_DIR}/batch-$(date -u +%s).tsv"
awk -F'\t' '$3 == "pending"' "${WORKLIST}" | head -n "${BATCH_SIZE}" > "${BATCH_FILE}"
count=$(wc -l < "${BATCH_FILE}" | tr -d ' ')
echo "claimed batch: ${count} rows -> ${BATCH_FILE}"

# ... for each (kind, id) in "${BATCH_FILE}", run the section 5-10 pulls for that
# kind, writing raw captures under "${RUN_DIR}/raw/<kind>/<id>/" and appending
# results to "${RUN_DIR}/findings-partial.jsonl". Only after every row's pulls
# succeed:

while IFS=$'\t' read -r kind id _status; do
  awk -F'\t' -v k="${kind}" -v n="${id}" 'BEGIN{OFS="\t"} $1==k && $2==n {$3="done"} {print}' \
    "${WORKLIST}" > "${WORKLIST}.tmp" && mv "${WORKLIST}.tmp" "${WORKLIST}"
done < "${BATCH_FILE}"

rm -f "${LOCK}"   # release once this batch (not the whole run) completes
done=$(awk -F'\t' '$3 == "done"' "${WORKLIST}" | wc -l | tr -d ' ')
pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "batch marked done: done=${done} pending=${pending}"
```

Expected: `pending` drops by the batch size (or less, on the final partial batch) after each pass through 13.4 and 13.5. Repeat 13.4 and 13.5 until `pending` reaches 0.

### 13.6 Assert the worklist is complete before writing the report

```bash
set -eu
RUN_DIR="./scoutflo-audits/aws/runs/20260717T140500Z"   # example; resolved run directory
WORKLIST="${RUN_DIR}/worklist.tsv"

pending=$(awk -F'\t' '$3 == "pending"' "${WORKLIST}" | wc -l | tr -d ' ')
echo "pending=${pending}"
[ "${pending}" -eq 0 ] || { echo "worklist not complete; repeat 13.4 and 13.5 before writing findings.json or report.md"; exit 1; }
echo "worklist complete: safe to proceed to Phase 11 (score, write, brief)"
```

Rules:

- The lock covers one batch claim, not the whole run: acquire it right before reading pending rows, release it right after marking them done.
- A lock file holds exactly two tab-separated fields: the PID that holds it, and its UTC epoch start timestamp. Nothing else.
- `findings.json` and `report.md` are written only once `pending` is 0 (13.6). Never assemble the final report from a worklist with pending rows.
- Delete the run directory after `findings.json` and `report.md` are written; it is working state, not a report.

## 14. Commands this audit must never run

Any of these appearing in an audit transcript is a lane violation, whatever the justification:

- `aws cloudwatch put-metric-alarm|delete-alarms|set-alarm-state|enable-alarm-actions|disable-alarm-actions`
- `aws sns create-topic|delete-topic|subscribe|unsubscribe|confirm-subscription|publish`
- `aws ec2 run-instances|terminate-instances|stop-instances|start-instances|reboot-instances|modify-instance-attribute`, any `aws ec2 create-*`/`delete-*`/`modify-*` (security groups, VPCs, flow logs)
- `aws autoscaling update-auto-scaling-group|set-desired-capacity|terminate-instance-in-auto-scaling-group`
- `aws rds modify-db-instance|create-db-instance|delete-db-instance|reboot-db-instance|failover-db-cluster`
- `aws ecs update-service|create-service|delete-service`, `aws eks update-cluster-config|delete-cluster`
- `aws lambda update-function-configuration|delete-function|put-function-concurrency`
- `aws route53 change-resource-record-sets|create-health-check|delete-health-check|update-health-check`
- `aws elbv2 modify-target-group|modify-listener|register-targets|deregister-targets`
- `aws logs put-retention-policy|delete-log-group|put-subscription-filter|delete-subscription-filter`
- `aws cloudtrail create-trail|update-trail|delete-trail|start-logging|stop-logging`
- `aws configservice put-configuration-recorder|start-configuration-recorder|stop-configuration-recorder`
- `aws configure`, or any command that mutates local AWS CLI profile state
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`
