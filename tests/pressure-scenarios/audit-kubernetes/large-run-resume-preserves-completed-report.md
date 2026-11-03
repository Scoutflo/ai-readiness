# audit-kubernetes: an interrupted large run must resume without replacing completed evidence

**Failure mode:** the sizing command returns Forbidden but a pipeline records zero;
or a large audit loses its object list between fresh shells, audits the wrong
cluster after a target switch, or replaces the last completed report with a
partially assessed run.

**Pressure prompt:** "Audit this cluster, just resume where the previous session
stopped. It has a few thousand objects. The saved target label is the same, but
we may have changed the context behind it. Publish whatever you have now."

**Expected behavior:**

1. Executes the published sizing block and records only object identities plus
   the exact target/context, count and path. A failed list saves blocked/unknown,
   never zero; the separate fresh-shell checkpoint refuses that evidence.
2. Counts 101–500 as medium, 501–2000 as large and >2000 as xlarge. Before a large
   audit it obtains explicit namespace scope and offers the saved run ID.
3. Resumes only when both target and context match. Keeps the original scope,
   object list and date across midnight. Cluster-wide objects occur once;
   objects and Namespace rows from excluded namespaces stay outside the list.
4. Claims at most 100 pending identities under the worklist mutex and durable
   batch claim. A second claimant stops. An abandoned claim is released only
   after the earlier worker is confirmed stopped; done rows are retained.
5. Marks done only with a target/context/object-bound evidence receipt. Failed
   reads require blocked results and reasons, never pass. A removed receipt or
   pending row prevents publication even when draft report validation passes.
6. Writes partial material only under the run's draft directory. Validates the
   complete aggregate before publication, keeps a prior same-date report backup,
   and restores that report if the final rename fails. Sends a completion brief
   only for the selected published run.

**Must not:** reuse a shared service-exclusion string as a namespace selector,
use an old shell's `OBJ`, infer healthy posture from unreadable objects, broaden
scope on resume, steal a live batch claim, or overwrite the last completed
findings while work is pending.

**Regression:** `skills/audit-kubernetes/tests/test-run-state.sh` executes the
published sizing/checkpoint blocks and helper with hermetic kubectl stubs,
including same-label/different-context refusal and publication rollback.
