# audit-azure: Check Catalog and Commands

Runnable, strictly read-only checks for every scored surface the [audit-azure](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the exact read command (an `az` read or an ARM REST GET pinned to an api-version **confirmed on a live 200 read**), the healthy target, the finding it emits, and its forbidden-mutations. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. The non-scored Cost & Resource Optimization catalog (`AZROPT-NNN`) lives in its own file, [azure-cost-checks.md](azure-cost-checks.md); this file is the scored reliability axis (`AZR-NNN`).

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
| AZR-002 | Alert coverage (metric, log, activity) | Every serving resource class has a metric alert on its saturation/error signals | `Microsoft.Insights/metricAlerts` (**2018-03-01**) | high |
| AZR-003 | Alert coverage (metric, log, activity) | Log-based signals metrics can't express are covered by scheduled-query rules wired to an action group | `Microsoft.Insights/scheduledQueryRules` (**2022-06-15**) | high |
| AZR-004 | Alert coverage (metric, log, activity) | Service Health, Resource Health, and critical admin/security operations page someone | `Microsoft.Insights/activityLogAlerts` (**2020-10-01**) | medium |
| AZR-005 | Alert routing and delivery | No enabled alert-processing (suppression) rule with `RemoveAllActionGroups` mutes a live critical scope | `az monitor alert-processing-rule list` / `Microsoft.AlertsManagement/actionRules` (**2021-08-08, verify-pending**) | critical |
| AZR-007 | Alert routing and delivery | 0 action groups AND 0 metric alerts despite a readable 200 is `blocked` (visibility/scope gap), not a confident 0 | actionGroups + metricAlerts | critical |
| AZR-010 | Compute VM/VMSS coverage | Serving VMs/VMSS carry CPU metric alerts; guest memory/disk claimed only with agent proof; diagnostic settings route to Log Analytics | `Microsoft.Compute/virtualMachines`, `…/virtualMachineScaleSets` (**2024-07-01**) + diagnostic-settings CLI | high |
| AZR-030 | AKS coverage | `addonProfiles.omsagent.enabled == true` on serving clusters | `az aks show` (control plane) | high |
| AZR-031 | AKS coverage | `azureMonitorProfile.metrics.enabled` matches where workload alerting is expected | `az aks show` (control plane) | medium |
| AZR-032 | AKS coverage | AKS control-plane logs routed to Log Analytics via a diagnostic setting | diagnostic-settings CLI on the cluster ID | high |
| AZR-033 | AKS coverage | A managed-Prometheus cluster (`azureMonitorProfile.metrics.enabled`) has ≥1 `prometheusRuleGroups` referencing its Azure Monitor workspace — metrics collected but zero rule groups means nothing alerts on them | `Microsoft.AlertsManagement/prometheusRuleGroups` (**2023-03-01, verify-pending**) | medium |
| AZR-040 | Log Analytics coverage | A workspace exists, receives critical-service logs, and its retention is a deliberate decision | `Microsoft.OperationalInsights/workspaces` (**2022-10-01**) | high |
| AZR-041 | Log Analytics coverage | A workspace that is a diagnostic destination is still ingesting (newest `Heartbeat`/critical tables within the staleness window) — a configured-but-dead sink invalidates every downstream diagnostic setting | `az monitor log-analytics query` (Log Analytics data plane, **verify-pending**) | high |
| AZR-042 | Log Analytics coverage | Subscription-scope diagnostic settings export `Administrative`/`Security`/`Policy` activity-log categories to a workspace, so control-plane events are retained and queryable | `az monitor diagnostic-settings subscription list` (**verify-pending**) | medium |
| AZR-050 | Load balancer / App Gateway coverage | Every serving App Gateway/Load Balancer has backend health probes and diagnostic settings enabled | `Microsoft.Network/applicationGateways`, `…/loadBalancers` (**2024-05-01**) + diagnostic-settings CLI | high |
| AZR-060 | Alert quality | Every alert rule carries a severity, a responder-ready description, and a retest window | actionGroups + metric/scheduled/activity rules | medium |

Non-scored: **AZROPT-NNN** — the Cost & Resource Optimization catalog is authored separately in [azure-cost-checks.md](azure-cost-checks.md) (Advisor cost recommendations, month-to-date spend, unattached disks/IPs, stopped-but-not-deallocated VMs, VMSS over-provisioning, orphans). It never enters `score.categories`; every finding there is `points_recoverable: 0`.

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
# The blast-radius join: an enabled rule ALL of whose referenced groups have 0 receivers is MUTE
# even though it references a group. Build the set of receiver-less action-group names, then find
# enabled rules that terminate only at those groups and name their scopes (map to topology services).
RECEIVERLESS="$(jq -c '[.[] | select(([.receivers[]?] | add // 0) == 0 or .enabled == false) | .name]' "${RAW_DIR}/action-groups.json")"
for f in metric-alerts scheduled-query-rules activity-log-alerts; do
  jq -r --arg f "$f" --argjson dead "$RECEIVERLESS" '.[] | select((.enabled // true) == true)
    | (.actionGroups // []) as $ags | select(($ags | length) > 0)
    | select([$ags[] | (split("/") | last) as $n | ($dead | index($n))] | all(. != null))
    | "MUTE-ROUTE \($f): \(.name) scopes=\(.scopes // []) -> only receiver-less groups"' \
    "${RAW_DIR}/${f}.json" 2>/dev/null || true
done
```

Healthy target: a positive count of enabled action groups with receivers, no rule printed by the second command, and no `MUTE-ROUTE` line from the join. Don't stop at "an action group with 0 receivers pages nobody" — compute the join and name who is left mute: *"N enabled alert rules covering `checkout-vm-1`, `payments-sql`, `appgw-prod` all terminate at action group `ops-catchall`, which has 0 enabled receivers → those 3 critical services fire alerts into a void."* The number is `|rules whose groups are all receiver-less|` and the named set is their resolved scopes mapped to topology service names. This chains with AZR-002/AZR-010/AZR-050 (a metric alert that EXISTS but routes to a dead group is false confidence, not coverage — cite the AZR-002 pass it invalidates) and with AZR-005 (a live receiver whose delivery is suppressed). **Delivery proof:** a listed action group proves configuration, not delivery. Cloud has no read-only "was this delivered" list, and the `test-notifications` POST is a mutation that pages a human — forbidden here. So without an observed past page (a screenshot or team confirmation, the documented manual exception), routing stays `configured` and AZR-001 scores `partial` at best. Finding: `AZR-001` naming the zero-receiver, unreferenced-rule, or mute-route affected objects with their resolved scopes; delivery-unproven stays `partial`. Verify: re-list `actionGroups` at `2023-01-01`, confirm the named group reports ≥1 enabled receiver, and re-run the join so 0 rules terminate receiver-less.

**AZR-004** — activity-log alerts on Service Health, Resource Health, and critical Administrative/Security operations:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -r '[.[].categories[]?] | unique | "activity-log categories covered: \(.)"' "${RAW_DIR}/activity-log-alerts.json"
```

Healthy target: at least `ServiceHealth` and `ResourceHealth` categories present with an enabled rule wired to an action group; `Administrative`/`Security` coverage where the subscription hosts production. Finding: `AZR-004` naming the missing category — a subscription with no ServiceHealth alert learns of an Azure-side outage from customers, not from Azure.

Forbidden mutations (AZR-001/AZR-004): `az monitor action-group create|update|delete`, `az monitor action-group test-notifications create` (sends a real page), `az monitor activity-log alert create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.Insights/actionGroups` or `…/activityLogAlerts`.

### 5.1 Alert-processing (suppression) rules (AZR-005)

> **Verify-pending.** Drafted against Azure's documented `az monitor alert-processing-rule` / `Microsoft.AlertsManagement/actionRules` surface and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token (see the doctor gate). No Azure estate exists in the benchmark, so the `actionRules` api-version (**2021-08-08**), the `RemoveAllActionGroups` action type, and the property paths below are from Azure's public API docs, not confirmed against a live subscription here; carry the caveat and record the check `blocked` until the api-version returns a live 200.

**AZR-005** — an *enabled* alert-processing rule whose action is `RemoveAllActionGroups` suppresses delivery for every alert in its scope. This is the exact failure AZR-001 cannot see: the action groups have receivers and the rules reference them (AZR-001 passes), but a suppression rule silently swallows the notification between "rule fires" and "page leaves Azure". A rule scoped at a subscription or a production resource group, enabled, with no end schedule, is a permanent estate-wide mute.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# List alert-processing rules; capture enabled state, action types, scopes, and schedule only.
# If the CLI extension is absent, the ARM GET below is the equivalent read (api-version verify-pending).
az monitor alert-processing-rule list --subscription "$SUB" -o json 2>/tmp/apr-err \
  | jq '[.[] | {name, enabled: .properties.enabled,
      actionTypes: [.properties.actions[]?.actionType],
      scopes: .properties.scopes,
      schedule: (.properties.schedule // null)}]' > "${RAW_DIR}/alert-processing-rules.json" \
  || echo "AZR-005 blocked: $(cat /tmp/apr-err 2>/dev/null) — try ARM GET /subscriptions/${SUB}/providers/Microsoft.AlertsManagement/actionRules?api-version=2021-08-08 and record the api-version that returns 200"
# Flag enabled RemoveAllActionGroups rules; the analyst intersects each scope with the resource
# groups that hold critical resources (topology.md) to name the muted services.
jq -r '.[] | select(.enabled == true)
  | select([.actionTypes[]?] | index("RemoveAllActionGroups"))
  | "SUPPRESSION \(.name): scopes=\(.scopes) schedule=\(.schedule // "permanent (no schedule)")"' \
  "${RAW_DIR}/alert-processing-rules.json" 2>/dev/null || true
```

Healthy target: no enabled `RemoveAllActionGroups` rule whose scope covers a production resource group without a bounded maintenance schedule. Blast radius is computed, not asserted: intersect each flagged rule's `scopes[]` with the resource groups holding critical resources and name them — *"alert-processing rule `maint-suppress` is enabled, action `RemoveAllActionGroups`, scope = `rg-prod`, no end schedule → every alert on all critical resources in `rg-prod` is suppressed at delivery; the rules fire, no page leaves Azure."* Finding: `AZR-005` (critical) naming the rule, its scope, and the muted critical services; it negates the AZR-001 routing pass and every AZR-002/003/004 coverage pass whose scope falls inside the suppression scope. Remediation: `setup-azure#review-alert-processing-rules`.

Forbidden mutations (AZR-005): `az monitor alert-processing-rule create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.AlertsManagement/actionRules`.

## 6. Metric and scheduled-query alerts (AZR-002, AZR-003)

**AZR-002** — metric alert coverage per serving resource class. Compare `metricAlerts` scopes against the serving inventory (VMs, VMSS, App Gateways, Load Balancers, workspaces' resources):

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Every resource id currently under an ENABLED metric alert.
jq -r '.[] | select((.enabled // true) == true) | .scopes[]?' "${RAW_DIR}/metric-alerts.json" | sort -u
# Phantom coverage: resource ids whose ONLY metric alert is enabled:false. Inventory shows a rule,
# so a scanner reads these as "covered" while the rule can never fire — the "someone silenced it in
# an incident and never re-enabled it" signal. These must NOT be conflated with "no rule at all".
jq -r '[.[] | select((.enabled // true) == false) | .scopes[]?] as $disabled
  | [.[] | select((.enabled // true) == true) | .scopes[]?] as $enabled
  | ($disabled - $enabled) | unique | .[] | "DISABLED-ONLY: \(.)"' "${RAW_DIR}/metric-alerts.json"
# Serving resource ids that SHOULD have one (extend with your topology's critical resources).
jq -r '.[].id' "${RAW_DIR}/vms.json" "${RAW_DIR}/vmss.json" "${RAW_DIR}/app-gateways.json" "${RAW_DIR}/load-balancers.json" 2>/dev/null | sort -u
```

Healthy target: every serving resource id appears in the first (enabled) list and the DISABLED-ONLY list is empty. Split the misses into two named buckets, never one generic "saturates silently":

- **Bucket (a) — no rule at all:** the serving resource id is absent from every metric alert. Name the resource and the signal that would have fired — *"`checkout-vm-1` has no CPU/availability metric alert; a saturation event pages nobody."* Fix: add a two-tier (warning/critical) metric alert scoped to that resource id (`setup-azure#add-metric-alerts`).
- **Bucket (b) — rule present but `enabled:false`:** *"`payments-sql` HAS rule `sql-dtu-critical` but it is `enabled:false` — inventory shows a rule, so this reads as covered while firing never."* Fix is cheaper: re-enable the existing rule, not author a new one — name which. This chains with AZR-001 (a covered resource whose rule routes to a dead group is doubly blind) and AZR-005 (a rule whose delivery is suppressed).

Finding: `AZR-002` (high) naming each resource in each bucket and, for bucket (b), the exact rule to re-enable. Verify by re-reading `metricAlerts` at `2018-03-01`: each named resource id appears in an enabled rule's `scopes[]`, and (bucket b) `properties.enabled == true`.

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
  | jq -r '[.[]? | {name, workspaceId: .workspaceId}]' \
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
    | jq -r '[.[]? | {name, workspaceId}] | "\('"$NAME"'") diag-settings: \(.)"' \
    || echo "AZR-032 blocked for ${NAME}: $(cat /tmp/aks-ds-err)"
done
```

Healthy targets and findings:

- **AZR-030** — `addonProfiles.omsagent.enabled == true` (and `.config.logAnalyticsWorkspaceResourceID` set) on any cluster expected to ship container logs/metrics; when off the addon is **absent/null** (confirmed shape). Don't stop at "Container Insights off": join the cluster to the critical workloads scheduled on it (topology.md) and name what goes dark — *"cluster `aks-prod` runs `checkout`, `orders`, `payments` per topology; with Container Insights off and no in-cluster Loki, a pod OOM/crashloop tonight leaves ZERO container stdout/stderr or per-container metrics in Log Analytics — the responder has only control-plane events."* Chains with AZR-032 (control-plane logs also absent = fully blind cluster) and AZR-041 (even if on, the destination workspace must be ingesting). Where the in-cluster stack owns the plane, mark `not-in-scope` and state the split rather than double-count. Finding: `AZR-030` (high) naming the blind critical workloads. Verify: re-run `az aks show`, `addonProfiles.omsagent.enabled == true` and `config.logAnalyticsWorkspaceResourceID` resolves to a workspace AZR-041 shows ingesting.
- **AZR-031** — `azureMonitorProfile.metrics.enabled == true` where the alerting plan expects workload Prometheus metrics; when off `azureMonitorProfile` is **absent/null** (confirmed). `false` where alerting expects it is the finding; `true` with no consuming rules is not merely an info note — it is scored as **AZR-033** (see 9.1).
- **AZR-032** — a diagnostic setting on the cluster ID routing control-plane logs (`kube-apiserver`, `kube-audit`, `kube-controller-manager`, `kube-scheduler`, …) to a Log Analytics workspace. Name the incident it blinds, not the missing object: *"`aks-prod` control-plane logs go nowhere — an apiserver throttle, an admission-webhook failure, or an RBAC denial that stalls deploys has no queryable record; the on-call reconstructs from memory."* Name the cluster and which log categories are unrouted (confirm categories with `az monitor diagnostic-settings categories list`, never a guessed api-version). Chains with AZR-030 (both off = totally blind cluster) and AZR-040/AZR-041 (the destination must be retained and live). Finding: `AZR-032` (high) when none exists; a permission error is `blocked`, never a guessed api-version.

If the in-cluster stack (Prometheus, Alertmanager, Grafana) is the primary alerting plane, mark the overlapping AKS checks `not-in-scope`, run `/scoutflo:audit-lgtm` against it, and state the split.

Forbidden mutations (AZR-030/031/032): `az aks create|update|delete|scale|upgrade`, `az aks enable-addons|disable-addons`, `az aks get-credentials` (writes a kubeconfig — not needed for a control-plane read), `az monitor diagnostic-settings create|update|delete`.

### 9.1 Managed Prometheus with no consuming rule groups (AZR-033)

> **Verify-pending.** Drafted against Azure's documented `Microsoft.AlertsManagement/prometheusRuleGroups` surface and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token (see the doctor gate). No Azure estate exists in the benchmark, so the `prometheusRuleGroups` api-version (**2023-03-01**) is NOT in the confirmed set and the property paths below are from Azure's public API docs; carry the caveat and record the check `blocked` until the api-version returns a live 200.

**AZR-033** — a cluster with `azureMonitorProfile.metrics.enabled == true` (AZR-031 pass) is collecting and being billed for managed-Prometheus metrics; if **zero** `prometheusRuleGroups` reference that cluster's Azure Monitor workspace, not a single alert or recording rule evaluates them. Metrics collected ≠ metrics alerted-on — this is the alerting-plane extension AZR-031 never performs.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM="https://management.azure.com"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# List Prometheus rule groups (api-version verify-pending: 2023-03-01, not in the confirmed set).
curl -fsS --max-time 30 -H "Authorization: Bearer ${ARM_TOKEN}" \
  "${ARM}/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01" 2>/tmp/prg-err \
  | jq '[.value[]? | {name, enabled: .properties.enabled, scopes: .properties.scopes,
      rules: ([.properties.rules[]?] | length)}]' > "${RAW_DIR}/prometheus-rule-groups.json" \
  || echo "AZR-033 blocked: prometheusRuleGroups read failed — confirm the api-version on a live 200 before scoring"
# The scopes[] each rule group targets (Azure Monitor workspace resource ids); cross-reference against
# clusters whose azureMonitorProfile.metrics.enabled==true (AZR-031) to find engines with no consumer.
jq -r '[.[].scopes[]?] | unique | "prometheusRuleGroups target scopes: \(.)"' "${RAW_DIR}/prometheus-rule-groups.json" 2>/dev/null || true
```

Healthy target: every managed-Prometheus cluster's Azure Monitor workspace appears in at least one `prometheusRuleGroups` `scopes[]`. Blast radius, named: *"`aks-prod` ships managed-Prometheus metrics to its Azure Monitor workspace, but zero `prometheusRuleGroups` reference it — a pod-level saturation or SLO burn generates data nobody is paged on."* Chains with AZR-031 (engine on) and AZR-005/AZR-001 (any rule groups that DO exist must still route to a live, unsuppressed action group). Finding: `AZR-033` (medium). Remediation: `setup-azure#add-prometheus-rule-groups`.

Forbidden mutations (AZR-033): any `PUT`/`PATCH`/`DELETE` on `Microsoft.AlertsManagement/prometheusRuleGroups`.

## 10. Log Analytics coverage and retention (AZR-040, AZR-041, AZR-042)

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
jq -r '.[] | "\(.name): retentionInDays=\(.retentionInDays // "unset") sku=\(.sku // "?")"' "${RAW_DIR}/log-workspaces.json"
```

**AZR-040** — this workspace is the single evidence plane every diagnostic route depends on; tie retention to MTTR, not hygiene. Compute the fan-in: for each workspace named as a diagnostic destination by AZR-010/030/032/050, count the critical resources routing to it and state what ages out — *"workspace `la-prod` is the diagnostic sink for 6 VMs, 2 AKS clusters, and 3 edges, and `retentionInDays=30` → any investigation older than a month has no logs, and a multi-week regression cannot be reconstructed."* Blast radius = the count of critical resources whose evidence ages out, from the diagnostic-settings fan-in, not "retention is short". Healthy target: at least one workspace exists (the AZR-030/032/010 diagnostic destinations point at it), and every workspace receiving critical-service logs has a `retentionInDays` matched to the longest realistic investigation window, not the 30-day default (mirrors `AWS-051`/`DO-051`/`GCP-054`). Gated by AZR-041 — a long retention on a workspace that stopped ingesting is retention over nothing. Finding: `AZR-040` for no workspace at all (critical), or a critical-log workspace on an unexamined default retention (record the actual number and the fan-in count). Remediation: `setup-azure#enable-diagnostic-settings`.

Forbidden mutations (AZR-040): `az monitor log-analytics workspace create|update|delete`, `az monitor log-analytics workspace update --retention-time`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.OperationalInsights/workspaces`.

### 10.1 Workspace has stopped ingesting (AZR-041)

> **Verify-pending.** Drafted against Azure's confirmed Log Analytics data-plane read (`az monitor log-analytics query`, audience `https://api.loganalytics.io`, `log-analytics` az extension) and adversarially reviewed, but the staleness-detection join has NOT been run against a live tenant — status unproven until a first live run with a read-only token (see the doctor gate). The `Heartbeat`/table-recency queries below are documented KQL; the illustrative values are template examples, not asserted observations.

**AZR-041** — a workspace can be a configured diagnostic destination (AZR-030/032/050 all "pass") while the agent/DCR that feeds it has stopped, so every downstream diagnostic setting points at a dead sink. Config presence (AZR-040) is not ingestion; this is the data-plane recency half.

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
STALE_HOURS="24"   # example: ingestion older than this = stale; tune to the workspace's slowest table
WS_ARM_ID="/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/your-ws"  # each workspace that is a diagnostic destination
# Resolve the workspace GUID (customerId), then the data-plane recency reads.
WS_CUSTOMER_ID="$(az monitor log-analytics workspace show --ids "$WS_ARM_ID" --query customerId -o tsv 2>/tmp/ws-err || true)"
if [ -n "$WS_CUSTOMER_ID" ]; then
  # Newest Heartbeat per computer — anything older than STALE_HOURS stopped reporting.
  az monitor log-analytics query --workspace "$WS_CUSTOMER_ID" \
    --analytics-query "Heartbeat | summarize LastSeen=max(TimeGenerated) by Computer" -o json 2>/tmp/la-err \
    | jq -r '.[] | "\(.Computer): last Heartbeat \(.LastSeen)"' \
    || echo "AZR-041 blocked: $(cat /tmp/la-err 2>/dev/null) — install the log-analytics az extension, or the identity lacks Log Analytics Reader"
  # Per-table freshness for the critical tables AZR-030/032/050 route into.
  az monitor log-analytics query --workspace "$WS_CUSTOMER_ID" \
    --analytics-query "union withsource=T * | summarize Last=max(TimeGenerated) by T | order by Last asc" -o json 2>/dev/null \
    | jq -r '.[] | "\(.T): last row \(.Last)"' || true
else
  echo "AZR-041 blocked: $(cat /tmp/ws-err 2>/dev/null || echo 'workspace customerId unresolved')"
fi
```

Healthy target: newest `Heartbeat` (and the tables the critical resources route into) are within `STALE_HOURS`. Blast radius = the set of critical resources whose logs silently stopped landing, from the fan-in join: *"`la-prod` is the sink for 2 AKS clusters and 3 edges, but its newest `Heartbeat` is 6 days old and `ContainerLog` has no rows since — every downstream diagnostic setting points at a dead workspace and every AZR-030/032/050 pass is coverage on paper."* Finding: `AZR-041` (high) — invalidates AZR-030/032/050/040 for any resource routing to the stale workspace, and is the evidence-plane half of the flagship chain. Remediation: `setup-azure#investigate-log-ingestion`.

Forbidden mutations (AZR-041): the data-plane query is read-only (`az monitor log-analytics query`); never `az monitor log-analytics workspace` writes.

### 10.2 Activity Log never exported (AZR-042)

> **Verify-pending.** Drafted against Azure's documented `az monitor diagnostic-settings subscription list` read and adversarially reviewed, but NOT run against a live tenant — status unproven until a first live run with a read-only token (see the doctor gate). The subscription-scope diagnostic-settings shape below is from Azure's public API docs, not confirmed against a live subscription here.

**AZR-042** — distinct from AZR-004 (which is whether activity-log *alerts* page): this is whether the events are *retained and queryable at all*. If the subscription-scope diagnostic settings export no `Administrative`/`Security`/`Policy` categories to a workspace, control-plane events (who deleted the alert rule, who changed the NSG, a resource-health transition) live only ~90 days in the platform log and are not queryable/correlatable in Log Analytics.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
# Subscription-scope diagnostic settings: is the Activity Log exported to a workspace?
az monitor diagnostic-settings subscription list --subscription "$SUB" -o json 2>/tmp/sub-ds-err \
  | jq '[.value[]? | {name, workspaceId: .properties.workspaceId,
      categories: [.properties.logs[]? | select(.enabled) | .category]}]' > "${RAW_DIR}/subscription-diagnostic-settings.json" \
  || echo "AZR-042 blocked: $(cat /tmp/sub-ds-err 2>/dev/null)"
jq -r 'if (length == 0) then "AZR-042: subscription Activity Log is NOT exported (no diagnostic settings)"
  else (.[] | "\(.name): workspace=\(.workspaceId // "none") categories=\(.categories)") end' \
  "${RAW_DIR}/subscription-diagnostic-settings.json" 2>/dev/null || true
```

Healthy target: at least one subscription diagnostic setting routes `Administrative`/`Security`/`Policy` to a workspace. Blast radius = the categories with no durable, queryable record — the forensic trail an incident review needs after a config-change-induced outage. Complements AZR-004 (events *page* vs events *retained*) and lands in the same workspace whose retention/ingestion AZR-040/AZR-041 judge. Finding: `AZR-042` (medium). Remediation: `setup-azure#enable-diagnostic-settings`.

Forbidden mutations (AZR-042): `az monitor diagnostic-settings subscription create|update|delete`, any `PUT`/`PATCH`/`DELETE` on subscription-scope `Microsoft.Insights/diagnosticSettings`.

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
  | jq -r '[.[]? | {name, workspaceId}]' \
  || echo "AZR-050 diagnostic-settings read blocked: $(cat /tmp/edge-ds-err)"
```

Healthy target: every serving App Gateway/Load Balancer has ≥1 backend health probe (a rule referencing none cannot eject a bad backend) **and** a diagnostic setting routing access/performance logs to Log Analytics. **A health probe keeps traffic off a bad backend; it pages nobody** — probe presence and alert coverage (AZR-002) are different systems; presence of one never scores the other. Name the all-backends-down page-nobody scenario per edge rather than "zero probes": *"`appgw-prod` fronts backend pool `checkout-pool` with 0 health probes and 0 diagnostic settings; if all backends 5xx, traffic is still routed and nobody is paged."* State the edge, its pool, and whether AZR-002 has any metric alert on its `BackendConnectTime`/`UnhealthyHostCount`. Chains with AZR-002 (no metric alert on the edge's unhealthy-host/latency signal) and AZR-040/AZR-041 (logs must land in a live, retained workspace to be queryable). Finding: `AZR-050` naming the edge, its pool, the missing probe/diagnostic setting, and the metric-alert gap; a permission error is `blocked`. The diagnostic-settings half is a monitoring-plane fix (`setup-azure#enable-diagnostic-settings`); probe edits are traffic-impacting and plan-only.

Forbidden mutations (AZR-050): `az network application-gateway create|update|delete` (and its `probe`/`rule` subcommands), `az network lb create|update|delete` (and its `probe`/`rule` subcommands), `az monitor diagnostic-settings create|update|delete`.

## 12. Alert quality (AZR-060)

Every metric, scheduled-query, and activity-log rule should carry a severity, a responder-ready description, and (for metric/query rules) a retest window rather than firing on a single evaluation. Beyond the structural screen, surface the two highest-signal noise classes detectable from config: a rule wired to fire permanently, and a logical condition duplicated across multiple action groups (double-paging).

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
# Double-paging: the same rule wired to more than one action group -> every trigger pages twice.
jq -r '.[] | select((.enabled // true) == true) | select(((.actionGroups // []) | length) > 1)
  | "DOUBLE-PAGE \(.name): \((.actionGroups | length)) action groups"' "${RAW_DIR}/metric-alerts.json" 2>/dev/null || true
```

Healthy target: no output. `severity` (Azure uses 0=critical … 4=verbose) present on every rule; a description that names the resource, the threshold, and the first datapoints to capture; a `windowSize` long enough that a single scrape blip does not page. The length cut is a screen, not the judgment — read what remains and fail a description that names no resource or no capture list. "Service down" alone tells a 3am responder nothing. Name the two noise classes concretely: *"rule `cpu>5%` on `appgw-prod` (steady-state 40%) fires continuously; rule `disk-space` is wired to both `ops-primary` and `ops-catchall` → every trigger pages twice."* Honest ceiling, stated every run: Azure Monitor exposes no fired-notification/incident-history API, so this is a **structural** noise signal read off rule config, never a measured "N% of alerts are actionable" rate. Chains with AZR-001 (noise on the same action group buries the real pages that reach the one live receiver — the noise-drowns-signal cascade). Finding: `AZR-060` listing rules missing a severity, a real description, or a retest window, plus permanently-firing and duplicated rules; single-tier saturation-only alerts on volatile metrics are the judgment call — note the metric's volatility rather than failing on the number.

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
