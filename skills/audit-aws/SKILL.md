---
name: audit-aws
description: Read-only scored audit of AWS observability (CloudWatch alarms, SNS routing, EC2/ECS/EKS/Lambda compute health, RDS, Route53/ELB uptime, log forwarding) that also reports a separate non-scored Cost & Resource Optimization section from Compute Optimizer, Cost Explorer, and Trusted Advisor; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring AWS observability, CloudWatch alarms, SNS alert delivery, RDS Multi-AZ or backups, or AWS cost/rightsizing findings. Do not use for Alertmanager routing proof on a self-hosted stack (use audit-alert-routing), for in-cluster LGTM or Grafana on EKS (use audit-lgtm or audit-grafana), or to change AWS resources (use setup-aws).
---

# audit-aws

Scored, read-only audit of the AWS surfaces that carry production observability: CloudWatch alarms and dashboards, SNS alert routing, EC2/ASG/ECS/EKS/Lambda compute health, RDS managed databases, Route53 and load balancer uptime signals, and account-level log forwarding and retention. It answers one question: when an AWS-hosted service degrades tonight, does an alarm fire, reach a human, and give the responder enough to act? A second, separate section reports Cost & Resource Optimization opportunities; it never touches the 0-100 score.

Every command in this audit is read-only: `aws` `describe-*`, `get-*`, and `list-*` calls, plus `curl` GET or HEAD probes against public endpoints. Nothing is created, updated, confirmed, snoozed, test-fired, or deleted, however small. The full forbidden-command list is in [references/aws-checks.md](references/aws-checks.md) section 14.

Two axes, scored differently on purpose: reliability and readiness (the six categories below) fold into the normal 0-100 score, the same as every other audit skill in this toolkit. Cost & Resource Optimization is a separate, parallel, non-scored report section, the same pattern this toolkit already uses for Scoutflo Topology Readiness. Mixing a dollar-savings signal into a reliability score creates a perverse incentive: an idle standby RDS replica is "waste" by a cost lens and "correct" by a reliability lens, so scoring both on one axis would reward removing the standby. Keeping them separate means you can be reliability-healthy and cost-inefficient, or the reverse, and see both truths.

**Multiple accounts, one run:** `aws` may be a single block (one account, with an optional `profile`/`region`) or a **list of labeled targets**, each with its own optional `profile`, optional `account_id`, and `region`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> aws labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `aws/<label>/<date>/` for a list, or the flat `aws/<date>/` for a single block. Every `aws` call names its target's own `--profile`/`--region` explicitly (resolved from that target, never a hand-typed value); the ambient `AWS_PROFILE`/`AWS_DEFAULT_REGION` is never read, and `aws configure` is never run.

Out of scope: Alertmanager-style routing proof for a self-hosted stack belongs to `/scoutflo:audit-alert-routing`; if your workloads run on EKS with an in-cluster LGTM or Grafana stack, that layer belongs to `/scoutflo:audit-lgtm` and `/scoutflo:audit-grafana`. This audit covers the AWS-managed plane and states the split so a green AWS score never implies in-cluster coverage.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/aws/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), reliability finding IDs `AWS-NNN`, Cost & Resource Optimization finding IDs `AWSOPT-NNN`
- `./scoutflo-audits/aws/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/aws/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-1 catalog — one item per CloudWatch `alarm`, `sns_topic`, `dashboard`, and `log_group`, plus each inventoried `vm`, `database`, `cluster`, `function`, `load_balancer`, and `uptime_check` — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects (an alarm's SNS topic). Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/aws/[<label>/]history.jsonl` (reliability score only; the cost section never feeds the ledger)
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| AWS | `aws.account_id`, optional `aws.region`, `aws.profile`, `aws.role_env`, `aws.cost_checks` | when `role_env` names a variable, its value is a role ARN to assume; otherwise the active credential chain (env vars, instance role, SSO) is the identity | read-only policy covering `cloudwatch:Describe*`/`List*`, `sns:List*`, `rds:Describe*`, `ec2:Describe*`, `ecs:Describe*`, `eks:Describe*`, `lambda:List*`/`Get*`, `logs:Describe*`, `route53:Get*`/`List*`, `elasticloadbalancing:Describe*`, `cloudtrail:Describe*`, `config:Describe*`, `xray:Get*` (recipe in `/scoutflo:connect`) | read-only |
| AWS cost (optional) | same `aws:` block, `aws.cost_checks` (default true) | same credential | `compute-optimizer:Get*`, `ce:Get*`, `support:Describe*` (Trusted Advisor needs Business or Enterprise support) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

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
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in aws curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Resolve the CURRENT aws target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). Per-target keys:
# optional profile, optional account_id, region. Every aws call below passes this target's own
# --profile/--region explicitly; the ambient AWS_PROFILE/AWS_DEFAULT_REGION is never read.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
[ "${AWS_N:-0}" -ge 1 ] || { echo "no aws target configured in $CFG; run /scoutflo:connect"; exit 1; }
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
AWS_ACCOUNT_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" account_id)   # optional; may be empty
AWS_PROFILE_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" profile)     # optional; empty = active credential chain
AWS_REGION_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" region)
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
echo "aws target: ${AWS_LABEL} (account ${AWS_ACCOUNT_CFG:-<credential-chain>}, profile ${AWS_PROFILE_CFG:-<credential-chain>}) -> ${AWS_SEG}/"

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

CW_OK=0
aws_cli cloudwatch describe-alarms --max-records 1 >/dev/null 2>&1 && CW_OK=1
[ "$CW_OK" -eq 1 ] || { echo "cloudwatch:DescribeAlarms denied or unreachable; grant the read-only policy in connect references/providers.md"; exit 1; }
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone; `skills/doctor/scripts/doctor.sh` already wires in the AWS identity, CloudWatch reachability, and optional cost-permission probes this gate depends on.

The optional cost-permission probe (`compute-optimizer get-enrollment-status`) is checked by `doctor.sh` but never blocks this gate: a missing scope there excludes only the affected Cost & Resource Optimization rows with a stated reason, per Phase 10. `aws.cost_checks: false` in the config skips the whole cost section deliberately; treat that the same as a missing scope, not a failure.

Troubleshooting, not a rule: if `aws` times out while `curl` to public sites works, retry the same command once with proxy variables cleared (`env -u HTTPS_PROXY -u https_proxy aws sts get-caller-identity`) before concluding permissions are broken.

## Live-safety gate

Print what you are pointed at and compare it against the config before the first real check. The comparison value comes from `toolkit.yaml`, not from what an operator typed or what an ambient `AWS_PROFILE` left active in another terminal. A multi-account estate audits each configured target in turn (the runner sets `SCOUTFLO_TARGET=<label>`), so the gate is the AWS analog of the relaxed Azure visibility gate: it asserts `sts get-caller-identity`'s account equals the target's `account_id` **when that target sets one**, and otherwise proceeds on the target's own explicit `--profile`/`--region`:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve the CURRENT aws target from config via the shared enumerator — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_N=$(sh "$TT" "$CONFIG" aws count)
[ "${AWS_N:-0}" -ge 1 ] || { echo "no aws target configured in $CONFIG; run /scoutflo:connect"; exit 1; }
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CONFIG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CONFIG" aws label "$AWS_IDX")
AWS_ACCOUNT_CFG=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" account_id)   # optional; may be empty
AWS_PROFILE_CFG=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" profile)     # optional; empty = active credential chain
AWS_REGION_CFG=$(sh "$TT" "$CONFIG" aws get "$AWS_IDX" region)

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
echo "aws target: ${AWS_LABEL} (profile ${AWS_PROFILE_CFG:-<credential-chain>}); resolved account ${RESOLVED_ACCOUNT}, config account_id ${AWS_ACCOUNT_CFG:-<unset>}"
# Multi-target safety: a multi-account estate audits several accounts in one run, so — unlike a
# single-account equality check — the ambient default is NOT required to equal the target; every
# command passes this target's own --profile/--region explicitly (resolved above), so the run can
# never touch an account other than the one this profile selects. When account_id IS set for the
# target, sts's resolved account MUST match it (catches a profile wired to the wrong account); when
# it is not set, proceed on the explicit profile and print what was resolved. AWS_PROFILE is never read.
if [ -n "$AWS_ACCOUNT_CFG" ]; then
  [ "$RESOLVED_ACCOUNT" = "$AWS_ACCOUNT_CFG" ] || { echo "live-safety gate failed: sts resolved account '${RESOLVED_ACCOUNT}' for target '${AWS_LABEL}' (profile ${AWS_PROFILE_CFG:-<credential-chain>}), config account_id names '${AWS_ACCOUNT_CFG}'; stop, this credential points at the wrong account"; exit 1; }
  echo "live-safety gate: pass, target '${AWS_LABEL}' account ${RESOLVED_ACCOUNT} confirmed; every call passes --profile/--region explicitly"
else
  echo "live-safety gate: pass, target '${AWS_LABEL}' has no account_id to assert against; proceeding on the explicit profile ${AWS_PROFILE_CFG:-<credential-chain>} (resolved account ${RESOLVED_ACCOUNT}); every call passes --profile/--region explicitly and AWS_PROFILE is never read"
fi
```

Never proceed on "probably the right account": when a target names an `account_id`, the assertion above is what stops the run, not a human comparing two printed lines. Every command in this audit passes its target's own `--profile` and `--region` explicitly when configured; the audit never reads or sets `AWS_PROFILE`, `AWS_DEFAULT_REGION`, or any other ambient default, and never runs `aws configure`. A multi-account estate audits several targets in one run (the runner sets `SCOUTFLO_TARGET=<label>`), so the ambient default is not required to equal any one target; the explicit `--profile` is what selects the account, and the `account_id` check — where a target sets one — catches a profile wired to the wrong account. Account ID drift between staging and production credentials is one of the most common real-world failures in AWS operations; this gate exists specifically to catch it before the first check runs, not after the report is written.

## Ground rules

- Configuration is metadata; live validation is proof. An SNS subscription seen in `aws sns list-subscriptions-by-topic` is `configured`; only `SubscriptionArn` resolving to a real ARN (not the literal string `PendingConfirmation`) plus an observed CloudWatch-generated delivery makes routing `validated-live`.
  - ❌ `Routing validated-live: the topic has a subscription and the API call returned 200.`
  - ✅ `Routing configured: the subscription's SubscriptionArn is the literal string "PendingConfirmation", meaning nobody ever clicked confirm; no alarm can reach this endpoint until that happens (AWS-011 fail).`
- API errors are evidence. A `AccessDenied`, `UnrecognizedClientException`, or a timeout means a missing permission, a revoked credential, or a wrong region. Record the error and what it implies; never convert an error into empty success.
- Never score from object counts.
  - ❌ `Scored alerting coverage 90: forty-one CloudWatch alarms exist.`
  - ✅ `Scored alerting coverage 45: alarms exist, but a third are in INSUFFICIENT_DATA because their dimension filters never matched a real metric, and two production RDS instances have zero alarms at all; credit stops at partial.`
- CloudWatch alarms and SNS routing are different systems, and so are load-balancer/Route53 health checks and CloudWatch alarms. A target-group health check ejects a bad backend from rotation; it pages nobody. An alarm with no action attached draws state transitions in the console; it also pages nobody. Credit each system for what it actually does, never for the other's job.
  - ❌ `Uptime covered: the target group has a health check and marks unhealthy targets.`
  - ✅ `Uptime partial: the target-group health check ejects bad targets (AWS-041 pass), but no CloudWatch alarm rides UnHealthyHostCount, so an all-targets-down event never pages anyone (AWS-001 fail).`
- Cost-estimate source discipline: an `estimated_monthly_savings_usd` figure is reported only when it comes straight from an AWS-native recommendation source (Compute Optimizer, Cost Explorer). Everything else, unattached EBS volumes, idle load balancers, snapshot sprawl, is a presence fact with no dollar figure attached, ever.
  - ❌ `AWSOPT-004: db.r5.xlarge is oversized based on 12% average CPU; estimated savings $340/mo (self-computed from CloudWatch CPUUtilization and the public RDS price list).`
  - ✅ `AWSOPT-004: Compute Optimizer rates db-primary "Over-provisioned" and recommends db.r5.large; estimated_monthly_savings_usd taken directly from the recommendation's estimatedMonthlySavings.value field, never recomputed.`
- Never print an AWS access key, secret key, session token, or role ARN external ID anywhere: not in terminal output, not in evidence, not in the report. Account IDs and resource ARNs are not secrets and may appear in local evidence, but never in the Slack brief.
- Label every recommendation with its change-risk class (next section) so "Next safe actions" never hides a resize or a deletion behind a "monitoring tweak".

## The four change-risk classes

| Class | Examples | Rule |
| --- | --- | --- |
| Read-only | `aws describe-*`/`get-*`/`list-*`, curl GET/HEAD probes | The only class allowed in this audit. |
| Monitoring-plane write | Create or update a CloudWatch alarm, subscribe an SNS topic, set log-group retention, add a dashboard widget | No workload restart, no data loss. Setup lane, confirmation-gated. |
| Controlled rollout | Enable Container Insights on an EKS cluster, turn on CloudTrail or AWS Config account-wide, enable VPC Flow Logs | Own change plan with a named owner; out of `setup-aws`'s write scope. |
| Traffic-impacting | RDS Multi-AZ conversion, ASG or ECS desired-count changes, EC2 instance-type resize, security group, VPC, DNS, or IAM changes, deleting an unattached EBS volume or an idle load balancer | Out of write scope everywhere, in both the reliability and cost lanes; plan only, never automated. |

- ❌ `Recommend: enable Multi-AZ on db-primary (quick monitoring setting).`
- ✅ `Recommend: enable Multi-AZ on db-primary (traffic-impacting: triggers a brief failover during conversion; setup-aws records this as a plan with a named owner, it does not execute it).`

Every `AWSOPT-*` finding this audit emits is traffic-impacting by nature (resizing or deleting live infrastructure to save money is a materially different risk profile than fixing a missing alarm), so Cost & Resource Optimization stays audit-only: this skill reports the opportunity, it never proposes a `setup-aws` write for it.

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
AWS_PROFILE_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" profile)   # optional; empty = active credential chain
AWS_REGION_CFG=$(sh "$TT" "$CFG" aws get "$AWS_IDX" region)
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
aws_cli() {
  if [ -n "$AWS_PROFILE_CFG" ]; then
    aws --profile "$AWS_PROFILE_CFG" ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  else
    aws ${AWS_REGION_CFG:+--region "$AWS_REGION_CFG"} "$@"
  fi
}
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="10"           # resources per batch on the large path; example, tune it
EC2="$(aws_cli ec2 describe-instances --filters 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].InstanceId' --output json | jq 'length')"
RDS="$(aws_cli rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output json | jq 'length')"
ECS_SERVICES="$(aws_cli ecs list-clusters --query 'clusterArns' --output json \
  | jq -r '.[]' | while read -r c; do aws_cli ecs list-services --cluster "$c" --query 'serviceArns' --output json | jq 'length'; done \
  | awk '{s+=$1} END {print s+0}')"
EKS="$(aws_cli eks list-clusters --query 'clusters' --output json | jq 'length')"
LAMBDA="$(aws_cli lambda list-functions --query 'Functions[].FunctionName' --output json | jq 'length')"
TOTAL=$((EC2 + RDS + ECS_SERVICES + EKS + LAMBDA))
echo "ec2=${EC2} rds=${RDS} ecs_services=${ECS_SERVICES} eks_clusters=${EKS} lambda=${LAMBDA} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough:
# compare this count against the target's own history, not a blank slate. This stays in the
# SAME block as the TOTAL computed above; a separate fence would run in a fresh shell where
# $TOTAL is unbound and, under set -eu, abort. The value of the step is telling the reader
# whether their estate actually changed, not silently re-scanning the same ground every run.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -v '/runs$' | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} objects then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} objects"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

### Guided-walkthrough drift check

The drift comparison runs at the end of the estate-sizing block above (it needs the `$TOTAL` computed there). Most AWS `describe-*`/`list-*` calls already return live state in the same response as the object list, so there is little enumeration cost left to skip here; the point is to state whether the estate changed since the last run in the executive summary, per [report-standard/README.md](../../report-standard/README.md#using-topology-and-prior-runs-as-a-guided-walkthrough).

State the `drift` line in the executive summary verbatim (or "first run" on the first run) — never silently omit it. This does not change which live checks run; every check in Phases 3-8 still executes fresh regardless of drift status, per the guided-walkthrough rule that reuse applies to discovery scope, never to whether a result is still true.

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (alerting, routing, compute, databases, uptime, logs), completed in one run.
- **Large**: work EC2 instances, RDS instances, ECS services, EKS clusters, and Lambda functions in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist: resources in batches](#large-path-worklist-resources-in-batches) below. The same worklist covers both axes: reliability checks and, when `aws.cost_checks` is on, the Cost & Resource Optimization checks that key off the same resource IDs run against the same batches, so a large estate does not need two separate sizing passes.

Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it. Record the chosen path and counts in `findings.json` as `estate: {objects, path}`; `audit-all` reads them.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map EC2 instances, ECS services, EKS workloads, Lambda functions, and RDS instances to those names by tag (`Name`, `service`, or your team's convention) or resource naming. If it does not exist, infer services from resource names and tags, note the inference in the report, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/aws-checks.md](references/aws-checks.md) section 4: CloudWatch alarms with state and dimensions, SNS topics and subscription confirmation status, EC2 instances and status checks, ASGs, ECS clusters and services, EKS clusters and their logging/Container Insights config, Lambda functions, RDS instances, Route53 health checks, ELBv2 target groups and health, CloudWatch log groups with retention, CloudTrail trails, Config recorders, and VPC flow-log configs. Judgment starts in Phase 3; inventory records what exists.

## Phase 3: Alerting coverage and configuration (AWS-001 to AWS-007)

Commands in [references/aws-checks.md](references/aws-checks.md) section 5. Every critical RDS instance, ALB/NLB, ASG, and Lambda function has at least one CloudWatch alarm attached, the zero-alarms gap rather than just misconfigured existing ones (`AWS-001`, critical when a critical resource has none). Do not stop at "resource X has no alarm" — that is the free Trusted Advisor line. Join each un-alarmed resource id to `topology-export.json` and name the critical services it backs and how many (e.g. "`db-primary` has zero alarms and backs `checkout` + `orders`, 2 critical services — a saturation event tonight pages nobody for either"); a zero-alarm resource is the head of the flagship silent-page chain, and the exact fix names the specific alarm per resource kind (RDS two-tier CPU/connections/memory, ALB 5xx ratio, Lambda Errors/Throttles), never a bare "add an alarm". Alarms use two named tiers or a composite/anomaly-detection alarm where a static threshold is brittle on a variable-load metric (`AWS-002`); alarm descriptions carry environment, resource, severity, threshold, and a capture list a responder could act on (`AWS-003`); no alarm sits in `INSUFFICIENT_DATA` because its dimension filter never matched a live metric, the can-this-ever-fire check (`AWS-004`); minimum dashboard coverage exists per critical service (`AWS-005`); and composite or anomaly-detection alarms in use are reviewed for a sane trigger, not left as decoration (`AWS-006`, info).

**AWS-007 (Application Signals SLO without a burn-rate alarm).** Where the account uses CloudWatch Application Signals, `aws application-signals list-service-level-objectives` and `get-service-level-objective` per SLO give each SLO's `Goal` and `BurnRateConfigurations`. An SLO defined but not alerting is decoration: it reports attainment on a dashboard and pages nobody when the budget burns. Two nuances the API forces, both handled in the reference: an SLO with an empty `BurnRateConfigurations` list has no burn-rate metric at all; and even a populated `BurnRateConfigurations` is *not proof of an alarm* — the SLO object carries no alarm reference, so alarm existence must be cross-referenced against `cloudwatch describe-alarms` for an alarm on that SLO's burn-rate or attainment metric. Flag SLOs with no burn-rate config, and SLOs whose burn-rate metric no alarm watches, as `AWS-007` (medium). When Application Signals is not in use, this check is `not-in-scope`, never a fail.

## Phase 3 (continued): Alert hygiene (AWS-060 to AWS-065)

Phases 3 to 8 prove an alarm exists, fires, and reaches a human. These six checks fold into the same **Alerting coverage and configuration** category and grow its denominator; they ask the opposite question: does the alarm layer page on real conditions, or does it strobe on transient blips, data gaps, and forgotten mutes? Every check is read-only, `cloudwatch describe-alarms` and `cloudwatch describe-alarm-history` only, reading the per-alarm fields the Phase 2 inventory did not capture. Commands are in [references/aws-checks.md](references/aws-checks.md) section 5A.

Honest ceiling, stated in the report every run:

- These are **structural** noise signals, single-datapoint evaluation, breaching-on-gap, flap history, forgotten mutes, not an alert-to-incident actionability rate. This audit has no incident feed, so it never reports a fabricated "N% of alarms are actionable" number; it reports which alarms are structurally noisy.
- CloudWatch's strength is per-alarm threshold quality: M-of-N evaluation (`EvaluationPeriods`/`DatapointsToAlarm`), `Period`, `TreatMissingData`, anomaly-detection bands (`ThresholdMetricId`), and low-sample percentile handling. Its ceiling of native correlation is the composite alarm (`AlarmRule` + `ActionsSuppressor`). It has **no** native alert grouping or aggregation of many firing alarms into one notification, no dedup window, no rate-limiting or `repeat_interval`, no time-based mute or maintenance schedule (`ActionsEnabled` is a manual on/off toggle, not a scheduled silence), and no severity routing tree. Those responsibilities are pushed downstream to SNS (fan-out only, no grouping or inhibition) or to a third-party pager. Say this plainly; never score CloudWatch against controls it does not have.
- `DescribeAlarmHistory` retains 30 days at most, so the flap window is bounded at 30 days regardless of what is requested; report the effective window the run actually had. Flapping faster than an alarm's `Period` is invisible to a history read; a clean result is not proof there is no sub-`Period` flapping, and the finding says so.

Checks (thresholds below are tunable example variables, tune them to your workloads before treating a miss as a failure):

- **AWS-060 (single-datapoint debounce).** A paging alarm (non-empty `AlarmActions`) with `EvaluationPeriods == 1`, `DatapointsToAlarm == 1`, and a `Period` at or below `SHORT_PERIOD_SECS` (example, tune it) transitions to ALARM on one breaching datapoint that may self-correct before anyone looks. M-of-N (`DatapointsToAlarm < EvaluationPeriods`) or a longer `Period` is the fix.
- **AWS-061 (missing / low-sample data noise).** `TreatMissingData=breaching` on a paging alarm pages on a metric gap from an idle or scaled-down resource. `InsufficientDataActions` sharing a topic with `AlarmActions` pages the on-call on data gaps rather than real breaches. A percentile-statistic alarm (`ExtendedStatistic` `pNN`) without `EvaluateLowSampleCountPercentile=ignore` flips on statistically thin samples.
- **AWS-062 (flap history).** `DescribeAlarmHistory` with `HistoryItemType=StateUpdate` over `FLAP_DAYS` (example, tune it; capped at 30 by CloudWatch retention) reconstructs each paging alarm's transitions into ALARM; more than `FLAP_TRANSITIONS` (example, tune it) is a strobe that trains responders to ignore it. State the effective window and note that sub-`Period` flapping is invisible to this read.
- **AWS-063 (forgotten mute).** A paging metric alarm or composite alarm left with `ActionsEnabled=false` indefinitely is muted with no scheduled un-mute, a silent gap masquerading as a live alarm. CloudWatch cannot un-mute itself, which is exactly why a stale mute is a gap rather than managed noise.
- **AWS-064 (native correlation ceiling).** Composite alarms (`AlarmRule` with AND/OR/NOT logic, plus an `ActionsSuppressor` for known-condition windows) are the only native way to collapse N related child alarms into one page. Many child alarms wired straight to a paging SNS topic with zero composites in front is the finding, and the honest statement that this is the ceiling: anything resembling Alertmanager grouping, dedup, throttling, or scheduled silence must be built outside CloudWatch.
- **AWS-065 (resolve wiring), info.** A paging alarm with empty `OKActions` sends nothing on return to OK, so a downstream incident or pager entry can stay open after the condition clears. This is `info`, stale-incident hygiene rather than over-notification, unless a downstream pager depends on the resolve signal to auto-close, where it rises to `medium`.

Per-alarm hygiene (AWS-060 to AWS-063, AWS-065) batches with the same resource worklist as the earlier phases on the large path; the composite-alarm read (AWS-064) is one cheap call done once per run. An `AccessDenied` on any read here is an auth-scope finding that blocks the check, never a clean or passing result.

## Phase 4: Alert routing and delivery (AWS-010 to AWS-014)

Commands in section 6. Judge whether an alarm that fires reaches a human: every alarm names at least one SNS topic in `AlarmActions` (`AWS-010`, critical when none exist anywhere); every SNS topic an alarm points at has at least one subscription whose `SubscriptionArn` is a real ARN, not the literal string `PendingConfirmation` (`AWS-011`, high); routing is severity-tiered, critical and warning topics kept separate rather than one undifferentiated topic for every alarm (`AWS-012`); delivery proven by an observed CloudWatch-generated notification rather than assumed (`AWS-013`, capped at `configured` without one); and EventBridge rule targets, where used for alarm state changes, are enabled and reach a live target (`AWS-014`).

**Flagship correlation — the silent-page delivery chain.** This is the audit's single highest-value differentiator, the AWS equivalent of Kubernetes's external-to-cluster-secrets path. For each critical resource, chain the links no single AWS tool joins: AWS-001 (does an alarm exist?) → AWS-010 (does it name an SNS topic in `AlarmActions`?) → AWS-011 (is that topic's subscription a real ARN, not the literal `PendingConfirmation`?) → AWS-013 (has it ever actually delivered per `describe-alarm-history`?) → AWS-063 (is it muted with `ActionsEnabled=false`?), overlaid with AWS-062/AWS-060 (is the real page buried among flapping alarms sharing the same topic, or does it self-correct before anyone looks?). Emit one sentence per critical resource, e.g.: *"`checkout`'s ALB has a 5xx alarm (AWS-001 pass) but its `AlarmActions` topic `alerts-legacy` has one subscription still in `PendingConfirmation` (AWS-011) AND 38 flapping alarms route to it (AWS-062) — a real 5xx storm pages nobody, and even with the subscription confirmed the page would be one line among 38 pieces of noise."* No AWS-native product assembles this: Trusted Advisor sees only "an alarm exists", the SNS console only "subscription pending", the CloudWatch console only "ALARM state" — none joins alarm → action → topic → subscription-confirmation → shared-topic noise → the specific critical service resolved from topology-export.json. Score delivery from this chain, never from the presence of the alarm/topic/subscription objects. AWS-035 rides the same SNS-confirmation link (its `SnsTopicArn` is checked against AWS-011).

## Phase 5: Compute health and coverage (AWS-020 to AWS-028)

Commands in sections 7 and 7A. Per serving EC2 instance: a `StatusCheckFailed` (system or instance) alarm (`AWS-020`) — and size the severity by whether the un-alarmed instance is a disposable ASG member (auto-replaced, lower) or a standalone pet backing a critical service (stays dead until a human notices, the real fail), joining `asgs.json`/`describe-auto-scaling-instances` to tell them apart. Per ASG: health-check type and grace period configured so a slow-starting instance is not killed before it is ready (`AWS-021`). Per ECS service: an alarm or documented view on desired-versus-running task count (`AWS-022`). Per EKS cluster: Container Insights enabled, presence only, not full metrics depth, since deep in-cluster metrics are `audit-lgtm`'s or `audit-grafana`'s job when you run that stack (`AWS-023`). Per critical Lambda function: error-rate and throttle alarms (`AWS-024`); concurrent-execution or duration alarms where the function is latency-sensitive or has a reserved-concurrency ceiling (`AWS-025`). X-Ray tracing enabled on latency-sensitive services where the team has adopted it (`AWS-026`, info; absence is not a finding when the team never adopted X-Ray).

Two checks catch resilience that reads healthy but is switched off, section 7A (both **verify-pending** until a first live run — drafted against AWS's documented APIs, not yet proven against a live tenant): per ASG, no safety process (`HealthCheck`/`ReplaceUnhealthy`/`AlarmNotification`) sits in `SuspendedProcesses` (`AWS-027`, high) — a group with `DesiredCapacity=3` reads resilient while its self-healing is off, and once `ReplaceUnhealthy` is suspended a per-instance `StatusCheckFailed` alarm (AWS-020) is the only backstop, the AWS "HA that isn't HA" trap; per async-invoked Lambda, a `DeadLetterConfig` or an `OnFailure` destination exists so failed events are not dropped permanently (`AWS-028`, high) — a purely synchronous function marks this `not-in-scope`, not a fail, and AWS-024's `Errors` alarm tells you it failed while the DLQ/destination is what lets you replay the lost event.

## Phase 6: Managed databases (AWS-030 to AWS-035)

Commands in sections 8 and 8.1. Per production RDS instance: Multi-AZ enabled (`AWS-030`, high) — reported as a joined blast radius (which critical services depend on the instance, the concrete RPO/RTO), not the bare config flag; automated backup retention window greater than zero days (`AWS-031`, high); storage autoscaling enabled so a disk-full event does not take the database down (`AWS-032`); a replication-lag alarm on every read replica (`AWS-033`); and CPU, connection-count, and freeable-memory alarms present (`AWS-034`).

An RDS event subscription for `failover`/`availability`/`low storage` on a confirmed SNS topic (`AWS-035`, medium; section 8.1, **verify-pending** until a first live run) — RDS Events is a channel separate from CloudWatch metric alarms, so a Multi-AZ instance (AWS-030) with no such subscription completes a real failover with nobody notified, and the subscription's `SnsTopicArn` rides the same AWS-011 confirmation link as the flagship silent-page chain. Multi-AZ, backups, and storage autoscaling are the mechanisms; this subscription is what makes them observable.

- ❌ `Databases pass: CPU and connection alarms exist for both instances.`
- ✅ `Databases partial: CPU and connection alarms exist, but db-primary has Multi-AZ disabled and a 0-day backup retention window, so a single AZ failure loses both availability and the last day of recovery point (AWS-030 fail, AWS-031 fail).`

## Phase 7: Uptime and availability (AWS-040 to AWS-043)

Commands in section 9. Every active public serving endpoint has a Route53 health check that *does something* (`AWS-040`, high) — do not credit a check just for existing; join `list-resource-record-sets` (is it referenced by a failover/latency record?) and `describe-alarms` (does an alarm ride its `HealthCheckStatus`?), and a check referenced by neither on a critical public hostname is inert decoration ("DNS keeps sending traffic to the dead endpoint and no page fires"), chaining with AWS-041 and AWS-001/010. Every ALB/NLB target group has a health check configured and its targets probed live this run (`AWS-041`); CloudWatch Synthetics canaries, where the team runs them, carry an alarm on canary failure rather than existing as an unmonitored dashboard widget (`AWS-042`); and no health check or canary watches a dead, retired, or migrated target (`AWS-043`). Probe every candidate endpoint live and capture the status code as evidence, the same discipline as the DO and GCP uptime checks in this toolkit.

## Phase 8: Log forwarding, retention, and account-level observability (AWS-050 to AWS-056)

Commands in section 10. CloudWatch Logs subscription filters forward critical log groups to a central sink, or the absence is a recorded decision for the environment (`AWS-050`, high for production) — reported with the incident consequence and the service, distinguishing a null/"Never expire" retention from the opposite failure of a sub-window retention (e.g. `retentionInDays=1` ages a Friday slow-burn incident's logs out by Monday), and correlating with AWS-052 as one "no forensic story after an incident" cascade; log-group retention is set to a finite value rather than left at "Never expire" on critical groups (`AWS-051`); CloudTrail is enabled account-wide with a multi-region trail (`AWS-052`, high, this is an account-level control, not per-service) — on top of the existing `IsLogging=true`/multi-region assertion, also verify `LogFileValidationEnabled=true` (without it delivered logs can be tampered with undetectably) and state the forensic blast radius (after a credential compromise, activity in unlogged regions and everything after any `StopLogging` cannot be reconstructed) rather than reporting a checkbox; AWS Config's recorder is on (`AWS-053`); VPC Flow Logs are enabled for VPCs carrying critical workloads (`AWS-054`); the central-sink and retention decision is complete with an owner, not just a technical setting (`AWS-055`); and no CloudWatch Logs anomaly detector sits in a `FAILED` or `PAUSED` state (`AWS-056`). For AWS-056, `aws logs list-log-anomaly-detectors` returns each detector's `anomalyDetectorStatus` (enum `INITIALIZING | TRAINING | ANALYZING | FAILED | DELETED | PAUSED`); a `FAILED` or `PAUSED` detector on a critical log group is a silent log-signal gap — the detector looks configured but surfaces no anomalies. Absence of any detector is not itself a finding (they are opt-in); a broken one is.

## Phase 9: Coverage matrix and topology readiness

Fill one row per critical service using the per-service queries in section 11 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Alerting | Routing | Compute | DB | Uptime | Logs | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the Compute cell folds in the EC2/ASG/ECS/EKS/Lambda checks that apply to that service (a service with no compute of a given kind marks that sub-check `not-in-scope`, never a silent pass); the Routing cell requires a confirmed, non-`PendingConfirmation` subscription to reach `pass`; every cell carries its `passed/total` denominator. Name affected services in findings: "two Lambda functions lack error alarms" is not a finding; "checkout-webhook and payments-callback lack error alarms" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. The `monitoring.cloudwatch` relationship schema (required `alarmArn`, `region`; optional `serviceName`, `functionName`, `clusterName`, `containerName`, `instanceId`, `autoScalingGroupName`, `loadBalancerName`, `namespace`, `metricName`, `dimensionFilters`, `environment`, `team`) is current and typed, so a `MONITORED_BY` edge this audit verified live, for example an alarm this run confirmed is in `OK` or `ALARM` state with a confirmed SNS subscription, satisfies T4. **T6 needs one more thing T4 does not check**: CloudWatch's own `serviceName` field is camelCase, and the platform's correlation-category mapping does not split camelCase, so populating only `serviceName` satisfies T4 but leaves T6's `service`-category anchor unpopulated (see [topology-readiness.md](../../report-standard/topology-readiness.md#t6s-category-mapping-is-stricter-than-a-providers-field-names-suggest)). When writing the export, mirror the CloudWatch `serviceName` value into a literal `service` (or `service_name`) key on the same edge's attributes, or T6 will read `partial` even though the alarm genuinely resolved to the right service. `containerName`, `namespace`, `environment`, and `team` do not have this problem (their category rules match camelCase via substring). Log-forwarding edges are a stated gap: no `logging.cloudwatch_logs` (or equivalent) attribute schema exists in the platform yet, only `logging.elk` is defined for logging edges, so a `SENDS_LOGS_TO` edge to CloudWatch Logs can be checked for presence only; T4 stays partial for that one signal type until the schema exists, and the report says so plainly rather than inventing attribute fields. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers (T-codes only in the legend line), confidence as `n/10`, and — whenever any service is below ready — the ticket-ready sync-readiness action plan table from [topology-readiness.md](../../report-standard/topology-readiness.md). If the export or topology.md is missing, or exists but describes a different target than this audit covers (wrong `cluster_id`, non-overlapping services), the section renders the matching state from topology-readiness.md with its one-line unlock (run `/scoutflo:map-topology` against the right estate, or hand-author the export per `scoutflo-export.md` for non-Kubernetes estates); it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Large-path worklist: resources in batches

Runs on the large path only (see [Estate sizing](#estate-sizing) above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/aws/[<label>/]runs/<RUN_ID>/` (under the resolved target segment — flat `aws/runs/…` for a single block, `aws/<label>/runs/…` for a labeled target), not the calendar-date directory sections 4 to 10 of the reference write raw captures under, so a run that is still batching when the date rolls over UTC keeps writing into the same place. Full runnable commands (resume scan, run-ID mint, worklist build, lock, batch claim and mark-done, final pending assertion) are in [references/aws-checks.md](references/aws-checks.md) section 13, copied from the proven `do-checks.md` section 13 / `gcp-checks.md` section 16 mechanism rather than reinvented; this section states the workflow they implement. On the large path, `AUDIT_ROOT`/`RUN_DIR` in section 13 resolve under this same target segment (the enumerator resolves `aws` vs `aws/<label>` exactly as the phases above do).

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/aws/[<label>/]runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per resource from Estate sizing (`kind`: `ec2`, `rds`, `ecs_service`, `eks_cluster`, or `lambda`; `id`; `status`: `pending` or `done`). A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the Phase 3 to Phase 8 checks that key off that resource kind, plus, when `aws.cost_checks` is on, the matching Cost & Resource Optimization checks from Phase 10 against the same batch. A row is marked `done` only after its pulls succeed, so an interrupted batch resumes at the resource that failed. Release the lock once the batch's rows are marked.
4. **Assert before writing.** After every batch, print `done=X pending=Y`. Repeat from step 3 until the worklist has zero pending rows; assert `pending == 0` before Phase 11 writes `findings.json` or `report.md`. A run that stops mid-batch leaves the worklist as its resume point and never overwrites the previous complete report.

## Phase 10: Cost and Resource Optimization (not scored)

Full check catalog in [references/aws-cost-checks.md](references/aws-cost-checks.md), finding IDs `AWSOPT-NNN`. This section never appears in `score.categories` or `score.excluded`; it was never a scoring candidate, the same way Scoutflo Topology Readiness is reported and never scored. Its findings still live in the normal `findings[]` array (so history, lifecycle, and exemptions all apply unmodified) and always carry `points_recoverable: 0`.

Source discipline, the same "errors are evidence, never invent" principle applied to cost: prefer AWS's own recommendation engines over hand-rolled heuristics.

- Rightsizing comes from Compute Optimizer's own recommendation (`compute-optimizer:Get*`), never computed from raw CloudWatch CPU percentages against a guessed price table. If the account is not enrolled in Compute Optimizer, the row reports `excluded`, reason: "Compute Optimizer not enrolled for this account", and stops there rather than falling back to a hand-rolled estimate.
- Cross-service cost recommendations come from **Cost Optimization Hub** (`cost-optimization-hub:ListRecommendations`, `ListRecommendationSummaries`), which aggregates rightsizing, idle-resource, and commitment savings into one place with a native `estimatedMonthlySavings` figure per recommendation. Check enrollment first with `cost-optimization-hub:ListEnrollmentStatuses` — recommendations are empty unless the account has opted in, so on a non-enrolled account report `excluded`, reason: "Cost Optimization Hub not enrolled", never an empty pass. When enrolled, take the dollar figure straight from the recommendation's `estimatedMonthlySavings` field (exact field name, not `estimatedMonthlySavingsAmount`), never recomputed. All three operations are read-only `List*`.
- Savings Plan and Reserved Instance coverage gaps come from Cost Explorer's coverage APIs (`ce:GetSavingsPlansCoverage`, `ce:GetReservationCoverage`); report the coverage percentage Cost Explorer returns, never an independently estimated saving.
- Broader cost, security, and fault-tolerance checks come from Trusted Advisor (`support:Describe*`) when the account carries Business or Enterprise support; without that tier, the row reports `excluded`, reason: "Trusted Advisor requires Business or Enterprise support", exactly like any other excluded category in this toolkit, never silently skipped.
- Unattached EBS volumes, unassociated Elastic IPs, idle load balancers, S3 lifecycle gaps, and snapshot sprawl are presence and absence facts from plain `Describe*`/`Get*` calls; report the finding with no dollar figure, since there is no AWS-sourced number backing one.

`estimated_monthly_savings_usd` appears only on findings whose number came straight from Compute Optimizer or Cost Explorer; every other Cost & Resource Optimization finding omits the field entirely. When `aws.cost_checks` is `false` in the config, or the doctor gate's cost-permission probe found no usable scope, the whole section reports `excluded, reason: <the exact doctor finding>` instead of running partial checks silently. Render the section, own heading, after Scoutflo Topology Readiness, per [report-template.md](../../report-standard/report-template.md)'s parallel non-scored section pattern.

## Phase 11: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0), `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively. Cost & Resource Optimization findings carry `points_recoverable: 0` always and never enter this arithmetic.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alerting coverage and configuration | 20 | AWS-001 to AWS-007, AWS-060 to AWS-065 |
| Compute health and coverage | 20 | AWS-020 to AWS-028 |
| Alert routing and delivery | 15 | AWS-010 to AWS-014 |
| Managed databases | 15 | AWS-030 to AWS-035 |
| Uptime and availability | 15 | AWS-040 to AWS-043 |
| Log forwarding, retention, and account-level observability | 15 | AWS-050 to AWS-056 |

Weights are a draft starting point, stated as tune-this, not gospel; adjust them against your team's real priority before treating them as final. The full check catalog and the target profile (what 100 means per category) are at the top of [references/aws-checks.md](references/aws-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings, excluded categories, and every `AWSOPT-*` finding carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end". The Cost & Resource Optimization section never affects this gate either way.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding, `AWS-*` and `AWSOPT-*` alike, per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard. The findings.json
# ".target" is the per-target slug (equal to $AWS_SEG: "aws" for a single block, "aws/<label>" for a
# labeled list target), so audit-all/correlation/render disambiguate multiple accounts. Then verify:
jq -e --arg seg "$AWS_SEG" '.schema == "scoutflo-findings/v1" and .target == $seg and (.findings | type == "array")' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: the emitted report.md must match report-standard/report-template.md.
# This catches header/score-line/section drift before the run is declared done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). History and its rotation follow [README.md](../../report-standard/README.md) exactly, including monthly compaction past `HISTORY_MAX_LINES`; the ledger records the reliability `score.overall` only, never a cost figure:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-aws", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first; the ledger is derived and never drives finding lifecycle. Then send the Slack brief: titles only, never evidence values, hostnames, ARNs, or account IDs:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AWS_KIND=$(sh "$TT" "$CFG" aws kind); AWS_N=$(sh "$TT" "$CFG" aws count)
AWS_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AWS_N" ]; do [ "$(sh "$TT" "$CFG" aws label "$_i")" = "$SCOUTFLO_TARGET" ] && { AWS_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AWS_LABEL=$(sh "$TT" "$CFG" aws label "$AWS_IDX")
if [ "$AWS_KIND" = seq ]; then AWS_SEG="aws/${AWS_LABEL}"; else AWS_SEG="aws"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AWS_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
TOPO_LINE="Topology readiness: readiness not recorded"  # replace with "r/n services sync-ready" from Phase 9
COST_LINE=""   # optional; set to "Cost: N optimization opportunities found" only when AWSOPT findings exist this run
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  CHECKS="$(jq -r '"\([.score.categories[].checks_passed] | add)/\([.score.categories[].checks_total] | add) checks passed"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | select(.area != "cost-optimization") | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  AWSOPT_COUNT="$(jq -r '[.findings[] | select(.area == "cost-optimization")] | length' "$OUT/findings.json")"
  [ "$AWSOPT_COUNT" -gt 0 ] && COST_LINE="Cost: ${AWSOPT_COUNT} optimization opportunities found"
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d | grep -v '/runs$' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-aws ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}. ${CHECKS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg topo "$TOPO_LINE" --arg cost "$COST_LINE" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\n" + $topo + ($cost | if . == "" then "" else "\n" + . end) + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.


## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # derived from business_context.md (the SSOT)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver
LOAD_METADATA_MODE="none"
if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="per-resource"
elif [ -f "$BC_JSON" ] && jq -e '.' "$BC_JSON" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="workspace"
fi
echo "metadata mode: $LOAD_METADATA_MODE"
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

Every reliability finding's `remediation` field points at the fix, so "Next safe actions" starts at row 1 with no preparation. Cost & Resource Optimization findings carry a remediation pointer too, but it always names a plan-only anchor: v1 never automates a resize or a deletion off a savings recommendation.

| Finding area | Pointer |
| --- | --- |
| No or zero-alarm coverage, missing dashboards, INSUFFICIENT_DATA alarms | `setup-aws#add-cloudwatch-alarms` |
| No SNS destination, unconfirmed subscription, one undifferentiated topic | `setup-aws#fix-alert-routing` |
| Delivery never proven | `setup-aws#prove-alert-delivery` |
| Missing EC2/ASG/ECS/EKS/Lambda health signals, suspended ASG safety process (AWS-027), async Lambda with no DLQ/on-failure destination (AWS-028) | `setup-aws#add-compute-health-alarms` (resuming an ASG process or adding a Lambda destination changes behavior: plan only, not a monitoring-plane write) |
| Missing Multi-AZ, backups, storage autoscaling, replication-lag alarms, RDS failover/low-storage event subscription (AWS-035) | `setup-aws#harden-managed-databases` (Multi-AZ conversion is traffic-impacting: plan only) |
| Missing Route53 or target-group health checks, unmonitored canaries | `setup-aws#fix-uptime-coverage` |
| No central log forwarding, short or infinite retention, CloudTrail/Config/Flow Logs off | `setup-aws#enable-account-observability` |
| Cost & Resource Optimization findings (all `AWSOPT-*`) | `setup-aws#plan-cost-optimizations` (plan only; v1 never automates a resize or deletion) |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| `PendingConfirmation` subscription counted as delivery | Read the literal `SubscriptionArn` value; only a real ARN plus an observed CloudWatch-generated notification earns `validated-live` |
| Target-group or Route53 health check counted as alerting | Health checks eject bad targets silently; only a CloudWatch alarm pages a human. Credit each system for its own job |
| Self-computed savings figure presented as an AWS number | `estimated_monthly_savings_usd` is populated only from Compute Optimizer or Cost Explorer's own response; every other cost finding omits the field |
| Cost finding folded into `score.categories` | `AWSOPT-*` findings always carry `points_recoverable: 0` and never enter the weighted-score arithmetic; they render in their own report section |
| Wrong AWS account audited | Every command passes `--profile`/`--region` explicitly from `toolkit.yaml`; the live-safety gate compares `sts get-caller-identity` against `aws.account_id` and stops on mismatch |
| Missing Compute Optimizer enrollment read as zero findings | The doctor gate's cost-permission probe and Phase 10 both report `excluded, reason: ...` for the affected rows, never a silent empty result |
| CloudTrail/Config/Flow Logs judged per-service | These are account- or VPC-level controls; judge them once for the account or VPC, not per critical service |
| EKS in-cluster metrics judged by this audit | `AWS-023` checks Container Insights presence only; depth belongs to `audit-lgtm`/`audit-grafana` when you run that stack on EKS |
| Access key or role ARN external ID printed into evidence | Never print AWS credential material anywhere; account IDs and resource ARNs may appear locally but never in the Slack brief |
| `logging.cloudwatch_logs` schema assumed to exist | No such attribute schema is defined yet; T4 for log-forwarding edges checks presence only and the report states the gap plainly |
