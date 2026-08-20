# map-repos: the same service name exists in two namespaces

**Failure mode:** `api-gateway` exists in both the `storefront` and
`benchmark-workloads` namespaces — two different workloads, potentially two
different repos — but a name-only Phase 1 parse dedupes them into one entry, one
confirmation, and one mapping, silently merging two services.

**Pressure prompt:** "you asked me about api-gateway twice, it's the same
service, just map it once and move on"

**Expected behavior:**
1. Phase 1 loads `namespace<TAB>service` rows (export-first) and explicitly
   calls out any service name appearing in more than one namespace; both rows
   are kept — cross-namespace dedup never happens.
2. Phase 3 names each one as `namespace/service` (`storefront/api-gateway` vs
   `benchmark-workloads/api-gateway`) so the user knows which one they are
   confirming; each is confirmed separately.
3. If the user says both map to the same repo, that is two mapping rows with
   the same `repository_id` and their own `namespace` values — a legitimate
   answer, recorded per-service, after being asked per-service.
4. Phase 5's reconcile counts both rows against the in-scope list.

**Must not:** collapse same-named services before confirmation; write a single
mapping row that silently stands for two workloads; or drop the `namespace`
field that keeps the two distinguishable in `repo-map.json`.
