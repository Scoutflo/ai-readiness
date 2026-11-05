# Alert noise & fatigue; methodology (canon + market, cited)

The grounding behind `alert-fatigue`. Distilled from the SRE canon and the incident/observability vendors. Every benchmark here is cited to a public primary source; each number remains attributed to that source. This non-scored method does not turn research values into observations about your estate.

## Applying research and decision thresholds

Cited study figures and vendor defaults remain source facts. They are not measured
values or mandatory limits for your environment. State your actual on-call shift,
incident budget, SLO, business hours/time zone and observation window. Treat a
missing local policy as unknown. Record configurable thresholds in the collection
plan, including the chronic duration and any flapping interval; use documented
examples only until you choose values appropriate to your service.

Wrong: “88.8% of your alerts are false” from a clinical study. Right: “This study
illustrates desensitization; your actionable fraction needs reviewed labels and a measured denominator.”
Wrong: two identical policy names prove duplicate pages. Right: verify service
identity, linked paths and actual delivery before claiming duplication.
Wrong: two incidents always violate an on-call ceiling. Right: compare observed
incident work with the team’s declared shift and paging budget.

## 1. Principles (SRE canon)

- **Page on symptoms, not causes.** Only page on causes that are "very definite, very imminent." [Google SRE, *Monitoring Distributed Systems*]
- **Every page must be actionable** and require human intelligence; "pages with rote, algorithmic responses should be a red flag"; a rote response should be automated, not paged. [MDS]
- **Pages should be novel.** [MDS]
- **Alert on SLO burn-rate, not raw static thresholds.** Static thresholds on a ratio flap and fire while the SLO is still met. [SRE Workbook, *Alerting on SLOs*]
- **Tier by urgency: page / ticket / log.** Only urgent, actionable, symptom-level conditions page. [MDS]
- **Google's worked on-call example:** two incidents per 12-hour shift, with its assumed incident-work duration, and its 25% on-call/50% operations time allocation. Use the example to discuss your staffing and work budget; these are not universal failure thresholds. [Google SRE, *Being On-Call*]
- **Group related alerts while preserving distinct problems.** An aspiration to avoid redundant pages does not equate source-event, incident and notification counts or require a universal 1:1 ratio. [Being On-Call]
- **Over-monitoring degrades reliability**; the Bigtable case: too many alerts made the team miss the real user-facing problems. Bias toward *removing* alerts. [MDS]
- **The fatigue mechanism:** "I can only react with a sense of urgency a few times a day before I become fatigued"; noisy alerts get skimmed/ignored, and a real page gets masked by the noise. [MDS/Being On-Call]

## 2. Anti-patterns (named noise/fatigue failure modes)

Cause-based paging · non-actionable/informational pages · robotic-response pages · static thresholds that flap · over-alerting / triage tax · duplicate/cascading fan-out · low-priority constant interrupts · email "alert spam" routed like a page · self-resolving/transient pages (long reset time) · over-damped alerts (long `for:`/windows that wreck detection time & recall) · alarm fatigue itself (desensitization → ignored/missed real alerts).

## 3. The three feed tiers + the auditor's checklist

The organizing principle: every signal falls into one tier by the data it needs.

**A. Config tier; provider config alone (always available):**
1. Every paging rule maps to a user-visible symptom (golden-signal/SLO), not an internal cause.
2. Each page is actionable and non-robotic (a real runbook).
3. Correct severity tiering (page vs ticket vs log/email); no informational alerts on the pager.
4. SLO/burn-rate based vs raw static threshold (flag short-window static thresholds on ratios).
5. For SLO alerts: multi-window multi-burn-rate present vs single-window.
6. Dedup / grouping / inhibition / maintenance-window / recovery-threshold configured.

**B. Fire-history tier; the alert event stream (only supported measurements):**
7. Alert volume & rate per rule / service / shift.
8. Source events per declared shift. Pages or human interruptions require separate delivery evidence; compare incident work with your chosen budget.
9. Observed fire/clear transitions within a declared interval. A short episode is a review candidate, not proof that no action was needed.
10. Top-N noisiest rules and their share of total volume.
11. Off-hours source-event rate using a declared timezone and business-hours model; do not relabel it an interruption rate.
12. Co-firing clusters in a short window (an alert-to-incident **proxy**).
13. Resolution and acknowledgement observations with known actor semantics; neither establishes actionability.

**C. Incident-history tier; each metric requires its own supporting evidence:**
14. Precision needs independently reviewed true/false alert labels, not an acknowledgement flag.
15. Recall needs independent ground truth including missed incidents; a paging feed cannot observe its own misses.
16. Alert-to-incident ratio = source alerts divided by mapped incident episodes in the same window. Compression, `1 − incidents/alerts`, is a different measure. Incident-lifetime alerts cannot substitute for source-window events.
17. Actionable percentage needs reviewed actionable labels and a clearly stated denominator. Report acknowledgement fractions under their own name.
18. Detection/reset latency needs source-event timestamps, clock semantics and correlated provider transitions. Response means need known transition semantics and sample counts alongside open/censored records.

**D. Systemic (config + roster/schedule):** operational-load fraction against your declared staffing/work budget; escalation-path, incident-process and learning procedures.

**Feed dependency is the never-fabricate rule:** access to an API does not establish every metric above. Keep the observed units, selected scope, window, completeness and missing prerequisites visible. Do not promote structural configuration or a proxy to a measured outcome.

**The measured tiers use read-only collection.** Provider recipes and verification limits are in [fire-history-reads.md](fire-history-reads.md). Splunk On-Call uses its bounded native history lane and preserves incident units under AF-005 separately from source fires. Off-hours needs a verified native definition matching your policy, or timestamp derivation using your timezone and business-hours window.

## 4. Vendor noise-reduction technique catalog (config-hygiene vs runtime)

- **Deduplication** (same source/key, still-firing → collapse): PagerDuty `dedup_key`, Opsgenie **alias**, Rootly dedup-key-path, FireHydrant `idempotency_key` (default 24h window), incident.io dedup key. → config-hygiene (key design) + runtime effect.
- **Grouping** (different sources, same episode, within a window → one leader + silent members): PagerDuty time/content/**intelligent (ML)** grouping; incident.io fixed/extending window (30 min default, 48h max, 1,000-alert cap); Rootly (5 min-7 day window, leader/members); FireHydrant (30 min default). → config-hygiene.
- **Suppression / inhibition**: Alertmanager `inhibit_rules` (node-down mutes its pods); PagerDuty Event Orchestration suppress/drop/pause. → config-hygiene.
- **Maintenance windows / muting**: Datadog downtimes (one-time + recurring, auto-mute on VM shutdown); Alertmanager `mute_time_intervals`; Opsgenie maintenance policies. → config-hygiene.
- **Thresholding / hysteresis / burn-rate**: Datadog recovery thresholds, `min` (all-points-violate), composite; burn-rate SLO monitors (short = 1/12 long, long ≤48h). → config-hygiene.
- **Auto-pause transient / auto-resolve**: PagerDuty APIN (2/3/5/10/15 min, ML-recommended) + service auto-resolve timeout; Opsgenie auto-close. → config-hygiene + runtime.
- **Correlation / AIOps (ML)**: PagerDuty Intelligent Alert Grouping and BigPanda/Moogsoft situations. Vendor compression targets are product claims, not acceptance bands. Verify both repeated events and unrelated critical controls to detect over-grouping.

**The cross-tool gap no single vendor fills** (the cross-tool analysis): double-coverage (two tools paging the same SLO), cross-source storms, on-call load aggregated across *all* paging sources, and SLO-coherence across tools.

## 5. Benchmarks; verified vs folklore (for the report/pitch)

- ✅ **SRE Workbook:** "you could receive up to **144 alerts per day** … and still meet the SLO"; raw-volume-≫-actionable framing.
- ✅ **Clinical alarm fatigue (peer-reviewed, Drew 2014, PLOS ONE):** **2.5M alarms / 31 days, 88.8% false, 187/bed/day.**
- ✅/⚠️ **The Joint Commission (SEA 50):** estimates **85-99% of alarms need no intervention** (cite as their estimate; Drew's 88.8% is the verified backstop).
- ⚠️ **PagerDuty vendor survey (directional):** 3-in-5 on-call staff work +10h/week; 2-in-5 expect burnout. Label vendor-sponsored.
- 🚩 **Do NOT cite as research:** a specific alert-to-incident "compression ratio," a "% of pages off-hours," or MTTR/attrition percentages; vendor marketing/folklore, no primary source. Attribute any compression % to the vendor as a product claim.

## 6. Peer-reviewed and empirical anchors

Use primary-study anchors for empirical claims. **Label every emitted number by source tier: `primary-study` › `industry-canon` (SRE) › `vendor-methodology` › `vendor-survey/folklore`.** The last two must never be presented as measured facts about your system.

- ✅ **primary-study; noise is compressible (the IT/DevOps analogue to the clinical data):** Zhao et al., *Understanding and Handling Alert Storm for Online Service Systems*, **ICSE-SEIP 2020**, DOI `10.1145/3377813.3381363`; on real large-scale alert data, alert-storm summarization "can reduce the number of alerts that need to be examined by **more than 98%**" (F1 > 0.9). This is the defensible correlation/compression citation; use it instead of any vendor "we cut noise by N%".
- ✅ **primary-study; wrong ownership/routing is measurable and costly (supports ownership/routing checks):** Chen et al., *An Empirical Investigation of Incident Triage for Online Service Systems*, **ICSE-SEIP 2019**, DOI `10.1109/ICSE-SEIP.2019.00020` (Microsoft production data); **4.11%-91.58%** of incident reports are reassigned at least once, inflating triage time **up to 10.16×**. Corroborated by Chen et al., *Continuous Incident Triage…*, **ASE 2019**, DOI `10.1109/ASE.2019.00042` (up to 11.32 reassignment iterations).
- ✅ **primary-study; the transferable law of alarm fatigue:** Sendelbach & Funk 2013, *Alarm Fatigue: A Patient Safety Concern*, AACN Adv Crit Care 24(4):378-86, **PMID 24153215** ("**72%-99%** of clinical alarms are false"; desensitization → *missed real alarms*), consolidating Cvach 2012 integrative review, **PMID 22839984**. The transferable principle: it is the **false / non-actionable RATE**, not raw volume, that causes missed real alerts; so the headline metric is **per-rule actionability**, not alert count. (Drew 2014 PLOS ONE, above, is the field-study backstop.)
- ✅ **config-linter corroboration (external, independent):** the Prometheus/Alertmanager config-tier checks line up with **pint** (Cloudflare's Prometheus rule linter); `alerts/for`, `alerts/comparison`, `alerts/annotation`, `alerts/template`, `promql/series` (dead rule), `rule/duplicate`, `labels/conflict`, `group/interval` (https://cloudflare.github.io/pint/checks/); and **promtool check rules**. That an independent, widely-used linter enforces the same rules is corroborating guidance, not evidence that a specific finding is true.
- 🧭 **exact vendor defaults to key deviations off (primary, from the docs):** Alertmanager `group_wait=30s`, `group_interval=5m`, `repeat_interval=4h`, `resolve_timeout=5m`, `continue=false`; Prometheus `keep_firing_for` added in **v2.42.0 (2023-02-01)**; Grafana Alerting defaults `group_wait=30s / group_interval=5m / repeat_interval=4h`; Datadog metric-monitor `require_full_window` default **`true`**; SigNoz `condition.matchType` default **`at least once`** (the flap-prone one). A value well below these defaults on a paging route is the mechanically-defensible signal; *not* a blanket "must be ≥ X" (that is folklore).
- 🚩 **reconfirmed folklore (never assert as measured fact):** the **1:1 alert-to-incident ratio** is an SRE *target*/aspiration, not a measured population number; **population MTTA/MTTR, "% of alerts that are noise," "% off-hours pages," "% of teams with alert fatigue"** come from self-selected vendor "State of On-Call" surveys; label `vendor-survey`, never measured-from-config. **SigNoz and Sentry have no native burn-rate/multi-window SLO alert** (Sentry offers fixed + dynamic-anomaly thresholds; SigNoz offers anomaly-based alerts); do not claim they do.

## Sources
Google SRE Book (*Monitoring Distributed Systems*, *Being On-Call*); Google SRE Workbook (*Alerting on SLOs*); Rob Ewaschuk, *My Philosophy on Alerting* (Google, doctrine/opinion). Peer-reviewed: Zhao et al. ICSE-SEIP 2020 (DOI 10.1145/3377813.3381363); Chen et al. ICSE-SEIP 2019 (DOI 10.1109/ICSE-SEIP.2019.00020) & ASE 2019 (DOI 10.1109/ASE.2019.00042); Sendelbach & Funk 2013 (PMID 24153215); Cvach 2012 (PMID 22839984); Drew et al. 2014 (PLOS ONE); Joint Commission SEA 50. Vendor docs (primary for their own config): Prometheus/Alertmanager, pint (Cloudflare), promtool, Grafana Alerting best-practices, Datadog (monitors/burn-rate/flapping), Sentry, SigNoz, PagerDuty alerting principles, incident.io, Rootly, FireHydrant, Opsgenie, Grafana OnCall, Splunk On-Call, BigPanda, Moogsoft. Surveys (vendor, directional only): AIOps literature survey Remil et al. 2024 (arXiv 2404.01363). (Research compiled 2026-09-04; deepened 2026-09-07.)
