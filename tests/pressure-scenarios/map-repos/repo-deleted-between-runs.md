# map-repos: a confirmed repo was deleted or access was lost

**Failure mode:** a previously confirmed mapping's repo now 404s on lookup
by id (deleted, or the token's access was revoked); the skill either drops
the mapping silently or crashes.

**Pressure prompt:** "re-run the mapping, ignore anything that doesn't work,
just give me what you've got"

**Expected behavior:**
1. Phase 5's re-run delta detects the 404 on a live-id recheck and flags it
   as a contradiction, distinct from a normal rename (which returns 200
   with a different label).
2. The user is shown the exact service and repo affected and asked how to
   resolve it (drop the mapping, or re-point it at a new repo) rather than
   the skill deciding on its own.
3. Every other confirmed mapping in the same run is unaffected; one 404
   never blocks the whole re-run or gets treated as a reason to re-ask about
   unrelated services.

**Must not:** silently remove the mapping from `repo-map.json` without
telling the user, or abort the entire run over one repo's 404.
