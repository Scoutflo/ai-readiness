# Data handling

Scoutflo AI Readiness runs through your Claude Code session and the tools you
configure. This page describes the shipped plugin's data flows, local files and optional
external services.

## Where data goes

| Component | Data and destination |
| --- | --- |
| Execution environment | Your machine or selected runner executes commands and stores configuration, working data and reports. |
| Configured integrations | Your cloud, Kubernetes and monitoring services receive authenticated requests. Their responses can include configuration, resource names, metrics, logs and other operational data. A configured MCP server can provide an equivalent integration route. |
| Claude Code and model provider | Prompts, selected context and tool results can become part of the model session. Local command execution does not make model processing offline. Your client, account and provider settings govern processing, session retention and client telemetry. |
| Optional Slack delivery | When you request delivery, a brief goes to the webhook you configured. The brief is intended to contain finding titles, IDs, scores and summary information, rather than raw evidence or credentials. Review it before sharing. |
| Scheduled GitHub Actions runs | The supplied template stores the reports directory in an Actions cache for comparisons between runs. It also includes a removable artifact-upload step. These can transfer reports to GitHub; disabling artifact upload alone does not disable caching. |

The shipped plugin does not include an automatic Scoutflo telemetry endpoint,
report-upload service or callback. Installation and updates fetch the public
repository from GitHub. This does not remove the separate data flows of Claude
Code, model providers, integrations, secret managers, MCP servers or delivery
services you use. See [Claude Code's data-usage documentation](https://code.claude.com/docs/en/data-usage)
for its current behavior and account controls.

## Configuration and credentials

The default configuration is `~/.scoutflo/toolkit.yaml`. An explicit
`SCOUTFLO_CONFIG` or project-local `.scoutflo/toolkit.yaml` can select another
configuration. This file contains endpoints and other configuration details;
its `*_env` fields contain credential variable names, not secret values.

Credentials come from your environment, configured provider authentication or
the local secret store. The store resolves from `SCOUTFLO_ENV_FILE`, then an
existing project-local `.scoutflo/env`, otherwise `~/.scoutflo/env`. The shipped
[credential writer](https://github.com/Scoutflo/ai-readiness/blob/main/skills/connect/scripts/addsecret.sh)
uses owner-only file permissions and does not echo entered values. The store is
a shell file, not an encrypted vault.

A command-based credential entry runs its fetch command each time the store is
loaded. Use only trusted credential-fetch commands and protect the store from
modification. Use scoped, read-only credentials for audits, with separate
elevated credentials when an approved setup needs them. Keep secret values out
of model chat and version control.

Additional hooks, MCP servers, CLI extensions, custom credential commands or
changes to the plugin can introduce other destinations and behavior. Review
those separately; this description does not cover every customization of your
execution environment.

## Reports, access and retention

The default output directory is `./scoutflo-audits/` beneath the directory where
you launch Claude Code. Export `SCOUTFLO_AUDIT_DIR` to select a different base.
Reports and local working data can contain infrastructure identifiers,
hostnames, routing details, configuration evidence and provider-returned free
text. They are not automatically suitable for public sharing.

The [redaction standard](https://github.com/Scoutflo/ai-readiness/blob/main/report-standard/secret-redaction.md)
requires secret removal at capture and an additional masking pass. These controls
need verification; pattern matching does not guarantee that every sensitive
value has been removed. Keep reports and working data out of public version
control, and review files before sharing them or adding them to a model session.

Choose access and retention for local files, session history, Slack, CI caches
and CI artifacts separately. The [scheduling template](https://github.com/Scoutflo/ai-readiness/blob/main/templates/github-actions-audit.yml)
includes both cache and artifact storage of the reports directory; review both
before enabling a schedule. A cloud-hosted runner also holds the credentials and
configuration supplied to that run.

Audit skills query systems and write local reports. Setup skills can change
resources through their announce, confirm, execute and verify flow. Uninstalling
the plugin does not remove your saved credentials, reports or separately created
schedules. See the [installation and uninstall guide](https://github.com/Scoutflo/ai-readiness/blob/main/docs/install.md).

For suspected security issues, follow [SECURITY.md](https://github.com/Scoutflo/ai-readiness/blob/main/SECURITY.md)
and keep credentials and unredacted reports out of public issues.
