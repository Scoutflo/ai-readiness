# Scoutflo AI Readiness

Audit, harden, and monitor your infrastructure and observability stacks from inside Claude Code — scored reports, guided fixes, Slack briefs, scheduled runs. Built from Scoutflo's own SRE consulting practice, packaged so you can run the same checks yourself, on your own systems, with your own credentials.

**The two guarantees this whole plugin is built around:**

1. **Everything runs on your side.** Every API call originates from your machine or your CI. Nothing is sent to Scoutflo — no telemetry, no report upload, no callbacks. The AI driving these skills never sees a secret value: it shows you the exact command to create and export a credential, and you run it yourself, in your own terminal. Reports stay on your filesystem.
2. **Nothing changes without your explicit yes.** Audit skills are strictly read-only — they list, get, and query, never create or modify anything. Setup skills (the ones that fix what an audit found) always show you the exact change first and wait for you to confirm before touching anything live.

---

## Install

Installing is a **one-time terminal step**. Using the plugin afterward is **not** — once installed, it works directly inside Claude.app's chat via `/scoutflo:...` commands, no terminal needed for day-to-day use.

**Step 1 — one time, in a real terminal window** (Terminal.app, iTerm, etc. — not the Claude.app chat box). If you don't have the `claude` command yet:

```bash
npm install -g @anthropic-ai/claude-code
```

Then, still in that terminal:

```bash
claude plugin marketplace add Scoutflo/ai-readiness
claude plugin install scoutflo@scoutflo
```

`/plugin marketplace add` and `/plugin install` only work as commands inside the standalone `claude` terminal CLI. They are **not** available as slash commands inside Claude.app's chat window — typing `/plugin ...` there will fail with "isn't available in this environment," which just means you're in the wrong surface for this one step, not that anything is broken.

**Step 2 — restart Claude Code / Claude.app** (fully quit and reopen, not just a new chat tab) so it picks up the plugin from the shared config the terminal command just wrote.

**Step 3 — everyday use, back inside Claude.app (or any Claude Code surface), no terminal needed:**

```
/scoutflo:start
```

That orients you — what's installed, what to do first, where reports land. Every skill after this (`/scoutflo:connect`, `/scoutflo:audit-lgtm`, etc.) is a normal slash command you type directly in the chat.

For team-wide or org-wide rollout instead of one person at a time, see [docs/install.md](docs/install.md).

## Your first 15 minutes

1. **`/scoutflo:connect`** — tell it which integrations you use (Grafana, Sentry, PagerDuty, Prometheus, DigitalOcean, GCP, AWS, whatever applies). For each one it shows you the exact click-path to create a minimal-scope, read-only credential in that provider's own UI, and the exact command to export it in your own shell. It never asks you to paste a token into the chat, and never runs that command for you.
2. **`/scoutflo:doctor`** — validates every credential you just set up with one cheap, read-only call per integration. Tells you exactly what's broken and how to fix it if anything is.
3. **`/scoutflo:map-topology`** (recommended, one time) — builds a real map of your services from Kubernetes/Istio. Once this exists, every audit report uses your actual service names instead of generic ones.
4. **Run your first audit** — pick whichever matches what you connected: `/scoutflo:audit-lgtm`, `/scoutflo:audit-grafana`, `/scoutflo:audit-sentry`, `/scoutflo:audit-pagerduty`, `/scoutflo:audit-alert-routing`, `/scoutflo:audit-digitalocean`, `/scoutflo:audit-gcp`, or `/scoutflo:audit-aws`. Or run everything you've configured at once with `/scoutflo:audit-all`.
5. **Read the report** in `./scoutflo-audits/<target>/<date>/report.md` — a scored, evidence-backed breakdown of what's healthy and what isn't, with a direct pointer to the fix for each finding.

That's it — nothing else is required to get real value out of this.

## How credentials work

Every integration that supports scoped tokens gets one of two tiers:

| Tier | Used by | Can do |
| --- | --- | --- |
| **Read-only** | every `audit-*` skill, `doctor`, `map-topology` | List, get, query. Cannot create, modify, or delete anything. |
| **Elevated** | every `setup-*` skill | Read-only, plus the specific write scopes that setup skill needs. |

Start with read-only only. Add an elevated credential later, as a separate token, only when you're ready to actually fix something with a `setup-*` skill. `/scoutflo:connect` walks you through creating both, correctly scoped and named, per integration.

Secrets live only in environment variables you export yourself. `~/.scoutflo/toolkit.yaml` (the one config file every skill reads) holds only hosts, org names, and the *names* of the environment variables — never a value.

## What's in the box

**Harness** — the skills that wire everything together:

| Skill | What it does |
| --- | --- |
| `/scoutflo:start` | Orientation: what's installed, what to do first, where reports land |
| `/scoutflo:connect` | Guided credential setup per integration, two token tiers |
| `/scoutflo:doctor` | Preflight: config parses, env vars are set, one live check per integration |
| `/scoutflo:map-topology` | Builds your real service map from Kubernetes/Istio |
| `/scoutflo:audit-all` | Runs every audit you've configured, one combined report and Slack brief |
| `/scoutflo:schedule-audits` | Sets up recurring audits via GitHub Actions, cron, or a Claude cloud schedule |

**Audits** — read-only, scored 0–100, evidence-backed, change nothing. Beyond coverage, every audit also scores **alert hygiene** — flapping alerts, permanently-firing "wallpaper" rules, missing debounce, and noisy routing — so a healthy score means signal, not noise:

| Skill | What it covers |
| --- | --- |
| `/scoutflo:audit-lgtm` | Loki, Tempo, Mimir, VictoriaMetrics, and Alertmanager stack health |
| `/scoutflo:audit-grafana` | Dashboard truthfulness, alert-rule wiring, query hygiene, datasource health |
| `/scoutflo:audit-sentry` | Org and project config, privacy scrubbing, alert-rule tiers, releases, monitors |
| `/scoutflo:audit-pagerduty` | Paging health: services, escalation policies, on-call coverage, alert grouping and noise, incident aging — plus a vendor-analytics-backed **actionability** section (auto-resolved share, MTTA, sleep-hour interruptions) when your plan and key allow |
| `/scoutflo:audit-alert-routing` | Proves an alert actually reaches a human — rule → Alertmanager → receiver, live — and scores **alert noise / alert fatigue**: flapping, permanently-firing rules, missing `for` debounce, missing grouping or inhibition, duplicate delivery, resolve noise |
| `/scoutflo:audit-digitalocean` | App Platform, managed databases, uptime checks, alert routing |
| `/scoutflo:audit-gcp` | Cloud Monitoring, uptime checks, GKE telemetry, logging, load-balancer health |
| `/scoutflo:audit-aws` | CloudWatch alarms, SNS routing, EC2/ECS/EKS/Lambda/RDS health, uptime, log forwarding — plus a separate, non-scored **Cost & Resource Optimization** report sourced from AWS's own Compute Optimizer / Cost Explorer / Trusted Advisor |

**Setups** — fix what an audit found. Always: announce the exact change → wait for your yes → apply it → re-read the object to prove it landed:

| Skill | What it fixes |
| --- | --- |
| `/scoutflo:setup-lgtm` | Alert receivers/routing, retention, HA, exposure, service-label alignment |
| `/scoutflo:setup-grafana` | Datasources, dashboards, contact points, notification policies, alert rules |
| `/scoutflo:setup-sentry` | Projects, environments, privacy scrubbing, alert routing, monitors |
| `/scoutflo:setup-digitalocean` | Alert destinations, uptime checks, App Platform and database alerting |
| `/scoutflo:setup-gcp` | Notification channels, uptime checks, alert policies, dashboards |
| `/scoutflo:setup-aws` | CloudWatch alarms, SNS routing, log forwarding, account-level observability. Never automates a cost-driven change (resize/delete) — Cost & Resource Optimization findings are always plan-only, a decision for you to make deliberately |

(No `setup-alert-routing` yet — that's coming; today alert-routing findings point at `setup-lgtm` or `setup-grafana`.)

## Reading a report

Every audit run writes two files:

```
./scoutflo-audits/
  <target>/
    history.jsonl              # one line per run — reports render the score trend from it
    <YYYY-MM-DD>/
      findings.json            # machine-readable: score, severities, evidence
      report.md                # human-readable: summary, scorecard, findings, next actions
```

`report.md` opens with an executive summary and a score out of 100, then a weighted scorecard by category, a findings table (every finding has a severity, real evidence, and a direct pointer to the setup skill that fixes it), and a "next safe actions" list ordered so you can start at row 1 with nothing to prepare first. Re-run the same audit later and it shows you the delta — what got fixed, what's new, how the score moved.

A score of 85+ with full coverage of every critical service earns the "end-to-end" label; below that, the honest phrasing is "good base coverage" — this toolkit never inflates a partial setup into a false "you're covered."

Every `report.md` is validated against a fixed output-conformance standard before it is written, so the structure — summary, scorecard, findings table, next safe actions, evidence — is the same run to run and across every stack.

**Keep `./scoutflo-audits/` out of version control** — reports describe your real infrastructure. Add it to `.gitignore` before your first run (see [docs/install.md](docs/install.md) for the exact snippet).

## Requirements

- The `claude` terminal CLI (`npm install -g @anthropic-ai/claude-code`) — needed once, for the install step in a terminal. Claude.app alone (without ever having run the CLI) can't install a plugin.
- Claude Code (latest), with an active subscription
- `bash`, `curl`, `jq` on your `PATH`
- The CLI for whatever you're auditing (`kubectl`/`istioctl` for Kubernetes, `doctl` for DigitalOcean, `gcloud` for GCP, `aws` for AWS) — `/scoutflo:doctor` tells you if anything's missing
- Admin access to each integration you connect, just long enough to create a scoped credential

## Troubleshooting

- **`/plugin isn't available in this environment.`** You typed a `/plugin ...` command inside Claude.app's chat window. `/plugin marketplace add` and `/plugin install` only run in the standalone `claude` terminal CLI — open a real terminal, run `claude`, and run the commands there (see Install above). Once installed, you go back to using Claude.app normally — only this one setup step needs a terminal.
- **`/plugin marketplace add` fails or hangs (in the terminal).** Check your network and that your GitHub credentials are set up (an SSH key, or `gh auth login`) — the marketplace uses your existing GitHub credentials to fetch the repo. Then try again.
- **After installing, the `/scoutflo:*` commands don't show up.** New plugin installs need a full restart to load — fully quit Claude Code / Claude.app and reopen it, not just a new chat/tab. An in-progress conversation, or even a new tab in an already-running app, won't pick up a plugin installed partway through the session.
- **A command says "not recognized here" but then answers anyway.** Some Claude Code clients have their own fixed list of built-in slash commands separate from installed-plugin commands; this message just means the client's own list doesn't include it, not that the skill failed. If it responds with real content right after, it worked.

## Feedback and issues

Found a bug, or something confusing? Open an issue at [Scoutflo/ai-readiness](https://github.com/Scoutflo/ai-readiness/issues) with:

- which skill you ran and what you typed
- what you expected vs. what actually happened
- anything from `./scoutflo-audits/` that looks wrong (redact real hostnames/org names if you'd rather not share them)

Small friction is worth reporting too, not just crashes — confusing wording, a step that took longer than it should have, a question that was unclear.

## More

- Full install options — individual, team, enterprise-managed rollout: [docs/install.md](docs/install.md)
- Common questions: [docs/faq.md](docs/faq.md)
- Contributing and release rules: [CONTRIBUTING.md](CONTRIBUTING.md)
- Skill-authoring conventions (for anyone extending this): [docs/skill-authoring-conventions.md](docs/skill-authoring-conventions.md)
- Full changelog: [CHANGELOG.md](CHANGELOG.md)

## License

Licensed under **Apache-2.0** — see the [LICENSE](LICENSE) file. Install uses your existing GitHub credentials (an SSH key, or `gh auth login`) to fetch the plugin from `Scoutflo/ai-readiness`, the same way `git` clones any repo.
