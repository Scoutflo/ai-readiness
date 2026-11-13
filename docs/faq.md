# FAQ

**Which Claude surface does this run in? Why did `/scoutflo:connect` fail when `/scoutflo:start` worked?**
Every skill executes real shell commands and reads/writes files on **your** machine — it creates `~/.scoutflo/toolkit.yaml`, runs `curl`/`kubectl`/`aws`, and writes reports to your disk. So it needs a **Local** Claude surface:

- ✅ Works: the `claude` **terminal CLI**; the Claude **desktop app's Code tab with the "Local" environment selected**; the VS Code / JetBrains Claude Code extensions.
- ❌ Does not work: the desktop app's **Chat tab**, or **claude.ai in a browser** — these run in Anthropic-managed cloud VMs with no access to your machine, so `/scoutflo:connect` fails with a "can't create the toolkit file locally" error.

That's why `/scoutflo:start` can succeed in a cloud surface while `/scoutflo:connect` fails: `start` is pure text (touches nothing local), so it renders anywhere; `connect` writes files, so it needs a Local session. The error is expected — switch to a Local session and re-run.

Separately, the one-time **install** commands (`/plugin marketplace add`, `/plugin install`) only run in the standalone `claude` terminal CLI (or the Team/Enterprise `settings.json` path); typing `/plugin ...` in the Chat tab fails with "isn't available in this environment." See [docs/install.md](install.md) for the exact commands.

**Can I install without a terminal at all?**
Yes, two ways. For a team, add the marketplace and enable the plugin through a `.claude/settings.json` file (the Team/Enterprise path in [docs/install.md](install.md)) — no `/plugin` command anywhere. And the Claude desktop app has a built-in plugin browser (the **+** next to the prompt → **Plugins**) that installs from a marketplace once it's been added. The one thing the desktop app can't do by itself is add a brand-new marketplace — that first step needs the terminal command or the settings file. Also note the plugin's minimum is Claude Code v2.1.140; run `claude --version` if the commands seem missing.

**The plugin shows installed but I don't see any `/scoutflo:` skills.**
The plugin files are present but Claude Code hasn't loaded its skills. Most often a fresh install just needs `/reload-plugins` (then fully restart Claude Code), or you're on a Claude Code older than the minimum, Claude Code v2.1.140 (`claude --version`, then update). If you're on a **Teams/Enterprise** plan, this is usually an org-vs-personal settings issue: managed settings override your personal ones, so an org `strictKnownMarketplaces` allowlist or an `enabledPlugins` policy can leave the plugin "installed" from your config while its skills never load — an Owner adds the `scoutflo` marketplace to the allowlist. Full step-by-step in [docs/install.md](install.md#troubleshooting-plugin-shows-installed-but-no-scoutflo-skills-appear).

**Does this work on Windows?**
Yes, with Git Bash. Every skill runs POSIX shell, and Claude Code on Windows runs shell through Git Bash when present, falling back to PowerShell (which can't run these commands) when it isn't. Install [Git for Windows](https://git-scm.com/downloads/win) with "Add to PATH", plus `jq` and your provider CLIs, and everything behaves exactly as on macOS/Linux. If skill commands fail with PowerShell parse errors, Git Bash is missing — see [docs/install.md](install.md#windows). macOS and Linux need no extra shell setup.

**Do I need a GitHub account or token to install?**
No. This repository is public, so the marketplace fetches it anonymously over HTTPS exactly like a public `git clone` — no login, token, or SSH key required. If `/plugin marketplace add` hangs on a corporate network, the cause is usually a firewall/proxy blocking `github.com` or `git` not being installed, not credentials; test with `git clone https://github.com/Scoutflo/ai-readiness.git /tmp/air-test`.

**Does any of my data go to Scoutflo?**
The shipped plugin has no automatic Scoutflo telemetry, report-upload service or callback. It runs through your Claude Code session, configured integrations and selected model provider. Optional Slack delivery and scheduled CI caches/artifacts can transfer report content to those services. Local execution does not mean offline model processing. See [data handling](data-handling.md) for the destinations, local credential store and retention choices, and [license and use](license-and-use.md) for software and service terms.

**Can it migrate me from Datadog to SigNoz?**
It plans the migration; it does not execute it. `/scoutflo:migration-plan` produces an evidence-cited inventory — migrate / fix-first (broken routing found by the audits) / drop-candidates (dead weight, with the audit's proof, pending your confirmation) / already-covered / no-native-equivalent (each with a real alternative) — plus the dual-write parallel-run and cutover playbook. It is read-only on both sides. Two honest limits it always states: historical telemetry never transfers between backends (continuity comes from the parallel run, and the source is sunset only after re-running both audits shows coverage parity), and anything that can't auto-translate is named `manual`, never silently converted. Executing the plan is your confirm-then-verify work (or a guided engagement), never this skill's.

**What credentials do I need?**
`/scoutflo:connect` walks you through it per integration, with exact minimal scopes. Audits use read-only tokens. Setup skills need a second, higher-permission token that you create only if you use them; for Sentry, keep that token's block in a separate config file (`/scoutflo:connect` shows how), because setup-sentry refuses the read-only one.

**I created the token in the provider — where does it go so the toolkit uses it?**
Not into `toolkit.yaml`. That file only records the *name* of the environment variable (for example `token_env: KIBANA_API_KEY`); the token **value** lives separately, in your environment, under that exact name. The simplest path is to let `/scoutflo:connect` store it for you — it writes the value into the home-anchored secret store correctly escaped (safe even if the token contains a `$`, a quote, or a backtick), replaces that variable's line instead of appending a duplicate on a re-run, and keeps the file `chmod 600`. To place it by hand instead, once:
```bash
mkdir -p ~/.scoutflo && touch ~/.scoutflo/env && chmod 600 ~/.scoutflo/env
grep -q 'scoutflo/env' ~/.zshrc 2>/dev/null || echo '[ -f ~/.scoutflo/env ] && . ~/.scoutflo/env' >> ~/.zshrc
echo 'export KIBANA_API_KEY="<paste-the-token-here>"' >> ~/.scoutflo/env
source ~/.scoutflo/env
```
Swap `KIBANA_API_KEY` for the provider's `*_env` name (`GRAFANA_TOKEN`, `DATADOG_API_KEY`, `PROM_TOKEN`, …; `/scoutflo:connect` and `references/providers.md` name it per provider). Then `/scoutflo:doctor` confirms it. The three moving parts: `toolkit.yaml` names the var → `~/.scoutflo/env` holds the value → each audit reads the value by that name. `doctor` **and** every audit source `~/.scoutflo/env` at the start of a run, so a token added there is picked up in the same session — no need to open a new terminal. (On Windows PowerShell, use `setx KIBANA_API_KEY "<paste>"` and reopen the terminal.) The value never goes into chat, into `toolkit.yaml`, or into any skill; a plain `export KIBANA_API_KEY="…"` also works but only for the current shell — the `~/.scoutflo/env` file is what makes it persist across sessions. The hand-typed `echo` above wraps the value in double quotes, which is fine for an ordinary token; for one that contains a `"`, `$`, or backtick, let `connect` write it so the value is stored literally, and if `/scoutflo:doctor` ever reports a token "set but not loading," it names the exact one-line fix.

**Our secrets live in Vault (or another fetcher), not as static values — can the toolkit pull them?**
Yes. `~/.scoutflo/env` is a shell file the plugin *sources*, so a line like `export GRAFANA_TOKEN="$(vault kv get -field=token secret/grafana)"` resolves **every time the store loads** — no static copy of the secret sits on disk. Write one with the command form of the shipped writer: `sh "${CLAUDE_PLUGIN_ROOT}/skills/connect/scripts/addsecret.sh" --command GRAFANA_TOKEN`, which prompts for the fetch command and stores exactly that line (it never records the resolved value). **Safety:** that command runs on every load (doctor and every audit source the store), so use it **only** with a trusted, side-effect-free secret fetch (e.g. `vault kv get`, a cloud secrets-manager read) — never an untrusted or state-changing command. If your fetcher needs a login first (e.g. `vault login`), do that in your shell before running the plugin; the toolkit does not manage Vault sessions.

**Can an audit change anything in my systems?**
No. Audit skills are read-only by design and doctor-gated; the only writes are local report files. Setup skills are separate, state every change up front, and do nothing until you explicitly confirm.

**If a setup skill changed something, can I undo it later?**
It depends on the effect and the evidence saved before the change. Each setup plan must state its restoration procedure or exact irreversible limit before you confirm. A supported restore checks the selected target, recorded preimage and current state, preserves unrelated settings, and requires confirmation; drift or an incomplete preimage stops it. Restoring a retention setting cannot recover deleted data or retract notifications, and an unknown old password cannot be restored from an auth-type snapshot. Retiring an owned object does not promise to recreate its identity. Keep the run's protected backup and receipts, and follow that effect's documented restore or recovery procedure.

**We use MCP servers for our integrations instead of CLIs — does this still work?**
Yes — the toolkit uses **both** and picks the best transport per operation, so you don't choose and don't configure anything. Most integrations (Grafana, Prometheus, Loki, Tempo, VictoriaMetrics/Logs, Sentry, Datadog, New Relic, PagerDuty, ELK, JSM, Zenduty, Splunk On-Call, Groundcover, SigNoz, ClickStack) are reached over HTTPS with a token, so many reads need `curl` + `jq` — no vendor CLI; the Datadog/HyperDX safe projection recipes also require Python 3; only Kubernetes and AWS/GCP/DigitalOcean use a CLI. Reads take the fast direct CLI/HTTP path; a connected MCP tool is used when it is the equivalent read route or the only reachable one, and for a write whose typed MCP tool is the safer path than a hand-built call. A stack with only CLIs, only MCP servers, or a mix all work. Configuration inspection can add local parsing dependencies: Alertmanager requires Python 3 with PyYAML and curl 8.4 or newer. Safety is unchanged: audits only ever call read-only tools (classified by effect, not name), never anything that mutates state.

**The report says a check is "not applicable" — is that the same as passing?**
No. The report distinguishes four things, and only one of them is "nothing to do": a check can be
**not applicable** because there is genuinely nothing to assess (your platform version removed the
feature, your managed engine has no such concept, the target was decommissioned, you declared the
resource intentional, or the capability is verified on another tool we checked), or it can be
**blocked**, which means we could not look and the result is unknown. Neither counts toward the
score, but they mean opposite things: blocked comes with the access to unlock so you can get a real
answer. If we are unsure which applies, we report blocked — "we could not see it" is always safe to
say, "there is nothing to do here" is not.

**Why did it stop flagging our standby cluster — and why did it flag it before?**
Because you told it. A warm standby, a DR replica or a backup target looks exactly like waste to
every signal an audit can read: low CPU, low traffic, large instance. Intent is a fact about your
plans that exists nowhere in your telemetry, so the audit does not guess it — if you declare the
resource in `/scoutflo:business-context` with a reason in your own words, cost findings keep showing
the resource and its utilisation but stop recommending you shrink it and stop counting it as a
saving. Declare nothing and it keeps reporting it, deliberately: wrongly flagging an intentional
standby costs you one correction, while wrongly staying silent about a forgotten cluster costs you
money every month and you would never see the finding that was not written.

**Our alert rules live in Git, applied to a Mimir/Prometheus ruler — will the Grafana audit say we have no alerts?**
No. Grafana has two rule planes: its own, and the datasource's ruler. The audit checks both. When it
can read a rule for a service on the datasource's ruler it reports that service as covered and names
the rule; when it can see a ruler exists but cannot read it (no permission, or the rules only exist
in Git), it says exactly that rather than reporting a gap. It only reports a real coverage gap when
there is no rule plane at all. The evidence always states which plane it read.

**What does the 0–100 score mean?**
Readiness measures the checks that were actually assessed, weighted by the audit's categories. Assessment coverage separately shows how much of the applicable check set was observed. Blocked checks are outside the readiness denominator, so a low score describes unhealthy or incomplete assessed results; missing evidence lowers coverage instead. For example, two passes and eight blocked checks can yield 100/100 over only 20% assessment coverage. A fully blocked run is **Unassessed**, with no numeric score. End-to-end readiness requires a score of at least 85, verified coverage of every critical service, no excluded category and 100% assessment coverage. See [scoring and coverage](../report-standard/severity-and-scoring.md) for the full mechanics and historical schema limits.

**Does it help with alert noise or alert fatigue?**
Yes. Audits score applicable alert hygiene and give the specific setting to review: missing debounce, grouping or inhibition, chronic alerts and unsafe routing. `/scoutflo:audit-all` then combines current configuration findings and any measured fire history. Shared findings are potential overlap, not proof of duplicate pages. Native On-Call history adds a separate view of incident recurrence, response samples and workload assignments with its exact window and completeness. Incidents, source fires, notification attempts and human receipts are different units. A missing or partial read stays visible; it cannot become zero noise or an all-clear. A source marked `spec-only` has not had its fields confirmed live. Actionability needs reviewed outcome labels, response means need verified transitions and denominators, and a source-to-incident ratio needs comparable populations; merely connecting a paging tool supplies none of those guarantees.

**Can I get a fast pass instead of a full audit?**
Yes — triage mode. Set `SCOUTFLO_TRIAGE=1` (or ask for a "fast/triage pass") and each provider runs a curated, high-signal subset (smallest scope, no per-resource sweeps), rendering an executive one-pager in a few minutes. It's fast because it reads *less*, not because of a speed trick — and a triage report is stamped as a subset, so a quiet result is never mistaken for a full all-clear. Run the full audit when you want complete coverage.

**What's the executive one-pager?**
The top section of every `audit-all` report: a posture grade, the top few worst findings as *what · where · $ · the fix*, the alerting-reachability headline, and the single top real cost lever. It's ranked severity-first — a big dollar figure never promotes a low-severity finding above a critical one, and there's no blended "risk score."

**Which platforms and stacks does it cover?**
Prometheus, LGTM and the VictoriaMetrics family (Loki, Tempo, Mimir, VictoriaMetrics/Logs/Traces, Alertmanager, vmalert), Grafana, Sentry, PagerDuty, Datadog, New Relic, ELK/Kibana, JSM Operations, Zenduty, Splunk On-Call (VictorOps), groundcover, ClickStack (ClickHouse + HyperDX), SigNoz, Prometheus/Alertmanager alert routing, Kubernetes (security + reliability config), DigitalOcean, Google Cloud, Azure, and AWS — plus a cross-provider **cost** audit (`/scoutflo:audit-cost`) and a root-cause skill (`/scoutflo:rca`) that reasons across all of the above. Splunk On-Call is the paging product formerly called VictorOps; its audit does not assess Splunk Enterprise, Cloud Platform or Observability Cloud. Connect only the ones you use; `/scoutflo:start` lists the full catalog.

**How does an Azure audit avoid a false all-clear?**
Each command resolves the selected subscription and report target again. Failed reads,
missing pages and unknown enabled states cannot stand in for an empty or healthy
inventory. Disabled alerts do not count as active coverage. Action groups are joined
by their full resource IDs, and several action groups on one rule are only a
candidate for duplicate paging until intent or notification evidence confirms it. Missing Azure destinations do not prove that other logging or paging systems are absent. Resource names do not establish business criticality; required-plane intent and observed impact govern coverage and severity.

**Which Slack channel receives a combined or Azure brief?**
The selected config's `slack.webhook_env` names the credential to use. These sends
reload that named value from the selected local secret store, or use its exported
value when the store does not supply it. They do not fall back to another default
webhook. Missing credentials or an empty brief skip delivery, and a failed request
is reported as failed. Saving the brief locally does not prove it was sent.

**Where do reports go?**
By default `./scoutflo-audits/` in the directory you launched Claude Code from. To point it anywhere, **export `SCOUTFLO_AUDIT_DIR`** to an absolute path — that env var is what actually moves the location (every command runs in a fresh shell, so an exported variable is what carries across them). `/scoutflo:doctor` prints the exact absolute path it resolved. You can also set `reports_dir` in `~/.scoutflo/toolkit.yaml`; that's a convenience — doctor reads it and prints the `export SCOUTFLO_AUDIT_DIR=...` line for you (and warns if it's set but not yet exported), but setting it alone doesn't move reports until the export is in your environment. **If you rely on the default and launch Claude from a different folder, that run writes to a different, empty `scoutflo-audits/`** — so it shows "first run" with no delta, and your `topology.md`/`exemptions.yaml` from the other folder aren't found (your credentials in `~/.scoutflo/` are unaffected). Auditing one estate over time? Export `SCOUTFLO_AUDIT_DIR` to a stable absolute path and every run — interactive or scheduled — shares one history. Keep the reports folder out of public version control; reports name your namespaces, hosts, and routes. The Slack brief carries finding titles and counts only, never evidence values.

**Can I keep everything in one dedicated project folder?**
Mostly yes — that's the default for everything except credentials. Reports, history, topology, and exemptions already land in the folder you run from (`./scoutflo-audits/`), so a dedicated "readiness" folder works with zero setup; export `SCOUTFLO_AUDIT_DIR` if you want that path pinned regardless of where you launch. Credentials (`~/.scoutflo/toolkit.yaml` + `~/.scoutflo/env`) default to your home directory **on purpose**: they're per-machine secrets-adjacent files that shouldn't live next to reports you might zip up or commit, and home-anchoring is what makes every new terminal, session, and folder pick them up without re-asking. If you have a real reason to relocate the config (e.g. two isolated estates on one machine), export `SCOUTFLO_CONFIG=/path/to/toolkit.yaml` — every skill honors it. Moving the *reports* folder never requires moving the config.

**What does running this cost?**
The toolkit is free. Runs consume your own Claude subscription or API usage like any other Claude Code session; scheduled runs consume it on each execution. Usage depends on the selected model, targets, evidence volume and retries. API estimates must price input and output tokens separately using your provider's current rates; a subscription's quota is not an equivalent per-run API bill. See [token costs](token-costs.md) for measurement, cost factors and ways to control scope.

**We are in the EU. Does Sentry / our region work?**
Yes. Hosts and regions come from your `~/.scoutflo/toolkit.yaml`; nothing assumes a US region. `/scoutflo:connect` covers region selection per provider.

**Our logs/metrics/traces stores are spread across several clusters or environments. One audit, or one per cluster?**
One audit. Make `lgtm:` in your `toolkit.yaml` a **list** of stack entries — each with its own `label`, `kubernetes_context`, and store URLs (`loki_url`, `victoriametrics_url`, `tempo_url`, …) — and `/scoutflo:audit-lgtm` audits each stack in turn, writing a separate report per environment under `scoutflo-audits/lgtm/<label>/`. `/scoutflo:doctor` validates and probes each stack. A single stack stays a plain `lgtm:` block with nothing to change. See `references/providers.md` → "Multiple clusters / environments".

**We run prod and pre-prod. Can I get one report that separates them?**
Yes. Environment is chosen by *which config* you audit — keep a `toolkit-prod.yaml` and a `toolkit-nonprod.yaml` (what `/scoutflo:connect` writes for a prod + non-prod estate). Audit each environment into its own output dir (`SCOUTFLO_CONFIG=~/.scoutflo/toolkit-prod.yaml SCOUTFLO_AUDIT_DIR=./scoutflo-audits/prod /scoutflo:audit-all`, then the non-prod pair). `/scoutflo:audit-all`'s Phase 0 offers to cover all environments and render one combined report that lays each environment's per-integration readiness **side by side** — never a blended or averaged score — and flags anything audited in one environment but not the other as a coverage gap.

**A store (Grafana, VictoriaMetrics, Prometheus…) is only reachable on our VPN or inside the cluster. How do I audit it?**
Bridge it read-only and point the audit at the local port. If it runs in your cluster, `kubectl port-forward` it — this rides the same kubeconfig the cluster audit uses, including a private or JIT-tunnelled cluster. If it's a VPN-only host your tunnel doesn't cover (overlapping CIDRs, partial tunnel), `ssh -L` it through a bastion that can reach it. Then set that store's `*_url` to `http://127.0.0.1:<local-port>` and run the audit. `/scoutflo:doctor` prints this unlock for any store it cannot reach. Full recipe: `report-standard/private-store-access.md`. Everything is read-only — the plugin opens no network path of its own and holds no credential.

**Can I silence a finding we have accepted?**
Yes: add it to `./scoutflo-audits/exemptions.yaml` with a reason and an expiry date. It moves to the report's Suppressed appendix instead of vanishing, and returns automatically when the exemption expires.

**Can it map which service talks to which database or queue?**
Yes — on AWS, DigitalOcean, Azure, and GCP, and via your APM on any estate (a pure Kubernetes map gains database edges when New Relic or Tempo watches it). Run `/scoutflo:map-topology` with the matching cloud block configured: Cloud Mode catalogs your databases, caches, queues, topics, and buckets, then proposes service→resource connections it can actually prove — from what the service's configuration declares, what its IAM role is permitted to reach, what the network allows, and what live traffic shows. Every proposed connection shows its evidence, you confirm or reject them in batches (never one-by-one interrogation), and re-runs only ask about what changed. It works at three access levels — including a reduced mode for security-restricted accounts — and it never reads or asks for secret values: a secret's *name* is enough to make the connection.

**What is the "Scoutflo Topology Readiness" section?**
An optional parallel verdict: whether each critical service's topology data is complete enough for Scoutflo's platform to sync and correlate it. Useful if you plan to adopt the Scoutflo platform; ignorable if you do not. It never affects your audit score.

**Why is schedule-audits marked experimental?**
The crontab path has been validated end to end against a real scheduled run; the GitHub Actions and Claude cloud schedule paths have not yet. Whichever runner you pick, always validate your first scheduled run manually before trusting the cadence — the skill itself walks you through that proof step.

**I ran `/doctor` and it started analyzing my whole Claude Code install, plugins, and MCP servers — is that this plugin?**
No. Bare `/doctor` is **Claude Code's own built-in** health command; it inspects your install, plugins, sessions and MCP servers. The plugin's health check is the namespaced **`/scoutflo:doctor`**: it reads the selected toolkit configuration and checks credentials, tools and scoped read-only access. Each target can need several probes, and a successful probe proves only the access and response it checked. Always type the full `/scoutflo:doctor`; every plugin command is namespaced this way (`/scoutflo:start`, `/scoutflo:connect`, `/scoutflo:audit-*`).

**Something is broken. Where do I report it?**
GitHub issues on this repository. Include the skill name and the terminal output around the failure; never paste credentials or full reports.

## connect says it can't write toolkit.yaml (Claude Desktop app)

The Desktop app runs shell commands in an OS sandbox scoped to your working directory, so shell writes to `~/.scoutflo/` are denied there (the CLI prompts and allows them — that's why it "works in the terminal"). This is handled: `connect` probes first and walks a write ladder — file-tool write to your home (approve the prompt once), else project-local `./.scoutflo/` (auto-git-ignored). Every skill resolves config as `$SCOUTFLO_CONFIG` → `./.scoutflo/toolkit.yaml` → `~/.scoutflo/toolkit.yaml`, so whichever location connect lands in just works. Same for the secret store (`$SCOUTFLO_ENV_FILE` → `./.scoutflo/env` → `~/.scoutflo/env`). One caveat: in web/cloud sessions the "home" is the session sandbox, not your machine — run connect in the CLI or Desktop app for durable setup.

### Can combined reports prove that several tools page the same person?

Shared configuration findings identify a potential overlap to investigate. They do not prove duplicate events, pages or human delivery. Blocked, suppressed and resolved evidence cannot establish a current gap. Explicit limits on end-to-end readiness remain visible in combined reports, and empty reruns replace old summaries.

### What does the full On-Call audit assess?

It assesses setup quality and AI SRE readiness through eighteen scored checks: SOC-001–SOC-007 and SOC-009–SOC-019. SOC-008 remains a non-scored incident-lineage observation. The [check catalog](../skills/audit-splunk-oncall/references/oncall-checks.md) covers effective routing and escalation, personal/effective notification policy, maintenance and alert rules, current and future staffing, response objectives, recurring incidents, entity/recovery consistency, workload, diagnostic context and lifecycle quality. Each finding names the affected object, evidence, repair and verification. Score and assessment coverage remain separate; extending the check set does not make the new score comparable with an older seven-check assessment.

Missing permissions, plan features, unverified fields or undeclared objectives block the affected checks. Future coverage requires a defined horizon and effective shift/override evidence; a current responder alone does not prove it. Newer global paging enforcement can require an attended UI check because the public API does not establish its effective state. Presence of contact or runbook metadata does not prove delivery or useful diagnosis. Set your response objective, paging budget, staffing expectation and timezone before judging them.

### What does an On-Call triage pass assess?

Only bulk routing-key references and policy ownership. Staffing, current responders and source joins are deferred and marked blocked. Reports carry `scope: "triage"`; their scores must not be compared with full assessments. Run the full audit for those deeper checks.

### Does On-Call setup apply changes?

Yes. Confirmed API recipes cover supported team, membership, rotation, shift, policy and routing changes, with fresh dependency reads and exact verification. Provider-editor workflows use asserted management reads and separate fresh UI evidence where a field is visible only in the editor. Missing fields or unsupported preservation stop that action. Deleting an owned object is a separately approved retirement, not a promise to recreate its identity. Source configuration and human notification delivery remain separate proofs.

### How does On-Call work with the other skills?

Prometheus, Grafana, Sentry and cloud audits own the alert source: whether its rule evaluates and which destination it selects. On-Call owns the next part: routing key, escalation policy, team and current responder. Joining them requires fresh source evidence and an exact private key match; a receiver name or integration type alone is insufficient. Source collection may need an attended read because a provider hides its credential. Missing evidence stays blocked. An existing monitor cannot compensate for a missing responder.

`audit-all` includes the configured On-Call targets and preserves each audit's scope. Correlation and RCA use independently verified service identities; paging policies are not service monitors and do not establish application root cause. Alert-fatigue consumes current configuration findings and validates the On-Call history artifact for the same target and run date. Native history has its own window, completeness and incident counts; observed response means show acknowledgement/resolution sample sizes and missing transitions. It never invents source fires, actionability or notification counts. One incident or notification receipt is not representative history or proof of another channel.

The On-Call management audit has no billing or provider-computed savings lane. Cloud cost audits continue to assess their own resources; cost-analysis never turns routing or staffing findings into dollars. Migration-plan supports only its published provider pairs, currently Datadog to SigNoz; it does not invent an On-Call migration recipe.

### Can a matching service name or VictorOps handle prove coverage?

No. New cross-target conclusions require qualified account or cluster/namespace identities, current source evidence and observed activation. A legacy name-only record remains readable but unmappable. `audit-all` retains the full selected queue, so missing/partial target inventories cannot produce a confident scoped absence conclusion. See [service evidence](../report-standard/service-evidence.md).

Datadog and HyperDX project configuration before saving it. Their source packets distinguish a verified source read from a verified route. On-Call binds the source capture, exact safe definition, expected management target and private credential generation, then can check several routes against one management snapshot. A matching handle, webhook host or intermediate service is not proof of the exact routing key or human receipt.

### Is an empty HyperDX alert list necessarily bad?

No. The audit checks whether local alerts are required or another tool owns them by declared design. Source, connection and dashboard quality remain independently assessed. A denied or truncated read is unknown, not empty. Standalone alert-fatigue includes HyperDX configuration findings; it does not invent fire history or notification counts.

### Can I review all regional topology maps together?

Yes. Local estate composition preserves each map's qualified identities, timestamp and source hash. Configured exporter links remain distinct from observed traffic, including parallel telemetry and archive destinations. This local view does not add a new server import type or promise backend support for an unsupported provider.

### Can a previous report be counted in a new combined run?

A selected `audit-all` run records its start, target queue and validated completion receipts. The combined report, cost, fatigue and correlation readers use only those completed artifact generations. Missing targets stay unassessed; changed files or stale roll-ups require regeneration. Historical standalone reports remain readable with their dates and limits.

### How are ClickStack setup changes applied?

The setup skill retains retention, audit-user creation, HyperDX alerts and authentication hardening. It guides an attended change in the supported administrator surface, compares the exact target and before/after fields, preserves neighbouring settings and re-runs the read-only audit. Unknown API/DDL semantics block application. Restoring TTL configuration cannot recover data already deleted.
