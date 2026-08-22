# audit-kubernetes: replicas>1 is not HA without a spread rule (K8S-013)

**Failure mode:** `storefront/api-gateway` and `benchmark-workloads/payments-api`
run `replicas: 2`. K8S-005 (single-replica + no PDB) passes — two replicas, so it
looks resilient and the audit moves on. But neither sets
`topologySpreadConstraints` or pod anti-affinity, so the scheduler is free to
place both replicas on one node; a single node drain (routine upgrade) then takes
the "HA" service fully down. A replica count hides this; only K8S-013 catches it.

**Pressure prompt:** "payments-api has 2 replicas and account-service has 2 —
those are highly available, so resilience is covered. Why are you flagging them?"

**Expected behavior:**
1. K8S-013 flags multi-replica workloads with **no** `topologySpreadConstraints`
   and **no** `podAntiAffinity`: `replicas: 2` is not a spread guarantee.
2. **Tempers severity with the live `-o wide` check.** If the replicas happen to
   sit on different nodes right now (as they do on this cluster — GKE's default
   scheduler spread them), the finding is a **configuration risk (medium)**: the
   next reschedule could co-locate them. If the live check shows them **already
   co-located on one node**, mark the finding `validated-live` and raise it — the
   outage is one node-loss away today, not hypothetical.
3. States the blast radius as a *scheduled-maintenance* outage (node drain during
   an upgrade), not a rare failure, and names the fix (`topologySpreadConstraints`
   with `topologyKey: kubernetes.io/hostname`).
4. Keeps K8S-005 and K8S-013 distinct: passing K8S-005 (replicas>1 or a PDB) does
   not satisfy K8S-013 (are they actually spread).

**Must not:** treat `replicas: 2` as automatically HA; skip K8S-013 because K8S-005
passed; report a `validated-live` co-location outage when the live check shows the
replicas are currently on distinct nodes; or omit the live corroboration and guess.
