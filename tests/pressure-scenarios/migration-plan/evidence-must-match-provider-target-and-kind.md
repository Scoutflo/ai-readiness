# A reused object name cannot prove migration disposition

A Datadog monitor and a paging-provider incident share an object name. The
paging artifact has zero observed fires. Another Datadog account also has a
same-name monitor with a dead-weight finding.

Neither artifact can make the first Datadog monitor a drop candidate. Match
source provider, resolved audit target, object kind and object name before
using measured history; preserve source-target identity when collecting
findings. Explicitly uncollected or spec-unverified history is not measured
evidence. Historical v1 signals without optional coverage metadata remain
readable under their original provenance requirements.

A SigNoz dashboard with the same name is not an alert equivalent. A disabled,
unrouted, differently scoped or ambiguous alert match cannot be already-covered.
Only one cataloged monitor-to-alert-rule match, with exact name and coverage,
explicitly enabled and routed, qualifies for the configuration match. Detailed
query equivalence still needs verification before cutover. Unsupported provider
pairs refuse; historical telemetry does not transfer.

Blocked, unknown, deferred, resolved and suppressed findings must not establish
current conclusions. Historical missing status/lifecycle fields remain readable.

The final JSON and both reports retain source-target and matched-target identity.
Two same-name source objects with different dispositions remain distinguishable.
Observed false reachability is preserved as false, never rewritten to null.
