---
name: schedule-audits
description: Sets up recurring audits by filling a GitHub Actions workflow, crontab entry, or Claude cloud schedule that runs audit-all headless with an optional Slack brief, writing the file only after approval. Use when the user asks to schedule audits, run audits weekly or nightly, automate recurring audits, or set up a cron or CI audit job. Do not use to run an audit now (use audit-all) or to set up credentials (use connect).
---

# Schedule Recurring Audits

> Status: experimental in this release. The crontab path has an end-to-end
> live validation behind it; GitHub Actions and the Claude cloud schedule
> path do not yet. Whichever runner you pick, validate the first scheduled
> run manually before trusting the cadence — this skill's own steps walk
> you through that proof.

Turns your audits into a recurring job. This skill asks what you want, fills the matching template, and writes the scheduling file after you approve it. It runs no audit itself and needs no integration credentials; the scheduled runner needs them at run time.

Prerequisites: `~/.scoutflo/toolkit.yaml` filled in (`/scoutflo:connect`) and at least one successful manual run of `/scoutflo:audit-all`. Never schedule a job you have not seen succeed by hand once.

## Phase 1: Three questions

Ask, with defaults:

1. **Which audits?** Default: everything configured, via `/scoutflo:audit-all`. A single stack instead: swap in that skill, for example `/scoutflo:audit-lgtm --slack`.
2. **What cadence?** Default weekly. Examples, tune to your environment:

   | Cadence | Cron expression |
   | --- | --- |
   | Weekly, Monday 06:00 | `0 6 * * 1` |
   | Daily, 06:00 | `0 6 * * *` |
   | Twice weekly, Mon and Thu | `0 6 * * 1,4` |

3. **Delivery?** Slack brief on or off (needs `slack.webhook_env` in the config), and for GitHub Actions whether to upload `./scoutflo-audits/` as a build artifact and for how many days.

## Phase 2: Choose a runner

| Runner | Choose when | Main caveat |
| --- | --- | --- |
| GitHub Actions | Targets reachable from a hosted runner; you want run history and team visibility | VPN-only or in-cluster targets need a self-hosted runner |
| Local crontab | An always-on machine can reach every target | Machine asleep at the scheduled time means a missed run; cron does not catch up |
| Claude cloud schedule | Every target is a SaaS endpoint on the public internet (managed Grafana, sentry.io) | Your credentials must be stored with the cloud environment; see below |

**Cloud schedule caveat.** Claude's own scheduled runs need no runner of yours, but the run executes outside your network: it can only reach public SaaS endpoints, and every token it uses must be stored with the cloud environment. Use dedicated read-only tokens you are comfortable holding there, and never use this path for private-network targets. When in doubt, prefer the two self-hosted paths below, where secrets stay in your CI store or on your machine.

**Cost note for every path.** Each scheduled run is a headless Claude session; usage scales with the number of configured audits and the size of your stack. Start weekly, check actual usage after the first runs, then tighten the cadence if the reports earn it.

## Phase 3a: GitHub Actions path

1. Fill the template at `templates/github-actions-audit.yml` (in this plugin) with the chosen cron expression, one `env` line per `*_env` name in the user's `toolkit.yaml`, and the artifact retention choice. Show the completed file and wait for approval, then write it to `.github/workflows/scoutflo-audit.yml` in their repo.
2. Create the secrets. `gh secret set` reads the value interactively or from stdin, so nothing lands in shell history:

```bash
set -eu
REPO="your-org/your-repo"        # the repo that will run the schedule
gh secret set ANTHROPIC_API_KEY --repo "$REPO"
gh secret set SCOUTFLO_TOOLKIT_YAML --repo "$REPO" < "$HOME/.scoutflo/toolkit.yaml"
gh secret set GRAFANA_TOKEN --repo "$REPO"          # repeat for every *_env name in toolkit.yaml
gh secret set SCOUTFLO_SLACK_WEBHOOK --repo "$REPO" # only if the brief is on
```

Expected output: a "Set Actions secret" confirmation per call. The whole `toolkit.yaml` goes in as a secret so hostnames never enter the repo.

3. Verify: after the user commits and pushes the workflow, trigger it once by hand and watch it:

```bash
set -eu
REPO="your-org/your-repo"        # same repo as above
gh workflow run scoutflo-audit.yml --repo "$REPO"
RUN_ID=$(gh run list --repo "$REPO" --workflow scoutflo-audit.yml --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --repo "$REPO" --exit-status; echo "watch_exit=$?"
```

Expect: watch_exit=0 (the scheduled workflow completed successfully). A missing-secret failure names the variable; add it and re-run.

## Phase 3b: Crontab path

1. Fill the template at `templates/crontab.example` with the project directory, the cron expression, and the absolute `claude` binary path from `command -v claude` (cron's `PATH` is minimal).
2. Have the user create `$HOME/.scoutflo/env` with `chmod 600`: one `export` line per `*_env` variable named in their `toolkit.yaml`, plus the Slack webhook variable if the brief is on. Values come from their secret manager; the file is never committed anywhere.
3. Show the finished entry and ask the user to paste it via `crontab -e`. Verify:

```bash
crontab -l 2>/dev/null | grep -q 'scoutflo:audit-all' && echo "cron_entry=present" || echo "cron_entry=missing"
```

Expect: cron_entry=present

4. Before running the full entry, confirm headless auth works at all — this is cheap and fails fast, versus discovering it only after a full audit run times out:

```bash
"$(command -v claude)" -p "say ok" --allowedTools "" 2>&1 | head -5
```

Expect: a short reply, not `Not logged in · Please run /login`. Confirmed live: a machine using interactive subscription login (no `ANTHROPIC_API_KEY` exported) fails headless invocation with exactly that message — the prerequisite list already says "authenticated (subscription login, or export `ANTHROPIC_API_KEY`)," but subscription login alone does not carry into a headless `-p` invocation the way it does an interactive session. If this check fails, export `ANTHROPIC_API_KEY` in `$HOME/.scoutflo/env` before going further; do not proceed to a full scheduled run on a machine that fails this check.

5. Prove the full entry works before trusting the schedule: run the entry's command once by hand, from the same directory, and confirm a report and brief appear. Then check `$HOME/.scoutflo/audit-cron.log` after the first scheduled run.

## Where scheduled reports go

Cron runs accumulate reports in the project's `./scoutflo-audits/`, so deltas compute automatically. GitHub Actions runners start clean each run; the template restores the previous `scoutflo-audits/` from the Actions cache so deltas work there too, and optionally uploads each run's reports as an artifact. Artifacts are visible to anyone with read access to the repo, and reports describe your infrastructure: keep the repo private or the retention short.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Cron fires but `claude` is not found | Write the absolute path from `command -v claude` into the entry; cron's `PATH` is minimal |
| Crontab entry runs but fails with `Not logged in · Please run /login` | Confirmed live: interactive subscription login does not carry into a headless `-p` invocation. Run the cheap headless-auth check (Phase 3b step 4) before trusting any schedule on that machine; export `ANTHROPIC_API_KEY` in the env file if it fails |
| CI run fails on a missing `*_env` secret | Mirror every `*_env` name from `toolkit.yaml` into the CI secret store before the first scheduled run |
| Hosted runner cannot reach in-cluster or VPN-only targets | Use a self-hosted runner or the crontab path for private-network targets |
| Slack brief works locally but not on the schedule | The webhook is an env var like any other; add it to the CI secrets or the cron env file |
| Every CI run reports "first run, no delta" | Keep the Actions cache step so the previous `scoutflo-audits/` directory is restored |
| Usage costs surprise you | Start weekly, review usage after the first runs, then adjust cadence deliberately |
