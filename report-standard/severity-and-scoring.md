# Severity, Status, Scoring, and Coverage

This document defines the shared vocabulary and scoring mechanics every audit skill uses. Skills define their own checks and category tables; the definitions and rules here are toolkit-wide and versioned with the plugin.

## Severity

| Severity | Definition | Examples |
| --- | --- | --- |
| `critical` | Incident response is broken, or a critical service is invisible. If this fires tonight, nobody finds out or nobody can act. | Default alert receiver is dead or points nowhere; no receiver configured at all; a critical service has no telemetry in any signal |
| `high` | One failure away from critical, or a serious exposure. | Single-node telemetry storage with no backups; observability endpoint publicly reachable without auth; a critical service missing one required signal |
| `medium` | Degrades response quality or trust in the data. | Noisy or stale rules paging on non-issues; service names that do not correlate across signals; broken dashboard panels; missing alert grouping or inhibition |
| `low` | Hygiene gaps that slow people down during an incident. | Missing runbook link on a paging alert; unknown service ownership; missing deploy markers or annotations |
| `info` | Observation only. No action required. | Version notes, upcoming deprecations, tuning opportunities recorded for context |

Severity describes impact on your ability to detect, diagnose, and respond. It is not a measure of how hard the fix is.

## Status

Finding status (used in `findings.json`, one value per finding):

| Status | Meaning |
| --- | --- |
| `validated-live` | The observed state was confirmed by querying the live system during this run. The evidence shows the live response. |
| `configured` | The state exists in configuration, but live behavior was not proven. A configured receiver that has never delivered a notification is `configured`, not working. |
| `blocked` | The check could not complete. The evidence records the blocker: auth failure, unreachable endpoint, missing permission. |

Check results (used in scoring and in the coverage matrix, one value per check per service):

| Result | Meaning | Score credit |
| --- | --- | --- |
| `pass` | Verified live and healthy | 1.0 |
| `partial` | Present but incomplete, stale, or unproven live | 0.5 |
| `fail` | Verified absent or broken | 0 |
| `blocked` | Could not verify; blocker stated | 0 |
| `not-in-scope` | Intentionally not part of this environment, declared by you | removed from the denominator |

Score conservatively. When you are unsure between two results, pick the lower one and state why.

## Scoring model

Each audit skill defines a category table: named categories with integer weights summing to 100. The reference example, from the LGTM audit:

| Category | Weight | What it measures |
| --- | ---: | --- |
| Service coverage | 20 | Required signals present per critical service |
| Metrics layer | 15 | Queryable metrics, rules, labels, target health |
| Logs layer | 15 | Searchable logs, fields, ingestion health |
| Traces layer | 15 | Trace search, correlation, sampling policy |
| Alert routing | 15 | Working receivers, severity routes, noise control |
| Dashboards and correlation | 10 | Valid panels, cross-signal pivots, incident views |
| Reliability and security | 10 | HA, backups, retention, exposure, secrets |

Weights are per audit domain: a Grafana audit or an error-tracking audit ships its own table. What is fixed toolkit-wide is the mechanics:

1. Every check maps to exactly one category and yields a result from the table above.
2. Category score = 100 x (sum of credit) / (number of scored checks), where `not-in-scope` checks are removed from the denominator. Round down.
3. Overall score = sum over included categories of (weight x category score) / (sum of included weights). Round down.
4. **Blocked or out-of-scope sections are excluded and stated.** When an entire category cannot be assessed (every check blocked, or the whole area declared not in scope), exclude its weight, renormalize the remaining weights, and list the exclusion with its reason in `score.excluded` and in the report's scorecard and executive summary. Never present a score over excluded categories as if it covered everything: write "72/100 across 6 of 7 categories; traces excluded (endpoint unreachable)".
5. Individual blocked checks inside an otherwise assessable category score 0. Blockage inside a category counts against you; only whole-category blockage is excluded.
6. **Once past the gates, the run always ends in a report.** A customer's estate can be at any state — broken backends, half-migrated stacks, empty projects, zero alert rules, unreachable endpoints, scopes the token cannot read. None of that is a reason to abort: every mid-run failure becomes a `blocked` check or an excluded category with the blocker as evidence, the estate's real state becomes findings, and the run still writes `findings.json` and `report.md` with honest denominators. A worst-state estate produces a low score with a long action list, never a crash or a refusal. The only legitimate no-report exits are the preflight gates — missing config or credentials (doctor gate) and a target-identity mismatch (live-safety gate) — because auditing the wrong account or an unidentified target is worse than no report. An audit that starts checking and then gives up without artifacts is a toolkit bug, always.
   - ❌ `Traces endpoint returned 404 mid-run; aborted the audit.`
   - ✅ `Traces endpoint returned 404 (LGTM-040 evidence); traces checks blocked, category excluded with reason, remaining 6 categories scored, report written.`

Claim rules that override any arithmetic:

- **Never score from object counts.** Forty dashboards or two hundred alert rules prove nothing. Credit comes from meaningful queries returning meaningful data that a responder could act on.
- **Successful API syntax is not correctness.** A query that returns 200 with plausible-looking data is syntax evidence only. Check scope, labels, reducers, and pagination before crediting the number it shows.
- **Configuration is metadata, live validation is proof.** Inventory records, config files, and chart values are discovery input. Credit requires querying the live provider.

## Target profile and the gap model

A score is only meaningful against a stated target. Each audit skill defines a target profile alongside its category table: for every category, what 100/100 means, written as the benchmark attributes of a best-practice setup. For alert routing, for example: every severity route reaches a distinct receiver with proven delivery, noise controls are active, and nothing depends on a catch-all route. The target profile lives with the skill's check catalog; the checks are the target profile made executable.

Three measures derive from it:

**Gap to target.** 100 minus the overall score, in points. The executive summary states it directly: "gap to target: N points, biggest levers: ...", where the levers are the open findings with the highest `points_recoverable`.

**`points_recoverable`, on every finding.** The whole-point increase in the overall score if this finding's check moved to `pass`, everything else unchanged. Compute it by re-running the scoring model with that check at full credit and subtracting the current overall score; round to the nearest whole point, minimum 1 for any finding on a scored check. `info` findings and findings in excluded categories carry 0. Summing `points_recoverable` across findings approximates the gap but need not equal it: rounding and excluded categories make it an ordering tool for prioritization, not an accounting identity.

**Maturity, per category.** One value per category in the scorecard's maturity column:

| Maturity | Meaning |
| --- | --- |
| `reactive` | The category works only after something breaks. Gaps surface during incidents; coverage exists where past pain forced it. |
| `proactive` | The category catches problems before users report them. Coverage is deliberate, alerts fire ahead of impact, known gaps are tracked. |
| `systematic` | The category is enforced by defaults and process. New services inherit coverage automatically, drift gets detected, exceptions are declared. |

Maturity answers a different question than the score: the score says how good the setup is today; maturity says whether it will still be good after the next ten deploys. It is a judgment call, made conservatively like every other call here: when unsure between two levels, pick the lower and say why. An excluded category gets no maturity value.

## The end-to-end gate

An audit may claim end-to-end coverage only when all three hold:

1. Overall score is at or above **85**.
2. Every critical service passes every row of the coverage definition below.
3. No category was excluded from scoring.

Below the gate, use "good base coverage" or "mostly covered". Never "end to end". The 85 gate is a toolkit convention shared by every audit skill; skills must not lower it. A score can be useful and honest without earning the label.

## Coverage definition

Coverage is judged per critical service. The critical-service list comes from `./scoutflo-audits/topology.md` when present; otherwise from live discovery, with the report noting that the list was inferred.

Each audit skill defines which signals apply to its domain. Before claiming end-to-end, every critical service needs live evidence for each applicable item:

| Item | Required evidence |
| --- | --- |
| Each required signal | Recent data for this service, queried live, with stable service and environment labels |
| Signal identity | The same service resolves to the same name across all signals; mismatches are correlation findings |
| Alert path | At least one severity-labeled alert for this service, routed to a receiver proven live |
| Incident view | A dashboard or equivalent that links this service's signals and active alerts |
| Ownership | Named owner and escalation route |
| Runbook | Actionable triage link on every paging alert for this service |
| Change context | Release, image tag, or deploy marker where available |
| Security | The backing observability endpoints are not needlessly exposed; credentials are protected |

If one critical service misses one applicable item, coverage is partial and the end-to-end label is off the table, whatever the score says. Report exactly which service misses exactly what: that sentence is the most useful line in the report.
