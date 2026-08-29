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
| AWS-004 | Alerting coverage and configuration | No alarm proven unable to evaluate because its exact dimensions yield no data for an active resource | high |
| AWS-005 | Alerting coverage and configuration | Minimum dashboard coverage per critical service | low |
| AWS-006 | Alerting coverage and configuration | Composite/anomaly-detection alarms in use are reviewed for a sane trigger | info |
| AWS-007 | Alerting coverage and configuration | Application Signals SLOs have a burn-rate config and an alarm on it (not-in-scope when App Signals is unused) | medium |
| AWS-010 | Alert routing and delivery | Every alarm names at least one SNS topic in AlarmActions | critical |
| AWS-011 | Alert routing and delivery | Every referenced SNS topic has a confirmed (non-PendingConfirmation) subscription | high |
| AWS-012 | Alert routing and delivery | Severity-tiered topics, not one undifferentiated topic | medium |
| AWS-013 | Alert routing and delivery | Intended human receipt proven by destination-side evidence correlated to an alarm event | high |
| AWS-014 | Alert routing and delivery | EventBridge rule targets enabled and reachable | medium |
| AWS-020 | Compute health and coverage | StatusCheckFailed alarm per serving EC2 instance | high |
| AWS-021 | Compute health and coverage | ASG health-check type and grace period configured | medium |
| AWS-022 | Compute health and coverage | ECS service desired-vs-running count alarm or documented view | high |
| AWS-023 | Compute health and coverage | Container Insights enabled per EKS cluster (presence only) | medium |
| AWS-024 | Compute health and coverage | Error-rate and throttle alarms per critical Lambda function | high |
| AWS-025 | Compute health and coverage | Concurrency/duration alarms where latency-sensitive or concurrency-capped | medium |
| AWS-026 | Compute health and coverage | X-Ray tracing reviewed where the team has adopted it | info |
| AWS-027 | Compute health and coverage | No ASG has a safety process suspended (HealthCheck / ReplaceUnhealthy / AlarmNotification) — self-healing is not switched off | high |
| AWS-028 | Compute health and coverage | Async Lambda has a dead-letter queue or on-failure destination (failed events are not dropped silently) | high |
| AWS-030 | Managed databases | Engine-appropriate production HA: Multi-AZ for standalone RDS, multi-AZ members for Aurora/RDS clusters and DocumentDB | high |
| AWS-031 | Managed databases | Automated backup retention window > 0 days at the instance or cluster layer that owns backups | high |
| AWS-032 | Managed databases | Storage autoscaling enabled where the engine exposes it; not-in-scope for auto-growing Aurora/DocumentDB storage | medium |
| AWS-033 | Managed databases | Engine-native replication-lag alarm per applicable replica or cluster | medium |
| AWS-034 | Managed databases | Engine-native resource-pressure alarms use the correct namespace, dimensions, and metrics | high |
| AWS-035 | Managed databases | Production RDS/DocumentDB has an enabled event subscription for service-supported availability categories on a confirmed topic | medium |
| AWS-040 | Uptime and availability | Route53 health coverage where Route53 authority or monitoring ownership is confirmed | high |
| AWS-041 | Uptime and availability | ALB/NLB target-group health check configured and probed live | high |
| AWS-042 | Uptime and availability | Synthetics canaries, where used, carry a failure alarm | medium |
| AWS-043 | Uptime and availability | No health check or canary watches a dead or migrated target | medium |
| AWS-050 | Log forwarding, retention, and account-level observability | Central log forwarding for critical log groups, or absence recorded | high |
| AWS-051 | Log forwarding, retention, and account-level observability | Finite retention set on critical log groups | medium |
| AWS-052 | Log forwarding, retention, and account-level observability | CloudTrail enabled account-wide, multi-region trail | high |
| AWS-053 | Log forwarding, retention, and account-level observability | AWS Config recorder on | medium |
| AWS-054 | Log forwarding, retention, and account-level observability | VPC Flow Logs enabled for VPCs carrying critical workloads | medium |
| AWS-055 | Log forwarding, retention, and account-level observability | Central-sink and retention decision evidenced by an authoritative record and named owner | low |
| AWS-056 | Log forwarding, retention, and account-level observability | No CloudWatch Logs anomaly detector stuck in FAILED or PAUSED | medium |
| AWS-060 | Alerting coverage and configuration | Paging alarms debounce single datapoints via M-of-N (DatapointsToAlarm < EvaluationPeriods) or an adequate Period | medium |
| AWS-061 | Alerting coverage and configuration | No paging alarm pages on data gaps or thin percentile samples (TreatMissingData not breaching, InsufficientDataActions not on a paging topic, EvaluateLowSampleCountPercentile=ignore) | medium |
| AWS-062 | Alerting coverage and configuration | No paging alarm flaps across the 30-day StateUpdate history | medium |
| AWS-063 | Alerting coverage and configuration | No paging alarm left indefinitely with ActionsEnabled=false (forgotten mute) | medium |
| AWS-064 | Alerting coverage and configuration | Composite alarms (AlarmRule + ActionsSuppressor) used for native correlation where child alarms fan out | medium |
| AWS-065 | Alerting coverage and configuration | Paging alarms wire OKActions so a return to OK resolves downstream incidents | info |

## 3. Target profile

What 100/100 means per category; the checks above are this profile made executable.

- **Alerting coverage and configuration**: every critical RDS instance, load balancer, ASG, and Lambda function has at least one alarm whose dimension filter matches live data, two-tier or anomaly-based where load varies, with responder-ready descriptions and dashboard coverage.
- **Alert routing and delivery**: every alarm names a confirmed SNS topic, severity-tiered rather than one catch-all, with destination-side evidence that at least one representative alarm event per topic class reached its intended human receiver.
- **Compute health and coverage**: every serving EC2 instance, ASG, ECS service, EKS cluster, and critical Lambda function has a live health signal that pages someone, and Container Insights presence is confirmed on every EKS cluster.
- **Managed databases**: every production standalone RDS instance, Aurora/RDS cluster, and DocumentDB cluster has engine-appropriate HA, backups, replication visibility, and resource-pressure alarms; unsupported controls are explicitly not-in-scope.
- **Uptime and availability**: every live public endpoint has a health control in the system that owns it; Route53-specific coverage is scored only where Route53 authority or monitoring ownership is confirmed.
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

aws_cli cloudwatch describe-alarms --output json \
  | jq '[.MetricAlarms[] | {name: .AlarmName, state: .StateValue, actions: .AlarmActions,
      ok_actions: .OKActions, namespace: .Namespace, metric: .MetricName,
      dimensions: [.Dimensions[]? | {name: .Name, value: .Value}],
      description: (.AlarmDescription // ""), state_reason: (.StateReason // ""),
      state_reason_data: (.StateReasonData // ""), state_updated_at: .StateUpdatedTimestamp,
      treat_missing_data: (.TreatMissingData // "missing"), period: .Period,
      evaluation_periods: .EvaluationPeriods, statistic: (.Statistic // .ExtendedStatistic // ""),
      metrics: (.Metrics // [])}]' > "${RAW_DIR}/alarms.json"
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
  | jq '[.DBInstances[] | {id: .DBInstanceIdentifier, engine: .Engine,
      cluster_id: (.DBClusterIdentifier // null), availability_zone: .AvailabilityZone, multi_az: .MultiAZ,
      backup_retention_days: .BackupRetentionPeriod, storage_autoscaling: (.MaxAllocatedStorage != null),
      is_replica: (.ReadReplicaSourceDBInstanceIdentifier != null), status: .DBInstanceStatus}]' > "${RAW_DIR}/rds.json"
aws_cli rds describe-db-clusters --output json \
  | jq '[.DBClusters[] | {id: .DBClusterIdentifier, engine: .Engine, engine_mode: (.EngineMode // "provisioned"),
      status: .Status, backup_retention_days: .BackupRetentionPeriod,
      members: [.DBClusterMembers[]? | {id: .DBInstanceIdentifier, writer: .IsClusterWriter,
        promotion_tier: .PromotionTier}]}]' > "${RAW_DIR}/rds-clusters.json"
aws_cli docdb describe-db-instances --output json \
  | jq '[.DBInstances[] | {id: .DBInstanceIdentifier, engine: .Engine,
      cluster_id: .DBClusterIdentifier, availability_zone: .AvailabilityZone,
      status: .DBInstanceStatus}]' > "${RAW_DIR}/docdb-instances.json"
aws_cli docdb describe-db-clusters --output json \
  | jq '[.DBClusters[] | {id: .DBClusterIdentifier, engine: .Engine, status: .Status,
      backup_retention_days: .BackupRetentionPeriod,
      members: [.DBClusterMembers[]? | {id: .DBInstanceIdentifier, writer: .IsClusterWriter,
        promotion_tier: .PromotionTier}]}]' > "${RAW_DIR}/docdb-clusters.json"
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
aws_cli route53 list-hosted-zones --output json \
  | jq '[.HostedZones[] | {id: .Id, name: .Name, private: .Config.PrivateZone}]' > "${RAW_DIR}/route53-hosted-zones.json"
aws_cli elbv2 describe-target-groups --output json \
  | jq '[.TargetGroups[] | {arn: .TargetGroupArn, name: .TargetGroupName, health_check_enabled: .HealthCheckEnabled}]' > "${RAW_DIR}/target-groups.json"

aws_cli logs describe-log-groups --output json \
  | jq '[.logGroups[] | {name: .logGroupName, retention_days: (.retentionInDays // null)}]' > "${RAW_DIR}/log-groups.json"
aws_cli cloudtrail describe-trails --output json \
  | jq '[.trailList[] | {name: .Name, multi_region: .IsMultiRegionTrail, is_org_trail: .IsOrganizationTrail,
      log_file_validation: .LogFileValidationEnabled}]' > "${RAW_DIR}/cloudtrail.json"
aws_cli configservice describe-configuration-recorder-status --output json \
  | jq '[.ConfigurationRecordersStatus[] | {name: .name, recording: .recording}]' > "${RAW_DIR}/config-recorders.json" \
  || echo '[]' > "${RAW_DIR}/config-recorders.json"
aws_cli ec2 describe-flow-logs --output json \
  | jq '[.FlowLogs[] | {resource_id: .ResourceId, status: .FlowLogStatus}]' > "${RAW_DIR}/flow-logs.json"
```

Expected: one JSON file per surface. Keep RDS instances, RDS clusters, DocumentDB instances, and DocumentDB clusters distinct; their fields are not interchangeable. An empty service inventory on an account that genuinely does not use that service is `not-in-scope`, not a failure. Any `AccessDenied` or failed pull is `blocked`; never replace it with `[]` or score it as an empty healthy estate.

## 5. Alerting coverage and configuration (AWS-001 to AWS-007)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
# AWS-001: alarms grouped by the resource id in their dimensions, to find resources with zero alarms.
jq -r '.[] | .dimensions[]? | select(.name | test("DBInstanceIdentifier|LoadBalancer|AutoScalingGroupName|FunctionName")) | .value' \
  "${RAW_DIR}/alarms.json" | sort -u
# AWS-004: INSUFFICIENT_DATA is a candidate only. Print every field required by the decision gate.
jq -r '.[] | select(.state == "INSUFFICIENT_DATA")
  | "\(.name): namespace=\(.namespace) metric=\(.metric) dimensions=\(.dimensions|tojson) TreatMissingData=\(.treat_missing_data) state_reason=\(.state_reason) updated=\(.state_updated_at)"' \
  "${RAW_DIR}/alarms.json"
# AWS-003: alarms whose description is too short to be responder-ready (screen, not the judgment).
jq -r '.[] | select((.description | length) < 40) | .name' "${RAW_DIR}/alarms.json"
```

Expected: cross-reference the first list's resource IDs against the section 4 inventories (`rds.json`, `target-groups.json`, `asgs.json`, `lambda.json`); any critical resource id absent from the list is the `AWS-001` finding, named exactly.

**AWS-001 is not "resource X has no alarm" — that is the Trusted Advisor line, free in thirty seconds. The finding is the computed blast radius.** Take each un-alarmed resource id from the diff above and join it to `./scoutflo-audits/topology-export.json`: resolve the resource to the critical services that back it via the `MONITORED_BY`/`service` (and mirrored `serviceName`) edge attributes, and state who dies unwatched and how many. For example: *"`db-primary` has zero CloudWatch alarms and backs `checkout` + `orders` (2 critical services, resolved from the `service` edges in topology-export.json) — a saturation event tonight pages nobody for either."* The number is the count of critical-service edges pointing at the un-alarmed resource; when no topology export exists, fall back to the resource's `service`/`Name` tag and say the join was inferred, never dropped. A zero-alarm resource is the **head of the flagship silent-page chain** — its strongest form, because there is not even an alarm to fail to deliver — so name the downstream links it feeds: AWS-034 (which specific RDS metric alarm is the one missing), AWS-024 (Lambda `Errors`/`Throttles`). Exact fix, per resource kind, never a bare "add an alarm": RDS → a two-tier `CPUUtilization` + `DatabaseConnections` + `FreeableMemory` set; ALB → an `HTTPCode_Target_5XX_Count` ratio; Lambda → `Errors` + `Throttles`, all with the section 12 starting thresholds; remediation `setup-aws#add-cloudwatch-alarms`. Verify by re-running the diff (the resource id now appears in the alarm-dimension id set) *and* `aws cloudwatch describe-alarms --alarm-names <name>` showing `StateValue != INSUFFICIENT_DATA` — which proves the dimension filter matched a live metric, not merely that an alarm object exists.

`AWS-004` is not automatically a fail. A failed finding requires all five gates below. If any gate is unknown, keep the check `partial` or `blocked` and state the missing evidence; never convert the alarm state alone into a dead-dimension claim.

1. **State reason:** `StateReason` or parsed `StateReasonData` says the alarm lacks datapoints; a new alarm, configuration update, or evaluation error is classified separately.
2. **Resource lifecycle:** every resource named by the dimensions resolves in the current inventory and is active (`running`, `available`, or the service's equivalent). A stopped, paused, scaled-to-zero, newly created, or deleted resource is not a dead-filter finding.
3. **Exact dimensions:** namespace, metric name, and the complete dimension set are queried unchanged. Do not drop a dimension to make data appear.
4. **Missing-data policy:** record `TreatMissingData`, `EvaluationPeriods`, and `Period`; explain whether the policy is expected to produce `INSUFFICIENT_DATA` for this metric.
5. **Recent datapoints:** the exact metric query returns zero datapoints over at least twice the alarm evaluation horizon, and the metric is documented or observed to emit continuously for this active resource. Sparse, request-driven, or metric-math alarms remain unproven unless their own query semantics are evaluated.

For a simple metric alarm, run this read-only datapoint check with the values copied exactly from `alarms.json`:

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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
ALARM_NAME="your-alarm-name"   # one simple metric alarm from alarms.json
ALARM_JSON="$(jq -c --arg name "$ALARM_NAME" '.[] | select(.name == $name)' "${RAW_DIR}/alarms.json")"
[ -n "$ALARM_JSON" ] || { echo "alarm not found in alarms.json: ${ALARM_NAME}"; exit 1; }
[ "$(printf '%s' "$ALARM_JSON" | jq '.metrics | length')" -eq 0 ] || { echo "metric-math alarm: evaluate its original Metrics array instead"; exit 1; }
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOOKBACK_SECONDS="$(printf '%s' "$ALARM_JSON" | jq '([(.period * .evaluation_periods * 2), 3600] | max)')"
START="$(date -u -d "${LOOKBACK_SECONDS} seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"${LOOKBACK_SECONDS}"S +%Y-%m-%dT%H:%M:%SZ)"
QUERY="$(printf '%s' "$ALARM_JSON" | jq '[{Id:"m1",MetricStat:{Metric:{Namespace:.namespace,MetricName:.metric,Dimensions:[.dimensions[]|{Name:.name,Value:.value}]},Period:.period,Stat:.statistic},ReturnData:true}]')"
aws_cli cloudwatch get-metric-data --metric-data-queries "$QUERY" --start-time "$START" --end-time "$END" --output json \
  | jq '{status_codes:[.MetricDataResults[].StatusCode], datapoints:([.MetricDataResults[].Values[]?] | length), messages:[.Messages[]?.Value]}'
```

Expected: a successful query reports the datapoint count and status. Zero datapoints is still only one gate. For metric-math alarms, evaluate the original `.Metrics` query array; do not substitute a single metric query or fail AWS-004 from the summary fields.

- ❌ `AWS-004 fail: the alarm is INSUFFICIENT_DATA.`
- ✅ `AWS-004 fail: StateReason says no datapoints; the exact dimensions name an active instance; TreatMissingData=missing; the unchanged query returned 0 datapoints over 1 hour, twice the evaluation horizon; CPUUtilization for this running instance emits continuously.`

`AWS-002`, `AWS-005`, and `AWS-006` are judgment steps: read the alarm's `Threshold`/`ComparisonOperator` pair (or the composite alarm's `AlarmRule`) against the resource's known load pattern, and check `cloudwatch list-dashboards`/`get-dashboard` for a view naming this service.

**AWS-007 (Application Signals SLO burn-rate alarm).** Only where the account uses Application Signals. A successful empty `list-service-level-objectives` response is `not-in-scope`; an authorization, transport, throttling, or malformed-response failure is `blocked`, never empty and never a pass.

```bash
set -eu
aws_cli() { aws "$@"; }   # your resolved profile/region wrapper from section 4
RAW_DIR="${RAW_DIR:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/$(date -u +%F)/raw}"
mkdir -p "$RAW_DIR"
SLO_LIST="${RAW_DIR}/application-signals-slos.json"
SLO_ERR="${RAW_DIR}/application-signals-slos.stderr"
if aws_cli application-signals list-service-level-objectives --output json >"$SLO_LIST" 2>"$SLO_ERR"; then
  jq -e '.SloSummaries | type == "array"' "$SLO_LIST" >/dev/null \
    || { echo "AWS-007 blocked: invalid Application Signals list response"; rm -f "$SLO_LIST"; }
else
  echo "AWS-007 blocked: Application Signals list failed; inspect ${SLO_ERR}"
  rm -f "$SLO_LIST"
fi

# Only a successful list may establish an empty/not-in-scope result. A failed
# per-SLO read blocks that SLO instead of silently omitting it.
if [ -f "$SLO_LIST" ]; then
  jq -r '.SloSummaries[]?.Arn' "$SLO_LIST" | while read -r arn; do
    [ -n "$arn" ] || continue
    safe_id="$(printf '%s' "$arn" | cksum | awk '{print $1}')"
    slo_out="${RAW_DIR}/application-signals-slo-${safe_id}.json"
    slo_err="${RAW_DIR}/application-signals-slo-${safe_id}.stderr"
    if aws_cli application-signals get-service-level-objective --id "$arn" --output json >"$slo_out" 2>"$slo_err"; then
      jq -r '.Slo | "\(.Name)\tburn_rate_configs=\((.BurnRateConfigurations // []) | length)"' "$slo_out"
    else
      echo "AWS-007 blocked for SLO ${arn}: get-service-level-objective failed; inspect ${slo_err}"
    fi
  done
fi
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
jq -r '.[] | select((.alarm_actions | length) > 0 and .actions_enabled == false)
  | "\(.name): ActionsEnabled=false (actions muted; CloudWatch has no scheduled un-mute, so this stays silent until toggled back)"' "${RAW_DIR}/alarm-hygiene.json"
jq -r '.[] | select(.actions_enabled == false) | "\(.name): composite ActionsEnabled=false"' "${RAW_DIR}/composite-hygiene.json"
```

Expected: no output. `ActionsEnabled=false` is CloudWatch's only per-alarm mute and it is a manual toggle, not a scheduled silence, so an alarm left this way after a maintenance window is a silent gap. Cross-reference `describe-alarm-history` (section 5A.4, `HistoryItemType=ConfigurationUpdate`) for how long it has been muted where the history still holds it.

### 5A.6 Native correlation ceiling (AWS-064)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
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
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
jq -r '.[] | select((.alarm_actions | length) > 0 and (.ok_actions | length) == 0)
  | "\(.name): no OKActions (return to OK sends no resolve; a downstream incident may stay open)"' "${RAW_DIR}/alarm-hygiene.json"
```

Expected: judgment. A paging alarm with empty `OKActions` never signals a return to OK, so a downstream incident tracker or pager may leave the page open after the condition clears. This is `info` unless a downstream pager depends on the resolve to auto-close, where it rises to `medium`. `OKActions` pointing at a chatty topic is the opposite risk (resolve-noise); read the destination, not just presence.

## 6. Alert routing and delivery (AWS-010 to AWS-014)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
# AWS-010: alarms with zero actions attached.
jq -r '.[] | select((.actions // []) | length == 0) | .name' "${RAW_DIR}/alarms.json"
# AWS-011: subscriptions whose SubscriptionArn is literally "PendingConfirmation".
jq -r '.[] | select(.subscription_arn == "PendingConfirmation") | "\(.topic): \(.protocol) subscription unconfirmed"' \
  "${RAW_DIR}/sns-subscriptions.json"
```

Expected: no output from either. Every line from the first is an `AWS-010` finding, critical if the resource is a critical service; every line from the second is an `AWS-011` finding, and the topic behind it cannot deliver to that endpoint until a human clicks confirm. `AWS-012` is a judgment step: read the topic names and subscription endpoints and decide whether critical and warning severities share one topic; one topic named `alerts` receiving every alarm in the account is the finding.

`AWS-013`: separate four evidence layers. `AlarmActions` proves wiring; a non-`PendingConfirmation` subscription proves confirmation; CloudWatch action history or SNS delivery metrics prove AWS attempted or accepted transport; only destination-side evidence correlated to the same alarm event proves receipt. Accept a pager incident, chat message, received email, or downstream invocation/delivery log containing the alarm name and matching timestamp or event identifier. A verbal statement without a record, a state transition, or `NumberOfNotificationsDelivered` alone does not prove a human received the page. Without destination-side evidence, AWS-013 stays `partial` and the report says `receipt unproven`.

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
aws_cli cloudwatch describe-alarm-history --alarm-name "$ALARM_NAME" --max-records 20 --output json \
  | jq '[.AlarmHistoryItems[] | {timestamp: .Timestamp, type: .HistoryItemType, summary: .HistorySummary}]'
```

Expected: `StateUpdate` shows the transition; `Action` can show CloudWatch attempted the configured action. Neither proves destination receipt. Correlate one event to destination-side evidence before passing AWS-013. Empty history is not a delivery failure; receipt is simply unproven.

- ❌ `AWS-013 pass: four alarms exist, each with a confirmed SNS subscription.`
- ✅ `AWS-013 partial: alarms and confirmed subscriptions exist and CloudWatch recorded an action attempt, but no correlated pager/chat/email receipt was provided; AWS transport is evidenced, human receipt is unproven.`

`AWS-014`: for EventBridge rules that target alarm state changes (`source: aws.cloudwatch`), confirm the rule's `State` is `ENABLED` and its targets resolve; a disabled rule or a target pointing at a deleted Lambda function is the finding.

## 7. Compute health and coverage (AWS-020 to AWS-026)

`AWS-020`: cross-reference `ec2.json` instance IDs against alarm dimensions naming `InstanceId` with a `StatusCheckFailed` or `StatusCheckFailed_System`/`StatusCheckFailed_Instance` metric; any serving instance absent from that set is a candidate. **"instance X has no StatusCheckFailed alarm" is a scanner line that mis-sizes severity by ignoring whether the instance is disposable.** Join each un-alarmed running instance to `asgs.json` / `aws autoscaling describe-auto-scaling-instances`: an instance that is NOT a member of any ASG (a *pet*) and serves a critical service stays dead until a human notices, so the missing `StatusCheckFailed_System` alarm (the one that also drives EC2 auto-recovery) is the only backstop — this is the real fail; an ASG *member* is auto-replaced, so the same gap is lower severity there. The number is pet instances mapped to a critical-service tag; name the instance id and its service. This crosses the NEW AWS-027 (ASG suspended processes): a member assumed safe *by* auto-replacement is not safe when `ReplaceUnhealthy`/`HealthCheck` is suspended, at which point the per-instance `StatusCheckFailed` alarm becomes the only backstop again — together they are the AWS "HA that isn't HA" trap (analogous to K8S-013). Exact fix: for pets, `StatusCheckFailed_System` (auto-recovery) + `StatusCheckFailed_Instance` alarms per instance (`setup-aws#add-compute-health-alarms`); for members, fix the ASG health-check type/grace (AWS-021) instead of per-instance alarms. Verify with `describe-alarms` showing a `StatusCheckFailed` alarm dimensioned to the `InstanceId`, in `OK` (not `INSUFFICIENT_DATA`) state. `AWS-021`: from `asgs.json`, an ASG whose `health_check_type` is `EC2` when it fronts a load balancer (should be `ELB`) or whose `grace_period` is shorter than the service's own startup time is the finding. `AWS-022`: cross-reference `ecs-services.json` desired-vs-running counts against alarm dimensions naming `ServiceName`; a service with a persistent desired-running gap and no alarm is the finding.

`AWS-023`, Container Insights presence:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
jq -r '.[] | "\(.name): \([.logging[] | select(.types[]? == "api" or .types[]? == "controllerManager") | .enabled] | any)"' "${RAW_DIR}/eks.json"
```

Container Insights itself is a CloudWatch agent add-on, not a `describe-cluster` field; confirm it via `aws cloudwatch list-metrics --namespace ContainerInsights --dimensions Name=ClusterName,Value=<cluster>` returning at least one metric. An empty result on a serving cluster is the `AWS-023` finding. Depth beyond presence, per-pod or per-container metrics, belongs to `audit-lgtm`/`audit-grafana` when you run that stack on EKS; this check never claims that depth.

`AWS-024`/`AWS-025`: cross-reference `lambda.json` function names against alarm dimensions naming `FunctionName` with `Errors`, `Throttles`, `ConcurrentExecutions`, or `Duration` metrics; a critical function with no `Errors` alarm is `AWS-024` fail, and a function with a `ReservedConcurrentExecutions` value set but no `ConcurrentExecutions` alarm is `AWS-025` fail. `AWS-026`: `aws xray get-sampling-rules` returning rules for a latency-sensitive service confirms adoption; absence is `info`, not a fail, since not every team has adopted X-Ray.

- ❌ `Scored compute coverage 100: alarms exist for CPU and errors on every resource type.`
- ✅ `Scored compute coverage 65: EC2 and Lambda are covered, but 2 of 3 ECS services have no desired-vs-running signal and the EKS cluster shows zero ContainerInsights metrics, so cluster health is unproven (AWS-022 fail, AWS-023 fail).`

## 7A. Self-healing and async-failure checks (AWS-027, AWS-028)

> **Live-verified (read-only).** `describe-auto-scaling-groups` (AWS-027) and `list-functions` (AWS-028) were run read-only against a live Scoutflo AWS account and returned valid, parseable JSON (exit 0). The account is real and populated (CloudWatch alarms and EC2 instances confirmed present), but carries no Auto Scaling groups or Lambda functions in the regions checked — so on this account these two are a clean **not-applicable** (an empty list, correctly handled), which proves the mechanism end to end; a positive-finding case awaits an account that runs ASGs/async Lambdas. Every command is read-only (`describe-*`/`get-*`/`list-*`).

Both open failure classes no existing check reaches: an ASG that reads as resilient (N instances desired) but whose resilience mechanism is switched off, and an async Lambda that silently discards failed events. Both fold into the **Compute health and coverage** category.

### 7A.1 ASG safety process suspended (AWS-027)

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
# ASGs with any process in SuspendedProcesses; HealthCheck/ReplaceUnhealthy/AlarmNotification
# are the safety-critical ones (Launch/Terminate/ScheduledActions suspension is often deliberate).
aws_cli autoscaling describe-auto-scaling-groups --output json \
  | jq -r '.AutoScalingGroups[]
      | select((.SuspendedProcesses // []) | length > 0)
      | "\(.AutoScalingGroupName)\tsuspended=\([.SuspendedProcesses[].ProcessName] | join(","))\tdesired=\(.DesiredCapacity)"'
# Per-instance health/lifecycle, to name which members sit unguarded behind a suspended process.
aws_cli autoscaling describe-auto-scaling-instances --output json \
  | jq -r '.AutoScalingInstances[] | "\(.AutoScalingGroupName)\t\(.InstanceId)\t\(.HealthStatus)\t\(.LifecycleState)"'
```

Expected: no ASG lists `HealthCheck`, `ReplaceUnhealthy`, or `AlarmNotification` in `suspended=`. An ASG with one of those suspended has silently lost its self-healing or scaling response: a failed instance is never replaced and scaling alarms are ignored, yet the group's `DesiredCapacity` still reads as if it were resilient. Blast radius: join the ASG to the critical service it fronts (tag / topology) and quote `desired=`, e.g. *"`asg-checkout-web` (fronts `checkout`, desired=3) has `ReplaceUnhealthy` + `HealthCheck` suspended — a hung instance stays in rotation serving errors and is never cycled out."* The number is ASGs with a safety process suspended × the critical services they front. Correlation: AWS-020 (once `ReplaceUnhealthy` is suspended, a per-instance `StatusCheckFailed` alarm is the ONLY backstop) and AWS-021 (health-check type/grace). Fix: resume the process (`setup-aws#add-compute-health-alarms` records it as a plan; resuming a process changes ASG behavior and is out of the audit's read-only lane). Verify with `describe-auto-scaling-groups` showing an empty `SuspendedProcesses` for the group. A deliberately suspended process during a known maintenance window is a note with an owner, not a fail — confirm intent before filing.

### 7A.2 Async Lambda with no DLQ or on-failure destination (AWS-028)

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
FN_NAME="your-function-name"   # each critical function from lambda.json
# DeadLetterConfig covers async (event) invokes; the event-invoke config's OnFailure destination is
# the newer path; event-source mappings (SQS/Kinesis/DynamoDB streams) carry their own OnFailure.
aws_cli lambda get-function-configuration --function-name "$FN_NAME" \
  --query '{dlq:DeadLetterConfig,runtime:Runtime,timeout:Timeout}' --output json
aws_cli lambda get-function-event-invoke-config --function-name "$FN_NAME" \
  --query 'DestinationConfig' --output json 2>/dev/null || echo 'no event-invoke config'
aws_cli lambda list-event-source-mappings --function-name "$FN_NAME" \
  --query 'EventSourceMappings[].{src:EventSourceArn,onfail:DestinationConfig.OnFailure}' --output json
```

Expected: an async-invoked function (EventBridge/S3/SNS trigger, or an event-source mapping) has EITHER a `DeadLetterConfig` OR an `OnFailure` destination. A function with neither drops the event permanently once retries exhaust — invisible data loss, not merely a missing alarm. Blast radius, joined to topology: *"`payments-callback` (critical, async via SNS) has no DLQ and no `OnFailure` destination — a downstream 5xx during a deploy silently discards payment callbacks with no replay path."* The number is async critical functions with neither. Nuance, exactly like AWS-026's X-Ray-adoption judgment: a function only ever invoked *synchronously* (behind API Gateway/ALB) marks this `not-in-scope`, not a fail — a synchronous caller gets the error back and owns the retry. Correlation with AWS-024: an `Errors` alarm tells you it failed; the DLQ/destination is what lets you REPLAY the lost event — an alarm with no DLQ means you know you lost data but cannot recover it. Complementary, not redundant. Fix: add a DLQ or `OnFailure` destination (`setup-aws#add-compute-health-alarms`; adding a destination changes function behavior, so it is a plan-only config write, never executed by the audit). Verify with `get-function-event-invoke-config` returning a non-empty `DestinationConfig.OnFailure`, or `get-function-configuration` showing a `DeadLetterConfig.TargetArn`.

## 8. Managed databases (AWS-030 to AWS-035)

Classify the deployment before judging any field. `rds.json`, `rds-clusters.json`, `docdb-instances.json`, and `docdb-clusters.json` are separate evidence sets.

| Deployment | AWS-030 HA evidence | AWS-031 backup owner | AWS-032 storage growth | AWS-033 lag signal | AWS-034 pressure signal |
| --- | --- | --- | --- | --- | --- |
| Standalone RDS instance (no `cluster_id`, non-replica) | `multi_az=true` on the instance | instance `backup_retention_days` | `MaxAllocatedStorage` present when supported | `ReplicaLag`, dimension `DBInstanceIdentifier`, on each read replica | `AWS/RDS`; instance dimensions; `CPUUtilization`, `DatabaseConnections`, `FreeableMemory` |
| Aurora cluster (`engine` starts with `aurora`) | at least one reader in a different Availability Zone from the writer, resolved by joining cluster members to `rds.json` | cluster `backup_retention_days` | `not-in-scope`: Aurora storage grows automatically | `AuroraReplicaLag` per reader or `AuroraReplicaLagMaximum` at cluster level, using the dimensions the live metric exposes | `AWS/RDS`; use `DBInstanceIdentifier` for instance metrics and `DBClusterIdentifier` only for cluster metrics |
| Non-Aurora RDS Multi-AZ DB cluster (`engine` mysql/postgres, `engine_mode` provisioned) | at least one reader in a different Availability Zone from the writer, resolved by joining cluster members to `rds.json` | cluster `backup_retention_days` | provisioned storage — assess `MaxAllocatedStorage`/storage-autoscaling like a standalone instance; **not** auto-grow | `ReplicaLag` (namespace `AWS/RDS`), **not** `AuroraReplicaLag`, using the dimensions the live metric exposes | `AWS/RDS`; use `DBInstanceIdentifier` for instance metrics and `DBClusterIdentifier` only for cluster metrics |
| DocumentDB cluster | at least one replica in a different Availability Zone from the writer, resolved by joining cluster members to `docdb-instances.json` | cluster `backup_retention_days` | `not-in-scope`: DocumentDB cluster storage grows automatically | `DBInstanceReplicaLag` per replica or `DBClusterReplicaLagMaximum` at cluster level, namespace `AWS/DocDB` | `AWS/DocDB`; use the exact live `DBInstanceIdentifier` or `DBClusterIdentifier` dimension |

`AWS-030` fails only the applicable HA row. An Aurora/DocumentDB member's instance-level `MultiAZ=false` or absent `MultiAZ` is not evidence of single-AZ architecture. `AWS-031` reads retention from the layer that owns backups. `AWS-032` never fails Aurora or DocumentDB for missing `MaxAllocatedStorage` (their storage auto-grows), but a **non-Aurora RDS Multi-AZ DB cluster** uses provisioned storage and IS assessed like a standalone instance — distinguish the two by `engine`/`engine_mode` in `rds-clusters.json`, and use `ReplicaLag` (not `AuroraReplicaLag`) for its AWS-033 lag signal. `AWS-033` and AWS-034 require namespace, metric, and dimension agreement with `list-metrics`/recent datapoints; an RDS metric name copied onto `AWS/DocDB` is a configuration defect, not coverage. Join every failed object to its dependent critical services and report the literal AZ/member/retention evidence rather than an assumed RPO or RTO. Business RPO/RTO comes only from the team's policy or service metadata; cloud configuration alone cannot establish it.

- ❌ `AWS-030 fail: the Aurora writer has MultiAZ=false.`
- ✅ `AWS-030 partial: the Aurora cluster has a writer and one reader, but both joined instance records resolve to the same Availability Zone; two dependent services share that cluster.`

### 8.1 Engine-aware event subscriptions (AWS-035)

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
# Discover the categories each service/source type actually supports before judging coverage.
aws_cli rds describe-event-categories --source-type db-instance --output json \
  | jq -r '.EventCategoriesMapList[] | "rds/db-instance\t\(.SourceEngine // "all-engines")\t\(.EventCategories|join(","))"'
aws_cli rds describe-event-categories --source-type db-cluster --output json \
  | jq -r '.EventCategoriesMapList[] | "rds/db-cluster\t\(.SourceEngine // "all-engines")\t\(.EventCategories|join(","))"'
aws_cli docdb describe-event-categories --source-type db-cluster --output json \
  | jq -r '.EventCategoriesMapList[] | "docdb/db-cluster\t\(.SourceEngine // "all-engines")\t\(.EventCategories|join(","))"'

# Event subscriptions ride a channel separate from CloudWatch metric alarms.
aws_cli rds describe-event-subscriptions --output json \
  | jq -r '.EventSubscriptionsList[]
      | "rds\t\(.CustSubscriptionId)\tsrc=\(.SourceType)\tenabled=\(.Enabled)\tsources=\((.SourceIdsList // [])|join(","))\tcats=\((.EventCategoriesList // [])|join(","))\ttopic=\(.SnsTopicArn)"'
aws_cli docdb describe-event-subscriptions --output json \
  | jq -r '.EventSubscriptionsList[]
      | "docdb\t\(.CustSubscriptionId)\tsrc=\(.SourceType)\tenabled=\(.Enabled)\tsources=\((.SourceIdsList // [])|join(","))\tcats=\((.EventCategoriesList // [])|join(","))\ttopic=\(.SnsTopicArn)"'

# Recent service events show whether an event occurred, not whether a human received it.
aws_cli rds describe-events --source-type db-instance --duration 20160 --output json \
  | jq -r '.Events[] | "rds\t\(.SourceIdentifier)\t\(.Date)\t\(.EventCategories|join(","))\t\(.Message)"'
aws_cli docdb describe-events --source-type db-cluster --duration 20160 --output json \
  | jq -r '.Events[] | "docdb\t\(.SourceIdentifier)\t\(.Date)\t\(.EventCategories|join(","))\t\(.Message)"'
```

Expected: every production database is covered by an enabled subscription at its actual service and source type, for the availability categories that `describe-event-categories` says that engine supports. An empty `EventCategoriesList` means all supported categories. Respect `SourceIdsList`: an explicit list covers only those IDs; an empty list covers all resources of that source type. Cross-check the topic with AWS-011 for confirmation, but do not claim human receipt without AWS-013 destination-side evidence. An unsupported category is `not-in-scope`, never a failure. A failed or denied category-discovery call blocks the category judgment; it is not safe to reuse a memorized RDS category list for DocumentDB.

- ❌ `AWS-035 fail: DocumentDB lacks the RDS low-storage event category.`
- ✅ `AWS-035 partial: the DocumentDB cluster has an enabled cluster subscription for every availability category returned by docdb describe-event-categories, but no destination-side receipt record was supplied; configuration passes and receipt remains unproven under AWS-013.`

## 9. Uptime and availability (AWS-040 to AWS-043)

`AWS-040` starts with an authority gate. A Route53 hosted zone in the account is not proof that public resolvers delegate the hostname to it. Confirm one of these before evaluating Route53-specific health coverage: (a) public NS answers match the hosted zone's delegation set, or (b) an authoritative team record explicitly says Route53 health checks are the monitoring control even though DNS is hosted elsewhere. If neither is available, mark AWS-040 `blocked`; if DNS authority and uptime monitoring are explicitly external, mark it `not-in-scope`. Do not file "Route53 health check missing."

Read-only authority comparison for a public zone:

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
ZONE_ID="your-public-hosted-zone-id"   # matching public zone from route53-hosted-zones.json
DNS_ZONE="example.com"                 # active public zone from service context
AWS_NS="$(aws_cli route53 get-hosted-zone --id "$ZONE_ID" --output json | jq -r '.DelegationSet.NameServers[]?' | sed 's/[.]$//' | tr 'A-Z' 'a-z' | sort)"
PUBLIC_NS="$(curl -fsS --max-time 15 "https://dns.google/resolve?name=${DNS_ZONE}&type=NS" | jq -r '.Answer[]? | select(.type == 2) | .data' | sed 's/[.]$//' | tr 'A-Z' 'a-z' | sort)"
printf 'route53_nameservers:\n%s\npublic_nameservers:\n%s\n' "$AWS_NS" "$PUBLIC_NS"
[ -n "$AWS_NS" ] && [ "$AWS_NS" = "$PUBLIC_NS" ] && echo "authority=confirmed" || echo "authority=not-confirmed"
```

Expected: `authority=confirmed` before Route53 absence can become an AWS-040 finding. For each in-scope health check, then join `list-resource-record-sets` (is its `HealthCheckId` referenced by routing?) and `describe-alarms` (does an alarm watch `AWS/Route53 HealthCheckStatus`?). A check referenced by neither is inert. Attach it to a routing policy or add a CloudWatch alarm; verification is a record-set reference or a matching alarm with `AlarmActions`. `AWS-041` remains independent: from `target-groups.json`, any disabled health check on a target group serving production traffic is a finding, then probe live health:

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

**Coverage denominator.** A full `describe-log-groups` pull is the eligible population. If cost, time, permissions, or the large-estate path limits deeper `describe-subscription-filters` checks to a subset, record `sampled=<n>/eligible=<N>`, the selection rule, the sampled log-group names, and `uninspected=<N-n>`. Findings may describe only the sampled groups. They must not say "all log groups," infer an estate-wide percentage, or pass the category from a subset.

`AWS-050`: from `log-groups.json`, cross-reference critical-service log group names against `aws logs describe-subscription-filters --log-group-name <name>`; an empty result on a critical group's log group is a candidate unless the team has a written decision that logs stay local to CloudWatch. **"log group X has no subscription filter / retention=null" carries no incident consequence and no service — deepen it, and distinguish the opposite failure (a short-but-finite retention) from a healthy one.** Join critical-service log groups (name pattern from topology) to their retention and subscription-filter state: *"`/aws/lambda/payments-callback` has `retentionInDays=null` and no subscription filter — nothing forwards to the central sink, so a cross-service incident can only be reconstructed one log group at a time,"* or the inverse *"`retentionInDays=1` on the `checkout` ALB access logs — a slow-burn incident opened Friday has no logs by Monday."* The number is critical-service log groups with null or sub-window retention and/or no forwarding. Correlation with AWS-052: no central app logs + no API-call trail is a single "no forensic story after an incident" cascade. Exact fix: add a subscription filter to the central sink for each critical group; set finite retention to the compliance window (never null, never 1 day on an incident-relevant group); remediation `setup-aws#enable-account-observability`. Verify with `describe-subscription-filters --log-group-name <name>` returning a filter and `describe-log-groups` showing `retentionInDays` at the compliance value. `AWS-051`: any critical log group with `retention_days: null` (meaning "Never expire") is the finding. `AWS-052`: from `cloudtrail.json`, at least one trail with `multi_region: true` must exist and be actively logging (`aws cloudtrail get-trail-status --name <trail>` returns `IsLogging: true`); absence is a critical, account-wide gap. **On top of that existing `IsLogging`/multi-region check, add two things the checkbox misses.** First, `describe-trails` also carries `LogFileValidationEnabled` — without it, delivered log files can be tampered with undetectably, so verify it is `true`. Second, state the forensic blast radius rather than reporting a checkbox: a trail that exists with `IsLogging=false`, or single-region, means API activity in other regions (and everything after any `StopLogging`) is unrecorded — *after a credential compromise you cannot reconstruct which resources the attacker touched or created.* Judge this once for the account, not per service, and state it as an account-wide gap. Fix: ensure one multi-region trail with `IsLogging=true` delivering to a locked-down S3 bucket with log-file validation enabled; remediation `setup-aws#enable-account-observability`. Verify with `get-trail-status --name <trail>` returning `IsLogging=true` and `describe-trails` showing `IsMultiRegionTrail=true` and `LogFileValidationEnabled=true`. `AWS-053`: from `config-recorders.json`, any recorder with `recording: false`, or an empty list entirely, is the finding. `AWS-054`: from `flow-logs.json`, any VPC carrying critical workloads absent from the list, or present with `status` other than `ACTIVE`, is the finding. `AWS-055` is a judgment step over the team's own answers: which backend receives forwarded logs, what retention, what redaction, who owns cost and access; without authoritative decision evidence this check is `blocked`, not a scored pass, partial, or fail.

For AWS-055, AWS fields answer only the technical questions: current `retentionInDays`, subscription-filter destination, encryption key, and tags. They do not prove who owns the sink, why a retention period was selected, whether it meets policy, or who approved cost/access. Pass AWS-055 only with a cited policy, runbook, repository record, or direct owner response covering those decisions. A tag is a lead to verify, not ownership proof. When no authoritative record is available, mark AWS-055 `blocked` with `decision evidence not supplied`; do not emit "no owner" or "no retention policy" as a verified fact.

- ❌ `AWS-055 fail: no Owner tag, therefore the log sink has no owner and no retention policy.`
- ✅ `AWS-055 blocked: AWS shows 30-day retention and an Owner tag, but no authoritative policy or owner confirmation was supplied, so ownership and policy compliance are unassessed.`

`AWS-056`: CloudWatch Logs anomaly detectors in a broken state. Read-only `list-log-anomaly-detectors`:

```bash
set -eu
aws_cli() { aws "$@"; }   # your resolved profile/region wrapper from section 4
RAW_DIR="${RAW_DIR:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/$(date -u +%F)/raw}"
mkdir -p "$RAW_DIR"
ANOMALY_OUT="${RAW_DIR}/log-anomaly-detectors.json"
ANOMALY_ERR="${RAW_DIR}/log-anomaly-detectors.stderr"
if aws_cli logs list-log-anomaly-detectors --output json >"$ANOMALY_OUT" 2>"$ANOMALY_ERR"; then
  jq -e '.anomalyDetectors | type == "array"' "$ANOMALY_OUT" >/dev/null \
    && jq -r '.anomalyDetectors[]? | "\(.detectorName // .anomalyDetectorArn)\t\(.anomalyDetectorStatus)"' "$ANOMALY_OUT" \
    || { echo "AWS-056 blocked: invalid detector-list response"; rm -f "$ANOMALY_OUT"; }
else
  echo "AWS-056 blocked: detector list failed; inspect ${ANOMALY_ERR}"
  rm -f "$ANOMALY_OUT"
fi
```

Expected: each detector's `anomalyDetectorStatus` is one of `INITIALIZING | TRAINING | ANALYZING | FAILED | DELETED | PAUSED`. A successful empty detector array means the opt-in feature is absent and is not a finding; a failed or invalid list is `blocked`, never absence. A `FAILED` or `PAUSED` detector on a critical log group is the AWS-056 finding: it looks configured but surfaces no anomalies. `INITIALIZING`/`TRAINING` are transient and informational.

- ❌ `Logs pass: CloudTrail is enabled.`
- ✅ `Logs partial: CloudTrail is enabled and multi-region (AWS-052 pass), but three production log groups have no retention set and no subscription filter, so incident logs age out silently with nothing centrally searchable (AWS-050 fail, AWS-051 fail, named log groups listed).`

## 11. Per-service coverage rows

Assemble one row per critical service from the raw captures; re-fetch any cell you are about to fail:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/${RUN_DATE}/raw"
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

Runnable commands for the large path named in [SKILL.md's Estate sizing](../SKILL.md#estate-sizing) and worked through in [Large-path worklist: resources in batches](../SKILL.md#large-path-worklist-resources-in-batches). This is the same run-ID-keyed, lock-and-resume mechanism as `do-checks.md` section 13 and `gcp-checks.md` section 16, adapted to AWS resource kinds; every block here is stateless and redeclares its own inputs. `AUDIT_ROOT` resolves under the current target segment via the shared enumerator (13.1 and 13.2 compute it): flat `aws/` for a single block, `aws/<label>/` for the `SCOUTFLO_TARGET`-selected item of a labeled list — so a multi-target run keeps each account's worklist and run state separate. The `RUN_DIR="…/aws/runs/<timestamp>"` lines in 13.3–13.6 are single-block **examples**; substitute the resolved `RUN_DIR` from 13.1 or 13.2 (which already carries the `aws/<label>/` segment for a labeled target). The per-resource pulls a batch runs (13.3, 13.5) use the same `--profile`/`--region` discipline as sections 4–12: fill in the target's own `aws.profile`/`aws.region`, never the ambient default.

### 13.1 Find a resumable run, or start a new one

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"

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
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"   # first-seen timestamp of this run; stable for its lifetime
RUN_DIR="${AUDIT_ROOT}/runs/${RUN_ID}"
mkdir -p "${RUN_DIR}"
echo "${RUN_ID}" > "${RUN_DIR}/run-id"
echo "run: ${RUN_ID}"
```

### 13.3 Build or resume the worklist

One row per resource, tab-separated: `kind` (`ec2`, `rds_instance`, `rds_cluster`, `docdb_instance`, `docdb_cluster`, `ecs_service`, `eks_cluster`, or `lambda`), `id`, `status` (`pending` or `done`).

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
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/runs/20260717T140500Z"   # example; resolved run directory from 13.1 or 13.2

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
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'rds_instance\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
  aws_cli rds describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text \
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'rds_cluster\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
  aws_cli docdb describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text \
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'docdb_instance\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
  aws_cli docdb describe-db-clusters --query 'DBClusters[].DBClusterIdentifier' --output text \
    | tr '\t' '\n' | while read -r id; do [ -n "$id" ] && printf 'docdb_cluster\t%s\tpending\n' "$id" >> "${WORKLIST}"; done
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
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/runs/20260717T140500Z"   # example; resolved run directory
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
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/runs/20260717T140500Z"   # example; resolved run directory
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
RUN_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/aws/runs/20260717T140500Z"   # example; resolved run directory
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
- `aws docdb modify-db-instance|modify-db-cluster|create-db-instance|create-db-cluster|delete-db-instance|delete-db-cluster|reboot-db-instance|failover-db-cluster`
- `aws ecs update-service|create-service|delete-service`, `aws eks update-cluster-config|delete-cluster`
- `aws lambda update-function-configuration|delete-function|put-function-concurrency`
- `aws route53 change-resource-record-sets|create-health-check|delete-health-check|update-health-check`
- `aws elbv2 modify-target-group|modify-listener|register-targets|deregister-targets`
- `aws logs put-retention-policy|delete-log-group|put-subscription-filter|delete-subscription-filter`
- `aws cloudtrail create-trail|update-trail|delete-trail|start-logging|stop-logging`
- `aws configservice put-configuration-recorder|start-configuration-recorder|stop-configuration-recorder`
- `aws configure`, or any command that mutates local AWS CLI profile state
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`
