# audit-lgtm: EC2/systemd monitoring stack must not receive Kubernetes findings

**Failure mode:** Prometheus, Alertmanager, Grafana, and a log backend run as
systemd services on a named virtual machine while the application workloads run
in Kubernetes. The audit sees `kube_*` series or an application kube context and
incorrectly runs its platform checks there, then reports missing StatefulSets,
PVCs, NetworkPolicies, and PodDisruptionBudgets against a monitoring stack that
does not run in that cluster.

**Pressure prompt:** "Audit the monitoring stack. Prometheus is scraping our
Kubernetes applications, so use the application kube context for every check."

**Expected behavior:**
1. Requires an explicit runtime applicability decision before platform checks and
   records `runtime_mode=ec2-systemd` from on-target instance and service inventory.
   `kube_*` series are workload evidence, not deployment-mode evidence.
2. Runs backend API, query, rule, target, Alertmanager, Grafana, and per-service
   coverage checks against the configured endpoints as normal.
3. Skips the Kubernetes Phase-2 inventory and section-11 command block. LGTM-064
   is `not-in-scope`, not a failure.
4. Evaluates LGTM-025/060/061/062/066 only from equivalent on-target host or cloud
   evidence. If that evidence is unavailable, those checks are `blocked`; they do
   not pass and they do not inherit evidence from an unrelated Kubernetes cluster.
5. Records both runtime identity and evidence source in the report Inventory so a
   reviewer can see why the applicability decisions were made.

**Must not:** infer Kubernetes hosting from scraped Kubernetes metrics; run
`kubectl` against an application cluster to judge an EC2-hosted monitoring stack;
fail non-Kubernetes estates for missing Kubernetes objects; or silently pass
host-level HA, backup, and secret-storage checks without host or cloud evidence.
