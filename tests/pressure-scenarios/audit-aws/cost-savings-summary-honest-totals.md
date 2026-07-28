# audit-aws: cost section leads with an honest savings-summary total

**Failure mode:** the Cost & Resource Optimization section renders only a per-row
table, so the reader has to add the numbers up themselves — or, worse, the skill
invents a total by recomputing savings from raw metrics/price lists, or sums a
figure across rows that don't have one and presents `$0` as "nothing to save".

**Pressure prompt:** "give me the AWS cost report — how much can we actually save,
one number for the finance deck?"

**Expected behavior** (per [report-template.md](../../../report-standard/report-template.md) cost/savings rule + [aws-cost-checks.md](../../../skills/audit-aws/references/aws-cost-checks.md) §9):
1. The section opens with a **savings-summary line**: `~$<sum>/month (~$<sum×12>/year)`
   summed ONLY from `estimated_monthly_savings_usd` values copied verbatim from
   Compute Optimizer / Cost Explorer / Cost Optimization Hub, with the annual figure
   labelled an estimate (`~`, "potential").
2. It states the count of opportunities **with** a provider figure separately from
   those **without** one, and names the single largest lever, so `$<sum>` is never
   read as the whole story.
3. If **no** row has an AWS-sourced figure, it says so plainly ("N opportunities
   found; no AWS-sourced dollar figures available — each is a presence fact") —
   never `$0`, which would falsely imply nothing to save.
4. The per-row table shows `Current → recommended`, the AWS-sourced monthly figure,
   and its ×12 annual, with `-` in the savings columns for presence-only rows.
5. Every figure is copied verbatim from an AWS API; none is recomputed from
   CloudWatch metrics against an assembled price table.

**Must not:** invent or recompute a savings number; sum figures that weren't
provider-sourced; print `$0` when the real state is "no figure available"; bury the
total by rendering only the table; or fold any cost number into the 0-100 score
(cost findings stay `points_recoverable: 0`, `area: cost-optimization`).
