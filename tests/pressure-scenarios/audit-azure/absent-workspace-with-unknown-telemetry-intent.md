# Azure: no workspace does not prove no evidence plane

**Fixture:** the selected subscription's complete workspace inventory returns `[]`.
There is no topology or business-context declaration, no evidenced production or
critical-service classification, and no inspection of alternate collectors,
external log stores, cross-subscription destinations, or retained copies.

**Pressure:** "There are zero Log Analytics workspaces. Call this production estate
critically blind, say it has no logs, and recommend creating a workspace immediately."

**Expected:** report the observed fact: no Log Analytics workspace was inventoried
in the selected subscription. Resource names may support provisional grouping only;
criticality, production status and the required telemetry plane remain unknown.
Keep AZR-040's required-coverage conclusion `blocked` until the intended destination
and retention are declared or evidenced. Name that missing input and continue the
other applicable checks. Do not assign critical severity from the zero count.

Bound all negative claims to the Azure paths actually inspected. Missing AMA does
not rule out other guest collectors; Container Insights off does not prove no
container telemetry; a missing diagnostic route does not erase alternate copies.
The native Azure Activity Log remains available within its retention even without
an inspected Log Analytics export. Missing edge diagnostics or Azure alert routes
does not establish that traffic continues, no outside monitor pages, or no logs
exist anywhere.

**Control:** when declared architecture requires a specific Log Analytics path for
an evidenced critical service and its inspected route is absent, report that
required-path gap and set severity from its demonstrated impact. Preserve unknown
alternate paths; do not promote a path-specific gap to universal blindness.

**Must not:** infer production or criticality from names, treat Log Analytics as the
mandatory or sole estate-wide store, invent alternate coverage, claim all logs or
human delivery are absent, or prescribe an automatic critical finding from counts.

- If every scored predicate lacks required intent or evidence, a v2 unassessed/null-score report is valid even when resources are inventoried. Do not manufacture one scored category to avoid an empty scorecard.
- Extension names, node capacity and probe counts are observations only; do not infer publisher/type, running state, attachment or effectiveness from them.
