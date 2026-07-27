# Install

Three paths: install it yourself, roll it out to a team through a shared repository, or force-enable it across an organization with managed settings. All three end at the same place: run `/scoutflo:start` and follow it.

**Every path below that uses a `/plugin ...` command means the standalone `claude` terminal CLI, not Claude.app's chat window.** `/plugin marketplace add`, `/plugin install`, `/plugin` (list/update), `/plugin uninstall`, and `/plugin marketplace remove` are all terminal-CLI-only commands — typing them into Claude.app's chat box fails with "isn't available in this environment." This is a one-time distinction: once a plugin is installed, it's available inside Claude.app automatically (the terminal and the app read the same shared `~/.claude/` config), and every `/scoutflo:...` skill command works directly in Claude.app's chat with no terminal involved. The "Team" and "Enterprise" paths below skip the terminal step entirely — they install via a settings file instead.

**Two ways to avoid the terminal for the install itself.** (1) The **Team / Enterprise** paths below add the marketplace and enable the plugin through a `settings.json` file — no `/plugin` command anywhere. (2) The **Claude desktop app** has a built-in plugin browser (in the app's UI, not the chat box: the **+** next to the prompt → **Plugins**) that can install and manage plugins — but only from a marketplace that has *already been added*. The desktop app cannot add a brand-new marketplace on its own, so the very first step (`/plugin marketplace add Scoutflo/ai-readiness`, or the `settings.json` entry) still comes from the terminal or a settings file. After that, browsing and installing from the app's UI works.

**Version note.** The `/plugin` commands need a reasonably recent Claude Code (roughly **v2.1.140 or newer**). Check with `claude --version` and update (`npm install -g @anthropic-ai/claude-code`) if it's older, or the commands may not exist yet.

## Individual

**Step 1 — one time, in a real terminal** (Terminal.app, iTerm, etc.). If the `claude` command isn't installed yet:

```bash
npm install -g @anthropic-ai/claude-code
```

Then, in that same terminal:

```bash
claude plugin marketplace add Scoutflo/ai-readiness
claude plugin install scoutflo@scoutflo
```

**Step 2 — restart Claude Code / Claude.app** (fully quit and reopen, not just a new tab) so it loads the plugin you just installed.

**Step 3 — everyday use, back in Claude.app's chat (or any Claude Code surface) — no more terminal needed.** First run, in order:

1. `/scoutflo:start` orients you: what is installed, what to do first.
2. `/scoutflo:connect` sets up credentials for your integrations, with exact scopes and read-only token recipes.
3. `/scoutflo:doctor` validates every connection live before you run anything else.

Then run any `audit-*` skill and read the report in `./scoutflo-audits/<target>/<date>/report.md`. Not sure which audits apply to you? `/scoutflo:start` lists the full catalog.

### Verify or update the installed version

In a terminal:

```bash
claude plugin list
claude plugin update scoutflo@scoutflo
```

(Or, inside a `claude` terminal session, the interactive `/plugin` command — not inside Claude.app's chat, same restriction as install.) Compare the installed version against [CHANGELOG.md](../CHANGELOG.md); the marketplace serves the latest release from the repository's `main` branch. Restart Claude Code / Claude.app after updating.

### Uninstall

In a terminal:

```bash
claude plugin uninstall scoutflo@scoutflo
claude plugin marketplace remove scoutflo
```

Your credentials (`~/.scoutflo/toolkit.yaml`, token env variables) and generated reports (`./scoutflo-audits/`) are yours and are not removed; delete them yourself if you want a full cleanup.

## Team

Commit this to `.claude/settings.json` in the repository your team works from. Everyone who opens the repo in Claude Code gets the marketplace and the plugin automatically, kept up to date:

```json
{
  "extraKnownMarketplaces": {
    "scoutflo": {
      "source": { "source": "github", "repo": "Scoutflo/ai-readiness" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": {
    "scoutflo@scoutflo": {}
  }
}
```

Credentials stay individual: each teammate runs `/scoutflo:connect` once with their own tokens. Nothing secret goes in the settings file.

## Enterprise

To force-enable the plugin for every user, put the same `extraKnownMarketplaces` and `enabledPlugins` keys in your managed settings file (`managed-settings.json`, deployed by your device management to the system-level Claude Code settings path). Managed settings override user and project settings, so users cannot disable the plugin.

If your organization sets `strictKnownMarketplaces`, only allowlisted marketplaces can be added. Add the `scoutflo` marketplace entry to that allowlist in the same managed settings file, or installs will be refused.

## Keep reports private

Audit reports contain infrastructure detail: hostnames, namespaces, service names, alert routing. Keep them out of public version control. Add this to the `.gitignore` of any repository where you run audits:

```gitignore
scoutflo-audits/
```

## Trust

The toolkit runs entirely inside your own Claude Code session, on your machine or your CI. Your credentials stay in your environment and every API call originates from it. Nothing is sent to Scoutflo: no telemetry, no report upload, no callbacks.

## How the marketplace fetches the plugin

`Scoutflo/ai-readiness` is a **public** repository, so the marketplace clones it anonymously over HTTPS the same way `git` clones any public repo — **no GitHub login or token is required.** (If you happen to have git credentials configured, git will use them, but they are not needed.)

It does use `git` over the network, so the failure modes in a locked-down environment are git's, not GitHub's: a firewall/proxy blocking `github.com`, `git` not installed, or a proxy that needs authentication. Pre-flight check from the target machine:

```bash
git clone https://github.com/Scoutflo/ai-readiness.git /tmp/air-test && rm -rf /tmp/air-test
```

If that succeeds, `/plugin marketplace add Scoutflo/ai-readiness` will work too.
