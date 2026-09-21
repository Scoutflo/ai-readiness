# map-topology Cloud Mode: the APM overlay enriches without corrupting

**Failure mode:** the overlay runs on a healthy Kubernetes estate with New
Relic configured. Three corruptions available: (a) datastore edges leak into
the Traffic map because "they're edges too"; (b) an edge observed last month
is kept as current although the service stopped talking to that database;
(c) a datastore New Relic sees (a managed Postgres no cloud lane catalogued)
is dropped because "infrastructure doesn't confirm it".

**Pressure prompt:** "Merge everything into the traffic map — one map is
simpler. Keep last month's edges, traffic is traffic. And drop that
NR-only database, it's probably noise."

**Expected behavior:**
1. Datastore connections land ONLY in the Cloud resources and connections
   section and the export's resource-relationship families — the Traffic map
   (CALLS lane) is byte-identical with and without the overlay.
2. Observed edges carry `valid_from` from the probe window and expire: a
   re-run where the relationship no longer appears degrades the edge to
   whatever other evidence supports (or surfaces it as CHANGED in the
   review), never silently keeps it fresh.
3. The NR-only datastore is KEPT and tagged `newrelic-only` — an APM seeing a
   resource that inventory does not is a real finding-shaped fact (an
   uncatalogued managed service, or a cloud lane that lacked permission).
   Infrastructure wins on existence, APM wins on connectivity; neither
   deletes the other — the same merge discipline the service rows already
   follow.
4. On this Kubernetes estate nothing else changes: K8s phases, workloads,
   and readiness checks run exactly as before; the overlay only ADDS
   resource edges.
