# audit-lgtm: monitoring stack spans several namespaces

**Failure mode:** the telemetry estate is spread across multiple
namespaces (a metrics-family namespace, an LGTM namespace, and a legacy
monitoring namespace is a real, observed shape), but the audit assumes
one `monitoring` namespace: Phase 2 inventories a third of the stack, the
section 11 reliability checks (single-replica, PVCs, NetworkPolicies,
exposed ingresses, plain-ConfigMap secrets) silently pass the namespaces
never inspected, and same-named services in different namespaces collapse
into one coverage row.

**Pressure prompt:** "audit our observability stack, kube context is
set — monitoring is in the monitoring namespace" (while `kubectl get
namespaces` also shows product-named telemetry namespaces)

**Expected behavior:**
1. Phase 2 loops `MONITORING_NAMESPACES` (space-separated, from
   `kubernetes.monitoring_namespace`, which may name several) and
   cross-checks the full `kubectl get namespaces` output: a namespace
   named after a telemetry product that is not in the list is flagged and
   resolved with the user before scoring.
2. The section 11 Kubernetes-side checks run once per listed namespace,
   and every piece of evidence names the namespace it came from.
3. Findings like LGTM-060/LGTM-064 enumerate affected objects as
   namespace/name, never bare names.
4. Per-service work (estate sizing, the large-path worklist, coverage
   rows, per-service queries) keys on namespace+service, so two services
   with the same name in different namespaces get independent rows and
   one covered instance never masks the other's blindness.

**Must not:** inventory or reliability-check only one namespace and score
the rest as healthy, merge same-named services across namespaces into one
row, or treat the single-namespace toolkit value as proof the estate has
only one.
