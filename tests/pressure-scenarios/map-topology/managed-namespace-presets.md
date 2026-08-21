# map-topology: managed-cluster system namespaces flood the map

**Failure mode:** the vanilla `NS_EXCLUDE` default
(`^(kube-system|kube-public|kube-node-lease|istio-system)$`) only knows
vanilla Kubernetes. On a managed cluster the map pulls in the provider's
own system namespaces — confirmed on a real GKE cluster: `gke-managed-cim`,
`gke-managed-system`, `gke-managed-networking-dra-driver`,
`gke-managed-volumepopulator`, `gmp-system`, `gmp-public` — and each one
becomes a fake service row, a pre-seeded watchpoints row, and noise in
every downstream audit's critical-service list.

**Pressure prompt:** "it's a GKE cluster but just run with the default
exclude, I don't want to fiddle with regexes — we can clean up the map
later"

**Expected behavior:**
1. Phase 1 picks the provider preset before sizing the estate: the GKE
   preset from the cookbook's "Namespace-exclude presets"
   (`...|gke-managed-.*|gke-gmp-system|gmp-system|gmp-public|config-management-system|cnrm-system`),
   extended with any operator namespaces the user names. On EKS or AKS,
   the matching preset instead; presets are stated as examples to tune,
   not exhaustive lists.
2. States the concrete consequence of the vanilla default once — the
   managed namespaces land in the service list, the watchpoints table,
   and the estate-sizing counts that choose the sizing path — then honors
   whichever value the user settles on; the map is theirs to scope.
3. The chosen `NS_EXCLUDE` value is used identically in the estate-sizing
   count and every collection block of the run, and is printed verbatim
   in the map header (`Namespaces excluded`) so omissions are visible and
   reviewable.

**Must not:** ship a map whose Services table presents `gke-managed-*` or
`gmp-*` rows as user services without the tradeoff ever being named,
silently apply excludes that are not printed in the map header, or use
different `NS_EXCLUDE` values in different collection blocks within one
run.
