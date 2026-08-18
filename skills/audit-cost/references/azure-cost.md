# audit-cost (Azure): Deep Per-Resource Cost Check Catalog

Runnable, strictly read-only cost checks for the Azure provider phase of [audit-cost](../SKILL.md). Findings from this catalog live in the `scoutflo-cost/v1` result (a savings summary + ranked findings, **no 0-100 score**): every finding carries `points_recoverable: 0` and `area: cost-optimization`, names a concrete resource in `affected`, and quotes real command output in `evidence` — never folded into `score.categories` or `score.excluded`, per the [parallel non-scored sections](../../../report-standard/severity-and-scoring.md#parallel-non-scored-sections) rule. IDs are `COST-AZ-NNN`, a permanently registered prefix distinct from the reliability catalog's `AZR-NNN` and from audit-azure's own in-pack parallel-section prefix `AZR-OPT-NNN` ([azure-cost-checks.md](../../audit-azure/references/azure-cost-checks.md)), so a reader can tell which axis — and which pass — a finding belongs to at a glance. This is deep, per-resource cost analysis — every finding names a concrete resource (managed disk, public IP, VM, scale set, snapshot) with its resource group, region, SKU/size, and age — never "the subscription has waste". The central COST-AZ pass and the in-pack AZR-OPT section are two views of the same estate: **never sum their figures for the same resource** — count each resource's savings once.

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied **verbatim** from an Azure-native cost recommendation — Azure Advisor's own cost recommendation response — and never recomputed from raw metrics against a price table you assembled, never derived by arithmetic on any other provider number. Azure prices vary by region, reservation, savings-plan commitment, and negotiated rate, so any number you derive is a guess. Every other check in this file — unattached disks, unassociated public IPs, stopped-but-not-deallocated VMs, over-scaled scale sets, orphaned resources, month-to-date spend — is a **presence/absence fact** (or a spend-context fact) reported with **no** `estimated_monthly_savings_usd`. This mirrors the toolkit-wide rule that errors are evidence, never invented; applied to money, an unverified number is worse than no number, because it gets pasted straight into a budget conversation.

- ❌ `COST-AZ-021: 6 managed disks unattached; at ~$0.05/GiB-month that is roughly $190/mo wasted.`
- ✅ `COST-AZ-021: 6 managed disks in diskState 'Unattached' (names/SKUs/sizes/RGs listed); no estimated_monthly_savings_usd — Azure returns no native dollar figure for a bare unattached disk, so this is a presence fact.`
- ✅ `COST-AZ-001: Advisor rates VM 'vm-api' "Underutilized" (impact Medium); estimated_monthly_savings_usd = 120.00, copied verbatim from Advisor's own recommendation (savings_source: azure-advisor). If Advisor returned only an annual/non-USD figure, it is quoted in the finding body and the USD-monthly field is left unset.`

**One Azure dollar that is NOT a saving.** The Cost Management Query REST API returns the subscription's **actual month-to-date spend** (`PreTaxCost`). That is money **already spent**, not a saving you can capture by acting — it is section *context*, never a saving. Report it verbatim on its own line (COST-AZ-020) and **never** sum it into the savings total. This is the exact analogue of the AWS pack's carve-out for unused-commitment and anomaly dollars, and of the GCP pack's billing-context carve-out.

**Currency and period discipline for Advisor's figure.** Copy Advisor's own amount into `estimated_monthly_savings_usd` **only** when Advisor itself returns a *monthly* figure denominated in *USD*. If Advisor returns an annual figure, an hourly figure, or a non-USD currency, record that native value verbatim in the finding body with its own unit/currency and leave `estimated_monthly_savings_usd` unset — never convert annual→monthly or foreign→USD yourself. Conversion is arithmetic on a provider number, and the schema field is USD-monthly by contract.

## 2. Confirmed-truth provenance (what this catalog cites vs. presents to verify)

Per the Azure SDK/API Validation Report, the following are **confirmed on a live read** and cited directly here:

| Surface | Confirmed fact |
| --- | --- |
| Auth | `DefaultAzureCredential` → `AzureCliCredential` fallback (via `az login`) — works against ARM. Mint the ARM bearer from that same login. |
| Cost Management Query | REST `POST /subscriptions/{id}/providers/Microsoft.CostManagement/query` at **api-version `2023-11-01`** — endpoint + version valid (a live call returned HTTP 429, so it exists and is rate-limited); it is a **read that uses POST** (mark it `readOnly`) and must **handle 429 with backoff**. The `az costmanagement query` CLI **does not exist** — do not use it. |
| Azure Resource Graph | REST `POST /providers/Microsoft.ResourceGraph/resources` at **api-version `2022-10-01`** — 200 with live records; a **read that uses POST**. Enumerates any resource type across all regions of the subscription in one KQL query. |
| Compute (VMs / VMSS) | `Microsoft.Compute/virtualMachines` and `Microsoft.Compute/virtualMachineScaleSets` at **api-version `2024-07-01`** (200) — the confirmed direct-ARM fallback when Resource Graph does not surface a needed field. |

The following are **not** part of that confirmed run and are therefore authored **presence-fact-first**, with an explicit "confirm against your tenant" caveat wherever a specific field or command is named — never asserted as confirmed truth:

- **Azure Advisor** (`az advisor recommendation list --category Cost`) and the exact shape of a cost recommendation's savings fields. The recommendation's **presence** is the reportable signal; any dollar is copied verbatim **only** if Advisor itself returns one, with its own currency and period.
- **Per-resource-type KQL property paths** used in Resource Graph filters (e.g. `properties.diskState`, `properties.ipConfiguration`, `properties.extended.instanceView.powerState.code`). These are Azure's public resource schema, not validated in the confirmed run. Resource Graph returns the raw resource either way, so a wrong path yields *no rows* (a miss), not a false dollar — but confirm a flagged resource is truly idle before reporting it.
- **Managed disks** (`Microsoft.Compute/disks`) and **public IP addresses** (`Microsoft.Network/publicIPAddresses`) have **no confirmed direct ARM api-version** in the report, so this catalog enumerates them through the confirmed Resource Graph endpoint rather than citing an unconfirmed per-type api-version.

## 3. Check catalog

One permanent ID per check; IDs never change or get reused. "Savings figure" is either an Advisor-native dollar (copied verbatim), a provider spend dollar (context, never summed), or "presence fact" (no dollar).

| ID | Signal | Source (read-only) | Savings figure |
| --- | --- | --- | --- |
| COST-AZ-001 | VM / compute right-sizing (over-provisioned) | Azure Advisor `--category Cost` (right-size class) | Advisor $ — verbatim when Advisor returns a monthly-USD figure; else presence fact |
| COST-AZ-002 | Idle / shutdown candidates (underutilized VMs, idle resources) | Azure Advisor `--category Cost` (shutdown/idle class) | Advisor $ — verbatim when present; else presence fact |
| COST-AZ-003 | Reserved Instance purchase opportunities | Azure Advisor `--category Cost` (reserved-instance class) | Advisor $ — verbatim when present; else presence fact |
| COST-AZ-004 | Savings Plan purchase opportunities | Azure Advisor `--category Cost` (savings-plan class) | Advisor $ — verbatim when present; else presence fact |
| COST-AZ-005 | Any other Cost-category Advisor recommendation (SQL, storage, App Service, etc. — sweep) | Azure Advisor `--category Cost` (residual sweep) | Advisor $ — verbatim when present; else presence fact |
| COST-AZ-020 | Subscription month-to-date actual spend (context, not a saving) | Cost Management Query REST `2023-11-01` (`PreTaxCost`) | Provider $ (spend already incurred) — reported as context, **never** summed into savings |
| COST-AZ-021 | Unattached managed disks | Resource Graph `2022-10-01` (`microsoft.compute/disks`, `diskState == 'Unattached'`) | None (presence fact) |
| COST-AZ-022 | Unassociated public IP addresses | Resource Graph `2022-10-01` (`microsoft.network/publicipaddresses`, no `ipConfiguration`/`natGateway`) | None (presence fact) |
| COST-AZ-023 | Stopped-but-not-deallocated VMs (still billed for compute) | Resource Graph `2022-10-01` (`microsoft.compute/virtualmachines`, `PowerState/stopped`); confirmed direct ARM `2024-07-01` fallback | None (presence fact) |
| COST-AZ-024 | VMSS over-provisioning (high fixed capacity, no autoscale) | Resource Graph `2022-10-01` (`microsoft.compute/virtualmachinescalesets` + `microsoft.insights/autoscalesettings`) | None (presence fact) |
| COST-AZ-025 | Orphaned resources (unattached NICs, unused NSGs/route tables, aged snapshots) | Resource Graph `2022-10-01` (multiple types) | None (presence fact) |

## 4. Conventions

- **Identity preamble.** Every block confirms its target subscription and mints its own ARM bearer, so each block runs alone in a fresh shell and the run holds exactly one identity with no silent fallback. The confirmed auth path is `DefaultAzureCredential` → `AzureCliCredential`, so the bearer for the two POST-read endpoints (Cost Management, Resource Graph — neither has a first-class `az` command) comes from that same `az login`:

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""    # azure.subscription_id — set to the audited subscription (empty = az CLI default)
az account show --query '{subscription:id, tenant:tenantId, user:user.name}' -o json   # confirm the target BEFORE any read
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
```

  If `az account show` names a subscription/tenant/user other than the one you intend to audit, **stop** — reading the wrong subscription is a boundary violation even though every call is read-only. If minting the token fails, stop; do not fall back to a different credential. `ARM_TOKEN` travels only in `Authorization` headers — never echo it, never put it in a URL, evidence, or the report.

- **The scope rule — subscription-scoped, no per-region loop.** This is the #1 way Azure differs from AWS/GCP. AWS Compute Optimizer is regional and needs one call per active region; GCP recommendations are per-zone/region and must be looped. Azure's confirmed cost surfaces are **subscription-scoped and cross-region in a single call**, so there is **no per-region loop**:
  - **Resource Graph** returns resources across **all regions** of the subscription(s) you pass in `subscriptions[]` in one query — never iterate regions.
  - **Cost Management Query** aggregates the whole subscription scope in one POST. To widen scope, change the scope path (a management-group or billing-account scope) rather than summing subscriptions yourself; the subscription scope is the confirmed one.
  - For a **multi-subscription** estate, run once per audited subscription (Resource Graph accepts a `subscriptions[]` array; Cost Management is per-scope). **Never** blend two subscriptions' Cost Management totals into one number — report each scope's provider-returned total verbatim.

- **The 429-aware read-only POST helper.** Cost Management is tightly rate-limited (a live call returned HTTP 429); Resource Graph less so but shares the pattern. Both are reads that use POST. Honor a `Retry-After` header when present; otherwise back off `attempt² × 2` seconds up to a small cap:

```bash
arm_post() {   # $1 = full URL (with api-version), $2 = JSON body. READ that uses POST — mark readOnly in the harness.
  _url="$1"; _body="$2"; _attempt=1; _max=5
  while :; do
    _resp="$(curl -sS -D /tmp/az-hdr -w '\n%{http_code}' -X POST "$_url" \
      -H "Authorization: Bearer ${ARM_TOKEN}" -H 'Content-Type: application/json' -d "$_body")"
    _code="$(printf '%s' "$_resp" | tail -n1)"; _payload="$(printf '%s' "$_resp" | sed '$d')"
    if [ "$_code" = "429" ] && [ "$_attempt" -lt "$_max" ]; then
      _ra="$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' /tmp/az-hdr | head -n1)"
      sleep "${_ra:-$((_attempt * _attempt * 2))}"; _attempt=$((_attempt + 1)); continue
    fi
    printf '%s' "$_payload"; return 0
  done
}
RG_URL="https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
rg_query() {   # $1 = KQL; wraps it in the CONFIRMED body shape {subscriptions:[...], query:"..."}
  _kql="$1"
  arm_post "$RG_URL" "$(jq -n --arg s "$SUB" --arg q "$_kql" '{subscriptions:[$s], query:$q}')" \
    | jq '{count: .count, rows: .data}'
}
```

  A persistent 429 after the backoff exhausts → report the affected check `blocked, reason: "Cost Management throttled (429) after retries"`, never a guessed `0` and never a fabricated figure.

- **Cheap estate-sizing list note.** Before the deep per-resource pulls, size the estate with **one** Resource Graph count — a single cross-region `readOnly` POST, the same cheap call the deeper blocks reuse — and feed that number into the SKILL's estate-sizing checkpoint (small ≤100 / medium 101–500 / large 501–2000 / xlarge >2000). This never enumerates per resource, so it stays cheap even on a large subscription:

```bash
# One POST returns the whole subscription's cost-bearing object count, grouped by type — the sizing input.
rg_query "Resources | where type in~ ('microsoft.compute/disks','microsoft.network/publicipaddresses','microsoft.compute/virtualmachines','microsoft.compute/virtualmachinescalesets','microsoft.network/networkinterfaces','microsoft.compute/snapshots') | summarize count() by type"
```

  On the large/xlarge path the per-check blocks below run against the scoped set in bounded batches; the report names any region or resource class the user scoped out.

- **Copy the dollar verbatim; never normalize against a price table.** The only savings number that may reach a finding is Advisor's own amount, read directly from its recommendation response (section 6). See section 1 for the currency/period guard.

- **Read-only by effect, not verb.** The Cost Management and Resource Graph `/query` endpoints are **reads that use HTTP POST** — mark them `readOnly` in the harness; never confuse the POST verb with a write (the validation harness had to be fixed for exactly this). Conversely, `az advisor recommendation disable` looks administrative but **mutates** Advisor's suppression state and is forbidden (section 13). Every call this catalog makes is a `show`/`list`/`get`, or a POST explicitly marked `readOnly`.

- **Thresholds and windows are examples; tune to your workloads.** Snapshot-age, VMSS fixed-capacity, and idle-day defaults are starting points, not law.

## 5. Doctor-gate dependency

`audit-cost`'s doctor gate runs one cheap read-only cost-permission probe per configured provider and writes a matrix row. A **missing cost scope EXCLUDES the affected check(s) with the doctor's stated reason** — it never fails the run and never guesses a value. Read the row this run wrote:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # this run's doctor gate, or the most recent
[ -f "$MATRIX" ] || { echo "no doctor matrix; run the doctor gate before the Azure cost phase"; exit 1; }
awk -F'\t' '$1 == "azure" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"   # e.g. "pass -" or "skipped <reason>"
```

The scope splits three ways, so a partial block excludes only what it must rather than the whole Azure phase:

| Scope group | Checks that need it | Probe | On missing scope |
| --- | --- | --- | --- |
| Advisor read (native-dollar path) | COST-AZ-001…005 | `az advisor recommendation list --category Cost` returns non-403 | Those five report `excluded, reason: "<the exact hint from the matrix row>"` — never a metrics-derived estimate |
| Cost Management read (spend context) | COST-AZ-020 | Cost Management query for a 1-day `MonthToDate` window returns non-403 | Just that context row reports `excluded, reason: "Cost Management query denied (needs Cost Management Reader or Billing Reader)"` — never a computed dollar |
| Subscription `Reader` + Resource Graph (already needed for the scored audit) | COST-AZ-021…025 | covered by the base audit doctor probe (`az account show` + a Resource Graph read succeed) | run even when the two scopes above are missing — state the split explicitly, never exclude the whole phase for a partial block |

A `skipped` on the `azure cost-permissions` row means COST-AZ-001 through COST-AZ-005 render exactly one line: "Azure Advisor cost checks: excluded, reason: `<the exact hint from the matrix row>`", and none of them runs this cycle. The **presence-fact** checks (COST-AZ-021…025) need only the `Reader` role plus Resource Graph, which the scored audit already requires, so they still run when the Advisor and Cost Management scopes are missing — say so rather than excluding the whole section when only the native-dollar or spend-context part is blocked.

## 6. The Advisor extraction (shared by COST-AZ-001 to COST-AZ-005)

Advisor is the one place Azure itself may attach a **native savings figure**. This surface was **not** exercised in the confirmed validation run, so treat the recommendation's **presence** as the reportable fact, and copy a dollar **only** if Advisor returns one — verbatim, with its own currency and period, never computed. Pull the full `--category Cost` set once; the per-check sections below only classify what came back:

```bash
set -eu
# --category Cost filters to Advisor's cost recommendations. Print the whole recommendation including
# its extendedProperties: Azure documents cost recommendations as carrying an impact and (for many types)
# an own savings amount, but the exact key varies by recommendation type and was NOT validated here —
# so emit the raw object and copy ONLY what Advisor itself returns, verbatim.
az advisor recommendation list --category Cost -o json 2>/tmp/adv-err \
  | jq '[.[] | {
      id: .id,
      impacted_resource: (.impactedValue // .resourceMetadata.resourceId // null),
      resource_type: (.impactedField // null),
      impact: .impact,
      problem: (.shortDescription.problem // null),
      solution: (.shortDescription.solution // null),
      extended_properties: .extendedProperties }]' \
  || echo "COST-AZ-001..005 excluded: az advisor recommendation list --category Cost denied/unavailable — $(cat /tmp/adv-err)"
```

**Expected & failure meaning.** Zero or more recommendations, each naming the impacted resource, Advisor's `impact` (`High`/`Medium`/`Low`), and an `extended_properties` object. Where that object contains Advisor's own **monthly-USD** savings amount, copy it verbatim into `estimated_monthly_savings_usd` and set `savings_source: azure-advisor`; where Advisor gives an **annual** or **non-USD** figure, record it verbatim in the finding body with its own unit/currency and leave `estimated_monthly_savings_usd` unset (never divide an annual figure to fabricate a monthly one). Where Advisor gives no figure at all, the recommendation is still a presence fact worth reporting (e.g. "Advisor recommends shutting down VM `x`") — just with no dollar. A permission error or no Advisor data → `excluded` with the reason, never a guessed `0`.

- ❌ `COST-AZ-001: Advisor flags vm-api Underutilized; sizing down to Standard_D2s_v5 saves ~$120/mo per the public price list.`
- ✅ `COST-AZ-001: Advisor rates vm-api "Underutilized" (impact Medium), recommends Standard_D2s_v5; estimated_monthly_savings_usd = 120.00, copied verbatim from Advisor's own recommendation (savings_source: azure-advisor).`

## 7. Right-sizing and idle/shutdown recommendations (COST-AZ-001, COST-AZ-002)

Classify the section 6 pull. The exact sub-type/category field on an Advisor recommendation was **not** validated in the confirmed run, so classify best-effort by the `solution`/`problem` text and `extended_properties` keys, and confirm the resource before reporting — a recommendation that does not clearly classify still lands under the residual sweep (COST-AZ-005), so nothing is dropped.

- **COST-AZ-001** — right-sizing: Advisor recommends a smaller SKU for an over-provisioned resource (VM, VM scale set, disk, database). Carry the current → recommended shape into the finding where Advisor gives it, and Advisor's own monthly-USD figure where present.
- **COST-AZ-002** — idle / shutdown: Advisor recommends shutting down or deleting an underutilized/idle resource. Carry the subtype (shut down vs delete) so the reader knows whether the action is reversible.

```bash
# Right-size class (COST-AZ-001): solution mentions resizing / SKU change.
jq --argjson recs "$(az advisor recommendation list --category Cost -o json 2>/dev/null || echo '[]')" \
  -n '$recs | map(select((.shortDescription.solution // "") | test("(?i)resize|right.?size|sku|underutil"))) 
      | map({resource: (.impactedValue // .resourceMetadata.resourceId), impact, solution: .shortDescription.solution, extended_properties: .extendedProperties})'

# Idle / shutdown class (COST-AZ-002): solution mentions shutdown / delete / idle.
jq --argjson recs "$(az advisor recommendation list --category Cost -o json 2>/dev/null || echo '[]')" \
  -n '$recs | map(select((.shortDescription.solution // "") | test("(?i)shut ?down|deallocate|delete|idle"))) 
      | map({resource: (.impactedValue // .resourceMetadata.resourceId), impact, solution: .shortDescription.solution, extended_properties: .extendedProperties})'
```

**Expected & failure meaning.** Each classified recommendation names one resource, its `impact`, and — where Advisor returns one — its own monthly-USD figure copied verbatim into `estimated_monthly_savings_usd`. A resource Advisor rates idle that your team knows is a warm standby is a false positive to **annotate**, not silently drop — record why it stays. Where Advisor gives no figure, the recommendation is a presence fact with no dollar. A resource that also appears as a presence fact below (COST-AZ-021…025) is counted **once** under whichever view carries the Advisor dollar — annotate the overlap, never double-count.

## 8. Commitment recommendations — Reserved Instances and Savings Plans (COST-AZ-003, COST-AZ-004)

Advisor surfaces commitment purchase opportunities in the same `--category Cost` set. A **commitment is a spend decision**, so these findings are advisory-only and must name the term Advisor assumed (1-year vs 3-year changes the number) and whether the figure is monthly or annual before any dollar is copied.

```bash
# Reserved Instance class (COST-AZ-003).
jq --argjson recs "$(az advisor recommendation list --category Cost -o json 2>/dev/null || echo '[]')" \
  -n '$recs | map(select(((.shortDescription.solution // "") + (.shortDescription.problem // "")) | test("(?i)reserv"))) 
      | map({resource: (.impactedValue // .resourceMetadata.resourceId), impact, solution: .shortDescription.solution, extended_properties: .extendedProperties})'

# Savings Plan class (COST-AZ-004).
jq --argjson recs "$(az advisor recommendation list --category Cost -o json 2>/dev/null || echo '[]')" \
  -n '$recs | map(select(((.shortDescription.solution // "") + (.shortDescription.problem // "")) | test("(?i)savings ?plan"))) 
      | map({resource: (.impactedValue // .resourceMetadata.resourceId), impact, solution: .shortDescription.solution, extended_properties: .extendedProperties})'
```

**Expected & failure meaning.** COST-AZ-003/004 describe a reservation or savings-plan purchase Advisor projects a saving for, over a stated commitment term. Copy Advisor's own figure into `estimated_monthly_savings_usd` **only** when Advisor gives a monthly-USD amount; if it gives an annual amount (Azure Reservations and Savings Plans are commonly quoted per-year or over the full term), or a non-USD currency, record that native figure verbatim in the finding body with its own unit/currency/period and leave `estimated_monthly_savings_usd` unset — never divide a term or annual figure down to a month, and never convert a foreign currency yourself. Every commitment finding names the term Advisor assumed (1-year vs 3-year) and whether the quoted figure is monthly, annual, or whole-term, so the reader is never handed a bare number with no period. If the Advisor scope is missing (section 5), COST-AZ-003/004 report `excluded` with the doctor's reason, never a modeled commitment saving.

- ❌ `COST-AZ-003: Advisor suggests a 3-year VM reservation; at list price that is roughly $9,000/yr, so ~$750/mo saved.`
- ✅ `COST-AZ-003: Advisor recommends a 3-year Reserved Instance for the Standard_D-family in West US; Advisor's own projected saving is $9,000 over the 3-year term (native figure, quoted verbatim; term = 3yr) — estimated_monthly_savings_usd left unset because Advisor did not return a monthly-USD figure. Advisory only: purchasing spends money and is a human decision (COST-AZ-003 never triggers a purchase).`

## 9. Residual Cost-category Advisor sweep (COST-AZ-005)

New Advisor cost recommendation types appear over time (SQL, storage, App Service, Cosmos DB, Data Explorer, and others). Rather than hardcode a classifier that silently goes stale, COST-AZ-005 sweeps up **every** `--category Cost` recommendation from the section 6 pull that sections 7 and 8 did not already classify, so nothing surfaced by Advisor is dropped on the floor:

```bash
# Residual sweep (COST-AZ-005): everything in the Cost set NOT matched by the right-size, idle, RI, or savings-plan classifiers.
jq --argjson recs "$(az advisor recommendation list --category Cost -o json 2>/dev/null || echo '[]')" \
  -n '$recs
      | map(select((((.shortDescription.solution // "") + (.shortDescription.problem // ""))
            | test("(?i)resize|right.?size|sku|underutil|shut ?down|deallocate|delete|idle|reserv|savings ?plan")) | not))
      | map({resource: (.impactedValue // .resourceMetadata.resourceId), resource_type: .impactedField, impact, problem: .shortDescription.problem, solution: .shortDescription.solution, extended_properties: .extendedProperties})'
```

**Expected & failure meaning.** Zero or more recommendations that did not fit the earlier classes — each still names one impacted resource, its `impact`, and Advisor's own text. Copy a dollar into `estimated_monthly_savings_usd` **only** if Advisor returns a monthly-USD figure for it, verbatim; otherwise it is a presence fact. This keeps emerging Advisor cost types in scope **only when Azure actually surfaces a recommendation for them** — the honest alternative to inventing a saving for a resource type the platform has not flagged. If the Advisor scope is missing, this row is `excluded` along with COST-AZ-001…004.

## 10. Subscription month-to-date spend — context only (COST-AZ-020)

This is **context, not a savings figure**: it shows where the money is actually going so the ranked opportunities above have a denominator, but actual spend never populates `estimated_monthly_savings_usd`. There is **no** `az costmanagement query` CLI command — the confirmed path is the Cost Management Query REST API (`2023-11-01`), a `readOnly` POST that is tightly rate-limited, so it goes through the section 4 `arm_post` helper (429 backoff). Reuse the section 4 preamble (`SUB`, `ARM_TOKEN`, `arm_post`):

```bash
set -eu
# Self-contained: the section-4 identity preamble + arm_post helper, repeated so this block runs alone.
AZ_SUBSCRIPTION_CFG=""    # azure.subscription_id (empty = az CLI default)
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
ARM_TOKEN="$(az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)"
arm_post() {   # READ that uses POST (readOnly); honor Retry-After / back off on 429
  _url="$1"; _body="$2"; _attempt=1; _max=5
  while :; do
    _resp="$(curl -sS -D /tmp/az-hdr -w '\n%{http_code}' -X POST "$_url" -H "Authorization: Bearer ${ARM_TOKEN}" -H 'Content-Type: application/json' -d "$_body")"
    _code="$(printf '%s' "$_resp" | tail -n1)"; _payload="$(printf '%s' "$_resp" | sed '$d')"
    if [ "$_code" = "429" ] && [ "$_attempt" -lt "$_max" ]; then
      _ra="$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' /tmp/az-hdr | head -n1)"
      sleep "${_ra:-$((_attempt * _attempt * 2))}"; _attempt=$((_attempt + 1)); continue
    fi
    printf '%s' "$_payload"; return 0
  done
}
# READ that uses POST (readOnly) — subscription-scoped, whole month-to-date, one call, no per-region loop.
CM_URL="https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
CM_BODY='{"type":"ActualCost","timeframe":"MonthToDate","dataset":{"granularity":"None","aggregation":{"totalCost":{"name":"PreTaxCost","function":"Sum"}}}}'
arm_post "$CM_URL" "$CM_BODY" \
  | jq '{columns: [.properties.columns[].name], rows: .properties.rows}' \
  || echo "COST-AZ-020 excluded: Cost Management query denied (needs Cost Management Reader or Billing Reader)"
```

**Expected & failure meaning.** The response's `rows` carry the subscription's month-to-date `PreTaxCost` with its currency column — report the provider's own total **verbatim** as context, with its currency and the `MonthToDate` window, on its own COST-AZ-020 line. **Never** sum it into the savings total, and **never** blend two subscriptions' totals into one number (report each scope's total separately). A `403` → `excluded` with the doctor's reason. A persistent `429` after the section 4 backoff → `blocked, reason: "Cost Management throttled (429) after retries"` — never a guessed or `0` figure. Present spend as spend; mixing it into savings misleads a budget conversation.

## 11. Presence facts via Resource Graph (COST-AZ-021 to COST-AZ-025)

These run from the confirmed Resource Graph endpoint (`2022-10-01`) plus the subscription `Reader` role the scored audit already requires, so they still run when the Advisor and Cost Management scopes are missing. **None carries a dollar figure** — Azure returns no native cost for a bare idle resource, so each is a presence fact naming the concrete resource, its resource group, region, SKU/size, and age. The KQL `properties.*` paths below are Azure's public resource schema and were **not** validated in the confirmed run; a wrong path yields *no rows* (a miss), not a false dollar — confirm a flagged resource is truly idle before reporting it. Reuse the section 4 `rg_query` helper.

```bash
# COST-AZ-021: unattached managed disks (diskState 'Unattached' == not attached to any VM, still billed).
rg_query "Resources | where type =~ 'microsoft.compute/disks'
  | where tostring(properties.diskState) =~ 'Unattached'
  | project name, resourceGroup, location, sku=tostring(sku.name), sizeGb=toint(properties.diskSizeGB), timeCreated=tostring(properties.timeCreated)
  | order by sizeGb desc"

# COST-AZ-022: public IP addresses not associated with any config or NAT gateway (a reserved static IP is billed while idle).
rg_query "Resources | where type =~ 'microsoft.network/publicipaddresses'
  | where isnull(properties.ipConfiguration) and isnull(properties.natGateway)
  | project name, resourceGroup, location, sku=tostring(sku.name), allocation=tostring(properties.publicIPAllocationMethod), ip=tostring(properties.ipAddress)"

# COST-AZ-023: VMs stopped but NOT deallocated — 'PowerState/stopped' is still billed for compute; 'PowerState/deallocated' is not.
# powerState path is unconfirmed public schema; if RG does not surface instanceView, the confirmed direct ARM 2024-07-01 GET is the fallback.
rg_query "Resources | where type =~ 'microsoft.compute/virtualmachines'
  | extend powerState = tostring(properties.extended.instanceView.powerState.code)
  | where powerState == 'PowerState/stopped'
  | project name, resourceGroup, location, vmSize=tostring(properties.hardwareProfile.vmSize), powerState"

# COST-AZ-024: VMSS with fixed capacity and no autoscale setting targeting it (candidate over-provisioning).
rg_query "Resources | where type =~ 'microsoft.compute/virtualmachinescalesets'
  | project vmssId=tolower(id), name, resourceGroup, location, sku=tostring(sku.name), capacity=toint(sku.capacity)
  | join kind=leftouter (
      Resources | where type =~ 'microsoft.insights/autoscalesettings'
      | project targetId=tolower(tostring(properties.targetResourceUri))
    ) on \$left.vmssId == \$right.targetId
  | where isnull(targetId)
  | project name, resourceGroup, location, sku, capacity"

# COST-AZ-025: orphaned resources — unattached NICs, NSGs/route tables associated with nothing, and snapshots (age vs the team's stated retention).
rg_query "Resources | where type =~ 'microsoft.network/networkinterfaces' and isnull(properties.virtualMachine)
  | project kind='orphaned-nic', name, resourceGroup, location
  | union (Resources | where type =~ 'microsoft.network/networksecuritygroups'
      | where array_length(properties.networkInterfaces) == 0 and array_length(properties.subnets) == 0
      | project kind='unused-nsg', name, resourceGroup, location)
  | union (Resources | where type =~ 'microsoft.compute/snapshots'
      | project kind='snapshot', name, resourceGroup, location, sizeGb=toint(properties.diskSizeGB), timeCreated=tostring(properties.timeCreated))"
```

**Expected & failure meaning.** Any non-empty `rows` is a presence-fact finding, each line naming one concrete resource with its resource group, region, SKU/size, and (where present) age — **no dollar attached**. COST-AZ-021 and COST-AZ-022 are the presence-fact counterparts to Advisor's native-dollar right-size/idle findings: a resource that appears here *and* carries an Advisor dollar is reported once under the Advisor view with its figure; the rest stay here as presence facts, so a partial Advisor scope never drops a real idle resource. For COST-AZ-023, `PowerState/stopped` means still-billed (the actionable case); a `PowerState/deallocated` VM is not billed for compute and is **not** flagged. For COST-AZ-025 snapshots, compare age against the team's **own** stated retention (from business context) — never an assumed default; if the team has not stated one, say so in the finding rather than picking a number for them. Empty `rows` for any check is "checked, nothing found", not an error.

## 12. Rendering the section

Every finding here uses `area: cost-optimization`, `points_recoverable: 0`, and is **report-only**: the `recommendation` states the concrete action and the exact Azure portal / `az` path to take it (e.g. "act on this Advisor recommendation from Cost Management + Advisor in the portal"), and the audit never resizes, stops, deletes, deallocates, or purchases anything — those are the mutating verbs in section 13. It carries **no** `setup-*` remediation pointer, because acting on a cost recommendation (resizing, deleting, or deallocating live infrastructure, or committing spend) is materially riskier than a reliability fix and stays a human decision. Findings render under this parallel section's own heading, never in the scored Findings table.

**Open the section with the savings-summary line**, per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule, built **only** from Advisor-sourced `estimated_monthly_savings_usd` values already on the findings (USD, monthly-window figures only):

> **Potential savings: ~$&lt;sum&gt;/month (~$&lt;sum×12&gt;/year)** across **&lt;n&gt;** opportunities with an Azure Advisor figure; **&lt;m&gt; more** found with no dollar figure (presence facts, listed below). Largest single lever: **$&lt;max&gt;/mo** — &lt;that finding's one-line action&gt;.

Sum only figures copied verbatim from Advisor where the amount was **monthly** and denominated in **USD**; the annual number is `monthly × 12`, labelled an estimate (`~`, "potential"). State the count *with* a figure separately from the count *without* one, so `$<sum>` is never read as the whole story. Any annual, whole-term, or non-USD Advisor figure is listed with its own currency/period and is **not** folded into the USD total. The COST-AZ-020 month-to-date spend is reported as context on its own line and is **never** part of the savings sum. If no row carries an Advisor figure, write "&lt;n&gt; opportunities found; no Azure-sourced dollar figures available — each is a presence fact to review", never `$0`.

Then render the per-row table, columns `Finding | Resource (RG / region) | Signal source | Current → recommended | Est. monthly savings (Azure-sourced) | Est. annual | Action`. `Current → recommended` shows the shape change where Advisor gives it (`Standard_D4s_v5 → Standard_D2s_v5`, `unattached 30+ days → delete`), else `-`. A row with no Azure-sourced savings figure prints `-` in the savings columns rather than a blank, so it reads as "checked, no number available" rather than "forgot to fill this in".

## 13. Commands this audit must never run

Any of these in an audit transcript is a lane violation, whatever the justification:

- `az advisor recommendation disable` and any `PATCH`/`PUT`/`POST` to `Microsoft.Advisor/.../suppressions` — these mutate Advisor's suppression/lifecycle state on Azure's side. The audit only `list`s Advisor recommendations.
- Any `POST`/`PUT`/`PATCH`/`DELETE` to `management.azure.com` that is **not** one of the two explicitly `readOnly`-marked query endpoints (Resource Graph `/resources`, Cost Management `/query`). A POST verb alone is never a license to mutate.
- `az vm start|stop|deallocate|delete|restart|resize|update`, `az vmss start|stop|deallocate|delete|scale|update` — acting on an idle/right-sizing recommendation is a setup-lane change, never an audit action.
- `az disk delete|update`, `az snapshot delete|create`, `az image delete`.
- `az network public-ip delete|update`, `az network nic delete`, `az network nsg delete`, `az network route-table delete`.
- `az reservations reservation-order purchase`, `az billing ...` mutations, any Savings Plan purchase — **purchasing a reservation or savings plan spends money**; COST-AZ-003/004 are advisory only.
- `az sql db update|delete`, `az cosmosdb update|delete`, and any tier/throughput change acting on a COST-AZ-005 database recommendation.
- `az aks scale|update|delete` and any node-pool mutation acting on an AKS cost recommendation.
- `az account set` (mutates shared local az state; this audit passes the explicit `SUB` + minted `ARM_TOKEN` instead), `az login`, `az logout`, `az account clear`.
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`.
