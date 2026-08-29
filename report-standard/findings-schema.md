# findings.json Schema

`findings.json` is the machine-readable result of one audit run. The report, the delta, and the Slack brief all derive from it. Evidence-aware audit emitters use schema identifier `scoutflo-findings/v2`. The validator continues to accept `scoutflo-findings/v1` artifacts for historical data and for audit skills that have not yet completed the staged v2 migration.

Version 2 adds a normalized `checks[]` ledger. The score is verified against that ledger, blocked checks are reported as unassessed instead of being treated as failures, and assessment coverage is shown separately from readiness. This prevents a missing permission from looking like a broken service and prevents a high score from hiding a mostly blocked audit.

## Example

```json
{
  "schema": "scoutflo-findings/v2",
  "toolkit_version": "0.1.0",
  "skill": "audit-lgtm",
  "target": "lgtm",
  "run_date": "2026-07-17",
  "generated_at": "2026-07-17T14:32:05Z",
  "checks": [
    { "id": "LGTM-001", "category": "Service coverage", "result": "pass" },
    { "id": "LGTM-014", "category": "Alert routing", "result": "fail", "reason": "The configured default receiver refused the live read-only reachability probe." },
    { "id": "LGTM-031", "category": "Service coverage", "result": "partial", "reason": "Two of six critical services use different names across signals." },
    { "id": "LGTM-040", "category": "Traces layer", "result": "blocked", "reason": "The traces endpoint returned HTTP 502 on every read." },
    { "id": "LGTM-050", "category": "Reliability and security", "result": "not-in-scope", "reason": "This externally managed backend is outside the declared infrastructure scope." }
  ],
  "score": {
    "overall": 42,
    "state": "assessed",
    "gate": 85,
    "end_to_end": false,
    "scoring_model": "assessed-only-v1",
    "check_set": "cksum-v2:375363344:131",
    "assessment": {
      "applicable_checks": 4,
      "assessed_checks": 3,
      "scored_checks": 3,
      "blocked_checks": 1,
      "suppressed_checks": 0,
      "not_in_scope_checks": 1,
      "coverage_percent": 75
    },
    "categories": [
      { "name": "Service coverage", "weight": 20, "score": 75, "maturity": "reactive", "checks_passed": 1, "checks_partial": 1, "checks_failed": 0, "checks_blocked": 0, "checks_suppressed": 0, "checks_not_in_scope": 0, "checks_total": 2 },
      { "name": "Alert routing", "weight": 15, "score": 0, "maturity": "reactive", "checks_passed": 0, "checks_partial": 0, "checks_failed": 1, "checks_blocked": 0, "checks_suppressed": 0, "checks_not_in_scope": 0, "checks_total": 1 },
      { "name": "Traces layer", "weight": 15, "score": 0, "maturity": "reactive", "checks_passed": 0, "checks_partial": 0, "checks_failed": 0, "checks_blocked": 1, "checks_suppressed": 0, "checks_not_in_scope": 0, "checks_total": 0 },
      { "name": "Reliability and security", "weight": 50, "score": 0, "maturity": "reactive", "checks_passed": 0, "checks_partial": 0, "checks_failed": 0, "checks_blocked": 0, "checks_suppressed": 0, "checks_not_in_scope": 1, "checks_total": 0 }
    ],
    "excluded": [
      { "name": "Traces layer", "weight": 15, "reason": "blocked: traces endpoint returned HTTP 502 on every request" },
      { "name": "Reliability and security", "weight": 50, "reason": "not in scope: externally managed backend" }
    ]
  },
  "severity_counts": { "critical": 1, "high": 0, "medium": 1, "low": 1, "info": 0 },
  "findings": [
    {
      "id": "LGTM-014",
      "title": "Default Alertmanager receiver points to a dead webhook",
      "severity": "critical",
      "area": "alert-routing",
      "status": "validated-live",
      "lifecycle": "new",
      "scoring_scope": "readiness",
      "report_lanes": ["general-audit", "ai-sre-readiness"],
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
      "scoring_scope": "readiness",
      "report_lanes": ["ai-sre-readiness"],
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
    },
    {
      "id": "LGTM-040",
      "title": "The traces read path could not be assessed",
      "severity": "low",
      "area": "traces-layer",
      "status": "blocked",
      "lifecycle": "new",
      "scoring_scope": "readiness",
      "report_lanes": ["general-audit", "ai-sre-readiness"],
      "points_recoverable": 0,
      "affected": ["tempo/query-api"],
      "evidence": [
        {
          "check": "The traces endpoint returns a readable response",
          "command": "curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \"${TRACES_URL}/api/search\"",
          "observed": "HTTP 502 on every read attempt"
        }
      ],
      "recommendation": "Restore or authorize the traces read path, then rerun this check before drawing a readiness conclusion.",
      "remediation": "audit-lgtm#traces-layer"
    }
  ]
}
```

## Envelope fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | string | yes | `scoutflo-findings/v2` for evidence-aware emitters; `scoutflo-findings/v1` remains accepted for historical data and staged-migration compatibility |
| `toolkit_version` | string | yes | Plugin version that produced the file |
| `skill` | string | yes | Emitting skill name, e.g. `audit-lgtm` |
| `target` | string | yes | The resolved target segment slug the run wrote under, matching its `<reports-dir>` directory segment: the integration name for a single-block integration (`lgtm`, `grafana`), or `<integration>/<label>` for one target of a labeled multi-target list (`azure/prod-sub`, `clickstack/eu-hyperdx`); the single-block `signoz`/`kubernetes` audits resolve to `signoz/<host>` / `kubernetes/<context>`. See the multi-target example below |
| `run_date` | string | yes | `YYYY-MM-DD`, UTC; must match the directory name |
| `generated_at` | string | yes | ISO 8601 UTC timestamp |
| `score` | object | yes | See below |
| `checks` | array | v2: yes; v1: no | One normalized result per catalog check. This is the score input and must include pass, partial, fail, blocked, and not-in-scope checks rather than findings only |
| `severity_counts` | object | yes | Count of findings per severity level |
| `findings` | array | yes | Finding objects, highest severity first |
| `coverage` | array | no | Optional per-service coverage rows mirroring the report's coverage matrix |
| `estate` | object | no | Estate sizing recorded by the run: `objects` (integer the sizing pre-check counted) and `path` (`small`, `medium`, `large`, or `xlarge` per [estate-scope-checkpoint.md](estate-scope-checkpoint.md)). `audit-all` reads these for its roll-up; omit only when sizing was impossible |

**Multi-target example.** When one integration is audited across several targets in one environment (a labeled multi-target list — N Azure subscriptions, 3 HyperDX instances), each target writes its own `findings.json` under its own resolved segment, and `target` carries that segment. A two-subscription Azure run writes `azure/prod-sub/<date>/findings.json` with `"target": "azure/prod-sub"` and `azure/nonprod-sub/<date>/findings.json` with `"target": "azure/nonprod-sub"`, so the two never collide. The resolved segment comes from the shared `report-standard/toolkit-targets.sh` enumerator (the multi-target parity gate in [../AGENTS.md](../AGENTS.md) enforces this); a single-block integration keeps the bare integration name.

`score` object:

| Field | Type | Meaning |
| --- | --- | --- |
| `overall` | integer 0-100 or null | Weighted score across included categories; null only when `state` is `unassessed` |
| `state` | string | v2: `assessed` when at least one unsuppressed check was scored; `unassessed` when no check remains in the readiness denominator because all applicable checks were blocked or suppressed. An unassessed run uses `overall: null` |
| `gate` | integer | The end-to-end gate, `85` (toolkit convention) |
| `end_to_end` | boolean | True only when the gate rules in [severity-and-scoring.md](severity-and-scoring.md) all pass |
| `scoring_model` | string | v2: always `assessed-only-v1` |
| `check_set` | string | v2: deterministic fingerprint of the sorted check IDs + category names **and the category weights + gate**. Raw score movement is comparable only when this and `scoring_model` match — a category re-weighting changes the fingerprint, so a re-weighted run is correctly treated as incomparable rather than plotted as a real delta |
| `assessment` | object | v2: `applicable_checks`, `assessed_checks`, `scored_checks`, `blocked_checks`, `suppressed_checks`, `not_in_scope_checks`, and `coverage_percent`; all are recomputed by `check-findings.sh`. Suppressed checks were assessed but are excluded from readiness scoring by an active exemption |
| `categories` | array | Per category: `name`, `weight`, `score` (0-100), `maturity`, `checks_passed`, `checks_partial`, `checks_failed`, `checks_blocked`, `checks_suppressed`, `checks_not_in_scope`, and `checks_total`. In v2, `checks_total` is the unsuppressed readiness denominator; blocked and suppressed checks are shown separately |
| `excluded` | array | Categories excluded from scoring, each with `name`, `weight`, `reason`. Empty array when nothing was excluded |

## Check ledger (v2)

Each `checks[]` row has exactly one stable check ID, its scorecard category, and one result:

| Result | Meaning | Readiness score |
| --- | --- | --- |
| `pass` | Verified live and healthy | 1.0 credit |
| `partial` | Assessed and incomplete, stale, or only partly healthy | 0.5 credit; `reason` required |
| `fail` | Assessed and verified absent or broken | 0 credit |
| `blocked` | No conclusion was possible because the read failed or evidence was unavailable | Excluded from the readiness denominator; `reason` required |
| `not-in-scope` | Deliberately not applicable to this target | Excluded from readiness and assessment-coverage denominators; `reason` required |

For a readiness finding, an active exemption is represented on the original
`partial` or `fail` row with `"suppressed": true` and a non-empty
`suppression_reason`. The same-ID finding must use `lifecycle: "suppressed"`
and `points_recoverable: 0`. Suppression does not rewrite the observed result,
but it removes that row from the readiness denominator. Because the evidence
was still collected, a suppressed row counts as assessed for assessment
coverage. Do not suppress `pass`, `blocked`, or `not-in-scope` rows. An
explicitly `non-scored` finding has no check row; its exemption changes only the
finding lifecycle and never affects readiness arithmetic.

`check-findings.sh` recomputes every category score and the assessment coverage from this ledger. Every `partial`, `fail`, or `blocked` row must have exactly one same-ID finding. Every readiness finding must point back to one of those non-pass rows; a `pass` or `not-in-scope` row cannot carry an open finding. A deliberately separate observation, such as an AWS cost-optimization opportunity, may omit a check row only when it explicitly declares `scoring_scope: "non-scored"` and `points_recoverable: 0`. A blocked finding carries `status: blocked` and `points_recoverable: 0`; the next action is to unlock evidence, not to claim the underlying system is broken.

Every v2 finding also declares `report_lanes`. This is a presentation and ownership split, not a second severity model and not a second invented score. List both lanes when an operational defect also blocks trustworthy AI-assisted diagnosis. Do not classify a generic optimization as AI SRE readiness unless the evidence shows that it affects telemetry quality, correlation, incident context, or action safety.

The `check_set` value is a fingerprint over the check ledger **and** the scoring model
(each check's id + category, plus every category's name + weight, plus the gate), so a
pure re-weighting is correctly treated as incomparable instead of yielding a fabricated
trend delta:

```bash
jq -r '
  ( [ .checks[] | "chk\t" + .id + "\t" + .category ]
    + [ .score.categories[] | "cat\t" + .name + "\t" + (.weight|tostring) ]
    + [ "gate\t" + ((.score.gate // 85)|tostring) ]
  ) | sort | .[]' findings.json \
  | LC_ALL=C cksum \
  | awk '{print "cksum-v2:" $1 ":" $2}'
```

## Finding object fields

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | yes | Stable check identifier, `<PREFIX>-<NNN>`. See ID rules below |
| `title` | string | yes | One line stating the defect. Plain language, names the affected thing, no secrets |
| `severity` | string | yes | `critical`, `high`, `medium`, `low`, or `info`. Definitions in [severity-and-scoring.md](severity-and-scoring.md) |
| `area` | string | yes | Kebab-case slug of the scorecard category this finding belongs to, e.g. `alert-routing` |
| `status` | string | yes | `validated-live`, `configured`, or `blocked`. See below |
| `lifecycle` | string | yes | `new`, `unchanged`, `regressed`, or `suppressed`. Computed per the finding lifecycle rules below; `resolved` IDs are recorded in the delta, not as open findings |
| `report_lanes` | array of strings | v2: yes; v1: no | One or both of `general-audit` and `ai-sre-readiness`. General audit covers reliability, security, backup, capacity, alerting, and operational hygiene. AI SRE readiness covers whether telemetry, identity, topology, ownership, change context, and routing evidence are sufficient for trustworthy RCA or automation |
| `points_recoverable` | integer | yes | Whole points the overall score gains when this finding's check moves to `pass`, computed per the gap model in [severity-and-scoring.md](severity-and-scoring.md). `0` for `info` findings, findings in excluded categories, and findings in a parallel non-scored section (see below) |
| `scoring_scope` | string | v2: yes | `readiness` for a finding linked to a same-ID non-pass `checks[]` row; `non-scored` only for an intentionally separate finding with no check row and zero recoverable readiness points |
| `affected` | array of strings | non-info | Services or objects the finding applies to — the "where", and the correlation join key. Required (non-empty) for every non-`info` finding so the correlation engine can join it to findings from other audits; optional only for `info` (whose observations may be account-scoped). Name the concrete resource/route/alarm/receiver/host, not a vague scope. Use topology.md service names when it exists. Enforced by `check-findings.sh` |
| `impact` | string | no | One line: the concrete consequence if this stays unfixed — the "why it matters". Feeds the report's **Why it matters** line; omit only when the title already makes the consequence obvious |
| `evidence` | array | yes | One or more evidence items; see evidence rules |
| `recommendation` | string | yes | What to do about it, in one or two sentences, addressed to the reader |
| `remediation` | string | yes | Pointer to the fix: a setup skill name, optionally with an anchor (`setup-lgtm#fix-default-receiver`), or a doc anchor in this repo |
| `estimated_monthly_savings_usd` | number | no | Only on findings in a cost/optimization parallel section, and only when the figure comes straight from an AWS-native recommendation source (Compute Optimizer, Cost Explorer) — never a hand-computed estimate. Omit the field entirely rather than guess a number |
| `estimated_monthly_cost_usd` | number | no | A monthly *spend* figure (e.g. current Datadog usage), distinct from `estimated_monthly_savings_usd`, which is a provider-native *saving*. Only on findings in a cost/optimization parallel section, and only when the figure comes straight from the provider's own usage/billing endpoint — never a hand-computed estimate, and never summed as a saving. Omit the field entirely rather than guess a number |
| `coverage_gap` | object | no | Optional precision hint for the cross-tool coverage correlation (C14): `{ "signal": "<the exact signal this gap is about, e.g. CPU% metric alert / trace error rate>", "kind": "<metric_alert\|log_alert\|uptime\|…>" }`. Set it on a finding that reports a missing/absent alert or monitor so the correlation engine can (a) recognize the finding as a coverage gap without the area+title heuristic and (b) word a "covered-elsewhere" reframe against the specific signal ("confirm the covering monitor watches `<signal>`"). Purely advisory — `check-findings.sh` neither requires nor validates it, and its presence never changes the score or severity |

### How report.md renders a finding

The human `report.md` renders each finding as **What's wrong** (from `title`), **Where** (from `affected`), **Why it matters** (from `impact`), and **How to fix** (from `recommendation` + `remediation`), under a plain-English heading, with the coded `id` demoted to a small `ref:` line — see [report-template.md](report-template.md). `findings.json` keeps every field for machine use, and the coded `id` stays the stable key for deltas, evidence, and exemptions. The report is human-first; the JSON is machine-first; they never disagree on the facts.

### Parallel non-scored sections

Some findings genuinely don't belong on the 0-100 reliability score — a cost-optimization opportunity is real and worth reporting, but scoring it on the same axis as reliability creates a perverse incentive (an idle standby replica is "waste" by a cost lens and "correct" by a reliability lens). An audit skill may define its own `area` values that never appear in `score.categories` or `score.excluded` — those findings still live in the normal `findings[]` array (so history, lifecycle, and exemptions all apply unmodified), declare `scoring_scope: "non-scored"`, always carry `points_recoverable: 0`, and render in their own named report section instead of the Findings table. Scoutflo Topology Readiness (`area: topology-readiness`, `TOPO-` prefix) already works this way; the AWS, Azure, and Datadog packs each carry a non-scored Cost & Resource Optimization section (`area: cost-optimization`, prefixed `AWSOPT-`, `AZROPT-`, and `DDOPT-` respectively) as further examples. A category is "excluded" (per the `excluded` field above) only when it was a scoring candidate that couldn't be assessed this run; a parallel-section area was never a scoring candidate at all — don't conflate the two.

Each evidence item:

| Field | Type | Meaning |
| --- | --- | --- |
| `check` | string | What was being verified, as a statement |
| `command` | string | The exact command that was run, with placeholder variables as declared in the skill |
| `observed` | string | What the command actually returned, quoted or tightly summarized with the load-bearing values intact |

## Finding ID rules

- Format: `<PREFIX>-<NNN>`. `PREFIX` is 2 to 6 characters that start with a letter and may contain digits (enforced by `check-findings.sh` as `^[A-Z][A-Z0-9]{1,5}-[0-9]{2,4}$` — so `K8S` and `AWSOPT` are valid). Registered prefixes, one per audit: `ALR` (alertmanager), `AWS` + `AWSOPT` (aws reliability + its non-scored cost section), `AZR` + `AZROPT` (azure reliability + its non-scored cost section), `CS` (clickstack), `DD` + `DDOPT` (datadog reliability + its non-scored cost section), `DO` + `DORT` (digitalocean reliability + its parallel live-runtime section), `ELK` (elk), `GC` (groundcover), `GCP` (gcp), `GRAF` (grafana), `JSM` (jsm), `K8S` (kubernetes), `K8SRT` (the kubernetes parallel live-runtime snapshot section), `LGTM` (lgtm), `PD` (pagerduty), `PROM` (prometheus), `SIG` (signoz), `SNTRY` (sentry), `ZD` (zenduty), and `TOPO` (the parallel Topology Readiness section). The dedicated `audit-cost` skill emits its own non-scored `scoutflo-cost/v1` file with `COST-<PROVIDER>` IDs — see [cost-schema.md](cost-schema.md). `NNN` is a zero-padded number, e.g. `LGTM-014`, `GRAF-003`. `AWSOPT` is kept distinct from `AWS` so a reader can tell the cost axis from the reliability axis at a glance.
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
| `suppressed` | ID matched by a live entry in exemptions.yaml; moved to the Suppressed appendix, excluded from score and severity counts. Its same-ID scored check carries `suppressed: true` and `suppression_reason` so the ledger and score cannot disagree |

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
