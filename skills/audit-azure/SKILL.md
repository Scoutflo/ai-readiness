---
name: audit-azure
description: Read-only scored audit of Azure Monitor observability, covering action groups and alert delivery, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM/VMSS coverage, AKS Container Insights and managed Prometheus, Log Analytics coverage and retention, and App Gateway/Load Balancer diagnostics; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Azure or Azure Monitor alerting, action groups, metric or log alerts, AKS monitoring add-ons, Log Analytics retention, or noisy Azure alerts. Do not use to change Azure resources (use setup-azure), for in-cluster Prometheus stacks on AKS (use audit-lgtm), or for Kubernetes-workload RBAC (use audit-kubernetes).
---

# audit-azure

Scored, read-only audit of the Azure surfaces that carry production observability: Azure Monitor action groups and their delivery, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM and VMSS coverage, AKS Container Insights and managed Prometheus, Log Analytics workspace coverage and retention, and Application Gateway / Load Balancer diagnostics. It answers one question: when an Azure-hosted service degrades tonight, does an alert fire, reach a human, and give the responder enough to act?

Every command in this audit is read-only: `az ... show`/`list`, ARM GETs at confirmed api-versions, the two POST-shaped **reads** (Resource Graph, Cost Management Query — classified by effect, marked `readOnly`), and the Log Analytics data-plane `az monitor log-analytics query`. Nothing is created, updated, enabled, or deleted, and no command mutates local `az` state — `az account set` is as forbidden as a cloud write; every command passes explicit `--subscription`. The full forbidden-command list is in [references/azure-cost-checks.md](references/azure-cost-checks.md) section 14.

Scope boundaries, stated so a green score never overpromises:

- One subscription per run: the audit judges `azure.subscription_id` from `~/.scoutflo/toolkit.yaml`. Multi-subscription estates run once per subscription.
- Covered: Azure Monitor (action groups, metric/log/activity alerts), VMs/VMSS, AKS monitoring surfaces, Log Analytics, and App Gateway/Load Balancer diagnostics. Not covered: App Service/Functions internals, Cosmos/SQL/Storage service-specific depth, Front Door, and API Management; if those carry production traffic, say so in the report as unaudited surface.
- In-cluster stacks (Prometheus, Alertmanager, Grafana running inside AKS) belong to `/scoutflo:audit-lgtm`; this audit covers the Azure-managed plane and states the split.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/azure/<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `AZR-NNN` (cost `AZROPT-NNN`)
- `./scoutflo-audits/azure/<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/azure/<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per action group, metric alert, scheduled-query (log) alert, activity-log alert, VM, VMSS, AKS cluster, Log Analytics workspace, App Gateway, and Load Balancer (`kind`: `action_group`, `alert_rule`, `log_alert`, `activity_log_alert`, `vm`, `vmss`, `cluster`, `workspace`, `app_gateway`, `load_balancer`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/azure/history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

All api-versions, property paths, and auth behavior cited below are the ones live-confirmed in the Azure SDK/API Validation Report; nothing unconfirmed is asserted as fact.

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Azure | `azure.subscription_id`, optional `azure.tenant_id`, optional `azure.region` | none stored; auth is `az login` (`DefaultAzureCredential` → `AzureCliCredential` fallback, confirmed) | `Reader` + `Monitoring Reader` on the subscription; `Log Analytics Reader` for data-plane queries; `Cost Management Reader` only for the non-scored cost section (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || { if [ -f "./.scoutflo/toolkit.yaml" ]; then CFG="./.scoutflo/toolkit.yaml"; else CFG="$HOME/.scoutflo/toolkit.yaml"; fi; }
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting. It only sets *_env variables; no secret
# value is printed. A profile that already sources it makes this a no-op. This mirrors what
# /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in az curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
az version --query '"azure-cli"' -o tsv 2>/dev/null | head -1
AZ_SUBSCRIPTION_CFG="your-sub-id"   # azure.subscription_id; empty means the az CLI default subscription
# Confirmed auth path: DefaultAzureCredential -> AzureCliCredential (via az login).
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
SUB="${AZ_SUBSCRIPTION_CFG:-$(printf '%s' "$ACCT" | jq -r '.id')}"
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name') on subscription $(printf '%s' "$ACCT" | jq -r '.name')"
ARM_TOKEN="$(az account get-access-token --subscription "$SUB" --resource https://management.azure.com --query accessToken -o tsv)"
# One cheap ARM read at a CONFIRMED api-version proves reachability + the token works.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${ARM_TOKEN}" \
  "https://management.azure.com/subscriptions/${SUB}/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01")"
[ "$code" = "200" ] || { echo "action-groups api: ${code} (expected 200); 401 = missing/malformed token (confirmed), 403 = missing Monitoring Reader, 404 = wrong subscription id (confirmed)"; exit 1; }
echo "action-groups api: ${code}"
```

Expected: the identity line, the resolved subscription, and `action-groups api: 200`, all asserted by the block itself. Any assertion failing stops the block with a nonzero exit; never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone.

Two notes that live here because they bite at the gate:

- If the audit identity holds `Contributor`, `Owner`, or `User Access Administrator`, the audit still runs, but record in the report that the audit credential can write; a read-only identity (`Reader` + `Monitoring Reader`) is itself part of good posture.
- The Log Analytics data-plane query needs the `log-analytics` az extension (audience `https://api.loganalytics.io`); if it is absent, the log-coverage checks that use it record `blocked` with the install hint, never a fabricated pass.

## Live-safety gate

Print what you are pointed at and compare it against the config before the first real check. The comparison value comes from `toolkit.yaml`, not from what an operator typed or what `az account set` left active in another terminal:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"; [ -n "$CONFIG" ] || { if [ -f "./.scoutflo/toolkit.yaml" ]; then CONFIG="./.scoutflo/toolkit.yaml"; else CONFIG="$HOME/.scoutflo/toolkit.yaml"; fi; }
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve azure.subscription_id the same way doctor.sh reads two-level keys: yq when present,
# a sed fallback otherwise. Never hand-typed.
if command -v yq >/dev/null 2>&1 && yq -r '. | keys | length' "$CONFIG" >/dev/null 2>&1; then
  AZ_SUB_CFG="$(yq -r '.azure.subscription_id // ""' "$CONFIG")"
else
  AZ_SUB_CFG="$(sed -n '/^azure:/,/^[A-Za-z_]/p' "$CONFIG" \
    | sed -n 's/^[[:space:]]\{1,\}subscription_id:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]#.*$//' -e "s/^[\"']//" -e "s/[\"']\$//" -e 's/[[:space:]]*$//')"
fi
[ -n "$AZ_SUB_CFG" ] || { echo "azure.subscription_id is not set in $CONFIG; run /scoutflo:connect"; exit 1; }
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name')"
echo "tenant: $(printf '%s' "$ACCT" | jq -r '.tenantId')"
echo "config target (azure.subscription_id): ${AZ_SUB_CFG}"
echo "live subscription (az account show): $(printf '%s' "$ACCT" | jq -r '.id') ($(printf '%s' "$ACCT" | jq -r '.name'))"
[ "$(printf '%s' "$ACCT" | jq -r '.id')" = "$AZ_SUB_CFG" ] \
  || { echo "STOP: az resolves a subscription that does not match toolkit.yaml azure.subscription_id (${AZ_SUB_CFG}); every command must pass --subscription ${AZ_SUB_CFG} explicitly, or fix the config"; exit 1; }
echo "live-safety gate passed: identity, tenant, and subscription confirmed against config"
```

The assertion is the gate: the live subscription equals `azure.subscription_id` or the block exits nonzero and stops the run. Never proceed on "probably the right subscription". If the printed identity or tenant is not the one your team intends for audits, stop and report the mismatch even though the subscription assertion passed; identity, tenant, and subscription are separate checks. No command in this audit reads the ambient `az` default; every command names `--subscription` explicitly, and pointing the audit elsewhere is an edit to `toolkit.yaml`, never an `az account set`.

## Ground rules

- Configuration is metadata; live validation is proof. An alert rule in the list is `configured`; only an observed Azure Monitor notification, or a proven delivery path, makes routing `validated-live`.
- API errors are evidence. A `403` means a missing role; a `404` means a wrong subscription or a retired resource; a `429` on the cost path means throttling, not absence. Record the code and what it implies; never convert an error into empty success. (401/404 statuses are confirmed; a `429` on Cost Management is confirmed and must be retried with backoff, never read as "no data".)
- Never score from object counts. A subscription with thirty alert rules and six action groups is not "covered": credit stops until each enabled rule names a reachable action group and delivery is proven.
- A Load Balancer / App Gateway health probe keeps traffic away from a bad backend; it pages nobody. Health probes and Azure Monitor alerts are different systems — neither presence scores the other.
- VM guest metrics (memory, disk-free, per-process) exist only where the Azure Monitor Agent ships them via a Data Collection Rule; platform metrics (CPU, disk, network) need no agent. Coverage claims name which half they mean.
- Action group receivers (webhook URLs, service keys, SMS numbers, Logic App callback URLs) and diagnostic-setting connection strings carry secrets. Capture receiver **display name and type only**, per the redaction procedure in [report-standard/secret-redaction.md](../../report-standard/secret-redaction.md); never print or write a receiver's secret value into evidence, the report, or the terminal.
- Two webhooks, two jobs: an action group's webhook receiver is the object under audit; the toolkit Slack brief webhook (`slack.webhook_env`) is the reporting path. Name them exactly this way and flag any action group that appears to be the brief webhook.

## The four change-risk classes

Every fix this audit recommends carries one of four classes so "Next safe actions" never hides a cluster change behind a "monitoring tweak":

| Class | Examples | Rule |
| --- | --- | --- |
| Read-only | `az show`/`list`, ARM GET, Resource Graph / Cost Management `readOnly` POST, `log-analytics query` | The only class allowed in this audit. |
| Monitoring-plane write | action groups, metric/log/activity alerts, diagnostic settings, Log Analytics retention | `setup-azure`, confirmation-gated. No workload restarts. |
| Controlled rollout | AKS Container Insights / managed Prometheus enablement, VM agent (AMA) + DCR install | Own change plan with a named owner; a role assignment inside it needs Owner/User Access Administrator. |
| Traffic-impacting | App Gateway / Load Balancer probe edits, NSG/DNS/network, VM resize/restart, AKS node pools | Out of write scope everywhere; plan only. |

## Estate sizing

Count before judging, and declare the path in the terminal output:

```bash
set -eu
AZ_SUBSCRIPTION_CFG="your-sub-id"   # azure.subscription_id
SUB="${AZ_SUBSCRIPTION_CFG:-$(az account show --query id -o tsv)}"
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="10"           # objects per batch on the large path; example, tune it
VMS="$(az vm list --subscription "$SUB" --query 'length(@)' -o tsv)"
VMSS="$(az vmss list --subscription "$SUB" --query 'length(@)' -o tsv)"
AKS="$(az aks list --subscription "$SUB" --query 'length(@)' -o tsv)"
APPGW="$(az network application-gateway list --subscription "$SUB" --query 'length(@)' -o tsv)"
LBS="$(az network lb list --subscription "$SUB" --query 'length(@)' -o tsv)"
AGS="$(az monitor action-group list --subscription "$SUB" --query 'length(@)' -o tsv)"
METRIC_ALERTS="$(az monitor metrics alert list --subscription "$SUB" --query 'length(@)' -o tsv)"
TOTAL=$((VMS + VMSS + AKS + APPGW + LBS))
echo "vms=${VMS} vmss=${VMSS} aks=${AKS} app_gateways=${APPGW} load_balancers=${LBS} action_groups=${AGS} metric_alerts=${METRIC_ALERTS} scored_objects=${TOTAL}"

# Guided-walkthrough drift check: compare against the last run's estate.objects rather than a blank
# slate and state it in the executive summary (per report-standard/README.md). Never skips a live check.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -v '/runs$' | sort | tail -1)"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  [ -n "$PREV_TOTAL" ] && { [ "$PREV_TOTAL" -eq "$TOTAL" ] \
    && echo "drift: estate unchanged since ${PREV_RUN##*/} (${TOTAL} objects)" \
    || echo "drift: estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} objects"; }
fi
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (routing, alert coverage, VMs, AKS, Log Analytics, LB), completed in one run.
- **Large**: work VMs/VMSS, App Gateways, and Load Balancers in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist](#large-path-worklist) below; alert routing, AKS, Log Analytics, and alert-quality checks are subscription- or category-scoped and always run once per run regardless of path.

A resource-type list that comes back empty because the provider is not registered on this subscription makes that area `not-in-scope`, declared in the scorecard, not a failure. Record the chosen path and counts in `findings.json` as `estate: {objects, path}`; `audit-all` reads them. Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer resource-group / region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

### Empty / hidden-scope guardrail (AZR-007)

The scope checkpoint above narrows a *large* estate. This guardrail catches the opposite and more dangerous case: an estate that looks like it has **no alerting** because the identity or resource-group scope cannot see the alerting objects. It is the Azure analog of audit-elk's space-visibility trip-wire (ELK-033) and the JSM/Zenduty team-visibility guardrails: scoring a confident `0/100` because the API returned zero action groups is the same wrong answer as auditing only the `default` Kibana space. **This guardrail is live-validated** — on a live subscription that returned 0 action groups AND 0 metric alerts, the trip-wire fired correctly, proving it detects zero-alerting-despite-200 rather than scoring a confident zero. After Phase 2 materializes the raw inventory:

```bash
set -eu
AZ_SUBSCRIPTION_CFG="your-sub-id"   # azure.subscription_id
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}/raw"
AGS="$(jq 'length' "${RAW_DIR}/action-groups.json" 2>/dev/null || echo 0)"
ALERTS="$(jq 'length' "${RAW_DIR}/metric-alerts.json" 2>/dev/null || echo 0)"
if [ "${AGS:-0}" -eq 0 ] && [ "${ALERTS:-0}" -eq 0 ]; then
  # Both empty despite a readable ARM surface (the doctor gate returned 200, not 401/403).
  echo "[guard] 0 action groups AND 0 metric alerts in ${AZ_SUBSCRIPTION_CFG} despite a readable ARM surface — possible identity / resource-group visibility gap (AZR-007)"
  echo "[guard] alerting may live in a resource group this identity cannot read, or this identity lacks Monitoring Reader at subscription scope — do NOT score a confident 0/100"
fi
```

Behavior this enforces (Phase 11 honors it):

- **Alerting-object-dependent categories excluded** — **Alert routing and delivery, Alert coverage, and Alert quality** are marked `blocked` with the visibility-gap reason and renormalized per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md); emit finding **AZR-007** naming the gap and the fix (confirm the identity holds `Reader`/`Monitoring Reader` at subscription scope, and check the resource groups that hold the alerting objects — recipe in `/scoutflo:connect`). **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim.
- **Keep the resource-signal categories included** — **Compute VM/VMSS coverage, AKS coverage, Log Analytics coverage, and Load balancer coverage** assess the estate's own posture (AMA/DCR presence, `addonProfiles.omsagent.enabled`, `azureMonitorProfile.metrics.enabled`, diagnostic settings, retention, health-probe attachment) from resource inventory that does not depend on the alerting objects, so at least one scored category remains (excluding all leaves nothing to score and `check-findings.sh` rejects an all-excluded scorecard).
- If those resource categories are **also** empty — a pure subscription with no resources of its own, or an identity that can see nothing — emit **no confident score at all** and report AZR-007 as the outcome. A `401`/`403` from Phase 2 is a *privilege* finding, not this trip-wire.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map VMs, AKS workloads, App Gateways, and Load Balancers to those names. If it does not exist, infer services from resource names, note the inference in the report, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/azure-checks.md](references/azure-checks.md): action groups (redacted at capture, as a JSON array in `raw/action-groups.json`), metric alerts (`raw/metric-alerts.json`), scheduled-query rules, activity-log alerts, VMs and VMSS with instance-view power state, AKS clusters with `addonProfiles.omsagent.enabled` and `azureMonitorProfile.metrics.enabled`, Log Analytics workspaces with `retentionInDays`, App Gateways / Load Balancers with their health probes and diagnostic settings. Judgment starts in Phase 3; inventory records what exists. Use the confirmed api-versions: `actionGroups` 2023-01-01, `metricAlerts` 2018-03-01, `scheduledQueryRules` 2022-06-15, `activityLogAlerts` 2020-10-01, `managedClusters` 2024-09-01, `workspaces` 2022-10-01, `virtualMachines`/`virtualMachineScaleSets` 2024-07-01, `applicationGateways`/`loadBalancers` 2024-05-01. `diagnosticSettings` has **no** confirmed api-version — let the `az` CLI pick it and confirm supported categories with `az monitor diagnostic-settings categories list`, never assert one.

## Phase 3: Alert routing and delivery (AZR-001)

Commands in [references/azure-checks.md](references/azure-checks.md). Judge whether an alert that fires reaches a human: at least one enabled action group with a live receiver exists (critical when none); every enabled alert rule (metric, log, activity) names at least one action group; groups split per environment (`<team>-<environment>-alerts`) instead of one catch-all; no disabled or dead receiver still referenced by a rule; and delivery proven by an observed notification rather than assumed (capped at `configured` without one — Azure Monitor exposes no public fired-notification list, so a team-confirmed sighting is the documented manual exception). Any action group that appears to be the toolkit Slack brief webhook is flagged, not counted as alerting.

## Phase 4: Alert coverage — metric, log, activity (AZR-002, AZR-003, AZR-004)

Commands in [references/azure-checks.md](references/azure-checks.md).

- **AZR-002 metric alerts.** Each critical resource (App Service, SQL, Storage, Cosmos, VM — anything with an ARM resource id) carries a platform-metric alert on the signal that matters, scoped to a real resource id that emits the metric (a rule watching a metric the resource never ships can never fire). Two named tiers (warning/critical) where the workload is stable.
- **AZR-003 scheduled-query (log) alerts.** Log-rate, missing-heartbeat, and business-signal coverage a metric alert cannot give. Credit requires the workspace to actually receive the logs the KQL reads and the query to return rows for a real condition — validate with the confirmed data-plane read `az monitor log-analytics query` (needs the `log-analytics` extension); an alert on a query that matches nothing is decoration.
- **AZR-004 activity-log alerts.** Control-plane coverage for the subscription itself: Azure Service Health advisories, Resource Health transitions, and policy/administrative events, each attaching an action group. Absence of any Service Health alert is a real gap — a regional Azure incident then pages nobody.

## Phase 5: Compute VM/VMSS coverage (AZR-010)

Commands in [references/azure-checks.md](references/azure-checks.md). Per serving VM or scale set: platform CPU/disk/network alerts (no agent needed) with two tiers where stable; guest metrics (memory, disk-free, per-process) credited **only** after Azure Monitor Agent + Data Collection Rule evidence proves them live per VM — never before; and every metric-alert scope resolves to a resource that emits the metric. A VMSS running fixed capacity with alerts only on the aggregate hides a single unhealthy instance; name that gap. Stopped-but-billed VMs (power state `PowerState/stopped`) are a cost signal handled in the non-scored cost section, not here.

## Phase 6: AKS coverage (AZR-030, AZR-031, AZR-032)

Commands in [references/azure-checks.md](references/azure-checks.md). All three verify against **confirmed** property paths from `az aks show`:

- **AZR-030 Container Insights** — `addonProfiles.omsagent.enabled == true` (with `.config.logAnalyticsWorkspaceResourceID` pointing at a real workspace); the addon absent is the "off" signal, not an error.
- **AZR-031 managed Prometheus** — `azureMonitorProfile.metrics.enabled == true`; `azureMonitorProfile` absent/null is "off" (confirmed). Credit this where workload metric alerting is expected.
- **AZR-032 AKS diagnostic settings** — the cluster's control-plane logs route to a Log Analytics workspace via a diagnostic setting; a cluster with monitoring add-ons but no control-plane diagnostic settings loses API-server and scheduler logs.

Where the in-cluster Prometheus/Alertmanager stack is the primary alerting plane, mark the overlapping checks `not-in-scope`, state the split, and run `/scoutflo:audit-lgtm` against that stack. Enabling any of these is a controlled rollout (a cluster mutation), out of read-only scope — findings point at `setup-azure`, which plans it.

## Phase 7: Log Analytics coverage and retention (AZR-040)

Commands in [references/azure-checks.md](references/azure-checks.md). At least one workspace is the estate's log destination; critical resources route to it via diagnostic settings; and `retentionInDays` is a deliberate decision, not an unexamined default — matching the retention discipline `audit-aws` (`AWS-051`) and `audit-gcp` (`GCP-054`) already require. A workspace that exists but receives nothing from the critical resources is coverage on paper only; name the resources whose diagnostic settings are missing.

## Phase 8: Load balancer and App Gateway coverage (AZR-050)

Commands in [references/azure-checks.md](references/azure-checks.md). Every serving Application Gateway / Load Balancer has a health probe attached, **and** a diagnostic setting routing its access/performance logs and metrics to Log Analytics so a 5xx or latency spike is queryable and alertable. The trap this phase exists for: health probes eject bad backends silently, so an estate can look "self-healing" while an all-backends-down event pages nobody. Health probes and Monitor alerts are audited separately; neither is credited for the other. Editing a live probe is traffic-impacting and out of write scope — only the diagnostic-settings half is a monitoring-plane fix.

## Phase 9: Alert quality (AZR-060)

Commands in [references/azure-checks.md](references/azure-checks.md). Reading the rule bodies already captured in Phase 2 (no new call, no mutation): each paging rule carries a `windowSize`/`evaluationFrequency` that debounces a single transient sample; `severity` is set to a real tier (0 critical … 4 verbose), not left at a default that makes everything look equally urgent; documentation tells the responder where they are, how bad it is, and what to capture first; and no rule is permanently firing or duplicated across action groups. Honest ceiling, stated in the report every run: Azure Monitor exposes no public fired-notification/incident-history list API, so this audit reports **structural** noise signals read off each rule's configuration and never a fabricated "N% of alerts are actionable" number.

## Phase 10: Coverage matrix and topology readiness

Fill one row per critical service using the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Metric | Log | VM/VMSS | AKS | Log Analytics | LB/AppGW | Routing | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the `VM/VMSS` cell folds in the AMA gate (platform-only coverage caps it at `partial` with the gap named); the `Log` cell requires a matching, recently-matching, action-group-carrying query to reach `pass`; every cell carries its `passed/total` denominator. Name affected services in findings: "two VMs lack memory coverage" is not a finding; "checkout-vm-1 and checkout-vm-2 lack memory coverage" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live counts toward T6. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. If the export or topology.md is missing or describes a different target, render the matching state from topology-readiness.md with its one-line unlock; never guess and never say a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 11: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), `fail`/`blocked` (0); `not-in-scope` leaves the denominator. Category score is the credit ratio times 100 rounded down; overall is the weight-normalized sum over included categories. Whole categories that could not be assessed are excluded, renormalized, and stated; blocked checks inside an assessable category score 0. Score conservatively: when unsure between two results, pick the lower and say why. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert routing and delivery | 25 | AZR-001 |
| Alert coverage (metric, log, activity) | 25 | AZR-002 to AZR-004 |
| Compute VM/VMSS coverage | 15 | AZR-010 |
| AKS coverage | 15 | AZR-030 to AZR-032 |
| Log Analytics coverage | 10 | AZR-040 |
| Load balancer / App Gateway coverage | 5 | AZR-050 |
| Alert quality | 5 | AZR-060 |

The full check catalog and the target profile (what 100 means per category) are in [references/azure-checks.md](references/azure-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers. `AZR-007`, when it fires, excludes the alerting-dependent categories rather than scoring them zero (see the guardrail section).

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. Suppressed findings leave the score and severity counts.
3. Every findings area and coverage cell carries its denominator (`passed/total`).

Emit and verify:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json, inventory.json, and report.md per the report standard, then verify:
jq -e '.schema == "scoutflo-findings/v1" and .target == "azure" and (.findings | type == "array") and (.estate.path != null)' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance + score reconciliation, then the viz, then template conformance.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-azure", overall:.score.overall, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and (.overall >= 0)' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first; the ledger is derived and never drives finding lifecycle. Then send the Slack brief: titles only, never evidence values, hostnames, subscription ids, tenant ids, or endpoints:

```bash
set -eu
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
TOPO_LINE="Topology readiness: readiness not recorded"  # replace with "r/n services sync-ready" from Phase 10
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  CHECKS="$(jq -r '"\([.score.categories[].checks_passed] | add)/\([.score.categories[].checks_total] | add) checks passed"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d | grep -v '/runs$' | sort | tail -2 | head -1)"
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  jq -n --arg head "audit-azure ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}. ${COUNTS}. ${CHECKS}." \
        --arg top "$TOP" --arg delta "$DELTA" --arg topo "$TOPO_LINE" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\n" + $topo + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # derived from business_context.md (the SSOT)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver
LOAD_METADATA_MODE="none"
if [ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="per-resource"
elif [ -f "$BC_JSON" ] && jq -e '.' "$BC_JSON" >/dev/null 2>&1; then
  LOAD_METADATA_MODE="workspace"
fi
echo "metadata mode: $LOAD_METADATA_MODE"
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (per-env SLA); and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Large-path worklist

Runs on the large path only (see the Estate sizing step above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/azure/runs/<RUN_ID>/`, not a calendar-date directory, so a run still batching when the UTC date rolls over keeps writing to the same place (the drift check and the emit step already skip this directory with `grep -v '/runs$'`).

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/azure/runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per VM, VMSS, App Gateway, and Load Balancer counted in Estate sizing, status `pending` or `done`. A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the matching per-resource checks against just that batch — VM/VMSS coverage (AZR-010) for a VM/VMSS row, App Gateway / Load Balancer health-probe + diagnostic-setting checks (AZR-050) for a network row. A row is marked `done` **only after its reads succeed**, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

The subscription- and category-scoped checks (alert routing AZR-001, alert coverage AZR-002/003/004, AKS AZR-030/031/032, Log Analytics AZR-040, alert quality AZR-060, and the AZR-007 guardrail) are single cheap passes; they run once per run regardless of path and are never batched.

## Cost and Resource Optimization (not scored)

A separate, **never-scored** section reports Azure cost and idle-resource signals under the `AZROPT-NNN` prefix, per [references/azure-cost-checks.md](references/azure-cost-checks.md). None of it enters `score.categories` or `score.excluded`; every finding carries `points_recoverable: 0` and `area: cost-optimization`. The one hard rule: `estimated_monthly_savings_usd` appears **only** when copied verbatim from Azure Advisor's own cost recommendation — never recomputed against a price table, never converted from an annual or non-USD figure. Everything else (unattached disks, unassociated public IPs, stopped-but-not-deallocated VMs, over-scaled VMSS, orphaned resources) is a presence fact with no dollar. The subscription's month-to-date `PreTaxCost` from the Cost Management Query REST API (api-version `2023-11-01`, rate-limited — **handle 429 with backoff**) is spend already incurred, reported as context and never summed into savings. `az costmanagement query` **does not exist**; the read path is the Cost Management Query REST API only. The full catalog, the 429-aware `readOnly` POST helper, Resource Graph enumeration, and the forbidden-command list are in [references/azure-cost-checks.md](references/azure-cost-checks.md).

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| No, catch-all, or dead action groups; alert-quality attachment/hygiene | `setup-azure#create-and-wire-an-action-group` |
| Missing metric alerts on critical resources | `setup-azure#add-metric-alerts` |
| Missing scheduled-query (log) alerts | `setup-azure#add-log-alerts` |
| Missing activity-log / Service Health alerts | `setup-azure#add-activity-log-alerts` |
| Missing VM/VMSS platform alerts (guest metrics = plan) | `setup-azure#enable-vm-diagnostics` |
| AKS Container Insights or managed Prometheus off | `setup-azure#enable-aks-monitoring` |
| Missing diagnostic settings (AKS/App Gateway/LB); Log Analytics retention | `setup-azure#enable-diagnostic-settings` |
| Empty/hidden-scope visibility gap (AZR-007) | `setup-azure#handle-the-empty-scope-guardrail` (diagnose scope, not a confident fix) |
| VM agent installs, RBAC grants, health-probe edits, network changes | `setup-azure#plan-cost-and-out-of-scope-changes` (plan only) |
| Cost / idle-resource opportunities (`AZROPT-*`) | `setup-azure#plan-cost-and-out-of-scope-changes` (read-only guidance) |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Wrong ambient subscription audited | Every command passes `--subscription "${SUB}"`; the live-safety gate re-reads `azure.subscription_id` from toolkit.yaml and stops on mismatch |
| Local `az` default subscription mutated to "fix" identity | `az account set` is forbidden; the subscription comes from explicit flags and the confirmed `az login` auth path |
| Permission error read as "nothing exists" | A `403` is a missing role, a `429` is throttling; record it and mark the check `blocked`, never empty success |
| Confident `0/100` on a hidden-alerting subscription | AZR-007 fires when 0 action groups AND 0 metric alerts despite a 200; exclude the alerting categories, never score a confident zero (live-validated) |
| Health probes counted as alerting | Probes eject backends silently; only Monitor alerts page; audit both, credit neither for the other |
| VM guest metrics promised without the agent | Credit memory/disk-free only after AMA + DCR evidence per VM; platform metrics need no agent, guest metrics do |
| Log alert credited whose KQL matches nothing | Validate with `az monitor log-analytics query` (confirmed data-plane read); inspect the count before crediting |
| AKS "off" misread as an error | `azureMonitorProfile` absent/null and the omsagent addon absent are the confirmed "off" signals, not failures |
| diagnosticSettings audited against an assumed api-version | It has no confirmed api-version; let the CLI pick it and confirm categories with `categories list` |
| Action-group receiver secrets leaked | Capture receiver display name and type only, per secret-redaction.md; never print webhook URLs or service keys |
| Toolkit brief webhook conflated with an action group | Two webhooks, two jobs; flag any overlap as a finding |
| `az costmanagement query` used for a cost figure | That CLI does not exist; the cost read path is the Cost Management Query REST API at 2023-11-01, handling 429 with backoff, never a guessed dollar |
