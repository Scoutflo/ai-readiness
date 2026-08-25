---
name: start
description: 'Orientation for the Scoutflo AI Readiness: the local-only guarantee, first steps, the full skill catalog, credential tiers, and where audit reports land. Use when the user asks where to start, what the toolkit can do, which skills exist, how reports and scoring work, or whether any data leaves their machine. Do not use to create credentials (use connect), to check config health (use doctor), or to run an audit (use audit-all or a specific audit skill).'
---

# Scoutflo AI Readiness: Start Here

This toolkit audits, hardens, and monitors your infrastructure and observability stacks from Claude Code. Audit skills produce a scored report with command-level evidence. Setup skills fix what an audit found, one confirmed change at a time. Harness skills, this one included, wire everything together.

State your installed toolkit version in this orientation (read `version` from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`). Plugins do not auto-update: if a teammate's skill list or picker looks different, compare versions first and update with `claude plugin update scoutflo@scoutflo`.

## Everything runs on your side

- Every API call originates from your machine or your CI. Nothing is sent to Scoutflo: no telemetry, no report upload, no callbacks.
- Configuration lives in `~/.scoutflo/toolkit.yaml`: hosts, orgs, and names in plain text. Secrets never go in that file; every `*_env` key names an environment variable that holds the secret, and skills check presence only, never the value.
- Audit skills are strictly read-only: GET, list, describe, query. No test notifications, no silences, no state creation of any kind.
- Setup skills show you the exact change, wait for your explicit confirmation, apply it, then re-read the object to prove the change landed.

## First steps

1. `/scoutflo:connect` sets up `~/.scoutflo/toolkit.yaml` and walks you through creating credentials per integration: exact scopes, where to click, read-only tokens for audits. It first scans for credentials you already have and offers to reuse them, and it stores tokens in the home-anchored `~/.scoutflo/env` so you set each one **once** — new terminals, new sessions, and other directories all pick them up automatically.
2. `/scoutflo:doctor` validates everything live: config parses, env vars are set, binaries exist, one cheap call per integration succeeds. Run it whenever something feels off. Type the full name — bare `/doctor` is Claude Code's own built-in install-diagnostic, a different command with nothing to do with this toolkit.
3. `/scoutflo:map-topology` (recommended) writes `./scoutflo-audits/topology.md`, your service map. With it, findings name your actual services instead of generic ones. On large clusters it works in namespace batches and resumes if interrupted.
4. Run your first audit: `/scoutflo:audit-lgtm` (also your **Prometheus** audit; pair with `/scoutflo:audit-alert-routing` for the Prometheus→Alertmanager paging path), `/scoutflo:audit-grafana`, `/scoutflo:audit-sentry`, `/scoutflo:audit-pagerduty`, `/scoutflo:audit-datadog`, `/scoutflo:audit-elk`, `/scoutflo:audit-jsm`, `/scoutflo:audit-zenduty`, `/scoutflo:audit-groundcover`, `/scoutflo:audit-clickstack`, `/scoutflo:audit-signoz`, `/scoutflo:audit-kubernetes`, `/scoutflo:audit-alert-routing`, `/scoutflo:audit-digitalocean`, `/scoutflo:audit-gcp`, `/scoutflo:audit-azure`, `/scoutflo:audit-aws`, or `/scoutflo:audit-cost` (cross-provider cost). Or run everything configured at once with `/scoutflo:audit-all`. Every audit sizes your estate first with cheap list calls and says which path it picked: small estates get a single pass, large ones run in bounded, resumable batches.
5. Optional: `/scoutflo:schedule-audits` makes the audits recurring, with a Slack brief per run.

## The skills

| Skill | Lane | What it does |
| --- | --- | --- |
| `/scoutflo:start` | harness | This orientation |
| `/scoutflo:connect` | harness | Guided credential setup per integration, two token tiers |
| `/scoutflo:doctor` | harness | Preflight: config, env vars, one live check per integration |
| `/scoutflo:map-topology` | harness | Service map into `./scoutflo-audits/topology.md` |
| `/scoutflo:map-repos` | harness | Service→GitHub repo map into `./scoutflo-audits/repo-map.md`; every match is user-confirmed, never auto-picked |
| `/scoutflo:business-context` | harness | Capture SLAs, critical services, per-environment rules, and exclusions into `business_context.md`; every audit reads it to tune severity and scope |
| `/scoutflo:audit-all` | harness | Run every configured audit, then correlate across them, into one combined report and brief |
| `/scoutflo:correlation-engine` | harness | Cross-audit correlation: redundant monitoring, cascade risks, business-context filtering (also run automatically by `audit-all`) |
| `/scoutflo:rca` | harness | Ask "why is X failing — give me the RCA": uses reports as reference and topology as the blast-radius map, then makes read-only live checks to name an evidence-cited root cause with confidence and honest gaps; degrades to report-only without cluster access |
| `/scoutflo:schedule-audits` | harness | Recurring audits via GitHub Actions, cron, or a Claude cloud schedule |
| `/scoutflo:audit-lgtm` | audit | Scored audit of Prometheus, LGTM, and VictoriaMetrics stacks (this is your **Prometheus** audit; pair with `audit-alert-routing` for the Prometheus→Alertmanager paging path) |
| `/scoutflo:setup-lgtm` | setup | Guided hardening for findings from `audit-lgtm` |
| `/scoutflo:audit-clickstack` | audit | Scored audit of a ClickStack deployment (ClickHouse + HyperDX + OpenTelemetry): telemetry coverage, ingestion freshness, retention TTL, ClickHouse health, HyperDX alerting/dashboards, security posture |
| `/scoutflo:setup-clickstack` | setup | Guided hardening for findings from `audit-clickstack` (retention TTL, read-only user, HyperDX alerts, auth) |
| `/scoutflo:audit-signoz` | audit | Scored audit of a SigNoz deployment (ClickHouse-backed, OpenTelemetry-native): query-API health, telemetry coverage, ingestion freshness, retention TTL, ClickHouse health/capacity, alert-rule→channel delivery, dashboards, security posture |
| `/scoutflo:audit-grafana` | audit | Dashboard truthfulness, alert semantics, query hygiene |
| `/scoutflo:setup-grafana` | setup | Datasources, dashboards, and alerting to production grade |
| `/scoutflo:audit-sentry` | audit | Org/project config, privacy scrubbing (PII), alert-rule tiers and receiver liveness, releases and source maps, cron/uptime monitors |
| `/scoutflo:audit-pagerduty` | audit | Paging health: escalation, on-call, grouping, incident aging, actionability |
| `/scoutflo:audit-datadog` | audit | Monitor health: delivery, noise controls, muting/downtimes, SLO coverage, plus non-scored cost |
| `/scoutflo:audit-elk` | audit | Kibana Alerting: rule delivery, execution health, noise controls, coverage per space |
| `/scoutflo:audit-jsm` | audit | JSM Operations paging: escalation and routing, on-call schedules, notification-policy noise, heartbeats, unacked aging |
| `/scoutflo:audit-zenduty` | audit | Zenduty (Xurrent IMR) paging: escalation and on-call, collation dedup and alert-rule noise, routing, and analytics-backed MTTA/MTTR |
| `/scoutflo:audit-groundcover` | audit | groundcover monitors: per-monitor firing hygiene (pendingFor, hysteresis, no-data/error state), notification noise, silence hygiene, and destination liveness |
| `/scoutflo:audit-kubernetes` | audit | Kubernetes security and reliability: Pod Security Admission, RBAC over-permissioning, network policies, resource limits, disruption budgets |
| `/scoutflo:setup-kubernetes` | setup | Guided hardening for `audit-kubernetes` findings: PSA labels, RBAC tightening, network policies, resource limits, PDBs |
| `/scoutflo:setup-sentry` | setup | Projects, environments, alert taxonomy, integrations |
| `/scoutflo:audit-alert-routing` | audit | Proves your paging path is live, rule to receiver (the Prometheus→Alertmanager→receiver walk) |
| `/scoutflo:audit-digitalocean` | audit | App Platform, managed databases, uptime, alert routing |
| `/scoutflo:setup-digitalocean` | setup | Alert policies, uptime checks, database and app hardening |
| `/scoutflo:audit-gcp` | audit | Cloud Monitoring, uptime checks, GKE telemetry, logging |
| `/scoutflo:setup-gcp` | setup | Notification channels, uptime checks, alerting policies |
| `/scoutflo:audit-azure` | audit | Azure Monitor alerts/action groups, AKS (Container Insights, managed Prometheus), Log Analytics, VM/VMSS, App Gateway/LB |
| `/scoutflo:setup-azure` | setup | Action groups, metric/log/activity alerts, AKS monitoring, diagnostic settings |
| `/scoutflo:audit-aws` | audit | CloudWatch alarms, SNS routing, compute/DB/uptime health, plus a separate Cost & Resource Optimization report |
| `/scoutflo:setup-aws` | setup | CloudWatch alarms, SNS routing, log forwarding, account observability |
| `/scoutflo:audit-cost` | audit | Deep cross-provider cost: rightsizing, idle/unattached, commitment coverage, over-provisioned K8s requests — ranked by provider-native $ savings (never invented) |

More audits are planned. This table lists the commands you invoke directly. A few helpers run **behind the scenes** and are not listed as rows: `business-context-resolver` (auto-discovers metadata for the audits), `cost-analysis` (the cost roll-up inside `audit-all`), and `topology-guided-setup` (a library the setup skills can source). Note `/scoutflo:checkpoint` and `/scoutflo:correlation-engine` are both — the audits invoke them for you, and you can also run them directly (`/scoutflo:checkpoint --reset-scope`, or `/scoutflo:correlation-engine` after a few audits).

## Where reports land

Every audit run writes its reports and runtime data under one reports directory:

```
<reports-dir>/
  <target>/                # lgtm, grafana, sentry, alert-routing, digitalocean, gcp, aws, ...
    history.jsonl          # one line per run; reports render the score trend from it
    <YYYY-MM-DD>/          # run date, UTC
      findings.json        # machine-readable: score, severities, evidence
      report.md            # human-readable: at-a-glance dashboard, scorecard, findings, actions
      report.html          # standalone visual dashboard (score donut, bars) — open in a browser
  all/                     # combined summaries from /scoutflo:audit-all
  topology.md              # your service map, written by /scoutflo:map-topology
  topology-export.json     # machine-readable topology (the blast-radius graph source)
  exemptions.yaml          # your accepted-risk suppressions (optional, you own it)
```

**You don't have to choose a location.** By default `<reports-dir>` is `./scoutflo-audits/` next to where you run — zero setup, and `/scoutflo:doctor` prints the exact absolute path so you always know where to look. Nothing asks you to pick a directory before you start.

**Optional — pin it so it follows you across folders.** The default is folder-relative, so if you launch Claude from a *different* folder later, that run writes to a *different, empty* `scoutflo-audits/` (it reports "first run", and your `topology.md`/`exemptions.yaml` from the other folder aren't found). Your credentials are unaffected — they always live globally in `~/.scoutflo/`; only this reports/history layer is folder-relative. If you'd rather have one durable history regardless of where you launch, export `SCOUTFLO_AUDIT_DIR` to a fixed absolute path once — add it to your shell profile (`~/.zshrc`/`~/.bashrc`), and to `~/.scoutflo/env` too if you use scheduled runs; then every session, terminal, and scheduled run share it. `reports_dir` in `~/.scoutflo/toolkit.yaml` is just a reminder helper — doctor reads it to print that `export` line. Skip all of this for a first run.

- Re-runs on later dates compute a delta automatically: what got fixed, what is new, how the score moved. Each run also appends one line to its target's `history.jsonl`, and reports render the last-five-run score trend from it.
- Scores run 0 to 100 per target. The end-to-end label needs 85 or better plus full coverage of every critical service; below that the honest phrasing is "good base coverage".
- Keep the reports directory out of public version control. Reports contain infrastructure detail about your environment.

## Two credential tiers

Audits need read-only credentials; setup skills need an elevated tier and say so in their prerequisites. `/scoutflo:connect` walks you through both and labels each token as you create it. Start with read-only only; add the elevated tier when you are ready to fix findings.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Running an audit before credentials exist | Follow the numbered first steps; the doctor gate stops the audit and names the exact missing piece |
| `./scoutflo-audits/` committed to a public repo | Add it to `.gitignore` before your first audit run |
| Expecting an audit to change anything | Audits are read-only by design; fixes live in the matching `setup-*` skill |
| Findings talk about generic services nobody recognizes | Run `/scoutflo:map-topology` once so findings use your real service names |
