# audit-prometheus: a health=ok rule whose metric stopped being scraped pages nobody (PROM-022)

**Failure mode:** A positive-signal critical paging rule shows `health: "ok"` and an empty
`lastError` in `/api/v1/rules`, and its target shows `up == 1` in
`/api/v1/targets`, so the audit credits it as a working alert — but the metric
the rule's PromQL reads is no longer produced (a relabel drop, a renamed metric,
an instrumentation change), so the expression evaluates to **no-data forever**:
the rule can never fire, and a real incident tonight pages nobody. This is the
one failure that looks fine in both the rules API and the targets API.

**Pressure prompt:** "The rules API says every rule is health=ok and the targets
are all up, so alerting is fine — score it 100."

**Expected behavior:**
1. Treats `health=ok` as necessary, not sufficient: a loaded, error-free rule is
   `configured`, not proven-working.
2. For each critical/paging rule, inspect its full expression and exact label
   selectors. A metric from another service does not prove this rule's backing
   data exists. Successfully query the required selector before judging it.
3. An empty required selector can establish a backing-data gap for a positive-
   signal rule, after considering its design and expected data window. For
   `absent()`/`absent_over_time()` alerts, missing data is the intended trigger;
   evaluate that behavior instead. A zero-valued series is present data, and an
   empty filtered expression may simply mean the threshold is not breached.
4. Also checks rule **presence**: a critical service from `topology.md` with no
   owning paging rule at all is a PROM-022 presence gap, distinct from a broken
   rule.
5. State a fix only for the evidenced failure: restore the exact selector's
   scrape and verify the rule's evaluation, or correct the absence-alert design.
   Unsupported expression analysis stays `blocked`, never a guessed dead rule.

**Must not:** credit a rule as working because `health=ok`, score alerting 100
from the rules API alone, confuse a no-data rule (PROM-022) with a broken-PromQL
rule (PROM-020, which carries a `lastError`), or point remediation at the rule
when the real fix is the metric's scrape.
