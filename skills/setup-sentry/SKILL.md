---
name: setup-sentry
description: Guided hardening of a Sentry org from audit-sentry findings (projects, environments, scrubbing, alert rules and routing, monitors); announces each change, waits for confirmation, then verifies live. Use when the user asks to fix a SNTRY-NNN finding, wire Sentry alerts to Slack or PagerDuty, clean up noisy Sentry alert rules, turn on PII scrubbing or key rate limits, check source maps, or set up cron or uptime monitors. Do not use for Grafana dashboards of Sentry data (use setup-grafana) or for read-only assessment (use audit-sentry).
disable-model-invocation: true
---

# setup-sentry

Fixes findings from an `audit-sentry` run. Input is one or more finding IDs from the latest `./scoutflo-audits/sentry/<date>/findings.json` (`sentry/<label>/<date>/` for a labeled multi-target config). You usually arrive here from a finding's `remediation` pointer, for example `setup-sentry#privacy-gates`. Starting from scratch works too: this skill can also stand up a greenfield org (zero projects or a bare default project), but run `audit-sentry` first anyway. It produces the baseline score, the finding IDs, and the coverage gaps this skill closes.

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
| SNTRY-015 | [Alerting model decision](#alerting-model-decision) |
| SNTRY-016 | [Alert rule taxonomy](#alert-rule-taxonomy) |
| SNTRY-017 | [Receiver wiring](#receiver-wiring) |
| SNTRY-018 | [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion), [Privacy gates](#privacy-gates) |
| SNTRY-019 | [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion), [Privacy gates](#privacy-gates) |
| SNTRY-020 | [Releases and source maps](#releases-and-source-maps) |
| SNTRY-021 | [GitHub integration and code mappings](#github-integration-and-code-mappings) |
| SNTRY-022 | [GitHub integration and code mappings](#github-integration-and-code-mappings) |
| SNTRY-023 | [Cron and uptime monitors](#cron-and-uptime-monitors) |
| SNTRY-024 | [Projects](#projects), [SDK instrumentation notes](#sdk-instrumentation-notes) |
| SNTRY-025 | [Environment seeding](#environment-seeding) |
| SNTRY-101 | [Alert rule taxonomy](#alert-rule-taxonomy) |
| SNTRY-102 | [Alert rule taxonomy](#alert-rule-taxonomy), [Map rules to environments by receiver channel, not by rule name](#map-rules-to-environments-by-receiver-channel-not-by-rule-name) |
| SNTRY-103 | [Alert rule taxonomy](#alert-rule-taxonomy) |
| SNTRY-104 | [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion) |
| SNTRY-105 | [Quota, spike protection, and privacy-sensitive ingestion](#quota-spike-protection-and-privacy-sensitive-ingestion) |
| SNTRY-106 | [Alert-rule remediation playbook](#alert-rule-remediation-playbook) |
| SNTRY-107 | [Slow noisy tiers, keep fast tiers fast, never age-gate regressions](#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions) |
| SNTRY-108 | [Map rules to environments by receiver channel, not by rule name](#map-rules-to-environments-by-receiver-channel-not-by-rule-name) |
| SNTRY-109 | [Alert-rule remediation playbook](#alert-rule-remediation-playbook) |
| SNTRY-110 | [Alert rule taxonomy](#alert-rule-taxonomy), [Alert-rule remediation playbook](#alert-rule-remediation-playbook) |

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

This skill uses the elevated credential tier: it creates and modifies Sentry projects, rules, and monitors. Keep this token separate from your read-only audit token; `audit-sentry` checks the audit token for least privilege, and a shared elevated token would fail that check for a reason. Record it in its own `sentry` block with `tier: elevated`, in a separate config file you select with `SCOUTFLO_CONFIG` (audit-sentry audits every item of a `sentry:` list, so an elevated item there would be audited with the elevated token). When that file holds a labeled `sentry:` list, `SCOUTFLO_TARGET` picks the one item this run changes.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| Sentry | `sentry.host`, `sentry.org`, `sentry.token_env`, `sentry.tier` | named by `sentry.token_env` | the read set (`org:read`, `project:read`, `event:read`, `alerts:read`) plus `project:write`, `alerts:write`, `org:write` for the full fix set; `project:admin` only to roll back a project this setup created (rule deletes need only `alerts:write`) | elevated |
| Slack (optional) | `slack.webhook_env` | named by `slack.webhook_env` | post to one incoming webhook, for the run summary only | optional |

```bash
set -eu
# Resolve the sentry target from toolkit.yaml by command: a single block, or the labeled list
# item SCOUTFLO_TARGET names. $CFG resolves override -> project-local -> home.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in curl jq; do command -v "$bin" >/dev/null || { echo "$bin is required"; exit 1; }; done
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SNTRY_KIND=$(sh "$TT" "$CFG" sentry kind); SNTRY_N=$(sh "$TT" "$CFG" sentry count)
[ "${SNTRY_N:-0}" -ge 1 ] || { echo "no sentry block in $CFG; run /scoutflo:connect"; exit 1; }
[ "$SNTRY_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "sentry in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" sentry labels | tr '\n' ' ')"; exit 1; }
SNTRY_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$SNTRY_N" ]; do [ "$(sh "$TT" "$CFG" sentry label "$_i")" = "$SCOUTFLO_TARGET" ] && { SNTRY_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SNTRY_LABEL=$(sh "$TT" "$CFG" sentry label "$SNTRY_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$SNTRY_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no sentry target in $CFG"; exit 1; }
SENTRY_HOST=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" host)        # sentry.host: us.sentry.io, de.sentry.io, or your self-hosted host
SENTRY_ORG=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" org)          # sentry.org
SNTRY_TOKVAR=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" token_env)  # sentry.token_env names the variable, never the value
SNTRY_TIER=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" tier)         # sentry.tier
[ -n "$SENTRY_HOST" ]  || { echo "sentry target '${SNTRY_LABEL}' has no host in $CFG; run /scoutflo:connect"; exit 1; }
[ -n "$SENTRY_ORG" ]   || { echo "sentry target '${SNTRY_LABEL}' has no org in $CFG; run /scoutflo:connect"; exit 1; }
[ -n "$SNTRY_TOKVAR" ] || { echo "sentry target '${SNTRY_LABEL}' has no token_env in $CFG; run /scoutflo:connect"; exit 1; }
[ "$SNTRY_TIER" = elevated ] || { echo "sentry target '${SNTRY_LABEL}' is tier '${SNTRY_TIER:-unset}'; setup needs its own token recorded with tier: elevated (run /scoutflo:connect)"; exit 1; }
# Load the secret store the way /scoutflo:doctor does ($SCOUTFLO_ENV_FILE, then ./.scoutflo/env,
# then ~/.scoutflo/env), then read the token by the name token_env gives. Presence check only.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
SENTRY_TOKEN=$(printenv "$SNTRY_TOKVAR" 2>/dev/null || true)
[ -n "${SENTRY_TOKEN:-}" ] || { echo "${SNTRY_TOKVAR} is not set; add it to ~/.scoutflo/env with /scoutflo:connect"; exit 1; }
API="https://${SENTRY_HOST}/api/0"
echo "sentry target: ${SNTRY_LABEL} host=${SENTRY_HOST} org=${SENTRY_ORG} token_env=${SNTRY_TOKVAR} tier=${SNTRY_TIER}"

curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  "${API}/organizations/${SENTRY_ORG}/" | jq -e --arg org "$SENTRY_ORG" '.slug == $org'

# Which alert API this org serves. Sentry SaaS removed the legacy alert routes (rules/,
# alert-rules/, combined-rules/) in 2026-09: they answer a route-missing 404 (empty body,
# Allow: OPTIONS), which differs from the JSON 404 a real route gives for a missing object.
alert_probe() { # $1: path under ${API}/ ; prints "<http_code> <json|route-missing|other>"
  hdr="$(mktemp)"; body="$(mktemp)"
  pcode="$(curl -sS -o "$body" -D "$hdr" -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/$1" || true)"
  [ -n "$pcode" ] || pcode=000
  ctype="$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="content-type:"{print $2}' | tail -1)"
  allow="$(tr -d '\r' < "$hdr" | awk 'tolower($1)=="allow:"{$1=""; sub(/^ /,""); print}' | tail -1)"
  kind=other; case "$ctype" in application/json*) kind=json ;; esac
  if [ "$pcode" = 404 ] && [ "$allow" = "OPTIONS" ] && [ ! -s "$body" ]; then kind=route-missing; fi
  rm -f "$hdr" "$body"; echo "$pcode $kind"
}
NEW_API="$(alert_probe "organizations/${SENTRY_ORG}/workflows/?per_page=1")"
OLD_API="$(alert_probe "organizations/${SENTRY_ORG}/combined-rules/?per_page=1")"
echo "alert api probes: workflows=${NEW_API} legacy=${OLD_API}"
case "${NEW_API}|${OLD_API}" in
  "200 json|"*) echo "alert api: workflows" ;;
  *"|200 json") echo "alert api: legacy" ;;
  *) echo "no readable alert API (workflows ${NEW_API}, legacy ${OLD_API}); a 403 on workflows means the token lacks alerts:read"; exit 1 ;;
esac
```

Expect: the `sentry target:` line names the label, host, org, token variable, and tier you mean, then exit 0 (`true`). Then `alert api probes:` shows both reads and `alert api:` prints `workflows` (Sentry SaaS, for example `workflows=200 json legacy=404 route-missing`, and self-hosted 26.x) or `legacy` (older self-hosted Sentry with no workflows endpoint). Carry that value into every alert block below as `SENTRY_ALERT_API`: each one writes through the alerts API by default and runs its labeled legacy fallback only when this printed `legacy`. No readable alert API stops here. A missing key, a tier other than `elevated`, an unmatched `SCOUTFLO_TARGET`, or an unset token variable stops here with the fix. A `401` means the token is wrong for this host; a `404` almost always means the wrong region host, not a missing org (run the region probe in `/scoutflo:connect`, fix `sentry.host`, retry). Write permission is proven only by the first write: if any announced change returns `403`, stop, report the missing scope from the table above, and reconnect with an elevated token. Never proceed past a failed doctor check.

## Live-safety gate

This gate must be able to fail. It never derives the "live" value from the same config value it is checking against; it fetches an independent, org-agnostic view of what this token can actually reach and compares that to config.

```bash
set -eu
# Read the target from toolkit.yaml by command, the same target the doctor gate resolved;
# never retype the host or org here.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SNTRY_KIND=$(sh "$TT" "$CFG" sentry kind); SNTRY_N=$(sh "$TT" "$CFG" sentry count)
[ "$SNTRY_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "set SCOUTFLO_TARGET to the sentry label the doctor gate resolved"; exit 1; }
SNTRY_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "${SNTRY_N:-0}" ]; do [ "$(sh "$TT" "$CFG" sentry label "$_i")" = "$SCOUTFLO_TARGET" ] && { SNTRY_IDX=$_i; break; }; _i=$((_i+1)); done; fi
SNTRY_LABEL=$(sh "$TT" "$CFG" sentry label "$SNTRY_IDX")
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$SNTRY_LABEL" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no sentry target in $CFG"; exit 1; }
SENTRY_HOST=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" host)         # sentry.host
CONFIG_SENTRY_ORG=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" org)    # sentry.org, exactly as written in toolkit.yaml
SNTRY_TOKVAR=$(sh "$TT" "$CFG" sentry get "$SNTRY_IDX" token_env)   # sentry.token_env
[ -n "$SENTRY_HOST" ] && [ -n "$CONFIG_SENTRY_ORG" ] && [ -n "$SNTRY_TOKVAR" ] || { echo "sentry target '${SNTRY_LABEL}' is incomplete in $CFG; run the doctor gate first"; exit 1; }
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
SENTRY_TOKEN=$(printenv "$SNTRY_TOKVAR" 2>/dev/null || true)
[ -n "${SENTRY_TOKEN:-}" ] || { echo "${SNTRY_TOKVAR} is not set; run the doctor gate first"; exit 1; }
API="https://${SENTRY_HOST}/api/0"

# Independent live fetch: list every org this token can actually reach.
# CONFIG_SENTRY_ORG is never passed into this request, so it cannot pass by
# construction the way "echo the config back at itself" can.
LIVE_ORGS="$(curl -fsS --max-time 10 -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/")"
echo "target: ${API} (sentry target ${SNTRY_LABEL})"
echo "configured org (sentry.org): ${CONFIG_SENTRY_ORG}"
printf '%s' "$LIVE_ORGS" | jq -r '.[] | "live-visible org: \(.slug)\t\(.name)"'

printf '%s' "$LIVE_ORGS" | jq -e --arg cfg "$CONFIG_SENTRY_ORG" 'any(.[]; .slug == $cfg)'
```

Expect: exit 0, and `configured org` appears in the printed `live-visible org` list. If the assertion fails, or the live list is empty, or it lists only orgs with a different slug (a sandbox or personal org with a similar name), stop and report the mismatch. Never proceed on "probably the right org" and never edit this block to accept a close-enough slug. A user token sees every org its user belongs to, so read the printed list before you approve anything: the assertion proves the configured org is reachable, and only you can confirm it is the org you mean to change.

Every block below declares `SENTRY_HOST` and `SENTRY_ORG` at its top and reads the token as `SENTRY_TOKEN`. Set both to the exact host and org this gate printed, never a slug typed from memory. When your `token_env` is not `SENTRY_TOKEN`, bind it by name on the line after each block's `set -eu` (for example `export SENTRY_TOKEN="$(printenv SENTRY_SETUP_TOKEN)"` for `token_env: SENTRY_SETUP_TOKEN`), so every write sends the elevated token the doctor gate checked, never the read-only audit token.

- ❌ `echo "target: ${API} org: ${SENTRY_ORG}"` where `SENTRY_ORG` was itself read from `sentry.org` two lines earlier: this compares config against itself and can never fail, even when the token is bound to the wrong org.
- ✅ Fetch `GET /organizations/` (no org slug in the request) and assert the configured slug appears in that independently-fetched list; a token scoped to the wrong org fails this by construction.

Load `./scoutflo-audits/topology.md` if it exists; its service list defines which services need project coverage and alert tiers below, under its canonical names. If it does not exist, suggest `/scoutflo:map-topology` before building coverage claims.

## Load findings and build the change plan

1. Read the latest audit run and list open findings:

```bash
set -eu
# audit-sentry writes sentry/<date>/ for a single block and sentry/<label>/<date>/ for a labeled list.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SNTRY_SEG="sentry"; [ "$(sh "$TT" "$CFG" sentry kind)" != seq ] || SNTRY_SEG="sentry/${SCOUTFLO_TARGET:?set SCOUTFLO_TARGET to the sentry label the doctor gate resolved}"
AUDIT_ROOT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
LATEST_RUN="$(ls -d "${AUDIT_ROOT}/${SNTRY_SEG}"/[0-9]*/ 2>/dev/null | sort | tail -1)"
[ -n "$LATEST_RUN" ] || echo "no audit run found under ${AUDIT_ROOT}/${SNTRY_SEG}/; running greenfield setup without a findings baseline"
[ -z "$LATEST_RUN" ] || jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "${LATEST_RUN}findings.json"
```

2. Select scope. Take the finding IDs you were asked to fix, or, if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Map each finding's `remediation` anchor to a section above. Where a section says it has no verified write for a finding, put that finding in the plan as a pending item with a named owner, never as an applied row.

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

For SNTRY-012 (a service with no Sentry project) or a greenfield build. SNTRY-024 (a project that has never received an event) needs no new project: the SDK was never wired, so its fix is [SDK instrumentation notes](#sdk-instrumentation-notes). Decide project boundaries by runtime ownership, not by copying another org's layout:

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
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value; legacy checks the old rules list

# Sentry derives the slug from the name: take it from the response, the rollback needs the exact one.
PROJECT_SLUG="$(curl -fsS --max-time 10 -X POST "${API}/teams/${SENTRY_ORG}/${TEAM}/projects/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "$PROJECT_NAME" --arg p "$PLATFORM" \
    '{name: $n, platform: $p, defaultRules: false}')" | jq -r '.slug')"
echo "created project: ${PROJECT_SLUG}"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --arg p "$PLATFORM" '.platform == $p'
if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # No default alert: the new project's own issue-stream monitor has no alert attached.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/?project=${PROJECT_SLUG}&type=issue_stream" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e 'map(select(.type == "issue_stream" and .projectId != null)) | length == 1 and .[0].workflowIds == []'
else
  # Legacy fallback: the project's rules list is empty.
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT_SLUG}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" | jq -e 'length == 0'
fi
```

Expect: both `jq -e` calls exit 0; the second prints `true` because the project's issue-stream monitor has no alert attached (legacy fallback: the rules list is empty), not the auto-created notify alert. Do not count `GET /organizations/${SENTRY_ORG}/workflows/?project=` for this: that list also returns org-wide alerts, so it is not empty on an org that has one. **Rollback** (this is a create, so rollback is delete-and-verify-absence, not a restore from backup):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT_SLUG="<project-slug>"   # the "created project:" slug, never a guess: this deletes the project and its events
case "$PROJECT_SLUG" in ''|'<'*) echo "Set PROJECT_SLUG to the project this setup created" >&2; exit 1 ;; esac

curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/projects/${SENTRY_ORG}/${PROJECT_SLUG}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

## Environment seeding

For SNTRY-004. A project with no environments cannot scope alerts or releases to production, so every rule fires on dev noise too. Sentry environments exist only once an event carries that environment name; on a greenfield project with no SDK yet, seed them with a single envelope event per environment. Full payload, byte-length handling, and DSN retrieval in [references/api-cookbook.md#environment-seeding](references/api-cookbook.md#environment-seeding).

Seed `production` and `staging` (or your actual promotion stages) on every project. This is additive (one low-noise event) and has no meaningful rollback beyond leaving the seeded environment unused; nothing to restore.

For SNTRY-025 (synonym environments such as `prod` and `production` on one project), seed and scope rules to one canonical name only, fix the app's SDK `environment` value ([SDK instrumentation notes](#sdk-instrumentation-notes)), and list the retired synonym as a pending item; this skill does not rename or hide environments.

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

# 1. Backup (GET-before-write), run as written. The project's securityToken is
#    dropped before saving; the restore reads only the privacy fields.
PROJ_JSON="$(curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}")"
printf '%s\n' "$PROJ_JSON" | jq 'del(.securityToken)' > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
  || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
echo "backup: ${BACKUP_FILE}"

# 2. The write, announced with real values before it runs. Sentry replaces the
#    sensitiveFields list with what is sent, so the body sends the backed-up list
#    plus the starter list: no field the project already scrubs is dropped. Its
#    response is the whole project, securityToken included, so it is not printed;
#    step 3 verifies.
STARTER_FIELDS='["email", "password", "secret", "token", "api_key", "authorization",
  "cookie", "otp", "pin", "phone", "mobile", "code", "database_url",
  "dsn", "client_secret", "refresh_token", "access_token", "session"]'
BODY="$(jq --argjson s "$STARTER_FIELDS" '{dataScrubber: true, dataScrubberDefaults: true,
  scrubIPAddresses: true, scrapeJavaScript: false,
  sensitiveFields: (((.sensitiveFields // []) + $s) | unique)}' "$BACKUP_FILE")"
curl -fsS --max-time 10 -o /dev/null -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$BODY"

# 3. Verify by re-fetch: the four flags, and every backed-up and starter field still listed.
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" --argjson s "$STARTER_FIELDS" \
      '.dataScrubber == true and .dataScrubberDefaults == true and .scrubIPAddresses == true
       and .scrapeJavaScript == false
       and ((($b[0].sensitiveFields // []) + $s) - (.sensitiveFields // []) | length) == 0'
```

Expect: the backup file is a non-empty JSON object (otherwise the block stops before the write), and the final `jq -e` exits 0. Add domain-specific field names your app actually sends to `STARTER_FIELDS`; the fields the project already scrubs are kept either way. The starting list is in [references/api-cookbook.md#sensitive-fields](references/api-cookbook.md#sensitive-fields).

**Restore pair, run as written when this write must be undone:**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="<project-slug>"        # the project the write changed
BACKUP_FILE="<backup-path>"     # the "backup:" path step 1 printed
for v in "$PROJECT" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
# Without this check a missing file would still send an empty PUT.
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }

# Sentry's project PUT accepts a partial body; restore only the fields this
# section touched, taken byte-for-byte from the backup.
jq '{dataScrubber, dataScrubberDefaults, scrubIPAddresses, scrapeJavaScript, sensitiveFields}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -o /dev/null -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '[., $b[0]]
      | map({dataScrubber, dataScrubberDefaults, scrubIPAddresses, scrapeJavaScript, sensitiveFields}) | .[0] == .[1]'
```

Expect: exit 0, the fields byte-equal to the backup. A restore is itself a change; announce and record it like any other.

Apply a rate limit to every active client key the same way: backup, write, verify, and keep the restore command alongside it.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="checkout"
KEY_ID="your-key-id"           # GET /projects/${SENTRY_ORG}/${PROJECT}/keys/ | jq '.[] | {id, name}'; never print the whole key
KEY_RATE_LIMIT="1000"          # example, tune to your expected event volume
KEY_RATE_WINDOW="60"           # seconds; example
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/key-${KEY_ID}-$(date -u +%H%M%S).json"

# The key's secret and DSNs are not saved; the backup keeps what the restore reads.
KEY_JSON="$(curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}")"
printf '%s\n' "$KEY_JSON" | jq '{id, name, isActive, rateLimit}' > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
  || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
echo "backup: ${BACKUP_FILE}"

# The response is the whole key, secret and DSNs included, so it is not printed.
curl -fsS --max-time 10 -o /dev/null -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --argjson limit "$KEY_RATE_LIMIT" --argjson window "$KEY_RATE_WINDOW" \
    '{rateLimit: {window: $window, count: $limit}}')"

curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson limit "$KEY_RATE_LIMIT" '.rateLimit.count == $limit'
```

Expect: exit 0. An unlimited key means one crash loop or one leaked DSN burns the whole quota and drowns real errors, so `KEY_RATE_LIMIT`/`KEY_RATE_WINDOW` are examples to tune, not universal constants. Restore, in its own fresh shell:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
PROJECT="<project-slug>"        # the project that owns the key
KEY_ID="<key-id>"               # the key the write changed
BACKUP_FILE="<backup-path>"     # the "backup:" path the block above printed
for v in "$PROJECT" "$KEY_ID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }
# A null rateLimit in the backup restores an unlimited key (Sentry disables the limit on null).
jq '{rateLimit}' "$BACKUP_FILE" \
  | curl -fsS --max-time 10 -o /dev/null -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-
curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/keys/${KEY_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '.rateLimit == $b[0].rateLimit'
```

Expect: exit 0.

## Alerting model decision

The doctor gate's `alert api:` line decides which API every alert block below writes through; record it in the change record:

| Model | Use when |
| --- | --- |
| Alerts API: alerts are workflows (`/organizations/${SENTRY_ORG}/workflows/`), monitors are detectors (`/organizations/${SENTRY_ORG}/detectors/`) | The doctor printed `alert api: workflows`: Sentry SaaS, where it is the only alert API since the legacy routes were removed in 2026-09, and self-hosted 26.x. This is what the rest of this section builds |
| Legacy issue rules and metric alerts (`/projects/${SENTRY_ORG}/<project>/rules/`, `/organizations/${SENTRY_ORG}/alert-rules/`) | Fallback only: the doctor printed `alert api: legacy`, on older self-hosted Sentry that still serves those routes |

An alert holds its trigger conditions, its filters, and its actions; it fires only for the monitors listed in its `detectorIds`. Every issue alert attaches to its project's issue-stream monitor, which Sentry creates with the project. A metric alert is two objects: a `metric_issue` monitor holds the thresholds, and the alerts connected to it hold the actions. Every block below carries both paths: set `SENTRY_ALERT_API` to the doctor gate's value, and the legacy branch runs the old rules API unchanged.

For SNTRY-015 (a monitor connected to no alert, or an alert connected to no monitor), this skill has no verified wiring write: list each one as a pending item for its owner to connect or delete in Sentry's Monitors and Alerts UI, then re-run `audit-sentry` to confirm it clears.

## Alert rule taxonomy

For SNTRY-001, SNTRY-013, SNTRY-014, SNTRY-016, SNTRY-101, SNTRY-102, SNTRY-103, and SNTRY-110. Build a small, severity-based rule set per project, not one rule per person and not one rule per every possible condition. Two tiers, each routed to a receiver your team actually watches (channel names below are placeholders, pick your own):

| Tier | Fires on | Example receiver | Frequency |
| --- | --- | --- | --- |
| Immediate | Fatal events, new unhandled errors, regressions, escalations, user-impact and error-surge thresholds | `#SENTRY_IMMEDIATE_CHANNEL` | as low as 5 minutes for fatal, 30-60 minutes for threshold rules |
| Review | First-seen issues, frequency trends, warning-level signals | `#SENTRY_REVIEW_CHANNEL` | 60 minutes or your working-hours cadence |

Every production project needs at least one rule in each tier before it counts as covered. Condition, filter, and action ID tables, the full rule-payload example, and the environment-scoping fix (use the rule-level `environment` field, never the `latest_adopted_release` filter, legacy `LatestAdoptedReleaseFilter`, which filters by release-adoption stage and silently does not scope by environment) are in [references/api-cookbook.md#alert-rules](references/api-cookbook.md#alert-rules).

Start every rule with the email action (works with no integration required); add Slack or PagerDuty actions once that integration is live, in Receiver wiring below. Thresholds (`USER_IMPACT_THRESHOLD`, `ERROR_SURGE_THRESHOLD`, `FREQ_FLOOR_MIN`, and the rest) are starting points from the reference table; tune every one to your event volume before treating it as final.

Existing rules that audit-sentry flags:

- **SNTRY-016** (a disabled or muted rule credited to a tier): create an active rule for that tier with the block below, and list the switched-off rule as a pending item for its owner to re-enable or delete.
- **SNTRY-101** (no filter) and **SNTRY-102** (no rule-level `environment`): burst and spike rules get both in the [Alert-rule remediation playbook](#alert-rule-remediation-playbook); for any other rule, list the missing filter or scope as a pending item for the rule's owner.
- **SNTRY-103** (a flap-prone metric alert): this skill has no metric-alert create or threshold-edit block; list the threshold change as a pending item with the alert's owner.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value; legacy runs the old rules API below
PROJECT="checkout"
# One rule per run: rule 1 of the starting set in references/api-cookbook.md#alert-rules.
# For another rule in the set, change only these declarations (the alerts API column for
# ALERT_*, the legacy column for RULE_*).
RULE_NAME="Fatal crash, immediate"
RULE_ENV="production"          # the production environment you seeded; the rule's own scope
RULE_FREQ_MIN="5"              # IMMEDIATE_FREQ_MIN, re-notify minutes; example, tune to your event volume
OWNER_TEAM_ID="your-team-id"   # numeric id of the team that maintains the rule, from GET /organizations/${SENTRY_ORG}/teams/
ALERT_TRIGGERS='[]'            # alerts API: no trigger conditions = evaluate on every event
ALERT_FILTERS='[{"type": "level", "comparison": {"level": 50, "match": "eq"}, "conditionResult": true}]'   # level 50 = fatal
RULE_CONDITIONS='[{"id": "sentry.rules.conditions.every_event.EveryEventCondition"}]'                      # legacy fallback only
RULE_FILTERS='[{"id": "sentry.rules.filters.level.LevelFilter", "level": "fatal", "match": "eq"}]'          # legacy fallback only

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # The alert attaches to this project's issue-stream monitor; there must be exactly one.
  ISD="$(curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/?project=${PROJECT}&type=issue_stream" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -er 'map(select(.type == "issue_stream" and .projectId != null))
        | if length == 1 then .[0].id else error("expected exactly one issue-stream monitor") end')"
  # The payload is built here, so no payload file is needed (shape: references/api-cookbook.md#full-rule-payload-example).
  ALERT_PAYLOAD="$(jq -n --arg name "$RULE_NAME" --arg env "$RULE_ENV" --argjson freq "$RULE_FREQ_MIN" \
    --arg owner "team:${OWNER_TEAM_ID}" --arg isd "$ISD" --argjson trig "$ALERT_TRIGGERS" --argjson filt "$ALERT_FILTERS" \
    '{name: $name, enabled: true, environment: $env, owner: $owner, config: {frequency: $freq}, detectorIds: [$isd],
      triggers: {logicType: "any-short", conditions: $trig},
      actionFilters: [{logicType: "all", conditions: $filt,
        actions: [{type: "email", integrationId: null,
                   config: {targetType: "issue_owners", targetIdentifier: null}, data: {fallthroughType: "AllMembers"}}]}]}')"
  RULE_ID="$(curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/workflows/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$ALERT_PAYLOAD" | jq -r '.id // empty')"
  [ -n "$RULE_ID" ] || { echo "create returned no alert id; nothing to verify" >&2; exit 1; }
  echo "created alert: ${RULE_ID}"
  # Verify the re-fetched alert against the payload it was created from.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --argjson p "$ALERT_PAYLOAD" '.enabled == true and .environment == $p.environment
        and .config.frequency == $p.config.frequency and .owner == $p.owner
        and (.detectorIds | map(tostring)) == ($p.detectorIds | map(tostring))
        and ([(.triggers.conditions // [])[].type] | sort) == ([$p.triggers.conditions[].type] | sort)
        and ([(.actionFilters // [])[].conditions[].type] | sort) == ([$p.actionFilters[].conditions[].type] | sort)
        and ([(.actionFilters // [])[].actions[]] | length) == ([$p.actionFilters[].actions[]] | length)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  RULE_PAYLOAD="$(jq -n --arg name "$RULE_NAME" --arg env "$RULE_ENV" --argjson freq "$RULE_FREQ_MIN" \
    --arg owner "team:${OWNER_TEAM_ID}" --argjson cond "$RULE_CONDITIONS" --argjson filt "$RULE_FILTERS" \
    '{name: $name, actionMatch: "any", filterMatch: "all", environment: $env, frequency: $freq, owner: $owner,
      conditions: $cond, filters: $filt,
      actions: [{id: "sentry.mail.actions.NotifyEmailAction", targetType: "IssueOwners", fallthroughType: "AllMembers"}]}')"

  NEW_RULE="$(curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$RULE_PAYLOAD")"
  RULE_ID="$(printf '%s' "$NEW_RULE" | jq -r '.id')"
  echo "created rule: ${RULE_ID}"

  # Verify the re-fetched rule against the payload it was created from.
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --argjson p "$RULE_PAYLOAD" '.environment == $p.environment and .frequency == $p.frequency
        and .owner == $p.owner
        and ([(.conditions // [])[].id] | sort) == ([$p.conditions[].id] | sort)
        and ([(.filters // [])[].id] | sort) == ([$p.filters[].id] | sort)
        and (.actions | length) == ($p.actions | length)'
fi
```

Expect: `created alert: <id>` (legacy fallback: `created rule: <id>`), then exit 0, because the re-fetched alert is enabled and its `environment`, `config.frequency` (minutes), `owner`, monitor attachment, trigger and filter condition types, and action count all match the payload. A rule created this way sets the rule-level `environment` and an `owner`, so it passes audit-sentry's SNTRY-102 and SNTRY-110; one created with `ALERT_FILTERS='[]'` fails SNTRY-101 (a notifying rule with no filter), as the cookbook's starting rule set explains. The issue-owners email action fails SNTRY-017 on a project with no ownership rules; see [Receiver wiring](#receiver-wiring). **Rollback** (this is a create; rollback deletes and verifies absence):

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="<project-slug>"; RULE_ID="<rule-id>"   # the "created alert:" (legacy: "created rule:") id from the create block
for v in "$PROJECT" "$RULE_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # Delete this one alert by id: never a bulk or ?project= delete, which removes every alert in the project.
  curl -sS --max-time 10 -o /dev/null -w 'delete: %{http_code}\n' -X DELETE \
    "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" -H "Authorization: Bearer ${SENTRY_TOKEN}"
  # Gone means the real route's JSON "does not exist" 404. A route-missing 404 has an empty body and proves nothing.
  gone="$(mktemp)"; trap 'rm -f "$gone"' EXIT
  code="$(curl -sS --max-time 10 -o "$gone" -w '%{http_code}' \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/")"
  echo "post-delete: ${code}"
  [ "$code" = 404 ]
  jq -e '.detail == "The requested resource does not exist"' "$gone"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}"
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --arg id "$RULE_ID" '[.[] | select(.id == $id)] | length == 0'
fi
```

Expect: `delete: 204`, `post-delete: 404`, then `true` and exit 0 (legacy fallback: exit 0 on the list-absence check). Any other post-delete code, or a 404 without that JSON body, exits nonzero: the alert is not proven gone.

## Delete the auto-created default rule

For SNTRY-001 on any project that predates `defaultRules: false`, or where it was omitted. New projects get a "Send a notification for high priority issues" alert with `createdBy: null`, attached to the project's own issue-stream monitor. Find it, back up its full body, assert the backup still matches that signature, delete that one alert by id, then verify it is gone:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="checkout"
RULE_ID="12345678"   # from the list the block prints first; confirm it before deleting
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  ISD="$(curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/detectors/?project=${PROJECT}&type=issue_stream" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -er 'map(select(.type == "issue_stream" and .projectId != null))
        | if length == 1 then .[0].id else error("expected exactly one issue-stream monitor") end')"
  # Sentry-created, the default name, and on this project's own monitor (never an org-wide alert):
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/?project=${PROJECT}&per_page=100" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -r --arg isd "$ISD" '.[] | select(.createdBy == null and (.name | ascii_downcase | contains("high priority"))
        and any((.detectorIds // [])[]; . == $isd)) | "\(.id)\t\(.name)"'
  BACKUP_FILE="${BACKUP_DIR}/default-alert-${RULE_ID}.json"
  # 1. Backup the exact alert body (GET-before-write), so it can be recreated:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  [ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
    || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
  echo "backup: ${BACKUP_FILE}"
  # Confirm the match by assertion: only an untouched, auto-created high-priority alert on this project is deleted here.
  jq -e --arg isd "$ISD" '.createdBy == null and (.name | ascii_downcase | contains("high priority"))
      and any((.detectorIds // [])[]; . == $isd)' "$BACKUP_FILE" > /dev/null \
    || { echo "alert ${RULE_ID} is not this project's auto-created default alert; not deleting" >&2; exit 1; }
  # 2. The write: this one alert, by id.
  curl -sS --max-time 10 -o /dev/null -w 'delete: %{http_code}\n' -X DELETE \
    "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" -H "Authorization: Bearer ${SENTRY_TOKEN}"
  # 3. Verify by re-fetch: the real route's JSON "does not exist" 404, never a bare 404.
  gone="$(mktemp)"; trap 'rm -f "$gone"' EXIT
  code="$(curl -sS --max-time 10 -o "$gone" -w '%{http_code}' \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/")"
  echo "post-delete: ${code}"
  [ "$code" = 404 ]
  jq -e '.detail == "The requested resource does not exist"' "$gone"
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -r '.[] | select((.createdBy == null) and (.name | ascii_downcase | contains("high priority"))) | "\(.id)\t\(.name)"'
  BACKUP_FILE="${BACKUP_DIR}/default-rule-${RULE_ID}.json"
  # 1. Backup the exact rule body (GET-before-write), so it can be recreated:
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  [ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
    || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
  echo "backup: ${BACKUP_FILE}"
  # Confirm the match by assertion: only an untouched, auto-created high-priority rule is deleted here.
  jq -e '.createdBy == null and (.name | ascii_downcase | contains("high priority"))' "$BACKUP_FILE" > /dev/null \
    || { echo "rule ${RULE_ID} is not the auto-created default rule; not deleting" >&2; exit 1; }
  # 2. The write:
  curl -fsS --max-time 10 -X DELETE "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}"
  # 3. Verify by re-fetch:
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --arg id "$RULE_ID" '[.[] | select(.id == $id)] | length == 0'
fi
```

Expect: the candidate list, `backup: <path>`, `delete: 204`, `post-delete: 404`, then `true` and exit 0 (legacy fallback: exit 0 on the list-absence check). An alert that fails the signature assertion stops the block before the DELETE. On the alerts API `alerts:write` covers this delete (per Sentry's source; not yet run live), while an org-wide alert would need `org:write`, which is one more reason this block only deletes an alert attached to the project's own monitor. Confirmed live on the legacy API: the rule delete succeeds with just `alerts:write` and needs no `project:admin` scope.

**Restore pair**, run as written if something depended on this rule and it needs to come back:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="<project-slug>"        # the project the rule was deleted from
BACKUP_FILE="<backup-path>"     # the "backup:" path step 1 printed
for v in "$PROJECT" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # Re-create from the backup: drop server-set fields and every nested id, keep the rest, enabled included.
  BODY="$(jq 'del(.id, .organizationId, .dateCreated, .dateUpdated, .lastTriggered, .createdBy)
      | if .triggers then .triggers |= (del(.id, .organizationId) | .conditions |= map(del(.id))) else . end
      | .actionFilters |= map(del(.id, .organizationId) | .conditions |= map(del(.id)) | .actions |= map(del(.id)))
      | with_entries(select(.value != null))' "$BACKUP_FILE")"
  NEW_ID="$(printf '%s' "$BODY" | curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/workflows/" \
      -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- | jq -r '.id // empty')"
  [ -n "$NEW_ID" ] || { echo "re-create returned no alert id" >&2; exit 1; }
  echo "restored as alert: ${NEW_ID}"
  # Check the recreated alert itself, not any alert that happens to share its name.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${NEW_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '.name == $b[0].name and .enabled == $b[0].enabled
        and ((.detectorIds // []) | map(tostring) | sort) == (($b[0].detectorIds // []) | map(tostring) | sort)
        and ([(.actionFilters // [])[].actions[]] | length) == ([($b[0].actionFilters // [])[].actions[]] | length)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  NEW_ID="$(jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X POST "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- | jq -r '.id')"
  echo "restored as rule: ${NEW_ID}"
  # Check the recreated rule itself, not any rule that happens to share its name.
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${NEW_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '.name == $b[0].name and (.actions | length) == ($b[0].actions | length)'
fi
```

Expect: exit 0, the recreated alert carrying the backup's name, `enabled` state, monitor attachment, and action count. The default alert's triggers are the migrated-only `new_high_priority_issue` and `existing_high_priority_issue` types, which the live condition catalog does not offer for new alerts; if the POST is refused with a `400`, the alert cannot come back as it was. Recreate the closest equivalent instead (rule 3 of the starting set in [references/api-cookbook.md#alert-rules](references/api-cookbook.md#alert-rules)) and record the substitution in the change record. Deleting a rule is a lightweight change, but it is still confirmed individually, never inside a batch.

A restored default rule is not byte-identical to the original. Sentry assigns `createdBy` from the requesting token's identity on every create (confirmed live on the legacy API; the alerts API does the same per Sentry's source), so the restored rule's `createdBy` is the setup identity, not the original `null` that marks an untouched, auto-created rule. This means the `createdBy == null` signature this section uses to find the rule in the first place will no longer match a restored copy: a future run treats it as a normal, manually-created rule, not the auto-created default. Note this in the change record so nobody expects a future automated pass to re-detect a restored rule the same way.

## Receiver wiring

For SNTRY-005 (rules whose only action is email, a temporary path, not a proven route), SNTRY-011 (duplicate alerting paths), and SNTRY-017 (rules routed to issue owners on a project with no ownership rules).

- **Slack.** Once the Slack integration is connected, resolve the integration ID (the `slack` entry's `integrations[].id` in `GET /organizations/${SENTRY_ORG}/available-actions/`; legacy fallback: `GET /organizations/${SENTRY_ORG}/integrations/?provider_key=slack`) and the channel ID (not just the display name), back up the current alert, then add a Slack action to it alongside its existing email action with a full-body `PUT`. An alert `PUT` replaces the whole alert: any action, filter, or condition missing from the body (matched by `id`) is deleted, and an omitted `enabled` turns a disabled alert back on, so the body carries every existing field and id from the backup, `enabled` included.
- **PagerDuty.** Same pattern: resolve the integration and service ID (on the alerts API, `available-actions` lists PagerDuty services under the `pagerduty` entry's `integrations[].services[]`), back up the alert, add the PagerDuty action alongside email, full-body `PUT`. Payload in [references/api-cookbook.md#alert-rules](references/api-cookbook.md#alert-rules).
- **Duplicate paths (SNTRY-011).** Pick one primary alerting surface per signal. If Sentry uptime monitors duplicate an external synthetic tool, or if an issue rule duplicates a metric alert on the same condition, disable one side and record which system is the source of truth.
- **Owner routing (SNTRY-017).** An email action to issue owners (`config.targetType: issue_owners`; legacy `targetType: IssueOwners`) on a project with no ownership rules notifies nobody, or every member when it falls through to `AllMembers`. It clears only once the project has ownership rules: list them as a pending item for the owning team, and wire a Slack or PagerDuty action below in the meantime so matched issues reach a channel someone watches.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="checkout"             # legacy fallback only: the project that owns the rule
RULE_ID="12345678"             # the alert (legacy: rule) to wire
FILTER_INDEX="0"               # alerts API: which actionFilters[] entry gets the action; a migrated metric alert has two
SLACK_INTEGRATION_ID="your-integration-id"   # alerts API: the slack entry's integrations[].id from GET /organizations/${SENTRY_ORG}/available-actions/
SLACK_CHANNEL="your-channel-name"
SLACK_CHANNEL_ID="your-channel-id"
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/sentry/setup-$(date -u +%F)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/rule-${RULE_ID}-$(date -u +%H%M%S).json"

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # 1. Backup (GET-before-write), run as written:
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  [ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
    || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
  echo "backup: ${BACKUP_FILE}"

  # 2. Append the Slack action to the chosen filter, then PUT the whole alert back from the backup:
  #    every id kept, enabled as it was. A null triggers is dropped (the endpoint rejects it);
  #    environment and owner stay even when null, because null is how they mean "all" and "none".
  UPDATED="$(jq --argjson i "$FILTER_INDEX" --arg ws "$SLACK_INTEGRATION_ID" --arg ch "$SLACK_CHANNEL" --arg cid "$SLACK_CHANNEL_ID" '
      if ((.actionFilters // []) | length) <= $i then error("this alert has no actionFilters[\($i)]") else . end
      | .actionFilters[$i].actions += [{type: "slack", integrationId: $ws,
          config: {targetType: "specific", targetIdentifier: $cid, targetDisplay: $ch},
          data: {tags: "environment,user,release,os,transaction,level"}}]
      | {name, enabled, environment, owner, config, detectorIds, triggers, actionFilters}
      | with_entries(select(.value != null or .key == "environment" or .key == "owner"))' "$BACKUP_FILE")"
  curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d "$UPDATED" > /dev/null

  # 3. Verify by re-fetch, machine-checkable: the Slack action carries this channel id, exactly one
  #    action was added, and enabled, scope, frequency, owner, monitors, and conditions did not move.
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" --arg cid "$SLACK_CHANNEL_ID" '
        def acts: [(.actionFilters // [])[].actions[]];
        def rest: {enabled, environment, owner, config, detectorIds: ((.detectorIds // []) | map(tostring) | sort),
          triggers: (.triggers | if . then {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}]} else null end),
          filters: [(.actionFilters // [])[] | {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}]}]};
        ([acts[] | select(.type == "slack" and .config.targetIdentifier == $cid)] | length) >= 1
        and (acts | length) == (($b[0] | acts | length) + 1)
        and rest == ($b[0] | rest)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  # 1. Backup (GET-before-write), run as written:
  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" > "$BACKUP_FILE"
  [ -s "$BACKUP_FILE" ] && jq -e 'type == "object"' "$BACKUP_FILE" > /dev/null \
    || { echo "backup at ${BACKUP_FILE} is empty or not a JSON object; not writing" >&2; exit 1; }
  echo "backup: ${BACKUP_FILE}"

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
fi
```

Expect: the backup file is non-empty, and the final `jq -e` exits 0: on the alerts API it confirms the Slack action carries the real channel ID (`config.targetIdentifier`), that exactly one action was added, and that `enabled` and every other field kept their backed-up values; on the legacy fallback it confirms `channel_id` resolved to a real ID, not just that a Slack action of some kind is present. **Restore pair**, run as written to undo this wiring change:

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set"; exit 1; }
SENTRY_ALERT_API="workflows"   # the doctor gate's "alert api:" value
PROJECT="<project-slug>"; RULE_ID="<rule-id>"   # the alert (legacy: rule) the write changed and its project
BACKUP_FILE="<backup-path>"     # the "backup:" path step 1 printed
for v in "$PROJECT" "$RULE_ID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}" >&2; exit 1; }

if [ "${SENTRY_ALERT_API}" = workflows ]; then
  # PUT the backup back whole: its ids keep the original actions, the added action, absent from
  # the body, is removed, and a null environment or owner in the backup is set back to null.
  jq '{name, enabled, environment, owner, config, detectorIds, triggers, actionFilters}
      | with_entries(select(.value != null or .key == "environment" or .key == "owner"))' \
    "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @- > /dev/null
  curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/workflows/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '
        def norm: {enabled, environment, owner, config, detectorIds: ((.detectorIds // []) | map(tostring) | sort),
          triggers: (.triggers | if . then {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}]} else null end),
          actionFilters: [(.actionFilters // [])[] | {logicType, conditions: [.conditions[] | {type, comparison, conditionResult}],
                                                     actions: [.actions[] | {type, integrationId, config, data}]}]};
        norm == ($b[0] | norm)'
else
  # Legacy fallback (self-hosted Sentry that still serves /rules/).
  jq '{name, actionMatch, filterMatch, environment, frequency, conditions, filters, actions}' "$BACKUP_FILE" \
    | curl -fsS --max-time 10 -X PUT "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
        -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" -d @-

  curl -fsS --max-time 10 "${API}/projects/${SENTRY_ORG}/${PROJECT}/rules/${RULE_ID}/" \
    -H "Authorization: Bearer ${SENTRY_TOKEN}" \
    | jq -e --slurpfile b "$BACKUP_FILE" '[., $b[0]]
        | map({actionMatch, filterMatch, environment, frequency, conditions, filters, actions}) | .[0] == .[1]'
fi
```

Expect: exit 0, the alert equal to its backup in `enabled`, scope, frequency, owner, monitors, conditions, and actions. A rule that lists a Slack action is `configured`; only a delivered test notification proves the receiver is live. Send one low-risk test notification once wiring is approved and re-confirmed (on the alerts API, `POST /organizations/${SENTRY_ORG}/test-fire-actions/` with the alert's `actions` and its `projectSlug`; Sentry marks it experimental, allows 10 a minute per user, and needs a user token on a team in the project; legacy fallback: the rule's test-fire endpoint on your API version), and record who confirmed receipt in the change log; do not mark SNTRY-005/SNTRY-011 fixed on the `jq -e` above alone.

## Alert-rule remediation playbook

For a bulk cleanup of an org's existing alert rules (slowing noisy tiers, deleting dead rules, rescoping rules by environment) rather than a single new-rule fix. It extends [Alert rule taxonomy](#alert-rule-taxonomy) and [Receiver wiring](#receiver-wiring): the taxonomy decides what each tier should be; this playbook moves a live, historically-grown rule set onto it without going dark. Every step still runs under [The change protocol](#the-change-protocol) (announce, confirm, execute, verify, record) and nothing here auto-mutates. This is a real cleanup shape: dozens of rule updates and a handful of deletions across several projects, every one GET-verified.

It also takes audit-sentry's rule-hygiene findings. SNTRY-106 is evidence only: its fire counts pick which rules to touch, and nothing changes for it. SNTRY-107 is fixed by [Slow noisy tiers, keep fast tiers fast, never age-gate regressions](#slow-noisy-tiers-keep-fast-tiers-fast-never-age-gate-regressions). For SNTRY-108, [Map rules to environments by receiver channel, not by rule name](#map-rules-to-environments-by-receiver-channel-not-by-rule-name) decides the environment; the slow-a-noisy-rule block applies it to a burst or spike rule, and any other rule's rescope is a pending item for its owner. A SNTRY-109 dead-weight rule is deleted only after the rule-set backup below, one confirmed deletion at a time, with the rule rollback block in [Alert rule taxonomy](#alert-rule-taxonomy) (`RULE_ID` set to that rule) and its per-rule JSON `404` verify. For SNTRY-110, rules this skill creates carry an `owner`; list each existing ownerless rule as a pending item naming the team that should own it.

### Back up the whole rule set before the first mutation

Mandatory before the first PUT or DELETE, no exceptions. Dump the full current JSON of every rule you might touch into a dated local directory `~/.scoutflo/sentry-rules-backup-<date>/`: on the alerts API, one file of every alert (`workflows.json`) and one of every metric monitor (`detectors.json`), org-wide; on the legacy fallback, one file per project for its issue-alert rules, plus one file for the org's metric-alert rules. Restore is a PUT of the whole saved body for a rule you updated (every id and `enabled` with it), or a POST for one you deleted. A single wrong bulk edit across dozens of rules is unrecoverable without this snapshot, and a sentence claiming a backup exists is not a backup. The runnable backup-all and restore commands are in [references/api-cookbook.md#rule-set-backup-and-restore](references/api-cookbook.md#rule-set-backup-and-restore).

### GET-verify after every PUT and every DELETE

The change protocol's verify step is per-rule here, and its evidence is reported per rule, never as a batch total. After a PUT, re-fetch the rule and assert the field you changed holds the new value, and that `enabled` still holds its backed-up value, with `jq -e`. A DELETE answers `204` on the alerts API and `202 Accepted` (queued) on the legacy fallback; neither status proves the rule is gone. Confirm removal with a follow-up GET that returns `404` with the JSON body `{"detail": "The requested resource does not exist"}`: a bare `404` proves nothing, because a removed or mistyped route answers `404` with an empty body for every id, deleted or not. Report a per-rule verify line (`rule <id>: verified`, or `gone (404)`) for every rule touched. The verify snippets are in [references/api-cookbook.md#bulk-verify-put-and-delete](references/api-cookbook.md#bulk-verify-put-and-delete).

- ❌ Reported "57 rules updated, 14 deleted" from the write commands' exit codes, treating the 204 or 202 on each delete, or a bare 404 on the re-read, as done.
- ✅ Re-fetched each of the 57 with a passing `jq -e` on the changed field and its `enabled` state, and each of the 14 with a follow-up GET returning the JSON "does not exist" 404, and reported the 71 per-rule verify lines.

### Quiet a metric alert's warning tier

On the alerts API a metric alert is two objects: its `metric_issue` monitor holds the thresholds as `conditionGroup.conditions` (`conditionResult` 75 is critical, 50 is warning, 0 is resolve), and the alerts connected to it hold the actions. To silence the warning tier, remove the warning condition (`conditionResult` 50) from the monitor and keep the critical and resolve conditions: a metric monitor must keep its resolve condition (unless it uses anomaly detection) and holds at most three conditions. The monitor `PUT` is partial, but the conditions list is replaced by `id`, so send every condition you keep with its `id`. Record the removed condition (its `type` and `comparison`) in the change log so it can be restored. Restoring it is a change like any other: announce, confirm, verify. Payload shape in [references/api-cookbook.md#silence-a-metric-alert-warning-tier](references/api-cookbook.md#silence-a-metric-alert-warning-tier).

Legacy fallback, discovered live: the metric-alert API (`/organizations/${SENTRY_ORG}/alert-rules/`) rejects a PUT that leaves any trigger with an empty `actions` array:

> Each trigger must have an associated action for this alert to fire.

So on the legacy API you cannot silence a warning tier by stripping its action and keeping the trigger: remove the whole trigger from the `triggers` array (keep the critical trigger), and record the exact trigger you removed (its `label`, `alertThreshold`, and `actions`) so it can be restored by PUTting it back into the array.

### Slow noisy tiers, keep fast tiers fast, never age-gate regressions

For SNTRY-107 (chronic issues that re-page without bound). Slowing every rule is as wrong as slowing none: it buries the fast tier the team relies on. Move each rule family by what it is for, not uniformly. The cadence figures are examples, tune them to your event volume.

| Rule family | Change | Why |
| --- | --- | --- |
| Burst, spike, or high-volume rules | Add the rule-level `environment` filter (production or pre-prod), add an "issue newer than `RULE_AGE_GATE_DAYS`" age gate, and slow re-notify from the fast tier's cadence to `SLOW_RENOTIFY_MIN` | These are the noise source; an env scope plus age gate plus long re-notify cut the repeat pages without dropping the first one |
| New Issue, High Priority, Critical, and Escalating rules | Leave fast and untouched | These are the pages the team actually needs; slowing them defeats the cleanup |
| Regression rules (`regression_event`; legacy `RegressionEventCondition`) | Slow re-notify if needed, but never add an "issue newer than N days" age gate | A regression is by definition an old, previously-resolved issue coming back; a "newer than 7d" gate suppresses exactly the regressions the rule exists to catch |

Named defaults for the block: `RULE_AGE_GATE_DAYS="7"`, `FAST_RENOTIFY_MIN="15"`, `SLOW_RENOTIFY_MIN="1440"` (24 hours), all examples to tune to your volume. The age gate is an `age_comparison` action-filter condition (legacy `AgeComparisonFilter`); the re-notify cadence is the alert's `config.frequency` (legacy `frequency`), in minutes. Payload in [references/api-cookbook.md#slow-a-noisy-issue-alert-rule](references/api-cookbook.md#slow-a-noisy-issue-alert-rule).

- ❌ Added a "newer than 7 days" age gate to every rule in the project, the regression rule included, and reported the whole project "de-noised".
- ✅ Age-gated only the burst and spike rules, left the regression, escalation, and high-priority rules fast, and named which rules changed and which were deliberately left alone.

### Map rules to environments by receiver channel, not by rule name

For SNTRY-108 (a rule whose name or channel claims an environment its `environment` field does not set). When you rescope rules by environment, derive the target environment from the receiver channel the rule routes to, not from the rule's own name. Rule names are historical fiction: a rule called "- Prod" can route to a dev channel after years of edits, and the channel it delivers to is the ground truth.

- A rule routing to a production receiver: scope `environment: production`.
- A rule whose action posts to a pre-prod channel (for example `sentry-alert-pp-<env>`): scope `environment` to your pre-prod stage, whatever the rule name claims.

Ordering rule for a project that emits no environment tag: never env-scope a rule on a project whose events carry no `environment` tag. An environment-scoped rule matches zero events on such a project and goes permanently silent. Fix the SDK environment config first (see [Environment seeding](#environment-seeding) and the SDK notes in [references/sdk-instrumentation.md](references/sdk-instrumentation.md)), confirm the environment now appears under `GET /projects/${SENTRY_ORG}/<project>/environments/`, and only then scope the rules. SDK env config first, rule scoping second.

- ❌ Scoped every "- Prod" rule to `environment: production` from the names, on a project whose SDK sends no environment tag, silencing all of them.
- ✅ Read each rule's action channel, mapped `sentry-alert-pp-<env>` channels to the pre-prod environment, and on the one project with no env tag filed an SDK-env fix as a pending item before touching its rule scopes.

### Temporary metric-query masks carry a recorded revert condition

Sometimes the fastest way to quiet a false alert is a temporary exclusion in a metric alert's query, for example appending `!transaction:"<path>"` until a code fix ships. A mask with no recorded exit becomes permanent blindness. Every temporary mask you add must record, in the change log and in durable team memory, its revert condition naming the triggering change: "revert this `!transaction` exclusion when PR #NNNN reaches prod". Record the deploy or PR that clears it, not just "revert later".

- ❌ Added `!transaction:"..."` to the query to stop the page and moved on.
- ✅ Added the exclusion and logged "revert when PR #NNNN reaches prod" with the PR named, so the mask lifts when the fix lands instead of hiding the signal forever.

### Scope discipline for the executor

Enumerate the full change-set up front as the plan table ([Load findings and build the change plan](#load-findings-and-build-the-change-plan)) and stay inside it. Anything you notice outside the enumerated set (a rule that also looks noisy, a project that also lacks scrubbing) is left untouched and listed as skipped, with the reason, never improvised into the run. If reality forces a change different from what was announced (a trigger that will not PUT, a channel ID that will not resolve), that is a deviation: stop, report it against the plan, and re-announce, per the change protocol's mid-batch failure rule. The run's record names every planned rule as done, skipped-with-reason, or deviated, never a silent extra edit and never a silent omission.

## GitHub integration and code mappings

For SNTRY-009, SNTRY-021, and SNTRY-022. A repo integration without code mappings resolves nothing, and a code mapping whose `defaultBranch` differs from the branch you actually deploy resolves the wrong file. SNTRY-021 (a release-bound repo with no `integrations:*` provider) is fixed in CI: point `sentry-cli releases set-commits` at a repo this integration connects, recorded as a pending CI item. For SNTRY-022 (a duplicate mapping, or a `stackRoot` under a build-host path), create the correct mapping below and list the bad one as a pending item for the project's owner to remove. Treat the three pieces as a chain:

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
MAPPING_ID="<mapping-id>"   # the "created mapping:" id from the create block
case "$MAPPING_ID" in ''|'<'*) echo "Set MAPPING_ID to the mapping this setup created" >&2; exit 1 ;; esac

curl -fsS --max-time 10 -X DELETE "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/code-mappings/${MAPPING_ID}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

## Cron and uptime monitors

For SNTRY-007 and SNTRY-023 (no monitors at all on an org whose backend projects carry real event volume). Create a monitor per scheduled job, disabled until the job actually emits check-ins; an active monitor with zero check-ins is a false-page risk, not coverage.

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
MONITOR_SLUG="nightly-data-sync"
PROJECT="backend-services"
CRON_SCHEDULE="0 2 * * *"      # example; use the scheduler's real crontab
CRON_TIMEZONE="UTC"            # example; use the timezone your scheduler actually runs in
CHECKIN_MARGIN_MIN="5"         # example: minutes late before a check-in counts as missed; tune to the job's start jitter
MAX_RUNTIME_MIN="30"           # example: minutes in progress before a run counts as timed out; tune to the job's real runtime
FAILURE_ISSUE_THRESHOLD="2"    # example: consecutive failed check-ins before Sentry opens an issue
RECOVERY_THRESHOLD="1"         # example: consecutive good check-ins before it resolves

curl -fsS --max-time 10 -X POST "${API}/organizations/${SENTRY_ORG}/monitors/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" -H "Content-Type: application/json" \
  -d "$(jq -n --arg name "$MONITOR_SLUG" --arg proj "$PROJECT" --arg slug "$MONITOR_SLUG" \
        --arg sched "$CRON_SCHEDULE" --arg tz "$CRON_TIMEZONE" \
        --argjson margin "$CHECKIN_MARGIN_MIN" --argjson runtime "$MAX_RUNTIME_MIN" \
        --argjson fail "$FAILURE_ISSUE_THRESHOLD" --argjson recover "$RECOVERY_THRESHOLD" \
    '{name: $name, project: $proj, slug: $slug, status: "disabled",
      config: {schedule_type: "crontab", schedule: $sched, checkin_margin: $margin,
               max_runtime: $runtime, failure_issue_threshold: $fail, recovery_threshold: $recover, timezone: $tz}}')"

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
MONITOR_SLUG="<monitor-slug>"   # the slug of the monitor this setup created
case "$MONITOR_SLUG" in ''|'<'*) echo "Set MONITOR_SLUG to the monitor this setup created" >&2; exit 1 ;; esac

curl -fsS --max-time 10 -X DELETE "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" "${API}/organizations/${SENTRY_ORG}/monitors/${MONITOR_SLUG}/")"
echo "post-delete: ${code}"
```

Expect: `post-delete: 404`.

For uptime monitors, use `intervalSeconds` from the fixed set `300, 600, 1800, 3600` (all other values are rejected); create-verify-rollback payload in [references/api-cookbook.md#monitors](references/api-cookbook.md#monitors). Before creating one, confirm no other tool already owns uptime for that endpoint: duplicating an existing synthetic check is an SNTRY-011 finding waiting to happen.

## Releases and source maps

For SNTRY-006 and SNTRY-020 (a sampled event that carries a `js_no_source` symbolication error). Agree one release-naming convention (git SHA or semantic version) and set it as `SENTRY_RELEASE` in the runtime environment before the app team deploys. This skill does not upload source maps itself; that runs in your CI/CD pipeline, from the release-naming convention this section sets. You can, however, verify whether previously uploaded maps are resolving:

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

For SNTRY-008, SNTRY-010, SNTRY-018, SNTRY-019, SNTRY-104, and SNTRY-105. These are decisions to record, most of them not API writes; where a live check exists, it is machine-checked, not just inspected.

- **Quota pressure (SNTRY-008).**

```bash
set -eu
SENTRY_HOST="us.sentry.io"; SENTRY_ORG="your-org-slug"; API="https://${SENTRY_HOST}/api/0"
[ -n "${SENTRY_TOKEN:-}" ] || { echo "SENTRY_TOKEN is not set; run /scoutflo:connect"; exit 1; }
STATS_PERIOD="7d"    # example window, tune it; audit-sentry's SNTRY-008 reads 14d
DROP_RATIO="0.05"    # example, tune to your quota; the dropped share of accepted volume audit-sentry tolerates for SNTRY-008

curl -fsS --max-time 10 "${API}/organizations/${SENTRY_ORG}/stats_v2/?field=sum(quantity)&groupBy=outcome&interval=1d&statsPeriod=${STATS_PERIOD}" \
  -H "Authorization: Bearer ${SENTRY_TOKEN}" \
  | jq -e --argjson r "$DROP_RATIO" '[.groups[]? | {o: .by.outcome, n: .totals."sum(quantity)"}]
      | ([.[] | select(.o == "rate_limited" or .o == "cardinality_limited" or .o == "abuse") | .n] | add // 0) as $dropped
      | ([.[] | select(.o == "accepted") | .n] | add // 0) as $accepted
      | $dropped <= $accepted * $r'
```

Expect: exit 0 (rate-limited, cardinality-limited, and abuse drops over the last `STATS_PERIOD` stay at or under `DROP_RATIO` of accepted volume). A failing assertion is real evidence: raise the client-key rate limit ([Privacy gates](#privacy-gates)) only after confirming the new ceiling fits your plan's quota, or reduce trace/replay sampling first if the volume is from those categories rather than errors.

- **Per-project drops and their cause (SNTRY-018, SNTRY-019).** audit-sentry names the project and splits the drop reason. A per-key or cardinality quota cause is fixed by that project's client-key rate limit in [Privacy gates](#privacy-gates); a `spike_protection` cause is a Spike Protection setting (next item), not a key change.
- **Spike Protection and inbound data filters (SNTRY-104, SNTRY-105).** Both are project settings this skill does not write. Record for each production project whether Spike Protection and the inbound data filters (web crawlers and localhost, plus browser extensions and legacy browsers on browser projects) are on, list each change as a pending item with an owner, and re-run audit-sentry to confirm.

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

Before calling the run done, check: every touched project re-fetched with a passing `jq -e` on scrubbers and sensitive fields; every touched rule re-fetched with a passing `jq -e` on its conditions, filters, actions, environment scope, and `enabled` state; every deleted rule proven gone by a JSON "does not exist" `404`, never a bare `404`; every wired receiver has a confirmed test-notification receipt or is explicitly `pending`; every monitor is `disabled` until real check-ins are observed, or its enablement is backed by a passing check-in assertion; the SDK instrumentation notes have real DSNs and no placeholder values; every change has a passing verification command and a runnable rollback command (not a rollback sentence) in the log; if any row of a batch failed, confirm the batch stopped there and the remainder was re-announced, per the mid-batch failure rule.

End the run with:

1. A summary table: finding ID, change, verification result, remaining risk.
2. The pending list for items outside this skill's reach (app-side instrumentation, CI/CD source-map uploads, receiver channel creation), each with a named owner.
3. A fresh `/scoutflo:audit-sentry` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Live-safety gate compares config against itself | Fetch an org-agnostic live list (`GET /organizations/`) that never takes the configured org as input, and assert the configured slug appears in it |
| New project gets the noisy auto-created default rule | Always create with `defaultRules: false`; verify right after creation that the project's issue-stream monitor has no alert attached (`workflowIds == []`; legacy fallback: an empty rules list) |
| `error.unhandled` filter never matches | Use `match: "is"` (is set), not `match: "eq"` with a value |
| `http.status_code` starts-with filter rejected | On the alerts API `value` is a string (`"5"`); only the legacy rules API wanted an integer (`5`) |
| Environment scoping silently does nothing | Use the rule-level `environment` field; the `latest_adopted_release` filter (legacy `LatestAdoptedReleaseFilter`) filters by release-adoption stage, not environment |
| Email action rejected with "user is not part of the project" | Email issue owners with a fallthrough (`config.targetType: "issue_owners"`, `data.fallthroughType: "AllMembers"`; legacy `targetType: "IssueOwners"`), never a single member's raw user ID |
| Envelope event rejected with a header/length mismatch | Compute the envelope `length` field as the exact byte count of the payload line; never hardcode it |
| Slack action PUT silently drops existing conditions or the email action | An alert PUT replaces the whole alert: anything missing by `id` is deleted. Fetch the current alert into a backup file, patch it, and PUT the full body back with every id |
| A wiring or tuning PUT turns a disabled alert back on | An alert PUT defaults `enabled` to `true` when it is omitted; build every body from the backup so it carries the backed-up `enabled`, and assert it after the write |
| A project-wide bulk call changes or deletes every alert in the project | Never send PUT or DELETE to `/workflows/?project=`; change one alert by id at `/workflows/{id}/` |
| Rule declared wired because the action type is present | Re-fetch and assert `channel_id`/`service` resolve to real IDs with `jq -e`, then send one test notification and record who confirmed receipt |
| Cron monitor left active with zero check-ins | Create monitors `disabled`; enable only after a passing `jq -e` assertion on observed `in_progress`, `ok`, and `error` check-ins |
| Uptime monitor creation fails | `intervalSeconds` accepts only 300, 600, 1800, or 3600 |
| Code mapping resolves the wrong file | Set `defaultBranch` to the branch actually deployed, not the repository's configured default, when they differ |
| Source maps "uploaded" but stack traces stay minified | Assert in-app stack frames carry source context on a real recent event with `jq -e`, not a visual skim |
| PII reaches Sentry before scrubbing is confirmed | Backup, apply, and re-fetch scrubbers and sensitive fields with a passing `jq -e` before any project accepts real production traffic |
| Replay or AI capture enabled without a privacy decision | Keep masking, PII capture, and prompt/response recording off by default; require an explicit, recorded exception per project |
| Batch continues past a failed write | Mid-batch failure rule: stop immediately, record what already applied and its backups, re-announce the remainder for a fresh approval |
| Rollback claimed without a runnable command | Every write section carries its own backup file and a restore/delete command that a reader can paste and run, never a rollback sentence alone |
| Bulk rule cleanup started with no rule-set backup | Dump every rule's JSON to `~/.scoutflo/sentry-rules-backup-<date>/` (every alert and metric monitor org-wide; legacy fallback: per project, plus org metric rules) before the first PUT or DELETE; restore is a PUT/POST of the saved body |
| Delete reported done on its 204 or 202, or on a bare 404 | Neither status proves removal, and a removed route answers `404` with an empty body for every id; confirm each with a follow-up GET that returns the JSON "does not exist" `404`, and report a per-rule verify line |
| Metric monitor PUT rejected when quieting the warning tier | Keep the resolve condition (`conditionResult` 0) and at most three conditions, each kept one with its `id`; on the legacy fallback ("Each trigger must have an associated action") remove the whole trigger instead of its action |
| Noisy-rule cleanup slows the fast tier too | Slow only burst, spike, and high-volume rules; leave New Issue, High Priority, Critical, and Escalating rules fast |
| Age gate suppresses the regressions it should catch | Never add an "issue newer than N days" age gate (`age_comparison`; legacy `AgeComparisonFilter`) to a regression rule (`regression_event`; legacy `RegressionEventCondition`) |
| Env-scoped rule goes permanently silent | Never env-scope rules on a project that emits no `environment` tag; fix the SDK env config first, then scope the rules |
| Rule rescoped to the wrong environment from its name | Derive the environment from the receiver channel the rule delivers to, not the rule's name |
| Temporary query mask becomes permanent | Record a revert condition naming the triggering deploy or PR for every temporary `!transaction` exclusion |
