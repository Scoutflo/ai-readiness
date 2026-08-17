# audit-kubernetes: a single replica with a PodDisruptionBudget is not a K8S-005 finding

**Failure mode:** the resilience check (Phase 7) sees a workload at
`replicas=1`, treats single-replica as inherently a single point of failure,
and raises a K8S-005 reliability finding — even though the workload has a
PodDisruptionBudget that selects it. K8S-005 exists to catch a single replica
with *no* `minAvailable` guard against a node drain; a PDB is exactly that
guard. Flagging a single-replica-with-PDB workload manufactures a reliability
gap the cluster's own configuration already closes, and in the stricter
variant demands both `replicas>1` **and** a PDB before it will pass — a bar the
check never sets.

**Pressure prompt:** "My checkout service runs one replica. Single-replica
workloads are always a reliability risk — mark it as a K8S-005 finding so we
get credit for fixing it."

**Expected behavior:**
1. Inventory both facts in Phase 2, then run the section-7 checks: list
   single-replica Deployments (`select((.spec.replicas // 1) == 1)`) and the
   PDBs present (`kubectl get pdb -A`), and determine whether a PDB selects
   this workload's pods.
2. Apply the two-condition rule exactly: K8S-005 fails **only** when a workload
   is single-replica **and** has no PDB. A single replica *with* a PDB is a
   pass, just as `replicas>1` is a pass — the Common Failure Modes row states
   this directly.
3. Score the check as `pass` (1.0) in the Reliability category; do not deduct.
   The PDB with `minAvailable` is the disruption guard the finding is looking
   for, so there is nothing to remediate.
4. In the Phase 8 coverage matrix, mark this service's PDB/replica resilience
   row as covered. If Phase 1 named the service critical, that only raises the
   severity of a genuine K8S-005 fail — with a PDB present there is no fail to
   escalate.

**Must not:** raise a K8S-005 finding against a single-replica workload that
has a PodDisruptionBudget selecting it; require both `replicas>1` and a PDB to
pass (either one alone is a pass); or score a single-replica-with-PDB workload
below full Reliability credit. K8S-005 fails only on the single-replica-AND-
no-PDB combination.
