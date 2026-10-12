---
name: setup-gcp
description: Guided hardening of Google Cloud Monitoring from audit-gcp findings; creates and repairs notification channels, uptime checks, alert policies, logs-based metrics, and dashboards, announcing each change, waiting for confirmation, then verifying live. Monitoring-plane writes only. Use when the user asks to fix a GCP-NNN finding, wire GCP alert routing, add uptime checks or alert policies, or create logs-based metrics. Do not use for read-only assessment (use audit-gcp), for in-cluster stacks (use setup-lgtm), or for Ops Agent installs and VM, GKE, load balancer, firewall, or IAM changes (planned here, never executed).
disable-model-invocation: true
---

# setup-gcp

Fixes findings from an `audit-gcp` run. Input is one or more finding IDs from the latest `./scoutflo-audits/gcp/[<label>/]<date>/findings.json`; you usually arrive here from a finding's `remediation` pointer, for example `setup-gcp#fix-uptime-coverage`.

| Finding ID | Fix section |
| --- | --- |
| GCP-001, GCP-003, GCP-005 | [Fix notification channels](#fix-notification-channels) |
| GCP-002 | [Attach channels to policies](#attach-channels-to-policies) |
| GCP-004 | [Prove channel delivery](#prove-channel-delivery) |
| GCP-006 | [Review snoozes](#review-snoozes) |
| GCP-010 to GCP-016 | [Fix uptime coverage](#fix-uptime-coverage) |
| GCP-020, GCP-023, GCP-024 | [Add VM pressure policies](#add-vm-pressure-policies) |
| GCP-021, GCP-022 | [Gate memory and disk on the Ops Agent](#gate-memory-and-disk-on-the-ops-agent) |
| GCP-031, GCP-032, GCP-033 | [Add GKE health policies](#add-gke-health-policies) |
| GCP-017, GCP-041, GCP-042 | [Add LB alert policies](#add-lb-alert-policies) |
| GCP-050, GCP-051, GCP-052 | [Create logs-based metrics and their alerts](#create-logs-based-metrics) |
| GCP-060 to GCP-066 | [Improve alert documentation](#improve-alert-documentation) |
| GCP-070, GCP-071 | [Build dashboards](#build-dashboards) |
| GCP-007, GCP-008, GCP-030, GCP-040, GCP-043, GCP-053, GCP-054, GCP-067 | [Plan out-of-scope changes](#plan-out-of-scope-changes) (plan only) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

**Write scope: the Monitoring plane only.** This skill creates and updates notification channels, uptime checks, alert policies, logs-based metrics, and dashboards. Out of write scope, always: Ops Agent installs, GKE cluster or node pool changes (including telemetry component enablement), log sink changes, load balancer, backend, health-check, firewall, IAM, DNS, and certificate changes, and any VM mutation. Those are controlled rollouts or traffic-impacting changes owned by the people who own those surfaces; this skill records a plan with a named owner instead ([Plan out-of-scope changes](#plan-out-of-scope-changes)). It also never mutates local gcloud state: no `gcloud config set`, no `configurations activate`; every command carries explicit flags.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the command or JSON payload with real values filled in (webhook URLs and tokens excepted; announce channel display names, never label values), its risk class, and its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If reality forces a different change (an API rejects a field, a flag differs on your gcloud version), stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `jq -e` or a captured HTTP code. A write is unverified until a read proves it.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

Order discipline, kept from hard experience: routing before alerts (channels first, then policies that reference them), logs-based metrics before log-alert policies, dashboards last. A policy created before its channel exists pages nobody and verifies dirty. Where you run parallel environments, fix the non-production environment first and confirm the result before touching production.

## Doctor gate

Elevated tier: this skill mutates Cloud Monitoring and Cloud Logging metric state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Secret | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| GCP | `gcp.project`, optional `gcp.region`, optional `gcp.credentials_env` | key-file path variable when used; presence only | `roles/monitoring.editor`, plus `roles/logging.configWriter` when logs-based metrics are in scope | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done
[ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
if [ ! -f "$CFG" ]; then
  # Multi-environment setup: if you run prod and nonprod you often have no default
  # toolkit.yaml but named variants (toolkit-prod.yaml, toolkit-nonprod.yaml). List
  # them so the choice is directed, not a dead stall, but NEVER auto-pick an
  # environment (changing the wrong one is worse than asking).
  ENVCFGS=$(for d in "./.scoutflo" "$HOME/.scoutflo"; do ls "$d"/toolkit-*.yaml 2>/dev/null; done || true)
  if [ -n "$ENVCFGS" ]; then
    echo "no default config at $CFG, but found environment-specific configs:"
    printf '%s\n' "$ENVCFGS" | sed 's/^/  - /'
    echo "re-run with SCOUTFLO_CONFIG=<one of the above> for the environment you want (never auto-picked), or run /scoutflo:connect to create a default"
  else
    echo "missing $CFG; run /scoutflo:connect"
  fi
  exit 1
fi
# Load the secret store the way /scoutflo:doctor and audit-gcp do, so a variable added to
# ~/.scoutflo/env is seen here. It only sets *_env variables; nothing is printed.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in gcloud curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Resolve the gcp target with the shared enumerator: a single block, or the SCOUTFLO_TARGET-named
# item of a labeled list. A list with no matching SCOUTFLO_TARGET stops; a target is never guessed.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  GCP_IDX=-1; _i=0
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "gcp is a labeled list in $CFG; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' has no project in $CFG; run /scoutflo:connect"; exit 1; }
echo "gcp target: ${GCP_LABEL} (project ${GCP_PROJECT})"
# gcp.credentials_env is the NAME of the variable holding a service-account key-file path.
# Resolve it by name, require the file, and mint from it, so a configured key is never
# silently replaced by your gcloud login. Unset means your active gcloud login is the identity.
GCP_CRED_VAR="$(sh "$TT" "$CFG" gcp get "$GCP_IDX" credentials_env)"
if [ -n "$GCP_CRED_VAR" ]; then
  GCP_CRED_PATH="$(printenv "$GCP_CRED_VAR" 2>/dev/null || true)"
  [ -n "$GCP_CRED_PATH" ] || { echo "gcp.credentials_env names '${GCP_CRED_VAR}', but that variable is unset in this shell; export it (recipe in /scoutflo:connect) and rerun"; exit 1; }
  [ -f "$GCP_CRED_PATH" ] || { echo "gcp.credentials_env ('${GCP_CRED_VAR}') names a missing key file"; exit 1; }
  export GOOGLE_APPLICATION_CREDENTIALS="$GCP_CRED_PATH"
  TOKEN="$(gcloud auth application-default print-access-token)"
  export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"
else
  TOKEN="$(gcloud auth print-access-token)"
fi
gcloud projects describe "$GCP_PROJECT" --format='value(projectId)'
# status-probe-ok: gcloud authenticated the identity above; monitoring.googleapis.com is a fixed JSON API and 403/404 are handled below.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer ${TOKEN}" \
  "https://monitoring.googleapis.com/v3/projects/${GCP_PROJECT}/notificationChannels?pageSize=1")"
[ "$code" = "200" ] || { echo "monitoring api: ${code} (expected 200); a 403 means the identity lacks Monitoring access or the API is disabled, a 404 means the project id is wrong"; exit 1; }
echo "monitoring api: ${code}"
```

Expected: the `gcp target:` line, the project id and `monitoring api: 200`, each asserted by the block itself. Editor-tier permission cannot be introspected cheaply, so the first write of the run is the scope test: a `403` on it means the identity lacks `monitoring.editor` (or `logging.configWriter` for metric writes). Stop, report which role is missing, and point at `/scoutflo:connect`; do not keep trying other writes to find one that works.

## Live-safety gate

Resolve the target and the identity from `toolkit.yaml` itself, never from a value typed into the block, prove the identity the change blocks will act as can read that project, and print what you are about to change:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Same target resolution as the doctor gate: never hand-typed, and a labeled list needs SCOUTFLO_TARGET.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
[ "${GCP_N:-0}" -ge 1 ] || { echo "no gcp target configured in $CFG; run /scoutflo:connect"; exit 1; }
GCP_IDX=0
if [ "$GCP_KIND" = seq ]; then
  GCP_IDX=-1; _i=0
  while [ "$_i" -lt "$GCP_N" ]; do [ "$(sh "$TT" "$CFG" gcp label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { GCP_IDX=$_i; break; }; _i=$((_i+1)); done
  [ "$GCP_IDX" -ge 0 ] || { echo "STOP: gcp is a labeled list in $CFG; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" gcp labels | tr '\n' ' ')"; exit 1; }
fi
GCP_LABEL=$(sh "$TT" "$CFG" gcp label "$GCP_IDX"); GCP_PROJECT=$(sh "$TT" "$CFG" gcp get "$GCP_IDX" project)
[ -n "$GCP_PROJECT" ] || { echo "gcp target '${GCP_LABEL:-?}' has no project in $CFG; run /scoutflo:connect"; exit 1; }
# Identity comes from gcp.credentials_env. The change blocks act as the key file in
# GOOGLE_APPLICATION_CREDENTIALS when it is set, else as your gcloud login, so that variable
# must agree with the config or the identity printed here is not the one that writes.
GCP_CRED_VAR="$(sh "$TT" "$CFG" gcp get "$GCP_IDX" credentials_env)"
if [ -n "$GCP_CRED_VAR" ]; then
  GCP_CRED_PATH="$(printenv "$GCP_CRED_VAR" 2>/dev/null || true)"
  { [ -n "$GCP_CRED_PATH" ] && [ -f "$GCP_CRED_PATH" ]; } || { echo "live-safety gate failed: gcp.credentials_env ('${GCP_CRED_VAR}') is unset in this shell or names a missing key file"; exit 1; }
  [ "${GOOGLE_APPLICATION_CREDENTIALS:-}" = "$GCP_CRED_PATH" ] || { echo "STOP: the change blocks act as GOOGLE_APPLICATION_CREDENTIALS, which does not name the key file in ${GCP_CRED_VAR}; set it to that file in your shell and rerun"; exit 1; }
  CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN
  echo "identity: $(jq -r '.client_email // "unknown"' "$GCP_CRED_PATH") (key file via ${GCP_CRED_VAR})"
else
  [ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || { echo "STOP: GOOGLE_APPLICATION_CREDENTIALS is set but gcp.credentials_env is not, so the change blocks would act as that key file instead of your gcloud login; unset it or set gcp.credentials_env"; exit 1; }
  [ -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ] && [ -z "$(gcloud config get-value auth/access_token_file 2>/dev/null)" ] \
    || { echo "STOP: an access-token override is set, so gcloud would act as that token, not the login printed here; unset it and rerun"; exit 1; }
  echo "identity: $(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
  IMP="$(gcloud config get-value auth/impersonate_service_account 2>/dev/null || true)"
  [ -z "$IMP" ] || echo "acting as (impersonated): ${IMP}"
fi
echo "gcp target: ${GCP_LABEL} -> project ${GCP_PROJECT}"
echo "ambient gcloud project (printed for awareness, never used): $(gcloud config get-value project 2>/dev/null || echo unset)"
# `projects describe X` echoes back the id you passed, so comparing its projectId to X proves
# nothing. The assertion is that the call succeeds as this identity; the number and name are for you.
DESC="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectId,projectNumber,name)')" \
  || { echo "live-safety gate failed: cannot read project '${GCP_PROJECT}' as this identity (wrong id, or no resourcemanager.projects.get)"; exit 1; }
echo "target project, confirm the id, number and name are the project you intend to change: ${DESC}"
```

Expected: the identity, target, ambient and target-project lines print and nothing stops the block. The block asserts three things: on a labeled list, `SCOUTFLO_TARGET` names the target; the identity the change blocks act as (the key file in `GOOGLE_APPLICATION_CREDENTIALS`, or your gcloud login) is the one `gcp.credentials_env` names; and that identity can read the project. It cannot prove the project is the one you mean, so read the printed id, number and name, and stop and report if they are not the project your team intends to change or the identity is not the one intended for setup work. Never proceed on "probably the right project". The guard on every write is its explicit target: fill `GCP_PROJECT` in each change block with the project this gate printed; every gcloud call passes `--project`, and the REST blocks refuse a resource name outside `projects/<GCP_PROJECT>/`. In key-file mode every change block mints its own token from that key and exports it as `CLOUDSDK_AUTH_ACCESS_TOKEN`, so gcloud and curl act as the identity printed here. Unlike the doctor gate, this block does not load `~/.scoutflo/env`, because the change blocks do not either: a key path kept only there stops the gate, and the fix is exporting it in the shell your change blocks run in. The ambient gcloud project is printed only so a drift is visible; no block reads it, and pointing the skill elsewhere is an edit to `toolkit.yaml`, never `gcloud config set`. Every object in this skill is addressed by the full resource name captured from the audit run (`projects/<id>/alertPolicies/<id>`), never by display-name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
# The audit writes gcp/<date>/ for a single block and gcp/<label>/<date>/ for a labeled list.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
GCP_KIND=$(sh "$TT" "$CFG" gcp kind); GCP_N=$(sh "$TT" "$CFG" gcp count)
GCP_SEG="gcp"
if [ "$GCP_KIND" = seq ]; then
  GCP_SEG=""; _i=0
  while [ "$_i" -lt "$GCP_N" ]; do _l="$(sh "$TT" "$CFG" gcp label "$_i")"; [ "$_l" = "${SCOUTFLO_TARGET:-}" ] && { GCP_SEG="gcp/${_l}"; break; }; _i=$((_i+1)); done
  [ -n "$GCP_SEG" ] || { echo "STOP: gcp is a labeled list; set SCOUTFLO_TARGET to the target the live-safety gate printed"; exit 1; }
fi
# Date-shaped run folders only: this skill's own setup-<date>/ folder, runs/ and <label>/ hold no audit findings.
FINDINGS="$(ls -d "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${GCP_SEG}"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/findings.json 2>/dev/null | sort | tail -1)"
[ -n "$FINDINGS" ] || { echo "no audit-gcp findings.json under ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${GCP_SEG}/<date>/; run /scoutflo:audit-gcp first"; exit 1; }
jq -e --arg seg "$GCP_SEG" '.target == $seg' "$FINDINGS" >/dev/null \
  || { echo "STOP: ${FINDINGS} is not an audit of target ${GCP_SEG}"; exit 1; }
echo "findings: ${FINDINGS}"
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "$FINDINGS"
RUN_DATE="$(date -u +%Y-%m-%d)"
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-${RUN_DATE}"
BACKUP_DIR="${WORK_DIR}/backups"
mkdir -p "$BACKUP_DIR"
```

Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown; deletions (a channel, a policy, a snooze cancellation) are still re-confirmed individually at their announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Re-fetch the failed object's current state, report what happened, and re-announce the remainder only after the user decides. A half-applied policy (created but with no channels attached) is worse than no policy; verify or roll back the failed object before anything else runs.

**Backups are GET-before-write.** Before any update, capture the object's current JSON into `BACKUP_DIR` with a plain GET. Channel backups contain label values (webhook URLs, tokens): they stay local, out of version control, and out of every announcement. Rollback is re-applying the backup or deleting the created object; every section names its restore command, and one worked restore pair lives in [Attach channels to policies](#attach-channels-to-policies).

gcloud flag names shift across versions: for every gcloud write in this skill, check the subcommand's `--help` before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags.

## Fix notification channels

For `GCP-001`, `GCP-003`, `GCP-005`. Monitoring-plane writes; nothing redeploys. Name channels per environment (`<team> <environment> alerts`) even when they route to the same workspace, so a page's origin is readable before its body. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of notification channels; they are different webhooks with different jobs.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="payments production alerts"   # <team> <environment> alerts naming pattern
CHANNEL_EMAIL="oncall@example.org"          # the address your team actually watches
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)"
mkdir -p "$WORK_DIR"
jq -n --arg dn "$CHANNEL_NAME" --arg em "$CHANNEL_EMAIL" \
  '{type:"email", displayName:$dn, labels:{email_address:$em}, enabled:true}' > "${WORK_DIR}/channel.json"
# Capture the POST first: a 4xx stops the block here, and the response (label values included) is never printed.
RESP="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d @"${WORK_DIR}/channel.json" "${MON_API}/projects/${GCP_PROJECT}/notificationChannels")"
NEW_CHANNEL="$(printf '%s' "$RESP" | jq -r '.name // empty')"
[ -n "$NEW_CHANNEL" ] || { echo "create returned no channel name; stop and re-fetch before anything else runs" >&2; exit 1; }
echo "created: ${NEW_CHANNEL}"
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_CHANNEL}" \
  | jq -e '.enabled == true and .type == "email"'
```

Expected: the new channel's resource name and a final `jq -e` exit 0. For webhook, Slack, or PagerDuty channel types the sensitive value (URL, token, service key) goes into the payload file from an unechoed variable, is never printed, and the announcement shows the display name and type only.

Rollback, in its own fresh shell:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
NEW_CHANNEL="<channel-resource-name>"   # the "created:" value, projects/<project>/notificationChannels/<id>
case "$NEW_CHANNEL" in "projects/${GCP_PROJECT}/notificationChannels/"?*) ;; *) echo "Set NEW_CHANNEL to a channel this setup created in ${GCP_PROJECT}" >&2; exit 1 ;; esac
curl -fsS --max-time 30 -X DELETE -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_CHANNEL}" > /dev/null
curl -sS --max-time 30 -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_CHANNEL}"
```

Expected: `404`. For `GCP-005`, replacing a dead channel means creating the good one, re-pointing every referencing policy ([next section](#attach-channels-to-policies)), verifying, and only then deleting the dead channel, confirmed individually with its display name, type and label keys quoted, never its label values.

## Attach channels to policies

For `GCP-002`. Update the policy's `notificationChannels` field only, with an explicit `updateMask` so nothing else moves. This is also the worked backup-and-restore pair for every PATCH in this skill.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
POLICY_NAME="projects/your-project-id/alertPolicies/1234567890"   # full resource name from the audit capture
CHANNEL_NAME="projects/your-project-id/notificationChannels/987654321"   # the channel to attach
case "$POLICY_NAME" in "projects/${GCP_PROJECT}/alertPolicies/"?*) ;; *) echo "Set POLICY_NAME to the policy to patch in ${GCP_PROJECT}" >&2; exit 1 ;; esac
case "$CHANNEL_NAME" in "projects/${GCP_PROJECT}/notificationChannels/"?*) ;; *) echo "Set CHANNEL_NAME to a channel in ${GCP_PROJECT}" >&2; exit 1 ;; esac
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/policy-$(basename "$POLICY_NAME").json"
# 1. Backup (GET-before-write):
# Keep the original: a re-run or a second change to this policy today must not replace it.
[ ! -e "$BACKUP_FILE" ] || { echo "${BACKUP_FILE} already exists: restore from it first, or move it before another change" >&2; exit 1; }
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" > "$BACKUP_FILE"
[ -s "$BACKUP_FILE" ] || { echo "backup failed; nothing was changed" >&2; exit 1; }
echo "backup: ${BACKUP_FILE}"
# 2. Patch the one field, announced first:
jq -n --arg ch "$CHANNEL_NAME" '{notificationChannels: [$ch]}' \
  | curl -fsS --max-time 30 -X PATCH -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d @- "${MON_API}/${POLICY_NAME}?updateMask=notificationChannels" >/dev/null
# 3. Verify by re-fetch:
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" \
  | jq -e --arg ch "$CHANNEL_NAME" '.notificationChannels | index($ch)'
```

Expected: exit 0. To attach without dropping existing channels, build the array from the backup: `jq '{notificationChannels: (.notificationChannels + ["NEW"])}' "$BACKUP_FILE"`. **Restore pair, run as written when a patch must be undone:**

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
POLICY_NAME="<policy-resource-name>"   # the patched policy, projects/<project>/alertPolicies/<id>
case "$POLICY_NAME" in "projects/${GCP_PROJECT}/alertPolicies/"?*) ;; *) echo "Set POLICY_NAME to the patched policy in ${GCP_PROJECT}" >&2; exit 1 ;; esac
BACKUP_DATE="YYYY-MM-DD"   # UTC date of the backup step (its setup-<date>/backups folder)
BACKUP_FILE="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-${BACKUP_DATE}/backups/policy-$(basename "$POLICY_NAME").json"
[ -s "$BACKUP_FILE" ] || { echo "No backup at ${BACKUP_FILE}: set BACKUP_DATE to the day the backup ran" >&2; exit 1; }
jq '{notificationChannels: (.notificationChannels // [])}' "$BACKUP_FILE" \
  | curl -fsS --max-time 30 -X PATCH -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d @- "${MON_API}/${POLICY_NAME}?updateMask=notificationChannels" >/dev/null
# The API omits an empty channel list, so compare both sides with a missing list read as [].
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${POLICY_NAME}" \
  | jq -e --slurpfile b "$BACKUP_FILE" '(.notificationChannels // []) == ($b[0].notificationChannels // [])'
```

Expected: exit 0, the field equal to the backup. A restore is a change; announce and record it like any other.

## Prove channel delivery

For `GCP-004`. Two levels, recorded separately and never conflated:

1. **Channel verification, where the type supports it.** Some channel types accept a Monitoring-issued verification code (`sendVerificationCode` / `verify` on the channel resource). This posts a visible message to the destination; announce it and get confirmation first. Success flips `verificationStatus` to `VERIFIED`, asserted by the second block below. This proves the channel accepts Monitoring traffic, nothing more.
2. **Observed Monitoring-generated notification.** Only Cloud Monitoring firing a real policy proves the path end to end: use the next natural threshold event or planned maintenance signal, have a human confirm the message arrived, and record the timestamp. Never fabricate load or force an incident to generate one; with no natural event due, `GCP-004` stays `configured` and the wait becomes a pending item with an owner.

- ❌ `Verification code accepted, so GCP-004 is fixed and routing is validated-live.`
- ✅ `verificationStatus VERIFIED recorded; GCP-004 stays configured until a Monitoring-generated notification is seen at the destination, pending item owned by the on-call lead.`

Level 1, each step in its own fresh shell. Send the code, once announced and confirmed:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="<channel-resource-name>"   # the channel to verify, projects/<project>/notificationChannels/<id>
case "$CHANNEL_NAME" in "projects/${GCP_PROJECT}/notificationChannels/"?*) ;; *) echo "Set CHANNEL_NAME to the channel to verify in ${GCP_PROJECT}" >&2; exit 1 ;; esac
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' -d '{}' "${MON_API}/${CHANNEL_NAME}:sendVerificationCode")"
echo "sendVerificationCode: ${code}"
[ "$code" = "200" ] || { echo "expected 200; a 403 means the identity lacks monitoring.editor, any other code is evidence to record" >&2; exit 1; }
```

Then verify with the code the person watching the destination received:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="<channel-resource-name>"        # the same channel
VERIFY_CODE="<code-from-the-destination>"     # typed in by the person who received it; never echoed
case "$CHANNEL_NAME" in "projects/${GCP_PROJECT}/notificationChannels/"?*) ;; *) echo "Set CHANNEL_NAME to the channel to verify in ${GCP_PROJECT}" >&2; exit 1 ;; esac
case "$VERIFY_CODE" in ''|'<'*) echo "Set VERIFY_CODE to the code the destination received" >&2; exit 1 ;; esac
# The verify response is the channel with its label values: discard it and assert on a re-fetch.
jq -n --arg c "$VERIFY_CODE" '{code: $c}' \
  | curl -fsS --max-time 30 -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
      -d @- "${MON_API}/${CHANNEL_NAME}:verify" > /dev/null
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${CHANNEL_NAME}" \
  | jq -e '.verificationStatus == "VERIFIED"'
```

Expected: `sendVerificationCode: 200`, then `true`. Record the result as level 1 only.

## Review snoozes

For `GCP-006`. Ending a snooze early un-mutes alerting; that is a Monitoring-plane write, announced with the snooze body quoted and confirmed individually. Leave deliberate maintenance snoozes alone; the fix for a valid-but-undocumented snooze is a documented expiry and owner in the change record, not a cancellation. To end one, back it up, then cancel it with the GA `gcloud monitoring snoozes cancel`, which moves its end time to one second from now (and its start time too, for a snooze that has not started); check `--help` on your version first:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
SNOOZE_ID="<snooze-id>"   # bare id: the last segment of the snooze name in the audit capture, projects/<project>/snoozes/<id>
case "$SNOOZE_ID" in ''|'<'*|*/*) echo "Set SNOOZE_ID to the bare id of the snooze to end in ${GCP_PROJECT}" >&2; exit 1 ;; esac
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
SNOOZE_BACKUP="${BACKUP_DIR}/snooze-${SNOOZE_ID}.json"
[ ! -e "$SNOOZE_BACKUP" ] || { echo "${SNOOZE_BACKUP} already exists: keep the original backup" >&2; exit 1; }
gcloud monitoring snoozes describe "$SNOOZE_ID" --project "$GCP_PROJECT" --format=json > "$SNOOZE_BACKUP"
[ -s "$SNOOZE_BACKUP" ] || { echo "backup failed; nothing was changed" >&2; exit 1; }
echo "backup: ${SNOOZE_BACKUP}"
gcloud monitoring snoozes cancel "$SNOOZE_ID" --project "$GCP_PROJECT"
sleep 2
gcloud monitoring snoozes describe "$SNOOZE_ID" --project "$GCP_PROJECT" --format=json \
  | jq -e '(.interval.endTime | sub("\\.[0-9]+"; "") | fromdateiso8601) < now'
```

Expected: `backup: <path>`, then `true` (the snooze has ended). The rollback is a new snooze on the backup's `criteria.policies` for the window that remained, announced as its own change.

## Fix uptime coverage

For `GCP-010` to `GCP-016`. Two objects per endpoint, in strict order: the uptime check, then the alert policy on its `check_passed` metric; a check without a policy notifies nobody (`GCP-011`). Before creating any check, prove the exact target answers `200` in this session; a wrong target pages people at 3am:

```bash
set -eu
TARGET_HOST="www.example.com"   # the exact host the check will watch
TARGET_PATH="/healthz"          # the exact path
BODY="$(mktemp)"
code="$(curl -sS -o "$BODY" -w '%{http_code}' --max-time 15 "https://${TARGET_HOST}${TARGET_PATH}")" || code="000"
echo "GET https://${TARGET_HOST}${TARGET_PATH} -> ${code}"
head -c 200 "$BODY"; echo; rm -f "$BODY"
```

Expected: `200` right now. A `401` (auth-only), `3xx` to a login page, `404`, or timeout stops this section: fix the endpoint or pick another path first. Do not create checks for auth-only endpoints unless you deliberately configure expected-status matching, announced as such. Then create and verify (GA gcloud group; check `--help` on your version first):

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
TARGET_HOST="www.example.com"
TARGET_PATH="/healthz"
CHECK_NAME="checkout production uptime"   # name it for the service and environment
UPTIME_PERIOD=1        # example: MINUTES between checks. gcloud --period is an integer count of minutes (default 1), NOT a duration string like "60s", which current gcloud rejects. Tune to your traffic.
UPTIME_TIMEOUT=10      # example: SECONDS to wait for the request. gcloud --timeout is an integer count of seconds (default 60), NOT a duration string like "10s".
CHECK_RES="$(gcloud monitoring uptime create "$CHECK_NAME" --project "$GCP_PROJECT" \
  --resource-type=uptime-url --resource-labels="host=${TARGET_HOST},project_id=${GCP_PROJECT}" \
  --protocol=https --port=443 --path="$TARGET_PATH" --period="$UPTIME_PERIOD" --timeout="$UPTIME_TIMEOUT" \
  --format='value(name)')"
echo "created: ${CHECK_RES}"
gcloud monitoring uptime describe "$CHECK_RES" --project "$GCP_PROJECT" --format=json \
  | jq -e --arg h "$TARGET_HOST" --arg p "$TARGET_PATH" \
      '.monitoredResource.labels.host == $h and .httpCheck.path == $p'
```

Expected: the new check's resource name and exit 0. Its id (the `.name` tail) scopes the alert policy: create the policy via the REST POST in [Add VM pressure policies](#add-vm-pressure-policies), with the condition filter on `monitoring.googleapis.com/uptime_check/check_passed` scoped to `metric.labels.check_id`, a `REDUCE_COUNT_FALSE` aggregation, and your notification channel attached; verify the policy re-fetch shows the channel and the filter. SSL-expiry visibility (`GCP-012`) is one more policy on `uptime_check/time_until_ssl_cert_expires`.

A check created without `--regions` runs from every checker region; for `GCP-014`, widen a check pinned to fewer regions with `gcloud monitoring uptime update` and `--clear-regions` (every region) or `--set-regions`, announced like any update and verified by a describe of its `selectedRegions`. For `GCP-016`, a disabled check that a policy still references is either re-enabled, after a live 200 from its target, or retired with its policy like a dead check; re-enabling (`disabled: false`) and turning failure logging on (`logCheckFailures: true`) are uptime-check PATCHes that name their `updateMask`, backup first. Retiring a dead check (`GCP-015`) deletes a detection path: confirm individually with the audit's DNS and status-code evidence quoted, remove its `check_passed` policy and then the check with the two rollback blocks (names from the audit capture; each block asserts absence), and record where the target lives now. Rollback for creations removes the check's alert policy with the policy rollback block in [Add VM pressure policies](#add-vm-pressure-policies), then the check, each in its own fresh shell:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
CHECK_RES="<uptime-check-resource-name>"   # the "created:" value, projects/<project>/uptimeCheckConfigs/<id>
case "$CHECK_RES" in "projects/${GCP_PROJECT}/uptimeCheckConfigs/"?*) ;; *) echo "Set CHECK_RES to an uptime check in ${GCP_PROJECT}" >&2; exit 1 ;; esac
gcloud monitoring uptime delete "$CHECK_RES" --project "$GCP_PROJECT" --quiet
gcloud monitoring uptime list-configs --project "$GCP_PROJECT" --format=json \
  | jq -e --arg n "$CHECK_RES" 'all(.[]; .name != $n)'
```

Expected: `true`.

## Add VM pressure policies

For `GCP-020`, `GCP-023`, `GCP-024`. Gate first, create second: run the audit's series probe ([audit-gcp references section 7](../audit-gcp/references/gcp-checks.md)) on the exact condition filter you are about to ship; zero series means the policy would be born dead (`GCP-023`), and a `metadata.user_labels` scope that returns nothing means the label shape is wrong (`GCP-024`). Announce the full policy JSON, then:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
CHANNEL_NAME="projects/your-project-id/notificationChannels/987654321"   # from Fix notification channels
case "$CHANNEL_NAME" in "projects/${GCP_PROJECT}/notificationChannels/"?*) ;; *) echo "Set CHANNEL_NAME to a channel in ${GCP_PROJECT}" >&2; exit 1 ;; esac
CPU_WARN_PCT="0.80"     # example warning tier, tune to your baseline. A 0-1 ratio: audit-gcp's starting set says 80 (percent), which this metric never reaches
CPU_WINDOW="300s"       # example
ALIGN_PERIOD="60s"      # example alignment period, tune to the metric's sampling interval
WORK_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/setup-$(date -u +%Y-%m-%d)"
mkdir -p "$WORK_DIR"
jq -n --arg ch "$CHANNEL_NAME" --arg thr "$CPU_WARN_PCT" --arg win "$CPU_WINDOW" --arg align "$ALIGN_PERIOD" '{
  displayName: "production vm cpu WARNING",
  combiner: "OR",
  conditions: [{
    displayName: "cpu utilization above warning tier",
    conditionThreshold: {
      filter: "metric.type = \"compute.googleapis.com/instance/cpu/utilization\" AND resource.type = \"gce_instance\"",
      comparison: "COMPARISON_GT",
      thresholdValue: ($thr | tonumber),
      duration: $win,
      aggregations: [{alignmentPeriod: $align, perSeriesAligner: "ALIGN_MEAN"}]
    }
  }],
  notificationChannels: [$ch],
  documentation: {content: "production gce_instance WARNING cpu above threshold for window | capture CPU chart, load and process state, container or app status, recent deploy, LB 5xx and latency, dependency health", mimeType: "text/markdown"}
}' > "${WORK_DIR}/cpu-warn-policy.json"
# Capture the POST first: a 4xx stops the block here instead of surfacing later as a bad verify URL.
RESP="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d @"${WORK_DIR}/cpu-warn-policy.json" "${MON_API}/projects/${GCP_PROJECT}/alertPolicies")"
NEW_POLICY="$(printf '%s' "$RESP" | jq -r '.name // empty')"
[ -n "$NEW_POLICY" ] || { echo "create returned no policy name; stop and re-fetch before anything else runs" >&2; exit 1; }
echo "created: ${NEW_POLICY}"
curl -fsS --max-time 30 -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_POLICY}" \
  | jq -e '.enabled != false and ((.notificationChannels // []) | length) >= 1'
```

Expected: the new policy's resource name and exit 0. Repeat for the saturation tier (a second policy at `CPU_SAT_PCT`, for example 0.95; both examples, tune per workload) and scope the filter to your serving VMs by label once the label probe passed. This same POST-create-verify shape serves uptime, GKE, LB, and log policies; only the filter, threshold, and documentation change. Rollback removes any policy this setup created, in its own fresh shell:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
MON_API="https://monitoring.googleapis.com/v3"
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN="$TOKEN"; else TOKEN="$(gcloud auth print-access-token)"; fi
NEW_POLICY="<policy-resource-name>"   # the "created:" value, projects/<project>/alertPolicies/<id>
case "$NEW_POLICY" in "projects/${GCP_PROJECT}/alertPolicies/"?*) ;; *) echo "Set NEW_POLICY to a policy this setup created in ${GCP_PROJECT}" >&2; exit 1 ;; esac
curl -fsS --max-time 30 -X DELETE -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_POLICY}" > /dev/null
curl -sS --max-time 30 -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${TOKEN}" "${MON_API}/${NEW_POLICY}"
```

Expected: `404`.

## Gate memory and disk on the Ops Agent

For `GCP-021`, `GCP-022`. Memory and disk policies are created here only for VMs where the agent metrics are proven live this session (the `agent.googleapis.com/agent/uptime` probe in the audit reference, per VM). For proven VMs, create policies on `agent.googleapis.com/memory/percent_used` and `agent.googleapis.com/disk/percent_used` with the create-verify shape above. For unproven VMs, the fix is installing the Ops Agent, and that is a VM-level controlled rollout out of this skill's write scope: record it in [Plan out-of-scope changes](#plan-out-of-scope-changes) with the VM list from the finding and a named owner, and leave `GCP-021` open until the agent metrics exist.

- ❌ `Created memory policies for all six VMs; the agent will be installed next week anyway.`
- ✅ `Created memory and disk policies for the two VMs with live agent metrics; filed the Ops Agent install plan for the other four with the platform owner; GCP-021 stays open for them.`

## Add GKE health policies

For `GCP-031`, `GCP-032`, `GCP-033`. Policies on `kubernetes.io/container/restart_count` (restart spike per workload), pod pending and unschedulable conditions, and node pressure, using the create-verify shape with filters validated by the series probe first; scope filters by `resource.labels.cluster_name` and namespace. If the series probe returns nothing because cluster telemetry components are off (`GCP-030`) or Managed Prometheus is absent where the plan expects it (`GCP-032` when enablement is the fix), the prerequisite is a cluster update: out of write scope, plan it with the cluster owner. Never create a policy whose metric the cluster does not ship yet; that is the false confidence the audit exists to catch.

## Add LB alert policies

For `GCP-017`, `GCP-041`, `GCP-042`. Same create-verify shape: a 5xx-ratio policy on `loadbalancing.googleapis.com/https/request_count` filtered to `response_code_class = 500` against total request rate (starting ratio `LB_5XX_RATIO`, example 0.05), and a latency policy on `loadbalancing.googleapis.com/https/backend_latencies` (starting p95 `LB_LATENCY_MS`, example 1000 ms; both tuned after observing baselines, and a request-anomaly policy only once a baseline exists). Validate each filter against live series first; a forwarding rule with no traffic yields zero series and an honest pause, not a dead policy. Health-check attachment (`GCP-040`) and get-health IAM (`GCP-043`) are LB and IAM changes: plan only. For `GCP-017`, the burn-rate policy rides the SLO itself: the same create-verify shape, with a `select_slo_burn_rate` condition filter naming the exact SLO resource from the audit capture and a burn-rate threshold and lookback tuned to your error budget.

## Create logs-based metrics

For `GCP-050`, `GCP-051`, `GCP-052`. Strict order: prove the filter matches, create the metric, then the policy. The service roster comes from topology.md, one error-count metric per critical service. First the read-only gate: the filter must match something recent before it becomes a metric.

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
LOG_FILTER='resource.type="gce_instance" AND severity>=ERROR AND jsonPayload.service="checkout"'  # tune to your log shape
LOG_FRESHNESS="24h"   # example lookback, tune to how often the service errors
LAST_MATCH="$(gcloud logging read "$LOG_FILTER" --project "$GCP_PROJECT" --limit 1 --freshness="$LOG_FRESHNESS" --format='value(timestamp)')"
[ -n "$LAST_MATCH" ] || { echo "STOP: nothing matched the filter in the last ${LOG_FRESHNESS}; fix the filter, or record in writing that the service logs no errors" >&2; exit 1; }
echo "latest match: ${LAST_MATCH}"
```

Expected: `latest match: <timestamp>`; a stop ends the section. On a service you know errors, a stop means the filter is wrong; shipping it anyway creates the `GCP-051` decoration this section exists to prevent. Then create the metric from the exact filter that matched, announced first, and verify it:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
SERVICE_NAME="checkout"         # canonical name from topology.md
LOG_FILTER='resource.type="gce_instance" AND severity>=ERROR AND jsonPayload.service="checkout"'  # the exact filter the gate matched
METRIC_NAME="${SERVICE_NAME}-error-count"
gcloud logging metrics create "$METRIC_NAME" --project "$GCP_PROJECT" \
  --description="error count for ${SERVICE_NAME}" --log-filter="$LOG_FILTER"
gcloud logging metrics describe "$METRIC_NAME" --project "$GCP_PROJECT" --format=json \
  | jq -e --arg f "$LOG_FILTER" '.filter == $f'
```

Expected: exit 0. Then create the alert policy on `logging.googleapis.com/user/<METRIC_NAME>` with the create-verify shape (`GCP-052`), rate over `LOG_ERROR_RATE_WINDOW` (example 300s, tune per service).

Rollback deletes the metric's alert policy first, with the policy rollback block in [Add VM pressure policies](#add-vm-pressure-policies), then the metric, each in its own fresh shell with the explicit project. The metric half:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
METRIC_NAME="<metric-name>"     # the metric this setup created, <service>-error-count
case "$METRIC_NAME" in ''|'<'*) echo "Set METRIC_NAME to the metric this setup created" >&2; exit 1 ;; esac
gcloud logging metrics delete "$METRIC_NAME" --project "$GCP_PROJECT" --quiet
gcloud logging metrics describe "$METRIC_NAME" --project "$GCP_PROJECT" --format=json 2>&1 | grep -c -i -E 'not.found'
```

Expected: `1` or more (the metric is gone). Sink changes (`GCP-053`) are out of write scope: plan them.

## Improve alert documentation

For `GCP-060`, `GCP-061`, `GCP-062`. PATCH `documentation` (and `userLabels` for severity) with `updateMask`, using the backup-restore pair's mechanics. Confirmed live: the Monitoring API rejects any write where `documentation.content` is non-empty but `documentation.mimeType` is missing (`400 INVALID_ARGUMENT: "non-empty content requires non-empty MIME type and vice versa"`), so always set both together (`text/markdown` is a safe default) whether creating a policy or PATCHing this field on an existing one. Documentation shape, one line then capture list:

`<environment> <resource kind> <resource name> <severity tier> <metric> <threshold/window> | capture <datapoint>, <datapoint>, <datapoint>`

Severity tiers are yours to name (`WARNING`, `SATURATION`, `DOWN` is a working starter set). Datapoints to capture first, per surface; these decide whether the incident is capacity, routing, app, provider, deploy, or a noisy threshold:

| Surface | Capture first |
| --- | --- |
| Uptime | URL, status code, latency, SSL state, DNS resolution, checker region, recent deploy window, backend service, target VM, app logs |
| Compute CPU | CPU chart, load and process state, container or app status, recent deploy, LB 5xx and latency, dependency health |
| Compute memory/disk | memory percent, disk percent, inode and disk growth, process pressure, app logs (only exists after agent proof) |
| GKE | cluster, namespace, workload, pod, node, node pool, restart count, last termination reason, pending and unschedulable pods, pressure, recent rollout |
| Load balancer | host, URL map, backend service, health check, instance group or NEG, backend health, 5xx count, p95 and p99 latency, request volume, deploy window |
| Log alerts | log query, service, environment, VM or cluster, container, request id, trace id, deploy id, error class and message, rate over the window |

For `GCP-062`, retuning a threshold is a PATCH on the condition with the baseline stated in the announcement; removing a duplicate or noisy policy deletes a detection path and is confirmed individually with the policy body quoted.

The noise controls (`GCP-063` to `GCP-066`) are policy PATCHes with the same backup and `updateMask` mechanics. A field named in the mask is replaced whole, so build its new value from the backup, change only what the finding names, and re-fetch to assert the change with `jq -e`:

- `GCP-063`: set each condition's `duration` (a multiple of 60s, at least 120s on an absence condition; example `DURATION_MIN="60s"`, tune it) with `updateMask=conditions`. A `GCP-062` threshold retune uses the same mask, so it too carries every other condition over from the backup.
- `GCP-064`: set `alertStrategy.autoClose` (example `AUTOCLOSE_MAX="86400s"`, tune it) with `updateMask=alertStrategy`.
- `GCP-065`: set `alertStrategy.notificationRateLimit.period` on log-match policies. The API reference says the limit is not implemented for other policies, so a noisy metric policy gets a retest window (`GCP-063`) instead.
- `GCP-066`: keep each `notificationChannelStrategy[].renotifyInterval` between 30 minutes and 24 hours. A `CLOSED` notification prompt is often deliberate; change it only on a policy already flagged noisy.

## Build dashboards

For `GCP-070`, `GCP-071`. Dashboards come last, after routing and policies exist; a dashboard is not an alert and never closes an alerting finding. Author the layout JSON per critical service (uptime, pressure, LB traffic, error-log rate side by side), announce it, then:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
DASH_FILE="<layout-file>"   # the exact path of the layout JSON you announced, for example under gcp/setup-<date>/
[ -s "$DASH_FILE" ] || { echo "Set DASH_FILE to the announced layout file" >&2; exit 1; }
DASH_NAME="checkout service overview"   # displayName inside the file
DASH_RES="$(gcloud monitoring dashboards create --project "$GCP_PROJECT" --config-from-file="$DASH_FILE" --format='value(name)')"
echo "created: ${DASH_RES}"
gcloud monitoring dashboards describe "$DASH_RES" --project "$GCP_PROJECT" --format=json \
  | jq -e --arg dn "$DASH_NAME" '.displayName == $dn'
```

Expected: the new dashboard's resource name and exit 0. Rollback, in its own fresh shell:

```bash
set -eu
GCP_PROJECT="your-project-id"   # gcp.project
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then CLOUDSDK_AUTH_ACCESS_TOKEN="$(gcloud auth application-default print-access-token)"; export CLOUDSDK_AUTH_ACCESS_TOKEN; fi
DASH_RES="<dashboard-resource-name>"   # the "created:" value, projects/<number>/dashboards/<id>
# Dashboard names carry the project NUMBER; gcloud acts on the project in the name, so it must be this one.
GCP_NUM="$(gcloud projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
case "$DASH_RES" in "projects/${GCP_NUM}/dashboards/"?*) ;; *) echo "Set DASH_RES to a dashboard in ${GCP_PROJECT} (projects/${GCP_NUM}/dashboards/<id>)" >&2; exit 1 ;; esac
gcloud monitoring dashboards delete "$DASH_RES" --project "$GCP_PROJECT" --quiet
gcloud monitoring dashboards list --project "$GCP_PROJECT" --format=json \
  | jq -e --arg n "$DASH_RES" 'all(.[]; .name != $n)'
```

Expected: `true`.

## Plan out-of-scope changes

For `GCP-007`, `GCP-008`, `GCP-030`, `GCP-040`, `GCP-043`, `GCP-053`, `GCP-054`, `GCP-067`, and every Ops Agent install from [Gate memory and disk](#gate-memory-and-disk-on-the-ops-agent). No command in this section executes; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, maintenance window if any, and a named owner. GKE telemetry enablement and Ops Agent installs are controlled rollouts on surfaces this skill does not own; backend health checks, get-health IAM grants, sink routing, firewall, DNS, and certificate work can affect traffic or log delivery and deserve their own approval cycle. Recording the plan here keeps the finding traceable without smuggling a cluster change through a "monitoring tweak" approval.

- `GCP-007`: zero policies and zero channels in a readable project usually means the alerting lives in a metrics-scope scoping project or this identity sees only part of the estate; confirm which project owns the alerting and fix the access or `gcp.project` through `/scoutflo:connect`, and never create channels or policies here to fill a gap that may only be invisible.
- `GCP-008`: adding a production project to a metrics scope changes what every policy in the scoping project watches, and its billing and quota surface, so plan it with the scoping project's owner.
- `GCP-054`: log bucket retention is a Cloud Logging storage setting where a longer period costs more and a shorter one drops older logs, so plan the retention your incident reviews need with the log owner.
- `GCP-067`: an MQL condition still evaluates, so this is migration debt, not an outage; plan each rewrite to a PromQL condition with the policy owner, and because the series probe cannot validate PromQL, prove the new query returns the same series before it replaces the old one with a `conditions` PATCH ([Improve alert documentation](#improve-alert-documentation)).

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/gcp/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact command or payload applied; channel label values never included>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (delivery proof waits, Ops Agent installs, cluster and LB plans), and a fresh `/scoutflo:audit-gcp` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Policy created before its channel exists | Order discipline: channels, then policies, then dashboards; a policy with zero channels fails its own verify |
| Local gcloud config "fixed" to reach the project | Never `gcloud config set`; explicit `--project` and the documented auth paths only |
| Gate printed one identity, the writes ran as another | The live-safety gate stops when `GOOGLE_APPLICATION_CREDENTIALS` disagrees with `gcp.credentials_env`, and every change block mints its own key-file token |
| Policy shipped whose filter matches zero series | Run the series probe on the exact filter before every create; zero series stops the announcement |
| Memory or disk policy created ahead of the agent | Per-VM agent proof gates creation; unproven VMs go to the plan section, not the API |
| Uptime check created for an unverified target | Capture a live 200 from the exact host and path immediately before create |
| Logs metric created from an unmatched filter | `gcloud logging read` gate first; empty output stops the section |
| PATCH without updateMask rewrites the whole policy | Every PATCH names its updateMask; the full-object backup is for restore, not for blind re-PUT |
| Channel label values leak into announcements or records | Announce display names and types; sensitive labels ride unechoed variables into payload files that stay local |
| Verification code success closes GCP-004 | Two levels recorded separately; only an observed Monitoring-generated notification closes delivery |
| Batch continues past a failed create | Mid-batch failure rule: stop, re-fetch the failed object, re-announce the remainder |
| Deletion slipped into a batch approval | Channels, policies, checks, and snooze cancellations are deleted only with individual confirmation and the body quoted; for a channel, quote its display name, type and label keys, never label values |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Cluster or VM change smuggled in as monitoring work | Write scope is the Monitoring plane; everything else becomes a plan with a named owner |
