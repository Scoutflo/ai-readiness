---
name: setup-azure
description: Guided hardening of Azure Monitor from audit-azure findings; creates and repairs action groups, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM/VMSS alerts, AKS Container Insights and managed Prometheus, and diagnostic settings to Log Analytics, announcing each change, waiting for confirmation, then verifying live. Monitoring-plane writes only. Use when the user asks to fix an AZR-NNN finding, wire Azure alert routing, add metric or log alerts, or enable AKS monitoring. Do not use for read-only assessment (use audit-azure), for in-cluster stacks (use setup-lgtm), or for VM agent installs, network/health-probe changes, or RBAC role assignments (planned here, executed only by an identity that holds Owner/User Access Administrator).
disable-model-invocation: true
---

# setup-azure

Fixes findings from an `audit-azure` run. Input is one or more finding IDs from the latest `./scoutflo-audits/azure/<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-azure#add-metric-alerts`.

| Finding ID | Fix section |
| --- | --- |
| AZR-001, AZR-060 | [Create and wire an action group](#create-and-wire-an-action-group) |
| AZR-002 | [Add metric alerts](#add-metric-alerts) |
| AZR-003 | [Add log alerts](#add-log-alerts) |
| AZR-004 | [Add activity-log alerts](#add-activity-log-alerts) |
| AZR-010 | [Enable VM diagnostics](#enable-vm-diagnostics) |
| AZR-030, AZR-031 | [Enable AKS monitoring](#enable-aks-monitoring) |
| AZR-032, AZR-040, AZR-050 | [Enable diagnostic settings](#enable-diagnostic-settings) |
| AZR-007 | [Handle the empty-scope guardrail](#handle-the-empty-scope-guardrail) (visibility gap, not a confident fix) |
| AZR-OPT-* | [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes) (read-only guidance, no write) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**Write scope: the Monitoring plane only.** This skill creates and updates action groups, metric alerts, scheduled-query (log) alerts, activity-log alerts, and diagnostic settings, sets Log Analytics workspace retention, and enables the AKS monitoring surfaces (Container Insights, managed Prometheus). Out of write scope, always: VM/VMSS agent installs (Azure Monitor Agent, the diagnostic extension) and their Data Collection Rules, any AKS cluster change beyond monitoring enablement, editing a live Application Gateway or Load Balancer health probe, and every network, NSG, DNS, and RBAC change. Those are controlled rollouts or traffic-impacting changes owned by the people who own those surfaces; this skill records a plan with a named owner instead ([Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes)). It also never mutates local Azure CLI state: no `az account set` inside a fix block, no default-subscription flip; every command carries an explicit `--subscription` (or a `SUB` resolved from config in the same block).

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the `az` command (or JSON payload) with real values filled in — including the **rollback** command — plus its risk class. Webhook URLs, service keys, and connection strings are the exception: announce an action's display name and type, never the secret value.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change (the CLI rejects a flag, an api-version differs on your `az` version, a role assignment is refused), stop and re-announce.
4. **Verify.** Re-read the modified object and assert the outcome with `jq -e` or a captured exit code. A write is unverified until a read proves it; verification reads use the confirmed api-versions in [the change-risk classes](#the-change-risk-classes) table's source column.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

Order discipline, kept from hard experience: routing before alerts (the action group first, then the alerts that reference it), diagnostic settings before any log alert that queries the workspace they feed, AKS enablement before an alert on a metric the cluster does not ship yet. An alert created before its action group exists pages nobody and verifies dirty. Where you run parallel environments, fix the non-production subscription or resource group first and confirm the result before touching production.

## The change-risk classes

Every announcement in this skill names its class. The class decides the extra gate — and, for the RBAC class, whether the change executes here at all.

| Class | In this skill | Confirmed source for verify | Extra gate |
| --- | --- | --- | --- |
| Read-only | GET-before-write snapshots, verification reads, all cost/`AZR-OPT-*` guidance | the audit's read api-versions | none |
| Monitoring-plane write | action group create/update; metric alert; scheduled-query (log) alert; activity-log alert; diagnostic settings; Log Analytics retention | `actionGroups` **2023-01-01**, `metricAlerts` **2018-03-01**, `scheduledQueryRules` **2022-06-15**, `activityLogAlerts` **2020-10-01**, `workspaces` **2022-10-01** | announce + confirm |
| Controlled rollout | AKS Container Insights / managed Prometheus enablement (a cluster mutation) | `az aks show` → `addonProfiles.omsagent.enabled`, `azureMonitorProfile.metrics.enabled` | announce + confirm; larger blast radius; **if it triggers a role assignment and the identity is Contributor, it becomes plan-with-named-owner** |
| RBAC / role-granting | any `Microsoft.Authorization/roleAssignments/write` (grant the audit identity a role; wire a managed-identity role) | `roleAssignments` **2022-04-01** | **needs `Owner`/`User Access Administrator`**; the validation identity was **Contributor and could NOT create role assignments** (`AuthorizationFailed`), so a Contributor identity records this as **plan-with-named-owner**, never executes it |
| Traffic-impacting | editing a live App Gateway/LB health probe; NSG/DNS/network changes; VM/VMSS agent (AMA / diagnostic extension) installs | n/a | out of write scope everywhere; plan only |

**The RBAC ceiling is a real, confirmed finding, not a hypothetical.** The Azure API validation run proved the validation identity could create resources (resource groups, AKS clusters, Log Analytics workspaces all succeeded) but **could not create role assignments** — `Microsoft.Authorization/roleAssignments/write` returned `AuthorizationFailed`. So every monitoring-plane write in this skill is Contributor-capable, but any step that grants a role needs `User Access Administrator` or `Owner`. When a fix requires a role assignment and the live identity lacks that role, do not retry, do not escalate, do not treat `AuthorizationFailed` as permission to self-grant — announce it as a **plan-with-named-owner** and stop.

- ❌ `Managed Prometheus enablement hit AuthorizationFailed on roleAssignments/write, so grant the cluster identity Monitoring Data Reader myself and continue.`
- ✅ `Enablement needs a role assignment the Contributor identity cannot make; recorded as a plan for the subscription Owner (needs User Access Administrator), AZR-031 stays open until they run it.`

## Doctor gate

Elevated tier: this skill mutates Azure Monitor and Log Analytics state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Azure | `azure.subscription_id`, optional `azure.tenant_id`, optional `azure.region` | none stored; auth is `az login` (`DefaultAzureCredential` → `AzureCliCredential` fallback, confirmed) | `Monitoring Contributor` (action groups, metric/log/activity alerts, diagnostic settings) plus `Log Analytics Contributor` for workspace retention; AKS enablement needs write on the AKS resource; any **role assignment** needs `Owner`/`User Access Administrator` (Contributor is insufficient — confirmed) | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
for bin in az curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id; empty means the az CLI default subscription
# Confirmed auth path: DefaultAzureCredential -> AzureCliCredential (via az login).
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name') on subscription $(printf '%s' "$ACCT" | jq -r '.name')"
SUB="${AZ_SUBSCRIPTION_CFG:-$(printf '%s' "$ACCT" | jq -r '.id')}"
ARM_TOKEN="$(az account get-access-token --subscription "$SUB" --resource https://management.azure.com --query accessToken -o tsv)"
# One cheap ARM read at a CONFIRMED api-version proves reachability + the token works.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${ARM_TOKEN}" \
  "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01")"
echo "action-groups api: ${code}"
```

Expected: the identity line, the resolved subscription, and `action-groups api: 200`. A `401` means the token is missing or malformed (both confirmed to return 401); a `404` means the subscription id is wrong (confirmed). Editor-tier write permission cannot be introspected cheaply, so the first write of the run is the scope test: an `AuthorizationFailed` on it means the identity lacks `Monitoring Contributor` (or the role the section names). Stop, report which role is missing, point at `/scoutflo:connect`; do not keep trying other writes to find one that works. `roleAssignments/write` is a separate, higher bar — see [the change-risk classes](#the-change-risk-classes).

## Live-safety gate

Resolve the target subscription from `toolkit.yaml` itself, not from a value typed into the block, then compare it against what `az` actually resolves live. The comparison value has to come from the config file or the gate can pass on whatever the operator happened to type or whatever `az account set` left active in another terminal:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve azure.subscription_id the same way doctor.sh's cfg() reads two-level keys:
# yq when present, a sed fallback otherwise. Never hand-typed.
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CONFIG" >/dev/null 2>&1; then
  AZ_SUB_CFG="$(yq -r '.azure.subscription_id // ""' "$CONFIG")"
else
  AZ_SUB_CFG="$(sed -n '/^azure:/,/^[A-Za-z_]/p' "$CONFIG" \
    | sed -n 's/^[[:space:]]\{1,\}subscription_id:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]#.*$//' -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/[[:space:]]*$//')"
fi
[ -n "$AZ_SUB_CFG" ] || { echo "azure.subscription_id is not set in $CONFIG; run /scoutflo:connect"; exit 1; }
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
LIVE_SUB="$(printf '%s' "$ACCT" | jq -r '.id')"
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name')"
echo "config target (azure.subscription_id): ${AZ_SUB_CFG}"
echo "live subscription (az account show): ${LIVE_SUB}"
[ "$LIVE_SUB" = "$AZ_SUB_CFG" ] || { echo "STOP: az resolves subscription ${LIVE_SUB}, which does not match toolkit.yaml azure.subscription_id (${AZ_SUB_CFG}); pass --subscription ${AZ_SUB_CFG} explicitly or fix the config"; exit 1; }
echo "live-safety gate passed: az resolves the subscription toolkit.yaml names"
```

Expected: the final line prints and nothing stops the block. `AZ_SUB_CFG` is re-read from `toolkit.yaml` in this same block every time, never carried over from a prior block or from what an operator remembers running `az account set` on, so the gate cannot pass on the wrong target by construction. If the identity is not the one your team intends for setup work, or the subscription does not resolve, stop and report the mismatch. Never proceed on "probably the right subscription". Every object in this skill is addressed by the full resource id captured from the audit run (`/subscriptions/<id>/resourceGroups/<rg>/providers/...`), never by display-name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/*/ 2>/dev/null | grep -v '/runs/' | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found; run /scoutflo:audit-azure first"; exit 1; }
jq -r '.findings[] | select(.area != "cost-optimization") | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Reliability findings (`AZR-*`) only; `AZR-OPT-*` cost findings never enter this plan (see [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes)). Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown; deletions (an action group, an alert rule) and any RBAC / role-granting row are still re-confirmed individually at their announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-read the failed object's current state, report what happened, and re-announce the remainder only after the user decides. A half-applied alert (created but with no action group attached) is worse than no alert; verify or roll back the failed object before anything else runs.

**Backups are GET-before-write.** Before any update, capture the object's current state into `BACKUP_DIR` with a plain `az ... show` (or ARM GET). Backups may contain resource ids, action definitions, and connection detail; `./scoutflo-audits/` stays out of version control and out of every announcement. Rollback is re-applying the backup or deleting the created object; every section names its restore command.

`az` flag names and defaults shift across CLI versions, and the write subcommands below were **not** exercised in the confirmed validation run — only the reads and the AKS enablement result were. So for every `az` write in this skill, check the subcommand's `--help` on your version before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags (this is the change protocol's re-announce rule, not an exception to it). The api-versions cited for verification reads **are** confirmed; the write CLI shapes are the documented path, to be confirmed live before execution.

## Create and wire an action group

For `AZR-001` and `AZR-060`. Monitoring-plane write; nothing redeploys. An action group is the object a metric/log/activity alert points at so a page reaches a human — create it first, then every alert section attaches it. Name groups per environment (`<team>-<environment>-alerts`) so a page's origin is readable before its body. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of action groups; they are different webhooks with different jobs.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="observability-rg"                       # the resource group that owns the action group
AG_NAME="payments-production-alerts"        # <team>-<environment>-alerts
AG_SHORT="payprod"                          # <= 12 chars, shown in the SMS/email subject
AG_EMAIL="oncall@example.org"               # the address your team actually watches
# Create (announced first). For webhook/logic-app/SMS receivers the sensitive value rides an
# unechoed variable into --action, and the announcement shows the receiver name + type only.
az monitor action-group create --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" \
  --short-name "$AG_SHORT" --action email primary "$AG_EMAIL"
# Verify by re-read (actionGroups is confirmed at api-version 2023-01-01):
az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.enabled == true and (.emailReceivers | length) >= 1'
```

Expected: the created group and a final `jq -e` exit 0. Capture the group's resource id for the alert sections: `AG_ID="$(az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv)"`. **Rollback:** `az monitor action-group delete --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB"`, then a `show` asserting it is gone.

For `AZR-060` (alert quality), the fix is mostly attachment and hygiene, not new objects: attach this group to an alert that has none (`--add-action-groups <AG_ID>` in the relevant alert section's update), correct a mis-tiered `--severity` (0 critical … 4 verbose), and retune or remove a permanently-firing rule in its own alert section with the rule body quoted and confirmed individually. Replacing a dead receiver means creating the good one, re-pointing every referencing alert, verifying, then deleting the dead one — confirmed individually.

## Add metric alerts

For `AZR-002`. Metric alerts on platform metrics of a critical resource (App Service, SQL, Storage, Cosmos, VM — anything with an ARM resource id). Gate first, create second: confirm the target resource id exists and emits the metric you are about to alert on (`az monitor metrics list-definitions --resource <id>`) so the alert is not born watching a metric the resource never ships. Announce the full command, then:

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="observability-rg"
TARGET_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.Web/sites/checkout"  # full resource id from the audit capture
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="checkout-5xx-warning"
# Confirmed: metricAlerts read api-version is 2018-03-01 (used by the verify read below).
az monitor metrics alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$TARGET_ID" --condition "total Http5xx > 10" \
  --window-size 5m --evaluation-frequency 1m --severity 2 \
  --action "$AG_ID" --description "checkout HTTP 5xx above warning tier | capture request rate, dependency health, recent deploy, app logs"
# Verify by re-read: enabled and at least one action group attached.
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.enabled == true and ((.actions // []) | length) >= 1'
```

Expected: exit 0. Tune `--condition`, `--severity`, `--window-size`, and `--evaluation-frequency` to the resource's baseline — a threshold with no baseline behind it becomes the noise `AZR-060` flags. **Rollback:** `az monitor metrics alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"`, verified by a `show` that returns nothing. This create-verify shape serves every critical resource type; only the `--scopes`, `--condition`, and `--description` change.

## Add log alerts

For `AZR-003`. Scheduled-query (log) alerts run a KQL query against a Log Analytics workspace on a schedule and fire on the result count — the coverage a metric alert cannot give (error-log rate, missing-heartbeat, a business-signal query). Strict order: the query must return rows for a real condition before it becomes an alert, and the workspace must already be receiving the logs the query reads (see [Enable diagnostic settings](#enable-diagnostic-settings) if it is not). Prove the query first with the confirmed data-plane read, then create:

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="observability-rg"
WORKSPACE_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"
WORKSPACE_GUID="your-workspace-customer-id"   # the workspace customerId; from: az monitor log-analytics workspace show --query customerId -o tsv
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="checkout-error-log-rate"
KQL="AppServiceHTTPLogs | where ScStatus >= 500 | summarize count()"
# 1. Gate with the CONFIRMED data-plane read (needs the 'log-analytics' az extension; audience api.loganalytics.io):
az monitor log-analytics query --workspace "$WORKSPACE_GUID" --analytics-query "$KQL" -o json \
  | jq -e 'length >= 0'   # the query must PARSE and run; inspect the count before shipping it as an alert
# 2. Create the scheduled-query rule (announced first), then verify:
az monitor scheduled-query create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$WORKSPACE_ID" --condition "count 'errs' > 5" \
  --condition-query errs="$KQL" \
  --window-size 5m --evaluation-frequency 5m --severity 2 \
  --action-groups "$AG_ID" --description "checkout 5xx log rate over 5m | capture query, request id, deploy id, error class"
# scheduledQueryRules read api-version is confirmed at 2022-06-15.
az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '((.actions.actionGroups // []) | length) >= 1'
```

Expected: the gate query parses and returns (inspect the count — an empty result on a service you know errors means the query or the log source is wrong, and shipping it anyway creates a decorative alert), then exit 0. **Rollback:** `az monitor scheduled-query delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"`, verified by a `show` that returns nothing. The `az monitor scheduled-query` flag shape varies across CLI versions more than most — run `az monitor scheduled-query create --help` and re-announce if it differs.

## Add activity-log alerts

For `AZR-004`. Activity-log alerts fire on control-plane events for the subscription itself — Azure Service Health advisories, Resource Health transitions, and policy/administrative events — not on resource metrics. They are subscription-scoped, so the scope is the subscription (or a resource group), and they attach an action group exactly like a metric alert.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="observability-rg"
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="service-health-incidents"
# Service Health advisories for the whole subscription -> the on-call action group.
az monitor activity-log alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scope "/subscriptions/${SUB}" \
  --condition category=ServiceHealth \
  --action-group "$AG_ID" --description "Azure Service Health advisories for this subscription"
# activityLogAlerts read api-version is confirmed at 2020-10-01.
az monitor activity-log alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.enabled == true and ((.actions.actionGroups // .actionGroups // []) | length) >= 1'
```

Expected: exit 0. Repeat with `category=ResourceHealth` for per-resource health transitions and `category=Policy` for policy events, each a separate rule so a reader can tell which control-plane axis fired. **Rollback:** `az monitor activity-log alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"`, verified by a `show` that returns nothing.

## Enable VM diagnostics

For `AZR-010`. Two distinct halves, and only one executes here. **Platform metric alerts** (CPU, disk, network) on a VM or VMSS come straight from the Azure platform and need no agent — they are a monitoring-plane write, the same `az monitor metrics alert create` shape as [Add metric alerts](#add-metric-alerts) with `--scopes` set to the VM/VMSS resource id:

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="observability-rg"
VM_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.Compute/virtualMachines/api-01"  # confirmed read type: virtualMachines api-version 2024-07-01
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="api-01-cpu-warning"
az monitor metrics alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$VM_ID" --condition "avg Percentage CPU > 80" \
  --window-size 5m --evaluation-frequency 1m --severity 2 \
  --action "$AG_ID" --description "api-01 CPU above warning tier | capture load, process state, recent deploy, dependency health"
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.enabled == true and ((.actions // []) | length) >= 1'
```

Expected: exit 0. **Rollback:** `az monitor metrics alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"`. The **guest-level half** — memory, disk-free, per-process, and log collection — needs the Azure Monitor Agent (or the legacy diagnostic extension) plus a Data Collection Rule on each VM. Installing an agent and wiring a DCR is a per-VM controlled rollout on a surface this skill does not own (it can also require a role assignment for the VM's managed identity, which a Contributor identity cannot make): record it in [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes) with the VM list from the finding and a named owner, and leave the guest-metric part of `AZR-010` open until the agent metrics exist.

- ❌ `Installed the Azure Monitor Agent on all six VMs and wired the DCRs under the same batch as the CPU alerts.`
- ✅ `Created the platform CPU/disk metric alerts this run; filed the AMA + DCR install for guest metrics as a plan with the platform owner; the guest-metric half of AZR-010 stays open.`

## Enable AKS monitoring

For `AZR-030` (Container Insights) and `AZR-031` (managed Prometheus). These are **cluster mutations** (controlled rollout), not plain monitoring-plane writes, so their blast radius is larger and the announcement says so. Both verify against the **confirmed** property paths: `addonProfiles.omsagent.enabled` for Container Insights and `azureMonitorProfile.metrics.enabled` for managed Prometheus (`azureMonitorProfile` is absent/null when off — that absence is the "off" signal, not an error).

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
RG="app-rg"
CLUSTER="prod-aks"
LA_WS_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"  # workspaces confirmed at 2022-10-01
# AZR-030 Container Insights -> Log Analytics. Cluster write; Contributor on the AKS resource can do it.
az aks enable-addons --addons monitoring --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" \
  --workspace-resource-id "$LA_WS_ID"
az aks show --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.addonProfiles.omsagent.enabled == true'
```

Expected: exit 0 (`addonProfiles.omsagent.enabled == true`, confirmed path). **Rollback:** `az aks disable-addons --addons monitoring --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB"`, verified by `az aks show ... | jq -e '(.addonProfiles.omsagent.enabled // false) == false'`.

`AZR-031` managed Prometheus is `az aks update --enable-azure-monitor-metrics --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB"` (optionally `--azure-monitor-workspace-resource-id <amw-id>`), verified with `az aks show ... | jq -e '.azureMonitorProfile.metrics.enabled == true'`; rollback is `az aks update --disable-azure-monitor-metrics ...`. **RBAC caveat, load-bearing:** enabling managed Prometheus provisions a Data Collection Rule and can grant the cluster's managed identity a Monitoring role on the Azure Monitor Workspace. That grant is a `Microsoft.Authorization/roleAssignments/write`, which the confirmed validation identity (**Contributor**) could not perform (`AuthorizationFailed`). If your identity is Contributor and the enablement fails on the role assignment, stop and record `AZR-031` as **plan-with-named-owner** for the subscription Owner / a `User Access Administrator`; do not self-grant the role.

- ❌ `--enable-azure-monitor-metrics failed with AuthorizationFailed on the DCR role; created the role assignment myself to finish the fix.`
- ✅ `Container Insights enabled and verified (omsagent.enabled true). Managed Prometheus needs a role assignment the Contributor identity cannot make; filed as a plan for the Owner, AZR-031 stays open.`

## Enable diagnostic settings

For `AZR-032` (AKS control-plane logs), `AZR-040` (Log Analytics workspace coverage & retention), and `AZR-050` (App Gateway / Load Balancer diagnostics). A diagnostic setting routes a resource's platform logs and metrics to a Log Analytics workspace so they can be queried and alerted on. It is a monitoring-plane write on the resource; it does not change the resource's behavior.

```bash
set -eu
AZ_SUBSCRIPTION_CFG=""   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
TARGET_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.ContainerService/managedClusters/prod-aks"  # AKS control plane (AZR-032); or an appGateways / loadBalancers id (AZR-050)
LA_WS_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"
DS_NAME="to-central-logs"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# GET-before-write: capture any existing settings on this resource so rollback is exact.
az monitor diagnostic-settings list --resource "$TARGET_ID" -o json > "${BACKUP_DIR}/diag-$(basename "$TARGET_ID").json" || true
# NOTE: diagnosticSettings has NO confirmed ARM api-version in the validation run (no resource was
# attached to during it). The 'az' CLI selects its own version; confirm the categories your resource
# supports first with: az monitor diagnostic-settings categories list --resource "$TARGET_ID"
az monitor diagnostic-settings create --name "$DS_NAME" --resource "$TARGET_ID" --workspace "$LA_WS_ID" \
  --logs '[{"categoryGroup":"allLogs","enabled":true}]' \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
# Verify by re-read: a setting exists pointing at this workspace.
az monitor diagnostic-settings show --name "$DS_NAME" --resource "$TARGET_ID" -o json \
  | jq -e --arg ws "$LA_WS_ID" '.workspaceId == $ws'
```

Expected: exit 0. **Rollback:** `az monitor diagnostic-settings delete --name "$DS_NAME" --resource "$TARGET_ID"`, verified by a `list` that no longer shows it (or re-apply the captured backup if you were editing an existing setting).

`AZR-040` retention: set the workspace's retention with `az monitor log-analytics workspace update --resource-group <rg> --workspace-name <ws> --retention-time <days> --subscription "$SUB"` (workspaces read is confirmed at `2022-10-01`); GET-before-write captures the prior `retentionInDays` so rollback is setting it back. `AZR-050`: only the **diagnostic-settings** half of App Gateway / Load Balancer coverage executes here (appGateways and loadBalancers are confirmed reads at `2024-05-01`). Editing a live health **probe** — interval, threshold, path — can eject healthy backends from rotation; that is traffic-impacting and out of write scope, recorded as a plan instead.

## Handle the empty-scope guardrail

For `AZR-007`. This is **not** a change to execute — it is the audit telling you it saw `0 action groups AND 0 metric alerts despite a 200`, which is a visibility gap (the identity may lack read scope on the alerting resources, or the objects live in a resource group it cannot see), **not** a confident "you have no alerting". Do not "fix" it by creating a first action group and declaring victory; that would paper over a permissions or scoping problem with a real object in the wrong place.

The correct response is diagnosis, then a scoped re-audit — no write:

1. Confirm the read scope. `az role assignment list --assignee <identity> --subscription "$SUB" -o table` and check the identity actually holds `Reader`/`Monitoring Reader` at the subscription (or the resource groups that hold the alerting objects). `az role assignment list` is a read; it is not a role **grant**.
2. If scope is genuinely missing, that is a `Reader`/`Monitoring Reader` grant — an RBAC write needing `Owner`/`User Access Administrator` — recorded as **plan-with-named-owner**, never self-granted here.
3. Re-run `/scoutflo:audit-azure` with the corrected scope; only if it still reports zero after full read visibility do you treat "no alerting exists" as true and start at [Create and wire an action group](#create-and-wire-an-action-group).

- ❌ `AZR-007 fired, so created an action group and a CPU alert to make the count non-zero and closed it.`
- ✅ `AZR-007 is a visibility gap: confirmed the identity lacked Monitoring Reader on payments-rg; filed the Reader grant as a plan for the Owner and will re-audit with scope before deciding whether any alerting is actually missing.`

## Plan cost and out-of-scope changes

For `AZR-OPT-*` and every controlled-rollout / traffic-impacting / RBAC item deferred by the sections above (VM agent installs, AKS managed-identity role grants, App Gateway/LB health-probe edits, `Reader`/`Monitoring Reader` grants, network changes). **No command in this section executes**; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, maintenance window if any, and a named owner.

`AZR-OPT-*` cost findings are **read-only guidance** here, exactly as in the dedicated audit-cost skill: resizing, deallocating, or deleting live Azure infrastructure to save money is a materially different risk profile than fixing missing alerting, and this skill's change protocol and backups are built for "restore observability", not "remove infrastructure". To act on an `AZR-OPT-*` finding, open it in the latest `audit-azure` report, review the recommendation where Azure presents it (Azure Advisor, the Cost Management view, or the presence fact), and act manually under your own change control. The read-only surface and the never-invent-a-dollar rule are in [audit-azure's azure-cost-checks.md](../audit-azure/references/azure-cost-checks.md); never run `az costmanagement query` (that CLI command does not exist — the cost read path is the Cost Management Query REST API at `2023-11-01`).

Recording the plan here keeps the finding traceable without smuggling a cluster change, an agent install, or a role grant through a "monitoring tweak" approval.

## Review alert processing rules

AZR-005. An alert processing rule (formerly "action rule") with a suppression on a live production scope silently stops alerts from that scope from ever notifying — the alerts still fire and resolve in the portal, but no action group runs. This is the highest-severity Azure alerting defect because it looks healthy everywhere except delivery. The fix is a scoped review, never a blanket delete:
- Announce the exact rule (`az monitor alert-processing-rule list`), its `scopes`, its `conditions`, and the schedule/`enabled` state, and which live resources it currently mutes.
- Confirm intent: a suppression bounded to a real maintenance window with an `endsAt` is legitimate; an open-ended or perpetually-renewed suppression on a production scope is the finding.
- Narrow the scope or add a schedule with a real end (`az monitor alert-processing-rule update`), or disable the rule — announced, one change, with the prior state recorded for rollback.
- Verify: the rule no longer covers the production scope at the current time, and a subsequent real alert on that scope reaches its action group (prove delivery via the action-group test in *Create and wire an action group*, not by assuming).

## Investigate log ingestion

AZR-041. A Log Analytics workspace that has stopped ingesting means every log-based alert and query over it is now blind — the query returns the last data and looks alive. The fix is upstream of the workspace, not the workspace itself:
- Announce which tables stopped (`az monitor log-analytics query` for `Heartbeat`/table `_BilledSize` max TimeGenerated) and the last-seen timestamp per table.
- Trace the source route: the resource's diagnostic setting still points at this workspace (*Enable diagnostic settings*), the Data Collection Rule / agent (AMA) is running, and the resource still exists. Fix whichever link broke — re-point the diagnostic setting, repair the DCR association, or restart the agent — announced as one change.
- Verify: `Heartbeat | summarize max(TimeGenerated)` (or the affected table) advances to within minutes, and one previously-blind alert query returns fresh rows.

## Add Prometheus rule groups

AZR-033. Azure Monitor managed Prometheus can be collecting metrics while **zero** Prometheus rule groups consume them — so the metrics exist but nothing alerts on them. Collection without rules is a half-built pipeline. The fix authors the rule groups:
- Announce the intended rule groups (a `Microsoft.AlertsManagement/prometheusRuleGroups` resource) scoped to the Azure Monitor workspace, with the specific PromQL expressions and `severity`/`for` per rule, mapped to the critical services from topology.
- Confirm the expressions against live data first (query the managed Prometheus endpoint read-only), then apply the rule-group resource (Bicep/ARM/`az resource create`), one announced change.
- Verify: the rule group appears in the Azure Monitor workspace, its rules show a recent evaluation, and a test condition routes to the intended action group.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact az command or payload applied; action-group secret values never included>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (VM agent installs, AKS/RBAC plans, `Reader` grants for `AZR-007`, health-probe edits), and a fresh `/scoutflo:audit-azure` run to re-score; its delta shows which findings moved to fixed. RBAC-blocked items never appear as "fixed" by this skill; they close only when an Owner / User Access Administrator acts and a later audit observes the change.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Alert created before its action group exists | Order discipline: action group first, then the alerts that reference it; an alert with no action group fails its own verify |
| Local `az` default subscription "fixed" to reach the target | Never `az account set` inside a fix block; explicit `--subscription` resolved from config, and the Live-safety gate compares config against the live subscription every block |
| Wrong subscription mutated | Live-safety gate re-reads `azure.subscription_id` from `toolkit.yaml` fresh every block and compares against a live `az account show`; it cannot pass on what an operator typed or last `az account set` |
| `AuthorizationFailed` on `roleAssignments/write` treated as a retry-or-self-grant signal | RBAC/role-granting is its own risk class needing Owner/User Access Administrator; the Contributor identity records it as plan-with-named-owner, never self-grants |
| Managed Prometheus enablement's DCR role grant done by hand | If enablement needs a role assignment a Contributor cannot make, AZR-031 becomes a plan for the Owner; only the enablement that succeeds without a grant executes |
| AKS enablement treated as a plain monitoring-plane write | Container Insights / managed Prometheus are cluster mutations (controlled rollout); announce the larger blast radius and verify against the confirmed `omsagent.enabled` / `azureMonitorProfile.metrics.enabled` paths |
| VM guest-metric coverage "fixed" by installing the agent | AMA + DCR install is a per-VM controlled rollout out of write scope; only the platform metric alerts execute, the agent install is a plan |
| Log alert shipped whose KQL matches nothing | Gate with `az monitor log-analytics query` first (confirmed data-plane read); inspect the count before the query becomes an alert |
| Diagnostic setting written against an unconfirmed api-version assumption | `diagnosticSettings` has no confirmed api-version; confirm supported categories with `az monitor diagnostic-settings categories list` and let the CLI pick the version, re-announcing if it differs |
| Health-probe parameters edited instead of adding diagnostics | Editing a live App Gateway/LB probe can eject healthy backends; only the diagnostic-settings half of AZR-050 executes, the probe edit is a recorded plan |
| `AZR-007` "closed" by creating a first alert | AZR-007 is a visibility gap, not a confident zero; diagnose read scope, plan any missing grant, re-audit with scope before treating "no alerting" as true |
| Action-group secret values leak into announcements or records | Announce receiver names and types; webhook URLs, service keys, and connection strings ride unechoed variables into the command and stay out of the change record |
| `az costmanagement query` used for a cost figure | That CLI does not exist; cost is read-only guidance here — point at audit-cost and the Cost Management REST path, never invent a dollar |
| Batch continues past a failed create | Mid-batch failure rule: stop, re-read the failed object, re-announce the remainder |
| Deletion slipped into a batch approval | Action groups, alerts, and diagnostic settings are deleted only with individual confirmation and the body quoted |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Cluster, network, or RBAC change smuggled in as monitoring work | Write scope is the Monitoring plane; everything else becomes a plan with a named owner |
