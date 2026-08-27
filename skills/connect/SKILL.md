---
name: connect
description: Guided credential setup; creates minimal-scope tokens per tier for Grafana, Sentry, PagerDuty, Datadog, ELK/Kibana, JSM Operations, Zenduty, Groundcover, Prometheus, Loki, Tempo, Mimir, VictoriaMetrics, ClickStack (ClickHouse + HyperDX), SigNoz, DigitalOcean, GCP, Azure, AWS, Kubernetes, and Slack, and writes ~/.scoutflo/toolkit.yaml. Use when the user wants to connect or onboard the toolkit, add an integration, rotate a token, or set up credentials, including the audit-brief Slack webhook. Do not use for alert-delivery webhooks (Grafana contact points, Alertmanager receivers; use setup-grafana or setup-lgtm) or to verify reachability (use doctor).
---

# Connect: Credential and Config Setup

Connect sets up every credential the toolkit needs, at the smallest scope that works, and records the non-secret half in `~/.scoutflo/toolkit.yaml`. Run it when you install the toolkit, when you add an integration, when you rotate a token, or when you move from the read-only tier to the elevated tier.

Everything stays on your machine. Secrets go into environment variables you control. The config file holds only hosts, org names, and the names of those variables.

## Asking questions

Every question in this flow (which integrations, host, org slug, tier, tenant ID, anything) is a plain question in a normal chat message, answered in free text. Never drive a question through a structured multiple-choice or multi-select UI tool: some client environments cap the option count on those tools (a maximum of 4 has been observed) or require a minimum (2, in the same client) and reject the call outright if a question falls outside that range — a fixed list of integrations can exceed the maximum, and an inherently free-text field like an org slug or a custom URL has no natural set of 2+ options to offer, so wrapping it in one ("I'll type it") can fall below the minimum. A plain-text question has neither limit and works identically in every client this skill runs in.

## The human/agent boundary

Two hard rules for this whole flow:

- Never paste a token, webhook URL, or any secret into this conversation. `toolkit.yaml` never contains a secret either: every `*_env` key names an environment variable, and the value lives only in your environment.
- Any command that reads, exports, or prompts for a secret value is shown for you to run in your own terminal. An agent driving this skill displays those commands and never executes them; the agent's own commands are limited to non-secret work (creating directories, copying the template, parsing the config, running the presence-only env scan in Step 4a, the read-only name→ID discovery in Step 2a — `az account list`, `gcloud projects list`, and `aws sts get-caller-identity` / `aws iam list-account-aliases` / `aws organizations list-accounts` — and running doctor).
- For every credential a chosen integration needs, the agent must hand you an exact, copy-pasteable command to **set** the variable (the placeholder `export`/`$Env:` form for your OS in Step 4), not merely a command to read or display an existing token. First it runs the Step 4a presence scan and, for anything already set, asks whether to reuse it before asking you to set a new one.
- If a secret does get pasted into a conversation, treat it as exposed: revoke it in the provider UI, mint a fresh credential under the same name, and re-export. A rotated token costs a minute; an exposed one is permanent.

## Prerequisites

- `bash`, `curl`, `jq` on your PATH.
- `kubectl`, only if you connect a Kubernetes cluster.
- Admin access to each provider you connect (you create the tokens in their UIs).
- Write access to `~/.scoutflo/`.

Most integrations (Grafana, Prometheus, Loki, Tempo, Mimir, VictoriaMetrics, Sentry, Datadog, PagerDuty, ELK, JSM, Zenduty, Groundcover) are reached over HTTPS with a token, so they need only `curl` + `jq` — no vendor CLI. Only Kubernetes and AWS/GCP/Azure/DigitalOcean lean on a CLI. If you connect one of those and don't have its CLI yet (`doctor` will name exactly which is missing), install it first:

| CLI | Needed for | Install |
| --- | --- | --- |
| `kubectl` | Kubernetes | https://kubernetes.io/docs/tasks/tools/ — macOS: `brew install kubectl` |
| `aws` (v2) | AWS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html — macOS: `brew install awscli` |
| `gcloud` | GCP | https://cloud.google.com/sdk/docs/install — macOS: `brew install --cask google-cloud-sdk` |
| `az` | Azure | https://learn.microsoft.com/cli/azure/install-azure-cli — macOS: `brew install azure-cli`; for Entra-integrated AKS also `az aks install-cli` (kubelogin) |
| `doctl` | DigitalOcean | https://docs.digitalocean.com/reference/doctl/how-to/install/ |

**Already have MCP servers for these providers?** You still record hosts/tokens here the same way, and `doctor` still validates reachability. The toolkit uses **both** CLI/HTTP and MCP and picks per operation — reads go over the fast direct path, and a connected MCP tool is used when it is the equivalent read route (or the only reachable one), or for a write whose typed MCP tool is the safer path. You are never asked to choose, and a stack with only CLIs or only MCP servers both work. Read-only discipline and every safety rule are unchanged. See [docs/skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md#integration-access-per-operation-transport-selection-clihttp-and-mcp).

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

**Multiple targets of one integration (same environment).** If you run several instances of the same integration in one environment — e.g. 3 HyperDX instances, N Azure subscriptions, multiple AWS accounts or GCP projects — make that integration's block a **YAML list**, where each item is the normal mapping plus a required `label:` (a unique slug), each with its own `*_env` variable name for its own secret. The audit runs once per target and writes to `<integration>/<label>/<date>/`; a plain single block is unchanged and writes the flat `<integration>/<date>/`. See the worked example at the top of [templates/toolkit.yaml.example](../../templates/toolkit.yaml.example). For a *different* environment (prod vs staging) keep using a separate `toolkit-<env>.yaml` selected with `SCOUTFLO_CONFIG` — that is environment isolation, distinct from multiple targets in one environment.

Ask which integrations to configure as a plain numbered list in a normal chat message, per the "Asking questions" rule above — this table has many rows, well past the option ceiling that rule warns about.

| Integration | Used by | Config block | Suggested env var | Tier summary |
| --- | --- | --- | --- | --- |
| Grafana | audit-grafana, setup-grafana, audit-lgtm, audit-alert-routing | `grafana:` | `GRAFANA_TOKEN` | Viewer for audits; Editor or Admin for setup |
| Sentry | audit-sentry, setup-sentry | `sentry:` | `SENTRY_TOKEN` | read scopes for audits; write scopes for setup |
| PagerDuty | audit-pagerduty | `pagerduty:` | `PAGERDUTY_TOKEN` | read-only REST key for audits |
| Datadog | audit-datadog | `datadog:` | `DATADOG_API_KEY` + `DATADOG_APP_KEY` | scoped read-only app key for audits |
| Cost (cross-provider) | audit-cost | (reuses `aws:`, `gcp:`, `azure:`, `datadog:`, `digitalocean:`, `kubernetes:` blocks) | none of its own | reuses each provider's read creds; add the optional cost scope per provider (AWS Compute Optimizer/Cost Explorer read; GCP Recommender viewer; Azure `Cost Management Reader` + Advisor via `Reader`; Datadog `usage_read`) to get provider-native dollar figures |
| ELK / Kibana | audit-elk | `elk:` | `KIBANA_API_KEY` | read-only Kibana **feature** privileges (Stack Rules, Rules Settings, Actions & Connectors) at `spaces:["*"]` — not ES cluster/index privileges; the audit auto-discovers spaces. Minting via `POST /_security/api_key`? Use the `role_descriptors` recipe in [references/providers.md](references/providers.md#or-mint-it-directly-via-the-elasticsearch-api-curl) |
| JSM Operations | audit-jsm | `jsm:` | `JSM_EMAIL` + `JSM_API_TOKEN` | Atlassian API token over Basic auth; read-only by GET-only use |
| Zenduty | audit-zenduty | `zenduty:` | `ZENDUTY_TOKEN` | `Authorization: Token` API key; Bot Token (Beta) for least privilege, read-only by GET-only use |
| Groundcover | audit-groundcover | `groundcover:` | `GROUNDCOVER_API_KEY` | service-account API key on a Viewer role = true read-only tier |
| Prometheus + Alertmanager | audit-lgtm, setup-lgtm, audit-alert-routing | `prometheus:` | `PROM_TOKEN` (only if your endpoints require auth) | URL reachability; optional bearer |
| ClickStack (ClickHouse + HyperDX) | audit-clickstack, setup-clickstack | `clickstack:` | `CH_KEY` (ClickHouse read-only user password) + `HDX_API_KEY` (HyperDX **Personal API Access Key**, not the ingestion key) | ClickHouse: a read-only user with `SELECT` on the telemetry db + `system.*`; HyperDX: the per-user Personal API Access Key (Settings → API Keys) that reads the external API v2 (`GET /api/v2/alerts`, `/api/v2/dashboards`, `/api/v2/sources`) via `Authorization: Bearer` |
| SigNoz (ClickHouse-backed) | audit-signoz | `signoz:` | `SIGNOZ_API_KEY` (Service Account token assigned the read-only `signoz-viewer` role) + optional `SIGNOZ_CH_KEY` (ClickHouse read-only user password) | A `signoz-viewer`-role service-account token (Settings → Service Accounts → Roles) that can `GET /api/v1/rules`, `/api/v1/channels`, `/api/v2/dashboards` and `POST /api/v3/query_range`; optionally a read-only ClickHouse user with `SELECT` on `signoz_*` + `system.*` for the deep backend lane |
| Loki | audit-lgtm, setup-lgtm | `loki:` | `LOKI_TOKEN` (optional) | URL; optional tenant and token |
| Tempo | audit-lgtm, setup-lgtm | `tempo:` | `TEMPO_TOKEN` (optional) | URL; optional tenant and token |
| Mimir | audit-lgtm, setup-lgtm | `mimir:` | `MIMIR_TOKEN` (optional) | URL; `tenant_id` when multi-tenant |
| VictoriaMetrics | audit-lgtm, setup-lgtm | `victoriametrics:` | `VM_TOKEN` (optional) | URL; `vmalert_url` when you run vmalert |
| DigitalOcean | audit-digitalocean, setup-digitalocean | `digitalocean:` | `DIGITALOCEAN_ACCESS_TOKEN` | read-only token; `doctl` honors it natively |
| GCP | audit-gcp, setup-gcp | `gcp:` | none (gcloud login) or `GOOGLE_APPLICATION_CREDENTIALS` | `project` in config; `gcloud` identity or a service-account key file, `monitoring.viewer` for audits |
| Azure | audit-azure, setup-azure | `azure:` | none (`az login`) or a service principal | `subscription_id` in config; `az` identity, `Monitoring Reader`+`Reader` for audits; setup that grants RBAC also needs `User Access Administrator`/Owner (Contributor alone cannot create role assignments) |
| AWS | audit-aws, setup-aws | `aws:` | none (credential chain) or `AWS_ROLE_ARN` | `account_id`+`region` in config; active credential chain or assumed role, read-only policy for audits |
| Kubernetes | map-topology, audit-kubernetes, audit-lgtm, setup-lgtm | `kubernetes:` | none (kubeconfig context) | read-only context for audits |
| GitHub | map-repos | `github:` | `GITHUB_TOKEN` | fine-grained PAT with Contents:Read + Metadata:Read, or classic `repo` read on private repos |
| Slack | the per-run brief from every audit skill | `slack:` | `SCOUTFLO_SLACK_WEBHOOK` | the webhook URL is itself the secret |

## Step 2: Gather the configuration

Judgment step: collect the non-secret facts for every integration you picked before creating any credential. Missing facts surface here, not halfway through a provider UI.

| Integration | Required keys | Example |
| --- | --- | --- |
| Grafana | `grafana.url`, `grafana.token_env`, `grafana.tier` | `url: https://grafana.example.com` |
| Sentry | `sentry.host`, `sentry.org`, `sentry.token_env`, `sentry.tier` | `host: us.sentry.io` |
| PagerDuty | `pagerduty.token_env`, `pagerduty.tier`; optional `region` | `region: us` |
| Datadog | `datadog.site`, `datadog.api_key_env`, `datadog.app_key_env`, `datadog.tier` | `site: datadoghq.com` |
| ELK / Kibana | `elk.kibana_url`, `elk.token_env`, `elk.tier`; optional `spaces` | `kibana_url: https://kibana.example.com` |
| JSM Operations | `jsm.site`, `jsm.email_env`, `jsm.token_env`, `jsm.tier`; optional `cloud_id`, `teams` | `site: your-site.atlassian.net` |
| Zenduty | `zenduty.token_env`, `zenduty.tier`; optional `teams` | `token_env: ZENDUTY_TOKEN` |
| Groundcover | `groundcover.token_env`, `groundcover.tier`; optional `backend_id`, `api_url` | `token_env: GROUNDCOVER_API_KEY` |
| Prometheus + Alertmanager | `prometheus.url`, `prometheus.alertmanager_url`; add `token_env` and `tier` only behind an auth proxy | `url: https://prometheus.example.com` |
| ClickStack | `clickstack.clickhouse_url` / `clickstack.clickhouse_user` / `clickstack.clickhouse_password_env` **optional (ClickHouse lane)**; `clickstack.hyperdx_url` / `clickstack.hyperdx_api_key_env` **optional (HyperDX lane)** — configure at least one lane; a HyperDX-only or ClickHouse-only ClickStack config is valid and the audit scores the lane you have | `clickhouse_url: https://your-clickhouse-host:8123` |
| SigNoz | `signoz.url`, `signoz.api_key_env`, and optional `signoz.clickhouse_url`, `signoz.clickhouse_user`, `signoz.clickhouse_password_env` | `url: https://your-signoz-host` |
| Loki | `loki.url`; optional `token_env` and `tier` | `url: https://loki.example.com` |
| Tempo | `tempo.url`; optional `token_env` and `tier` | `url: https://tempo.example.com` |
| Mimir | `mimir.url`; optional `tenant_id`, `token_env`, `tier` | `tenant_id: your-tenant` |
| VictoriaMetrics | `victoriametrics.url`; optional `vmalert_url`, `token_env`, `tier` | `vmalert_url: https://vmalert.example.com` |
| GCP | `gcp.project`, `gcp.tier`; optional `credentials_env` | resolve `project` in Step 2a / the recipe in [references/providers.md](references/providers.md#google-cloud-gcp) — never hand-type it |
| Azure | `azure.subscription_id`, `azure.tier`; optional `tenant_id` | resolve `subscription_id` (+`tenant_id`) in Step 2a / the recipe in [references/providers.md](references/providers.md#azure) |
| AWS | `aws.account_id` (quoted), `aws.region`, `aws.tier`; optional `profile`, `role_env` | resolve `account_id` in Step 2a / the recipe in [references/providers.md](references/providers.md#aws) |
| Kubernetes | `kubernetes.context`; optional `monitoring_namespace` | `context: your-kube-context` |
| GitHub | `github.org`, `github.token_env`; optional `tier` | `org: your-org` |
| Slack | `slack.webhook_env` | `webhook_env: SCOUTFLO_SLACK_WEBHOOK` |

**Multiple targets of one integration (same environment).** If Step 1 identified more than one instance of the same integration in one environment (e.g. two HyperDX instances, N Azure subscriptions), gather the facts *per target*: a unique `label:` slug (lowercase letters/digits/hyphens, unique within that block) **and a distinct `*_env` variable name for each target's own secret**, alongside that target's own host/URL/ID. Two HyperDX instances, for example, each get their own `hyperdx_url` and their own `hyperdx_api_key_env` (say `HDX_EU_KEY` and `HDX_US_KEY`) so no target ever reads another's credential. Every other key in each target's mapping is the same set the table above lists for the single-block form; you are only repeating the mapping once per target and adding the `label:`. These get assembled into a YAML list in Steps 5–6.

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

## Step 2a: Resolve names to IDs (agent-run, read-only)

The cloud providers are keyed by an **ID**, not a name: `azure` needs `subscription_id` (a GUID), `gcp` needs `project` (the project ID, not the display name), `aws` needs a quoted 12-digit `account_id`. You think of them as "Production" or "Engineering Operations"; the config needs the identifier behind that name. Guessing or hand-typing a GUID is exactly how a run ends up auditing the wrong estate — a transposed subscription id is unmemorable and passes every YAML check.

So for each cloud provider you picked, the agent runs a **read-only discovery** first (this is on the non-secret, agent-runnable side of the boundary rule — it lists identifiers, never touches a credential value), then resolves each name to its ID before any credential work. Run only the block(s) for the providers you picked:

```bash
# Azure — every subscription this `az login` can see, with tenant + state.
az account list --query "[].{name:name, id:id, tenantId:tenantId, state:state}" -o table
```

```bash
# GCP — every project this `gcloud` login can see.
gcloud projects list --format="table(projectId, name, projectNumber)"
```

```bash
# AWS — the active identity first; then, IF this is an Organizations management/delegated
# account, every member account (the list call is harmless — `|| true` — where it is denied).
aws sts get-caller-identity --output json
aws iam list-account-aliases --output json 2>/dev/null || true
aws organizations list-accounts --query "Accounts[].{name:Name, id:Id, status:Status}" --output table 2>/dev/null || true
```

From that output the agent builds a plain-text **resolution table** — one row per visible target, `<name you use> -> <resolved id>[+ tenant] (<state>)` — and shows **every** subscription/project/account the login can see, not only the ones you mentioned:

```
name (as you call it)    ->  resolved id                    [+ tenant]         (state)     selection
Production               ->  <prod-subscription-guid>       tenant <guid>      Enabled     [selected]
Engineering Operations   ->  <other-subscription-guid>      tenant <guid>      Enabled     [NOT selected]
```

Then the agent asks which targets to audit and, before moving on, **names every visible-but-unselected target back to you** — "you did not pick *Engineering Operations*; skip it, or add it?" — so a real account is a deliberate exclusion, never a silent omission (that near-miss is why this step exists). Each target you select becomes one entry: a single target fills the provider's `subscription_id`/`project`/`account_id` directly; several targets of one provider in one environment become a **labeled YAML list** (Steps 5–6), each list item carrying a unique `label:` slug plus its resolved ID. Keep the finished `name -> id` mapping — Step 5 makes you confirm it and Step 6 checks that every name you selected here ended up written.

## Step 3: Create each credential

Work through the matching section of [references/providers.md](references/providers.md) for every integration you picked. Each section gives you:

- the exact click path in the provider UI,
- the minimal scopes for the read-only tier and for the elevated tier,
- the `toolkit.yaml` block and env var to set,
- a one-line verification command to run immediately after creating the credential.

Create read-only credentials now, named `scoutflo-audit` per the naming rule. Create elevated ones later, named `scoutflo-setup`, when a `setup-*` skill asks for them.

**Run each provider's verify command the moment you export that credential — before starting the next integration, not after all of them.** Across the many possible integrations, a wrong host, wrong scope, or mistyped org slug is far cheaper to catch and fix one provider at a time than to debug from a single `doctor` run at the very end of Step 7, where several small mistakes can compound into one confusing failure list. Step 7's `doctor` pass is the final confirmation that everything is wired together, not the first time any of it gets checked.

## Step 4: Set the secrets (you run these, not the agent)

The commands in this step read secret values, so they are yours to run in your own terminal. An agent shows them and never executes them; the value never enters the conversation. **The agent's job here is to hand you an exact, copy-pasteable command for every variable you need to set — never just a "show the token" command.**

**"I made the token — now what do I do with it?"** The token *value* does **not** go into `toolkit.yaml`. That file only records the **name** of the environment variable (`token_env: KIBANA_API_KEY`); the value lives separately, in your environment, under that exact name. So "add my token" means: put the value in the home-anchored secret store `~/.scoutflo/env` keyed by that `*_env` name (Step 4c) — one line, once — and every skill reads it from there at run time by matching the name. You do not paste the token into chat, into `toolkit.yaml`, or into any skill. Three moving parts: (1) `toolkit.yaml` names the var, (2) `~/.scoutflo/env` holds the value, (3) the audit reads the value by that name. Get the value into `~/.scoutflo/env` and you are done — `doctor` and every audit source that file, so a token added there is picked up in the same session without opening a new terminal.

### 4a. First, reuse what's already there

Before asking you to create or paste anything, the agent runs this **presence-only scan** (it prints variable names and whether they are set, never any value) to find credentials you may already have exported for these systems:

```bash
# Safe for the agent to run: prints names + set/unset only, never a value.
# Load the global store first so a credential set in a PRIOR session/terminal counts as set.
[ -f ~/.scoutflo/env ] && . ~/.scoutflo/env
for V in GRAFANA_TOKEN PROM_TOKEN LOKI_TOKEN TEMPO_TOKEN MIMIR_TOKEN VM_TOKEN \
         DATADOG_API_KEY DATADOG_APP_KEY SENTRY_TOKEN PAGERDUTY_TOKEN \
         KIBANA_API_KEY JSM_EMAIL JSM_API_TOKEN ZENDUTY_TOKEN GROUNDCOVER_API_KEY \
         CH_KEY HDX_API_KEY SIGNOZ_API_KEY SIGNOZ_CH_KEY \
         DIGITALOCEAN_ACCESS_TOKEN GITHUB_TOKEN AWS_ROLE_ARN GOOGLE_APPLICATION_CREDENTIALS \
         SCOUTFLO_SLACK_WEBHOOK; do
  if [ -n "$(printenv "$V" 2>/dev/null || true)" ]; then echo "$V = already set"; else echo "$V = not set"; fi
done
```

For each variable that comes back **already set**, the agent asks you plainly: *"`GRAFANA_TOKEN` is already set in your environment — reuse it for this audit, or set a fresh read-only one?"* Reusing an existing read-only token is fine; the only reason to set a new one is if the existing token has more scope than an audit needs (see the tier rule above — audits want read-only) or belongs to a different account than the one you are auditing. The agent never reads the value to decide; it asks you.

### 4b. For anything not already set (or that you chose to replace), set it now

Pick the block for your OS. Replace the placeholder with the token you created in Step 3; the value never goes into the chat.

**macOS / Linux (bash/zsh) — this shell session:**

```bash
# YOU run this in your own terminal. One line per variable you need.
export GRAFANA_TOKEN="<paste-your-grafana-token-here>"
```

**Windows — PowerShell (this session):**

```powershell
# YOU run this in PowerShell. One line per variable.
$Env:GRAFANA_TOKEN = "<paste-your-grafana-token-here>"
```

**Windows — Git Bash** (the shell the plugin's skills actually run in on Windows): use the macOS/Linux `export` form above, in the Git Bash window.

A bare `export`/`$Env:` sets the value **only in the shell you type it in**. The plugin's skills run in their *own* process and read every secret from the home-anchored store `~/.scoutflo/env` (Step 4a sources it, and so do `doctor` and every audit) — so a plain `export` in your terminal is **invisible to the plugin**. The forms above are for running a provider's Step 3 verify command right now, in the same shell; for anything the toolkit must see later, use the one-line store-writer `scoutflo_addsecret` in Step 4c, which both records the value in `~/.scoutflo/env` **and** exports it into your current shell. Prefer it especially for any value you paste (a long HyperDX key, a webhook URL): it takes the variable **name as a fixed argument** and reads the value with a single silent `read`, so a wrapped paste can never split the name in two (`HDX_EU_KEY` arriving as `HDX_E U_KEY`), leave the token in your shell history, or double an `=`.

Swap `GRAFANA_TOKEN` for the exact `*_env` name of whatever you are setting (`DATADOG_API_KEY`, `PROM_TOKEN`, `PAGERDUTY_TOKEN`, …). Datadog needs two (`DATADOG_API_KEY` and `DATADOG_APP_KEY`); JSM needs `JSM_EMAIL` plus `JSM_API_TOKEN`.

### 4c. Set it ONCE, globally — so you are never asked again

A plain `export` lives only in the current shell, so it vanishes when you open a new terminal, start a new session, or `cd` elsewhere — and then `connect`/`doctor` would ask for the token again. **The fix is a single home-anchored secret file, `~/.scoutflo/env`, that your shell loads at startup.** Set a credential there once and every future session, terminal, and directory already has it. This is the recommended path; do it once and you are done. (Every skill resolves the store as `$SCOUTFLO_ENV_FILE` → `./.scoutflo/env` → `~/.scoutflo/env`, first hit wins — so on a sandboxed surface where `$HOME` is not shell-writable, the write ladder above can fall back to a project-local `./.scoutflo/env` and everything still works; keep `.scoutflo/` git-ignored in that mode.)

**macOS / Linux / Git Bash — one-time setup, then one line per credential:**

```bash
# 1) Create the file (once), locked to you:
mkdir -p ~/.scoutflo && touch ~/.scoutflo/env && chmod 600 ~/.scoutflo/env

# 2) Load it from your shell profile (once). Adds a source line if not already there:
grep -q 'scoutflo/env' ~/.zshrc 2>/dev/null || echo '[ -f ~/.scoutflo/env ] && . ~/.scoutflo/env' >> ~/.zshrc
# bash users: same line into ~/.bashrc instead of ~/.zshrc.

# 3) Define the store-writer ONCE per shell (paste this block; add it to your profile to
#    keep it). It takes the variable NAME as its argument and prompts silently for the value:
scoutflo_addsecret() {
  _n="$1"; [ -n "$_n" ] || { echo "usage: scoutflo_addsecret VARNAME" >&2; return 2; }
  mkdir -p ~/.scoutflo && touch ~/.scoutflo/env && chmod 600 ~/.scoutflo/env
  printf '%s: ' "$_n" >&2; stty -echo 2>/dev/null; IFS= read -r _v; stty echo 2>/dev/null; printf '\n' >&2
  _e=$(printf '%s' "$_v" | sed "s/'/'\\''/g")
  grep -v "^export ${_n}=" ~/.scoutflo/env > ~/.scoutflo/env.$$ 2>/dev/null || :
  printf "export %s='%s'\n" "$_n" "$_e" >> ~/.scoutflo/env.$$
  mv ~/.scoutflo/env.$$ ~/.scoutflo/env && chmod 600 ~/.scoutflo/env
  export "$_n=$_v"; unset _v _e; echo "$_n written to ~/.scoutflo/env and exported here" >&2
}

# 4) Add each credential by NAME (one call per variable). It prompts silently — paste the
#    value at the prompt and press Enter; nothing echoes and nothing lands in shell history:
scoutflo_addsecret GRAFANA_TOKEN
```

Why this is the safe path and not a hand-typed `echo … >> env`: the **name is a fixed argument**, so a wrapped paste can never turn `HDX_EU_KEY` into `HDX_E U_KEY` and there is no keyboard path to an `export VAR==` typo; the value is read once, silently, and never enters shell history; it is single-quote-escaped before storage, so a `$`, `"`, or backtick in a token is stored literally; a re-run **replaces** that variable's line rather than appending a duplicate; the file stays `chmod 600`; and it `export`s the value into your current shell too, so a provider's Step 3 verify command works in the same terminal without opening a new one. Swap `GRAFANA_TOKEN` for the exact `*_env` name you are setting.

**Windows — PowerShell — one-time, persists for your user across all new terminals:**

```powershell
setx GRAFANA_TOKEN "<paste-your-grafana-token-here>"
# setx writes to the user environment; it affects NEW terminals, so reopen PowerShell after.
```

Because `~/.scoutflo/env` is in your home directory (not tied to any project folder), it is the same store the scheduled-runs path uses — so interactive runs, new terminals, and cron all read one place. `doctor` sources `~/.scoutflo/env` before checking, so once a credential is in it, no skill asks you to set it again.

### 4d. Confirm it's set (safe for anyone, prints no value)

```bash
VAR_NAME="GRAFANA_TOKEN"   # the *_env name from your config block
if [ -n "$(printenv "$VAR_NAME" || true)" ]; then echo "${VAR_NAME} set"; else echo "${VAR_NAME} NOT SET"; fi
# Expect: "GRAFANA_TOKEN set"
```

Run each provider's verify command (Step 3 / `references/providers.md`) right after you set its variable, so a wrong scope or host is caught one provider at a time rather than piling up for the Step 7 `doctor` run.

## Step 5: Propose the config blocks, then wait

Confirmation gate, no exceptions: before anything is written to `~/.scoutflo/toolkit.yaml`, assemble the exact YAML blocks with the real values from Step 2 (URLs, org slug, kube context, env var names, tiers), show them in full, and wait for explicit approval in the conversation. Only the approved blocks get written. Never write the file from inferred values, and never treat an earlier "set it up" as consent for specific blocks shown later.

- ❌ The user says "connect my Grafana", so the agent writes a `grafana:` block from a URL it found in shell history.
- ✅ The agent shows the assembled `grafana:` block with the URL the user stated, asks "write this to ~/.scoutflo/toolkit.yaml?", and writes only after a yes.
- **For any cloud provider resolved in Step 2a, confirm the mapping before the YAML.** First echo the `name -> resolved id [+ tenant]` table (`Production -> <subscription-guid>`, one row per selected target) as plain text and get an explicit "yes, that pairing is right". You are confirming the **mapping**, not eyeballing a GUID: a subscription/project/account id is unmemorable, so the operator can only vouch that the *name* beside it is the estate they mean — show the name against every id and approve the pairing, then show the YAML those ids go into.
- When Step 1 named more than one instance of an integration in one environment, the block you assemble here is a **YAML list**: one list item per target, each the provider's normal mapping plus its unique `label:` and its own `*_env` name. Show the full list and wait for approval the same way — no target is written until the whole list is approved.

## Step 6: Write ~/.scoutflo/toolkit.yaml

Back up any existing config, then seed from the template shipped with this plugin. Fixed step: run as written.

```bash
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"                             # toolkit config location
TEMPLATE="${CLAUDE_PLUGIN_ROOT}/templates/toolkit.yaml.example"   # template shipped with this plugin
# WRITE PROBE: on sandboxed surfaces (the Claude Desktop app) shell writes to $HOME are
# denied by the OS sandbox even though the CLI allows them. Probe once and pick the mode.
if mkdir -p "$HOME/.scoutflo" 2>/dev/null && touch "$HOME/.scoutflo/.write-probe" 2>/dev/null; then
  rm -f "$HOME/.scoutflo/.write-probe"; echo "config home: $HOME/.scoutflo (shell-writable)"
else
  echo "SANDBOXED SURFACE: shell cannot write $HOME/.scoutflo — see the write ladder below this block"
fi
if [ -f "$CONFIG" ]; then cp "$CONFIG" "${CONFIG}.bak.$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || true; fi
if [ ! -f "$CONFIG" ]; then cp "$TEMPLATE" "$CONFIG" 2>/dev/null || echo "shell copy denied — use the write ladder below"; fi
chmod 600 "$CONFIG" 2>/dev/null || true
ls -l "$CONFIG" 2>/dev/null || true
# Expect: the file exists (ideally -rw-------). chmod failing on a sandboxed surface is
# tolerable for toolkit.yaml (it holds no secret values, only variable NAMES).
```

`${CLAUDE_PLUGIN_ROOT}` is set by the plugin runtime; running from a repo checkout instead, export it as the repo root first.

**The write ladder (when the probe reports a sandboxed surface).** The plugin must work on every surface, so config writing degrades in exactly this order — never give up at rung 1:

1. **Shell write to `$HOME/.scoutflo`** (the block above) — works in the CLI; denied by the Desktop app's OS sandbox.
2. **File-writing tool to `$HOME/.scoutflo/toolkit.yaml`** — when the shell write is denied, write the file with the file-Write tool instead of shell redirection: it goes through the app's permission prompt (the user approves once), not the OS sandbox. Verify by reading the file back. Never compose config with `cat >`/`>>` on a sandboxed surface.
3. **Project-local mode: `./.scoutflo/toolkit.yaml`** — when even the file tool is denied, write inside the working directory (always writable). Every skill resolves config in the order `$SCOUTFLO_CONFIG` → `./.scoutflo/toolkit.yaml` → the `~/.scoutflo/active-config` pointer → `$HOME/.scoutflo/toolkit.yaml`, so project-local config is picked up automatically with zero extra setup. **Mandatory companion step:** immediately ensure `.scoutflo/` is git-ignored — `grep -qx '.scoutflo/' .gitignore 2>/dev/null || printf '.scoutflo/\n' >> .gitignore` — and tell the user this config is per-project, not global.

The same ladder applies to the secret store `env` file (Step 4c): shell append → file tool → project-local `./.scoutflo/env` with the same `.gitignore` guard. When `chmod 600` is denied by the sandbox, give the user the exact one-liner to run in their own terminal (`chmod 600 ~/.scoutflo/env` — their shell is never sandboxed); never leave a secret file with open permissions silently.

If the user asks to keep the config inside their project folder instead of `~/.scoutflo/`, explain the trade-off rather than refusing: home-anchoring is what makes credentials work from every folder and session without re-entry, and reports already live in their project folder (`./scoutflo-audits/`). If they still want it relocated (isolated estates, shared-machine policy), set it up with `export SCOUTFLO_CONFIG="<their-path>/toolkit.yaml"` persisted the same way as Step 4c — every skill honors that override.

**Multiple environments (prod + nonprod), the recommended shape.** A team auditing more than one estate keeps a **named config per environment** — `~/.scoutflo/toolkit-prod.yaml`, `~/.scoutflo/toolkit-nonprod.yaml` — instead of one `toolkit.yaml`, and selects one per run with `export SCOUTFLO_CONFIG=~/.scoutflo/toolkit-<env>.yaml`. This is a first-class pattern: when a skill finds no default `toolkit.yaml` but sees `toolkit-*.yaml` variants, its doctor gate **lists them and asks which environment** rather than stalling — and it **never auto-picks** one, because auditing prod when you meant staging (or vice-versa) is worse than a one-line question. When you set up multiple environments here, write each `toolkit-<env>.yaml` (same structure, environment-specific `kubernetes.context` / account / URLs), then **write the pointer to the environment new terminals should default to** — `printf '%s\n' "$HOME/.scoutflo/toolkit-nonprod.yaml" > "$HOME/.scoutflo/active-config"` (nonprod is the safer default) — so a fresh session resolves that environment without re-exporting. A one-off `export SCOUTFLO_CONFIG=~/.scoutflo/toolkit-prod.yaml` overrides the pointer for a single prod run; this is what keeps "audit prod when you meant staging" from ever happening by accident. `/scoutflo:audit-cost` and `/scoutflo:audit-all` can also ask which environment to cover when both configs are present.

Then apply the approved blocks from Step 5:

- Fill in the approved values for every integration you set up. The per-provider blocks are shown in [references/providers.md](references/providers.md).
- Delete the blocks for integrations you do not run. Deleting them is correct, not destructive: a leftover placeholder block (for example `grafana.example.com`) makes doctor probe a fake host and fail with noise, and the shape of every deleted block stays available in this plugin's template and in providers.md.
- On a re-run, touch only the blocks for the integrations you are adding or changing; leave the rest of the file alone.
- **Re-adding an integration that was deleted earlier:** copy its block verbatim from the provider's **Config** section in [references/providers.md](references/providers.md) (or from `${CLAUDE_PLUGIN_ROOT}/templates/toolkit.yaml.example`), then fill in the approved values. Never reconstruct a block's keys from memory — key names like `token_env` vs `api_key_env`+`app_key_env` (Datadog), `kibana_url` (ELK, not the Elasticsearch URL), `account_id` quoted (AWS), or `context` (Kubernetes) differ per provider, and an invented key silently reads as "not configured" to doctor and every audit.
- **Multiple targets of one integration in one environment:** assemble the block as a **YAML list** — one item per target, each item the provider's normal mapping plus a unique `label:` slug and its own `*_env` variable name. Copy the labeled-list shape verbatim from that provider's **Config** section in [references/providers.md](references/providers.md) (or the worked example at the top of `${CLAUDE_PLUGIN_ROOT}/templates/toolkit.yaml.example`); the same "never reconstruct the keys from memory" rule applies to the list form. The audit runs once per target and writes to `<integration>/<label>/<date>/`; a single target stays a plain mapping and writes the flat `<integration>/<date>/`.

Confirm the file parses:

```bash
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"   # toolkit config location
if command -v yq >/dev/null 2>&1; then
  yq '. | keys | length' "$CONFIG" >/dev/null && echo "toolkit.yaml parses"
else
  echo "yq not installed; doctor falls back to a flat two-level parser"
fi
# Expect: "toolkit.yaml parses" (or the fallback note when yq is absent).
```

**Persist which config is active (so a new terminal just works).** The single most common support issue is a `SCOUTFLO_CONFIG` export that lived only in the old shell: the next terminal reports it "can't find the config" even though the file is right there. Writing a one-line pointer fixes it permanently — every skill resolves this pointer as a tier, so a new session, terminal, or directory finds the same config without re-exporting or re-running `connect`.

```bash
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
printf '%s\n' "$CONFIG" > "$HOME/.scoutflo/active-config" 2>/dev/null \
  && echo "active config remembered — new terminals will use: $CONFIG" \
  || echo "(could not persist the pointer; set SCOUTFLO_CONFIG per session — see the write ladder)"
```

A one-off `export SCOUTFLO_CONFIG=<other>` still overrides this pointer for a single run, and re-running `connect` changes the remembered default. In the **multiple-environments** case below, point it at the environment new terminals should default to — never leave the default ambiguous.

**Completeness check — every target you named in Step 1 is actually written.** A dropped list item (a paste that lost a target, a slug typo) leaves the config parsing fine while silently auditing fewer estates than you meant. So for each integration you configured, enumerate the written targets with the shared enumerator and reconcile the count and the names against Step 1 — this stays inline, no new library. Run it once per integration you wrote, filling `BLOCK` / `EXPECT_N` / `EXPECT_LABELS` from Step 1 (for a single target the written label is the block name; for a labeled list they are the slugs you assigned in Step 2a):

```bash
CONFIG="${SCOUTFLO_CONFIG:-}"
[ -n "$CONFIG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CONFIG="$_c"; break; }; done
[ -n "$CONFIG" ] || CONFIG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"   # the shared target enumerator
BLOCK="azure"                                    # the block you just wrote
EXPECT_N="2"                                     # how many targets you named for it in Step 1
EXPECT_LABELS="production engineering-operations" # each selected target's label (block name if single)
WRITTEN_N="$(sh "$TT" "$CONFIG" "$BLOCK" count)"
echo "written labels for ${BLOCK}:"; sh "$TT" "$CONFIG" "$BLOCK" labels
if [ "$WRITTEN_N" = "$EXPECT_N" ]; then echo "COUNT OK: ${BLOCK} wrote ${WRITTEN_N} target(s), matching the ${EXPECT_N} named in Step 1"; else echo "COUNT MISMATCH: ${BLOCK} wrote ${WRITTEN_N} target(s) but Step 1 named ${EXPECT_N} — a stated target is missing"; fi
WRITTEN_LABELS="$(sh "$TT" "$CONFIG" "$BLOCK" labels)"
for _name in $EXPECT_LABELS; do
  if printf '%s\n' "$WRITTEN_LABELS" | grep -qxF "$_name"; then echo "  ok: '${_name}' -> written"; else echo "  MISSING: '${_name}' was named in Step 1 but has no written target in ${BLOCK}"; fi
done
# Expect: COUNT OK and every name "ok". Any COUNT MISMATCH or MISSING line names a target
# you meant to audit that did not make it into the file — fix the block and re-run this check.
```

## Step 7: Verify with doctor

Doctor checks every configured block, verifies each `*_env` variable is set (presence only, values are never printed), makes one cheap read-only call per integration, and emits a connection matrix with fix hints:

```bash
OUT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/doctor/$(date -u +%Y-%m-%d)"   # doctor run directory
sh "${CLAUDE_PLUGIN_ROOT}/skills/doctor/scripts/doctor.sh" --out "${OUT_DIR}"
echo "doctor_exit=$?"
# Expect: doctor_exit=0. 1 = config missing, 2 = an env var is unset, 3 = a live check failed.
```

When doctor exits 0:

1. If you connected Kubernetes, run `/scoutflo:map-topology` to build your service map (it needs `kubectl` and a `kubernetes.context`; skip this step if you don't run Kubernetes).
2. Run `/scoutflo:audit-all` (or a single audit such as `/scoutflo:audit-grafana`) for your first scored report.

On any other exit: fix the failing rows using the hint column (exit 1: config missing — rerun this skill; exit 2: export the named variable per Step 4; exit 3: recheck that provider's host and token per Step 3), then rerun `/scoutflo:doctor`.

## Step 8: Offer to capture business context (optional but recommended)

Credentials tell the toolkit *how* to reach your stack; business context tells it
*what matters* — SLAs per service, which environment uses which profile/cluster
and its SLA, critical services that gate on approval, regions/accounts to never
touch, cost priorities, and your own custom rules and runbooks. Without it,
audits run with neutral defaults (everything production-severity, no exclusions).

Offer it, don't force it:

> Optionally set your SRE guardrails now so every audit is tuned to your business.
> Run `/scoutflo:business-context` to capture them interactively (guided questions,
> paste your own rules, or import an existing file). It writes
> `~/.scoutflo/business_context.md` — the one place your rules live, which every
> audit and setup reads. You can also skip this and add it any time later.

Do not write `business_context.md` from this skill; `/scoutflo:business-context`
owns that file and its rich capture flow.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Token pasted into `toolkit.yaml` or into the chat | Only `*_env` names go in the file; secrets are set in your terminal via the Step 4 `export`/`$Env:` command |
| Agent shows only a "read/show token" command, not how to set one | Step 4 requires an exact copy-pasteable **set** command (placeholder `export`/`$Env:` for the user's OS) for every needed variable — never just a display command |
| User on Windows given only a bash `export` | Step 4 gives PowerShell (`$Env:`/`setx`) and Git Bash forms alongside macOS/Linux |
| A credential the user already has gets asked for again | Step 4a runs the presence-only scan first and offers to reuse any matching var that is already set |
| An agent executes the secret-export prompt itself | Step 4 commands are user-run only; agents display them and run nothing that touches a secret value |
| Config written before the blocks were approved | Step 5 is a gate: propose the exact blocks, wait for an explicit yes in the conversation, then write |
| Sentry commands hit the wrong region and every call 404s | Set `sentry.host` explicitly; run the region probe in [references/providers.md](references/providers.md) before writing the config |
| One admin token reused for both tiers | Separate credentials named `scoutflo-audit` and `scoutflo-setup`; record each block's `tier:` and revoke the elevated one when setup work is done |
| Slack webhook URL treated as non-secret config | The URL is the credential; it goes in the env var named by `slack.webhook_env`, never in the file |
| Secrets exported in one terminal, doctor run in another (or invisible to the plugin) | A bare `export` lives only in that shell and the plugin reads its own process; write the value to `~/.scoutflo/env` with `scoutflo_addsecret <VAR>` (Step 4c) so every session, terminal, and the plugin pick it up |
| A pasted key wraps and the name splits (`HDX_E U_KEY`) or an `export VAR==` typo slips in | Use `scoutflo_addsecret <VAR>` (Step 4c): the name is a fixed argument and the value is a single silent read, so a wrapped paste can't break the name and there is no `==` keyboard path |
| A named cloud target is silently dropped from the config | Step 2a resolves and lists every visible subscription/project/account and Step 6's completeness check reconciles written targets against the names from Step 1 |
| Audits pointed at an admin kube context | Use a read-only context bound to the `view` ClusterRole; name it in `kubernetes.context` |
| Mimir or VictoriaMetrics queries return empty because tenancy was skipped | Set `mimir.tenant_id` (or the VM tenant path) during connect, not mid-audit |
| Old config clobbered on re-run | Back up first with the timestamped copy in Step 6; edit blocks in place |
