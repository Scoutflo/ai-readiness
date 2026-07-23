# Install

Three paths: install it yourself, roll it out to a team through a shared repository, or force-enable it across an organization with managed settings. All three end at the same place: run `/scoutflo:start` and follow it.

## Individual

Inside Claude Code:

```
/plugin marketplace add Scoutflo/ai-readiness
/plugin install scoutflo@scoutflo
```

First run, in order:

1. `/scoutflo:start` orients you: what is installed, what to do first.
2. `/scoutflo:connect` sets up credentials for your integrations, with exact scopes and read-only token recipes.
3. `/scoutflo:doctor` validates every connection live before you run anything else.

Then run any `audit-*` skill and read the report in `./scoutflo-audits/<target>/<date>/report.md`. Not sure which audits apply to you? `/scoutflo:start` lists the full catalog.

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

The plugin marketplace clones `Scoutflo/ai-readiness` with your own git credentials — SSH keys in your agent, or HTTPS via `gh auth login`. No separate access grant is needed.
