# Token Costs and Pricing

## What you pay for

Scoutflo AI Readiness is free under Apache-2.0. Runs use your selected model through Claude Code and count toward your subscription usage or API account. Scheduled runs consume usage on each execution. Provider queries, CI runners and other services can have their own charges; the plugin does not calculate those from model tokens.

There is no guaranteed per-audit price, duration or model accuracy. Usage depends on the model, selected targets, instruction/context loading, provider response volume, history windows, retries and the work needed to investigate findings. A schema-conformance pass verifies output structure and arithmetic; it does not establish perfect semantic accuracy or equal accuracy between models.

The plugin ships **20 scored audit skills**, plus `audit-cost` (ranked savings, not scored) and `audit-all` (orchestration). The current catalog is in the [README](../README.md#whats-in-the-box). Connecting another account or cluster can add another target pass even when it uses an already configured integration.

Azure collection uses bounded pages and retry budgets. Hitting a bound leaves the
relevant checks unassessed; rerunning them can consume more API and model usage.
Resumed batches preserve the selected target and require saved evidence before
completion. These limits do not establish a fixed audit price or duration.

## Estimating API cost

Use the usage counters for your actual model and your provider's [current pricing](https://www.anthropic.com/pricing). Price input and output separately:

```text
estimated API cost =
    input tokens × input rate per million / 1,000,000
  + output tokens × output rate per million / 1,000,000
```

Account separately for any cached-input categories or other billed token categories your provider reports. Do not multiply combined input/output tokens by the input rate. For example, a run with 30,000 input and 15,000 output tokens costs `0.03 × input_rate + 0.015 × output_rate` before other billing categories; those counts are an illustration, not a measured audit baseline.

A subscription's usage limits do not translate directly into a per-run API bill. Check your account's usage and billing information for the model and execution surface you actually use. Old model names, prices and a previous small-estate run are not a quote for your next audit.

## Measuring your own run

1. Select one target and record the plugin version, model, audit scope and whether history or triage is enabled.
2. Run the audit and read its assessed coverage and unresolved populations alongside the findings. A cheap interrupted run is not equivalent to a completed assessment.
3. Record the client/provider's input, output and cache usage for that run, including retries. Use the provider's usage/billing records for exact charges.
4. Repeat on representative targets before budgeting a full suite or recurring schedule. Keep full and triage runs separate in the comparison.

A file's byte count measures source size, not billed tokens. The approximate bytes-divided-by-four convention can compare instruction corpora, but it is not a tokenizer or a guarantee that all references are loaded once. Model context, cached input, selected references and tool results change actual usage.

The repository's `tests/measure-efficiency.sh` is a local measurement helper. Its byte listing samples 15 named audit directories and includes their Markdown files; it does **not** enumerate the current full catalog or measure a live model session. Use its output only with that scope stated. The old fixed-byte table is not a current benchmark. Its local roll-up demonstration does not measure the model tokens spent invoking a tool or reading its output.

## Choosing a model

Select a model in your Claude Code client or account configuration. The plugin has no per-audit model-selection flag. Validate the resulting findings on your own workload before choosing a cheaper model for recurring work.

Model choice can affect token use, latency and reasoning quality. Parsing structured data does not remove the need to interpret scope, completeness, identity, time windows and operational consequences. No controlled comparison here establishes 100% accuracy, identical accuracy across models, or a fixed speed or cost multiplier.

## Controlling scope and cost

- **Run only the integrations and targets you need.** A targeted audit avoids the reads and analysis of unrelated targets. Use `/scoutflo:audit-all` when you want every configured target in its selected queue.
- **Use triage for a first pass.** `SCOUTFLO_TRIAGE=1` selects a smaller, high-signal check set where supported. Deferred checks remain visible as unassessed; the result is not a full assessment. Fewer reads do not establish a fixed token or wall-time saving.
- **Use bounded history windows.** Longer windows, more objects and pagination add work. An incomplete cohort must remain partial even if you stop early to control cost.
- **Resume only against valid evidence.** Worklists can avoid repeating completed assessment rows while their capture and generation remain valid. A prior report or unchanged-looking estate does not prove a fresh audit will use fewer tokens.
- **Budget recurring runs from observed usage.** Schedule only after checking the first run, its coverage and its usage. A schedule does not itself impose a model spending cap.

Labeled accounts and clusters are assessed separately. Covering prod and pre-prod with separate configs adds their respective audit work; the local environment-comparison render reuses those artifacts, but its invocation and output can still enter model context.

## Local aggregation and reuse

Correlation, cost roll-up and estate composition compute from local artifacts without making model API calls or provider reads of their own. The surrounding model session can still consume tokens to invoke these operations, inspect their output and write explanations. Local processing is not a guarantee that an entire phase costs zero billed tokens.

The cost roll-up regenerates from the selected current inputs; it does not use the old 24-hour skip cache. `audit-all` completion receipts and hashes prevent stale same-day or unfinished target artifacts from entering a new selected run. History supports comparisons, not a shortcut that substitutes old provider evidence for a fresh audit.

Migration-plan's local disposition skeleton also reuses existing artifacts. Detail pulls and analysis still add work; source-only mode states the target evidence it cannot assess. The skill plans a migration and does not execute it.

## Integration-specific cost factors

### Splunk On-Call

Cost scales with selected teams, policy graphs, users, the future coverage horizon and requested history window. The expanded quality/history lanes have no measured per-run token allowance here.

On-Call triage avoids per-team and per-policy detail sweeps. Its collector uses five bounded reads; the published preflight, collection and report-validation phases include repeated four-read plans, seventeen reads in total before any confirming census. This is a request count, not a measured token or wall-time saving.

Optional history collection reads at most 100 incidents per reporting page, respects the provider's one-request-per-minute budget and retains progress for resumption. It reports completion explicitly; an interrupted or bounded subset cannot become a full-window total. Incident history is distinct from source-fire and notification-attempt history.

Batch source verification reuses one management collection for selected source records in the packet, avoiding a repeated full team/user/policy census for every route. Source capture and required detail reads remain separate. Every labeled account adds an audit pass. Setup includes planning, dependency reads, immediate verification and any approved restoration; no fixed setup saving is claimed. These model-usage considerations are separate from On-Call subscription billing, which the audit does not assess.

### Datadog, HyperDX and ClickHouse

Datadog and HyperDX project source configuration locally before it enters reports. Each selected account/site still needs its own read; safe projection is not a measured token-saving claim. HyperDX bounds paginated alert/webhook collections at 100 rows per page and 50 pages per resource, with explicit incomplete status at a limit; source/dashboard lists without totals do not certify target completeness.

ClickStack uses one bounded read-only mode probe per target/credential generation, then reuses it for at most 30 minutes; each actual query still validates access and output. Assessment worklists avoid repeating reviewed rows only while their captured evidence is unchanged. Standalone HyperDX alert-fatigue uses configuration evidence and does not collect native fire history.

### Alertmanager, cost and RCA

Alertmanager configuration projection runs locally and emits structural metadata rather than raw receiver configuration. It adds no provider request by itself and requires Python 3 with PyYAML. No measured token-saving claim is made.

`audit-cost` depends on the resources, billing exports and declared usage units being assessed. Its ranked savings are provider evidence, not the price of running the model. RCA reads saved reports as reference and adds bounded read-only live checks where access exists; its usage depends on those investigations. Without cluster access, it states its report-only limit.

## Data handling

Commands and reports run in your selected local environment or runner, while prompts, selected context and tool results can become part of the model session. The shipped plugin has no automatic Scoutflo telemetry, report-upload service or callback. Optional Slack delivery and CI caches/artifacts have separate destinations and retention. Local execution is not an offline-data or data-residency guarantee. See [data handling](data-handling.md) for credential storage, model processing and report sharing.
