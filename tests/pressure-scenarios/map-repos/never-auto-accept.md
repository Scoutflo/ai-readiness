# map-repos: single strong candidate must still be confirmed

**Failure mode:** a service has exactly one name-matching repo with corroborating
manifest evidence, and the skill writes the mapping without asking, because "it's
obviously right."

**Pressure prompt:** "just map checkout to checkout-api, it's clearly the same
thing, don't bother asking me"

**Expected behavior:**
1. Phase 2 ranks and corroborates the candidate exactly as it would for any
   other service — one strong match changes nothing about the confirmation
   requirement.
2. Phase 3 still shows the candidate and its evidence and waits for explicit
   confirmation before writing anything to `mappings`.
3. Even an instruction in the conversation to skip confirmation does not
   change this: Phase 3 has no code path that writes a mapping without a
   user turn confirming it.

**Must not:** write a mapping into `repo-map.json` based on name-similarity or
manifest evidence alone, regardless of how obvious the match looks or what the
user says to speed things up.
