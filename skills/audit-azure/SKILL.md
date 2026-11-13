---
name: audit-azure
description: Read-only scored audit of Azure Monitor observability, covering action groups and alert delivery, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM/VMSS coverage, AKS Container Insights and managed Prometheus, Log Analytics coverage and retention, and App Gateway/Load Balancer diagnostics; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring Azure or Azure Monitor alerting, action groups, metric or log alerts, AKS monitoring add-ons, Log Analytics retention, or noisy Azure alerts. Do not use to change Azure resources (use setup-azure), for in-cluster Prometheus stacks on AKS (use audit-lgtm), or for Kubernetes-workload RBAC (use audit-kubernetes).
---

# audit-azure

Scored, read-only audit of the Azure surfaces that carry production observability: Azure Monitor action groups and their delivery, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM and VMSS coverage, AKS Container Insights and managed Prometheus, Log Analytics workspace coverage and retention, and Application Gateway / Load Balancer diagnostics. It answers one question: when an Azure-hosted service degrades tonight, does an alert fire, reach a human, and give the responder enough to act?

Every command in this audit is read-only: `az ... show`/`list`, ARM GETs at confirmed api-versions, the two POST-shaped **reads** (Resource Graph, Cost Management Query — classified by effect, marked `readOnly`), and the Log Analytics data-plane `az monitor log-analytics query`. Nothing is created, updated, enabled, or deleted, and no command mutates local `az` state — `az account set` is as forbidden as a cloud write; every command passes explicit `--subscription`. The full forbidden-command list is in [references/azure-cost-checks.md](references/azure-cost-checks.md) section 14.

Scope boundaries, stated so a green score never overpromises:

- **Multiple subscriptions, one run:** `azure` may be a single block (one `subscription_id`) or a **list of labeled targets**, each with its own `subscription_id`. The audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> azure labels` and run the full sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `azure/<label>/<date>/` for a list, or the flat `azure/<date>/` for a single block. Every command names `--subscription` explicitly; the ambient `az` default is never read.
- Covered: Azure Monitor (action groups, metric/log/activity alerts), VMs/VMSS, AKS monitoring surfaces, Log Analytics, and App Gateway/Load Balancer diagnostics. Not covered: App Service/Functions internals, Cosmos/SQL/Storage service-specific depth, Front Door, and API Management; if those carry production traffic, say so in the report as unaudited surface.
- In-cluster stacks (Prometheus, Alertmanager, Grafana running inside AKS) belong to `/scoutflo:audit-lgtm`; this audit covers the Azure-managed plane and states the split.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/azure/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `AZR-NNN` (cost `AZROPT-NNN`)
- `./scoutflo-audits/azure/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output)
- `./scoutflo-audits/azure/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per action group, metric alert, scheduled-query (log) alert, activity-log alert, VM, VMSS, AKS cluster, Log Analytics workspace, App Gateway, and Load Balancer (`kind`: `action_group`, `alert_rule`, `log_alert`, `activity_log_alert`, `vm`, `vmss`, `cluster`, `workspace`, `app_gateway`, `load_balancer`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/azure/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

Read-path proof and populated-rule proof are different. The reference catalog records which reads succeeded, which returned empty results, and which emit conditions remain unobserved. Never promote an empty read or a throttled request to proof of a populated predicate.

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Azure | `azure.subscription_id`, optional `azure.tenant_id` (pins the Entra tenant — asserted at the live-safety gate), optional `azure.region` (reserved for future regional-scope narrowing; not consulted today) | none stored; auth is `az login` (`DefaultAzureCredential` → `AzureCliCredential` fallback, confirmed) | `Reader` + `Monitoring Reader` on the subscription; `Log Analytics Reader` for data-plane queries; `Cost Management Reader` only for the non-scored cost section (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
set +x
# Validate the layered secret store in isolation; Azure auth stays in az login.
# Store exports must not redirect the caller's target, output directory or runtime.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
if [ -f "$SCOUTFLO_ENV" ]; then
  sh -n "$SCOUTFLO_ENV" >/dev/null 2>&1 || { echo "secret store syntax invalid" >&2; exit 1; }
  ( . "$SCOUTFLO_ENV" >/dev/null 2>&1 ) || { echo "secret store load failed" >&2; exit 1; }
fi
for bin in az curl jq python3; do command -v "$bin" >/dev/null || { echo "missing binary: $bin" >&2; exit 1; }; done
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
# The fixed ARM probe must return a JSON list envelope, not HTML with a 200 status.
PROBE=$(azure_http GET "$ARM/subscriptions/$SUB/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01")
printf '%s' "$PROBE"|azure_project -e '(.value|type)=="array"' >/dev/null
echo "action-groups api: 200 with JSON list; selected identity verified"
```

Requires curl 8.4 or newer for bounded unknown-length responses. Expected: the identity line, the resolved subscription, and `action-groups api: 200 with JSON list`, all asserted by the block itself. Any assertion failing stops the block with a nonzero exit; never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same checks standalone.

Two notes that live here because they bite at the gate:

- If the audit identity holds `Contributor`, `Owner`, or `User Access Administrator`, the audit still runs, but record in the report that the audit credential can write; a read-only identity (`Reader` + `Monitoring Reader`) is itself part of good posture.
- The Log Analytics data-plane query needs the `log-analytics` az extension (audience `https://api.loganalytics.io`); if it is absent, the log-coverage checks that use it record `blocked` with the install hint, never a fabricated pass.

## Live-safety gate

Print what you are pointed at and compare it against the config before the first real check. The comparison value comes from `toolkit.yaml`, not from what an operator typed or what `az account set` left active in another terminal:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
echo "live-safety gate passed: selected subscription and optional tenant pin verified"
```

The assertion is the gate: the target subscription must be **visible to this identity** (`az account list`) or the block exits nonzero and stops the run. A multi-subscription estate audits each configured target in turn (the runner sets `SCOUTFLO_TARGET=<label>`), so — unlike a single-subscription equality check — the ambient `az` default is **not** required to equal the target; instead every command names `--subscription "$SUB"` explicitly, so the run can never touch a subscription other than the one it resolved from `toolkit.yaml`. If the printed identity or tenant is not the one your team intends for audits, stop and report the mismatch even though the visibility check passed; identity, tenant, and subscription are separate checks. `az account set` is never used, and pointing the audit elsewhere is an edit to `toolkit.yaml`.

## Ground rules

- Configuration is metadata; live validation is proof. An alert rule in the list is `configured`; only an observed Azure Monitor notification, or a proven delivery path, makes routing `validated-live`.
- API errors are evidence. A `403` can mean a missing role or another access policy; a `404` can mean a wrong scope, hidden object, or retired resource; a `429` on the cost path means throttling, not absence. Record the code and what it implies; never convert an error into empty success. (401/404 statuses are confirmed; a `429` on Cost Management is confirmed and must be retried with backoff, never read as "no data".)
- Never score from object counts. A subscription with thirty alert rules and six action groups is not "covered": credit stops until each enabled rule names a reachable action group and delivery is proven.
- Bound negative telemetry and delivery claims to the Azure paths inspected in the selected subscription. Alternate collectors, external or cross-subscription destinations, retained copies, and other paging routes remain unknown unless separately evidenced. Resource names and missing objects do not establish production status, criticality, or the required telemetry plane; without that intent, record confirmed configuration absence but keep the required-coverage conclusion `blocked`. Severity follows evidenced impact, never absence alone.
- A Load Balancer / App Gateway health probe keeps traffic away from a bad backend; it pages nobody. Health probes and Azure Monitor alerts are different systems — neither presence scores the other.
- Credit the inspected Azure Monitor guest-metric path (memory, disk-free, per-process) only with Azure Monitor Agent + Data Collection Rule evidence; platform metrics need no guest agent. Missing AMA/DCR proves no coverage through that inspected path, not that another collector measures nothing.
- Extension names alone do not establish Azure Monitor Agent publisher/type or DCR coverage; node capacity is not running-state evidence. Probe/rule names or counts do not prove attachment or live effectiveness. Keep these predicates unknown until the required fields or observations are read.
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
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_identity
SMALL_MAX_OBJECTS="${AZURE_SMALL_MAX_OBJECTS:-15}" # examples; tune before starting the run
MEDIUM_MAX_OBJECTS="${AZURE_MEDIUM_MAX_OBJECTS:-60}"
case "$SMALL_MAX_OBJECTS:$MEDIUM_MAX_OBJECTS" in *[!0-9:]*|:*|*:) echo "invalid estate thresholds" >&2; exit 1;; esac
[ "$SMALL_MAX_OBJECTS" -le "$MEDIUM_MAX_OBJECTS" ] || exit 1
count_read() { _list=$(azure_cli "$@"); printf '%s' "$_list"|azure_project -er 'if type=="array" then length else error("list expected") end'; }
VMS=$(count_read vm list); VMSS=$(count_read vmss list); AKS=$(count_read aks list)
APPGW=$(count_read network application-gateway list); LBS=$(count_read network lb list)
AGS=$(count_read monitor action-group list); METRIC_ALERTS=$(count_read monitor metrics alert list)
TOTAL=$((VMS + VMSS + AKS + APPGW + LBS))
ESTATE_PATH=large
[ "$TOTAL" -gt "$MEDIUM_MAX_OBJECTS" ] || ESTATE_PATH=medium
[ "$TOTAL" -gt "$SMALL_MAX_OBJECTS" ] || ESTATE_PATH=small
mkdir -p "$OUT"
# Stable, target-bound state supplies TOTAL to the next fresh shell.
jq -n --arg target "$AZ_SEG" --arg d "$RUN_DATE" --arg path "$ESTATE_PATH" --argjson n "$TOTAL" \
  '{target:$target,run_date:$d,objects:$n,path:$path}' > "$OUT/estate.json"
echo "vms=$VMS vmss=$VMSS aks=$AKS app_gateways=$APPGW load_balancers=$LBS action_groups=$AGS metric_alerts=$METRIC_ALERTS scored_objects=$TOTAL path=$ESTATE_PATH"
PREV_FILE=$(azure_previous_findings); PREV_RUN=${PREV_FILE%/findings.json}
if [ -n "$PREV_RUN" ] && [ -f "$PREV_RUN/findings.json" ]; then
  PREV_TOTAL=$(jq -r '.estate.objects//empty' "$PREV_RUN/findings.json")
  [ -z "$PREV_TOTAL" ] || echo "drift: prior estate=$PREV_TOTAL current estate=$TOTAL; still recheck every scoped resource"
fi
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (routing, alert coverage, VMs, AKS, Log Analytics, LB), completed in one run.
- **Large**: work VMs/VMSS, App Gateways, and Load Balancers in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist, per [Large-path worklist](#large-path-worklist) below; alert routing, AKS, Log Analytics, and alert-quality checks are subscription- or category-scoped and always run once per run regardless of path.

A denied, malformed, or provider-unavailable list is `blocked`. Only a successful complete empty list or your explicit scope decision supports absence or `not-in-scope`; record the reason. Record the chosen path and counts in `findings.json` as `estate: {objects, path}`; `audit-all` reads them. Never silently truncate: if the run judged a subset, the report names what was skipped and the coverage denominators reflect it.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
TOTAL=$(jq -er --arg target "$AZ_SEG" --arg d "$RUN_DATE" '
  select(.target==$target and .run_date==$d)|.objects|select(type=="number" and .>=0 and floor==.)' "$OUT/estate.json")
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE=$(checkpoint_load_scope)
[ "$SCOPE" = all ] || echo "[checkpoint] reusing saved audit scope: $SCOPE"
if [ "$TOTAL" -ge 501 ]; then
  cli_pause_before_audit "$TOTAL"
  cli_prompt_exclude_services
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

### Empty / hidden-scope guardrail (AZR-007)

The scope checkpoint above narrows a *large* estate. This guardrail catches the opposite and more dangerous case: an estate that looks like it has **no alerting** because the identity or resource-group scope cannot see the alerting objects. It is the Azure analog of audit-elk's space-visibility trip-wire (ELK-033) and the JSM/Zenduty team-visibility guardrails: scoring a confident `0/100` because the API returned zero action groups is the same wrong answer as auditing only the `default` Kibana space. **This guardrail is live-validated** — on a live subscription that returned 0 action groups AND 0 metric alerts, the trip-wire fired correctly, proving it detects zero-alerting-despite-200 rather than scoring a confident zero. After Phase 2 materializes the raw inventory:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
azure_require action-groups metric-alerts
AGS="$(jq 'length' "${RAW_DIR}/action-groups.json")"
ALERTS="$(jq 'length' "${RAW_DIR}/metric-alerts.json")"
if [ "${AGS:-0}" -eq 0 ] && [ "${ALERTS:-0}" -eq 0 ]; then
  # Both empty despite a readable ARM surface (the doctor gate returned 200, not 401/403).
  echo "[guard] 0 action groups AND 0 metric alerts in target ${AZ_LABEL} (subscription ${SUB}) despite a readable ARM surface — possible identity / resource-group visibility gap (AZR-007)"
  echo "[guard] alerting may live in a resource group this identity cannot read, or this identity lacks Monitoring Reader at subscription scope — do NOT score a confident 0/100"
fi
```

Behavior this enforces (Phase 11 honors it):

- **Alerting-object-dependent categories excluded** — every check in **Alert routing and delivery, Alert coverage, and Alert quality** records `blocked` with the visibility-gap reason; each fully-unassessed category (assessed==0) then moves to `score.excluded[]` and renormalizes out per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md). Emit finding **AZR-007** (`scoring_scope: "non-scored"`, points_recoverable 0, no check-ledger row) naming the gap and the fix (confirm the identity holds `Reader`/`Monitoring Reader` at subscription scope, and check the resource groups that hold the alerting objects — recipe in `/scoutflo:connect`). **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim.
- **Examine resource-signal categories independently** — Compute VM/VMSS, AKS, Log Analytics and edge evidence does not depend on the alerting inventory. Do not block those categories merely because the alerting guardrail fired. Assess only predicates supported by the collected fields and established requirements; unread or insufficient evidence remains `blocked`. Readable resources do not force a pass or failure. When no predicate can be assessed, emit the supported v2 `unassessed` result with a null score and explicit gaps.
- If those resource categories are **also** empty — a pure subscription with no resources of its own, or an identity that can see nothing — every check is `blocked`, the run is `state: "unassessed"` with `overall: null` (never a confident score at all), and AZR-007 is the reported outcome. A `401`/`403` from Phase 2 is a *privilege* finding, not this trip-wire.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it and use its canonical service names in findings, the coverage matrix, and `affected` arrays. Treat a service as critical or production only when topology, business context, or other cited evidence declares it; a service list alone does not. If topology is missing, resource names may support provisional resource/service grouping only: label that grouping inferred, keep criticality, production status, and required telemetry plane unknown, and suggest `/scoutflo:map-topology`. Ask for the missing intent before judging required coverage; meanwhile report observed Azure configuration. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/azure-checks.md](references/azure-checks.md): action groups (redacted at capture, as a JSON array in `raw/action-groups.json`), metric alerts (`raw/metric-alerts.json`), scheduled-query rules, activity-log alerts, VMs and VMSS with SKU metadata (power-state cost evidence comes from the separate Resource Graph read), AKS names and IDs for the per-cluster detail reads in Phase 6, Log Analytics workspaces with `retentionInDays`, App Gateways / Load Balancers with their health probes and diagnostic settings. Judgment starts in Phase 3; inventory records what exists. Use the confirmed api-versions: `actionGroups` 2023-01-01, `metricAlerts` 2018-03-01, `scheduledQueryRules` 2022-06-15, `activityLogAlerts` 2020-10-01, `managedClusters` 2024-09-01, `workspaces` 2022-10-01, `virtualMachines`/`virtualMachineScaleSets` 2024-07-01, `applicationGateways`/`loadBalancers` 2024-05-01. `diagnosticSettings` has **no** confirmed api-version — let the `az` CLI pick it and confirm supported categories with `az monitor diagnostic-settings categories list`, never assert one.

## Phase 3: Alert routing and delivery (AZR-001, AZR-005)

Commands in [references/azure-checks.md](references/azure-checks.md). Judge whether an alert that fires reaches a human. Do not stop at "an action group with 0 receivers pages nobody" — perform the join that IS the blast radius: for each enabled rule in `metric-alerts.json`/`scheduled-query-rules.json`/`activity-log-alerts.json`, resolve every `actionGroupId` to `action-groups.json` and sum receiver counts; a rule whose *only* groups have 0 enabled receivers is mute even though it references a group. Report it as the named set (`N enabled rules covering [checkout-vm-1, payments-sql, appgw-prod] all terminate at ops-catchall with 0 enabled receivers`), mapped to topology service names, and cite the AZR-002 pass it invalidates. Also required: at least one enabled action group with a live receiver exists where Azure paging is required (severity follows the evidenced impact of a missing route); every enabled alert rule names at least one action group; groups split per environment (`<team>-<environment>-alerts`) instead of one catch-all; no disabled or dead receiver still referenced by a rule; and delivery proven by an observed notification rather than assumed (capped at `configured` without one — Azure Monitor exposes no public fired-notification list, so a team-confirmed sighting is the documented manual exception). Any action group that appears to be the toolkit Slack brief webhook is flagged, not counted as alerting.

**AZR-005 alert-processing (suppression) rules (verify-pending).** Routing can look healthy — groups have receivers, rules reference them (AZR-001 passes) — while an enabled alert-processing rule with action `RemoveAllActionGroups` silently swallows the notification between "rule fires" and "page leaves Azure". Intersect each enabled suppression rule's `scopes[]` with the resource groups holding critical resources and name the muted services; a rule scoped at a production resource group with no end schedule is a permanent estate-wide mute. It negates the AZR-001 pass and is the hidden middle of the flagship chain. The `actionRules` read path returned an empty live result. Its populated suppression predicate remains unobserved; validate the enabled/action/scope/schedule fields on the selected estate before a confident finding. A denied or unknown-shaped response is `blocked`.

## Phase 4: Alert coverage — metric, log, activity (AZR-002, AZR-003, AZR-004)

Commands in [references/azure-checks.md](references/azure-checks.md).

- **AZR-002 metric alerts.** Each critical resource (App Service, SQL, Storage, Cosmos, VM — anything with an ARM resource id) carries a platform-metric alert on the signal that matters, scoped to a real resource id that emits the metric (a rule watching a metric the resource never ships can never fire). Two named tiers (warning/critical) where the workload is stable. Split the misses into two named buckets, never one generic "saturates silently": **(a) no rule at all** — name the resource and the signal that would have fired, fix = add a two-tier alert; **(b) rule present but `enabled:false`** — phantom coverage that inventory reads as covered ("`payments-sql` HAS rule `sql-dtu-critical` but it is `enabled:false`"), the "someone silenced it in an incident and never re-enabled it" signal, fix = re-enable the existing rule (cheaper) not author a new one, and name which. A covered resource whose rule routes to a dead group (AZR-001) or a suppressed scope (AZR-005) is doubly blind.
- **AZR-003 scheduled-query (log) alerts.** Log-rate, missing-heartbeat, and business-signal coverage a metric alert cannot give. Credit requires the workspace to actually receive the logs the KQL reads and the query to return rows for a real condition — validate with the confirmed data-plane read `az monitor log-analytics query` (needs the `log-analytics` extension); an alert on a query that matches nothing is decoration.
- **AZR-004 activity-log alerts.** Control-plane coverage for the subscription itself: Azure Service Health advisories, Resource Health transitions, and policy/administrative events, each attaching an action group. Where this Azure paging route is required, a missing Service Health alert leaves that route without the inspected advisory notification; other notification routes remain unassessed.

## Phase 5: Compute VM/VMSS coverage (AZR-010)

Commands in [references/azure-checks.md](references/azure-checks.md). Per serving VM or scale set: platform CPU/disk/network alerts (no agent needed) with two tiers where stable; guest metrics on the inspected Azure Monitor path credited **only** after Azure Monitor Agent + Data Collection Rule evidence proves them live per VM; alternate guest collectors remain unassessed; and every metric-alert scope resolves to a resource that emits the metric. A VMSS running fixed capacity with alerts only on the aggregate hides a single unhealthy instance; name that gap. Stopped-but-billed VMs (power state `PowerState/stopped`) are a cost signal handled in the non-scored cost section, not here.

## Phase 6: AKS coverage (AZR-030, AZR-031, AZR-032, AZR-033)

Commands in [references/azure-checks.md](references/azure-checks.md). AZR-030/031/032 verify against **confirmed** property paths from `az aks show`:

- **AZR-030 Container Insights** — `addonProfiles.omsagent.enabled == true` (with `.config.logAnalyticsWorkspaceResourceID` pointing at a real workspace); the addon absent is the "off" signal, not an error. Don't file "Container Insights off" as the finding — join the cluster to the critical workloads scheduled on it (topology.md) and name what goes dark: "`aks-prod` runs `checkout`, `orders`, `payments` per declared topology; Container Insights is off, so this inspected Azure collection path is absent. Whether another collector retains container logs or metrics is unassessed."
- **AZR-031 managed Prometheus** — `azureMonitorProfile.metrics.enabled == true`; `azureMonitorProfile` absent/null is "off" (confirmed). Credit this where workload metric alerting is expected.
- **AZR-032 AKS diagnostic settings** — the cluster's control-plane logs route to a Log Analytics workspace via a diagnostic setting; name the incident it blinds, not the missing object: "`aks-prod` has no inspected diagnostic route for these control-plane categories to its required Log Analytics destination, leaving this Azure investigation path unavailable; other destinations and retained copies are unassessed." State the cluster and which log categories are unrouted (confirm categories with `categories list`).
- **AZR-033 managed-Prometheus rule-group consumption (verify-pending).** A cluster with `azureMonitorProfile.metrics.enabled == true` is collecting and being billed for metrics; if **zero** inspected `prometheusRuleGroups` reference its Azure Monitor workspace, this Azure rule-group path has no observed consumer; alternate rule engines remain unassessed. Metrics collected do not prove alerting. This is the alerting-plane extension AZR-031 never performs. The `prometheusRuleGroups` 2023-03-01 read returned an empty live result; populated rule-group fields remain unobserved. Validate the workspace-to-enabled-rule join on this estate before scoring it.

Where the in-cluster Prometheus/Alertmanager stack is the primary alerting plane, mark the overlapping checks `not-in-scope`, state the split, and run `/scoutflo:audit-lgtm` against that stack. Enabling any of these is a controlled rollout (a cluster mutation), out of read-only scope — findings point at `setup-azure`, which plans it.

## Phase 7: Log Analytics coverage and retention (AZR-040, AZR-041, AZR-042)

Commands in [references/azure-checks.md](references/azure-checks.md). Assess the Log Analytics destinations actually referenced by inspected Azure routes in the selected subscription. Log Analytics is not assumed to be the estate’s only or required evidence plane; a destination in another subscription or another telemetry system remains unassessed unless separately evidenced.

- **AZR-040 coverage/retention.** When declared requirements or inspected destination references establish that Log Analytics is required, assess those routes and compare workspace retention with the stated investigation window. Compute only the observed fan-in: "`la-prod` receives inspected diagnostic routes from 6 VMs, 2 AKS clusters, and 3 edges; `retentionInDays=30` limits the queried copy in this workspace. Longer-lived copies elsewhere are unassessed." Count critical resources only when their criticality is evidenced. If no workspace is inventoried, report that selected-subscription fact; do not infer that the estate has no logs or assign critical severity automatically. Without required-plane intent, AZR-040 required coverage is `blocked` with the missing declaration named. With intent, severity follows the evidenced service impact of the missing route or insufficient retention.
- **AZR-041 workspace stopped ingesting (verify-pending).** Config presence (AZR-040) is not ingestion. A workspace can be a configured destination while the agent/DCR feeding it has stopped — a data-plane recency read (`az monitor log-analytics query` on `Heartbeat`/critical-table freshness, confirmed read path) yields the last ingestion time. A stale workspace invalidates every AZR-030/032/050 pass that routes to it and is the evidence-plane half of the flagship chain. Drafted but not run against a live tenant; carry the verify-pending caveat.
- **AZR-042 Activity Log never exported (verify-pending).** Distinct from AZR-004 (whether activity-log *alerts* page): whether the inspected Azure export retains the required categories in Log Analytics. If the subscription-scope diagnostic settings export no `Administrative`/`Security`/`Policy` categories to a workspace, control-plane events (who deleted the alert rule, who changed the NSG) remain available in the native Azure Activity Log within its retention; no inspected export to Log Analytics was established. Other exports or copies remain unassessed, so this is not proof that the forensic trail is absent everywhere. The subscription-settings read returned an empty live result; populated export/category fields remain unobserved and need verification on this estate.

## Phase 8: Load balancer and App Gateway coverage (AZR-050)

Commands in [references/azure-checks.md](references/azure-checks.md). Inspect each serving Application Gateway / Load Balancer’s probe attachment and diagnostic routes; judge a Log Analytics destination only where it is required by declared intent or evidenced architecture. For example: "`appgw-prod` fronts `checkout-pool` with 0 inspected probes and no inspected diagnostic route to the required workspace. AZR-002 found no matching Azure metric-alert route; backend-failure detection and investigation on these Azure paths are unproven. External alerts and logs are unassessed." State the edge, pool, and inspected metric signals without claiming that all traffic continues or nobody is paged from these counts alone. Health probes and Monitor alerts are audited separately; neither is credited for the other. Editing a live probe is traffic-impacting and out of write scope; only the diagnostic-settings half is a monitoring-plane fix.

## Phase 9: Alert quality (AZR-060)

Commands in [references/azure-checks.md](references/azure-checks.md). Reading the rule bodies already captured in Phase 2 (no new call, no mutation): each paging rule carries a `windowSize`/`evaluationFrequency` that debounces a single transient sample; `severity` is set to a real tier (0 critical … 4 verbose), not left at a default that makes everything look equally urgent; documentation tells the responder where they are, how bad it is, and what to capture first. Surface the two highest-signal noise classes concretely: **(a) permanently firing** — a rule with a threshold below the resource's steady-state ("`cpu>5%` on `appgw-prod` (steady-state 40%) fires continuously"); **(b) possible overlapping fan-out** — the same logical condition names multiple groups; confirm intended recipients and actual overlapping delivery before calling it duplicate paging. Noise on the same action group buries the real pages that reach the one live receiver (chains with AZR-001 — the noise-drowns-signal cascade). Honest ceiling, stated in the report every run: This audit does not collect human notification receipts, so it reports **structural** noise signals read off each rule's configuration and never a fabricated "N% of alerts are actionable" number.

## Phase 10: Coverage matrix and topology readiness

Fill one row per critical service using the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Metric | Log | VM/VMSS | AKS | Log Analytics | LB/AppGW | Routing | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the `VM/VMSS` cell folds in the AMA gate (platform-only coverage caps it at `partial` with the gap named); the `Log` cell requires a matching, recently-matching, action-group-carrying query to reach `pass`; every cell carries its `passed/total` denominator. Name affected services in findings: "two VMs lack memory coverage" is not a finding; "checkout-vm-1 and checkout-vm-2 lack memory coverage" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live counts toward T6. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. If the export or topology.md is missing or describes a different target, render the matching state from topology-readiness.md with its one-line unlock; never guess and never say a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 11: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is the assessed-credit ratio times 100 rounded down; overall is the weight-normalized sum over categories with at least one assessed check. Show assessment coverage separately. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively.

**Assemble the flagship detection-blindness chain.** Before scoring, join evidenced gaps for a named service along the inspected Azure path: `alert-EXISTS × route-LIVE × signal-MEASURED × evidence-RETAINED`. For example: *"`checkout-vm-1` is critical per declared topology. Its inspected CPU alert routes only to an action group with no enabled receivers, and a verified active suppression rule covers its scope. No AMA/DCR guest-memory path was established; the required `la-prod` workspace's inspected table is stale. These Azure paging and investigation paths have confirmed gaps. Alternate collectors, notification routes and retained copies are unassessed."* Keep each link tied to its observed scope and required-plane intent. This joins individual findings without claiming that no page fires, no metric exists, or the service is undetectable everywhere. Delivery receipts and declared architecture are required for an end-to-end conclusion; mark every unknown, verify-pending, or blocked link explicitly.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert routing and delivery | 25 | AZR-001, AZR-005 |
| Alert coverage (metric, log, activity) | 25 | AZR-002 to AZR-004 |
| Compute VM/VMSS coverage | 15 | AZR-010 |
| AKS coverage | 15 | AZR-030 to AZR-033 |
| Log Analytics coverage | 10 | AZR-040 to AZR-042 |
| Load balancer / App Gateway coverage | 5 | AZR-050 |
| Alert quality | 5 | AZR-060 |

Weights are unchanged from the prior release (they still sum to 100); the four new checks (AZR-005, AZR-033, AZR-041, AZR-042) fold into their home categories rather than triggering a reweight. AZR-005, AZR-033 and AZR-042 have confirmed empty read paths; their populated emit predicates remain unobserved. AZR-041 remains live-verify-pending. Judge each from this run’s evidence: validate populated property shapes and joins before scoring; an empty list proves no field semantics. Missing or unknown-shaped evidence is `blocked`, excluded from the readiness denominator and shown in assessment coverage. Never claim live validation from a static fixture.

The full check catalog and the target profile (what 100 means per category) are in [references/azure-checks.md](references/azure-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers. `AZR-007`, when it fires, excludes the alerting-dependent categories rather than scoring them zero (see the guardrail section).

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding, `AZR-*` and `AZROPT-*` alike, per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `points_recoverable` to 0. Suppressed readiness checks remain assessed for coverage but are excluded from readiness scoring. A non-scored `AZROPT-*` finding has no check row: set only its lifecycle to `suppressed`, preserve `scoring_scope: "non-scored"`, and keep zero readiness points.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `AZR-*` readiness catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `AZROPT-*` findings stay outside the readiness ledger and explicitly carry `scoring_scope: "non-scored"`. The AZR-007 guardrail is not a standing catalog check: when it fires it is emitted as a `scoring_scope: "non-scored"` finding (points_recoverable 0, no check-ledger row); its score impact is that the alerting-dependent categories' own checks record `blocked` and, being fully unassessed, move to `score.excluded[]`. Every `not-in-scope` row additionally carries `not_in_scope_reason` — one of `inapplicable` (nothing of the kind exists on this target), `target-gone` (proven decommissioned), `by-design` (you declared it) or `covered-elsewhere` (verified on the plane that owns it) — per [not-in-scope-reasons.md](../../report-standard/not-in-scope-reasons.md). A row you cannot evidence is `blocked`, not `not-in-scope`.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass `AZR-*` check; `non-scored` for `AZROPT-*` and the AZR-007 guardrail) and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Use the AI SRE lane only when the evidence shows impact to telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/worklist.sh" assert
mkdir -p "$OUT"
# ... write findings.json (scoutflo-findings/v2 with a complete checks[] ledger),
# inventory.json, and report.md per the report standard. The findings.json
# ".target" is the per-target slug (equal to $AZ_SEG: "azure" for a single block, "azure/<label>" for
# a labeled list target), so audit-all/correlation/render disambiguate multiple subscriptions. Verify:
jq -e --arg seg "$AZ_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.checks | type == "array" and length > 0)
  and (.findings | type == "array")
  and (.findings | all((.scoring_scope | IN("readiness","non-scored")) and (.report_lanes | type == "array" and length > 0)))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance + score reconciliation, then the viz, then template conformance.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-1 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e '.schema == "scoutflo-inventory/v1" and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "$OUT/findings.json" >/dev/null && echo "findings-by-purpose section renders"
grep -qxF '## Findings by purpose' "$OUT/report.md" && echo "findings-by-purpose section present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer. Then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
PREV=$(azure_previous_findings)
# Absence is not resolution. Count only prior failed IDs with a currently passing check.
if [ -n "$PREV" ]; then
  RESOLVED=$(jq -n --slurpfile p "$PREV" --slurpfile c "$OUT/findings.json" '
    [$p[0].findings[]|select((.lifecycle//"new")!="suppressed")|.id] as $before
    |[$c[0].checks[]|select(.result=="pass")|.id] as $passing
    |[$before[]|select(. as $id|$passing|index($id)!=null)]|unique|length')
else RESOLVED=$(jq -n '[]|length'); fi
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-azure", overall:.score.overall, state:.score.state,
    scoring_model:.score.scoring_model, check_set:.score.check_set,
    assessment_coverage_percent:.score.assessment.coverage_percent, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and ((.overall|type)=="number" or .overall==null) and .scoring_model and .check_set' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first; the ledger is derived and never drives finding lifecycle. Then send the Slack brief: titles only, never evidence values, hostnames, subscription ids, tenant ids, or endpoints:

```bash
set -eu
set +x
[ "${SCOUTFLO_SUPPRESS_SLACK:-0}" != 1 ] || exit 0
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
[ "$(sh "$TT" "$CFG" slack kind)" = map ] || { echo "Slack requires one configured destination per environment; skipping brief"; exit 0; }
WEBHOOK_ENV=$(sh "$TT" "$CFG" slack get 0 webhook_env)
printf '%s\n' "$WEBHOOK_ENV" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || { echo "Slack webhook_env is missing or invalid; skipping brief"; exit 0; }
# Import only the configured value; store settings never change this run's output root.
# An explicitly named missing variable never falls back to an ambient default.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
if [ -f "$SCOUTFLO_ENV" ]; then
  SLACK_URL=$(sh -eu -c '. "$1" >/dev/null 2>&1; printenv -- "$2"' _ "$SCOUTFLO_ENV" "$WEBHOOK_ENV" 2>/dev/null) || { echo "Slack selected credential unavailable; skipping brief"; exit 0; }
else
  SLACK_URL=$(printenv -- "$WEBHOOK_ENV" 2>/dev/null || true)
fi
TOPO_LINE="Topology readiness: see the report's observed T1–T6 results"
COST_LINE=""
if [ -n "$SLACK_URL" ]; then
  [ -s "$OUT/findings.json" ] && [ -s "$OUT/report.md" ] || { echo "Slack report unavailable; skipping brief"; exit 0; }
  OUT_ABS="$(cd "$OUT" && pwd)"   # absolute path: the brief must be openable from anywhere
  SCORE="$(jq -r '.score.overall' "$OUT/findings.json")"
  SCORE_STATE="$(jq -r '.score.state' "$OUT/findings.json")"
  CUR_MODEL="$(jq -r '.score.scoring_model' "$OUT/findings.json")"
  CUR_SET="$(jq -r '.score.check_set' "$OUT/findings.json")"
  ASSESSMENT="$(jq -r '.score.assessment | "\(.assessed_checks)/\(.applicable_checks) (\(.coverage_percent)%) assessed, \(.scored_checks) scored, \(.blocked_checks) blocked, \(.suppressed_checks) suppressed"' "$OUT/findings.json")"
  E2E="$(jq -r 'if .score.end_to_end then "end-to-end" else "not end-to-end" end' "$OUT/findings.json")"
  COUNTS="$(jq -r '.severity_counts | "\(.critical) critical, \(.high) high, \(.medium) medium, \(.low) low"' "$OUT/findings.json")"
  CHECKS="$(jq -r '"\([.score.categories[].checks_passed] | add)/\([.score.categories[].checks_total] | add) checks passed"' "$OUT/findings.json")"
  TOP="$(jq -r '[.findings[] | select((.lifecycle // "new") != "suppressed") | select(.area != "cost-optimization") | "\(.id) \(.title)"] | .[0:5] | join("\n")' "$OUT/findings.json")"
  AZROPT_COUNT="$(jq -r '[.findings[] | select(.area == "cost-optimization")] | length' "$OUT/findings.json")"
  [ "$AZROPT_COUNT" -gt 0 ] && COST_LINE="Cost: ${AZROPT_COUNT} optimization opportunities found"
  PREV_FILE=$(azure_previous_findings); PREV=${PREV_FILE%/findings.json}
  MOVE=""; DELTA="first run"
  if [ -n "$PREV" ] && [ "$PREV" != "$OUT" ]; then
    PREV_MODEL="$(jq -r '.score.scoring_model // ""' "$PREV/findings.json")"
    PREV_SET="$(jq -r '.score.check_set // ""' "$PREV/findings.json")"
    PREV_SCORE="$(jq -r 'if (.score.overall|type)=="number" then .score.overall else "" end' "$PREV/findings.json")"
    if [ "$SCORE_STATE" = "assessed" ] && [ -n "$PREV_SCORE" ] && [ "$PREV_MODEL" = "$CUR_MODEL" ] && [ "$PREV_SET" = "$CUR_SET" ]; then
    MOVE="$(jq -rn --argjson prev "$(jq '.score.overall' "$PREV/findings.json")" --argjson cur "$SCORE" \
      '(($cur - $prev) | if . >= 0 then "(+\(.))" else "(\(.))" end)')"
    fi
    DELTA="$(jq -rn --slurpfile p "$PREV/findings.json" --slurpfile c "$OUT/findings.json" '
      [$p[0].findings[].id] as $b | [$c[0].findings[].id] as $n |
      [$c[0].checks[] | select(.result=="pass") | .id] as $passing |
      "\([$b[] | select(. as $id | $passing | index($id)!=null)] | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  if [ "$SCORE_STATE" = "unassessed" ]; then
    HEAD="audit-azure ${RUN_DATE}: readiness unassessed; ${ASSESSMENT}. ${COUNTS}."
  else
    HEAD="audit-azure ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}; ${ASSESSMENT}. ${COUNTS}. ${CHECKS}."
  fi
  SLACK_PAYLOAD=$(jq -n --arg head "$HEAD" \
        --arg top "$TOP" --arg delta "$DELTA" --arg topo "$TOPO_LINE" --arg cost "$COST_LINE" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\n" + $topo + ($cost | if . == "" then "" else "\n" + . end) + "\nReport: " + $path)}') || { echo "Slack brief encoding failed; nothing sent"; exit 0; }
  printf '%s' "$SLACK_PAYLOAD" | curl -q -fsS --proto '=https' --max-time 10 -H 'Content-Type: application/json' -d @- "$SLACK_URL" 2>/dev/null \
    || echo "Slack brief failed to send; audit result unaffected"
fi
```

After history is written and the optional brief is sent or explicitly skipped, close the local run. Keep its active pointer until these date-bound consumers finish, including when a resumed run crosses midnight:

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/worklist.sh" finish
```

When invoked by `audit-all`, skip the Slack brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your infrastructure.

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # workspace projection, derived from the SSOT
BC_MD="${HOME}/.scoutflo/business_context.md"          # the SSOT itself (authoritative)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver

# The workspace layer and the per-resource layer load TOGETHER, not either/or.
HAVE_PER_RESOURCE=0; HAVE_WORKSPACE=0
[ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1 && HAVE_PER_RESOURCE=1
[ -f "$BC_JSON" ]  && jq -e '.' "$BC_JSON"  >/dev/null 2>&1 && HAVE_WORKSPACE=1
# Workspace source: the derived json, else the markdown SSOT directly (ssot-md fallback).
BC_SRC=""
if [ "$HAVE_WORKSPACE" -eq 1 ]; then BC_SRC="$BC_JSON"; elif [ -f "$BC_MD" ]; then BC_SRC="$BC_MD"; fi
if   [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ "$HAVE_WORKSPACE" -eq 1 ]; then LOAD_METADATA_MODE="per-resource+workspace"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ -n "$BC_SRC" ];             then LOAD_METADATA_MODE="per-resource+ssot-md"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ];                                then LOAD_METADATA_MODE="per-resource"
elif [ "$HAVE_WORKSPACE" -eq 1 ];                                   then LOAD_METADATA_MODE="workspace"
elif [ -n "$BC_SRC" ];                                              then LOAD_METADATA_MODE="ssot-md"
else                                                                     LOAD_METADATA_MODE="none"; fi
echo "metadata mode: $LOAD_METADATA_MODE"

# Load the workspace rules the apply step below honors. All fields optional; absence = neutral default.
if [ "$HAVE_WORKSPACE" -eq 1 ]; then
  ENVIRONMENT="$(jq -r '.environment // "production"' "$BC_JSON" 2>/dev/null || echo production)"
  COST_SENSITIVITY="$(jq -r '.cost_sensitivity // "medium"' "$BC_JSON" 2>/dev/null || echo medium)"
  CRITICAL="$(jq -r '.critical_dependencies[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  EXCLUSIONS="$(jq -r '.exclusions // {} | [.accounts?, .regions?, .services?, .resources?] | add // [] | .[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  jq -r --arg e "$ENVIRONMENT" '.environment_map[]? | select(.environment==$e)' "$BC_JSON" 2>/dev/null || true  # per-env profile/project/context + uptime_sla
  jq -r '.service_slas[]? | "\(.service)=\(.sla)"' "$BC_JSON" 2>/dev/null || true                               # per-service SLA (wins over the env default)
elif [ "$BC_SRC" = "$BC_MD" ]; then
  # Read the selected Markdown workspace rules even when a per-resource cache is present.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with `not_in_scope_reason: "by-design"` (the exclusion is your declaration) and the exclusion as the `reason`, never a fail); **escalate** findings on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (per-env SLA); and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule. Processing defaults are not evidence of production status, criticality, or a required telemetry plane; keep any undeclared attribute unknown in findings and severity judgments.

## Large-path worklist

After the complete inventory, use the local-only worklist on the large path. It copies the projected inventory into `azure/[<label>/]runs/<RUN_ID>/raw/`, records the original UTC date, and restores both when a later fresh shell resumes. Published reports retain the normal date layout. A pending run is resumed instead of replaced. Examined resources have content-hashed receipts: successful reads are `done`; failed reads are `blocked` with null unavailable payloads and an explicit reason. Both are examined, but a blocked receipt never earns readiness credit. Unprocessed rows still prevent finalization.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
ESTATE_PATH=$(jq -er --arg seg "$AZ_SEG" 'select(.target==$seg)|.path' "$OUT/estate.json")
if [ "$ESTATE_PATH" = large ]; then
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/worklist.sh" start
  # Use one stable, non-secret worker token for this operator across fresh shells.
  : "${SCOUTFLO_AZURE_WORKER:?export a stable worker token before claiming a batch}"
  BATCH_SIZE="${BATCH_SIZE:-10}"; export BATCH_SIZE
  sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/worklist.sh" claim
fi
```

Run the VM/VMSS and edge diagnostic blocks for the claimed batch; they select only that worker's claimed rows and record success or explicit blocked evidence for each required read. Repeat the claim block until status reports `pending=0`. A fresh shell with the same worker token resumes an interrupted claim and skips examined rows. Another worker cannot claim the same batch. After confirming an interrupted worker has stopped, run `sh "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/worklist.sh" release` with its token to return only its unfinished claims to pending. Do not remove another worker's live lock; a leftover local operation lock requires confirming that process has stopped first.

Before report emission, `worklist.sh assert` rejects any unfinished row or changed receipt. After report validation, history, and the brief attempt, `worklist.sh finish` clears the active pointer and preserves the completed run. An unprocessed run never overwrites a complete report. A report with examined-but-blocked rows is valid: emit those checks as unassessed, disclose coverage, and never present their null evidence as success or absence. Subscription/category checks still run once per run; the worklist is specifically for VM, VMSS and edge per-resource reads. Apply confirmed exclusions before initialization, preserve excluded IDs with reasons in the check ledger, and include that scoped denominator in the report.

## Cost and Resource Optimization (not scored)

A separate, **never-scored** section reports Azure cost and idle-resource signals under the `AZROPT-NNN` prefix, per [references/azure-cost-checks.md](references/azure-cost-checks.md). None of it enters `score.categories`, `score.excluded`, or `checks[]`; every finding carries `scoring_scope: "non-scored"`, `points_recoverable: 0`, and `area: cost-optimization`. Its findings still live in the normal `findings[]` array (so history, lifecycle, and exemptions all apply unmodified). The one hard rule: `estimated_monthly_savings_usd` appears **only** when copied verbatim from Azure Advisor's own cost recommendation — never recomputed against a price table, never converted from an annual or non-USD figure. Everything else (unattached disks, unassociated public IPs, stopped-but-not-deallocated VMs, over-scaled VMSS, orphaned resources) is a presence fact with no dollar. The subscription's month-to-date `PreTaxCost` from the Cost Management Query REST API (api-version `2023-11-01`, rate-limited — **handle 429 with backoff**) is spend already incurred, reported as context and never summed into savings. `az costmanagement query` **does not exist**; the read path is the Cost Management Query REST API only. The full catalog, the 429-aware `readOnly` POST helper, Resource Graph enumeration, and the forbidden-command list are in [references/azure-cost-checks.md](references/azure-cost-checks.md).

## Remediation pointers

Every finding's `remediation` field points at the fix, so "Next safe actions" starts at row 1 with no preparation:

| Finding area | Pointer |
| --- | --- |
| No, catch-all, or dead action groups; alert-quality attachment/hygiene | `setup-azure#create-and-wire-an-action-group` |
| Alert-processing (suppression) rule muting a live scope (AZR-005) | `setup-azure#review-alert-processing-rules` |
| Missing metric alerts on critical resources | `setup-azure#add-metric-alerts` |
| Missing scheduled-query (log) alerts | `setup-azure#add-log-alerts` |
| Missing activity-log / Service Health alerts | `setup-azure#add-activity-log-alerts` |
| Subscription Activity Log not exported to Log Analytics (AZR-042) | `setup-azure#enable-diagnostic-settings` |
| Missing VM/VMSS platform alerts (guest metrics = plan) | `setup-azure#enable-vm-diagnostics` |
| AKS Container Insights or managed Prometheus off | `setup-azure#enable-aks-monitoring` |
| Managed Prometheus with no consuming rule groups (AZR-033) | `setup-azure#add-prometheus-rule-groups` |
| Missing diagnostic settings (AKS/App Gateway/LB); Log Analytics retention | `setup-azure#enable-diagnostic-settings` |
| Log Analytics workspace stopped ingesting (AZR-041) | `setup-azure#investigate-log-ingestion` |
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
| Routing scored green while a suppression rule swallows every page | AZR-005: an enabled `RemoveAllActionGroups` alert-processing rule scoped to a production RG mutes delivery — intersect its scope with critical resource groups, never trust AZR-001's receiver check alone |
| Configured workspace assumed to be ingesting | AZR-041: config presence (AZR-040) is not ingestion; a data-plane `Heartbeat`/table-recency read proves it, and a stale workspace invalidates the AZR-030/032/050 passes routing to it |
| Managed Prometheus "on" counted as alerted-on | AZR-033: `azureMonitorProfile.metrics.enabled==true` collects and bills for metrics; without a `prometheusRuleGroups` consumer nothing alerts — collected ≠ alerted-on |
| Verify-pending check scored as a confident pass | AZR-005/033/042 have confirmed empty read paths but unobserved populated emit conditions; AZR-041 remains live-verify-pending. Score only evidence validated on this run; an empty result proves no field semantics |
| Health probes counted as alerting | Probes eject backends silently; only Monitor alerts page; audit both, credit neither for the other |
| VM guest metrics promised without the agent | Credit memory/disk-free only after AMA + DCR evidence per VM; platform metrics need no agent, guest metrics do |
| Log alert credited whose KQL matches nothing | Validate with `az monitor log-analytics query` (confirmed data-plane read); inspect the count before crediting |
| AKS "off" misread as an error | `azureMonitorProfile` absent/null and the omsagent addon absent are the confirmed "off" signals, not failures |
| diagnosticSettings audited against an assumed api-version | It has no confirmed api-version; let the CLI pick it and confirm categories with `categories list` |
| Action-group receiver secrets leaked | Capture receiver display name and type only, per secret-redaction.md; never print webhook URLs or service keys |
| Toolkit brief webhook conflated with an action group | Two webhooks, two jobs; flag any overlap as a finding |
| `az costmanagement query` used for a cost figure | That CLI does not exist; the cost read path is the Cost Management Query REST API at 2023-11-01, handling 429 with backoff, never a guessed dollar |
