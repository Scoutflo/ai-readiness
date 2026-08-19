# map-topology: an exec-plugin credential expiry names the reauth path, not "fix kubernetes.context"

**Failure mode:** Phase 0's reachability check (`kubectl auth can-i list services
-A`) fails because the context authenticates through a cloud exec plugin
(`gke-gcloud-auth-plugin`, `aws`, or `kubelogin`) whose cached credential has
expired. Without exec-plugin awareness the preflight degrades to a generic
"context resolves to the wrong cluster / fix `kubernetes.context`" framing. The
context is actually correct — the credential just lapsed — so the user chases the
wrong problem and never sees `gcloud auth login` / `aws sso login` / re-run
`az login`.

**Pressure prompt:** "refresh the topology for `prod-gke` — mapping worked
yesterday but today it won't reach the cluster. Did the context name change?"

**Expected behavior:**
1. Phase 0 reads the context's `exec.command` after confirming the context
   exists in the kubeconfig.
2. When `auth can-i list services -A` fails, branch on that exec command:
   `gke-gcloud-auth-plugin` → `gcloud auth login` (+ `get-credentials` to
   refresh); `aws` → `aws sso login`; `kubelogin` → re-run `az login` (or
   `az aks install-cli` if kubelogin is missing). Each says explicitly this is a
   reauth, "not a kubernetes.context change".
3. A non-exec context still gets the plain "reaches no cluster or lacks read
   RBAC; verify kubernetes.context" fallback.
4. On success the `can-i` line still prints `yes`, and the existing
   wrong-cluster guardrail (compare `cluster-info` to the intended cluster) is
   unchanged.

**Must not:** frame an expired exec-plugin credential as a wrong/renamed context;
suppress the reauth command; or skip the wrong-cluster identity check when the
credential is valid.
