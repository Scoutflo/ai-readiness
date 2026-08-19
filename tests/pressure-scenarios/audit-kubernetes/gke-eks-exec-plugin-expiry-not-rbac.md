# audit-kubernetes: a GKE/EKS exec-plugin credential expiry is a reauth prompt, not an RBAC finding

**Failure mode:** the context authenticates through a cloud exec plugin —
`gke-gcloud-auth-plugin` (GKE) or `aws` (EKS) — and the plugin's cached
credential has expired (the gcloud login lapsed, or the AWS SSO session timed
out). The doctor gate's `kubectl auth can-i get pods -A` fails. A gate that only
special-cases `kubelogin` (Entra AKS) lets GKE/EKS fall straight through to the
generic `context reaches no cluster or lacks read RBAC; bind the view
ClusterRole` message — the **wrong** remediation. The user goes and edits RBAC or
re-runs `/scoutflo:connect` when all they needed was to re-authenticate; the real
fix (`gcloud auth login` / `aws sso login`) is never named.

**Pressure prompt:** "audit my GKE cluster `prod-gke` — I ran an audit fine last
week but now it says it can't reach the cluster. Is my RBAC broken?"

**Expected behavior:**
1. In the doctor gate, when `auth can-i` fails, branch on the context's
   `exec.command` **before** the generic RBAC message.
2. `gke-gcloud-auth-plugin` → say the credential is likely expired (not an RBAC
   gap) and give the fix: `gcloud auth login`, then
   `gcloud container clusters get-credentials <cluster>` to refresh the token.
3. `aws` → say the aws exec-plugin credential is likely expired and give the fix:
   `aws sso login` (or otherwise refresh AWS credentials).
4. A non-exec context (cert/local-account, no `exec.command`) still falls through
   to the RBAC fallback (`bind the view ClusterRole`) — that message is correct
   only when there is no exec plugin to blame.
5. This is a doctor-gate stop, never downgraded into a scored `K8S-NNN`.

**Must not:** tell a GKE/EKS user with an expired exec-plugin credential to bind
the view ClusterRole or re-run connect; misread a reauth need as unreachable /
no-RBAC; or drop the RBAC fallback for genuinely non-exec contexts.
