---
name: setup-splunk-oncall
description: Configure Splunk On-Call (formerly VictorOps) teams, staffed rotations, escalation policies, routing keys and incoming sources with exact change approval, fresh dependency checks and readback. Use when you say "set up Splunk On-Call", "fix VictorOps routing", "configure On-Call escalation", or "update the team description". Includes guarded API recipes and attended provider UI workflows where API preservation is unavailable. Use audit-splunk-oncall for read-only health checks and connect for credentials; do not use for Splunk log search, Observability Cloud, routine incident handling or organization roles.
disable-model-invocation: true
---

# setup-splunk-oncall

Plan a paging path you can explain and verify: the incoming source selects a routing key, the key selects one or more escalation policies, and each policy reaches the intended team and an eligible responder. Start from `/scoutflo:audit-splunk-oncall` findings or your explicit new-configuration goal. Keep the team, schedule, policy, routing and source work in one change plan, ordered by dependencies. Execute supported API operations through the fixed recipes below. For provider features whose API cannot preserve the necessary state, use the concrete attended UI workflow and record its narrower evidence. Every action keeps its own approval, readback and restoration or retirement boundary; a missing field stops that action rather than enabling a guessed request.

Splunk On-Call still uses VictorOps domains for its API. It is distinct from Splunk Enterprise, Cloud Platform and Observability Cloud. This skill does not configure those products. The management API is fixed at `https://api.victorops.com`; the incoming-alert service is a separate credential surface. Never substitute an incoming integration key for a management API key.

## Supported execution and proof boundaries

| Configuration | Execution path | Proof and preservation boundary |
| --- | --- | --- |
| Existing non-default team description | [Description recipe](references/team-description.md), retained for its narrow original workflow | Exact description update/restore; name and identity remain unchanged. |
| Teams and enrolled membership | [Team workflow](references/team-rotation-workflows.md): create, complete metadata update, enrolled-member add | Team creation also creates a provider default policy. Membership removal/reassignment uses the attended procedure below; adding the old member is not its inverse. |
| Rotations, shifts and staffing | [Rotation workflow](references/team-rotation-workflows.md): create/rename, full shift create/replace, roster add/move/remove, scheduled selection and owned retirement | Configuration/roster readback is distinct from interval coverage and notification delivery. Exact drift checks gate supported restoration; deletion changes identity. |
| Escalation policies | [Policy workflow](references/policy-routing-workflows.md): create, complete replacement, guarded restoration and owned retirement | Existing users/rotations and cycle-checked policy references; email/webhook targets use the attended editor workflow. |
| Non-default routing keys | [Routing workflow](references/policy-routing-workflows.md): create, replace when mode is observable, owned retirement | Existing mapping replacement requires a returned boolean responder mode. When absent, preserve and verify mode in the UI. Default keys remain protected. |
| Incoming sources, personal paging, overrides, maintenance and transformations | Attended procedures below, using the current provider/source editor | Read current controls, announce exact effects, save once, verify both changed and preserved state. API gaps never become guessed write recipes. |

There is no object-count cap. Choose the change set that satisfies the stated need and order it by dependencies. Every new API write family requires its own live acceptance/readback receipt; fixture tests and another operation's success do not supply it. Team/member creation, standard rotation creation and label restoration, complete shift replacement/restoration, and policy creation/replacement have populated November 2026 observations. Other variants remain separately identified until exercised. If a provider control cannot expose or preserve the required state, leave that specific action unapplied with the exact missing proof; do not report it configured.

## The change protocol

Apply this protocol to every API or attended UI change. Every attended procedure must execute the [before/after assertion block](references/attended-verification.md): `check-before` against the preserved baseline before saving, then `check-after` against the approved complete expected state. It reads management fields through fixed GETs and separately verifies fresh evidence-bound UI-only observations. Unobservable fields refuse the save; a prose claim is not a verification result:

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
| Tools | `sh`, `curl` 8.4 or newer, `jq`, `shasum` for private plan credential binding, Python 3.9+ (`python3`) with IANA timezone data for fixed recipes and exclusive local journal creation; no cloud CLI is needed for this provider |

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
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || { echo 'Python 3.9 or newer is required'; exit 1; }
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

The recipe rejects missing/null descriptions because restoration to an absent field has not been proven. It also rejects arbitrary free-text content that cannot be safely retained as a backup. This restriction belongs to this proven recipe, not to what Splunk On-Call can represent. For broader metadata changes, use the complete team workflow below. If its shape guard also refuses the current state, stop that metadata variant: the attended verifier has no team-metadata comparator, so inspecting the editor does not establish preservation or authorize a save.

## Teams and membership

Use `team-create`, `team-update` or `member-add` in the [team workflow](references/team-rotation-workflows.md). Plan the exact name, description, existing enrolled members and entitlement impact. Apply only the approved checksum, then verify the returned identity and complete membership. Creation also creates an implicit default escalation policy; inventory it before connecting any source. A metadata PUT includes both name and description, preserves the other known fields and supports restoration against the saved post-write state. An identity-changing rename or unrepresentable before-state stops as unknown.

Adding an enrolled user to a team changes access. Invitations, organization roles and team membership are distinct actions; this skill's API recipe never sends invitations or changes roles. Check verified enrollment before adding membership and again before execution. Pending invitations do not count as staffed coverage, and a slow page never justifies sending a duplicate invitation.

For **member removal/reassignment**, use the current team's member editor after reading every affected rotation, escalation policy and override. Select the exact existing member and a different eligible replacement, record the named references and intervals that will move, and approve that complete reassignment. Save once, then read membership and every affected reference and rendered interval. A missing member row alone is insufficient. To reverse, compare the current references with the saved post-change state and obtain approval for the complete inverse reassignment before saving again; simply re-adding the former member is not restoration.

For **team retirement**, use the owned-object guard in the team recipe. It requires the exact successful team-create journal, zero members/rotations and no dependent consumers. The sole empty implicit default policy may be deleted with that empty team only under the recipe’s verified narrow conditions; the approved plan names both deletions. Additional or nonempty policies, routing/nested consumers, overrides and maintenance stop it. This does not enable general cascade deletion. Stop any retirement variant outside those proven conditions: the attended verifier has no complete team-retirement comparator, so a provider editor is not a supported fallback for unknown deletion effects. Recreation requires a new plan and may produce new identities. Never retire a default or unrelated team.

## Rotations and shifts

Use the [rotation workflow](references/team-rotation-workflows.md) for rotation create/rename, complete shift create/update, roster changes and current scheduled-user selection. Provide the real coverage timezone, start in epoch milliseconds, duration in days, shift type, weekday/time mask and enrolled members. Inline rotation creation can staff a shift through `usernames`; standalone shift POST/PUT ignores that field, so the recipe rejects it there and uses a separate roster operation. Roster writes may return an empty HTTP 204; only the following GET proves staffing.

A full shift replacement preserves every required timing field and the roster. The standard all-day API shape uses 00:00 to 00:00: observed normalization of another end time must not be silently accepted. The recipe rejects a requested/readback mismatch. Rotation-label and complete-shift restoration compare the saved post-write state first. Roster reordering also checks the scheduled user; removing a current responder or changing the scheduled user is a timed duty change whose reversal needs a fresh plan. Never remove the last distinct responder.

For a **partial/custom/alternate schedule** that the fixed shape cannot represent faithfully, open that exact shift in the current schedule editor. Record the complete timezone, recurrence, day/time restrictions, start, order and roster, plus the intended interval and a DST boundary when relevant. Preview the proposed intervals with named eligible users, approve, save once, and compare both the API configuration and rendered coverage with the preview. Treat timezone-alias equivalence as a demonstrated interval comparison, not a guessed string substitution. To restore, re-read the whole shift and roster against the saved post-state, announce the original configuration, confirm, save once and repeat interval verification. If the UI cannot preview or restore a required field, stop that variant and name the gap.

A period with start/end times does not prove staffing. An unstaffed shift can expose periods/current/next while omitting `oncall`; the scheduled-user endpoint can return JSON null. Team-schedule `onCallUser` and current-on-call `onCalluser` are endpoint-specific. Join the actual returned user to verified membership and claim coverage only for the fetched interval. For retirement, remove run-owned shifts before their rotation and inspect all policies for references to its `rtg-…` slug; the numeric rotation API ID is a different identifier.

## Escalation policies

Use `policy-create` or `policy-replace` in the [policy workflow](references/policy-routing-workflows.md). It supports enrolled direct users, existing rotations and cycle-checked references to existing policies. Build membership and rotations first. Provide the full ordered steps, target identities, timeout in minutes and explicit `ignoreCustomPagingPolicies`; omission is not false, and replacement is not a patch. Verify the team association, exact order, delays, flags and every selected target after saving. A supported restore requires the current saved post-state and a separately confirmed inverse.

For **email or webhook entries**, use the reference's attended destination workflow. Read the complete policy and existing destination identity, keep addresses/URLs in their protected store or provider editor, and show only a safe alias in the plan. A new destination requires its owner's concrete authorization. Announce the exact new step/position/delay and preservation of every other step and flag, save once, and re-read the full policy. Compare the private destination in memory and record equality rather than its value. Restore only after a fresh full-state comparison and confirmation of the inverse. Destination presence is not successful delivery; do not test-send merely to validate syntax.

**Wrong:** "Two policies exist, so independent fallback is configured." **Right:** "Both supported paths resolve to the same verified person, so independent fallback is absent." Direct-user and rotation entries selecting the same person count once. Before owned-policy retirement, prove no routing-key, nested-policy or override consumer; deleting a last policy target may also delete its routing key. Replacement, reassignment and retirement are separate plans.

## Routing keys

Use the [routing workflow](references/policy-routing-workflows.md) to create a non-default key for the exact existing policy set. A create plan generates/stores the new value directly in the protected secret store and records only its variable name. Read the complete routing list, join the key in memory and compare the full target set. Verify multi-policy fanout explicitly. Retain existing default keys and refuse collisions.

For **mapping replacement**, the API recipe requires the current `isMultiResponder` boolean and preserves it. If GET omits it, use the attended route editor procedure in the reference: inspect and privately record the current mode, announce the complete new target set with unchanged key/mode, approve, save once, re-read the mapping and verify the mode in the UI. Record UI-observed preservation separately from API evidence. Restore against both current API and UI post-state with an approved inverse mapping; drift requires a new plan. Never substitute a guessed false.

For **key rotation/rename**, first inventory every sender using the old key and its reload/rollback mechanism. Prefer a separately created successor key with the same approved policy set, store it privately, update each selected sender through its owning setup flow, and verify the source→key→policy join before retiring the unused old key. An in-place rename is not supported by the attended verifier: its identity binding must remain unchanged, and it has no combined old-absence/new-identity comparator. Stop that variant and use the separately created successor-key workflow. Do not call deletion an atomic rollback. Owned retirement requires external-use confirmation and fresh rule/maintenance/policy checks; keep the old secret reference for unknown-outcome reconciliation.

## Incoming alert sources

This is an **attended source/provider configuration workflow**. The management API credential and the incoming integration credential are separate. Enabling an integration creates persistent incoming access and needs that exact action in the approved plan.

For a Kubernetes-hosted Alertmanager, follow the [native source recipe](references/alertmanager-source.md) for protected configuration, selected cluster identity, preserved receivers, installed-version assertions and rollback. Its supported source shape and prerequisites are explicit; do not transplant it into an unverified deployment.

1. Inspect the selected provider integration and sender, their current enablement, existing receiver/routing configuration and delivery policy. Identify the intended non-default route/policy set, environment and recipients. Preserve a restorable sender configuration without copying secret values into the worklog.
2. Announce the exact integration enablement, source receiver and matching rule, retained receivers and rollback. After confirmation, enable or select the current provider integration once. Transfer its incoming credential directly into the sender's supported protected secret mechanism; record only the secret reference.
3. Validate the sender configuration before applying it. For Alertmanager, use its running version's supported VictorOps fields and validate the actual route tree: a matching child does not automatically invoke the parent receiver, and `continue` controls siblings. Never infer that a YAML environment expression is expanded by the running notifier.
4. Apply through the source's owning setup workflow, then read the loaded sender configuration and provider routing/policy state to verify the exact join and preserved existing receivers. A saved file alone is not a loaded configuration.
5. If delivery testing is approved, use a unique correlation identity and an existing suitable QA alert, with exact expected source/route/policy/recipients and a reliable recovery procedure. Reconcile accepted, incident-created, policy-selected, user-paged, notification-delivered and human-acknowledged as separate facts. This skill does not create a cluster fault; a source fault needs its own verified environment and cleanup authority.
6. To restore, verify no concurrent sender/provider edit, announce the saved receiver/routing configuration, confirm and restore it through the owning source workflow. Read the loaded state again before disabling a newly unused integration. Do not disable shared incoming credentials or remove another sender's receiver.

An incoming endpoint may return JSON with `text/plain`; assert the documented body rather than status alone. A timeout after POST can still mean acceptance: reconcile the unique incident identity before another send. Resolving a test incident while its source still fires is test cleanup, not recovery or continuous-delivery proof. Normal incident acknowledgement, resolution and bulk actions remain outside configuration setup.

## Personal paging and contact methods

Use the **selected responder's current contact and paging editor** for these actions. Contact API list/detail identity and step-delete semantics are not sufficiently established for a generic write recipe. Keep actual email addresses, phone numbers and device tokens out of worklogs, model-visible shell output and public artifacts.

Read the selected person's necessary contact types, verified state, current ordered paging steps and fallback. Obtain the exact recipient's approval for contact enrollment and any verification message or charge; team setup alone does not authorize a test call/SMS/email. Add only the approved contact in the provider editor, save once, and have the owner complete verification. Re-read its verified state before adding it to a paging policy. A pending contact is not reachable evidence.

For paging-rule changes, announce the complete order, delays and contact aliases, preserve a last reachable path, approve and save once. Reopen the editor and compare every step and verification status; a new contact alone does not prove the policy uses it. Restoration requires equality with the saved post-change steps, an approved inverse and the same readback. Retire a newly added unused contact only after removing its verified references and the owner's explicit approval. If the UI cannot preserve or restore an ordered field, stop that action rather than manufacture a personal-policy API delete.

## Overrides, maintenance and alert rules

For an **override**, read the exact absent person, eligible replacement, start/end, timezone and every affected rotation/policy. Preview the rendered interval and approve its complete duty impact. Save once in the current override editor, then read the override and rendered coverage to confirm the replacement and unaffected adjacent intervals. Reversal is cancellation or replacement at the current time: compare the saved post-state, approve the changed duty interval, save once, and verify coverage again. One interval and one person do not establish multi-person handover or future continuity.

For **maintenance**, select an exact nonempty route set after checking its current maintenance and sender state. Empty route selection means global maintenance in the documented API and is refused. Announce the suppression scope, start and reliable end mechanism; use a provider-enforced end if the current UI actually supports it, or an authorized operator who will remain present to end it. Do not start unattended suppression that depends on this agent surviving. Confirm, start once in the provider UI, then verify active status and exact selected routes while other routes remain unaffected. Ending maintenance can resume paging: confirm the end, end once and verify absence of that maintenance plus the intended restored route state. Global maintenance is not test isolation.

For **transformations, routing rewrites and annotations**, inspect the complete ordered organization rule list, exact predicates, rank, stop behavior and affected routes. Keep secret-bearing annotation values in a protected store/editor and record only aliases/equality. Preview the intended match and non-match examples without sending a notification. Announce and approve the exact rule and preservation of other rules, save once, then re-read the full list and compare predicate, action, order and `stopFlag`. A provider reorder is an effect that must be reviewed. To restore, first compare all current rule state with the saved post-state, announce the prior rule/order, confirm and save once, then repeat both positive and negative matching checks. If safe exact preservation or ordering cannot be established, leave the specific action unapplied; do not create a catch-all experiment.

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
| A route GET has no `isMultiResponder` | Preserve and verify it through the attended editor workflow; no generated mapping PUT or false default. |
| Schedule has five periods but no person | Period existence does not prove coverage. Check the actual user and verified membership. |
| Three pending invitations for one address | Inspect and reconcile the existing identities under explicit identity-management approval; do not create another invitation. |
| A resolved test incident still has a firing source | Report cleanup separately and keep source recovery unproven. |
| “All API operations are in the spec, run them” | Select useful configuration by failure mode; contacts, roles, messages, incident actions and global suppression need their own concrete authority and proof. |

## Sources and compatibility

The public [VictorOps API specification](https://portal.victorops.com/api-docs/victorops-api-v1.yaml) supplies method/path and request-field contracts. Its Swagger version is not a product-version compatibility promise. The observed SaaS read and individually exercised write behaviors above were checked in November 2026; runtime shape guards take precedence over that date. Provider UI layouts can change. Do not invent new menu paths, enum values, permissions or rollback behavior when they do.
