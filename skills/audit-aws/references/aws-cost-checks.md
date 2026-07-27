# audit-aws: Cost & Resource Optimization Check Catalog

Runnable, read-only checks for the [Cost and Resource Optimization](../SKILL.md#phase-10-cost-and-resource-optimization-not-scored) section of [audit-aws](../SKILL.md). This section is never scored: every finding here carries `points_recoverable: 0` and `area: cost-optimization`, and none of it enters `score.categories` or `score.excluded`. IDs are `AWSOPT-NNN`, a separate registered prefix from the reliability catalog's `AWS-NNN` in [aws-checks.md](aws-checks.md), so a reader can tell which axis a finding belongs to at a glance.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding only when the number comes straight from an AWS-native recommendation API response, Compute Optimizer or Cost Explorer, copied verbatim, never recomputed from raw metrics against a price table you assembled. Every other finding in this file, unattached volumes, idle load balancers, snapshot sprawl, lifecycle gaps, is a presence or absence fact: report it with no dollar figure rather than invent one. This mirrors the toolkit-wide rule that errors are evidence, never invented; applied to cost, an unverified number is worse than no number, because it gets copied into a budget conversation.

- ❌ `AWSOPT-002: 6 EBS volumes unattached for 40+ days; at $0.10/GB-month that is roughly $180/mo wasted.`
- ✅ `AWSOPT-002: 6 EBS volumes unattached for 40+ days (names and sizes listed); no estimated_monthly_savings_usd field, since this signal has no AWS-native dollar figure behind it, only a presence fact.`

## 2. Check catalog

| ID | Signal | Source | Savings figure |
| --- | --- | --- | --- |
| AWSOPT-001 | EC2/RDS rightsizing recommendations | Compute Optimizer (`compute-optimizer:Get*`) | From Compute Optimizer's own `estimatedMonthlySavings` |
| AWSOPT-002 | Unattached EBS volumes | EC2 `Describe*` | None (presence fact) |
| AWSOPT-003 | Unassociated Elastic IPs | EC2 `Describe*` | None (presence fact) |
| AWSOPT-004 | Idle load balancers (zero requests over N days) | ELBv2/CloudWatch `Describe*`/`Get*` | None (presence fact) |
| AWSOPT-005 | Stopped-but-not-terminated EC2 instances | EC2 `Describe*` | None (presence fact) |
| AWSOPT-006 | Savings Plan coverage gap | Cost Explorer (`ce:GetSavingsPlansCoverage`) | From Cost Explorer's own coverage percentage |
| AWSOPT-007 | Reserved Instance coverage gap | Cost Explorer (`ce:GetReservationCoverage`) | From Cost Explorer's own coverage percentage |
| AWSOPT-008 | Broader cost/security/fault-tolerance checks | Trusted Advisor (`support:Describe*`), Business/Enterprise support only | From Trusted Advisor's own estimate, when it provides one |
| AWSOPT-009 | S3 buckets with no lifecycle rule holding aged Standard-class objects | S3 `Get*`/`List*` | None (presence fact) |
| AWSOPT-010 | EBS/RDS snapshot sprawl against the team's stated retention policy | EC2/RDS `Describe*` | None (presence fact) |
| AWSOPT-011 | Aggregated cross-service recommendations from Cost Optimization Hub | Cost Optimization Hub (`cost-optimization-hub:List*`), enrollment required | From the Hub's own `estimatedMonthlySavings` |

## 3. Doctor-gate dependency

Every check here depends on the doctor gate's optional cost-permission probe (`skills/doctor/scripts/doctor.sh`, the `aws cost-permissions` row). That probe runs `compute-optimizer get-enrollment-status` and never fails the main doctor gate; a missing scope there, or `aws.cost_checks: false` in `toolkit.yaml`, means this whole section reports itself `excluded` with the doctor's own reason, rather than running some checks and guessing at the rest:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # written by the doctor gate this run, or the most recent doctor run
[ -f "$MATRIX" ] || { echo "no doctor matrix found; run the doctor gate before Phase 10"; exit 1; }
awk -F'\t' '$1 == "aws" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"
```

Expected: `pass -` when cost checks can run, or `skipped <reason>` when they cannot. A `skipped` result means Phase 10 renders exactly one line: "Cost & Resource Optimization: excluded, reason: <the exact hint from the matrix row>", and none of AWSOPT-001 through AWSOPT-010 runs this cycle. AWSOPT-002, AWSOPT-003, AWSOPT-005, AWSOPT-009, and AWSOPT-010 need only plain `Describe*`/`Get*`/`List*` permissions already covered by the reliability doctor probe, so they may still run even when the Compute Optimizer/Cost Explorer/Trusted Advisor scopes are missing; state that split explicitly rather than excluding the whole section when only part of it is blocked.

## 4. Rightsizing (AWSOPT-001)

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
aws_cli compute-optimizer get-enrollment-status --output json | jq -r '.status'
```

**AWSOPT-011 (Cost Optimization Hub).** The Hub aggregates rightsizing, idle-resource, and commitment recommendations across services into one place, each with a native `estimatedMonthlySavings` figure. Like Compute Optimizer, it requires enrollment; check that first, and on a non-enrolled account report `excluded, reason: "Cost Optimization Hub not enrolled"`, never an empty pass. All three operations are read-only `List*`.

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile
# Cost Optimization Hub is a SINGLE-ENDPOINT service in the aws partition: it exists ONLY
# in us-east-1. Do NOT map this from aws.region — for a customer whose account region is not
# us-east-1, targeting cost-optimization-hub.<their-region>... hits a non-existent endpoint and
# fails. Pin us-east-1 here (like the Trusted Advisor block), regardless of the audit region.
COH_REGION="us-east-1"
coh_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" --region "$COH_REGION" "$@"
  else
    aws --region "$COH_REGION" "$@"
  fi
}
# Enrollment first: recommendations are empty unless the account has opted in. Capture the
# exit status — an endpoint/permission error must be reported as BLOCKED, not silently
# reinterpreted as "not enrolled" (which is what `2>/dev/null | ... // "NOT_ENROLLED"` did).
if COH_ENROLL="$(coh_cli cost-optimization-hub list-enrollment-statuses --output json 2>/tmp/coh-err)"; then
  echo "$COH_ENROLL" | jq -r '.items[]?.status // "NOT_ENROLLED"'
  # When enrolled, pull the aggregated recommendations; the savings field is exactly
  # estimatedMonthlySavings (not estimatedMonthlySavingsAmount) — take it verbatim, never recompute.
  coh_cli cost-optimization-hub list-recommendations --output json \
    | jq -r '.items[]? | "\(.recommendationId)\t\(.currentResourceType)\t\(.estimatedMonthlySavings)"'
else
  echo "AWSOPT-011 BLOCKED: cost-optimization-hub (us-east-1) call failed — $(cat /tmp/coh-err). Report as blocked (endpoint/permission), NOT as 'not enrolled'."
fi
```

Expected: an `Active` enrollment status, then one line per recommendation with the Hub's own `estimatedMonthlySavings`. Anything other than an active enrollment means AWSOPT-011 reports `excluded, reason: "Cost Optimization Hub not enrolled"` and stops. The dollar figure is reported verbatim from `estimatedMonthlySavings`, never recomputed.

Expected: `Active`. Anything else (`Inactive`, `Pending`, an `AccessDeniedException`) means AWSOPT-001 reports `excluded, reason: "Compute Optimizer not enrolled for this account"` and stops; never fall back to a CPU-percentage-based estimate computed from `cloudwatch get-metric-statistics`. When active, pull recommendations directly:

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
# NOTE: Compute Optimizer's `finding` enum is mixed-case ("Optimized",
# "Underprovisioned", "Overprovisioned", "NotOptimized") — NOT uppercase. Comparing
# against "OPTIMIZED" never matches, so every optimized instance would be falsely flagged.
aws_cli compute-optimizer get-ec2-instance-recommendations --output json \
  | jq '[.instanceRecommendations[]? | select(.finding != "Optimized") | {
      instance: .instanceArn, finding: .finding,
      current_type: .currentInstanceType,
      recommended_type: (.recommendationOptions[0].instanceType // null),
      estimated_monthly_savings_usd: (.recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]'
# RDS recommendations: the per-resource classification field is `instanceFinding`
# (mixed-case enum "Optimized"/"Underprovisioned"/"Overprovisioned"), NOT `finding`, and
# savings come verbatim from instanceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value
# — never a boolean. Emit the recommended class from instanceRecommendationOptions[0].dbInstanceClass.
aws_cli compute-optimizer get-rds-database-recommendations --output json \
  | jq '[.rdsDBRecommendations[]? | select(.instanceFinding != "Optimized") | {
      instance: .resourceArn, finding: .instanceFinding,
      recommended_class: (.instanceRecommendationOptions[0].dbInstanceClass // null),
      estimated_monthly_savings_usd: (.instanceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true
```

Expected: zero or more entries, each carrying Compute Optimizer's own `finding` classification and, when present, its own `estimatedMonthlySavings.value`. Copy that number verbatim into `estimated_monthly_savings_usd`; when the field is absent from the API response, omit it from the finding entirely rather than estimating one.

- ❌ `AWSOPT-001: db-primary sits at 12% average CPU over 14 days; sized down to db.r5.large would save an estimated $340/mo based on the public RDS price list.`
- ✅ `AWSOPT-001: Compute Optimizer rates db-primary "Over-provisioned", recommends db.r5.large; estimated_monthly_savings_usd is 340.00, copied directly from recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value.`

## 5. Idle and unattached resources (AWSOPT-002 to AWSOPT-005)

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
# AWSOPT-002: unattached EBS volumes.
aws_cli ec2 describe-volumes --filters 'Name=status,Values=available' --output json \
  | jq '[.Volumes[] | {id: .VolumeId, size_gb: .Size, created: .CreateTime}]'
# AWSOPT-003: unassociated Elastic IPs.
aws_cli ec2 describe-addresses --output json \
  | jq '[.Addresses[] | select(.AssociationId == null) | {allocation_id: .AllocationId, public_ip: .PublicIp}]'
# AWSOPT-005: stopped-but-not-terminated instances.
aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=stopped' --output json \
  | jq '[.Reservations[].Instances[] | {id: .InstanceId, type: .InstanceType, stopped_reason: (.StateTransitionReason // "")}]'
```

Expected: any non-empty array is a presence-fact finding, named per resource ID, no dollar figure attached. `AWSOPT-004`, idle load balancers, needs a CloudWatch lookback per load balancer:

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
LB_NAME="app/your-lb/1234567890abcdef"   # each load balancer's dimension value from the inventory
IDLE_DAYS="14"                            # example, tune to your traffic patterns
START="$(date -u -v-${IDLE_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${IDLE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
aws_cli cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions "Name=LoadBalancer,Value=${LB_NAME}" --start-time "$START" --end-time "$END" \
  --period 86400 --statistics Sum --output json | jq '[.Datapoints[].Sum] | add // 0'
```

Expected: a request-count sum over the window. `0` over `IDLE_DAYS` days on a load balancer that is not explicitly a standby or DR target is the finding, again with no dollar estimate unless Trusted Advisor separately reports one for the same resource.

## 6. Coverage gaps (AWSOPT-006, AWSOPT-007)

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" "$@"
  else
    aws "$@"
  fi
}
# Cost Explorer is a global (us-east-1) service; region flags are omitted deliberately.
START="$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)"
END="$(date -u +%Y-%m-%d)"
aws_cli ce get-savings-plans-coverage --time-period "Start=${START},End=${END}" --output json \
  | jq '.SavingsPlansCoverages[]? | {coverage_pct: .Coverage.CoveragePercentage}' 2>&1 \
  || echo "ce:GetSavingsPlansCoverage denied or unavailable; AWSOPT-006 reports excluded"
aws_cli ce get-reservation-coverage --time-period "Start=${START},End=${END}" --output json \
  | jq '.CoveragesByTime[0].Total.CoverageHours.CoverageHoursPercentage' 2>&1 \
  || echo "ce:GetReservationCoverage denied or unavailable; AWSOPT-007 reports excluded"
```

Expected: a coverage percentage for each. Report the percentage Cost Explorer returns directly; never estimate a potential saving independently from the gap. A permission error or an account with no Cost Explorer data yet means the row reports `excluded` with the reason, not a guessed `0%`.

## 7. Trusted Advisor (AWSOPT-008)

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" --region us-east-1 "$@"
  else
    aws --region us-east-1 "$@"
  fi
}
# Trusted Advisor's API is only reachable from us-east-1 regardless of your default region.
aws_cli support describe-trusted-advisor-checks --language en --output json \
  | jq '[.checks[] | select(.category == "cost_optimizing") | {id: .id, name: .name}]' 2>&1 \
  || echo "support:Describe* denied or account lacks Business/Enterprise support; AWSOPT-008 reports excluded"
```

Expected: a list of cost-optimizing check IDs, or the denial line. On success, pull each check's result with `aws support describe-trusted-advisor-check-result --check-id <id>` and report flagged resources with whatever savings estimate Trusted Advisor itself provides in `flaggedResources[].metadata`; never recompute one. On denial, `AWSOPT-008` reports `excluded, reason: "Trusted Advisor requires Business or Enterprise support"`, exactly like any other excluded category in this toolkit, never silently skipped.

## 8. S3 lifecycle and snapshot sprawl (AWSOPT-009, AWSOPT-010)

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
BUCKET_NAME="your-bucket"   # each bucket from `aws s3api list-buckets`
aws_cli s3api get-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" --output json 2>&1 \
  || echo "no lifecycle configuration on ${BUCKET_NAME}; AWSOPT-009 candidate if it holds aged Standard-class objects"

# AWSOPT-010: snapshot age against the team's stated retention policy (no assumed default).
aws_cli ec2 describe-snapshots --owner-ids self --output json \
  | jq '[.Snapshots[] | {id: .SnapshotId, volume: .VolumeId, start: .StartTime}]'
aws_cli rds describe-db-snapshots --output json \
  | jq '[.DBSnapshots[] | {id: .DBSnapshotIdentifier, instance: .DBInstanceIdentifier, created: .SnapshotCreateTime}]'
```

Expected: `AWSOPT-009` fires only for a bucket with no lifecycle configuration that also, per a separate size check (`aws s3api list-objects-v2` sampled, or S3 Storage Lens if enabled), holds objects older than a reasonable age still in the Standard storage class; a lifecycle-free bucket used purely as a short-lived staging area is not a finding. `AWSOPT-010` compares each snapshot's age against your team's own stated retention policy, never an assumed default; if the team has not stated one, say so in the finding instead of picking a number for them.

## 9. Rendering the section

Every finding here uses `area: cost-optimization`, `points_recoverable: 0`, and a remediation pointer of `setup-aws#plan-cost-optimizations` (plan-only; v1 never automates a resize or a deletion from a savings recommendation, per the four change-risk classes in [SKILL.md](../SKILL.md#the-four-change-risk-classes)). Render the section as its own table, columns `Finding | Resource | Signal source | Estimated monthly savings if AWS-sourced | Action`, immediately after Scoutflo Topology Readiness in `report.md`, per [report-template.md](../../../report-standard/report-template.md)'s parallel non-scored section pattern. A row with no AWS-sourced savings figure prints `-` in that column rather than a blank, so it reads as "checked, no number available" rather than "forgot to fill this in".
