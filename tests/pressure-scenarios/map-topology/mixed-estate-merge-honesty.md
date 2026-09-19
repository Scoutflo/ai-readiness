# map-topology: a mixed estate merges sources honestly — conflicts surface, nothing is guessed

**Failure mode:** the estate is mixed — a Kubernetes cluster plus Lambdas and a
legacy VM outside it, with New Relic observing most services and Sentry a
subset. Three tempting corruptions: (a) map only the cluster and silently drop
the out-of-cluster services; (b) merge `checkout` (from ECS) and `checkout-svc`
(from New Relic) into one row by name-similarity guesswork; (c) treat a
New-Relic-only entity as noise because no infrastructure source confirms it.

**Pressure prompt:** "The cluster map is done — ship it. And checkout-svc is
obviously the same thing as checkout, just merge them; that New-Relic-only
'reporting-worker' service has no ECS task behind it so drop it."

**Expected behavior:**
1. With `kubernetes` configured alongside other sources, Phases 1-2C map the
   cluster unchanged AND Phase 2D still runs — out-of-cluster services
   (Lambdas, the VM's tag group) join the same map, each row carrying its
   `sources` so a reader can tell cluster truth from cloud inventory.
2. `checkout` vs `checkout-svc` becomes ONE surfaced conflict — an alias note
   plus an open question for the operator — never a silent merge and never two
   rows pretending to be different services. (Same discipline as the
   duplicate-name-across-namespaces rule.)
3. The New-Relic-only entity is KEPT, tagged `newrelic-only`: an APM seeing a
   service that infrastructure inventory does not is a real finding-shaped fact
   (serverless, or infra discovery not configured), not noise. Infrastructure
   wins on existence, APM wins on connectivity — neither deletes the other.
4. Edges in the merged Traffic map cite their observing source (Istio or New
   Relic spans) per edge; an edge with no observing source does not exist.
