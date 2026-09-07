---
name: alert-fatigue
disable-model-invocation: true
description: Non-scored alert noise & fatigue assessment with TWO modes. (1) Cross-audit roll-up — aggregates the alerting-noise findings the individual audits already produced, finds services paged by more than one tool for one incident (cross-source storm), and computes the alert-to-incident ratio when an incident-count block is supplied. (2) Standalone — point it at a single alerting integration (even with no full audit run) and it drives that provider's own alerting-lane checks to produce a config + fire-history noise picture directly. Runs inside /scoutflo:audit-all after correlation, or standalone. Never re-scores a finding, cites source finding-IDs, never fabricates a number.
---

# alert-fatigue

Alert noise & fatigue, two ways, answering a question no single backend can: *across your alerting, how much of your paging is noise, and does one incident page through several tools at once?* It is a sibling of `/scoutflo:correlation-engine` and the `cost-analysis` roll-up. It **never mutates a finding or its severity and never re-scores** — each alerting-noise finding is scored **once**, in its home audit (`audit-alertmanager`, `audit-grafana`, `audit-datadog`, `audit-lgtm`, `audit-prometheus`, `audit-sentry`, `audit-pagerduty`, `audit-jsm`, `audit-zenduty`, `audit-signoz`, `audit-groundcover`, `audit-digitalocean`); this skill **cites** those source finding-IDs and adds the estate-wide view.

## Two modes

- **Roll-up mode (default inside `/scoutflo:audit-all`, Phase 3.6).** After the audits have written `findings.json`, the roll-up **library** reads only those files — **zero provider calls** — aggregates the alerting-noise findings, finds cross-source storms, and (with a signal block) the ratio. This is the richest view because every tool was audited.
- **Standalone mode (NEW — single integration, no full audit needed).** Point it at one (or a few) configured alerting providers and it **drives that provider's own alerting-lane checks** — the same read-only config + fire-history checks that live in `audit-<provider>` (referenced, never duplicated) — to produce the noise/fatigue picture *directly*, then rolls the result up. So it is useful even when you have run no other audit. The provider reads happen in the audit-lane check blocks it invokes; the roll-up library itself still makes zero provider calls.

**"Handle both" is the design:** with audits already run → pure roll-up; with only this skill run against one integration → it produces the picture itself. Either way the output is one `alert-fatigue.json` and the honest feed-tiering below.

It runs automatically in `/scoutflo:audit-all` (Phase 3.6, right after correlation). You can also run it standalone (§Standalone mode).

## Standalone mode (single integration, no full audit required)

When the user asks for an alert-noise/fatigue read on **one integration** (or a few) without running the whole estate, this skill produces it directly by driving that provider's **own alerting-lane checks** — the read-only config + fire-history checks already shipped in `audit-<provider>` — then rolling the result up. It never re-implements a provider's alert reads; it invokes the existing ones (DRY), so there is a single source of truth per provider.

**Steps:**
1. **Resolve the configured alerting providers** from `~/.scoutflo/toolkit.yaml` (the same config every audit resolves). The alerting-lane providers and the audit whose checks own their noise reads:

   | Provider block | Run these alerting-lane checks (in its audit's references) |
   | --- | --- |
   | `alertmanager` (+`prometheus`) | `audit-alertmanager` — routing→live-receiver, flapping, permanently-firing, missing `for`, missing grouping/inhibition, duplicate delivery, resolve-noise |
   | `datadog` | `audit-datadog` — DD-006/007/008/018/019/023/035-038 (measured alert-event volume, placeholder handles, `@all`, no-floor ratio, tautological threshold, downtime decay, dupes, never-evaluated, paused synthetic) |
   | `sentry` | `audit-sentry` — SNTRY-101/102/103/106/107/108/109/110 + SNTRY-014 (un-gated rules, all-env scope, flap-prone metric, fire-history, chronic re-page, name/scope, dead-weight, ownerless) |
   | `pagerduty` | `audit-pagerduty` — PD-016/017/026/043 (verify-pending: needs a live key) |
   | `zenduty` | `audit-zenduty` — ZD-007/008/025/033/034 (orphaned EP, bus factor, dormancy, GET-only actionability, timeout posture) |
   | `grafana` | `audit-grafana` — alert-rule wiring, receiver delivery |
   | `signoz` | `audit-signoz` — SIG-040 routing + SIG-042 SLO-aware alert quality |
   | `elk` | `audit-elk` — ELK-007/015 (zero connectors, never-alerted stale rule) |
   | `digitalocean` | `audit-digitalocean` — DO-017/026/073 (uncovered-failing, prod/PP parity, destination consistency) |
   | `lgtm` (vmalert) | `audit-lgtm` — vmalert routing/hygiene lane |

2. **Run only the alerting-lane checks** for each configured provider (not the full audit — the coverage/retention/security lanes are out of scope for a fatigue read). Each writes its normal `findings.json` under `<audits-dir>/<target>/<date>/`, so the reads happen in the audit lane (which is allowed to call providers) and the roll-up library still makes zero provider calls.
3. **Roll up** exactly as `alert_fatigue_run` does below. With one provider you still get its config-tier + fire-history-tier picture; with two or more you also get the cross-source view (AF-002).

**If the operator has already run those audits today**, skip step 2 — the findings exist; go straight to the roll-up (that is roll-up mode). This is the "handle both": standalone drives the checks; roll-up consumes them; the same `alert-fatigue.json` comes out.

## What it produces

`${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue.json` (`scoutflo-alert-fatigue/v1`, `scoring_scope: non-scored`) with three advisory `AF-*` items, each citing the source findings it rolled up:

| ID | What it rolls up |
| --- | --- |
| `AF-001` | **Alerting-noise concentration** — every alerting/hygiene finding across all audits, grouped by source tool and severity, so you can see where the noise lives. Cites each source finding-ID; it re-scores nothing. |
| `AF-002` | **Cross-source alert storm** — a service that carries alerting-noise findings from **two or more** tools. One real incident on that service pages through every one of them; consolidating the paging path turns N pages back into one. |
| `AF-003` | **Alert-to-incident ratio** — computed **only** from an operator-supplied signal block (see below). Absent that block it is `not-in-scope`, never a fabricated actionability percentage. |

Plus the **human report** (see §Running it): `alert-fatigue-report.md` and a standalone `alert-fatigue-report.html` dashboard, rendered from `alert-fatigue.json` by [`report-standard/render-report-viz.sh`](../../report-standard/render-report-viz.sh) (`alert-fatigue` / `alert-fatigue-html` modes). The report leads with an at-a-glance line and the three honest tiers, then a **worst-first "top offenders" list where every noise finding shows problem → where → why it matters → the exact fix** (its `recommendation` + `remediation` pointer, joined from the home `findings.json`), where the noise concentrates by tool, the cross-source storms, the alert-to-incident ratio (or an explicit "not measured — needs an incident feed" block), and the cited benchmarks to score against. This is the deliverable a user reads — not the JSON. Same never-fabricate, cites-never-re-scores discipline as the roll-up.

## How it selects the noise (cites, never re-scores)

A finding is rolled into the fatigue view when its `area` names the alerting/routing/hygiene plane **or** its title carries noise vocabulary (flapping, permanently-firing, missing `for`/debounce, duplicate delivery, re-notify/repeat storms, resolve-noise, missing grouping/inhibition, noisy volume, over-broad mute/silence). Both signals are already in each audit's `findings.json`, so every audit's noise checks aggregate here without a hardcoded ID list that would go stale, and without any change to the audits themselves. The finding keeps its own `id` and `severity`; this roll-up only tags it as a fatigue signal and cites it.

## The optional fatigue-signal block (for AF-003 only)

`findings.json` records alerting **configuration** noise, not how many alerts actually fired or how many real incidents occurred — this roll-up has no incident feed. So the alert-to-incident ratio is computed **only** when you provide the counts, in `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue.json` (or a path in `ALERT_FATIGUE_SIGNAL`):

```json
{ "window": "7d", "alerts_fired": 4200, "incidents": 35 }
```

With it, `AF-003` reports `alerts_per_incident` (here 120 — a strong fatigue signal). Without it, `AF-003` is `not-in-scope` with that reason stated, and `AF-001`/`AF-002` (which need no incident data) still report. **This roll-up never invents an actionability number.**

## The three feed tiers (what is a real number vs a proxy vs verify-pending)

Every alert-fatigue signal falls into one of three tiers by the data it needs. This is the honest core — report each tier for what it is, never promote one to another:

- **Config tier (provider config only, always available):** symptom-vs-cause paging, actionability/severity-tiering (page vs ticket vs log), static-threshold-vs-burn-rate, and whether **dedup / grouping / inhibition / maintenance-window / recovery-threshold** are configured. Pure hygiene — a real yes/no from the rules.
- **Fire-history tier (the provider's alert event stream, no incident feed):** alert volume/rate, **pages-per-shift**, **flapping / self-resolve / transient rate**, **top-N noisiest rules**, **off-hours rate**, co-firing clusters (an alert-to-incident **proxy**), and a raw noise-reduction/dedup ratio. **These are honest measured numbers** from read-only access.
- **Incident-feed tier (needs the paging tool's incident/ack stream):** true precision/recall, MTTA/MTTR, %-actionable, ack/escalation ratios, and the **true** alert-to-incident ratio. Where the feed is absent, emit the structural/history finding and mark the outcome **`verify-pending (needs incident feed)`** or a labeled proxy — **never a fabricated percentage**.

## What "good" looks like — the canon + market benchmarks (cited)

Score against these; cite them; never invent one. Grounded in the SRE canon and vendor docs (research 2026-09-04):

- **Every page must be actionable** and require human intelligence; page on **symptoms, not causes** (Google SRE, *Monitoring Distributed Systems*).
- **On-call load ceiling: ≤2 incidents per 12-hour shift**, and on-call ≤25% of an engineer's time (Google SRE, *Being On-Call*). Pages-per-shift above this is the fatigue red flag.
- **Alert on SLO burn-rate, not raw static thresholds** — multi-window/multi-burn-rate: page **14.4** (1h/5m) and **6** (6h/30m), ticket **1** (3d/6h); short window ≈ **1/12 of the long**, long window **≤48h** (SRE Workbook + Datadog burn-rate docs). A bare static threshold on a ratio is flap-prone.
- **Target a 1:1 alert-to-incident ratio**; group/dedupe so one incident → one page (Google SRE). Grouping window ≈ **30 min** default (to 48h), dedup window ≈ **24h** default across incident tools (incident.io / FireHydrant / Opsgenie).
- **AIOps compression sweet spot ≈ 70–85%** — and higher is **not** strictly better: over-compression mis-groups and hides real signal (BigPanda target; Splunk; INOC caveat).
- **Off-hours bands** (a citable definition): Working 8am–7pm / Late 7pm–11pm / Overnight 11pm–8am (incident.io).

**Defensible stats for the report/pitch (verified) — and what NOT to claim:**
- ✅ SRE Workbook: *"you could receive up to 144 alerts per day … and still meet the SLO"* — the raw-volume-≫-actionable framing.
- ✅ Clinical alarm-fatigue (peer-reviewed, Drew 2014, PLOS ONE): **2.5M alarms in 31 days, 88.8% false, 187/bed/day**; The Joint Commission estimates **85–99% of alarms need no intervention** (cite as their estimate; 88.8% is the verified backstop).
- ⚠️ PagerDuty vendor survey (directional): **3-in-5 on-call staff work +10h/week; 2-in-5 expect burnout** — label vendor-sponsored.
- 🚩 **Do NOT cite as research:** a specific "alert-to-incident compression ratio," a "% of pages that are off-hours," or MTTR/attrition percentages — these are vendor marketing/folklore with no primary source. Attribute any compression % explicitly to the vendor and label it a product claim. (This is the same never-fabricate rule the whole toolkit runs on.)

The full principles, anti-patterns, per-tier auditor checklist, vendor technique catalog, and source citations are in [references/methodology.md](references/methodology.md).

## Honest ceiling (stated every run)

- **Structural, not behavioral.** `AF-001`/`AF-002` are read off the audits' *configuration* findings — where noise is structurally likely and which services are multi-tool-paged. They are not a measured page rate. The only behavioral number is `AF-003`, and only when you supply the signal block.
- **Non-scored.** There is no 0–100 here and no `check-findings.sh` reconciliation; `alert-fatigue.json` is a synthesis file like `correlation.json`, not a scored audit result. Finding-ID prefix `AF` is registered as a non-scored roll-up prefix.
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

Expected: `[alert-fatigue] Written <audits-dir>/alert-fatigue.json` plus a one-line summary (`alerting-noise findings: N | cross-source storms: N | tools with noise: N | ratio: computed|not-in-scope`). Zero findings for the date is a clean skip, not an error. It reads only local files, so re-running is free.

**Then render the human report** — a pretty, self-contained deliverable that shows each problem *and its exact fix*, so the user does not read raw JSON. The renderer is deterministic and joins each cited noise finding back to its home `findings.json` for the fix text (`recommendation` + `remediation`); it never re-derives or re-scores:

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
| A storm reported without evidence | `AF-002` only fires when a service's `affected` token appears in alerting-noise findings from two or more distinct target directories; each contributing finding is cited by target + id |
| Mutating a finding's severity from the roll-up | The library only reads findings.json; it writes alert-fatigue.json and touches no per-audit artifact |
