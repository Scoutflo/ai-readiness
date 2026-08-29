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

All api-versions, property paths, and auth behavior cited below are the ones live-confirmed in the Azure SDK/API Validation Report; nothing unconfirmed is asserted as fact.

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Azure | `azure.subscription_id`, optional `azure.tenant_id` (pins the Entra tenant — asserted at the live-safety gate), optional `azure.region` (reserved for future regional-scope narrowing; not consulted today) | none stored; auth is `az login` (`DefaultAzureCredential` → `AzureCliCredential` fallback, confirmed) | `Reader` + `Monitoring Reader` on the subscription; `Log Analytics Reader` for data-plane queries; `Cost Management Reader` only for the non-scored cost section (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

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
# Resolve the CURRENT azure target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). Every command below
# names --subscription "$SUB" explicitly; the ambient az default is never read.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
[ "${AZ_N:-0}" -ge 1 ] || { echo "no azure target configured in $CFG; run /scoutflo:connect"; exit 1; }
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX"); SUB=$(sh "$TT" "$CFG" azure get "$AZ_IDX" subscription_id)
[ -n "$SUB" ] || { echo "azure target '${AZ_LABEL:-?}' has no subscription_id in $CFG; run /scoutflo:connect"; exit 1; }
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
echo "azure target: ${AZ_LABEL} (subscription ${SUB}) -> ${AZ_SEG}/"
# Confirmed auth path: DefaultAzureCredential -> AzureCliCredential (via az login).
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
# subscription_id may hold a subscription NAME as well as a GUID: `az` accepts either on --subscription,
# but the ARM REST path below needs the GUID, so resolve a NAME to its id here and use the id hereafter.
# A value matching a visible id is used as-is; a value matching neither an id nor a name is left as-is
# so the ARM reachability probe reports it (404 = wrong subscription id), unchanged from before.
SUB_ACCTS="$(az account list -o json 2>/dev/null || echo '[]')"
if ! printf '%s' "$SUB_ACCTS" | jq -e --arg s "$SUB" 'any(.[]; .id==$s)' >/dev/null 2>&1; then
  SUB_NAME_HITS="$(printf '%s' "$SUB_ACCTS" | jq -r --arg s "$SUB" '[.[] | select(.name==$s)] | length')"
  [ "${SUB_NAME_HITS:-0}" -le 1 ] || { echo "azure subscription_id '${SUB}' matches ${SUB_NAME_HITS} visible subscriptions by NAME; set it to the subscription id (GUID) to disambiguate"; exit 1; }
  SUB_ID="$(printf '%s' "$SUB_ACCTS" | jq -r --arg s "$SUB" 'map(select(.name==$s)) | .[0].id // empty')"
  [ -n "$SUB_ID" ] && { echo "note: azure subscription_id '${SUB}' matched a subscription NAME; resolved to id ${SUB_ID}"; SUB="$SUB_ID"; }
fi
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name'); auditing subscription ${SUB}"
ARM_TOKEN="$(az account get-access-token --subscription "$SUB" --resource https://management.azure.com --query accessToken -o tsv)"
# One cheap ARM read at a CONFIRMED api-version proves reachability + the token works.
# status-probe-ok: the az CLI already authenticated the identity above; this is an ARM reachability + api-version confirmation on management.azure.com (a fixed JSON API, not an SSO-fronted SPA), with 401/403/404 handled explicitly.
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
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CONFIG" ] || { echo "missing $CONFIG; run /scoutflo:connect"; exit 1; }
# Resolve the CURRENT azure target from config via the shared enumerator — a single block, or the
# SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_N=$(sh "$TT" "$CONFIG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CONFIG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CONFIG" azure label "$AZ_IDX")
AZ_SUB_CFG=$(sh "$TT" "$CONFIG" azure get "$AZ_IDX" subscription_id)
[ -n "$AZ_SUB_CFG" ] || { echo "azure target '${AZ_LABEL:-?}' has no subscription_id in $CONFIG; run /scoutflo:connect"; exit 1; }
ACCT="$(az account show -o json)" || { echo "az account show failed; run 'az login'"; exit 1; }
echo "identity: $(printf '%s' "$ACCT" | jq -r '.user.name')"
echo "tenant: $(printf '%s' "$ACCT" | jq -r '.tenantId')"
echo "azure target: ${AZ_LABEL} -> subscription ${AZ_SUB_CFG}"
# Multi-target safety: the target subscription must be one THIS identity can see (`az account list`),
# matched by id OR by subscription NAME (subscription_id may legitimately hold either), and every
# command passes --subscription "${AZ_SUB_CFG}" explicitly. A multi-subscription estate audits several
# subscriptions in one run, so the ambient default is NOT required to equal the target; `az account
# set` is never used. A value visible neither by id nor by name genuinely stops the run.
AZ_ACCTS="$(az account list -o json 2>/dev/null || echo '[]')"
AZ_SUB_ID="$(printf '%s' "$AZ_ACCTS" | jq -r --arg s "$AZ_SUB_CFG" 'map(select(.id==$s)) | .[0].id // empty')"
if [ -z "$AZ_SUB_ID" ]; then
  # No id match: a subscription NAME in subscription_id is allowed, but resolve it to its id so every
  # --subscription (and the ARM REST path, which needs the GUID) uses the id, never the bare name.
  # An ambiguous name (2+ visible subscriptions share it) stops rather than guessing which to audit.
  AZ_NAME_HITS="$(printf '%s' "$AZ_ACCTS" | jq -r --arg s "$AZ_SUB_CFG" '[.[] | select(.name==$s)] | length')"
  [ "${AZ_NAME_HITS:-0}" -le 1 ] \
    || { echo "STOP: azure target '${AZ_LABEL}' subscription_id '${AZ_SUB_CFG}' matches ${AZ_NAME_HITS} visible subscriptions by NAME; set azure.subscription_id to the subscription id (GUID) to disambiguate"; exit 1; }
  AZ_SUB_ID="$(printf '%s' "$AZ_ACCTS" | jq -r --arg s "$AZ_SUB_CFG" 'map(select(.name==$s)) | .[0].id // empty')"
  [ -n "$AZ_SUB_ID" ] && echo "note: azure target '${AZ_LABEL}' subscription_id '${AZ_SUB_CFG}' matched a subscription NAME; resolved to id ${AZ_SUB_ID}, used on every --subscription hereafter"
fi
[ -n "$AZ_SUB_ID" ] \
  || { echo "STOP: azure target '${AZ_LABEL}' subscription '${AZ_SUB_CFG}' is not visible to this identity ($(printf '%s' "$ACCT" | jq -r '.user.name')) in 'az account list' (by id or name); az login to the right tenant/account, or fix the config"; exit 1; }
AZ_SUB_CFG="$AZ_SUB_ID"
# Optional tenant pin: when azure.tenant_id is set for this target, the resolved account's tenant
# MUST match it — protects against auditing a same-named subscription in the wrong Entra tenant.
AZ_TENANT_CFG=$(sh "$TT" "$CONFIG" azure get "$AZ_IDX" tenant_id)
if [ -n "$AZ_TENANT_CFG" ]; then
  [ "$(printf '%s' "$ACCT" | jq -r '.tenantId')" = "$AZ_TENANT_CFG" ] \
    || { echo "STOP: azure target '${AZ_LABEL}' resolved tenant $(printf '%s' "$ACCT" | jq -r '.tenantId') != configured azure.tenant_id ${AZ_TENANT_CFG}; az login to the intended tenant, or fix the config"; exit 1; }
fi
echo "live-safety gate passed: identity + tenant printed${AZ_TENANT_CFG:+ (tenant pinned to ${AZ_TENANT_CFG})}; target subscription ${AZ_SUB_CFG} is visible and will be named explicitly on every command"
```

The assertion is the gate: the target subscription must be **visible to this identity** (`az account list`) or the block exits nonzero and stops the run. A multi-subscription estate audits each configured target in turn (the runner sets `SCOUTFLO_TARGET=<label>`), so — unlike a single-subscription equality check — the ambient `az` default is **not** required to equal the target; instead every command names `--subscription "$SUB"` explicitly, so the run can never touch a subscription other than the one it resolved from `toolkit.yaml`. If the printed identity or tenant is not the one your team intends for audits, stop and report the mismatch even though the visibility check passed; identity, tenant, and subscription are separate checks. `az account set` is never used, and pointing the audit elsewhere is an edit to `toolkit.yaml`.

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
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX"); SUB=$(sh "$TT" "$CFG" azure get "$AZ_IDX" subscription_id)
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
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
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}"
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
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX"); SUB=$(sh "$TT" "$CFG" azure get "$AZ_IDX" subscription_id)
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}/${RUN_DATE}/raw"
AGS="$(jq 'length' "${RAW_DIR}/action-groups.json" 2>/dev/null || echo 0)"
ALERTS="$(jq 'length' "${RAW_DIR}/metric-alerts.json" 2>/dev/null || echo 0)"
if [ "${AGS:-0}" -eq 0 ] && [ "${ALERTS:-0}" -eq 0 ]; then
  # Both empty despite a readable ARM surface (the doctor gate returned 200, not 401/403).
  echo "[guard] 0 action groups AND 0 metric alerts in target ${AZ_LABEL} (subscription ${SUB}) despite a readable ARM surface — possible identity / resource-group visibility gap (AZR-007)"
  echo "[guard] alerting may live in a resource group this identity cannot read, or this identity lacks Monitoring Reader at subscription scope — do NOT score a confident 0/100"
fi
```

Behavior this enforces (Phase 11 honors it):

- **Alerting-object-dependent categories excluded** — every check in **Alert routing and delivery, Alert coverage, and Alert quality** records `blocked` with the visibility-gap reason; each fully-unassessed category (assessed==0) then moves to `score.excluded[]` and renormalizes out per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md). Emit finding **AZR-007** (`scoring_scope: "non-scored"`, points_recoverable 0, no check-ledger row) naming the gap and the fix (confirm the identity holds `Reader`/`Monitoring Reader` at subscription scope, and check the resource groups that hold the alerting objects — recipe in `/scoutflo:connect`). **Never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim.
- **Keep the resource-signal categories included** — **Compute VM/VMSS coverage, AKS coverage, Log Analytics coverage, and Load balancer coverage** assess the estate's own posture (AMA/DCR presence, `addonProfiles.omsagent.enabled`, `azureMonitorProfile.metrics.enabled`, diagnostic settings, retention, health-probe attachment) from resource inventory that does not depend on the alerting objects, so at least one scored category remains (excluding all leaves nothing to score and `check-findings.sh` rejects an all-excluded scorecard).
- If those resource categories are **also** empty — a pure subscription with no resources of its own, or an identity that can see nothing — every check is `blocked`, the run is `state: "unassessed"` with `overall: null` (never a confident score at all), and AZR-007 is the reported outcome. A `401`/`403` from Phase 2 is a *privilege* finding, not this trip-wire.

## Phase 1: Service context

If `./scoutflo-audits/topology.md` exists, load it. Its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays; map VMs, AKS workloads, App Gateways, and Load Balancers to those names. If it does not exist, infer services from resource names, note the inference in the report, and suggest `/scoutflo:map-topology`. If live discovery contradicts topology.md, record the discrepancy; only the mapping skill and you edit that file.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/azure-checks.md](references/azure-checks.md): action groups (redacted at capture, as a JSON array in `raw/action-groups.json`), metric alerts (`raw/metric-alerts.json`), scheduled-query rules, activity-log alerts, VMs and VMSS with instance-view power state, AKS clusters with `addonProfiles.omsagent.enabled` and `azureMonitorProfile.metrics.enabled`, Log Analytics workspaces with `retentionInDays`, App Gateways / Load Balancers with their health probes and diagnostic settings. Judgment starts in Phase 3; inventory records what exists. Use the confirmed api-versions: `actionGroups` 2023-01-01, `metricAlerts` 2018-03-01, `scheduledQueryRules` 2022-06-15, `activityLogAlerts` 2020-10-01, `managedClusters` 2024-09-01, `workspaces` 2022-10-01, `virtualMachines`/`virtualMachineScaleSets` 2024-07-01, `applicationGateways`/`loadBalancers` 2024-05-01. `diagnosticSettings` has **no** confirmed api-version — let the `az` CLI pick it and confirm supported categories with `az monitor diagnostic-settings categories list`, never assert one.

## Phase 3: Alert routing and delivery (AZR-001, AZR-005)

Commands in [references/azure-checks.md](references/azure-checks.md). Judge whether an alert that fires reaches a human. Do not stop at "an action group with 0 receivers pages nobody" — perform the join that IS the blast radius: for each enabled rule in `metric-alerts.json`/`scheduled-query-rules.json`/`activity-log-alerts.json`, resolve every `actionGroupId` to `action-groups.json` and sum receiver counts; a rule whose *only* groups have 0 enabled receivers is mute even though it references a group. Report it as the named set (`N enabled rules covering [checkout-vm-1, payments-sql, appgw-prod] all terminate at ops-catchall with 0 enabled receivers`), mapped to topology service names, and cite the AZR-002 pass it invalidates. Also required: at least one enabled action group with a live receiver exists (critical when none); every enabled alert rule names at least one action group; groups split per environment (`<team>-<environment>-alerts`) instead of one catch-all; no disabled or dead receiver still referenced by a rule; and delivery proven by an observed notification rather than assumed (capped at `configured` without one — Azure Monitor exposes no public fired-notification list, so a team-confirmed sighting is the documented manual exception). Any action group that appears to be the toolkit Slack brief webhook is flagged, not counted as alerting.

**AZR-005 alert-processing (suppression) rules (verify-pending).** Routing can look healthy — groups have receivers, rules reference them (AZR-001 passes) — while an enabled alert-processing rule with action `RemoveAllActionGroups` silently swallows the notification between "rule fires" and "page leaves Azure". Intersect each enabled suppression rule's `scopes[]` with the resource groups holding critical resources and name the muted services; a rule scoped at a production resource group with no end schedule is a permanent estate-wide mute. It negates the AZR-001 pass and is the hidden middle of the flagship chain. This check is drafted against Azure's documented `actionRules` surface but has not been run against a live tenant; carry the verify-pending caveat and record it `blocked` until the api-version returns a live 200 — never a fabricated observation.

## Phase 4: Alert coverage — metric, log, activity (AZR-002, AZR-003, AZR-004)

Commands in [references/azure-checks.md](references/azure-checks.md).

- **AZR-002 metric alerts.** Each critical resource (App Service, SQL, Storage, Cosmos, VM — anything with an ARM resource id) carries a platform-metric alert on the signal that matters, scoped to a real resource id that emits the metric (a rule watching a metric the resource never ships can never fire). Two named tiers (warning/critical) where the workload is stable. Split the misses into two named buckets, never one generic "saturates silently": **(a) no rule at all** — name the resource and the signal that would have fired, fix = add a two-tier alert; **(b) rule present but `enabled:false`** — phantom coverage that inventory reads as covered ("`payments-sql` HAS rule `sql-dtu-critical` but it is `enabled:false`"), the "someone silenced it in an incident and never re-enabled it" signal, fix = re-enable the existing rule (cheaper) not author a new one, and name which. A covered resource whose rule routes to a dead group (AZR-001) or a suppressed scope (AZR-005) is doubly blind.
- **AZR-003 scheduled-query (log) alerts.** Log-rate, missing-heartbeat, and business-signal coverage a metric alert cannot give. Credit requires the workspace to actually receive the logs the KQL reads and the query to return rows for a real condition — validate with the confirmed data-plane read `az monitor log-analytics query` (needs the `log-analytics` extension); an alert on a query that matches nothing is decoration.
- **AZR-004 activity-log alerts.** Control-plane coverage for the subscription itself: Azure Service Health advisories, Resource Health transitions, and policy/administrative events, each attaching an action group. Absence of any Service Health alert is a real gap — a regional Azure incident then pages nobody.

## Phase 5: Compute VM/VMSS coverage (AZR-010)

Commands in [references/azure-checks.md](references/azure-checks.md). Per serving VM or scale set: platform CPU/disk/network alerts (no agent needed) with two tiers where stable; guest metrics (memory, disk-free, per-process) credited **only** after Azure Monitor Agent + Data Collection Rule evidence proves them live per VM — never before; and every metric-alert scope resolves to a resource that emits the metric. A VMSS running fixed capacity with alerts only on the aggregate hides a single unhealthy instance; name that gap. Stopped-but-billed VMs (power state `PowerState/stopped`) are a cost signal handled in the non-scored cost section, not here.

## Phase 6: AKS coverage (AZR-030, AZR-031, AZR-032, AZR-033)

Commands in [references/azure-checks.md](references/azure-checks.md). AZR-030/031/032 verify against **confirmed** property paths from `az aks show`:

- **AZR-030 Container Insights** — `addonProfiles.omsagent.enabled == true` (with `.config.logAnalyticsWorkspaceResourceID` pointing at a real workspace); the addon absent is the "off" signal, not an error. Don't file "Container Insights off" as the finding — join the cluster to the critical workloads scheduled on it (topology.md) and name what goes dark: "`aks-prod` runs `checkout`, `orders`, `payments`; with Container Insights off and no in-cluster Loki, a pod OOM/crashloop leaves zero container stdout/stderr or per-container metrics in Log Analytics — the responder has only control-plane events."
- **AZR-031 managed Prometheus** — `azureMonitorProfile.metrics.enabled == true`; `azureMonitorProfile` absent/null is "off" (confirmed). Credit this where workload metric alerting is expected.
- **AZR-032 AKS diagnostic settings** — the cluster's control-plane logs route to a Log Analytics workspace via a diagnostic setting; name the incident it blinds, not the missing object: "`aks-prod` control-plane logs go nowhere — an apiserver throttle, admission-webhook failure, or RBAC denial that stalls deploys has no queryable record; the on-call reconstructs from memory." State the cluster and which log categories are unrouted (confirm categories with `categories list`).
- **AZR-033 managed-Prometheus rule-group consumption (verify-pending).** A cluster with `azureMonitorProfile.metrics.enabled == true` is collecting and being billed for metrics; if **zero** `prometheusRuleGroups` reference its Azure Monitor workspace, nothing alerts on them — metrics collected ≠ metrics alerted-on. This is the alerting-plane extension AZR-031 never performs. Drafted against Azure's documented `prometheusRuleGroups` surface (api-version 2023-03-01, not in the confirmed set); carry the verify-pending caveat and record it `blocked` until a live 200 confirms the api-version.

Where the in-cluster Prometheus/Alertmanager stack is the primary alerting plane, mark the overlapping checks `not-in-scope`, state the split, and run `/scoutflo:audit-lgtm` against that stack. Enabling any of these is a controlled rollout (a cluster mutation), out of read-only scope — findings point at `setup-azure`, which plans it.

## Phase 7: Log Analytics coverage and retention (AZR-040, AZR-041, AZR-042)

Commands in [references/azure-checks.md](references/azure-checks.md). This workspace is the single evidence plane every diagnostic route depends on.

- **AZR-040 coverage/retention.** At least one workspace is the estate's log destination; critical resources route to it via diagnostic settings; and `retentionInDays` is a deliberate decision, not an unexamined default — matching the retention discipline `audit-aws` (`AWS-051`) and `audit-gcp` (`GCP-054`) already require. Tie it to MTTR: compute the diagnostic-settings fan-in ("`la-prod` is the sink for 6 VMs, 2 AKS clusters, and 3 edges, and `retentionInDays=30` → any investigation older than a month has no logs") and report the count of critical resources whose evidence ages out, not "retention is short". A workspace that exists but receives nothing from the critical resources is coverage on paper only; name the resources whose diagnostic settings are missing.
- **AZR-041 workspace stopped ingesting (verify-pending).** Config presence (AZR-040) is not ingestion. A workspace can be a configured destination while the agent/DCR feeding it has stopped — a data-plane recency read (`az monitor log-analytics query` on `Heartbeat`/critical-table freshness, confirmed read path) yields the last ingestion time. A stale workspace invalidates every AZR-030/032/050 pass that routes to it and is the evidence-plane half of the flagship chain. Drafted but not run against a live tenant; carry the verify-pending caveat.
- **AZR-042 Activity Log never exported (verify-pending).** Distinct from AZR-004 (whether activity-log *alerts* page): whether the events are *retained and queryable at all*. If the subscription-scope diagnostic settings export no `Administrative`/`Security`/`Policy` categories to a workspace, control-plane events (who deleted the alert rule, who changed the NSG) live only ~90 days in the platform log and are not queryable in Log Analytics — the forensic trail an incident review needs after a config-change-induced outage. Drafted but not run against a live tenant; carry the verify-pending caveat.

## Phase 8: Load balancer and App Gateway coverage (AZR-050)

Commands in [references/azure-checks.md](references/azure-checks.md). Every serving Application Gateway / Load Balancer has a health probe attached, **and** a diagnostic setting routing its access/performance logs and metrics to Log Analytics so a 5xx or latency spike is queryable and alertable. Name the all-backends-down page-nobody scenario per edge rather than "zero probes": "`appgw-prod` fronts backend pool `checkout-pool` with 0 health probes and 0 diagnostic settings; if all backends 5xx, traffic is still routed and nobody is paged." State the edge, its pool, and whether AZR-002 has any metric alert on its `BackendConnectTime`/`UnhealthyHostCount`. The trap this phase exists for: health probes eject bad backends silently, so an estate can look "self-healing" while an all-backends-down event pages nobody. Health probes and Monitor alerts are audited separately; neither is credited for the other. Editing a live probe is traffic-impacting and out of write scope — only the diagnostic-settings half is a monitoring-plane fix.

## Phase 9: Alert quality (AZR-060)

Commands in [references/azure-checks.md](references/azure-checks.md). Reading the rule bodies already captured in Phase 2 (no new call, no mutation): each paging rule carries a `windowSize`/`evaluationFrequency` that debounces a single transient sample; `severity` is set to a real tier (0 critical … 4 verbose), not left at a default that makes everything look equally urgent; documentation tells the responder where they are, how bad it is, and what to capture first. Surface the two highest-signal noise classes concretely: **(a) permanently firing** — a rule with a threshold below the resource's steady-state ("`cpu>5%` on `appgw-prod` (steady-state 40%) fires continuously"); **(b) double-paging** — the same logical condition wired to more than one action group ("`disk-space` is wired to both `ops-primary` and `ops-catchall` → every trigger pages twice"). Noise on the same action group buries the real pages that reach the one live receiver (chains with AZR-001 — the noise-drowns-signal cascade). Honest ceiling, stated in the report every run: Azure Monitor exposes no public fired-notification/incident-history list API, so this audit reports **structural** noise signals read off each rule's configuration and never a fabricated "N% of alerts are actionable" number.

## Phase 10: Coverage matrix and topology readiness

Fill one row per critical service using the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Metric | Log | VM/VMSS | AKS | Log Analytics | LB/AppGW | Routing | Owner | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |

Cell composition, so the matrix hides nothing: the `VM/VMSS` cell folds in the AMA gate (platform-only coverage caps it at `partial` with the gap named); the `Log` cell requires a matching, recently-matching, action-group-carrying query to reach `pass`; every cell carries its `passed/total` denominator. Name affected services in findings: "two VMs lack memory coverage" is not a finding; "checkout-vm-1 and checkout-vm-2 lack memory coverage" is.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate T1 to T6 per critical service from `./scoutflo-audits/topology-export.json`, read-only. An edge this audit verified live counts toward T6. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. If the export or topology.md is missing or describes a different target, render the matching state from topology-readiness.md with its one-line unlock; never guess and never say a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

## Phase 11: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is the assessed-credit ratio times 100 rounded down; overall is the weight-normalized sum over categories with at least one assessed check. Show assessment coverage separately. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action. Assign each category a maturity value (`reactive`, `proactive`, `systematic`) per the shared definitions, judged conservatively.

**Assemble the flagship detection-blindness chain.** Before scoring, join the findings into the one silent-degradation path no scanner assembles: for a named critical service, `alert-EXISTS × route-LIVE × signal-MEASURED × evidence-RETAINED`. Emit it as a single sentence naming the specific service — e.g. *"`checkout-vm-1` (critical, per topology) HAS a CPU metric alert (AZR-002 pass) → but its only action group has 0 enabled receivers (AZR-001) AND an enabled `RemoveAllActionGroups` rule scopes `rg-prod` (AZR-005) → the VM has no AMA/DCR so memory is never even measured (AZR-010) → and its platform logs route to `la-prod` whose newest Heartbeat is 6 days old (AZR-041) at `retentionInDays=30` (AZR-040): when checkout saturates tonight, no page fires, the signal is never collected, and the logs to reconstruct it are stale."* Five individually-green-looking objects that a free scanner reports as "covered", chained into one proof the service is undetectable end-to-end. This is the Azure differentiator: Azure Monitor exposes no fired-notification API, so the only way to know a service is blind is to compute this chain from config + data-plane recency — which Advisor and the Portal banners do not. Where a link is verify-pending or blocked, say so in the chain rather than asserting it.

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert routing and delivery | 25 | AZR-001, AZR-005 |
| Alert coverage (metric, log, activity) | 25 | AZR-002 to AZR-004 |
| Compute VM/VMSS coverage | 15 | AZR-010 |
| AKS coverage | 15 | AZR-030 to AZR-033 |
| Log Analytics coverage | 10 | AZR-040 to AZR-042 |
| Load balancer / App Gateway coverage | 5 | AZR-050 |
| Alert quality | 5 | AZR-060 |

Weights are unchanged from the prior release (they still sum to 100); the four new checks (AZR-005, AZR-033, AZR-041, AZR-042) fold into their home categories rather than triggering a reweight. All four are **verify-pending** (`live_verifiable=false`): drafted against Azure's documented API and adversarially reviewed, but never run against a live tenant — no Azure estate exists in the benchmark. Until a first live run with a read-only token confirms each one's api-version (AZR-005 `actionRules` 2021-08-08; AZR-033 `prometheusRuleGroups` 2023-03-01) and read path, they score `blocked` (unassessed — the check leaves the readiness denominator, never a confident pass or a fabricated observation, and a category whose every check is blocked is fully unassessed, moves to `score.excluded[]`, and renormalizes out), exactly as any unreachable check does.

The full check catalog and the target profile (what 100 means per category) are in [references/azure-checks.md](references/azure-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers. `AZR-007`, when it fires, excludes the alerting-dependent categories rather than scoring them zero (see the guardrail section).

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service passes every applicable coverage row, and no category was excluded. Below the gate, write "good base coverage", never "end to end".

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding, `AZR-*` and `AZROPT-*` alike, per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `points_recoverable` to 0. Suppressed readiness checks remain assessed for coverage but are excluded from readiness scoring. A non-scored `AZROPT-*` finding has no check row: set only its lifecycle to `suppressed`, preserve `scoring_scope: "non-scored"`, and keep zero readiness points.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `AZR-*` readiness catalog check, including passes, partials, failures, blockers, and not-in-scope checks. Derive category counts, readiness, assessment coverage, and `score.check_set` from that complete ledger; never write them independently. `AZROPT-*` findings stay outside the readiness ledger and explicitly carry `scoring_scope: "non-scored"`. The AZR-007 guardrail is not a standing catalog check: when it fires it is emitted as a `scoring_scope: "non-scored"` finding (points_recoverable 0, no check-ledger row); its score impact is that the alerting-dependent categories' own checks record `blocked` and, being fully unassessed, move to `score.excluded[]`.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass `AZR-*` check; `non-scored` for `AZROPT-*` and the AZR-007 guardrail) and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Use the AI SRE lane only when the evidence shows impact to telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX")
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}/${RUN_DATE}"
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
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX")
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
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
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
AZ_KIND=$(sh "$TT" "$CFG" azure kind); AZ_N=$(sh "$TT" "$CFG" azure count)
AZ_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$AZ_N" ]; do [ "$(sh "$TT" "$CFG" azure label "$_i")" = "$SCOUTFLO_TARGET" ] && { AZ_IDX=$_i; break; }; _i=$((_i+1)); done; fi
AZ_LABEL=$(sh "$TT" "$CFG" azure label "$AZ_IDX")
if [ "$AZ_KIND" = seq ]; then AZ_SEG="azure/${AZ_LABEL}"; else AZ_SEG="azure"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${AZ_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
TOPO_LINE="Topology readiness: readiness not recorded"  # replace with "r/n services sync-ready" from Phase 10
COST_LINE=""   # optional; set to "Cost: N optimization opportunities found" only when AZROPT findings exist this run
# slack.webhook_env names the webhook variable; skip when unset.
if [ -n "${SCOUTFLO_SLACK_WEBHOOK:-}" ]; then
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
  PREV="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d | grep -v '/runs$' | sort | tail -2 | head -1)"
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
      "\(($b - $n) | length) fixed, \(($n - $b) | length) new, \(($n - ($n - $b)) | length) unchanged"')"
  fi
  if [ "$SCORE_STATE" = "unassessed" ]; then
    HEAD="audit-azure ${RUN_DATE}: readiness unassessed; ${ASSESSMENT}. ${COUNTS}."
  else
    HEAD="audit-azure ${RUN_DATE}: ${SCORE}/100${MOVE:+ $MOVE}, ${E2E}; ${ASSESSMENT}. ${COUNTS}. ${CHECKS}."
  fi
  jq -n --arg head "$HEAD" \
        --arg top "$TOP" --arg delta "$DELTA" --arg topo "$TOPO_LINE" --arg cost "$COST_LINE" --arg path "$OUT_ABS/report.md" \
        '{text: ($head + "\nTop findings:\n" + $top + "\nDelta: " + $delta + "\n" + $topo + ($cost | if . == "" then "" else "\n" + . end) + "\nReport: " + $path)}' \
    | curl -fsS --max-time 10 -H 'Content-Type: application/json' -d @- "$SCOUTFLO_SLACK_WEBHOOK" \
    || echo "Slack brief failed to send; audit result unaffected"
fi
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
elif [ "$LOAD_METADATA_MODE" = "ssot-md" ]; then
  # Only business_context.md exists (json not derived): read the same rules from the SSOT directly.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; **reduce severity** for a gap that exists only in a non-production `environment` (per-env SLA); and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Large-path worklist

Runs on the large path only (see the Estate sizing step above). All state lives under a run-ID-keyed run directory `./scoutflo-audits/azure/[<label>/]runs/<RUN_ID>/`, not a calendar-date directory, so a run still batching when the UTC date rolls over keeps writing to the same place (the drift check and the emit step already skip this directory with `grep -v '/runs$'`).

1. **Find a resumable run, or start a new one.** Before minting a new `RUN_ID`, scan `./scoutflo-audits/azure/[<label>/]runs/*/worklist.tsv` for one with pending rows and offer to resume it instead of starting over.
2. **Build or resume the worklist.** One row per VM, VMSS, App Gateway, and Load Balancer counted in Estate sizing, status `pending` or `done`. A resumed run continues from its existing worklist; never rebuild one that already exists.
3. **Lock, then claim one batch.** Acquire `worklist.lock` in the run directory before reading pending rows; a lock older than `LOCK_STALE_MINUTES` (30 minutes; example, tune to your batch size) is abandoned and safe to reclaim. Take the next `BATCH_SIZE` pending rows and run the matching per-resource checks against just that batch — VM/VMSS coverage (AZR-010) for a VM/VMSS row, App Gateway / Load Balancer health-probe + diagnostic-setting checks (AZR-050) for a network row. A row is marked `done` **only after its reads succeed**, so an interrupted batch resumes at the row that failed. Release the lock once the batch's rows are marked.
4. **Assemble incrementally.** After each batch, recompose the partial findings and coverage matrix from the batches completed so far, and print progress (`done=X pending=Y`). Repeat from step 3 until the worklist has zero pending rows.
5. **Assert before writing.** `findings.json` and `report.md` are written only once a final check confirms the worklist's `pending` count is `0`. A partial run's state stays in the run directory as the resume point and never overwrites the previous complete report.

The subscription- and category-scoped checks (alert routing AZR-001, alert coverage AZR-002/003/004, AKS AZR-030/031/032, Log Analytics AZR-040, alert quality AZR-060, and the AZR-007 guardrail) are single cheap passes; they run once per run regardless of path and are never batched.

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
| Verify-pending check scored as a confident pass | AZR-005/033/041/042 are drafted against documented APIs but unrun against a live tenant; score `blocked` until a live 200 confirms the api-version/read path, never a fabricated observation |
| Health probes counted as alerting | Probes eject backends silently; only Monitor alerts page; audit both, credit neither for the other |
| VM guest metrics promised without the agent | Credit memory/disk-free only after AMA + DCR evidence per VM; platform metrics need no agent, guest metrics do |
| Log alert credited whose KQL matches nothing | Validate with `az monitor log-analytics query` (confirmed data-plane read); inspect the count before crediting |
| AKS "off" misread as an error | `azureMonitorProfile` absent/null and the omsagent addon absent are the confirmed "off" signals, not failures |
| diagnosticSettings audited against an assumed api-version | It has no confirmed api-version; let the CLI pick it and confirm categories with `categories list` |
| Action-group receiver secrets leaked | Capture receiver display name and type only, per secret-redaction.md; never print webhook URLs or service keys |
| Toolkit brief webhook conflated with an action group | Two webhooks, two jobs; flag any overlap as a finding |
| `az costmanagement query` used for a cost figure | That CLI does not exist; the cost read path is the Cost Management Query REST API at 2023-11-01, handling 429 with backoff, never a guessed dollar |
