# audit-azure: Check Catalog and Commands

Runnable, strictly read-only checks for every scored surface the [audit-azure](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the exact read command (an `az` read or an ARM REST GET pinned to an api-version **confirmed on a live 200 read**), the healthy target, the finding it emits, and its forbidden-mutations. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. The non-scored Cost & Resource Optimization catalog (`AZR-OPT-NNN`) lives in its own file, [azure-cost-checks.md](azure-cost-checks.md); this file is the scored reliability axis (`AZR-NNN`).

## 1. Conventions

- **Confirmed-truth provenance.** Every api-version cited here was confirmed on a live 200 read before this catalog cited it; this catalog never invents one. The single surface the report did **not** exercise is `Microsoft.Insights/diagnosticSettings` (no resource to attach it to), so wherever diagnostic settings are read (AZR-010, AZR-032, AZR-050) the pinned surface is the `az monitor diagnostic-settings` **CLI** (it manages its own api-version); a failure there is recorded `blocked`, never worked around with a guessed REST version.
- **Identity preamble.** Every ARM block starts with these lines, so it runs alone in a fresh shell holding one identity with no silent fallback. The confirmed auth path is `DefaultAzureCredential` → `AzureCliCredential` (via `az login`):

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id from ~/.scoutflo/toolkit.yaml (empty = az CLI default)
az account show --query '{subscription:id, tenant:tenantId, user:user.name}' -o json   # confirm the target BEFORE any read
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM="https://management.azure.com"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
arm_get() { curl -fsS --max-time 30 -H "Authorization: Bearer ${ARM_TOKEN}" "${ARM}${1}"; }   # every call is a GET (read-only)
```

  `ARM_TOKEN` travels only in the `Authorization` header. Never echo it, put it in a URL, or write it to a file, evidence, or the report. If minting the token fails, stop; do not fall back to another credential.
- **Explicit subscription on everything.** Every REST path embeds `${SUB}`; the audit never runs `az account set` mid-run to switch subscriptions silently. Confirm `az account show` matches the intended target before any read.
- **Read-only by effect, not verb.** Resource Graph and Cost Management queries are READS that use POST (`readOnly`) and belong to the cost catalog; every call **this** file makes is a GET or `az … list/show`. An action group's `test-notifications` POST actually pages a human and is a mutation — never run it (delivery proof is a manual/`setup-azure` exception, see AZR-001).
- **Redaction.** Action-group receivers carry emails, phone numbers, and webhook URIs. Capture `name`, `enabled`, and receiver **type and count** only — never a receiver value; the jq filters below already do this.
- **Pagination is real.** ARM lists return `nextLink`; loop until empty (shown once in the inventory), never judge counts from one page.
- **`az aks show` is the pinned AKS surface** (the report confirmed the signals off the control-plane object, not from inside the cluster); the audit never runs `az aks get-credentials`. Thresholds and windows are examples; tune to your workloads.

## 2. Check catalog

One permanent ID per check; IDs never change or get reused. Severity listed is the typical severity when the check fails; judge real impact in your environment.

| ID | Category | Check | Confirmed surface (api-version) | Typical fail severity |
| --- | --- | --- | --- | --- |
| AZR-001 | Alert routing and delivery | ≥1 enabled action group with a reachable receiver exists, and enabled alert rules reference one | `Microsoft.Insights/actionGroups` (**2023-01-01**) | critical |
| AZR-002 | Metric alert coverage | Every serving resource class has a metric alert on its saturation/error signals | `Microsoft.Insights/metricAlerts` (**2018-03-01**) | high |
| AZR-003 | Scheduled-query (log) alerts | Log-based signals metrics can't express are covered by scheduled-query rules wired to an action group | `Microsoft.Insights/scheduledQueryRules` (**2022-06-15**) | high |
| AZR-004 | Activity-log alerts | Service Health, Resource Health, and critical admin/security operations page someone | `Microsoft.Insights/activityLogAlerts` (**2020-10-01**) | medium |
| AZR-007 | Empty/hidden-scope guardrail | 0 action groups AND 0 metric alerts despite a readable 200 is `blocked` (visibility/scope gap), not a confident 0 | actionGroups + metricAlerts | critical |
| AZR-010 | VM/VMSS coverage | Serving VMs/VMSS carry CPU metric alerts; guest memory/disk claimed only with agent proof; diagnostic settings route to Log Analytics | `Microsoft.Compute/virtualMachines`, `…/virtualMachineScaleSets` (**2024-07-01**) + diagnostic-settings CLI | high |
| AZR-030 | AKS Container Insights | `addonProfiles.omsagent.enabled == true` on serving clusters | `az aks show` (control plane) | high |
| AZR-031 | AKS managed Prometheus | `azureMonitorProfile.metrics.enabled` matches where workload alerting is expected | `az aks show` (control plane) | medium |
| AZR-032 | AKS diagnostic settings | AKS control-plane logs routed to Log Analytics via a diagnostic setting | diagnostic-settings CLI on the cluster ID | high |
| AZR-040 | Log Analytics coverage/retention | A workspace exists, receives critical-service logs, and its retention is a deliberate decision | `Microsoft.OperationalInsights/workspaces` (**2022-10-01**) | high |
| AZR-050 | App Gateway / Load Balancer | Every serving App Gateway/Load Balancer has backend health probes and diagnostic settings enabled | `Microsoft.Network/applicationGateways`, `…/loadBalancers` (**2024-05-01**) + diagnostic-settings CLI | high |
| AZR-060 | Alert quality | Every alert rule carries a severity, a responder-ready description, and a retest window | actionGroups + metric/scheduled/activity rules | medium |

Non-scored: **AZR-OPT-NNN** — the Cost & Resource Optimization catalog is authored separately in [azure-cost-checks.md](azure-cost-checks.md) (Advisor cost recommendations, month-to-date spend, unattached disks/IPs, stopped-but-not-deallocated VMs, VMSS over-provisioning, orphans). It never enters `score.categories`; every finding there is `points_recoverable: 0`.

## 3. Target profile

What 100/100 means per category (the checks above are this profile made executable): at least one enabled action group with a receiver a human reads, every enabled rule referencing one, and an observed delivery per receiver class (delivery proof is manual, AZR-001); every serving resource class under a metric alert, log-only signals under scheduled-query rules, and Service/Resource Health under activity-log alerts; serving VMs/VMSS with CPU alerts (guest memory/disk credited only with agent proof) and diagnostic settings to Log Analytics; AKS Container Insights on where container telemetry is expected, managed Prometheus matching the alerting plan, and control-plane logs in Log Analytics; a workspace receiving critical logs with deliberate retention; every serving edge with backend probes and diagnostic settings; and every rule carrying a severity, a responder-ready description, and a retest window.

## 4. Inventory (all categories)

Capture raw state once per run; later sections re-fetch specific objects before filing findings. The `nextLink` loop is shown once here and applies to every ARM list.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""
az account show --query '{subscription:id, tenant:tenantId, user:user.name}' -o json
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM="https://management.azure.com"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
mkdir -p "$RAW_DIR"

# Paginated ARM list -> a JSON array on stdout. $1 = full path+query (with api-version).
arm_list() {
  _next="${ARM}$1"; : > /tmp/az-page
  while [ -n "$_next" ]; do
    _resp="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${ARM_TOKEN}" "$_next")"
    printf '%s\n' "$_resp" | jq -c '.value[]?' >> /tmp/az-page
    _next="$(printf '%s' "$_resp" | jq -r '.nextLink // empty')"
  done
  jq -s '.' /tmp/az-page; rm -f /tmp/az-page
}

arm_list "/subscriptions/${SUB}/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01" \
  | jq '[.[] | {name, enabled: .properties.enabled,
      receivers: ((.properties | to_entries
        | map(select(.key | endswith("Receivers")))
        | map({(.key): (.value | length)}) | add) // {})}]' > "${RAW_DIR}/action-groups.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Insights/metricAlerts?api-version=2018-03-01" \
  | jq '[.[] | {name, enabled: .properties.enabled, severity: .properties.severity,
      scopes: .properties.scopes, windowSize: .properties.windowSize,
      actionGroups: [.properties.actions[]?.actionGroupId], description: .properties.description}]' > "${RAW_DIR}/metric-alerts.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Insights/scheduledQueryRules?api-version=2022-06-15" \
  | jq '[.[] | {name, enabled: .properties.enabled, severity: .properties.severity,
      scopes: .properties.scopes, actionGroups: (.properties.actions.actionGroups // []),
      windowSize: .properties.windowSize, description: .properties.description}]' > "${RAW_DIR}/scheduled-query-rules.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Insights/activityLogAlerts?api-version=2020-10-01" \
  | jq '[.[] | {name, enabled: .properties.enabled, scopes: .properties.scopes,
      categories: [.properties.condition.allOf[]? | select(.field=="category") | .equals],
      actionGroups: [.properties.actions.actionGroups[]?.actionGroupId]}]' > "${RAW_DIR}/activity-log-alerts.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" \
  | jq '[.[] | {name, id, location, vmSize: .properties.hardwareProfile.vmSize}]' > "${RAW_DIR}/vms.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Compute/virtualMachineScaleSets?api-version=2024-07-01" \
  | jq '[.[] | {name, id, location, sku: .sku.name, capacity: .sku.capacity}]' > "${RAW_DIR}/vmss.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.OperationalInsights/workspaces?api-version=2022-10-01" \
  | jq '[.[] | {name, id, location, retentionInDays: .properties.retentionInDays, sku: .properties.sku.name}]' > "${RAW_DIR}/log-workspaces.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Network/applicationGateways?api-version=2024-05-01" \
  | jq '[.[] | {name, id, location, probes: [.properties.probes[]?.name],
      backendPools: [.properties.backendAddressPools[]?.name]}]' > "${RAW_DIR}/app-gateways.json"
arm_list "/subscriptions/${SUB}/providers/Microsoft.Network/loadBalancers?api-version=2024-05-01" \
  | jq '[.[] | {name, id, location, sku: .sku.name, probes: [.properties.probes[]?.name],
      rules: [.properties.loadBalancingRules[]?.name]}]' > "${RAW_DIR}/load-balancers.json"
# AKS control-plane objects, one per cluster (az aks show is the confirmed AKS surface).
az aks list --query '[].{name:name, rg:resourceGroup, id:id}' -o json > "${RAW_DIR}/aks-list.json"
wc -l "${RAW_DIR}"/*.json 2>/dev/null || true
```

Expected: one file per surface, non-empty JSON arrays where the resources exist. An error naming a disabled resource provider (Compute, ContainerService, Network) on a subscription that genuinely has no such resource means the area is `not-in-scope` — declare it in the scorecard rather than failing the run. Any other `403` is a missing role (`Reader` + `Monitoring Reader` are the minimal read set); record it and mark the affected checks `blocked`. A `401` is a stale token — re-run the preamble.

## 5. Alert routing and delivery (AZR-001, AZR-004)

**AZR-001** — an enabled action group with a reachable receiver must exist, and enabled alert rules must reference one. An action group with `enabled: false` or zero receivers pages nobody.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Enabled action groups that actually carry ≥1 receiver (of any class). 0 is critical.
jq '[.[] | select(.enabled == true) | select(([.receivers[]?] | add // 0) > 0)] | length' "${RAW_DIR}/action-groups.json"
# Enabled metric/scheduled/activity rules that reference NO action group — one line per rule.
for f in metric-alerts scheduled-query-rules activity-log-alerts; do
  jq -r --arg f "$f" '.[] | select((.enabled // true) == true) | select((.actionGroups // [] | length) == 0) | "\($f): \(.name)"' \
    "${RAW_DIR}/${f}.json"
done
```

Healthy target: a positive count of enabled action groups with receivers, and no rule printed by the second command. **Delivery proof:** a listed action group proves configuration, not delivery. Cloud has no read-only "was this delivered" list, and the `test-notifications` POST is a mutation that pages a human — forbidden here. So without an observed past page (a screenshot or team confirmation, the documented manual exception), routing stays `configured` and AZR-001 scores `partial` at best. Finding: `AZR-001` naming the zero-receiver or unreferenced-rule affected objects; delivery-unproven stays `partial`.

**AZR-004** — activity-log alerts on Service Health, Resource Health, and critical Administrative/Security operations:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -r '[.[].categories[]?] | unique | "activity-log categories covered: \(.)"' "${RAW_DIR}/activity-log-alerts.json"
```

Healthy target: at least `ServiceHealth` and `ResourceHealth` categories present with an enabled rule wired to an action group; `Administrative`/`Security` coverage where the subscription hosts production. Finding: `AZR-004` naming the missing category — a subscription with no ServiceHealth alert learns of an Azure-side outage from customers, not from Azure.

Forbidden mutations (AZR-001/AZR-004): `az monitor action-group create|update|delete`, `az monitor action-group test-notifications create` (sends a real page), `az monitor activity-log alert create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.Insights/actionGroups` or `…/activityLogAlerts`.

## 6. Metric and scheduled-query alerts (AZR-002, AZR-003)

**AZR-002** — metric alert coverage per serving resource class. Compare `metricAlerts` scopes against the serving inventory (VMs, VMSS, App Gateways, Load Balancers, workspaces' resources):

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Every resource id currently under a metric alert.
jq -r '.[] | select((.enabled // true) == true) | .scopes[]?' "${RAW_DIR}/metric-alerts.json" | sort -u
# Serving resource ids that SHOULD have one (extend with your topology's critical resources).
jq -r '.[].id' "${RAW_DIR}/vms.json" "${RAW_DIR}/vmss.json" "${RAW_DIR}/app-gateways.json" "${RAW_DIR}/load-balancers.json" 2>/dev/null | sort -u
```

Healthy target: every serving resource id appears in the first list. Finding: `AZR-002` naming each serving resource with no metric alert — an unmonitored resource saturates silently.

**AZR-003** — scheduled-query (log) alerts for signals metrics can't express (specific error strings, query-derived counts). A rule with no `actionGroups` fires into a void:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -r '.[] | "\(.name): enabled=\(.enabled) scopes=\(.scopes|length) actionGroups=\((.actionGroups//[])|length) window=\(.windowSize // "?")"' \
  "${RAW_DIR}/scheduled-query-rules.json"
```

Healthy target: each critical log-derived signal from topology has an enabled rule scoped to the right workspace/resource and wired to an action group. Finding: `AZR-003` for a missing log-alert signal, or a rule with zero action groups (`partial`).

Forbidden mutations (AZR-002/AZR-003): `az monitor metrics alert create|update|delete`, `az monitor scheduled-query create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.Insights/metricAlerts` or `…/scheduledQueryRules`.

## 7. Empty/hidden-scope guardrail (AZR-007)

The visibility trip-wire — **LIVE-VALIDATED** on a live subscription that returned 0 action groups AND 0 metric alerts and correctly tripped `AZR-007-OBS` instead of scoring a confident 0.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
AG=$(jq 'length' "${RAW_DIR}/action-groups.json")
MA=$(jq 'length' "${RAW_DIR}/metric-alerts.json")
echo "action-groups=${AG} metric-alerts=${MA}"
if [ "$AG" -eq 0 ] && [ "$MA" -eq 0 ]; then
  echo "AZR-007 TRIP: 0 action groups AND 0 metric alerts despite a readable 200 -> blocked (visibility/scope gap), NOT a confident 0"
fi
```

Healthy target: not tripped (some alerting exists), or the trip is understood — alerting may live in a different subscription, the identity may see only a subset of scopes, or the resources genuinely are non-alert-bearing (the validation subscription held only Cognitive Services accounts). Finding: when both counts are zero despite a 200, file `AZR-007` with `status: blocked` and the reason "zero alerting despite readable API — confirm subscription scope and the identity's role assignments", never a scored 0. Reading `Microsoft.Authorization/roleAssignments` (**2022-04-01**) confirms whether the identity even holds Monitoring Reader on this scope.

Forbidden mutations (AZR-007): none beyond the global list — this is a pure read/count with no write surface.

## 8. VM / VMSS coverage (AZR-010)

Compute Engine exposes CPU natively; **guest memory and disk exist only where the Azure Monitor Agent (or legacy diagnostic extension) ships them** — the exact analogue of the GCP Ops Agent gate. Never credit memory/disk coverage until the agent extension proves present per VM.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM="https://management.azure.com"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"

# AZR-010 metric coverage: CPU metric alerts scoped to each VM/VMSS (from metric-alerts.json scopes, section 6).
# AZR-010 agent gate: the Azure Monitor Agent extension per VM. Compute api-version 2024-07-01 is confirmed; the /extensions child read was not itself exercised (no VMs in the validation sub) — confirm against your VM.
VM_ID="$(jq -r '.[0].id // empty' "${RAW_DIR}/vms.json")"
[ -n "$VM_ID" ] && curl -fsS --max-time 30 -H "Authorization: Bearer ${ARM_TOKEN}" \
  "${ARM}${VM_ID}/extensions?api-version=2024-07-01" \
  | jq -r '[.value[]?.name] | "extensions on this VM: \(.)"'

# AZR-010 diagnostic routing: diagnostic settings are read via the CLI (the diagnosticSettings ARM
# api-version is NOT confirmed in the report). A failure here is blocked, never a guessed api-version.
[ -n "$VM_ID" ] && az monitor diagnostic-settings list --resource "$VM_ID" -o json 2>/tmp/ds-err \
  | jq -r '[.value[]? | {name, workspaceId: .workspaceId}]' \
  || echo "AZR-010 diagnostic-settings read blocked: $(cat /tmp/ds-err)"
```

Healthy target: every serving VM/VMSS has a CPU metric alert (AZR-002 supplies the scope list); `AzureMonitorLinuxAgent`/`AzureMonitorWindowsAgent` present on any VM whose coverage claims memory/disk; a diagnostic setting routing platform logs to a Log Analytics workspace. Finding: `AZR-010` naming VMs with no CPU alert, VMs whose memory/disk coverage is unproven because the agent is absent (false confidence), or serving VMs with no diagnostic setting. Report a diagnostic-settings permission error as `blocked`.

Forbidden mutations (AZR-010): `az vm create|delete|start|stop|deallocate|restart|resize|update`, `az vmss …` mutations, `az vm extension set|delete`, `az monitor diagnostic-settings create|update|delete`.

## 9. AKS coverage (AZR-030, AZR-031, AZR-032)

Read from the control-plane object `az aks show` returns — the property paths below are **confirmed** in the validation report (create→validate→delete of a real Entra cluster). Run once per cluster from `aks-list.json`.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -c '.[]' "${RAW_DIR}/aks-list.json" | while read -r c; do
  NAME="$(printf '%s' "$c" | jq -r .name)"; RG="$(printf '%s' "$c" | jq -r .rg)"; ID="$(printf '%s' "$c" | jq -r .id)"
  # AZR-030 Container Insights + AZR-031 managed Prometheus, straight off the control plane.
  az aks show -n "$NAME" -g "$RG" -o json \
    | jq -r '{
        container_insights: (.addonProfiles.omsagent.enabled // false),
        oms_workspace: (.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID // null),
        managed_prometheus: (.azureMonitorProfile.metrics.enabled // false),
        entra_managed: (.aadProfile.managed // false),
        entra_rbac: (.aadProfile.enableAzureRbac // false)
      } | "\('"$NAME"'): \(.)"'
  # AZR-032 control-plane diagnostic logs -> Log Analytics (diagnosticSettings via CLI; api-version unconfirmed).
  az monitor diagnostic-settings list --resource "$ID" -o json 2>/tmp/aks-ds-err \
    | jq -r '[.value[]? | {name, workspaceId}] | "\('"$NAME"'") diag-settings: \(.)"' \
    || echo "AZR-032 blocked for ${NAME}: $(cat /tmp/aks-ds-err)"
done
```

Healthy targets and findings:

- **AZR-030** — `addonProfiles.omsagent.enabled == true` (and `.config.logAnalyticsWorkspaceResourceID` set) on any cluster expected to ship container logs/metrics; when off the addon is **absent/null** (confirmed shape). Finding: `AZR-030` naming clusters with Container Insights off — no container-level telemetry.
- **AZR-031** — `azureMonitorProfile.metrics.enabled == true` where the alerting plan expects workload Prometheus metrics; when off `azureMonitorProfile` is **absent/null** (confirmed). `true` with no consuming rules is an unused engine (info); `false` where alerting expects it is the finding.
- **AZR-032** — a diagnostic setting on the cluster ID routing control-plane logs (`kube-apiserver`, `kube-audit`, …) to a Log Analytics workspace. Finding: `AZR-032` when none exists (control-plane failures leave no queryable trail); a permission error is `blocked`, never a guessed api-version.

If the in-cluster stack (Prometheus, Alertmanager, Grafana) is the primary alerting plane, mark the overlapping AKS checks `not-in-scope`, run `/scoutflo:audit-lgtm` against it, and state the split.

Forbidden mutations (AZR-030/031/032): `az aks create|update|delete|scale|upgrade`, `az aks enable-addons|disable-addons`, `az aks get-credentials` (writes a kubeconfig — not needed for a control-plane read), `az monitor diagnostic-settings create|update|delete`.

## 10. Log Analytics coverage and retention (AZR-040)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -r '.[] | "\(.name): retentionInDays=\(.retentionInDays // "unset") sku=\(.sku // "?")"' "${RAW_DIR}/log-workspaces.json"
```

Healthy target: at least one workspace exists (the AZR-030/032/010 diagnostic destinations point at it), and every workspace receiving critical-service logs has a `retentionInDays` that is a deliberate decision, not the 30-day default — a short retention ages evidence out before anyone investigates (mirrors `AWS-051`/`DO-051`/`GCP-054`). The data-plane read path (`az monitor log-analytics query`, audience `https://api.loganalytics.io`, needs the `log-analytics` az extension) is confirmed and can prove a critical table has recent rows. Finding: `AZR-040` for no workspace at all (critical), or a critical-log workspace on an unexamined default retention (record the actual number).

Forbidden mutations (AZR-040): `az monitor log-analytics workspace create|update|delete`, `az monitor log-analytics workspace update --retention-time`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.OperationalInsights/workspaces`.

## 11. App Gateway / Load Balancer coverage (AZR-050)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Backend health probes present? (from the CONFIRMED 2024-05-01 captures)
jq -r '.[] | "appgw \(.name): probes=\(.probes|length) backendPools=\(.backendPools|length)"' "${RAW_DIR}/app-gateways.json"
jq -r '.[] | "lb \(.name) [\(.sku)]: probes=\(.probes|length) rules=\(.rules|length)"' "${RAW_DIR}/load-balancers.json"
```

Then, per serving App Gateway / Load Balancer, read its diagnostic settings by resource id (diagnostic-settings CLI — api-version unconfirmed, so CLI is the pinned surface):

```bash
set -eu
RESOURCE_ID="/subscriptions/.../providers/Microsoft.Network/applicationGateways/your-agw"   # each serving edge resource id
az monitor diagnostic-settings list --resource "$RESOURCE_ID" -o json 2>/tmp/edge-ds-err \
  | jq -r '[.value[]? | {name, workspaceId}]' \
  || echo "AZR-050 diagnostic-settings read blocked: $(cat /tmp/edge-ds-err)"
```

Healthy target: every serving App Gateway/Load Balancer has ≥1 backend health probe (a rule referencing none cannot eject a bad backend) **and** a diagnostic setting routing access/performance logs to Log Analytics. **A health probe keeps traffic off a bad backend; it pages nobody** — probe presence and alert coverage (AZR-002) are different systems; presence of one never scores the other. Finding: `AZR-050` naming edges with zero probes or no diagnostic setting; a permission error is `blocked`.

Forbidden mutations (AZR-050): `az network application-gateway create|update|delete` (and its `probe`/`rule` subcommands), `az network lb create|update|delete` (and its `probe`/`rule` subcommands), `az monitor diagnostic-settings create|update|delete`.

## 12. Alert quality (AZR-060)

Every metric, scheduled-query, and activity-log rule should carry a severity, a responder-ready description, and (for metric/query rules) a retest window rather than firing on a single evaluation.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Metric + scheduled-query rules with a thin/absent description or no window.
for f in metric-alerts scheduled-query-rules; do
  jq -r --arg f "$f" '.[] | select((.enabled // true) == true)
    | select(((.description // "") | length) < 40 or (.windowSize == null))
    | "\($f): \(.name) severity=\(.severity // "unset") window=\(.windowSize // "unset") desc_len=\((.description // "") | length)"' \
    "${RAW_DIR}/${f}.json"
done
```

Healthy target: no output. `severity` (Azure uses 0=critical … 4=verbose) present on every rule; a description that names the resource, the threshold, and the first datapoints to capture; a `windowSize` long enough that a single scrape blip does not page. The length cut is a screen, not the judgment — read what remains and fail a description that names no resource or no capture list. "Service down" alone tells a 3am responder nothing. Finding: `AZR-060` listing rules missing a severity, a real description, or a retest window; single-tier saturation-only alerts on volatile metrics are the judgment call — note the metric's volatility rather than failing on the number.

Forbidden mutations (AZR-060): none beyond the global list — this is a pure read of already-captured rule objects.

## 13. Per-service coverage rows

Assemble one row per critical service from the raw captures; re-fetch any cell you are about to fail. Cell vocabulary is `pass`, `partial`, `fail`, `blocked`, `not-in-scope`, each carrying its `passed/total` denominator. Map VMs, VMSS, AKS workloads, and edge resources to canonical service names via topology.md when present. The `Routing` cell folds AZR-001/AZR-004; a `Logs` cell reaches `pass` only with a workspace that has deliberate retention (AZR-040) and a diagnostic setting routing this service's logs to it.

## 14. Commands this audit must never run

Any of these in an audit transcript is a lane violation, whatever the justification. The audit passes explicit reads only; every recommendation names the Portal/`az` path for a human to run under change control in `setup-azure`.

- **Alerting:** `az monitor action-group create|update|delete`, `az monitor action-group test-notifications create` (sends a real page), `az monitor metrics alert create|update|delete`, `az monitor scheduled-query create|update|delete`, `az monitor activity-log alert create|update|delete`, `az monitor diagnostic-settings create|update|delete`.
- **Observability stores:** `az monitor log-analytics workspace create|update|delete` (including `--retention-time`), `az monitor log-analytics cluster` mutations.
- **AKS:** `az aks create|update|delete|scale|upgrade`, `az aks enable-addons|disable-addons`, `az aks get-credentials` (writes a kubeconfig — control-plane `az aks show` is the read path).
- **Compute / network:** any `az vm` / `az vmss` mutation (`create|delete|start|stop|deallocate|restart|resize|update`, `extension set|delete`), any `az network application-gateway` / `az network lb` mutation.
- **Identity:** `az role assignment create|delete` (the audit reads `roleAssignments` at 2022-04-01, never writes one).
- **Any REST verb other than GET** against `management.azure.com` — no `PUT`, `PATCH`, `DELETE`, and no POST except the two `readOnly` query endpoints used by the cost catalog (Resource Graph `2022-10-01`, Cost Management `2023-11-01`); the action-group `test-notifications` POST is never run.
- **Any POST to a webhook**, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`.
