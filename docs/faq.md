# FAQ

**Which Claude surface does this run in? Why did `/scoutflo:connect` fail when `/scoutflo:start` worked?**
Every skill executes real shell commands and reads/writes files on **your** machine — it creates `~/.scoutflo/toolkit.yaml`, runs `curl`/`kubectl`/`aws`, and writes reports to your disk. So it needs a **Local** Claude surface:

- ✅ Works: the `claude` **terminal CLI**; the Claude **desktop app's Code tab with the "Local" environment selected**; the VS Code / JetBrains Claude Code extensions.
- ❌ Does not work: the desktop app's **Chat tab**, or **claude.ai in a browser** — these run in Anthropic-managed cloud VMs with no access to your machine, so `/scoutflo:connect` fails with a "can't create the toolkit file locally" error.

That's why `/scoutflo:start` can succeed in a cloud surface while `/scoutflo:connect` fails: `start` is pure text (touches nothing local), so it renders anywhere; `connect` writes files, so it needs a Local session. The error is expected — switch to a Local session and re-run.

Separately, the one-time **install** commands (`/plugin marketplace add`, `/plugin install`) only run in the standalone `claude` terminal CLI (or the Team/Enterprise `settings.json` path); typing `/plugin ...` in the Chat tab fails with "isn't available in this environment." See [docs/install.md](install.md) for the exact commands.

**Can I install without a terminal at all?**
Yes, two ways. For a team, add the marketplace and enable the plugin through a `.claude/settings.json` file (the Team/Enterprise path in [docs/install.md](install.md)) — no `/plugin` command anywhere. And the Claude desktop app has a built-in plugin browser (the **+** next to the prompt → **Plugins**) that installs from a marketplace once it's been added. The one thing the desktop app can't do by itself is add a brand-new marketplace — that first step needs the terminal command or the settings file. Also note `/plugin` needs a fairly recent Claude Code (roughly v2.1.140+); run `claude --version` if the commands seem missing.

**The plugin shows installed but I don't see any `/scoutflo:` skills.**
The plugin files are present but Claude Code hasn't loaded its skills. Most often a fresh install just needs `/reload-plugins` (then fully restart Claude Code), or you're on a Claude Code older than ~v2.1.140 (`claude --version`, then update). If you're on a **Teams/Enterprise** plan, this is usually an org-vs-personal settings issue: managed settings override your personal ones, so an org `strictKnownMarketplaces` allowlist or an `enabledPlugins` policy can leave the plugin "installed" from your config while its skills never load — an Owner adds the `scoutflo` marketplace to the allowlist. Full step-by-step in [docs/install.md](install.md#troubleshooting-plugin-shows-installed-but-no-scoutflo-skills-appear).

**Does this work on Windows?**
Yes, with Git Bash. Every skill runs POSIX shell, and Claude Code on Windows runs shell through Git Bash when present, falling back to PowerShell (which can't run these commands) when it isn't. Install [Git for Windows](https://git-scm.com/downloads/win) with "Add to PATH", plus `jq` and your provider CLIs, and everything behaves exactly as on macOS/Linux. If skill commands fail with PowerShell parse errors, Git Bash is missing — see [docs/install.md](install.md#windows). macOS and Linux need no extra shell setup.

**Do I need a GitHub account or token to install?**
No. This repository is public, so the marketplace fetches it anonymously over HTTPS exactly like a public `git clone` — no login, token, or SSH key required. If `/plugin marketplace add` hangs on a corporate network, the cause is usually a firewall/proxy blocking `github.com` or `git` not being installed, not credentials; test with `git clone https://github.com/Scoutflo/ai-readiness.git /tmp/air-test`.

**Does any of my data go to Scoutflo?**
No. The toolkit runs inside your Claude Code. Your credentials stay in your environment, every API call originates from your machine or CI, and there is no telemetry, no report upload, and no callback. The only outbound calls go to your own integrations and, if you configure it, your own Slack webhook.

**What credentials do I need?**
`/scoutflo:connect` walks you through it per integration, with exact minimal scopes. Audits use read-only tokens. Setup skills need a second, higher-permission token that you create only if you use them.

**I created the token in the provider — where does it go so the toolkit uses it?**
Not into `toolkit.yaml`. That file only records the *name* of the environment variable (for example `token_env: KIBANA_API_KEY`); the token **value** lives separately, in your environment, under that exact name. Put it in the home-anchored secret store once:
```bash
mkdir -p ~/.scoutflo && touch ~/.scoutflo/env && chmod 600 ~/.scoutflo/env
grep -q 'scoutflo/env' ~/.zshrc 2>/dev/null || echo '[ -f ~/.scoutflo/env ] && . ~/.scoutflo/env' >> ~/.zshrc
echo 'export KIBANA_API_KEY="<paste-the-token-here>"' >> ~/.scoutflo/env
source ~/.scoutflo/env
```
Swap `KIBANA_API_KEY` for the provider's `*_env` name (`GRAFANA_TOKEN`, `DATADOG_API_KEY`, `PROM_TOKEN`, …; `/scoutflo:connect` and `references/providers.md` name it per provider). Then `/scoutflo:doctor` confirms it. The three moving parts: `toolkit.yaml` names the var → `~/.scoutflo/env` holds the value → each audit reads the value by that name. `doctor` **and** every audit source `~/.scoutflo/env` at the start of a run, so a token added there is picked up in the same session — no need to open a new terminal. (On Windows PowerShell, use `setx KIBANA_API_KEY "<paste>"` and reopen the terminal.) The value never goes into chat, into `toolkit.yaml`, or into any skill; a plain `export KIBANA_API_KEY="…"` also works but only for the current shell — the `~/.scoutflo/env` file is what makes it persist across sessions.

**Can an audit change anything in my systems?**
No. Audit skills are read-only by design and doctor-gated; the only writes are local report files. Setup skills are separate, state every change up front, and do nothing until you explicitly confirm.

**We use MCP servers for our integrations instead of CLIs — does this still work?**
Yes — the toolkit uses **both** and picks the best transport per operation, so you don't choose and don't configure anything. Most integrations (Grafana, Prometheus, Loki, Tempo, VictoriaMetrics/Logs, Sentry, Datadog, PagerDuty, ELK, JSM, Zenduty, Groundcover) are reached over HTTPS with a token, so a read needs only `curl` + `jq` — no vendor CLI; only Kubernetes and AWS/GCP/DigitalOcean use a CLI. Reads take the fast direct CLI/HTTP path; a connected MCP tool is used when it is the equivalent read route or the only reachable one, and for a write whose typed MCP tool is the safer path than a hand-built call. A stack with only CLIs, only MCP servers, or a mix all work. Safety is unchanged: audits only ever call read-only tools (classified by effect, not name), never anything that mutates state.

**What does the 0–100 score mean?**
It measures your setup against a stated best-practice target for that audit's domain, weighted by category (the scorecard shows each category's weight and its passed/total checks). 85 is the end-to-end gate: at or above it — with every critical service covered and no category excluded — the report may claim end-to-end coverage. Below it, the executive summary states your gap in points and the two or three findings that recover the most. Scoring is conservative: a check only earns full credit when it was verified live this run, so a low first score usually means "unproven", not "broken". Full mechanics are in `report-standard/severity-and-scoring.md`.

**Does it help with alert noise or alert fatigue?**
Yes. Every audit scores alert hygiene alongside coverage: it flags rules that flap (fire and resolve in a loop), rules that have fired so long they've become wallpaper, alerts with no debounce that trip on a single blip, missing grouping or inhibition, duplicate delivery, and resolve-noise. Each noisy rule is named with the exact setting to fix it. It reports the structural signs of noise directly; it does not invent an "X% of your alerts are actionable" figure — a true alert-to-incident rate needs a feed from your paging tool.

**Which platforms and stacks does it cover?**
Prometheus, LGTM and the VictoriaMetrics family (Loki, Tempo, Mimir, VictoriaMetrics/Logs/Traces, Alertmanager, vmalert), Grafana, Sentry, PagerDuty, Datadog, ELK/Kibana, JSM Operations, Zenduty, groundcover, Prometheus/Alertmanager alert routing, Kubernetes (security + reliability config), DigitalOcean, Google Cloud, and AWS — plus a cross-provider **cost** audit (`/scoutflo:audit-cost`) and a root-cause skill (`/scoutflo:rca`) that reasons across all of the above. Connect only the ones you use; `/scoutflo:start` lists the full catalog.

**Where do reports go?**
By default `./scoutflo-audits/` in the directory you launched Claude Code from. To point it anywhere, **export `SCOUTFLO_AUDIT_DIR`** to an absolute path — that env var is what actually moves the location (every command runs in a fresh shell, so an exported variable is what carries across them). `/scoutflo:doctor` prints the exact absolute path it resolved. You can also set `reports_dir` in `~/.scoutflo/toolkit.yaml`; that's a convenience — doctor reads it and prints the `export SCOUTFLO_AUDIT_DIR=...` line for you (and warns if it's set but not yet exported), but setting it alone doesn't move reports until the export is in your environment. **If you rely on the default and launch Claude from a different folder, that run writes to a different, empty `scoutflo-audits/`** — so it shows "first run" with no delta, and your `topology.md`/`exemptions.yaml` from the other folder aren't found (your credentials in `~/.scoutflo/` are unaffected). Auditing one estate over time? Export `SCOUTFLO_AUDIT_DIR` to a stable absolute path and every run — interactive or scheduled — shares one history. Keep the reports folder out of public version control; reports name your namespaces, hosts, and routes. The Slack brief carries finding titles and counts only, never evidence values.

**Can I keep everything in one dedicated project folder?**
Mostly yes — that's the default for everything except credentials. Reports, history, topology, and exemptions already land in the folder you run from (`./scoutflo-audits/`), so a dedicated "readiness" folder works with zero setup; export `SCOUTFLO_AUDIT_DIR` if you want that path pinned regardless of where you launch. Credentials (`~/.scoutflo/toolkit.yaml` + `~/.scoutflo/env`) default to your home directory **on purpose**: they're per-machine secrets-adjacent files that shouldn't live next to reports you might zip up or commit, and home-anchoring is what makes every new terminal, session, and folder pick them up without re-asking. If you have a real reason to relocate the config (e.g. two isolated estates on one machine), export `SCOUTFLO_CONFIG=/path/to/toolkit.yaml` — every skill honors it. Moving the *reports* folder never requires moving the config.

**What does running this cost?**
The toolkit is free. Runs consume your own Claude subscription or API usage like any other Claude Code session; scheduled runs consume it on each execution. A full suite is on the order of a few hundred thousand to ~1M tokens (a dollar or two at Haiku pricing), scaling with how many integrations you connect and your estate size. See [docs/token-costs.md](token-costs.md) for the per-audit breakdown, cost factors, and ways to control spending.

**We are in the EU. Does Sentry / our region work?**
Yes. Hosts and regions come from your `~/.scoutflo/toolkit.yaml`; nothing assumes a US region. `/scoutflo:connect` covers region selection per provider.

**Can I silence a finding we have accepted?**
Yes: add it to `./scoutflo-audits/exemptions.yaml` with a reason and an expiry date. It moves to the report's Suppressed appendix instead of vanishing, and returns automatically when the exemption expires.

**What is the "Scoutflo Topology Readiness" section?**
An optional parallel verdict: whether each critical service's topology data is complete enough for Scoutflo's platform to sync and correlate it. Useful if you plan to adopt the Scoutflo platform; ignorable if you do not. It never affects your audit score.

**Why is schedule-audits marked experimental?**
The crontab path has been validated end to end against a real scheduled run; the GitHub Actions and Claude cloud schedule paths have not yet. Whichever runner you pick, always validate your first scheduled run manually before trusting the cadence — the skill itself walks you through that proof step.

**I ran `/doctor` and it started analyzing my whole Claude Code install, plugins, and MCP servers — is that this plugin?**
No. Bare `/doctor` is **Claude Code's own built-in** health command; it inspects your entire install (plugins, sessions, MCP servers, permission mode, native install) and has nothing to do with this toolkit. The plugin's health check is the namespaced **`/scoutflo:doctor`** — it does one thing: reads `~/.scoutflo/toolkit.yaml` and makes one cheap read-only call per configured integration to tell you what's connected. Always type the full `/scoutflo:doctor`; the two commands are unrelated despite the similar name. Every plugin command is namespaced this way (`/scoutflo:start`, `/scoutflo:connect`, `/scoutflo:audit-*`).

**Something is broken. Where do I report it?**
GitHub issues on this repository. Include the skill name and the terminal output around the failure; never paste credentials or full reports.
