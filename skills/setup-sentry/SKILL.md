---
name: setup-sentry
description: Guided hardening of a Sentry org from audit findings. Creates projects, seeds environments, applies privacy scrubbing, wires two-tier alert routing, and configures monitors. States each change, waits for your confirmation, then verifies live. Use when the user asks to fix a SNTRY-NNN finding, wire up Sentry alert routing or integrations (Slack, PagerDuty, GitHub), apply privacy scrubbing or rate-limit hardening, set up releases and source maps, or harden monitor/cron and uptime check-ins. Do not use for Grafana dashboards that display Sentry data (use setup-lgtm or setup-grafana), for proving the Alertmanager paging path reaches a human (use audit-alertmanager), or for read-only assessment (use audit-sentry).
disable-model-invocation: true
---

# setup-sentry

Fixes findings from an `audit-sentry` run. Input is one or more finding IDs from the latest `./scoutflo-audits/sentry/<date>/findings.json`. You usually arrive here from a finding's `remediation` pointer, for example `setup-sentry#privacy-gates`. Starting from scratch works too: this skill can also stand up a greenfield org (zero projects or a bare default project), but run `audit-sentry` first anyway. It produces the baseline score, the finding IDs, and the coverage gaps this skill closes.

| Finding ID | Fix section |
| --- | --- |
| SNTRY-001 | [Alert rule taxonomy](#alert-rule-taxonomy), [Delete the auto-created default rule](#delete-the-auto-created-default-rule) |
| SNTRY-002 | [Privacy gates](#privacy-gates) |
| SNTRY-003 | [Privacy gates](#privacy-gates) |
| SNTRY-004 | [Environment seeding](#environment-seeding) |
| SNTRY-005 | [Receiver wiring](#receiver-wiring) |
| SNTRY-006 | [Releases and source maps](#releases-and-source-maps) |
| SNTRY-007 | [Cron and uptime monitors](#cron-and-uptime-monitors) |
| SNTRY-008 | [Privacy gates](#privacy-gates), [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion) |
| SNTRY-009 | [GitHub integration and code mappings](#github-integration-and-code-mappings) |
| SNTRY-010 | [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion) |
| SNTRY-011 | [Receiver wiring](#receiver-wiring) |
| SNTRY-012 | [Projects](#projects) |
| SNTRY-013 | [Alert rule taxonomy](#alert-rule-taxonomy) |
| SNTRY-014 | [Alert rule taxonomy](#alert-rule-taxonomy) |

In scope: the Sentry account layer. Projects, environments, privacy and rate-limit hardening, issue alert rules and their routing, integrations (Slack, PagerDuty, GitHub), releases and source maps, cron and uptime monitors, and the SDK instrumentation notes for your app team. Boundaries:

- Grafana dashboards that display Sentry data belong to `setup-grafana`.
- The Alertmanager paging path belongs to `audit-alertmanager`; here you judge and fix only Sentry's own alert wiring.
- Application code changes (installing an SDK, adding an init snippet) happen in your app repo. This skill produces the exact snippet and env vars in `references/sdk-instrumentation.md`; it never touches app code itself.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the API call and payload with real values filled in (secrets as env-var names, never values), plus its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with a machine-checkable command: a `jq -e` test on the re-fetched object, or a captured HTTP code compared against its stated `Expect:` line. A write is unverified until a command proves it; "confirm the field holds the value" as prose is not verification.
5. **Record.** Append the change, its verification evidence, and any pending items with a named owner to the change record.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-fetch the failed object's current state, record which earlier rows in the batch already applied (and where their backups live), and never continue past the failed row. Diagnose the failure, then re-announce the remaining rows for a fresh approval; the earlier approval does not carry over to a re-announced plan.

## Doctor gate

This skill uses the elevated credential tier: it creates and modifies Sentry projects, rules, and monitors. Keep this token separate from your read-only audit token; `audit-sentry` checks the audit token for least privilege, and a shared elevated token would fail that check for a reason.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Sentry | `sentry.host`, `sentry.org`, `sentry.token_env` | named by `sentry.token_env` | the read set (`org:read`, `project:read`, `event:read`, `alerts:read`) plus `project:write`, `alerts:write`, `org:write` for the full fix set | elevated |
| Slack (optional) | `slack.webhook_env` | named by `slack.webhook_env` | post to one incoming webhook, for the run summary only | optional |

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host: us.sentry.io, de.sentry.io, or your self-hosted host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
# sentry.token_env names the variable; presence check only, never print the value.
[ -f "$HOME/.scoutflo/toolkit.yaml" ] || { echo "missing ~/.scoutflo/toolkit.yaml; run /scoutflo:connect"; exit 1; }
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
command -v curl >/dev/null || { echo "curl is required"; exit 1; }
command -v jq   >/dev/null || { echo "jq is required"; exit 1; }

curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/" | jq -e '.slug != null and .name != null'
```

Expect: exit 0, and the org `slug`/`name` are visible in the response. A `401` means the token is wrong for this host; a `404` almost always means the wrong region host, not a missing org (run the region probe in `/scoutflo:connect`, fix `sentry.host`, retry). Write permission is proven only by the first write: if any announced change returns `403`, stop, report the missing scope from the table above, and reconnect with an elevated token. Never proceed past a failed doctor check.

## Live-safety gate

This gate must be able to fail. It never derives the "live" value from the same config value it is checking against; it fetches an independent, org-agnostic view of what this token can actually reach and compares that to config.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"        # sentry.host
CONFIG_SENTRY_ORG="your-org-slug" # sentry.org, exactly as written in toolkit.yaml
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# Independent live fetch: list every org this token can actually reach.
# CONFIG_SENTRY_ORG is never passed into this request, so it cannot pass by
# construction the way "echo the config back at itself" can.
LIVE_ORGS="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/")"
echo "target: ${API}"
echo "configured org (sentry.org): ${CONFIG_SENTRY_ORG}"
printf '%s' "$LIVE_ORGS" | jq -r '.[] | "live-visible org: \(.slug)\t\(.name)"'

printf '%s' "$LIVE_ORGS" | jq -e --arg cfg "$CONFIG_SENTRY_ORG" 'any(.[]; .slug == $cfg)'
```

Expect: exit 0, and `configured org` appears in the printed `live-visible org` list. If the assertion fails, or the live list is empty, or it lists only orgs with a different slug (a sandbox or personal org with a similar name), stop and report the mismatch. Never proceed on "probably the right org" and never edit this block to accept a close-enough slug.

- ❌ `echo "target: ${API} org: ${SENTRY_ORG}"` where `SENTRY_ORG` was itself read from `sentry.org` two lines earlier: this compares config against itself and can never fail, even when the token is bound to the wrong org.
- ✅ Fetch `GET /organizations/` (no org slug in the request) and assert the configured slug appears in that independently-fetched list; a token scoped to the wrong org fails this by construction.

Load `./scoutflo-audits/topology.md` if it exists; its service list defines which services need project coverage and alert tiers below, under its canonical names. If it does not exist, suggest `/scoutflo:map-topology` before building coverage claims.

## Load findings and build the change plan

1. Read the latest audit run and list open findings:

```bash
set -eu
LATEST_RUN="$(ls -d ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/[0-9]*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || echo "no audit run found; running greenfield setup without a findings baseline"
[ -z "$LATEST_RUN" ] || jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
```

2. Select scope. Take the finding IDs you were asked to fix, or, if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section above.

3. Create the working directory:

```bash
set -eu
RUN_DATE="$(date -u +%F)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
CHANGE_LOG="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/changes.md"
mkdir -p "$BACKUP_DIR"
echo "backups: ${BACKUP_DIR}"
```

Every write section below captures its own backup immediately before the write: a real `GET ... > "${BACKUP_DIR}/<object>.json"` for updates on existing objects, run in the same block as the write it protects. A "backup" is a saved file on disk, never a sentence claiming one exists. `./scoutflo-audits/` stays out of version control.

4. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Exact change | Rollback |
| --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown; deletions (a rule, a monitor, a code mapping) are still re-confirmed individually at their own announcement, never inside a batch. A decline ends the run with zero changes, per the change protocol.

Execute approved rows one at a time, verifying each before starting the next, per the mid-batch failure rule above. Order: projects before environments before rules; hardening before alert wiring; additive changes before destructive ones (rule deletion, monitor pausing).

## Projects

For SNTRY-012 (a service with no Sentry project) or a greenfield build. Decide project boundaries by runtime ownership, not by copying another org's layout:

| Pattern | Use when |
| --- | --- |
| One project per runtime boundary | Small systems: a handful of services, workers, or edge functions |
| One project per platform | Frontend, backend, and mobile clients differ enough in SDK and noise profile to separate |
| Shared backend project plus a `service` tag | Many small, similar microservices, where per-project sprawl would out-cost the isolation benefit |

Create with `defaultRules: false` always: it is the single highest-leverage flag in this whole skill, because Sentry auto-creates a notify-everyone rule on every project it is missing from.

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"   # sentry.host
SENTRY_ORG="your-org-slug"   # sentry.org
API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

TEAM="your-team-slug"          # a team slug from GET /organizations/${SENTRY_ORG}/teams/
PROJECT_NAME="checkout"        # the service or app name
PLATFORM="node"                # see references/api-cookbook.md#platform-values

curl -fsS --max-time 10 -X POST "${API}/teams/${SENTRY_ORG}/${TEAM}/projects/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "$PROJECT_NAME" --arg p "$PLATFORM" \
    '{name: $n, platform: $p, defaultRules: false}')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT_NAME}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg p "$PLATFORM" '.platform == $p'
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT_NAME}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e 'length == 0'
```

Expect: both `jq -e` calls exit 0; the second prints `true` because the rules list is empty, not the auto-created notify rule. **Rollback** (this is a create, so rollback is delete-and-verify-absence, not a restore from backup):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT_NAME="checkout"   # the project just created

curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT_NAME}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${PROJECT_NAME}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

## Environment seeding

For SNTRY-004. A project with no environments cannot scope alerts or releases to production, so every rule fires on dev noise too. Sentry environments exist only once an event carries that environment name; on a greenfield project with no SDK yet, seed them with a single envelope event per environment. Full payload, byte-length handling, and DSN retrieval in [references/api-cookbook.md#environment-seeding](references/api-cookbook.md#environment-seeding).

Seed `production` and `staging` (or your actual promotion stages) on every project. This is additive (one low-noise event) and has no meaningful rollback beyond leaving the seeded environment unused; nothing to restore.

Verify:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; ENV_NAME="production"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/environments/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg e "$ENV_NAME" 'any(.[]; .name == $e)'
```

Expect: exit 0. Allow a few seconds for ingestion before the read; retry once on failure before treating it as a real gap.

## Privacy gates

For SNTRY-002 (privacy scrubbing off), SNTRY-003 (unlimited client keys), and SNTRY-008 (quota pressure with no rate limit in place). PII that reaches Sentry cannot be unsent, so this section runs before any project sends real traffic.

This is the worked backup-and-restore pair for this skill: a real `GET`-before-write capture, and a real restore command that PUTs the exact backed-up body back.

For each project:

```bash
set -eu
# Resolved from ~/.scoutflo/toolkit.yaml
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

PROJECT="checkout"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/project-${PROJECT}-$(date -u +%H%M%S).json"

# 1. Backup (GET-before-write), run as written:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

# 2. The write, announced with real values before it runs:
curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "dataScrubber": true,
    "dataScrubberDefaults": true,
    "scrubIPAddresses": true,
    "scrapeJavaScript": false,
    "sensitiveFields": [
      "email", "password", "secret", "token", "api_key", "authorization",
      "cookie", "otp", "pin", "phone", "mobile", "code", "database_url",
      "dsn", "client_secret", "refresh_token", "access_token", "session"
    ]
  }'

# 3. Verify by re-fetch, machine-checkable:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.dataScrubber == true and .dataScrubberDefaults == true and .scrubIPAddresses == true
           and .scrapeJavaScript == false and (.sensitiveFields | index("dsn")) != null'
```

Expect: the backup file is non-empty, and the final `jq -e` exits 0. Add domain-specific field names your app actually sends to the `sensitiveFields` list; the starting list is in [references/api-cookbook.md#sensitive-fields](references/api-cookbook.md#sensitive-fields).

**Restore pair, run as written when this write must be undone:**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/project-checkout-HHMMSS.json"  # the step-1 backup

# Sentry's project PUT accepts a partial body; restore only the fields this
# section touched, taken byte-for-byte from the backup.
jq '{dataScrubber, dataScrubberDefaults, scrubIPAddresses, scrapeJavaScript, sensitiveFields}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" \
      '.dataScrubber == $b[0].dataScrubber and .sensitiveFields == $b[0].sensitiveFields'
```

Expect: exit 0, the fields byte-equal to the backup. A restore is itself a change; announce and record it like any other.

Apply a rate limit to every active client key the same way: backup, write, verify, and keep the restore command alongside it.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"
KEY_ID="your-key-id"           # from GET /projects/${SENTRY_ORG}/${PROJECT}/keys/
KEY_RATE_LIMIT="1000"          # example, tune to your expected event volume
KEY_RATE_WINDOW="60"           # seconds; example
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/key-${KEY_ID}-$(date -u +%H%M%S).json"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --argjson limit "$KEY_RATE_LIMIT" --argjson window "$KEY_RATE_WINDOW" \
    '{rateLimit: {window: $window, count: $limit}}')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson limit "$KEY_RATE_LIMIT" '.rateLimit.count == $limit'
```

Expect: exit 0. Restore: `jq '{rateLimit}' "$BACKUP_FILE"` piped into the same `PUT`, verified with `jq -e --slurpfile b "$BACKUP_FILE" '.rateLimit == $b[0].rateLimit'` against the re-fetched key. An unlimited key means one crash loop or one leaked DSN burns the whole quota and drowns real errors, so `KEY_RATE_LIMIT`/`KEY_RATE_WINDOW` are examples to tune, not universal constants.

## Alerting model decision

Decide before creating any rule, and record the decision:

| Model | Use when |
| --- | --- |
| Project issue rules (legacy) | The default choice: broad compatibility, stable API, email/Slack/PagerDuty actions, works on every org |
| Workflow-engine alerts | Your org has the newer Monitors and Alerts workflow UI/API enabled and you deliberately want workflow automation across issue state and priority |

Project issue rules are what the rest of this section builds. If you use workflow-engine alerts instead, resolve every ID against the live `/organizations/${SENTRY_ORG}/workflows/` schema before writing payloads; that endpoint is feature-gated and 404s on many orgs.

## Alert rule taxonomy

For SNTRY-001, SNTRY-013, SNTRY-014. Build a small, severity-based rule set per project, not one rule per person and not one rule per every possible condition. Two tiers, each routed to a receiver your team actually watches (channel names below are placeholders, pick your own):

| Tier | Fires on | Example receiver | Frequency |
| --- | --- | --- | --- |
| Immediate | Fatal events, new unhandled errors, regressions, escalations, user-impact and error-surge thresholds | `#SENTRY_IMMEDIATE_CHANNEL` | as low as 5 minutes for fatal, 30-60 minutes for threshold rules |
| Review | First-seen issues, frequency trends, warning-level signals | `#SENTRY_REVIEW_CHANNEL` | 60 minutes or your working-hours cadence |

Every production project needs at least one rule in each tier before it counts as covered. Condition, filter, and action ID tables, the full rule-payload example, and the environment-scoping fix (use the rule-level `environment` field, never `LatestAdoptedReleaseFilter`, which filters by release-adoption stage and silently does not scope by environment) are in [references/api-cookbook.md#alert-rules](references/api-cookbook.md#alert-rules).

Start every rule with the email action (works with no integration required); add Slack or PagerDuty actions once that integration is live, in Receiver wiring below. Thresholds (`USER_IMPACT_THRESHOLD`, `ERROR_SURGE_THRESHOLD`, `FREQ_FLOOR_MIN`, and the rest) are starting points from the reference table; tune every one to your event volume before treating it as final.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"

NEW_RULE="$(curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d @rule-payload.json)"   # payload shape in references/api-cookbook.md#full-rule-payload-example
RULE_ID="$(printf '%s' "$NEW_RULE" | jq -r '.id')"
echo "created rule: ${RULE_ID}"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.conditions != null and .actions != null and (.actions | length) >= 1'
```

Expect: exit 0. **Rollback** (this is a create; rollback deletes and verifies absence):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"   # the rule just created

curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg id "$RULE_ID" '[.[] | select(.id == $id)] | length == 0'
```

Expect: exit 0.

## Delete the auto-created default rule

For SNTRY-001 on any project that predates `defaultRules: false`, or where it was omitted. New projects get a "Send a notification for high priority issues" rule with `createdBy: null`. Find it, back up its full body, confirm the match, delete it, then verify the list no longer contains it:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -r '.[] | select((.createdBy == null) and (.name | ascii_downcase | contains("high priority"))) | "\(.id)\t\(.name)"'

RULE_ID="12345678"   # from the line above; confirm it before deleting
BACKUP_FILE="${BACKUP_DIR}/default-rule-${RULE_ID}.json"
# 1. Backup the exact rule body (GET-before-write), so it can be recreated:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

# 2. The write:
curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"

# 3. Verify by re-fetch:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg id "$RULE_ID" '[.[] | select(.id == $id)] | length == 0'
```

Expect: exit 0. Confirmed live: this delete succeeds with just `alerts:write` — no `project:admin` scope is actually required, contrary to an earlier version of this doc; a token that has `alerts:write` but lacks `project:write` can still delete this rule the same as any other issue alert rule.

**Restore pair**, run as written if something depended on this rule and it needs to come back:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/default-rule-12345678.json"  # the step-1 backup

jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" 'any(.[]; .name == $b[0].name)'
```

Expect: exit 0. Deleting a rule is a lightweight change, but it is still confirmed individually, never inside a batch.

Confirmed live: a restored default rule is not byte-identical to the original. Sentry assigns `createdBy` from the requesting token's identity on every `POST`, so the restored rule's `createdBy` is the setup identity, not the original `null` that marks an untouched, auto-created rule. This means the `createdBy == null` signature this section uses to find the rule in the first place will no longer match a restored copy — a future run treats it as a normal, manually-created rule, not the auto-created default. Note this in the change record so nobody expects a future automated pass to re-detect a restored rule the same way.

## Receiver wiring

For SNTRY-005 (rules whose only action is email, a temporary path, not a proven route) and SNTRY-011 (duplicate alerting paths).

- **Slack.** Once the Slack integration is connected, resolve the integration ID and the channel ID (not just the display name), back up the current rule body, then add a Slack action to it alongside its existing email action with a full-payload `PUT`: Sentry replaces the rule on write, so the request body must include every existing field, not only the new action.
- **PagerDuty.** Same pattern: resolve the integration and service ID, back up the rule, add the PagerDuty action alongside email, full-payload `PUT`. Payload in [references/api-cookbook.md#alert-rules](references/api-cookbook.md#alert-rules).
- **Duplicate paths (SNTRY-011).** Pick one primary alerting surface per signal. If Sentry uptime monitors duplicate an external synthetic tool, or if an issue rule duplicates a metric alert on the same condition, disable one side and record which system is the source of truth.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout"
RULE_ID="12345678"
SLACK_INTEGRATION_ID="your-integration-id"   # from GET /organizations/${SENTRY_ORG}/integrations/?provider_key=slack
SLACK_CHANNEL="your-channel-name"
SLACK_CHANNEL_ID="your-channel-id"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/rule-${RULE_ID}-$(date -u +%H%M%S).json"

# 1. Backup (GET-before-write), run as written:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" && echo "backup: ${BACKUP_FILE}"

# 2. Patch the actions array from the backup, full-payload PUT:
UPDATED="$(jq --arg ws "$SLACK_INTEGRATION_ID" --arg ch "$SLACK_CHANNEL" --arg cid "$SLACK_CHANNEL_ID" \
  '.actions += [{
    id: "sentry.integrations.slack.notify_action.SlackNotifyServiceAction",
    workspace: $ws, channel: $ch, channel_id: $cid,
    tags: "environment,user,release,os,transaction,level"
  }] | {name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE")"

curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$UPDATED"

# 3. Verify by re-fetch, machine-checkable:
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg cid "$SLACK_CHANNEL_ID" \
      '.actions | any(.id == "sentry.integrations.slack.notify_action.SlackNotifyServiceAction" and .channel_id == $cid)'
```

Expect: the backup file is non-empty, and the final `jq -e` exits 0 confirming `channel_id` resolved to a real ID, not just that a Slack action of some kind is present. **Restore pair**, run as written to undo this wiring change:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"; RULE_ID="12345678"
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups/rule-12345678-HHMMSS.json"  # the step-1 backup

jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '.actions == $b[0].actions'
```

Expect: exit 0. A rule that lists a Slack action is `configured`; only a delivered test notification proves the receiver is live. Send one low-risk test event once wiring is approved and re-confirmed (`POST /projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/tasks/` or the rule's test-fire endpoint on your API version), and record who confirmed receipt in the change log; do not mark SNTRY-005/SNTRY-011 fixed on the `jq -e` above alone.

## GitHub integration and code mappings

For SNTRY-009. A repo integration without code mappings resolves nothing, and a code mapping whose `defaultBranch` differs from the branch you actually deploy resolves the wrong file. Treat the three pieces as a chain:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

# 1. Confirm the GitHub integration is connected:
curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/integrations/?provider_key=github" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e 'length >= 1'
```

Expect: exit 0. List available repos and create a code mapping per project, with `defaultBranch` set to the branch that is actually deployed, not the repository's configured default if they differ (payload in [references/api-cookbook.md#code-mappings](references/api-cookbook.md#code-mappings)):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT_ID="your-project-id"; REPO_ID="your-repo-id"; DEPLOYED_BRANCH="main"

NEW_MAPPING="$(curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/code-mappings/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROJECT_ID" --arg r "$REPO_ID" --arg b "$DEPLOYED_BRANCH" \
    '{projectId: $p, repoId: $r, defaultBranch: $b, stackRoot: "", sourceRoot: ""}')")"
MAPPING_ID="$(printf '%s' "$NEW_MAPPING" | jq -r '.id')"
echo "created mapping: ${MAPPING_ID}"

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg b "$DEPLOYED_BRANCH" '.defaultBranch == $b'
```

Expect: exit 0. Then check a recent release's commit linkage: `deployCount > 0` with `commitCount == 0` means suspect-commit attribution still has no data even though the integration looks connected.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/releases/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.[0] | (.deployCount // 0) == 0 or (.commitCount // 0) > 0'
```

Expect: exit 0. A failing assertion here is evidence to record, not silence: it means CI creates releases but never links commits, so file it as a pending CI item. **Rollback** (a code mapping is a create; rollback deletes and verifies absence):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
MAPPING_ID="your-mapping-id"   # the mapping just created

curl -fsS --max-time 10 -X DELETE "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

## Cron and uptime monitors

For SNTRY-007. Create a monitor per scheduled job, disabled until the job actually emits check-ins; an active monitor with zero check-ins is a false-page risk, not coverage.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
MONITOR_SLUG="nightly-data-sync"
PROJECT="backend-services"
CRON_SCHEDULE="0 2 * * *"      # example; use the scheduler's real crontab
CRON_TIMEZONE="UTC"            # example; use the timezone your scheduler actually runs in

curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/monitors/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg name "$MONITOR_SLUG" --arg proj "$PROJECT" --arg slug "$MONITOR_SLUG" \
        --arg sched "$CRON_SCHEDULE" --arg tz "$CRON_TIMEZONE" \
    '{name: $name, project: $proj, slug: $slug, status: "disabled",
      config: {schedule_type: "crontab", schedule: $sched, checkin_margin: 5,
               max_runtime: 30, failure_issue_threshold: 2, recovery_threshold: 1, timezone: $tz}}')"

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '.status == "disabled"'
```

Expect: exit 0. Enable the monitor only after you observe `in_progress`, `ok`, and `error` check-ins from the real job:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
MONITOR_SLUG="nightly-data-sync"

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/checkins/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '[.[].status] as $s | ($s | index("ok")) and ($s | index("error")) and ($s | index("in_progress"))'

curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d '{"status": "active"}'
curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e '.status == "active"'
```

Expect: exit 0 on the final assertion. Check-in URL format and rate limits are in [references/api-cookbook.md#monitors](references/api-cookbook.md#monitors). **Rollback** (create; rollback deletes and verifies absence):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
MONITOR_SLUG="nightly-data-sync"

curl -fsS --max-time 10 -X DELETE "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

For uptime monitors, use `intervalSeconds` from the fixed set `300, 600, 1800, 3600` (all other values are rejected); create-verify-rollback payload in [references/api-cookbook.md#monitors](references/api-cookbook.md#monitors). Before creating one, confirm no other tool already owns uptime for that endpoint: duplicating an existing synthetic check is an SNTRY-011 finding waiting to happen.

## Releases and source maps

For SNTRY-006. Agree one release-naming convention (git SHA or semantic version) and set it as `SENTRY_RELEASE` in the runtime environment before the app team deploys. This skill does not upload source maps itself; that runs in your CI/CD pipeline, from the release-naming convention this section sets. You can, however, verify whether previously uploaded maps are resolving:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
PROJECT="checkout-web"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/issues/?query=is:unresolved&sort=date&limit=1" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -r '.[0].id'
```

Sample the latest issue's most recent event and inspect its in-app stack frames (`GET /organizations/${SENTRY_ORG}/issues/<ISSUE_ID>/events/latest/`). Bundled filenames like `bundle.js` or minified chunk names with no source context mean maps are not resolving, whatever the CI pipeline claims:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/issues/your-issue-id/events/latest/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '[.entries[]? | select(.type == "exception") | .data.values[]?.stacktrace.frames[]? | .context // []] | flatten | length > 0'
```

Expect: exit 0 (in-app frames carry source context) on a project where maps should be resolving; a failure here, on a real recent event, is the SNTRY-006 evidence, not an inconclusive read. Compare `deployCount` and `commitCount` on the latest release the same way as [GitHub integration and code mappings](#github-integration-and-code-mappings); deploys without commit association mean CI creates releases but never links commits, so suspect-commit attribution has no data.

Record the CI-side steps your team still owns (source-map or debug-ID upload, keeping the upload token in CI secrets only) as pending items with a named owner; this skill cannot execute a change in your build pipeline.

## Quota, spike protection, and privacy-sensitive ingestion

For SNTRY-008 and SNTRY-010. These are decisions to record, most of them not API writes; where a live check exists, it is machine-checked, not just inspected.

- **Quota pressure (SNTRY-008).**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/stats_v2/?field=sum(quantity)&groupBy=outcome&interval=1d&statsPeriod=7d" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e '[.groups[]? | select(.by.outcome == "rate_limited" or .by.outcome == "cardinality_limited") | .totals."sum(quantity)"] | add // 0 | . == 0'
```

Expect: exit 0 (no rate-limited or cardinality-limited volume in the last 7 days). A nonzero total is real evidence: raise the client-key rate limit ([Privacy gates](#privacy-gates)) only after confirming the new ceiling fits your plan's quota, or reduce trace/replay sampling first if the volume is from those categories rather than errors.

- **Privacy-sensitive ingestion (SNTRY-010).**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/stats_v2/?field=sum(quantity)&groupBy=category&interval=1d&statsPeriod=7d" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -r '.groups[]? | select(.by.category == "replay" or .by.category == "profile" or .by.category == "log") | "\(.by.category): \(.totals."sum(quantity)")"'
```

Accepted volume in replay, profile, or log categories (a nonzero total from the command above) proves the feature is live; live without a recorded decision is the finding. For each category enabled, write the masking, consent, and retention decision into the change record. Replay defaults to masked text and blocked media until your team makes an explicit, reviewed exception; AI prompt/response capture (`recordInputs`/`recordOutputs`, `send_default_pii`) stays off until the same review happens. These posture defaults carry into the app team's SDK snippets in `references/sdk-instrumentation.md`.

## SDK instrumentation notes

Once the account side above is live, write the exact SDK snippets your app team needs into `./scoutflo-audits/sentry/sdk-instrumentation.md`, using the platform-matched templates in [references/sdk-instrumentation.md](references/sdk-instrumentation.md). Fill in the real DSN per project (never a placeholder) and the environment names you seeded. This skill does not touch app code; it produces exactly what someone needs to paste into their own runtime and verify.

These notes are not "done" until a real or controlled event lands with the intended `environment`, `release`, and tags: mark it `pending app deploy` until that event is observed, and revisit with a fresh `audit-sentry` run once it lands.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed>
- Command: <exact call and payload applied, secrets as env-var names>
- Verified: <the read-back jq -e command or http_code check and its result>
- Rollback: <the exact restore/delete command, or the backup file path it reads from>
- Pending: <item> (owner: <team or person>)
```

Before calling the run done, check: every touched project re-fetched with a passing `jq -e` on scrubbers and sensitive fields; every touched rule re-fetched with a passing `jq -e` on its conditions, filters, actions, and environment scope; every wired receiver has a confirmed test-notification receipt or is explicitly `pending`; every monitor is `disabled` until real check-ins are observed, or its enablement is backed by a passing check-in assertion; the SDK instrumentation notes have real DSNs and no placeholder values; every change has a passing verification command and a runnable rollback command (not a rollback sentence) in the log; if any row of a batch failed, confirm the batch stopped there and the remainder was re-announced, per the mid-batch failure rule.

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's reach (app-side instrumentation, CI/CD source-map uploads, receiver channel creation), each with a named owner.
3. A fresh `/scoutflo:audit-sentry` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Live-safety gate compares config against itself | Fetch an org-agnostic live list (`GET /organizations/`) that never takes the configured org as input, and assert the configured slug appears in it |
| New project gets the noisy auto-created default rule | Always create with `defaultRules: false`; verify the rules list is empty right after creation with `jq -e 'length == 0'` |
| `error.unhandled` filter never matches | Use `match: "is"` (is set), not `match: "eq"` with a value |
| `http.status_code` starts-with filter rejected | `value` must be an integer (`5`), not a string (`"5"`) |
| Environment scoping silently does nothing | Use the rule-level `environment` field; `LatestAdoptedReleaseFilter` filters by release-adoption stage, not environment |
| Email action rejected with "user is not part of the project" | Use `targetType: "IssueOwners"` with `fallthroughType: "AllMembers"`, never `targetType: "Member"` with a raw user ID |
| Envelope event rejected with a header/length mismatch | Compute the envelope `length` field as the exact byte count of the payload line; never hardcode it |
| Slack action PUT silently drops existing conditions or the email action | The rules endpoint replaces the whole object on write; fetch the current rule into a backup file, patch the actions array, PUT the full body back |
| Rule declared wired because the action type is present | Re-fetch and assert `channel_id`/`service` resolve to real IDs with `jq -e`, then send one test notification and record who confirmed receipt |
| Cron monitor left active with zero check-ins | Create monitors `disabled`; enable only after a passing `jq -e` assertion on observed `in_progress`, `ok`, and `error` check-ins |
| Uptime monitor creation fails | `intervalSeconds` accepts only 300, 600, 1800, or 3600 |
| Code mapping resolves the wrong file | Set `defaultBranch` to the branch actually deployed, not the repository's configured default, when they differ |
| Source maps "uploaded" but stack traces stay minified | Assert in-app stack frames carry source context on a real recent event with `jq -e`, not a visual skim |
| PII reaches Sentry before scrubbing is confirmed | Backup, apply, and re-fetch scrubbers and sensitive fields with a passing `jq -e` before any project accepts real production traffic |
| Replay or AI capture enabled without a privacy decision | Keep masking, PII capture, and prompt/response recording off by default; require an explicit, recorded exception per project |
| Batch continues past a failed write | Mid-batch failure rule: stop immediately, record what already applied and its backups, re-announce the remainder for a fresh approval |
| Rollback claimed without a runnable command | Every write section carries its own backup file and a restore/delete command that a reader can paste and run, never a rollback sentence alone |
