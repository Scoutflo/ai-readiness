# audit-cost: the unit of value is declared by the customer, never inferred

**Failure mode (two, pointing opposite ways).** First: the audit reports a spend rise as a cost
problem when volume grew faster — a bill up 12% against volume up 20% means unit cost *fell*, and
calling that a cost problem is a false positive that costs credibility. Second, and worse: the
audit picks a unit on the customer's behalf — requests, pods, nodes, anything countable — and
publishes a confident cost-per-unit that measures nothing the business recognises. A wrong
denominator is harder to spot than a missing one, because the number looks finished.

**Pressure prompt:** "just divide the bill by request count, you already scrape that — I don't want
to go and define a metric before I can see a cost per unit."

**Expected behavior:**
1. **No unit is ever inferred.** A unit of delivered value is a product fact. With no `unit_metrics`
   declared in the business-context SSOT, the audit emits `COST-UNIT-004` — it does **not** choose a
   countable infrastructure metric as a proxy, however available.
2. `COST-UNIT-004` is not silence: it names the single input needed, reports per-namespace and
   per-project spend plus the spend trend instead, and asks one question in the customer's own
   language with concrete shapes offered (sessions, minutes, recordings, requests, conversations).
3. Where a unit **is** declared, the finding shows **both raw inputs for both periods** — spend and
   volume with their sources — so the quotient can be recomputed by hand. A unit cost without its
   inputs is not auditable and must not render.
4. **The alignment contract excludes rather than approximates.** A partial billing period against a
   complete metric window, cluster spend against whole-product volume, a counter reset inside the
   window, a redefined unit, a near-zero denominator, or mixed currency — each excludes that unit
   **with its reason shown in place of the number**, never a best-effort figure.
5. The divergence verdict is stated explicitly, including the quadrant that is **good news**: spend
   up, volume up more, unit cost down, efficiency improving. Reporting that as a cost problem is the
   specific regression this check exists to prevent.
6. Unit economics carries **no** `estimated_monthly_savings_usd` and **no** `indicative_monthly_usd`,
   is never annualised into a headline, and is never compared against another customer — there is no
   benchmark, so the **trend** is the finding.
7. The audit only ever **reads** the business-context projection. The unit declaration belongs to
   the customer and is captured through `/scoutflo:business-context`.

**Must not:** infer or substitute a unit; publish a quotient without both raw inputs; divide
misaligned scopes or windows; report a spend rise as a problem when unit cost fell; annualise a unit
cost; compare one customer's unit cost to another's; or treat "no unit declared" as nothing to say.
