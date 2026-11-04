---
name: setup-splunk-oncall
description: Plan Splunk On-Call (formerly VictorOps) configuration and execute a guarded description-only team update or restore. Use when you say "set up Splunk On-Call", "fix VictorOps routing", "configure On-Call escalation", or "update the team description". Teams, schedules, policies, routing and ingestion currently produce plans only; their execution and rollback remain pending. For "audit VictorOps" or a read-only health check, use audit-splunk-oncall; for credentials, use connect. Do not use for Splunk log search, Observability Cloud, incident handling or account administration.
disable-model-invocation: true
---

# setup-splunk-oncall

Plan a paging path you can explain and verify: the incoming source selects a routing key, the key selects one or more escalation policies, and each policy reaches the intended team and an eligible responder. Start from `/scoutflo:audit-splunk-oncall` findings or your explicit new-configuration goal. Keep the team, schedule, policy, routing and source work in one change plan, ordered by dependencies. **This version executes only the description-only team update/restore recipe. Every other configuration section is planning-only: do not submit provider UI changes or generate API writes from it. Exact execution, verification and rollback for those capabilities remain pending.**

Splunk On-Call still uses VictorOps domains for its API. It is distinct from Splunk Enterprise, Cloud Platform and Observability Cloud. This skill does not configure those products. The management API is fixed at `https://api.victorops.com`; the incoming-alert service is a separate credential surface. Never substitute an incoming integration key for a management API key.

## Supported execution and proof boundaries

| Configuration | Current execution path | What has been observed and what remains unproven |
| --- | --- | --- |
| Existing non-default team's description | Guarded API plan, update, readback and restore in the [team recipe](references/team-description.md) | Description-only update and restoration were observed on a populated team. Rename, absent-description restoration and new response fields are not supported by this recipe. |
| Teams, standard or partial rotations, escalation policies | Planning only; no API or UI mutation | Populated UI-created objects and their joins were observed. Exact setup execution, requested-field verification and rollback remain verify-pending. |
| Non-default routing key creation | Planning only; no API or UI mutation | Single-policy and two-policy creation/readback were observed, but delete/restore was not. Execution and rollback remain verify-pending; creation-only evidence does not enable this capability. |
| Existing route mapping repair or rename | Diagnose and prepare a plan only; refuse API and UI mutation | The read can omit `isMultiResponder`. Omission is not false. This version cannot promise to preserve that mode in an API replacement. |
| Incoming alert source | Prepare a provider/source change plan only | An observed incoming event and incident lifecycle establish those observations only. Configuration readback does not establish continuous forwarding or a human receiving a notification. |
| Personal paging, contacts, overrides, maintenance, transformations | Discover dependencies and prepare a scoped plan | Automated mutation and rollback remain verify-pending. Follow the sections below; do not emit speculative write recipes. |

There is no object-count cap. Choose the smallest change set that fixes the stated failure, then expand it when another required behavior needs a distinct object. API breadth is not a reason to create configuration. A pending execution path must leave a useful, specific plan and its missing proof; it must not report the integration configured. A new user approval does not make an unimplemented verification or rollback procedure available.

## The change protocol

For the supported description action, and as the design requirements for every planned future action:

1. **Read and bind.** Resolve one configured target and its expected team identity. Read the complete object and relevant dependencies. Missing, denied, partial, malformed or ambiguous state stops that action; it is not an empty configuration.
2. **Announce.** Show the exact target, object identities, permitted before/after fields, which people or sources could be affected, preservation assertions, and undo or retention procedure. Represent routing keys and credentials by secret-store variable names. For a batch, show every member first.
3. **Confirm.** Obtain explicit approval for that concrete action or batch. Existing approval for the same fully specified action remains valid; a changed target, new recipient, altered payload or larger impact needs a revised confirmation. Do not treat silence as approval.
4. **Re-read.** Compare current state to the approved before-state. If it changed, do not overwrite it. Explain the difference and revise the plan. No documented conditional-write facility is assumed: an owner must keep the object stable between this last read and the write.
5. **Execute once.** Apply only the approved mutation. After timeout, connection loss or an ambiguous response, read to reconcile; never blindly repeat a create or replacement. Record applied, unapplied and unknown actions separately.
6. **Verify immediately.** The next provider operation is a fresh read of the changed object. Assert the requested effect and unchanged dependencies. A successful status is not a verified change. On failure, stop later rows and record applied, unknown and unapplied actions separately. Re-announce any changed remaining plan and obtain its confirmation before resuming.
7. **Record and re-audit.** Retain safe before/after evidence and verification, including remaining delivery or rollback limitations. Run the audit with its read-only key after the change. Do not hand-edit `findings.json` or the reports to turn a finding green.

Backups contain permitted configuration, not raw HTTP bodies. Routing key, ingestion URL, contact address, phone, device token and annotation values may be secret-bearing. Keep the required secret in the existing protected secret store and put only its variable name in the plan. If an exact restorable before-state cannot be captured safely, report rollback unavailable before approval. Do not delete objects as an improvised undo.

## Doctor gate

| Input | Requirement |
| --- | --- |
| `splunk_oncall.api_id_env` | Name of the management API ID variable |
| `splunk_oncall.api_key_env` | Name of the read-only management key variable; never replaced by the elevated key |
| `splunk_oncall.team_slug` | Exact known team identity in the intended organization, obtained from a trusted provider UI or prior verified setup |
| `splunk_oncall.setup_api_key_env` | Separate elevated key variable, required for API setup and optional for read-only audits |
| Tools | `sh`, `curl` 8.4 or newer, `jq`, `shasum` for private plan credential binding, `python3` for exclusive local journal creation; no cloud CLI is needed for this provider |

Resolve `SCOUTFLO_CONFIG` first, then project-local config, the home active-config pointer, then the home default. Use the normal secret-store precedence: `SCOUTFLO_ENV_FILE`, project-local `.scoutflo/env`, then `~/.scoutflo/env`. Read only the selected variables from the store. Do not accept a key pasted into chat or write a second credential file.

The following block is read-only and self-contained. A labeled list requires `SCOUTFLO_TARGET`; an unknown or duplicate label stops. Two successful reads of the expected team bind the selected key pair to that known resource. They do not discover a globally unique organization identity or prove write permission. Never probe write permission by performing a dummy mutation.

<!-- oncall-setup-doctor:start -->
```bash
set -eu
set +x
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for candidate in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null 2>&1 || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$candidate" ] && { CFG="$candidate"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'Missing config; run /scoutflo:connect'; exit 1; }
for bin in curl jq shasum python3; do command -v "$bin" >/dev/null 2>&1 || { echo "Missing $bin"; exit 1; }; done
SOC_CURL_VERSION=$(curl --version | awk 'NR==1 {print $2}')
printf '%s\n' "$SOC_CURL_VERSION" | awk -F. '$1>8 || ($1==8 && $2>=4) {ok=1} END {exit !ok}' || { echo 'curl 8.4 or newer is required for bounded reads'; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SOC_KIND=$(sh "$TT" "$CFG" splunk_oncall kind)
SOC_N=$(sh "$TT" "$CFG" splunk_oncall count)
[ "$SOC_N" -ge 1 ] || { echo 'No splunk_oncall target'; exit 1; }
SOC_IDX=0
if [ "$SOC_KIND" = seq ]; then
  SOC_LABELS=$(sh "$TT" "$CFG" splunk_oncall labels)
  SOC_LI=0
  while [ "$SOC_LI" -lt "$SOC_N" ]; do
    case "$(sh "$TT" "$CFG" splunk_oncall get "$SOC_LI" label)" in ''|*[!A-Za-z0-9_-]*) echo 'List targets require explicit safe labels'; exit 1;; esac
    SOC_LI=$((SOC_LI+1))
  done
  printf '%s\n' "$SOC_LABELS" | awk '$0 !~ /^[A-Za-z0-9_-]+$/ || seen[$0]++ {bad=1} END {exit bad}' || { echo 'Invalid or duplicate target labels'; exit 1; }
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select SCOUTFLO_TARGET for setup'; exit 1; }
  SOC_MATCHES=0; SOC_I=0
  while [ "$SOC_I" -lt "$SOC_N" ]; do
    if [ "$(sh "$TT" "$CFG" splunk_oncall label "$SOC_I")" = "$SCOUTFLO_TARGET" ]; then SOC_IDX=$SOC_I; SOC_MATCHES=$((SOC_MATCHES+1)); fi
    SOC_I=$((SOC_I+1))
  done
  [ "$SOC_MATCHES" -eq 1 ] || { echo 'SCOUTFLO_TARGET must match exactly one splunk_oncall label'; exit 1; }
fi
SOC_TEAM=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" team_slug)
case "$SOC_TEAM" in ''|*[!A-Za-z0-9_-]*) echo 'Invalid team_slug'; exit 1;; esac
SOC_ID_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_id_env)
SOC_READ_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_key_env)
SOC_WRITE_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" setup_api_key_env)
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f './.scoutflo/env' ]; then SCOUTFLO_ENV='./.scoutflo/env'; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
soc_secret() {
  case "$1" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1;; esac
  sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || exit 1; fi; printenv "$2"' _ "$SCOUTFLO_ENV" "$1" 2>/dev/null
}
SOC_ID=$(soc_secret "$SOC_ID_VAR") || { echo 'Missing management API ID'; exit 1; }
SOC_READ=$(soc_secret "$SOC_READ_VAR") || { echo 'Missing read-only key'; exit 1; }
SOC_WRITE=$(soc_secret "$SOC_WRITE_VAR") || { echo 'Missing separate setup key'; exit 1; }
[ -n "$SOC_ID" ] && [ -n "$SOC_READ" ] && [ -n "$SOC_WRITE" ] && [ "$SOC_READ" != "$SOC_WRITE" ] || { echo 'Require nonempty and separate credential tiers'; exit 1; }
for SOC_VALUE in "$SOC_ID" "$SOC_READ" "$SOC_WRITE"; do
  printf '%s' "$SOC_VALUE" | jq -Rse 'length > 0 and (test("[\\r\\n]")|not)' >/dev/null 2>&1 || { echo 'Invalid credential format'; exit 1; }
done
SOC_PREVIOUS=''
for SOC_KEY in "$SOC_READ" "$SOC_WRITE"; do
  SOC_REPLY=$( { printf 'header = %s\n' "$(printf 'X-VO-Api-Id: %s' "$SOC_ID" | jq -Rs .)"; printf 'header = %s\n' "$(printf 'X-VO-Api-Key: %s' "$SOC_KEY" | jq -Rs .)"; } | curl -q -sS --config - --proto '=https' --max-redirs 0 --connect-timeout 5 --max-time 20 --max-filesize 1048576 -w '\n%{http_code}' "https://api.victorops.com/api-public/v1/team/${SOC_TEAM}" 2>/dev/null) || { echo 'Team read failed; no mutation attempted'; exit 1; }
  SOC_STATUS=$(printf '%s\n' "$SOC_REPLY" | tail -n 1)
  case "$SOC_STATUS" in
    200) ;;
    401|403) echo "Team access refused (HTTP $SOC_STATUS); check this key and entitlement, not an inferred role"; exit 1;;
    429) echo 'Team read throttled (HTTP 429); stop and honor Retry-After before a later read'; exit 1;;
    3[0-9][0-9]) echo 'Team read redirected; credentials were not forwarded'; exit 1;;
    5[0-9][0-9]) echo "Provider unavailable (HTTP $SOC_STATUS); no mutation attempted"; exit 1;;
    *) echo "Unexpected team status (HTTP $SOC_STATUS); no mutation attempted"; exit 1;;
  esac
  SOC_BODY=$(printf '%s\n' "$SOC_REPLY" | sed '$d')
  SOC_STREAM=$(printf '%s' "$SOC_BODY" | jq --stream -c . 2>/dev/null) || { echo 'Invalid team JSON stream'; exit 1; }
  printf '%s' "$SOC_STREAM" | jq -e -s --arg team "$SOC_TEAM" '[.[] | select(length==2 and .[0][0]=="slug")] | length==1 and .[0][0]==["slug"] and .[0][1]==$team' >/dev/null 2>&1 || { echo 'Ambiguous team identity JSON'; exit 1; }
  printf '%s' "$SOC_BODY" | jq -e -s --arg team "$SOC_TEAM" 'length == 1 and (.[0] | type == "object" and .slug == $team and (.name|type == "string" and length > 0))' >/dev/null 2>&1 || { echo 'Team identity or JSON shape mismatch'; exit 1; }
  SOC_CURRENT=$(printf '%s' "$SOC_BODY" | jq -Sc '{slug,name}')
  [ -z "$SOC_PREVIOUS" ] || [ "$SOC_CURRENT" = "$SOC_PREVIOUS" ] || { echo 'Credential targets disagree'; exit 1; }
  SOC_PREVIOUS=$SOC_CURRENT
  sleep 1
done
printf 'On-Call setup preflight passed for team %s; no write permission inferred.\n' "$SOC_TEAM"
unset SOC_ID SOC_READ SOC_WRITE SOC_KEY SOC_VALUE SOC_REPLY SOC_BODY SOC_CURRENT SOC_PREVIOUS
```
<!-- oncall-setup-doctor:end -->

Expected: exit 0 and one safe preflight message. Missing keys, an HTML page with status 200, a wrong team, a redirect, an incomplete read or disagreement between key tiers stops before writes. A 401 or 403 describes that refused call; neither uniquely identifies the credential's role. Read-only refusal of a write was observed as 401 in one test, so do not assume it must be 403.

## Live-safety gate

State the selected config and label, the expected team, the exact objects being changed and whether any existing source or current incident depends on them. Confirm those identities against the intended organization in the provider UI. Do not infer organization identity from an arbitrary team name, a successful status, an API ID, or a self URL. A team identity anchor is a scoped check and must come from a trusted prior observation.

The API uses two required headers, `X-VO-Api-Id` and `X-VO-Api-Key`. All requests use the fixed HTTPS origin, refuse redirects and construct paths from validated IDs. Never follow `_selfUrl`, `_membersUrl` or another URL returned in a response. Never disable TLS verification. API ID, both management keys, routing keys, incoming URLs, contacts and raw alert fields are never printed or written; project allowed metadata before capture, following [secret redaction](../../report-standard/secret-redaction.md).

Run serially. One request per second is a conservative pace for the documented two-per-second configuration operations; stricter endpoint limits win. Stop on 429 and honor the server's retry indication before a fresh read. Do not retry writes automatically. History's separate once-per-minute limit does not become a configuration limit. The skill has no need to fetch secret-bearing alert-detail bodies during setup.

## Load findings and define the work

Use the audit run for the selected `splunk_oncall` target only. Resolve list labels with `report-standard/toolkit-targets.sh` and keep the same per-target segment, `splunk_oncall` or `splunk_oncall/<label>`. Select only date-named audit folders; a `setup-*` or `runs/` folder is not an audit. Verify the finding's owning skill, target and concrete affected resources before using it. Historical evidence proposes a change; a fresh dependency read authorizes its facts.

For a new organization without a previous audit, record the intended team, existing enrolled responders, required coverage window and timezone, escalation delay/fallback policy, source identity and environment. Absence of an existing audit is not a reason to invent findings. Respect the selected business-context exclusions and service SLA; an intentionally unused or partial-coverage rotation is not automatically a defect. Separate production and non-production destinations when your policy requires it, not because the skill assumes they must differ.

Keep a worklist with one row per concrete action: dependency IDs, reason, current state, desired state, proof status, approval, write result, readback and undo/retention. For a long run, pause at completed dependency boundaries. Resume by re-reading the target and every unresolved action; a stale worklist must never replay writes. A surviving request-start record without readback means unknown outcome, not permission to retry.

## Team description

Use the [description-only recipe](references/team-description.md) to prepare, apply or restore a non-default team's description. It preserves the name and identity, refuses unknown/missing response fields, reads both credential tiers and checks fresh state before each PUT. It requires a safe, exact local before-state and a distinct run directory. The source API requires `name` in its PUT payload even though this flow does not rename the team.

The recipe rejects missing/null descriptions because restoration to an absent field has not been proven. It also rejects arbitrary free-text content that cannot be safely retained as a backup. This restriction belongs to this proven recipe, not to what Splunk On-Call can represent. A different shape remains planning-only until its preservation and restore procedure has been implemented and verified.

## Teams and membership

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Prepare the intended team name, description, existing members and cost/entitlement effect. The future executor must read the created team and member list to record and verify its returned identity. Preserve existing default teams. Do not delete a default or unrelated team to make the workspace look clean.

Adding an already enrolled user to a team changes access. Inviting a new person, assigning an organization role and editing team membership are three distinct actions; approval for one does not silently include the others. Check existing active and pending users before an invitation. Do not re-submit an invitation because a page was slow, and do not use invitations as an API test. Pending invitations are not eligible verified coverage.

Before removing a member, inspect policies, rotations and overrides for references and approve a concrete replacement. The documented member deletion accepts a replacement; re-adding the old member does not undo those replacements. This version does not automate it. Team deletion additionally requires a complete dependency inventory and explicit retirement approval; recreation can change the identity.

## Rotations and shifts

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Prepare the coverage timezone, rotation order, start point, full-day or partial schedule, and enrolled members in the plan. The UI-created standard and partial forms have populated read evidence; API mutation and other shift modes remain verify-pending. Do not invent API request bodies from the response shape.

The future verification procedure must read the rotation, each shift and the rendered current/scheduled coverage after an approved save. Compare the returned timezone and weekday/time mask with the approved intent, then join rendered users to verified membership. The provider can normalize an equivalent timezone alias; establish equivalence for the requested interval rather than comparing strings alone. Inspect a daylight-saving transition when the intended window includes one.

A period with start/end times does not prove anyone staffs it. An unstaffed shift can return periods and current/next time blocks while omitting `oncall`. The standalone scheduled-user endpoint can return JSON null; it does not prove a populated scheduled user. Team-schedule `onCallUser` and current-on-call `onCalluser` are endpoint-specific fields. Treat missing staffing as uncovered or unknown according to the intended schedule and evidence, without substituting fields across endpoints. No interval proof beyond the fetched window is claimed.

## Escalation policies

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Propose each step's target type, exact existing user or rotation, delay, and custom-paging policy behavior. Build rotations and eligible membership first. Preserve all existing steps and flags unless the approved change explicitly replaces them; a policy PUT may be full replacement. This version stops at the plan because create/replace/delete behavior, exact verification and rollback are not yet enabled.

Required future verification: read the policy detail, its team association and every selected target after saving. Assert exact step order, target IDs and timeout against the approved plan; the audit's policy/coverage checks can supply the read evidence. A UI-only detail that the API does not expose needs an explicit screenshot or human comparison and remains limited to that observation. Never mark API preservation proven from it.

**Wrong:** "Two policies exist, so independent fallback is configured." **Right:** "Both supported policy paths currently resolve to the same verified user; the required independent fallback is still absent." A policy count is not an observed responder count.

A direct-user step and a rotation selecting that same user are one distinct human. Two policy targets do not prove independent fallback. Never delete a policy until every routing-key consumer is known: deleting the last policy target can remove a routing key. Replacement, reassignment and retirement are different plans.

## Routing keys

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Join the exact incoming-source route to the intended policy set in memory, and retain only a safe alias or secret-variable name in evidence. A route's presence is configuration; it proves neither incoming traffic nor paging. Validate every target policy before creating a key. Keep existing default routes and check name collisions before any create.

Prepare an exact mapping/retention plan for a new non-default key. The future executor must save its value directly in the protected local secret store, read the full routing list, locate the key in memory and compare the complete policy set, including multi-policy fanout, with the announced set. The verification record must contain equality booleans and target policy IDs, never the key. This section does not enable that execution. Existing API creation/readback evidence does not establish deletion or an atomic rollback, so do not offer automated create/delete as a reversible pair.

For mapping repair, first establish the existing `isMultiResponder` value from an authoritative surface. The management GET may omit it; missing is not false. An API PUT also carries a key in its path and another in its body, and can rename. This version refuses generated PUT/DELETE requests rather than silently changing mode or identity. A future repair must explicitly preserve the original key and responder mode, then re-read exact mappings; that verifier and rollback are still pending. If the mode cannot be checked, stop with the missing evidence.

## Incoming alert sources

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Plan only the named source and destination, showing the exact route and notification impact. Enabling a provider integration creates persistent incoming access and is a separate action from storing management credentials. Keep the incoming key and routing secret in the sender's supported secret mechanism. A YAML environment expression is not evidence that a deployed notifier expands it.

When the sender is Alertmanager, use the running version's supported VictorOps receiver fields and test routing semantics against its actual route tree. A matching child route does not automatically send to the parent receiver; `continue` controls sibling matching. Preserve the existing receivers and delivery policy. Never deploy a broad catch-all test route or treat a sink receiver as a mute control without testing it.

A separate approved delivery test needs a unique correlation identity, a single intended source/route, the exact expected policy/team, notification recipients, and a cleanup/recovery plan. Prefer an existing suitable QA alert; do not create a cluster fault from this skill. A new fault needs its source tool's explicit environment, baseline and independently reliable cleanup. Distinguish alert accepted, incident created, policy selected, user paged, notification delivered and human acknowledgement as separate facts.

An incoming endpoint may return a JSON body with `text/plain`; a documented body assertion is stronger than status alone. A timeout after a POST can still mean the event was accepted. Reconcile by the known incident identity before another send. Resolving an incident to clean up a test while its source still fires is test cleanup, not upstream recovery or proof of continuous integration. Runtime acknowledge/resolve and bulk incident actions are outside normal configuration setup.

## Personal paging and contact methods

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

Inspect only the selected responder's necessary contact type, verification state and paging references. Never persist actual email addresses, phone numbers or device tokens. The documented contact listing's numeric ID and detail lookup have shown unresolved identity behavior; do not invent another detail ID or follow an untrusted URL to work around it.

Contact enrollment may send verification messages and consume communication capacity. A future executor needs the exact recipient's approval and a verified enrollment procedure; a team setup request does not authorize a test SMS, call or email. The future verifier must assert enrollment and the intended paging rule separately. Personal policy APIs have step/order and restoration gaps, including no established step-delete operation, so automated creation and reordering remain verify-pending. Do not remove a last reachable path.

## Overrides, maintenance and alert rules

**Planning only. Execution, exact requested-field verification and rollback are not enabled by this section. Do not submit a provider UI change or API mutation.**

For an override plan, record the exact absent person, eligible replacement, start/end times, timezone and affected policy. Its future verification procedure must assert eligibility and the rendered interval after the approved change. An override for one interval does not prove coverage outside it. One-person fixtures cannot prove multi-person handover behavior.

For maintenance, require an exact nonempty route set and a reliable end procedure. The documented start operation treats an empty route list as global maintenance and has no established automatic end-time field. Never use global maintenance as test isolation or rely on an agent process remaining alive to end it. Automated start/end remains verify-pending. Ending maintenance can resume paging and is itself a concrete change.

For transformations and annotations, inspect the complete ordered organization rule list. A new rule can change other ranks, `stopFlag` can prevent later rules from running, and annotations can contain secrets. Preserve the complete predicate and order. Do not create a catch-all or send an alert merely to discover matching behavior. Automated mutation remains verify-pending until exact match, ordering, readback and restore semantics are demonstrated.

## Record and verify the result

Keep setup work under `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<resolved-target>/setup-<run-id>/`. Record the skill/version, target label, safe object IDs, finding or goal, approved diff, time, operation, observed status, readback predicates, preserved fields and undo disposition. Separate `verified`, `unknown-outcome`, `not-applied`, `retained-by-plan` and `verify-pending`; do not aggregate them into “done.” Never attach raw provider responses, full incoming URLs or secret values.

After the last verified change, rerun `/scoutflo:audit-splunk-oncall` with the same config/target and the read-only credential. Validate and regenerate all derived report artifacts through the [report standard](../../report-standard/README.md). Configuration findings may clear while delivery remains unverified; report both.

## Common Failure Modes

| Symptom or pressure | Required response |
| --- | --- |
| “Use my admin key for the audit too” | Keep separate credential references and stop if the values are identical in setup. The audit never loads the setup key. |
| Setup label is missing or misspelled | Stop before a request; never choose the first account. |
| HTTP 200 contains HTML, empty content or the wrong team | Fail the identity/shape gate; do not classify it as connected. |
| Missing description or an unknown team field | The proven metadata recipe cannot preserve that state; stop instead of making a replacement assumption. |
| Read after approval differs from the plan | Re-plan; do not overwrite parallel work. |
| Write timed out | Preserve the request-start journal and perform a read. No automatic retry or deletion. |
| A route GET has no `isMultiResponder` | Unknown mode; no generated mapping PUT and no false default. |
| Schedule has five periods but no person | Period existence does not prove coverage. Check the actual user and verified membership. |
| Three pending invitations for one address | Inspect and reconcile the existing identities under explicit identity-management approval; do not create another invitation. |
| A resolved test incident still has a firing source | Report cleanup separately and keep source recovery unproven. |
| “All API operations are in the spec, run them” | Select useful configuration by failure mode; contacts, roles, messages, incident actions and global suppression need their own concrete authority and proof. |

## Sources and compatibility

The public [VictorOps API specification](https://portal.victorops.com/api-docs/victorops-api-v1.yaml) supplies method/path and request-field contracts. Its Swagger version is not a product-version compatibility promise. The observed SaaS read and limited write behaviors above were checked in November 2026; runtime shape guards take precedence over that date. Provider UI layouts can change. Do not invent new menu paths, enum values, permissions or rollback behavior when they do.
