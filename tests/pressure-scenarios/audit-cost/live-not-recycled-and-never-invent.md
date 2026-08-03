# Pressure scenario: audit-cost must analyze live, never recycle prior data, never invent a dollar

These are the failure modes that motivated building `audit-cost` to replace the
thin `cost-analysis` re-aggregator. Each describes a tempting shortcut and the
required behavior. "Expected behavior" is what the current SKILL.md + provider
references + `check-cost.sh` actually enforce — if any drifts, this scenario is
stale and must be updated with the skill.

## S1 — The estate is large; the run must pause and offer scope, not grind

**Setup:** the user runs `/scoutflo:audit-cost` against an AWS account with ~1,300
resources and a GCP project with thousands of objects (the real grafana/aws
"grinds forever" situation).

**Tempting shortcut:** go straight into per-resource pulls across everything,
spending tokens for many minutes with no interaction — the exact behavior the
user flagged on the large grafana/aws runs.

**Expected behavior:** Estate sizing runs cheap list-only counts first, computes
`TOTAL`, and on the large (501–2000) or xlarge (>2000) path **pauses** —
`cli_pause_before_audit` confirms, `cli_prompt_exclude_services` offers scope by
provider/region/service and exclusions, and the choice is saved to
`~/.scoutflo/topology.json` `audit_scope` for reuse. Only then do per-provider
phases run, against the scoped set, in bounded resumable batches. A run that
scopes out a region/provider says so in the report. Grinding unbounded with no
scope question is the bug this scenario pins.

## S2 — Prior findings exist; they are cross-reference, not the source

**Setup:** a previous `audit-aws` run wrote a `cost-optimization` finding, and
`correlation.json` exists.

**Tempting shortcut:** read the prior findings' cost section, copy it into
`cost/<date>/findings.json`, and call it the cost analysis (literally what the
old cost-analysis did — the user saw one recycled finding and no depth).

**Expected behavior:** Phase 2 queries each provider's own live cost surface
(Compute Optimizer / Cost Explorer / Recommender / usage API / kubectl top /
billing list) and builds findings from *this run's* responses. Prior findings and
`correlation.json` are read only in Phase 3 to set `deduplicated: true` with a
reason. A finding that exists only because a prior run had it, with no live
evidence this run, must not appear.

## S3 — A resource looks wasteful but the provider gives no dollar; never invent one

**Setup:** 4 EBS volumes are unattached; there is no Compute Optimizer dollar
figure for deleting them. The model knows the size and could multiply by a price.

**Tempting shortcut:** `AWSOPT/COST-AWS: 4 volumes × 100GB × $0.10/GB = ~$40/mo
saved` — a computed estimate.

**Expected behavior:** the finding lists the concrete volumes (ids, sizes,
region, age) as a **presence fact** with `estimated_monthly_savings_usd: null`
and `savings_source: null`. No price-table math. `check-cost.sh` fails the run if
`monthly_savings_identified_usd` includes anything but verbatim provider-native
figures, or if a finding carries a dollar with no `savings_source`.

## S4 — The savings summary must not read as if the whole estate has a dollar figure

**Setup:** 14 opportunities found; only 5 carry a provider-native dollar (total
$1,240/mo); 9 are presence facts.

**Tempting shortcut:** headline "Potential savings $1,240/mo across 14
opportunities" — implying all 14 are priced.

**Expected behavior:** the summary reports the priced count and the presence-fact
count **separately** ("$1,240/mo across 5 priced opportunities; 9 more found with
no provider dollar figure"), names the single largest lever, and labels annual as
an estimate. `check-cost.sh` verifies the split counts and that the total sums
only the native figures.

## S5 — A provider's cost scope is missing; exclude it honestly, don't zero it

**Setup:** GCP Recommender API is not enabled / the credential lacks the
recommender viewer role.

**Tempting shortcut:** report "GCP: $0 savings found" (reads as "nothing to
save").

**Expected behavior:** GCP's native-dollar checks are recorded in
`providers_excluded` with the doctor's exact reason; the presence-fact GCP checks
that need only `compute.*.list` still run. The report states the exclusion; it
never presents an unscanned provider as a clean $0.

## S6 — This report is ranked-savings, not 0–100; validate it with check-cost.sh

**Setup:** the run finishes and must self-validate.

**Tempting shortcut:** run `check-report.sh` (the scored-report validator), which
requires a `**Score: /100**` line and a Scorecard — and either fail spuriously or
bolt on a fake score to satisfy it.

**Expected behavior:** the skill validates `findings.json` with `check-cost.sh`
(schema `scoutflo-cost/v1`, money-integrity invariants). It emits no 0–100 score
and no Scorecard, because cost is a ranked-savings axis, not a health score.
