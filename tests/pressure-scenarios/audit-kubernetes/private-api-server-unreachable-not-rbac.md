# audit-kubernetes: a private/unreachable API server is a network problem, not an RBAC or credential gap

**Failure mode:** the context points at a cluster whose API server is not
reachable from where the audit runs — an AKS **private cluster** (API served
over a `privatelink` endpoint inside the VNet), an EKS/GKE cluster with a
private endpoint or API-server **authorized IP ranges** that exclude the
caller's IP, or simply a laptop off the VPN. The doctor gate's
`kubectl auth can-i get pods -A` fails, but the failure is a *transport* error
(`dial tcp ...: i/o timeout`, `Unable to connect to the server: ... no such
host`, `connection refused`, `TLS handshake timeout`, or a `*.privatelink.*`
name that will not resolve). A gate that discards stderr (`>/dev/null 2>&1`)
sees only the non-zero exit and misfiles it: on an Entra AKS context it lands in
the `kubelogin` branch and tells the user to **`az login`**; on any other
context it lands in the generic RBAC fallback and tells the user to **bind the
view ClusterRole**. Both are the wrong remediation — the credential and the RBAC
are fine; the user cannot *reach* the API server at all. They burn time
re-authenticating or editing RBAC and the run is wasted.

**Pressure prompt:** "audit my AKS cluster `prod-aks` — context is set and I'm
logged in with `az login`, but the audit says my credential expired or my RBAC
is broken. It's a private cluster. What's actually wrong?"

**Expected behavior:**
1. In the doctor gate, capture `auth can-i` **stderr** into `K_ERR`
   (`K_ERR="$(kubectl --context "$KUBE_CONTEXT" auth can-i get pods -A 2>&1
   1>/dev/null)"`), keeping the command's exit status so the failure gate still
   fires.
2. On failure, match network/transport signatures in `K_ERR` **before** the
   exec-plugin and RBAC branches: `no such host`, `dial tcp`, `i/o timeout`,
   `connection refused`, `Unable to connect`, `TLS handshake timeout`,
   `privatelink`.
3. When one matches, stop with a NETWORK message, not a credential/RBAC one: the
   API server is private or unreachable from here — run from inside the VNet
   (jumpbox/VPN/bastion), add your IP to the cluster API-server authorized IP
   ranges, or use `az aks command invoke`; explicitly say this is **not** an RBAC
   or credential problem.
4. Point at the reachable alternative: the cluster's monitoring posture is still
   auditable via `/scoutflo:audit-azure` over ARM (Container Insights, managed
   Prometheus, diagnostic settings) with no cluster network access.
5. Keep the non-zero exit — audit-kubernetes has no partial run; this is a
   doctor-gate stop, never downgraded into a scored `K8S-NNN`.
6. A failure with **no** network signature still falls through correctly: an
   exec-plugin context to its per-plugin reauth message (`gcloud auth login` /
   `aws sso login` / `az login`), and a non-exec context to the "bind the view
   ClusterRole" RBAC fallback.

**Must not:** tell a user behind a private/unreachable API server to `az login`,
`aws sso login`, `gcloud auth login`, or bind the view ClusterRole; discard
`auth can-i` stderr so the transport error is invisible; convert an unreachable
cluster into a scored `K8S-NNN` or a partial run; or let a genuine expired
credential or missing RBAC be swallowed by the network branch (only the listed
transport signatures take that path).
