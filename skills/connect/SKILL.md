---
name: connect
description: Guided credential setup; creates minimal-scope tokens per tier for Grafana, Sentry, PagerDuty, Datadog, Prometheus, Loki, Tempo, Mimir, VictoriaMetrics, Kubernetes, and Slack, and writes ~/.scoutflo/toolkit.yaml. Use when the user wants to connect or onboard the toolkit, add an integration, rotate a token, or set up credentials, including the audit-brief Slack webhook. Do not use for alert-delivery webhooks (Grafana contact points, Alertmanager receivers; use setup-grafana or setup-lgtm) or to verify reachability (use doctor).
---

# Connect: Credential and Config Setup

Connect sets up every credential the toolkit needs, at the smallest scope that works, and records the non-secret half in `~/.scoutflo/toolkit.yaml`. Run it when you install the toolkit, when you add an integration, when you rotate a token, or when you move from the read-only tier to the elevated tier.

Everything stays on your machine. Secrets go into environment variables you control. The config file holds only hosts, org names, and the names of those variables.

## Asking questions

Every question in this flow (which integrations, host, org slug, tier, tenant ID, anything) is a plain question in a normal chat message, answered in free text. Never drive a question through a structured multiple-choice or multi-select UI tool: some client environments cap the option count on those tools (a maximum of 4 has been observed) or require a minimum (2, in the same client) and reject the call outright if a question falls outside that range — a fixed list of integrations can exceed the maximum, and an inherently free-text field like an org slug or a custom URL has no natural set of 2+ options to offer, so wrapping it in one ("I'll type it") can fall below the minimum. A plain-text question has neither limit and works identically in every client this skill runs in.

## The human/agent boundary

Two hard rules for this whole flow:

- Never paste a token, webhook URL, or any secret into this conversation. `toolkit.yaml` never contains a secret either: every `*_env` key names an environment variable, and the value lives only in your environment.
- Any command that reads, exports, or prompts for a secret value is shown for you to run in your own terminal. An agent driving this skill displays those commands and never executes them; the agent's own commands are limited to non-secret work (creating directories, copying the template, parsing the config, running doctor).
- If a secret does get pasted into a conversation, treat it as exposed: revoke it in the provider UI, mint a fresh credential under the same name, and re-export. A rotated token costs a minute; an exposed one is permanent.

## Prerequisites

- `bash`, `curl`, `jq` on your PATH.
- `kubectl`, only if you connect a Kubernetes cluster.
- Admin access to each provider you connect (you create the tokens in their UIs).
- Write access to `~/.scoutflo/`.

## The two credential tiers

Every integration that supports scoped tokens gets one of two tiers. Exact scopes per provider are in [references/providers.md](references/providers.md).

| Tier | Who uses it | Rule |
| --- | --- | --- |
| Read-only | `audit-*` skills, `doctor`, `map-topology` | Can list, get, and query. Cannot create, modify, or delete anything. |
| Elevated | `setup-*` skills | The read-only scopes plus the specific write scopes each setup skill declares. |

Start with the read-only tier. Add an elevated credential only when you are ready to run a `setup-*` skill, and keep it as a separate token or service account so you can revoke it independently. Never raise the audit credential in place.

Two conventions are rules, not suggestions:

- **Naming**: name every credential for its tier, `scoutflo-audit` for read-only and `scoutflo-setup` for elevated, in every provider that lets you name tokens, service accounts, or integrations. Provider audit logs and revocation lists then say exactly which credential belongs to which tier.
- **Recording**: every config block that names a `token_env` also records the tier of that token as `tier: read-only` or `tier: elevated`. The file then documents what the credential behind each variable is allowed to do.

- ❌ `grafana: { url: ..., token_env: GRAFANA_TOKEN }` backed by a token named `my-admin-token` with the Admin role, used for audits and setup alike.
- ✅ `grafana: { url: ..., token_env: GRAFANA_TOKEN, tier: read-only }` backed by a Viewer service account named `scoutflo-audit`, with a separate `scoutflo-setup` account created only when setup work starts.

## Step 1: Pick your integrations

Configure only what you run. Unconfigured integrations are skipped cleanly by every skill; they are not failures.

Ask which integrations to configure as a plain numbered list in a normal chat message, per the "Asking questions" rule above — this table has up to 11 rows, well past the option ceiling that rule warns about.

| Integration | Used by | Config block | Suggested env var | Tier summary |
| --- | --- | --- | --- | --- |
| Grafana | audit-grafana, setup-grafana, audit-lgtm, audit-alert-routing | `grafana:` | `GRAFANA_TOKEN` | Viewer for audits; Editor or Admin for setup |
| Sentry | audit-sentry, setup-sentry | `sentry:` | `SENTRY_TOKEN` | read scopes for audits; write scopes for setup |
| PagerDuty | audit-pagerduty | `pagerduty:` | `PAGERDUTY_TOKEN` | read-only REST key for audits |
| Datadog | audit-datadog | `datadog:` | `DATADOG_API_KEY` + `DATADOG_APP_KEY` | scoped read-only app key for audits |
| Prometheus + Alertmanager | audit-lgtm, setup-lgtm, audit-alert-routing | `prometheus:` | `PROM_TOKEN` (only if your endpoints require auth) | URL reachability; optional bearer |
| Loki | audit-lgtm, setup-lgtm | `loki:` | `LOKI_TOKEN` (optional) | URL; optional tenant and token |
| Tempo | audit-lgtm, setup-lgtm | `tempo:` | `TEMPO_TOKEN` (optional) | URL; optional tenant and token |
| Mimir | audit-lgtm, setup-lgtm | `mimir:` | `MIMIR_TOKEN` (optional) | URL; `tenant_id` when multi-tenant |
| VictoriaMetrics | audit-lgtm, setup-lgtm | `victoriametrics:` | `VM_TOKEN` (optional) | URL; `vmalert_url` when you run vmalert |
| Kubernetes | map-topology, audit-lgtm, setup-lgtm | `kubernetes:` | none (kubeconfig context) | read-only context for audits |
| Slack | the per-run brief from every audit skill | `slack:` | `SCOUTFLO_SLACK_WEBHOOK` | the webhook URL is itself the secret |

## Step 2: Gather the configuration

Judgment step: collect the non-secret facts for every integration you picked before creating any credential. Missing facts surface here, not halfway through a provider UI.

| Integration | Required keys | Example |
| --- | --- | --- |
| Grafana | `grafana.url`, `grafana.token_env`, `grafana.tier` | `url: https://grafana.example.com` |
| Sentry | `sentry.host`, `sentry.org`, `sentry.token_env`, `sentry.tier` | `host: us.sentry.io` |
| PagerDuty | `pagerduty.token_env`, `pagerduty.tier`; optional `region` | `region: us` |
| Datadog | `datadog.site`, `datadog.api_key_env`, `datadog.app_key_env`, `datadog.tier` | `site: datadoghq.com` |
| Prometheus + Alertmanager | `prometheus.url`, `prometheus.alertmanager_url`; add `token_env` and `tier` only behind an auth proxy | `url: https://prometheus.example.com` |
| Loki | `loki.url`; optional `token_env` and `tier` | `url: https://loki.example.com` |
| Tempo | `tempo.url`; optional `token_env` and `tier` | `url: https://tempo.example.com` |
| Mimir | `mimir.url`; optional `tenant_id`, `token_env`, `tier` | `tenant_id: your-tenant` |
| VictoriaMetrics | `victoriametrics.url`; optional `vmalert_url`, `token_env`, `tier` | `vmalert_url: https://vmalert.example.com` |
| Kubernetes | `kubernetes.context`; optional `monitoring_namespace` | `context: your-kube-context` |
| Slack | `slack.webhook_env` | `webhook_env: SCOUTFLO_SLACK_WEBHOOK` |

A minimal assembled config, for a team running only Grafana and an unauthenticated in-cluster Prometheus, looks like this:

```yaml
grafana:
  url: https://grafana.example.com
  token_env: GRAFANA_TOKEN
  tier: read-only

prometheus:
  url: https://prometheus.example.com
  alertmanager_url: https://alertmanager.example.com
```

## Step 3: Create each credential

Work through the matching section of [references/providers.md](references/providers.md) for every integration you picked. Each section gives you:

- the exact click path in the provider UI,
- the minimal scopes for the read-only tier and for the elevated tier,
- the `toolkit.yaml` block and env var to set,
- a one-line verification command to run immediately after creating the credential.

Create read-only credentials now, named `scoutflo-audit` per the naming rule. Create elevated ones later, named `scoutflo-setup`, when a `setup-*` skill asks for them.

**Run each provider's verify command the moment you export that credential — before starting the next integration, not after all of them.** With eleven possible integrations, a wrong host, wrong scope, or mistyped org slug is far cheaper to catch and fix one provider at a time than to debug from a single `doctor` run at the very end of Step 7, where several small mistakes can compound into one confusing failure list. Step 7's `doctor` pass is the final confirmation that everything is wired together, not the first time any of it gets checked.

## Step 4: Export the secrets (you run these, not the agent)

The commands in this step read secret values, so they are yours to run in your own terminal. An agent shows them and never executes them; the value never enters the conversation. Export each secret without echoing it and without leaving it in shell history:

```bash
# YOU run this in your own terminal; an agent never executes this command.
# Prompts silently, exports for this shell session only. Repeat per variable.
printf 'GRAFANA_TOKEN: ' && read -rs GRAFANA_TOKEN && export GRAFANA_TOKEN && printf '\n'
```

Environment variables are per-shell: export them in the same shell where you run the toolkit's skills. For persistence, load them in your shell profile from a secret manager rather than hardcoding values:

```bash
# In ~/.zshrc or ~/.bashrc: pull from your secret manager at shell start.
# Substitute your own secret manager's CLI.
export GRAFANA_TOKEN="$(your-secret-manager get sre-toolkit/grafana-audit)"
```

If you must skip a secret manager, a plain `export` line in your profile works but leaves the value readable in that file; restrict its permissions and know the tradeoff.

A presence check is safe for anyone, including an agent, to run; it never prints the value:

```bash
VAR_NAME="GRAFANA_TOKEN"   # the *_env name from your config block
if [ -n "$(printenv "$VAR_NAME" || true)" ]; then echo "${VAR_NAME} set"; else echo "${VAR_NAME} NOT SET"; fi
# Expect: "GRAFANA_TOKEN set"
```

## Step 5: Propose the config blocks, then wait

Confirmation gate, no exceptions: before anything is written to `~/.scoutflo/toolkit.yaml`, assemble the exact YAML blocks with the real values from Step 2 (URLs, org slug, kube context, env var names, tiers), show them in full, and wait for explicit approval in the conversation. Only the approved blocks get written. Never write the file from inferred values, and never treat an earlier "set it up" as consent for specific blocks shown later.

- ❌ The user says "connect my Grafana", so the agent writes a `grafana:` block from a URL it found in shell history.
- ✅ The agent shows the assembled `grafana:` block with the URL the user stated, asks "write this to ~/.scoutflo/toolkit.yaml?", and writes only after a yes.

## Step 6: Write ~/.scoutflo/toolkit.yaml

Back up any existing config, then seed from the template shipped with this plugin. Fixed step: run as written.

```bash
CONFIG="$HOME/.scoutflo/toolkit.yaml"                             # toolkit config location
TEMPLATE="${CLAUDE_PLUGIN_ROOT}/templates/toolkit.yaml.example"   # template shipped with this plugin
mkdir -p "$HOME/.scoutflo"
if [ -f "$CONFIG" ]; then cp "$CONFIG" "${CONFIG}.bak.$(date -u +%Y%m%d%H%M%S)"; fi
if [ ! -f "$CONFIG" ]; then cp "$TEMPLATE" "$CONFIG"; fi
chmod 600 "$CONFIG"
ls -l "$CONFIG"
# Expect: the file exists with -rw------- permissions.
```

`${CLAUDE_PLUGIN_ROOT}` is set by the plugin runtime; running from a repo checkout instead, export it as the repo root first.

Then apply the approved blocks from Step 5:

- Fill in the approved values for every integration you set up. The per-provider blocks are shown in [references/providers.md](references/providers.md).
- Delete the blocks for integrations you do not run.
- On a re-run, touch only the blocks for the integrations you are adding or changing; leave the rest of the file alone.

Confirm the file parses:

```bash
CONFIG="$HOME/.scoutflo/toolkit.yaml"   # toolkit config location
if command -v yq >/dev/null 2>&1; then
  yq '. | keys | length' "$CONFIG" >/dev/null && echo "toolkit.yaml parses"
else
  echo "yq not installed; doctor falls back to a flat two-level parser"
fi
# Expect: "toolkit.yaml parses" (or the fallback note when yq is absent).
```

## Step 7: Verify with doctor

Doctor checks every configured block, verifies each `*_env` variable is set (presence only, values are never printed), makes one cheap read-only call per integration, and emits a connection matrix with fix hints:

```bash
OUT_DIR="./scoutflo-audits/doctor/$(date -u +%Y-%m-%d)"   # doctor run directory
sh "${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/doctor.sh" --out "${OUT_DIR}"
echo "doctor_exit=$?"
# Expect: doctor_exit=0. 1 = config missing, 2 = an env var is unset, 3 = a live check failed.
```

When doctor exits 0:

1. Run `/scoutflo:map-topology` to build your service map.
2. Run `/scoutflo:audit-all` (or a single audit such as `/scoutflo:audit-grafana`) for your first scored report.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Token pasted into `toolkit.yaml` or into the chat | Only `*_env` names go in the file; secrets are exported in your terminal via the silent-read prompt |
| An agent executes the secret-export prompt itself | Step 4 commands are user-run only; agents display them and run nothing that touches a secret value |
| Config written before the blocks were approved | Step 5 is a gate: propose the exact blocks, wait for an explicit yes in the conversation, then write |
| Sentry commands hit the wrong region and every call 404s | Set `sentry.host` explicitly; run the region probe in [references/providers.md](references/providers.md) before writing the config |
| One admin token reused for both tiers | Separate credentials named `scoutflo-audit` and `scoutflo-setup`; record each block's `tier:` and revoke the elevated one when setup work is done |
| Slack webhook URL treated as non-secret config | The URL is the credential; it goes in the env var named by `slack.webhook_env`, never in the file |
| Secrets exported in one terminal, doctor run in another | Env vars are per-shell; load them from your profile or re-export in the shell where you run skills |
| Audits pointed at an admin kube context | Use a read-only context bound to the `view` ClusterRole; name it in `kubernetes.context` |
| Mimir or VictoriaMetrics queries return empty because tenancy was skipped | Set `mimir.tenant_id` (or the VM tenant path) during connect, not mid-audit |
| Old config clobbered on re-run | Back up first with the timestamped copy in Step 6; edit blocks in place |
