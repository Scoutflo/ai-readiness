---
name: setup-digitalocean
description: Guided hardening of DigitalOcean observability from audit-digitalocean findings; provisions alert destinations, uptime checks, App Platform alert rules and health checks, database alert policies, and log forwarding, announcing each change, waiting for confirmation, then verifying live. Use when the user asks to fix a DO-NNN finding, wire DO alert routing, add uptime checks, or harden App Platform or managed-database alerting. Do not use for read-only assessment (use audit-digitalocean) or for DOKS in-cluster stacks (use setup-lgtm).
disable-model-invocation: true
---

# setup-digitalocean

Fixes findings from an `audit-digitalocean` run. Input is one or more finding IDs from the latest `./scoutflo-audits/digitalocean/[<label>/]<date>/findings.json` (the `<label>/` segment exists only when `digitalocean` is a labeled list of targets); you usually arrive here from a finding's `remediation` pointer, for example `setup-digitalocean#harden-health-checks`.

| Finding ID | Fix section |
| --- | --- |
| DO-001, DO-002, DO-003, DO-005, DO-070, DO-071, DO-073 | [Fix alert routing](#fix-alert-routing) |
| DO-004 | [Prove alert delivery](#prove-alert-delivery) |
| DO-010 to DO-017 | [Fix uptime coverage](#fix-uptime-coverage) |
| DO-020 to DO-026, DORT-001, DORT-002 | [Add App Platform alerts](#add-app-platform-alerts) |
| DO-030, DO-031 | [Harden health checks](#harden-health-checks) |
| DO-032, DO-033, DO-044, DO-045, DO-046 | [Plan traffic-impacting changes](#plan-traffic-impacting-changes) |
| DO-040 to DO-043, DO-048, DO-072 | [Set database alert policies](#set-database-alert-policies) |
| DO-047 | [Configure database logsinks](#configure-database-logsinks) |
| DO-050, DO-051, DO-052 | [Enable app log forwarding](#enable-app-log-forwarding) |
| DO-060, DO-061 | [Retire stale monitoring](#retire-stale-monitoring) |
| DO-062 | [Move secret env vars](#move-secret-env-vars) |
| TOPO-* | `/scoutflo:map-topology` (fill watchpoints, re-run) |

In scope: alert destinations and policy text, uptime checks and their alert rules, App Platform alert rules, health checks, log forwarding, database alert policies and logsinks, and retiring stale monitoring. Out of write scope, always: autoscaling, instance counts, database resize or standby nodes, database firewalls, and DNS or domain changes; those are traffic-impacting and get a written plan with an owner, never an execution here.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the command or spec diff with real values filled in, its risk class, and its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may cover a batch only when every change in the batch was shown first. Silence, an earlier approval, or "fix everything" from three steps ago is not consent. Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one resource at a time. If reality forces a different change, stop and re-announce.
4. **Verify.** Re-fetch the modified object and assert the outcome with `jq -e` or a captured HTTP code. A write is unverified until a read proves it.
5. **Record.** Append the change, its verification evidence, and pending items with named owners to the change record.

## The four change-risk classes

Every announcement names its class; the class decides the ceremony.

| Class | In this skill | Extra gate |
| --- | --- | --- |
| Read-only | snapshots, verification reads | none |
| Non-disruptive write | uptime checks and their alerts, DO Monitoring policy create/update/delete, app alert destination updates, database logsinks | announce and confirm |
| Controlled rollout | any app spec change: alert rules, health checks, log destinations, env types | snapshot first, `propose` validation, one app at a time, staging app before production, `--wait`, endpoint verification |
| Traffic-impacting | autoscaling, instance counts, DB resize or standby, DB firewall, DNS | out of write scope; plan only |

The trap this table exists for: **App Platform spec edits trigger a new deployment.** Adding "just an alert rule" rebuilds and redeploys the app, and a private build failure can take it down. Never bundle a controlled rollout inside a batch approved as "monitoring tweaks".

- ❌ `The user approved "fix the alerting findings", so add health checks to all six apps in one pass.`
- ✅ `Destination updates run as one approved non-disruptive batch; each health check is a controlled rollout announced per app with its spec diff, staging first.`

## Doctor gate

Elevated tier: this skill mutates DO monitoring, uptime, app, and database state. A failed check stops the skill with the exact failure and the fix, usually `/scoutflo:connect`.

| Integration | Config keys | Env var | Minimum scope | Tier |
| --- | --- | --- | --- | --- |
| DigitalOcean | `digitalocean.token_env`, `digitalocean.team` (required here; per target on a labeled list) | the variable `token_env` names (default `DIGITALOCEAN_ACCESS_TOKEN`); doctl itself reads `DIGITALOCEAN_ACCESS_TOKEN` | custom-scoped token with create/update/delete on monitoring, uptime, and apps, plus databases when logsinks are in scope; full-access only when custom scopes are unavailable | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
for bin in doctl curl jq; do
  command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }
done
# Load the secret store the way /scoutflo:doctor does; it only sets *_env variables and prints nothing.
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
# Resolve THIS target: a single digitalocean block, or the SCOUTFLO_TARGET item of a labeled list.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DO_KIND=$(sh "$TT" "$CFG" digitalocean kind); DO_N=$(sh "$TT" "$CFG" digitalocean count)
[ "${DO_N:-0}" -ge 1 ] || { echo "no digitalocean block in $CFG; run /scoutflo:connect"; exit 1; }
DO_IDX=0
if [ "$DO_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$DO_N" -gt 1 ]; }; then
  DO_IDX=""; _i=0
  while [ "$_i" -lt "$DO_N" ]; do [ "$(sh "$TT" "$CFG" digitalocean label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { DO_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$DO_IDX" ] || { echo "set SCOUTFLO_TARGET to the digitalocean label you intend to change; labels: $(sh "$TT" "$CFG" digitalocean labels | tr '\n' ' ')"; exit 1; }
fi
DO_LABEL=$(sh "$TT" "$CFG" digitalocean label "$DO_IDX")
# digitalocean.token_env names THIS target's token variable; presence check only, never print the value.
DO_TOKEN_VAR=$(sh "$TT" "$CFG" digitalocean get "$DO_IDX" token_env); [ -n "$DO_TOKEN_VAR" ] || DO_TOKEN_VAR="DIGITALOCEAN_ACCESS_TOKEN"
export DIGITALOCEAN_ACCESS_TOKEN="$(printenv "$DO_TOKEN_VAR" 2>/dev/null || true)"
[ -n "$DIGITALOCEAN_ACCESS_TOKEN" ] || { echo "${DO_TOKEN_VAR} is not set; add it to ~/.scoutflo/env or run /scoutflo:connect"; exit 1; }
# With -o json, doctl prints an error as JSON on stdout and exits 1, so capture before parsing.
ACCOUNT_JSON="$(doctl account get -o json)" || { echo "doctl account get failed for target ${DO_LABEL}: ${ACCOUNT_JSON}; a 401 means the token is wrong or revoked; run /scoutflo:connect"; exit 1; }
printf '%s' "$ACCOUNT_JSON" | jq -e '(if type=="array" then .[0] else . end) | .status == "active"' >/dev/null \
  || { echo "account status for target ${DO_LABEL} is not active; run /scoutflo:connect"; exit 1; }
echo "doctor gate: pass (target ${DO_LABEL})"
```

Expected: `doctor gate: pass`. The DO API cannot introspect token scopes, so the first write of the run is the scope test: if it returns `403`, stop, report which scope is missing, and point at `/scoutflo:connect`. Do not keep trying other writes to find one that works.

## Live-safety gate

Resolve the target team from `toolkit.yaml` itself, not from a value typed into the block, then compare it against the team `doctl` is actually authenticated against. The comparison value has to come from the config file or the gate can pass on whatever the operator happened to type. Every later block runs doctl on the `DIGITALOCEAN_ACCESS_TOKEN` already in its environment, so the gate also proves that token is the one `toolkit.yaml` names for this target:

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
# Resolve THIS target through the shared enumerator: a single digitalocean block, or the SCOUTFLO_TARGET item of a labeled list.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DO_KIND=$(sh "$TT" "$CFG" digitalocean kind); DO_N=$(sh "$TT" "$CFG" digitalocean count)
[ "${DO_N:-0}" -ge 1 ] || { echo "no digitalocean block in $CFG; run /scoutflo:connect"; exit 1; }
DO_IDX=0
if [ "$DO_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$DO_N" -gt 1 ]; }; then
  DO_IDX=""; _i=0
  while [ "$_i" -lt "$DO_N" ]; do [ "$(sh "$TT" "$CFG" digitalocean label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { DO_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$DO_IDX" ] || { echo "STOP: set SCOUTFLO_TARGET to the digitalocean label you intend to change; labels: $(sh "$TT" "$CFG" digitalocean labels | tr '\n' ' ')"; exit 1; }
fi
DO_LABEL=$(sh "$TT" "$CFG" digitalocean label "$DO_IDX")
# The comparison value is THIS target's digitalocean.team. This skill writes, so the key is required, never assumed.
DO_TEAM=$(sh "$TT" "$CFG" digitalocean get "$DO_IDX" team)
[ -n "$DO_TEAM" ] || { echo "STOP: target ${DO_LABEL} has no digitalocean.team in ${CFG}; add the team UUID you intend to change (personal for an account with no team)"; exit 1; }
# The token later blocks use is the one in this environment now, captured before the secret store loads.
LATER_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:-}"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
DO_TOKEN_VAR=$(sh "$TT" "$CFG" digitalocean get "$DO_IDX" token_env); [ -n "$DO_TOKEN_VAR" ] || DO_TOKEN_VAR="DIGITALOCEAN_ACCESS_TOKEN"
TARGET_TOKEN="$(printenv "$DO_TOKEN_VAR" 2>/dev/null || true)"
# Compared, never printed.
[ -n "$TARGET_TOKEN" ] && [ "$LATER_TOKEN" = "$TARGET_TOKEN" ] || { echo "STOP: every later block runs doctl on the DIGITALOCEAN_ACCESS_TOKEN in this environment, and it is unset or not the ${DO_TOKEN_VAR} value toolkit.yaml names for target ${DO_LABEL}. Make them the same where your commands run (load ~/.scoutflo/env from your shell profile, per /scoutflo:connect), then re-run this gate."; exit 1; }
export DIGITALOCEAN_ACCESS_TOKEN="$TARGET_TOKEN"
# Capture first: with -o json a failed call prints its error on stdout, which would otherwise read as team "personal".
ACCOUNT_JSON="$(doctl account get -o json)" || { echo "STOP: doctl account get failed: ${ACCOUNT_JSON}"; exit 1; }
LIVE_TEAM="$(printf '%s' "$ACCOUNT_JSON" | jq -r '(if type=="array" then .[0] else . end) | .team.uuid // "personal"')"
echo "config target ${DO_LABEL} (digitalocean.team): ${DO_TEAM}"
echo "live team (doctl account get): ${LIVE_TEAM}"
[ "$LIVE_TEAM" = "$DO_TEAM" ] || { echo "STOP: doctl is authenticated to team ${LIVE_TEAM}, but toolkit.yaml names ${DO_TEAM} for target ${DO_LABEL}. Fix ${DO_TOKEN_VAR} or digitalocean.team before continuing."; exit 1; }
echo "live-safety gate passed: doctl matches the team toolkit.yaml names for target ${DO_LABEL}"
```

Expected: the final line prints and nothing stops the block. `DO_TEAM` and the token are re-read from `toolkit.yaml` and the secret store in this same block every time, never carried over from a prior block or from what an operator remembers typing, so the gate cannot pass on the wrong target by construction. A token doctl found any other way (its own `doctl auth` context, a stale export) fails the token comparison. If the two teams differ, stop and report the mismatch; never proceed on "probably the right account". Later blocks do not re-resolve the target: re-run this gate whenever the token, `SCOUTFLO_TARGET` or `toolkit.yaml` changes, and before any rollback in a later session. Rollback blocks repeat the team check against the team this gate printed. Every app and database in this skill is addressed by ID captured from the audit run, never by name matching at execution time.

## Load findings and build the change plan

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
# Resolve THIS target's audit folder the way audit-digitalocean writes it: digitalocean/<date>/ for a single block, digitalocean/<label>/<date>/ for a labeled list.
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
DO_KIND=$(sh "$TT" "$CFG" digitalocean kind); DO_N=$(sh "$TT" "$CFG" digitalocean count)
DO_IDX=0
if [ "$DO_KIND" = seq ] && { [ -n "${SCOUTFLO_TARGET:-}" ] || [ "$DO_N" -gt 1 ]; }; then
  DO_IDX=""; _i=0
  while [ "$_i" -lt "$DO_N" ]; do [ "$(sh "$TT" "$CFG" digitalocean label "$_i")" = "${SCOUTFLO_TARGET:-}" ] && { DO_IDX=$_i; break; }; _i=$((_i+1)); done
  [ -n "$DO_IDX" ] || { echo "set SCOUTFLO_TARGET to the digitalocean label you intend to change; labels: $(sh "$TT" "$CFG" digitalocean labels | tr '\n' ' ')"; exit 1; }
fi
DO_LABEL=$(sh "$TT" "$CFG" digitalocean label "$DO_IDX")
if [ "$DO_KIND" = seq ]; then DO_SEG="digitalocean/${DO_LABEL}"; else DO_SEG="digitalocean"; fi
# Only date-named run folders hold an audit's findings.json; setup-<date>/, <label>/ and runs/ folders are skipped.
LATEST="$(find "${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/${DO_SEG}" -mindepth 2 -maxdepth 2 -type f \
  -path '*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/findings.json' 2>/dev/null | sort | tail -1)"
[ -n "$LATEST" ] || { echo "no audit run found for target ${DO_LABEL}; run /scoutflo:audit-digitalocean first"; exit 1; }
echo "findings: ${LATEST}"
jq -r '.findings[] | [.id, .severity, .title, .remediation] | @tsv' "$LATEST"
```

Expected: the `findings:` path of the newest audit run for this target, then one line per finding. This block creates nothing: only a backup block creates the setup folder, so loading findings or declining the plan leaves none behind.

Take the finding IDs you were asked to fix; if asked for "everything critical and high", enumerate those IDs explicitly so the plan names each one. Announce the full plan as one table and wait for approval:

| # | Finding | Object | Risk class | Exact change | Rollback |
| --- | --- | --- | --- | --- | --- |

Approval may cover the whole table because every row was shown, except that each controlled-rollout row is re-confirmed at its own announcement. If only some rows are approved, only those execute. A decline ends the run with zero changes. Order safety first: routing fixes before delivery proof, non-disruptive rows before controlled rollouts, deletions last and confirmed individually.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the batch immediately: no change N+1 runs. Verify the failed object's current state, report what happened, and re-announce the remainder only after the user decides. For a failed app deployment, first confirm the previous deployment is still active and serving (commands in [Add App Platform alerts](#add-app-platform-alerts)) before touching anything else.

**Backups are GET-before-write.** Before any write that changes or removes an existing object, that section's backup block captures the object's current state under `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-<date>/backups/` and prints the exact path: the app spec, the policy JSON, the app alert destinations, the uptime check with its alerts. Only these blocks create the setup folder, and every later block takes the printed path as an explicit input, never a path rebuilt from today's date. Backups contain env values, channel names and webhook URLs; `./scoutflo-audits/` stays out of version control. Rollback is re-applying the backup; every section names its restore command. A create has no prior state: its rollback deletes the id the create printed.

## Fix alert routing

For `DO-001`, `DO-002`, `DO-003`, `DO-005`, `DO-070`, `DO-071`, `DO-073`. Non-disruptive writes: destination, description, window and enabled changes redeploy nothing.

Slack incoming webhooks are channel-bound: the webhook posts to the channel it was installed in, and a payload `channel` field does not re-route it. Fixing wrong-channel routing means installing or obtaining a webhook for the correct channel, then pointing the policy at it. Keep the toolkit's own brief webhook (`slack.webhook_env`) out of DO destinations; they are different webhooks with different jobs.

DO Monitoring policies (databases and other DO Monitoring surfaces). `doctl monitoring alert update` replaces the whole policy: `--enabled` defaults to true, `--window` to `5m`, and any tag, Slack destination or email left off the command is dropped. So the change is built from a backup of the live policy, and the update sends every field from that file. First back up the policy and build the changed copy; this block only reads the policy and writes local files:

```bash
set -eu
POLICY_UUID="your-policy-uuid"   # from the audit's alert-policies capture
# The announced change. Leave a value empty to keep what the policy has now.
NEW_EMAILS=""         # the full recipient list, comma-joined with no spaces, e.g. "oncall@example.org"
NEW_DESCRIPTION=""    # DO-005: responder-ready text in the shape below
NEW_WINDOW=""         # DO-070: 10m, 30m or 1h
NEW_ENABLED=""        # DO-071: true re-enables a disabled policy
SLACK_CHANNEL=""      # one Slack channel to route to; it replaces the policy's Slack destinations
SLACK_URL_ENV="DO_ALERT_SLACK_WEBHOOK"   # names the variable holding that channel's webhook URL; never echoed
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
POLICY_BACKUP="${BACKUP_DIR}/policy-${POLICY_UUID}-$(date -u +%H%M%S).json"
NEW_POLICY="${POLICY_BACKUP%.json}-new.json"
# With -o json a failed call prints its error on stdout and exits 1: capture, then keep only this policy.
OUT="$(doctl monitoring alert get "$POLICY_UUID" -o json)" || { echo "cannot read policy ${POLICY_UUID}: ${OUT}" >&2; exit 1; }
printf '%s' "$OUT" | jq -e --arg u "$POLICY_UUID" '(if type=="array" then .[0] else . end) | select(.uuid == $u)' > "$POLICY_BACKUP"
SLACK_URL=""
if [ -n "$SLACK_CHANNEL" ]; then
  SLACK_URL="$(printenv "$SLACK_URL_ENV" 2>/dev/null || true)"
  [ -n "$SLACK_URL" ] || { echo "${SLACK_URL_ENV} is not set; add the webhook to your secret store" >&2; exit 1; }
fi
jq --arg e "$NEW_EMAILS" --arg d "$NEW_DESCRIPTION" --arg w "$NEW_WINDOW" --arg on "$NEW_ENABLED" \
   --arg ch "$SLACK_CHANNEL" --arg url "$SLACK_URL" '
    (if $e != "" then .alerts.email = ($e | split(",")) else . end)
  | (if $d != "" then .description = $d else . end)
  | (if $w != "" then .window = $w else . end)
  | (if $on != "" then .enabled = ($on == "true") else . end)
  | (if $ch != "" then .alerts.slack = [{channel: $ch, url: $url}] else . end)' "$POLICY_BACKUP" > "$NEW_POLICY"
echo "backup: ${POLICY_BACKUP}"
echo "new:    ${NEW_POLICY}"
# Announce this diff: every field the update will send, without webhook URLs.
OLD_VIEW="$(mktemp)"; NEW_VIEW="$(mktemp)"
jq 'del(.alerts.slack[]?.url)' "$POLICY_BACKUP" > "$OLD_VIEW"
jq 'del(.alerts.slack[]?.url)' "$NEW_POLICY" > "$NEW_VIEW"
diff -u "$OLD_VIEW" "$NEW_VIEW" || true
rm -f "$OLD_VIEW" "$NEW_VIEW"
```

Expected: the `backup:` and `new:` paths, then a diff that touches only the announced fields. Announce that diff with the Slack channel by name; the webhook URL never appears. After confirmation, apply the file. The same block is the restore:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"   # digitalocean.team: the team the live-safety gate printed, or "personal"
POLICY_FILE="<policy-json>"   # the "new:" path to apply the change, or the "backup:" path to restore it
ACTION="update"               # update applies the file to its policy; create re-creates a deleted policy from its backup
for v in "$EXPECTED_TEAM" "$POLICY_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$POLICY_FILE" ] || { echo "No policy file at ${POLICY_FILE}" >&2; exit 1; }
LIVE_TEAM="$(doctl account get -o json | jq -r '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
# Every field comes from the file, so nothing falls back to a doctl default.
get() { jq -r "$1" "$POLICY_FILE"; }
POLICY_UUID="$(get .uuid)"
set -- --type "$(get .type)" --compare "$(get .compare)" --value "$(get .value)" --window "$(get .window)" \
  --description "$(get .description)" --enabled="$(get .enabled)"
V="$(get '(.entities // []) | join(",")')"; [ -z "$V" ] || set -- "$@" --entities "$V"
V="$(get '(.tags // []) | join(",")')"; [ -z "$V" ] || set -- "$@" --tags "$V"
V="$(get '(.alerts.email // []) | join(",")')"; [ -z "$V" ] || set -- "$@" --emails "$V"
V="$(get '[.alerts.slack[]?.channel] | join(",")')"
[ -z "$V" ] || set -- "$@" --slack-channels "$V" --slack-urls "$(get '[.alerts.slack[]?.url] | join(",")')"
case "$ACTION" in
  update) doctl monitoring alert update "$POLICY_UUID" "$@" > /dev/null ;;
  create) OUT="$(doctl monitoring alert create "$@" -o json)" || { echo "policy not created: ${OUT}" >&2; exit 1; }
          POLICY_UUID="$(printf '%s' "$OUT" | jq -r '(if type=="array" then .[0] else . end).uuid')"
          case "$POLICY_UUID" in ''|null) echo "policy not created; stop" >&2; exit 1 ;; esac
          echo "created: ${POLICY_UUID}" ;;
  *) echo "ACTION must be update or create" >&2; exit 1 ;;
esac
# Field-for-field check against the file; prints only true or false, never a webhook URL.
doctl monitoring alert get "$POLICY_UUID" -o json | jq -e --slurpfile want "$POLICY_FILE" '
  def norm: (if type=="array" then .[0] else . end) | {type, compare, value, window, description, enabled,
    entities: ((.entities // []) | sort), tags: ((.tags // []) | sort),
    email: ((.alerts.email // []) | sort), slack: ((.alerts.slack // []) | sort_by(.channel))};
  norm == ($want[0] | norm)'
```

Expected: `true`. Rollback: run the same block with `POLICY_FILE` set to the `backup:` path; it re-sends every backed-up field and the check proves the policy matches the backup. doctl refuses a policy with no email or Slack destination, so the backup of a policy that had none restores only from the control panel. doctl flag names shift across versions: for every write in this skill, check the subcommand's `--help` before announcing, and if your version differs from what is written here, stop and re-announce with the corrected flags.

`DO-070`: a longer `window` is the only flap damper DO offers, and it delays the page by the same amount, so announce the delay you accept. `DO-071`: re-enable with `NEW_ENABLED="true"` only after the policy's owner confirms the mute is over; a policy nobody needs is deleted with the `DO-043` procedure in [Set database alert policies](#set-database-alert-policies) instead. `DO-073`: give the deviant policy the same destinations as its siblings.

App Platform alert destinations use the destination-only command, which avoids a spec rollout. Back up the alert's current destinations and build the new file; this block only reads the alerts and writes local files:

```bash
set -eu
APP_ID="your-app-id"; ALERT_ID="your-app-alert-id"   # from the audit's per-app alerts capture
NEW_EMAILS=""         # the full recipient list, comma-joined with no spaces; empty keeps the alert's emails
SLACK_CHANNEL=""      # one Slack channel to route to; it replaces the alert's Slack webhooks
SLACK_URL_ENV="DO_ALERT_SLACK_WEBHOOK"   # names the variable holding that channel's webhook URL; never echoed
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
DEST_BACKUP="${BACKUP_DIR}/dest-${ALERT_ID}-$(date -u +%H%M%S).json"
DEST_NEW="${DEST_BACKUP%.json}-new.json"
OUT="$(doctl apps list-alerts "$APP_ID" -o json)" || { echo "cannot read the alerts of app ${APP_ID}: ${OUT}" >&2; exit 1; }
printf '%s' "$OUT" | jq -e --arg a "$ALERT_ID" \
  '.[] | select(.id == $a) | {emails: (.emails // []), slack_webhooks: (.slack_webhooks // [])}' > "$DEST_BACKUP" \
  || { echo "alert ${ALERT_ID} not found on app ${APP_ID}" >&2; exit 1; }
SLACK_URL=""
if [ -n "$SLACK_CHANNEL" ]; then
  SLACK_URL="$(printenv "$SLACK_URL_ENV" 2>/dev/null || true)"
  [ -n "$SLACK_URL" ] || { echo "${SLACK_URL_ENV} is not set; add the webhook to your secret store" >&2; exit 1; }
fi
jq --arg e "$NEW_EMAILS" --arg ch "$SLACK_CHANNEL" --arg url "$SLACK_URL" '
    (if $e != "" then .emails = ($e | split(",")) else . end)
  | (if $ch != "" then .slack_webhooks = [{channel: $ch, url: $url}] else . end)' "$DEST_BACKUP" > "$DEST_NEW"
echo "backup: ${DEST_BACKUP}"
echo "new:    ${DEST_NEW}"
# Announce these two lines, before and after; webhook URLs are left out.
jq -c '{emails, slack_channels: [.slack_webhooks[]?.channel]}' "$DEST_BACKUP" "$DEST_NEW"
```

After confirmation, apply the file. The same block is the restore:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"       # digitalocean.team: the team the live-safety gate printed, or "personal"
APP_ID="<app-id>"                 # the app that owns the alert
ALERT_ID="<app-alert-id>"         # the alert whose destinations change
DEST_FILE="<destinations-json>"   # the "new:" path to apply the change, or the "backup:" path to restore it
for v in "$EXPECTED_TEAM" "$APP_ID" "$ALERT_ID" "$DEST_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$DEST_FILE" ] || { echo "No destinations file at ${DEST_FILE}" >&2; exit 1; }
LIVE_TEAM="$(doctl account get -o json | jq -r '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
# The command's own output can list webhook URLs, so it is discarded.
doctl apps update-alert-destinations "$APP_ID" "$ALERT_ID" --app-alert-destinations "$DEST_FILE" > /dev/null
# The alert's destinations must now equal the file; prints only true or false.
doctl apps list-alerts "$APP_ID" -o json | jq -e --arg a "$ALERT_ID" --slurpfile want "$DEST_FILE" '
  def norm: {emails: ((.emails // []) | sort), slack: ((.slack_webhooks // []) | sort_by(.channel))};
  (.[] | select(.id == $a) | norm) == ($want[0] | norm)'
```

Expected: `true`. Rollback: run the same block with `DEST_FILE` set to the `backup:` path.

For `DO-005`, set descriptions to the responder-ready shape: environment, resource, severity tier, metric, threshold and window, then the datapoints to capture first, so the responder can decide between capacity, query pressure, provider incident, and noisy threshold. Per-engine starting rosters (examples, tune per workload):

| Engine | Datapoints to capture first |
| --- | --- |
| PostgreSQL / MySQL | connections, slow queries, locks, replication lag, disk growth rate |
| Redis / Valkey | ops per second, evictions, blocked clients, memory versus maxmemory, failover state |
| MongoDB | slow queries, connections, lock and current-op state, cache pressure, replication state |
| Kafka | consumer lag, under-replicated partitions, broker disk, request latency |
| OpenSearch | cluster status, JVM heap, indexing and search latency, shard health |

App Platform alert rules take no custom text; keep their capture checklist (CPU and memory charts, instance count, restarts, deployment ID and recent deploy status, request and error rate, p95 latency, dependency health) in your runbook instead of forcing a spec rollout to add text.

## Prove alert delivery

For `DO-004`. Two levels, recorded separately and never conflated:

1. **Webhook smoke test.** Posts a visible message to the channel; announce it and get confirmation first. The URL comes from the secret-store variable the destination was configured from and is never echoed:

```bash
set -eu
WEBHOOK_ENV="DO_ALERT_SLACK_WEBHOOK"   # names the variable holding the destination's webhook URL
WEBHOOK_URL="$(printenv "$WEBHOOK_ENV" 2>/dev/null || true)"
[ -n "$WEBHOOK_URL" ] || { echo "${WEBHOOK_ENV} is not set; add the webhook to your secret store" >&2; exit 1; }
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
  --data '{"text":"Controlled routing test from setup-digitalocean. Safe to ignore."}' "$WEBHOOK_URL")" || code="000"
echo "smoke: ${code}"
```

Expected `smoke: 200`. This proves the webhook accepts a message in its bound channel, nothing more.

2. **DO-generated event.** Only DigitalOcean firing a real alert proves the path: use the next planned deployment's lifecycle alert or a real threshold event, have a human confirm the message arrived in the channel, and record the timestamp. Never fabricate an incident to force one; with no natural event due, `DO-004` stays `configured` and the wait becomes a pending item with an owner.

- ❌ `Smoke test returned 200, so DO-004 is fixed and routing is validated-live.`
- ✅ `Smoke 200 recorded; DO-004 stays configured until the next DO-generated alert is seen in-channel, pending item owned by the on-call lead.`

## Fix uptime coverage

For `DO-010` to `DO-017`. Non-disruptive, but a check against a wrong target pages people at 3am; verify the exact target immediately before creating anything:

```bash
set -eu
TARGET_URL="https://www.example.com/"   # the exact URL the check will watch
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$TARGET_URL")" || code="000"
echo "GET ${TARGET_URL} -> ${code}"
```

Expected: `200` right now. Anything else stops this section: fix the target or the app first, or settle ownership with the audit's DNS evidence (a dead or moved target, `DO-015` included, goes to [Retire stale monitoring](#retire-stale-monitoring)). `DO-017` is the one exception: its target is failing by definition, so instead of the `200`, quote the audit's evidence that the hostname still points at your DO app, and say in the announcement that the down alert will fire as soon as the check runs. Then create the check, or reuse the existing one, and verify:

```bash
set -eu
CHECK_ID=""                                # DO-011 to DO-013: the existing check's id from the audit; empty creates a new check
CHECK_NAME="checkout-prod"                 # name it for the service and environment
TARGET_URL="https://www.example.com/"
REGIONS="us_east,eu_west"                  # example, tune to where your users are
ALERT_EMAIL="oncall@example.org"           # an address on your DigitalOcean account that your team actually watches
UPTIME_DOWN_WINDOW="2m"                    # example, tune to your traffic
SSL_EXPIRY_DAYS="21"                       # example
UPTIME_LATENCY_MS="1000"                   # example, set from observed latency
UPTIME_LATENCY_WINDOW="10m"                # example, tune to your traffic
# With -o json a failed doctl call prints its error on stdout and exits 1, so capture before parsing.
if [ -z "$CHECK_ID" ]; then
  # Take the id from the create itself: a lookup by target can return an older check for the same URL.
  OUT="$(doctl monitoring uptime create "$CHECK_NAME" --target "$TARGET_URL" --type https --regions "$REGIONS" -o json)" \
    || { echo "check not created: ${OUT}" >&2; exit 1; }
  CHECK_ID="$(printf '%s' "$OUT" | jq -r '(if type=="array" then .[0] else . end).id')"
  case "$CHECK_ID" in ''|null) echo "check not created; stop" >&2; exit 1 ;; esac
  echo "created: ${CHECK_ID}"
fi
# Add only the rule types the check lacks, and print each new rule's id for the rollback.
OUT="$(doctl monitoring uptime alert list "$CHECK_ID" -o json)" || { echo "cannot list rules on ${CHECK_ID}: ${OUT}" >&2; exit 1; }
TYPES=" $(printf '%s' "$OUT" | jq -r '[.[].type] | join(" ")') "
has() { case "$TYPES" in *" $1 "*) return 0 ;; esac; return 1; }
add() {
  OUT="$(doctl monitoring uptime alert create "$CHECK_ID" "$@" -o json)" || { echo "rule not created: ${OUT}" >&2; exit 1; }
  NEW_ALERT="$(printf '%s' "$OUT" | jq -r '(if type=="array" then .[0] else . end).id')"
  case "$NEW_ALERT" in ''|null) echo "rule not created; stop" >&2; exit 1 ;; esac
  echo "added alert: ${NEW_ALERT}"
}
# doctl 1.155.0 requires --comparison on every rule type, down included.
has down || has down_global || add --name "${CHECK_NAME}-down" --type down --comparison greater_than \
  --period "$UPTIME_DOWN_WINDOW" --emails "$ALERT_EMAIL"
has ssl_expiry || add --name "${CHECK_NAME}-ssl" --type ssl_expiry \
  --threshold "$SSL_EXPIRY_DAYS" --comparison less_than --period "$UPTIME_DOWN_WINDOW" --emails "$ALERT_EMAIL"
has latency || add --name "${CHECK_NAME}-latency" --type latency \
  --threshold "$UPTIME_LATENCY_MS" --comparison greater_than --period "$UPTIME_LATENCY_WINDOW" --emails "$ALERT_EMAIL"
doctl monitoring uptime alert list "$CHECK_ID" -o json \
  | jq -e '[.[].type] | (index("down") != null or index("down_global") != null) and (index("ssl_expiry") != null) and (index("latency") != null)'
```

Expected: final `jq -e` exits 0 printing `true`. An empty `CHECK_ID` creates a new check (`DO-010`, `DO-017`) and prints `created:`; an existing check's id (`DO-011` to `DO-013`) gets only the rule types it lacks, so it never gains a duplicate check or rule. Every new rule prints `added alert:`. Uptime alert emails must be addresses associated with your DigitalOcean account, per doctl's own help, so a team alias such as an on-call list will not work there: use a team member's address, or Slack, which adds `--slack-channels` plus `--slack-urls` with the URL held in an unechoed variable. `DO-014` is the `REGIONS` choice at create time; widening an existing check means `doctl monitoring uptime update`, which rewrites name, target, type and regions together, so record it as a plan item with an owner. For `DO-016`, a live certificate already inside the expiry window, the `ssl_expiry` rule makes the next expiry page; renewing this certificate (usually a domain validation that broke when DNS moved) is outside this skill's writes and goes to [Plan traffic-impacting changes](#plan-traffic-impacting-changes) with an owner.

Rollback for a check this setup created (it printed `created:`), in its own fresh shell. Unlike `doctl monitoring alert delete`, `doctl monitoring uptime delete` has no `-f`/`--force` flag at all (confirmed live: passing `-f` fails with "unknown shorthand flag") and needs none, since it deletes immediately with no confirmation prompt:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"    # digitalocean.team: the team the live-safety gate printed, or "personal"
CHECK_ID="<uptime-check-id>"   # the "created:" value from the create block
for v in "$EXPECTED_TEAM" "$CHECK_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
ACCT="$(doctl account get -o json)"   # a failed call stops here: doctl prints its error JSON on stdout and exits 1
LIVE_TEAM="$(printf '%s' "$ACCT" | jq -er '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
doctl monitoring uptime delete "$CHECK_ID"
doctl monitoring uptime list -o json | jq -e --arg id "$CHECK_ID" 'all(.[]?; .id != $id)'
```

Expected: `true`. A token for another team stops the block before the delete.

On a check that existed before this setup, roll back only the rules the setup added, never the check itself:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"    # digitalocean.team: the team the live-safety gate printed, or "personal"
CHECK_ID="<uptime-check-id>"   # the existing check the rules were added to
ALERT_IDS="<alert-ids>"        # the "added alert:" values from the create block, comma-joined
for v in "$EXPECTED_TEAM" "$CHECK_ID" "$ALERT_IDS"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
LIVE_TEAM="$(doctl account get -o json | jq -r '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
for a in $(printf '%s' "$ALERT_IDS" | tr ',' ' '); do doctl monitoring uptime alert delete "$CHECK_ID" "$a"; done
doctl monitoring uptime alert list "$CHECK_ID" -o json \
  | jq -e --arg ids "$ALERT_IDS" '($ids | split(",")) as $gone | all(.[]?; .id as $i | all($gone[]; . != $i))'
```

Expected: `true`, with the check and its other rules still in place.

## Add App Platform alerts

For `DO-020` to `DO-026`. Controlled rollout: this edits the app spec and triggers a deployment. One app at a time, staging app before production when one exists, and each app is its own announcement. For `DO-026`, the rule to add is the one the PP sibling already enforces, copied into the prod app's spec. `DORT-001` and `DORT-002` (a deployment failed or wedged right now) get the `DEPLOYMENT_FAILED` rule so the next failure pages a human; the broken deployment itself belongs to the app owner, and no spec rollout goes on top of a failed or still-running deployment, so record the rule as pending with that owner until the app is healthy again.

1. **Snapshot (GET-before-write), run as written:**

```bash
set -eu
APP_ID="your-app-id"   # from the audit inventory
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/app-${APP_ID}-$(date -u +%H%M%S).yaml"
doctl apps spec get "$APP_ID" > "$BACKUP_FILE"
test -s "$BACKUP_FILE" || { echo "empty snapshot; stop" >&2; exit 1; }
echo "snapshot:  ${BACKUP_FILE}"
echo "edit copy: ${BACKUP_FILE%.yaml}-new.yaml"
```

The spec contains env values (SECRET-type values appear encrypted and round-trip safely on restore). The backup stays local and out of version control.

2. **Edit a copy.** Copy the snapshot to the `edit copy:` path step 1 printed (`NEW_SPEC` in steps 3 to 5) and add the alert rules: lifecycle rules (`DEPLOYMENT_FAILED`, `DEPLOYMENT_LIVE`, `DOMAIN_FAILED`, `DOMAIN_LIVE`) under top-level `alerts`, resource rules (`CPU_UTILIZATION`, `MEM_UTILIZATION`, `RESTART_COUNT`) under each service's `alerts` with `operator`, `value`, and `window` from the starting set in [audit-digitalocean references section 12](../audit-digitalocean/references/do-checks.md) (examples, tune per workload). Request-rate and p95 rules only when a recorded baseline sets the threshold.

3. **Validate enums before trusting them.** Documented rule names and API-accepted names have diverged; `propose` is the arbiter:

```bash
set -eu
APP_ID="your-app-id"
NEW_SPEC="<new-spec-path>"   # the "edit copy:" path step 1 printed
case "$NEW_SPEC" in ''|'<'*) echo "Set NEW_SPEC to the edit copy from step 2" >&2; exit 1 ;; esac
[ -s "$NEW_SPEC" ] || { echo "No spec at ${NEW_SPEC}" >&2; exit 1; }
doctl apps propose --spec "$NEW_SPEC" --app "$APP_ID" >/dev/null && echo "spec accepted"
```

Expected: `spec accepted`. A rejection names the invalid field or enum; when one rule name is rejected and another spelling is accepted, record both in the change record so future automation uses the accepted one. `propose` validates only; it deploys nothing.

4. **Announce** this diff, the risk class (controlled rollout, will redeploy), and the rollback. Its context lines can show env values, and a log destination carries its credential: mask any such value before you announce it.

```bash
set -eu
BACKUP_FILE="<snapshot-path>"   # the "snapshot:" path step 1 printed
NEW_SPEC="<new-spec-path>"      # the "edit copy:" path step 1 printed
for v in "$BACKUP_FILE" "$NEW_SPEC"; do
  case "$v" in ''|'<'*) echo "Fill in both paths from step 1 first" >&2; exit 1 ;; esac
  [ -s "$v" ] || { echo "No file at ${v}" >&2; exit 1; }
done
diff -u "$BACKUP_FILE" "$NEW_SPEC" || true   # diff exits 1 when the files differ, which is the point
```

Wait for confirmation on this app specifically.

5. **Execute and verify, run as written:**

```bash
set -eu
APP_ID="your-app-id"
NEW_SPEC="<new-spec-path>"              # the "edit copy:" path step 1 printed
PUBLIC_URL="https://www.example.com/"   # the app's live URL from the audit inventory
case "$NEW_SPEC" in ''|'<'*) echo "Set NEW_SPEC to the edit copy from step 2" >&2; exit 1 ;; esac
[ -s "$NEW_SPEC" ] || { echo "No spec at ${NEW_SPEC}" >&2; exit 1; }
PREV_DEPLOY="$(doctl apps get "$APP_ID" -o json | jq -r '(if type=="array" then .[0] else . end).active_deployment.id')"
echo "previous deployment: ${PREV_DEPLOY}"
doctl apps update "$APP_ID" --spec "$NEW_SPEC" --wait
doctl apps get "$APP_ID" -o json | jq -e --arg prev "$PREV_DEPLOY" \
  '(if type=="array" then .[0] else . end).active_deployment | (.id != $prev) and (.phase == "ACTIVE")'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_URL")" || code="000"
echo "post-deploy: ${code}"
```

Expected: `true` and `post-deploy: 200`. If `update --wait` fails or the phase is not `ACTIVE`: stop the batch (mid-batch failure rule), collect the failure from `doctl apps list-deployments "$APP_ID"`, and confirm the previous deployment still serves before anything else runs:

```bash
set -eu
APP_ID="<app-id>"                 # the app the failed update targeted
PREV_DEPLOY="<deployment-id>"     # the "previous deployment:" id the execute block printed
PUBLIC_URL="https://www.example.com/"   # the app's live URL
for v in "$APP_ID" "$PREV_DEPLOY"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
doctl apps get "$APP_ID" -o json | jq -e --arg prev "$PREV_DEPLOY" \
  '(if type=="array" then .[0] else . end).active_deployment | (.id == $prev) and (.phase == "ACTIVE")'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_URL")" || code="000"
echo "still serving: ${code}"
```

Expected: `true` and `still serving: 200`. Then re-announce. Once the deploy succeeds, verify the change itself. For alert rules, every rule the announced diff added must be live and enabled; `list-alerts` nests each rule under `.spec`:

```bash
set -eu
APP_ID="your-app-id"
ANNOUNCED_RULES="DEPLOYMENT_FAILED,DEPLOYMENT_LIVE,DOMAIN_FAILED,DOMAIN_LIVE,CPU_UTILIZATION,MEM_UTILIZATION,RESTART_COUNT"   # every rule the announced diff adds
doctl apps list-alerts "$APP_ID" -o json | jq -e --arg r "$ANNOUNCED_RULES" '
  [.[] | select(.spec.disabled | not) | .spec.rule] as $live
  | all($r | split(",")[]; . as $want | any($live[]; . == $want))'
```

Expected: `true`. Health checks, log destinations and env types verify their own field instead; each of those sections shows its check.

6. **Rollback, the worked pair for every spec change in this skill:**

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"     # digitalocean.team: the team the live-safety gate printed, or "personal"
APP_ID="<app-id>"               # the app this setup changed
BACKUP_FILE="<snapshot-path>"   # the "snapshot:" path step 1 printed
PUBLIC_URL="https://www.example.com/"   # the app's live URL
for v in "$EXPECTED_TEAM" "$APP_ID" "$BACKUP_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BACKUP_FILE" ] || { echo "No snapshot at ${BACKUP_FILE}" >&2; exit 1; }
ACCT="$(doctl account get -o json)"   # a failed call stops here: doctl prints its error JSON on stdout and exits 1
LIVE_TEAM="$(printf '%s' "$ACCT" | jq -er '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
PREV_DEPLOY="$(doctl apps get "$APP_ID" -o json | jq -r '(if type=="array" then .[0] else . end).active_deployment.id')"
echo "previous deployment: ${PREV_DEPLOY}"
doctl apps update "$APP_ID" --spec "$BACKUP_FILE" --wait
# A new active deployment proves the restore deployed; ACTIVE alone is also true of the old one.
doctl apps get "$APP_ID" -o json | jq -e --arg prev "$PREV_DEPLOY" \
  '(if type=="array" then .[0] else . end).active_deployment | (.id != $prev) and (.phase == "ACTIVE")'
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$PUBLIC_URL")"; echo "post-rollback: ${code}"
```

Expected: `true` and `post-rollback: 200`. A rollback is itself a deployment; it needs the same announcement it just proved the need for.

## Harden health checks

For `DO-030`, `DO-031`. Controlled rollout, same six steps as [Add App Platform alerts](#add-app-platform-alerts); the delta is the payload and one extra gate: verify the exact path live before it enters the spec. A wrong health check marks a healthy app unhealthy and can restart it in a loop.

```bash
set -eu
PUBLIC_URL="https://www.example.com"   # the app's live URL
HEALTH_PATH="/healthz"                 # the candidate path; must need no auth, Origin, or session
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${PUBLIC_URL}${HEALTH_PATH}")" || code="000"
echo "GET ${PUBLIC_URL}${HEALTH_PATH} -> ${code}"
```

Expected: `200` from a plain unauthenticated GET. A `3xx` to a login page, `401`, `403`, or `404` disqualifies the path; fix the app or pick another path first. Then add to the service in the spec copy, with starting values (examples, tune per service): `http_path` set to the verified path, `initial_delay_seconds: 30`, `period_seconds: 10`, `timeout_seconds: 5`, `failure_threshold: 3`. For `DO-030` (a `health_check` with no `liveness_health_check`), also add a `liveness_health_check` stanza on a path that does not call downstream services, verified live the same way. Continue from step 3 of the previous section. After step 5's deployment check, verify the field itself:

```bash
set -eu
APP_ID="your-app-id"
SERVICE_NAME="checkout-api"   # the service the health check was added to
HEALTH_PATH="/healthz"        # the path verified live above
LIVENESS_PATH=""              # DO-030 only: the liveness path you added, or empty when you added none
doctl apps spec get "$APP_ID" --format json \
  | jq -e --arg s "$SERVICE_NAME" --arg p "$HEALTH_PATH" --arg l "$LIVENESS_PATH" \
      'any(.services[]?; .name == $s and .health_check.http_path == $p and ($l == "" or .liveness_health_check.http_path == $l))'
```

Expected: `true`.

## Set database alert policies

For `DO-040` to `DO-043`, `DO-048` and `DO-072`. Non-disruptive: DO Monitoring policies live outside the cluster config. Take accepted `type` strings from the audit's policy capture or `doctl monitoring alert list` output rather than memory, and validate on create.

```bash
set -eu
DB_UUID="your-database-uuid"        # doctl databases list
# Copy the exact .type from the audit's alert-policies capture or doctl monitoring alert list; one metric per run.
POLICY_TYPE="v1/dbaas/alerts/cpu_alerts"   # spellings seen live: cpu_alerts, memory_utilization_alerts, disk_utilization_alerts
DB_WARN_PCT="80"                    # example warning tier, tune per engine and workload
DB_WINDOW="5m"                      # example
ALERT_EMAIL="oncall@example.org"    # the recipient your team actually watches
DESCRIPTION="PROD db-main WARNING cpu >${DB_WARN_PCT}% for ${DB_WINDOW} | capture CPU chart, connections, slow queries"   # DO-005 shape
# With -o json a rejected create prints its error (a wrong type string, for one) on stdout and exits 1.
OUT="$(doctl monitoring alert create \
  --type "$POLICY_TYPE" \
  --compare GreaterThan --value "$DB_WARN_PCT" --window "$DB_WINDOW" \
  --entities "$DB_UUID" \
  --description "$DESCRIPTION" \
  --emails "$ALERT_EMAIL" -o json)" || { echo "policy not created: ${OUT}" >&2; exit 1; }
NEW_UUID="$(printf '%s' "$OUT" | jq -r '(if type=="array" then .[0] else . end).uuid')"
case "$NEW_UUID" in ''|null) echo "policy not created; stop" >&2; exit 1 ;; esac
echo "created: ${NEW_UUID}"
doctl monitoring alert get "$NEW_UUID" -o json | jq -e --arg e "$DB_UUID" --arg t "$POLICY_TYPE" \
  '(if type=="array" then .[0] else . end) | (.entities | index($e)) and .enabled and .type == $t'
```

Expected: exit 0. If the `type` string is rejected, list existing policies for the accepted spelling on your account, record the doc-versus-API mismatch, and re-announce; the exact enum set varies by engine. Repeat per metric and tier by changing `POLICY_TYPE`, the threshold and `DESCRIPTION`, never the command body: warning at `DB_WARN_PCT` and saturation at a higher tier (99 is a common example) for CPU, memory, and disk.

Rollback, in its own fresh shell (one policy per run):

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"      # digitalocean.team: the team the live-safety gate printed, or "personal"
NEW_UUID="<alert-policy-uuid>"   # the "created:" value from the create block
for v in "$EXPECTED_TEAM" "$NEW_UUID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
ACCT="$(doctl account get -o json)"   # a failed call stops here: doctl prints its error JSON on stdout and exits 1
LIVE_TEAM="$(printf '%s' "$ACCT" | jq -er '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
doctl monitoring alert delete "$NEW_UUID" -f
doctl monitoring alert list -o json | jq -e --arg u "$NEW_UUID" 'all(.[]?; .uuid != $u)'
```

Expected: `true`.

For `DO-043`, removing a noisy or duplicate policy deletes a detection path: confirm each deletion individually with the policy body quoted, never inside a batch approval. Keep the named tiers, back up and delete the generic duplicate, and verify:

```bash
set -eu
DUP_UUID="the-duplicate-policy-uuid"   # the one policy the user confirmed for deletion
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
POLICY_BACKUP="${BACKUP_DIR}/policy-${DUP_UUID}-$(date -u +%H%M%S).json"
# No verified backup, no delete: a failed -o json call prints its error on stdout, so capture and check the uuid.
OUT="$(doctl monitoring alert get "$DUP_UUID" -o json)" || { echo "cannot back up ${DUP_UUID}, nothing deleted: ${OUT}" >&2; exit 1; }
printf '%s' "$OUT" | jq -e --arg u "$DUP_UUID" '(if type=="array" then .[0] else . end) | select(.uuid == $u)' > "$POLICY_BACKUP"
echo "backup: ${POLICY_BACKUP}"
doctl monitoring alert delete "$DUP_UUID" -f
doctl monitoring alert list -o json | jq -e --arg u "$DUP_UUID" '[.[] | select(.uuid == $u)] | length == 0'
```

Expected: the `backup:` path, then `true`. To restore a deleted policy, run the policy apply block in [Fix alert routing](#fix-alert-routing) with `ACTION="create"` and `POLICY_FILE` set to that backup; it comes back with every backed-up field and a new UUID.

- ❌ `Deleted three "is running high" policies under the batch approval for routing fixes.`
- ✅ `Announced each duplicate with its metric, threshold, and the named tier that supersedes it; the user confirmed each; deletion verified by absence in the re-fetched list.`

For `DO-072`, collapsing near-identical single-entity policies into one tag-scoped policy changes what the policy covers: every resource that carries the tag, including resources added later. Record the consolidation as a plan item with an owner; this skill does not run it.

For `DO-048`, where the engine exposes no native policy for a signal (connection saturation, replication lag, slow queries), record the gap and its compensating control in the change record with an owner instead of inventing a policy the surface cannot support.

## Configure database logsinks

For `DO-047`. Non-disruptive write, but decision-gated: name the backend, retention, redaction, index naming, and owner in the announcement, or record `DO-047` as blocked on that decision instead of shipping logs somewhere unowned. Database logsinks support a different destination list from app log forwarding (historically rsyslog, Elasticsearch, OpenSearch); verify the accepted types against current DO docs at run time.

doctl has no `databases logsink` command (on 1.155.0 it prints the `databases` help and exits 0, so it fails silently), so this uses the API's singular `/logsink` route directly, the same route the audit reads:

```bash
set -eu
DB_UUID="your-database-uuid"   # doctl databases list
SINK_NAME="db-main-logs"
SINK_TYPE="opensearch"         # opensearch or elasticsearch here; rsyslog takes server/port/tls/format instead of url
INDEX_PREFIX="db-main"
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set" >&2; exit 1; }
# LOGSINK_URL embeds the backend credential: export it from your secret store, never echo it.
[ -n "${LOGSINK_URL:-}" ] || { echo "LOGSINK_URL is not set" >&2; exit 1; }
API="https://api.digitalocean.com/v2/databases/${DB_UUID}/logsink"
SINK_ID="$(jq -n --arg n "$SINK_NAME" --arg t "$SINK_TYPE" --arg u "$LOGSINK_URL" --arg p "$INDEX_PREFIX" \
    '{sink_name: $n, sink_type: $t, config: {url: $u, index_prefix: $p}}' \
  | curl -fsS --max-time 30 -X POST -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" \
      -H 'Content-Type: application/json' -d @- "$API" \
  | jq -r '.sink.sink_id')"
echo "created: ${SINK_ID}"
# The list returns each sink's config, credential included: assert on the id only, print nothing else.
curl -fsS --max-time 30 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "$API" \
  | jq -e --arg id "$SINK_ID" 'any(.sinks[]?; .sink_id == $id)'
```

Expected: the new sink id, then `true`. The sink config carries credentials on some backends; keep them in an unechoed variable and out of every announcement and record.

Rollback, in its own fresh shell:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"    # digitalocean.team: the team the live-safety gate printed, or "personal"
DB_UUID="<database-uuid>"      # the cluster the sink was added to
SINK_ID="<sink-id>"            # the "created:" value from the create block
for v in "$EXPECTED_TEAM" "$DB_UUID" "$SINK_ID"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -n "${DIGITALOCEAN_ACCESS_TOKEN:-}" ] || { echo "DIGITALOCEAN_ACCESS_TOKEN is not set" >&2; exit 1; }
ACCT="$(doctl account get -o json)"   # a failed call stops here: doctl prints its error JSON on stdout and exits 1
LIVE_TEAM="$(printf '%s' "$ACCT" | jq -er '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
API="https://api.digitalocean.com/v2/databases/${DB_UUID}/logsink"
curl -fsS --max-time 30 -X DELETE -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "${API}/${SINK_ID}" > /dev/null
curl -fsS --max-time 30 -H "Authorization: Bearer ${DIGITALOCEAN_ACCESS_TOKEN}" "$API" \
  | jq -e --arg id "$SINK_ID" 'all(.sinks[]?; .sink_id != $id)'
```

Expected: `true`.

## Enable app log forwarding

For `DO-050` to `DO-052`. Controlled rollout: `log_destinations` live in the app spec, so this follows the six steps of [Add App Platform alerts](#add-app-platform-alerts) with two additions. First, the same backend decision gate as logsinks: backend, retention, redaction, naming, owner, announced before the diff. Second, credential handling: app log destinations embed their credential (an API key or token) in the spec itself, which means it lands in snapshots and in DO's stored spec. Say so in the announcement, source the value from an unechoed variable when building the spec copy, and never print the rendered destination block. App destinations and database logsinks accept different backends (`DO-052`); do not promise one universal path until both lists are verified against current docs. Verify after rollout: step 5's deployment check, then the spec field below, then log lines arriving in the destination backend within one flush interval. That arrival is a human-inspection check, because no block here can read your backend: search it for a log line from this app newer than the deployment, and record the query and the line's timestamp in the change record. Until then the destination stays `configured`.

```bash
set -eu
APP_ID="your-app-id"
COMPONENT="checkout-api"       # the service, worker or job that forwards logs
LOG_DEST_NAME="central-logs"   # the log_destinations[].name the announced diff added
# Asserts on names only; the destination block holds a credential and is never printed.
doctl apps spec get "$APP_ID" --format json | jq -e --arg c "$COMPONENT" --arg d "$LOG_DEST_NAME" '
  any(((.services // []) + (.workers // []) + (.jobs // []))[]; .name == $c and any(.log_destinations[]?; .name == $d))'
```

Expected: `true`.

## Retire stale monitoring

For `DO-060`, `DO-061`. Deleting a check or policy removes a detection path even when the target is a ghost; confirm each deletion individually with the audit evidence quoted (the DNS answer and status code that proved the move). Back up and delete one uptime check per run; its alert rules go with it. `doctl monitoring uptime delete` has no `-f` flag (confirmed live) and needs none, since it deletes immediately:

```bash
set -eu
CHECK_ID="the-stale-check-id"   # from the audit's DO-060 or DO-061 evidence, quoted in the announcement
BACKUP_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/setup-$(date -u +%Y-%m-%d)/backups"
mkdir -p "$BACKUP_DIR"
CHECK_BACKUP="${BACKUP_DIR}/uptime-${CHECK_ID}-$(date -u +%H%M%S).json"
# No verified backup, no delete. A failed -o json call prints its error on stdout, so capture each read.
CHECK_JSON="$(doctl monitoring uptime get "$CHECK_ID" -o json)" || { echo "cannot back up ${CHECK_ID}, nothing deleted: ${CHECK_JSON}" >&2; exit 1; }
RULES_JSON="$(doctl monitoring uptime alert list "$CHECK_ID" -o json)" || { echo "cannot back up its rules, nothing deleted: ${RULES_JSON}" >&2; exit 1; }
# The check and its rules in one file; the rules carry webhook URLs, so the file stays local.
printf '%s\n%s\n' "$CHECK_JSON" "$RULES_JSON" \
  | jq -s '{check: (.[0] | if type=="array" then .[0] else . end), alerts: .[1]}' > "$CHECK_BACKUP"
jq -e --arg id "$CHECK_ID" '.check.id == $id and (.alerts | type == "array")' "$CHECK_BACKUP" > /dev/null
echo "backup: ${CHECK_BACKUP}"
doctl monitoring uptime delete "$CHECK_ID"
doctl monitoring uptime list -o json | jq -e --arg id "$CHECK_ID" 'all(.[]?; .id != $id)'
```

Expected: the `backup:` path, then `true`. Delete any DO Monitoring policy scoped only to the retired resource with the `DO-043` block in [Set database alert policies](#set-database-alert-policies), which backs the policy up first and accepts `-f`; its restore is the policy apply block with `ACTION="create"`.

Restore a retired check, in its own fresh shell; it comes back with a new id:

```bash
set -eu
EXPECTED_TEAM="<team-uuid>"    # digitalocean.team: the team the live-safety gate printed, or "personal"
CHECK_BACKUP="<backup-path>"   # the "backup:" path the retire block printed
for v in "$EXPECTED_TEAM" "$CHECK_BACKUP"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$CHECK_BACKUP" ] || { echo "No backup at ${CHECK_BACKUP}" >&2; exit 1; }
LIVE_TEAM="$(doctl account get -o json | jq -r '(if type=="array" then .[0] else . end) | select(.status) | .team.uuid // "personal"')"
[ "$LIVE_TEAM" = "$EXPECTED_TEAM" ] || { echo "This token is for team ${LIVE_TEAM}, not ${EXPECTED_TEAM}; stopping" >&2; exit 1; }
get() { jq -r "$1" "$CHECK_BACKUP"; }
OUT="$(doctl monitoring uptime create "$(get .check.name)" --target "$(get .check.target)" --type "$(get .check.type)" \
  --regions "$(get '.check.regions | join(",")')" --enabled="$(get .check.enabled)" -o json)" \
  || { echo "check not re-created: ${OUT}" >&2; exit 1; }
NEW_ID="$(printf '%s' "$OUT" | jq -r '(if type=="array" then .[0] else . end).id')"
case "$NEW_ID" in ''|null) echo "check not re-created; stop" >&2; exit 1 ;; esac
echo "restored as: ${NEW_ID}"
# Re-create each backed-up rule with every field it had; doctl requires a comparison even on a down rule.
rule() { jq -r --argjson i "$i" ".alerts[\$i] | $1" "$CHECK_BACKUP"; }
i=0; N="$(get '.alerts | length')"
while [ "$i" -lt "$N" ]; do
  set -- --name "$(rule .name)" --type "$(rule .type)" --period "$(rule .period)" --threshold "$(rule '.threshold // 0')" \
    --comparison "$(rule '(.comparison // "") | if . == "" then "greater_than" else . end')"
  V="$(rule '(.notifications.email // []) | join(",")')"; [ -z "$V" ] || set -- "$@" --emails "$V"
  V="$(rule '[.notifications.slack[]?.channel] | join(",")')"
  [ -z "$V" ] || set -- "$@" --slack-channels "$V" --slack-urls "$(rule '[.notifications.slack[]?.url] | join(",")')"
  doctl monitoring uptime alert create "$NEW_ID" "$@" > /dev/null
  i=$((i + 1))
done
doctl monitoring uptime alert list "$NEW_ID" -o json \
  | jq -e --slurpfile b "$CHECK_BACKUP" '([.[].type] | sort) == ([$b[0].alerts[].type] | sort)'
```

Expected: `restored as:` with the new id, then `true`. Record where the service actually lives now and who owns its monitoring there; retiring the DO side without naming the new owner trades noise for blindness.

## Move secret env vars

For `DO-062`. Controlled rollout: changing an env var's `type` from `GENERAL` to `SECRET` is a spec edit. Follow the six steps of [Add App Platform alerts](#add-app-platform-alerts); in the spec copy, set `type: SECRET` on each affected key, leaving the value untouched. After the rollout, DO stores the value encrypted and the spec shows it as an encrypted blob. Verify that every flagged key now reports `SECRET`; the check reads key names and types only:

```bash
set -eu
APP_ID="your-app-id"
COMPONENT="checkout-api"               # the service, worker or job that holds the keys
SECRET_KEYS="DATABASE_URL,API_TOKEN"   # the key names the audit flagged, comma-joined
doctl apps spec get "$APP_ID" --format json | jq -e --arg c "$COMPONENT" --arg k "$SECRET_KEYS" '
  [((.services // []) + (.workers // []) + (.jobs // []))[] | select(.name == $c) | .envs[]?] as $envs
  | all($k | split(",")[]; . as $key | any($envs[]; .key == $key and .type == "SECRET"))'
```

Expected: `true`. Rotate any value that sat in plaintext if your policy treats exposure time as compromise; record the rotation as a pending item with an owner, since rotation touches the consuming app's configuration too.

## Plan traffic-impacting changes

For `DO-032`, `DO-033`, `DO-044`, `DO-045`, `DO-046`. No command in this section executes; the deliverable is a written plan in the change record, per item: current state (from audit evidence), proposed target, blast radius, rollback, baseline needed (for autoscaling: observed CPU, request, and latency baselines first), maintenance window, and a named owner. Instance counts, standby nodes, resizes, firewall edits, and DNS moves can drop traffic or sever connectivity; they deserve their own change plan and their own approval cycle outside this skill. Backup gaps (`DO-044`) that doctl shows as empty on a backup-capable engine go to the plan with a support-escalation owner.

## Record and wrap up

Append one entry per executed change to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/digitalocean/changes.md`:

```markdown
## <UTC timestamp> | <finding IDs>
- Change: <object and what changed, with risk class>
- Command: <exact command or spec diff applied>
- Verified: <the read-back command and the value it showed>
- Rollback: <command or backup path>
- Pending: <item> (owner: <team or person>)
```

End the run with a summary table (finding ID, change, verification result, remaining risk), the pending list with named owners (delivery proof waits, traffic-impacting plans, rotations), and a fresh `/scoutflo:audit-digitalocean` run to re-score; its delta shows which findings moved to fixed.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| "Just an alert rule" redeploys the app | Classify every change first; any spec field edit is a controlled rollout with snapshot, propose, and per-app confirmation |
| Spec updated from a doc-remembered enum, API rejects mid-rollout | `doctl apps propose` validates before announce; record accepted spellings when they differ from docs |
| Batch continues past a failed deploy | Mid-batch failure rule: stop, confirm the prior deployment still serves, re-announce the remainder |
| Webhook smoke test recorded as delivery proof | Two levels, recorded separately; only an observed DO-generated event closes DO-004 |
| Slack payload channel override trusted | Webhooks are channel-bound; fix routing by installing a webhook in the right channel |
| Uptime check created for an unverified target | Capture a live 200 from the exact target immediately before create |
| Health check added to a path needing auth or Origin | Probe the path with a plain unauthenticated GET first; anything but 200 disqualifies it |
| Policy update silently drops fields | `monitoring alert update` replaces the policy and defaults `--enabled` to true; build the change from a backup of the live policy, send every field from that file, and check each one after |
| Findings lookup lands on a `setup-<date>/` or `<label>/` folder | Read only date-named run folders under this target's segment, and create the setup folder only from a backup block |
| Gate checks one token while later blocks run on another | The gate proves the `DIGITALOCEAN_ACCESS_TOKEN` later blocks use equals this target's `token_env` value before it compares teams |
| Verify reads a field the command never returns, or a count that passed before the change | Assert the shape the command emits (`.spec.rule` and `.spec.disabled` for app alerts) and every announced value |
| Duplicate policy deleted inside a batch | Deletions are confirmed individually with the policy body quoted |
| Secrets leak via spec snapshots or sink configs | Backups stay out of version control; credentials live in unechoed variables; announcements show channel names and key names only |
| Declined plan partially applied | Declining means zero changes; execution starts only after explicit approval of shown rows |
| Rollback treated as free | A spec rollback is itself a deployment; announce and verify it like any other change |
