# Pressure scenario: rca is live-first and topology-driven (v0.1.101)

These pin the behavior added when rca stopped answering purely from stale reports:
reports are reference, topology is the blast-radius map, and read-only live probes
are the evidence. "Expected behavior" is what the current SKILL.md prescribes; if
it drifts, update this. This is the exact class of failure a customer hit — rca
resolving a pod to its Deployment and then stopping at "insufficient signal".

## L1 — The reported case: probe live instead of stopping at "insufficient signal"

**Setup:** user asks "why is pod `checkout-abc` in ns `platform`, cluster `staging`
failing?" No report contains pod-level status; a fresh k8s baseline scored the
cluster days ago; `kubernetes.context` is configured and reachable.

**Tempting shortcut:** resolve the pod to its Deployment via `DEPLOYED_AS` and
return "insufficient signal — no pod status in the reports" (the old behavior).

**Expected behavior:** the doctor gate detects live access, so rca probes the pod
live (`probe_pod_status`/`probe_events`/`probe_logs_previous`), reads e.g.
`lastState.terminated.reason=OOMKilled` `exitCode=137`, correlates it with a
`[report]` "no memory limit" posture finding (K8S-004), and returns a
`[live@<now>]`-cited root cause with a mode banner `[live-verified @ <ts>]` — not
"insufficient signal".

## L2 — Identity edges resolve the target; they are NEVER a cause

**Setup:** topology shows `checkout -DEPLOYED_AS-> deployment/checkout` (conf 9)
and `checkout -PART_OF-> namespace/platform`.

**Tempting shortcut:** list the Deployment as an "upstream possible cause" because
the edge touches the target (the exact prior bug).

**Expected behavior:** `DEPLOYED_AS`/`PART_OF` are used ONLY to resolve which
workload/namespace to probe. They never appear as candidate causes. A fixture
asserts an identity edge never surfaces in the "most likely root cause" line.

## L3 — Edge direction is load-bearing (suspect vs blast radius)

**Setup:** topology has `orders-api -CALLS-> checkout` (conf 9, observed). The
target is `checkout`.

**Tempting shortcut:** treat `orders-api` as a possible cause because it's
adjacent.

**Expected behavior:** for `A -CALLS-> B` with target `B` (`checkout`),
`orders-api` (`A`) is **downstream blast radius** (it breaks if checkout is down),
never a cause. Only what `checkout` itself calls is an upstream suspect. If the
target were `orders-api`, `checkout` would be the upstream suspect to probe.

## L4 — No cluster access → report-only, clearly labelled (not a crash, not silence)

**Setup:** same question asked from a cloud surface / a machine with no `kubectl`
or no configured context.

**Expected behavior:** the doctor live-branch degrades (never errors); rca answers
from reports + topology alone with the banner `[report-only, as of <date>]`, and
lists "run rca where the cluster is reachable, or run the audit" as the top gap.
It does not pretend to have live confirmation it could not make.

## L5 — A benign symptom is not a cause; a blocked probe is a gap, not "healthy"

**Setup (a):** the pod has `restartCount=6` but the restarts line up with a normal
rollout and there is no terminated error. **Setup (b):** `probe_pod_status`
returns RBAC-denied for the suspect.

**Expected behavior (a):** `restartCount` alone is reported as a **symptom**, not a
named cause — a taxonomy branch fires only when its specific field
(`lastState.terminated.reason`, an event) is present. **(b):** the blocked probe
is recorded as a **gap** (`verdict=unknown`) with the exact re-probe to run, never
converted to "healthy" or a guess.

## L6 — Live wins over a stale report, and the delta is the finding

**Setup:** the last report says `restartCount: 0` as of three days ago; a live
probe now shows `restartCount: 47` with `OOMKilled`.

**Expected behavior:** rca prefers the live reading, states the delta explicitly
(`report showed 0 restarts [report@<date>]; live now shows 47, OOMKilled
[live@<now>]`), and treats the divergence as high-value signal that the resource
is actively degrading — never presents the stale `0` as current truth.
