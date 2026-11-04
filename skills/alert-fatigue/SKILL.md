---
name: alert-fatigue
description: 'Read-only, non-scored alert-fatigue analysis from existing audit findings and optional current fire-history or incident counts. Use when the user mentions alert fatigue, noisy paging, flapping alerts, too many alerts, cross-tool alert overlap, or alert-to-incident ratio. Supports local roll-up and bounded standalone collection. Do not use for a full provider score (use audit-<provider>), changing routing or alert rules (use setup-<provider>), or general cross-stack correlation (use correlation-engine).'
---

# alert-fatigue

Alert noise & fatigue, two ways: identify potential overlap in alerting configuration, then report measured noise only where current fire-history or incident counts are available. It is a sibling of `/scoutflo:correlation-engine` and the `cost-analysis` roll-up. It **never mutates a finding or its severity and never re-scores**; each alerting-noise finding is scored **once**, in its home audit (`audit-alertmanager`, `audit-grafana`, `audit-datadog`, `audit-lgtm`, `audit-prometheus`, `audit-sentry`, `audit-pagerduty`, `audit-jsm`, `audit-zenduty`, `audit-splunk-oncall`, `audit-signoz`, `audit-newrelic`, `audit-groundcover`, `audit-digitalocean`); this skill **cites** those source finding-IDs and adds the estate-wide view.

Current conclusions use only open, observed findings: `configured` or `validated-live`,
with lifecycle `new`, `unchanged` or `regressed`. Missing status/lifecycle fields
remain compatible with historical artifacts; blocked, unknown, deferred, resolved
or suppressed rows cannot establish current noise, savings or migration defects.

## Two modes

- **Roll-up mode (default inside `/scoutflo:audit-all`, Phase 3.6).** After the audits have written `findings.json`, the roll-up **library** reads only those files; **zero provider calls**; aggregates the alerting-noise findings, finds potential cross-source overlaps, and (with a signal block) the ratio. Its coverage is limited to the audits actually supplied for the selected run.
- **Standalone mode (single integration, no full audit needed).** Point it at one (or a few) configured alerting providers and it **drives that provider's own alerting-lane checks**; the same read-only config + fire-history checks that live in `audit-<provider>` (referenced, never duplicated); to produce the noise/fatigue picture *directly*, then rolls the result up. So it is useful even when you have run no other audit. The provider reads happen in the audit-lane check blocks it invokes; the roll-up library itself still makes zero provider calls.

**"Handle both" is the design:** with audits already run → pure roll-up; with only this skill run against one integration → it produces the picture itself. Either way the output is one `alert-fatigue.json` and the honest feed-tiering below.

It runs automatically in `/scoutflo:audit-all` (Phase 3.6, right after correlation). You can also run it standalone (§Standalone mode).

## Standalone mode (single integration, no full audit required)

When the user asks for an alert-noise/fatigue read on **one integration** (or a few) without running the whole estate, this skill produces it directly by driving that provider's **own alerting-lane checks**; the read-only config + fire-history checks already shipped in `audit-<provider>`; then rolling the result up. It never re-implements a provider's alert reads; it invokes the existing ones (DRY), so there is a single source of truth per provider.

**Doctor gate, live-safety gate and resume are mandatory for provider reads.**
Follow [collection-workflow.md](references/collection-workflow.md) first. It
selects one configured target, pins the intended identity and observation window,
runs doctor against only that target, verifies a live identity response and keeps
an immutable per-object worklist. Every fresh request block reloads its named
credentials; no empty auth header or ambient cloud target is permitted. A failed
gate stops collection before checks. Local roll-up mode makes no provider calls
and does not need this preflight. Use the same completed receipts when resuming;
changed config/window/object scope starts a new run and preserves old evidence.

**Steps:**
1. **Resolve the configured alerting providers** from `~/.scoutflo/toolkit.yaml` (the same config every audit resolves). The alerting-lane providers and the audit whose checks own their noise reads:

   | Provider block | Run these alerting-lane checks (in its audit's references) |
   | --- | --- |
   | `alertmanager` (+`prometheus`) | `audit-alertmanager`; routing→live-receiver, flapping, permanently-firing, missing `for`, missing grouping/inhibition, duplicate delivery, resolve-noise |
   | `datadog` | `audit-datadog`; DD-006/007/008/018/019/023/035-038/039 (measured alert-event volume, placeholder handles, `@all`, no-floor ratio, tautological threshold, downtime decay, dupes, never-evaluated, paused synthetic, partial-window flap) |
   | `sentry` | `audit-sentry`; SNTRY-101/102/103/106/107/108/109/110 + SNTRY-014 (un-gated rules, all-env scope, flap-prone metric, fire-history, chronic re-page, name/scope, dead-weight, ownerless) |
   | `pagerduty` | `audit-pagerduty`; PD-016/017/026/043 (verify-pending: needs a live key) |
   | `splunk_oncall` | `audit-splunk-oncall`; routing and paging checks from its catalog; reuse its bounded evidence and preserve blocked outcomes. An observed incident is not a complete incident feed or a measured notification count |
   | `zenduty` | `audit-zenduty`; ZD-007/008/025/033/034 (orphaned EP, bus factor, dormancy, GET-only actionability, timeout posture) |
   | `grafana` | `audit-grafana`; alert-rule wiring, receiver delivery |
   | `signoz` | `audit-signoz`; SIG-040 routing + SIG-042 SLO-aware alert quality |
   | `newrelic` | `audit-newrelic`; NR-010/011/012/013 (unwatched estate, uncaught policy, broken workflow→channel→destination linkage, destination posture) + NR-020-026 noise lane (single-tier terms, evaluation sanity incl. charts-vs-alerts divergence and sparse-signal stall, loss-of-signal, dead-weight disabled conditions, open-ended mutes, **measured `NrAiIncident` fire-history**; chronic opens, top-noisy, muted fires; and incidentPreference judgment) |
   | `elk` | `audit-elk`; ELK-007/015 (zero connectors, never-alerted stale rule) |
   | `digitalocean` | `audit-digitalocean`; DO-017/026/073 (uncovered-failing, production/non-production parity, destination consistency) |
   | `lgtm` (vmalert) | `audit-lgtm`; vmalert routing/hygiene lane |
   | `aws` | `audit-aws`; CloudWatch alarms are a first-class alert source: AWS-001/004/007 (zero-alarm coverage, dead alarm dimension, SLO burn-rate alarm), AWS-010/011/012 (alarm with zero actions = dead-end, unconfirmed SNS subscription, one topic for all severities), AWS-060/061/062 (single-datapoint flap, `TreatMissingData` quiet-period paging, flap history). Measured tier (AF-004): SNS-subscriber reachability + `DescribeAlarmHistory` per [references/fire-history-reads.md](references/fire-history-reads.md) |
   | `azure` | `audit-azure`; AZR-001/002/004/005 (action group with a reachable receiver + rules that reference one, metric alert routing to a dead group, activity-log alerts on Service/Resource Health, live receiver whose delivery is suppressed) |
   | `gcp` | `audit-gcp`; GCP-001/002/003/005/006 (enabled notification channels, alert policies with zero channels = dead-end, one channel absorbing every environment, channel-vs-referenced-state, a stale snooze muting a critical policy) |

2. **After the target's doctor and live-safety gates, run only the alerting-lane checks** for each configured provider (not the full audit; the coverage/retention/security lanes are out of scope for a fatigue read). Each writes its normal `findings.json` under `<audits-dir>/<target>/<date>/`, so the reads happen in the audit lane (which is allowed to call providers) and the roll-up library still makes zero provider calls.
3. **Collect the measured fire-history tier (read-only)** for each configured provider per [references/fire-history-reads.md](references/fire-history-reads.md), writing `fatigue-signals.json`; this is what powers AF-004/005/006 (and AF-003 when an incident feed is read). Skip a provider that can't expose history (mark it `verify-pending` with a reason). Set each provider's `provider_coverage[].verification` to `spec-only` until its reads have been confirmed against a live tenant (see the §Live-verification checklist), then `live-verified`.
3b. **Validate the signals file before analyzing it.** Run [`report-standard/check-fatigue-signals.sh`](../../report-standard/check-fatigue-signals.sh) `<fatigue-signals.json> <audits-dir> <run-date>`; it must print `FATIGUE-SIGNALS-OK`. It fails closed on a malformed schema, a wrong field type, an `off_hours_fires > fires` impossibility, a reasonless `verify-pending`, or a `source_finding_ids` that cites a finding absent from this run. Do not feed a file that fails validation into the roll-up.
4. **Roll up** exactly as `alert_fatigue_run` does below. With one provider you still get its config + measured picture; with two or more you also get the cross-source view (AF-002). The library validates a snapshot of `fatigue-signals.json` before loading it. Invalid or stale input blocks the measured tier, replaces prior output, and returns nonzero.

**If the operator has already run those audits today**, skip step 2; the findings exist; go straight to the roll-up (that is roll-up mode). This is the "handle both": standalone drives the checks; roll-up consumes them; the same `alert-fatigue.json` comes out.

## Fire-history collection lane (the measured tier; how this skill goes deeper than a re-list)

The config audits answer *"is this rule shaped well?"*. The fatigue skill owns the definition of what qualifies as fatigue, so it collects the **measured** tier itself: per configured alerting provider it makes **read-only fire-history API calls**; the reads the config audits skip; normalizes them into `fatigue-signals.json`, and the roll-up library analyzes them into **AF-004 reachability, AF-005 volume/flapping, AF-006 chronic/stuck** (and, from an incident feed, **AF-003**). The provider calls happen **here, in this collection lane** (the audit lane is allowed to call providers); the roll-up library still makes zero provider calls.

The exact per-provider read blocks, the `fatigue-signals.json` schema, and the derivations (fires / flapping / stuck / off-hours / reaches-a-human) are in **[references/fire-history-reads.md](references/fire-history-reads.md)**; CloudWatch `DescribeAlarmHistory` + SNS `ListSubscriptionsByTopic`; Datadog Events + monitor state; Grafana annotations / state-history; Prometheus sampled-state observations (exact fire totals remain unavailable without a complete event log); Alertmanager notification counters + silences; SigNoz rule-history routes; and the incident-feed reads (PagerDuty/incident.io/Opsgenie) for AF-003.

**Rails (non-negotiable):** every read is a GET or a documented read-by-POST (a query/search body, no mutation); this lane never mutates. **Off-hours has no native field** anywhere; it is *derived* from a fire timestamp against the business-hours window; say so. A provider that cannot expose history (no permission / API absent) is marked **`verify-pending`** in `provider_coverage[]`; never a guessed number. Use the [durable collection worklist](references/collection-workflow.md): bound each window/page, claim pending objects, assert each response and mark success only after validation. Completed objects are hash-checked and never silently overwritten or pulled again. Unsupported history stays verify-pending with evidence.

Absent the lane (or where a provider is `verify-pending`), AF-004/005/006 are simply `not-in-scope` and the config tier (AF-001/002/007) still reports the available findings; the analysis degrades honestly, it never fabricates a measured number.

**Verification status (honest by construction).** The per-provider read blocks are doc-verified but the measured tier has not yet been confirmed against a live tenant per provider; each provider carries `verification: "spec-only"` until a first live run confirms its flagged fields (the ledger + per-provider checklist are in [references/fire-history-reads.md](references/fire-history-reads.md) § Live-verification). The report shows this coverage line, so a `spec-only` provider is never presented as battle-tested; the numbers are real reads, and a live run confirms the parsing. `check-fatigue-signals.sh` (step 3b) gates the file's structure and the never-fabricate cross-reference on every run.

## What it produces

`${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue.json` (`scoutflo-alert-fatigue/v1`, `scoring_scope: non-scored`) with the advisory `AF-*` analysis. **AF-001/002/007 are the config tier** (from the audits' `findings.json`, always available); **AF-004/005/006 are the measured fire-history tier** (from `fatigue-signals.json`; the read-only fire-history collection lane below; `not-in-scope` when that lane did not run); **AF-003 is the incident-feed tier**. Every item cites its source finding-IDs and re-scores nothing:

| ID | What it computes |
| --- | --- |
| `AF-001` | **Alerting-noise concentration** (config); every alerting/hygiene finding across all audits, grouped by source tool and severity. Cites each source finding-ID; re-scores nothing. |
| `AF-002` | **Potential cross-source overlap** (config): a service carrying alerting-noise findings from **two or more** audit targets. They may describe one linked path or independent paths; configuration findings do not prove duplicate events, pages or human delivery. Verify the actual paths before changing routing. |
| `AF-003` | **Alert-to-incident ratio** (incident-feed); computed from a **live incident feed** (`fatigue-signals.json` `.incident_feed`, collected read-only from PagerDuty/incident.io/Opsgenie) **or** an operator `fatigue.json`. Absent both → `not-in-scope`, never a fabricated percentage (with MTTA/MTTR/%-actionable when the feed supplies them). |
| `AF-004` | **Alerting reachability** (measured); of the alerting objects whose routing was resolved, **how many can reach NOBODY** by construction (zero-subscriber SNS / zero-workflow detector / no channel), grouped by reason. The headline fatigue-adjacent finding. `not-in-scope` if no signal resolved routing. |
| `AF-005` | **Measured noise volume & flapping** (measured); real fires per object over the window, the flapping set, and the **top offenders ranked by fatigue impact** (fires weighted by flapping / off-hours share / dead-end routing; each weight added only when its datum is present). |
| `AF-006` | **Chronic / stuck alerts** (measured); objects firing continuously for a long time (desensitization risk), ranked by duration. |
| `AF-007` | **Fatigue anti-pattern histogram** (config+measured); every noise finding classified into a named failure mode (dead-end, chronic-stuck, flap-prone, un-gated-repage, ownerless, decoration-or-dead-weight), with counts. Turns "N noise findings" into "what KIND of noise". |

Plus the **human report** (see §Running it): `alert-fatigue-report.md` and a standalone `alert-fatigue-report.html` dashboard, rendered from `alert-fatigue.json` by [`report-standard/render-report-viz.sh`](../../report-standard/render-report-viz.sh) (`alert-fatigue` / `alert-fatigue-html` modes). The report leads with an at-a-glance line and the three honest tiers, then a **worst-first "top offenders" list where every noise finding shows problem → where → why it matters → the exact fix** (its `recommendation` + `remediation` pointer, joined from the home `findings.json`), where the noise concentrates by tool, the cross-source storms, the alert-to-incident ratio (or an explicit "not measured; needs an incident feed" block), and attributed research context to compare with your declared operating targets. This is the deliverable a user reads; not the JSON. Same never-fabricate, cites-never-re-scores discipline as the roll-up.

## How it selects the noise (cites, never re-scores)

A finding is rolled into the fatigue view when its `area` names the alerting/routing/hygiene plane **or** its title carries noise vocabulary (flapping, permanently-firing, missing `for`/debounce, duplicate delivery, re-notify/repeat storms, resolve-noise, missing grouping/inhibition, noisy volume, over-broad mute/silence). Both signals are already in each audit's `findings.json`, so every audit's noise checks aggregate here without a hardcoded ID list that would go stale, and without any change to the audits themselves. The finding keeps its own `id` and `severity`; this roll-up only tags it as a fatigue signal and cites it.

## The optional fatigue-signal block (for AF-003 only)

`findings.json` records alerting **configuration** noise, not how many alerts actually fired or how many real incidents occurred; this roll-up has no incident feed. So the alert-to-incident ratio is computed **only** when you provide the counts, in `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue.json` (or a path in `ALERT_FATIGUE_SIGNAL`):

```json
{ "window": "7d", "alerts_fired": 4200, "incidents": 35 }
```

With it, `AF-003` reports `alerts_per_incident` (here 120; a strong fatigue signal). Without it, `AF-003` is `not-in-scope` with that reason stated, and the config tier still reports. **This roll-up never invents an actionability number.**

**Preferred over the operator block: a live incident feed.** When the fire-history lane reads a paging tool's incident/ack stream (PagerDuty/incident.io/Opsgenie; see [references/fire-history-reads.md](references/fire-history-reads.md)) it writes an `incident_feed` block into `fatigue-signals.json`; `AF-003` then computes the ratio **and** MTTA/MTTR/%-actionable from that live feed (source recorded). The operator `fatigue.json` is the fallback when no feed is reachable; absent both, `not-in-scope`.

## The three feed tiers (what is a real number vs a proxy vs verify-pending)

Every alert-fatigue signal falls into one of three tiers by the data it needs. This is the honest core; report each tier for what it is, never promote one to another:

- **Config tier (provider config only, always available):** symptom-vs-cause paging, actionability/severity-tiering (page vs ticket vs log), static-threshold-vs-burn-rate, and whether **dedup / grouping / inhibition / maintenance-window / recovery-threshold** are configured. Pure hygiene; a real yes/no from the rules.
- **Fire-history tier (the provider's alert event stream, no incident feed):** alert volume/rate, **pages-per-shift**, **flapping / self-resolve / transient rate**, **top-N noisiest rules**, **off-hours rate**, co-firing clusters (an alert-to-incident **proxy**), and a raw noise-reduction/dedup ratio. **These are honest measured numbers** from read-only access.
- **Incident-feed tier (needs the paging tool's incident/ack stream):** true precision/recall, MTTA/MTTR, %-actionable, ack/escalation ratios, and the **true** alert-to-incident ratio. Where the feed is absent, emit the structural/history finding and mark the outcome **`verify-pending (needs incident feed)`** or a labeled proxy; **never a fabricated percentage**.

## What "good" looks like; the canon + market benchmarks (cited)

Score against these; cite them; never invent one. Grounded in the SRE canon and vendor docs (research 2026-09-04):

- **Every page must be actionable** and require human intelligence; page on **symptoms, not causes** (Google SRE, *Monitoring Distributed Systems*).
These cited values describe research or vendor defaults, not universal pass/fail
thresholds. Record your team’s shift length, SLOs, paging budget, business-hours
time zone and chosen observation window before comparing a measurement. Override
the example values in the collection plan when those conditions differ; missing
policy means an observation, not a policy violation. Clinical alarm rates and
vendor surveys are context, never estimates for your estate.

- **Google SRE example budget: ≤2 incidents per 12-hour shift**, with on-call ≤25% of an engineer's time (*Being On-Call*). Compare your measured incident work with your declared shift and budget before flagging overload.
- **Alert on SLO burn-rate, not raw static thresholds**; multi-window/multi-burn-rate: page **14.4** (1h/5m) and **6** (6h/30m), ticket **1** (3d/6h); short window ≈ **1/12 of the long**, long window **≤48h** (SRE Workbook + Datadog burn-rate docs). A bare static threshold on a ratio is flap-prone.
- **Target a 1:1 alert-to-incident ratio**; group/dedupe so one incident → one page (Google SRE). Grouping window ≈ **30 min** default (to 48h), dedup window ≈ **24h** default across incident tools (incident.io / FireHydrant / Opsgenie).
- **AIOps compression sweet spot ≈ 70-85%**; and higher is **not** strictly better: over-compression mis-groups and hides real signal (BigPanda target; Splunk; INOC caveat).
- **Off-hours bands** (a citable definition): Working 8am-7pm / Late 7pm-11pm / Overnight 11pm-8am (incident.io).

**Defensible stats for the report/pitch (verified); and what NOT to claim:**
- ✅ SRE Workbook: *"you could receive up to 144 alerts per day … and still meet the SLO"*; the raw-volume-≫-actionable framing.
- ✅ Clinical alarm-fatigue (peer-reviewed, Drew 2014, PLOS ONE): **2.5M alarms in 31 days, 88.8% false, 187/bed/day**; The Joint Commission estimates **85-99% of alarms need no intervention** (cite as their estimate; 88.8% is the verified backstop).
- ⚠️ PagerDuty vendor survey (directional): **3-in-5 on-call staff work +10h/week; 2-in-5 expect burnout**; label vendor-sponsored.
- 🚩 **Do NOT cite as research:** a specific "alert-to-incident compression ratio," a "% of pages that are off-hours," or MTTR/attrition percentages; these are vendor marketing/folklore with no primary source. Attribute any compression % explicitly to the vendor and label it a product claim. (This is the same never-fabricate rule the whole toolkit runs on.)

The full principles, anti-patterns, per-tier auditor checklist, vendor technique catalog, and source citations are in [references/methodology.md](references/methodology.md).

## Honest ceiling (stated every run)

- **Config tier vs measured tier, labeled honestly.** `AF-001`/`AF-002`/`AF-007` are read off the audits' *configuration* findings; where noise is structurally likely and which verified service identities have potentially overlapping configuration findings; they are not a measured page rate. `AF-004`/`AF-005`/`AF-006` **are** measured, but only when the fire-history collection lane ran against a provider that exposes history; otherwise they are `not-in-scope`, never a guess. `AF-003` is measured only from a live incident feed or the operator block. Each `fire_history_coverage[]` entry states `collected` vs `verify-pending` per provider. Sampled state and notification attempts cannot populate exact `fires`; see the bounded Prometheus recipe and provider response assertions.
- **Non-scored.** There is no 0-100 here and no `check-findings.sh` reconciliation; `alert-fatigue.json` is a synthesis file like `correlation.json`, not a scored audit result. Finding-ID prefix `AF` is registered as a non-scored roll-up prefix.
- **Cites, never mutates.** Every `source_findings[].finding_id` exists in this run's `findings.json`; this roll-up changes none of them and re-scores nothing. Noise is scored once, in its home audit; this only aggregates and de-duplicates the estate view.

## Running it

Standalone, after some audits have written findings for today's date:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="$(date -u +%F)"
. "${CLAUDE_PLUGIN_ROOT}/skills/alert-fatigue/lib/alert-fatigue.sh"
alert_fatigue_run "$RUN_DATE"
```

Expected on valid input: `[alert-fatigue] Written <audits-dir>/alert-fatigue.json` plus a summary with counts only for measured fields; other fields show `not-in-scope`. The run validates `fatigue-signals.json` before loading it. Its existing `generated_at` must belong to `RUN_DATE` in UTC, its window must be stated, counts must be nonnegative and consistent, and every supplied finding ID must exist even when the run has no findings. Standalone observations may omit finding IDs. Missing or old measurement provenance is blocked, not accepted as current; recollect it for the selected run. This is a calendar-date binding, not proof that two snapshots from the same day describe the same instant. An actually absent optional file remains `not-in-scope`. Zero findings **and** zero signals for the date replaces any prior roll-up with empty configuration evidence and explicit unmeasured tiers, never a stale result or an all-clear. It reads only local files, so re-running makes no provider calls. A failed measurement validation writes a fresh `input_validation.status: blocked` roll-up, clears prior generated Markdown/HTML, retains the invalid input for correction, and returns nonzero. You can run the separate renderer block to view that blocked state; do not treat it as a successful measurement. Invalid selected operator `fatigue.json` counts also block the ratio. Errors reading config findings remove the prior roll-up instead of leaving it current.

**Then render the human report**; a pretty, self-contained deliverable that shows each problem *and its exact fix*, so the user does not read raw JSON. The renderer is deterministic and joins each cited noise finding back to its home `findings.json` for the fix text (`recommendation` + `remediation`); it never re-derives or re-scores:

```bash
set -eu
AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
RUN_DATE="$(date -u +%F)"
VIZ="${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh"
AFJ="${AUDITS_DIR}/alert-fatigue.json"
if [ -f "$AFJ" ]; then
  sh "$VIZ" alert-fatigue      "$AFJ" "$AUDITS_DIR" "$RUN_DATE" > "${AUDITS_DIR}/alert-fatigue-report.md"
  sh "$VIZ" alert-fatigue-html "$AFJ" "${AUDITS_DIR}/alert-fatigue-report.html" "$AUDITS_DIR" "$RUN_DATE"
  echo "[alert-fatigue] report: ${AUDITS_DIR}/alert-fatigue-report.md (+ .html dashboard)"
fi
```

Show the operator the rendered `alert-fatigue-report.md` (the worst-first, problem→fix view) and point them at the `alert-fatigue-report.html` dashboard. Both derive only from `alert-fatigue.json` + the per-audit `findings.json` already on disk, so they never disagree with the numbers and re-running is free.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Fabricated "N% of alerts are actionable" | `AF-003` is computed only from an operator-supplied `fatigue.json` signal block; absent it, the ratio is `not-in-scope`, never guessed |
| Re-scoring noise that an audit already scored | This roll-up never emits a scored result; it cites source finding-IDs and aggregates. Noise is scored once, in its home audit |
| A single-block signoz/kubernetes or a multi-target label dropped from the roll-up | The findings collector globs BOTH `<target>/<date>/` and `<integration>/<label>/<date>/`, matching correlation-engine and the report standard |
| A storm reported without evidence | `AF-002` identifies potential overlap only when a service's `affected` token appears in alerting-noise findings from two or more distinct target directories; each contributing finding is cited by its artifact-directory target + id. On-Call joins only the explicit source-verified `correlation_affected` subset, never account-local policy/team names or run-local route aliases. Its raw `affected` remains available for remediation. It never asserts that pages were delivered or duplicated |
| Stale or invalid measured input appears current | The library gates the actual entry path with the signals validator; a blocked run replaces previous measurements and removes stale generated reports. Correct the retained source input and rerun |
| A legacy structured target crashes or two named accounts collapse | Collector and renderer use the artifact-directory identity; old unambiguous envelope aliases remain readable for earlier roll-ups |
| Mutating a finding's severity from the roll-up | The library only reads findings.json; it writes alert-fatigue.json and touches no per-audit artifact |
| Fabricating a measured fire count / reachability when the fire-history lane could not read a provider | That provider is marked `verify-pending` in `provider_coverage[]`; AF-004/005/006 stay `not-in-scope` for it; a measured number is only emitted from a real read |
| A resumed collection repeats successful reads or overwrites evidence | Immutable target/window/object plans, per-job claims and hash-checked completion receipts preserve success; changed basis or evidence stops the run |
| State samples reported as exact fires | Prometheus normalization emits a distinct sampled-state count separately; exact fires require a fully exhausted event log with verified transition semantics |
| A fire-history read that mutates (a test-fire, an ack) | The collection lane is GET / read-by-POST only, per [references/fire-history-reads.md](references/fire-history-reads.md); it never mutates, exactly like an audit |
| Presenting an off-hours % as a native provider metric | Off-hours has no native field anywhere; it is derived from a fire timestamp against the business-hours window, and the report says so |
