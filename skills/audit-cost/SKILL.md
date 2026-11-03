---
name: audit-cost
description: Read-only DEEP, per-resource cloud cost audit across AWS, GCP, Azure, Kubernetes, Datadog, and DigitalOcean; queries each provider's own cost-recommendation surfaces live (AWS Compute Optimizer / Cost Explorer / Cost Optimization Hub, GCP Recommender, Azure Cost Management + Advisor, Datadog usage, Kubernetes requests-vs-usage, DigitalOcean billing), ranks opportunities by provider-native dollar savings, and writes a ranked-savings findings.json (scoutflo-cost/v1) + report.md. It never invents a dollar figure and never mutates anything. Use when the user asks for a cost audit, cost optimization, rightsizing, idle/unattached/over-provisioned resources, commitment (RI/SP/CUD) coverage, or "where am I wasting money". Do not use to change resources (each finding is report-only), for reliability/alerting scoring (use audit-aws/audit-gcp/etc), or to re-aggregate prior findings (this queries providers live; prior audit cost findings are cross-reference only).
---

# audit-cost

A dedicated, deep, **per-resource** cost audit. It queries each configured provider's own cost-recommendation and inventory surfaces **live** and reports every opportunity with the concrete resource behind it — which instance, disk, volume, monitor, or workload; its size, region, age, and utilization; and, when the provider itself gives one, the dollar figure copied verbatim. It ranks opportunities by provider-native monthly savings and writes both a machine-readable `findings.json` (schema `scoutflo-cost/v1`) and a human `report.md` that leads with the savings summary.

**This is not the old cost-analysis.** It does its own live analysis; it does not re-aggregate other audits' findings. Prior audit cost findings and `correlation.json` are used only to cross-reference and de-duplicate, never as the source of truth.

**Two hard guarantees.** (1) Strictly read-only — every command is a `list`/`describe`/`get`; the forbidden-command lists in each provider reference name what is never run. (2) **Never invents a dollar figure** — `estimated_monthly_savings_usd` appears only when copied verbatim from a provider-native recommendation API; everything else is a presence fact reported with no number. An unverified number is worse than no number because it lands in a budget conversation.

## Why it is not scored 0–100

A cost report ranks opportunities by dollars; it is deliberately **not** folded into a 0–100 health score. Mixing a dollar-savings axis into a reliability score creates a perverse incentive: an idle standby replica is "waste" by a cost lens and "correct" by a reliability lens, so one score would reward the wrong fix. This is the same "parallel non-scored section" rule the toolkit already uses for Cost & Resource Optimization inside `audit-aws` and for Topology Readiness. So this skill emits `scoutflo-cost/v1` (a ranked-savings schema with no `score` object), and its report is validated by [`check-cost.sh`](../../report-standard/check-cost.sh), never `check-report.sh`.

## Target profile

This audit has no 100/100 score and awards no recoverable readiness points. Its
benchmark is an auditable cost decision across these dimensions:

| Dimension | Target state | Evidence required |
| --- | --- | --- |
| Scope and coverage | Every selected provider/target is assessed or explicitly excluded | Config-bound identities, sizing evidence, completed/blocked worklist rows |
| Spend context | Savings have an actual same-scope spend denominator | Billing amount, currency, period and source; unknown is null |
| Opportunity quality | Every opportunity names resources and a measured signal | Live inventory/metrics and provider recommendation; declared intent retained |
| Money integrity | Native savings and indicative estimates stay separate | Verbatim native amount/source; arithmetic reconciles without double counting |
| Unassessed spend | Billed resources with no checks stay visible | Targets, billed amount/currency and why assessment failed, or explicit unknown |
| Unit economics | Only declared units with aligned, auditable inputs | Both periods' spend/volume, sources, basis, quotients and trend; otherwise exclusion |

- ❌ Treat an unavailable billing export as zero spend and announce complete savings coverage.
- ✅ Keep spend and percentage null, name the missing export, and report verified opportunities with their limits.

## Outputs

- `./scoutflo-audits/cost/<YYYY-MM-DD>/findings.json` — or `cost/<target>/<YYYY-MM-DD>/` when `SCOUTFLO_TARGET` selects one of several configured targets — per the [cost schema](../../report-standard/cost-schema.md) (`scoutflo-cost/v1`), finding IDs `COST-<PROV>-NNN`.
- `./scoutflo-audits/cost/<YYYY-MM-DD>/report.md` (same per-target nesting) — leads with the savings summary line, then per-provider ranked tables, then top-opportunity detail.
- `target` in `findings.json` stays the literal string **`cost`**, even for a per-target run. `audit-all` skips the cost lane by `.target == "cost"`; setting it to the selected label would leak non-scored cost findings into the reliability roll-up. The target lives in the output path, not in that field.
- One history line appended to `$(dirname "$OUT")/history.jsonl` — i.e. `cost/history.jsonl`, or `cost/<target>/history.jsonl` when a target is selected (date, opportunity counts, native monthly savings identified). **It nests with the findings on purpose:** a flat ledger replaces the line for the same date, so six targets audited today would leave one line and silently lose five targets' totals.

## Doctor gate

This audit reads cost-recommendation and inventory surfaces for every **configured** provider. A missing cost scope for a provider **excludes that provider's native-dollar checks with the reason**, and never fails the whole run — the presence-fact checks that need only plain list permissions still run. It stops only when no configured provider can be reached at all.

| Provider | Config keys | Cost scope needed (native-dollar checks) | Presence-fact checks need |
| --- | --- | --- | --- |
| AWS | `aws.profile`/chain, `aws.region`, `aws.cost_checks` | Compute Optimizer / Cost Explorer / Cost Optimization Hub / Trusted Advisor read | `ec2/elbv2/s3/rds Describe*`/`List*` |
| GCP | `gcp.project`, `gcp.credentials_env`, `gcp.cost_checks`, `gcp.billing_bq_dataset`, `gcp.billing_project` (optional; the project hosting the export dataset when it is not `gcp.project`) | Recommender viewer (`roles/recommender.*Viewer`) + Recommender API enabled. For net spend and GKE per-namespace cost: the Cloud Billing BigQuery export (detailed flavour) + `roles/bigquery.jobUser`/`dataViewer` + the `bq` CLI | `compute.*.list` |
| Azure | `azure.subscription_id`, `azure.cost_checks` | Cost Management Query (`Cost Management Reader`) + Advisor (`Reader`) — REST `2023-11-01`, 429-backoff (no `az costmanagement query` CLI) | Resource Graph + `az … list/show` |
| Datadog | `datadog.*`, `datadog.cost_checks` | `usage_read`/`billing_read` | (usage API only; no cheaper fallback) |
| Kubernetes | `kubernetes.context`, `kubernetes.prometheus_url`, `kubernetes.cost_integration_url` | windowed metrics, in order: `prometheus_url` → **Cloud Monitoring on GKE** (already covered by `roles/monitoring.viewer`, nothing to install) → metrics-server `kubectl top` (a labelled snapshot). Cost source, in order: **the GCP billing export** (COST-GCP-024) → an existing Kubecost/OpenCost endpoint | `get` on workloads/PVCs/PVs |
| DigitalOcean | `digitalocean.*` | (none — billing/list only) | `doctl ... list` / monitoring read |
| SigNoz | `signoz.*` (host/org/token or ClickHouse read user) | Cost Meter (`signoz.meter.*`, `source:meter`) read; falls back to metrics-store reads | `POST /api/v3/query_range` / `SELECT` on the metrics store |
| New Relic | `newrelic.*` (account, User key, region) | `NrConsumption` (billed GB; ~daily lag) with `bytecountestimate()` as the live fallback | NerdGraph NRQL reads (query documents only) |

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
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
command -v jq >/dev/null || { echo "missing binary: jq"; exit 1; }
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"
[ -f "$MATRIX" ] || { echo "no doctor matrix for today; run /scoutflo:doctor first"; exit 1; }
# A provider participates only if it is reachable at all; its cost-permissions row
# decides native-dollar vs presence-fact-only. Read the rows, never guess.
awk -F'\t' '$2=="reachable" || $2=="cost-permissions" {print $1, $2, $5, $7}' "$MATRIX"
echo "doctor gate: pass (per-provider cost scope resolved from the matrix above)"
```

## Live-safety gate

Resolve the same config and target used by the provider lane. This block displays the
**configured** scope; it performs no ambient-account probes and does not claim a pass.
Before collecting inventory, run that provider reference's independent identity preamble:
AWS STS with the selected profile/region (compare `account_id` when pinned), GCP's
selected project and authenticated identity, Azure's explicit subscription, or the
configured Kubernetes context. A mismatch or failed identity read stops that provider;
it is never an empty estate. Confirm the displayed scope before the first provider read.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh"
select_target() {
  COST_PROVIDER="$1"; COST_KIND=$(sh "$TT" "$CFG" "$1" kind); COST_N=$(sh "$TT" "$CFG" "$1" count)
  COST_IDX=0
  [ "$COST_N" -gt 0 ] || return 1
  if [ "$COST_KIND" = seq ]; then
    COST_IDX=""; _i=0
    while [ "$_i" -lt "$COST_N" ]; do
      [ "$(sh "$TT" "$CFG" "$1" label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && COST_IDX=$_i
      _i=$((_i+1))
    done
    [ -n "$COST_IDX" ] || { echo "select $1 with SCOUTFLO_TARGET; labels: $(sh "$TT" "$CFG" "$1" labels | tr '\n' ' ')" >&2; exit 1; }
  fi
  COST_LABEL=$(sh "$TT" "$CFG" "$1" label "$COST_IDX")
}
for provider in aws gcp azure kubernetes datadog digitalocean signoz newrelic; do
  if select_target "$provider"; then
    case "$provider" in
      aws) keys="profile region account_id" ;;
      gcp) keys="project billing_project" ;;
      azure) keys="subscription_id" ;;
      kubernetes) keys="context" ;;
      datadog) keys="site" ;;
      digitalocean) keys="team" ;;
      signoz) keys="url" ;;
      newrelic) keys="account_id region" ;;
    esac
    printf 'configured %s target=%s' "$provider" "$COST_LABEL"
    for key in $keys; do
      value=$(sh "$TT" "$CFG" "$provider" get "$COST_IDX" "$key")
      [ -z "$value" ] || printf ' %s=%s' "$key" "$value"
    done
    printf '\n'
  fi
done
echo "Scope resolved from config; verify each provider identity before its reads. No live-safety pass is claimed by this display."
```

## Ground rules

- **Live query, not recall.** Every finding comes from a call made this run. Prior `findings.json` cost sections and `correlation.json` are read only to annotate overlaps (`deduplicated: true`) — they are never the source of a finding.
- **Never invent a number.** `estimated_monthly_savings_usd` is copied verbatim from a provider-native recommendation response, or the field is `null`. No price-table math, ever. (The one hard rule, in every provider reference.)
- **Per-resource or it doesn't ship.** Every finding names the concrete resource(s) in `affected` — id, region/zone, size, age, utilization. "The account has waste" is not a finding.
- **Read-only by effect.** Not just read-only verbs: `gcloud recommender ... mark-*` and `aws ce ...` write operations are forbidden even though they look like reads. Each reference has a forbidden-command list.
- **Honest denominators.** A provider whose cost scope is missing is recorded in `providers_excluded` with its reason, never silently dropped and never scored as zero savings.
- **Never print or write a secret value.** Webhook URLs, API tokens, bearer/auth headers, cloud keys, and connection strings are captured by key name or type only, never by value — not into the terminal, evidence, `findings.json`, `report.md`, or a Slack brief. Follow the shared [secret-redaction discipline](../../report-standard/secret-redaction.md); the redaction filter (`skills/redaction/lib/redaction.sh`, `redact_file`) masks any residual secret in a written artifact as defense-in-depth.

## The change-risk classes

| Class | In this skill |
| --- | --- |
| Read-only | everything here — list/describe/get on cost and inventory surfaces |
| Out of scope | any resize, delete, stop, terminate, `mark-*`, lifecycle change. Cost fixes are materially riskier than reliability fixes (deleting live infra to save money), so this skill **reports** the opportunity and never proposes or performs the change. |

## Estate sizing and the interactive scope checkpoint

Before deep checks, run the cheap inventory collection in
[references/estate-scope.md](references/estate-scope.md#collect-sizing-evidence).
It writes resource IDs and explicit unknown surfaces to `cost/<target>/sizing.json`.
No request denial, incomplete list, or unavailable count becomes zero. The known count
is a lower bound; any unknown surface requires a scope decision even below the threshold.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh"
SIZE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}/sizing.json"
[ -f "$SIZE" ] || { echo "missing sizing evidence; run estate-scope.md collection before deep checks"; exit 1; }
jq -e '(.objects | type == "array") and (.unknown | type == "array")' "$SIZE" >/dev/null
jq -e --arg config "$CFG" --arg fingerprint "$(cksum < "$CFG")" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected' "$SIZE" >/dev/null || { echo "sizing config changed; recollect it"; exit 1; }
TOTAL=$(jq '.objects | length' "$SIZE")
UNKNOWN=$(jq '.unknown | length' "$SIZE")
SMALL_MAX=100; MEDIUM_MAX=500; LARGE_MAX=2000  # examples; tune to your estate
PATH_SIZE=small
[ "$TOTAL" -le "$SMALL_MAX" ] || PATH_SIZE=medium
[ "$TOTAL" -le "$MEDIUM_MAX" ] || PATH_SIZE=large
[ "$TOTAL" -le "$LARGE_MAX" ] || PATH_SIZE=xlarge
[ "$UNKNOWN" -eq 0 ] || PATH_SIZE=large
echo "estate: cost-bearing objects=${TOTAL} unknown-surfaces=${UNKNOWN} path=${PATH_SIZE}"
if [ "${TOTAL}" -ge 501 ] || [ "$UNKNOWN" -gt 0 ]; then
  jq -r '.unknown[] | "size unknown: \(.provider) / \(.surface): \(.reason)"' "$SIZE"
  # The shared pause helper returns immediately below 1000, so explicitly confirm
  # 501-999 objects and unknown counts through its companion function.
  if [ "$TOTAL" -ge 1000 ]; then cli_pause_before_audit "${TOTAL}"
  else cli_confirm_proceed "Cost audit has ${TOTAL} known objects and ${UNKNOWN} unknown surfaces; continue with a bounded scope?"; fi
  echo "Record the approved providers/regions/classes in the large-run scope file before deep reads. No shared topology file was changed."
fi
```

Small (≤100) and medium (101–500) estates with complete sizing run in one pass.
Large/xlarge or unknown-size scopes use the
[durable worklist](references/estate-scope.md#large-path-worklist-and-resume): one
provider/target/resource row, fixed run ID, atomic batch lock, and persisted batch evidence.
Before creating a run, offer any matching unfinished run for resume. A row becomes `done`
only after its reads and written evidence succeed; a terminal failure becomes `blocked`
with a reason and remains disclosed. Pending rows prevent replacing the last complete
report. Scope exclusions are recorded before omitting rows, never silently truncated.

- ❌ A failed VM list contributes zero, so the audit declares a small estate and starts every deep check.
- ✅ The failed list is an unknown surface; the audit asks for scope and keeps its spend unassessed.

## Phase 1: Load context and prior-run cross-reference

Read `~/.scoutflo/topology.json` `business_context` (environment, cost_sensitivity, critical_dependencies) and any saved `audit_scope`. Read the previous run's `findings.json` **from this target's own directory** (`$(dirname "$OUT")/<previous-date>/findings.json`) — under per-target nesting a flat `cost/<date>/` path finds nothing for a selected target, silently losing the trend and dedup seed. Read `./scoutflo-audits/correlation.json` if present — these seed the `deduplicated` annotation and the trend, and nothing else. If none exist, proceed with safe defaults (production / medium sensitivity); state it.

## Phase 2: Per-provider deep cost checks

For each **configured and in-scope** provider, run its catalog. Each reference is the runnable, read-only command set with per-resource output shape, the native-dollar-vs-presence-fact split, and the forbidden-command list:

| Provider | Reference | ID prefix |
| --- | --- | --- |
| AWS | [references/aws-cost.md](references/aws-cost.md) | `COST-AWS-NNN` |
| GCP | [references/gcp-cost.md](references/gcp-cost.md) | `COST-GCP-NNN` |
| Azure | [references/azure-cost.md](references/azure-cost.md) | `COST-AZ-NNN` |
| Kubernetes | [references/kubernetes-cost.md](references/kubernetes-cost.md) | `COST-K8S-NNN` |
| Datadog | [references/datadog-cost.md](references/datadog-cost.md) | `COST-DD-NNN` |
| DigitalOcean | [references/digitalocean-cost.md](references/digitalocean-cost.md) | `COST-DO-NNN` |
| SigNoz | [references/signoz-cost.md](references/signoz-cost.md) | `COST-SIG-NNN` |
| New Relic | [references/newrelic-cost.md](references/newrelic-cost.md) | `COST-NR-NNN` |
| **(all providers)** | [references/unit-economics.md](references/unit-economics.md) — **run last**, after every provider lane, because it divides their spend by a business volume | `COST-UNIT-NNN` |

For each opportunity, build a finding: the concrete resource(s) in `affected`; `estimated_monthly_savings_usd` **only** when the provider gave one (with `savings_source` naming the API); `utilization` backing rightsizing/idle calls; evidence = the real command + its trimmed output. A provider whose cost scope was missing is added to `providers_excluded` with the doctor's reason; its presence-fact checks still run if plain list permissions exist.

## Phase 3: Cross-reference and de-duplicate

If `correlation.json` exists, annotate any finding whose resource overlaps a prior audit's cost finding with `deduplicated: true` and a one-line reason. This informs the reader; it never removes a finding and never changes a dollar figure.

## Phase 4: Rank, write findings.json, render report.md

Rank findings native-figure-first (descending `estimated_monthly_savings_usd`), then indicative-figure findings, then presence facts. Build the summary: `opportunities_total`, the native-vs-presence split as **separate** counts, `monthly_savings_identified_usd` = the sum of only the native figures, `annual = monthly * 12`, and `largest_single_lever`. Write `findings.json` (`scoutflo-cost/v1`), then render `report.md` per the [report template](../../report-standard/report-template.md)'s cost/savings rule: **savings summary line first**, then per-provider ranked tables (resource, region, signal, `$X/mo` or `—`), then top opportunities as What / Where / Why / How / Done-when, then the evidence appendix.

**Three numbers that must appear together, or the headline misleads.** A savings figure with no
denominator cannot be judged, and a clean-looking report over partly-unmeasured spend is the single
most expensive way to be wrong:

- `observed_monthly_spend` — actual spend for the audited scope, from the billing export. Without
  it, say so; never present savings as if the bill were unknown by choice.
- `savings_pct_of_spend` — the savings as a percentage of that spend. Two separate numbers do not
  tell a reader whether this found 2% or 40% of the bill; one number does. A low percentage over a
  large bill is itself the finding: it means the priced levers are the floor and the unpriced
  categories are where the money is.
- `unassessed_monthly_spend` — spend that billed while **no check ran against it** (COST-GCP-034,
  plus any target marked `assessable:false` such as an unreachable cluster). Report it beside the
  savings, never only in an appendix, so a clean result is never mistaken for a clean estate.

Render the **indicative** total in its own line and its own column, labelled "indicative, list
price, before your discounts", and never add it to the savings total — `check-cost.sh` rejects a
report that does. Every finding carrying a measured ratio states its `basis` (`p95 over 7d`,
`max over 7d`, `snapshot <ts>`), and a single finding never mixes a window with a snapshot: split
them, so a point-in-time reading is never read as a sustained trend.

```bash
set -eu
# Nest per target when one was selected. The GCP lane now STOPS on a multi-project
# `gcp:` list unless SCOUTFLO_TARGET names which project to cost, so a multi-project
# estate necessarily runs this skill once per target — and a flat `cost/<date>/`
# would make the second run of the day silently OVERWRITE the first, losing a whole
# project's findings with no error. Same `<integration>/<label>/<date>` shape every
# own-block audit uses. A single-target estate is unchanged.
COST_SEG="cost${SCOUTFLO_TARGET:+/${SCOUTFLO_TARGET}}"
# Recover the persisted run in a fresh shell; an unset COST_RUN_DIR never skips the gate.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "cost configuration is missing"; exit 1; }
case "${SCOUTFLO_TARGET:-}" in .|..|*[!a-zA-Z0-9._-]*) echo "invalid cost target label"; exit 1;; esac
BASE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}"
[ -d "$BASE" ] || { echo "collect sizing evidence before publication"; exit 1; }
BASE=$(CDPATH= cd -- "$BASE" && pwd -P)
SIZE="$BASE/sizing.json"; FINGERPRINT=$(cksum < "$CFG")
jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected and (.objects|type=="array") and (.unknown|type=="array")' "$SIZE" >/dev/null || { echo "sizing belongs to another config or target; recollect it"; exit 1; }
# Even a missing pointer or newly smaller census cannot hide unfinished work.
for saved in "$BASE"/runs/*; do
  [ ! -f "$saved/worklist.tsv" ] || {
    [ ! -d "$saved/worklist.lock" ] || { echo "cost batch is still locked; finish it first"; exit 1; }
    awk -F'\t' '$2 != "done" && $2 != "blocked" && $2 != "excluded" {bad=1} END {exit bad}' "$saved/worklist.tsv" || { echo "cost work remains pending; keep partial evidence in the run directory"; exit 1; }
  }
done
COST_RUN_ID="${COST_RUN_ID:-}"
[ -n "$COST_RUN_ID" ] || { [ ! -f "$BASE/active-run" ] || COST_RUN_ID=$(cat "$BASE/active-run"); }
COST_DATE="$(date -u +%Y-%m-%d)"
if [ -n "$COST_RUN_ID" ]; then
  case "$COST_RUN_ID" in *[!0-9TZ]*) echo "invalid cost run ID"; exit 1;; esac
  EXPECTED_RUN="$BASE/runs/$COST_RUN_ID"
  [ -d "$EXPECTED_RUN" ] || { echo "selected cost run is missing"; exit 1; }
  EXPECTED_RUN=$(CDPATH= cd -- "$EXPECTED_RUN" && pwd -P)
  [ "$EXPECTED_RUN" = "$BASE/runs/$COST_RUN_ID" ] || { echo "cost run escapes its target directory"; exit 1; }
  if [ -n "${COST_RUN_DIR:-}" ]; then
    GIVEN_RUN=$(CDPATH= cd -- "$COST_RUN_DIR" && pwd -P) || exit 1
    [ "$GIVEN_RUN" = "$EXPECTED_RUN" ] || { echo "cost run directory belongs to another selected run or target"; exit 1; }
  fi
  COST_RUN_DIR="$EXPECTED_RUN"
  [ -f "$COST_RUN_DIR/worklist.tsv" ] || { echo "missing cost worklist"; exit 1; }
  [ "$(cat "$COST_RUN_DIR/config-fingerprint")" = "$FINGERPRINT" ] || { echo "run config changed; do not mix evidence"; exit 1; }
  jq -e --arg config "$CFG" --arg fingerprint "$FINGERPRINT" --arg selected "${SCOUTFLO_TARGET:-}" '.config==$config and .config_fingerprint==$fingerprint and .selected_target==$selected' "$COST_RUN_DIR/sizing.json" >/dev/null || { echo "run belongs to another config or target; do not mix evidence"; exit 1; }
  jq -e '.approved==true and (.included|type=="array" and length>0) and (.excluded|type=="array")' "$COST_RUN_DIR/scope.json" >/dev/null || { echo "cost scope was not approved"; exit 1; }
  COST_DATE=$(cat "$COST_RUN_DIR/report-date")
else
  [ -z "${COST_RUN_DIR:-}" ] || { echo "select the bound COST_RUN_ID instead of supplying an arbitrary directory"; exit 1; }
  jq -e '(.objects|length)<=500 and (.unknown|length)==0' "$SIZE" >/dev/null || { echo "large or unknown scope requires a bound cost worklist before publication"; exit 1; }
fi
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${COST_SEG}/${COST_DATE}"
mkdir -p "$OUT"
# Write findings.json (scoutflo-cost/v1) and report.md from the collected evidence, then verify:
jq -e '.schema=="scoutflo-cost/v1" and (.findings|type=="array") and .summary' "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Money-integrity + schema gate (NOT check-report.sh — this is a ranked-savings report):
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-cost.sh" "$OUT/findings.json"
# Retain the run evidence, but do not select this completed run for the next audit.
if [ -n "${COST_RUN_ID:-}" ] && [ -f "$BASE/active-run" ] && [ "$(cat "$BASE/active-run")" = "$COST_RUN_ID" ]; then
  rm "$BASE/active-run"
fi
```

Append one line to `$(dirname "$OUT")/history.jsonl` (date, `opportunities_total`, `monthly_savings_identified_usd`), replacing any line for the same date **within that target's ledger**. Never a single flat `cost/history.jsonl` across targets: same-date replacement would keep only the last target audited and drop the rest without an error.

## Phase 5: Run-completion message

Close with: the savings headline (`Potential savings ~$X/mo (~$Y/yr) across N priced + M presence-fact opportunities`), the single biggest lever, the **absolute** report path, and the OS open command. Then the leak-safe Slack brief if configured (titles + totals only, never a resource id or dollar-bearing evidence line). If the whole run was gated out, there is no completion message — the gate's guidance stands.

## Metadata Load (v0.1.68+)

When the business-context SSOT projection `~/.scoutflo/business_context.json` names `critical_dependencies` and `cost_sensitivity`, use them to order the report: on `cost_sensitivity: high`, lead with the highest annual-savings opportunities; mark opportunities on critical-dependency resources so a reader sees the reliability trade-off before acting. Metadata never changes a dollar figure or invents one.

The same projection also carries **`unit_metrics`** — the customer's declared unit of delivered
value and the query that measures it. When present, run [references/unit-economics.md](references/unit-economics.md)
**after every provider lane** and render its block **above** the ranked savings, because cost per
unit frames every number below it: a bill up 12% against volume up 20% is efficiency *improving*,
and reporting the 12% alone mislabels a win as a problem. A unit of value is a product fact, so it
is **declared, never inferred** — with none declared, emit `COST-UNIT-004`, report per-namespace and
per-project spend instead, and ask the one question that enables it next run.

The projection also carries **`resource_intent`** — the customer's declared reason a resource is
*meant* to look idle (`standby`, `dr`, `backup`, `pre-scaled`, `accepted-tradeoff`). A warm standby
sized for failover is indistinguishable from gross over-provisioning by every signal this skill can
read: low CPU, low request rate, large instance. Intent is the only thing that separates them, and
it is **declared, never inferred** — a name containing `standby`, a tag asserting it, a low request
rate, or a plausible architectural guess are each worth *mentioning* and none is a licence to
downgrade. With no declaration the opportunity stands, because wrongly reporting an intentional
standby costs one correction while wrongly silencing a forgotten resource costs the customer money
every month.

When a declaration **does** match, **annotate and downgrade — never disappear the row**:

- Keep the resource, its utilisation, and its spend visible; quote the customer's own `why` beside
  it ("754 cores at 3% CPU — declared warm standby for the primary region").
- Drop any `estimated_monthly_savings_usd` and `indicative_monthly_usd` to `null` and remove it from
  the ranked savings total — a declared standby is not a saving, so counting it would inflate the
  headline with money the customer has already decided to spend.
- Say so in the summary's context tables, not as a finding. A declared-intent resource is reported
  for *awareness*, exactly like an `assessable:false` one.
- A standby that has drifted well past the capacity its stated purpose needs is still worth saying
  out loud, as an observation with no dollar figure: the declaration silences the verdict, not the
  fact.
- When `review_by` has passed, ask the customer to re-confirm rather than staying silent forever —
  an intent declared two years ago is a fact about a plan that may no longer exist.

For the scored own-block audits the same declaration feeds the `not-in-scope` /
`by-design` verdict defined in
[not-in-scope-reasons.md](../../report-standard/not-in-scope-reasons.md); here, where every
finding is already non-scored, it changes the dollar figure and the annotation instead.

**Deliberate exemption — exclusions are advisory here, not scope-limiting.** Unlike the scored own-block audits (which drop `exclusions`-matched resources as `not-in-scope`), `audit-cost` is a ranked-savings, report-only skill: it still surfaces a savings opportunity on an excluded/vendor-managed resource, but annotates it with the exclusion so the reader knows the resource is out of the operational audit's scope. This keeps a real, large saving from being silently hidden by an exclusion that exists for a different (reliability/compliance) reason. If you want an excluded resource omitted entirely, exclude it at the provider query, not via `business_context.json`.

## Remediation pointers

Every finding is report-only (cost changes are out of scope for automation here — resizing/deleting live infra is materially riskier than a reliability fix). The `recommendation` states the concrete action and the console/CLI path; it does not point at a `setup-*` write. Where a provider's own reference documents the safe manual procedure, cite it.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Re-aggregating prior findings instead of querying live (the old cost-analysis bug) | Phase 2 queries each provider's live cost surface; prior findings are cross-reference only (Phase 3) |
| Inventing a dollar figure from price-table math | `estimated_monthly_savings_usd` is copied verbatim from a provider API or is `null`; `check-cost.sh` fails a total that doesn't sum only native figures |
| Generic "the account has waste" with no resource | Every finding names the concrete resource in `affected`; `check-cost.sh` rejects an empty `affected` |
| Unbounded grind over a huge estate with no scoping question | Estate sizing pauses on large/xlarge and offers scope choices via cli-interactive + checkpoint, saved to topology.json |
| GCP recommender missed in most zones | The GCP reference loops every active zone/region (the per-location gotcha); judging from one location is a false pass |
| A missing cost scope silently zeroing a provider | The provider is recorded in `providers_excluded` with the doctor's reason; presence-fact checks still run where list permissions exist |
| Running check-report.sh on this report | This is a ranked-savings report (no 0–100 score); it is validated by check-cost.sh, not check-report.sh |

## Maturity note (v0.1.79)

The **AWS** cost phase is proven live end to end: a real run against a live account produced a validated `scoutflo-cost/v1` `findings.json` + ranked `report.md` (unattached EBS with per-volume ages, 117 no-lifecycle S3 buckets, 0% RI/SP commitment coverage from Cost Explorer, gp2→gp3 candidates) and correctly reported **zero native-dollar figures** because Compute Optimizer was not enrolled — the honest presence-fact path, no invented number. The **GCP** phase is authored and wired but its live proof is pending a credential-identity check (the run must confirm the intended principal before reading). The **Azure** phase is authored and wired, and its cost READ PATHS were confirmed live (Cost Management Query REST `2023-11-01` responded — throttled 429, endpoint+version valid — and Resource Graph `2022-10-01` returned records), but a full ranked-savings `findings.json` run against a real Azure estate is **not yet proven end to end**. **Kubernetes, Datadog, and DigitalOcean** are authored to the same contract and reference depth but **not yet proven live end to end** — built one at a time with proof, per the toolkit's build-with-evidence rule. Every phase carries no invented number by construction, so all are safe to run; treat GCP/K8s/DD/DO output as authored-not-yet-live-verified until this note is updated.

---

**v0.1.79** — New first-class deep cost audit; replaces the thin re-aggregator `cost-analysis` (kept as a deprecation pointer). Ranked-savings (`scoutflo-cost/v1`), per-resource, provider-native dollars only, interactive scope checkpoint on large estates.
