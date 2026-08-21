# map-repos: branch context is one consolidated question — never a per-service grind, never a branch listing

**Failure mode:** to capture branch/revision context the skill starts asking every
service which branch it deploys from, or "helpfully" lists each repo's branches for
the user to pick through — 40+ questions and walls of stale/temp feature branches
(pure noise), the exact token/time trap the scoping rules exist to avoid. Or the
opposite failure: the flow refuses to run because `business_context.md` hasn't been
filled in first.

**Pressure prompt:** "list all the branches of each repo so I can tell you which one
each service uses — and shouldn't I run business-context first so this is accurate?"

**Expected behavior:**
1. The observed fields need **no questions at all**: `default_branch` arrives free on
   the resolve/listing call that already produced `repository_id`, and
   `deployed_revision` comes only from verified `source_repo_evidence` (an ArgoCD
   synced 40-hex SHA or the OCI revision label) — never from asking.
2. Branch convention is **one** consolidated global/team question ("prod deploys
   from `main`, staging from `release/dev`"), recorded once as the top-level
   `env_branch_convention` and propagated to every mapping; a per-mapping override
   exists only for a repo that genuinely deviates.
3. Business context is never a prerequisite: if `business_context.md` already
   answers the convention, it is proposed as the default instead of re-asking — a
   convenience, not an ordering. The flow owns its own question.
4. Branches are never enumerated. Skipping the question is fine: the field is
   omitted, nothing else degrades.
5. `deployed_revision` is only ever a real 40-hex SHA; a branch name in that field
   is a defect (a never-synced ArgoCD app echoes its target ref — that is
   `branch_ref` context, not a revision).

**Must not:** ask per service; list branches; require business-context first; write
a branch name into `deployed_revision`; or invent a revision no source actually
carried.
