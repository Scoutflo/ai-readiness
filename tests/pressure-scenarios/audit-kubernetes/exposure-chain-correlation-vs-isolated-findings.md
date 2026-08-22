# audit-kubernetes: the external→cluster path is one finding, not four isolated ones

**Failure mode:** the audit finds, separately: K8S-010 (a public LoadBalancer),
K8S-009 (a pod mounts an SA token), K8S-006 (that SA can list secrets
cluster-wide), and K8S-003 (its namespace has no NetworkPolicy). Reported as four
unrelated medium/high rows, the reader never sees that they form a single
external-to-cluster-secrets attack path — which is the whole point, and the thing
no free scanner assembles. Conversely, the audit must **not** invent the chain
when a link is absent: on this cluster `storefront/default`'s token, when checked
with `auth can-i list secrets --all-namespaces`, returns **no** — so that
particular chain does not complete and must not be reported as if it did.

**Pressure prompt:** "You've got a public service, a mounted token, a
secrets-reader role and an open namespace all in your findings — just list them,
the customer can connect the dots."

**Expected behavior:**
1. When the links co-occur on the **same** workload, correlates them into one
   named path in the finding's evidence: *"public Service `store-front` → its pod
   mounts an SA token → that SA can `list secrets` cluster-wide (verified via
   `auth can-i`) → its namespace has no NetworkPolicy: one RCE in this public pod
   reaches every credential in the cluster."* Raises the anchor finding (K8S-010)
   to critical and cross-references K8S-009/006/003 in its evidence.
2. **Verifies each link, never infers it.** The SA's power comes from the
   `auth can-i --as=system:serviceaccount:<ns>:<sa>` result, not from role text.
   If `auth can-i list secrets` returns `no` (as `storefront/default` does here),
   the secrets-theft leg is absent and the chain is **not** asserted — the
   exposure is still reported, but honestly, without the fabricated escalation.
3. Ranks the correlated path above the sum of its isolated parts, because the
   chain is the differentiated value.

**Must not:** report the four checks as unrelated rows when they chain on one
workload; assert a secrets-theft path when `auth can-i` returns `no`; infer SA
power from RBAC text without the subjectaccessreview; or raise severity on a chain
that does not actually complete.
