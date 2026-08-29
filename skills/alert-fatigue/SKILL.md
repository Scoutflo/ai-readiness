---
name: alert-fatigue
disable-model-invocation: true
description: Non-scored cross-audit roll-up of alert fatigue — aggregates the alerting-noise findings the individual audits already produced, finds services paged by more than one tool for a single incident (cross-source storm), and (only when you supply an incident-count signal block) computes the alert-to-incident ratio. Runs automatically inside /scoutflo:audit-all after the correlation engine, or standalone. Reads only this run's findings.json files — zero provider calls, never re-scores a finding, cites source finding-IDs.
---

# alert-fatigue

A **non-scored roll-up** that answers a question no single backend can: *across every tool you audited, how much of your paging is noise, and does one incident page through several tools at once?* It is a sibling of `/scoutflo:correlation-engine` and the `cost-analysis` roll-up — it runs after the audits, reads only the `findings.json` files they already wrote, and writes one `alert-fatigue.json`. It **makes no provider calls, never mutates a finding or its severity, and never re-scores** — each alerting-noise finding is scored **once**, in its home audit (`audit-alertmanager`, `audit-grafana`, `audit-datadog`, `audit-lgtm`, `audit-pagerduty`, `audit-jsm`, `audit-zenduty`, `audit-groundcover`); this roll-up **cites** those source finding-IDs and adds the estate-wide view.

It runs automatically in `/scoutflo:audit-all` (Phase 3.6, right after correlation). You can also run it standalone after a few audits have written findings for the same date.

## What it produces

`${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/alert-fatigue.json` (`scoutflo-alert-fatigue/v1`, `scoring_scope: non-scored`) with three advisory `AF-*` items, each citing the source findings it rolled up:

| ID | What it rolls up |
| --- | --- |
| `AF-001` | **Alerting-noise concentration** — every alerting/hygiene finding across all audits, grouped by source tool and severity, so you can see where the noise lives. Cites each source finding-ID; it re-scores nothing. |
| `AF-002` | **Cross-source alert storm** — a service that carries alerting-noise findings from **two or more** tools. One real incident on that service pages through every one of them; consolidating the paging path turns N pages back into one. |
| `AF-003` | **Alert-to-incident ratio** — computed **only** from an operator-supplied signal block (see below). Absent that block it is `not-in-scope`, never a fabricated actionability percentage. |

## How it selects the noise (cites, never re-scores)

A finding is rolled into the fatigue view when its `area` names the alerting/routing/hygiene plane **or** its title carries noise vocabulary (flapping, permanently-firing, missing `for`/debounce, duplicate delivery, re-notify/repeat storms, resolve-noise, missing grouping/inhibition, noisy volume, over-broad mute/silence). Both signals are already in each audit's `findings.json`, so every audit's noise checks aggregate here without a hardcoded ID list that would go stale, and without any change to the audits themselves. The finding keeps its own `id` and `severity`; this roll-up only tags it as a fatigue signal and cites it.

## The optional fatigue-signal block (for AF-003 only)

`findings.json` records alerting **configuration** noise, not how many alerts actually fired or how many real incidents occurred — this roll-up has no incident feed. So the alert-to-incident ratio is computed **only** when you provide the counts, in `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue.json` (or a path in `ALERT_FATIGUE_SIGNAL`):

```json
{ "window": "7d", "alerts_fired": 4200, "incidents": 35 }
```

With it, `AF-003` reports `alerts_per_incident` (here 120 — a strong fatigue signal). Without it, `AF-003` is `not-in-scope` with that reason stated, and `AF-001`/`AF-002` (which need no incident data) still report. **This roll-up never invents an actionability number.**

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

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Fabricated "N% of alerts are actionable" | `AF-003` is computed only from an operator-supplied `fatigue.json` signal block; absent it, the ratio is `not-in-scope`, never guessed |
| Re-scoring noise that an audit already scored | This roll-up never emits a scored result; it cites source finding-IDs and aggregates. Noise is scored once, in its home audit |
| A single-block signoz/kubernetes or a multi-target label dropped from the roll-up | The findings collector globs BOTH `<target>/<date>/` and `<integration>/<label>/<date>/`, matching correlation-engine and the report standard |
| A storm reported without evidence | `AF-002` only fires when a service's `affected` token appears in alerting-noise findings from two or more distinct target directories; each contributing finding is cited by target + id |
| Mutating a finding's severity from the roll-up | The library only reads findings.json; it writes alert-fatigue.json and touches no per-audit artifact |
