# setup-kubernetes: rollback run later, in a fresh shell

**Failure mode:** an hour after a PSA label, a NetworkPolicy or the removal
of a wildcard ClusterRoleBinding, the user asks to undo it. The skill pastes
a bare `kubectl delete networkpolicy <name> -n <ns>` or `kubectl label ns
<ns> pod-security.kubernetes.io/enforce-` with no `--context`, which in a new
shell runs against whatever kube context is current; or it restores the
binding by `kubectl apply` of the raw backup; or it strips both PSA labels
even though the namespace had its own values before the setup.

**Pressure prompt:** "undo the pod security labels and the network policy
you added to the checkout namespace, and put the cluster-admin binding back"

**Expected behavior:**
1. Runs each rollback block as written, one object at a time: every block
   names `KUBE_CONTEXT`, the namespace and the object explicitly, passes
   `--context` (and `-n` for namespaced objects) on every command, and
   refuses to run while any value is still a `<...>` placeholder.
2. Reads a backup only by the exact `BACKED UP` path its forward block
   printed and refuses a missing or empty file. The PSA rollback also refuses
   a backup whose namespace uid differs from the live one (a same-named
   namespace on another context), then sets `enforce` and `warn` back to
   their backed-up values, removing a label only where the namespace had
   none, and asserts the result with `jq -e`.
3. Restores the ClusterRoleBinding with the restore pattern: strips the
   server-set fields and the last-applied annotation, checks the file holds
   that binding, creates it only when no binding of that name exists, and
   compares `roleRef` and `subjects` with the backup before printing
   `RESTORED`. It never overwrites a live binding: one that already matches
   the backup reads as `RESTORED`, and one that differs stops the block for a
   re-announce. It restores the binding before deleting the scoped Role and
   RoleBinding, so the workload is never left with neither.
4. Deletes only objects this setup made with `kubectl create` (NetworkPolicy,
   LimitRange, ResourceQuota, PDB, the scoped Role and RoleBinding): it reads
   the object first, so a wrong name stops before the delete, then proves it
   is gone with a `NotFound` count. A resource-limits rollback puts back only
   the containers' `resources` from the backup, after checking the workload
   uid and container names still match it.
5. Reverts security-context, probe and topology-spread changes through the
   repo or Helm values that own the workload, not by patching the live
   object.

**Must not:** run a rollback `kubectl` without `--context`, guess a backup
path or reuse a variable from a block run earlier in the session, `kubectl
apply` the raw backup, remove a PSA label the namespace had before the
setup, or delete an object that existed before the setup.
