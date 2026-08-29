---
name: setup-lgtm
description: Guided hardening of LGTM and VictoriaMetrics-family stacks from audit-lgtm findings; fixes alert receivers and routing, retention, HA, ingress exposure, NetworkPolicies, PodDisruptionBudgets, and service-label alignment, announcing each change, waiting for confirmation, then verifying live. Use when the user asks to fix an LGTM-NNN finding, wire or repair Alertmanager or vmalert routing, quiet noisy rules, harden retention or HA, lock down exposed monitoring endpoints, or standardize service labels across metrics, logs, and traces. Do not use for the Grafana application layer such as dashboards or contact points (use setup-grafana), for proving alerts reach a human (use audit-alertmanager), or for read-only assessment (use audit-lgtm).
disable-model-invocation: true
---

# setup-lgtm

Fixes findings from an `audit-lgtm` run against your LGTM or VictoriaMetrics-family stack. Input is one or more finding IDs from the latest `./scoutflo-audits/lgtm/<date>/findings.json`. You usually arrive here from a finding's `remediation` pointer, for example `setup-lgtm#fix-default-receiver`.

In scope: Alertmanager and vmalert routing, receiver test-fires, noisy rule cleanup, retention, HA and replication, ingress exposure, NetworkPolicies, PodDisruptionBudgets, and service-label alignment at the collector level. Grafana contact points, dashboards, and datasources belong to `setup-grafana`. Error-tracking fixes belong to `setup-sentry`. Missing application instrumentation is a change inside your application code; this skill records those items with a named owner instead of touching app repos.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the API call, manifest, or values diff with real values filled in, plus its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object with a read call and show the changed field holding the intended value. A write is unverified until re-read.
5. **Record.** Append the change, its verification evidence, and any pending items with a named owner to the change record.

## Doctor gate

Run these checks before any real work. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`. This skill uses the elevated credential tier: it mutates cluster and Alertmanager state.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Kubernetes | `kubernetes.context`, `kubernetes.monitoring_namespace` | none (kubeconfig) | patch/apply on workloads, config, NetworkPolicies, PDBs in the monitoring namespace | elevated |
| Alertmanager | `prometheus.alertmanager_url` | `prometheus.token_env` if set | GET status, POST alerts | elevated |
| Metrics backend | `prometheus.url` or `victoriametrics.url` or `mimir.url` | its `token_env` if set | read, for verification | read-only |
| Loki / Tempo | `loki.url`, `tempo.url` | their `token_env` if set | read, for label-parity verification | read-only |
| Helm | none | none | needed only when the stack is Helm-managed | elevated |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"                      # kubernetes.context
MON_NS="monitoring"                                   # kubernetes.monitoring_namespace
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
METRICS_URL="https://prometheus.example.com"          # prometheus.url (or victoriametrics.url / mimir.url)

[ -f "$HOME/.scoutflo/toolkit.yaml" ] || { echo "missing ~/.scoutflo/toolkit.yaml; run /scoutflo:connect"; exit 1; }
for bin in curl jq kubectl; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
command -v helm >/dev/null || echo "note: helm not found; Helm-managed changes are unavailable"

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" auth can-i patch statefulsets >/dev/null \
  || { echo "no write access to ${MON_NS} in ${KUBE_CONTEXT}; switch to an elevated kubeconfig"; exit 1; }
curl -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" | jq -r '.cluster.status'
curl -fsS --max-time 10 "${METRICS_URL}/api/v1/status/buildinfo" | jq -r '.data.version' \
  || curl -fsS --max-time 10 "${METRICS_URL}/health"
```

Expected: Alertmanager cluster status `ready` (or `disabled` on a single replica) and a version string or `OK` from the metrics backend. If any endpoint requires auth, add `-H "Authorization: Bearer ${PROM_TOKEN}"` to its curl; the `token_env` key in `toolkit.yaml` names the variable and the value never appears in output or logs.

## Live-safety gate

```bash
set -eu
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
echo "shell context:  $(kubectl config current-context)"
echo "pinned context: ${KUBE_CONTEXT}"
kubectl --context "$KUBE_CONTEXT" get nodes -o name | head -3
```

If the pinned context is not the cluster the config names, stop and report the mismatch. Never proceed on "probably the right cluster". Every command below pins `--context` explicitly; the shell default is never trusted.

## Load findings and build the change plan

1. Read the latest audit run and list open findings:

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-lgtm first"; exit 1; }
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
```

2. Select scope. Take the finding IDs you were asked to fix, or, if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section below.

3. Discover who owns each object before planning an edit. A change made below its owner gets reverted:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace

helm --kube-context "$KUBE_CONTEXT" list -A -o json | jq -r '.[] | "\(.namespace)/\(.name) \(.chart)"'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get deploy,sts -o json \
  | jq -r '.items[] | "\(.kind)/\(.metadata.name) managed-by=\(.metadata.labels["app.kubernetes.io/managed-by"] // "none") argocd=\(.metadata.labels["argocd.argoproj.io/instance"] // "-")"'
```

Helm-managed objects change through `helm upgrade` on the release. Operator-managed objects change through their CRs. If Argo CD or Flux owns the release, make the change in the Git source your controller syncs from; the protocol still applies, with "execute" meaning commit and sync, then verify live.

4. Create the working directory and snapshot targets before any change:

```bash
set -eu
RUN_DATE="$(date -u +%F)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
CHANGE_LOG="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/changes.md"
mkdir -p "$BACKUP_DIR"
```

Backups can embed receiver URLs and other sensitive config. `./scoutflo-audits/` stays out of version control.

5. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Exact change | Rollback |
| --- | --- | --- | --- | --- |

Approval must be explicit and may cover the whole table because every row was shown. If you approve only some rows, only those execute. A decline ends the run with zero changes. Execute approved rows one at a time, verifying each before starting the next. Order safety first: routing fixes before test-fires, allow-policies before default-deny, additive changes before destructive ones.

**Mid-batch failure rule.** If row N of an approved batch fails its verification, stop the batch immediately: no row N+1 runs. Every row already applied keeps its backup in `BACKUP_DIR`, taken before that row's write; those rows stay applied and recorded, they are not rolled back automatically. Re-fetch the failed object's current state, report exactly what happened (the command, the error, and what the live object now shows), and diagnose before doing anything else. Re-announce the remaining unexecuted rows as a fresh plan only after the user decides how to proceed; the earlier approval does not carry over to a re-announced batch. A half-applied change (a receiver pointed at a new webhook but never test-fired, a NetworkPolicy applied without its allow rule verified first) is worse than no change; verify or roll back the failed row before anything else runs.

## Fix sections by finding family

| Audit finding area | Sections | Payload details |
| --- | --- | --- |
| alert-routing | Fix default receiver, Add severity routes and inhibition, Test-fire receivers, Quiet noisy rules | [references/alerting.md](references/alerting.md) |
| service-coverage, correlation gaps | Standardize service labels | [references/hardening.md](references/hardening.md) |
| reliability-security | Set retention, Enable HA, Lock down exposure, Add network policies, Add disruption budgets | [references/hardening.md](references/hardening.md) |

### Fix default receiver

For findings where the default route points at a dead webhook, localhost, or a `null` receiver.

1. Read the running config and quote the current default route in the announcement:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url

curl -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" | jq -r '.config.original' | sed -n '/^route:/,/^receivers:/p'
```

2. Locate where that config comes from (Helm values, operator CR, or a raw Secret) and back it up; per-style payloads and rollbacks are in [references/alerting.md](references/alerting.md).
3. Announce the diff: old receiver, new receiver, the full route block after the change. Webhook URLs never go inline in config you write; use `*_file` options or an existing Secret mount.
4. Apply through the owner (helm upgrade, CR apply, or Secret replace).
5. Verify: re-run the read from step 1 and show the new default receiver name. Then prove delivery with a test-fire (next section).

Rollback: re-apply the backup taken in step 2, or `helm rollback` to the recorded revision.

### Add severity routes and inhibition

For findings about missing severity routing, grouping, or inhibition. Same locate/backup/apply/verify path as the default receiver; route and `inhibit_rules` payloads are in [references/alerting.md](references/alerting.md). Verify by re-reading `.config.original` and confirming each new route block, then test-fire one alert per new route.

### Test-fire receivers

Proves a receiver actually delivers. This pages real humans: tell your on-call before firing at a pager receiver, and announce each test-fire as its own change.

```bash
set -eu
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
TEST_SEVERITY="critical"                              # the route under test
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# macOS (BSD) date, then GNU date fallback:
END="$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"

curl -fsS --max-time 10 -X POST "${ALERTMANAGER_URL}/api/v2/alerts" \
  -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"ToolkitReceiverTest\",\"severity\":\"${TEST_SEVERITY}\",\"service\":\"receiver-test\"},
       \"annotations\":{\"summary\":\"Controlled receiver test from setup-lgtm. Safe to acknowledge.\"},
       \"startsAt\":\"${NOW}\",\"endsAt\":\"${END}\"}]"
```

Verify, in order:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url

curl -fsS --max-time 10 -G "${ALERTMANAGER_URL}/api/v2/alerts" \
  --data-urlencode 'filter=alertname="ToolkitReceiverTest"' | jq -r '.[].status.state'
```

Expected: `active`. Then confirm with a human that the message arrived at the receiver (channel message, page, email). Delivery is proven by receipt, not by the POST succeeding. If nothing arrives, read the Alertmanager pod logs for `notify` errors; the failure shapes are in [references/alerting.md](references/alerting.md).

Rollback (also run this after a successful test):

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
TEST_SEVERITY="critical"                              # the route under test

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
curl -fsS --max-time 10 -X POST "${ALERTMANAGER_URL}/api/v2/alerts" \
  -H 'Content-Type: application/json' \
  -d "[{\"labels\":{\"alertname\":\"ToolkitReceiverTest\",\"severity\":\"${TEST_SEVERITY}\",\"service\":\"receiver-test\"},
       \"startsAt\":\"${NOW}\",\"endsAt\":\"${NOW}\"}]"
```

The `endsAt` in the past resolves the alert immediately; the original `endsAt` bounds it even if you forget.

### Quiet noisy rules

For findings about rules firing on non-issues: missing `for` durations, completed Jobs paging as unready pods, dev namespaces paging production receivers.

1. Find the rule's source CR or rule file, back it up, and announce the exact edit (add `for`, tighten the `expr`, or delete the rule block). Patterns per rule engine are in [references/alerting.md](references/alerting.md).
2. Apply through the owner.
3. Verify against the live rule API, not the file:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
METRICS_URL="https://prometheus.example.com"   # prometheus.url (or victoriametrics.url / mimir.url)
RULE_NAME="KubePodNotReady"                    # the rule you changed

curl -fsS --max-time 10 "${METRICS_URL}/api/v1/rules" \
  | jq -r '.data.groups[].rules[] | select(.name=="'"$RULE_NAME"'") | "\(.name) for=\(.duration)s state=\(.state)"'
```

Expected: the new `for` duration in seconds and a sane state. For vmalert, use `${VMALERT_URL}/api/v1/rules`.

Rollback: `kubectl apply -f` the backup CR, or `helm rollback`.

Deleting a rule removes a detection path. Confirm rule deletions individually, never inside a batch approval.

### Standardize service labels

For correlation findings where the same service carries different names across metrics, logs, and traces. Fix at the collection layer so every signal derives the label the same way; relabel, pipeline, and OTel payloads are in [references/hardening.md](references/hardening.md).

1. Announce the canonical label plan: one `service` value per service, sourced from one pod label (for example `app.kubernetes.io/name`), and which collectors change.
2. Apply the relabel or processor change per collector, through its owner, one collector at a time.
3. Verify parity live after each apply (allow one scrape/flush interval):

```bash
set -eu
METRICS_URL="https://prometheus.example.com"   # prometheus.url
LOKI_URL="https://loki.example.com"            # loki.url
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR"
curl -fsS --max-time 10 "${METRICS_URL}/api/v1/label/service/values" | jq -r '.data[]' | sort > "${WORK_DIR}/metrics-services.txt"
curl -fsS --max-time 10 "${LOKI_URL}/loki/api/v1/label/service/values" | jq -r '.data[]' | sort > "${WORK_DIR}/logs-services.txt"
comm -3 "${WORK_DIR}/metrics-services.txt" "${WORK_DIR}/logs-services.txt"
```

Expected: no output once names align. VictoriaLogs and trace-side equivalents are in the reference.

Renaming a label breaks every dashboard query and alert `expr` that used the old name, and starts new series. Update the affected rules and dashboards in the same announced change, and re-run the audit's correlation check afterward. `service.name` set inside application SDKs is an application change: record it as pending with the owning team named.

Rollback: re-apply the backed-up collector config; old label values return on the next scrape.

### Set retention

For findings about missing or unbounded retention. Retention values are examples, tune to your compliance and cost targets:

```bash
RETENTION="30d"   # example, tune to your environment
```

Per-backend flags, values paths, and verification reads (Prometheus `/api/v1/status/flags`, VictoriaMetrics `/flags`, Loki `/config`, Tempo compactor) are in [references/hardening.md](references/hardening.md).

Reducing retention deletes data, sometimes within minutes of the component restarting. Announce a reduction as its own change with the data loss stated, never inside a batch.

Rollback: restore the previous value the same way; deleted data does not come back.

### Enable HA

For findings about single-replica Alertmanager or single-node metrics storage. Replica counts are examples, tune to your environment. Payloads per component are in [references/hardening.md](references/hardening.md).

Verify Alertmanager clustering after the change:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url

curl -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" | jq -r '.cluster.status, (.cluster.peers | length)'
```

Expected: `ready` and a peer count equal to the replica count. For metrics storage, adding replication multiplies disk usage and may require query-side deduplication; the reference states the checks per backend. Rollback: restore the previous replica or replication values and verify the same reads.

### Lock down exposure

For findings where a metrics, logs, traces, or Alertmanager endpoint is publicly reachable without auth.

1. Enumerate exposure and quote it in the announcement:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get ingress -o json \
  | jq -r '.items[] | "\(.metadata.name) hosts=\([.spec.rules[].host] | join(","))"'
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get svc -o json \
  | jq -r '.items[] | select(.spec.type=="LoadBalancer" or .spec.type=="NodePort") | "\(.metadata.name) \(.spec.type)"'
```

2. Prove it live before and after:

```bash
INGRESS_HOST="alertmanager.example.com"   # the exposed host from step 1
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 "https://${INGRESS_HOST}/"
```

Before: `200` with no auth is the finding. After the fix: `401`, `403`, `404`, or a timeout.

3. Fix by deleting the ingress, adding an auth layer, or converting the Service to ClusterIP; options with rollbacks are in [references/hardening.md](references/hardening.md). Back up the object first; rollback is re-applying the backup.

Removing an ingress your team actually uses locks them out too. Confirm who consumes the endpoint before deleting, and name the internal access path they switch to.

### Add network policies

For findings about missing NetworkPolicies in the monitoring namespace. Order is load-bearing:

1. Apply allow policies first: scrapers to targets, Grafana to datasources, Alertmanager egress to receivers. Manifests in [references/hardening.md](references/hardening.md).
2. Verify scraping still works: `${METRICS_URL}/api/v1/targets` shows the same number of `up` targets as before.
3. Only then apply default-deny, and verify both that a cross-namespace probe now times out and that targets stay up. The probe command is in the reference.

Rollback: `kubectl delete networkpolicy` the applied policies, most recent first.

### Add disruption budgets

For findings about missing PDBs on monitoring components. Only add a PDB where replicas are 2 or more; a PDB on a single replica blocks node drains. Manifest in [references/hardening.md](references/hardening.md).

Verify:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace

kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get pdb
```

Expected: `ALLOWED DISRUPTIONS` of 1 or more for each new PDB. `0` means the PDB is blocking maintenance; fix the replica count or delete the PDB.

Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete pdb <name>`.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/lgtm/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed>
- Command: <exact command or values diff applied>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's reach (application instrumentation, SDK `service.name`, Git-owned config awaiting merge), each with a named owner.
3. A fresh `/scoutflo:audit-lgtm` run to re-score; its delta shows which findings moved to fixed. If routing changed, `audit-alertmanager` proves the paging path end to end.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Helm-, operator-, or GitOps-owned object edited directly, reverted at next sync | Discover the owner first; change at the owner level and verify live after sync |
| Change applied to the wrong cluster | Run the live-safety gate; pin `--context` on every kubectl command |
| Default-deny NetworkPolicy applied before allow rules, scraping breaks | Apply and verify allow policies first; check target counts before default-deny |
| Test alert without `endsAt` keeps re-notifying | Set `endsAt` on every test-fire and post an explicit resolve after the test |
| Receiver marked fixed without delivery proof | End every receiver change with a test-fire and a human confirming receipt |
| Pager receiver test-fired without warning | Tell your on-call before firing at any paging receiver |
| Retention reduced and data expired immediately | Treat reductions as destructive; announce the data loss and confirm individually |
| PDB on a single-replica component blocks node drains | Add PDBs only where replicas are 2 or more; check `ALLOWED DISRUPTIONS` after |
| Service label renamed, dashboards and alert exprs break | Update rules and dashboards in the same change; re-run the label parity check |
| Alertmanager config written but never picked up | Verify by re-reading `.config.original` from the API, not the Secret or file |
| Noisy rule deleted inside a batch, detection path lost | Confirm every rule deletion individually with the rule body quoted |
