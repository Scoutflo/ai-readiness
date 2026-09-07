# Alert noise & fatigue — methodology (canon + market, cited)

The grounding behind `alert-fatigue`. Distilled from the SRE canon and the incident/observability vendors. Every benchmark here is cited to a public primary source; nothing is a fabricated number. This file is *doctrine* the skill scores against — not customer data.

## 1. Principles (SRE canon)

- **Page on symptoms, not causes.** Only page on causes that are "very definite, very imminent." [Google SRE, *Monitoring Distributed Systems*]
- **Every page must be actionable** and require human intelligence — "pages with rote, algorithmic responses should be a red flag"; a rote response should be automated, not paged. [MDS]
- **Pages should be novel.** [MDS]
- **Alert on SLO burn-rate, not raw static thresholds.** Static thresholds on a ratio flap and fire while the SLO is still met. [SRE Workbook, *Alerting on SLOs*]
- **Tier by urgency: page / ticket / log.** Only urgent, actionable, symptom-level conditions page. [MDS]
- **On-call load ceiling: ≤2 incidents per 12-hour shift** (an incident ≈ 6h of work); on-call ≤25% of time, total ops ≤50%. [Google SRE, *Being On-Call*]
- **Target a 1:1 alert-to-incident ratio**; group related alerts. [Being On-Call]
- **Over-monitoring degrades reliability** — the Bigtable case: too many alerts made the team miss the real user-facing problems. Bias toward *removing* alerts. [MDS]
- **The fatigue mechanism:** "I can only react with a sense of urgency a few times a day before I become fatigued"; noisy alerts get skimmed/ignored, and a real page gets masked by the noise. [MDS/Being On-Call]

## 2. Anti-patterns (named noise/fatigue failure modes)

Cause-based paging · non-actionable/informational pages · robotic-response pages · static thresholds that flap · over-alerting / triage tax · duplicate/cascading fan-out · low-priority constant interrupts · email "alert spam" routed like a page · self-resolving/transient pages (long reset time) · over-damped alerts (long `for:`/windows that wreck detection time & recall) · alarm fatigue itself (desensitization → ignored/missed real alerts).

## 3. The three feed tiers + the auditor's checklist

The organizing principle (six research passes converged on it): every signal falls into one tier by the data it needs.

**A. Config tier — provider config alone (always available):**
1. Every paging rule maps to a user-visible symptom (golden-signal/SLO), not an internal cause.
2. Each page is actionable and non-robotic (a real runbook).
3. Correct severity tiering (page vs ticket vs log/email); no informational alerts on the pager.
4. SLO/burn-rate based vs raw static threshold (flag short-window static thresholds on ratios).
5. For SLO alerts: multi-window multi-burn-rate present vs single-window.
6. Dedup / grouping / inhibition / maintenance-window / recovery-threshold configured.

**B. Fire-history tier — the alert event stream, NO incident feed (honest measured numbers):**
7. Alert volume & rate per rule / service / shift.
8. Pages-per-shift vs the ≤2/12h ceiling.
9. Flapping / self-resolve / transient rate (fires-and-clears within N min, no action).
10. Top-N noisiest rules and their share of total volume.
11. Off-hours / low-priority interrupt rate.
12. Co-firing clusters in a short window (an alert-to-incident **proxy**).
13. Auto-resolve vs human-acknowledged ratio (where the provider exposes ack).

**C. Incident-feed tier — needs the paging tool's incident/ack stream (else proxy / verify-pending):**
14. Precision = significant alerts ÷ all alerts.
15. Recall = detected significant events ÷ all significant events.
16. True alert-to-incident ratio = alerts ÷ correlated incidents (BigPanda's published form: `1 − unique(incidents)/unique(alerts)`).
17. % actionable = pages acted on ÷ pages.
18. Detection time (incident start → alert) and reset time (resolve → clear).

**D. Systemic (config + roster/schedule):** operational-load fraction vs the 50%/25% caps; escalation-path/incident-process/blameless-postmortem scaffolding present.

**Feed-dependency is the never-fabricate rule:** tiers A & B are real numbers from read-only access; tier C is a labeled proxy or `verify-pending (needs incident feed)` — never a fabricated precision/ratio.

## 4. Vendor noise-reduction technique catalog (config-hygiene vs runtime)

- **Deduplication** (same source/key, still-firing → collapse): PagerDuty `dedup_key`, Opsgenie **alias**, Rootly dedup-key-path, FireHydrant `idempotency_key` (default 24h window), incident.io dedup key. → config-hygiene (key design) + runtime effect.
- **Grouping** (different sources, same episode, within a window → one leader + silent members): PagerDuty time/content/**intelligent (ML)** grouping; incident.io fixed/extending window (30 min default, 48h max, 1,000-alert cap); Rootly (5 min–7 day window, leader/members); FireHydrant (30 min default). → config-hygiene.
- **Suppression / inhibition**: Alertmanager `inhibit_rules` (node-down mutes its pods); PagerDuty Event Orchestration suppress/drop/pause. → config-hygiene.
- **Maintenance windows / muting**: Datadog downtimes (one-time + recurring, auto-mute on VM shutdown); Alertmanager `mute_time_intervals`; Opsgenie maintenance policies. → config-hygiene.
- **Thresholding / hysteresis / burn-rate**: Datadog recovery thresholds, `min` (all-points-violate), composite; burn-rate SLO monitors (short = 1/12 long, long ≤48h). → config-hygiene.
- **Auto-pause transient / auto-resolve**: PagerDuty APIN (2/3/5/10/15 min, ML-recommended) + service auto-resolve timeout; Opsgenie auto-close. → config-hygiene + runtime.
- **Correlation / AIOps (ML)**: PagerDuty Intelligent Alert Grouping, BigPanda/Moogsoft situations. → runtime + ML. AIOps compression sweet spot **≈ 70–85%**; higher risks mis-grouping (BigPanda target; Splunk; INOC caveat).

**The cross-tool gap no single vendor fills** (our wedge): double-coverage (two tools paging the same SLO), cross-source storms, on-call load aggregated across *all* paging sources, and SLO-coherence across tools.

## 5. Benchmarks — verified vs folklore (for the report/pitch)

- ✅ **SRE Workbook:** "you could receive up to **144 alerts per day** … and still meet the SLO" — raw-volume-≫-actionable framing.
- ✅ **Clinical alarm fatigue (peer-reviewed, Drew 2014, PLOS ONE):** **2.5M alarms / 31 days, 88.8% false, 187/bed/day.**
- ✅/⚠️ **The Joint Commission (SEA 50):** estimates **85–99% of alarms need no intervention** (cite as their estimate; Drew's 88.8% is the verified backstop).
- ⚠️ **PagerDuty vendor survey (directional):** 3-in-5 on-call staff work +10h/week; 2-in-5 expect burnout. Label vendor-sponsored.
- 🚩 **Do NOT cite as research:** a specific alert-to-incident "compression ratio," a "% of pages off-hours," or MTTR/attrition percentages — vendor marketing/folklore, no primary source. Attribute any compression % to the vendor as a product claim.

## Sources
Google SRE Book (*Monitoring Distributed Systems*, *Being On-Call*); Google SRE Workbook (*Alerting on SLOs*); Drew et al. 2014 (PLOS ONE) & Joint Commission SEA 50 (alarm fatigue); PagerDuty, Datadog, Alertmanager, incident.io, Rootly, FireHydrant, Opsgenie, Grafana OnCall, Splunk On-Call, BigPanda, Moogsoft docs. (Research compiled 2026-09-04.)
