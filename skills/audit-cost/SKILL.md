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

## Outputs

- `./scoutflo-audits/cost/<YYYY-MM-DD>/findings.json` per the [cost schema](../../report-standard/cost-schema.md) (`scoutflo-cost/v1`), finding IDs `COST-<PROV>-NNN`.
- `./scoutflo-audits/cost/<YYYY-MM-DD>/report.md` — leads with the savings summary line, then per-provider ranked tables, then top-opportunity detail.
- One history line appended to `./scoutflo-audits/cost/history.jsonl` (date, opportunity counts, native monthly savings identified).

## Doctor gate

This audit reads cost-recommendation and inventory surfaces for every **configured** provider. A missing cost scope for a provider **excludes that provider's native-dollar checks with the reason**, and never fails the whole run — the presence-fact checks that need only plain list permissions still run. It stops only when no configured provider can be reached at all.

| Provider | Config keys | Cost scope needed (native-dollar checks) | Presence-fact checks need |
| --- | --- | --- | --- |
| AWS | `aws.profile`/chain, `aws.region`, `aws.cost_checks` | Compute Optimizer / Cost Explorer / Cost Optimization Hub / Trusted Advisor read | `ec2/elbv2/s3/rds Describe*`/`List*` |
| GCP | `gcp.project`, `gcp.credentials_env`, `gcp.cost_checks` | Recommender viewer (`roles/recommender.*Viewer`) + Recommender API enabled | `compute.*.list` |
| Azure | `azure.subscription_id`, `azure.cost_checks` | Cost Management Query (`Cost Management Reader`) + Advisor (`Reader`) — REST `2023-11-01`, 429-backoff (no `az costmanagement query` CLI) | Resource Graph + `az … list/show` |
| Datadog | `datadog.*`, `datadog.cost_checks` | `usage_read`/`billing_read` | (usage API only; no cheaper fallback) |
| Kubernetes | `kubernetes.context` | metrics source: metrics-server (`kubectl top`) or Prometheus | `get` on workloads/PVCs/PVs |
| DigitalOcean | `digitalocean.*` | (none — billing/list only) | `doctl ... list` / monitoring read |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-$HOME/.scoutflo/toolkit.yaml}"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
[ -f "$HOME/.scoutflo/env" ] && . "$HOME/.scoutflo/env" || true
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

Print every target this run will read from, and confirm before the first call. This audit is read-only, but reading the wrong account is still a boundary violation.

```bash
set -eu
# For each configured provider, print the exact identity this run will use.
# AWS: sts identity + region. GCP: project + active account. Azure: subscription/tenant/user. K8s: context + server. DO: account. Datadog: site.
# (Each provider block in references/<prov>-cost.md prints its own identity preamble; this gate is the summary.)
echo "audit-cost will READ the following targets (nothing is modified):"
# AWS
if command -v aws >/dev/null; then aws sts get-caller-identity --output text --query '[Account,Arn]' 2>/dev/null | sed 's/^/  aws: /' || true; fi
# GCP
if command -v gcloud >/dev/null; then gcloud config get-value project 2>/dev/null | sed 's/^/  gcp project: /' || true; fi
# Azure
if command -v az >/dev/null; then az account show --query '{sub:id,tenant:tenantId,user:user.name}' -o tsv 2>/dev/null | sed 's/^/  azure: /' || true; fi
echo "live-safety gate: pass — confirm these are the accounts you intend to audit for cost"
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

Cost surfaces scale with resource count, and a large multi-account/multi-region estate can be thousands of objects. Before spending tokens, size the estate cheaply and **pause to let the user scope** — the checkpoint the toolkit's `checkpoint` skill and `cli-interactive` library provide. This is mandatory, not optional: an unbounded grind over 4,000 objects with no scoping question is a bug.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
# Cheap count per configured provider (list-only, no per-resource pulls yet).
# Example for AWS+GCP; extend per configured provider. These are the SAME cheap
# list calls the per-provider references open with.
TOTAL=0
# ... sum cheap list counts per provider into TOTAL (see each reference's sizing note) ...

# Sizing paths (shared toolkit thresholds):
#   small   (<= 100 objects): one pass, no checkpoint needed
#   medium  (101–500):        one pass, print scope, proceed
#   large   (501–2000):       PAUSE — offer scope choices, save to topology.json
#   xlarge  (> 2000):         PAUSE — scope selection REQUIRED before proceeding
echo "estate: cost-bearing objects=${TOTAL}"

# Interactive checkpoint on large/xlarge — offer: (a) audit everything (batched),
# (b) scope by provider/region/service, (c) exclude noisy classes. Persist the
# choice to ~/.scoutflo/topology.json audit_scope for reuse (see /scoutflo:checkpoint).
if [ "${TOTAL}" -ge 501 ]; then
  cli_pause_before_audit "${TOTAL}"          # confirm before a large run
  cli_prompt_exclude_services                # offer scope/exclusions, persist to topology.json
  echo "[checkpoint] scope saved to ~/.scoutflo/topology.json (reused on the next run; /scoutflo:checkpoint --reset-scope to clear)"
fi
```

On the large/xlarge path, per-provider phases run against the **scoped** set in bounded batches (process one region/namespace/product-line group at a time rather than the whole estate at once). Never silently truncate: the report names any provider or region the user scoped out, and the summary reflects it.

## Phase 1: Load context and prior-run cross-reference

Read `~/.scoutflo/topology.json` `business_context` (environment, cost_sensitivity, critical_dependencies) and any saved `audit_scope`. Read the previous `cost/<date>/findings.json` and `scoutflo-audits/correlation.json` if present — these seed the `deduplicated` annotation and the trend, and nothing else. If none exist, proceed with safe defaults (production / medium sensitivity); state it.

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

For each opportunity, build a finding: the concrete resource(s) in `affected`; `estimated_monthly_savings_usd` **only** when the provider gave one (with `savings_source` naming the API); `utilization` backing rightsizing/idle calls; evidence = the real command + its trimmed output. A provider whose cost scope was missing is added to `providers_excluded` with the doctor's reason; its presence-fact checks still run if plain list permissions exist.

## Phase 3: Cross-reference and de-duplicate

If `correlation.json` exists, annotate any finding whose resource overlaps a prior audit's cost finding with `deduplicated: true` and a one-line reason. This informs the reader; it never removes a finding and never changes a dollar figure.

## Phase 4: Rank, write findings.json, render report.md

Rank findings native-figure-first (descending `estimated_monthly_savings_usd`), then presence facts. Build the summary: `opportunities_total`, the native-vs-presence split as **separate** counts, `monthly_savings_identified_usd` = the sum of only the native figures, `annual = monthly * 12`, and `largest_single_lever`. Write `findings.json` (`scoutflo-cost/v1`), then render `report.md` per the [report template](../../report-standard/report-template.md)'s cost/savings rule: **savings summary line first**, then per-provider ranked tables (resource, region, signal, `$X/mo` or `—`), then top opportunities as What / Where / Why / How / Done-when, then the evidence appendix.

```bash
set -eu
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/cost/$(date -u +%Y-%m-%d)"
mkdir -p "$OUT"
# ... write findings.json (scoutflo-cost/v1) and report.md per the standard, then verify:
jq -e '.schema=="scoutflo-cost/v1" and (.findings|type=="array") and .summary' "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Money-integrity + schema gate (NOT check-report.sh — this is a ranked-savings report):
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-cost.sh" "$OUT/findings.json"
```

Append one line to `cost/history.jsonl` (date, `opportunities_total`, `monthly_savings_identified_usd`), replacing any line for the same date.

## Phase 5: Run-completion message

Close with: the savings headline (`Potential savings ~$X/mo (~$Y/yr) across N priced + M presence-fact opportunities`), the single biggest lever, the **absolute** report path, and the OS open command. Then the leak-safe Slack brief if configured (titles + totals only, never a resource id or dollar-bearing evidence line). If the whole run was gated out, there is no completion message — the gate's guidance stands.

## Metadata Load (v0.1.68+)

When the business-context SSOT projection `~/.scoutflo/business_context.json` names `critical_dependencies` and `cost_sensitivity`, use them to order the report: on `cost_sensitivity: high`, lead with the highest annual-savings opportunities; mark opportunities on critical-dependency resources so a reader sees the reliability trade-off before acting. Metadata never changes a dollar figure or invents one.

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
