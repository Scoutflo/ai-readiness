# audit-azure: Check Catalog and Commands

Runnable, strictly read-only checks for every scored surface the [audit-azure](../SKILL.md) workflow covers. Each section lists the catalog IDs it serves, the exact read command (an `az` read or an ARM REST GET pinned to an api-version **confirmed on a live 200 read**), the healthy target, the finding it emits, and its forbidden-mutations. Evidence for a finding is the command plus its observed output, trimmed with truncation marked. The non-scored Cost & Resource Optimization catalog (`AZROPT-NNN`) lives in its own file, [azure-cost-checks.md](azure-cost-checks.md); this file is the scored reliability axis (`AZR-NNN`).

## 1. Conventions

- **Confirmed-truth provenance.** Every api-version cited here was confirmed on a live 200 read before this catalog cited it; this catalog never invents one. The single surface the report did **not** exercise is `Microsoft.Insights/diagnosticSettings` (no resource to attach it to), so wherever diagnostic settings are read (AZR-010, AZR-032, AZR-050) the pinned surface is the `az monitor diagnostic-settings` **CLI** (it manages its own api-version); a failure there is recorded `blocked`, never worked around with a guessed REST version.
- **Identity preamble.** Every runnable block sources the same selected-target recipe; live blocks verify the selected identity with these lines, so it runs alone in a fresh shell holding one identity with no silent fallback. The confirmed auth path is `DefaultAzureCredential` → `AzureCliCredential` (via `az login`):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_token
echo "selected Azure identity and non-empty token verified"
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
| AZR-005 | Alert routing and delivery | No enabled alert-processing (suppression) rule with `RemoveAllActionGroups` mutes a live critical scope | `az monitor alert-processing-rule list` / `Microsoft.AlertsManagement/actionRules` (2021-08-08, read path live-confirmed) | critical |
| AZR-007 | Alert routing and delivery | 0 action groups AND 0 metric alerts despite a readable 200 is `blocked` (visibility/scope gap), not a confident 0 | actionGroups + metricAlerts | critical |
| AZR-010 | Compute VM/VMSS coverage | Serving VMs/VMSS carry CPU metric alerts; guest memory/disk claimed only with agent proof; diagnostic settings route to Log Analytics | `Microsoft.Compute/virtualMachines`, `…/virtualMachineScaleSets` (**2024-07-01**) + diagnostic-settings CLI | high |
| AZR-030 | AKS coverage | `addonProfiles.omsagent.enabled == true` on serving clusters | `az aks show` (control plane) | high |
| AZR-031 | AKS coverage | `azureMonitorProfile.metrics.enabled` matches where workload alerting is expected | `az aks show` (control plane) | medium |
| AZR-032 | AKS coverage | AKS control-plane logs routed to Log Analytics via a diagnostic setting | diagnostic-settings CLI on the cluster ID | high |
| AZR-033 | AKS coverage | A managed-Prometheus cluster (`azureMonitorProfile.metrics.enabled`) has ≥1 `prometheusRuleGroups` referencing its Azure Monitor workspace — zero rule groups means no consumer was observed on this Azure rule-group path; other alert consumers remain unassessed | `Microsoft.AlertsManagement/prometheusRuleGroups` (2023-03-01, read path live-confirmed) | medium |
| AZR-040 | Log Analytics coverage | Required Log Analytics destinations are evidenced, receive the declared logs, and have deliberate retention | `Microsoft.OperationalInsights/workspaces` (**2022-10-01**) | high |
| AZR-041 | Log Analytics coverage | A workspace that is a diagnostic destination is still ingesting (newest `Heartbeat`/critical tables within the staleness window) — a configured-but-dead sink invalidates every downstream diagnostic setting | `az monitor log-analytics query` (Log Analytics data plane, **verify-pending**) | high |
| AZR-042 | Log Analytics coverage | Subscription-scope diagnostic settings export `Administrative`/`Security`/`Policy` activity-log categories to a workspace, so control-plane events are retained and queryable | `az monitor diagnostic-settings subscription list` (read path live-confirmed) | medium |
| AZR-050 | Load balancer / App Gateway coverage | Every serving App Gateway/Load Balancer has backend health probes and diagnostic settings enabled | `Microsoft.Network/applicationGateways`, `…/loadBalancers` (**2024-05-01**) + diagnostic-settings CLI | high |
| AZR-060 | Alert quality | Every alert rule carries a severity, a responder-ready description, and a retest window | actionGroups + metric/scheduled/activity rules | medium |

Non-scored: **AZROPT-NNN** — the Cost & Resource Optimization catalog is authored separately in [azure-cost-checks.md](azure-cost-checks.md) (Advisor cost recommendations, month-to-date spend, unattached disks/IPs, stopped-but-not-deallocated VMs, VMSS over-provisioning, orphans). It never enters `score.categories`; every finding there is `points_recoverable: 0`.

## 3. Target profile

What 100/100 means per category (the checks above are this profile made executable): at least one enabled action group with a receiver a human reads, every enabled rule referencing one, and an observed delivery per receiver class (delivery proof is manual, AZR-001); every serving resource class under a metric alert, log-only signals under scheduled-query rules, and Service/Resource Health under activity-log alerts; serving VMs/VMSS with CPU alerts (guest memory/disk credited only with agent proof) and diagnostic settings to Log Analytics; AKS Container Insights on where container telemetry is expected, managed Prometheus matching the alerting plan, and control-plane logs in Log Analytics; declared Log Analytics destinations receiving their required logs with deliberate retention; every serving edge with backend probes and diagnostic settings; and every rule carrying a severity, a responder-ready description, and a retest window.

## 4. Inventory (all categories)

Capture projected, secret-free state once per run; later sections re-fetch specific objects before filing findings. The shared recipe follows up to 20 same-origin, same-subscription pages on the original collection path. A timeout, malformed page, repeated link, foreign link, or size/page limit blocks the collection. Raw receiver values stay in memory and never reach temporary files.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
mkdir -p "$RAW_DIR"; chmod 700 "$RAW_DIR"
# A partial refresh may not be mistaken for a complete empty or stale inventory.
: > "$RAW_DIR/.inventory-pending"
azure_inventory action-groups "/subscriptions/${SUB}/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01" \
  '[.value[] | {id,name,enabled:.properties.enabled,
    receivers:((.properties|to_entries|map(select(.key|endswith("Receivers")))
      |map({(.key):([.value[] | select(.enabled != false)]|length)})|add)//{})}]'
azure_inventory metric-alerts "/subscriptions/${SUB}/providers/Microsoft.Insights/metricAlerts?api-version=2018-03-01" \
  '[.value[]|{id,name,enabled:.properties.enabled,severity:.properties.severity,scopes:.properties.scopes,
    windowSize:.properties.windowSize,actionGroups:[.properties.actions[]?.actionGroupId],
    description_length:((.properties.description//"")|length)}]'
azure_inventory scheduled-query-rules "/subscriptions/${SUB}/providers/Microsoft.Insights/scheduledQueryRules?api-version=2022-06-15" \
  '[.value[]|{id,name,enabled:.properties.enabled,severity:.properties.severity,scopes:.properties.scopes,
    actionGroups:(.properties.actions.actionGroups//[]),windowSize:.properties.windowSize,
    description_length:((.properties.description//"")|length)}]'
azure_inventory activity-log-alerts "/subscriptions/${SUB}/providers/Microsoft.Insights/activityLogAlerts?api-version=2020-10-01" \
  '[.value[]|{id,name,enabled:.properties.enabled,scopes:.properties.scopes,
    categories:[.properties.condition.allOf[]?|select(.field=="category")|.equals],
    actionGroups:[.properties.actions.actionGroups[]?.actionGroupId]}]'
azure_inventory vms "/subscriptions/${SUB}/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01" \
  '[.value[]|{name,id,location,vmSize:.properties.hardwareProfile.vmSize}]'
azure_inventory vmss "/subscriptions/${SUB}/providers/Microsoft.Compute/virtualMachineScaleSets?api-version=2024-07-01" \
  '[.value[]|{name,id,location,sku:.sku.name,capacity:.sku.capacity}]'
azure_inventory log-workspaces "/subscriptions/${SUB}/providers/Microsoft.OperationalInsights/workspaces?api-version=2022-10-01" \
  '[.value[]|{name,id,location,retentionInDays:.properties.retentionInDays,sku:.properties.sku.name}]'
azure_inventory app-gateways "/subscriptions/${SUB}/providers/Microsoft.Network/applicationGateways?api-version=2024-05-01" \
  '[.value[]|{name,id,location,probes:[.properties.probes[]?.name],backendPools:[.properties.backendAddressPools[]?.name]}]'
azure_inventory load-balancers "/subscriptions/${SUB}/providers/Microsoft.Network/loadBalancers?api-version=2024-05-01" \
  '[.value[]|{name,id,location,sku:.sku.name,probes:[.properties.probes[]?.name],rules:[.properties.loadBalancingRules[]?.name]}]'
AKS=$(azure_cli aks list --query '[].{name:name,rg:resourceGroup,id:id}')
printf '%s' "$AKS" | azure_project -e 'type=="array"' >/dev/null
azure_save aks-list "$AKS"
rm "$RAW_DIR/.inventory-pending"
echo "complete inventory: $AZ_SEG/$RUN_DATE"
```

Expected: one file per surface, non-empty JSON arrays where the resources exist. A provider error is not proof that resources are absent. Declare `not-in-scope` only from the owner’s scope decision or complete independent inventory; otherwise record the affected checks `blocked` and continue independent categories. A `403` may indicate a missing role or another access policy (`Reader` + `Monitoring Reader` are the minimal read set); record it and mark the affected checks `blocked`. A `401` is a stale token — re-run the preamble.

## 5. Alert routing and delivery (AZR-001, AZR-004)

**AZR-001** — an enabled action group with a reachable receiver must exist, and enabled alert rules must reference one. An action group with `enabled: false` or zero receivers pages nobody.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_booleans action-groups metric-alerts scheduled-query-rules activity-log-alerts
# Compare complete ARM IDs, case-insensitively. A name is not a resource identity.
jq -e 'all(.[]; (.id|type)=="string" and (.id|length)>0)
  and ([.[].id|ascii_downcase]|length== (unique|length))' "$RAW_DIR/action-groups.json" >/dev/null
LIVE=$(jq -c '[.[]|select(.enabled==true and ([.receivers[]?]|add//0)>0)|.id|ascii_downcase]' "$RAW_DIR/action-groups.json")
DEAD=$(jq -c '[.[]|select(.enabled==false or ([.receivers[]?]|add//0)==0)|.id|ascii_downcase]' "$RAW_DIR/action-groups.json")
printf '%s' "$LIVE" | jq 'length'
for f in metric-alerts scheduled-query-rules activity-log-alerts; do
  jq -r --arg f "$f" --argjson live "$LIVE" --argjson dead "$DEAD" '
    .[]|select(.enabled==true)|(.actionGroups//[]|map(ascii_downcase)|unique) as $ags
    |if ($ags|length)==0 then "UNROUTED \($f): \(.name)"
     elif (($ags-$live-$dead)|length)>0 then "BLOCKED-ROUTE \($f): \(.name) unresolved full action-group ID; no mute conclusion"
     elif ($ags-$dead|length)==0 then "MUTE-ROUTE \($f): \(.name) scopes=\(.scopes//[]) -> only disabled or receiver-less groups"
     else empty end' "$RAW_DIR/$f.json"
done
```

Healthy target: a positive count of enabled action groups with receivers, no rule printed by the second command, and no `MUTE-ROUTE` line from the join. Don't stop at "an action group with 0 receivers pages nobody" — compute the join and name who is left mute: *"N enabled alert rules covering `checkout-vm-1`, `payments-sql`, `appgw-prod` all terminate at action group `ops-catchall`, which has 0 enabled receivers → those 3 critical services fire alerts into a void."* The number is `|rules whose groups are all receiver-less|` and the named set is their resolved scopes mapped to topology service names. This chains with AZR-002/AZR-010/AZR-050 (a metric alert that EXISTS but routes to a dead group is false confidence, not coverage — cite the AZR-002 pass it invalidates) and with AZR-005 (a live receiver whose delivery is suppressed). **Delivery proof:** a listed action group proves configuration, not delivery. Cloud has no read-only "was this delivered" list, and the `test-notifications` POST is a mutation that pages a human — forbidden here. So without an observed past page (a screenshot or team confirmation, the documented manual exception), routing stays `configured` and AZR-001 scores `partial` at best. Finding: `AZR-001` naming the zero-receiver, unreferenced-rule, or mute-route affected objects with their resolved scopes; delivery-unproven stays `partial`. Verify: re-list `actionGroups` at `2023-01-01`, confirm the named group reports ≥1 enabled receiver, and re-run the join so 0 rules terminate receiver-less.

**AZR-004** — activity-log alerts on Service Health, Resource Health, and critical Administrative/Security operations:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_booleans activity-log-alerts action-groups
LIVE=$(jq -c '[.[]|select(.enabled==true and ([.receivers[]?]|add//0)>0)|.id|ascii_downcase]' "$RAW_DIR/action-groups.json")
jq -r --argjson live "$LIVE" '[.[]|select(.enabled==true)
  |select(any(.actionGroups[]?; ascii_downcase as $id|$live|index($id)!=null))
  |.categories[]?]|unique|"activity-log categories configured with receivers: \(.)"' "$RAW_DIR/activity-log-alerts.json"
```

Healthy target: at least `ServiceHealth` and `ResourceHealth` categories present with an enabled rule wired to an action group; `Administrative`/`Security` coverage where the subscription hosts production. Finding: `AZR-004` naming the missing category — without that route, your team may learn of an Azure-side outage only after a service is affected.

Forbidden mutations (AZR-001/AZR-004): `az monitor action-group create|update|delete`, `az monitor action-group test-notifications create` (sends a real page), `az monitor activity-log alert create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.Insights/actionGroups` or `…/activityLogAlerts`.

**Wrong:** “two groups means every alert pages twice.” **Right:** “two configured destinations; duplicate delivery is unproven until intent and delivery evidence show overlap.”

### 5.1 Alert-processing (suppression) rules (AZR-005)

> **Read path live-confirmed; emit-path unobserved.** Run read-only against a live Scoutflo-internal Azure subscription: both `az monitor alert-processing-rule list` and the ARM `Microsoft.AlertsManagement/actionRules?api-version=2021-08-08` GET returned **200** (`{value:[]}`) — the api-version and read path are confirmed. The estate carried no alert-processing rule, so the `RemoveAllActionGroups` **emit** condition and its property paths were not exercised against a real rule (they remain from Azure's public API docs); treat a match as verify-pending on the property shape until a live rule exhibits it, but the read no longer needs to be recorded `blocked`.

**AZR-005** — an *enabled* alert-processing rule whose action is `RemoveAllActionGroups` suppresses delivery for every alert in its scope. This is the exact failure AZR-001 cannot see: the action groups have receivers and the rules reference them (AZR-001 passes), but a suppression rule silently swallows the notification between "rule fires" and "page leaves Azure". A rule scoped at a subscription or a production resource group, enabled, with no end schedule, is a permanent estate-wide mute.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
APR=$(azure_cli monitor alert-processing-rule list)
printf '%s' "$APR" | azure_project -e 'type=="array"' >/dev/null
SAFE=$(printf '%s' "$APR" | azure_project '[.[]|{name,enabled:.properties.enabled,actionTypes:[.properties.actions[]?.actionType],scopes:.properties.scopes,schedule:(.properties.schedule//null)}]')
azure_save alert-processing-rules "$SAFE"
azure_booleans alert-processing-rules
jq -r '.[]|select(.enabled==true)|select(.actionTypes|index("RemoveAllActionGroups"))
  |"SUPPRESSION-CANDIDATE \(.name) scopes=\(.scopes) schedule=\(.schedule); verify the active schedule and critical-scope intersection"' "$RAW_DIR/alert-processing-rules.json"
```

Healthy target: no enabled `RemoveAllActionGroups` rule whose scope covers a production resource group without a bounded maintenance schedule. Blast radius is computed, not asserted: intersect each flagged rule's `scopes[]` with the resource groups holding critical resources and name them — *"alert-processing rule `maint-suppress` is enabled, action `RemoveAllActionGroups`, scope = `rg-prod`, no end schedule → every alert on all critical resources in `rg-prod` is suppressed at delivery; the rules fire, no page leaves Azure."* Finding: `AZR-005` (critical) naming the rule, its scope, and the muted critical services; it negates the AZR-001 routing pass and every AZR-002/003/004 coverage pass whose scope falls inside the suppression scope. Remediation: `setup-azure#review-alert-processing-rules`.

Forbidden mutations (AZR-005): `az monitor alert-processing-rule create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.AlertsManagement/actionRules`.

## 6. Metric and scheduled-query alerts (AZR-002, AZR-003)

**AZR-002** — metric alert coverage per serving resource class. Compare `metricAlerts` scopes against the serving inventory (VMs, VMSS, App Gateways, Load Balancers, workspaces' resources):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_booleans metric-alerts
azure_require vms vmss app-gateways load-balancers
jq -r '[.[]|select(.enabled==true)|.scopes[]?]|unique|.[]|"ENABLED: \(.)"' "$RAW_DIR/metric-alerts.json"
jq -r '[.[]|select(.enabled==false)|.scopes[]?] as $disabled
  |[.[]|select(.enabled==true)|.scopes[]?] as $enabled
  |($disabled-$enabled)|unique|.[]|"DISABLED-ONLY: \(.)"' "$RAW_DIR/metric-alerts.json"
jq -r '.[].id' "$RAW_DIR/vms.json" "$RAW_DIR/vmss.json" "$RAW_DIR/app-gateways.json" "$RAW_DIR/load-balancers.json" | sort -u
```

Healthy target: every serving resource id appears in the first (enabled) list and the DISABLED-ONLY list is empty. Split the misses into two named buckets, never one generic "saturates silently":

- **Bucket (a) — no rule at all:** the serving resource id is absent from every metric alert. Name the resource and the signal that would have fired — *"`checkout-vm-1` has no CPU/availability metric alert; a saturation event pages nobody."* Fix: add a two-tier (warning/critical) metric alert scoped to that resource id (`setup-azure#add-metric-alerts`).
- **Bucket (b) — rule present but `enabled:false`:** *"`payments-sql` HAS rule `sql-dtu-critical` but it is `enabled:false` — inventory shows a rule, so this reads as covered while firing never."* Fix is cheaper: re-enable the existing rule, not author a new one — name which. This chains with AZR-001 (a covered resource whose rule routes to a dead group is doubly blind) and AZR-005 (a rule whose delivery is suppressed).

Finding: `AZR-002` (high) naming each resource in each bucket and, for bucket (b), the exact rule to re-enable. Verify by re-reading `metricAlerts` at `2018-03-01`: each named resource id appears in an enabled rule's `scopes[]`, and (bucket b) `properties.enabled == true`.

**AZR-003** — scheduled-query (log) alerts for signals metrics can't express (specific error strings, query-derived counts). A rule with no `actionGroups` fires into a void:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_booleans scheduled-query-rules
jq -r '.[] | "\(.name): enabled=\(.enabled) scopes=\(.scopes|length) actionGroups=\((.actionGroups//[])|length) window=\(.windowSize // "?")"' \
  "${RAW_DIR}/scheduled-query-rules.json"
```

Healthy target: each critical log-derived signal from topology has an enabled rule scoped to the right workspace/resource and wired to an action group. Finding: `AZR-003` for a missing log-alert signal, or a rule with zero action groups (`partial`).

Forbidden mutations (AZR-002/AZR-003): `az monitor metrics alert create|update|delete`, `az monitor scheduled-query create|update|delete`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.Insights/metricAlerts` or `…/scheduledQueryRules`.

## 7. Empty/hidden-scope guardrail (AZR-007)

The visibility trip-wire — **LIVE-VALIDATED** on a live subscription that returned 0 action groups AND 0 metric alerts and correctly tripped `AZR-007-OBS` instead of scoring a confident 0.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_require action-groups metric-alerts
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

Azure Compute exposes CPU natively. Credit guest memory and disk on the inspected Azure Monitor path only with the corresponding agent and collection evidence. No AMA or diagnostic extension means that path is unproven; it does not exclude another guest collector or telemetry backend.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_require vms vmss
RESOURCES=$(azure_resource_rows vms vmss)
printf '%s\n' "$RESOURCES" | sed '/^$/d' | while IFS= read -r resource; do
  ID=$(printf '%s' "$resource"|jq -r .id)
  azure_url "${ARM:?context missing}$ID"
  EXT=null; DS=null; EXT_STATUS=blocked; DS_STATUS=blocked
  if VALUE=$(arm_list "$ID/extensions?api-version=2024-07-01" '[.value[]|{name}]'); then EXT=$VALUE; EXT_STATUS=complete; fi
  if VALUE=$(azure_diagnostics "$ID"); then DS=$VALUE; DS_STATUS=complete; fi
  RESULT=$(jq -n --arg id "$ID" --arg ext_status "$EXT_STATUS" --arg ds_status "$DS_STATUS" --argjson ext "$EXT" --argjson ds "$DS" '
    {resource_id:$id,extensions:$ext,diagnostic_settings:$ds,
     read_status:{extensions:$ext_status,diagnostic_settings:$ds_status},
     result:(if $ext_status=="complete" and $ds_status=="complete" then "examined" else "blocked" end),
     reason:(if $ext_status=="complete" and $ds_status=="complete" then null else "A required resource read failed or returned incomplete/unknown-shaped evidence; keep the affected check unassessed" end)}')
  printf '%s\n' "$RESULT"
  azure_resource_done "$ID" "$RESULT"
done
```

Healthy target: every serving VM/VMSS has a CPU metric alert (AZR-002 supplies the scope list); `AzureMonitorLinuxAgent`/`AzureMonitorWindowsAgent` present on any VM whose coverage claims memory/disk; a diagnostic setting routing platform logs to a Log Analytics workspace. Finding: `AZR-010` naming VMs with no CPU alert, VMs whose memory/disk coverage is unproven because the agent is absent (false confidence), or serving VMs with no diagnostic setting. Report a diagnostic-settings permission error as `blocked`.

Forbidden mutations (AZR-010): `az vm create|delete|start|stop|deallocate|restart|resize|update`, `az vmss …` mutations, `az vm extension set|delete`, `az monitor diagnostic-settings create|update|delete`.

## 9. AKS coverage (AZR-030, AZR-031, AZR-032)

Read from the control-plane object `az aks show` returns — the property paths below are **confirmed** in the validation report (create→validate→delete of a real Entra cluster). Run once per cluster from `aks-list.json`.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_require aks-list
jq -c '.[]' "$RAW_DIR/aks-list.json" | while IFS= read -r cluster; do
  NAME=$(printf '%s' "$cluster"|jq -r .name); RG=$(printf '%s' "$cluster"|jq -r .rg); ID=$(printf '%s' "$cluster"|jq -r .id)
  azure_url "${ARM:?context missing}$ID"
  AKS=$(azure_cli aks show -n "$NAME" -g "$RG")
  printf '%s' "$AKS" | azure_project -e 'type=="object"' >/dev/null
  printf '%s' "$AKS" | azure_project --arg name "$NAME" '{name:$name,
    container_insights:(.addonProfiles.omsagent.enabled//false),
    oms_workspace:(.addonProfiles.omsagent.config.logAnalyticsWorkspaceResourceID//null),
    managed_prometheus:(.azureMonitorProfile.metrics.enabled//false),
    entra_managed:(.aadProfile.managed//false),entra_rbac:(.aadProfile.enableAzureRbac//false)}'
  DS=$(azure_diagnostics "$ID")
  printf '%s' "$DS" | azure_project --arg name "$NAME" '{name:$name,diagnostic_settings:.}'
done
```

Healthy targets and findings:

- **AZR-030** — `addonProfiles.omsagent.enabled == true` (and `.config.logAnalyticsWorkspaceResourceID` set) on any cluster expected to ship container logs/metrics; when off the addon is **absent/null** (confirmed shape). Don't stop at "Container Insights off": join the cluster to the critical workloads scheduled on it (topology.md) and name what goes dark — *"cluster `aks-prod` runs `checkout`, `orders`, `payments` per declared topology; Container Insights is off, so the inspected Azure collection path is absent. Alternate container collectors, metrics and log copies are unassessed."* Chains with AZR-032 (both inspected Azure collection paths may have gaps, without proving the cluster has no other telemetry) and AZR-041 (even if on, the destination workspace must be ingesting). Where the in-cluster stack owns the plane, mark `not-in-scope` and state the split rather than double-count. Finding: `AZR-030` (high) naming the blind critical workloads. Verify: re-run `az aks show`, `addonProfiles.omsagent.enabled == true` and `config.logAnalyticsWorkspaceResourceID` resolves to a workspace AZR-041 shows ingesting.
- **AZR-031** — `azureMonitorProfile.metrics.enabled == true` where the alerting plan expects workload Prometheus metrics; when off `azureMonitorProfile` is **absent/null** (confirmed). `false` where alerting expects it is the finding; `true` with no consuming rules is not merely an info note — it is scored as **AZR-033** (see 9.1).
- **AZR-032** — a diagnostic setting on the cluster ID routing control-plane logs (`kube-apiserver`, `kube-audit`, `kube-controller-manager`, `kube-scheduler`, …) to a Log Analytics workspace. Name the incident it blinds, not the missing object: *"`aks-prod` has no inspected diagnostic route for these control-plane categories to the required Log Analytics destination. This Azure investigation path is unavailable; other retained copies or destinations are unassessed."* Name the cluster and which log categories are unrouted (confirm categories with `az monitor diagnostic-settings categories list`, never a guessed api-version). Chains with AZR-030 (both inspected Azure paths have gaps) and AZR-040/AZR-041 (the destination must be retained and live). Finding: `AZR-032` when a required inspected route is absent, with severity based on evidenced impact; unknown required-plane intent is `blocked`; a permission error is `blocked`, never a guessed api-version.

If the in-cluster stack (Prometheus, Alertmanager, Grafana) is the primary alerting plane, mark the overlapping AKS checks `not-in-scope`, run `/scoutflo:audit-lgtm` against it, and state the split.

Forbidden mutations (AZR-030/031/032): `az aks create|update|delete|scale|upgrade`, `az aks enable-addons|disable-addons`, `az aks get-credentials` (writes a kubeconfig — not needed for a control-plane read), `az monitor diagnostic-settings create|update|delete`.

### 9.1 Managed Prometheus with no consuming rule groups (AZR-033)

> **Read path live-confirmed; emit-path unobserved.** Run read-only against a live Scoutflo-internal Azure subscription: `Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01` returned **200** (`{value:[]}`) — the api-version and read path are confirmed. The one live cluster had managed Prometheus off, so a rule-group-less-but-metrics-on cluster (the AZR-033 emit condition) and the property paths below were not exercised against a real rule group; treat those as verify-pending on the property shape until a live estate exhibits them, but the read no longer needs to be recorded `blocked`.

**AZR-033** — a cluster with `azureMonitorProfile.metrics.enabled == true` (AZR-031 pass) is collecting and being billed for managed-Prometheus metrics; if **zero** inspected `prometheusRuleGroups` reference that cluster's Azure Monitor workspace, this Azure rule-group path has no observed consumer; other rule engines are unassessed. Metrics collected ≠ metrics alerted-on — this is the alerting-plane extension AZR-031 never performs.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_inventory prometheus-rule-groups "/subscriptions/${SUB}/providers/Microsoft.AlertsManagement/prometheusRuleGroups?api-version=2023-03-01" \
  '[.value[]|{name,enabled:.properties.enabled,scopes:.properties.scopes,rules:([.properties.rules[]?]|length)}]'
azure_booleans prometheus-rule-groups
jq -r '[.[]|select(.enabled==true and .rules>0)|.scopes[]?]|unique
  |"enabled nonempty prometheusRuleGroups target scopes: \(.)"' "$RAW_DIR/prometheus-rule-groups.json"
```

Healthy target: every managed-Prometheus cluster's Azure Monitor workspace appears in at least one `prometheusRuleGroups` `scopes[]`. Blast radius, named: *"`aks-prod` ships managed-Prometheus metrics to its Azure Monitor workspace, but zero `prometheusRuleGroups` reference it — no consumer was observed on this Azure rule-group path for a pod-level saturation or SLO burn; alternate consumers and pages are unassessed."* Chains with AZR-031 (engine on) and AZR-005/AZR-001 (any rule groups that DO exist must still route to a live, unsuppressed action group). Finding: `AZR-033` (medium). Remediation: `setup-azure#add-prometheus-rule-groups`.

Forbidden mutations (AZR-033): any `PUT`/`PATCH`/`DELETE` on `Microsoft.AlertsManagement/prometheusRuleGroups`.

## 10. Log Analytics coverage and retention (AZR-040, AZR-041, AZR-042)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_require log-workspaces
jq -r '.[] | "\(.name): retentionInDays=\(.retentionInDays // "unset") sku=\(.sku // "?")"' "${RAW_DIR}/log-workspaces.json"
```

**AZR-040** — assess Log Analytics destinations actually referenced by inspected Azure routes in the selected subscription, where declared requirements or architecture establish this plane is required. It is not assumed to be the estate's only evidence store. For each observed destination, count the inspected resource fan-in and compare its retention with the stated investigation window: *"`la-prod` receives inspected routes from 6 VMs, 2 AKS clusters, and 3 edges; `retentionInDays=30` limits the queried copy in this workspace. Longer-lived copies elsewhere are unassessed."* Use critical-resource counts only with evidence of criticality. AZR-041 tests whether the inspected destination is ingesting.

A complete inventory returning zero workspaces proves only that none were inventoried in the selected subscription. It does not prove no logs, no external destination, or no shared workspace in another subscription. Without declared or evidenced required-plane intent, record the absence and keep the required-coverage conclusion `blocked`; ask which destination and retention are required. If a required destination or retention is missing, emit `AZR-040` with severity based on evidenced service impact, never automatic critical severity from a zero count. Remediation: `setup-azure#enable-diagnostic-settings`.

Forbidden mutations (AZR-040): `az monitor log-analytics workspace create|update|delete`, `az monitor log-analytics workspace update --retention-time`, any `PUT`/`PATCH`/`DELETE` on `Microsoft.OperationalInsights/workspaces`.

### 10.1 Workspace has stopped ingesting (AZR-041)

> **Verify-pending.** Drafted against Azure's confirmed Log Analytics data-plane read (`az monitor log-analytics query`, audience `https://api.loganalytics.io`, `log-analytics` az extension) and adversarially reviewed, but the staleness-detection join has NOT been run against a live tenant — status unproven until a first live run with a read-only token (see the doctor gate). The `Heartbeat`/table-recency queries below are documented KQL; the illustrative values are template examples, not asserted observations.

**AZR-041** — a workspace can be a configured diagnostic destination (AZR-030/032/050 all "pass") while the agent/DCR that feeds it has stopped, so every downstream diagnostic setting points at a dead sink. Config presence (AZR-040) is not ingestion; this is the data-plane recency half.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_require log-workspaces
STALE_HOURS="${AZURE_STALE_HOURS:-24}" # example; choose with the owner of the slowest critical table
case "$STALE_HOURS" in ''|*[!0-9]*) echo "AZR-041 blocked: invalid freshness window" >&2; exit 1;; esac
jq -r '.[].id' "$RAW_DIR/log-workspaces.json" | while IFS= read -r ID; do
  azure_url "${ARM:?context missing}$ID"
  WS=$(azure_cli monitor log-analytics workspace show --ids "$ID")
  GUID=$(printf '%s' "$WS"|azure_project -er '.customerId|select(type=="string" and length>0)')
  ROWS=$(azure_cli monitor log-analytics query --workspace "$GUID" --analytics-query "Heartbeat | summarize LastSeen=max(TimeGenerated) by Computer | extend Stale=LastSeen < ago(${STALE_HOURS}h)")
  printf '%s' "$ROWS" | azure_project -e 'type=="array"' >/dev/null
  printf '%s' "$ROWS" | azure_project --arg id "$ID" '{workspace:$id,heartbeat:[.[]|{Computer,LastSeen,Stale}]}'
  ROWS=$(azure_cli monitor log-analytics query --workspace "$GUID" --analytics-query "union withsource=T * | summarize Last=max(TimeGenerated) by T | extend Stale=Last < ago(${STALE_HOURS}h)")
  printf '%s' "$ROWS" | azure_project -e 'type=="array"' >/dev/null
  printf '%s' "$ROWS" | azure_project --arg id "$ID" '{workspace:$id,tables:[.[]|{T,Last,Stale}]}'
done
```

Healthy target: newest `Heartbeat` (and the tables the critical resources route into) are within `STALE_HOURS`. Blast radius = the set of critical resources whose logs silently stopped landing, from the fan-in join: *"`la-prod` is the sink for 2 AKS clusters and 3 edges, but its newest `Heartbeat` is 6 days old and `ContainerLog` has no rows since — every downstream diagnostic setting points at a dead workspace and every AZR-030/032/050 pass is coverage on paper."* Finding: `AZR-041` (high) — invalidates AZR-030/032/050/040 for any resource routing to the stale workspace, and is the evidence-plane half of the flagship chain. Remediation: `setup-azure#investigate-log-ingestion`.

Forbidden mutations (AZR-041): the data-plane query is read-only (`az monitor log-analytics query`); never `az monitor log-analytics workspace` writes.

### 10.2 Activity Log never exported (AZR-042)

> **Read path confirmed; populated emit path pending.** The subscription diagnostic-settings read returned an empty live result. A nonempty setting and its property paths have not been observed; validate them on the selected estate before scoring a populated match.

**AZR-042** — distinct from AZR-004 (which is whether activity-log *alerts* page): this is whether the inspected Azure export retains the required categories in Log Analytics. If the subscription-scope diagnostic settings export no `Administrative`/`Security`/`Policy` categories to a workspace, control-plane events (who deleted the alert rule, who changed the NSG, a resource-health transition) remain in the native Azure Activity Log within its retention; no inspected export to Log Analytics was established. Other exports or retained copies are unassessed.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
DS=$(azure_cli monitor diagnostic-settings subscription list)
printf '%s' "$DS"|azure_project -e 'type=="object" and (.value|type)=="array"' >/dev/null
SAFE=$(printf '%s' "$DS"|azure_project '[.value[]|{name,workspaceId:.properties.workspaceId,
  categories:[.properties.logs[]?|select(.enabled==true)|(.category//.categoryGroup)]}]')
azure_save subscription-diagnostic-settings "$SAFE"
jq -r 'if length==0 then "AZR-042: no subscription diagnostic settings returned"
  else .[]|"\(.name): workspace=\(.workspaceId//"none") categories=\(.categories)" end' "$RAW_DIR/subscription-diagnostic-settings.json"
```

Healthy target, when required by declared architecture: an inspected subscription diagnostic setting routes the required `Administrative`/`Security`/`Policy` categories to the intended workspace. Name only the categories without that inspected export. Native Azure Activity Log records still exist within their retention, and alternate exports or copies remain unassessed; do not claim the forensic trail is absent everywhere. Complements AZR-004 (events *page* vs events *retained*) and lands in the same workspace whose retention/ingestion AZR-040/AZR-041 judge. Finding: `AZR-042` (medium). Remediation: `setup-azure#enable-diagnostic-settings`.

Forbidden mutations (AZR-042): `az monitor diagnostic-settings subscription create|update|delete`, any `PUT`/`PATCH`/`DELETE` on subscription-scope `Microsoft.Insights/diagnosticSettings`.

## 11. App Gateway / Load Balancer coverage (AZR-050)

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_require app-gateways load-balancers
# Backend health probes present? (from the CONFIRMED 2024-05-01 captures)
jq -r '.[] | "appgw \(.name): probes=\(.probes|length) backendPools=\(.backendPools|length)"' "${RAW_DIR}/app-gateways.json"
jq -r '.[] | "lb \(.name) [\(.sku)]: probes=\(.probes|length) rules=\(.rules|length)"' "${RAW_DIR}/load-balancers.json"
```

Then, per serving App Gateway / Load Balancer, read its diagnostic settings by resource id (diagnostic-settings CLI — api-version unconfirmed, so CLI is the pinned surface):

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_require app-gateways load-balancers
RESOURCES=$(azure_resource_rows app-gateways load-balancers)
printf '%s\n' "$RESOURCES" | sed '/^$/d' | while IFS= read -r resource; do
  ID=$(printf '%s' "$resource"|jq -r .id)
  DS=null; DS_STATUS=blocked
  if VALUE=$(azure_diagnostics "$ID"); then DS=$VALUE; DS_STATUS=complete; fi
  RESULT=$(jq -n --arg id "$ID" --arg status "$DS_STATUS" --argjson ds "$DS" '
    {resource_id:$id,diagnostic_settings:$ds,read_status:{diagnostic_settings:$status},
     result:(if $status=="complete" then "examined" else "blocked" end),
     reason:(if $status=="complete" then null else "Diagnostic-settings read failed or returned incomplete/unknown-shaped evidence; keep diagnostic coverage unassessed" end)}')
  printf '%s\n' "$RESULT"
  azure_resource_done "$ID" "$RESULT"
done
```

Healthy target: each serving edge has the intended health-probe attachment and the diagnostic route required by declared architecture. Credit only the inspected Azure destination and signals. Health probes and metric alerts are different systems; one does not prove the other. For example: *"`appgw-prod` fronts `checkout-pool` with 0 inspected probes and no inspected diagnostic route to the required workspace. No matching Azure metric-alert route was observed for the checked signals; external alerts, logs and backend behavior are unassessed."* Do not infer that traffic continues or nobody is paged from those counts alone. State the edge, pool, required destination and inspected AZR-002 signals. Chains with AZR-040/AZR-041 concern only the observed workspace copies. Emit `AZR-050` for evidenced required-path gaps with severity based on impact; unknown required-plane intent or unreadable evidence is `blocked`. The diagnostic-settings half is a monitoring-plane fix (`setup-azure#enable-diagnostic-settings`); probe edits are traffic-impacting and plan-only.

Forbidden mutations (AZR-050): `az network application-gateway create|update|delete` (and its `probe`/`rule` subcommands), `az network lb create|update|delete` (and its `probe`/`rule` subcommands), `az monitor diagnostic-settings create|update|delete`.

## 12. Alert quality (AZR-060)

Every metric, scheduled-query, and activity-log rule should carry a severity, a responder-ready description, and (for metric/query rules) a retest window rather than firing on a single evaluation. Beyond the structural screen, surface the two highest-signal noise classes detectable from config: a rule wired to fire permanently, and multiple destinations that may overlap. Multiple groups alone do not prove duplicate delivery.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_booleans metric-alerts scheduled-query-rules
DESCRIPTION_MIN_LENGTH="${AZURE_DESCRIPTION_MIN_LENGTH:-40}" # example screen, not semantic quality
case "$DESCRIPTION_MIN_LENGTH" in ''|*[!0-9]*) echo "invalid description screen" >&2; exit 1;; esac
for f in metric-alerts scheduled-query-rules; do
  jq -r --arg f "$f" --argjson minimum "$DESCRIPTION_MIN_LENGTH" '.[]|select(.enabled==true)
    |select((.description_length < $minimum) or .windowSize==null or .severity==null)
    |"\($f): \(.name) severity=\(.severity//"unset") window=\(.windowSize//"unset") desc_len=\(.description_length)"' "$RAW_DIR/$f.json"
  jq -r '.[]|select(.enabled==true)|select((.actionGroups//[]|unique|length)>1)
    |"MULTI-DESTINATION-CANDIDATE \(.name): \((.actionGroups|unique|length)) groups; check intended fan-out and delivery overlap"' "$RAW_DIR/$f.json"
done
```

Healthy target: no unexplained structural gaps; multi-destination candidates may be intentional. `severity` (Azure uses 0=critical … 4=verbose) present on every rule; a description that names the resource, the threshold, and the first datapoints to capture; a `windowSize` long enough that a single scrape blip does not page. The length cut is a screen, not the judgment — inspect descriptions in memory without recording their text, and fail a description that names no resource or no capture list. "Service down" alone tells a 3am responder nothing. Name the two noise classes concretely: *"rule `cpu>5%` on `appgw-prod` (steady-state 40%) fires continuously; rule `disk-space` is wired to two action groups; confirm the intended audiences and observed delivery overlap before alleging duplicate paging."* Honest ceiling, stated every run: This audit does not collect human notification receipts, so this is a **structural** noise signal read off rule config, never a measured "N% of alerts are actionable" rate. Chains with AZR-001 (noise on the same action group buries the real pages that reach the one live receiver — the noise-drowns-signal cascade). Finding: `AZR-060` listing rules missing a severity, a real description, or a retest window, plus verified permanently-firing or duplicate-delivery rules; single-tier saturation-only alerts on volatile metrics are the judgment call — note the metric's volatility rather than failing on the number.

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
