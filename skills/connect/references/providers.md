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
| [JSM Operations](#jsm-operations) | Atlassian API token (Basic auth) | Read-only enforced by GET-only use; a JSM agent/user account with Operations access | id.atlassian.com > Security > API tokens |
| [Zenduty](#zenduty-xurrent-imr) | API key (`Authorization: Token`) | No read-only key scope; use a **Bot Token (Beta)** with view-only permissions, GET-only use | Account Settings > API Keys (Bot Tokens for least privilege) |
| [Groundcover](#groundcover) | Service-account API key (`Authorization: Bearer`) | A **Viewer-role** service account = true read-only tier | Settings > Access > Service Accounts, then API Keys |
| [GCP](#google-cloud-gcp) | Service account | `roles/monitoring.viewer`, `roles/logging.viewer`, `roles/compute.viewer`, `roles/container.viewer` | IAM & Admin > Service Accounts > Create service account |
| [Prometheus + Alertmanager](#prometheus-and-alertmanager) | URL reachability, optional bearer token | No scopes to grant unless behind an auth proxy | Just the URL, if reachable without auth |
| [Loki / Tempo / Mimir / VictoriaMetrics](#loki-tempo-mimir-victoriametrics) | URL, optional tenant + token | No scopes to grant unless behind an auth proxy | Just the URL, plus `tenant_id` for Mimir |
| [Kubernetes](#kubernetes) | kubeconfig context | Built-in `view` ClusterRole | A dedicated read-only context, not your admin one |
| [GitHub](#github) | Personal access token | Classic `repo` (read) on private repos, or fine-grained `Contents:Read` + `Metadata:Read` | Settings > Developer settings > Personal access tokens |
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
curl -fsS --max-time 10 -H "Authorization: Bearer ${GRAFANA_TOKEN}" "${GRAFANA_URL}/api/health" | jq -e '.database=="ok"' >/dev/null \
  && echo PASS || echo "FAIL: not reachable/authorized, or a 200 HTML SSO/login page instead of JSON (401 = token wrong/expired)"
# Expect: PASS. Asserting .database=="ok" makes a Grafana behind an SSO proxy (which returns a 200 login page) FAIL here instead of false-passing.

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
  # status-probe-ok: quick user sanity-check against sentry.io (fixed vendor JSON API, no SSO login fall-through); the authoritative JSON-asserting gate is /scoutflo:doctor.
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
# status-probe-ok: quick user sanity-check against api.pagerduty.com (fixed vendor JSON API, no SSO login fall-through); the authoritative JSON-asserting gate is /scoutflo:doctor.
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
# status-probe-ok: quick user sanity-check against api.<site> Datadog (fixed vendor JSON API, no SSO login fall-through); the authoritative JSON-asserting gate is /scoutflo:doctor.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "DD-API-KEY: ${DATADOG_API_KEY}" "https://api.${DD_SITE}/api/v1/validate")
[ "$code" = "200" ] && echo "API key PASS" || echo "API key FAIL: got $code (403 = wrong key or wrong site)"

# status-probe-ok: quick user sanity-check against api.<site> Datadog (fixed vendor JSON API, no SSO login fall-through); the authoritative JSON-asserting gate is /scoutflo:doctor.
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
  # spaces: [default]                       # OPTIONAL restriction. Omit to audit ALL Kibana spaces the
                                            # key can see (auto-discovered via GET /api/spaces/space).
                                            # List space ids to restrict to a subset. Discovery is
                                            # complete only if the key has Read at spaces:["*"].
```

Alerting rules live in **Kibana**, not Elasticsearch, so `kibana_url` is the Kibana application endpoint — a different host and port from the Elasticsearch API (on self-managed, Kibana is `:5601`, Elasticsearch is `:9200`; on Elastic Cloud they are two separate endpoints). One Elasticsearch API key authenticates both the Elasticsearch and Kibana APIs, so there is no separate "Kibana key" to create.

### Rules are space-isolated — and the audit discovers spaces for you

Kibana alerting rules and connectors belong to a **space**, and a team's rules very often live in a **non-default** space. `audit-elk` **auto-discovers** your spaces at run time via `GET /api/spaces/space` and audits all of them, so you no longer have to know your space ids up front — `elk.spaces` is now an **optional restriction** (list ids to audit only a subset), not the source of truth.

One catch that decides whether discovery is complete: `GET /api/spaces/space` returns **only the spaces your key can see**, and a key sees a space only where its role holds at least one Kibana feature privilege there. So a key scoped to a single space enumerates only that space — and the audit would again miss the space that holds your rules. Grant the read privileges at **`spaces:["*"]`** (all spaces) so discovery is complete. This is still fully read-only and needs no admin privilege.

### Scopes per tier

Read-only for the audit is a set of **Kibana feature privileges**, granted to the role the API key inherits, not an Elasticsearch cluster privilege:

| Tier | Used by | Privileges |
| --- | --- | --- |
| Read-only | audit-elk | Kibana `Read` on **Stack Rules**, **Rules Settings**, and **Actions and Connectors**, granted at **`spaces:["*"]`** (all spaces) so space auto-discovery is complete. Add `monitor_watcher` cluster privilege only if you want the legacy-Watcher split check. |
| Elevated | (future setup-elk) | Kibana `All` on the same features, created as a separate key when setup work starts. |

> **These are Kibana *feature* privileges, not Elasticsearch *cluster/index* privileges.** A key scoped to `cluster: ["monitor"]` plus index `read`/`view_index_metadata` (the natural "read-only Elasticsearch" shape) **authenticates** against Kibana but returns **403** on `/api/alerting/rules/_find` and `/api/actions/connectors`, because those endpoints are gated by Kibana feature privileges. If your audit 403s on the rule/connector reads while the key clearly "works", this is why — the key has the wrong *kind* of privilege. Use the `role_descriptors` shape in *Where to click* below, which grants the Kibana feature privileges.

Version note: this audit targets the current `/api/alerting/rule(s)` API. Kibana **9.0 removed** the legacy `/api/alerts/*` routes, and maintenance-window listing (`GET /api/maintenance_window/_find`) is a **public API only from 9.2**; the audit version-gates those checks rather than assuming them.

### Where to click (Kibana UI)

1. In Kibana, Stack Management > API keys > Create API key (this mints an Elasticsearch key usable on both APIs). Name it `scoutflo-audit`.
2. Restrict it: turn on **User API key** restrictions and, under the role descriptors, grant the **Kibana feature privileges** above (`Read` on Stack Rules, Rules Settings, Actions and Connectors) at **All spaces** — not an Elasticsearch cluster/index privilege.
3. Copy the key's **encoded** value (the base64 `id:api_key` form) once.
4. For setup work later, mint a second key named `scoutflo-setup` with the write privileges.

### Or mint it directly via the Elasticsearch API (curl)

If you create keys with `POST /_security/api_key` instead of the UI, use **exactly** this `role_descriptors` shape — it grants the Kibana feature privileges at all spaces, which is what the audit needs. (Do **not** use `cluster:["monitor"]` + index read; that authenticates but 403s the alerting reads, per the note above.)

```bash
# YOU run this in your own terminal, against Elasticsearch (:9200), with a user allowed to mint keys.
curl -fsS -u "<es_user>" -X POST "https://elasticsearch.example.com:9200/_security/api_key" \
  -H "Content-Type: application/json" -d '{
    "name": "scoutflo-audit",
    "role_descriptors": {
      "scoutflo_audit_elk": {
        "cluster": [],
        "indices": [],
        "applications": [
          { "application": "kibana-.kibana",
            "privileges": [
              "feature_stackAlerts.read",
              "feature_rulesSettings.read",
              "feature_actions.read"
            ],
            "resources": ["*"] }
        ]
      }
    }
  }' | jq -r '.encoded'
# The printed "encoded" value is your KIBANA_API_KEY. resources:["*"] = all spaces (complete discovery).
# The Kibana application name is "kibana-.kibana" on a default install; confirm yours via
# GET /_security/privilege or the Stack Management > API keys UI if it differs.
```

If you also want the legacy-Watcher split check (ELK-032), add `"cluster": ["monitor_watcher"]` to that descriptor.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
# This prompt shows NOTHING as you paste the key — that is the -s (silent) flag hiding the
# value, not a hang. Paste and press Enter. (Prefer a visible paste? Use the plain form:
#   export KIBANA_API_KEY="<paste-the-encoded-key-here>" )
printf 'KIBANA_API_KEY: ' && read -rs KIBANA_API_KEY && export KIBANA_API_KEY && printf '\n'

KIBANA_URL="https://kibana.example.com"   # elk.kibana_url
# Kibana takes the encoded key as "Authorization: ApiKey <encoded>".
# 1) Cheapest liveness probe (also audit-worthy):
curl -fsS --max-time 10 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/alerting/_health" | jq -e '.is_sufficiently_secure != null'
# 2) Prove the key actually has the Kibana FEATURE privileges the audit needs. _health can
#    pass on a key that still 403s the real reads, so verify the rule read directly:
curl -fsS --max-time 10 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/alerting/rules/_find?per_page=1" | jq -e '.total != null' \
  && echo "rule read OK" || echo "403? key lacks Kibana Read on Stack Rules — see the role_descriptors above"
# 3) List the spaces this key can see (this is what audit-elk auto-discovers). If your rules
#    live in a space that is NOT listed here, widen the key to spaces:["*"] read.
curl -fsS --max-time 10 -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
  "${KIBANA_URL}/api/spaces/space" | jq -r '.[].id'
# Expect: (1) exit 0/true, (2) "rule read OK", (3) a list including the space with your rules.
# 401 = wrong key; 404 = wrong host (pointed at Elasticsearch, or a base-path/space-prefix mismatch).
```

## JSM Operations

### Config

```yaml
jsm:
  site: your-site.atlassian.net            # your Atlassian site host; used to discover cloud_id
  email_env: JSM_EMAIL                     # env var holding the Atlassian account email (Basic-auth username)
  token_env: JSM_API_TOKEN                 # env var holding the Atlassian API token (Basic-auth password)
  tier: read-only                          # read-only is enforced by GET-only use, not by a token scope
  # cloud_id: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  # optional UUID; set it to skip the site-based discovery step
  # teams: [team-id-a, team-id-b]           # Operations team IDs to audit; omit to discover from /v1/teams
```

This is the **JSM Operations REST API** (`api.atlassian.com/jsm/ops/api/{cloud_id}/v1/...`), the cloud successor to standalone Opsgenie. **Do not point this at `api.opsgenie.com`** — standalone Opsgenie is end-of-sale (2025-06-04) with a hard shutdown on 2027-04-05, and its per-account keys are retired at migration. The classic `GenieKey` header does not authenticate this cloud API at all.

### Auth is an Atlassian API token over HTTP Basic

The credential is an **Atlassian API token** used as the password in HTTP Basic auth, with your account email as the username: `Authorization: Basic base64(email:token)`. There is no read-only *scope* on the token — an API token inherits the permissions of the user it belongs to. Read-only is enforced by this toolkit using **GET only**; to make that guarantee real, create the token under a JSM user whose Operations role is a viewer/read role, not an admin.

| Tier | Used by | How read-only is guaranteed |
| --- | --- | --- |
| Read-only | audit-jsm | GET-only usage in the skill, under a token whose user holds a read/observer Operations role. There is no reporting/analytics API, so nothing here writes. |
| Elevated | (future setup-jsm) | A token under a user with policy/maintenance write access, created only when setup work starts. |

### Discover your cloud_id

Every Operations API path needs your site's `cloud_id`. The audit resolves it from `jsm.site`; you can also set `jsm.cloud_id` directly to skip the lookup:

```bash
# YOU run this in your own terminal. tenant_info is an unauthenticated site endpoint.
SITE="your-site.atlassian.net"   # jsm.site
curl -fsS --max-time 10 "https://${SITE}/_edge/tenant_info" | jq -r '.cloudId'
# Prints the cloud_id (a UUID). If your site blocks that edge route, the documented
# alternative needs an OAuth token: GET https://api.atlassian.com/oauth/token/accessible-resources
# and read the .id of your site's resource.
```

### Teams are the scope for policies and heartbeats

Notification policies and heartbeats in JSM Operations are **team-scoped**, not global: `GET /v1/teams/{teamId}/policies?type=notification` and `GET /v1/teams/{teamId}/heartbeats`. List the Operations team IDs you want audited in `jsm.teams` (the audit discovers them from `/v1/teams` when omitted) so coverage denominators are honest about which teams were checked. Global alert policies (`/v1/alerts/policies`) and maintenance windows (`/v1/maintenances`) are account-wide.

### Where to click

1. Sign in at `id.atlassian.com` > Security > **Create and manage API tokens** > Create API token. Name it `scoutflo-audit`. Copy it once; it is shown only at creation.
2. Confirm the account you created it under has an Operations **read/observer** role in JSM (not admin), so GET-only use is a real read-only tier.
3. Note your site host (the `*.atlassian.net` in your JSM URL) for `jsm.site`.
4. For setup work later, create a separate token under a user with write access rather than widening this one.

### Export and verify

```bash
# YOU run these in your own terminal; an agent never executes these lines.
printf 'JSM_EMAIL: ' && read -r JSM_EMAIL && export JSM_EMAIL
printf 'JSM_API_TOKEN: ' && read -rs JSM_API_TOKEN && export JSM_API_TOKEN && printf '\n'

SITE="your-site.atlassian.net"   # jsm.site
CLOUD_ID="$(curl -fsS --max-time 10 "https://${SITE}/_edge/tenant_info" | jq -r '.cloudId')"
# One page of alerts is the cheapest Operations-scoped read; -u sends Basic auth.
# status-probe-ok: quick user sanity-check against api.atlassian.com (fixed vendor JSON API, no SSO login fall-through); the authoritative JSON-asserting gate is /scoutflo:doctor.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" \
  "https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1/alerts?size=1")
[ "$code" = "200" ] && echo "JSM Operations PASS" || echo "FAIL: got $code (401 = bad token/email; 403 = user lacks Operations access; 404 = wrong cloud_id)"
```

## Zenduty (Xurrent IMR)

### Config

```yaml
zenduty:
  token_env: ZENDUTY_TOKEN                 # env var holding the API key; sent as "Authorization: Token <key>"
  tier: read-only                          # read-only is by GET-only use, not a key scope (see below)
  # teams: [team-unique-id-a]              # team unique_ids to audit; omit to discover from /api/account/teams/
```

Zenduty was acquired by Xurrent (Feb 2025) and rebranded **Xurrent IMR** (Nov 2025) — this is a branding change, not a sunset: the API and product are alive, and everything still runs through `https://www.zenduty.com/api/...`. The current help lives at `xurrent.com/imr-help/*` (the old `zenduty.com/docs/*` now redirects there).

### Auth is a Token-prefixed API key, and there is no read-only scope

The credential is an API key sent as `Authorization: Token <key>` — note the literal word `Token`, not `Bearer`. **Zenduty has no read-only or scoped tier for standard API keys**: a standard key inherits full account access, and only an Account Owner or Admin can create one. So read-only for the audit is enforced by this toolkit using **GET only** (plus the two documented read-by-POST calls — incident filter and analytics — which change nothing).

To make that guarantee real, prefer a **Bot Token (Beta)**: a key bound to a bot user with granular, view-only permissions, created under Account Settings > API Keys > Bot Tokens. It is the closest thing to a least-privilege audit credential Zenduty offers today.

| Tier | Used by | How read-only is guaranteed |
| --- | --- | --- |
| Read-only | audit-zenduty | GET-only usage (plus read-by-POST for incident filter and analytics), ideally under a **Bot Token** with view-only permissions. Standard keys have no read scope. |
| Elevated | (future setup-zenduty) | A standard API key or a write-permissioned bot token, created only when setup work starts. |

### Rate limits are tight and per-endpoint-class

Zenduty publishes strict, per-endpoint-class rate limits (for example, Incident GET is 3/second and 30/minute; Alert GET is 1/second and 20/minute; list GETs such as teams and schedules are 5/second and 40/minute). The audit throttles by design and backs off on `429`. This is the defining operational constraint of this integration, so a large account audit is paced, not fast.

### Where to click

1. Sign in as an Account Owner or Admin. Go to Account Settings > API Keys.
2. For least privilege, open the **Bot Tokens (Beta)** section, create a bot with view-only permissions, and copy its key. Otherwise create a standard API key (full access — the audit stays read-only by GET-only use).
3. Name it `scoutflo-audit` where the UI allows a label.
4. For setup work later, create a separate write-permissioned credential rather than widening this one.

### Export and verify

```bash
# YOU run these in your own terminal; an agent never executes these lines.
printf 'ZENDUTY_TOKEN: ' && read -rs ZENDUTY_TOKEN && export ZENDUTY_TOKEN && printf '\n'

# Teams is the cheapest list read and the doctor probe. Token, not Bearer.
curl -fsS --max-time 10 -H "Authorization: Token ${ZENDUTY_TOKEN}" "https://www.zenduty.com/api/account/teams/" \
  | jq -e 'type=="array" or type=="object"' >/dev/null \
  && echo "Zenduty PASS" || echo "FAIL: bad/non-Token-prefixed key (401), rate-limited (429), or a 200 Cloudflare/SPA page instead of JSON"
```

## Groundcover

### Config

```yaml
groundcover:
  token_env: GROUNDCOVER_API_KEY           # env var holding the API key; sent as "Authorization: Bearer <key>"
  tier: read-only                          # bind the key to a Viewer-role service account
  # backend_id: your-backend               # required only for multi-backend accounts (X-Backend-Id header)
  # api_url: https://api.groundcover.com   # override the API base if your deployment uses a different host
```

Groundcover's monitors and workflows are its alerting layer. The audit reads them read-only through the groundcover API at `https://api.groundcover.com`.

### Auth is a service-account API key, and Viewer is a real read-only tier

The credential is an **API key bound to a service account**, sent as `Authorization: Bearer <key>`. A service account carries an RBAC role (Admin, Editor, or **Viewer**), and the key inherits that role's permissions — so binding the audit key to a **Viewer** service account gives you a genuine read-only tier, unlike PagerDuty or Zenduty where read-only is only enforced by GET-only use.

| Tier | Used by | Scope |
| --- | --- | --- |
| Read-only | audit-groundcover | An API key on a **Viewer**-role service account. The audit uses list/read calls only. |
| Elevated | (future setup-groundcover) | A key on an Editor/Admin service account, created only when setup work starts. |

### Multi-backend accounts need a backend id

If your groundcover account has more than one backend, the API requires an `X-Backend-Id` header naming which backend to query; set `groundcover.backend_id` and the skills send it. Single-backend accounts can omit it. The backend id is shown under Settings > Access > API Keys. Sending it when present is always safe.

### Where to click

1. In groundcover, Settings > Access > Service Accounts. Create a service account named `scoutflo-audit` with the **Viewer** role.
2. Under that service account (or Settings > Access > API Keys), create an API key and copy it once.
3. If your account is multi-backend, note the Backend ID shown alongside the key for `groundcover.backend_id`.
4. For setup work later, create a separate key on an Editor/Admin service account rather than widening this one.

### Export and verify

```bash
# YOU run these in your own terminal; an agent never executes these lines.
printf 'GROUNDCOVER_API_KEY: ' && read -rs GROUNDCOVER_API_KEY && export GROUNDCOVER_API_KEY && printf '\n'

GC_API="https://api.groundcover.com"   # groundcover.api_url
# Listing monitors is the cheapest read and the doctor probe (there is no whoami endpoint).
# Add -H "X-Backend-Id: <backend>" if your account is multi-backend.
curl -fsS --max-time 10 -H "Authorization: Bearer ${GROUNDCOVER_API_KEY}" -H "Content-Type: application/json" \
  -X POST "${GC_API}/api/monitors/list" --data '{"sources":[]}' | jq -e 'type=="array" or type=="object"' >/dev/null \
  && echo "Groundcover PASS" || echo "FAIL: 401 = bad key; 403 = lacks Viewer / wrong X-Backend-Id; or a 200 non-JSON page on a self-hosted host (monitors API not exposed there)"
```

## AWS

### Config

```yaml
aws:
  account_id: "123456789012"                # AWS account ID the audits target (one account per run)
  region: us-east-1                         # default region; multi-region checks state their own region
  # profile: your-aws-profile               # optional; named profile in ~/.aws/config. Omit to use the
  #                                         # active credential chain (env vars, instance role, SSO).
  # role_env: AWS_ROLE_ARN                  # optional; names the variable holding a role ARN to assume
  tier: read-only                           # read-only | elevated; audits require read-only
  # cost_checks: true                       # optional, default true; set false to skip the Cost & Resource
  #                                         # Optimization section even when the cost permissions are present
```

The AWS CLI is a prerequisite for the AWS skills (install AWS CLI v2 from your package manager; `aws --version` is the doctor check). There is no `token_env`: auth rides the AWS credential chain, not a pasted token. `account_id` is quoted so YAML never strips a leading zero. Pick one auth path:

1. **Named profile (recommended on a workstation).** Configure a profile in `~/.aws/config` (SSO or access keys) and set `aws.profile`. Every skill command passes `--profile` and `--region` explicitly, so nothing depends on ambient shell state.
2. **Active credential chain (CI, instance roles).** Leave `profile` unset; the environment variables, instance role, or SSO session already in effect become the identity.
3. **Assumed role.** Set `role_env: AWS_ROLE_ARN` and export that variable with the role ARN; the skills assume it on top of the active chain.

### Scopes per tier

| Tier | Used by | Policy |
| --- | --- | --- |
| Read-only | audit-aws | `cloudwatch:Describe*`/`List*`/`Get*`, `sns:List*`/`Get*`, `rds:Describe*`, `ec2:Describe*`, `ecs:Describe*`/`List*`, `eks:Describe*`/`List*`, `lambda:List*`/`Get*`, `logs:Describe*`, `route53:Get*`/`List*`, `elasticloadbalancing:Describe*`, `cloudtrail:Describe*`/`Get*`, `config:Describe*`, `xray:Get*` |
| Read-only cost (optional) | audit-aws Cost & Resource Optimization section | add `compute-optimizer:Get*`, `ce:Get*`, `cost-optimization-hub:List*`, `support:Describe*` (Trusted Advisor needs Business or Enterprise support) |
| Elevated | setup-aws | the read-only set plus the write actions listed in setup-aws's own doctor gate (`cloudwatch:PutMetricAlarm`, `sns:CreateTopic`/`Subscribe`, `logs:PutRetentionPolicy`, `route53:CreateHealthCheck`, `rds:ModifyDBInstance`, and their paired deletes) |

The managed policy `ReadOnlyAccess` covers the read-only tier but grants far more than these audits need; a customer-managed policy with just the actions above is the least-privilege path. Never hand the audit an admin identity: the audit runs, but records that its credential can write, which is itself a posture gap.

### Where to click

1. Sign in to the AWS console with rights to manage IAM in the target account.
2. IAM > Policies > Create policy: paste the read-only action set above (all with `Resource: "*"`), name it for the tier, for example `scoutflo-audit-readonly`.
3. IAM > Users (or Roles for SSO/assume-role setups) > create or pick the audit identity > attach the policy.
4. For workstation use, create an access key for that identity (or configure SSO) and store it as a named profile: `aws configure --profile scoutflo-audit`.
5. For setup work, create a second identity or role with the elevated policy instead of widening the audit one, and record `tier: elevated` in the block you use for setup runs.

### Export and verify

```bash
# YOU run these in your own terminal; an agent never handles the credentials.
AWS_PROFILE_NAME="your-aws-profile"   # aws.profile; drop the --profile flags below if using the active chain
AWS_ACCOUNT_ID="123456789012"         # aws.account_id
AWS_REGION="us-east-1"                # aws.region

aws sts get-caller-identity --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" --output json \
  | jq -e --arg acct "$AWS_ACCOUNT_ID" '.Account == $acct'
# Expect: exit 0 (prints `true`). A different account means the profile points at
# the wrong account — fix that before any audit runs; doctor enforces this same match.

aws cloudwatch describe-alarms --max-records 1 --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION" >/dev/null \
  && echo "AWS PASS" || echo "FAIL: cloudwatch:DescribeAlarms denied — attach the read-only policy above"
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
# status-probe-ok: quick user sanity-check against monitoring.googleapis.com via a gcloud token (fixed JSON API, no SSO login fall-through); the authoritative gate is /scoutflo:doctor.
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

## ClickStack (ClickHouse + HyperDX)

ClickStack stores telemetry in ClickHouse and fronts it with HyperDX. `audit-clickstack` needs a **read-only ClickHouse user** and a HyperDX **Personal API Access Key**; both are read-only. HyperDX reads go through the **external API v2** (`/api/v2/*`) with the per-user Personal API Access Key (`Authorization: Bearer`) — **not** the team ingestion key, and **not** the internal `/api/*` routes (those are browser-session only and redirect a 401 to the login page). An **optional** login-credential pair is a legacy fallback for instances where you cannot mint a Personal API Access Key — see below.

### Config

```yaml
clickstack:
  clickhouse_url: https://your-clickhouse-host:8123
  clickhouse_user: scoutflo_ro
  clickhouse_password_env: CH_KEY
  hyperdx_url: https://your-hyperdx-host:8080   # the app/UI URL (or the API-server port if exposed)
  hyperdx_api_key_env: HDX_API_KEY              # the PERSONAL API ACCESS KEY (per-user), NOT the ingestion key
  # Optional legacy fallback — only if you cannot mint a Personal API Access Key.
  # A real user login; the audit reads the internal routes via a session cookie:
  # hyperdx_email_env: HDX_EMAIL
  # hyperdx_password_env: HDX_PASSWORD
```

### Create a read-only ClickHouse user

Run as a ClickHouse admin (this is a cluster change; apply it deliberately). It grants `SELECT` on the telemetry database and the `system` tables the audit reads, and nothing else:

```sql
CREATE USER scoutflo_ro IDENTIFIED WITH sha256_password BY '<strong-password>';
GRANT SELECT ON default.* TO scoutflo_ro;   -- use your telemetry database name if not `default`
GRANT SELECT ON system.* TO scoutflo_ro;
```

Then export the password into the variable your config names:

```bash
export CH_KEY='<strong-password>'
```

### Create a HyperDX Personal API Access Key (the read credential)

**HyperDX has two different tokens — use the right one.** The audit reads through the **external API v2** (`/api/v2/alerts`, `/api/v2/dashboards`, `/api/v2/sources`), which authenticates with the per-user **Personal API Access Key** sent as `Authorization: Bearer`. The team **Ingestion API Key** (the OTLP `authorization` header) is a *different* token and returns `401` on the read API — do not use it here.

In HyperDX, open **Team Settings → API Keys** and copy the **"Personal API Access Key"** card (the per-user key; on v2.36+ the section is renamed "API & Agents"). Export it into the variable your config names:

```bash
export HDX_API_KEY='<your-hyperdx-PERSONAL-api-access-key>'
```

Point `clickstack.hyperdx_url` at a URL that reaches the API: either the API-server port directly (then the audit uses `<url>/api/v2/...`) or the app/UI URL that proxies `/api` (the app strips one leading `/api`, so the audit automatically falls back to the doubled `<url>/api/api/v2/...`). The audit probes both forms and uses whichever returns JSON.

> **If the token seems to "ask for email and password":** you (or the tool) hit an **internal** route like `/api/alerts` instead of `/api/v2/alerts`. Internal routes are browser-session only — they ignore the Bearer token and return `401`, and HyperDX's web app then redirects to its login page. Use the `/api/v2/*` path with the Personal API Access Key.

### Optional: HyperDX login credentials (legacy session fallback)

Only if you cannot mint a Personal API Access Key. This is a deliberately **heavier posture** — a real user login. Prefer a dedicated least-privilege HyperDX member account, not an owner account. What the audit does with it (confirmed live): one `POST /api/login/password` with `{email, password}` per run, which answers `303` and sets a `connect.sid` session cookie; the cookie is held in a `mktemp` jar (`chmod 600`), used only for read-only `GET`s on the internal routes, deleted on exit, and never printed, logged, or written anywhere persistent.

```bash
export HDX_EMAIL='<hyperdx-login-email>'
export HDX_PASSWORD='<hyperdx-login-password>'
```

Name both variables in `clickstack.hyperdx_email_env` / `clickstack.hyperdx_password_env`. Skipping this is fine — with a working Personal API Access Key it is not needed, and with neither, the HyperDX categories simply stay `not-in-scope`.

### Verify

```bash
CH_URL="https://your-clickhouse-host:8123"; CH_USER="scoutflo_ro"   # clickstack.clickhouse_url / _user
curl -sS --max-time 10 -H "X-ClickHouse-User: ${CH_USER}" -H "X-ClickHouse-Key: ${CH_KEY}" \
  "${CH_URL}/?query=SELECT%201" | grep -qx 1 && echo "ClickHouse PASS" || echo "ClickHouse FAIL — check url/user/CH_KEY"
# HyperDX: the Personal API Access Key reads the external API v2 (Authorization: Bearer).
# Try the direct path form and the app-proxy-doubled form; a 200 with a JSON body is the pass
# (a 404/HTML means that path form is wrong on this deployment — the other usually answers).
HDX_URL="https://your-hyperdx-host:8080"   # clickstack.hyperdx_url
hdx_pass=0
for b in /api/v2 /api/api/v2; do
  KB="$(mktemp)"; km=$(curl -s -o "$KB" -w '%{http_code} %{content_type}' --max-time 10 -H "Authorization: Bearer ${HDX_API_KEY}" "${HDX_URL%/}${b}/alerts")
  kc="${km%% *}"; kct="${km#* }"
  if [ "$kc" = "200" ] && printf '%s' "$kct" | grep -qi json && jq -e 'type=="array" or has("data") or has("alerts")' "$KB" >/dev/null 2>&1; then
    echo "HyperDX PASS (Personal API Access Key -> ${b}/alerts -> 200 JSON)"; hdx_pass=1; rm -f "$KB"; break
  fi
  rm -f "$KB"
done
[ "$hdx_pass" = 1 ] || echo "HyperDX FAIL — the Personal API Access Key did not return JSON on /api/v2/alerts or /api/api/v2/alerts. Check you used the per-user 'Personal API Access Key' (not the Ingestion key), and that hyperdx_url reaches the API."
```

If you configured the v2 login credentials, verify the session path too (the cookie jar is temporary and never printed):

```bash
HDX_URL="https://your-hyperdx-host:8080"   # clickstack.hyperdx_url
JAR="$(mktemp)"; chmod 600 "$JAR"; trap 'rm -f "$JAR"' EXIT INT TERM
jq -n --arg e "$HDX_EMAIL" --arg p "$HDX_PASSWORD" '{email: $e, password: $p}' \
  | curl -s -o /dev/null --max-time 10 -c "$JAR" -H 'Content-Type: application/json' \
      --data-binary @- "${HDX_URL%/}/api/login/password"
# Assert a JSON body, not just 200 — a session that landed on the SPA/login page also returns 200 + text/html.
HB="$(mktemp)"; hm=$(curl -s -o "$HB" -w '%{http_code} %{content_type}' --max-time 10 -b "$JAR" "${HDX_URL%/}/api/alerts")
hc="${hm%% *}"; hct="${hm#* }"
if [ "$hc" = "200" ] && printf '%s' "$hct" | grep -qi json && jq -e 'type=="array" or has("data") or has("alerts")' "$HB" >/dev/null 2>&1; then
  echo "HyperDX session PASS (200 JSON)"
else echo "HyperDX session FAIL: code=$hc content-type=$hct — a 200 with an HTML body means the login/SPA page, not the API (check HDX_EMAIL/HDX_PASSWORD/url)"; fi
rm -f "$HB"
```

The external `default` ClickHouse user requires a password, so the audit always uses its own scoped `scoutflo_ro` user, never `default`.

## SigNoz (ClickHouse-backed, OpenTelemetry-native)

SigNoz stores telemetry (traces/metrics/logs) in ClickHouse and serves it through its own query-service API. `audit-signoz` authenticates to that API with a **Service Account token** — sent as the `SIGNOZ-API-KEY` header. Optionally, a **read-only ClickHouse user** unlocks the deep backend lane (part counts, disk/capacity, TTL) directly against the `signoz_*` databases; without it those checks read retention via SigNoz's own `GET /api/v1/settings/ttl` and mark the direct-CH checks `not-in-scope`.

> **Role note (confirmed live + at the SigNoz source on v0.138):** the service account needs **at least the read-only `signoz-viewer` role**. `/api/v1/rules`, `/api/v1/channels`, `/api/v2/dashboards`, and `/api/v1/alerts` are wrapped in SigNoz's `ViewAccess` gate, which admits **any** of `signoz-admin` / `signoz-editor` / `signoz-viewer` — so **Viewer is required and sufficient**. Do **not** assign Admin (over-privileged) or assume a custom role is needed. A **403 `authz_forbidden`** (`"only viewers/editors/admins can access this resource"`) means the service account holds **none of those roles** — on v0.138 a service account is created with **zero roles** until you attach one, so the fix is to assign it `signoz-viewer` (Settings → Service Accounts → Roles), not to grant a higher role.

### Config

```yaml
signoz:
  url: https://your-signoz-host
  api_key_env: SIGNOZ_API_KEY
  # Optional — the deep ClickHouse backend lane (SIG-030/060/061). Without these,
  # those checks are not-in-scope and retention is read via the SigNoz TTL settings API.
  # clickhouse_url: https://your-signoz-clickhouse-host:8123
  # clickhouse_user: scoutflo_ro
  # clickhouse_password_env: SIGNOZ_CH_KEY
```

### Create a Service Account token (assign it the `signoz-viewer` role)

On current SigNoz (**v0.114+, including v0.138**) the only token path is **Settings → Service Accounts** — there is **no "API Keys" menu** (only very old builds, ~v0.85–v0.113, had *Settings → API Keys*). Create a service account, then **open it and assign the `signoz-viewer` role** via the Roles dropdown (a service account starts with **zero roles**, so an unroled token gets `403 authz_forbidden` on the read endpoints — that is a missing role, not "Viewer is insufficient"). `signoz-viewer` is read-only and is the least-privilege role that works; do not use Admin. Generate the key and export it into the variable your config names (it is sent as the `SIGNOZ-API-KEY` header):

```bash
export SIGNOZ_API_KEY='<your-signoz-service-account-token>'
```

### Optional: read-only ClickHouse user (deep backend lane)

Run as a ClickHouse admin (a deliberate cluster change). It grants `SELECT` on the SigNoz telemetry databases and `system` tables the audit reads, and nothing else:

```sql
CREATE USER scoutflo_ro IDENTIFIED WITH sha256_password BY '<strong-password>';
GRANT SELECT ON signoz_traces.*  TO scoutflo_ro;
GRANT SELECT ON signoz_metrics.* TO scoutflo_ro;
GRANT SELECT ON signoz_logs.*    TO scoutflo_ro;
GRANT SELECT ON system.*         TO scoutflo_ro;
```

```bash
export SIGNOZ_CH_KEY='<strong-password>'
```

### Verify

```bash
SIGNOZ_URL="https://your-signoz-host"   # signoz.url
# Reachability (open, no auth):
curl -sS --max-time 10 "${SIGNOZ_URL%/}/api/v1/version" | jq -e '.version' >/dev/null && echo "SigNoz reachable" || echo "SigNoz FAIL — check url"
# Token works — assert a JSON body, not just a 200. A moved path / SSO-proxy / login page
# returns 200 + text/html (the SPA), which a status-only check would mis-read as authorized.
SB="$(mktemp)"; META=$(curl -s -o "$SB" -w '%{http_code} %{content_type}' --max-time 15 -H "SIGNOZ-API-KEY: ${SIGNOZ_API_KEY}" "${SIGNOZ_URL%/}/api/v1/rules")
CODE="${META%% *}"; CT="${META#* }"
case "$CODE" in
  200) case "$CT" in application/json*) jq -e 'type=="array" or has("data") or has("rules")' "$SB" >/dev/null 2>&1 && echo "SigNoz token PASS (200 JSON; signoz-viewer sufficient)" || echo "SigNoz token FAIL — 200 but unexpected body";;
       *) echo "SigNoz token FAIL — 200 but Content-Type=$CT (SPA/login fall-through, not the API; check url/version)";; esac ;;
  401) echo "SigNoz token FAIL — 401 (missing/invalid token)";;
  403) echo "SigNoz token FAIL — 403 authz_forbidden (service account has no role — assign it signoz-viewer)";;
  *)   echo "SigNoz token FAIL — got $CODE";;
esac
rm -f "$SB"
```

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

### Fetching a cluster context (managed clusters)

If a managed cluster's context is not in your kubeconfig yet, fetch it once with the provider's CLI. Each command adds a context to your local kubeconfig — a local file change, not a change to the cluster — and every audit still pins `--context`, so nothing trusts the ambient default. EKS, GKE, and AKS are handled the same way:

```bash
CLUSTER="your-cluster"; REGION="your-region"; PROJECT="your-project"
# EKS
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
# GKE
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" --project "$PROJECT"
# AKS — non-admin form runs as your own RBAC-limited identity; never use --admin for audits
az aks get-credentials --name "$CLUSTER" --resource-group "your-resource-group"
```

Use `--zone` in place of `--region` for a zonal GKE cluster or a zonal AKS node scope. Then run `kubectl config get-contexts`, copy the exact name that was added, and write it into `kubernetes.context`.

**AKS with Microsoft Entra (Azure AD) integration** needs `kubelogin` for kubectl to obtain a token — without it, later commands fail with a cryptic exec-plugin error. Install it once, then convert the fetched context to use your Azure CLI login:

```bash
az aks install-cli                          # installs kubelogin (and kubectl) if missing
kubelogin convert-kubeconfig -l azurecli    # only for Entra-integrated AKS contexts
```

AKS clusters configured for local accounts (certificate-based kubeconfig) work with plain `kubectl` and do not need `kubelogin`. Once the context exists, `audit-kubernetes` and `map-topology` treat AKS like any other context — no per-provider handling.

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

## GitHub

### Config

```yaml
github:
  org: your-org                             # GitHub org or user login
  token_env: GITHUB_TOKEN                   # env var holding the personal access token
  tier: read-only                           # tier of the token behind token_env: read-only or elevated
```

### Scopes per tier

| Tier | Used by | Token type |
| --- | --- | --- |
| Read-only | map-repos | Fine-grained PAT with `Contents: Read-only` and `Metadata: Read-only` on the target org/repos, or a classic PAT with the `repo` scope (read) if any target repo is private. Public-only repos need no scope on a classic PAT. |

map-repos never writes to GitHub; there is no elevated tier for this integration.

### Where to click

1. Sign in to GitHub.
2. Settings > Developer settings > Personal access tokens > Fine-grained tokens (recommended) or Tokens (classic).
3. Fine-grained: set Resource owner to your org, Repository access to the repos map-repos should see (or "All repositories"), and under Repository permissions set `Contents` and `Metadata` to Read-only. Classic: check the `repo` scope only if any target repo is private.
4. Set an expiry (90 days is an example, tune to your rotation policy). Copy the token once; it is not shown again.

### Export and verify

```bash
# YOU run this in your own terminal; an agent never executes this line.
printf 'GITHUB_TOKEN: ' && read -rs GITHUB_TOKEN && export GITHUB_TOKEN && printf '\n'

GITHUB_ORG="your-org"   # github.org
# status-probe-ok: quick user sanity-check against api.github.com (fixed vendor JSON API, no SSO login fall-through); the authoritative gate is /scoutflo:doctor.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${GITHUB_TOKEN}" "https://api.github.com/orgs/${GITHUB_ORG}")
[ "$code" = "200" ] && echo PASS || echo "FAIL: got $code"
# Expect: PASS. 404 here is normal for a personal account rather than an org --
# map-repos falls back to the /users/{login} path automatically. 401 means the
# token is wrong or expired.
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
