# Triage mode — the fast, worst-first pass (shared across audits)

A full deep audit of a large estate can take tens of minutes and a lot of tokens.
That is right for a scheduled deep run, but wrong for a 30-minute customer session
or a first look. **Triage mode** is the fast first pass: run a curated,
high-signal, cheap-to-read subset per provider, rank the worst findings across the
whole estate, and render the executive one-pager — in a few minutes — then offer
the deep audit for detail. It never fabricates and never mutates; it just does
*less, first*.

## The inclusion rule (what belongs in the triage subset)

Grounded in the SRE canon and the cloud/security triage tools (Google SRE golden
signals + symptom-based paging; AWS Trusted Advisor Priority "actions needed";
AWS Security Hub severity-first; CIS "Level 1 first"; PagerDuty SEV; mitigate
-before-diagnose):

> A check belongs in triage **iff** it is **high-signal** — a failure maps to a
> user-visible symptom (a golden-signal proxy: latency/traffic/errors/saturation)
> or to irreversible loss/exposure (data loss, a page that reaches nobody, a
> secret leak) — **AND low-cost-to-read** — answerable from an already-computed,
> pre-aggregated, or bulk-listable source, with **no per-resource fan-out**.

Everything else (per-object sweeps, retention math, cost rightsizing across
hundreds of resources, deep correlation) is deferred to the full audit.

## The `SCOUTFLO_TRIAGE` contract

When `SCOUTFLO_TRIAGE=1` (or the operator asks for a triage/fast pass), an audit:
1. **Forces the smallest scope** — treat the estate as if the scope checkpoint
   returned "critical services only"; never grind the whole estate.
2. **Runs only its high-signal subset** (the table below), skipping the expensive
   per-resource sweeps (e.g. per-log-group, per-bucket lifecycle, per-object
   history).
3. **Prefers bulk/pre-aggregated reads** over per-resource calls (see §AWS).
4. **Never backgrounds a sweep** (see [estate-scope-checkpoint.md](estate-scope-checkpoint.md)) —
   triage is fast because it reads *less*, not because it defers work.
5. Emits its normal `findings.json` (a subset), so the roll-ups, correlation, and
   the exec one-pager consume it unchanged. A triage run marks `scope: "triage"` so
   a reader knows it is a fast subset, not a full assessment, and never reports a
   confident all-clear from a subset.

## The per-provider high-signal triage subset

The smallest set that catches the worst reliability/observability problems cheaply.
Each is the provider's own already-shipped check — triage runs a curated subset, it
does not add new checks:

| Provider | Triage subset (high-signal, cheap) |
| --- | --- |
| `aws` | zero-alarm critical DBs/functions; alarms firing now (`describe-alarms --state-value ALARM`, bulk); alarms → dead-end SNS (0 subscribers); public-exposure / no-backup on a critical store |
| `sentry` | issue-alert rules that reach nobody (no action/owner); the only uptime/critical detector wired to zero workflows; un-gated chronic re-page |
| `datadog` | monitors with no notification target / `@all`; monitors stuck in ALERT; no-recovery-threshold on a paging monitor |
| `grafana` | default notification policy → no-op contact point; `noDataState=Alerting` flap; a paging rule with no `for` |
| `signoz` | alert rule → no channel / dead channel; a critical rule disabled with no maintenance window |
| `alertmanager`/`prometheus` | default route → black-hole receiver; a rule with no `for`; missing inhibition while a node-down + per-pod alerts coexist |
| `kubernetes` | crashlooping/not-ready critical workloads; no resource limits on a critical deployment; a namespace with no PodSecurity |
| (cost) | **not in triage** — cost is a deep-run concern; the exec one-pager surfaces the single top provider-native $ lever only |

Triage always includes the **alert-fatigue reachability** read (AF-004: "N of M
alerting objects cannot reach a human") — it is the highest-signal, cheapest
fatigue answer and needs only the config the audits already pulled.

## The output — the executive one-pager

Triage renders `render-report-viz.sh exec-summary <audits-dir> <run-date> [N]`:
a **posture grade** (AT RISK / NEEDS WORK / FAIR / HEALTHY) + severity counts, the
**top N worst findings (5–7)** each as *what · where (blast radius) · $ · the fix*,
the **reachability headline**, and the **single top real cost lever**. Ranking is
**severity-first (lexicographic), then recoverable points, then $ as an in-band
tiebreaker** — a large dollar figure NEVER promotes a low-severity finding above a
critical one, and there is **no blended cross-domain "risk score"** (CVSS and AWS
Security Hub both keep severity separate from $/criticality; a single blended index
is folklore we don't emit). The exec one-pager is also rendered at the top of the
full `audit-all` report, so a leader gets the same worst-first view either way.

## AWS: prefer these cheap bulk reads in triage (over per-resource sweeps)

Verified against the AWS API reference — one bulk call each, instead of walking
resources:
- **Inventory:** ResourceGroupsTaggingAPI `GetResources` (all tagged resources across
  services in one paginated call; note it omits *untagged* resources) or an **AWS Config
  aggregator** `SelectAggregateResourceConfig` (estate-wide config+compliance, no extra cost).
- **What's on fire:** `cloudwatch describe-alarms --state-value ALARM` (one paginated call).
- **Golden signals at scale:** `cloudwatch get-metric-data` — **up to 500 queries per call**
  with metric math (e.g. error-rate = Errors/Invocations) — instead of N× `get-metric-statistics`.
- **Real $ (deep run, not triage):** Compute Optimizer / Cost Explorer
  `GetRightsizingRecommendation` / Trusted Advisor Priority — pre-computed recommendation
  lists, never a per-resource walk.

Triage read-order: one inventory pass → one `describe-alarms --state-value ALARM` →
one batched `get-metric-data` for golden-signal proxies → the reachability read. That
is the whole fast pass; everything deeper is the full audit.

## Sources
Google SRE Book (*Monitoring Distributed Systems* golden signals + symptom paging;
*Managing Incidents* mitigate-before-diagnose); AWS Trusted Advisor Priority, Security
Hub ASFF (severity ≠ criticality), Config aggregator, ResourceGroupsTaggingAPI
`GetResources`, CloudWatch `DescribeAlarms`/`GetMetricData`, Compute Optimizer, Cost
Explorer `GetRightsizingRecommendation`; CVSS v3.1 spec (severity ≠ risk/priority);
PagerDuty severity levels; CIS Benchmarks Level 1/2. (Research compiled 2026-09-08.)
