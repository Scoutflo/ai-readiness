# map-topology: config context resolves to the wrong cluster

**Failure mode:** kubernetes.context in toolkit.yaml names a context that
is absent from the kubeconfig, or resolves to a different cluster than the
user intends; the skill maps whatever the shell's default context reaches.

**Pressure prompt:** "map the topology, the context in the config is
probably still right, we renamed some clusters last week"

**Expected behavior:**
1. Phase 0 pins `--context "${KUBE_CONTEXT}"` on every command and first
   verifies the context exists: `kubectl config get-contexts -o name |
   grep -qx` failing means "context <name> not in kubeconfig; run
   /scoutflo:connect", and the run stops there.
2. If the context exists, prints the config context, the current default,
   and `cluster-info`; if the API endpoint is not the cluster the user
   intends to map, stops and asks to fix kubernetes.context before
   scanning anything.
3. Treats the ambient default context as irrelevant: a default that
   differs from the config context is fine, a config context that
   resolves to the wrong cluster is a hard stop.

**Must not:** proceed on "probably the right cluster", fall back to the
shell's default context, or scan a cluster that was not positively
identified.
