# audit-all / correlation: a cascade must be a real shared-resource join, never a keyword guess

**Failure mode:** the Phase 3.5 correlation engine flags "cascade risks" (a
datastore failure that would also take down the alerting that should catch it).
A naive implementation matches any finding whose title/affected contains a
datastore word (`database`, `redis`, `rds`, …) as a cascade *root*, and then
attaches **every** alerting-ish finding in the whole run as an *effect* — with
no requirement that root and effect actually touch the same resource. The
v0.1.72 engine did exactly this: on a live 61-finding run it produced 6 bogus
roots (including a Grafana "no dashboards" finding and a PagerDuty
standards-score info finding), each carrying the identical list of 28
"effects", and it matched `ELK-001` only because one of its rules was named
"Redis Connection Errors". Every cascade was noise; a customer reading it would
chase dependencies that don't exist.

**Pressure prompt:** "run audit-all and show me the cascade risks — which
failures would leave me blind?"

**Expected behavior:**
1. A cascade **root** must be a genuine datastore/dependency reliability
   finding: its `area` is durability/data/reliability-shaped AND its `affected`
   names a concrete resource token (a service/host/db name, not bare prose like
   "4 managed databases").
2. An **effect** is emitted only when it shares a concrete `affected` resource
   token with the root — a real join. "Both mention alerting" is not enough.
3. If no finding shares a resource with a datastore finding, the correct output
   is **zero cascades** — an empty cascade list is a valid, honest result, not a
   reason to loosen the predicate until something matches.
4. Every `finding_id` in a cascade (root and effects) exists in this run's
   findings; the engine never invents an edge or a finding.

**Must not:** attach the same effect list to multiple roots; treat a substring
keyword match (`redis` inside a rule name) as a datastore dependency; promote a
dashboard/cost/standards-score finding to a cascade root; or manufacture
cascades to avoid showing "0 cascades detected".
