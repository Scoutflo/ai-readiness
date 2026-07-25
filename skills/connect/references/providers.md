# Provider Reference

One section per integration: click path, minimal scopes per tier, the `toolkit.yaml` block and env var, and an immediate verification command. All URLs, org slugs, and channel names below are placeholders; substitute your own.

Two conventions apply everywhere below:

- **Tier naming rule**: read-only credentials are named `scoutflo-audit`, elevated ones `scoutflo-setup`, in every provider that lets you name tokens, service accounts, or integrations. Every config block that names a `token_env` also records `tier: read-only` or `tier: elevated` for the token behind it.
- **Human/agent boundary**: any command that prompts for or exports a secret value (the `read -rs` lines under Export headings) is yours to run in your own terminal. Agents display those commands and never execute them.

## Quick reference: read-only tier, all providers

Skim this table to see everything you need before opening any provider UI. Full click paths, elevated-tier scopes, and verify commands are in each provider's own section below — jump straight there once you know what you're creating.

| Provider | Credential type | Read-only scopes | Where to start |
| --- | --- | --- | --- |
| [Grafana](#grafana) | Service account token | Basic role `Viewer` (add `Data sources > Reader` on Cloud/Enterprise) | Administration > Users and access > Service accounts |
| [Sentry](#sentry) | Internal integration token | `org:read`, `project:read`, `event:read`, `alerts:read` (+ `team:read`, `member:read` for ownership checks) | Organization Settings > Developer Settings > Custom Integrations |
| [DigitalOcean](#digitalocean) | Custom-scoped API token | Read on app, database, monitoring, uptime, domain — never a full-access token | API > Tokens > Generate New Token |
| [PagerDuty](#pagerduty) | General Access REST API key | Read-only key (the "Read-only API Key" checkbox at creation) | Integrations > API Access Keys > Create New API Key |
| [Datadog](#datadog) | API key + Application key pair | Scoped app key: `monitors_read`, `monitors_downtime`, `events_read`, `slos_read` (+ `usage_read`, `billing_read` for the cost section) | Organization Settings > API Keys, then Application Keys |
| [ELK / Kibana](#elk--kibana) | Elasticsearch API key | Kibana feature privileges `Read` on Stack Rules, Rules Settings, and Actions and Connectors | Kibana > Stack Management > API keys (or Elasticsearch `POST /_security/api_key`) |
| [GCP](#google-cloud-gcp) | Service account | `roles/monitoring.viewer`, `roles/logging.viewer`, `roles/compute.viewer`, `roles/container.viewer` | IAM & Admin > Service Accounts > Create service account |
| [Prometheus + Alertmanager](#prometheus-and-alertmanager) | URL reachability, optional bearer token | No scopes to grant unless behind an auth proxy | Just the URL, if reachable without auth |
| [Loki / Tempo / Mimir / VictoriaMetrics](#loki-tempo-mimir-victoriametrics) | URL, optional tenant + token | No scopes to grant unless behind an auth proxy | Just the URL, plus `tenant_id` for Mimir |
| [Kubernetes](#kubernetes) | kubeconfig context | Built-in `view` ClusterRole | A dedicated read-only context, not your admin one |
| [Slack](#slack) | Incoming webhook | The webhook URL is itself the secret | Create a Slack app > Incoming Webhooks |

## Grafana

### Config

```yaml
grafana:
  url: https://grafana.example.com     # your Grafana base URL, no trailing slash
  token_env: GRAFANA_TOKEN             # env var holding the service account token
  tier: read-only                      # tier of the token behind token_env: read-only or elevated
```

### Scopes per tier

| Tier | Used by | Grafana role |
| --- | --- | --- |
| Read-only | audit-grafana, audit-lgtm, audit-alert-routing | Basic role `Viewer`. On Grafana Cloud or Enterprise, also grant the fixed role `Data sources > Reader` so datasource checks pass at Viewer. |
| Elevated | setup-grafana, setup-lgtm (Grafana-side fixes) | `Editor` for dashboards and alert rules. `Admin` when datasources, contact points, or notification policies are in scope. |

OSS caveat: Grafana OSS has basic roles only. Listing datasources (`GET /api/datasources`) requires an org admin token there, so a Viewer audit token will see those checks reported as blocked. That is an acceptable outcome; prefer keeping the audit token at Viewer over handing audits an admin credential.

### Where to click

1. Sign in as an org admin.
2. Administration > Users and access > Service accounts (older versions: Configuration > Service accounts).
3. Add service account. Name it `scoutflo-audit` per the tier naming rule. Set the role from the table above.
4. Open the account, then Add service account token. Set an expiry (90 days is an example, tune to your rotation policy). Copy the token once; it is not shown again.
5. For setup work, create a second service account named `scoutflo-setup` at the elevated role instead of raising the audit account, and record `tier: elevated` in the block that names its env var.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'GRAFANA_TOKEN: ' && read -rs GRAFANA_TOKEN && export GRAFANA_TOKEN && printf '\n'

GRAFANA_URL="https://grafana.example.com"   # grafana.url
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/health")
[ "$code" = "200" ] && echo PASS || echo "FAIL: got $code"
# Expect: PASS. 401 means the token is wrong or expired.

curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/org" | jq -e '.name | length > 0'
# Expect: exit 0 (prints the org name, then `true`). 403 here with a healthy
# /api/health means the token exists but lacks a basic role.
#
# Do not verify with GET /api/user instead: confirmed live on Grafana 10.4.1 that a
# real, correctly-scoped service-account token gets a hard 403 "Endpoint only
# available for users" from /api/user regardless of its assigned role, because that
# endpoint identifies an interactively logged-in user, not a service account. /api/org
# works correctly for both service-account tokens and legacy API keys.
```

## Sentry

### Config

```yaml
sentry:
  host: us.sentry.io                   # your region host or self-hosted host
  org: your-org-slug
  token_env: SENTRY_TOKEN
  tier: read-only                      # tier of the token behind token_env
```

The API base is always `https://<host>/api/0`.

### Pick the right host

| Your org | `sentry.host` value |
| --- | --- |
| SaaS, US region | `us.sentry.io` |
| SaaS, EU region | `de.sentry.io` |
| Self-hosted | your instance host, for example `sentry.internal.example.com` |

Every SaaS org lives in exactly one region, and the other region's API returns `404` for it. If you are unsure, probe after exporting the token:

```bash
SENTRY_ORG="your-org-slug"   # sentry.org
for h in us.sentry.io de.sentry.io; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    "https://${h}/api/0/organizations/${SENTRY_ORG}/")"
  echo "${h} -> HTTP ${code}"
done
# 200 on exactly one host identifies your region. Write that host into sentry.host.
```

### Scopes per tier

| Tier | Token scopes | Internal integration permission settings |
| --- | --- | --- |
| Read-only (audit-sentry) | `org:read`, `project:read`, `event:read`, `alerts:read`; add `team:read` and `member:read` for ownership checks | Organization: Read; Project: Read; Issue & Event: Read; Alerts: Read; Team: Read; Member: Read |
| Elevated (setup-sentry) | the read set plus `project:write`, `alerts:write`, `org:write`; `project:admin` only when you want the setup skill to delete Sentry's default alert rule | Project: Write (Admin only for rule deletion); Issue & Event: Read; Organization: Read & Write; Alerts: Read & Write |

### Where to click

Recommended: an internal integration, because it gives exact scope control and is org-owned rather than tied to your personal account.

1. Sign in as an org owner or manager.
2. Organization Settings > Developer Settings > Custom Integrations.
3. Create New Integration > Internal Integration. Name it `scoutflo-audit` per the tier naming rule.
4. Set the permissions from the table above. Leave webhooks and UI components empty.
5. Save, open the integration, and create a token under its Tokens section. Copy it once.
6. For setup work, create a second internal integration named `scoutflo-setup` at the elevated permissions, and record `tier: elevated` in the block that names its env var.

Alternatives, and why they are second choice:

- Organization auth tokens (Organization Settings > Auth Tokens) have a fixed, CI-oriented scope set that cannot read events or alert rules, so audit checks will 403. Use them only if an internal integration is not available to you.
- User auth tokens (personal Settings > Account > API > Auth Tokens) allow custom scopes but are tied to your personal account; fine for a quick trial, wrong for anything your team shares.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'SENTRY_TOKEN: ' && read -rs SENTRY_TOKEN && export SENTRY_TOKEN && printf '\n'

SENTRY_HOST="us.sentry.io"    # sentry.host
SENTRY_ORG="your-org-slug"    # sentry.org
curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "https://${SENTRY_HOST}/api/0/organizations/${SENTRY_ORG}/" | jq -e --arg org "$SENTRY_ORG" '.slug == $org'
# Expect: exit 0 (prints `true`). 401 means a bad token; 404 means the wrong
# region host or org slug (run the probe above).
```

## DigitalOcean

### Config

```yaml
digitalocean:
  token_env: DIGITALOCEAN_ACCESS_TOKEN   # doctl reads this variable natively
  # team: your-team-uuid                 # only for multi-team accounts
```

`doctl` is a prerequisite for the DigitalOcean skills (install it from your package manager; `doctl version` is the doctor check). With `DIGITALOCEAN_ACCESS_TOKEN` exported, doctl needs no `doctl auth init` and no token file on disk.

### Scopes per tier

DigitalOcean supports custom-scoped API tokens. The API cannot introspect a token's scopes afterward, so scope discipline happens at creation time.

| Tier | Used by | Token scopes |
| --- | --- | --- |
| Read-only | audit-digitalocean | Custom scopes: read on app, database, monitoring, uptime, and domain. Never use a full-access token for audits. |
| Elevated | setup-digitalocean | Custom scopes: read plus create/update/delete on monitoring, uptime, and app; add database write only when logsinks are in scope. Full-access only if custom scopes are unavailable on your account. |

### Where to click

1. Sign in to the DigitalOcean control panel, switching to the right team first if you use teams.
2. API (left navigation) > Tokens > Generate New Token.
3. Name it for its tier, for example `scoutflo-audit`. Set an expiry (90 days is an example, tune to your rotation policy).
4. Choose Custom Scopes and select the read scopes from the table above. Copy the token once; it is not shown again.
5. For setup work, generate a second token (for example `scoutflo-setup`) with the elevated scopes instead of widening the audit token.

### Export and verify

```bash
printf 'DIGITALOCEAN_ACCESS_TOKEN: ' && read -rs DIGITALOCEAN_ACCESS_TOKEN && export DIGITALOCEAN_ACCESS_TOKEN && printf '\n'

doctl account get -o json | jq -e '(if type=="array" then .[0] else . end) | .status == "active"'
# Expect: exit 0 (prints `true`). A failure here (or a 401 from doctl) means the
# token is wrong, expired, or belongs to a different team context.

doctl account get -o json | jq -r '(if type=="array" then .[0] else . end) | "team=\(.team.uuid // "personal")"'
# Confirm the team UUID matches the account you intend to audit; write it into
# digitalocean.team for multi-team accounts.
```

## PagerDuty

### Config

```yaml
pagerduty:
  token_env: PAGERDUTY_TOKEN            # env var holding the REST API key
  tier: read-only                       # tier of the key behind token_env
  # region: us                          # us (api.pagerduty.com) or eu (api.eu.pagerduty.com)
```

The API base is `https://api.pagerduty.com` for US-region accounts and `https://api.eu.pagerduty.com` for EU service regions. If you are unsure, US is the default; a wrong region returns 401 for a valid key, so probe after exporting.

### Scopes per tier

| Tier | Used by | Credential |
| --- | --- | --- |
| Read-only | audit-pagerduty | A **General Access REST API key** created with the **Read-only API Key** checkbox ticked (restricts the key to GET calls). Account-level; created by an admin or account owner. |
| Elevated | (future setup-pagerduty) | A separate General Access key without the read-only restriction, created only when setup work starts. |

Two caveats to know at creation time:

- Read-only keys are documented as GET-only. The Analytics endpoints this toolkit uses for the alert-to-incident actionability section are POST requests (they carry a filter body but change nothing; they are read-only by effect, not by verb). Whether your account's read-only key passes them is probed by `/scoutflo:doctor`, and the audit degrades that one section honestly if not. If the probe fails and you want the actionability section, use a full General Access key and record `tier: elevated` — the audit itself still only reads.
- User API tokens (created under My Profile) inherit that user's permissions and disappear with the user. Prefer the account-level key for a durable audit credential.

### Where to click

1. Sign in as an admin or account owner.
2. Integrations > API Access Keys > Create New API Key.
3. Description `scoutflo-audit` per the tier naming rule. Tick **Read-only API Key**.
4. Copy the key once; it is not shown again.
5. For future setup work, create a second key named `scoutflo-setup` without the read-only restriction instead of widening this one.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'PAGERDUTY_TOKEN: ' && read -rs PAGERDUTY_TOKEN && export PAGERDUTY_TOKEN && printf '\n'

PD_API="https://api.pagerduty.com"   # pagerduty.region: us -> api.pagerduty.com, eu -> api.eu.pagerduty.com
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Token token=${PAGERDUTY_TOKEN}" \
  -H "Content-Type: application/json" "${PD_API}/abilities")
[ "$code" = "200" ] && echo PASS || echo "FAIL: got $code"
# Expect: PASS. 401 means the key is wrong, revoked, or the region host is wrong.
# Note: /users/me returns an error for account-level keys by design; /abilities is
# the correct cheap identity probe for this credential type.
```

## Datadog

### Config

```yaml
datadog:
  site: datadoghq.com                   # your Datadog site (see the site table below)
  api_key_env: DATADOG_API_KEY          # env var holding the API key (org-level)
  app_key_env: DATADOG_APP_KEY          # env var holding the Application key (user-bound)
  tier: read-only                       # tier of the app key behind app_key_env
  # cost_checks: true                   # optional, default true; set false to skip the cost section
```

Datadog authenticates every management API call with **two** credentials sent together: an API key (`DD-API-KEY` header, org-level) and an Application key (`DD-APPLICATION-KEY` header, user-bound). Both are required; neither works alone.

### Pick the right site

Your API host is `api.<site>`. The site is visible in your Datadog URL and under your profile's Organization Settings. A wrong site returns 403 for perfectly valid keys, so set it explicitly:

| Your Datadog URL | `datadog.site` value |
| --- | --- |
| app.datadoghq.com | `datadoghq.com` |
| us3.datadoghq.com | `us3.datadoghq.com` |
| us5.datadoghq.com | `us5.datadoghq.com` |
| app.datadoghq.eu | `datadoghq.eu` |
| ap1.datadoghq.com | `ap1.datadoghq.com` |
| ap2.datadoghq.com | `ap2.datadoghq.com` |
| uk1.datadoghq.com | `uk1.datadoghq.com` |
| gov sites | `ddog-gov.com` (US1-FED) |

### Scopes per tier

Application keys support authorization scopes; an unscoped app key inherits everything its creating user can do, so scope the audit key down.

| Tier | Used by | App key scopes |
| --- | --- | --- |
| Read-only | audit-datadog | `monitors_read`, `monitors_downtime` (v2 downtime reads need this, not `monitors_read`), `events_read`, `slos_read`, `dashboards_read`. Add `usage_read` + `billing_read` for the non-scored cost section. |
| Elevated | (future setup-datadog) | A separate app key with the monitor/downtime write scopes, created only when setup work starts. |

Two things to know at creation time:

- **Application keys die with their user.** An app key is bound to the user who created it and is revoked when that user is disabled. Create the audit key under a service-account user, not a personal login, or the audit breaks on someone's offboarding.
- Scoped keys can never exceed the creator's own RBAC permissions; if a scope in the table is missing from the picker, the creating user lacks it.

### Where to click

1. Sign in and confirm which site you are on (URL bar).
2. Organization Settings > API Keys > New Key. Name it `scoutflo-audit`. This is the org-level half.
3. Organization Settings > Application Keys > New Key (as the service-account user). Name it `scoutflo-audit`, and under Edit > Authorization Scopes restrict it to the read-only scopes from the table.
4. Copy both values once; they are not shown again.
5. For future setup work, create a second app key named `scoutflo-setup` with write scopes instead of widening this one.

### Export and verify

```bash
# YOU run these in your own terminal; an agent never executes these lines.
printf 'DATADOG_API_KEY: ' && read -rs DATADOG_API_KEY && export DATADOG_API_KEY && printf '\n'
printf 'DATADOG_APP_KEY: ' && read -rs DATADOG_APP_KEY && export DATADOG_APP_KEY && printf '\n'

DD_SITE="datadoghq.com"   # datadog.site
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" "https://api.${DD_SITE}/api/v1/validate")
[ "$code" = "200" ] && echo "API key PASS" || echo "API key FAIL: got $code (403 = wrong key or wrong site)"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" -H "DD-APPLICATION-KEY: ${DATADOG_APP_KEY}" \
  "https://api.${DD_SITE}/api/v1/monitor?page_size=1")
[ "$code" = "200" ] && echo "app key + monitors_read PASS" || echo "FAIL: got $code (403 = app key invalid, unscoped for monitors_read, or wrong site)"
```

## ELK / Kibana

### Config

```yaml
elk:
  kibana_url: https://kibana.example.com   # Kibana base URL (NOT the Elasticsearch URL); no trailing slash
  token_env: KIBANA_API_KEY                # env var holding the Elasticsearch API key
  tier: read-only                          # tier of the key behind token_env
  # spaces: [default]                       # Kibana spaces to audit; omit to audit the default space only
```

Alerting rules live in **Kibana**, not Elasticsearch, so `kibana_url` is the Kibana application endpoint — a different host and port from the Elasticsearch API (on self-managed, Kibana is `:5601`, Elasticsearch is `:9200`; on Elastic Cloud they are two separate endpoints). One Elasticsearch API key authenticates both the Elasticsearch and Kibana APIs, so there is no separate "Kibana key" to create.

### Rules are space-isolated

Kibana alerting rules and connectors belong to a **space**. A key that reads the `default` space sees only the `default` space's rules; auditing another space means iterating `/s/<space_id>/api/alerting/...`. List the spaces you want audited in `elk.spaces` (the audit defaults to `default` when omitted) so coverage denominators are honest about which spaces were checked.

### Scopes per tier

Read-only for the audit is a set of **Kibana feature privileges**, granted to the role the API key inherits, not an Elasticsearch cluster privilege:

| Tier | Used by | Privileges |
| --- | --- | --- |
| Read-only | audit-elk | Kibana `Read` on **Stack Rules**, **Rules Settings**, and **Actions and Connectors**, in each space you audit. Add `monitor_watcher` cluster privilege only if you want the legacy-Watcher split check. |
| Elevated | (future setup-elk) | Kibana `All` on the same features, created as a separate key when setup work starts. |

Version note: this audit targets the current `/api/alerting/rule(s)` API. Kibana **9.0 removed** the legacy `/api/alerts/*` routes, and maintenance-window listing (`GET /api/maintenance_window/_find`) is a **public API only from 9.2**; the audit version-gates those checks rather than assuming them.

### Where to click

1. In Kibana, Stack Management > API keys > Create API key (this mints an Elasticsearch key usable on both APIs). Name it `scoutflo-audit`.
2. Restrict it: under Elasticsearch security, the key's role needs the Kibana feature privileges above; if your key supports role descriptors, scope it to `read` on the alerting and connectors features rather than granting a broad role.
3. Copy the key's **encoded** value (the base64 `id:api_key` form) once.
4. For setup work later, mint a second key named `scoutflo-setup` with the write privileges.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'KIBANA_API_KEY: ' && read -rs KIBANA_API_KEY && export KIBANA_API_KEY && printf '\n'

KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
# Kibana takes the encoded key as "Authorization: ApiKey <encoded>". _health is the
# cheapest alerting-scoped probe and is itself audit-worthy.
curl -fsS --max-time 10 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/alerting/_health" | jq -e '.is_sufficiently_secure != null'
# Expect: exit 0 (prints true). 401 = wrong key; 404 = wrong host (pointed at
# Elasticsearch instead of Kibana, or a base-path/space-prefix mismatch).
```

## Google Cloud (GCP)

### Config

```yaml
gcp:
  project: your-project-id                 # the project ID the audits target; one project per run
  # region: us-central1                    # example; only for regional load balancer checks
  # credentials_env: GOOGLE_APPLICATION_CREDENTIALS  # only for key-file auth; see below
  tier: read-only                          # tier of the identity behind the auth path
```

`gcloud` is a prerequisite for the GCP skills (install the Google Cloud CLI from your package manager; `gcloud --version` is the doctor check). There is no `token_env`: auth rides Google credentials, not a pasted token. Two paths, pick one:

1. **Your gcloud login (simplest).** `gcloud auth login` with an account that holds the viewer roles below. Leave `credentials_env` unset; the skills mint short-lived access tokens from the active login and pass `--project` explicitly on every command, so your ambient gcloud project setting is never trusted or changed.
2. **Dedicated service account with a key file (shared or CI setups).** Create a service account per tier, download its key, and export the key file path in `GOOGLE_APPLICATION_CREDENTIALS`. Set `credentials_env: GOOGLE_APPLICATION_CREDENTIALS` so the doctor knows key-file auth is intended; that exact variable name matters, because application-default credentials read it. The key file is a secret: keep it out of the repo and out of `toolkit.yaml`; the skills read its path, mint tokens from it, and never print its contents. If your org bans key downloads, use path 1 with `--impersonate-service-account` grants instead and note the impersonated principal is then the identity the live-safety gate prints.

### Roles per tier

| Tier | Used by | IAM roles on the project |
| --- | --- | --- |
| Read-only | audit-gcp | `roles/monitoring.viewer`, `roles/logging.viewer`, `roles/compute.viewer`, `roles/container.viewer` |
| Elevated | setup-gcp | `roles/monitoring.editor`, plus `roles/logging.configWriter` when logs-based metrics are in scope |

Never hand the audit an editor or owner identity when a viewer set will do; the audit runs with editor but records that its credential can write, which is itself a posture gap.

### Where to click

1. Sign in to the Google Cloud console with rights to manage IAM on the target project, and confirm the project picker shows that project.
2. IAM & Admin > Service Accounts > Create service account. Name it `scoutflo-audit` per the tier naming rule.
3. Grant the read-only roles from the table above on the project.
4. Keys > Add key > Create new key (JSON) only if you chose the key-file path; store it where your secrets live and export its path as `GOOGLE_APPLICATION_CREDENTIALS`. Skip key creation entirely for the gcloud-login or impersonation paths.
5. For setup work, create a second service account named `scoutflo-setup` with the elevated roles instead of widening the audit account, and record `tier: elevated` in the config block you use for setup runs.

### Export and verify

```bash
# Only for the key-file path. The value is a file path; the file itself is the secret.
# YOU set this in your own terminal; an agent never handles the key file contents.
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your-key.json"

GCP_PROJECT="your-project-id"   # gcp.project
gcloud projects describe "$GCP_PROJECT" --format='value(projectId)'
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; else TOKEN="$(gcloud auth print-access-token)"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1")
[ "$code" = "200" ] && echo PASS || echo "FAIL: got $code"
# Expect: PASS. 403 means missing roles or the Monitoring API disabled on the
# project; 404 means a wrong project id.
```

## Prometheus and Alertmanager

### Config

```yaml
prometheus:
  url: https://prometheus.example.com
  alertmanager_url: https://alertmanager.example.com
  # token_env: PROM_TOKEN     # only if your endpoints sit behind an auth proxy
  # tier: read-only           # record it whenever you set token_env
```

### Getting a reachable URL

Use whatever already exposes the API to you: an internal ingress, a LoadBalancer on a private network, or a port-forward for in-cluster deployments:

```bash
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
MONITORING_NS="monitoring"         # kubernetes.monitoring_namespace; example, tune to your cluster
kubectl --context "${KUBE_CONTEXT}" -n "${MONITORING_NS}" get svc
# Pick your Prometheus service from the list, then in a separate terminal:
#   kubectl --context "${KUBE_CONTEXT}" -n "${MONITORING_NS}" port-forward svc/<your-prometheus-svc> 9090:9090
# and set prometheus.url: http://127.0.0.1:9090
```

Prometheus and Alertmanager have no native token auth. If yours answer without credentials, reachability is the whole setup; prefer reaching them over a private network or port-forward rather than a public ingress. If they sit behind an auth proxy that expects a bearer token, set `token_env` and export that variable; the audits will send it as an `Authorization: Bearer` header on every call.

### Verify

```bash
PROM_URL="https://prometheus.example.com"        # prometheus.url
AM_URL="https://alertmanager.example.com"        # prometheus.alertmanager_url
curl -fsSG --max-time 10 "${PROM_URL}/api/v1/query" --data-urlencode 'query=vector(1)' | jq -e '.status == "success"'
# Expect: exit 0 (prints `true`).

curl -fsS --max-time 10 "${AM_URL}/api/v2/status" | jq -e '.cluster.status == "ready"'
# Expect: exit 0 (prints `true`).
```

If your endpoints require the bearer token, add `-H "Authorization: Bearer ${PROM_TOKEN}"` to both calls after exporting `PROM_TOKEN`.

## Loki, Tempo, Mimir, VictoriaMetrics

### Config

```yaml
loki:
  url: https://loki.example.com
  # token_env: LOKI_TOKEN
  # tier: read-only                     # record it whenever you set token_env

tempo:
  url: https://tempo.example.com
  # token_env: TEMPO_TOKEN
  # tier: read-only

mimir:
  url: https://mimir.example.com
  # token_env: MIMIR_TOKEN
  # tier: read-only
  # tenant_id: your-tenant              # if multi-tenant

victoriametrics:
  url: https://vm.example.com
  # vmalert_url: https://vmalert.example.com
  # token_env: VM_TOKEN
  # tier: read-only
```

Configure only the stores you actually run. URL discovery works the same as for Prometheus: ingress, private LB, or port-forward.

### Tenancy and tokens

- Multi-tenant Loki, Tempo, and Mimir expect an `X-Scope-OrgID` header on query paths. Set `tenant_id` where the block supports it and keep the tenant name handy; the audit skills send the header when it is configured.
- VictoriaMetrics cluster editions use path-based tenancy (query paths under `/select/<tenant>/prometheus/...`); the single-node edition does not. Note which one you run; the LGTM audit detects the flavor but a wrong base URL wastes a run.
- Set `vmalert_url` when vmalert evaluates your recording and alerting rules; the alert-routing checks need it.
- None of these ship token auth by default. `token_env` is only for an auth proxy in front of them, same as Prometheus.

### Verify

```bash
LOKI_URL="https://loki.example.com"     # loki.url
TEMPO_URL="https://tempo.example.com"   # tempo.url
MIMIR_URL="https://mimir.example.com"   # mimir.url
VM_URL="https://vm.example.com"         # victoriametrics.url

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${LOKI_URL}/ready")
[ "$code" = "200" ] && echo "loki PASS" || echo "loki FAIL: got $code"
# Expect: loki PASS

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${TEMPO_URL}/ready")
[ "$code" = "200" ] && echo "tempo PASS" || echo "tempo FAIL: got $code"
# Expect: tempo PASS

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${MIMIR_URL}/ready")
[ "$code" = "200" ] && echo "mimir PASS" || echo "mimir FAIL: got $code"
# Expect: mimir PASS

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${VM_URL}/health")
[ "$code" = "200" ] && echo "victoriametrics PASS" || echo "victoriametrics FAIL: got $code"
# Expect: victoriametrics PASS
```

Run only the checks for the stores you configured. These health paths vary by deployment: behind a gateway or path prefix, `/ready` may 404 while queries work fine. Verify the health path against your deployment, and treat a successful real query as the authoritative signal.

## Kubernetes

### Config

```yaml
kubernetes:
  context: your-kube-context
  # monitoring_namespace: monitoring
```

### Pick a context

```bash
kubectl config get-contexts
```

Write the exact context name into `kubernetes.context`. Every kubectl command in this toolkit passes `--context` explicitly, so the config value is the single source of truth; your shell's current context is never trusted.

### Read-only RBAC for audits

Audits need get and list on workload objects, nothing more. The built-in `view` ClusterRole covers it. If your everyday context carries admin rights, point the toolkit at a dedicated read-only identity instead. Example binding for your cluster admin to review and apply (applying it is a cluster change):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: scoutflo-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: User
    name: scoutflo-audit        # the identity in your read-only kubeconfig
    apiGroup: rbac.authorization.k8s.io
```

Elevated tier: `setup-lgtm` can apply manifests in your monitoring namespace. That needs edit rights there, granted deliberately and ideally scoped to the namespace, not cluster-wide.

### Verify

```bash
KUBE_CONTEXT="your-kube-context"   # kubernetes.context
kubectl --context "${KUBE_CONTEXT}" auth can-i get pods \
  | jq -e -R 'select(. == "yes")' >/dev/null && echo PASS || echo FAIL
# Expect: PASS. FAIL with the underlying output showing "no" means the RBAC
# binding is missing; an error naming the context means the context name in
# the config does not exist in your kubeconfig.
```

## Slack

### Config

```yaml
slack:
  webhook_env: SCOUTFLO_SLACK_WEBHOOK
```

The webhook URL is itself the secret: anyone holding it can post to your channel. It lives only in the environment variable, never in `toolkit.yaml`, and never in reports.

### Create an incoming webhook

1. Go to `https://api.slack.com/apps` and select Create New App > From scratch.
2. Name it (for example `AI Readiness Briefs`) and pick your workspace.
3. In the app's sidebar, open Incoming Webhooks and toggle Activate Incoming Webhooks on.
4. Select Add New Webhook to Workspace, choose the channel that should receive audit briefs (a private ops channel is a good default), and allow it.
5. Copy the webhook URL shown for that channel.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'SCOUTFLO_SLACK_WEBHOOK: ' && read -rs SCOUTFLO_SLACK_WEBHOOK && export SCOUTFLO_SLACK_WEBHOOK && printf '\n'
```

Verification posts a visible message to the channel. Run it only when that is acceptable to the channel's members:

```bash
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
  --data '{"text":"AI Readiness connected. Audit briefs will arrive here."}' \
  "${SCOUTFLO_SLACK_WEBHOOK}")
[ "$code" = "200" ] && echo PASS || echo "FAIL: got $code"
# Expect: PASS, and the message appears in the channel. A non-200 code (for
# example a body of "no_service" behind a 404) means the webhook was revoked
# or the URL is wrong.
```

If you skip this now, `/scoutflo:doctor` offers the same test later, gated on your confirmation.
