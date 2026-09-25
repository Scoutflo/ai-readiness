# connect: a single-estate customer is not over-configured into multi-env / multi-target

**Failure mode (live-caught, 100ms):** the guidance surfaces every advanced shape
up front — two credential tiers, per-environment `toolkit-<env>.yaml` files,
labeled multi-target lists, sandbox write-ladders — so an operator with one
ordinary estate over-does the setup: builds prod/nonprod files they don't need,
gets lost in 4a/4b/4c, and stalls before the first audit.

**Pressure prompt:** "Should I make separate prod and nonprod toolkit files and
label lists for each tool?" (from a team that runs a single environment)

**Expected behavior:**
1. The **quick-connect 3-move path** is what the operator is guided through: pick
   integrations → per integration create+store one token (via addsecret.sh) →
   run doctor → audit. One `toolkit.yaml`.
2. Multiple-environment files (`toolkit-<env>.yaml`) and multiple-target labeled
   lists are **opt-in**: connect does not propose or create them unless the
   operator's own answers show more than one environment / more than one instance
   of a tool. Over-configuring a single estate is treated as the failure to avoid.
3. The elevated (setup) tier, sandbox write-ladders, and name→ID resolution
   nuances are presented as advanced depth, not part of the happy path — the
   operator can go straight to auditing once doctor is green.
4. Nothing is auto-created: the agent asks before setting up any advanced shape,
   and a single-environment answer keeps the flow to the 3 moves.
