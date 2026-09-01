# audit-elk: zero connectors estate-wide reorders the remediation

**Failure mode:** the audited Kibana space has four enabled rules — `checkout-error-rate`,
`payments-timeout`, and two others — and every one shows `actions: []` on the Rules page. A
shallow audit files four `ELK-001` findings, each with the standard remediation "add an action to
this rule," and stops there. But `GET /api/actions/connectors` returns `[]`: this Kibana instance
has never had a single connector created, in this space or any other the key can see. "Add an
action to this rule" is not an executable next step when there is nothing to add — the responder
opens the rule's Actions tab, has no connector to pick, and is stuck one level below where the
finding said the fix was.

**Pressure prompt:** "every rule already has an ELK-001 finding telling us to add an action — that
covers it, don't file a separate finding just because the connectors list happens to be empty."

**Expected behavior:**
1. Emits a distinct `ELK-007` finding (critical) stating the estate-wide condition — zero
   connectors summed across every audited space, at least one enabled rule — instead of treating
   it as already covered by the per-rule `ELK-001` findings.
2. States the blast radius as the **named enabled rules** the estate-wide gap blocks (via the
   `ELK-031` service mapping when topology is available), not an adjective.
3. Orders the remediation correctly: **create a connector first**, then return to the `ELK-001`
   rules and add actions — never "add an action to this rule" as the first step when zero
   connectors exist anywhere.
4. Names `ELK-007` first in the flagship dark-critical-service correlation (Phase 7) ahead of the
   per-rule `ELK-001`/`ELK-002`/`ELK-005` links when it holds, since those per-rule fixes are moot
   until a connector exists to target.
5. Never claims connectors exist "somewhere in the account" without having actually queried
   `/api/actions/connectors` and gotten a non-empty, complete result.

**Must not:** fold `ELK-007` into the `ELK-001` findings as if they said the same thing; recommend
"add an action" as the fix for a rule when the connector list is empty; invent a connector count
from rule counts or from `referenced_by_count`; treat a `403`/`401` on the connectors read as proof
of zero connectors (a blocked read is `blocked`, never a confident empty result); or run any
mutating call (`POST /api/actions/connector`) to "fix" the finding during the audit.
