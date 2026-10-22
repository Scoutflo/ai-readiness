# The four reasons a check is not in scope

A check ledger has two ways to leave the readiness denominator, and they say
opposite things:

- `blocked` — **we could not look.** The result is unknown. The next action is to
  unlock the evidence.
- `not-in-scope` — **we looked, and there is nothing to do.** The next action is
  nothing, or a one-line config edit.

Both are honest. Swapping them is not. Marking an unmeasured check
`not-in-scope` turns a risk nobody has assessed into a clean bill of health, and
the reader has no way to tell from the report that it happened. That is why
`not-in-scope` requires a `not_in_scope_reason` from a closed set of four, and
why each of the four carries its own evidence duty.

This file is the single definition of those four reasons. It is referenced by
[findings-schema.md](findings-schema.md) (the field) and by every audit that can
legitimately emit one.

One of the four — `inapplicable` — is the original and commonest meaning of
`not-in-scope` and is not a failure mode; it is simply a check that has nothing
to assess on this target. The other three exist because their absence produced
three specific classes of confidently wrong finding.

## `inapplicable` — the check has no meaning for this target

Use when the target's own identity means there is no such thing here to assess:
a server version that removed the feature, an engine that does not have the
concept, a component the configured stack does not include.

**Must be detected from the target's identity**, which is a read the audit
already does: the version string, the engine type, the configured block list.
Examples of the correct use:

- a pod-security-policy check against a Kubernetes server ≥ 1.25, where the API
  was removed from the platform — the absence is the platform's, not the
  customer's;
- a storage-headroom check against a managed engine that auto-grows storage, so
  "headroom" has no meaning;
- a dashboard check against a stack whose configuration does not include the
  dashboard component at all.

This is **not** a get-out for a check that is merely hard, slow, or
unauthenticated — those are `blocked`. The distinguishing question: if you had
perfect access, would there be anything to look at? If yes, it is not
`inapplicable`.

Prefer `inapplicable` over the other three when more than one could arguably
fit: it is the only one that claims nothing about the customer's intent, their
other planes, or the lifecycle of their infrastructure.

## Why the other three exist: three ways a report loses a reader's trust

Each reason below was added because the absence of it produced a specific,
observed class of wrong finding — a finding that was *structurally valid*,
reconciled with its scorecard, and passed every gate, while being wrong about
the estate.

1. **A deleted thing reported as a broken thing.** A monitoring server was
   decommissioned months earlier and its config block was never removed. The
   audit could not reach it, filed a `critical` "the metrics plane is down,
   restore or fail over the server", and recommended an emergency response for a
   machine that no longer existed. Every statement in the finding was true of an
   unreachable host; none of it was true of the estate.
2. **An intentional state reported as waste or neglect.** A warm-standby cluster
   sized for failover looked exactly like a grossly over-provisioned idle
   cluster, so the audit recommended shrinking the thing whose entire purpose is
   to be big before it is needed. The customer knew; the audit did not ask.
3. **A capability reported as missing because it lives somewhere else.** Alert
   rules had been moved out of one component and were applied to a different
   plane from Git. The audit read the plane it owns, found no rules, and reported
   every critical service as unalerted. The estate was alerted. The audit was
   looking in the wrong place and said so with full confidence.

The pattern in all three: **the audit reported the limit of its own view as a
property of the customer's system.** A reader who knows the estate spots it
immediately and stops trusting the rest of the report — including the findings
that were correct.

## `target-gone` — the configured target no longer exists

Use when the thing named in the config was decommissioned and the config
outlived it.

**Must be detected, authoritatively.** A positive not-found from the control
plane that owns the resource:

- a name that returns **NXDOMAIN from the zone's authoritative nameserver**,
  with a resolving sibling (the zone apex) proving it is not a local resolver
  failure;
- a cloud or cluster API that answers "no such resource" for an identifier it
  would recognise;
- a target absent from the provider's own authoritative list of targets.

**A timeout, a refused connection, a TLS failure, a 5xx, or a DNS failure you
could not attribute is `blocked`, not this.** Those are indistinguishable from a
firewall, a VPN you are not on, or an ingress outage — all of which mean the
target is alive and you cannot see it. The whole value of this reason is that it
is only reachable through evidence that a reachability failure cannot fake.

**The action is on the config, not the infrastructure.** Say it in `reason`:
retarget or remove this block. Never emit a restore/fail-over/scale
recommendation for a target proven gone — that is the exact finding this reason
exists to prevent.

**Never** use it for a target that is merely *empty* (a cluster with no
workloads, an org with no dashboards). Empty is a real, assessable state and is
usually a genuine `fail` or `partial`. Gone means the address itself resolves to
nothing.

## `by-design` — the state is intentional

Use when the observed state is what the customer chose: a warm standby, a DR
replica, a backup target, a deliberately cold environment, an accepted
trade-off.

**Must be declared, never inferred.** The admissible evidence is a customer
declaration recorded in the business-context SSOT projection and captured through
`/scoutflo:business-context` — either a matching `resource_intent` entry, or a
matching `exclusions` / per-resource `action: "skip"` entry (an exclusion *is* a
declaration: the customer said "do not judge this", which is why the exclusions
path maps here and not to `inapplicable`). Intent is a fact about the customer's
plans. It is not visible in telemetry, it is not derivable from a naming
convention, and a resource that *looks* like a standby is not a standby.

Specifically, **none of these establishes intent**: the resource name containing
`standby`, `dr`, `backup`, `canary`, or `spare`; a label or tag asserting it; a
low request rate; a replica relationship; a non-production-looking cluster name;
or a plausible inference from the architecture. Each of those is worth
*mentioning* in the finding as a prompt for the customer to declare, and none of
them is a licence to downgrade.

**With no declaration, the finding stands.** This is the asymmetry that keeps the
reason honest: silence is not consent, because the cost of wrongly reporting an
intentional standby is one correction, while the cost of wrongly silencing a
genuinely idle or neglected resource is a miss the customer is paying for. So
the default is to report it — and to name the single declaration that would
reclassify it, so the customer can answer once and have every future run get it
right.

When a declaration **does** exist, prefer **annotate-and-downgrade** over
disappearing the row: keep the observation visible with its intent stated, so
the reader sees "this 754-core cluster is at 3% CPU, declared warm standby for
the primary region" rather than nothing at all. A declared standby that has
drifted far past the capacity its purpose requires is still worth saying out
loud; `by-design` silences the *verdict*, not the *fact*.

## `covered-elsewhere` — the capability lives on a plane this audit does not read

Use when the capability is genuinely present in the estate, but implemented on a
plane outside this audit's read surface — so this audit's failure to find it
says nothing about whether the estate has it.

**Must be detected, with a pointer.** Evidence naming the plane that owns it:

- a component configured to read rules from an external or datasource-managed
  ruler;
- a declared provisioning path (rules or dashboards held in Git and applied by
  another component);
- a sibling integration in the same config that demonstrably owns the
  capability.

The pointer is what makes this reason falsifiable. Without it, the claim
"something else probably covers this" is a guess that reads as an assurance.

**"The customer told us it is handled" is `by-design`, not this** — that is a
declaration, and it belongs in the business-context SSOT where it is recorded,
versioned, and reusable, rather than absorbed into one run's evidence.

### Verified coverage exonerates; inferred coverage only reframes

This is the line that keeps `covered-elsewhere` from becoming an escape hatch,
and it matches the honesty bar the correlation engine already enforces for the
same word (`skills/correlation-engine/lib/correlation-engine.sh`: an exact
normalized `covers == affected` match on a monitor that is `enabled != false`
**and** has a real `routes_to`):

- **The audit read the owning plane and confirmed the capability there** — an
  exact match on the specific thing the check requires, enabled and routed. The
  capability is proven present, merely implemented somewhere this audit does not
  normally look. Emit `not-in-scope` / `covered-elsewhere`. Nothing is hidden,
  because something was verified.
- **The audit could not read the owning plane** — it only has a pointer saying
  the plane exists. That is *not* `not-in-scope`. The check stays a finding, with
  its severity lowered to reflect the pointer and its
  [`coverage_gap`](findings-schema.md) populated so the correlation engine can
  reframe it against the owning provider's own audit. Per `/scoutflo:rca`,
  cross-tool coverage **reframes a gap as a single-tool dependency; it does not
  exonerate it.** A pointer is evidence that someone else might be looking, not
  evidence that anyone is.

The practical test: could you name the exact rule, monitor, or object that
satisfies this check, and say it is enabled? If yes, exonerate. If you can only
name the *system* that probably holds it, reframe.

**When this audit cannot see the owning plane, the row is `blocked` — not this
reason.** The honest output is a **`blocked` row plus a populated
[`coverage_gap`](findings-schema.md)**: the capability is owned elsewhere, this
run did not verify it, and here is the integration that would. Reaching for
`not-in-scope` there is how "we did not check" silently becomes "it is fine",
and because `coverage_gap` is advisory and unvalidated, nothing downstream would
catch it. If the owning plane *is* configured in the same `toolkit.yaml`, the
right move is stronger still: point the reader at that audit's result instead of
asserting coverage on its behalf.

## Hard rules

- `not_in_scope_reason` is one of `inapplicable`, `target-gone`, `by-design`, or
  `covered-elsewhere`. There is no `other`. A situation that fits none of the
  four is `blocked`, `partial`, or `fail` — the closed set is deliberate,
  because an open one becomes a dumping ground for inconvenient rows.
- Every `not-in-scope` row carries a `reason` that states the evidence, not the
  conclusion. "Not applicable" is not a reason. "NXDOMAIN at the authoritative
  NS, zone apex resolves — host decommissioned; remove the `prometheus:` block"
  is.
- Never emit a remediation that acts on the live system for a `target-gone` row.
- Never downgrade on inferred intent. No declaration, no downgrade.
- Never let `covered-elsewhere` stand without naming the owning plane.
- A `not-in-scope` row carries no finding and recovers no points. If you want to
  tell the reader something about it, that belongs in the `reason` and in the
  report's coverage section — not in a finding.
- When in doubt between `blocked` and `not-in-scope`, choose `blocked`. Unknown
  is always a safe thing to say; "nothing to do here" is not.
