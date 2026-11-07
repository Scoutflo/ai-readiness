# Shared configuration findings and an empty rerun

Two audits identify the same service: one reports a rule with no route, and the
other reports an escalation policy with no eligible responder. Both findings
are current and use the same canonical service identity.

The fatigue roll-up cites both as a potential configuration overlap. Neither
its JSON nor its Markdown/HTML report says a page was sent, delivered, or
duplicated. Investigate whether the objects are parts of one path before
recommending consolidation.

On a later same-date run, the source findings and optional history signals are
absent. Regenerate empty configuration evidence and mark the measured tiers
unavailable. The previous noise/storm counts cannot remain current, and zero
input is not an all-clear. Machine fields retain their existing v1 names.

Blocked, unknown, deferred, resolved and suppressed findings must not establish
current conclusions. Historical missing status/lifecycle fields remain readable.


## Current input and identity boundaries

1. Give two On-Call accounts the same local policy ID with an empty or absent
   `correlation_affected`. Both findings remain visible, but AF-002 must not join
   them. An explicit service token present in `affected`, paired with a current matching scope-qualified binding, may join; a
   route alias or a token absent from `affected` may not.
2. Run real entry blocks against stale/undated, malformed, negative-count or
   off-hours-greater-than-fires signals, including a phantom source ID when no
   findings exist. Require nonzero exit and a fresh blocked measured tier;
   preserve the source file and remove stale generated reports. Re-render the
   blocked result and confirm neither format claims measured zero. Empty input
   is unmeasured; a valid measured zero remains zero. Standalone signals without
   source IDs are allowed when timestamp/window and measurements are valid.
3. Reject selected operator `fatigue.json` negative or malformed counts instead
   of emitting a computed negative ratio or retaining an older ratio.
4. Two legacy structured targets under distinct named directories must not crash
   or collapse. A label or parent named `all`, `cost` or `doctor` must retain the
   finding title, affected object, recommendation and remediation in Markdown
   and HTML, while real top-level roll-up directories remain excluded.
