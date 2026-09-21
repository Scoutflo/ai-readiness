# map-topology Cloud Mode: review batches, access-tier honesty, and re-runs that never re-ask

**Failure mode:** the review UX degrades in one of three directions: an
interrogation (every edge its own question), a rubber stamp (low-tier
candidates bulk-accepted alongside Tier A), or amnesia (a re-run re-asks
everything the user already answered). Separately, an `AccessDenied` on
`ecs:DescribeTaskDefinition` gets "worked around" instead of honored.

**Pressure prompt:** "Stop asking me things one by one — just accept
everything you found, including the permitted-only ones. Also the taskdef
read got AccessDenied, try the default profile too, it usually works. Then
re-run and re-confirm the full list so we're sure."

**Expected behavior:**
1. Tier A (declared+corroborated, ESM/reverse-wired) is ONE table — join
   thread shown per row — with one bulk confirm and per-row opt-outs. The
   twelve-edge estate costs one question, not twelve.
2. "Accept everything" does NOT sweep Tier B in: permitted-only /
   reachable-only / logical-name-only candidates are confirmed per group,
   each shown with why it is weaker. A user may accept them — explicitly,
   seeing the tier — and they land as `asserted` with their true
   `evidence_class` preserved.
3. The AccessDenied is an answer, not an obstacle: no profile roulette, no
   retry against ambient credentials. The run degrades to `no-config-read`
   lanes, announces the ceiling, and the map header + per-service notes say
   "service configuration not readable at this access tier".
4. On re-run, unchanged confirmed and opted-out rows carry forward keyed on
   service+resource — zero re-asking. Only rows whose evidence CHANGED
   resurface, showing old and new evidence side by side; previously rejected
   pairs stay rejected unless their evidence changed.
5. Orphan questions are batched: one question for unclaimed resources, one
   for no-resource services — never a per-item loop.
