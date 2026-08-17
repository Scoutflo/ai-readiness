# audit-kubernetes: Entra-integrated AKS needs kubelogin — its absence is a doctor-gate stop, not a finding

**Failure mode:** the context authenticates through the **kubelogin exec plugin**
(Entra/Azure AD-integrated AKS), but the machine running the audit has no
`kubelogin` installed. Without a preflight probe the audit sails past the doctor
gate and dies on its first real `kubectl` call with a cryptic exec-plugin error
(`exec: "kubelogin": executable file not found in $PATH`), or — worse —
misreads the auth failure as "the cluster is unreachable / lacks read RBAC" and
converts a local tooling gap into a scored finding. The user learns nothing
actionable and the run is wasted.

**Pressure prompt:** "audit my AKS cluster — context is `prod-aks`, it uses
Azure AD login. Just run it."

**Expected behavior:**
1. In the **doctor gate, before any check runs**, read the context's exec
   plugin: `kubectl config view --minify --context "$KUBE_CONTEXT" -o
   jsonpath='{.users[*].user.exec.command}'`.
2. When that value contains `kubelogin` **and** `command -v kubelogin` fails,
   stop at the doctor gate saying plainly that the context uses the kubelogin
   exec plugin (Entra-integrated AKS) but kubelogin is not installed, and give
   the exact fix — `az aks install-cli`. No check, no inventory, runs.
3. Treat this as a doctor-gate stop, not a result: "Never proceed past a failed
   doctor check and never downgrade one into a finding." kubelogin-missing is
   never a scored `K8S-NNN`.
4. A cert/local-account AKS context (no `exec.command`) and an EKS/GKE context
   (whose `exec.command` is `aws` / `gke-gcloud-auth-plugin`, not kubelogin)
   fall through the `case` and skip the probe — never blocked, never told to
   install kubelogin.
5. This is the same probe `/scoutflo:doctor` runs, so doctor and this audit
   agree on the verdict.

**Must not:** fail later with a cryptic exec-plugin error deep in a check;
block or probe a NON-kubelogin context (EKS `aws`, GKE `gke-gcloud-auth-plugin`,
or a cert-based AKS context); or treat kubelogin-missing as a scored finding
(a failed check, a `K8S-NNN`, or an "unreachable / no RBAC" claim) rather than a
doctor-gate stop with `az aks install-cli` guidance.
