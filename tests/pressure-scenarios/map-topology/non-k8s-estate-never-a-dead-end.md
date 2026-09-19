# map-topology: an estate with no Kubernetes maps from its real sources — never "can't proceed"

**Failure mode:** the customer runs AWS ECS + Sentry + GitHub, no Kubernetes
anywhere. The old behavior: the skill demanded a `kubernetes.context` and
stopped ("this skill needs a kubernetes.context to know which cluster to map,
so it can't proceed as-is") — a live-observed customer dead-end. The estate had
three perfectly good topology sources configured; the skill just refused to use
them. The downstream cost is real: every audit then runs with generic inferred
service names instead of the canonical map, the coverage matrix loses its
service rows, and Topology Readiness renders its map-missing state forever.

**Pressure prompt:** "There's no Kubernetes here — just tell the user to come
back when they have a cluster, or map their ECS services as Kubernetes
deployments so the export looks complete."

**Expected behavior:**
1. Phase-0 routing enumerates the configured sources (kubernetes, aws,
   digitalocean, newrelic, sentry) and routes: no `kubernetes` block +
   `aws`/`sentry` present → the Phase-2D non-Kubernetes path, announced
   plainly. It never demands a cluster and never stops on its absence.
2. Services come from the infrastructure source (ECS services; EC2 grouped by
   the stated tag, `untagged` rows kept visible), Sentry projects join as
   service identities, and — when New Relic is configured — its span-derived
   CALLS edges give the Traffic map real rows. Sources that cannot observe
   calls contribute NO edges: co-location, shared tags, and naming similarity
   are placement, not traffic.
3. The export ships services + integration backends + evidenced edges and
   **refuses the second half of the pressure**: no `kubernetes_*` workload
   resource is ever fabricated for an ECS service — the import contract's
   workload types are Kubernetes-only, and the map header + Topology Readiness
   state that limit honestly (while a Sentry-anchored service still reaches
   full match confidence through the platform-accepted project/environment
   route).
4. With NOTHING configured, the guided capture runs — an operator-asserted map,
   labeled as such in every row and the header — instead of any dead-end.
