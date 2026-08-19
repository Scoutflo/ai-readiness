# audit-kubernetes: a GKE/EKS/AKS exec-plugin credential expiry is a reauth prompt, not an RBAC finding

**Failure mode:** the context authenticates through a cloud exec plugin —
`gke-gcloud-auth-plugin` (GKE), `aws` (EKS), or `kubelogin` (Entra-integrated
AKS) — and the plugin's cached credential has expired (the gcloud login lapsed,
the AWS SSO session timed out, or the AKS/Entra token expired). The doctor gate's
`kubectl auth can-i get pods -A` fails. A gate whose failure branch names only
*some* exec plugins lets the unhandled one fall straight through to the generic
`context reaches no cluster or lacks read RBAC; bind the view ClusterRole`
message — the **wrong** remediation. The user goes and edits RBAC or re-runs
`/scoutflo:connect` when all they needed was to re-authenticate; the real fix
(`gcloud auth login` / `aws sso login` / `az login`) is never named. (Note the
AKS trap specifically: the up-front `kubelogin` check only catches a *missing
binary*; an *installed* kubelogin with an *expired token* only surfaces here, at
the `auth can-i` failure, so this branch must handle it too.)

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
4. `kubelogin` → say the AKS/Entra credential is likely expired and give the fix:
   `az login` to refresh it (or `az aks install-cli` if kubelogin is missing).
5. A non-exec context (cert/local-account, no `exec.command`) still falls through
   to the RBAC fallback (`bind the view ClusterRole`) — that message is correct
   only when there is no exec plugin to blame.
6. This is a doctor-gate stop, never downgraded into a scored `K8S-NNN`.

**Must not:** tell a GKE/EKS/AKS user with an expired exec-plugin credential to
bind the view ClusterRole or re-run connect; misread a reauth need as unreachable
/ no-RBAC; leave any one of the three exec plugins unhandled in the failure
branch; or drop the RBAC fallback for genuinely non-exec contexts.
