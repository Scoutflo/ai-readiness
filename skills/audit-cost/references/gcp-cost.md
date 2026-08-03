# audit-cost (GCP): Deep Per-Resource Cost Check Catalog

Runnable, read-only cost checks for the GCP provider phase of [audit-cost](../SKILL.md). This is a **parallel non-scored section**: every finding here carries `points_recoverable: 0` and `area: cost-optimization`, and none of it enters `score.categories` or `score.excluded` (see [severity-and-scoring.md](../../../report-standard/severity-and-scoring.md#parallel-non-scored-sections)). IDs are `COST-GCP-NNN`, a permanently registered prefix that is distinct from the reliability catalog's `GCP-NNN` in [audit-gcp/references/gcp-checks.md](../../audit-gcp/references/gcp-checks.md), so a reader can tell which axis a finding belongs to at a glance. This is deep, per-resource cost analysis — every finding names a concrete resource (instance, disk, address, snapshot, commitment) with its zone/region, size, age, and utilization — never "the project has waste".

## 1. The one hard rule

`estimated_monthly_savings_usd` appears on a finding **only** when the number is copied verbatim from a GCP-native recommendation: the [Recommender API](https://cloud.google.com/recommender/docs) (`recommender.googleapis.com`) `primaryImpact.costProjection.cost` field. Never recompute a dollar figure from raw metrics (CPU idle percent, disk GB, IP-hours) against a price list you assembled — GCP prices vary by region, commitment, sustained-use discount, and negotiated rate, so any number you derive is a guess. Every other check in this file — aged snapshots, reserved-but-unused static IPs, unattached disks, billing spend context — is a **presence/absence fact** reported with no `estimated_monthly_savings_usd` field. This mirrors the toolkit-wide rule that errors are evidence, never invented; applied to cost, an unverified number is worse than no number, because it gets pasted straight into a budget conversation.

- ❌ `COST-GCP-005: 4 persistent disks unattached for 60+ days totalling 900 GB; at $0.04/GB-month that is roughly $36/mo wasted.`
- ✅ `COST-GCP-005: Recommender (google.compute.disk.IdleResourceRecommender) flags disk 'data-scratch-3' (zone us-central1-a, 200 GB, pd-ssd) as idle; estimated_monthly_savings_usd is 34.00, copied verbatim from primaryImpact.costProjection.cost (units=-34, nanos=0, currencyCode=USD, duration=2592000s).`
- ✅ `COST-GCP-021: 4 reserved static external IPs are in state RESERVED (not IN_USE): 'legacy-nat-ip' (region us-central1), ... . No estimated_monthly_savings_usd — this is a presence fact; the idle-IP dollar figure, when GCP produces one, is reported under COST-GCP-004 from the Recommender.`

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
| COST-GCP-010 | Any other COST-category recommender surfaced in the project (GKE, Cloud Run, BigQuery slots, etc.) | Recommender API sweep (`gcloud recommender recommenders list`) | Native — `costProjection.cost`, verbatim |
| COST-GCP-020 | Aged Compute Engine snapshots vs the team's stated retention | Compute `gcloud compute snapshots list` | None (presence fact) |
| COST-GCP-021 | Reserved-but-unused static external IPs | Compute `gcloud compute addresses list` | None (presence fact) |
| COST-GCP-022 | Unattached / detached persistent disks | Compute `gcloud compute disks list` | None (presence fact) |
| COST-GCP-023 | Spend breakdown by service/SKU (context, not savings) | Cloud Billing BigQuery export | None (context; actual spend, not a savings figure) |

## 3. Conventions

- **Identity preamble.** Every block that talks to a Google API declares its own project and mints its own identity, so each block runs alone in a fresh shell and the run holds exactly one identity with no silent fallback:

```bash
GCP_PROJECT="your-project-id"   # gcp.project — clearly-marked config placeholder, never a hardcoded account
# gcp.credentials_env (optional) names GOOGLE_APPLICATION_CREDENTIALS, the key-file path variable.
# Set: the key file is the identity for gcloud and REST alike. Unset: your active gcloud login is.
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
  TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"
fi
```

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
awk -F'\t' '$1 == "gcp" && $2 == "cost-permissions" {print $5, $7}' "$MATRIX"
```

Expected: `pass -` when the Recommender checks can run, or `skipped <reason>` when they cannot. A `skipped` result means COST-GCP-001 through COST-GCP-010 render exactly one line: "GCP Recommender cost checks: excluded, reason: `<the exact hint from the matrix row>`", and none of them runs this cycle. The **presence-fact** checks — COST-GCP-020 (snapshots), COST-GCP-021 (static IPs), COST-GCP-022 (unattached disks) — need only plain `compute.*.list` permissions already covered by the reliability doctor probe, so they may still run even when the Recommender scope is missing; state that split explicitly rather than excluding the whole section when only the native-dollar part is blocked. COST-GCP-023 (billing context) depends separately on a configured Cloud Billing BigQuery export and BigQuery read access; a missing export excludes just that one context row with its reason.

## 5. The Recommender extraction (shared by COST-GCP-001 to COST-GCP-010)

Every native-dollar check pulls one recommender and extracts the verbatim cost figure the same way. This is the single place the dollar is read; the per-check sections below only change the `--recommender=` flag and the location set. Enumerate the project's zones/regions first, then loop:

```bash
set -eu
GCP_PROJECT="your-project-id"       # gcp.project
RECOMMENDER="google.compute.instance.IdleResourceRecommender"   # the flag changes per check; location kind must match (see section 3)
# Zonal recommenders (instances, disks) loop over zones; regional ones (addresses, MIGs, commitments, Cloud SQL) over regions; images use global.
LOCATIONS="$(gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"

for LOC in $LOCATIONS; do
  gcloud recommender recommendations list \
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
GCP_PROJECT="your-project-id"   # gcp.project
ZONES="$(gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
REGIONS="$(gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"

# COST-GCP-001: idle VMs — zonal. Subtypes STOP_VM / SNAPSHOT_AND_DELETE / DELETE_VM.
for Z in $ZONES; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.instance.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-002: VM machine-type right-sizing — zonal. Subtype CHANGE_MACHINE_TYPE.
for Z in $ZONES; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.instance.MachineTypeRecommender" --format=json 2>/dev/null
done
# COST-GCP-003: MIG right-sizing — regional (regional MIGs) and zonal (zonal MIGs); check both.
for R in $REGIONS; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.instanceGroupManager.MachineTypeRecommender" --format=json 2>/dev/null
done
```

Expected: each recommendation names one instance or MIG, its current and recommended machine type (in `content.operationGroups`), and the verbatim cost. Pipe each through the section 5 jq. `COST-GCP-001`'s `STOP_VM` subtype means the VM is a stop candidate (recoverable), while `SNAPSHOT_AND_DELETE`/`DELETE_VM` mean delete candidates — carry the subtype into the finding so the reader knows whether the action is reversible. A VM the Recommender rates idle that your team knows is a warm standby is a false positive to annotate, not silently drop — record why it stays.

## 7. Idle networking and storage recommenders (COST-GCP-004 to COST-GCP-006)

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
ZONES="$(gcloud compute zones list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"
REGIONS="$(gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"

# COST-GCP-004: idle reserved external IPs — regional. Subtype DELETE_ADDRESS.
for R in $REGIONS; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.address.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-005: idle persistent disks — zonal. Subtype SNAPSHOT_AND_DELETE_DISK / DELETE_DISK.
for Z in $ZONES; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$Z" \
    --recommender="google.compute.disk.IdleResourceRecommender" --format=json 2>/dev/null
done
# COST-GCP-006: idle custom images — global.
gcloud recommender recommendations list --project="$GCP_PROJECT" --location="global" \
  --recommender="google.compute.image.IdleResourceRecommender" --format=json 2>/dev/null
```

Expected: each recommendation names one address (with its region), disk (with its zone, size, and type), or image, and its verbatim cost. Pipe each through the section 5 jq. `COST-GCP-004` overlaps deliberately with the presence-fact `COST-GCP-021`: when the Recommender has a dollar for an idle IP, the finding is COST-GCP-004 with the native figure; the reserved-but-unused IPs the Recommender has *not* costed still surface as COST-GCP-021 presence facts, so nothing is lost when the Recommender scope is present but incomplete. Note the same overlap for disks (COST-GCP-005 native vs COST-GCP-022 presence).

## 8. Commitments and databases (COST-GCP-007 to COST-GCP-009)

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
REGIONS="$(gcloud compute regions list --project "$GCP_PROJECT" --filter='status=UP' --format='value(name)')"

# COST-GCP-007: committed-use discount purchase opportunities — regional. Subtype PURCHASE_COMMITMENT.
# The cost figure is the projected SAVING from committing to steady-state usage — read verbatim, do not model it yourself.
for R in $REGIONS; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.compute.commitment.UsageCommitmentRecommender" --format=json 2>/dev/null
done
# COST-GCP-008 / COST-GCP-009: Cloud SQL idle and over-provisioned — regional.
for R in $REGIONS; do
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.cloudsql.instance.IdleRecommender" --format=json 2>/dev/null
  gcloud recommender recommendations list --project="$GCP_PROJECT" --location="$R" \
    --recommender="google.cloudsql.instance.OverprovisionedRecommender" --format=json 2>/dev/null
done
```

Expected: `COST-GCP-007` recommendations describe a commitment to purchase (family, region, vCPU/memory amount) with the Recommender's own projected saving — a **commitment is a spend decision**, so the finding is advisory-only and names the commitment term the Recommender assumed (1-year vs 3-year changes the number). `COST-GCP-008`/`COST-GCP-009` name the Cloud SQL instance, its tier, and the recommended change. Pipe each through the section 5 jq. If the Cloud SQL Admin API or its recommender is not enabled in the project, that check reports `excluded` (API disabled), never an empty pass.

## 9. COST-category recommender sweep (COST-GCP-010)

New COST-category recommenders appear over time (GKE cost optimization, Cloud Run, BigQuery slot reservations, Spanner). Rather than hardcode a list that silently goes stale, enumerate the recommenders the project actually exposes and pull COST recommendations from any not already covered by COST-GCP-001..009:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
# List the recommenders available for this project, then run section 5's extraction against any
# COST-category recommender not already handled above (e.g. a GKE or Cloud Run cost recommender when present).
gcloud recommender recommenders list --format='value(name)' 2>/dev/null | grep -Ei 'cost|idle|commitment|machinetype|overprovision' || true
```

Expected: the printed list is the set of recommender IDs to sweep for this project; run the section 5 extraction against each, in each recommender's correct location kind, and emit any ACTIVE COST recommendation with its verbatim figure. This keeps GKE and other emerging cost recommenders in scope **only when GCP actually surfaces a costed recommendation for them** — the honest alternative to inventing a GKE idle-node dollar the platform has not produced. A recommender that returns no COST recommendations is not a finding; a recommender the project does not expose is simply absent from the list, not an error.

## 10. Spend breakdown by service and SKU — context only (COST-GCP-023)

This is **context, not a savings figure**: it shows where the money actually goes so the ranked opportunities above have a denominator, but actual spend never populates `estimated_monthly_savings_usd`. GCP has **no gcloud command that returns spend by SKU** — the canonical programmatic source is the [Cloud Billing BigQuery export](https://cloud.google.com/billing/docs/how-to/export-data-bigquery). First confirm the linked billing account (read-only), then query the export if it is configured:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
# Read-only: which billing account is this project linked to, and is billing enabled.
gcloud billing projects describe "$GCP_PROJECT" \
  --format='value(billingAccountName,billingEnabled)' 2>/dev/null \
  || echo "billing.projects.get denied or Cloud Billing API off; COST-GCP-023 reports excluded (no billing scope)"
```

```bash
set -eu
GCP_PROJECT="your-project-id"          # gcp.project
BILLING_DATASET="your_billing_dataset" # gcp.billing_bq_dataset — clearly-marked placeholder; the dataset holding gcp_billing_export_v1_*
BILLING_TABLE="gcp_billing_export_v1_XXXXXX_XXXXXX_XXXXXX"  # the standard-usage export table id
# Last full month spend by service and SKU. Read-only SELECT; no table is created or modified.
bq query --project_id="$GCP_PROJECT" --use_legacy_sql=false --format=prettyjson \
'SELECT service.description AS service, sku.description AS sku,
        ROUND(SUM(cost), 2) AS cost_usd, currency
   FROM `'"${GCP_PROJECT}.${BILLING_DATASET}.${BILLING_TABLE}"'`
  WHERE usage_start_time >= TIMESTAMP(DATE_TRUNC(DATE_SUB(CURRENT_DATE(), INTERVAL 1 MONTH), MONTH))
    AND usage_start_time <  TIMESTAMP(DATE_TRUNC(CURRENT_DATE(), MONTH))
  GROUP BY service, sku, currency
  ORDER BY cost_usd DESC
  LIMIT 25' 2>/dev/null \
  || echo "billing BigQuery export not configured or bq denied; COST-GCP-023 reports excluded (no spend export)"
```

Expected: the top services and SKUs by last-month spend, in the export's own `currency`, reported as **context** beside the ranked savings — for example, so a reader sees that Compute Engine SKUs dominate the bill, which frames why the idle-VM and CUD recommendations matter most. If no billing export is configured, COST-GCP-023 reports `excluded, reason: "no Cloud Billing BigQuery export configured"`, not a fabricated breakdown. Never present spend as savings; the two are different numbers and mixing them misleads a budget conversation.

## 11. Presence facts (COST-GCP-020 to COST-GCP-022)

These run from plain `compute.*.list` reads (already covered by the reliability doctor probe), so they still run when the Recommender scope is missing. None carries a dollar figure.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project

# COST-GCP-020: aged snapshots vs the team's stated retention. Report age; do NOT assume a default retention.
gcloud compute snapshots list --project "$GCP_PROJECT" --format=json \
  | jq -r 'sort_by(.creationTimestamp) | .[]
      | "\(.name)\tsrc=\(.sourceDisk // "?" | sub(".*/"; ""))\tGB=\(.diskSizeGb // "?")\tcreated=\(.creationTimestamp)\tstatus=\(.status)"'

# COST-GCP-021: reserved static external IPs not IN_USE (each is billed while idle).
gcloud compute addresses list --project "$GCP_PROJECT" --format=json \
  | jq -r '.[] | select(.status == "RESERVED")
      | "\(.name)\tregion=\((.region // "global") | sub(".*/"; ""))\taddress=\(.address)\ttype=\(.addressType // "EXTERNAL")"'

# COST-GCP-022: persistent disks with no attached user (users field empty/absent).
gcloud compute disks list --project "$GCP_PROJECT" --format=json \
  | jq -r '.[] | select((.users // []) | length == 0)
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
