# findings.json Schema

`findings.json` is the machine-readable result of one audit run. The report, the delta, and the Slack brief all derive from it. Schema identifier: `scoutflo-findings/v1`.

## Example

```json
{
  "schema": "scoutflo-findings/v1",
  "toolkit_version": "0.1.0",
  "skill": "audit-lgtm",
  "target": "lgtm",
  "run_date": "2026-07-17",
  "generated_at": "2026-07-17T14:32:05Z",
  "score": {
    "overall": 68,
    "gate": 85,
    "end_to_end": false,
    "categories": [
      { "name": "Service coverage", "weight": 20, "score": 55, "maturity": "reactive", "checks_passed": 11, "checks_total": 20 },
      { "name": "Alert routing", "weight": 15, "score": 40, "maturity": "reactive", "checks_passed": 4, "checks_total": 10 }
    ],
    "excluded": [
      { "name": "Traces layer", "weight": 15, "reason": "blocked: traces endpoint returned HTTP 502 on every request" }
    ]
  },
  "severity_counts": { "critical": 1, "high": 2, "medium": 4, "low": 3, "info": 1 },
  "findings": [
    {
      "id": "LGTM-014",
      "title": "Default Alertmanager receiver points to a dead webhook",
      "severity": "critical",
      "area": "alert-routing",
      "status": "validated-live",
      "lifecycle": "new",
      "points_recoverable": 2,
      "affected": ["alertmanager/route/default"],
      "evidence": [
        {
          "check": "Default receiver resolves and accepts notifications",
          "command": "curl -fsS --max-time 10 \"${ALERTMANAGER_URL}/api/v2/status\" | jq -r '.config.original' | grep -A3 'webhook_configs'",
          "observed": "url: http://127.0.0.1:9095/alert ; follow-up curl to the receiver URL failed: curl: (7) Failed to connect (exit 7)"
        }
      ],
      "recommendation": "Point the default route at a receiver your team actually watches, then prove delivery with one controlled test alert.",
      "remediation": "setup-lgtm#fix-default-receiver"
    },
    {
      "id": "LGTM-031",
      "title": "Service names differ across metrics and logs for two critical services",
      "severity": "medium",
      "area": "service-coverage",
      "status": "validated-live",
      "lifecycle": "new",
      "points_recoverable": 1,
      "affected": ["checkout", "payments"],
      "evidence": [
        {
          "check": "Service label parity between metrics and log streams",
          "command": "curl -fsS --max-time 10 \"${METRICS_URL}/api/v1/label/service/values\" | jq -r '.data[]' | sort",
          "observed": "metrics: checkout, payments ; logs: checkout-svc, payment ; 2 of 6 critical services do not correlate by label"
        }
      ],
      "recommendation": "Standardize one service label value per service across metrics, logs, and traces. Set it at the collector or resource-attribute level, not per dashboard.",
      "remediation": "setup-lgtm#standardize-service-labels"
    }
  ]
}
```

## Envelope fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | string | yes | Always `scoutflo-findings/v1` for this version |
| `toolkit_version` | string | yes | Plugin version that produced the file |
| `skill` | string | yes | Emitting skill name, e.g. `audit-lgtm` |
| `target` | string | yes | The resolved target segment slug the run wrote under, matching its `<reports-dir>` directory segment: the integration name for a single-block integration (`lgtm`, `grafana`), or `<integration>/<label>` for one target of a labeled multi-target list (`azure/prod-sub`, `clickstack/eu-hyperdx`); the single-block `signoz`/`kubernetes` audits resolve to `signoz/<host>` / `kubernetes/<context>`. See the multi-target example below |
| `run_date` | string | yes | `YYYY-MM-DD`, UTC; must match the directory name |
| `generated_at` | string | yes | ISO 8601 UTC timestamp |
| `score` | object | yes | See below |
| `severity_counts` | object | yes | Count of findings per severity level |
| `findings` | array | yes | Finding objects, highest severity first |
| `coverage` | array | no | Optional per-service coverage rows mirroring the report's coverage matrix |
| `estate` | object | no | Estate sizing recorded by the run: `objects` (integer the sizing pre-check counted) and `path` (`small`, `medium`, `large`, or `xlarge` per [estate-scope-checkpoint.md](estate-scope-checkpoint.md)). `audit-all` reads these for its roll-up; omit only when sizing was impossible |

**Multi-target example.** When one integration is audited across several targets in one environment (a labeled multi-target list — N Azure subscriptions, 3 HyperDX instances), each target writes its own `findings.json` under its own resolved segment, and `target` carries that segment. A two-subscription Azure run writes `azure/prod-sub/<date>/findings.json` with `"target": "azure/prod-sub"` and `azure/nonprod-sub/<date>/findings.json` with `"target": "azure/nonprod-sub"`, so the two never collide. The resolved segment comes from the shared `report-standard/toolkit-targets.sh` enumerator (the multi-target parity gate in [../AGENTS.md](../AGENTS.md) enforces this); a single-block integration keeps the bare integration name.

`score` object:

| Field | Type | Meaning |
| --- | --- | --- |
| `overall` | integer 0-100 | Weighted score across included categories |
| `gate` | integer | The end-to-end gate, `85` (toolkit convention) |
| `end_to_end` | boolean | True only when the gate rules in [severity-and-scoring.md](severity-and-scoring.md) all pass |
| `categories` | array | Per category: `name`, `weight`, `score` (0-100), `maturity` (`reactive`, `proactive`, or `systematic`; definitions in [severity-and-scoring.md](severity-and-scoring.md)), `checks_passed`, `checks_total` |
| `excluded` | array | Categories excluded from scoring, each with `name`, `weight`, `reason`. Empty array when nothing was excluded |

## Finding object fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | Stable check identifier, `<PREFIX>-<NNN>`. See ID rules below |
| `title` | string | yes | One line stating the defect. Plain language, names the affected thing, no secrets |
| `severity` | string | yes | `critical`, `high`, `medium`, `low`, or `info`. Definitions in [severity-and-scoring.md](severity-and-scoring.md) |
| `area` | string | yes | Kebab-case slug of the scorecard category this finding belongs to, e.g. `alert-routing` |
| `status` | string | yes | `validated-live`, `configured`, or `blocked`. See below |
| `lifecycle` | string | yes | `new`, `unchanged`, `regressed`, or `suppressed`. Computed per the finding lifecycle rules below; `resolved` IDs are recorded in the delta, not as open findings |
| `points_recoverable` | integer | yes | Whole points the overall score gains when this finding's check moves to `pass`, computed per the gap model in [severity-and-scoring.md](severity-and-scoring.md). `0` for `info` findings, findings in excluded categories, and findings in a parallel non-scored section (see below) |
| `affected` | array of strings | non-info | Services or objects the finding applies to — the "where", and the correlation join key. Required (non-empty) for every non-`info` finding so the correlation engine can join it to findings from other audits; optional only for `info` (whose observations may be account-scoped). Name the concrete resource/route/alarm/receiver/host, not a vague scope. Use topology.md service names when it exists. Enforced by `check-findings.sh` |
| `impact` | string | no | One line: the concrete consequence if this stays unfixed — the "why it matters". Feeds the report's **Why it matters** line; omit only when the title already makes the consequence obvious |
| `evidence` | array | yes | One or more evidence items; see evidence rules |
| `recommendation` | string | yes | What to do about it, in one or two sentences, addressed to the reader |
| `remediation` | string | yes | Pointer to the fix: a setup skill name, optionally with an anchor (`setup-lgtm#fix-default-receiver`), or a doc anchor in this repo |
| `estimated_monthly_savings_usd` | number | no | Only on findings in a cost/optimization parallel section, and only when the figure comes straight from an AWS-native recommendation source (Compute Optimizer, Cost Explorer) — never a hand-computed estimate. Omit the field entirely rather than guess a number |
| `estimated_monthly_cost_usd` | number | no | A monthly *spend* figure (e.g. current Datadog usage), distinct from `estimated_monthly_savings_usd`, which is a provider-native *saving*. Only on findings in a cost/optimization parallel section, and only when the figure comes straight from the provider's own usage/billing endpoint — never a hand-computed estimate, and never summed as a saving. Omit the field entirely rather than guess a number |

### How report.md renders a finding

The human `report.md` renders each finding as **What's wrong** (from `title`), **Where** (from `affected`), **Why it matters** (from `impact`), and **How to fix** (from `recommendation` + `remediation`), under a plain-English heading, with the coded `id` demoted to a small `ref:` line — see [report-template.md](report-template.md). `findings.json` keeps every field for machine use, and the coded `id` stays the stable key for deltas, evidence, and exemptions. The report is human-first; the JSON is machine-first; they never disagree on the facts.

### Parallel non-scored sections

Some findings genuinely don't belong on the 0-100 reliability score — a cost-optimization opportunity is real and worth reporting, but scoring it on the same axis as reliability creates a perverse incentive (an idle standby replica is "waste" by a cost lens and "correct" by a reliability lens). An audit skill may define its own `area` values that never appear in `score.categories` or `score.excluded` — those findings still live in the normal `findings[]` array (so history, lifecycle, and exemptions all apply unmodified), always carry `points_recoverable: 0`, and render in their own named report section instead of the Findings table. Scoutflo Topology Readiness (`area: topology-readiness`, `TOPO-` prefix) already works this way; the AWS, Azure, and Datadog packs each carry a non-scored Cost & Resource Optimization section (`area: cost-optimization`, prefixed `AWSOPT-`, `AZROPT-`, and `DDOPT-` respectively) as further examples. A category is "excluded" (per the `excluded` field above) only when it was a scoring candidate that couldn't be assessed this run; a parallel-section area was never a scoring candidate at all — don't conflate the two.

Each evidence item:

| Field | Type | Meaning |
| --- | --- | --- |
| `check` | string | What was being verified, as a statement |
| `command` | string | The exact command that was run, with placeholder variables as declared in the skill |
| `observed` | string | What the command actually returned, quoted or tightly summarized with the load-bearing values intact |

## Finding ID rules

- Format: `<PREFIX>-<NNN>`. `PREFIX` is 2 to 6 characters that start with a letter and may contain digits (enforced by `check-findings.sh` as `^[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}$` — so `K8S` and `AWSOPT` are valid). Registered prefixes, one per audit: `ALR` (alert-routing), `AWS` + `AWSOPT` (aws reliability + its non-scored cost section), `AZR` + `AZROPT` (azure reliability + its non-scored cost section), `CS` (clickstack), `DD` + `DDOPT` (datadog reliability + its non-scored cost section), `DO` + `DORT` (digitalocean reliability + its parallel live-runtime section), `ELK` (elk), `GC` (groundcover), `GCP` (gcp), `GRAF` (grafana), `JSM` (jsm), `K8S` (kubernetes), `K8SRT` (the kubernetes parallel live-runtime snapshot section), `LGTM` (lgtm), `PD` (pagerduty), `SIG` (signoz), `SNTRY` (sentry), `ZD` (zenduty), and `TOPO` (the parallel Topology Readiness section). The dedicated `audit-cost` skill emits its own non-scored `scoutflo-cost/v1` file with `COST-<PROVIDER>` IDs — see [cost-schema.md](cost-schema.md). `NNN` is a zero-padded number, e.g. `LGTM-014`, `GRAF-003`. `AWSOPT` is kept distinct from `AWS` so a reader can tell the cost axis from the reliability axis at a glance.
- IDs are stable identifiers from the skill's check catalog, not counters minted per run. The same defect gets the same ID on every run. This is what makes deltas exact.
- Each audit skill maintains its check catalog (in `SKILL.md` or `references/`) assigning one permanent ID per check. Retired IDs are never reused or renumbered.
- One finding per failed check. When one check fails for several services or objects, emit one finding and enumerate them in `affected`.

## Finding lifecycle

Every finding carries `lifecycle`, computed by comparing this run's finding IDs against the previous run and `exemptions.yaml`:

| Value | Meaning |
| --- | --- |
| `new` | ID absent from the previous run |
| `unchanged` | ID present in the previous run, still failing |
| `resolved` | ID present in the previous run, passing now (recorded in the delta, not as an open finding) |
| `regressed` | ID resolved in any earlier run, failing again. The highest-signal state; the executive summary names regressions first |
| `suppressed` | ID matched by a live entry in exemptions.yaml; moved to the Suppressed appendix, excluded from score and severity counts |

First run: every finding is `new`.

## Evidence rules

- **Evidence quotes real command output, never assertions.** "Alertmanager has no receivers configured" is an assertion. `jq '.config.receivers | length'` returning `0` is evidence. If you did not run a command and observe its output, you do not have a finding; you have a suspicion, and it does not go in the file.
- **API errors are evidence.** A `401`, `403`, `404`, timeout, or connection refusal is an observation. Record the status code or exit code and what it implies: wrong path, wrong tenant, missing auth, wrong backend, blocked network. Never convert an upstream error into empty success.
- **Trim, and say so.** Quote the load-bearing lines of output. When you truncate, mark it (`... 214 more lines`).
- **Never include secrets.** No tokens, authorization headers, webhook URLs, DSNs, passwords, cookies, or session values in any field, ever. Endpoints and hostnames may appear because findings.json stays local and out of version control; they must never reach the Slack brief.

## Status values

Short form; full definitions in [severity-and-scoring.md](severity-and-scoring.md):

- `validated-live`: the observed state was confirmed by querying the live system during this run.
- `configured`: the state was seen only in configuration; live behavior was not proven.
- `blocked`: the check could not complete; the evidence records the blocker.
