# audit-cost (GCP): Deep Per-Resource Cost Check Catalog

Runnable, read-only cost checks for the GCP provider phase of [audit-cost](../SKILL.md). This is a **parallel non-scored section**: every finding here carries `points_recoverable: 0` and `area: cost-optimization`, and none of it enters `score.categories` or `score.excluded` (see [severity-and-scoring.md](../../../report-standard/severity-and-scoring.md#parallel-non-scored-sections)). IDs are `COST-GCP-NNN`, a permanently registered prefix that is distinct from the reliability catalog's `GCP-NNN` in [audit-gcp/references/gcp-checks.md](../../audit-gcp/references/gcp-checks.md), so a reader can tell which axis a finding belongs to at a glance. This is deep, per-resource cost analysis — every finding names a concrete resource (instance, disk, address, snapshot, commitment) with its zone/region, size, age, and utilization — never "the project has waste".

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied verbatim from a GCP-native recommendation: the [Recommender API](https://cloud.google.com/recommender/docs) (`recommender.googleapis.com`) `primaryImpact.costProjection.cost` field. Never recompute a dollar figure from raw metrics (CPU idle percent, disk GB, IP-hours) against a price list you assembled — GCP prices vary by region, commitment, sustained-use discount, and negotiated rate, so any number you derive is a guess. Every other check in this file — aged snapshots, reserved-but-unused static IPs, unattached disks, billing spend context — is a **presence/absence fact** reported with no `estimated_monthly_savings_usd` field. This mirrors the toolkit-wide rule that errors are evidence, never invented; applied to cost, an unverified number is worse than no number, because it gets pasted straight into a budget conversation.

- ❌ `COST-GCP-005: 4 persistent disks unattached for 60+ days totalling 900 GB; at $0.04/GB-month that is roughly $36/mo wasted.`
- ✅ `COST-GCP-005: Recommender (google.compute.disk.IdleResourceRecommender) flags disk 'data-scratch-3' (zone us-central1-a, 200 GB, pd-ssd) as idle; estimated_monthly_savings_usd is 34.00, copied verbatim from primaryImpact.costProjection.cost (units=-34, nanos=0, currencyCode=USD, duration=2592000s).`
- ✅ `COST-GCP-021: 4 reserved static external IPs are in state RESERVED (not IN_USE): 'legacy-nat-ip' (region us-central1), ... . No estimated_monthly_savings_usd — this is a presence fact; the idle-IP dollar figure, when GCP produces one, is reported under COST-GCP-004 from the Recommender.`

### 1b. The third class: an indicative figure, clearly labelled, never in the total

Google prices only a narrow slice of waste. Whole categories it never costs — a managed share
provisioned ten times larger than its use, a premium inference tier where a standard one exists,
objects sitting in the wrong storage class — are where the largest money usually is, and reporting
them with no number at all pushes the arithmetic onto the customer at exactly the moment they are
deciding what to act on.

So there is a **third class**, and it is still sourced: an **indicative** figure, computed from
**Google's own published price for the specific SKU already on the bill**, applied to a quantity
taken from the billing export or a provider API. It is not a market estimate and not a rate you
looked up for a different resource.

The rules are absolute:

- It goes in `indicative_monthly_usd`, **never** `estimated_monthly_savings_usd`, and
  `check-cost.sh` enforces that it is excluded from `summary.monthly_savings_identified_usd`.
- It must name `indicative_source` — the SKU and the published price basis used.
- It is rendered in its own column, labelled **"indicative, list price, before your discounts"**,
  never merged with the Recommender total.
- It is a **ceiling before discounts**, so say so: committed-use, sustained-use and negotiated
  rates all reduce it. Never annualise an indicative figure into a headline.
- Where the shape of the target is a judgement (how much smaller a share should be), report the
  **current billed cost and the observed utilisation** and let the indicative figure describe only
  the step you can price exactly — e.g. one tier down, or one class transition.

The ❌ example above stays forbidden: it has no cited SKU, no published basis, and it was summed
into a savings claim. The distinction is sourcing and labelling, not arithmetic.

- ✅ `COST-GCP-030: Filestore share 'files-prod-1' is tier ENTERPRISE, 2048 GiB provisioned, 7-day max utilisation 0.9%; billed <amount> last month (export). indicative_monthly_usd describes ONE priced step — halving provisioned capacity at the same tier — from the published ENTERPRISE per-GiB-month price (indicative_source names it). Before discounts; the target shape needs the owner's SLA input.`

## 2. Check catalog

One permanent ID per check; IDs never change or get reused. "Savings figure" is either a native Recommender dollar (copied verbatim) or "presence fact" (no dollar).

| ID | Signal | Source API | Savings figure |
| --- | --- | --- | --- |
| COST-GCP-001 | Idle VM instances (stop/delete candidates) | Recommender `google.compute.instance.IdleResourceRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-002 | VM machine-type right-sizing (over/under-provisioned) | Recommender `google.compute.instance.MachineTypeRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-003 | Managed instance group (MIG) right-sizing | Recommender `google.compute.instanceGroupManager.MachineTypeRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-004 | Idle reserved external IP addresses | Recommender `google.compute.address.IdleResourceRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-005 | Idle persistent disks | Recommender `google.compute.disk.IdleResourceRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-006 | Idle custom images | Recommender `google.compute.image.IdleResourceRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-007 | Committed-use discount (CUD) purchase opportunities | Recommender `google.compute.commitment.UsageCommitmentRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-008 | Idle Cloud SQL instances | Recommender `google.cloudsql.instance.IdleRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-009 | Over-provisioned Cloud SQL instances | Recommender `google.cloudsql.instance.OverprovisionedRecommender` | Native — `costProjection.cost`, verbatim |
| COST-GCP-010 | Any other COST-category recommender surfaced in the project (GKE, Cloud Run, BigQuery slots, etc.) | Explicit Recommender sweep (`gcloud recommender recommendations list --recommender=<id>` over the known cost recommenders — there is no `recommenders list` subcommand) | Native — `costProjection.cost`, verbatim |
| COST-GCP-020 | Aged Compute Engine snapshots vs the team's stated retention | Compute `gcloud compute snapshots list` | None (presence fact) |
| COST-GCP-021 | Reserved-but-unused static external IPs | Compute `gcloud compute addresses list` | None (presence fact) |
| COST-GCP-022 | Unattached / detached persistent disks | Compute `gcloud compute disks list` | None (presence fact) |
| COST-GCP-023 | Net spend breakdown by project/service/SKU (context, not savings; `credits` unnested) | Cloud Billing BigQuery export | None (context; actual spend, not a savings figure) |
| COST-GCP-024 | GKE net spend by cluster, namespace and workload (section 10b) | The same Cloud Billing export, detailed resource-level flavour + GKE cost allocation labels | None itself (context) — but it is the **first-party source COST-K8S-008 cites** for a Kubernetes dollar, so no third-party cost tool is required |
| COST-GCP-025 | Object storage whose class and lifecycle do not match its access pattern | `gcloud storage buckets list` (class, lifecycle, versioning, location) + per-bucket spend from the export | **Indicative** — published class-price delta × billed bytes (section 3b); never Recommender |
| COST-GCP-026 | Network shape: service tier, egress mix, Cloud NAT data processing, idle forwarding rules | `gcloud compute project-info describe` / `routers list` / `forwarding-rules list` + Networking SKU spend from the export | **Indicative** for a tier change; presence fact for an idle forwarding rule |
| COST-GCP-027 | Log ingestion and retention beyond the free tier, with no exclusion filters | `gcloud logging sinks list` / `buckets list` + Cloud Logging SKU spend from the export | **Indicative** — published per-GiB ingestion rate × excluded volume |
| COST-GCP-030 | Provisioned-but-unused managed capacity (Filestore and peers): a tier or size far above observed use | `gcloud filestore instances list` + Cloud Monitoring `used_bytes_percent` + per-instance spend from the export | **Indicative** — published tier/size price delta; Google publishes no Filestore cost recommender |
| COST-GCP-031 | A large compute bill with zero commitments **and no CUD recommendation** (autoscaling leaves no floor Google will commit to) | `gcloud compute commitments list` + the Recommender sweep returning nothing + the observed spend floor from the export (section 10h) | **Indicative** — the floor is computed from billed spend, so it is a sourced figure, not a guess |
| COST-GCP-032 | Stopped (TERMINATED) VMs whose disks keep billing | `gcloud compute instances list` + per-disk spend from the export | None (presence fact); the disk's own billed cost is the ceiling |
| COST-GCP-033 | Premium-tier consumption where a standard tier exists — AI/ML inference and similar tiered services | Export SKU-name analysis (tier markers) + per-caller project split | **Indicative** — published tier price delta; the saving is a routing decision, not a resize |
| COST-GCP-034 | Billed projects **outside** the audited config: spend no check ran against | Export `project.id` set minus the configured project set | None — a **coverage** finding: unmeasured spend, reported as such |
| COST-GCP-028 | **Rate versus usage**: when spend moves, whether you used more or paid more per unit | Export `cost` **and** `usage.amount` per SKU across two periods | None — the decomposition *is* the finding; it tells you which lever applies |
| COST-GCP-029 | Spend that **appeared**: new SKUs, new projects, month-over-month jumps with no usage growth | Export period-over-period SKU/project set difference | None (movement fact) — but it is how a surprise is caught in month one instead of month six |
| COST-GCP-035 | Inference billed on-demand where **provisioned throughput** would cost less at the observed steady volume | Export inference SKU volume + the published provisioned-capacity rate | **Indicative** — published rate comparison at the observed floor |
| COST-GCP-036 | **Context caching** not used where prompt prefixes repeat, or cache storage costing more than it saves | Export cached-input vs uncached-input vs cache-storage SKUs | **Indicative** — published cached-vs-uncached input delta |
| COST-GCP-037 | Latency-tolerant inference running **online** where batch bills materially less | Export online-vs-batch SKU split per project | **Indicative** — published online-minus-batch rate delta |
| COST-GCP-038 | **Reasoning/thinking output** spend, the line teams rarely budget for | Export thinking/reasoning output SKUs as a share of total inference | None by itself — a budget-visibility finding; capping is a product decision |
| COST-GCP-039 | A **larger model tier** serving work a smaller tier handles | Export per-model-tier spend + token volume per project | **Indicative** — published per-token delta between tiers, for the one tier step |
| COST-GCP-040 | **Non-production discipline**: round-the-clock nonprod, premium tiers in nonprod, prod-sized nonprod | Export nonprod project spend + nonprod resource shapes vs their prod twins | **Indicative** for a schedule or tier change; presence fact for sizing parity |

## 3. Conventions

- **Identity preamble.** Every block that talks to a Google API declares its own project and mints its own identity, so each block runs alone in a fresh shell and the run holds exactly one identity with no silent fallback:

```bash
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# gcp.credentials_env (optional) names GOOGLE_APPLICATION_CREDENTIALS, the key-file path variable.
# Set: the key file is the identity for gcloud and REST alike. Unset: your active gcloud login is.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1   # MANDATORY — see below; never let gcloud ask a question
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"
else
  TOKEN="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud auth print-access-token)"   # plain gcloud login is the identity
fi
```

**`CLOUDSDK_CORE_DISABLE_PROMPTS=1` is a read-only safety requirement, not a convenience.**
Live-caught: `gcloud filestore instances list` against a project where the Filestore API is
disabled does not simply fail — it prints `API [file.googleapis.com] not enabled on project
[...]. Would you like to enable and retry?` and **waits for input**. In an audit that means one
of two bad outcomes: the run hangs on a prompt nobody sees, or something answers `y` and the
audit **enables a Google API** — a write, performed by a skill that promises to change nothing.
Several APIs behave this way, so set this once in every block's preamble and treat a disabled
API as the exclusion it is. With prompts disabled the same command exits non-zero with
`PERMISSION_DENIED: ... API has not been used in project ... or it is disabled`, which the
`|| echo "... reports excluded ..."` fallback already handles correctly.

The `else` branch matters: without it `TOKEN` is unset on the gcloud-login path, so any REST
read in this catalog (the Cloud Monitoring utilisation reads this lane shares with
`kubernetes-cost.md`) would send an empty `Authorization` header. Identical to the preamble in
`audit-gcp/references/gcp-checks.md` — keep the two in step.

  If minting the token fails, stop; do not fall back to a different credential. `TOKEN` travels only in `Authorization` headers — never echo it, never put it in a URL, evidence, or the report.
- **Explicit project on everything.** Every command carries `--project "${GCP_PROJECT}"`. Ambient gcloud config is never trusted; this audit never runs `gcloud config set` or `gcloud config configurations activate` (section 10). Where a customer runs the toolkit against a named configuration, they pass it themselves; the catalog stays account-agnostic.
- **Recommendations are per-LOCATION — this is the #1 GCP gotcha.** `gcloud recommender recommendations list` requires `--location`, and a recommendation only appears in the location of the resource it targets: **zones** for instances and disks, **regions** for addresses, MIGs, commitments, and Cloud SQL, **`global`** for images. A single `--location=us-central1-a` sees only that zone's idle-VM recommendations and silently misses every other zone. You must enumerate the project's active zones and regions and loop; the blocks below do this. Judging "no idle VMs" from one location is a false pass.
- **Copy the dollar verbatim; never normalize against a price table.** The only savings number that may reach a finding is `primaryImpact.costProjection.cost`, read directly from the Recommender response. See section 4 for the exact extraction and the currency/duration guards.
- **Currency and period guards.** `costProjection.cost` has `currencyCode`, `units` (a string integer, may be negative), and `nanos` (may be negative), plus a sibling `duration`. Cost recommenders emit a **negative** cost for a saving over a **monthly** window (`duration: "2592000s"`, i.e. 30 days). Treat the figure as `estimated_monthly_savings_usd` only when `currencyCode == "USD"` **and** `duration == "2592000s"`; take the absolute value. A non-USD currency is reported in its own currency and never summed into the USD total; a non-monthly duration is reported per its stated period and never divided to fabricate a monthly number.
- **Read-only by effect, not verb.** `gcloud recommender recommendations list|describe` reads; `gcloud recommender recommendations mark-*` **mutates** the recommendation lifecycle on Google's side and is forbidden (section 10). Every call this catalog makes is a list/describe/GET.
- **Large estates: prefer the BigQuery export.** For projects with hundreds of resources, enable the [Recommender BigQuery export](https://cloud.google.com/recommender/docs/bigquery-export/export-recommendations-to-bigquery) once and query all recommenders and locations in a single read, instead of looping the API per zone. Batch the per-location loops in the estate-sizing large path either way.
- **Thresholds and windows are examples; tune to your workloads.** Snapshot-age and idle-day defaults are starting points, not law.

## 4. Doctor-gate dependency

Every Recommender check (COST-GCP-001 through COST-GCP-010) depends on the doctor gate's optional cost-permission probe (`skills/doctor/scripts/doctor.sh`, the `gcp cost-permissions` row). That probe confirms the Recommender API is enabled and the credential holds a recommender viewer role (e.g. `roles/recommender.computeViewer` or the broader `roles/recommender.viewer`); it never fails the main doctor gate. A missing scope there, or `gcp.cost_checks: false` in `toolkit.yaml`, means the Recommender-backed part of this phase reports itself `excluded` with the doctor's own reason, rather than running some recommenders and guessing at the rest:

```bash
set -eu
RUN_DATE="$(date -u +%Y-%m-%d)"
MATRIX="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/${RUN_DATE}/matrix.tsv"   # written by the doctor gate this run, or the most recent doctor run
[ -f "$MATRIX" ] || { echo "no doctor matrix found; run the doctor gate before the GCP cost phase"; exit 1; }
# Resolve THIS target's label the same way every other block in this file does. Reading
# ${GCP_LABEL:-} without assigning it compares against the literal string "gcp ()", which
# matches nothing — reintroducing the very zero-row bug the match below exists to fix,
# silently skipping COST-GCP-001..010 on a multi-project estate.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind 2>/dev/null || echo map)
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run with SCOUTFLO_TARGET set to one of: $(sh "$TT" "$CFG" gcp labels 2>/dev/null | tr '\n' ' ')"; exit 1; }
  GCP_LABEL="$SCOUTFLO_TARGET"
else
  GCP_LABEL=""
fi
# doctor writes the integration as `gcp` for a single block but `gcp (<label>)` once
# `gcp:` lists more than one target (doctor.sh tint()). Matching only the bare form
# found ZERO rows on a multi-project estate — so the gate controlling COST-GCP-001..010,
# the entire provider-native-dollar section, silently had no verdict to read on exactly
# the configuration this lane exists for. Match both forms, select THIS target, and say
# so loudly when no row matches rather than printing nothing.
GCP_ROW="$(awk -F'\t' -v t="${GCP_LABEL:-}" '
  ($1 == "gcp" || $1 == "gcp (" t ")") && $2 == "cost-permissions" {print $5, $7}' "$MATRIX")"
[ -n "$GCP_ROW" ] || { echo "no gcp cost-permissions row for target '${GCP_LABEL:-<single>}' in ${MATRIX}: re-run /scoutflo:doctor against this config before the cost lane, and do not treat a missing row as permission to skip COST-GCP-001..010"; exit 1; }
printf '%s\n' "$GCP_ROW"
```

Expected: `pass -` when the Recommender checks can run, or `skipped <reason>` when they cannot. A `skipped` result means COST-GCP-001 through COST-GCP-010 render exactly one line: "GCP Recommender cost checks: excluded, reason: `<the exact hint from the matrix row>`", and none of them runs this cycle. The **presence-fact** checks — COST-GCP-020 (snapshots), COST-GCP-021 (static IPs), COST-GCP-022 (unattached disks) — need only plain `compute.*.list` permissions already covered by the reliability doctor probe, so they may still run even when the Recommender scope is missing; state that split explicitly rather than excluding the whole section when only the native-dollar part is blocked. COST-GCP-023 (billing context) depends separately on a configured Cloud Billing BigQuery export and BigQuery read access; a missing export excludes just that one context row with its reason.

## 5. The Recommender extraction (shared by COST-GCP-001 to COST-GCP-010)

Every native-dollar check pulls one recommender and extracts the verbatim cost figure the same way. This is the single place the dollar is read; the per-check sections below only change the `--recommender=` flag and the location set. Enumerate the project's zones/regions first, then loop:

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
RECOMMENDER="google.compute.instance.IdleResourceRecommender"   # the flag changes per check; location kind must match (see section 3)
# Zonal recommenders (instances, disks) loop over zones; regional ones (addresses, MIGs, commitments, Cloud SQL) over regions; images use global.
LOCATIONS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
# FAIL CLOSED. Every Recommender loop below iterates this list, and each gcloud call inside
# is `2>/dev/null`. So an empty list runs the loop ZERO times and produces no findings and no
# error — indistinguishable from "this project has no savings". A denied compute.viewer must
# never read as a clean project.
[ -n "$LOCATIONS" ] || { echo "GCP cost: could not enumerate zones for ${GCP_PROJECT}. This is a BLOCKER, not an empty result — report the GCP Recommender phase as excluded with this reason, never as 'no savings found'. Unlock: gcloud services enable compute.googleapis.com --project ${GCP_PROJECT} and grant roles/compute.viewer to the audit identity."; exit 1; }

for LOC in $LOCATIONS; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list \
    --project="$GCP_PROJECT" --location="$LOC" \
    --recommender="$RECOMMENDER" --format=json 2>/dev/null \
  | jq -r --arg loc "$LOC" '
      .[]
      | select(.stateInfo.state == "ACTIVE")
      | select(.primaryImpact.category == "COST")
      | .primaryImpact.costProjection as $cp
      | ( ($cp.cost.units // "0" | tonumber) + (($cp.cost.nanos // 0) / 1000000000) ) as $signed
      | {
          location: $loc,
          recommendation: (.name | sub(".*/recommendations/"; "")),
          subtype: (.recommenderSubtype // "?"),
          target: (.content.overview.resourceName // .content.overview.resource // .description),
          priority: (.priority // "?"),
          currency: ($cp.cost.currencyCode // "?"),
          period: ($cp.duration // "?"),
          native_cost_value: $signed,
          # estimated_monthly_savings_usd is populated ONLY when currency==USD AND period==2592000s.
          estimated_monthly_savings_usd: (
            if ($cp.cost.currencyCode == "USD") and ($cp.duration == "2592000s")
            then ($signed * -1) else null end)
        }'
done
```

Expected: zero or more JSON objects, each naming the concrete target resource, its location, the Recommender's own subtype (`STOP_VM`, `SNAPSHOT_AND_DELETE_DISK`, `CHANGE_MACHINE_TYPE`, `DELETE_ADDRESS`, `PURCHASE_COMMITMENT`, ...), and the dollar figure copied verbatim. When `estimated_monthly_savings_usd` comes back `null` (non-USD currency, or a non-monthly `duration`), the finding carries **no** `estimated_monthly_savings_usd` field and states the native figure and its period in evidence instead — never a divided-down monthly guess. An `AccessDenied`/`PERMISSION_DENIED` on the recommender means the check is `blocked` (record the status), and a disabled `recommender.googleapis.com` API means the whole Recommender part is `excluded` per the doctor gate — never reinterpreted as "no recommendations, all clean".

- ❌ `COST-GCP-002: web-1 runs at 8% CPU; downsizing e2-standard-8 → e2-standard-2 saves ~$110/mo per the public price list.`
- ✅ `COST-GCP-002: Recommender rates 'web-1' (zone us-central1-a) over-provisioned, subtype CHANGE_MACHINE_TYPE, e2-standard-8 → e2-standard-2; estimated_monthly_savings_usd is 109.20, copied verbatim from costProjection.cost (units=-109, nanos=-200000000, USD, 2592000s).`

## 6. Idle and right-sizing recommenders (COST-GCP-001 to COST-GCP-003)

Run the section 5 extraction with each recommender and its correct location kind.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
ZONES="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$ZONES" ] || { echo "GCP cost: could not enumerate zones for ${GCP_PROJECT} — BLOCKER, not an empty result (the loops below would run zero times and look clean). Report this phase excluded. Unlock: enable compute.googleapis.com and grant roles/compute.viewer."; exit 1; }
REGIONS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$REGIONS" ] || { echo "GCP cost: could not enumerate regions for ${GCP_PROJECT} — BLOCKER, not an empty result (the loops below would run zero times and look clean). Report this phase excluded. Unlock: enable compute.googleapis.com and grant roles/compute.viewer."; exit 1; }

# COST-GCP-001: idle VMs — zonal. Subtypes STOP_VM / SNAPSHOT_AND_DELETE / DELETE_VM.
for Z in $ZONES; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.instance.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-002: VM machine-type right-sizing — zonal. Subtype CHANGE_MACHINE_TYPE.
for Z in $ZONES; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.instance.MachineTypeRecommender" --format=json 2>/dev/null
done
# COST-GCP-003: MIG right-sizing — regional (regional MIGs) and zonal (zonal MIGs); check both.
for R in $REGIONS; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.instanceGroupManager.MachineTypeRecommender" --format=json 2>/dev/null
done
```

Expected: each recommendation names one instance or MIG, its current and recommended machine type (in `content.operationGroups`), and the verbatim cost. Pipe each through the section 5 jq. `COST-GCP-001`'s `STOP_VM` subtype means the VM is a stop candidate (recoverable), while `SNAPSHOT_AND_DELETE`/`DELETE_VM` mean delete candidates — carry the subtype into the finding so the reader knows whether the action is reversible. A VM the Recommender rates idle that your team knows is a warm standby is a false positive to annotate, not silently drop — record why it stays.

## 7. Idle networking and storage recommenders (COST-GCP-004 to COST-GCP-006)

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
ZONES="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$ZONES" ] || { echo "GCP cost: could not enumerate zones for ${GCP_PROJECT} — BLOCKER, not an empty result (the loops below would run zero times and look clean). Report this phase excluded. Unlock: enable compute.googleapis.com and grant roles/compute.viewer."; exit 1; }
REGIONS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$REGIONS" ] || { echo "GCP cost: could not enumerate regions for ${GCP_PROJECT} — BLOCKER, not an empty result (the loops below would run zero times and look clean). Report this phase excluded. Unlock: enable compute.googleapis.com and grant roles/compute.viewer."; exit 1; }

# COST-GCP-004: idle reserved external IPs — regional. Subtype DELETE_ADDRESS.
for R in $REGIONS; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.address.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-005: idle persistent disks — zonal. Subtype SNAPSHOT_AND_DELETE_DISK / DELETE_DISK.
for Z in $ZONES; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.disk.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-006: idle custom images — global.
CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="global" \
  --recommender="google.compute.image.IdleResourceRecommender" --format=json 2>/dev/null
```

Expected: each recommendation names one address (with its region), disk (with its zone, size, and type), or image, and its verbatim cost. Pipe each through the section 5 jq. `COST-GCP-004` overlaps deliberately with the presence-fact `COST-GCP-021`: when the Recommender has a dollar for an idle IP, the finding is COST-GCP-004 with the native figure; the reserved-but-unused IPs the Recommender has *not* costed still surface as COST-GCP-021 presence facts, so nothing is lost when the Recommender scope is present but incomplete. Note the same overlap for disks (COST-GCP-005 native vs COST-GCP-022 presence).

## 8. Commitments and databases (COST-GCP-007 to COST-GCP-009)

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
REGIONS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$REGIONS" ] || { echo "GCP cost: could not enumerate regions for ${GCP_PROJECT} — BLOCKER, not an empty result (the loops below would run zero times and look clean). Report this phase excluded. Unlock: enable compute.googleapis.com and grant roles/compute.viewer."; exit 1; }

# COST-GCP-007: committed-use discount purchase opportunities — regional. Subtype PURCHASE_COMMITMENT.
# The cost figure is the projected SAVING from committing to steady-state usage — read verbatim, do not model it yourself.
for R in $REGIONS; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.commitment.UsageCommitmentRecommender" --format=json 2>/dev/null
done
# COST-GCP-008 / COST-GCP-009: Cloud SQL idle and over-provisioned — regional.
for R in $REGIONS; do
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.cloudsql.instance.IdleRecommender" --format=json 2>/dev/null
  CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.cloudsql.instance.OverprovisionedRecommender" --format=json 2>/dev/null
done
```

Expected: `COST-GCP-007` recommendations describe a commitment to purchase (family, region, vCPU/memory amount) with the Recommender's own projected saving — a **commitment is a spend decision**, so the finding is advisory-only and names the commitment term the Recommender assumed (1-year vs 3-year changes the number). `COST-GCP-008`/`COST-GCP-009` name the Cloud SQL instance, its tier, and the recommended change. Pipe each through the section 5 jq. If the Cloud SQL Admin API or its recommender is not enabled in the project, that check reports `excluded` (API disabled), never an empty pass.

## 9. COST-category recommender sweep (COST-GCP-010)

New COST-category recommenders appear over time (GKE cost optimization, Cloud Run, BigQuery slot reservations, Spanner). Rather than hardcode a list that silently goes stale, enumerate the recommenders the project actually exposes and pull COST recommendations from any not already covered by COST-GCP-001..009:

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# Sweep the project's OWN locations, never a hand-typed one: a single literal region
# audits one location and reports silence for every other, which reads as "no savings".
# Regional recommenders take regions; the zonal ones in section 5 take zones.
LOCATIONS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
[ -n "$LOCATIONS" ] || { echo "GCP cost: could not enumerate regions for ${GCP_PROJECT}. This is a BLOCKER, not an empty result — report these recommenders as excluded with this reason, never as 'no savings found'. Unlock: gcloud services enable compute.googleapis.com --project ${GCP_PROJECT} and grant roles/compute.viewer to the audit identity."; exit 1; }
# There is NO `gcloud recommender recommenders list` subcommand (it errors "Invalid choice") — the
# Recommender API has no discovery endpoint, so sweep an EXPLICIT list of the COST-category
# recommenders section 5 did not already cover (GKE, Cloud Run, BigQuery, etc.). Each has its own
# location kind (regional vs zonal vs global); skip a 403/404 as "not enabled here", never as a finding.
for R in \
  google.container.DiagnosisRecommender \
  google.run.service.CostRecommender \
  google.cloudsql.instance.IdleRecommender \
  google.cloudsql.instance.OverprovisionedRecommender \
  google.bigquery.capacityCommitments.Recommender ; do
  for LOC in $LOCATIONS; do
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud recommender recommendations list \
      --project="$GCP_PROJECT" --location="$LOC" --recommender="$R" \
      --filter='stateInfo.state=ACTIVE' --format=json 2>/dev/null \
      | jq -e 'length > 0' >/dev/null 2>&1 && echo "ACTIVE cost recs from $R in $LOC (extract per section 5)" || true
  done
done
```

Expected: run the section 5 extraction against each recommender that returned ACTIVE recommendations, in each recommender's correct location kind, and emit any ACTIVE COST recommendation with its verbatim figure. This keeps GKE and other emerging cost recommenders in scope **only when GCP actually surfaces a costed recommendation for them** — the honest alternative to inventing a GKE idle-node dollar the platform has not produced. A recommender that returns no COST recommendations is not a finding; a recommender the project does not expose is simply absent from the list, not an error.

## 10. Spend breakdown by service and SKU — context only (COST-GCP-023)

This is **context, not a savings figure**: it shows where the money actually goes so the ranked opportunities above have a denominator, but actual spend never populates `estimated_monthly_savings_usd`. GCP has **no gcloud command that returns spend by SKU** — the canonical programmatic source is the [Cloud Billing BigQuery export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery). First confirm the linked billing account (read-only), then query the export if it is configured:

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# Read-only: which billing account is this project linked to, and is billing enabled.
CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud billing projects describe "$GCP_PROJECT" \
  --format='value(billingAccountName,billingEnabled)' 2>/dev/null \
  || echo "billing.projects.get denied or Cloud Billing API off; COST-GCP-023 reports excluded (no billing scope)"
```

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
# DISCOVER the table id; never hand-edit it. The standard-usage export is
# gcp_billing_export_v1_*, the detailed resource-level export gcp_billing_export_resource_v1_*.
# Prefer the detailed one: it is the only flavour carrying per-resource rows, and the only one
# GKE cost allocation can attribute to a cluster/namespace (section 10b).
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "no gcp_billing_export_* table in ${BILLING_DATASET}: COST-GCP-023 reports excluded (no spend export). The export is billing-account level and takes a few DAYS to appear and fill."; exit 0; }
# Last full month NET spend by project, service and SKU. `credits` is unnested because gross
# cost overstates the bill wherever a discount, promotion or CUD applies — and this number is
# the denominator every savings figure is read against, so it has to be the real one.
# Read-only SELECT; no table is created or modified.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT project.id AS project, service.description AS service, sku.description AS sku,
        ROUND(SUM(cost), 2) AS gross_usd,
        ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net_usd,
        currency
   FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
  GROUP BY project, service, sku, currency
  ORDER BY net_usd DESC
  LIMIT 25' 2>/dev/null \
  || echo "billing BigQuery export not configured or bq denied; COST-GCP-023 reports excluded (no spend export)"
```

### 10b. GKE spend by cluster, namespace and workload (COST-GCP-024)

The same export, the same auth, the same `bq` invocation — one different `GROUP BY`. **GKE nodes
are Compute Engine VMs, so their real cost is already in this table**; no third-party cost tool
is needed and none should ever be asked for. When **GKE cost allocation** is enabled on a
cluster, Google adds `goog-k8s-cluster-name`, `goog-k8s-namespace` and `goog-k8s-workload-name`
labels to the detailed export, which is what turns cluster spend into namespace and workload
spend. This is the only first-party path to a Kubernetes dollar, and `kubernetes-cost.md`
section 12 reads it for COST-K8S-008.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
# Discover the table here too: every block in this catalog runs alone in a fresh shell.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-024 reports excluded, reason: no gcp_billing_export_* table in ${BILLING_DATASET}"; exit 0; }
# Requires the DETAILED export (gcp_billing_export_resource_v1_*).
case "$BILLING_TABLE" in
  gcp_billing_export_resource_v1_*) : ;;
  *) echo "COST-GCP-024 reports excluded, reason: only the standard-usage export (${BILLING_TABLE}) is configured; per-cluster and per-namespace attribution needs the detailed resource-level export plus GKE cost allocation on the cluster"; exit 0 ;;
esac
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT (SELECT value FROM UNNEST(labels) WHERE key = "goog-k8s-cluster-name")  AS cluster,
        (SELECT value FROM UNNEST(labels) WHERE key = "goog-k8s-namespace")     AS namespace,
        (SELECT value FROM UNNEST(labels) WHERE key = "goog-k8s-workload-name") AS workload,
        ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net_usd,
        currency
   FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
    AND EXISTS (SELECT 1 FROM UNNEST(labels) WHERE key = "goog-k8s-cluster-name")
  GROUP BY cluster, namespace, workload, currency
  ORDER BY net_usd DESC
  LIMIT 50' 2>/dev/null \
  || echo "COST-GCP-024 reports excluded, reason: bq denied or the GKE allocation labels are absent (enable GKE cost allocation on the cluster)"
```

**A freshly enabled export has no history.** Neither the billing export nor GKE cost allocation
backfills: both start at the moment they are switched on. So a last-full-month window returns
**zero rows** on an export enabled days ago, which must never be read as "no spend". When the
month query comes back empty, re-run it over the data that exists — swap the `WHERE` clause for
`usage_start_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))` — and label the
finding with the window actually covered (`net spend, 7d — export enabled <date>, partial
month`). Say the coverage out loud rather than annualising a partial week into a yearly figure.

Expected: one row per cluster/namespace/workload with its net monthly spend. A cluster that
appears with spend but **no** namespace rows has cost allocation off — report that as the
reason, never as "the namespaces cost nothing". These are **verbatim billing figures**, so a
COST-K8S finding may cite them as its `savings_source`; a figure derived by multiplying a rate
by a quantity may not (section 1).

Expected: the top services and SKUs by last-month spend, in the export's own `currency`, reported as **context** beside the ranked savings — for example, so a reader sees that Compute Engine SKUs dominate the bill, which frames why the idle-VM and CUD recommendations matter most. If no billing export is configured, COST-GCP-023 reports `excluded, reason: "no Cloud Billing BigQuery export configured"`, not a fabricated breakdown. Never present spend as savings; the two are different numbers and mixing them misleads a budget conversation.

## 10c. Premium-tier consumption where a standard tier exists (COST-GCP-033)

Several Google services bill the same work at different rates depending on a tier chosen per
request or per deployment — inference service tiers being the common one. The tier is visible in
the **SKU description** on the bill, so the export tells you exactly how much is going through the
premium path and from which project. A non-production project on a premium tier is almost always
unintended, and it is the cheapest finding in this file to act on: it is a routing change, not a
resize, with no capacity risk.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-033 reports excluded, reason: no billing export table in ${BILLING_DATASET}"; exit 0; }
# Split every service's spend by the tier marker in its SKU name. Markers are matched
# case-insensitively and kept in one list so a new tier name is a one-line change.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT project.id AS project, service.description AS service,
        CASE WHEN REGEXP_CONTAINS(LOWER(sku.description), r"priority|premium|provisioned throughput") THEN "premium"
             WHEN REGEXP_CONTAINS(LOWER(sku.description), r"batch|standard|flex") THEN "standard"
             ELSE "untiered" END AS tier,
        ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net,
        currency, COUNT(DISTINCT sku.description) AS skus
   FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
  GROUP BY project, service, tier, currency
 HAVING net > 0
  ORDER BY net DESC
  LIMIT 50' 2>/dev/null \
  || echo "COST-GCP-033 reports excluded, reason: bq denied or the export is unreadable"
```

Expected: one row per project/service/tier. The finding fires when a service has **premium** spend
and a standard tier exists for the same work. Report the premium spend per project, name the SKUs,
and separate **production** from **non-production callers** — the second group is the
uncontroversial half. `indicative_monthly_usd` prices only the step you can price exactly: the
published premium-minus-standard rate delta on the same SKU family, applied to the billed premium
volume, labelled before discounts. Do **not** claim the whole premium spend as a saving: some
callers genuinely need the tier, and that is the owner's call. Where a tier's published rate is not
available, report the spend split with no indicative figure rather than guessing.

## 10d. Object storage: class and lifecycle versus access pattern (COST-GCP-025)

Object storage is usually billed on bytes stored at a class rate, and the cheapest reduction in a
media- or log-heavy estate is moving cold objects to a colder class or expiring them. Buckets with
**no lifecycle rule** and versioning enabled accumulate noncurrent versions indefinitely, which
bill at full class rate and are invisible in a bucket listing.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# Bucket shape: default class, location type, lifecycle rule count, versioning, soft-delete.
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud storage buckets list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-025 reports excluded, reason: storage.buckets.list denied or Cloud Storage API off"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | {name: .name, class: .default_storage_class, location: .location_type,
                  lifecycle_rules: ((.lifecycle_config.rule // []) | length),
                  versioning: (.versioning_enabled // false)}
           | "\(.name)\tclass=\(.class)\tlocation=\(.location)\trules=\(.lifecycle_rules)\tversioning=\(.versioning)"'
```

Expected: one line per bucket. The finding fires on a bucket that is **STANDARD class with zero
lifecycle rules**, or **versioning on with no noncurrent-version expiry**, or **multi-region where
the workload is single-region**. Pair each with its billed storage cost from the export (group the
Cloud Storage SKUs by `resource.name` on the detailed export) so the largest buckets rank first.
`indicative_monthly_usd` uses the **published class-price delta** — Standard to Nearline, Nearline
to Coldline, Coldline to Archive — applied to the billed bytes of that bucket, and must note the
two costs a class change carries: **early-delete minimum storage duration** and **retrieval cost**,
which can make a colder class more expensive for data that is still read. State the access pattern
you observed, or say that you could not observe it.

## 10e. Network shape: service tier, egress, NAT and idle forwarding rules (COST-GCP-026)

For a media, streaming or chat workload, networking is frequently the second-largest line and is
almost never examined, because none of it is Recommender-priced. Four things are checkable
read-only.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# 1. Default network service tier for the project (PREMIUM routes over Google's backbone; STANDARD
#    exits closer to the user and bills less — a real trade-off, not free money).
CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute project-info describe --project "$GCP_PROJECT" --format='value(defaultNetworkTier)' 2>/dev/null \
  || echo "COST-GCP-026: project-info denied"
# 2. Cloud NAT gateways. NAT bills a gateway-hour per gateway AND per-GiB data processing, so a
#    gateway per zone or per cluster multiplies the fixed half.
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute routers list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-026: routers.list denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | . as $r | ($r.nats // [])[] | "\($r.region | sub(".*/"; ""))/\($r.name)\tnat=\(.name)\tips=\((.natIps // []) | length)\tsubnets=\((.subnetworks // []) | length)"'
# 3. Forwarding rules with no backend traffic are an idle load-balancer charge.
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute forwarding-rules list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-026: forwarding-rules.list denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | "\((.region // "global") | sub(".*/"; ""))/\(.name)\tIP=\(.IPAddress)\ttier=\(.networkTier // "-")\ttarget=\((.target // .backendService // "-") | sub(".*/"; ""))"'
```

Expected: the project's default tier, every NAT gateway with its IP and subnet count, and every
forwarding rule. The finding fires on: **PREMIUM tier where the traffic is regional and
latency-tolerant** (indicative = published PREMIUM-minus-STANDARD egress delta on the billed egress
volume), **more NAT gateways than regions in use** (the gateway-hour half is priced exactly, so it
is indicative-eligible), and **forwarding rules whose target no longer exists** (presence fact).
Egress itself needs the export: group Networking SKUs by SKU name to separate inter-zone,
inter-region and internet egress, because the three have very different rates and only the first is
usually an architecture mistake. Never present total egress as waste — it is mostly the product
working.

## 10f. Log ingestion and retention (COST-GCP-027)

Log ingestion bills per GiB above a monthly free allowance, and retention bills per GiB-month above
the default. Teams facing this often disable logging wholesale — which is a reliability loss sold as
a saving — when an **exclusion filter** on the noisiest few log types would have kept the signal and
cut most of the cost.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# Log buckets and their retention (the default _Default/_Required buckets included).
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud logging buckets list --project "$GCP_PROJECT" --location=global --format=json 2>/dev/null)" || { echo "COST-GCP-027: logging.buckets.list denied or API off"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | "\(.name)\tretention_days=\(.retentionDays // "-")\tlocked=\(.locked // false)"'
# Sinks and, critically, whether any exclusion filter exists on the _Default sink.
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud logging sinks list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-027: logging.sinks.list denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | "\(.name)\tdest=\((.destination // "-") | sub(".*/"; ""))\texclusions=\((.exclusions // []) | length)"'
```

Expected: retention per bucket and exclusion count per sink. The finding fires when Cloud Logging
spend is material **and** `_Default` carries zero exclusions, or retention exceeds the default with
no stated policy. `indicative_monthly_usd` uses the **published per-GiB ingestion rate** times the
volume of the specific log types you propose excluding — so name them from the export's SKU/label
breakdown, never "logs in general". Record the reliability trade-off explicitly: an exclusion makes
those lines unqueryable, so route them to cheaper storage instead where they are needed for audit.

## 10g. Provisioned-but-unused managed capacity (COST-GCP-030)

Managed file, cache and database services bill **provisioned** capacity and tier, not used bytes, so
a share sized for a peak that never came bills at full rate forever. Google publishes no cost
recommender for these, which is exactly why they survive years of review.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud auth print-access-token)"; fi
START="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Inventory: tier and provisioned capacity per share.
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud filestore instances list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-030 reports excluded, reason: filestore.instances.list denied or API off"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | "\(.name | sub(".*/"; ""))\ttier=\(.tier)\tgb=\((.fileShares // [])[0].capacityGb // "-")\tcreated=\(.createTime // "-")"'
# Peak utilisation over a real window — ALIGN_MAX, because a mean hides the peak that sized it.
RAW="$(curl -fsSG --max-time 60 -H "Authorization: Bearer ${TOKEN}" \
  "${MON_API}/projects/${GCP_PROJECT}/timeSeries" \
  --data-urlencode 'filter=metric.type = "file.googleapis.com/nfs/server/used_bytes_percent"' \
  --data-urlencode "interval.startTime=${START}" --data-urlencode "interval.endTime=${END}" \
  --data-urlencode 'aggregation.alignmentPeriod=3600s' \
  --data-urlencode 'aggregation.perSeriesAligner=ALIGN_MAX')" || { echo "COST-GCP-030: monitoring timeSeries denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.timeSeries[]? | "\(.resource.labels.instance_name)\tmax_used_pct=\([.points[].value.doubleValue] | max)"'
```

Expected: tier, provisioned size and 7-day peak utilisation per share, joined to its billed cost
from the export. The finding fires below a low utilisation threshold. Report the **tier** as loudly
as the size: a premium tier at 1% use is two decisions, not one, and the tier change is usually the
larger of the two. `indicative_monthly_usd` prices **one step only** — one tier down, or halving
provisioned capacity at the same tier — from the published per-GiB-month rate, before discounts. The
target shape needs the owner's durability and throughput requirements, so ask rather than assume;
several shares of the same tier in one region are also a **consolidation** candidate, which is a
design change and gets no figure.

## 10h. Large uncommitted compute with no CUD recommendation (COST-GCP-031)

The Recommender sizes a commitment to a **stable floor** of observed usage. An aggressively
autoscaled estate has no stable floor at the resource level, so Google returns *no* recommendation
precisely where the bill is largest — the opposite of helpful. The floor still exists in the
**billed spend**, and spend-based commitments exist for this case, so compute the floor from the
export rather than reporting "no recommendation" and stopping.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
TARGET_PROJECT="$GCP_PROJECT"   # the project whose compute bill has no CUD recommendation — this target's, resolved above
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-031 reports the no-recommendation fact only, reason: no export to compute a floor from"; exit 0; }
# Daily net compute spend over 90 days. The MINIMUM and 5th-percentile days are the committable
# floor: spend the estate never drops below, even at its quietest.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'WITH daily AS (
  SELECT DATE(usage_start_time) AS d,
         SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net
    FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
   WHERE service.description = "Compute Engine"
     AND project.id = "'"${TARGET_PROJECT}"'"
     AND usage_start_time >= TIMESTAMP(DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY))
   GROUP BY d)
 SELECT COUNT(*) AS days_observed,
        ROUND(MIN(net), 2) AS min_day,
        ROUND(APPROX_QUANTILES(net, 100)[OFFSET(5)], 2) AS p5_day,
        ROUND(APPROX_QUANTILES(net, 100)[OFFSET(50)], 2) AS p50_day,
        ROUND(MAX(net), 2) AS max_day
   FROM daily' 2>/dev/null \
  || echo "COST-GCP-031: bq denied; report the no-recommendation fact without a floor"
```

Expected: the daily floor over a real quarter. Report the **p5 day** as the conservative committable
floor (the minimum day can be an incomplete or anomalous day), state `days_observed` so a short
export is visible, and multiply by 30 for a monthly floor. `indicative_monthly_usd` applies the
**published spend-based commitment discount rate** to that floor — a sourced figure from billed
spend, not a guess — and must say plainly that a commitment is a **spend decision locking a term**,
not recovered waste. Keep the underlying fact in the finding either way: a large bill with zero
commitments and no recommendation is itself the headline, and the floor is what makes it actionable.
If the export is too short to see a quarter, say so and report the fact alone.

## 10i. Stopped resources that still bill (COST-GCP-032)

A stopped VM bills nothing for CPU and everything for its attached disks, so a machine stopped
"temporarily" months ago is a pure, uncontroversial cut. This is a presence fact with an exact
ceiling: the disk's own billed cost.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute instances list --project "$GCP_PROJECT" --filter='status=TERMINATED' --format=json 2>/dev/null)" || { echo "COST-GCP-032 reports excluded, reason: compute.instances.list denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '.[] | "\(.zone | sub(".*/"; ""))/\(.name)\ttype=\(.machineType | sub(".*/"; ""))\tstopped=\(.lastStopTimestamp // "unknown")\tdisks=\([(.disks // [])[] | .diskSizeGb] | add // 0)GB"'
```

Expected: every TERMINATED instance with how long it has been stopped and how much disk it still
holds. Rank by **stopped duration × disk size**; a machine stopped for over a quarter with hundreds
of GiB attached is the clearest case in the whole report. No savings figure — but attach the disks'
billed cost from the export, which is the exact ceiling. Exclude instance templates and
autoscaler-stopped members, and respect the **snapshot-before-delete** order in the action.

## 10j. Billed projects outside the audited config (COST-GCP-034)

An audit's most dangerous blind spot is spend it never looked at. The export knows every project
that billed; the config knows every project that was checked. The difference is unmeasured spend,
and reporting it is what stops a clean report being mistaken for a clean estate.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-034 reports excluded, reason: no export, so billed projects cannot be enumerated"; exit 0; }
# Every project that billed last month, largest first. Compare this set with the configured set.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT project.id AS project,
        ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2) AS net, currency
   FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
  GROUP BY project, currency
 HAVING net > 0
  ORDER BY net DESC' 2>/dev/null \
  || echo "COST-GCP-034 reports excluded, reason: bq denied"
```

Expected: the full billed-project list. Subtract the projects configured for this run (every `gcp`
target across the config used) and report the remainder **with their spend, ranked**, plus the share
of total spend they represent. This is a **coverage** finding, not a waste finding: it carries no
savings figure and says explicitly that no check ran against this spend. Classify where you can —
Marketplace or third-party SaaS subscriptions billed through the account behave differently from a
first-party project nobody owns — and the action is to add the real ones to the config, not to cut
them. A project that bills and is audited by nobody is also the single most likely place for the
next surprise.

## 10k. Rate versus usage: which lever even applies (COST-GCP-028)

"Spend is up 8%" is not actionable, because it has two completely different causes with opposite
fixes. If **usage** rose, the lever is engineering — fewer resources, smaller requests, less
traffic. If the **rate** rose, the lever is commercial — a commitment, a tier, a region, a class.
Teams routinely spend a quarter optimising usage on a bill that moved because a discount expired.

The export carries `cost` **and** `usage.amount` per SKU, so the decomposition is arithmetic, not
a model. Hold usage at last period's level and reprice it at this period's effective rate; the gap
is the rate effect, and the remainder is the usage effect.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-028 reports excluded, reason: no billing export table"; exit 0; }
# Effective unit rate = net cost / usage amount, per SKU, for two consecutive months.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'WITH m AS (
  SELECT FORMAT_DATE("%Y-%m", DATE(usage_start_time)) AS mon,
         service.description AS service, sku.description AS sku, usage.unit AS unit,
         SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net,
         SUM(usage.amount) AS qty
    FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
   WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH))
     AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
   GROUP BY mon, service, sku, unit),
 p AS (
  SELECT service, sku, unit,
         MAX(IF(mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH)), net, NULL)) AS net_prev,
         MAX(IF(mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH)), qty, NULL)) AS qty_prev,
         MAX(IF(mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)), net, NULL)) AS net_now,
         MAX(IF(mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH)), qty, NULL)) AS qty_now
    FROM m GROUP BY service, sku, unit)
 SELECT service, sku, unit, ROUND(net_prev,2) AS net_prev, ROUND(net_now,2) AS net_now,
        ROUND(net_now - net_prev, 2) AS delta,
        ROUND(SAFE_DIVIDE(net_prev, qty_prev), 8) AS rate_prev,
        ROUND(SAFE_DIVIDE(net_now,  qty_now ), 8) AS rate_now,
        -- usage effect: last period rate applied to the usage change
        ROUND((qty_now - qty_prev) * SAFE_DIVIDE(net_prev, qty_prev), 2) AS usage_effect,
        -- rate effect: this period usage priced at the rate change
        ROUND(qty_now * (SAFE_DIVIDE(net_now, qty_now) - SAFE_DIVIDE(net_prev, qty_prev)), 2) AS rate_effect
   FROM p
  WHERE net_prev IS NOT NULL AND net_now IS NOT NULL AND qty_prev > 0 AND qty_now > 0
    AND ABS(net_now - net_prev) > 1
  ORDER BY ABS(net_now - net_prev) DESC
  LIMIT 30' 2>/dev/null \
  || echo "COST-GCP-028 reports excluded, reason: bq denied, or the export lacks usage.amount for these SKUs"
```

Expected: the biggest movers, each split into a usage effect and a rate effect that sum (to rounding)
to the delta. Report the **top movers by absolute delta** and label each one's dominant cause. State
the caveats plainly: a SKU whose `usage.unit` changed between periods cannot be decomposed (drop it
rather than produce nonsense), a new or retired SKU has no prior rate (that is COST-GCP-029's job),
and tiered-rate SKUs will show a rate effect purely from crossing a volume tier — which is real, but
it is a *volume* story, not a price change. No savings figure: this check tells you **which** lever
applies, and the other checks price the lever.

## 10l. Spend that appeared: new SKUs, new projects, unexplained jumps (COST-GCP-029)

The most expensive cost surprises are not inefficiencies — they are things that quietly started.
Someone enables a managed service, a Marketplace subscription lands on the account, a feature flips
to a premium tier, a new project starts billing. A static view of this month's spend cannot see any
of it; a period-over-period **set difference** sees all of it immediately.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-029 reports excluded, reason: no billing export table"; exit 0; }
# SKUs and projects that bill THIS period and did not bill the previous one, largest first.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'WITH m AS (
  SELECT FORMAT_DATE("%Y-%m", DATE(usage_start_time)) AS mon, project.id AS project,
         service.description AS service, sku.description AS sku,
         SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net
    FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
   WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH))
     AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
   GROUP BY mon, project, service, sku)
 SELECT "new-sku" AS kind, n.project, n.service, n.sku, ROUND(n.net, 2) AS net_now
   FROM m n
  WHERE n.mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND n.net > 0
    AND NOT EXISTS (SELECT 1 FROM m o
                     WHERE o.mon = FORMAT_DATE("%Y-%m", DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 2 MONTH), MONTH))
                       AND o.project = n.project AND o.sku = n.sku)
  ORDER BY net_now DESC
  LIMIT 40' 2>/dev/null \
  || echo "COST-GCP-029 reports excluded, reason: bq denied"
```

Expected: every SKU/project pair that is new this period, ranked by spend. The finding fires on
anything above a materiality floor. Classify what you can from the SKU and service name — a
Marketplace or third-party subscription behaves differently from a first-party service someone
enabled — and **ask who turned it on** rather than recommending deletion: a new SKU is as likely to
be a deliberate launch as a mistake, and the value here is *visibility in month one*. Pair this with
COST-GCP-034: a new SKU inside a project that is also outside the audited config is the highest-risk
combination in the whole report, because nothing is watching it at all. Do not report ordinary
month-length variation (28 vs 31 days) as a jump — normalise to a daily rate before comparing.

## 10m. Inference and AI/ML consumption (COST-GCP-035 to COST-GCP-039)

On an AI-heavy estate, inference is frequently the largest line after compute, and almost none of
it is touched by a cost recommender — so it is usually the biggest unexamined number in the bill.
Every lever below is visible in the **SKU description** on the export, which means all of it is
checkable read-only with no application change and no new integration.

Match SKU **name patterns**, never a hardcoded model list: model generations ship constantly, and a
check pinned to today's names silently stops finding anything. Keep the markers in one place so a
new generation is a one-line change.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }
# The Cloud Billing export is read from THIS target, never a global default: the dataset, and the
# project hosting it (gcp.billing_project, defaulting to this target's own project when the export
# lives alongside it). An unset dataset excludes the check with its reason, never a $0 line.
BILLING_DATASET=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_bq_dataset)
BILLING_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" billing_project); [ -n "$BILLING_PROJECT" ] || BILLING_PROJECT="$GCP_PROJECT"
[ -n "$BILLING_DATASET" ] || { echo "excluded: gcp target '${GCP_LABEL}' has no billing_bq_dataset in $CFG, so actual spend by SKU is unavailable and savings would have no denominator"; exit 0; }
# BILLING_PROJECT both HOSTS the dataset (the FROM clause) and RUNS the query job
# (--project_id), so it is the project needing bigquery.googleapis.com enabled plus
# roles/bigquery.jobUser, with dataViewer on the dataset. It is resolved above from
# this target's gcp.billing_project, falling back to its own gcp.project.
BILLING_TABLE="$(bq ls --project_id="$BILLING_PROJECT" --format=json "$BILLING_DATASET" 2>/dev/null \
  | jq -r '[.[].tableReference.tableId] | (map(select(startswith("gcp_billing_export_resource_v1_"))) + map(select(startswith("gcp_billing_export_v1_")))) | .[0] // empty')"
[ -n "$BILLING_TABLE" ] || { echo "COST-GCP-035..039 report excluded, reason: no billing export table"; exit 0; }
# One pass, classifying every inference SKU along the five axes the checks need.
bq query --project_id="$BILLING_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT project.id AS project, sku.description AS sku, usage.unit AS unit,
        REGEXP_CONTAINS(LOWER(sku.description), r"provisioned throughput|provisioned capacity") AS is_provisioned,
        REGEXP_CONTAINS(LOWER(sku.description), r"batch")                                        AS is_batch,
        REGEXP_CONTAINS(LOWER(sku.description), r"cach")                                         AS is_cache,
        REGEXP_CONTAINS(LOWER(sku.description), r"thinking|reasoning")                           AS is_thinking,
        REGEXP_CONTAINS(LOWER(sku.description), r"\binput\b")                                    AS is_input,
        REGEXP_CONTAINS(LOWER(sku.description), r"\boutput\b")                                   AS is_output,
        ROUND(SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)), 2)      AS net,
        ROUND(SUM(usage.amount), 0) AS qty
   FROM `'"${BILLING_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
    AND REGEXP_CONTAINS(LOWER(service.description), r"vertex|ai platform|generative|machine learning")
  GROUP BY project, sku, unit, is_provisioned, is_batch, is_cache, is_thinking, is_input, is_output
 HAVING net > 0
  ORDER BY net DESC
  LIMIT 100' 2>/dev/null \
  || echo "COST-GCP-035..039 report excluded, reason: bq denied"
```

Expected: every inference SKU with its spend, its billed quantity, and its classification. Read the
five findings off that one table:

**COST-GCP-035 — provisioned throughput versus on-demand.** Reserved inference capacity bills a flat
rate per unit of time; on-demand bills per token. Above a steady-state utilisation the reservation is
cheaper, below it the reservation wastes money. Compare the observed **floor** of on-demand token
volume (the quiet-period level, same technique as COST-GCP-031's spend floor) against the published
provisioned rate for the same model. Report the breakeven and which side of it they sit, and say
plainly that a reservation **locks a term** and that bursty traffic is the case *against* it.

**COST-GCP-036 — context caching.** Where prompt prefixes repeat — a long system prompt, a document
re-queried, a conversation replayed — cached input bills materially less than uncached. Two findings
live here and they point opposite ways: large uncached input spend with repeating prefixes is a
caching **opportunity**, while cache-storage spend that exceeds the input saving means caching is
costing more than it returns on low-reuse traffic. Report the cached, uncached and cache-storage
split, and never recommend caching without evidence of reuse — you can see the SKU, not the prompts,
so ask whether prefixes repeat rather than assuming it.

**COST-GCP-037 — batch versus online.** Batch inference bills materially less for work that
tolerates latency. Report online spend per project and name the plausible batch candidates —
evaluations, backfills, offline scoring, digest generation, anything on a schedule rather than a user
request. This is a routing change with no model change, so it is among the cheapest levers in the
file; but **only the caller knows** whether a given path is user-facing, so present it as a question
with the money attached, not as an instruction.

**COST-GCP-038 — reasoning/thinking output.** Models that emit reasoning tokens bill them as output,
often at the highest per-token rate on the bill, and the volume is a function of a parameter most
teams have never tuned. Report thinking-output spend as an absolute figure **and as a share of total
inference spend**, because the share is what makes it visible: a line nobody budgeted for sitting at
a large fraction of inference cost is the finding. Capping or lowering a reasoning budget changes
answer quality, so this carries **no savings figure** — it is budget visibility, and the trade-off is
the product team's call.

**COST-GCP-039 — model-tier right-sizing.** A premium-tier model serving work a lighter tier handles
is the largest single inference lever when it is real, and the most dangerous to recommend blind.
Report spend and token volume per model tier per project, and flag the shape that is almost always
unintended: **a non-production project on a premium tier** (pair with COST-GCP-033 and
COST-GCP-040). `indicative_monthly_usd` prices exactly one tier step using the published per-token
delta on the observed volume. Never recommend a tier change for a production path on cost grounds
alone — quality is the requirement, cost is the constraint, and only an evaluation can tell you
whether the lighter tier holds.

## 10n. Non-production discipline (COST-GCP-040)

Non-production is where the cheapest money in any estate sits, because nothing there has a user
waiting on it. Three shapes, in descending order of value, all checkable by comparing nonprod
against its own prod twin:

```bash
set -eu
# The nonprod project to compare against. It is a DIFFERENT target from the one under
# audit, so it is named explicitly — but resolved from the config, never hand-typed:
# SCOUTFLO_NONPROD_TARGET picks it out of the same gcp: list by label.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NP="${SCOUTFLO_NONPROD_TARGET:-}"
[ -n "$NP" ] || { echo "COST-GCP-040 reports excluded, reason: no nonprod target named. Set SCOUTFLO_NONPROD_TARGET to one of the gcp labels in $CFG: $(sh "$TT" "$CFG" gcp labels 2>/dev/null | tr '\n' ' ')"; exit 0; }
GCP_PROJECT=""; _i=0; _n=$(sh "$TT" "$CFG" gcp count)
while [ "$_i" -lt "${_n:-0}" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$NP" ] && { GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$_i" project); break; }; _i=$((_i+1)); done
[ -n "$GCP_PROJECT" ] || { echo "COST-GCP-040 reports excluded, reason: SCOUTFLO_NONPROD_TARGET=$NP matches no gcp target in $CFG"; exit 0; }
# Shape of nonprod compute: are machine types and counts the same as production's?
RAW="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute instances list --project "$GCP_PROJECT" --format=json 2>/dev/null)" || { echo "COST-GCP-040 reports excluded, reason: compute.instances.list denied"; RAW=""; }
[ -z "$RAW" ] || printf '%s\n' "$RAW" \
  | jq -r '[.[] | {type: (.machineType | sub(".*/"; "")), status: .status}]
           | group_by(.type) | map({type: .[0].type, n: length,
               running: (map(select(.status=="RUNNING")) | length)})[]
           | "\(.type)\tcount=\(.n)\trunning=\(.running)"'
```

**Round-the-clock running.** A non-production estate that bills 24×7 for a team working business
hours is paying roughly three times what it needs to. This is the single largest nonprod lever and
the most commonly skipped. `indicative_monthly_usd` prices it exactly: the published on-demand rate
for the running resources × the hours a schedule would remove. State what breaks — overnight CI, a
scheduled test, a shared environment in another timezone — and recommend a **schedule**, not a
shutdown.

**Premium tiers in non-production.** A premium inference tier, a premium managed-storage tier or a
premium support/security tier in a QA project is almost never a deliberate choice; it is a default
that was never revisited. Report each one with its nonprod spend; this is the most uncontroversial
finding in the whole file, because nobody argues for paying a latency premium in QA.

**Prod-sized non-production.** Where a nonprod resource matches its prod twin's machine type,
replica count, storage tier or retention, report the pair side by side. Some parity is deliberate —
performance testing needs prod-shaped capacity, and a staging environment that cannot reproduce a
prod bug is worthless — so this is a **presence fact** with the pairs named, never an instruction.
Ask which environments are load-test targets and exclude those.

## 11. Presence facts (COST-GCP-020 to COST-GCP-022)

These run from plain `compute.*.list` reads (already covered by the reliability doctor probe), so they still run when the Recommender scope is missing. None carries a dollar figure.

```bash
set -eu
# Resolve the CURRENT gcp target from toolkit.yaml through the shared enumerator — a single block,
# or the SCOUTFLO_TARGET-selected item of a labeled list (no yq required). Never hand-typed: when
# gcp: lists several projects there is no single gcp.project, and cloud spend belongs to exactly one
# project, so picking one silently would attribute another project's bill to this report.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "gcp in $CFG is a labeled list and cloud spend is per project, so this lane will not choose an entry for you: re-run it once per project with SCOUTFLO_TARGET=<label> set and its own SCOUTFLO_AUDIT_DIR. Labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
  _i=0; GCP_IDX=-1
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "$SCOUTFLO_TARGET" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no gcp target in $CFG; labels: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' names no project in $CFG; run /scoutflo:connect"; exit 1; }

# ⚠️ IDIOM, read before adding a check here. `gcloud ... | jq ... || echo "excluded"`
# does NOT work: jq exits 0 on empty stdin, so a DENIED read produces no output, the
# `||` never fires, and the check renders as "nothing found" — indistinguishable from a
# clean project. That is the exact failure `tests/pressure-scenarios/audit-cost/
# blocked-scope-never-reads-as-no-waste.md` forbids. Capture the command's own status
# FIRST (as the three blocks below do), then decide.
# COST-GCP-020: aged snapshots vs the team's stated retention. Report age; do NOT assume a default retention.
SNAP="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute snapshots list --project "$GCP_PROJECT" --format=json 2>&1)" \
  || { echo "COST-GCP-020 reports excluded, reason: snapshots list denied or failed: ${SNAP}"; SNAP=""; }
[ -z "$SNAP" ] || printf '%s' "$SNAP" | jq -r 'sort_by(.creationTimestamp) | .[]
      | "\(.name)\tsrc=\(.sourceDisk // "?" | sub(".*/"; ""))\tGB=\(.diskSizeGb // "?")\tcreated=\(.creationTimestamp)\tstatus=\(.status)"'

# COST-GCP-021: reserved static external IPs not IN_USE (each is billed while idle).
ADDR="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute addresses list --project "$GCP_PROJECT" --format=json 2>&1)" \
  || { echo "COST-GCP-021 reports excluded, reason: addresses list denied or failed: ${ADDR}"; ADDR=""; }
[ -z "$ADDR" ] || printf '%s' "$ADDR" | jq -r '.[] | select(.status == "RESERVED")
      | "\(.name)\tregion=\((.region // "global") | sub(".*/"; ""))\taddress=\(.address)\ttype=\(.addressType // "EXTERNAL")"'

# COST-GCP-022: persistent disks with no attached user (users field empty/absent).
DISKS="$(CLOUDSDK_CORE_DISABLE_PROMPTS=1 gcloud compute disks list --project "$GCP_PROJECT" --format=json 2>&1)" \
  || { echo "COST-GCP-022 reports excluded, reason: disks list denied or failed: ${DISKS}"; DISKS=""; }
[ -z "$DISKS" ] || printf '%s' "$DISKS" | jq -r '.[] | select((.users // []) | length == 0)
      | "\(.name)\tzone=\((.zone // .region) | sub(".*/"; ""))\tGB=\(.sizeGb)\ttype=\((.type // "?") | sub(".*/"; ""))\tcreated=\(.creationTimestamp)"'
```

Expected: any non-empty output is a presence-fact finding, each line naming one concrete resource with its region/zone, size, type, and age — no dollar figure attached. `COST-GCP-020` compares each snapshot's age against the team's own stated retention policy (from business context), never an assumed default; if the team has not stated one, say so in the finding rather than picking a number for them. `COST-GCP-021` and `COST-GCP-022` are the presence-fact counterparts to the native-dollar COST-GCP-004 and COST-GCP-005: a resource that appears here *and* carries a Recommender dollar is reported once under the native check with its figure; the rest stay here as presence facts, so a partial Recommender scope never drops a real idle resource on the floor.

## 12. Rendering the section

Every finding here uses `area: cost-optimization`, `points_recoverable: 0`, and is **report-only**: the `recommendation` states the concrete action and the exact GCP console / `gcloud` path to take it (e.g. "apply the Recommender recommendation from the Recommendation Hub for this resource"), and the audit never resizes, stops, deletes, or purchases anything — those are the mutating verbs in section 13. It carries no `setup-*` remediation pointer, because acting on a cost recommendation (resizing or deleting live infrastructure) is materially riskier than a reliability fix and stays a human decision. Findings render under this parallel section's own heading, never in the scored Findings table.

**Open the section with the savings-summary line**, per [report-template.md](../../../report-standard/report-template.md)'s cost/savings rule, built only from the Recommender-sourced `estimated_monthly_savings_usd` values already on the findings (USD, monthly-window figures only):

> **Potential savings: ~$&lt;sum&gt;/month (~$&lt;sum×12&gt;/year)** across **&lt;n&gt;** opportunities with a GCP Recommender figure; **&lt;m&gt; more** found with no dollar figure (presence facts, listed below). Largest single lever: **$&lt;max&gt;/mo** — &lt;that finding's one-line action&gt;.

Sum only figures copied verbatim from a Recommender `costProjection.cost` where `currencyCode == "USD"` and `duration == "2592000s"`; the annual number is `monthly × 12`, labelled an estimate (`~`, "potential"). State the count *with* a figure separately from the count *without* one, so `$<sum>` is never read as the whole story. Any non-USD or non-monthly Recommender figure is listed with its own currency/period and is **not** folded into the USD total. If no row carries a Recommender figure, write "&lt;n&gt; opportunities found; no GCP-sourced dollar figures available — each is a presence fact to review", never `$0`.

Then render the per-row table, columns `Finding | Resource (zone/region) | Signal source | Current → recommended | Est. monthly savings (GCP-sourced) | Est. annual | Action`. `Current → recommended` shows the shape change where the Recommender gives it (`e2-standard-8 → e2-standard-2`, `idle 30+ days → delete`), else `-`. A row with no GCP-sourced savings figure prints `-` in the savings columns rather than a blank, so it reads as "checked, no number available" rather than "forgot to fill this in".

## 13. Commands this audit must never run

Any of these in an audit transcript is a lane violation, whatever the justification:

- `gcloud recommender recommendations mark-claimed`, `mark-succeeded`, `mark-failed`, `mark-dismissed`, and any `PATCH`/`POST` to `recommender.googleapis.com` `recommendations:mark*` — these mutate recommendation lifecycle state on Google's side. The audit only `list`s and `describe`s.
- `gcloud compute instances stop|start|delete|reset|set-machine-type|update` — acting on an idle/right-sizing recommendation is a setup-lane change, never an audit action.
- `gcloud compute disks delete|resize|snapshot`, `gcloud compute snapshots delete`, `gcloud compute images delete`.
- `gcloud compute addresses delete|release`.
- `gcloud compute commitments create|update` — **purchasing a committed-use discount spends money**; COST-GCP-007 is advisory only.
- `gcloud sql instances patch|delete|restart`, any Cloud SQL tier change.
- `gcloud container clusters resize|update|delete` and any node-pool mutation acting on a GKE cost recommendation.
- `gcloud config set`, `gcloud config unset`, `gcloud config configurations activate|create` (mutates shared local gcloud state; the audit passes explicit `--project` instead), and `gcloud auth login|activate-service-account|application-default login|revoke`.
- `gcloud billing accounts|projects link|unlink`, any budget or billing-account mutation; `bq` DDL/DML (`CREATE`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`) — COST-GCP-023 issues a read-only `SELECT` only.
- Any POST to any webhook, including a smoke test; the toolkit Slack brief in the skill's final phase is the single exception and posts only to the brief webhook from `slack.webhook_env`.
