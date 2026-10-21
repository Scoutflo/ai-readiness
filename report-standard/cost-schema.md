# cost-findings.json Schema (`scoutflo-cost/v1`)

The machine-readable result of one `audit-cost` run. It is a **ranked-savings**
report, deliberately **not** a 0–100 scored report: a cost report ranks
opportunities by provider-native dollars, it does not fold a dollar-savings axis
into the reliability score (see the "parallel non-scored section" rule in
[severity-and-scoring.md](severity-and-scoring.md) — scoring waste on the
reliability axis creates perverse incentives). So this schema carries **no
`score` object**. Its report (`report.md`) leads with a savings summary line, not
a `**Score: /100**` line, and is validated by
[`check-cost.sh`](check-cost.sh), not `check-findings.sh`.

Schema identifier: `scoutflo-cost/v1`.

## Example

```json
{
  "schema": "scoutflo-cost/v1",
  "toolkit_version": "0.1.79",
  "skill": "audit-cost",
  "target": "cost",
  "run_date": "2026-08-03",
  "generated_at": "2026-08-03T12:00:00Z",
  "providers_covered": ["aws", "gcp"],
  "providers_excluded": [
    { "provider": "datadog", "reason": "datadog.cost_checks false in toolkit.yaml" }
  ],
  "summary": {
    "opportunities_total": 14,
    "opportunities_with_native_figure": 5,
    "presence_fact_opportunities": 9,
    "monthly_savings_identified_usd": 1240,
    "annual_savings_identified_usd": 14880,
    "largest_single_lever": { "id": "COST-AWS-001", "monthly_usd": 340, "title": "Right-size db-primary (over-provisioned)" },
    "deduplicated_overlaps": 1
  },
  "findings": [
    {
      "id": "COST-AWS-001",
      "title": "Compute Optimizer: db.r5.xlarge over-provisioned",
      "provider": "aws",
      "area": "cost-optimization",
      "signal": "rightsizing",
      "status": "validated-live",
      "affected": ["rds/db-primary (ap-south-2, db.r5.xlarge)"],
      "estimated_monthly_savings_usd": 340,
      "savings_source": "aws-compute-optimizer",
      "utilization": "max CPU 8% / max mem 22% over 14d",
      "evidence": [
        {
          "check": "Compute Optimizer RDS rightsizing recommendation",
          "command": "aws compute-optimizer get-rds-database-recommendations --region ap-south-2 --profile <profile>",
          "observed": "db-primary: finding=Overprovisioned, recommended db.r5.large, estimatedMonthlySavings.value=340 USD"
        }
      ],
      "recommendation": "Right-size db-primary from db.r5.xlarge to db.r5.large during a maintenance window; validate the workload fits the smaller class first.",
      "deduplicated": false
    },
    {
      "id": "COST-AWS-004",
      "title": "4 EBS volumes unattached 40+ days",
      "provider": "aws",
      "area": "cost-optimization",
      "signal": "unattached-storage",
      "status": "validated-live",
      "affected": ["vol-0a1 (100GB gp3)", "vol-0b2 (50GB gp2)", "vol-0c3 (50GB gp2)", "vol-0d4 (30GB gp2)"],
      "estimated_monthly_savings_usd": null,
      "savings_source": null,
      "evidence": [
        {
          "check": "Unattached EBS volumes",
          "command": "aws ec2 describe-volumes --filters Name=status,Values=available --region ap-south-2 --profile <profile>",
          "observed": "4 volumes in 'available' (unattached) state; ids and sizes listed; no AWS-native dollar figure for deletion savings"
        }
      ],
      "recommendation": "Confirm each volume is truly orphaned (snapshot if unsure), then delete. No provider-native dollar figure — this is a presence fact.",
      "deduplicated": false
    }
  ]
}
```

## Envelope fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | string | yes | Always `scoutflo-cost/v1` |
| `toolkit_version` | string | yes | Plugin version that produced the file |
| `skill` | string | yes | Always `audit-cost` |
| `target` | string | yes | Always `cost` (the run directory name) |
| `run_date` | string | yes | `YYYY-MM-DD`, UTC; matches the directory name |
| `generated_at` | string | yes | ISO 8601 UTC timestamp |
| `providers_covered` | array | yes | Provider slugs whose cost checks actually ran this run |
| `providers_excluded` | array | **yes** | Each `{provider, reason}`, both non-empty — a configured provider whose cost section was excluded (missing scope, `cost_checks:false`, unreachable). Use `[]` when nothing was excluded. Never silently dropped: `check-cost.sh` enforces the field's presence, that every entry names a reason, that no provider appears in both this and `providers_covered`, and that **a run with no provider-native dollar at all names at least one exclusion** — otherwise "could not look" renders identically to "nothing to save" |
| `summary` | object | yes | Savings roll-up; see below |
| `findings` | array | yes | Opportunity objects, ranked: native-figure findings by descending `estimated_monthly_savings_usd` first, then presence facts |

## `summary` object

| Field | Type | Meaning |
| --- | --- | --- |
| `opportunities_total` | integer | Count of all findings |
| `opportunities_with_native_figure` | integer | Findings carrying a provider-native `estimated_monthly_savings_usd` |
| `presence_fact_opportunities` | integer | Findings with no dollar figure (presence facts) |
| `monthly_savings_identified_usd` | number | Sum of **only** the provider-native `estimated_monthly_savings_usd` values. Never includes a recomputed or presence-fact number |
| `annual_savings_identified_usd` | number | `monthly_savings_identified_usd * 12`, labelled an estimate |
| `largest_single_lever` | object\|null | `{id, monthly_usd, title}` of the highest native-figure finding, or null if none |
| `indicative_monthly_usd` | number | Sum of the non-null `indicative_monthly_usd` values, reported **separately** and never added to `monthly_savings_identified_usd`. `0` when none |
| `observed_monthly_spend` | object\|null | `{amount, currency, period, source}` — actual spend for the audited scope, from the billing export. The **denominator**: without it a savings figure has no scale |
| `savings_pct_of_spend` | number\|null | `monthly_savings_identified_usd` as a percentage of `observed_monthly_spend` converted to USD, or `null` when spend is unknown. Two separate numbers do not tell a reader whether 2% or 40% of the bill was found; this does |
| `unassessed_monthly_spend` | object\|null | `{amount, currency, projects_or_targets, reason}` — spend that billed but **no check ran against** (COST-GCP-034 and any `assessable:false` target). Reported beside the savings so a clean result is never mistaken for a clean estate |
| `deduplicated_overlaps` | integer | Findings annotated as overlapping a prior audit's cost finding via correlation.json |

The two counts (`_with_native_figure` vs `presence_fact_`) MUST be reported
separately so the reader never mistakes the summed dollar figure for the whole
story when many opportunities have no number.

## Finding object fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | `COST-<PROV>-NNN`, stable, never reused |
| `title` | string | yes | One line naming the opportunity, no secrets |
| `provider` | string | yes | Provider slug (`aws`, `gcp`, `kubernetes`, `datadog`, `digitalocean`, `signoz`, `newrelic`) |
| `area` | string | yes | Always `cost-optimization` |
| `signal` | string | yes | Kebab-case class: `rightsizing`, `commitment-coverage`, `idle-resource`, `unattached-storage`, `snapshot-sprawl`, `over-provisioned-requests`, `metric-cardinality`, `log-volume`, etc. |
| `status` | string | yes | `validated-live`, `configured`, or `blocked` (same vocabulary as the scored schema) |
| `affected` | array | yes | The concrete resource(s): id, name, region/zone, size — never a vague scope |
| `estimated_monthly_savings_usd` | number\|null | yes | Present **only** when copied verbatim from a provider-native recommendation API; `null` for every presence fact. Never recomputed |
| `savings_source` | string\|null | yes | The provider API the figure came from (e.g. `aws-compute-optimizer`, `gcp-recommender`), or `null` when no figure |
| `evidence` | array | yes | ≥1 `{check, command, observed}`; the command is the real read-only call, `observed` is the trimmed real output |
| `recommendation` | string | yes | What to do, in one or two sentences |
| `utilization` | string | no | The observed utilization backing a rightsizing/idle finding |
| `basis` | string | no | **Required on any finding whose number came from a measurement window**: the exact basis, e.g. `p95 over 7d`, `max over 7d`, or `snapshot <ISO ts>`. One finding carries ONE basis — never mix windowed and snapshot rows in a single finding; split them so a snapshot is never read as a trend |
| `indicative_monthly_usd` | number\|null | no | A **third class** of figure: computed from the provider's own **published price for the SKU already on the bill**, applied to a quantity from the billing export or a provider API. A ceiling **before** committed-use, sustained-use and negotiated discounts. **Never** summed into `monthly_savings_identified_usd`, never annualised into a headline, and always rendered in its own column labelled "indicative, list price, before your discounts" |
| `indicative_source` | string\|null | no | **Required whenever `indicative_monthly_usd` is non-null**: the SKU and published price basis used, plus the single priced step it describes (e.g. `one tier down`, `one storage-class transition`, `premium-minus-standard rate delta`). Without it the figure is an unsourced guess and the validator rejects it |
| `assessable` | boolean | no | `false` when the resource **bills but could not be assessed** this run (unreachable cluster, denied scope). Its spend still appears in the context tables, so saying so is what stops billed-but-unchecked spend reading as healthy |
| `deduplicated` | boolean | no | True when correlation.json shows this overlaps a prior audit's cost finding |

## The one hard rule (enforced by `check-cost.sh`)

`estimated_monthly_savings_usd` is non-null **only** when the number came
straight from a provider-native recommendation API response, copied verbatim —
never recomputed from raw metrics against a price table. A finding with a
non-null figure must carry a non-null `savings_source`. `monthly_savings_identified_usd`
must equal the sum of exactly the non-null `estimated_monthly_savings_usd`
values. A presence fact carries `null`, and is reported for its own sake (a
listed, named resource to review), never with a guessed dollar value. An
unverified number is worse than no number — it gets pasted into a budget.

## How `report.md` renders this

Per [report-template.md](report-template.md)'s cost/savings rule: the section
**leads with the savings summary line** (potential $/mo and $/yr, count *with* a
figure separate from count *without*, the single biggest lever), then a
per-provider ranked table (resource, region, signal, `$X/mo` or `—`), then the
top opportunities in What / Where / Why / How / Done-when shape, then the
evidence appendix. No Scorecard, no `**Score: /100**` line — those belong to the
scored audits only.
