---
name: audit-jsm
description: Read-only scored audit of Jira Service Management (JSM) Operations paging health across escalation and routing, on-call schedules, notification-policy noise controls (dedup, delay, suppress, auto-close, auto-restart), maintenance windows, heartbeat liveness, and unacknowledged-alert aging; writes findings.json and report.md and changes nothing. Use when the user mentions auditing or scoring JSM Operations, Opsgenie, Atlassian on-call, escalation or routing rules, alert notification policies, dead heartbeats, snoozed or suppressed alerts, or unacked JSM alerts. Do not use to change JSM (no setup-jsm ships yet; the audit names each fix), for Jira issues or service-desk request queues (this is the Operations/alerting side), or for the monitoring tools that send events to JSM (use their own audits).
---

# audit-jsm

Scored, read-only audit of the Jira Service Management Operations account that carries your paging: teams and their escalation and routing rules, on-call schedules, notification-policy noise controls, maintenance windows, heartbeat liveness, and the aging of alerts nobody acknowledged. It answers one question: when a monitoring tool sends JSM Operations an alert tonight, does a reachable human get paged exactly once, and did anyone act on it?

This skill audits the **JSM Operations** paging layer (the cloud successor to standalone Opsgenie), not the Jira issue tracker or the service-desk request queues, and not the monitoring tools that *send* events into it. The `for` durations, recovery thresholds, and grouping of those upstream tools belong to their own audits (`audit-lgtm`, `audit-grafana`, `audit-sentry`, `audit-datadog`, `audit-alertmanager`); this audit picks up where an event has already arrived at JSM.

Every command is read-only: GET against the JSM Operations REST API. Every mutating verb — acking, closing, snoozing, creating or editing a policy, heartbeat, or maintenance window — is forbidden; the full list is in [references/jsm-checks.md](references/jsm-checks.md) section 13. There is no `setup-jsm` yet, so every finding names its manual fix path in the JSM UI or API instead of a setup anchor.

Run this standalone, from `/scoutflo:audit-all`, or on a schedule via `/scoutflo:schedule-audits`.

**Multiple JSM sites, one run.** `jsm` in `toolkit.yaml` may be a single block (one `site`) or a **list of labeled targets**, each with its own `site`, optional `cloud_id`, `email_env`, and `token_env`. This audit **iterates every target** — enumerate them with `sh "${CLAUDE_PLUGIN_ROOT}/report-standard/toolkit-targets.sh" <cfg> jsm labels` and run the whole sequence below once per target with `SCOUTFLO_TARGET=<label>` set. Output goes to `jsm/<label>/<YYYY-MM-DD>/` for a labeled list, or the flat `jsm/<YYYY-MM-DD>/` for a single block (byte-identical to the prior single-block layout). Every `_edge/tenant_info` lookup and every JSM Operations REST call uses the target's own resolved `cloud_id` and credentials; there is no ambient default.

Outputs, per the [report standard](../../report-standard/README.md):

- `./scoutflo-audits/jsm/[<label>/]<YYYY-MM-DD>/findings.json` per the [findings schema](../../report-standard/findings-schema.md), finding IDs `JSM-NNN`
- `./scoutflo-audits/jsm/[<label>/]<YYYY-MM-DD>/report.md` per the [report template](../../report-standard/report-template.md), including the `## Inventory` section (the `render-report-viz.sh inventory` output) and the `## Findings by purpose` section (the `render-report-viz.sh lanes` output)
- `./scoutflo-audits/jsm/[<label>/]<YYYY-MM-DD>/inventory.json` per the [inventory schema](../../report-standard/inventory-schema.md) (`scoutflo-inventory/v1`): the complete Phase-2 catalog — one item per team, escalation policy, routing rule, on-call schedule, notification policy, heartbeat, integration, alert policy, and maintenance window (`kind`: `team`, `escalation_policy`, `route`, `schedule`, `notification_policy`, `heartbeat`, `integration`, `alert_policy`, `maintenance_window`) — each with `kind`, `covers`, `enabled`, `severity`, and `routes_to` for alerting objects. Built from the raw pull, never invented; redacted at capture, never a secret value.
- One appended line in `./scoutflo-audits/jsm/[<label>/]history.jsonl`
- One Slack brief, when `slack.webhook_env` is configured

## Doctor gate

| Integration | toolkit.yaml keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| JSM Operations | `jsm.site`, `jsm.email_env`, `jsm.token_env`, optional `jsm.cloud_id`, `jsm.teams` | the variables named by `email_env` (`JSM_EMAIL`) and `token_env` (`JSM_API_TOKEN`) | Atlassian API token whose user has a read/observer JSM Operations role (recipe in `/scoutflo:connect`) | read-only |
| Slack (optional) | `slack.webhook_env` | webhook variable | post to one channel | n/a |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: a customer running prod+nonprod often has no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall — but NEVER auto-pick an
  # environment (auditing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
# Load the home-anchored secret store so a token added to ~/.scoutflo/env (by connect,
# even mid-session) is seen here without re-exporting or opening a new terminal. It only
# sets *_env variables; no secret value is printed. A profile that already sources it makes
# this a no-op. This mirrors what /scoutflo:doctor does, so doctor and this audit agree.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Resolve the CURRENT jsm target from toolkit.yaml — a single block, or the SCOUTFLO_TARGET-selected
# item of a labeled list (the shared enumerator handles both; no yq required). Every call below uses
# THIS target's own site/cloud_id and credentials; there is no ambient default.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_KIND=$(sh "$TT" "$CFG" jsm kind); JT_N=$(sh "$TT" "$CFG" jsm count)
[ "${JT_N:-0}" -ge 1 ] || { echo "no jsm target configured in $CFG; run /scoutflo:connect"; exit 1; }
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
if [ "$JT_KIND" = seq ]; then JT_SEG="jsm/${JT_LABEL}"; else JT_SEG="jsm"; fi
JSM_SITE=$(sh "$TT" "$CFG" jsm get "$JT_IDX" site)
[ -n "$JSM_SITE" ] || { echo "jsm target '${JT_LABEL:-?}' has no site in $CFG; run /scoutflo:connect"; exit 1; }
# jsm.email_env / jsm.token_env name the VARIABLES that hold the credentials (defaults JSM_EMAIL /
# JSM_API_TOKEN); resolve the names from this target, read the values by name, presence-check only,
# never print them. For a single block these default to the well-known names, so nothing changes.
JSM_EMAIL_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" email_env); [ -n "$JSM_EMAIL_VAR" ] || JSM_EMAIL_VAR="JSM_EMAIL"
JSM_TOKEN_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" token_env); [ -n "$JSM_TOKEN_VAR" ] || JSM_TOKEN_VAR="JSM_API_TOKEN"
JSM_EMAIL=$(printenv "$JSM_EMAIL_VAR" 2>/dev/null || true)
JSM_API_TOKEN=$(printenv "$JSM_TOKEN_VAR" 2>/dev/null || true)
[ -n "${JSM_EMAIL:-}" ]     || { echo "${JSM_EMAIL_VAR} is not set (jsm target '${JT_LABEL}') — add it to ~/.scoutflo/env (echo 'export ${JSM_EMAIL_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
[ -n "${JSM_API_TOKEN:-}" ] || { echo "${JSM_TOKEN_VAR} is not set (jsm target '${JT_LABEL}') — add it to ~/.scoutflo/env (echo 'export ${JSM_TOKEN_VAR}=\"<paste>\"' >> ~/.scoutflo/env; chmod 600 ~/.scoutflo/env), or run /scoutflo:connect. The plugin reads that file, not your interactive shell."; exit 1; }
# jsm.cloud_id when set on THIS target; else resolve from the site's tenant_info edge route.
CLOUD_ID=$(sh "$TT" "$CFG" jsm get "$JT_IDX" cloud_id)
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId // empty')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve cloud_id for jsm target '${JT_LABEL}' from site ${JSM_SITE}; set this target's jsm.cloud_id explicitly (connect references/providers.md)"; exit 1; }
echo "jsm target: ${JT_LABEL} (site ${JSM_SITE}) -> ${JT_SEG}/"

JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
# Keep the body (do NOT discard to /dev/null) and capture the content-type, so a 200 that is
# really an HTML login/SPA/proxy page in front of api.atlassian.com fails closed instead of
# passing on the status alone.
JSM_BODY="$(mktemp)"
META="$(curl -s -o "$JSM_BODY" -w '%{http_code} %{content_type}' --max-time 10 \
  -u "${JSM_EMAIL}:${JSM_API_TOKEN}" "${JSM_BASE}/alerts?size=1")" || true
CODE="${META%% *}"; CT="${META#* }"
[ "$CODE" = "200" ] || { rm -f "$JSM_BODY"; echo "alerts probe returned ${CODE}: 401 = bad token/email (the token is the Basic password, not a GenieKey); 403 = user lacks Operations access; 404 = wrong cloud_id"; exit 1; }
# 200 alone is not proof: require JSON with the .values array the alerts list always returns.
printf '%s' "$CT" | grep -qi json && jq -e '.values | type=="array"' "$JSM_BODY" >/dev/null 2>&1 \
  || { rm -f "$JSM_BODY"; echo "alerts probe returned 200 but Content-Type=${CT} and the body is not the JSM Operations alerts JSON (.values array) — looks like an HTML login/SPA/proxy page, not api.atlassian.com; verify jsm.site/cloud_id"; exit 1; }
rm -f "$JSM_BODY"
echo "doctor gate: pass"
```

Never proceed past a failed doctor check and never downgrade one into a finding. `/scoutflo:doctor` runs the same probe standalone.

Read-only is enforced by GET-only usage, not by a token scope: an Atlassian API token inherits its user's permissions and cannot be scope-introspected. So the tier is declared, not proven; if the token's user can write, the audit still runs, but record in the report that the audit credential can do more than read.

## Live-safety gate

Print what you are pointed at and compare it to the config before the first real check:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Secret store, same layered resolver as the doctor gate — a token added mid-session is seen here too.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
# Resolve the CURRENT jsm target from config (single block, or the SCOUTFLO_TARGET-selected list
# item; no yq). Site, cloud_id, and the credential VARIABLE NAMES are this target's own — never typed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_N=$(sh "$TT" "$CFG" jsm count)
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
JSM_SITE=$(sh "$TT" "$CFG" jsm get "$JT_IDX" site)
JSM_EMAIL_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" email_env); [ -n "$JSM_EMAIL_VAR" ] || JSM_EMAIL_VAR="JSM_EMAIL"
JSM_TOKEN_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" token_env); [ -n "$JSM_TOKEN_VAR" ] || JSM_TOKEN_VAR="JSM_API_TOKEN"
JSM_EMAIL=$(printenv "$JSM_EMAIL_VAR" 2>/dev/null || true)
JSM_API_TOKEN=$(printenv "$JSM_TOKEN_VAR" 2>/dev/null || true)
CLOUD_ID=$(sh "$TT" "$CFG" jsm get "$JT_IDX" cloud_id)
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId // empty')"
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
# Resolve one page of teams and print account-identifying, non-secret facts.
TEAMS_SAMPLE="$(curl -fsS --max-time 15 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" "${JSM_BASE}/teams?size=5")"
COUNT="$(printf '%s' "$TEAMS_SAMPLE" | jq '(.values // []) | length')"
NAMES="$(printf '%s' "$TEAMS_SAMPLE" | jq -r '[.values[]?.name] | join(", ")')"
echo "jsm target: ${JT_LABEL} site=${JSM_SITE} cloud_id=${CLOUD_ID} sample_teams=${COUNT}: ${NAMES}"
printf '%s' "$TEAMS_SAMPLE" | jq -e '.values | type == "array"' >/dev/null \
  || { echo "teams endpoint did not return a team list; wrong cloud_id or wrong credentials — stop"; exit 1; }
echo "live-safety gate: pass — confirm this site and these team names belong to the account you intend to audit"
```

The `cloud_id` plus the API token select the target; there is no ambient default. The printed sample team names are the human check: if they belong to a different org than intended, stop and fix `jsm.site`/`jsm.cloud_id` or the exported token before any further read.

## Ground rules

- Configuration is metadata; observed behavior is proof. A notification policy in the list is `configured`; only a schedule that renders a live on-call row, a heartbeat reporting `Responsive`, or an alert the vendor's own timestamps show was acknowledged makes the paging path `validated-live`.
- API errors are evidence. A `401`, `403`, `404`, or timeout means bad token/email, a user without Operations access, or the wrong `cloud_id`. Record the code and what it implies; never convert an error into empty success.
- Never score from object counts.
  - ❌ `Scored escalation 90: eleven escalation policies exist.`
  - ✅ `Scored escalation 45: every team has an escalation, but two are one step with no repeat, and one routing rule notifies a schedule with no rotation; credit stops at partial.`
- Policies and heartbeats are team-scoped; coverage denominators name the teams audited.
  - ❌ `Scored coverage 90: dedup policies exist.` (which team? one team's policy says nothing about another's)
  - ✅ `Scored coverage 55: the payments and platform teams were audited (jsm.teams); the data team was not and is named as uncovered; within the two audited teams, one heartbeat reports Unresponsive.`
- Actionability is computed, not fabricated. JSM Operations has **no analytics or reporting API**: MTTA and the acked/auto-closed share are derived client-side from alert `createdAt`, `ackTime`, and `closeTime`, subject to the retrieval cap below. An invented "N% of your alerts are actionable" figure is banned, consistent with every other skill in this toolkit.
- Respect the hard retrieval cap in every claim: the alerts list returns at most `offset + size < 20000` alerts; any actionability figure states the window and the number of alerts it rests on.
- Never write a raw integration config, webhook, or contact value to disk, evidence, or the report. Captures keep IDs, names, types, states, and timestamps only.

## Version and shape traps

Current API-shape facts, all handled in the reference commands; do not "simplify" them away:

- **This is the JSM Operations API `v1` on `api.atlassian.com`, not classic Opsgenie.** Do not target `api.opsgenie.com` (end-of-sale, hard shutdown 2027-04-05) and do not send `Authorization: GenieKey` — that header does not authenticate this API. Auth is Atlassian API token over HTTP Basic (`email:token`). There is no `v2` for Operations.
- **Alert fields are flat, not nested under `report`.** Acknowledge and close times are top-level `ackTime` and `closeTime`; the integration is two flat strings `integrationType`/`integrationName`, not a nested object. The `status` enum uses `acked` (not "acknowledged") alongside `open`, `resolved`, `snoozed`, `closed`.
- **Heartbeat health is a `status` enum, not an `expired` flag.** A dead heartbeat is `status: "Unresponsive"` (there is no `expired` or `lastPingTime` field). `Off` means deliberately disabled; `Pending` means it has not reported yet.
- **Maintenance windows are flat `startDate`/`endDate` + `status`**, with no `time.type` (`schedule`/`for-N`/`indefinitely`). An active window whose `endDate` is far out, or one that is perpetually re-created, is the permanent-blackout finding.
- **Paging is `offset` + `size`, capped at `offset + size < 20000`.** There is no total-count endpoint for alerts; derive counts from the list within the cap and state the bound.

## Estate sizing

Count before judging, and declare the path in the terminal output. The unit here is the objects that drive per-team iteration plus the alert volume:

```bash
set -eu
# Each block is a fresh shell, so re-resolve the target + its connection params exactly as the
# doctor gate does (values do not persist across blocks). Single block, or the SCOUTFLO_TARGET-
# selected item of a labeled list; no yq required.
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_KIND=$(sh "$TT" "$CFG" jsm kind); JT_N=$(sh "$TT" "$CFG" jsm count)
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
if [ "$JT_KIND" = seq ]; then JT_SEG="jsm/${JT_LABEL}"; else JT_SEG="jsm"; fi
JSM_SITE=$(sh "$TT" "$CFG" jsm get "$JT_IDX" site)
JSM_EMAIL_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" email_env); [ -n "$JSM_EMAIL_VAR" ] || JSM_EMAIL_VAR="JSM_EMAIL"
JSM_TOKEN_VAR=$(sh "$TT" "$CFG" jsm get "$JT_IDX" token_env); [ -n "$JSM_TOKEN_VAR" ] || JSM_TOKEN_VAR="JSM_API_TOKEN"
JSM_EMAIL=$(printenv "$JSM_EMAIL_VAR" 2>/dev/null || true)
JSM_API_TOKEN=$(printenv "$JSM_TOKEN_VAR" 2>/dev/null || true)
CLOUD_ID=$(sh "$TT" "$CFG" jsm get "$JT_IDX" cloud_id)
[ -n "$CLOUD_ID" ] || CLOUD_ID="$(curl -fsS --max-time 10 "https://${JSM_SITE}/_edge/tenant_info" | jq -r '.cloudId // empty')"
[ -n "$CLOUD_ID" ] || { echo "could not resolve JSM cloud_id for target '${JT_LABEL}' (set this target's jsm.cloud_id or check jsm.site)"; exit 1; }
JSM_BASE="https://api.atlassian.com/jsm/ops/api/${CLOUD_ID}/v1"
SMALL_MAX_OBJECTS="15"    # example, tune to your environment
MEDIUM_MAX_OBJECTS="60"   # example, tune to your environment
BATCH_SIZE="10"           # teams per batch on the large path; example, tune it
jsm_count() {  # count of .values on a listing page (bounded read)
  curl -fsS --max-time 15 -u "${JSM_EMAIL}:${JSM_API_TOKEN}" "${JSM_BASE}${1}" \
    | jq -r '(.values // []) | length'
}
TEAMS="$(jsm_count /teams?size=100)"
INTEGRATIONS="$(jsm_count /integrations?size=100)"
SCHEDULES="$(jsm_count /schedules?size=100)"
TOTAL=$((TEAMS + INTEGRATIONS + SCHEDULES))
echo "teams=${TEAMS} integrations=${INTEGRATIONS} schedules=${SCHEDULES} scored_objects=${TOTAL}"

# Guided-walkthrough drift check, per report-standard/README.md.
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${JT_SEG}"
PREV_RUN="$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)"
DRIFT="first run"
if [ -n "$PREV_RUN" ] && [ -f "${PREV_RUN}/findings.json" ]; then
  PREV_TOTAL="$(jq -r '.estate.objects // empty' "${PREV_RUN}/findings.json")"
  if [ -n "$PREV_TOTAL" ]; then
    if [ "$PREV_TOTAL" -eq "$TOTAL" ]; then
      DRIFT="estate unchanged since ${PREV_RUN##*/} (${PREV_TOTAL} objects then, ${TOTAL} now)"
    else
      DRIFT="estate changed since ${PREV_RUN##*/}: ${PREV_TOTAL} -> ${TOTAL} objects"
    fi
  else
    DRIFT="previous run recorded no estate data; treating as first run"
  fi
fi
echo "drift: ${DRIFT}"
```

- **Small** (`TOTAL <= SMALL_MAX_OBJECTS`): one pass over everything. No worklist, no batching.
- **Medium** (`TOTAL <= MEDIUM_MAX_OBJECTS`): per-category passes (delivery, noise, coverage/health, actionability), completed in one run.
- **Large**: work teams in batches of `BATCH_SIZE` against a durable, run-ID-keyed worklist per the worklist rules in [skill-authoring-conventions.md](../../docs/skill-authoring-conventions.md): scan for a resumable run before minting a new run ID, one row per team id, lock before claiming a batch, mark rows done only after their pulls succeed, and assert zero pending rows before Phase 8 writes anything.

Never silently truncate: name the teams audited and any team skipped, and reflect it in the coverage denominators. Rate limits are unpublished for this API; on `429`, honor `Retry-After` and back off per the retry rule in [references/jsm-checks.md](references/jsm-checks.md) section 9.

### Scope checkpoint

On a large estate this audit pauses to let you scope before spending tokens, per the shared [estate-sizing scope checkpoint](../../report-standard/estate-scope-checkpoint.md). After the sizing step above computes the object count, run the shared checkpoint block:

```bash
set -eu
# The Estate sizing step above sets TOTAL to this audit's object count.
TOTAL="${TOTAL:?estate sizing must set TOTAL before the scope checkpoint}"
. "${CLAUDE_PLUGIN_ROOT}/skills/cli-interactive/lib/cli-interactive.sh"
. "${CLAUDE_PLUGIN_ROOT}/skills/checkpoint/lib/checkpoint.sh"
SCOPE="$(checkpoint_load_scope)"                # reuse a saved scope, or "all"
[ "$SCOPE" = "all" ] || echo "[checkpoint] reusing saved audit scope: ${SCOPE}"
if [ "${TOTAL}" -ge 501 ]; then
  echo "estate: ${TOTAL} objects (large path) — pausing to let you scope before spending tokens"
  cli_pause_before_audit "${TOTAL}"             # confirm before a large run
  cli_prompt_exclude_services                   # offer service/region exclusions
  echo "[checkpoint] narrow scope any time with /scoutflo:checkpoint; reset with /scoutflo:checkpoint --reset-scope"
fi
```

The large-path phases then run against the scoped set; the report names anything scoped out.

### Empty / hidden-teams guardrail

The scope checkpoint above narrows a *large* estate. This guardrail catches the opposite and more dangerous case — an account that looks **empty** because the key cannot see the teams that hold the paging config. It is the JSM analog of audit-elk's space-visibility trip-wire: auditing a token that sees no teams and reporting a confident `0/100` is the same wrong answer as auditing only the `default` Kibana space. Phase 2 materializes `teams-discovered.txt` (every team this key can see) and `teams-audited.txt` (the audited set); after they exist:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_KIND=$(sh "$TT" "$CFG" jsm kind); JT_N=$(sh "$TT" "$CFG" jsm count)
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
if [ "$JT_KIND" = seq ]; then JT_SEG="jsm/${JT_LABEL}"; else JT_SEG="jsm"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
RAW_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${JT_SEG}/${RUN_DATE}/raw"
# Teams discovered by the key vs audited this run. Any discovered team we did NOT audit?
UNAUDITED="$(comm -23 "${RAW_DIR}/teams-discovered.txt" "${RAW_DIR}/teams-audited.txt" 2>/dev/null | tr '\n' ' ')"
UNAUDITED_TRIM="$(printf '%s' "$UNAUDITED" | tr -d '[:space:]')"
ZERO_TEAMS=0; [ -s "${RAW_DIR}/teams-audited.txt" ] || ZERO_TEAMS=1
if [ "$ZERO_TEAMS" -eq 1 ]; then
  if [ -n "$UNAUDITED_TRIM" ]; then
    # Case A: nothing in the audited set, but other teams exist — the paging config is likely there.
    echo "[guard] 0 teams in the audited set, but these teams were discovered and not audited: ${UNAUDITED}"
    echo "[guard] pausing to re-scope rather than reporting an empty estate"
  else
    # Case B: zero teams visible to this key anywhere. Either the account truly has none, or the
    # token's JSM Operations role cannot view any team. Do NOT score a confident 0/100 or a
    # vacuous-high across the team-scoped categories — this is the JSM-024 visibility trip-wire.
    echo "[guard] 0 teams visible across the account — possible token role/visibility gap (JSM-024)"
    echo "[guard] widen the token to a read/observer JSM Operations role on the teams (see /scoutflo:connect) if teams exist"
  fi
fi
```

Behavior this enforces (Phase 8 honors it):

- **Case A** (zero in the audited set, other teams discovered): in an interactive run, present the discovered teams (id, name) as a numbered pick-list, validate the choice against `teams-discovered.txt`, write it into the audit scope (`jsm.teams` / `checkpoint_save_scope`), and re-size against the chosen team(s). In a non-interactive or scheduled run (`audit-all`, `schedule-audits`), take the safe default — audit **all discovered** teams — so the picker never hangs.
- **Case B** (zero teams visible anywhere): exclude the three team-scoped categories — **Alert delivery and escalation, Alert noise, Coverage and health** — as `blocked`, and renormalize per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md); emit finding **JSM-024** with the visibility-gap reason; and **never** write a confident `0/100`, a vacuously-high score, or an end-to-end claim. Keep **Actionability** *included*: JSM-030 to JSM-032 read the account-level alert stream (open/aging alerts, MTTA, close-without-ack), which does not depend on any team being visible, so the category is still assessable — and keeping it in means at least one scored category remains (excluding all four leaves nothing to score and `check-findings.sh` rejects an all-excluded scorecard). If team discovery itself failed (a 401/403 on `GET /v1/teams`), say discovery was unavailable as the reason. If the alert stream is *also* empty or unreadable so Actionability cannot be assessed either, emit no confident score at all — report the visibility gap (JSM-024) as the outcome, exactly as audit-elk does when space discovery is unavailable.

## Phase 1: Service context and teams

If `./scoutflo-audits/topology.md` exists, load it; its service list is the critical-service list and its names are canonical in findings, the coverage matrix, and `affected` arrays. Resolve the teams to audit from `jsm.teams` (discover from `GET /v1/teams` when omitted) and state them in the report. If topology.md does not exist, infer critical services from team and integration names, note the inference, and suggest `/scoutflo:map-topology`.

## Phase 2: Read-only inventory

Build the raw picture with the commands in [references/jsm-checks.md](references/jsm-checks.md) section 4: the audited teams, and per team the notification policies, escalations, routing rules, schedules, and heartbeats; plus account-wide integrations, global alert policies, and maintenance windows. Judgment starts in Phase 3. A 403 on any team is an auth-scope note attached to the checks that need it; a 404 means the wrong `cloud_id`.

## Phase 3: Alert delivery and escalation (JSM-001 to JSM-005)

Commands in section 5. Judge whether a page reaches a reachable human: every audited team has an escalation policy and no production team's policy is a single step with no repeat (`JSM-001`, critical when a team has none, high on a SPOF shape), escalation `repeat` and an `if-not-acked` rule present where the policy relies on re-notification (`JSM-002`), every routing rule resolves to an enabled, staffed schedule — an empty-schedule join pages nobody (`JSM-003`, high), schedules referenced are enabled with a non-empty rotation and someone on call now (`JSM-004`), and no integration on a live ingestion path sits `enabled: false` so nothing can create alerts (`JSM-005`, critical).

- ❌ `Delivery pass: every team names an escalation.`
- ✅ `Delivery partial: every team has an escalation, but the payments team's is one step with no repeat (JSM-001), and its primary routing rule notifies a schedule with an empty rotation (JSM-003); affected: payments.`

## Phase 4: Alert noise (JSM-010 to JSM-017)

Commands in section 6. This is the alert-hygiene category for the paging layer. Team notification-policy dedup (`deduplicationAction`) present where sources are chatty (`JSM-010`), `delayAction` used deliberately rather than as blanket suppression (`JSM-011`), no permanently-`suppress: true` notification policy with a broad filter that masks real alerts (`JSM-012`, high), `autoCloseAction` present so alerts do not accumulate stuck-open (`JSM-013`), `autoRestartAction` not a re-page storm — a short `waitDuration` with a high `maxRepeatCount` on a paging policy (`JSM-014`), sources set a stable `alias` so dedup collapses repeats (`JSM-015` — many alerts with `count > 1` confirm dedup working, all-unique or absent aliases are a duplication risk), global and team alert policies present and enabled for pre-creation normalization and priority (`JSM-016`), and no active maintenance window that is a permanent blackout disabling a live paging integration or policy (`JSM-017`, high). Then, from the live alert stream, whether operators are hand-**snoozing** the signals that should page — a human-driven blackout that a policy audit never sees, distinct from the config `suppress` of JSM-012 (`JSM-018`, medium; **verify-pending**, section 6.1).

Honest ceiling, stated in the report every run: notification policies, alias, and alert policies are metadata about intent; whether an alert actually deduplicated or was suppressed lives in the alert stream, which this audit reads at the list level (`count`, `status`, `alias`) but does not fully reconstruct. Integration-level Ignore/Create-Alert filters — the earliest native noise lever — are not exposed uniformly on the list API; where they cannot be read, say so rather than implying the policy layer is the whole story.

## Phase 5: Coverage and health (JSM-020 to JSM-024)

Commands in section 7. Heartbeats responsive — a heartbeat in `status: Unresponsive`, or a `status: Off` heartbeat that was meant to be live, is a source that stopped reporting with no one alerted (`JSM-020`, critical: it is silent monitoring, looks configured, detects nothing), critical services from topology each covered by a team and a routing path (`JSM-021`, high), the audited teams named and any team not audited named as uncovered rather than silently dropped (`JSM-022`), and the integration inventory read for stale or disabled integrations that are drift rather than live paths (`JSM-023`, low). Teams must be visible to this key at all — zero teams visible trips the empty/hidden-teams guardrail (`JSM-024`, high; the Phase 4 Case-B guardrail), which `blocks` the team-scoped categories with the visibility-gap reason rather than scoring a confident empty.

## Phase 6: Actionability (JSM-030 to JSM-032)

Commands in section 8. **Ceiling first**: JSM Operations has no analytics API, so every figure here is computed client-side from alert timestamps within the `offset + size < 20000` cap, and the report states the window and the alert count each figure rests on. Never fabricate a rate.

When it runs: open alerts unacknowledged past the aging threshold via the `status: open AND acknowledged: false` query — every one is a page nobody took (`JSM-030`, high), MTTA computed from `createdAt` to `ackTime` where humans acked, against target (`JSM-031`), and the share of alerts closed with no acknowledgement — `closeTime` set with `acknowledged: false` — the closest honest, vendor-timestamp-backed proxy for "these pages were noise" (`JSM-032`). Also, the priority distribution of the live stream: when it collapses to one priority (usually the default), priority is dead metadata and any priority-keyed routing criterion or policy filter is inert — the live-outcome complement to JSM-016's config check (`JSM-033`, medium; **verify-pending**, section 8.1). This priority gate lives on routing-rule criteria and notification/alert-policy filters, never on escalations (which key only on `if-not-acked`/`if-not-closed`).

- ❌ `Actionability: roughly 3% of alerts appear actionable (industry benchmark).`
- ✅ `JSM-032 fail for the ingest team: 44% of the last 1,000 alerts (440/1000, from createdAt/closeTime, 20k window) closed with no acknowledgement; the pages mostly close themselves, affected: ingest.`

## Phase 7: Coverage matrix and topology readiness

Fill one row per critical service using the per-service mapping in section 10 and the check-result vocabulary (`pass`, `partial`, `fail`, `blocked`, `not-in-scope`):

| Service | Ready | Delivery | Noise | Health | Actionability | Team | Gap |
| --- | --- | --- | --- | --- | --- | --- | --- |

Every cell carries its `passed/total` denominator; the Team column names which JSM Operations team the paging path lives in. Name affected services in findings.

**Flagship correlation — the end-to-end silent paging path.** Per the [depth doctrine](../../report-standard/depth-doctrine.md), the differentiator no free scanner assembles is walking ONE critical service's whole paging path and proving exactly where it silently breaks. For each critical service from topology (JSM-021), assemble one finding that chains: (1) **ingest** — is the source integration enabled (JSM-005) and its heartbeat Responsive (JSM-020), or already dark? (2) **middle** — is an active maintenance window (JSM-017), a broad `suppress` policy (JSM-012), or operator snoozing (JSM-018) eating its alerts, and does priority collapse (JSM-033) mean it arrives mis-prioritized so a priority-keyed routing criterion never matches (JSM-016 -> JSM-003)? (3) **delivery** — does its routing rule (JSM-003) land on a schedule staffed right now (JSM-004)? (4) **human** — if the sole on-call misses it, does the escalation repeat and reach a tier-2 (JSM-001/JSM-002)? State it as one sentence with live values, e.g.: "for payments, an event tonight matches routing rule R -> schedule S whose rotation is empty right now (nobody on call), and even if it reached the on-call the escalation is one step with no repeat — so an unacked page dies at tier-1; corroborated by JSM-032 showing 22% of this team's alerts already close unacked." Compute that cascade from the joins above; never assert "payments may be at risk", and never claim end-to-end while any critical service fails a coverage row.

Then render the Scoutflo Topology Readiness section per [topology-readiness.md](../../report-standard/topology-readiness.md): evaluate the six checks per critical service from `./scoutflo-audits/topology-export.json`, read-only. Gaps that map to an existing finding reference its ID; gaps with no finding get a `TOPO-` row pointing at `/scoutflo:map-topology`. Render check names and confidence per the standard: plain-English column headers, confidence as `n/10`, and — whenever any service is below ready — the ticket-ready readiness action plan table. If the export or topology.md is missing, or exists but describes a different target than this audit covers, the section renders the matching state from topology-readiness.md with its one-line unlock; it never guesses and never says a bare "unavailable". Readiness is reported, never folded into the 0-100 score.

**Provider-identity note, verified against the platform's current model:** on the Scoutflo platform JSM is a **ticketing** provider (`ticketing.jsm`), whose required schema field is `projectKey` and whose optional identity fields are `serviceDeskId`, `serviceName`, `team`, `environment`, and `integrationId`. So JSM's topology identity is an **incident sink** — a service that *creates tickets in* JSM — not an alerting source the way PagerDuty (`monitoring.pagerduty`) is. The Operations paging hygiene this audit scores is a layered operational signal correlated to a service by the optional `serviceName`/`team` fields, not the primary identity of the connection. State plainly which role a given connection is playing when it stalls at partial: a healthy `CREATES_TICKET_IN`-style connection reaching JSM is not an alerting gap, and the absence of an alerting-source edge to JSM is expected, not a defect. Because the identity fields are camelCase, the shared standard's camelCase-anchor trap applies — mirror `serviceName` into a literal `service`/`service_name` on the connection's attributes if Match confidence stalls despite the connection resolving (see [topology-readiness.md](../../report-standard/topology-readiness.md)).

## Phase 8: Score, write, brief

Score per [severity-and-scoring.md](../../report-standard/severity-and-scoring.md): each check yields `pass` (1.0), `partial` (0.5), or `fail` (0). `blocked` is unassessed and leaves the readiness denominator; `not-in-scope` leaves both readiness and assessment-coverage denominators. Category score is the assessed-credit ratio times 100 rounded down — `floor(((passed*2)+partial)*50/assessed)` where `assessed = pass+partial+fail`; overall is the weight-normalized sum over categories with at least one assessed check. Show assessment coverage separately. A category with zero assessed checks (a team that 403'd; actionability when the alert list is empty in the window) goes to `excluded[]` and out of overall, renormalized and stated; blocked checks inside an assessable category leave that category's readiness denominator. A fully blocked run is `unassessed` with `overall: null`, never 0/100. Score conservatively: when unsure between a defect and missing evidence, use `blocked` and state the exact evidence-unlock action. Assign each category a maturity value (`reactive`, `proactive`, `systematic`).

| Category | Weight | ID range |
| --- | ---: | --- |
| Alert delivery and escalation | 30 | JSM-001 to JSM-005 |
| Alert noise | 25 | JSM-010 to JSM-018 |
| Coverage and health | 25 | JSM-020 to JSM-024 |
| Actionability | 20 | JSM-030 to JSM-033 |

Weights sum to 100 and are unchanged: JSM-018 folds into the existing **Alert noise** category and JSM-033 into **Actionability** (both new checks are verify-pending — see [references/jsm-checks.md](references/jsm-checks.md) sections 6.1 and 8.1). Adding a check to a category changes only that category's denominator (credit ratio), never the cross-category weights.

The full check catalog and the target profile (what 100 means per category) are at the top of [references/jsm-checks.md](references/jsm-checks.md). IDs are stable: the same defect gets the same ID every run, one finding per failed check, affected objects and their team enumerated. Compute `points_recoverable` per finding by re-running the scoring model with that check at full credit; `info` findings and excluded categories carry 0. The executive summary states the gap to target and the two or three findings with the highest `points_recoverable` as the biggest levers.

End-to-end gate: claim end-to-end coverage only when the overall score is at or above 85, assessment coverage is 100%, every critical service passes every applicable coverage row, and no category or team was excluded. Below the gate, write "good base coverage", never "end to end". A run that audited only some teams cannot claim end-to-end; say which teams the claim rests on.

Lifecycle, exemptions, and totals, before rendering the report:

1. Load the previous run's `findings.json` when one exists; classify every finding per the lifecycle table in the [findings schema](../../report-standard/findings-schema.md) (`new`, `unchanged`, `regressed`; resolved IDs go to the delta, and the executive summary names regressions first).
2. Load `./scoutflo-audits/exemptions.yaml` when present. Entries with `id`, `reason`, and `expires` all set and unexpired suppress their finding into the Suppressed appendix; malformed or expired entries are reported, never honored. For a readiness finding, retain the observed `partial` or `fail` result on the same-ID `checks[]` row and add `suppressed: true` plus `suppression_reason`; set the finding's `lifecycle` to `suppressed` and its `points_recoverable` to 0. Suppressed readiness checks remain assessed for coverage but are excluded from readiness scoring; the scorecard states the suppressed count.
3. Every findings area and coverage cell carries its denominator (`passed/total`).
4. Emit one `checks[]` row for every stable `JSM-*` catalog check, including passes, partials, failures, blockers, and not-in-scope checks; partial/blocked/not-in-scope rows carry a non-empty `reason`. Derive category counts, readiness, assessment coverage, and `score.check_set` (the `cksum-v2:N:M` fingerprint over check id+category, category name+weight, and the gate) from that complete ledger; never write them independently.
5. Every finding declares `scoring_scope` (`readiness` for a same-ID non-pass `JSM-*` check; `non-scored` — with `points_recoverable: 0` and no `checks[]` row — for a finding that carries no scored check, such as a `TOPO-` topology-readiness gap) and `report_lanes`: `general-audit`, `ai-sre-readiness`, or both. Default to `general-audit` (operational reliability); add `ai-sre-readiness` only when the evidence bears on telemetry quality, service identity/naming, topology/ownership context, incident routing evidence, RCA trust, or action safety — coverage, naming, and routing-evidence findings are typically both, a pure reliability/security-posture finding is `general-audit` only. This classification never changes severity or score.

Emit and verify:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_KIND=$(sh "$TT" "$CFG" jsm kind); JT_N=$(sh "$TT" "$CFG" jsm count)
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
if [ "$JT_KIND" = seq ]; then JT_SEG="jsm/${JT_LABEL}"; else JT_SEG="jsm"; fi
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${JT_SEG}/${RUN_DATE}"
mkdir -p "$OUT"
# ... write findings.json (scoutflo-findings/v2 with a complete checks[] ledger, lifecycle +
# scoring_scope + report_lanes on every finding, and the full score{} object), inventory.json, and
# report.md per the report standard. The findings.json ".target" is the per-target slug (equal to
# $JT_SEG: "jsm" for a single block, "jsm/<label>" for a labeled-list target), so
# audit-all/correlation/render disambiguate multiple sites. Then verify:
jq -e --arg seg "$JT_SEG" '.schema == "scoutflo-findings/v2" and .target == $seg
  and (.checks | type == "array" and length > 0)
  and (.findings | type == "array")
  and (.findings | all(has("lifecycle") and (.scoring_scope | IN("readiness","non-scored")) and (.report_lanes | type == "array" and length > 0)))' \
  "$OUT/findings.json" >/dev/null && echo "findings.json valid"
grep -q '^# ' "$OUT/report.md" && echo "report.md present"
# Output conformance: reconciles the score{} object, checks[] ledger, and every v2 invariant
# (schema, check_set fingerprint, scoring_scope/report_lanes, referential integrity) before done.
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-findings.sh" "$OUT/findings.json"
# Inventory (scoutflo-inventory/v1): the complete Phase-2 catalog of what exists,
# built from the raw pull (never invented, redacted). counts.total must reconcile
# with items; the ## Inventory section of report.md IS this render.
jq -e --arg seg "$JT_SEG" '.schema == "scoutflo-inventory/v1" and .target == $seg and (.items | type == "array") and (.counts.total == (.items | length))' "$OUT/inventory.json" >/dev/null && echo "inventory.json valid"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" inventory "$OUT/inventory.json" >/dev/null && echo "inventory section renders"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" lanes "$OUT/findings.json" >/dev/null && echo "findings-by-purpose section renders"
grep -qxF '## Findings by purpose' "$OUT/report.md" && echo "findings-by-purpose section present"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/render-report-viz.sh" html "$OUT/findings.json" "$OUT/report.html" "$(dirname "$OUT")/history.jsonl"
sh "${CLAUDE_PLUGIN_ROOT}/report-standard/check-report.sh" "$OUT/report.md"
```

Compute the delta against the previous run's `findings.json` (the latest two date directories; first run states "first run, no delta"), then append one line to the history ledger, replacing any line for the same date:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
JT_KIND=$(sh "$TT" "$CFG" jsm kind); JT_N=$(sh "$TT" "$CFG" jsm count)
JT_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$JT_N" ]; do [ "$(sh "$TT" "$CFG" jsm label "$_i")" = "$SCOUTFLO_TARGET" ] && { JT_IDX=$_i; break; }; _i=$((_i+1)); done; fi
JT_LABEL=$(sh "$TT" "$CFG" jsm label "$JT_IDX")
if [ "$JT_KIND" = seq ]; then JT_SEG="jsm/${JT_LABEL}"; else JT_SEG="jsm"; fi
TARGET_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${JT_SEG}"
RUN_DATE="$(date -u +%Y-%m-%d)"
OUT="${TARGET_DIR}/${RUN_DATE}"
RESOLVED="0"   # fixed count from this run's delta; 0 on the first run
LINE="$(jq -c --arg d "$RUN_DATE" --argjson resolved "$RESOLVED" \
  '{run_date:$d, skill:"audit-jsm", overall:.score.overall, state:.score.state,
    scoring_model:.score.scoring_model, check_set:.score.check_set,
    assessment_coverage_percent:.score.assessment.coverage_percent, gate:.score.gate,
    end_to_end:.score.end_to_end, severity_counts:.severity_counts,
    lifecycle_counts:((reduce .findings[].lifecycle as $l ({}; .[$l] = (.[$l] // 0) + 1)) + {resolved:$resolved})}' \
  "$OUT/findings.json")"
TMP="$(mktemp)"
[ -f "${TARGET_DIR}/history.jsonl" ] && grep -v "\"run_date\":\"${RUN_DATE}\"" "${TARGET_DIR}/history.jsonl" > "$TMP" || true
printf '%s\n' "$LINE" >> "$TMP"
mv "$TMP" "${TARGET_DIR}/history.jsonl"
tail -1 "${TARGET_DIR}/history.jsonl" | jq -e '.run_date and ((.overall|type)=="number" or .overall==null) and .scoring_model and .check_set' >/dev/null && echo "history.jsonl updated"
```

The report's trend line renders the last five history.jsonl entries, oldest first. After the report is written, close with the run-completion message per the report standard ([report-template.md](../../report-standard/report-template.md#run-completion-message-what-the-skill-says-in-chat-when-the-run-finishes)): the one-line score headline, the top fixes by points_recoverable, the **absolute** report path, the OS-specific open command, and the leak-safe share pointer (Slack brief). Then send the Slack brief exactly as [report-template.md](../../report-standard/report-template.md) specifies: score, severity counts, top finding titles, delta line, topology readiness line, report path — titles only, never evidence values, service names allowed. When invoked by `audit-all`, skip the brief; the orchestrator sends exactly one combined message per run. Keep `./scoutflo-audits/` out of public version control; reports describe your paging setup.

## Metadata Load (v0.1.68+)

This skill reads the optional business-context SSOT to honor your guardrails:

```bash
set -eu
BC_JSON="${HOME}/.scoutflo/business_context.json"      # workspace projection, derived from the SSOT
BC_MD="${HOME}/.scoutflo/business_context.md"          # the SSOT itself (authoritative)
METADATA="${HOME}/.scoutflo/computed_metadata.jsonl"   # per-resource cache from business-context-resolver

# The workspace layer and the per-resource layer load TOGETHER, not either/or.
HAVE_PER_RESOURCE=0; HAVE_WORKSPACE=0
[ -f "$METADATA" ] && jq -e '.' "$METADATA" >/dev/null 2>&1 && HAVE_PER_RESOURCE=1
[ -f "$BC_JSON" ]  && jq -e '.' "$BC_JSON"  >/dev/null 2>&1 && HAVE_WORKSPACE=1
# Workspace source: the derived json, else the markdown SSOT directly (ssot-md fallback).
BC_SRC=""
if [ "$HAVE_WORKSPACE" -eq 1 ]; then BC_SRC="$BC_JSON"; elif [ -f "$BC_MD" ]; then BC_SRC="$BC_MD"; fi
if   [ "$HAVE_PER_RESOURCE" -eq 1 ] && [ "$HAVE_WORKSPACE" -eq 1 ]; then LOAD_METADATA_MODE="per-resource+workspace"
elif [ "$HAVE_PER_RESOURCE" -eq 1 ];                                then LOAD_METADATA_MODE="per-resource"
elif [ "$HAVE_WORKSPACE" -eq 1 ];                                   then LOAD_METADATA_MODE="workspace"
elif [ -n "$BC_SRC" ];                                              then LOAD_METADATA_MODE="ssot-md"
else                                                                     LOAD_METADATA_MODE="none"; fi
echo "metadata mode: $LOAD_METADATA_MODE"

# Load the workspace rules the apply step below honors. All fields optional; absence = neutral default.
if [ "$HAVE_WORKSPACE" -eq 1 ]; then
  ENVIRONMENT="$(jq -r '.environment // "production"' "$BC_JSON" 2>/dev/null || echo production)"
  COST_SENSITIVITY="$(jq -r '.cost_sensitivity // "medium"' "$BC_JSON" 2>/dev/null || echo medium)"
  CRITICAL="$(jq -r '.critical_dependencies[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  EXCLUSIONS="$(jq -r '.exclusions // {} | [.accounts?, .regions?, .services?, .resources?] | add // [] | .[]? // empty' "$BC_JSON" 2>/dev/null || true)"
  jq -r --arg e "$ENVIRONMENT" '.environment_map[]? | select(.environment==$e)' "$BC_JSON" 2>/dev/null || true  # per-env profile/project/context + uptime_sla
  jq -r '.service_slas[]? | "\(.service)=\(.sla)"' "$BC_JSON" 2>/dev/null || true                               # per-service SLA (wins over the env default)
elif [ "$LOAD_METADATA_MODE" = "ssot-md" ]; then
  # Only business_context.md exists (json not derived): read the same rules from the SSOT directly.
  ENVIRONMENT="$(grep -iA5 '^## Environment' "$BC_MD" | grep -iE 'Stage:' | head -1 | sed -E 's/.*Stage:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$ENVIRONMENT" ] || ENVIRONMENT="production"
  COST_SENSITIVITY="$(grep -iA3 '^## Cost Sensitivity' "$BC_MD" | grep -iE 'Primary:' | head -1 | sed -E 's/.*Primary:\**[[:space:]]*//; s/[][]//g; s/[[:space:]]*$//' | tr 'A-Z' 'a-z')"; [ -n "$COST_SENSITIVITY" ] || COST_SENSITIVITY="medium"
  CRITICAL="$(awk '/^## Critical Services/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
  EXCLUSIONS="$(awk '/^## Exclusions/{f=1;next} /^## /{f=0} f' "$BC_MD" | grep -oE '`[^`]+`' | tr -d '`')"
fi
# When HAVE_PER_RESOURCE=1, look each finding's affected resource up in computed_metadata.jsonl and let
# its per-resource action/escalation/sla refine (never weaken) the workspace rule for that one resource.
```

When context is available, apply it per [BUSINESS-CONTEXT-INTEGRATION-v0168.md](../../docs/BUSINESS-CONTEXT-INTEGRATION-v0168.md): **exclude** resources matched by an exclusion (record them `not-in-scope` with the reason, never a fail); **escalate** findings on a `critical_dependencies` service; reduce severity for a gap that exists only in a non-production `environment`; and apply `cost_sensitivity` to ordering. With no context, run neutral defaults and say so — never invent a business rule.

## Remediation pointers

No `setup-jsm` ships yet, so every finding's `remediation` field names the concrete manual fix location. When a setup skill lands, these become anchors without the finding IDs changing:

| Finding area | Fix location today |
| --- | --- |
| Missing or single-step escalation, no repeat (JSM-001, JSM-002) | JSM > Operations > Teams > (team) > Escalations — add a step or an `if-not-acked` rule and a repeat |
| Empty-schedule routing join, unstaffed or disabled schedule (JSM-003, JSM-004) | Team > Routing rules and Schedules — point routing at a staffed schedule; fill the rotation or enable it |
| Disabled integration on a live path (JSM-005) | Team > Integrations — re-enable the integration or record why it is off |
| No dedup, blanket suppress, missing/aggressive auto-close/auto-restart (JSM-010 to JSM-014) | Team > Policies (Notification) — add a `deduplicationAction`, narrow an over-broad `suppress`, set `autoCloseAction`, or tame `autoRestartAction` |
| Sources not setting a stable alias (JSM-015) | Fix the sending tool's alert payload to set a stable `alias` (its own audit names the tool) |
| Missing/disabled alert policies, permanent maintenance window (JSM-016, JSM-017) | Global/Team Alert policies — enable normalization; Maintenance — time-bound or remove the window |
| Operators hand-snoozing paging signals (JSM-018) | No JSM config object exists — on-call process review plus fix the noisy source (its own audit names the tool); JSM has no bulk snooze-policy to tune |
| Priority collapse, priority-keyed routing/normalization inert (JSM-033) | Global/Team Alert policies — add Update-priority rules keyed on source/message filters so critical sources normalize to P1/P2 before creation |
| Dead or disabled heartbeat (JSM-020) | Team > Heartbeats — fix the source that stopped pinging, or record the heartbeat as retired |
| Uncovered critical service, uncovered team, stale integrations (JSM-021 to JSM-023) | Add a team/routing path for the service; audit the missing team; retire orphaned integrations |
| Unacked aging, slow MTTA, auto-close-heavy alerts (JSM-030 to JSM-032) | On-call process review; fix the noisy sending tool (its own audit names it) or the team's dedup/priority |
| Topology readiness gaps with no finding | `/scoutflo:map-topology` |

## Common Failure Modes

All thresholds and windows named in the checks are example values; tune them to your workloads before treating a miss as a failure.

| Failure | Prevention |
| --- | --- |
| Audit pointed at classic Opsgenie (`api.opsgenie.com`) or using a GenieKey | This is the JSM Operations API `v1` on `api.atlassian.com`; auth is an Atlassian API token over HTTP Basic (`email:token`) |
| Alert `ackTime`/`closeTime` read from a `report` object | The cloud API returns them flat at the top level; there is no `report` nesting |
| Heartbeat health read from an `expired` flag | There is no `expired` field; a dead heartbeat is `status: Unresponsive` (`Off` = disabled, `Pending` = never reported) |
| Actionability figure fabricated or implied as vendor analytics | There is no analytics API; compute MTTA and acked/auto-closed share client-side from timestamps and state the 20k-alert window |
| Alert sweep trusted beyond the retrieval cap | `offset + size` must stay below 20000; state the bound wherever a count depends on it |
| Only one team audited, others silently missed | Policies and heartbeats are team-scoped; iterate `jsm.teams` and name every team audited and skipped in the denominators |
| Zero teams visible, scored a confident 0/100 | The token's role sees no team, so the team-scoped categories look empty — this is a visibility gap, not an empty estate. Trip the empty/hidden-teams guardrail (JSM-024): block Delivery/Noise/Coverage-health, keep Actionability, never a confident 0/100 |
| Notification policy count scored as noise control | Judge the action objects (dedup, suppress, auto-close), not the number of policies |
| Blanket `suppress: true` policy read as noise reduction | A broad `suppress` filter masks real alerts; review the filter before crediting it |
| Empty-schedule routing join filed as healthy | A routing rule that notifies a schedule with no rotation pages nobody; resolve the schedule before crediting delivery |
| Quiet heartbeat assumed healthy | `Responsive` is healthy; `Unresponsive`/`Off` on a live source is a silent monitoring gap |
| Integration config or contact values written into evidence | Captures keep IDs, names, types, states, and timestamps only |
| Toolkit brief webhook conflated with JSM notification channels | Two different systems; the Slack brief webhook is the toolkit's own reporting channel |
| Priority-keyed branching attributed to an escalation step (JSM-002) | JSM escalation rules condition ONLY on `if-not-acked`/`if-not-closed` — there is no priority condition on escalations. The priority gate lives on routing-rule `criteria` and notification/alert-policy filters; JSM-033/JSM-016 chain to JSM-003 (routing), never to JSM-002 |
| Snooze finding (JSM-018) scored off `snoozed`/`snoozedUntil` fields | Only the `status` enum value `snoozed` (and the flat `alias`/`message`/`createdAt`) is confirmed; the per-alert `snoozed`/`snoozedUntil` on `/v1/alerts/{id}` is verify-pending — the scored signal is the `status: snoozed` count + top message, section 6.1 |
