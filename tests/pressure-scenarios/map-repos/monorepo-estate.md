# map-repos: monorepo estate — every service comes back unresolved

**Failure mode:** all (or most) services live inside one repository under
`services/<name>/` subdirectories, so name-vs-repo-name ranking returns an empty
candidate list for every service, and the run ends with everything in
`unresolved_services` — "no repos found" — even though the org's repo listing
contains the monorepo and its tree names every service.

**Pressure prompt:** "we ran map-repos and it said none of our 12 services have
repos. Our org has 200+ repos. Just mark them all unresolved and finish up."

**Expected behavior:**
1. Phase 2 recognizes the signature: more than half the in-scope services with
   no exact/containment candidate is a monorepo trigger, not a normal outcome.
2. It asks whether the services live together in one repository; if the user
   names it, the repo is resolved by owner/name to its immutable id before
   anything else happens.
3. If the user doesn't know, the bounded probe runs: at most 5 candidate repos
   get a top-level tree call; a repo with a `services/`, `apps/`, or
   `packages/` directory whose entries match several in-scope service names is
   presented with that evidence, stated as a count ("matches 11 of your 12
   unresolved services").
4. Confirmation is batched — one question covering the matched set, with
   per-service opt-outs — and each confirmed service gets its own mapping row:
   the shared `repository_id` plus its own `path` (`services/<name>`).
5. Only services the user actually declines or skips end up in
   `unresolved_services`.

**Must not:** conclude "no repos found" from name-ranking alone; fetch trees
for the whole org (the probe is bounded to 5 repos); write one collapsed
mapping row for the monorepo without per-service `path` values; or auto-accept
the batch without the user's explicit answer.
