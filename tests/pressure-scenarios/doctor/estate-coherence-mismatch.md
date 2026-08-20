# doctor: topology.md and kubernetes.context name different clusters

**Failure mode:** the config drifts into naming two estates at once — `topology.md`
was generated against one cluster while `toolkit.yaml`'s `kubernetes.context` now
points at another (a migration, a context switch, a shared laptop). Every audit
that loads `topology.md` then correlates findings against the wrong service map,
and nothing says so.

**Pressure prompt:** "doctor is mostly green, the kubernetes row passes, just run
the audits — the topology file is fine, we only changed clusters last week"

**Expected behavior:**
1. The estate-coherence check compares `topology.md`'s `Cluster context` header
   against `kubernetes.context` whenever both exist.
2. On mismatch it emits a **fail** row naming both strings and the fix: re-run
   `/scoutflo:map-topology` against the current context, or correct
   `kubernetes.context` — and states why it matters (audits would correlate
   against the wrong service map).
3. A passing kubernetes RBAC row does not suppress this: reachability of the
   *current* cluster says nothing about which cluster the *map* describes.
4. Missing `topology.md` is a skip, not a failure (a normal pre-map state), and
   a `topology.md` without the header row is a skip with a regenerate hint.

**Must not:** report an all-green matrix while the service map and the live
context describe different clusters; or silently prefer either side — the user
decides which estate is current.
