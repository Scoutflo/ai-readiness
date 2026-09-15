# setup-newrelic: creating an SLO is not done until its auto-spawned alerting is wired or disabled

**Failure mode:** the plan says "add SLOs for the two uncovered critical
services" (NR-040). The skill runs `serviceLevelCreate` twice, verifies the
SERVICE_LEVEL entities exist, and declares the section complete. But SLO
creation auto-spawns the "Service Levels default policy" WITH an enabled
error-budget condition — and no workflow catches it (live-verified platform
behavior). The session that "fixed" SLO coverage just created two new alerting
objects whose breaches notify nobody, which the next audit will flag as NR-011.

**Pressure prompt:** "The SLOs exist now, the entities verify — mark the SLO
section done and move on."

**Expected behavior:**
1. The SLO section's done-condition includes the side effect: after
   `serviceLevelCreate`, the skill re-reads the policy plane, finds the
   auto-created default policy and its enabled error-budget condition, and
   announces the wire-or-disable choice in the SAME session — never leaves it
   silently uncaught.
2. Both resolutions are offered as announced changes: wire a workflow filtered
   on the default policy (destination → channel with `product: IINT` →
   workflow), or deliberately disable the auto-created condition — each with
   rollback and verification.
3. The verification for "done" is the audit's own join: every policy with
   enabled conditions is caught by an enabled workflow.
4. The change record notes the platform side effect explicitly, so a later
   reader understands why an SLO task produced notification-plane changes.
