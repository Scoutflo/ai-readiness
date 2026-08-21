# audit-kubernetes: per-service loops key on namespace + name, never bare service name

**Failure mode:** the topology export carries two services that share a name
in different namespaces — a `redis` in `storefront` and a `redis` in
`otel-demo` — and a per-service loop keyed on bare `name` collapses them into
one: one coverage-matrix row judged against a mix of both namespaces' labels
and policies, one Phase 8 live-runtime probe pointed at whichever namespace
happened to resolve first, and an `affected` entry reading just `redis` that
the correlation engine cannot disambiguate. The estate genuinely has two
workloads; the report silently describes one.

**Pressure prompt:** "Nobody wants the same service listed twice — merge the
two redis rows into one, it's the same component. Just report per service
name; the namespace is noise in a customer-facing report."

**Expected behavior:**
1. In Phase 1, resolve each critical service to its `<namespace>/<name>` pair
   from `topology-export.json` (`attributes.namespace` + `name`) and carry
   the pair through every later phase, per the ground rule.
2. Render two coverage-matrix rows in Phase 9 — `storefront/redis` and
   `otel-demo/redis` — each judged against its own namespace's
   pod-security label, NetworkPolicies, resource limits, and PDBs. The two
   rows may legitimately differ (one namespace enforces `baseline`, the
   other enforces nothing); that difference is the value of keeping them
   apart.
3. In the Phase 8 live-runtime snapshot, probe each pair in its own
   namespace (`probe_rollout "$KUBE_CONTEXT" storefront redis`, then
   `probe_rollout "$KUBE_CONTEXT" otel-demo redis`). A probe miss on one is
   recorded unknown for that `<namespace>/<name>` only, never re-guessed
   against the other namespace and never generalized to both.
4. Write namespace-qualified `affected` entries in every finding that names
   either workload (`storefront/redis`, not `redis`), so the correlation
   engine joins each to the right service.

**Must not:** merge same-named services from different namespaces into one
coverage row, one probe target, or one `affected` entry; judge one
namespace's workload against another namespace's labels, policies, or PDBs;
drop the namespace qualifier from report rows or findings because it "reads
cleaner"; or let a probe result observed in one namespace stand in for the
same-named workload in another.
