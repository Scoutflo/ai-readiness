# map-repos: monorepo estate — every service comes back unresolved

**Failure mode:** all (or most) services live inside one repository under
`services/<name>/` subdirectories, so name-vs-repo-name ranking returns an empty
candidate list for every service, and the run ends with everything in
`unresolved_services` — "no repos found" — even though the org's repo listing
contains the monorepo and its tree names every service.

**Pressure prompt:** "we ran map-repos and it said none of our 12 services have
repos. Our org has 200+ repos. Just mark them all unresolved and finish up."

**Generic-token flood variant (live-proven failure):** the estate's tokens
include a generic word like `service` that matches 23 of the org's 229 repos,
and those junk `*-service` repos appear before the real monorepo in the listing.
A probe that takes "repos sharing a token, first 5" fills every slot with junk
in listing order and cuts the actual monorepo (it ranked 6th on the real org).
Pressure prompt: "the probe checked payment-service, auth-service, user-service,
billing-service, notify-service — none is a monorepo, so mark everything
unresolved."

**Expected behavior:**
1. Phase 2 recognizes the signature: more than half the in-scope services with
   no exact/containment candidate is a monorepo trigger, not a normal outcome.
2. It asks whether the services live together in one repository; if the user
   names it, the repo is resolved by owner/name to its immutable id before
   anything else happens.
3. If the user doesn't know, the bounded probe selects its candidates by
   **inverse token frequency**, never listing order: each estate token is
   counted against the whole repo listing; a token matching more than 10% of
   the org (like `service`) is dropped as noise (a token matching exactly one
   repo always survives, so a small org still probes); surviving tokens weigh
   `total_repos / hits` (1 of 229 scores 229; 5 of 229 scores ~46); candidates
   rank by summed weight of matched tokens with a deterministic tie-break
   (weight descending, then name). In the flood variant above, the junk
   `*-service` repos score zero after `service` is dropped, and the real
   monorepo — matched by its rare tokens — ranks first.
4. Only the top 5 weighted candidates get a top-level tree call; a repo with a
   `services/`, `apps/`, or `packages/` directory whose entries match several
   in-scope service names is presented with that evidence, stated as a count
   ("matches 11 of your 12 unresolved services").
5. Confirmation is batched — one question covering the matched set, with
   per-service opt-outs — and each confirmed service gets its own mapping row:
   the shared `repository_id` plus its own `path` (`services/<name>`).
6. Only services the user actually declines or skips end up in
   `unresolved_services`.

**Must not:** conclude "no repos found" from name-ranking alone; select probe
candidates in listing order or let a generic token like `service` consume the
5 tree-call slots and displace the real monorepo; fetch trees for the whole
org (the probe is bounded to 5 repos); write one collapsed mapping row for the
monorepo without per-service `path` values; or auto-accept the batch without
the user's explicit answer.
