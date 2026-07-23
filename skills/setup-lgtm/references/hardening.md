# Hardening Fix Cookbook

Payloads and rollbacks for the retention, HA, exposure, NetworkPolicy, PDB, and label sections of [setup-lgtm](../SKILL.md). Every block is applied only through the change protocol: announce, confirm, execute, verify, record.

Every command block below redeclares the variables it uses, each with the `toolkit.yaml` key it resolves from, so it runs correctly pasted alone into a fresh shell. No block depends on an earlier block having run.

## Retention per backend

All durations are examples; pick values that match your compliance and cost targets. Apply through the owner (Helm values, operator CR, or flags), then verify with the read shown.

| Backend | Where the setting lives | Verify after apply |
| --- | --- | --- |
| Prometheus (kube-prometheus-stack) | values: `prometheus.prometheusSpec.retention: 30d` (optionally `retentionSize`) | `curl -fsS --max-time 10 "${METRICS_URL}/api/v1/status/flags" \| jq -r '.data["storage.tsdb.retention.time"]'` |
| Prometheus (raw) | `--storage.tsdb.retention.time=30d` container arg | same flags read |
| VictoriaMetrics single | `-retentionPeriod=30d` extraArg (VMSingle CR: `spec.retentionPeriod`) | `curl -fsS --max-time 10 "${METRICS_URL}/flags" \| grep -i retentionPeriod` |
| VictoriaMetrics cluster | `-retentionPeriod` on vmstorage (VMCluster CR: `spec.retentionPeriod`) | same `/flags` read against a vmstorage or via vmselect |
| Mimir | `limits.compactor_blocks_retention_period` in the Mimir config | `curl -fsS --max-time 10 "${METRICS_URL}/config" \| grep -i compactor_blocks_retention` |
| Loki | `limits_config.retention_period` plus `compactor.retention_enabled: true` | `curl -fsS --max-time 10 "${LOKI_URL}/config" \| grep -iA1 'retention_period\|retention_enabled'` |
| Tempo | `compactor.compaction.block_retention` | `curl -fsS --max-time 10 "${TEMPO_URL}/status/config" \| grep -i block_retention` |

Notes:

- Loki retention does nothing without the compactor running with `retention_enabled: true`; verify the compactor pod exists and its logs show retention cycles.
- Reducing retention is destructive. The compactor or head block cleanup can delete data within minutes of restart. Announce reductions as standalone changes with the loss stated.
- Rollback: restore the previous value through the same path and re-run the verify read. Data already deleted does not return.

## HA per component

Replica counts are examples, tune to your environment. Check node capacity and storage class before doubling stateful replicas.

**Alertmanager** (safe first HA step, no query-side changes needed):

```yaml
# ha-am.yaml -- kube-prometheus-stack style values override
alertmanager:
  alertmanagerSpec:
    replicas: 2          # example, tune to your environment
```

Verify: `curl -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" | jq -r '.cluster.status, (.cluster.peers | length)'` expecting `ready` and `2`. Also confirm the replicas landed on different nodes: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pods -l app.kubernetes.io/name=alertmanager -o wide`.

**Prometheus:** two replicas scrape independently; queries then see duplicate series unless deduplicated.

```yaml
prometheus:
  prometheusSpec:
    replicas: 2                                # example, tune to your environment
    replicaExternalLabelName: prometheus_replica
```

Only do this when your query layer deduplicates (Thanos or Grafana-side handling). Without dedup, dashboards double every value; that is a worse state than single-replica. If you cannot deduplicate yet, record HA as pending instead.

**VictoriaMetrics cluster:** set `replicationFactor: 2` (VMCluster `spec.replicationFactor`) with at least that many vmstorage nodes; disk use multiplies by the factor. Verify vmstorage pod count and `curl -fsS --max-time 10 "${METRICS_URL}/flags" | grep -i replicationFactor`.

**Loki / Tempo:** move from single-binary to a replicated deployment mode with object storage; that is a migration, not a values flip. Announce it as its own project and record the finding as pending with an owner if it cannot be done in this run.

Rollback for all: restore previous replica values through the owner, verify with the same reads. Scale-down of stateful components leaves orphan PVCs; announce whether they are kept or deleted.

## Lock down exposure

Options, least invasive first. Back up every object before changing it: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress <name> -o yaml > "${BACKUP_DIR}/ingress-<name>.yaml"`.

1. **Delete an ingress nobody should have** (observability APIs rarely need public hosts; internal users can port-forward or use Grafana):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
INGRESS_NAME="alertmanager-public"   # from the exposure enumeration in SKILL.md
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete ingress "$INGRESS_NAME"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress "$INGRESS_NAME" 2>&1 | tail -1
```

Expected: `NotFound`. Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml"`.

2. **Convert a LoadBalancer/NodePort Service to ClusterIP:**

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
BACKUP_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
SVC="victoriametrics"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc "$SVC" -o yaml > "${BACKUP_DIR}/svc-${SVC}.yaml"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" patch svc "$SVC" -p '{"spec":{"type":"ClusterIP"}}'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc "$SVC" -o jsonpath='{.spec.type}{"\n"}'
```

Expected: `ClusterIP`. If Helm or GitOps owns the Service, make the same change in values or Git instead. Rollback: apply the backup.

3. **Keep the host but add auth** when your team genuinely needs external access: an authenticating reverse proxy or your ingress controller's auth annotations, with TLS. The exact mechanism depends on your ingress controller; announce the chosen mechanism and verify by repeating the external probe from SKILL.md and getting `401` or `403` without credentials.

Always finish with the external probe: `curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 "https://${INGRESS_HOST}/"` returning `401`, `403`, `404`, or a timeout.

## NetworkPolicies

Apply order: allow policies first, verify, then default-deny. Selector labels below are examples; read the real labels off your pods first (`kubectl get pods -n "$MON_NS" --show-labels`).

```yaml
# np-allow-monitoring.yaml -- example, adjust selectors and ports to your stack
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-paths
  namespace: monitoring
spec:
  podSelector: {}                # every pod in the monitoring namespace
  policyTypes: ["Ingress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
    - from:
        - namespaceSelector: {}  # scrape/push from workload namespaces
      ports:
        - port: 9090             # metrics backend; add 3100 (Loki), 4317/4318 (OTLP), 9093 (Alertmanager) as used
          protocol: TCP
---
# np-default-deny.yaml -- apply only after the allow policy is verified
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
```

Apply and verify:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"                # kubernetes.context
METRICS_URL="https://prometheus.example.com"    # prometheus.url (or victoriametrics.url / mimir.url)
kubectl --context "$KUBE_CONTEXT" apply -f np-allow-monitoring.yaml
# Verify scraping and ingestion still work before the deny:
curl -fsS --max-time 10 "${METRICS_URL}/api/v1/targets" | jq -r '.data.activeTargets | length'
kubectl --context "$KUBE_CONTEXT" apply -f np-default-deny.yaml
```

Expected: the active-target count matches the pre-change count. Then prove the deny works with a probe from a namespace that should not have access (this creates a temporary pod; it is part of the announced change):

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
kubectl --context "$KUBE_CONTEXT" -n default run np-probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null -w '%{http_code}\n' --max-time 5 "http://prometheus.monitoring.svc:9090/-/ready"
```

Expected after default-deny: timeout (exit 28), unless port 9090 is intentionally allowed. Re-check targets and Alertmanager delivery afterward; egress to receivers must keep working (the policies above restrict ingress only).

If your CNI does not enforce NetworkPolicy, these objects apply cleanly and do nothing. Confirm enforcement with the probe, not with `kubectl get`.

Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete networkpolicy default-deny-ingress allow-monitoring-paths` (deny first).

## PodDisruptionBudgets

Only for components with 2 or more replicas.

```yaml
# pdb-alertmanager.yaml -- example, adjust selector to your pod labels
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: alertmanager
  namespace: monitoring
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
```

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" apply -f pdb-alertmanager.yaml
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb alertmanager
```

Expected: `ALLOWED DISRUPTIONS` is 1 or more. `0` means the budget cannot be met and node drains will hang; fix replicas or remove the PDB. Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb alertmanager`.

## Service label cookbook

Goal: one canonical `service` label value per service, derived from the same pod label in every signal. `app.kubernetes.io/name` is the usual source; pick one and use it everywhere.

**Metrics (Prometheus/vmagent kubernetes_sd relabel):**

```yaml
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
    target_label: service
```

With the Prometheus Operator, the equivalent lives in ServiceMonitor/PodMonitor `relabelings`; with vmagent, in VMServiceScrape/VMPodScrape or scrape config.

**Logs (Promtail):** the same `relabel_configs` block inside `scrape_configs`. **Logs (Alloy):** a `discovery.relabel` rule with `source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]` and `target_label = "service"`. **Logs (Fluent Bit):** enrich via the `kubernetes` filter and lift the label to a stream label matching the same value.

**Traces (OTel Collector k8sattributes processor):**

```yaml
processors:
  k8sattributes:
    extract:
      labels:
        - tag_name: service
          key: app.kubernetes.io/name
          from: pod
```

`service.name` set inside application SDKs overrides collector-derived values; when SDK values diverge, the fix is in the application repo. Record it as pending with the owning team named; do not fight the SDK from the collector.

**Verification per signal** (metrics and Loki parity commands are in SKILL.md):

- VictoriaLogs: `curl -fsS --max-time 10 "${LOKI_URL}/select/logsql/field_values?field=service" | jq -r '.values[].value' | sort`
- Tempo: `curl -fsS --max-time 10 "${TEMPO_URL}/api/search/tag/service.name/values" | jq -r '.tagValues[]' | sort`
- Compare each list against the metrics list with `comm -3`; empty output means aligned.

Renamed labels start new series and orphan old queries. In the same announced change, update alert `expr`s and dashboard queries that used the old name, and note the cutover time so historical queries are read with the old label.
