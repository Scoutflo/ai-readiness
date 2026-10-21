# Unit economics — cost per unit of delivered value (`COST-UNIT-001` to `COST-UNIT-004`)

Provider-agnostic. The only family in this skill that belongs to no single cloud, because it
divides **billed spend** (any provider's export) by a **business volume the customer declares**.

## 1. Why this exists, and the false positive it removes

Every other check in this skill answers "where is waste". Nobody running a business asks only that.
They ask: **what does a unit of our product cost to serve, and is that getting better or worse?**
A waste list is reducible; a unit cost is *defensible* — it is the number that survives a budget
conversation, because it separates "we are spending more" from "we are growing".

It also removes a false positive we currently produce. A bill that rose 12% while volume rose 20%
is **efficiency improving**. Report the 12% alone and it reads as a cost problem; report cost per
unit and it reads as a win. We have been showing the first number and not the second.

## 2. The one hard rule here

Unit cost is a **quotient of two sourced numbers**, and that is the entire licence:

- The **numerator** is billed spend from the provider's own export — the same figure the rest of
  this skill treats as fact.
- The **denominator** is a volume returned by a query **the customer wrote or confirmed**, against
  their own metrics backend.

That is why this is allowed where a list-price calculation is not: nothing here invents a *price*.
Both inputs are measured; the division is arithmetic.

Therefore, absolutely:

- **Never infer the unit.** A unit of value is a product fact, not an infrastructure fact. Sessions,
  participant-minutes, recordings, API requests, conversations, documents, tokens, orders — only the
  customer knows which one their business is counted in, and picking one for them produces a
  confident number that means nothing. **Ask. Never guess.** If no unit is declared, emit
  `COST-UNIT-004` and stop.
- **Never compare across customers.** There is no benchmark. "₹4.20 per 1,000 sessions" is
  meaningless in isolation and dangerous as a comparison. The **trend** is the finding.
- **Never divide misaligned scopes or windows.** Spend for a cluster over one month divided by a
  volume for the whole product over a different month is a plausible-looking fiction. Section 5 is
  the alignment contract; a mismatch excludes the metric rather than producing a number.

## 3. Where the unit is declared

In the **business-context SSOT** — not a new config block. A unit of value is exactly the kind of
customer-declared truth that file already owns (environment map, per-environment SLAs, criticality,
cost sensitivity), it already has a capture flow and a parity gate, and `audit-cost` already reads
its projection in the Metadata Load phase. Reuse that; add nothing new to `toolkit.yaml`.

```yaml
# business_context.md -> projected into ~/.scoutflo/business_context.json
unit_metrics:
  - name: "participant-minutes"      # what the business counts, in the customer's own words
    query: 'sum(increase(app_participant_minutes_total[30d]))'   # THEIR query, confirmed by them
    source: prometheus               # prometheus | victoriametrics | thanos | cloud-monitoring
    scope: all                       # all | project:<id> | cluster:<name> | namespace:<ns>
    per: 1000                        # report cost per 1000 units; 1 for expensive units
```

Several units may be declared — a product with both conversations and recordings has two. Each is
reported independently; never add them together.

## 4. `COST-UNIT-001` — unit cost and its trend

```bash
set -eu
# Both inputs are already produced by earlier phases of this skill; this block only joins them.
# Numerator: net spend for the declared scope, same period, from the provider export
#            (COST-GCP-023 / COST-GCP-024 for GCP; the equivalent per-provider spend query).
# Denominator: the customer's declared volume query, run against their declared source over the
#            SAME closed period.
BC="${HOME}/.scoutflo/business_context.json"
[ -f "$BC" ] || { echo "COST-UNIT-001 reports excluded, reason: no business-context projection; run /scoutflo:business-context"; exit 0; }
jq -e '(.unit_metrics // []) | length > 0' "$BC" >/dev/null 2>&1 \
  || { echo "COST-UNIT-001 reports excluded, reason: no unit_metrics declared — see COST-UNIT-004"; exit 0; }
jq -r '.unit_metrics[] | "\(.name)\tper=\(.per // 1000)\tsource=\(.source)\tscope=\(.scope // "all")\tquery=\(.query)"' "$BC"
```

Expected: the declared units. For each one, compute for **two consecutive closed periods**:

```
unit_cost      = net_spend(period)      / volume(period)      x per
unit_cost_prev = net_spend(period-1)    / volume(period-1)    x per
trend_pct      = (unit_cost - unit_cost_prev) / unit_cost_prev x 100
```

Report: the unit name, both unit costs with their currency, the trend as a signed percentage, and
**both raw inputs for both periods** — spend and volume, each with its source. A reader must be able
to recompute the quotient by hand; a unit cost whose inputs are not shown is not auditable.

This finding has **no `estimated_monthly_savings_usd` and no `indicative_monthly_usd`**. It is not a
saving, it is the measure every saving should be judged against. Set `basis` to the period pair and
both sources, e.g. `Sep vs Aug (export) ÷ Sep vs Aug (prometheus)`.

A **rising** unit cost is the finding. A falling one is worth reporting just as loudly: it is
evidence the engagement is working, and it is the only number that demonstrates that.

## 5. The alignment contract (why a number gets excluded)

Exclude the unit — never approximate it — when any of these holds. Each silently produces a
confident, wrong number, which is worse than no number:

| Condition | Why it is fatal |
| --- | --- |
| Period mismatch | Billing exports lag by hours to a day. Use only **closed** periods present in both sources; never pair a complete month of spend with a partial month of volume |
| Scope mismatch | Cluster spend ÷ whole-product volume understates unit cost by however much of the product runs elsewhere. The declared `scope` must resolve to the same resources the spend query covers |
| Metric reset or gap | A counter reset, a scrape gap, or a retention boundary inside the window makes `increase()` wrong. Check the series is continuous across the window and exclude if not |
| Unit changed meaning | A redefinition mid-window (the customer started counting differently) breaks comparability. If `query` or `name` changed since the last run, report the trend as unavailable and start a fresh baseline |
| Volume near zero | A tiny denominator produces an explosive cost per unit. Below a materiality floor, report spend and volume separately with no quotient |
| Currency mixing | Convert with **the export's own stated rate** for that period, never a live rate, and name the rate used |

## 6. `COST-UNIT-002` — spend-versus-volume divergence

The decomposition that tells you whether a spend rise is a problem at all.

```
spend_delta_pct  = (spend  - spend_prev)  / spend_prev  x 100
volume_delta_pct = (volume - volume_prev) / volume_prev x 100
```

Four quadrants, and the verdict differs completely:

| Spend | Volume | Verdict |
| --- | --- | --- |
| up | up **more** | **Efficiency improving** — unit cost fell. Say so plainly; this is the quadrant our old reporting mislabelled as a cost problem |
| up | up **less** | Efficiency degrading. Real finding — growth is costing more per unit than it used to |
| up | flat or down | **The urgent one.** Paying more to serve the same or less; point at `COST-GCP-028`'s rate-versus-usage split to say which half moved |
| down | flat or up | Efficiency improving, cost falling. Report it — it is the proof an action worked |

Pair this with the run-rate so the reader sees where the trend lands, and name the largest
contributing service from the spend side so the quadrant has somewhere to act.

## 7. `COST-UNIT-003` — non-production overhead ratio

Non-production delivers **zero units of customer value** by definition, so its spend is pure
overhead on the production unit cost. Expressing it as a ratio is far more motivating than its
absolute figure:

```
nonprod_overhead_pct = nonprod_spend / prod_spend x 100
fully_loaded_unit    = (prod_spend + nonprod_spend) / prod_volume x per
```

Report both the production unit cost and the **fully loaded** unit cost, with the gap between them
labelled as the non-production overhead. Do **not** frame this as waste — a healthy estate needs
pre-production environments, and a team with none is a different and worse finding. It is a ratio to
*know*, and it makes `COST-GCP-040`'s schedule and tier findings concrete: a scheduled nonprod moves
the fully loaded unit cost, and that is the number a budget owner feels.

## 8. `COST-UNIT-004` — no unit declared (the enablement finding)

When no `unit_metrics` exist, this is **not** silence. Emit a finding that says: unit economics is
unavailable, the single input needed to enable it, and what is being reported instead.

What to report instead, in descending order of usefulness: per-namespace and per-cluster spend
(`COST-K8S-009`), per-project and per-service spend (`COST-GCP-023`), and the spend trend. Those are
genuine and sufficient to act on — they are simply not *unit* economics.

Then ask exactly one question, in the customer's language, and offer concrete shapes rather than a
blank prompt: *"What does your business count? Sessions, minutes, participants, recordings,
requests, conversations, documents, orders? Name it and the query that measures it, and every future
run reports your cost per that unit and whether it is improving."* A metric they already graph is
the best candidate — if it is on an existing dashboard, it is already trusted and already correct.

## 9. Rendering

One short block, high in the report, above the ranked savings — because it frames every number
below it:

```
Cost per 1,000 participant-minutes: <amount> (Sep)  vs  <amount> (Aug)   -6.1%
  spend  <amount> -> <amount>   (+12.4%, billing export)
  volume <n> -> <n>             (+19.7%, prometheus)
  Efficiency improving: spend rose, volume rose more.
  Fully loaded (incl. non-production overhead 9.2%): <amount> per 1,000
```

Never annualise a unit cost into a headline, never present it without both raw inputs, and never
show it at all when section 5 excluded it — show the exclusion reason in its place.

## 10. Commands this check must never run

No writes anywhere. It issues read-only metric queries and read-only billing `SELECT`s, and it never
modifies the business-context file: the unit declaration is the customer's, captured through
`/scoutflo:business-context`, and this check only reads the projection.
