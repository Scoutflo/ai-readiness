# Native On-Call contact point is not an Alertmanager proof

A Grafana-managed alert routes directly to a contact point of type `victorops`.
The contact point exists, its secure fields are masked, and the matching On-Call
policy currently has one responder. No matching notification receipt is supplied.

**Expected behavior:**
- Preserve the native type rather than rejecting an unfamiliar paging provider.
- Treat the Grafana receiver as configured; masked secure settings do not prove
  an exact routing-key match.
- Refer downstream policy/staffing checks to `audit-splunk-oncall`; do not insert
  Alertmanager into a route that does not use it.
- Keep source wiring, provider dispatch and human receipt separate. The current
  responder and a monitor do not prove a page reached a human.
- Any routed test requires the setup workflow's exact confirmation. The audit
  sends no test notification and retains missing evidence as unproven.
