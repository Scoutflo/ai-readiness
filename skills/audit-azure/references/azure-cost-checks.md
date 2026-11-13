# audit-azure: Cost & Resource Optimization Check Catalog

Runnable, strictly read-only checks for the Cost & Resource Optimization section of [audit-azure](../SKILL.md#cost-and-resource-optimization-not-scored). This section is **never scored**: every finding here carries `points_recoverable: 0` and `area: cost-optimization`, and none of it enters `score.categories` or `score.excluded` (per the parallel non-scored sections rule in [findings-schema.md](../../../report-standard/findings-schema.md)). IDs are `AZROPT-NNN`, a separate registered prefix from the scored reliability catalog's `AZR-NNN`, so a reader can tell the cost axis from the reliability axis at a glance.

This section deepens the picture the dedicated [audit-cost](../../audit-cost/SKILL.md) skill draws for Azure. The two stay consistent — same one hard rule, same Azure-native dollar sources, same forbidden verbs — but `AZROPT-*` is audit-azure's own in-pack parallel-section prefix, while audit-cost's central per-resource pass registers its Azure findings under the distinct `COST-AZ-NNN` prefix. Same discipline, two IDs, so a reader can tell an in-pack cost finding from a deep-cost finding at a glance; never sum the two catalogs' figures for the same resource.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied **verbatim** from an Azure-native cost recommendation response — Azure Advisor's own cost recommendation — never recomputed from raw metrics against a price table you assembled, and never derived by arithmetic on any other provider number. Everything else in this file is a **presence/absence fact** (unattached disks, unassociated public IPs, stopped-but-not-deallocated VMs, over-scaled scale sets, orphaned resources) reported with **no dollar figure** rather than an invented one. This mirrors the toolkit-wide rule that errors are evidence, never invented; applied to money, an unverified number is worse than no number, because it gets pasted into a budget conversation.

- ❌ `AZROPT-003: 6 managed disks unattached; at ~$0.05/GiB-month that is roughly $190/mo wasted.`
- ✅ `AZROPT-003: 6 managed disks in diskState Unattached (names/sizes/RGs listed); no estimated_monthly_savings_usd — Azure returns no native dollar figure for a bare unattached disk, so this is a presence fact.`

**One Azure dollar that is NOT `estimated_monthly_savings_usd`.** The Cost Management Query REST API returns the subscription's **actual month-to-date spend** (`PreTaxCost`). That is money **already spent**, not a saving you can capture by acting — it is section context, never a saving. Report it verbatim on its own line (AZROPT-002) and **never** sum it into the savings total. This is the exact analogue of the AWS pack's carve-out for unused-commitment and anomaly dollars.

**Currency and period discipline for Advisor's figure.** Copy Advisor's own amount into `estimated_monthly_savings_usd` **only** when Advisor itself returns a *monthly* figure denominated in *USD*. If Advisor returns an annual figure, an hourly figure, or a non-USD currency, record that native value verbatim in the finding body with its own unit/currency and leave `estimated_monthly_savings_usd` unset — never convert annual→monthly or foreign→USD yourself. Conversion is arithmetic on a provider number, and the schema field is USD-monthly by contract.

## 2. Confirmed-truth provenance (what this catalog cites vs. presents to verify)

Per the Azure SDK/API Validation Report, the following are **confirmed on a live read** and cited directly here:

| Surface | Confirmed fact |
| --- | --- |
| Cost Management Query | REST `POST /subscriptions/{id}/providers/Microsoft.CostManagement/query` at **api-version `2023-11-01`** — endpoint/version attempted (live call returned HTTP 429; a successful response and request semantics remain unproven); it is a **read that uses POST** (`readOnly`), and must **handle 429 with backoff**. The `az costmanagement query` CLI **does not exist** — do not use it. |
| Azure Resource Graph | REST `POST /providers/Microsoft.ResourceGraph/resources` at **api-version `2022-10-01`** — 200 with live records; a **read that uses POST**. Enumerates any resource type in a paginated cross-region query via KQL. |
| Compute (VMs / VMSS) | `Microsoft.Compute/virtualMachines` and `Microsoft.Compute/virtualMachineScaleSets` at **api-version `2024-07-01`** (200). |
| Auth | `DefaultAzureCredential` → `AzureCliCredential` fallback (via `az login`) — works against ARM. |

The following are **not** part of that confirmed run and are therefore authored **presence-fact-first**, with an explicit "confirm against your tenant" caveat wherever a specific field or command is named — never asserted as confirmed truth:

- **Azure Advisor** (`az advisor recommendation list --category Cost`) and the exact shape of a cost recommendation's savings fields. The recommendation's **presence** is the reportable signal; any dollar is copied verbatim only if Advisor itself returns one.
- **Per-resource-type KQL property paths** used in Resource Graph filters (e.g. `properties.diskState`, `properties.ipConfiguration`, `properties.extended.instanceView.powerState.code`). These are Azure's public resource schema, not validated in the confirmed run. Resource Graph returns the raw resource either way, so a wrong path yields *no rows* (a miss), not a false dollar — but confirm a flagged resource is truly idle before reporting it.
- **Managed disks** (`Microsoft.Compute/disks`) and **public IP addresses** (`Microsoft.Network/publicIPAddresses`) have **no confirmed direct ARM api-version** in the report, so this catalog enumerates them through the confirmed Resource Graph endpoint rather than citing an unconfirmed per-type api-version.

## 3. Config placeholders and the scope rule

Every command resolves the config with `SCOUTFLO_CONFIG` precedence and the exact `SCOUTFLO_TARGET` using the shared target enumerator. A subscription is required; an unselected list or missing subscription stops before a provider read. Each live block verifies `az account show --subscription "$SUB"`; the ambient default is never used. The confirmed auth path is `DefaultAzureCredential` → `AzureCliCredential`, so an ARM bearer token for the two POST-read endpoints (Cost Management, Resource Graph — neither has a first-class `az` command) comes from that same login:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
azure_token
echo "selected Azure scope ready; query helpers reject incomplete reads"
```

**The scope rule (how Azure differs from the AWS region fan-out).** AWS Compute Optimizer is regional and needs one call per active region; Azure's confirmed cost surfaces are **subscription-scoped and cross-region without a per-region fan-out**, so there is no per-region loop:

- **Resource Graph** returns resources across **all regions** of the subscription(s) you pass in `subscriptions[]` in one logical query, following every Resource Graph continuation token — never iterate regions.
- **Cost Management Query** aggregates the whole subscription scope in one POST. To widen scope, change the scope path (`/providers/Microsoft.Management/managementGroups/{mg}` or a billing-account scope) rather than summing subscriptions yourself.

For a **multi-subscription** estate, run once per audited subscription (Resource Graph accepts a `subscriptions[]` array; Cost Management is per-scope). Never blend two subscriptions' Cost Management totals into one number — report each scope's provider-returned total verbatim.

## 4. Check catalog

| ID | Signal | Source (read-only) | Savings figure |
| --- | --- | --- | --- |
| AZROPT-001 | Azure Advisor cost recommendations (rightsizing, idle, shutdown, reserved-instance/savings-plan) | `az advisor recommendation list --category Cost` | Azure-native $ — copied **verbatim** from Advisor's own recommendation **when present**; else presence fact |
| AZROPT-002 | Subscription month-to-date actual spend | Cost Management Query REST `2023-11-01` (`PreTaxCost`) | Provider $ (spend already incurred) — reported as context, **never** summed into savings |
| AZROPT-003 | Unattached managed disks | Resource Graph `2022-10-01` (`Microsoft.Compute/disks`, `diskState == 'Unattached'`) | None (presence fact) |
| AZROPT-004 | Unassociated public IP addresses | Resource Graph `2022-10-01` (`Microsoft.Network/publicIPAddresses`, no `ipConfiguration`/`natGateway`) | None (presence fact) |
| AZROPT-005 | Stopped-but-not-deallocated VMs (still billed for compute) | Resource Graph `2022-10-01` (`Microsoft.Compute/virtualMachines`, `powerState == 'PowerState/stopped'`) | None (presence fact) |
| AZROPT-006 | VMSS over-provisioning (high fixed capacity, no autoscale) | Resource Graph `2022-10-01` (`Microsoft.Compute/virtualMachineScaleSets` + `Microsoft.Insights/autoscalesettings`) | None (presence fact) |
| AZROPT-007 | Orphaned resources (unattached NICs, unused NSGs/route tables, aged snapshots) | Resource Graph `2022-10-01` (multiple types) | None (presence fact) |

## 5. Per-check access screen

No Azure `cost-permissions` doctor row is produced. Probe each existing read surface
on the selected subscription, and retain its own result. A Cost Management denial
affects AZROPT-002; it says nothing about Advisor or Resource Graph access. This
screen returns status metadata only. Each later check still validates its actual
read, because permissions and throttling can change mid-run.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
COST_ACCESS=unavailable; ADVISOR_ACCESS=unavailable; RG_ACCESS=unavailable
COST_BODY='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}}}'
if PROBE=$(azure_http POST "$ARM/subscriptions/$SUB/providers/Microsoft.CostManagement/query?api-version=2023-11-01" "$COST_BODY") \
  && printf '%s' "$PROBE"|azure_project -e '(.properties.columns|type)=="array" and (.properties.rows|type)=="array" and (.properties.nextLink//"")=="" and (.nextLink//"")==""' >/dev/null; then
  COST_ACCESS=available
fi
if PROBE=$(azure_cli advisor recommendation list --category Cost) \
  && printf '%s' "$PROBE"|azure_project -e 'type=="array"' >/dev/null; then ADVISOR_ACCESS=available; fi
if PROBE=$(rg_query "Resources | summarize resource_count=count()") \
  && printf '%s' "$PROBE"|azure_project -e '.complete==true' >/dev/null; then RG_ACCESS=available; fi
jq -n --arg cost "$COST_ACCESS" --arg advisor "$ADVISOR_ACCESS" --arg graph "$RG_ACCESS" \
  '{"AZROPT-001":$advisor,"AZROPT-002":$cost,"AZROPT-003..007":$graph}'
```

| Read surface | Checks | Successful evidence | Unavailable evidence |
| --- | --- | --- | --- |
| Advisor recommendations | AZROPT-001 | Successful JSON array from Advisor's own read | Only Advisor findings unavailable; no inferred savings |
| Cost Management query | AZROPT-002 | HTTP200, valid columns/rows and complete aggregate | Month-to-date spend unavailable; never a computed dollar |
| Resource Graph | AZROPT-003…007 | Complete JSON rows, all continuations consumed | Affected presence checks unavailable; no absence claim |

These checks remain non-scored. Record failed reads as unavailable evidence with
the failed surface/reason, continue independent checks, and do not claim an empty
cost section proves no optimization opportunities. Successful access alone is not
proof of a check's populated field semantics or a resource's idle state.

## 6. Read-only surface used (the whole set)

`az account show`; `az account get-access-token --resource https://management.azure.com`; `az advisor recommendation list --category Cost`; a `readOnly` POST to Cost Management (`.../Microsoft.CostManagement/query?api-version=2023-11-01`); a `readOnly` POST to Resource Graph (`/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01`). Optionally, confirmed direct ARM GETs `Microsoft.Compute/virtualMachines` / `Microsoft.Compute/virtualMachineScaleSets` at `2024-07-01`. Every one is a read (`show`/`list`/`get`, or a POST explicitly marked `readOnly` because the query verb is POST). Nothing here writes.

## 7. Azure Advisor cost recommendations (AZROPT-001)

Advisor is the one place Azure itself may attach a **native savings figure**. This surface was **not** exercised in the confirmed validation run, so treat the recommendation's **presence** as the reportable fact, and copy a dollar **only** if Advisor returns one in its own response — verbatim, with its own currency and period, never computed:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
ADVISOR=$(azure_cli advisor recommendation list --category Cost)
printf '%s' "$ADVISOR"|azure_project -e 'type=="array"' >/dev/null
# Keep identifiers and field names; arbitrary recommendation text/properties are not safe evidence.
printf '%s' "$ADVISOR"|azure_project '[.[]|{id,impacted_resource:(.resourceMetadata.resourceId//.impactedValue),
  resource_type:.impactedField,impact,extended_property_names:(.extendedProperties//{}|keys)}]'
# Inspect an actual savings field in memory, and record only the provider amount/unit/currency
# after verifying its meaning. Never save the raw extendedProperties object or infer USD/month.
```

**Expected & failure meaning.** Zero or more recommendations, each naming the impacted resource, Advisor's `impact` (`High`/`Medium`/`Low`), and an `extended_properties` object. Where that object contains Advisor's own **monthly USD** savings amount, copy it verbatim into `estimated_monthly_savings_usd` and name Advisor as the `savings_source`; where Advisor gives an **annual** or **non-USD** figure, record it verbatim in the finding body with its own unit/currency and leave `estimated_monthly_savings_usd` unset. Where Advisor gives no figure at all, the recommendation is still a presence fact worth reporting (e.g. "Advisor recommends shutting down VM `x`") — just with no dollar. A permission error or no Advisor data → `excluded` with the reason, never a guessed `0`.

- ❌ `AZROPT-001: Advisor flags vm-api Underutilized; sizing down to Standard_D2s_v5 saves ~$120/mo per the public price list.`
- ✅ `AZROPT-001: Advisor rates vm-api "Underutilized" (impact Medium); estimated_monthly_savings_usd = 120.00, copied verbatim from Advisor's own recommendation (savings_source: azure-advisor). If Advisor returned only an annual/non-USD figure, it is quoted in the finding body and the USD-monthly field is left unset.`

## 8. Subscription month-to-date spend (AZROPT-002)

The Cost Management Query REST API returns the subscription's **actual** spend. This is confirmed at api-version `2023-11-01` and is **rate-limited** (a live call returned HTTP 429), so it must be retried with backoff. It is **spend already incurred, not a saving** — report it as context and never fold it into the savings total.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
COST_URL="$ARM/subscriptions/${SUB}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
COST_BODY='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}}}'
COST=$(azure_http POST "$COST_URL" "$COST_BODY")
printf '%s' "$COST"|azure_project -e '(.properties.columns|type)=="array" and (.properties.rows|type)=="array"
  and (.properties.nextLink//"")=="" and (.nextLink//"")==""' >/dev/null \
  || { echo "AZROPT-002 blocked: invalid or paginated aggregate; no spend inferred" >&2; exit 1; }
printf '%s' "$COST"|azure_project '{columns:[.properties.columns[].name],rows:.properties.rows}'
```

**Expected & failure meaning.** A `properties.rows` array whose row(s) carry the summed `PreTaxCost` and its currency (read the currency from `properties.columns`). Report that number **verbatim** as "current month-to-date spend (`PreTaxCost`, per Cost Management)" on its own context line — never in `estimated_monthly_savings_usd`, never summed into savings. An HTTP 403 → `excluded, reason: "Cost Management query denied (needs Cost Management Reader or equivalent)"`. A persistent 429 after the backoff exhausts → report `blocked, reason: "Cost Management throttled (429) after retries"`, never a guessed `0` and never a fabricated figure. Do not attempt `az costmanagement query` — that CLI command does not exist.

## 9. Unattached disks and public IPs (AZROPT-003, AZROPT-004)

Enumerated through the confirmed Resource Graph endpoint (managed disks and public IPs have no confirmed direct ARM api-version). Pure presence facts — name every resource, attach **no** dollar. The KQL `type`/property filters are Azure's documented resource schema; Resource Graph returns the raw resource, so a filter that misses simply returns fewer rows — verify a flagged resource is truly unattached before reporting it.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
rg_query "Resources | where type =~ 'microsoft.compute/disks' | where tostring(properties.diskState) == 'Unattached' | project name, id, resourceGroup, location, sku=tostring(sku.name), sizeGiB=toint(properties.diskSizeGB), timeCreated=tostring(properties.timeCreated)"
rg_query "Resources | where type =~ 'microsoft.network/publicipaddresses' | where isnull(properties.ipConfiguration) and isnull(properties.natGateway) | project name, id, resourceGroup, location, sku=tostring(sku.name), method=tostring(properties.publicIPAllocationMethod)"
```

**Expected & failure meaning.** Any non-empty `rows` array is a per-resource presence finding, listed by name/RG/region with size/SKU/age, **no dollar**. A `Standard`-SKU public IP with no `ipConfiguration` bills a fixed hourly charge for nothing; an `Unattached` disk bills its full provisioned size. If Advisor (AZROPT-001) separately attaches a native figure for the same resource, cross-reference it and count the dollar once — do not invent one here.

## 10. Stopped-but-not-deallocated VMs (AZROPT-005)

A VM in power state `PowerState/stopped` (as opposed to `PowerState/deallocated`) **still bills for its compute** — the underlying hardware stays reserved. This is a classic silent cost. Power state is read from the VM's instance view; the property path below is Azure's documented Resource Graph shape (not part of the confirmed run), so treat a hit as a candidate and confirm before reporting.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
KQL="Resources | where type =~ 'microsoft.compute/virtualmachines' | extend powerState = tostring(properties.extended.instanceView.powerState.code) | where powerState == 'PowerState/stopped' | project name, id, resourceGroup, location, vmSize=tostring(properties.hardwareProfile.vmSize), powerState"
rg_query "$KQL"
```

**Expected & failure meaning.** Each row is a VM billing for compute while doing no work — the finding names the VM, its RG/region, and `vmSize`, with no dollar. Distinguish it clearly from a *deallocated* VM (not billed for compute), which is **not** a finding. If Resource Graph does not surface the power-state code on this tenant, fall back to the confirmed direct ARM path — `GET .../Microsoft.Compute/virtualMachines?api-version=2024-07-01` to list, then read each VM's instance view — and report the same presence fact; never guess a state.

## 11. VMSS over-provisioning (AZROPT-006)

A Virtual Machine Scale Set running a **high fixed capacity with no autoscale** pays for every instance around the clock regardless of load. Without a confirmed utilization-metrics path, this is a **presence fact**: report the scale set's capacity and whether an autoscale setting targets it; a high fixed capacity with no autoscale is the candidate, no dollar.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
rg_query "Resources | where type =~ 'microsoft.compute/virtualmachinescalesets' | project name, id, resourceGroup, location, sku=tostring(sku.name), capacity=toint(sku.capacity), upgradeMode=tostring(properties.upgradePolicy.mode)"
rg_query "Resources | where type =~ 'microsoft.insights/autoscalesettings' | project name, resourceGroup, targetResourceUri=tostring(properties.targetResourceUri), enabled=tobool(properties.enabled)"
```

**Expected & failure meaning.** Cross-reference the two results: a scale set whose `id` appears in no enabled `autoscalesettings.targetResourceUri`, running a fixed `capacity` above 1, is the finding — reported by name/capacity/SKU as a candidate for autoscale or downsizing, **no dollar**. A scale set already governed by an enabled autoscale setting is not a finding. If Advisor (AZROPT-001) attaches a native figure for the same scale set, cross-reference it.

## 12. Orphaned resources (AZROPT-007)

Resource Graph makes it cheap to sweep for the common orphan classes in one place. Each is a presence fact, no dollar; the list is extensible — add types your estate uses.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
rg_query "Resources | where type =~ 'microsoft.network/networkinterfaces' | where isnull(properties.virtualMachine) | project name, id, resourceGroup, location"
rg_query "Resources | where type =~ 'microsoft.network/networksecuritygroups' | where array_length(properties.subnets) == 0 and array_length(properties.networkInterfaces) == 0 | project name, id, resourceGroup, location"
rg_query "Resources | where type =~ 'microsoft.network/routetables' | where isnull(properties.subnets) or array_length(properties.subnets) == 0 | project name, id, resourceGroup, location"
rg_query "Resources | where type =~ 'microsoft.compute/snapshots' | project name, id, resourceGroup, location, sizeGiB=toint(properties.diskSizeGB), timeCreated=tostring(properties.timeCreated)"
```

**Expected & failure meaning.** Any non-empty `rows` array is a presence finding named per resource. For snapshots, compare each `timeCreated` against the team's **own stated** retention policy from business context — if none is stated, say so in the finding rather than pick a number for them. These resources bill while attached to nothing; the reader decides with the concrete list in hand, no invented dollar.

## 13. Rendering the Azure cost section

Every finding uses `area: cost-optimization` and `points_recoverable: 0`. Cost changes are **report-only** here — resizing, deallocating, or deleting live Azure infra is materially riskier than a reliability fix, so this section, like the dedicated audit-cost skill, never points at a `setup-azure` write anchor. Each finding's `recommendation` states the concrete action and the Azure Portal / `az` CLI path a human would follow; the audit itself changes nothing. Findings rank by `estimated_monthly_savings_usd` descending, then presence facts grouped after.

**Open with the savings-summary line** (per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule), built **only** from `estimated_monthly_savings_usd` values copied verbatim from Advisor (AZROPT-001):

> **Potential savings: ~$<sum>/month (~$<sum×12>/year)** across **<n>** opportunities with an Azure Advisor figure; **<m> more** found with no Azure dollar figure (presence facts, listed below). Largest single lever: **$<max>/mo** — <that finding's one-line action>.

Rules: sum only verbatim Advisor figures; annual = monthly × 12, labelled an estimate (`~`, "potential"); state the count *with* a figure separately from the count *without* one; name the single biggest lever. **Never** fold in the AZROPT-002 month-to-date spend — call it out on its own context line ("Current month-to-date spend: $X <currency> (PreTaxCost, per Cost Management) — context, not a saving"). If no row carries an Advisor figure, write "<n> opportunities found; no Azure-sourced dollar figures available — each is a presence fact to review", never `$0`.

Then render the per-row table: `Finding | Resource | Signal source | Current → recommended | Est. monthly savings (Azure-sourced) | Est. annual | Action`. `Current → recommended` shows the shape change where Advisor gives it (`Standard_D4s_v5 → Standard_D2s_v5`, `stopped → deallocate or delete`, `unattached → delete`), else `-`. A row with no Azure-sourced figure prints `-` in the savings columns (reads as "checked, no number available", not "forgot to fill in"). **Cross-reference note:** where Advisor (AZROPT-001) covers the same resource as a presence fact (AZROPT-003…007), annotate the overlap and count that resource's savings once — never sum two views of the same resource into the total. Every number carries its unit and period; no figure appears that was not copied from an Azure API.

## 14. Forbidden commands (never run in this or any audit)

This catalog is read-only. The following mutating verbs must **never** run under audit-azure — acting on a recommendation is a human/console decision, out of scope for automation here:

- **Compute / disks:** `az vm delete`, `az vm deallocate`, `az vm stop`, `az vm start`, `az vm resize`, `az disk delete`, `az disk update`, `az snapshot delete`, `az vmss delete`, `az vmss scale`, `az vmss update`.
- **Network:** `az network public-ip delete`, `az network nic delete`, `az network nsg delete`, `az network route-table delete`.
- **Generic resource / cost governance:** `az resource delete`, `az resource update`, `az group delete`, `az consumption budget create` / `az consumption budget update` (never create or change a budget), any Cost Management or Advisor `PUT`/`POST` that writes a configuration or suppression.
- **The non-existent CLI:** `az costmanagement query` — it does not exist; the cost read path is the Cost Management Query **REST** API at `2023-11-01`, and nothing else.

If any recommendation warrants action, the finding's `recommendation` names the exact Portal/CLI path for a human to run under change control; the audit never changes a live resource, not even a "harmless" disk deletion or VM deallocation.
