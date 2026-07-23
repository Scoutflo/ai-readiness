# FAQ

**Does any of my data go to Scoutflo?**
No. The toolkit runs inside your Claude Code. Your credentials stay in your environment, every API call originates from your machine or CI, and there is no telemetry, no report upload, and no callback. The only outbound calls go to your own integrations and, if you configure it, your own Slack webhook.

**What credentials do I need?**
`/scoutflo:connect` walks you through it per integration, with exact minimal scopes. Audits use read-only tokens. Setup skills need a second, higher-permission token that you create only if you use them.

**Can an audit change anything in my systems?**
No. Audit skills are read-only by design and doctor-gated; the only writes are local report files. Setup skills are separate, state every change up front, and do nothing until you explicitly confirm.

**What does the 0–100 score mean?**
It measures your setup against a stated best-practice target for that audit's domain, weighted by category (the scorecard shows each category's weight and its passed/total checks). 85 is the end-to-end gate: at or above it — with every critical service covered and no category excluded — the report may claim end-to-end coverage. Below it, the executive summary states your gap in points and the two or three findings that recover the most. Scoring is conservative: a check only earns full credit when it was verified live this run, so a low first score usually means "unproven", not "broken". Full mechanics are in `report-standard/severity-and-scoring.md`.

**Does it help with alert noise or alert fatigue?**
Yes. Every audit scores alert hygiene alongside coverage: it flags rules that flap (fire and resolve in a loop), rules that have fired so long they've become wallpaper, alerts with no debounce that trip on a single blip, missing grouping or inhibition, duplicate delivery, and resolve-noise. Each noisy rule is named with the exact setting to fix it. It reports the structural signs of noise directly; it does not invent an "X% of your alerts are actionable" figure — a true alert-to-incident rate needs a feed from your paging tool.

**Which platforms and stacks does it cover?**
LGTM and the VictoriaMetrics family (Loki, Tempo, Mimir, VictoriaMetrics/Logs/Traces, Alertmanager, vmalert), Grafana, Sentry, Prometheus/Alertmanager alert routing, DigitalOcean, Google Cloud, and AWS. Connect only the ones you use; `/scoutflo:start` lists the full catalog.

**Where do reports go?**
`./scoutflo-audits/` in your working directory. Keep that folder out of public version control; reports name your namespaces, hosts, and routes. The Slack brief carries finding titles and counts only, never evidence values.

**What does running this cost?**
The toolkit is free. Runs consume your own Claude subscription or API usage like any other Claude Code session; scheduled runs consume it on each execution.

**We are in the EU. Does Sentry / our region work?**
Yes. Hosts and regions come from your `~/.scoutflo/toolkit.yaml`; nothing assumes a US region. `/scoutflo:connect` covers region selection per provider.

**Can I silence a finding we have accepted?**
Yes: add it to `./scoutflo-audits/exemptions.yaml` with a reason and an expiry date. It moves to the report's Suppressed appendix instead of vanishing, and returns automatically when the exemption expires.

**What is the "Scoutflo Topology Readiness" section?**
An optional parallel verdict: whether each critical service's topology data is complete enough for Scoutflo's platform to sync and correlate it. Useful if you plan to adopt the Scoutflo platform; ignorable if you do not. It never affects your audit score.

**Why is schedule-audits marked experimental?**
The crontab path has been validated end to end against a real scheduled run; the GitHub Actions and Claude cloud schedule paths have not yet. Whichever runner you pick, always validate your first scheduled run manually before trusting the cadence — the skill itself walks you through that proof step.

**Something is broken. Where do I report it?**
GitHub issues on this repository. Include the skill name and the terminal output around the failure; never paste credentials or full reports.
