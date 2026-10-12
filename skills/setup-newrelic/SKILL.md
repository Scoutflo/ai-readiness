---
name: setup-newrelic
description: Guided, confirm-then-verify remediation of the gaps audit-newrelic finds in a New Relic account — wiring workflows to uncaught policies, creating per-service alert conditions from golden metrics, fixing condition tiering/evaluation/loss-of-signal settings, retiring dead-weight conditions, scheduling muting rules, adding SLOs, ownership tags, synthetic monitors, and change tracking. Every change is announced with its exact NerdGraph mutation and rollback, applied only after explicit approval, and verified by re-read. Use when the user asks to fix, remediate, or harden New Relic alerting or coverage, or follows an audit-newrelic finding's pointer. Do not use to audit (use audit-newrelic) or for the collector-side OTel pipeline (that lives in the shipping cluster's own config).
disable-model-invocation: true
---

# setup-newrelic

Fixes what `audit-newrelic` finds, in the safety order that never leaves the
account worse mid-change: delivery first (a fired incident must reach someone),
then coverage, then noise tuning, then posture (SLOs, tags, synthetics, change
tracking). Every write is a NerdGraph **mutation announced with real values,
approved explicitly, executed one object at a time, verified by re-read, and
recorded** — the change protocol below has no exceptions.

Mutation-surface honesty: the **create** mutations in this skill
(`alertsPolicyCreate`, `alertsNrqlConditionStaticCreate`,
`alertsNrqlConditionBaselineCreate`, `aiNotificationsCreateDestination`,
`aiNotificationsCreateChannel`, `aiWorkflowsCreateWorkflow`,
`alertsMutingRuleCreate`, `serviceLevelCreate`, `syntheticsCreateSimpleMonitor`,
`taggingAddTagsToEntity`, `changeTrackingCreateDeployment`) are live-verified
against a real account, and so is **`alertsNrqlConditionStaticUpdate`**
(partial-body updates of `expiration` and `terms` applied and read back live —
a remediation session resolved NR-011/NR-022/NR-025 end-to-end with it,
including the incident close cycle). The remaining **update/delete** mutations
are named per New Relic's schema but must be **introspected before first use**
(`{ __type(name: "<InputType>") { inputFields { name type { name kind } } } }`)
— the live schema is the authority and drifts ahead of the docs; announce the
introspected shape, not a guessed one.

## The change protocol

Every change follows one loop, no exceptions:

1. **Announce.** Show the exact change before touching anything: the NerdGraph
   mutation document and variables with real values filled in (secrets as
   env-var names, never values), plus its rollback.
2. **Confirm.** Wait for explicit approval in the conversation. One approval may
   cover a batch only when every change in the batch was shown first. Silence,
   an earlier approval, or "fix everything" from three steps ago is not consent.
   Declining means zero changes.
3. **Execute.** Apply exactly what was announced, one object at a time. If
   reality forces a different change (a schema field the introspection renamed,
   an id that no longer exists), stop and re-announce.
4. **Verify.** Re-read the modified object with the same query the audit uses
   and assert the outcome machine-checkably: a `jq -e` test on the re-read, or a
   captured HTTP code against its stated `Expect:` line. A write is unverified
   until a command proves it. **Check BOTH error surfaces**: top-level GraphQL
   `errors[]` AND the mutation's in-payload `errors` block — NerdGraph is
   inconsistent about which one carries a failure.
5. **Record.** Append the change, its verification evidence, and any pending
   items with a named owner to the change record.

**Mid-batch failure rule.** If change N of an approved batch fails, stop the
batch immediately: no change N+1 runs. Re-read the failed object's current
state, record which earlier rows already applied (and where their backups
live), and never continue past the failed row. Diagnose, then re-announce the
remaining rows for a fresh approval; the earlier approval does not carry over
to a re-announced plan.

## Doctor gate

This skill uses the elevated tier: the User key's user must be allowed to
manage alert conditions, workflows, destinations, SLOs, synthetics, and tags.
Keep it separate from a least-privileged audit key where your org supports it;
`audit-newrelic` runs read-only and records when its credential can do more
than read.

| Integration | Config keys | Env var | Minimum capability | Tier |
| --- | --- | --- | --- | --- |
| New Relic | `newrelic.account_id`, `newrelic.api_key_env`, optional `newrelic.region` (`US` default, `EU`) | named by `api_key_env` (a **User** key, `NRAK-…`) | NerdGraph reads plus alert/workflow/SLO/synthetics/tag management on the account | elevated |

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
[ -f "$CFG" ] || { echo "missing $CFG; run /scoutflo:connect"; exit 1; }
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
for bin in curl jq; do command -v "$bin" >/dev/null || { echo "missing binary: $bin"; exit 1; }; done
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "${NR_N:-0}" -ge 1 ] || { echo "no newrelic target configured in $CFG; run /scoutflo:connect"; exit 1; }
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX"); NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
[ -n "$NR_ACCT" ] || { echo "newrelic target '${NR_LABEL:-?}' has no account_id in $CFG"; exit 1; }
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; *) echo "newrelic.region must be US or EU"; exit 1 ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — add it to ~/.scoutflo/env, or run /scoutflo:connect"; exit 1; }
NRB="$(mktemp)"
NRM="$(curl -s -o "$NRB" -w '%{http_code} %{content_type}' --max-time 15 \
  -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data '{"query":"{ actor { user { name } accounts { id name } } }"}')" || true
NRC="${NRM%% *}"; NRCT="${NRM#* }"
[ "$NRC" = "401" ] && { rm -f "$NRB"; echo "401 authentication required: key missing or invalid (indistinguishable) — mint/re-paste a USER key (NRAK-)"; exit 1; }
[ "$NRC" = "403" ] && { rm -f "$NRB"; echo "403: valid key on the wrong region endpoint — fix newrelic.region"; exit 1; }
[ "$NRC" = "200" ] && printf '%s' "$NRCT" | grep -qi json && jq -e '.data.actor.user.name' "$NRB" >/dev/null 2>&1 \
  || { rm -f "$NRB"; echo "unexpected ${NRC} / non-JSON from ${NR_API_HOST} — not NerdGraph"; exit 1; }
jq -e --argjson a "$NR_ACCT" '.data.actor.accounts | any(.[]; .id == $a)' "$NRB" >/dev/null 2>&1 \
  || { echo "key cannot see account ${NR_ACCT}; it sees:"; jq -r '.data.actor.accounts[] | "  - \(.id) \(.name)"' "$NRB"; rm -f "$NRB"; exit 1; }
rm -f "$NRB"
echo "doctor gate: pass"
```

There is no scope introspection on a User key; whether it can mutate is proven
by the first announced change's verification, never assumed. A 4xx on a
mutation is evidence to record, not permission to retry with a different key.

## Live-safety gate

The identity check is independent of the config: the account list comes from
the API, so a wrong `account_id` cannot pass by construction — and the entity
sample tells a human this is the right estate before anything changes.

```bash
set -eu
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX"); NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
LSB="$(mktemp)"
LSM="$(curl -s -o "$LSB" -w '%{http_code} %{content_type}' --max-time 15 \
  -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { id name } entitySearch(query: \\\"accountId = ${NR_ACCT} AND (domain = 'EXT' OR domain = 'APM')\\\") { count results { entities { name } } } } }\"}")" || true
LSC="${LSM%% *}"; LSCT="${LSM#* }"
[ "$LSC" = "200" ] && printf '%s' "$LSCT" | grep -qi json && jq -e '.data.actor.account.id' "$LSB" >/dev/null 2>&1 \
  || { rm -f "$LSB"; echo "account identification failed (HTTP ${LSC}) — stop"; exit 1; }
echo "TARGET: account $(jq -r '.data.actor.account.id' "$LSB") ($(jq -r '.data.actor.account.name' "$LSB")) region=${NR_REGION} services=$(jq -r '.data.actor.entitySearch.count' "$LSB") sample: $(jq -r '[.data.actor.entitySearch.results.entities[:3][].name] | join(", ")' "$LSB")"
rm -f "$LSB"
echo "live-safety gate: pass — confirm this is the account you intend to CHANGE before approving anything"
```

## Load findings and build the change plan

Read the latest `audit-newrelic` run and turn its findings into an ordered plan:

```bash
set -eu
AUD="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
LATEST="$(find "$AUD/newrelic" -mindepth 1 -maxdepth 2 -name findings.json 2>/dev/null | sort | tail -1)"
[ -n "$LATEST" ] || { echo "no audit-newrelic findings.json found under $AUD/newrelic — run /scoutflo:audit-newrelic first"; exit 1; }
jq -r '.findings[] | select(.scoring_scope=="readiness") | "\(.severity)\t\(.id)\t\(.title)"' "$LATEST" | sort
```

Order the plan **delivery → coverage → noise → posture** (the section order
below). Announce the whole plan first; approve per section or per change.

## Wire a workflow to an uncaught policy

Fixes NR-011/NR-012/NR-013 (a conditioned policy no enabled workflow catches;
broken channel→destination linkage; unproven delivery). This includes the
platform-created "Service Levels default policy": New Relic auto-creates it
WITH an enabled error-budget condition, caught by nothing — the deliberate
choice here is wire-or-disable, never ignore.

1. **Backup (read-before-write), run as written** — capture the current
   workflow/destination state the rollback restores from:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# Read every page: the rollback keeps whatever this backup lists, so a missed page would let it delete an object that existed before.
fetch() { # fetch <out> <container path> <query using $a and $c>: every entity of one paginated list, as a JSON array in <out>
  cur=null; pages=0; : > "$1.jsonl"
  while :; do
    jq -n --arg q "$3" --argjson a "$NR_ACCT" --argjson c "$cur" '{query: $q, variables: {a: $a, c: $c}}' \
      | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
          -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @- > "$1.page"
    jq -e ".errors == null and (${2}.error == null) and (${2}.entities | type == \"array\")" "$1.page" > /dev/null \
      || { echo "reading ${2} failed; no backup written" >&2; exit 1; }
    jq -c "${2}.entities[]" "$1.page" >> "$1.jsonl"
    next="$(jq -c "${2}.nextCursor // null" "$1.page")"
    [ "$next" != null ] || break
    [ "$next" != "$cur" ] || { echo "the ${2} cursor did not advance; no backup written" >&2; exit 1; }
    cur="$next"; pages=$((pages + 1))
    [ "$pages" -lt 1000 ] || { echo "more than 1000 pages of ${2}; no backup written" >&2; exit 1; }
  done
  total="$(jq "${2}.totalCount // empty" "$1.page")"; got="$(wc -l < "$1.jsonl" | tr -d ' ')"
  [ -z "$total" ] || [ "$total" -eq "$got" ] || { echo "read ${got} of ${total} in ${2}; no backup written" >&2; exit 1; }
  jq -s '.' "$1.jsonl" > "$1"
}
fetch "$TMPD/workflows" '.data.actor.account.aiWorkflows.workflows' 'query($a: Int!, $c: String) { actor { account(id: $a) { aiWorkflows { workflows(cursor: $c) { nextCursor totalCount entities { id name workflowEnabled destinationConfigurations { channelId } issuesFilter { predicates { attribute operator values } } } } } } } }'
fetch "$TMPD/destinations" '.data.actor.account.aiNotifications.destinations' 'query($a: Int!, $c: String) { actor { account(id: $a) { aiNotifications { destinations(cursor: $c) { nextCursor totalCount error { details } entities { id name type active } } } } } }'
fetch "$TMPD/channels" '.data.actor.account.aiNotifications.channels' 'query($a: Int!, $c: String) { actor { account(id: $a) { aiNotifications { channels(cursor: $c) { nextCursor totalCount error { details } entities { id name destinationId } } } } } }'
jq -n --slurpfile w "$TMPD/workflows" --slurpfile d "$TMPD/destinations" --slurpfile ch "$TMPD/channels" \
  '{aiWorkflows: {workflows: {entities: $w[0]}}, aiNotifications: {destinations: {entities: $d[0]}, channels: {entities: $ch[0]}}}' > "$BK/notification-plane.json"
jq -e '.aiWorkflows' "$BK/notification-plane.json" >/dev/null && echo "backup: $BK/notification-plane.json"
```

2. **Announce, then create** destination → channel → workflow (all three
   creates live-verified). The channel MUST carry `product: IINT` — the classic
   mismatch failure. Filter the workflow on the exact policy id:

```
mutation { aiNotificationsCreateDestination(accountId: <acct>, destination: {type: EMAIL, name: "<name>", properties: [{key: "email", value: "<team-address>"}]}) { destination { id } error { details } } }
mutation { aiNotificationsCreateChannel(accountId: <acct>, channel: {type: EMAIL, name: "<name>", destinationId: "<dest-id>", product: IINT, properties: [{key: "subject", value: "{{issueTitle}}"}]}) { channel { id } error { details } } }
mutation { aiWorkflowsCreateWorkflow(accountId: <acct>, createWorkflowData: {name: "<name>", workflowEnabled: true, destinationsEnabled: true, mutingRulesHandling: DONT_NOTIFY_FULLY_MUTED_ISSUES, issuesFilter: {predicates: [{attribute: "labels.policyIds", operator: EXACTLY_MATCHES, values: ["<policy-id>"]}], type: FILTER}, destinationConfigurations: [{channelId: "<channel-id>"}]}) { workflow { id } errors { description } } }
```

3. **Verify by re-read, machine-checkable** — the audit's own NR-011 join must
   now catch the policy:

```bash
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { aiWorkflows { workflows { entities { workflowEnabled issuesFilter { predicates { attribute values } } } } } } } }\"}" \
  | jq -e --arg p "<policy-id>" '.data.actor.account.aiWorkflows.workflows.entities
      | any(.[]; .workflowEnabled == true and any(.issuesFilter.predicates[]; .attribute == "labels.policyIds" and (.values | index($p))))' \
  && echo "policy <policy-id> is now caught"
```

4. **Rollback (worked pair)**, in its own fresh shell: delete in reverse order
   (workflow, channel, destination) with the ids the create responses
   returned. Any id the step 1 backup lists existed before the setup and is
   kept, so a destination you reused stays. Introspect each delete input
   before first use; a renamed input comes back in `errors[]` and stops the
   block before the next object.

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
WORKFLOW_ID="<workflow-id>"   # workflow.id from the aiWorkflowsCreateWorkflow response; none if that create never ran
CHANNEL_ID="<channel-id>"     # channel.id from the aiNotificationsCreateChannel response; none if that create never ran
DEST_ID="<destination-id>"    # destination.id from the aiNotificationsCreateDestination response; none if you reused one
BK_FILE="<backup-path>"       # the "backup:" path step 1 printed
for v in "$WORKFLOW_ID" "$CHANNEL_ID" "$DEST_ID" "$BK_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$BK_FILE" ] || { echo "No backup at ${BK_FILE}" >&2; exit 1; }
jq -e '.aiWorkflows and .aiNotifications' "$BK_FILE" > /dev/null || { echo "${BK_FILE} is not a notification-plane backup" >&2; exit 1; }
gql() { # gql <query> <id>: one NerdGraph call on this account
  jq -n --arg q "$1" --argjson a "$NR_ACCT" --arg id "$2" '{query: $q, variables: {a: $a, id: $id}}' \
    | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
        -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @-
}
for obj in workflow channel destination; do
  case "$obj" in
    workflow) ID="$WORKFLOW_ID"; BEFORE='.aiWorkflows.workflows.entities'
      # deleteChannels: false, so the channel gets its own verified delete below.
      DEL_Q='mutation($a: Int!, $id: ID!) { r: aiWorkflowsDeleteWorkflow(accountId: $a, id: $id, deleteChannels: false) { id errors { description } } }'
      GET_Q='query($a: Int!, $id: ID!) { actor { account(id: $a) { aiWorkflows { l: workflows(filters: {id: $id}) { entities { id } } } } } }' ;;
    channel) ID="$CHANNEL_ID"; BEFORE='.aiNotifications.channels.entities'
      DEL_Q='mutation($a: Int!, $id: ID!) { r: aiNotificationsDeleteChannel(accountId: $a, channelId: $id) { ids error { details } } }'
      GET_Q='query($a: Int!, $id: ID!) { actor { account(id: $a) { aiNotifications { l: channels(filters: {id: $id}) { entities { id } } } } } }' ;;
    destination) ID="$DEST_ID"; BEFORE='.aiNotifications.destinations.entities'
      DEL_Q='mutation($a: Int!, $id: ID!) { r: aiNotificationsDeleteDestination(accountId: $a, destinationId: $id) { ids error { details } } }'
      GET_Q='query($a: Int!, $id: ID!) { actor { account(id: $a) { aiNotifications { l: destinations(filters: {id: $id}) { entities { id } } } } } }' ;;
  esac
  [ "$ID" != "none" ] || { echo "${obj}: none created, skipped"; continue; }
  if jq -e --arg id "$ID" "any(${BEFORE}[]?; .id == \$id)" "$BK_FILE" > /dev/null; then
    echo "${obj} ${ID}: in the pre-change backup, kept"; continue
  fi
  # Both error surfaces (top-level errors[] and the mutation's own errors/error block), and the deleted id must come back.
  gql "$DEL_Q" "$ID" | jq -e --arg id "$ID" '.errors == null and ((.data.r.errors // []) | length == 0) and .data.r.error == null
      and (.data.r.id == $id or any(.data.r.ids[]?; . == $id))' > /dev/null \
    || { echo "${obj} ${ID}: delete failed; stopping before the next object" >&2; exit 1; }
  # A null account (a failed read) is not an empty list: require an array.
  gql "$GET_Q" "$ID" | jq -e '.errors == null and ((.data.actor.account | (.aiWorkflows // .aiNotifications).l.entities) | type == "array" and length == 0)' > /dev/null \
    || { echo "${obj} ${ID}: still present after the delete, or the re-read failed" >&2; exit 1; }
  echo "${obj} ${ID}: deleted"
done
```

   Expected: one `deleted`, `kept`, or `skipped` line per object, then exit 0.
   The block stops at the first delete or re-read that fails.

**Webhook destinations** are domain-validated at creation (`.invalid`-style
hosts are rejected with `AiNotificationsDataValidationError` — fields
`fields { field message }`); a rejected create is evidence the endpoint is
wrong, not a retry-until-it-sticks loop. Slack destinations are OAuth-only —
they cannot be created by API; name the UI step instead. To upgrade NR-013 from
`configured` to `validated-live`, trigger one controlled test notification from
the UI and confirm receipt.

## Create per-service alert conditions

Fixes NR-030 (zero-coverage entities) and NR-014 (no entity-bound paging path).
Each entity's `goldenMetrics` ships ready-made NRQL — start from it instead of
authoring queries:

1. Read the service's golden metric:
   `{ actor { entity(guid: "<guid>") { goldenMetrics { metrics { name query } } } } }`
2. **Snapshot the alerting plane before any create, run as written.** The
   rollback below never deletes a condition or a policy this snapshot lists:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# Read every page: a missed page would let the rollback delete something that existed before.
fetch() { # fetch <out> <container path> <list field> <query using $a and $c>: every entry of one paginated list, as a JSON array in <out>
  cur=null; pages=0; : > "$1.jsonl"
  while :; do
    jq -n --arg q "$4" --argjson a "$NR_ACCT" --argjson c "$cur" '{query: $q, variables: {a: $a, c: $c}}' \
      | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
          -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @- > "$1.page"
    jq -e ".errors == null and (${2}.${3} | type == \"array\")" "$1.page" > /dev/null \
      || { echo "reading ${3} failed; no snapshot written" >&2; exit 1; }
    jq -c "${2}.${3}[]" "$1.page" >> "$1.jsonl"
    next="$(jq -c "${2}.nextCursor // null" "$1.page")"
    [ "$next" != null ] || break
    [ "$next" != "$cur" ] || { echo "the ${3} cursor did not advance; no snapshot written" >&2; exit 1; }
    cur="$next"; pages=$((pages + 1))
    [ "$pages" -lt 1000 ] || { echo "more than 1000 pages of ${3}; no snapshot written" >&2; exit 1; }
  done
  total="$(jq "${2}.totalCount // empty" "$1.page")"; got="$(wc -l < "$1.jsonl" | tr -d ' ')"
  [ -z "$total" ] || [ "$total" -eq "$got" ] || { echo "read ${got} of ${total} ${3}; no snapshot written" >&2; exit 1; }
  jq -s '.' "$1.jsonl" > "$1"
}
fetch "$TMPD/policies" '.data.actor.account.alerts.policiesSearch' policies 'query($a: Int!, $c: String) { actor { account(id: $a) { alerts { policiesSearch(cursor: $c) { nextCursor totalCount policies { id } } } } } }'
fetch "$TMPD/conditions" '.data.actor.account.alerts.nrqlConditionsSearch' nrqlConditions 'query($a: Int!, $c: String) { actor { account(id: $a) { alerts { nrqlConditionsSearch(cursor: $c) { nextCursor totalCount nrqlConditions { id } } } } } }'
jq -n --slurpfile p "$TMPD/policies" --slurpfile c "$TMPD/conditions" '{policies: [$p[0][].id], conditions: [$c[0][].id]}' > "$BK/alerting-snapshot.json"
jq -e '(.policies | type) == "array" and (.conditions | type) == "array"' "$BK/alerting-snapshot.json" > /dev/null && echo "snapshot: $BK/alerting-snapshot.json"
```

3. Announce the condition (both terms; example thresholds — tune to the
   signal's real floor):

```
mutation { alertsNrqlConditionStaticCreate(accountId: <acct>, policyId: "<policy-id>", condition: {name: "<service> error rate", enabled: true, nrql: {query: "<golden errorRate NRQL, FACETed or WHERE-scoped to the service>"}, terms: [{operator: ABOVE, priority: WARNING, threshold: 1, thresholdDuration: 300, thresholdOccurrences: ALL}, {operator: ABOVE, priority: CRITICAL, threshold: 5, thresholdDuration: 300, thresholdOccurrences: ALL}], signal: {aggregationWindow: 60, aggregationMethod: EVENT_FLOW, aggregationDelay: 120}, violationTimeLimitSeconds: 259200}) { id } }
```

4. Verify: re-read the condition
   (`nrqlConditionsSearch` filtered by name → `jq -e '.enabled == true'`) AND,
   after the entity re-evaluates, `alertSeverity != "NOT_CONFIGURED"` on the
   covered entity.

Prefer `alertsNrqlConditionBaselineCreate`
(`baselineDirection: UPPER_AND_LOWER`) for seasonal signals instead of static
thresholds. Durations must be multiples of the aggregation window or the create
is rejected at apply time.

**Rollback**, in its own fresh shell: delete the condition with the id its
create returned, then its policy only when this setup created that policy and
nothing else is left in it, because a policy delete takes its conditions with
it (`alertsConditionDelete`, `alertsPolicyDelete`; introspect both before
first use). Any condition or policy the step 2 snapshot lists existed before
the setup, and the block refuses it:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
COND_ID="<condition-id>"     # id from the alertsNrqlConditionStaticCreate (or BaselineCreate) response
POLICY_ID="<policy-id>"      # the policyId that create used
POLICY_CREATED="no"          # yes only when this setup created that policy with alertsPolicyCreate
SNAPSHOT="<snapshot-path>"   # the "snapshot:" path step 2 printed before the creates
for v in "$COND_ID" "$POLICY_ID" "$SNAPSHOT"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
case "$POLICY_CREATED" in yes|no) ;; *) echo "POLICY_CREATED must be yes or no" >&2; exit 1 ;; esac
[ -s "$SNAPSHOT" ] || { echo "No snapshot at ${SNAPSHOT}" >&2; exit 1; }
jq -e '(.policies | type) == "array" and (.conditions | type) == "array"' "$SNAPSHOT" > /dev/null || { echo "${SNAPSHOT} is not an alerting snapshot" >&2; exit 1; }
if jq -e --arg id "$COND_ID" 'any(.conditions[]; . == $id)' "$SNAPSHOT" > /dev/null; then
  echo "condition ${COND_ID} is in the snapshot: it existed before this setup and stays" >&2; exit 1
fi
if [ "$POLICY_CREATED" = yes ] && jq -e --arg p "$POLICY_ID" 'any(.policies[]; . == $p)' "$SNAPSHOT" > /dev/null; then
  echo "policy ${POLICY_ID} is in the snapshot: it existed before this setup, so it stays" >&2; exit 1
fi
gql() { # gql <query> <variables-json>: one NerdGraph call
  jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' \
    | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
        -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @-
}
policy_conditions() { # every condition id left in POLICY_ID, one per line, across all pages
  _cur=null; _pages=0
  while :; do
    _r="$(gql 'query($a: Int!, $p: ID!, $c: String) { actor { account(id: $a) { alerts { nrqlConditionsSearch(cursor: $c, searchCriteria: {policyId: $p}) { nextCursor nrqlConditions { id } } } } } }' \
      "$(jq -n --argjson a "$NR_ACCT" --arg p "$POLICY_ID" --argjson c "$_cur" '{a: $a, p: $p, c: $c}')")"
    # A null account (a failed read) is not an empty policy: require an array.
    printf '%s' "$_r" | jq -e '.errors == null and (.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions | type == "array")' > /dev/null \
      || { echo "reading policy ${POLICY_ID} failed" >&2; return 1; }
    printf '%s' "$_r" | jq -r '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[].id'
    _cur="$(printf '%s' "$_r" | jq -c '.data.actor.account.alerts.nrqlConditionsSearch.nextCursor // null')"
    [ "$_cur" != null ] || return 0
    _pages=$((_pages + 1)); [ "$_pages" -lt 1000 ] || { echo "more than 1000 pages in policy ${POLICY_ID}" >&2; return 1; }
  done
}
gql 'mutation($a: Int!, $id: ID!) { alertsConditionDelete(accountId: $a, id: $id) { id } }' \
    "$(jq -n --argjson a "$NR_ACCT" --arg id "$COND_ID" '{a: $a, id: $id}')" \
  | jq -e --arg id "$COND_ID" '.errors == null and .data.alertsConditionDelete.id == $id' > /dev/null \
  || { echo "condition ${COND_ID}: delete failed" >&2; exit 1; }
REMAINING="$(policy_conditions)"
if printf '%s\n' "$REMAINING" | grep -qxF "$COND_ID"; then echo "condition ${COND_ID}: still in policy ${POLICY_ID}" >&2; exit 1; fi
echo "condition ${COND_ID}: deleted"
[ "$POLICY_CREATED" = yes ] || { echo "policy ${POLICY_ID}: existed before this setup, kept"; exit 0; }
[ -z "$REMAINING" ] || { echo "policy ${POLICY_ID}: still holds conditions, kept" >&2; exit 1; }
POLICY_VARS="$(jq -n --argjson a "$NR_ACCT" --arg p "$POLICY_ID" '{a: $a, p: $p}')"
gql 'mutation($a: Int!, $p: ID!) { alertsPolicyDelete(accountId: $a, id: $p) { id } }' "$POLICY_VARS" \
  | jq -e --arg p "$POLICY_ID" '.errors == null and .data.alertsPolicyDelete.id == $p' > /dev/null \
  || { echo "policy ${POLICY_ID}: delete failed" >&2; exit 1; }
gql 'query($a: Int!, $p: ID!) { actor { account(id: $a) { alerts { policiesSearch(searchCriteria: {ids: [$p]}) { policies { id } } } } } }' "$POLICY_VARS" \
  | jq -e '.errors == null and (.data.actor.account.alerts.policiesSearch.policies | type == "array" and length == 0)' > /dev/null \
  || { echo "policy ${POLICY_ID}: still present after the delete, or the re-read failed" >&2; exit 1; }
echo "policy ${POLICY_ID}: deleted"
```

Expected: `condition <id>: deleted`, then `policy <id>: ... kept` (or
`deleted` when `POLICY_CREATED=yes`, the snapshot does not list the policy,
and it was empty), exit 0.

## Fix condition tiering and evaluation settings

Fixes NR-020 (critical-only conditions) and NR-021 (delay/duration/occurrence
misconfiguration — including the documented charts-vs-alerts divergence when
`aggregationDelay` is below real data latency, and the sparse-signal stall:
signals with >65-minute gaps must move to `EVENT_TIMER`).

1. **Backup the exact condition body (read-before-write):**

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
COND_ID="<condition-id>"   # the condition you are about to change or delete
case "$COND_ID" in ''|'<'*) echo "Set COND_ID to the condition you are about to change" >&2; exit 1 ;; esac
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { alerts { nrqlConditionsSearch { nrqlConditions { id name enabled type policyId description runbookUrl violationTimeLimitSeconds nrql { query } terms { threshold thresholdDuration thresholdOccurrences operator priority } signal { aggregationWindow aggregationMethod aggregationDelay fillOption } expiration { expirationDuration openViolationOnExpiration closeViolationsOnExpiration } ... on AlertsNrqlBaselineCondition { baselineDirection } } } } } } }\"}" \
  | jq --arg id "$COND_ID" '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[] | select(.id == $id)' > "$BK/condition-${COND_ID}.json"
jq -e '.id' "$BK/condition-${COND_ID}.json" >/dev/null && echo "backup: $BK/condition-${COND_ID}.json"
```

2. Announce and apply `alertsNrqlConditionStaticUpdate(accountId:, id:,
   condition: {…})` (introspect the update input first — announce the
   introspected shape) carrying the corrected `terms`/`signal`.
3. Verify: re-read the condition and `jq -e` the exact fields you changed
   (`[.terms[].priority] | index("WARNING")`, `.signal.aggregationDelay >= <n>`,
   duration `% window == 0`).
4. **Restore pair (worked)**, in its own fresh shell: the same update
   mutation, its `condition` body built byte-for-byte from the backup:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
COND_ID="<condition-id>"   # the condition step 2 updated
BK_FILE="<backup-path>"    # the "backup:" path step 1 printed
for v in "$COND_ID" "$BK_FILE"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
# A missing, empty, or foreign backup would send an empty or wrong condition body.
[ -s "$BK_FILE" ] || { echo "No backup at ${BK_FILE}" >&2; exit 1; }
jq -e --arg id "$COND_ID" '.id == $id' "$BK_FILE" > /dev/null || { echo "${BK_FILE} is not a backup of condition ${COND_ID}" >&2; exit 1; }
RESTORE_VARS=$(jq --argjson acct "$NR_ACCT" --arg id "$COND_ID" \
  '{acct:$acct, id:$id, condition:{terms:.terms, signal:.signal, expiration:.expiration}}' "$BK_FILE")
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "$(jq -n --arg q 'mutation($acct: Int!, $id: ID!, $condition: AlertsNrqlConditionUpdateStaticInput!) { alertsNrqlConditionStaticUpdate(accountId: $acct, id: $id, condition: $condition) { id } }' --argjson v "$RESTORE_VARS" '{query:$q,variables:$v}')" \
  | jq -e '.data.alertsNrqlConditionStaticUpdate.id and (.errors == null)' > /dev/null \
  || { echo "alertsNrqlConditionStaticUpdate failed for ${COND_ID}" >&2; exit 1; }
# Verify by re-read in the condition's policy: the restored fields must equal the backup's.
VERIFY_VARS=$(jq --argjson acct "$NR_ACCT" '{acct:$acct, p:.policyId}' "$BK_FILE")
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "$(jq -n --arg q 'query($acct: Int!, $p: ID!) { actor { account(id: $acct) { alerts { nrqlConditionsSearch(searchCriteria: {policyId: $p}) { nrqlConditions { id terms { threshold thresholdDuration thresholdOccurrences operator priority } signal { aggregationWindow aggregationMethod aggregationDelay fillOption } expiration { expirationDuration openViolationOnExpiration closeViolationsOnExpiration } } } } } } }' --argjson v "$VERIFY_VARS" '{query:$q,variables:$v}')" \
  | jq -e --arg id "$COND_ID" --slurpfile b "$BK_FILE" '[.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[] | select(.id == $id)]
      | length == 1 and (.[0] | {terms, signal, expiration}) == ($b[0] | {terms, signal, expiration})' > /dev/null \
  || { echo "condition ${COND_ID} does not match ${BK_FILE} after the restore" >&2; exit 1; }
echo "restored: condition ${COND_ID} from ${BK_FILE}"
```

   Expected: `restored: condition <id> from <backup-path>` and exit 0.

## Set loss-of-signal handling

Fixes NR-022. A presence-style condition (BELOW/canary) with
`openViolationOnExpiration: false` closes incidents when the signal disappears
— the exact outage it exists to catch mutes it. Backup the condition body (the
worked pair above), then update `expiration: {expirationDuration: <s>,
openViolationOnExpiration: true, closeViolationsOnExpiration: false}` on the
canary; verify by re-read (`jq -e '.expiration.openViolationOnExpiration ==
true'`). Where a signal legitimately stops (batch jobs), leave close-on-expiry
and record why.

## Retire dead-weight conditions

Fixes NR-023. A disabled condition is not coverage — delete it or re-enable it
deliberately. **Backup the full condition body first** (the worked pair above —
the restore for a delete is re-creating from that exact backup via
`alertsNrqlConditionStaticCreate`), then `alertsConditionDelete(accountId:,
id:)` (introspect first). Verify: `nrqlConditionsSearch` no longer returns the
id.

**Restore**, in its own fresh shell: re-create the condition in its original
policy from the backup, with `alertsNrqlConditionStaticCreate`, or
`alertsNrqlConditionBaselineCreate` for a baseline condition:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
BK_FILE="<backup-path>"   # the "backup:" path the tiering section's step 1 printed for the deleted condition
case "$BK_FILE" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac
[ -s "$BK_FILE" ] || { echo "No backup at ${BK_FILE}" >&2; exit 1; }
jq -e '.id and .policyId and .nrql.query' "$BK_FILE" > /dev/null || { echo "${BK_FILE} is not a condition backup" >&2; exit 1; }
case "$(jq -r '.type' "$BK_FILE")" in
  STATIC) CREATE="alertsNrqlConditionStaticCreate"; INPUT="AlertsNrqlConditionStaticInput" ;;
  BASELINE) CREATE="alertsNrqlConditionBaselineCreate"; INPUT="AlertsNrqlConditionBaselineInput" ;;
  *) echo "Only STATIC and BASELINE conditions re-create from this backup" >&2; exit 1 ;;
esac
VARS="$(jq --argjson acct "$NR_ACCT" '{acct: $acct, p: .policyId,
  c: ({name, enabled, nrql: {query: .nrql.query}, terms, signal, expiration, description, runbookUrl, violationTimeLimitSeconds}
      + (if .type == "BASELINE" then {baselineDirection} else {} end))}' "$BK_FILE")"
RESP="$(curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "$(jq -n --arg q "mutation(\$acct: Int!, \$p: ID!, \$c: ${INPUT}!) { r: ${CREATE}(accountId: \$acct, policyId: \$p, condition: \$c) { id } }" --argjson v "$VARS" '{query:$q,variables:$v}')")"
NEW_ID="$(printf '%s' "$RESP" | jq -er 'select(.errors == null) | .data.r.id')" \
  || { echo "${CREATE} failed: $(printf '%s' "$RESP" | jq -c '.errors' 2>/dev/null)" >&2; exit 1; }
echo "restored as condition: ${NEW_ID}"
# Verify by re-read: every backed-up field except the id must match the re-created condition.
VERIFY_VARS=$(jq --argjson acct "$NR_ACCT" '{acct:$acct, p:.policyId}' "$BK_FILE")
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
  -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "$(jq -n --arg q 'query($acct: Int!, $p: ID!) { actor { account(id: $acct) { alerts { nrqlConditionsSearch(searchCriteria: {policyId: $p}) { nrqlConditions { id name enabled type policyId description runbookUrl violationTimeLimitSeconds nrql { query } terms { threshold thresholdDuration thresholdOccurrences operator priority } signal { aggregationWindow aggregationMethod aggregationDelay fillOption } expiration { expirationDuration openViolationOnExpiration closeViolationsOnExpiration } ... on AlertsNrqlBaselineCondition { baselineDirection } } } } } } }' --argjson v "$VERIFY_VARS" '{query:$q,variables:$v}')" \
  | jq -e --arg id "$NEW_ID" --slurpfile b "$BK_FILE" '[.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[] | select(.id == $id)]
      | length == 1 and (.[0] as $live | $b[0] | del(.id) | to_entries | all(.[]; $live[.key] == .value))' > /dev/null \
  || { echo "condition ${NEW_ID} does not match ${BK_FILE}" >&2; exit 1; }
echo "verified: condition ${NEW_ID} matches ${BK_FILE}"
```

Expected: `restored as condition: <new-id>`, then `verified: ...`, exit 0.
The condition comes back under a new id; record it in the change record.

## Tune chronic and noisy conditions

Fixes NR-025 (opens with no closes; top-noisy conditions). A chronic condition
usually has its threshold below the signal's steady-state floor — raise the
threshold above the floor (or convert to a baseline condition) so it can
recover and re-alert on genuine change. Backup + update + verify exactly per
the tiering section's worked pair; then confirm against fire-history: the open
incident closes and subsequent `NrAiIncident` opens pair with closes.

## Set incident preference deliberately

Fixes NR-026. `PER_POLICY` on a many-condition policy over-groups (one open
incident masks the next failure); `PER_CONDITION_AND_TARGET` on a wide-facet
condition fans out per target. Announce `alertsPolicyUpdate(accountId:, id:,
policy: {incidentPreference: <choice>})` (introspect first) with the reasoning
(condition count and facet width), verify by re-reading `policiesSearch`.

## Schedule or disable muting rules

Fixes NR-024. An ENABLED muting rule without a schedule/end is a silent blind
spot. Either disable it (`alertsMutingRuleUpdate` with `enabled: false`) or
bound it — `schedule: {startTime:, endTime:, timeZone:, repeat:, endRepeat:}`
(create live-verified; the schedule reads back with timezone offsets). Backup:
capture the rule from `mutingRules` first; verify by re-read of
`schedule`/`enabled`.

## Fix ingest at the source

Fixes NR-004/NR-005/NR-006 and the NROPT items — these are **not** NerdGraph
mutations; the fix lives at the emitting side and this section only names it:

- Delta-conversion anomalies → set
  `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta` in the emitting
  SDKs (never add a `cumulativetodelta` collector processor — the platform
  converts server-side).
- Stale-span rejections → fix clock skew / batching delay at the collector
  (spans older than 20 minutes are silently dropped).
- Attribute truncation and cardinality → trim attributes at the collector;
  NR-side metric normalization rules are the platform lever.
- Budget → collector filter/sampler processors are the only layer you control
  on every plan; legacy drop rules are dead for new accounts and the successor
  is permission-gated.

Verification for every item is the same read: the relevant
`NrIntegrationError` facet count stops growing.

## Add SLOs

Fixes NR-040. `serviceLevelCreate` (live-verified) on the service's entity guid
with valid/good NRQL events and a rolling window. **Expect the platform side
effect**: creating an SLO auto-spawns the "Service Levels default policy" WITH
an enabled error-budget condition that no workflow catches — immediately follow
with the wire-or-disable choice from the workflow section, or the new SLO's
breaches notify nobody. Verify: a SERVICE_LEVEL entity exists for the service
and (if wired) its policy is caught.

## Add ownership tags

Fixes NR-035. **Backup the entity's tags first (read-before-write), run as
written:**

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
ENTITY_GUID="<entity-guid>"   # the entity you are about to tag, from the NR-035 finding
case "$ENTITY_GUID" in ''|'<'*) echo "Set ENTITY_GUID to the entity you are about to tag" >&2; exit 1 ;; esac
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
jq -n --arg q 'query($g: EntityGuid!) { actor { entity(guid: $g) { guid tags { key values } } } }' --arg g "$ENTITY_GUID" '{query:$q,variables:{g:$g}}' \
  | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @- \
  | jq '.data.actor.entity' > "$BK/entity-tags.json"
jq -e --arg g "$ENTITY_GUID" '.guid == $g' "$BK/entity-tags.json" > /dev/null && echo "backup: $BK/entity-tags.json"
```

Then announce and apply `taggingAddTagsToEntity(guid:, tags: [{key: "team",
values: ["<team>"]}, {key: "environment", values: ["<env>"]}])`
(live-verified). Verify: re-read the entity's `tags` and `jq -e` the keys.

**Rollback**, in its own fresh shell: remove only the values the add
introduced, with `taggingDeleteTagValuesFromEntity` (introspect it before
first use). Deleting the whole key would also drop values your team set
before the setup, so a value the backup already lists stays:

```bash
set -eu
# Self-resolve target + key (fresh shell; nothing carries over from earlier blocks).
CFG="${SCOUTFLO_CONFIG:-}"; [ -n "$CFG" ] || for _c in "./.scoutflo/toolkit.yaml" "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$_c" ] && { CFG="$_c"; break; }; done; [ -n "$CFG" ] || CFG="$HOME/.scoutflo/toolkit.yaml"
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"; [ -n "$SCOUTFLO_ENV" ] || { if [ -f "./.scoutflo/env" ]; then SCOUTFLO_ENV="./.scoutflo/env"; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
[ -f "$SCOUTFLO_ENV" ] && . "$SCOUTFLO_ENV" || true
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
NR_KIND=$(sh "$TT" "$CFG" newrelic kind); NR_N=$(sh "$TT" "$CFG" newrelic count)
[ "$NR_KIND" != seq ] || [ -n "${SCOUTFLO_TARGET:-}" ] || { echo "newrelic in $CFG is a labeled list; set SCOUTFLO_TARGET to one of: $(sh "$TT" "$CFG" newrelic labels | tr '\n' ' ')"; exit 1; }
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
[ -z "${SCOUTFLO_TARGET:-}" ] || [ "$(sh "$TT" "$CFG" newrelic label "$NR_IDX")" = "$SCOUTFLO_TARGET" ] || { echo "SCOUTFLO_TARGET=${SCOUTFLO_TARGET} matches no newrelic target in $CFG"; exit 1; }
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set; run the doctor gate first"; exit 1; }
ENTITY_GUID="<entity-guid>"      # the entity the add mutation tagged
TAGS_BACKUP="<backup-path>"      # the "backup:" path the block above printed
ADDED_TAGS="<key>=<value>"       # the pairs the add mutation set, ;-separated, e.g. team=payments;environment=production
for v in "$ENTITY_GUID" "$TAGS_BACKUP" "$ADDED_TAGS"; do case "$v" in ''|'<'*) echo "Fill in every <...> value from the change record first" >&2; exit 1 ;; esac; done
[ -s "$TAGS_BACKUP" ] || { echo "No backup at ${TAGS_BACKUP}" >&2; exit 1; }
jq -e --arg g "$ENTITY_GUID" '.guid == $g' "$TAGS_BACKUP" > /dev/null || { echo "${TAGS_BACKUP} is not a tag backup of ${ENTITY_GUID}" >&2; exit 1; }
gql() { # gql <query> <variables-json>: one NerdGraph call
  jq -n --arg q "$1" --argjson v "$2" '{query: $q, variables: $v}' \
    | curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" \
        -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" --data @-
}
# The added pairs minus every pair the backup already holds.
REMOVE="$(jq -c --arg s "$ADDED_TAGS" '(.tags // []) as $before
  | [$s | split(";")[] | select(length > 0) | (index("=") // error("each entry must be key=value")) as $i | {key: .[:$i], value: .[$i+1:]}]
  | map(. as $t | select(any($before[]; .key == $t.key and any(.values[]; . == $t.value)) | not))' "$TAGS_BACKUP")"
printf '%s' "$REMOVE" | jq -r '.[] | "removing: \(.key)=\(.value)"'
if [ "$(printf '%s' "$REMOVE" | jq 'length')" -gt 0 ]; then
  gql 'mutation($g: EntityGuid!, $tv: [TaggingTagValueInput!]!) { taggingDeleteTagValuesFromEntity(guid: $g, tagValues: $tv) { errors { message } } }' \
      "$(jq -n --arg g "$ENTITY_GUID" --argjson tv "$REMOVE" '{g: $g, tv: $tv}')" \
    | jq -e '.errors == null and ((.data.taggingDeleteTagValuesFromEntity.errors // []) | length == 0)' > /dev/null \
    || { echo "taggingDeleteTagValuesFromEntity failed for ${ENTITY_GUID}" >&2; exit 1; }
fi
# Verify by re-read: every key the add touched holds exactly its backed-up values. Tags can take a few seconds to settle.
for _try in 1 2 3; do
  if gql 'query($g: EntityGuid!) { actor { entity(guid: $g) { tags { key values } } } }' "$(jq -n --arg g "$ENTITY_GUID" '{g: $g}')" \
    | jq -e --arg s "$ADDED_TAGS" --slurpfile b "$TAGS_BACKUP" '.errors == null and (.data.actor.entity.tags | type == "array")
        and (.data.actor.entity.tags as $now | ($b[0].tags // []) as $before
        | [$s | split(";")[] | select(length > 0) | .[:index("=")]] | unique
        | all(.[]; . as $k | ([$now[] | select(.key == $k) | .values[]] | sort) == ([$before[] | select(.key == $k) | .values[]] | sort)))' > /dev/null
  then echo "restored: tags on ${ENTITY_GUID} match ${TAGS_BACKUP}"; exit 0; fi
  sleep 5
done
echo "tags on ${ENTITY_GUID} still differ from ${TAGS_BACKUP}" >&2; exit 1
```

Expected: one `removing:` line per value the add introduced, then
`restored: ...` and exit 0.

## Add synthetic monitors

Fixes NR-034. `syntheticsCreateSimpleMonitor` (live-verified) per public
endpoint — nearest public location, `EVERY_15_MINUTES` as the starting cadence
(example, tune to the endpoint's importance). Verify: the first
`SyntheticCheck` result row arrives with `result = "SUCCESS"`; a failing first
check is evidence about the endpoint, not a reason to delete the monitor.

## Wire change tracking

Fixes NR-042. `changeTrackingCreateDeployment(deployment: {version:,
entityGuid:})` (live-verified) belongs in the deploy pipeline, not in this
session — announce the pipeline change (the one CLI/API call at deploy time),
apply it in the pipeline config, and verify the next deploy emits a queryable
`Deployment` event.

## Change record

Append one line per applied change to
`${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/setup-changes.jsonl`: the
date, section, object id, mutation name, verification evidence (the `jq -e`
that passed), backup path, and rollback status. The record is what makes a
later "who changed this condition" answerable — and re-running
`/scoutflo:audit-newrelic` after a session is the final verification that the
findings the plan targeted are resolved.

## Common Failure Modes

| Failure | Prevention |
| --- | --- |
| Channel created without `product: IINT` | The workflow silently cannot use it; always set IINT on notification channels |
| A channel reused across two workflows | One channel per workflow — create a second channel on the same destination instead |
| The mutation "succeeded" but nothing changed | Check BOTH error surfaces: top-level GraphQL `errors[]` AND the payload's `errors`/`error` block — NerdGraph is inconsistent per mutation |
| Update input guessed from docs | Docs drift behind the live schema; introspect the input type and announce the introspected shape |
| Condition create rejected at apply time | `thresholdDuration` must be a multiple of `aggregationWindow`; fix the numbers, not the retry count |
| SLO created and declared done | The auto-spawned default policy carries an enabled, uncaught error-budget condition — wire-or-disable it in the same session |
| Webhook destination retried until accepted | Creation is domain-validated; a rejection means the endpoint is wrong — fix the URL, never brute-force |
| Slack destination attempted by API | OAuth-only; name the UI step and record it as a pending item with an owner |
| Deleting a condition with no backup | The restore for a delete is re-creating from the byte-exact backup; no backup, no delete |
| Rollback removes something that existed before the setup | Run the rollback blocks as written: they keep any id the pre-change backup or snapshot lists (both read across every page), refuse a condition or policy the snapshot lists, delete a policy only when it is empty, and remove only the tag values the add introduced, never the whole key |
| Loss-of-signal flipped everywhere | open-on-expiry on a batch job's condition pages nightly at completion; judge per signal, record the deliberate exceptions |
| Fixing noise by muting | An open-ended mute is the blind spot NR-024 exists to catch; tune the condition instead, or bound the mute with a schedule |
| Mid-batch failure papered over | Stop at the failed row, record applied rows + backups, re-announce the remainder — the old approval is void |
