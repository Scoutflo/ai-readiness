---
name: start
description: 'Orientation for the Scoutflo AI Readiness: the local-only guarantee, first steps, the full skill catalog, credential tiers, and where audit reports land. Use when the user asks where to start, what the toolkit can do, which skills exist, how reports and scoring work, or whether any data leaves their machine. Do not use to create credentials (use connect), to check config health (use doctor), or to run an audit (use audit-all or a specific audit skill).'
---

# Scoutflo AI Readiness: Start Here

This toolkit audits, hardens, and monitors your infrastructure and observability stacks from Claude Code. Audit skills produce a scored report with command-level evidence. Setup skills fix what an audit found, one confirmed change at a time. Harness skills, this one included, wire everything together.

## Everything runs on your side

- Every API call originates from your machine or your CI. Nothing is sent to Scoutflo: no telemetry, no report upload, no callbacks.
- Configuration lives in `~/.scoutflo/toolkit.yaml`: hosts, orgs, and names in plain text. Secrets never go in that file; every `*_env` key names an environment variable that holds the secret, and skills check presence only, never the value.
- Audit skills are strictly read-only: GET, list, describe, query. No test notifications, no silences, no state creation of any kind.
- Setup skills show you the exact change, wait for your explicit confirmation, apply it, then re-read the object to prove the change landed.

## First steps

1. `/scoutflo:connect` sets up `~/.scoutflo/toolkit.yaml` and walks you through creating credentials per integration: exact scopes, where to click, read-only tokens for audits.
2. `/scoutflo:doctor` validates everything live: config parses, env vars are set, binaries exist, one cheap call per integration succeeds. Run it whenever something feels off.
3. `/scoutflo:map-topology` (recommended) writes `./scoutflo-audits/topology.md`, your service map. With it, findings name your actual services instead of generic ones. On large clusters it works in namespace batches and resumes if interrupted.
4. Run your first audit: `/scoutflo:audit-lgtm`, `/scoutflo:audit-grafana`, `/scoutflo:audit-sentry`, `/scoutflo:audit-pagerduty`, `/scoutflo:audit-datadog`, `/scoutflo:audit-elk`, `/scoutflo:audit-jsm`, `/scoutflo:audit-zenduty`, `/scoutflo:audit-groundcover`, `/scoutflo:audit-alert-routing`, `/scoutflo:audit-digitalocean`, `/scoutflo:audit-gcp`, or `/scoutflo:audit-aws`. Or run everything configured at once with `/scoutflo:audit-all`. Every audit sizes your estate first with cheap list calls and says which path it picked: small estates get a single pass, large ones run in bounded, resumable batches.
5. Optional: `/scoutflo:schedule-audits` makes the audits recurring, with a Slack brief per run.

## The skills

| Skill | Lane | What it does |
| --- | --- | --- |
| `/scoutflo:start` | harness | This orientation |
| `/scoutflo:connect` | harness | Guided credential setup per integration, two token tiers |
| `/scoutflo:doctor` | harness | Preflight: config, env vars, one live check per integration |
| `/scoutflo:map-topology` | harness | Service map into `./scoutflo-audits/topology.md` |
| `/scoutflo:audit-all` | harness | Run every configured audit, one combined report and brief |
| `/scoutflo:schedule-audits` | harness | Recurring audits via GitHub Actions or cron |
| `/scoutflo:audit-lgtm` | audit | Scored audit of LGTM and VictoriaMetrics observability stacks |
| `/scoutflo:setup-lgtm` | setup | Guided hardening for findings from `audit-lgtm` |
| `/scoutflo:audit-grafana` | audit | Dashboard truthfulness, alert semantics, query hygiene |
| `/scoutflo:setup-grafana` | setup | Datasources, dashboards, and alerting to production grade |
| `/scoutflo:audit-sentry` | audit | Org, project, and alert-rule assessment |
| `/scoutflo:audit-pagerduty` | audit | Paging health: escalation, on-call, grouping, incident aging, actionability |
| `/scoutflo:audit-datadog` | audit | Monitor health: delivery, noise controls, muting/downtimes, SLO coverage, plus non-scored cost |
| `/scoutflo:audit-elk` | audit | Kibana Alerting: rule delivery, execution health, noise controls, coverage per space |
| `/scoutflo:audit-jsm` | audit | JSM Operations paging: escalation and routing, on-call schedules, notification-policy noise, heartbeats, unacked aging |
| `/scoutflo:audit-zenduty` | audit | Zenduty (Xurrent IMR) paging: escalation and on-call, collation dedup and alert-rule noise, routing, and analytics-backed MTTA/MTTR |
| `/scoutflo:audit-groundcover` | audit | groundcover monitors: per-monitor firing hygiene (pendingFor, hysteresis, no-data/error state), notification noise, silence hygiene, and destination liveness |
| `/scoutflo:setup-sentry` | setup | Projects, environments, alert taxonomy, integrations |
| `/scoutflo:audit-alert-routing` | audit | Proves your paging path is live, rule to receiver |
| `/scoutflo:audit-digitalocean` | audit | App Platform, managed databases, uptime, alert routing |
| `/scoutflo:setup-digitalocean` | setup | Alert policies, uptime checks, database and app hardening |
| `/scoutflo:audit-gcp` | audit | Cloud Monitoring, uptime checks, GKE telemetry, logging |
| `/scoutflo:setup-gcp` | setup | Notification channels, uptime checks, alerting policies |
| `/scoutflo:audit-aws` | audit | CloudWatch alarms, SNS routing, compute/DB/uptime health, plus a separate Cost & Resource Optimization report |
| `/scoutflo:setup-aws` | setup | CloudWatch alarms, SNS routing, log forwarding, account observability |

More audits are planned, including a dedicated Datadog audit. Installed skills always appear in this table.

## Where reports land

Every audit run writes two files under the project directory you ran it from:

```
./scoutflo-audits/
  <target>/                # lgtm, grafana, sentry, alert-routing, digitalocean, gcp, aws
    history.jsonl          # one line per run; reports render the score trend from it
    <YYYY-MM-DD>/          # run date, UTC
      findings.json        # machine-readable: score, severities, evidence
      report.md            # human-readable: summary, scorecard, findings, actions
  all/                     # combined summaries from /scoutflo:audit-all
  topology.md              # your service map, written by /scoutflo:map-topology
```

- Re-runs on later dates compute a delta automatically: what got fixed, what is new, how the score moved. Each run also appends one line to its target's `history.jsonl`, and reports render the last-five-run score trend from it.
- Scores run 0 to 100 per target. The end-to-end label needs 85 or better plus full coverage of every critical service; below that the honest phrasing is "good base coverage".
- Keep `./scoutflo-audits/` out of public version control. Reports contain infrastructure detail about your environment.

## Two credential tiers

Audits need read-only credentials; setup skills need an elevated tier and say so in their prerequisites. `/scoutflo:connect` walks you through both and labels each token as you create it. Start with read-only only; add the elevated tier when you are ready to fix findings.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Running an audit before credentials exist | Follow the numbered first steps; the doctor gate stops the audit and names the exact missing piece |
| `./scoutflo-audits/` committed to a public repo | Add it to `.gitignore` before your first audit run |
| Expecting an audit to change anything | Audits are read-only by design; fixes live in the matching `setup-*` skill |
| Findings talk about generic services nobody recognizes | Run `/scoutflo:map-topology` once so findings use your real service names |
