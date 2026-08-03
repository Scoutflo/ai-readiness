# audit-cost (AWS): deep per-resource cost check catalog

Runnable, strictly read-only checks for the AWS phase of [audit-cost](../SKILL.md). This is the **first-class, deep** cost audit — it queries AWS's own cost surfaces live and reports **per-resource** results (which resource, its ARN/ID, region, size, age, utilization), not a re-aggregation of another audit. It supersedes the thin `cost-analysis` re-aggregator and **deepens the `audit-aws` pack's `AWSOPT-*` set** ([aws-cost-checks.md](../../audit-aws/references/aws-cost-checks.md)); the two stay consistent — same one-hard-rule, same native-$ sources, same forbidden verbs — but `COST-AWS-*` IDs are a distinct, permanently-registered prefix so a reader can tell a deep-cost finding from the audit-aws parallel-section finding at a glance.

Findings from this catalog live in the `scoutflo-cost/v1` result (a savings summary + ranked findings, **no 0-100 score**). Every finding carries `area: cost-optimization`, `points_recoverable: 0`, names a concrete resource in `affected`, and quotes real command output in `evidence`. IDs are permanent and never reused or renumbered.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied **verbatim** from a provider-native AWS recommendation API response — Compute Optimizer `savingsOpportunity.estimatedMonthlySavings.value`, Cost Explorer purchase-recommendation `EstimatedMonthlySavingsAmount`, Cost Optimization Hub `estimatedMonthlySavings`, or Trusted Advisor `flaggedResources[].metadata` — never recomputed from raw metrics against a price table you assembled. Everything else in this file is a **presence/absence fact** (unattached volumes, idle load balancers, snapshot sprawl, gp2 volumes, previous-generation families) reported with **no dollar figure** rather than an invented one. An unverified number is worse than no number: it gets pasted into a budget conversation.

- ❌ `COST-AWS-016: 6 EBS volumes unattached for 40+ days; at $0.10/GB-month that is roughly $180/mo wasted.`
- ✅ `COST-AWS-016: 6 EBS volumes unattached (vol-0a1… 100 GiB gp3 ap-south-2a created 2026-05-01, … listed); no estimated_monthly_savings_usd — this is a presence fact, AWS returns no native dollar figure for it.`

**Two provider dollars that are NOT `estimated_monthly_savings_usd`.** Some AWS APIs return a real dollar that is *not a projected savings from an action*, and it must never be summed into the savings line:

- **Unused commitment** from `ce get-savings-plans-utilization` / `get-reservation-utilization` (`UnusedCommitment`) is money **already spent** on an idle commitment you are locked into — not a saving you can capture by acting. Report it verbatim in the finding body as "unused committed spend per the utilization API", never in `estimated_monthly_savings_usd`.
- **Anomaly impact** from `ce get-anomalies` (`Impact.TotalImpact`) is **anomalous spend detected**, not a recommended saving. Report it verbatim as "anomalous spend", never in `estimated_monthly_savings_usd`.

Coverage APIs (`GetSavingsPlansCoverage`, `GetReservationCoverage`) return a **percentage**, not a dollar — report the percentage AWS gives, never derive a saving from the gap.

## 2. Config placeholders and the region rule

Every command uses an `aws_cli` helper reading two placeholders from `~/.scoutflo/toolkit.yaml`: `aws.profile` (empty means the default credential chain) and `aws.region`. Set both to the account you are auditing. Run `aws sts get-caller-identity` with the same `--profile`/`--region` and confirm the account before any read.

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile — set to the audited account's profile (empty = default credential chain)
AWS_REGION_CFG="us-east-1"    # aws.region — set to the audited account's region (example)
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
```

**The region rule (critical for a non-`us-east-1` account like `ap-south-2`).** Three services are single-endpoint globals reachable **only from `us-east-1`**, regardless of `aws.region`:

- **Cost Explorer** (`ce`) — a global service; omit `--region` (it resolves to the global endpoint).
- **Cost Optimization Hub** (`cost-optimization-hub`) — exists **only** in `us-east-1`; pin `--region us-east-1`.
- **Trusted Advisor** (`support`) — API reachable **only** from `us-east-1`; pin `--region us-east-1`.

Targeting these at `ap-south-2` hits a non-existent endpoint and fails. **Compute Optimizer** (`compute-optimizer`), by contrast, is **regional** — it returns recommendations only for the region you call, so a multi-region account needs one call per active region. This catalog pins the globals to `us-east-1` explicitly in each block and never maps them from `aws.region`.

## 3. Check catalog

| ID | Signal | Source API (read-only) | Savings figure |
| --- | --- | --- | --- |
| COST-AWS-001 | EC2 instance rightsizing / over-provisioning | Compute Optimizer `get-ec2-instance-recommendations` | Native $ — `savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-002 | RDS instance rightsizing | Compute Optimizer `get-rds-database-recommendations` | Native $ — `instanceRecommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-003 | Lambda memory over/under-provisioning | Compute Optimizer `get-lambda-function-recommendations` | Native $ — `memorySizeRecommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-004 | Auto Scaling Group instance-type rightsizing | Compute Optimizer `get-auto-scaling-group-recommendations` | Native $ — `recommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-005 | EBS volume rightsizing (size/type) | Compute Optimizer `get-ebs-volume-recommendations` | Native $ — `volumeRecommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-006 | ECS/Fargate service rightsizing | Compute Optimizer `get-ecs-service-recommendations` | Native $ — `serviceRecommendationOptions[].savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-007 | Idle resources (EC2/ASG/EBS/ELB/RDS idle) | Compute Optimizer `get-idle-recommendations` | Native $ — `savingsOpportunity.estimatedMonthlySavings.value` |
| COST-AWS-008 | Savings Plans purchase opportunity | Cost Explorer `get-savings-plans-purchase-recommendation` | Native $ — `...Summary.EstimatedMonthlySavingsAmount` |
| COST-AWS-009 | Reserved Instance purchase opportunity | Cost Explorer `get-reservation-purchase-recommendation` | Native $ — `RecommendationDetails[].EstimatedMonthlySavingsAmount` |
| COST-AWS-010 | Savings Plans coverage gap | Cost Explorer `get-savings-plans-coverage` | Metric fact — coverage % (no $) |
| COST-AWS-011 | Reserved Instance coverage gap | Cost Explorer `get-reservation-coverage` | Metric fact — coverage % (no $) |
| COST-AWS-012 | Savings Plans / RI unused-commitment waste | Cost Explorer `get-savings-plans-utilization` / `get-reservation-utilization` | Provider $ (unused commitment) — reported, **not** summed into savings |
| COST-AWS-013 | Cross-service aggregated recommendations | Cost Optimization Hub `list-recommendations` (enrollment-gated) | Native $ — `estimatedMonthlySavings` |
| COST-AWS-014 | Trusted Advisor cost-optimizing checks | Support `describe-trusted-advisor-check-result` (Business/Enterprise) | Native $ — `flaggedResources[].metadata` estimate |
| COST-AWS-015 | Active cost anomalies | Cost Explorer `get-anomalies` | Provider $ (anomalous spend) — reported, **not** summed into savings |
| COST-AWS-016 | Unattached EBS volumes | EC2 `describe-volumes` | None (presence fact) |
| COST-AWS-017 | Unassociated Elastic IPs | EC2 `describe-addresses` | None (presence fact) |
| COST-AWS-018 | Idle load balancers (zero requests N days) | ELBv2 `describe-load-balancers` + CloudWatch `get-metric-statistics` | None (presence fact) |
| COST-AWS-019 | Stopped-but-not-terminated EC2 instances | EC2 `describe-instances` | None (presence fact) |
| COST-AWS-020 | Aged EBS/RDS snapshots vs stated retention | EC2 `describe-snapshots` / RDS `describe-db-snapshots` | None (presence fact) |
| COST-AWS-021 | S3 buckets with no lifecycle holding aged Standard objects | S3 `get-bucket-lifecycle-configuration` + `list-objects-v2` / Storage Lens | None (presence fact) |
| COST-AWS-022 | gp2 → gp3 EBS migration candidates | EC2 `describe-volumes` | None (presence fact) |
| COST-AWS-023 | Previous-generation instance families | EC2 `describe-instances` | None (presence fact) |
| COST-AWS-024 | Idle NAT gateways (zero bytes N days) | EC2 `describe-nat-gateways` + CloudWatch `get-metric-statistics` | None (presence fact) |

## 4. Doctor-probe dependency (which cost scope each check needs)

`audit-cost`'s doctor gate runs one cheap read-only cost-permission probe per configured provider and writes a matrix row. A **missing cost scope EXCLUDES the affected check(s) with the doctor's stated reason** — it never fails the run and never guesses a value. Read the row this run wrote:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # this run's doctor gate, or most recent
[ -f "$MATRIX" ] || { echo "no doctor matrix; run the doctor gate before the AWS cost phase"; exit 1; }
awk -F'\t' '$1 == "aws" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"   # e.g. "pass -" or "skipped <reason>"
```

The scope split, so a partial block excludes only what it must rather than the whole AWS phase:

| Scope group | Checks that need it | Probe / enrollment | On missing scope |
| --- | --- | --- | --- |
| Compute Optimizer enrolled | COST-AWS-001…007 | `compute-optimizer get-enrollment-status` returns `Active` | Those seven report `excluded, reason: "Compute Optimizer not enrolled"` — never a CPU-percent estimate |
| Cost Explorer (`ce:Get*`) | COST-AWS-008…012, 015 | `ce get-savings-plans-coverage` for a 1-day window succeeds | Those report `excluded, reason: "ce:Get* denied or Cost Explorer not enabled"` |
| Cost Optimization Hub enrolled | COST-AWS-013 | `cost-optimization-hub list-enrollment-statuses` shows `Active` | `excluded, reason: "Cost Optimization Hub not enrolled"` |
| Trusted Advisor (`support:*`, Business/Enterprise) | COST-AWS-014 | `support describe-trusted-advisor-checks` succeeds | `excluded, reason: "Trusted Advisor requires Business or Enterprise support"` |
| Plain `Describe*`/`Get*`/`List*` (already in the reliability probe) | COST-AWS-016…024 | covered by the base AWS doctor probe | run even when the cost scopes above are missing — state the split explicitly, never exclude the whole phase for a partial block |

## 5. Read-only verbs used (the whole surface)

`sts get-caller-identity`; `compute-optimizer get-enrollment-status` / `get-ec2-instance-recommendations` / `get-rds-database-recommendations` / `get-lambda-function-recommendations` / `get-auto-scaling-group-recommendations` / `get-ebs-volume-recommendations` / `get-ecs-service-recommendations` / `get-idle-recommendations`; `ce get-savings-plans-purchase-recommendation` / `get-reservation-purchase-recommendation` / `get-savings-plans-coverage` / `get-reservation-coverage` / `get-savings-plans-utilization` / `get-reservation-utilization` / `get-anomalies` / `get-anomaly-monitors`; `cost-optimization-hub list-enrollment-statuses` / `list-recommendations` / `list-recommendation-summaries`; `support describe-trusted-advisor-checks` / `describe-trusted-advisor-check-result`; `ec2 describe-volumes` / `describe-addresses` / `describe-instances` / `describe-snapshots` / `describe-nat-gateways`; `rds describe-db-snapshots`; `elbv2 describe-load-balancers`; `cloudwatch get-metric-statistics`; `s3api list-buckets` / `get-bucket-lifecycle-configuration` / `list-objects-v2` / `get-bucket-location`. Every one is a `get-*`/`describe-*`/`list-*` read. Nothing here writes.

## 6. Compute Optimizer rightsizing (COST-AWS-001 … 006)

Enrollment first — recommendations are empty and the finding is `excluded` (never a metrics-derived guess) unless the account shows `Active`:

```bash
aws_cli compute-optimizer get-enrollment-status --output json | jq -r '.status'
```

Expected `Active`. `Inactive`/`Pending`/`AccessDeniedException` → COST-AWS-001…007 all report `excluded, reason: "Compute Optimizer not enrolled"`. When active, pull each family. Note the `finding` enum is **mixed-case** (`Optimized`, `Overprovisioned`, `Underprovisioned`, `NotOptimized`) — comparing against `"OPTIMIZED"` never matches and would falsely flag every healthy resource.

```bash
# COST-AWS-001 EC2 — per instance: current type, recommended type, native $.
aws_cli compute-optimizer get-ec2-instance-recommendations --output json \
  | jq '[.instanceRecommendations[]? | select(.finding != "Optimized") | {
      instance: .instanceArn, name: (.instanceName // null), finding: .finding,
      current_type: .currentInstanceType,
      recommended_type: (.recommendationOptions[0].instanceType // null),
      estimated_monthly_savings_usd: (.recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]'

# COST-AWS-002 RDS — classification field is `instanceFinding` (NOT `finding`); recommended class from instanceRecommendationOptions[0].dbInstanceClass.
aws_cli compute-optimizer get-rds-database-recommendations --output json \
  | jq '[.rdsDBRecommendations[]? | select(.instanceFinding != "Optimized") | {
      instance: .resourceArn, finding: .instanceFinding,
      recommended_class: (.instanceRecommendationOptions[0].dbInstanceClass // null),
      estimated_monthly_savings_usd: (.instanceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true

# COST-AWS-003 Lambda — memory rightsizing.
aws_cli compute-optimizer get-lambda-function-recommendations --output json \
  | jq '[.lambdaFunctionRecommendations[]? | select(.finding != "Optimized") | {
      function: .functionArn, finding: .finding,
      current_memory_mb: .currentMemorySize,
      recommended_memory_mb: (.memorySizeRecommendationOptions[0].memorySize // null),
      estimated_monthly_savings_usd: (.memorySizeRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true

# COST-AWS-004 Auto Scaling Group — instance-type rightsizing.
aws_cli compute-optimizer get-auto-scaling-group-recommendations --output json \
  | jq '[.autoScalingGroupRecommendations[]? | select(.finding != "Optimized") | {
      asg: .autoScalingGroupArn, finding: .finding,
      current_type: (.currentConfiguration.instanceType // null),
      recommended_type: (.recommendationOptions[0].configuration.instanceType // null),
      estimated_monthly_savings_usd: (.recommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true

# COST-AWS-005 EBS volume — size/type rightsizing.
aws_cli compute-optimizer get-ebs-volume-recommendations --output json \
  | jq '[.volumeRecommendations[]? | select(.finding != "Optimized") | {
      volume: .volumeArn, finding: .finding,
      recommended_type: (.volumeRecommendationOptions[0].configuration.volumeType // null),
      recommended_size_gb: (.volumeRecommendationOptions[0].configuration.volumeSize // null),
      estimated_monthly_savings_usd: (.volumeRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true

# COST-AWS-006 ECS/Fargate service — CPU/memory task rightsizing.
aws_cli compute-optimizer get-ecs-service-recommendations --output json \
  | jq '[.ecsServiceRecommendations[]? | select(.finding != "Optimized") | {
      service: .serviceArn, finding: .finding,
      estimated_monthly_savings_usd: (.serviceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true
```

**Expected:** zero or more entries per family, each carrying Compute Optimizer's own `finding` classification and, where present, its own `estimatedMonthlySavings.value`. Copy that number **verbatim** into `estimated_monthly_savings_usd`; when the field is absent (`null`), **omit** it from the finding rather than estimate one. A failure means: this account has over/under-provisioned resources AWS itself flags, with AWS's own projected monthly savings for the recommended shape.

- ❌ `COST-AWS-002: db-primary sits at 12% CPU over 14 days; down to db.r5.large saves ~$340/mo per the public price list.`
- ✅ `COST-AWS-002: Compute Optimizer rates db-primary "Overprovisioned", recommends db.r5.large; estimated_monthly_savings_usd = 340.00, copied from instanceRecommendationOptions[0].savingsOpportunity.estimatedMonthlySavings.value.`

## 7. Idle resources (COST-AWS-007)

Compute Optimizer's idle finder aggregates idle EC2, ASGs, EBS, ELBs, and RDS into one call, each with a native monthly-savings figure:

```bash
aws_cli compute-optimizer get-idle-recommendations --output json \
  | jq '[.idleRecommendations[]? | select(.finding != "Active") | {
      resource: .resourceArn, id: .resourceId, type: .resourceType, finding: .finding,
      summary: (.findingDescription // null),
      estimated_monthly_savings_usd: (.savingsOpportunity.estimatedMonthlySavings.value // null)}]' 2>/dev/null || true
```

**Expected:** one entry per resource Compute Optimizer classifies idle (`finding` is `Idle`; `Active` = not idle), with `resourceType` (`EC2Instance`, `AutoScalingGroup`, `EBSVolume`, `ECSService`, `RDSDBInstance`) and its own `estimatedMonthlySavings.value`. Copy verbatim; omit when `null`. A failure means AWS confirms specific resources are idle and gives its own monthly cost of keeping them.

## 8. Savings Plans / RI commitments (COST-AWS-008 … 012)

**Purchase recommendations carry the native dollar** (`EstimatedMonthlySavingsAmount`); coverage returns a **percentage**; utilization returns **unused-commitment dollars** (waste already incurred, not a projected saving — never summed). Cost Explorer is global — **omit `--region`**.

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile (empty = default credential chain)
ce_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" "$@"; else aws "$@"; fi; }   # NO --region: ce is global
START="$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)"
END="$(date -u +%Y-%m-%d)"

# COST-AWS-008 Savings Plans purchase opportunity — native $ from the summary.
ce_cli ce get-savings-plans-purchase-recommendation \
    --savings-plans-type COMPUTE_SP --term-in-years ONE_YEAR --payment-option NO_UPFRONT \
    --lookback-period-in-days THIRTY_DAYS --output json \
  | jq '{estimated_monthly_savings_usd: (.SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary.EstimatedMonthlySavingsAmount // null),
         estimated_savings_pct: (.SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary.EstimatedSavingsPercentage // null),
         hourly_commitment: (.SavingsPlansPurchaseRecommendation.SavingsPlansPurchaseRecommendationSummary.HourlyCommitmentToPurchase // null)}' \
  2>&1 || echo "ce:GetSavingsPlansPurchaseRecommendation denied/unavailable; COST-AWS-008 excluded"

# COST-AWS-009 Reserved Instance purchase opportunity — native $ per recommendation detail (example: RDS).
ce_cli ce get-reservation-purchase-recommendation --service "Amazon Relational Database Service" \
    --lookback-period-in-days THIRTY_DAYS --term-in-years ONE_YEAR --payment-option NO_UPFRONT --output json \
  | jq '[.Recommendations[]?.RecommendationDetails[]? | {
      instance_family: (.InstanceDetails.RDSInstanceDetails.InstanceType // .InstanceDetails // null),
      recommended_units: .RecommendedNumberOfInstancesToPurchase,
      estimated_monthly_savings_usd: .EstimatedMonthlySavingsAmount,
      estimated_savings_pct: .EstimatedMonthlySavingsPercentage}]' \
  2>&1 || echo "ce:GetReservationPurchaseRecommendation denied/unavailable; COST-AWS-009 excluded"

# COST-AWS-010 Savings Plans coverage gap — a PERCENTAGE, no $.
ce_cli ce get-savings-plans-coverage --time-period "Start=${START},End=${END}" --output json \
  | jq '[.SavingsPlansCoverages[]? | {period: .TimePeriod, coverage_pct: .Coverage.CoveragePercentage,
         on_demand_cost: .Coverage.OnDemandCost}]' \
  2>&1 || echo "ce:GetSavingsPlansCoverage denied/unavailable; COST-AWS-010 excluded"

# COST-AWS-011 RI coverage gap — a PERCENTAGE, no $.
ce_cli ce get-reservation-coverage --time-period "Start=${START},End=${END}" --output json \
  | jq '.Total.CoverageHours.CoverageHoursPercentage' \
  2>&1 || echo "ce:GetReservationCoverage denied/unavailable; COST-AWS-011 excluded"

# COST-AWS-012 Unused-commitment waste — provider $ (already spent), reported NOT summed.
ce_cli ce get-savings-plans-utilization --time-period "Start=${START},End=${END}" --granularity MONTHLY --output json \
  | jq '.Total.Utilization | {utilization_pct: .UtilizationPercentage,
         unused_commitment_usd: .UnusedCommitment, total_commitment_usd: .TotalCommitment}' \
  2>&1 || echo "ce:GetSavingsPlansUtilization denied/unavailable; COST-AWS-012 (SP) excluded"
ce_cli ce get-reservation-utilization --time-period "Start=${START},End=${END}" --granularity MONTHLY --output json \
  | jq '.Total | {utilization_pct: .UtilizationPercentage, unused_hours: .UnusedHours}' \
  2>&1 || true
```

**Expected & failure meaning.** COST-AWS-008/009: a purchase recommendation with AWS's own `EstimatedMonthlySavingsAmount` — copy verbatim into `estimated_monthly_savings_usd`. (`--savings-plans-type`, `--term-in-years`, `--payment-option`, and `--service` are clearly-marked knobs; record the exact values used in evidence so the number is reproducible.) COST-AWS-010/011: report the coverage percentage AWS returns; a low percentage on steady-state compute is the finding — **no `$`**, never a saving derived from the gap. COST-AWS-012: `UnusedCommitment` > 0 or utilization well under 100% means committed spend is being wasted; quote the dollar in the finding body as "unused committed spend per the utilization API", **never** in `estimated_monthly_savings_usd`. A permission error or an account with no Cost Explorer data yet means the row is `excluded` with the reason, not a guessed `0`.

## 9. Cost Optimization Hub (COST-AWS-013)

The Hub aggregates rightsizing, idle, and commitment recommendations across services into one place, each with a native `estimatedMonthlySavings`. It is **`us-east-1`-only** and **enrollment-gated**; check enrollment first and, on a permission/endpoint error, report **blocked**, never silently reinterpret it as "not enrolled".

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile (empty = default credential chain)
coh_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" --region us-east-1 "$@"; else aws --region us-east-1 "$@"; fi; }
if COH_ENROLL="$(coh_cli cost-optimization-hub list-enrollment-statuses --output json 2>/tmp/coh-err)"; then
  echo "$COH_ENROLL" | jq -r '.items[]?.status // "NOT_ENROLLED"'
  coh_cli cost-optimization-hub list-recommendations --output json \
    | jq '[.items[]? | {id: .recommendationId, region: .region, resource_type: .currentResourceType,
           action: .actionType, estimated_monthly_savings_usd: .estimatedMonthlySavings,
           estimated_savings_pct: (.estimatedSavingsPercentage // null)}]'
else
  echo "COST-AWS-013 BLOCKED: cost-optimization-hub (us-east-1) failed — $(cat /tmp/coh-err). Report blocked (endpoint/permission), NOT 'not enrolled'."
fi
```

**Expected:** an `Active` status, then one line per recommendation with the Hub's own `estimatedMonthlySavings` (a plain `double` here, not a nested structure) and `actionType` (`Rightsize`, `Stop`, `Upgrade`, `MigrateToGraviton`, `Delete`, `PurchaseSavingsPlans`, …). Copy the dollar verbatim. Non-active enrollment → `excluded, reason: "Cost Optimization Hub not enrolled"`. This is the single richest native-$ source when enrolled — it dedups against COST-AWS-001…009, so annotate the overlap rather than double-counting the same resource's savings in the summary line.

## 10. Trusted Advisor cost checks (COST-AWS-014)

`us-east-1`-only; Business or Enterprise support required. List the cost checks, then pull each result and report only the resources Trusted Advisor itself flags, with **its own** savings estimate.

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile (empty = default credential chain)
ta_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" --region us-east-1 "$@"; else aws --region us-east-1 "$@"; fi; }
CHECK_IDS="$(ta_cli support describe-trusted-advisor-checks --language en --output json 2>/tmp/ta-err \
  | jq -r '.checks[] | select(.category == "cost_optimizing") | .id')" \
  || { echo "COST-AWS-014 excluded: support:Describe* denied or no Business/Enterprise support — $(cat /tmp/ta-err)"; CHECK_IDS=""; }
for id in $CHECK_IDS; do
  ta_cli support describe-trusted-advisor-check-result --check-id "$id" --language en --output json \
    | jq --arg id "$id" '{check: $id, status: .result.status,
        flagged: [.result.flaggedResources[]? | {resource_id: .resourceId, metadata: .metadata}]}'
done
```

**Expected:** a list of cost-optimizing check IDs, then per check a `status` (`ok`/`warning`/`error`) and `flaggedResources[].metadata` (a positional array whose estimated-monthly-savings column is defined by the check's `metadata` header from `describe-trusted-advisor-checks`). When Trusted Advisor provides a savings estimate there, copy it verbatim into `estimated_monthly_savings_usd`; never recompute one. Denial → `excluded, reason: "Trusted Advisor requires Business or Enterprise support"` — stated, never silently skipped.

## 11. Active cost anomalies (COST-AWS-015)

`ce get-anomalies` returns spikes Cost Anomaly Detection already found, each with a dollar `TotalImpact`. This is **detected anomalous spend**, not a recommended saving — report the dollar as "anomalous spend", never in `estimated_monthly_savings_usd`.

```bash
set -eu
AWS_PROFILE_CFG=""            # aws.profile (empty = default credential chain)
ce_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" "$@"; else aws "$@"; fi; }   # ce is global
START="$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%d)"
END="$(date -u +%Y-%m-%d)"
ce_cli ce get-anomalies --date-interval "StartDate=${START},EndDate=${END}" --output json \
  | jq '[.Anomalies[]? | {id: .AnomalyId, start: .AnomalyStartDate, end: .AnomalyEndDate,
      service: (.RootCauses[0].Service // .DimensionValue // null),
      region: (.RootCauses[0].Region // null),
      total_impact_usd: .Impact.TotalImpact, max_impact_usd: .Impact.MaxImpact}]' \
  2>&1 || echo "ce:GetAnomalies denied/unavailable or Cost Anomaly Detection not configured; COST-AWS-015 excluded"
```

**Expected:** zero or more anomalies with a root-cause service/region and AWS's own `TotalImpact` dollar. A non-empty result means AWS detected a spend spike worth investigating; quote `TotalImpact` verbatim in the finding as anomalous spend. No monitors configured / permission denied → `excluded` with the reason. This is a detection signal that feeds the report's context, kept out of the savings total by design.

## 12. Idle and unattached presence facts (COST-AWS-016 … 019)

Pure presence facts — name every resource, attach **no** dollar figure.

```bash
# COST-AWS-016 unattached EBS volumes — id, size, type, AZ, age.
aws_cli ec2 describe-volumes --filters 'Name=status,Values=available' --output json \
  | jq '[.Volumes[] | {id: .VolumeId, size_gb: .Size, type: .VolumeType, az: .AvailabilityZone, created: .CreateTime}]'

# COST-AWS-017 unassociated Elastic IPs.
aws_cli ec2 describe-addresses --output json \
  | jq '[.Addresses[] | select(.AssociationId == null) | {allocation_id: .AllocationId, public_ip: .PublicIp}]'

# COST-AWS-019 stopped-but-not-terminated instances — id, type, why/when stopped.
aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=stopped' --output json \
  | jq '[.Reservations[].Instances[] | {id: .InstanceId, type: .InstanceType,
      stopped_reason: (.StateTransitionReason // ""), name: ([.Tags[]? | select(.Key=="Name") | .Value][0] // null)}]'
```

`COST-AWS-018` (idle load balancers) needs a CloudWatch request-count lookback per load balancer. Enumerate load balancers first, then sum `RequestCount` over the window:

```bash
set -eu
AWS_PROFILE_CFG=""; AWS_REGION_CFG="us-east-1"
aws_cli() { if [ -n "$AWS_PROFILE_CFG" ]; then aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; else aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"; fi; }
aws_cli elbv2 describe-load-balancers --output json | jq -r '.LoadBalancers[] | "\(.LoadBalancerName)\t\(.LoadBalancerArn)"'
LB_DIM="app/your-lb/1234567890abcdef"   # the LoadBalancer dimension value from the ARN suffix
IDLE_DAYS="14"
START="$(date -u -v-${IDLE_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${IDLE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
aws_cli cloudwatch get-metric-statistics --namespace AWS/ApplicationELB --metric-name RequestCount \
  --dimensions "Name=LoadBalancer,Value=${LB_DIM}" --start-time "$START" --end-time "$END" \
  --period 86400 --statistics Sum --output json | jq '[.Datapoints[].Sum] | add // 0'
```

**Expected:** any non-empty array (016/017/019) is a per-resource presence finding, listed by ID with size/type/age, **no dollar**. For 018, a `RequestCount` sum of `0` over `IDLE_DAYS` on a load balancer not explicitly a standby/DR target is the finding — again no dollar unless Trusted Advisor (COST-AWS-014) separately reports one for the same LB, in which case cross-reference it. A failure means these resources exist and bill while doing nothing; the reader decides, with the concrete list in hand.

## 13. Snapshots, S3 lifecycle, and storage-class presence facts (COST-AWS-020 … 022)

```bash
# COST-AWS-020 snapshot age vs the team's STATED retention (no assumed default).
aws_cli ec2 describe-snapshots --owner-ids self --output json \
  | jq '[.Snapshots[] | {id: .SnapshotId, volume: .VolumeId, size_gb: .VolumeSize, started: .StartTime}]'
aws_cli rds describe-db-snapshots --snapshot-type manual --output json \
  | jq '[.DBSnapshots[] | {id: .DBSnapshotIdentifier, instance: .DBInstanceIdentifier, created: .SnapshotCreateTime}]'

# COST-AWS-022 gp2 -> gp3 migration candidates (gp3 is cheaper per GiB at equal/better baseline perf).
aws_cli ec2 describe-volumes --filters 'Name=volume-type,Values=gp2' --output json \
  | jq '[.Volumes[] | {id: .VolumeId, size_gb: .Size, az: .AvailabilityZone,
      attached_to: ([.Attachments[]?.InstanceId] | join(",")) }]'

# COST-AWS-021 S3 no-lifecycle buckets (candidate only if it holds aged Standard-class objects).
for b in $(aws_cli s3api list-buckets --output json | jq -r '.Buckets[].Name'); do
  if ! aws_cli s3api get-bucket-lifecycle-configuration --bucket "$b" >/dev/null 2>&1; then
    echo "no lifecycle: $b (COST-AWS-021 candidate — confirm aged Standard objects before flagging)"
  fi
done
```

**Expected & failure meaning.** COST-AWS-020: compare each snapshot's `StartTime`/`SnapshotCreateTime` against the team's **own stated** retention policy from business context — if none is stated, say so in the finding rather than pick a number for them; a snapshot far older than the stated policy is the finding, no dollar. COST-AWS-022: every `gp2` volume is a migration candidate — list them by ID/size (if Compute Optimizer COST-AWS-005 attached a native $ for the same volume, cross-reference it; the family check itself carries no dollar). COST-AWS-021: a bucket with no lifecycle config is a candidate **only** when a follow-up size check (`s3api list-objects-v2` sampled, or S3 Storage Lens if enabled) shows aged objects still in `STANDARD`; a lifecycle-free short-lived staging bucket is not a finding.

## 14. Previous-generation families and idle NAT gateways (COST-AWS-023, 024)

```bash
# COST-AWS-023 previous-generation instance families still running (newer gens are cheaper per unit of perf).
PREV_GEN='^(t1|t2|m1|m2|m3|m4|c1|c3|c4|cc2|r3|r4|i2|i3\.|d2|g2|g3|p2|hs1|cr1)'
aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=running' --output json \
  | jq --arg re "$PREV_GEN" '[.Reservations[].Instances[]
      | select(.InstanceType | test($re)) | {id: .InstanceId, type: .InstanceType, az: .Placement.AvailabilityZone}]'

# COST-AWS-024 idle NAT gateways — zero bytes processed over N days.
IDLE_DAYS="14"
START="$(date -u -v-${IDLE_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${IDLE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for ng in $(aws_cli ec2 describe-nat-gateways --filter 'Name=state,Values=available' --output json | jq -r '.NatGateways[].NatGatewayId'); do
  BYTES="$(aws_cli cloudwatch get-metric-statistics --namespace AWS/NATGateway --metric-name BytesOutToDestination \
    --dimensions "Name=NatGatewayId,Value=${ng}" --start-time "$START" --end-time "$END" \
    --period 86400 --statistics Sum --output json | jq '[.Datapoints[].Sum] | add // 0')"
  echo "${ng}\t${BYTES}"
done
```

**Expected & failure meaning.** COST-AWS-023: any running instance whose type matches a previous-generation family is listed by ID/type — a presence fact, no dollar (Compute Optimizer's COST-AWS-001 supplies the $ if it recommends a modern shape for the same instance; cross-reference). COST-AWS-024: a NAT gateway with `BytesOutToDestination` summing to `0` over `IDLE_DAYS` bills an hourly charge for nothing — the finding names the gateway ID and its zero-byte window, no dollar. `PREV_GEN` and `IDLE_DAYS` are clearly-marked tuning knobs; record the values used in evidence.

## 15. Rendering the AWS cost section

Every finding uses `area: cost-optimization`, `points_recoverable: 0`, and remediation pointer `setup-aws#plan-cost-optimizations` (plan-only; v1 never automates a resize or deletion from a savings recommendation). Findings rank by `estimated_monthly_savings_usd` descending, then presence facts grouped after.

**Open with the savings-summary line** (per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule), built **only** from `estimated_monthly_savings_usd` values copied verbatim from a recommendation API (COST-AWS-001…009, 013, 014):

> **Potential savings: ~$<sum>/month (~$<sum×12>/year)** across **<n>** opportunities with a Compute Optimizer / Cost Explorer / Cost Optimization Hub / Trusted Advisor figure; **<m> more** found with no AWS dollar figure (presence facts, listed below). Largest single lever: **$<max>/mo** — <that finding's one-line action>.

Rules: sum only verbatim recommendation-API figures; annual = monthly × 12, labelled an estimate (`~`, "potential"); state the count *with* a figure separately from the count *without* one; name the single biggest lever. **Never** fold in COST-AWS-012 unused-commitment or COST-AWS-015 anomaly dollars — call those out on their own line ("Unused committed spend: $X/mo per the utilization API; anomalous spend detected: $Y — investigate, not counted as savings"). If no row carries a recommendation-API figure, write "<n> opportunities found; no AWS-sourced dollar figures available — each is a presence fact to review", never `$0`.

Then render the per-row table: `Finding | Resource | Signal source | Current → recommended | Est. monthly savings (AWS-sourced) | Est. annual | Action`. `Current → recommended` shows the shape change where the API gives it (`db.r5.xlarge → db.r5.large`, `gp2 → gp3`, `unattached 40+ days → delete`), else `-`. A row with no AWS-sourced figure prints `-` in the savings columns (reads as "checked, no number available", not "forgot to fill in"). **Cross-reference note:** where COST-AWS-013 (Hub) or COST-AWS-014 (Trusted Advisor) covers the same resource as COST-AWS-001…009 or a presence fact, annotate the overlap and count each resource's savings once — never sum two APIs' figures for the same resource into the total.

## 16. Forbidden commands (never run in this or any audit)

This catalog is read-only. The following mutating verbs must **never** run under `audit-cost` — acting on a recommendation is the setup lane's job, gated behind explicit confirmation:

- **Enrollment (never auto-enroll):** `compute-optimizer update-enrollment-status`, `compute-optimizer put-recommendation-preferences`, `cost-optimization-hub update-enrollment-status`, `cost-optimization-hub update-preferences`.
- **EC2 / EBS:** `ec2 terminate-instances`, `ec2 stop-instances`, `ec2 start-instances`, `ec2 delete-volume`, `ec2 modify-volume` (the gp2→gp3 change), `ec2 delete-snapshot`, `ec2 release-address`, `ec2 delete-nat-gateway`, `ec2 modify-instance-attribute`.
- **RDS:** `rds delete-db-snapshot`, `rds modify-db-instance`, `rds delete-db-instance`, `rds stop-db-instance`.
- **Load balancing / storage:** `elbv2 delete-load-balancer`, `s3api put-bucket-lifecycle-configuration`, `s3api delete-bucket`, `s3api delete-object`, `s3api put-object`.
- **Commitments:** `savingsplans create-savings-plan`, `ec2 purchase-reserved-instances-offering`, `rds purchase-reserved-db-instances-offering`.
- **Anomaly / autoscaling / lambda config:** `ce create-anomaly-monitor`, `ce create-anomaly-subscription`, `ce update-anomaly-monitor`, `autoscaling update-auto-scaling-group`, `autoscaling set-desired-capacity`, `lambda update-function-configuration`.

If any recommendation warrants action, the finding's remediation pointer sends the reader to `setup-aws#plan-cost-optimizations`; the audit itself never changes a live resource, not even a "harmless" gp3 conversion or snapshot deletion.
