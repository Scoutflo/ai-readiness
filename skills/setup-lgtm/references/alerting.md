# Alerting Fix Cookbook

Payloads and rollbacks for the alert-routing sections of [setup-lgtm](../SKILL.md). Every block here is applied only through the change protocol: announce, confirm, execute, verify, record.

Every command block below redeclares the variables it uses, each with the `toolkit.yaml` key it resolves from (or the step that produced it), so it runs correctly pasted alone into a fresh shell. No block depends on an earlier block having run.

## Locate the running Alertmanager config

The running config is truth; find what generates it before editing anything.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get sts -l app.kubernetes.io/name=alertmanager -o json \
  | jq -r '.items[].spec.template.spec.volumes[] | select(.secret or .configMap) | (.secret.secretName // .configMap.name)'
```

| What you find | Deployment style | Where the change goes |
| --- | --- | --- |
| Secret named `alertmanager-<release>-...generated` | Prometheus Operator / kube-prometheus-stack | Helm values under `alertmanager.config`, or `AlertmanagerConfig` CRs |
| Secret or ConfigMap your team wrote by hand | Raw manifest | Replace that Secret/ConfigMap |
| `VMAlertmanager` CR present (`kubectl get vmalertmanagers -A`) | VictoriaMetrics operator | The Secret named in `spec.configSecret`, or `VMAlertmanagerConfig` CRs |
| Helm release for a standalone `alertmanager` chart | Helm | Chart values under `config` |

Back up before any edit:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
BACKUP_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
AM_SECRET="alertmanager-config"   # the Secret/ConfigMap found above
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get secret "$AM_SECRET" -o yaml > "${BACKUP_DIR}/${AM_SECRET}.yaml"
```

For Helm-managed configs also record the values and revision:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
BACKUP_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
RELEASE="kube-prometheus-stack"   # from: helm list -A
helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" get values "$RELEASE" > "${BACKUP_DIR}/${RELEASE}-values.yaml"
PREV_REV="$(helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" history "$RELEASE" --max 1 -o json | jq -r '.[0].revision')"
echo "rollback target: revision ${PREV_REV}"
```

## Default receiver and severity routes (Helm values path)

Override file for a kube-prometheus-stack style chart. Receiver names and channels are examples; use the receivers your team actually watches. Webhook and API URLs are secrets: reference them with `*_file` options pointing at a mounted Secret, never inline.

```yaml
# am-fix.yaml
alertmanager:
  config:
    route:
      receiver: team-default            # was: "null" or a dead webhook
      group_by: ["alertname", "service"]
      group_wait: 30s                   # example, tune to your environment
      group_interval: 5m                # example, tune to your environment
      repeat_interval: 4h               # example, tune to your environment
      routes:
        - matchers: ['severity="critical"']
          receiver: team-pager
        - matchers: ['severity="warning"']
          receiver: team-default
    inhibit_rules:
      - source_matchers: ['severity="critical"']
        target_matchers: ['severity="warning"']
        equal: ["alertname", "service"]
    receivers:
      - name: team-default
        slack_configs:
          - channel: "#alerts"
            api_url_file: /etc/alertmanager/secrets/alertmanager-slack/webhook-url
            send_resolved: true
      - name: team-pager
        pagerduty_configs:
          - routing_key_file: /etc/alertmanager/secrets/alertmanager-pagerduty/routing-key
            send_resolved: true
  alertmanagerSpec:
    secrets:                            # mounts each Secret at /etc/alertmanager/secrets/<name>/
      - alertmanager-slack
      - alertmanager-pagerduty
```

The referenced Secrets must exist first. Create them from environment variables so the values never land in your shell history as arguments to config files:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
# SLACK_WEBHOOK_URL comes from your secret store; presence check only, never echo it.
[ -n "${SLACK_WEBHOOK_URL:-}" ] || { echo "SLACK_WEBHOOK_URL is not set"; exit 1; }
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create secret generic alertmanager-slack \
  --from-literal=webhook-url="$SLACK_WEBHOOK_URL"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get secret alertmanager-slack -o jsonpath='{.data}' | jq 'keys'
```

Expected: `["webhook-url"]`. Apply the override:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
RELEASE="kube-prometheus-stack"    # from: helm list -A, the release from the backup step
CHART="prometheus-community/kube-prometheus-stack"   # the chart source your team already deploys from
helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" upgrade "$RELEASE" "$CHART" --reuse-values -f am-fix.yaml
```

Verify:

```bash
set -eu
ALERTMANAGER_URL="https://alertmanager.example.com"   # prometheus.alertmanager_url
curl -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" | jq -r '.config.original' | sed -n '/^route:/,/^receivers:/p'
```

Expected: the new default receiver and routes. Allow up to a minute for the config reloader to pick up the Secret change.

Rollback:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
RELEASE="kube-prometheus-stack"    # from: helm list -A, the release you upgraded
PREV_REV="3"                       # the revision recorded in the backup step's "rollback target" output
helm --kube-context "$KUBE_CONTEXT" -n "$MON_NS" rollback "$RELEASE" "$PREV_REV"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" delete secret alertmanager-slack alertmanager-pagerduty
```

## Default receiver (raw Secret path)

When the config is a hand-written Secret, edit a decoded copy and replace it:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
AM_SECRET="alertmanager-config"
AM_KEY="alertmanager.yml"    # the data key inside the Secret
WORK_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get secret "$AM_SECRET" \
  -o go-template='{{index .data "'"$AM_KEY"'" | base64decode}}' > "${WORK_DIR}/alertmanager.yml"
# Edit ${WORK_DIR}/alertmanager.yml: route, routes, inhibit_rules, receivers (use *_file for URLs/keys).
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" create secret generic "$AM_SECRET" \
  --from-file="${AM_KEY}=${WORK_DIR}/alertmanager.yml" --dry-run=client -o yaml \
  | kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f -
```

If `amtool` is installed, validate before applying: `amtool check-config "${WORK_DIR}/alertmanager.yml"`. Verify via `/api/v2/status` as above; if the pod does not hot-reload, announce and perform a rollout restart of the Alertmanager StatefulSet as its own change.

Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "${BACKUP_DIR}/${AM_SECRET}.yaml"`.

## Operator CR path

Prometheus Operator `AlertmanagerConfig` and VictoriaMetrics `VMAlertmanagerConfig` CRs merge namespaced routing into the global config. Use them when your team already manages routing that way; do not mix CR-managed and values-managed routes for the same severity, the merge order becomes the bug. Back up with `kubectl get <kind> <name> -o yaml`, apply the edited copy, and verify through `/api/v2/status` like every other path. Rollback is applying the backup.

## Test-fire failure shapes

After a test-fire shows `active` in `/api/v2/alerts` but nothing arrives:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" logs -l app.kubernetes.io/name=alertmanager --since=15m --tail=200 | grep -i 'notify' | tail -20
```

| Log shape | Meaning |
| --- | --- |
| `notify retry canceled ... context deadline exceeded` | Receiver endpoint unreachable: egress blocked, dead URL, DNS failure |
| `401` / `403` / `invalid_token` in notify errors | Webhook or routing key rejected: wrong secret mounted or rotated out |
| `404` from chat webhook | Webhook deleted or channel removed; recreate the webhook in the chat tool |
| No notify lines at all | Route never matched: check matchers against the test alert's labels |
| Message arrives but with resolved state only | `group_wait` or `repeat_interval` swallowed the firing state; re-check route timers |

Test one severity route at a time by changing only the `severity` label of the test alert. Never leave a test running: the resolve payload is in [SKILL.md](../SKILL.md#test-fire-receivers).

## Quiet noisy rules per rule engine

Find which engine evaluates the noisy rule first: `curl -fsS --max-time 10 "${METRICS_URL}/api/v1/rules" | jq -r '.data.groups[].file'` (Prometheus/Mimir), `${VMALERT_URL}/api/v1/rules` (vmalert), or Loki ruler paths for log-based rules.

**Prometheus Operator (`PrometheusRule` CR):**

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MON_NS="monitoring"                # kubernetes.monitoring_namespace
BACKUP_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)/backups"
RULE_CR="my-app-rules"    # from: kubectl get prometheusrules -n "$MON_NS"
WORK_DIR="./scoutflo-audits/lgtm/setup-$(date -u +%F)"
mkdir -p "$WORK_DIR" "$BACKUP_DIR"
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" get prometheusrule "$RULE_CR" -o yaml > "${BACKUP_DIR}/${RULE_CR}.yaml"
cp "${BACKUP_DIR}/${RULE_CR}.yaml" "${WORK_DIR}/${RULE_CR}-edit.yaml"
# Edit the copy: add a `for:` duration, tighten the expr, or remove the noisy rule block.
kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "${WORK_DIR}/${RULE_CR}-edit.yaml"
```

**VictoriaMetrics operator (`VMRule` CR):** same pattern with `kubectl get vmrules`; vmalert reloads rules automatically, verify at `${VMALERT_URL}/api/v1/rules`.

**Raw rule files:** edit the ConfigMap holding the rule file with the same backup/copy/apply pattern, then confirm the reload in the evaluator's logs.

Common edits for the noise classes audit-lgtm flags:

- Missing `for`: add `for: 10m` (example, tune to your environment) so transient spikes stop paging.
- Completed Jobs paging as unready pods: exclude succeeded pods, for example append `unless on(pod, namespace) kube_pod_status_phase{phase="Succeeded"} == 1` or filter `owner_kind!="Job"` where your rule uses `kube_pod_owner`.
- Dev namespaces paging production receivers: prefer routing the namespace to a low-urgency receiver over deleting the rule; detection stays, paging stops.

Verify every rule edit against the live rules API (`.duration`, `.state`, and the new `expr`), then watch `/api/v2/alerts` long enough to confirm the noise stopped and real alerts still fire.

Rollback: `kubectl --context "$KUBE_CONTEXT" -n "$MON_NS" apply -f "${BACKUP_DIR}/${RULE_CR}.yaml"`.

## vmalert notifier check

If routing fixes do not change delivery on a VictoriaMetrics stack, confirm vmalert points at the Alertmanager you just fixed:

```bash
set -eu
VMALERT_URL="https://vmalert.example.com"   # victoriametrics.vmalert_url (VM stacks)
curl -fsS --max-time 10 "${VMALERT_URL}/flags" | grep -i 'notifier.url'
```

Expected: your Alertmanager service URL. A localhost or stale notifier URL here means rules evaluate but notifications go nowhere; fix the vmalert flag or CR (`VMAlert` `spec.notifiers`) through its owner, then re-verify.
