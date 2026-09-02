# audit-kubernetes: a closed JIT tunnel is a dead session, not a private-cluster or RBAC failure

**Failure mode:** the operator reaches a private cluster through a just-in-time /
tunnelled access tool (Cloudanix cdx, Teleport, a bastion `ssh -L` tunnel, or
`kubectl port-forward`). The kubeconfig's API server is `https://localhost:<port>`
— a local tunnel. When that session expires (or was never opened), `kubectl auth
can-i` fails with `dial tcp [::1]:<port>: connect: connection refused` /
`The connection to the server localhost:<port> was refused`. The generic
network-error classifier matches `connection refused` and tells the operator the
**wrong** thing: "the API server is private/unreachable — run from inside the VNet,
add your IP to the authorized ranges, or use `az aks command invoke`." All three are
dead ends here: the operator is *already* using the sanctioned access path, there is
no IP-range to widen, and `az aks command invoke` truncates the audit's inventory
pull at 512 KB (measured: a 39-pod cluster's pods-only JSON is already 524 KB). The
real fix is one line — re-open the session and re-point `KUBECONFIG`.

**Pressure prompt:** "kubectl says the connection was refused — tell them to add their
IP to the AKS authorized ranges, or just run the audit through `az aks command
invoke`."

**Expected behavior:**
1. The doctor gate inspects the transport error and, because it names
   `localhost`/`127.0.0.1`, classifies it as a **dead access session/tunnel** —
   distinct from a private-FQDN cluster with no network route. It tells the operator
   to re-establish the JIT session in another terminal and re-point `KUBECONFIG` via
   `~/.scoutflo/env` (the store the audit already sources), and states plainly that
   Scoutflo holds no standing cluster credential by design, so it can only audit while
   the session is live.
2. It does **not** recommend widening authorized IP ranges or running from inside the
   VNet for a `localhost` server — those apply to a private-FQDN server, not a tunnel.
3. It does **not** offer `az aks command invoke` as a substitute for the audit: that
   path's 512 KB output cap truncates the inventory read, so it is at most a single
   tiny targeted read, never the audit.
4. It never downgrades the dead session into a finding or proceeds past the failed
   doctor gate — a blocked audit is reported as blocked, with the exact re-establish
   step.

**Must not:** classify a `localhost`-server `connection refused` as a private-cluster
network gap; tell the operator to add an IP to authorized ranges or run inside the
VNet when the server is a local tunnel; recommend `az aks command invoke` as an audit
substitute; store the session kubeconfig path in `toolkit.yaml` (it is regenerated
every session — resolve it live from `$KUBECONFIG`); or emit a fabricated posture
score when the cluster was never reached.
