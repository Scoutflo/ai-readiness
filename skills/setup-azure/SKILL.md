---
name: setup-azure
description: Guided hardening of Azure Monitor from audit-azure findings; creates and repairs action groups, metric alerts, scheduled-query (log) alerts, activity-log alerts, VM/VMSS alerts, AKS Container Insights and managed Prometheus, and diagnostic settings to Log Analytics, announcing each change, waiting for confirmation, then verifying live. Monitoring-plane writes only. Use when the user asks to fix an AZR-NNN finding, wire Azure alert routing, add metric or log alerts, or enable AKS monitoring. Do not use for read-only assessment (use audit-azure), for in-cluster stacks (use setup-lgtm), or for VM agent installs, network/health-probe changes, or RBAC role assignments (planned here, executed only by an identity that holds Owner/User Access Administrator).
disable-model-invocation: true
---

# setup-azure

Fixes findings from an `audit-azure` run. Input is one or more finding IDs from the latest `./scoutflo-audits/azure/<date>/findings.json` (`azure/<label>/<date>/` when `azure` is a labeled list of subscriptions); you usually arrive here from a finding's `remediation` pointer, for example `setup-azure#add-metric-alerts`.

| Finding ID | Fix section |
| --- | --- |
| AZR-001, AZR-060 | [Create and wire an action group](#create-and-wire-an-action-group) |
| AZR-002 | [Add metric alerts](#add-metric-alerts) |
| AZR-003 | [Add log alerts](#add-log-alerts) |
| AZR-004 | [Add activity-log alerts](#add-activity-log-alerts) |
| AZR-005 | [Review alert processing rules](#review-alert-processing-rules) |
| AZR-010 | [Enable VM diagnostics](#enable-vm-diagnostics) |
| AZR-030, AZR-031 | [Enable AKS monitoring](#enable-aks-monitoring) |
| AZR-032, AZR-040, AZR-042, AZR-050 | [Enable diagnostic settings](#enable-diagnostic-settings) |
| AZR-033 | [Add Prometheus rule groups](#add-prometheus-rule-groups) |
| AZR-041 | [Investigate log ingestion](#investigate-log-ingestion) |
| AZR-007 | [Handle the empty-scope guardrail](#handle-the-empty-scope-guardrail) (visibility gap, not a confident fix) |
| AZROPT-* | [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes) (read-only guidance, no write) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**Write scope: the Monitoring plane only.** This skill creates and updates action groups, metric alerts, scheduled-query (log) alerts, activity-log alerts, Prometheus rule groups, and diagnostic settings (resource and subscription scope), disables or re-enables alert processing rules, sets Log Analytics workspace retention, and enables the AKS monitoring surfaces (Container Insights, managed Prometheus). Out of write scope, always: VM/VMSS agent installs (Azure Monitor Agent, the diagnostic extension), Data Collection Rules and their associations (beyond what AKS enablement provisions itself), rewrites of an alert processing rule's scope or schedule, any AKS cluster change beyond monitoring enablement, editing a live Application Gateway or Load Balancer health probe, and every network, NSG, DNS, and RBAC change. Those are controlled rollouts or traffic-impacting changes owned by the people who own those surfaces; this skill records a plan with a named owner instead ([Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes)). It also never mutates local Azure CLI state: no `az account set` inside a fix block, no default-subscription flip; every command carries an explicit `--subscription` (or a `SUB` resolved from config in the same block).

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the `az` command (or JSON payload) with real values filled in, including the **rollback** command, plus its risk class. Webhook URLs, service keys, and connection strings are the exception: announce an action's display name and type, never the secret value.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change (the CLI rejects a flag, an api-version differs on your `az` version, a role assignment is refused), stop and re-announce.
4. **Verify.** Re-read the modified object and assert the outcome with `jq -e` or a captured exit code. A write is unverified until a read proves it. Configuration is metadata; live validation is proof: a re-read proves the change is `configured`, and only an observed effect (a real notification reaching its receiver, fresh rows landing in the workspace) makes it `validated-live`.
5. **Record.** Append the change, its verification evidence, whether it is `configured` or `validated-live`, and pending items with named owners to the change record.

- ❌ `Created the action group and the re-read shows one enabled email receiver, so AZR-001 delivery is validated-live.`
- ✅ `Re-read shows one enabled email receiver: configured. It becomes validated-live when the on-call confirms a real alert's notification arrived.`

Order discipline, kept from hard experience: routing before alerts (the action group first, then the alerts that reference it), diagnostic settings before any log alert that queries the workspace they feed, AKS enablement before an alert on a metric the cluster does not ship yet. An alert created before its action group exists pages nobody and verifies dirty. Where you run parallel environments, fix the non-production subscription or resource group first and confirm the result before touching production.

## The change-risk classes

Every announcement in this skill names its class. The class decides the extra gate and, for the RBAC class, whether the change executes here at all.

| Class | In this skill | Confirmed read surface | Extra gate |
| --- | --- | --- | --- |
| Read-only | GET-before-write snapshots, verification reads, all cost/`AZROPT-*` guidance | the audit's read api-versions | none |
| Monitoring-plane write | action group create/update; metric alert; scheduled-query (log) alert; activity-log alert; alert processing rule disable/re-enable; Prometheus rule group; diagnostic settings (resource and subscription scope); Log Analytics retention | `actionGroups` **2023-01-01**, `metricAlerts` **2018-03-01**, `scheduledQueryRules` **2022-06-15**, `activityLogAlerts` **2020-10-01**, `actionRules` **2021-08-08**, `prometheusRuleGroups` **2023-03-01**, `workspaces` **2022-10-01**; diagnostic settings have no confirmed api-version (the CLI picks its own) | announce + confirm |
| Controlled rollout | AKS Container Insights / managed Prometheus enablement (a cluster mutation) | `az aks show` → `addonProfiles.omsagent.enabled`, `azureMonitorProfile.metrics.enabled` | announce + confirm; larger blast radius; **if it triggers a role assignment and the identity is Contributor, it becomes a plan with a named owner** |
| RBAC / role-granting | any `Microsoft.Authorization/roleAssignments/write` (grant the audit identity a role; wire a managed-identity role) | `roleAssignments` **2022-04-01** | **needs `Owner`/`User Access Administrator`**; the validation identity was **Contributor and could NOT create role assignments** (`AuthorizationFailed`), so a Contributor identity records this as a **plan with a named owner**, never executes it |
| Traffic-impacting | editing a live App Gateway/LB health probe; NSG/DNS/network changes; VM/VMSS agent (AMA / diagnostic extension) installs | n/a | out of write scope everywhere; plan only |

**The RBAC ceiling is a real, confirmed finding, not a hypothetical.** The Azure API validation run proved the validation identity could create resources (resource groups, AKS clusters, Log Analytics workspaces all succeeded) but **could not create role assignments**: `Microsoft.Authorization/roleAssignments/write` returned `AuthorizationFailed`. So every monitoring-plane write in this skill is Contributor-capable, but any step that grants a role needs `User Access Administrator` or `Owner`. When a fix requires a role assignment and the live identity lacks that role, do not retry, do not escalate, do not treat `AuthorizationFailed` as permission to self-grant: announce it as a **plan with a named owner** and stop.

- ❌ `Managed Prometheus enablement hit AuthorizationFailed on roleAssignments/write, so grant the cluster identity Monitoring Data Reader myself and continue.`
- ✅ `Enablement needs a role assignment the Contributor identity cannot make; recorded as a plan for the subscription Owner (needs User Access Administrator), AZR-031 stays open until they run it.`

## Doctor gate

Elevated tier: this skill mutates Azure Monitor and Log Analytics state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Azure | `azure.subscription_id`, optional `azure.tenant_id`, optional `azure.region` | none stored; auth is `az login` (`DefaultAzureCredential` → `AzureCliCredential` fallback, confirmed) | `Monitoring Contributor` (action groups, metric/log/activity alerts, diagnostic settings) plus `Log Analytics Contributor` for workspace retention; AKS enablement needs write on the AKS resource; any **role assignment** needs `Owner`/`User Access Administrator` (Contributor is insufficient, confirmed) | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a team running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall, but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done || true)
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
[ "$code" = "200" ] || { echo "STOP: expected 200 (401 = missing or malformed token, 404 = wrong subscription id)"; exit 1; }
```

Expected: the identity line, the resolved subscription, and `action-groups api: 200`; any other code stops the block. A `401` means the token is missing or malformed (both confirmed to return 401); a `404` means the subscription id is wrong (confirmed). Editor-tier write permission cannot be introspected cheaply, so the first write of the run is the scope test: an `AuthorizationFailed` on it means the identity lacks `Monitoring Contributor` (or the role the section names). Stop, report which role is missing, point at `/scoutflo:connect`; do not keep trying other writes to find one that works. `roleAssignments/write` is a separate, higher bar: see [the change-risk classes](#the-change-risk-classes).

## Live-safety gate

Resolve the target subscription from `toolkit.yaml` itself, not from a value typed into the block, then compare it against what `az` actually resolves live. The comparison value has to come from the config file or the gate can pass on whatever the operator happened to type or whatever `az account set` left active in another terminal:

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve the target through the shared enumerator, as audit-azure does: a single azure block, or the
# SCOUTFLO_TARGET-labeled item of a labeled list (no yq required). Never hand-typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CONFIG" azure kind); AZ_N=$(sh "$TT" "$CONFIG" azure count)
[ "${AZ_N:-0}" -ge 1 ] || { echo "no azure target configured in $CONFIG; run /scoutflo:connect"; exit 1; }
AZ_IDX=0
if [ "$AZ_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$AZ_N" -gt 1 ]; }; then
  # A labeled list: the target is the label SCOUTFLO_TARGET names. A write skill never picks one for you.
  AZ_IDX=""; _i=0
  while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CONFIG" azure label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$AZ_IDX" ] || { echo "STOP: set SCOUTFLO_TARGET to one azure label in $CONFIG: $(sh "$TT" "$CONFIG" azure labels | tr '\n' ' ')"; exit 1; }
fi
AZ_LABEL=$(sh "$TT" "$CONFIG" azure label "$AZ_IDX")
AZ_SUB_CFG=$(sh "$TT" "$CONFIG" azure get "$AZ_IDX" subscription_id)
[ -n "$AZ_SUB_CFG" ] || { echo "azure target '${AZ_LABEL:-?}' has no subscription_id in $CONFIG; run /scoutflo:connect"; exit 1; }
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
LIVE_SUB="$(printf '%s' "$ACCT" | jq -r '.id')"
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name')"
echo "config target (azure target '${AZ_LABEL}', subscription_id): ${AZ_SUB_CFG}"
echo "live subscription (az account show): ${LIVE_SUB}"
[ "$LIVE_SUB" = "$AZ_SUB_CFG" ] || { echo "STOP: az resolves subscription ${LIVE_SUB}, which does not match azure target '${AZ_LABEL}' (${AZ_SUB_CFG}) in toolkit.yaml; point your own shell at ${AZ_SUB_CFG} or fix the config, then re-run this gate (this skill never runs az account set)"; exit 1; }
echo "live-safety gate passed: az resolves the subscription toolkit.yaml names for azure target '${AZ_LABEL}'"
```

Expected: the final line prints and nothing stops the block. `AZ_SUB_CFG` is re-read from `toolkit.yaml` in this same block every time, never carried over from a prior block or from what an operator remembers running `az account set` on, so the gate cannot pass on the wrong target by construction. When `azure` is a labeled list of subscriptions (audit-azure supports this), set `SCOUTFLO_TARGET=<label>` to the target you mean to change: the gate stops when it is unset or matches no label, because this skill writes and never chooses between subscriptions for you. Every forward and rollback block takes `SUB` explicitly: set it to the subscription id this gate printed. A block refuses to run while `SUB` is empty or a placeholder and never falls back to the `az` default, so a default changed later in another terminal cannot redirect a write. If the identity is not the one your team intends for setup work, or the subscription does not resolve, stop and report the mismatch. Never proceed on "probably the right subscription". Every object in this skill is addressed by the full resource id captured from the audit run (`/subscriptions/<id>/resourceGroups/<rg>/providers/...`), never by display-name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
# The same target the live-safety gate resolved. audit-azure writes azure/<date>/ for a single block
# and azure/<label>/<date>/ for a labeled list.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CONFIG" azure kind); AZ_N=$(sh "$TT" "$CONFIG" azure count)
AZ_IDX=0
if [ "$AZ_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "${AZ_N:-0}" -gt 1 ]; }; then
  AZ_IDX=""; _i=0
  while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CONFIG" azure label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$AZ_IDX" ] || { echo "STOP: set SCOUTFLO_TARGET to one azure label in $CONFIG"; exit 1; }
fi
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/$(sh "$TT" "$CONFIG" azure label "$AZ_IDX")"; else AZ_SEG="azure"; fi
# Date-named run folders only: never this skill's own setup-<date>/ folder, a runs/ worklist, or a label folder.
LATEST_RUN="$(ls -d "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || { echo "no audit run found under ${AZ_SEG}/; run /scoutflo:audit-azure first"; exit 1; }
[ -f "${LATEST_RUN}findings.json" ] || { echo "${LATEST_RUN} has no findings.json; re-run /scoutflo:audit-azure"; exit 1; }
echo "findings from: ${LATEST_RUN}"
jq -r '.findings[] | select(.area != "cost-optimization") | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Reliability findings (`AZR-*`) only; `AZROPT-*` cost findings never enter this plan (see [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes)). Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown; deletions (an action group, an alert rule) and any RBAC / role-granting row are still re-confirmed individually at their announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-read the failed object's current state, report what happened, and re-announce the remainder only after the user decides. A half-applied alert (created but with no action group attached) is worse than no alert; verify or roll back the failed object before anything else runs.

**Backups are GET-before-write.** Before any update, capture the object's current state into `BACKUP_DIR` with a plain `az ... show` (or ARM GET), in a new timestamped file whose path you record: a block refuses to write over an existing backup, because a re-run would otherwise replace the prior state with the changed one. Backups may contain resource ids, action definitions, and connection detail; `./scoutflo-audits/` stays out of version control and out of every announcement. Rollback is re-applying the backup or deleting the created object; every section names its restore command.

`az` flag names and defaults shift across CLI versions, and the write subcommands below were **not** exercised in the confirmed validation run; only the reads and the AKS enablement result were. So for every `az` write in this skill, check the subcommand's `--help` on your version before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags (this is the change protocol's re-announce rule, not an exception to it). The api-versions cited for reads **are** confirmed (an `az ... show` verify uses whatever version your CLI build pins); the write CLI shapes are the documented path, to be confirmed live before execution.

## Create and wire an action group

For `AZR-001` and `AZR-060`. Monitoring-plane write; nothing redeploys. An action group is the object a metric/log/activity alert points at so a page reaches a human. Create it first, then every alert section attaches it. Name groups per environment (`<team>-<environment>-alerts`) so a page's origin is readable before its body. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of action groups; they are different webhooks with different jobs.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"                       # the resource group that owns the action group
AG_NAME="payments-production-alerts"        # <team>-<environment>-alerts
AG_SHORT="payprod"                          # <= 12 chars, shown in the SMS/email subject
AG_EMAIL="oncall@example.org"               # the address your team actually watches
# Create (announced first). For webhook/logic-app/SMS receivers the sensitive value rides an
# unechoed variable into --action, and the announcement shows the receiver name + type only.
# A same-name create overwrites an existing object and the rollback deletes it, so never create over one.
OUT="$(az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "An action group named ${AG_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' || { printf '%s\n' "$OUT" >&2; exit 1; }
az monitor action-group create --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" \
  --short-name "$AG_SHORT" --action email primary "$AG_EMAIL"
# Verify by re-read (actionGroups is confirmed at api-version 2023-01-01):
az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.enabled == true and (.emailReceivers | length) >= 1'
```

Expected: the created group and a final `jq -e` exit 0. Every alert section below declares `AG_ID`, this group's full resource id; add `--query id -o tsv` to the verify `show` to print it. The re-read proves the group is `configured`; delivery is `validated-live` only after you observe a real notification reach each receiver class. **Rollback**, in its own fresh shell. Rollbacks never fall back to the CLI's default subscription: they name the one the live-safety gate verified.

```bash
set -eu
SUB="<subscription-id>"         # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"           # the resource group that owns the action group
AG_NAME="<action-group-name>"   # the action group this setup created
for v in "$SUB" "$RG" "$AG_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
az monitor action-group delete --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB"
OUT="$(az monitor action-group show --name "$AG_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the group's resource id, then `DELETED`. Any other error on the final read (403, throttling) is printed and fails the block instead of passing as "gone".

For `AZR-060` (alert quality), the fix is mostly attachment and hygiene, not new objects: attach this group to an alert that has none (for a metric alert, `--add-action <AG_ID>` on `az monitor metrics alert update`; check `--help` for the flag each alert type uses), correct a mis-tiered `--severity` (0 critical … 4 verbose), and retune or remove a permanently-firing rule in its own alert section with the rule body quoted and confirmed individually. Replacing a dead receiver means creating the good one, re-pointing every referencing alert, verifying, then deleting the dead one, each step confirmed individually.

## Add metric alerts

For `AZR-002`. Metric alerts on platform metrics of a critical resource (App Service, SQL, Storage, Cosmos, VM: anything with an ARM resource id). Gate first, create second: the gate block proves the target resource exists and emits the metric you are about to alert on, so the alert is not born watching a metric the resource never ships.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
TARGET_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.Web/sites/checkout"  # full resource id from the audit capture
METRIC_NAME="Http5xx"   # the metric the alert will watch
az monitor metrics list-definitions --resource "$TARGET_ID" -o json \
  | jq -e --arg m "$METRIC_NAME" 'any(.[]; .name.value == $m)'
```

Expected: `true`. `false` or an error means the resource id is wrong or the resource does not emit that metric: fix the target or the metric before announcing the create. Then announce the full command and run:

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"
TARGET_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.Web/sites/checkout"  # full resource id from the audit capture
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="checkout-5xx-warning"
METRIC_NAME="Http5xx"     # the metric the gate block proved this resource emits
ALERT_THRESHOLD="10"      # example, tune to your environment
WINDOW_SIZE="5m"          # example, tune to your environment
EVAL_FREQUENCY="1m"       # example, tune to your environment
ALERT_SEVERITY="2"        # example, tune to your environment (0 critical to 4 verbose)
# metricAlerts reads are confirmed at api-version 2018-03-01.
# A same-name create overwrites an existing object and the rollback deletes it, so never create over one.
OUT="$(az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "A metric alert named ${ALERT_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' || { printf '%s\n' "$OUT" >&2; exit 1; }
az monitor metrics alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$TARGET_ID" --condition "total ${METRIC_NAME} > ${ALERT_THRESHOLD}" \
  --window-size "$WINDOW_SIZE" --evaluation-frequency "$EVAL_FREQUENCY" --severity "$ALERT_SEVERITY" \
  --action "$AG_ID" --description "checkout HTTP 5xx above warning tier | capture request rate, dependency health, recent deploy, app logs"
# Verify by re-read: enabled, and the announced action group is the one attached.
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --arg ag "$AG_ID" '.enabled == true and any(.actions[]?; (.actionGroupId | ascii_downcase) == ($ag | ascii_downcase))'
```

Expected: exit 0. `ALERT_THRESHOLD`, `WINDOW_SIZE`, `EVAL_FREQUENCY`, and `ALERT_SEVERITY` are example values: tune them to the resource's baseline, because a threshold with no baseline behind it becomes the noise `AZR-060` flags. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"      # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"        # the resource group that owns the alert
ALERT_NAME="<alert-name>"    # the metric alert this setup created
for v in "$SUB" "$RG" "$ALERT_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
az monitor metrics alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"
OUT="$(az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the alert's resource id, then `DELETED`. This gate-create-verify shape serves every critical resource type; only `TARGET_ID`, `METRIC_NAME`, the thresholds, and `--description` change.

## Add log alerts

For `AZR-003`. Scheduled-query (log) alerts run a KQL query against a Log Analytics workspace on a schedule and fire on the result count: the coverage a metric alert cannot give (error-log rate, missing-heartbeat, a business-signal query). The `count` condition counts the rows the query returns, so the query returns the matching rows themselves; a query that ends in `summarize count()` always returns exactly one row and never crosses a threshold above 1. Strict order: the workspace must already be receiving the logs the query reads (see [Enable diagnostic settings](#enable-diagnostic-settings) if it is not), and the gate block below proves that and the query before the create block runs.

- ❌ `Alert query ends in summarize count() and the condition is count > 5: the query always returns one row, so the alert can never fire.`
- ✅ `Alert query returns the matching 5xx rows and the condition counts them, so more than five 5xx rows in the window fires the alert.`

```bash
set -eu
WORKSPACE_GUID="your-workspace-customer-id"   # the workspace customerId; from: az monitor log-analytics workspace show --query customerId -o tsv
SOURCE_TABLE="AppServiceHTTPLogs"             # the table the alert query reads
KQL="AppServiceHTTPLogs | where ScStatus >= 500"   # returns the matching rows; no summarize
GATE_LOOKBACK="P1D"   # example: a window that holds normal traffic for this source; tune to your environment
# Confirmed data-plane read; needs the 'log-analytics' az extension (audience api.loganalytics.io). Values come back as strings.
# 1. The source table receives rows. An alert over a table nothing writes to is decorative.
az monitor log-analytics query --workspace "$WORKSPACE_GUID" --timespan "$GATE_LOOKBACK" \
  --analytics-query "${SOURCE_TABLE} | summarize count()" -o json \
  | jq -e '(.[0].count_ | tonumber) > 0'
# 2. The alert query parses and runs; print how many rows it matched in the lookback.
az monitor log-analytics query --workspace "$WORKSPACE_GUID" --timespan "$GATE_LOOKBACK" \
  --analytics-query "${KQL} | summarize count()" -o json \
  | jq -e -r '.[0].count_ | tonumber | "alert query matched \(.) rows in the lookback"'
```

Expected: `true`, then the match count. The block stops when the source table has no rows in the lookback (the logs are not arriving) or when the query does not parse. A match count of 0 over a window in which you know the condition happened means the query is wrong: fix it before you announce the create. Then create the rule and verify it:

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"
WORKSPACE_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="checkout-error-log-rate"
KQL="AppServiceHTTPLogs | where ScStatus >= 500"   # the query the gate block proved; returns rows, no summarize
ERROR_ROWS_THRESHOLD="5"   # example, tune to your environment
WINDOW_SIZE="5m"           # example, tune to your environment
EVAL_FREQUENCY="5m"        # example, tune to your environment
ALERT_SEVERITY="2"         # example, tune to your environment (0 critical to 4 verbose)
# The condition counts the rows KQL returns in each window.
# A same-name create overwrites an existing object and the rollback deletes it, so never create over one.
OUT="$(az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "A scheduled-query rule named ${ALERT_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' || { printf '%s\n' "$OUT" >&2; exit 1; }
az monitor scheduled-query create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$WORKSPACE_ID" --condition "count 'errs' > ${ERROR_ROWS_THRESHOLD}" \
  --condition-query errs="$KQL" \
  --window-size "$WINDOW_SIZE" --evaluation-frequency "$EVAL_FREQUENCY" --severity "$ALERT_SEVERITY" \
  --action-groups "$AG_ID" --description "checkout 5xx log rows over ${WINDOW_SIZE} | capture query, request id, deploy id, error class"
# scheduledQueryRules reads are confirmed at api-version 2022-06-15. Verify the announced action group is attached.
az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --arg ag "$AG_ID" '.enabled == true and any(.actions.actionGroups[]?; ascii_downcase == ($ag | ascii_downcase))'
```

Expected: exit 0. `ERROR_ROWS_THRESHOLD`, `WINDOW_SIZE`, `EVAL_FREQUENCY`, and `ALERT_SEVERITY` are example values: tune them to the service's normal error rate. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"      # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"        # the resource group that owns the rule
ALERT_NAME="<alert-name>"    # the scheduled-query rule this setup created
for v in "$SUB" "$RG" "$ALERT_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
# --yes: this delete otherwise stops at a confirmation prompt.
az monitor scheduled-query delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" --yes
OUT="$(az monitor scheduled-query show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the rule's resource id, then `DELETED`. The `az monitor scheduled-query` flag shape varies across CLI versions more than most: run `az monitor scheduled-query create --help` and re-announce if it differs.

## Add activity-log alerts

For `AZR-004`. Activity-log alerts fire on control-plane events for the subscription itself (Azure Service Health advisories, Resource Health transitions, and policy/administrative events), not on resource metrics. They are subscription-scoped, so the scope is the subscription (or a resource group), and they attach an action group exactly like a metric alert.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="service-health-incidents"
# Service Health advisories for the whole subscription -> the on-call action group.
# A same-name create overwrites an existing object and the rollback deletes it, so never create over one.
OUT="$(az monitor activity-log alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "An activity-log alert named ${ALERT_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' || { printf '%s\n' "$OUT" >&2; exit 1; }
az monitor activity-log alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scope "/subscriptions/${SUB}" \
  --condition category=ServiceHealth \
  --action-group "$AG_ID" --description "Azure Service Health advisories for this subscription"
# activityLogAlerts reads are confirmed at api-version 2020-10-01. Verify the announced action group is attached.
az monitor activity-log alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --arg ag "$AG_ID" '.enabled == true and any((.actions.actionGroups // .actionGroups // [])[]; (.actionGroupId | ascii_downcase) == ($ag | ascii_downcase))'
```

Expected: exit 0. Repeat with `category=ResourceHealth` for per-resource health transitions and `category=Policy` for policy events, each a separate rule so a reader can tell which control-plane axis fired. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"      # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"        # the resource group that owns the alert
ALERT_NAME="<alert-name>"    # the activity-log alert this setup created
for v in "$SUB" "$RG" "$ALERT_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor activity-log alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
az monitor activity-log alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"
OUT="$(az monitor activity-log alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the alert's resource id, then `DELETED`.

## Enable VM diagnostics

For `AZR-010`. Two distinct halves, and only one executes here. **Platform metric alerts** (CPU, disk, network) on a VM or VMSS come straight from the Azure platform and need no agent: a monitoring-plane write, the same `az monitor metrics alert create` shape as [Add metric alerts](#add-metric-alerts) with `--scopes` set to the VM/VMSS resource id. `CPU_THRESHOLD` and the window, frequency, and severity below are example values: tune them to the VM's normal load.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"
VM_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.Compute/virtualMachines/api-01"  # confirmed read type: virtualMachines api-version 2024-07-01
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
ALERT_NAME="api-01-cpu-warning"
CPU_THRESHOLD="80"     # example, tune to your environment
WINDOW_SIZE="5m"       # example, tune to your environment
EVAL_FREQUENCY="1m"    # example, tune to your environment
ALERT_SEVERITY="2"     # example, tune to your environment (0 critical to 4 verbose)
# A same-name create overwrites an existing object and the rollback deletes it, so never create over one.
OUT="$(az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "A metric alert named ${ALERT_NAME} already exists: pick another name, or announce an edit of it" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' || { printf '%s\n' "$OUT" >&2; exit 1; }
az monitor metrics alert create --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" \
  --scopes "$VM_ID" --condition "avg Percentage CPU > ${CPU_THRESHOLD}" \
  --window-size "$WINDOW_SIZE" --evaluation-frequency "$EVAL_FREQUENCY" --severity "$ALERT_SEVERITY" \
  --action "$AG_ID" --description "api-01 CPU above warning tier | capture load, process state, recent deploy, dependency health"
# Verify by re-read: enabled, and the announced action group is the one attached.
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --arg ag "$AG_ID" '.enabled == true and any(.actions[]?; (.actionGroupId | ascii_downcase) == ($ag | ascii_downcase))'
```

Expected: exit 0. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"      # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"        # the resource group that owns the alert
ALERT_NAME="<alert-name>"    # the VM metric alert this setup created
for v in "$SUB" "$RG" "$ALERT_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
az monitor metrics alert delete --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB"
OUT="$(az monitor metrics alert show --name "$ALERT_NAME" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the alert's resource id, then `DELETED`. The **guest-level half** (memory, disk-free, per-process, and log collection) needs the Azure Monitor Agent (or the legacy diagnostic extension) plus a Data Collection Rule on each VM. Installing an agent and wiring a DCR is a per-VM controlled rollout on a surface this skill does not own (it can also require a role assignment for the VM's managed identity, which a Contributor identity cannot make): record it in [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes) with the VM list from the finding and a named owner, and leave the guest-metric part of `AZR-010` open until the agent metrics exist.

- ❌ `Installed the Azure Monitor Agent on all six VMs and wired the DCRs under the same batch as the CPU alerts.`
- ✅ `Created the platform CPU/disk metric alerts this run; filed the AMA + DCR install for guest metrics as a plan with the platform owner; the guest-metric half of AZR-010 stays open.`

## Enable AKS monitoring

For `AZR-030` (Container Insights) and `AZR-031` (managed Prometheus). These are **cluster mutations** (controlled rollout), not plain monitoring-plane writes, so their blast radius is larger and the announcement says so. Both verify against the **confirmed** property paths: `addonProfiles.omsagent.enabled` for Container Insights and `azureMonitorProfile.metrics.enabled` for managed Prometheus (`azureMonitorProfile` is absent or null when off; that absence is the "off" signal, not an error).

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="app-rg"
CLUSTER="prod-aks"
LA_WS_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"  # workspaces confirmed at 2022-10-01
# AZR-030 Container Insights -> Log Analytics. Cluster write; Contributor on the AKS resource can do it.
az aks enable-addons --addons monitoring --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" \
  --workspace-resource-id "$LA_WS_ID"
az aks show --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.addonProfiles.omsagent.enabled == true'
```

Expected: exit 0 (`addonProfiles.omsagent.enabled == true`, confirmed path). **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"     # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"       # the cluster's resource group
CLUSTER="<cluster-name>"    # the cluster this setup changed
for v in "$SUB" "$RG" "$CLUSTER"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az aks disable-addons --addons monitoring --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB"
az aks show --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '(.addonProfiles.omsagent.enabled // false) == false'
```

Expected: the subscription id, then `true`.

`AZR-031` managed Prometheus, in its own block (optionally add `--azure-monitor-workspace-resource-id <amw-id>` to the update):

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
RG="app-rg"
CLUSTER="prod-aks"
az aks update --enable-azure-monitor-metrics --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB"
az aks show --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.azureMonitorProfile.metrics.enabled == true'
```

Expected: exit 0. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"     # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"       # the cluster's resource group
CLUSTER="<cluster-name>"    # the cluster this setup changed
for v in "$SUB" "$RG" "$CLUSTER"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az aks update --disable-azure-monitor-metrics --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" --yes
# A null azureMonitorProfile is the "off" signal, so read a missing value as false.
az aks show --name "$CLUSTER" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '(.azureMonitorProfile.metrics.enabled // false) == false'
```

Expected: the subscription id, then `true`. **RBAC caveat, load-bearing:** enabling managed Prometheus provisions a Data Collection Rule and can grant the cluster's managed identity a Monitoring role on the Azure Monitor Workspace. That grant is a `Microsoft.Authorization/roleAssignments/write`, which the confirmed validation identity (**Contributor**) could not perform (`AuthorizationFailed`). If your identity is Contributor and the enablement fails on the role assignment, stop and record `AZR-031` as a **plan with a named owner** for the subscription Owner / a `User Access Administrator`; do not self-grant the role.

- ❌ `--enable-azure-monitor-metrics failed with AuthorizationFailed on the DCR role; created the role assignment myself to finish the fix.`
- ✅ `Container Insights enabled and verified (omsagent.enabled true). Managed Prometheus needs a role assignment the Contributor identity cannot make; filed as a plan for the Owner, AZR-031 stays open.`

## Enable diagnostic settings

For `AZR-032` (AKS control-plane logs), `AZR-040` (Log Analytics workspace coverage and retention), `AZR-042` (subscription Activity Log export), and `AZR-050` (App Gateway / Load Balancer diagnostics). A diagnostic setting routes a resource's platform logs and metrics to a Log Analytics workspace so they can be queried and alerted on. It is a monitoring-plane write on the resource; it does not change the resource's behavior.

Cost, announced with the change: for an AKS cluster the block sends the control-plane categories with `kube-audit-admin`, not `kube-audit`. `kube-audit` records every API request, reads included, and is usually the largest Log Analytics ingestion cost on a cluster; `kube-audit-admin` is the same audit log without the get and list events. Add `kube-audit` (or `categoryGroup` `allLogs`, which includes it) only as a deliberate, announced cost decision. For an App Gateway or Load Balancer id, set `DS_LOGS` to the categories `categories list` shows for that resource.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
TARGET_ID="/subscriptions/${SUB}/resourceGroups/app-rg/providers/Microsoft.ContainerService/managedClusters/prod-aks"  # AKS control plane (AZR-032); or an appGateways / loadBalancers id (AZR-050)
LA_WS_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"
DS_NAME="to-central-logs"
# AKS control-plane categories, kube-audit-admin instead of the far larger kube-audit (see the cost note above).
DS_LOGS='[{"category":"kube-apiserver","enabled":true},{"category":"kube-audit-admin","enabled":true},{"category":"kube-controller-manager","enabled":true},{"category":"kube-scheduler","enabled":true}]'
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# GET-before-write: capture any existing settings on this resource, never over an earlier backup. A failed read stops here.
DIAG_BACKUP="${BACKUP_DIR}/diag-$(basename "$TARGET_ID")-$(date -u +%Y%m%dT%H%M%SZ).json"
[ ! -e "$DIAG_BACKUP" ] || { echo "${DIAG_BACKUP} already exists; refusing to overwrite a backup" >&2; exit 1; }
az monitor diagnostic-settings list --resource "$TARGET_ID" -o json > "$DIAG_BACKUP"
echo "backup: ${DIAG_BACKUP}"
# The rollback deletes DS_NAME, so never create over a setting that already exists under that name.
jq -e --arg n "$DS_NAME" 'all((.value? // .)[]?; .name != $n)' "$DIAG_BACKUP" > /dev/null \
  || { echo "A diagnostic setting named ${DS_NAME} already exists here: pick another name (this block never edits an existing setting)" >&2; exit 1; }
# NOTE: diagnosticSettings has NO confirmed ARM api-version in the validation run (no resource was
# attached to during it). The 'az' CLI selects its own version; confirm the categories your resource
# supports first with: az monitor diagnostic-settings categories list --resource "$TARGET_ID"
az monitor diagnostic-settings create --name "$DS_NAME" --resource "$TARGET_ID" --workspace "$LA_WS_ID" \
  --logs "$DS_LOGS" \
  --metrics '[{"category":"AllMetrics","enabled":true}]'
# Verify by re-read: a setting exists pointing at this workspace (resource ids compare case-insensitively).
az monitor diagnostic-settings show --name "$DS_NAME" --resource "$TARGET_ID" -o json \
  | jq -e --arg ws "$LA_WS_ID" '(.workspaceId | ascii_downcase) == ($ws | ascii_downcase)'
```

Expected: the backup path, then exit 0. **Rollback** removes the setting this setup created (the create block refuses a name that already existed), in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"            # azure.subscription_id: the subscription the live-safety gate printed
TARGET_ID="<target-resource-id>"   # the resource whose setting this setup created
DS_NAME="<setting-name>"           # the diagnostic setting this setup created
for v in "$SUB" "$TARGET_ID" "$DS_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
case "$TARGET_ID" in "/subscriptions/${SUB}/"*) ;; *) echo "TARGET_ID is not in subscription ${SUB}" >&2; exit 1 ;; esac
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor diagnostic-settings show --name "$DS_NAME" --resource "$TARGET_ID" --query id -o tsv   # what will be deleted
az monitor diagnostic-settings delete --name "$DS_NAME" --resource "$TARGET_ID"
az monitor diagnostic-settings list --resource "$TARGET_ID" -o json \
  | jq -e --arg n "$DS_NAME" 'all((.value? // .)[]?; .name != $n)'
```

Expected: the subscription id, the setting's id, then `true`.

`AZR-042` (the subscription Activity Log is not exported) needs a subscription-scope diagnostic setting, a different object from the resource-scope one above. The block exports the `Administrative`, `Security`, and `Policy` categories audit-azure checks to the workspace; add `ServiceHealth`, `ResourceHealth`, `Alert`, `Recommendation`, or `Autoscale` to `SUB_DS_LOGS` if you want those retained too. Like every write here, check `az monitor diagnostic-settings subscription create --help` on your version before announcing.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
LA_WS_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.OperationalInsights/workspaces/central-logs"
SUB_DS_NAME="activity-log-to-central-logs"
SUB_DS_LOGS='[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"Policy","enabled":true}]'
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# GET-before-write: capture the subscription's existing settings, never over an earlier backup. A failed read stops here.
SUB_DS_BACKUP="${BACKUP_DIR}/subscription-diag-$(date -u +%Y%m%dT%H%M%SZ).json"
[ ! -e "$SUB_DS_BACKUP" ] || { echo "${SUB_DS_BACKUP} already exists; refusing to overwrite a backup" >&2; exit 1; }
az monitor diagnostic-settings subscription list --subscription "$SUB" -o json > "$SUB_DS_BACKUP"
echo "backup: ${SUB_DS_BACKUP}"
# The rollback deletes SUB_DS_NAME, so never create over a setting that already exists under that name.
jq -e --arg n "$SUB_DS_NAME" 'all((.value? // .)[]?; .name != $n)' "$SUB_DS_BACKUP" > /dev/null \
  || { echo "A subscription diagnostic setting named ${SUB_DS_NAME} already exists: pick another name" >&2; exit 1; }
az monitor diagnostic-settings subscription create --name "$SUB_DS_NAME" --subscription "$SUB" \
  --workspace "$LA_WS_ID" --logs "$SUB_DS_LOGS"
# Verify by re-read: this workspace, with the three categories audit-azure checks enabled.
az monitor diagnostic-settings subscription show --name "$SUB_DS_NAME" --subscription "$SUB" -o json \
  | jq -e --arg ws "$LA_WS_ID" '(.workspaceId | ascii_downcase) == ($ws | ascii_downcase)
      and ((["Administrative", "Policy", "Security"] - [.logs[]? | select(.enabled == true) | .category]) == [])'
```

Expected: the backup path, then `true`. **Rollback** removes the setting this setup created, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"         # azure.subscription_id: the subscription the live-safety gate printed
SUB_DS_NAME="<setting-name>"    # the subscription diagnostic setting this setup created
for v in "$SUB" "$SUB_DS_NAME"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor diagnostic-settings subscription show --name "$SUB_DS_NAME" --subscription "$SUB" --query id -o tsv   # what will be deleted
# --yes: this delete otherwise stops at a confirmation prompt.
az monitor diagnostic-settings subscription delete --name "$SUB_DS_NAME" --subscription "$SUB" --yes
az monitor diagnostic-settings subscription list --subscription "$SUB" -o json \
  | jq -e --arg n "$SUB_DS_NAME" 'all((.value? // .)[]?; .name != $n)'
```

Expected: the subscription id, the setting's id, then `true`.

`AZR-040` retention (workspaces read is confirmed at `2022-10-01`). The GET-before-write saves the workspace's current state to a new timestamped backup file and prints its path for the change record; the restore block below reads the prior `retentionInDays` from that file. `RETENTION_DAYS` is an example value: tune it to the longest investigation window you need and to your cost posture.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
LA_RG="observability-rg"   # the workspace's resource group
LA_WS="central-logs"       # the workspace name
RETENTION_DAYS="90"        # example, tune to your compliance and cost posture
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
WS_BACKUP="${BACKUP_DIR}/workspace-${LA_WS}-$(date -u +%Y%m%dT%H%M%SZ).json"
[ ! -e "$WS_BACKUP" ] || { echo "${WS_BACKUP} already exists; refusing to overwrite a backup" >&2; exit 1; }
az monitor log-analytics workspace show --resource-group "$LA_RG" --workspace-name "$LA_WS" --subscription "$SUB" -o json > "$WS_BACKUP"
echo "backup: ${WS_BACKUP}"   # record this path: the restore block reads it
jq -r '"prior retentionInDays: \(.retentionInDays)"' "$WS_BACKUP"
az monitor log-analytics workspace update --resource-group "$LA_RG" --workspace-name "$LA_WS" --subscription "$SUB" --retention-time "$RETENTION_DAYS"
az monitor log-analytics workspace show --resource-group "$LA_RG" --workspace-name "$LA_WS" --subscription "$SUB" -o json \
  | jq -e --argjson d "$RETENTION_DAYS" '.retentionInDays == $d'
```

Expected: the subscription id, the backup path, the prior value, then `true`. **Restore** puts the backed-up retention back, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"     # azure.subscription_id: the subscription the live-safety gate printed
LA_RG="<resource-group>"    # the workspace's resource group
LA_WS="<workspace-name>"    # the workspace this setup changed
WS_BACKUP="<backup-file>"   # the backup path the retention block printed, from the change record
for v in "$SUB" "$LA_RG" "$LA_WS" "$WS_BACKUP"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -f "$WS_BACKUP" ] || { echo "no backup at ${WS_BACKUP}" >&2; exit 1; }
# The backup must be this workspace in this subscription, and must hold a real prior value.
jq -e --arg ws "$LA_WS" --arg sub "/subscriptions/${SUB}/" '.name == $ws and (.id | ascii_downcase | startswith($sub | ascii_downcase))' "$WS_BACKUP" > /dev/null \
  || { echo "${WS_BACKUP} is not a backup of workspace ${LA_WS} in subscription ${SUB}" >&2; exit 1; }
PRIOR="$(jq -r '.retentionInDays // empty' "$WS_BACKUP")"
case "$PRIOR" in ''|*[!0-9]*) echo "no prior retentionInDays in ${WS_BACKUP}; refusing to guess one" >&2; exit 1 ;; esac
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor log-analytics workspace update --resource-group "$LA_RG" --workspace-name "$LA_WS" --subscription "$SUB" --retention-time "$PRIOR"
az monitor log-analytics workspace show --resource-group "$LA_RG" --workspace-name "$LA_WS" --subscription "$SUB" -o json \
  | jq -e --argjson d "$PRIOR" '.retentionInDays == $d'
```

Expected: the subscription id, then `true`. Restoring a shorter retention lets data older than the restored value age out, so announce and confirm the restore like any other change.

`AZR-050`: only the **diagnostic-settings** half of App Gateway / Load Balancer coverage executes here (appGateways and loadBalancers are confirmed reads at `2024-05-01`). Editing a live health **probe** (interval, threshold, path) can eject healthy backends from rotation; that is traffic-impacting and out of write scope, recorded as a plan instead.

## Handle the empty-scope guardrail

For `AZR-007`. This is **not** a change to execute: it is the audit telling you it saw `0 action groups AND 0 metric alerts despite a 200`, which is a visibility gap (the identity may lack read scope on the alerting resources, or the objects live in a resource group it cannot see), **not** a confident "you have no alerting". Do not "fix" it by creating a first action group and declaring victory; that would paper over a permissions or scoping problem with a real object in the wrong place.

The correct response is diagnosis, then a scoped re-audit, with no write:

1. Confirm the read scope with the block below, and check the audit identity actually holds `Reader` or `Monitoring Reader` at the subscription (or at the resource groups that hold the alerting objects). `az role assignment list` is a read; it is not a role **grant**.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
AUDIT_IDENTITY="audit-reader@example.org"   # the identity audit-azure printed on its identity line (sign-in name, app id, or object id)
# Read-only. --all lists resource-group assignments too, not just the subscription scope.
az role assignment list --assignee "$AUDIT_IDENTITY" --all --subscription "$SUB" -o table
```

Expected: one row per assignment with its role and scope. A role inherited through a group does not show here; add `--include-groups` for a user identity.

2. If scope is genuinely missing, that is a `Reader` or `Monitoring Reader` grant: an RBAC write needing `Owner` or `User Access Administrator`, recorded as a **plan with a named owner**, never self-granted here.
3. Re-run `/scoutflo:audit-azure` with the corrected scope; only if it still reports zero after full read visibility do you treat "no alerting exists" as true and start at [Create and wire an action group](#create-and-wire-an-action-group).

- ❌ `AZR-007 fired, so created an action group and a CPU alert to make the count non-zero and closed it.`
- ✅ `AZR-007 is a visibility gap: confirmed the identity lacked Monitoring Reader on payments-rg; filed the Reader grant as a plan for the Owner and will re-audit with scope before deciding whether any alerting is actually missing.`

## Plan cost and out-of-scope changes

For `AZROPT-*` and every controlled-rollout / traffic-impacting / RBAC item deferred by the sections above (VM agent installs, Data Collection Rule or agent repairs, alert processing rule rewrites, AKS managed-identity role grants, App Gateway/LB health-probe edits, `Reader`/`Monitoring Reader` grants, network changes). **No command in this section executes**; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, maintenance window if any, and a named owner.

`AZROPT-*` cost findings are **read-only guidance** here, exactly as in the dedicated audit-cost skill: resizing, deallocating, or deleting live Azure infrastructure to save money is a materially different risk profile than fixing missing alerting, and this skill's change protocol and backups are built for "restore observability", not "remove infrastructure". To act on an `AZROPT-*` finding, open it in the latest `audit-azure` report, review the recommendation where Azure presents it (Azure Advisor, the Cost Management view, or the presence fact), and act manually under your own change control. The read-only surface and the never-invent-a-dollar rule are in [audit-azure's azure-cost-checks.md](../audit-azure/references/azure-cost-checks.md); never run `az costmanagement query` (that CLI command does not exist; the cost read path is the Cost Management Query REST API at `2023-11-01`).

Recording the plan here keeps the finding traceable without smuggling a cluster change, an agent install, or a role grant through a "monitoring tweak" approval.

## Review alert processing rules

For `AZR-005`. An alert processing rule (formerly "action rule") with a suppression on a live production scope silently stops alerts from that scope from ever notifying: the alerts still fire and resolve in the portal, but no action group runs. This is the highest-severity Azure alerting defect because it looks healthy everywhere except delivery. The fix is a scoped review, never a blanket delete:

- Announce the exact rule (`az monitor alert-processing-rule show`), its `scopes`, `conditions`, `schedule`, and `enabled` state, and which live resources it currently mutes.
- Confirm intent. A suppression bounded to a real maintenance window (its `schedule` has an `effectiveUntil` end) is legitimate and is not the finding; an open-ended or perpetually renewed suppression on a production scope is.
- Disable the open-ended rule with the block below, announced as one change with its backup. Narrowing the rule's scope or rewriting it with a bounded schedule replaces the rule's body: record that as a plan with a named owner for the team that owns the maintenance window.

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"         # the rule's resource group, from the AZR-005 evidence
APR_NAME="maint-suppress"     # the alert processing rule AZR-005 names
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
# GET-before-write: the rule's full current state, never over an earlier backup. A failed read stops here.
APR_BACKUP="${BACKUP_DIR}/alert-processing-rule-${APR_NAME}-$(date -u +%Y%m%dT%H%M%SZ).json"
[ ! -e "$APR_BACKUP" ] || { echo "${APR_BACKUP} already exists; refusing to overwrite a backup" >&2; exit 1; }
az monitor alert-processing-rule show --name "$APR_NAME" --resource-group "$RG" --subscription "$SUB" -o json > "$APR_BACKUP"
echo "backup: ${APR_BACKUP}"
# Only an enabled rule is the finding: disabling one that is already off would make the undo switch it on.
jq -e '.properties.enabled == true' "$APR_BACKUP" > /dev/null || { echo "${APR_NAME} is already disabled: nothing to change" >&2; exit 1; }
az monitor alert-processing-rule update --name "$APR_NAME" --resource-group "$RG" --subscription "$SUB" --enabled false
# Verify by re-read: the rule is off.
az monitor alert-processing-rule show --name "$APR_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e '.properties.enabled == false'
```

Expected: the backup path, then `true`. The re-read proves the rule is off (`configured`); delivery on that scope is `validated-live` only once you observe the next real alert there reach its action group. `az monitor alert-processing-rule` comes from the `alertsmanagement` az extension; check `update --help` on your version before announcing. **Rollback** restores the rule's backed-up enabled state, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"     # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"       # the rule's resource group
APR_NAME="<rule-name>"      # the alert processing rule this setup disabled
APR_BACKUP="<backup-path>"  # the "backup:" path the disable block printed
for v in "$SUB" "$RG" "$APR_NAME" "$APR_BACKUP"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$APR_BACKUP" ] || { echo "No backup at ${APR_BACKUP}" >&2; exit 1; }
PRIOR="$(jq -er '.properties.enabled' "$APR_BACKUP")"   # restore exactly what the backup holds
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az monitor alert-processing-rule update --name "$APR_NAME" --resource-group "$RG" --subscription "$SUB" --enabled "$PRIOR"
az monitor alert-processing-rule show --name "$APR_NAME" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --argjson p "$PRIOR" '.properties.enabled == $p'
```

Expected: the subscription id, then `true`. Re-enabling brings the suppression back, so announce it as restoring the muting.

## Investigate log ingestion

For `AZR-041`. A Log Analytics workspace that has stopped ingesting means every log-based alert and query over it is now blind: the query returns the last data and looks alive. The fix is upstream of the workspace, not the workspace itself:

- Announce which tables stopped and the last-seen timestamp per table, from the AZR-041 evidence.
- Trace the source route: the resource's diagnostic setting still points at this workspace, the Data Collection Rule association and the agent (AMA) are running, and the resource still exists.
- A diagnostic setting that points elsewhere is fixed here: add one that routes to this workspace with [Enable diagnostic settings](#enable-diagnostic-settings) (that block never edits an existing setting). A broken Data Collection Rule association or a stopped agent is out of write scope: record it as a plan with a named owner in [Plan cost and out-of-scope changes](#plan-cost-and-out-of-scope-changes).
- Verify with the block below once the fix lands. It fails until rows newer than `FRESH_MINUTES` arrive.

```bash
set -eu
WORKSPACE_GUID="your-workspace-customer-id"   # the workspace customerId; from: az monitor log-analytics workspace show --query customerId -o tsv
FRESH_TABLE="Heartbeat"   # the table AZR-041 named as stale
FRESH_MINUTES="30"        # example, tune to the table's normal ingestion delay
# Read-only data-plane query ('log-analytics' az extension). Values come back as strings.
az monitor log-analytics query --workspace "$WORKSPACE_GUID" \
  --analytics-query "${FRESH_TABLE} | where TimeGenerated > ago(${FRESH_MINUTES}m) | summarize count()" -o json \
  | jq -e '(.[0].count_ | tonumber) > 0'
```

Expected: `true`. Run it again with `FRESH_TABLE` set to the table a previously blind alert reads. `AZR-041` closes only when a fresh audit observes ingestion.

## Add Prometheus rule groups

For `AZR-033`. Azure Monitor managed Prometheus can be collecting metrics while **zero** Prometheus rule groups consume them: the metrics exist but nothing alerts on them. Collection without rules is a half-built pipeline. The fix authors a rule group (a `Microsoft.AlertsManagement/prometheusRuleGroups` resource, read confirmed at `2023-03-01`) scoped to the cluster's Azure Monitor workspace and wired to the action group from [Create and wire an action group](#create-and-wire-an-action-group). Map each rule to a critical service from topology, and announce every expression with its `for` duration and severity. `RESTART_THRESHOLD`, `RESTART_WINDOW`, and the duration, severity, and interval values below are examples: tune them to your workloads.

Gate first: prove the metric is collected and the expression runs, read-only, against the workspace's Prometheus query endpoint (the identity needs `Monitoring Data Reader` on the Azure Monitor workspace):

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
AMW_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.Monitor/accounts/central-amw"  # the cluster's Azure Monitor workspace, from the AZR-033 evidence
PROM_METRIC="kube_pod_container_status_restarts_total"   # the metric the rule reads
RESTART_THRESHOLD="3"    # example, tune to your environment
RESTART_WINDOW="15m"     # example, tune to your environment
PROM_EXPR="increase(${PROM_METRIC}[${RESTART_WINDOW}]) > ${RESTART_THRESHOLD}"
AMW_QUERY="$(az monitor account show --ids "$AMW_ID" --query metrics.prometheusQueryEndpoint -o tsv)"
[ -n "$AMW_QUERY" ] || { echo "no Prometheus query endpoint on ${AMW_ID}" >&2; exit 1; }
PROM_TOKEN="$(az account get-access-token --subscription "$SUB" --resource https://prometheus.monitor.azure.com --query accessToken -o tsv)"
# 1. The metric is collected. A rule over a metric with no series watches nothing.
curl -fsS --max-time 30 -H "Authorization: Bearer ${PROM_TOKEN}" --data-urlencode "query=count(${PROM_METRIC})" \
  "${AMW_QUERY}/api/v1/query" | jq -e '.status == "success" and (.data.result | length) > 0'
# 2. The rule expression parses and runs.
curl -fsS --max-time 30 -H "Authorization: Bearer ${PROM_TOKEN}" --data-urlencode "query=${PROM_EXPR}" \
  "${AMW_QUERY}/api/v1/query" | jq -e '.status == "success"'
```

Expected: `true` twice. The block stops when the workspace holds no series for the metric (the rule would watch nothing) or when the expression does not parse. Then announce the rule group and create it:

```bash
set -eu
SUB="<subscription-id>"   # azure.subscription_id: the subscription the live-safety gate printed
case "$SUB" in ''|'<'*) echo "Set SUB to the subscription the live-safety gate printed" >&2; exit 1 ;; esac
RG="observability-rg"    # the resource group that owns the rule group
AMW_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/Microsoft.Monitor/accounts/central-amw"  # the cluster's Azure Monitor workspace, from the AZR-033 evidence
CLUSTER="prod-aks"       # the cluster whose metrics the rules read
AG_ID="/subscriptions/${SUB}/resourceGroups/observability-rg/providers/microsoft.insights/actionGroups/payments-production-alerts"
RULE_GROUP="prod-aks-pod-restarts"
PROM_METRIC="kube_pod_container_status_restarts_total"   # the metric the gate block proved
RESTART_THRESHOLD="3"    # example, tune to your environment
RESTART_WINDOW="15m"     # example, tune to your environment
FOR_DURATION="PT5M"      # example: how long the condition holds before it fires; tune to your environment
RULE_SEVERITY="3"        # example, tune to your environment (0 critical to 4 verbose)
RULE_INTERVAL="PT1M"     # example: how often the group evaluates; tune to your environment
PROM_EXPR="increase(${PROM_METRIC}[${RESTART_WINDOW}]) > ${RESTART_THRESHOLD}"
# The rollback deletes RULE_GROUP, so never create over a rule group that already exists under that name.
EXISTING="$(az alerts-management prometheus-rule-group list --resource-group "$RG" --subscription "$SUB" -o json)"
printf '%s' "$EXISTING" | jq -e --arg n "$RULE_GROUP" 'all((.value? // .)[]?; .name != $n)' > /dev/null \
  || { echo "A rule group named ${RULE_GROUP} already exists in ${RG}: pick another name" >&2; exit 1; }
RULES="$(jq -cn --arg expr "$PROM_EXPR" --arg dur "$FOR_DURATION" --argjson sev "$RULE_SEVERITY" --arg ag "$AG_ID" \
  '[{"alert": "PodRestartsHigh", "expression": $expr, "for": $dur, "severity": $sev, "enabled": true, "actions": [{"actionGroupId": $ag}]}]')"
AMW_REGION="$(az monitor account show --ids "$AMW_ID" --query location -o tsv)"   # the rule group lives in the workspace's region
az alerts-management prometheus-rule-group create --name "$RULE_GROUP" --resource-group "$RG" --subscription "$SUB" \
  --location "$AMW_REGION" --scopes "$AMW_ID" --cluster-name "$CLUSTER" --interval "$RULE_INTERVAL" --enabled true \
  --description "pod restarts on ${CLUSTER} | capture pod, container, last termination reason, recent deploy" --rules "$RULES"
# prometheusRuleGroups reads are confirmed at api-version 2023-03-01. Verify the scope and the announced action group on every rule.
az alerts-management prometheus-rule-group show --name "$RULE_GROUP" --resource-group "$RG" --subscription "$SUB" -o json \
  | jq -e --arg amw "$AMW_ID" --arg ag "$AG_ID" '.enabled == true
      and any(.scopes[]?; ascii_downcase == ($amw | ascii_downcase))
      and (.rules | length) > 0
      and all(.rules[]; any(.actions[]?; (.actionGroupId | ascii_downcase) == ($ag | ascii_downcase)))'
```

Expected: exit 0. The re-read proves the rule group is `configured`; it is `validated-live` once a real firing reaches the action group. `az alerts-management prometheus-rule-group` comes from the `alertsmanagement` az extension; check `create --help` on your version before announcing. **Rollback**, in its own fresh shell:

```bash
set -eu
SUB="<subscription-id>"          # azure.subscription_id: the subscription the live-safety gate printed
RG="<resource-group>"            # the resource group that owns the rule group
RULE_GROUP="<rule-group-name>"   # the Prometheus rule group this setup created
for v in "$SUB" "$RG" "$RULE_GROUP"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
az account show --subscription "$SUB" --query id -o tsv   # stops here if this login cannot see the subscription
az alerts-management prometheus-rule-group show --name "$RULE_GROUP" --resource-group "$RG" --subscription "$SUB" --query id -o tsv   # what will be deleted
az alerts-management prometheus-rule-group delete --name "$RULE_GROUP" --resource-group "$RG" --subscription "$SUB"
OUT="$(az alerts-management prometheus-rule-group show --name "$RULE_GROUP" --resource-group "$RG" --subscription "$SUB" -o json 2>&1)" && { echo "still present" >&2; exit 1; }
printf '%s\n' "$OUT" | grep -q -i -E 'not.?found' && echo "DELETED" || { printf '%s\n' "$OUT" >&2; exit 1; }
```

Expected: the subscription id, the rule group's resource id, then `DELETED`.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/azure/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact az command or payload applied; action-group secret values never included>
- Verified: <the read-back command and the value it showed>
- Proof: <configured (a re-read showed it) | validated-live (the effect you observed, for example the notification that arrived)>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, configured or validated-live, remaining risk), the pending list with named owners (VM agent installs, AKS/RBAC plans, `Reader` grants for `AZR-007`, health-probe edits), and a fresh `/scoutflo:audit-azure` run to re-score; its delta shows which findings moved to fixed. RBAC-blocked items never appear as "fixed" by this skill; they close only when an Owner / User Access Administrator acts and a later audit observes the change.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Alert created before its action group exists | Order discipline: action group first, then the alerts that reference it; an alert with no action group fails its own verify |
| Local `az` default subscription "fixed" to reach the target | Never `az account set` inside a fix block; every command passes an explicit `--subscription`, and the live-safety gate stops unless `az` resolves the subscription `toolkit.yaml` names |
| Wrong subscription mutated | The live-safety gate re-reads the target's `subscription_id` from `toolkit.yaml` through the shared enumerator (the `SCOUTFLO_TARGET` label for a labeled list, never a guess) and stops on a mismatch with a live `az account show`; forward blocks are announced with `AZ_SUBSCRIPTION_CFG` set to the gate's subscription, and rollbacks name `SUB` explicitly |
| Change plan built from the wrong run folder | Load findings reads only date-named run folders under the target's segment (`azure/<date>/` or `azure/<label>/<date>/`), never this skill's own `setup-<date>/` folder |
| `AuthorizationFailed` on `roleAssignments/write` treated as a retry-or-self-grant signal | RBAC/role-granting is its own risk class needing Owner/User Access Administrator; the Contributor identity records it as a plan with a named owner, never self-grants |
| Managed Prometheus enablement's DCR role grant done by hand | If enablement needs a role assignment a Contributor cannot make, AZR-031 becomes a plan for the Owner; only the enablement that succeeds without a grant executes |
| AKS enablement treated as a plain monitoring-plane write | Container Insights / managed Prometheus are cluster mutations (controlled rollout); announce the larger blast radius and verify against the confirmed `omsagent.enabled` / `azureMonitorProfile.metrics.enabled` paths |
| VM guest-metric coverage "fixed" by installing the agent | AMA + DCR install is a per-VM controlled rollout out of write scope; only the platform metric alerts execute, the agent install is a plan |
| Log alert shipped whose KQL matches nothing, or that can never fire | The gate block runs before the create block and stops when the source table is empty or the query does not parse; the alert query returns matching rows (no trailing `summarize count()`), so the row-count condition can cross its threshold |
| Diagnostic setting turns a cluster into the largest ingestion bill | AKS control-plane categories use `kube-audit-admin`, not `kube-audit`; `kube-audit` or `allLogs` is added only as an announced cost decision |
| A re-run overwrites the backup a restore needs | Backups are timestamped and a block refuses to write over an existing file; restores read the backup path the change record names and refuse an empty prior value |
| Diagnostic setting written against an unconfirmed api-version assumption | `diagnosticSettings` has no confirmed api-version; confirm supported categories with `az monitor diagnostic-settings categories list` and let the CLI pick the version, re-announcing if it differs |
| Health-probe parameters edited instead of adding diagnostics | Editing a live App Gateway/LB probe can eject healthy backends; only the diagnostic-settings half of AZR-050 executes, the probe edit is a recorded plan |
| `AZR-007` "closed" by creating a first alert | AZR-007 is a visibility gap, not a confident zero; diagnose read scope, plan any missing grant, re-audit with scope before treating "no alerting" as true |
| Action-group secret values leak into announcements or records | Announce receiver names and types; webhook URLs, service keys, and connection strings ride unechoed variables into the command and stay out of the change record |
| `az costmanagement query` used for a cost figure | That CLI does not exist; cost is read-only guidance here: point at audit-cost and the Cost Management REST path, never invent a dollar |
| Batch continues past a failed create | Mid-batch failure rule: stop, re-read the failed object, re-announce the remainder |
| Deletion slipped into a batch approval | Action groups, alerts, and diagnostic settings are deleted only with individual confirmation and the body quoted |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Cluster, network, or RBAC change smuggled in as monitoring work | Write scope is the Monitoring plane; everything else becomes a plan with a named owner |
