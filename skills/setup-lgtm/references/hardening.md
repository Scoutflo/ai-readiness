# Hardening Fix Cookbook

Payloads and rollbacks for the retention, HA, exposure, NetworkPolicy, PDB, and label sections of [setup-lgtm](../SKILL.md). Every block is applied only through the change protocol: announce, confirm, execute, verify, record.

Every command block below redeclares the variables it uses, each with the `toolkit.yaml` key it resolves from, so it runs correctly pasted alone into a fresh shell. No block depends on an earlier block having run.

## Retention per backend

All durations are examples; pick values that match your compliance and cost targets. Apply through the owner (Helm values, operator CR, or flags), then verify with the read shown.

| Backend | Where the setting lives | Read that verifies it (block below) |
| --- | --- | --- |
| Prometheus (kube-prometheus-stack) | values: `prometheus.prometheusSpec.retention: 30d` (optionally `retentionSize`) | `/api/v1/status/flags`, `storage.tsdb.retention.time` |
| Prometheus (raw) | `--storage.tsdb.retention.time=30d` container arg | same flags read |
| VictoriaMetrics single | `-retentionPeriod=30d` extraArg (VMSingle CR: `spec.retentionPeriod`) | `/flags`, `-retentionPeriod` |
| VictoriaMetrics cluster | `-retentionPeriod` on vmstorage (VMCluster CR: `spec.retentionPeriod`) | the same `/flags` read against a vmstorage address |
| Mimir | `limits.compactor_blocks_retention_period` in the Mimir config | `/config`, `compactor_blocks_retention_period` |
| Loki | `limits_config.retention_period` plus `compactor.retention_enabled: true` | `/config`, `retention_period` and `retention_enabled` |
| Tempo | `compactor.compaction.block_retention` | `/status/config`, `block_retention` |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
STORE="prometheus"                           # prometheus, victoriametrics, mimir, loki, or tempo: the store you changed
STORE_URL="https://prometheus.example.com"   # that store's url (for a VictoriaMetrics cluster, a vmstorage address)
WANT="30d"                                   # the announced retention as the store prints it (Tempo prints 720h0m0s); example
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
STORE_TOKEN="${PROM_TOKEN:-}"   # the variable that store's token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${STORE_TOKEN}"; [ -n "$STORE_TOKEN" ] || AUTH="Accept: application/json"
case "$STORE" in
  prometheus)      READ="/api/v1/status/flags"; KEY="storage.tsdb.retention.time" ;;
  victoriametrics) READ="/flags";               KEY="-retentionPeriod=" ;;
  mimir)           READ="/config";              KEY="compactor_blocks_retention_period:" ;;
  loki)            READ="/config";              KEY="retention_period:" ;;
  tempo)           READ="/status/config";       KEY="block_retention:" ;;
  *) echo "STORE must be prometheus, victoriametrics, mimir, loki, or tempo" >&2; exit 1 ;;
esac
BODY="$(curl -fsS --max-time 10 -H "$AUTH" "${STORE_URL}${READ}")" || { echo "${STORE_URL}${READ} unreachable or unauthorized" >&2; exit 1; }
if [ "$STORE" = prometheus ]; then
  GOT="$(printf '%s' "$BODY" | jq -r --arg k "$KEY" '.data[$k] // empty')"
else
  GOT="$(printf '%s\n' "$BODY" | grep -E "^ *${KEY}" | head -1 | sed -e "s/^ *${KEY}//" -e 's/["[:space:]]//g')"
fi
if [ "$STORE" = loki ]; then
  printf '%s\n' "$BODY" | grep -Eq '^ *retention_enabled: true' || { echo "loki compactor retention_enabled is not true: retention_period deletes nothing" >&2; exit 1; }
fi
echo "${STORE} retention: ${GOT:-not found}"
[ "$GOT" = "$WANT" ] || { echo "expected ${WANT}" >&2; exit 1; }
```

Expected: the store's retention line, then exit 0.

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

Verify with the clustering block in [SKILL.md](../SKILL.md#enable-ha), `WANT_REPLICAS="2"`: it asserts `ready` with that many peers and that the replicas landed on different nodes.

**Prometheus:** two replicas scrape independently; queries then see duplicate series unless deduplicated.

```yaml
prometheus:
  prometheusSpec:
    replicas: 2                                # example, tune to your environment
    replicaExternalLabelName: prometheus_replica
```

Only do this when your query layer deduplicates (Thanos or Grafana-side handling). Without dedup, dashboards double every value; that is a worse state than single-replica. If you cannot deduplicate yet, record HA as pending instead.

**VictoriaMetrics cluster:** set `replicationFactor: 2` (VMCluster `spec.replicationFactor`) with at least that many vmstorage nodes; disk use multiplies by the factor. Verify the flag and the vmstorage pod count:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"                        # kubernetes.context
MON_NS="monitoring"                                     # kubernetes.monitoring_namespace
METRICS_URL="https://vm.example.com"                    # victoriametrics.url
VMSTORAGE_SELECTOR="app.kubernetes.io/name=vmstorage"   # the vmstorage pod label; VM operator default, adjust to your chart
WANT_RF="2"                                             # the replicationFactor you announced; example, tune to your environment
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
MET_TOKEN="${VM_TOKEN:-}"   # the variable victoriametrics.token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${MET_TOKEN}"; [ -n "$MET_TOKEN" ] || AUTH="Accept: application/json"
FLAGS="$(curl -fsS --max-time 10 -H "$AUTH" "${METRICS_URL}/flags")" || { echo "flags unreachable or unauthorized at ${METRICS_URL}" >&2; exit 1; }
printf '%s\n' "$FLAGS" | grep -E '^-replicationFactor=' || true
printf '%s\n' "$FLAGS" | grep -Eq "^-replicationFactor=\"?${WANT_RF}\"?\$" || { echo "replicationFactor is not ${WANT_RF}" >&2; exit 1; }
PODS="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pods -l "$VMSTORAGE_SELECTOR" -o name | grep -c . || true)"
[ "$PODS" -ge "$WANT_RF" ] || { echo "${PODS} vmstorage pods for a replicationFactor of ${WANT_RF}" >&2; exit 1; }
echo "VERIFIED: replicationFactor ${WANT_RF} across ${PODS} vmstorage pods"
```

**Loki / Tempo:** move from single-binary to a replicated deployment mode with object storage; that is a migration, not a values flip. Announce it as its own project and record the finding as pending with an owner if it cannot be done in this run.

Rollback for all: restore previous replica values through the owner, verify with the same reads. Scale-down of stateful components leaves orphan PVCs; announce whether they are kept or deleted.

## Lock down exposure

Options, least invasive first. Back up every object before changing it:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
INGRESS_NAME="alertmanager-public"   # from the exposure enumeration in SKILL.md
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
[ ! -e "${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml" ] || { echo "${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml already holds the pre-change copy from an earlier change today; keep it and fold this edit into that change" >&2; exit 1; }
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress "$INGRESS_NAME" -o yaml > "${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml"
[ -s "${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml" ] && echo "BACKED UP: ${BACKUP_DIR}/ingress-${INGRESS_NAME}.yaml"
```

Expected: `BACKED UP` with the file path; note the date folder for the rollback.

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

Expected: `NotFound`. Rollback recreates the ingress from the backup, in its own fresh shell:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
KIND="ingress"
NAME="alertmanager-public"         # the ingress deleted above
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the backup step (its setup-<date>/backups folder)
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-${BACKUP_DATE}/backups/ingress-${NAME}.yaml"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day the backup ran" >&2; exit 1; }
RESTORE_FILE="${BACKUP_FILE%.yaml}.restore.yaml"
# Drop server-set fields and the last-applied annotation: a stale resourceVersion makes the update
# fail with a conflict, and one recorded in the annotation can break later `kubectl apply` runs.
sed -e '/^  resourceVersion: /d' -e '/^  uid: /d' -e '/^  creationTimestamp: /d' -e '/^  generation: /d' "$BACKUP_FILE" \
  | awk '/^    kubectl\.kubernetes\.io\/last-applied-configuration:/ {skip=1; next} skip && /^      / {next} {skip=0; print}' > "$RESTORE_FILE"
# Empty only when the object is absent; a Forbidden, wrong-context or timeout error stops the block.
LIVE_RV="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get "$KIND" "$NAME" --ignore-not-found -o jsonpath='{.metadata.resourceVersion}')"
if [ -n "$LIVE_RV" ]; then
  # Still there: replace it at its current resourceVersion (custom resources refuse an update without one).
  awk -v rv="$LIVE_RV" '{print} /^metadata:$/ && !d {print "  resourceVersion: \"" rv "\""; d=1}' "$RESTORE_FILE" > "${RESTORE_FILE}.replace"
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" replace -f "${RESTORE_FILE}.replace"
else
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create -f "$RESTORE_FILE"
fi
WANT="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create --dry-run=client -f "$RESTORE_FILE" -o json | jq -S '.data // .spec')"
LIVE="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get "$KIND" "$NAME" -o json | jq -S '.data // .spec')"
[ "$WANT" = "$LIVE" ] && echo "RESTORED: live ingress matches the backup"
```

Expected: `RESTORED`. Repeat the external probe from SKILL.md to confirm access is back as it was.

2. **Convert a LoadBalancer/NodePort Service to ClusterIP.** This releases the cloud load balancer: the rollback creates a new one with a new address, so DNS and clients pointing at the old address stay broken until updated. Say so in the announcement.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
SVC="victoriametrics"
[ ! -e "${BACKUP_DIR}/svc-${SVC}.yaml" ] || { echo "${BACKUP_DIR}/svc-${SVC}.yaml already holds the pre-change copy from an earlier change today; keep it and fold this edit into that change" >&2; exit 1; }
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc "$SVC" -o yaml > "${BACKUP_DIR}/svc-${SVC}.yaml"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" patch svc "$SVC" -p '{"spec":{"type":"ClusterIP"}}'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc "$SVC" -o jsonpath='{.spec.type}{"\n"}'
```

Expected: `ClusterIP`. If Helm or GitOps owns the Service, make the same change in values or Git instead. Rollback restores the backup, in its own fresh shell:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
KIND="service"
NAME="victoriametrics"             # SVC from the block above
BACKUP_DATE="YYYY-MM-DD"           # UTC date of the backup step (its setup-<date>/backups folder)
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-${BACKUP_DATE}/backups/svc-${NAME}.yaml"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day the backup ran" >&2; exit 1; }
RESTORE_FILE="${BACKUP_FILE%.yaml}.restore.yaml"
# Drop server-set fields and the last-applied annotation: a stale resourceVersion makes the update
# fail with a conflict, and one recorded in the annotation can break later `kubectl apply` runs.
sed -e '/^  resourceVersion: /d' -e '/^  uid: /d' -e '/^  creationTimestamp: /d' -e '/^  generation: /d' "$BACKUP_FILE" \
  | awk '/^    kubectl\.kubernetes\.io\/last-applied-configuration:/ {skip=1; next} skip && /^      / {next} {skip=0; print}' > "$RESTORE_FILE"
# Empty only when the object is absent; a Forbidden, wrong-context or timeout error stops the block.
LIVE_RV="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get "$KIND" "$NAME" --ignore-not-found -o jsonpath='{.metadata.resourceVersion}')"
if [ -n "$LIVE_RV" ]; then
  # Still there: replace it at its current resourceVersion (custom resources refuse an update without one).
  awk -v rv="$LIVE_RV" '{print} /^metadata:$/ && !d {print "  resourceVersion: \"" rv "\""; d=1}' "$RESTORE_FILE" > "${RESTORE_FILE}.replace"
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" replace -f "${RESTORE_FILE}.replace"
else
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create -f "$RESTORE_FILE"
fi
WANT="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create --dry-run=client -f "$RESTORE_FILE" -o json | jq -S '.data // .spec')"
LIVE="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get "$KIND" "$NAME" -o json | jq -S '.data // .spec')"
[ "$WANT" = "$LIVE" ] && echo "RESTORED: live Service matches the backup"
```

Expected: `RESTORED`.

3. **Keep the host but add auth** when your team genuinely needs external access: an authenticating reverse proxy or your ingress controller's auth annotations, with TLS. The exact mechanism depends on your ingress controller; announce the chosen mechanism and verify by repeating the external probe from SKILL.md and getting `401` or `403` without credentials.

Always finish with the external probe block in [SKILL.md](../SKILL.md#lock-down-exposure) (step 2), at an API path for the backend: it must print `CLOSED`.

## NetworkPolicies

A pod is isolated the moment any NetworkPolicy selects it. `allow-monitoring-paths` selects every pod in the namespace, so applying it is the breaking change: every inbound path your stack needs must be in it before it goes on. Order: save the baseline, apply the allow policy and compare, apply default-deny and compare, then probe. Selector labels and ports below are examples; read the real ones off your pods first (`kubectl --context <context> -n <namespace> get pods --show-labels`).

```yaml
# Save as ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-<UTC date>/np-allow-monitoring.yaml.
# Example: adjust namespaces, selectors, and ports to your stack.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-paths
  namespace: monitoring
spec:
  podSelector: {}                # every pod in the monitoring namespace: applying this starts isolation
  policyTypes: ["Ingress"]
  ingress:
    - from:                      # inside the namespace: scrapes, Prometheus to Alertmanager, Grafana to the stores
        - podSelector: {}
    - from:                      # other namespaces: Grafana and query clients, log, trace, OTLP and remote-write pushers
        - namespaceSelector: {}
      ports:                     # VictoriaMetrics uses 8428 (single), 8480 and 8481 (cluster); Mimir 8080
        - port: 9090             # Prometheus query and remote-write receiver
          protocol: TCP
        - port: 9093             # Alertmanager API, for rulers and Grafana outside the namespace
          protocol: TCP
        - port: 3100             # Loki push and query
          protocol: TCP
        - port: 3200             # Tempo query
          protocol: TCP
        - port: 4317             # OTLP gRPC
          protocol: TCP
        - port: 4318             # OTLP HTTP
          protocol: TCP
    - from:                      # your ingress controller, for every UI or API you expose
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx   # example: your ingress controller's namespace
```

Two inbound paths match no namespace selector because they start outside the pod network: the API server calling an operator admission webhook, and traffic arriving through a LoadBalancer or NodePort Service. If you run either, add an `ipBlock` rule for your control-plane or node CIDR on that port before applying; without it the webhook calls time out, which blocks or skips rule validation depending on the webhook's `failurePolicy`.

```yaml
# Save as ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-<UTC date>/np-default-deny.yaml.
# A backstop: it changes nothing while allow-monitoring-paths selects every pod, and keeps the
# namespace closed if that policy is later narrowed or removed.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes: ["Ingress"]
```

Save the baseline before any policy exists:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
METRICS_URL="https://prometheus.example.com"   # prometheus.url (or victoriametrics.url, or mimir.url + "/prometheus")
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR"
BASELINE="${WORK_DIR}/np-baseline-up.txt"
[ ! -e "$BASELINE" ] || { echo "${BASELINE} already holds the pre-policy baseline; keep it" >&2; exit 1; }
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
MET_TOKEN="${PROM_TOKEN:-}"   # the variable the metrics block's token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${MET_TOKEN}"; [ -n "$MET_TOKEN" ] || AUTH="Accept: application/json"
BODY="$(curl -fsS --max-time 10 -H "$AUTH" -G "${METRICS_URL}/api/v1/query" --data-urlencode 'query=count(up == 1)')" \
  || { echo "metrics query failed at ${METRICS_URL}" >&2; exit 1; }
UP="$(printf '%s' "$BODY" | jq -er '.data.result[0].value[1] | tonumber')" || { echo "no up series to count in this store" >&2; exit 1; }
printf '%s\n' "$UP" > "$BASELINE"
echo "BASELINE: ${UP} up targets, saved to ${BASELINE}"
```

Apply one policy and compare, in its own run: first with the allow policy, then, only after that run prints `VERIFIED`, with the deny policy. The block refuses the deny while the allow policy is absent.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"               # kubernetes.context
MON_NS="monitoring"                            # kubernetes.monitoring_namespace
METRICS_URL="https://prometheus.example.com"   # prometheus.url (or victoriametrics.url, or mimir.url + "/prometheus")
POLICY="np-allow-monitoring.yaml"              # np-allow-monitoring.yaml first; np-default-deny.yaml on the second run
SCRAPE_WAIT="60"                               # seconds, at least one scrape interval; example, tune to your environment
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)"
BASELINE="${WORK_DIR}/np-baseline-up.txt"
[ -s "${WORK_DIR}/${POLICY}" ] || { echo "Save the announced policy to ${WORK_DIR}/${POLICY} first" >&2; exit 1; }
[ -s "$BASELINE" ] || { echo "No baseline at ${BASELINE}: run the baseline block before any policy" >&2; exit 1; }
if [ "$POLICY" = "np-default-deny.yaml" ]; then
  kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get networkpolicy allow-monitoring-paths -o name >/dev/null \
    || { echo "apply and verify the allow policy before the deny" >&2; exit 1; }
fi
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
MET_TOKEN="${PROM_TOKEN:-}"   # the variable the metrics block's token_env names; empty for an open endpoint
AUTH="Authorization: Bearer ${MET_TOKEN}"; [ -n "$MET_TOKEN" ] || AUTH="Accept: application/json"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "${WORK_DIR}/${POLICY}"
echo "waiting ${SCRAPE_WAIT}s for a scrape cycle"; sleep "$SCRAPE_WAIT"
BODY="$(curl -fsS --max-time 10 -H "$AUTH" -G "${METRICS_URL}/api/v1/query" --data-urlencode 'query=count(up == 1)')" \
  || { echo "metrics query failed after ${POLICY}: run the NetworkPolicy rollback block if the policy cut the store off" >&2; exit 1; }
UP="$(printf '%s' "$BODY" | jq -er '.data.result[0].value[1] | tonumber')" || { echo "no up series after ${POLICY}: run the NetworkPolicy rollback block" >&2; exit 1; }
BASE="$(cat "$BASELINE")"
[ "$UP" -ge "$BASE" ] || { echo "up targets fell from ${BASE} to ${UP} after ${POLICY}: run the NetworkPolicy rollback block" >&2; exit 1; }
echo "VERIFIED: ${UP} up targets after ${POLICY} (baseline ${BASE})"
```

Expected: `VERIFIED` on each run. Also check what the count cannot see: Grafana panels still load from another namespace, and pushes from your collectors still land. Then prove enforcement with a probe from a namespace that should not have access, at a port the allow policy does not open (this creates a temporary pod; it is part of the announced change):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
PROBE_NS="default"                 # a namespace that should not reach the monitoring stack
PROBE_URL="http://alertmanager-operated.monitoring.svc:9094/"   # a monitoring port the allow policy does not open to other namespaces (the Alertmanager cluster port); example
RC=0
kubectl --context "$KUBE_CONTEXT" -n "$PROBE_NS" run np-probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sS -o /dev/null --max-time 5 "$PROBE_URL" || RC=$?
case "$RC" in
  28) echo "DENIED: the probe timed out (exit 28), so the policy is enforced" ;;
  0)  echo "REACHABLE: ${PROBE_URL} answered from ${PROBE_NS}: the CNI does not enforce the policy, or the policy opens that port" >&2; exit 1 ;;
  *)  echo "probe exit ${RC}, not a timeout: a refused connection or empty reply means it reached the pod; read the output above" >&2; exit 1 ;;
esac
```

Expected: `DENIED`. Re-check Alertmanager delivery afterward; egress to receivers keeps working because these policies restrict ingress only.

If your CNI does not enforce NetworkPolicy, these objects apply cleanly and do nothing. Confirm enforcement with the probe, not with `kubectl get`.

Rollback, in its own fresh shell (the deny policy goes first):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
# --ignore-not-found: after a mid-batch stop the deny policy may never have been applied, and the
# allow policy alone still isolates the namespace, so it must come out either way.
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete networkpolicy default-deny-ingress --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete networkpolicy allow-monitoring-paths --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get networkpolicy default-deny-ingress allow-monitoring-paths 2>&1 | grep -c NotFound
```

Expected: `2` (both policies gone).

## PodDisruptionBudgets

Only for components with 2 or more replicas.

```yaml
# Save as ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-<UTC date>/pdb-alertmanager.yaml.
# Example: adjust the selector to your pod labels.
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
PDB_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)/pdb-alertmanager.yaml"   # the announced manifest
STATUS_WAIT="5"   # seconds for the disruption controller to fill in status; example
[ -s "$PDB_FILE" ] || { echo "Save the announced manifest to ${PDB_FILE} first" >&2; exit 1; }
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "$PDB_FILE"
sleep "$STATUS_WAIT"
ALLOWED="$(kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb alertmanager -o jsonpath='{.status.disruptionsAllowed}')"
echo "alertmanager: disruptionsAllowed=${ALLOWED:-not yet computed}"
[ "${ALLOWED:-0}" -ge 1 ] || { echo "the budget allows no disruption, so node drains hang: fix replicas or remove the PDB" >&2; exit 1; }
```

Expected: `disruptionsAllowed` of 1 or more. `0` means the budget cannot be met and node drains will hang; fix replicas or remove the PDB. Rollback, in its own fresh shell:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb alertmanager
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb alertmanager 2>&1 | tail -1
```

Expected: `NotFound`.

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

**Verification per signal.** The metrics and Loki parity block is in [SKILL.md](../SKILL.md#standardize-service-labels). For VictoriaLogs or Tempo, compare its list with the metrics list:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SIGNAL="tempo"                                 # tempo, or victorialogs when loki.url serves VictoriaLogs
METRICS_URL="https://prometheus.example.com"   # prometheus.url (or victoriametrics.url, or mimir.url + "/prometheus")
SIGNAL_URL="https://tempo.example.com"         # tempo.url, or loki.url for VictoriaLogs
WINDOW_MINUTES="15"                            # only names seen this recently count; example, tune to your traffic
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
MET_TOKEN="${PROM_TOKEN:-}"     # the variable the metrics block's token_env names; empty for an open endpoint
SIG_TOKEN="${TEMPO_TOKEN:-}"    # the variable tempo.token_env (or loki.token_env) names; empty for an open endpoint
MAUTH="Authorization: Bearer ${MET_TOKEN}"; [ -n "$MET_TOKEN" ] || MAUTH="Accept: application/json"
SAUTH="Authorization: Bearer ${SIG_TOKEN}"; [ -n "$SIG_TOKEN" ] || SAUTH="Accept: application/json"
# macOS (BSD) date, then GNU date fallback:
SINCE="$(date -u -v-"${WINDOW_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${WINDOW_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"
MET_BODY="$(curl -fsS --max-time 10 -H "$MAUTH" -G "${METRICS_URL}/api/v1/label/service/values" --data-urlencode "start=${SINCE}")" \
  || { echo "metrics label read failed at ${METRICS_URL}" >&2; exit 1; }
case "$SIGNAL" in
  tempo)
    SIG_BODY="$(curl -fsS --max-time 10 -H "$SAUTH" "${SIGNAL_URL}/api/search/tag/service.name/values")" \
      || { echo "trace tag read failed at ${SIGNAL_URL}" >&2; exit 1; }
    printf '%s' "$SIG_BODY" | jq -r '.tagValues[]' | LC_ALL=C sort > "${WORK_DIR}/${SIGNAL}-services.txt" ;;
  victorialogs)
    SIG_BODY="$(curl -fsS --max-time 15 -H "$SAUTH" "${SIGNAL_URL}/select/logsql/field_values" \
      --data-urlencode "query=_time:${WINDOW_MINUTES}m" --data-urlencode "field=service")" \
      || { echo "log field read failed at ${SIGNAL_URL}" >&2; exit 1; }
    printf '%s' "$SIG_BODY" | jq -r '.values[].value' | LC_ALL=C sort > "${WORK_DIR}/${SIGNAL}-services.txt" ;;
  *) echo "SIGNAL must be tempo or victorialogs" >&2; exit 1 ;;
esac
printf '%s' "$MET_BODY" | jq -r '.data[]' | LC_ALL=C sort > "${WORK_DIR}/metrics-services.txt"
# Two empty lists compare equal and prove nothing.
[ -s "${WORK_DIR}/metrics-services.txt" ] && [ -s "${WORK_DIR}/${SIGNAL}-services.txt" ] \
  || { echo "a service list is empty: check the label name and that both stores hold recent data" >&2; exit 1; }
DIFF="$(LC_ALL=C comm -3 "${WORK_DIR}/metrics-services.txt" "${WORK_DIR}/${SIGNAL}-services.txt")"
[ -z "$DIFF" ] || { echo "names still differ (first column metrics only, indented ${SIGNAL} only):"; printf '%s\n' "$DIFF"; exit 1; }
echo "ALIGNED: metrics and ${SIGNAL} name the same services"
```

Expected: `ALIGNED`.

Renamed labels start new series and orphan old queries. In the same announced change, update alert `expr`s and dashboard queries that used the old name, and note the cutover time so historical queries are read with the old label.
