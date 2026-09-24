# Cloud Mode — Azure resources and service→resource edges

Command recipes for map-topology's **Cloud Mode** on Azure: App Service /
Functions / Container Apps as the service side; Azure SQL, PostgreSQL/MySQL
flexible servers, Cache for Redis, Cosmos DB, Service Bus, Event Hubs, and
Storage as the resource side; managed-identity role assignments, private
endpoints, and Service Connector as the connecting threads.

**Verification status: live-proven core (2026-09-21), app-lane first rows
owed.** The identity gate, all eight catalog reads, the private-endpoint pass,
and the webapp/functionapp enumerations ran clean against a real
subscription; the extension-absence guard was exercised for real
(containerapp CLI extension missing — the block skips and the gap is
recorded). The managed-identity, Service Connector, Container Apps, elevated,
App Insights, and VNet-flow-log blocks remain doc-verified only because that
subscription runs no App-Service-family apps (nor Traffic Analytics) — on their first live rows, confirm the
output shape before trusting a surprising result.

**Shared rules** (identical across clouds, defined once in
[cloud-mode-aws.md](cloud-mode-aws.md)): evidence classes, the composition
and confidence table, review tiers, and the redaction discipline. Everything
below is read-only. No secret-value permission is requested in the default
lanes; the one exception is the explicitly opt-in elevated lane below, and
even it never touches Key Vault secret values.

## Identity and access gate

The `azure` block names one `subscription_id` per run (a labeled list runs
once per label, like every multi-target integration). Auth is your `az login`
session; pass `--subscription` explicitly on every call — never trust the CLI
default:

```bash
set -eu
AZ_SUB="your-subscription-id"       # from toolkit.yaml azure.subscription_id (resolved in Phase 0)
az account show --subscription "$AZ_SUB" --output json \
| jq -e '.id' >/dev/null || { echo "Azure identity check failed — run az login / fix the azure block"; exit 1; }
az account show --subscription "$AZ_SUB" --output json | jq -r '"subscription: " + .name + " (" + .id + ")  tenant: " + .tenantId'
# Reader-tier is the default posture. Probe the ELEVATED config lane only when the
# operator explicitly opted in (see "Elevated lane"): a denial here is an answer.
```

## Resource endpoint catalog

`kind  id  endpoint_host  endpoint_port  engine  logical_names`, one call per
resource family (each returns the endpoint field Reader-tier):

```bash
set -eu
AZ_SUB="your-subscription-id"
CAT="${TMPDIR:-/tmp}/cloudmode-az-catalog.tsv"; : > "$CAT"
az sql server list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | ["database", .name, .fullyQualifiedDomainName, "1433", "sqlserver", "-"] | @tsv' >> "$CAT"
az postgres flexible-server list --subscription "$AZ_SUB" --output json 2>/dev/null \
| jq -r '.[] | ["database", .name, .fullyQualifiedDomainName, "5432", "postgres", "-"] | @tsv' >> "$CAT" || true
az mysql flexible-server list --subscription "$AZ_SUB" --output json 2>/dev/null \
| jq -r '.[] | ["database", .name, .fullyQualifiedDomainName, "3306", "mysql", "-"] | @tsv' >> "$CAT" || true
az redis list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | ["cache", .name, .hostName, (.sslPort|tostring), "redis", "-"] | @tsv' >> "$CAT"
az cosmosdb list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | ["database", .name, (.documentEndpoint | sub("^https://";"") | sub("/$";"")), "443", "cosmosdb", "-"] | @tsv' >> "$CAT"
az servicebus namespace list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | ["message_queue", .name, (.serviceBusEndpoint | sub("^https://";"") | sub("[:/].*$";"")), "5671", "servicebus", "-"] | @tsv' >> "$CAT"
az eventhubs namespace list --subscription "$AZ_SUB" --output json 2>/dev/null \
| jq -r '.[] | ["message_queue", .name, (.serviceBusEndpoint | sub("^https://";"") | sub("[:/].*$";"")), "9093", "eventhubs", "-"] | @tsv' >> "$CAT" || true
az storage account list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | ["object_storage", .name, (.primaryEndpoints.blob // "" | sub("^https://";"") | sub("/$";"")), "443", "blob", .name] | @tsv' >> "$CAT"
sort -u "$CAT" -o "$CAT"; echo "catalog rows: $(wc -l < "$CAT" | tr -d ' ')"
```

Queue/topic logical names (per Service Bus namespace, bounded to catalog
rows): `az servicebus queue list` / `az servicebus topic list
--namespace-name <ns> --resource-group <rg>`.

## Permitted lane: managed-identity role assignments

Azure's strongest Reader-tier thread: a role assignment's `scope` IS the
target resource's full ARM id. Per in-scope app (dedupe principals first):

```bash
set -eu
AZ_SUB="your-subscription-id"; RG="your-resource-group"; APP="your-app-name"
PID=$(az webapp identity show --subscription "$AZ_SUB" --resource-group "$RG" --name "$APP" --query principalId --output tsv 2>/dev/null || true)
# functionapp / containerapp variants: az functionapp identity show / az containerapp identity show
[ -n "$PID" ] && az role assignment list --subscription "$AZ_SUB" --assignee "$PID" --all --output json \
| jq -r '.[] | [.roleDefinitionName, .scope] | @tsv' \
  || echo "no managed identity on ${APP} — permitted lane empty for it (password/connection-string auth likely; declared lane needed)"
```

Verb-to-relation mapping mirrors the AWS table: a data-plane role on a
storage account (`Storage Blob Data *`) → `USES`; on Service Bus
(`Azure Service Bus Data Sender/Receiver`) → `PUBLISHES_TO`/`SUBSCRIBES_TO`;
on Cosmos/SQL → `STORES_DATA_IN`; on Key Vault → `CONFIGURED_BY`. A
subscription- or resource-group-scoped assignment is the wildcard case:
demote per the shared rule, never fan out.

## Declared configuration

Reader-tier declared sources, strongest first:

```bash
set -eu
AZ_SUB="your-subscription-id"; RG="your-resource-group"; APP="your-app-name"
# (1) Service Connector: first-class declared links, target id included
az webapp connection list --subscription "$AZ_SUB" --resource-group "$RG" --name "$APP" --output json 2>/dev/null \
| jq -r '.[] | [.name, (.targetService.id // .targetService.resourceId // "-")] | @tsv' || echo "service-connector: none/unavailable — skipping"
# (2) Container Apps: template env (+ serviceBinds) are Reader-visible — same redaction
#     discipline as every declared lane (secret-named keys skipped, secretRef recorded
#     as a reference, userinfo stripped before host capture, extractions never printed)
az containerapp list --subscription "$AZ_SUB" --output json 2>/dev/null \
| jq -r '.[] | .name as $app
  | (.properties.template.containers[]? .env // [])[]
  | select(.secretRef == null)
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?"; "g")
  | [$app, $k, .h, (.p // "-")] | @tsv' 2>/dev/null \
  | sort -u > "${TMPDIR:-/tmp}/cloudmode-az-extract.tsv" || true
[ -f "${TMPDIR:-/tmp}/cloudmode-az-extract.tsv" ] && echo "containerapp extraction rows: $(wc -l < "${TMPDIR:-/tmp}/cloudmode-az-extract.tsv" | tr -d ' ')"
# (3) secretRef entries are CONFIGURED_BY evidence + a name-join hint (never resolved)
```

## Elevated lane (opt-in only): App Service app settings

App Service settings/connection strings are the best declared coverage but
reading them is `Microsoft.Web/sites/config/list/Action` — a POST that
returns live values, which the Reader role deliberately lacks. This lane runs
ONLY when the operator explicitly opted in for this run (an explicit yes in
the session — never a default, never inferred from a working credential):

```bash
set -eu
AZ_SUB="your-subscription-id"; RG="your-resource-group"; APP="your-app-name"
# OPT-IN GATE: the operator explicitly approved reading app settings this run.
az webapp config appsettings list --subscription "$AZ_SUB" --resource-group "$RG" --name "$APP" --output json 2>/dev/null \
| jq -r '.[] 
  | select(.name | test("(?i)password|passwd|secret|token|api_?key|private|credential") | not)
  | .name as $k | (.value // "") | gsub("://[^@/]*@"; "://")
  | capture("(?<h>[A-Za-z0-9][A-Za-z0-9.-]+\\.[A-Za-z]{2,})(:(?<p>[0-9]{2,5}))?"; "g")
  | [$k, .h, (.p // "-")] | @tsv' 2>/dev/null | sort -u > "${TMPDIR:-/tmp}/cloudmode-az-appsettings.tsv" \
  || { echo "app-settings read denied — staying at Reader tier (this is the expected posture, not an error)"; : > "${TMPDIR:-/tmp}/cloudmode-az-appsettings.tsv"; }
echo "app-settings extraction rows: $(wc -l < "${TMPDIR:-/tmp}/cloudmode-az-appsettings.tsv" | tr -d ' ')"
```

Your security team can grant exactly this with a one-action custom role on top of
Reader; the map header records whether the elevated lane ran.

## Reachable lane: network joins

One Reader-tier pass each:

```bash
set -eu
AZ_SUB="your-subscription-id"
# Private endpoints: the connection names the exact target resource id
az network private-endpoint list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | .name as $pe | (.privateLinkServiceConnections // [])[] 
  | select((.privateLinkServiceConnectionState.status // "") == "Approved")
  | [$pe, .privateLinkServiceId, ((.groupIds // []) | join(","))] | @tsv'
# App VNet integration: subnet placement corroborates private-endpoint reachability
az webapp list --subscription "$AZ_SUB" --output json \
| jq -r '.[] | select(.virtualNetworkSubnetId != null) | [.name, .virtualNetworkSubnetId] | @tsv'
```

An Approved private endpoint whose `privateLinkServiceId` matches a catalog
resource, in a subnet an app integrates with, is `reachable` corroboration —
same composition rules as everywhere.

**Public-IP allowlist openings** (when the estate exposes them): Azure SQL
server firewall rules (`az sql server firewall-rule list` →
`startIpAddress`/`endIpAddress`) and storage-account `ipRules` are recorded as
*unattributed* openings — host `/32` only, a wide range is a finding. When
another cloud is also configured, those host openings feed the cross-cloud
attribution pass (shared rules, cookbook: "Cross-cloud IP attribution" in the
AWS cookbook); extend its combined catalog with Azure public IPs
(`az network public-ip list`). Verification status: the pattern is the shared
one; the first Azure↔other-cloud attribution row is owed on a live estate that
has one.

## Observed lane: VNet flow logs

Connection metadata only, no secrets, no config access — the current-gen
Azure path (NSG flow logs retire 2027-09-30 and already refuse new creation;
document the VNet path only). Needs a VNet flow log with **Traffic Analytics**
enabled writing to Log Analytics; storage-only flow logs are not KQL-queryable:

```bash
set -eu
AZ_SUB="your-subscription-id"; AZ_REGION="your-region"   # Network Watcher is per-region
# Discovery: does a VNet flow log with Traffic Analytics exist here?
FLB=$(az network watcher flow-log list --location "$AZ_REGION" --subscription "$AZ_SUB" --output json 2>/dev/null) || FLB=""
[ -n "$FLB" ] && WSID=$(printf '%s' "$FLB" | jq -r '[.[] | select(.enabled == true)
  | .flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration
  | select(.enabled == true)] | .[0].workspaceId // empty') || WSID=""
[ -n "$WSID" ] || { echo "vnet flow logs: none with Traffic Analytics in ${AZ_REGION} — skipping (the unlock: enable a VNet flow log with Traffic Analytics on the networks that matter)"; exit 0; }
# Bounded KQL on the NTANetAnalytics table (needs the log-analytics CLI extension;
# -w takes the workspace GUID from the flow-log config above, not an ARM id)
TB=$(az monitor log-analytics query -w "$WSID" --subscription "$AZ_SUB" \
  --analytics-query "NTANetAnalytics | where SubType == 'FlowLog' and FlowStatus == 'A' | summarize Bytes=sum(BytesSrcToDest) by SrcIp, DestIp, DestPort, FlowDirection | top 100 by Bytes" \
  -t P1D --output json 2>/dev/null) || TB=""
[ -n "$TB" ] && printf '%s' "$TB" | jq -r '.[] | [(.SrcIp // "-"), (.DestIp // "-"), ((.DestPort // 0)|tostring), (.FlowDirection // "-"), ((.Bytes // 0)|tostring)] | @tsv' | head -40 \
  || echo "traffic-analytics query unavailable (extension missing or access denied) — skipping; the gap is recorded in the map header"
```

Join rules: match `DestIp:DestPort` against the endpoint catalog and resolve
the other side through the estate's address table (`SrcVm`/`DestVm`/`SrcNic`
columns help when populated). Caveats (all doc-verified): records are
AGGREGATED per interval (a record is not one flow — never present record
counts as connection counts); `SrcIp`/`DestIp` are BLANK for public flow
types (the public addresses live in separate bar-separated columns — note
them, never guess identities from them); keep `SubType == 'FlowLog'` in every
query. Verification status: doc-verified with exact official schema; first
live rows owed with the rest of this cookbook's app lanes.

## Observed lane: Application Insights dependencies

Availability-gated (needs App Insights + a Log Analytics workspace +
`az monitor log-analytics query` access). Capture-then-branch, skip clean:

```bash
set -eu
WS="your-log-analytics-workspace-id"     # from the azure block when configured
AIB=$(az monitor log-analytics query --workspace "$WS" \
  --analytics-query "AppDependencies | where TimeGenerated > ago(24h) | summarize by AppRoleName, Target, DependencyType | limit 200" \
  --output json 2>/dev/null) || AIB=""
[ -n "$AIB" ] && printf '%s' "$AIB" | jq -c '.tables[0].rows[]?' \
  || echo "app-insights dependencies: unavailable/not configured — skipping (observed lane)"
```

`Target` carries the dependency host (joins the catalog); `DependencyType`
(SQL/Azure blob/HTTP) selects the relation. Observed edges expire per the
shared TTL rule.

## Traps

- Azure CLI output shapes vary with CLI/extension versions more than other
  clouds; the doc-verified banner above applies to every block here.
- `flexible-server` commands may require the CLI extension; the `|| true`
  guards keep an absent extension from killing the catalog — but record the
  gap in the map header ("postgres flexible servers not enumerated").
- Dead ends (do not build on): Service Map is retired; VM-insights Map is
  closed to new onboarding. App Insights `AppDependencies` is the supported
  observed source.
- A working `az` login is TENANT-wide: the identity gate pins the
  subscription per run; never enumerate other subscriptions than the labeled
  one.
- Key Vault: reference names are join hints; secret VALUES are never read —
  the elevated lane covers app settings only, not vault contents.

## Bounded reads

| Lane | Cost | Bound |
| --- | --- | --- |
| Catalog | ~8 list calls | fixed per subscription |
| Role assignments | 2 calls per in-scope app | scope checkpoint; dedupe principals |
| Service Connector / Container Apps | 1 call per app / 1 list call | scope checkpoint |
| Private endpoints + VNet | 2 calls | fixed |
| App Insights query | 1 bounded query | skip-clean when absent |
