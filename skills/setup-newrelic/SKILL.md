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
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
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
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_LABEL=$(sh "$TT" "$CFG" newrelic label "$NR_IDX"); NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"; export NEW_RELIC_USER_KEY
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
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { aiWorkflows { workflows { entities { id name workflowEnabled destinationConfigurations { channelId } issuesFilter { predicates { attribute operator values } } } } } aiNotifications { destinations { entities { id name type active } } channels { entities { id name destinationId } } } } } }\"}" \
  | jq '.data.actor.account' > "$BK/notification-plane.json"
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

4. **Rollback (worked pair):** delete in reverse order with the ids the creates
   returned — `aiWorkflowsDeleteWorkflow(id:)`,
   `aiNotificationsDeleteChannel(channelId:)`,
   `aiNotificationsDeleteDestination(destinationId:)` (introspect each delete
   input before first use); the backup file holds the pre-change state to
   compare against after rollback.

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
2. Announce the condition (both terms; example thresholds — tune to the
   signal's real floor):

```
mutation { alertsNrqlConditionStaticCreate(accountId: <acct>, policyId: "<policy-id>", condition: {name: "<service> error rate", enabled: true, nrql: {query: "<golden errorRate NRQL, FACETed or WHERE-scoped to the service>"}, terms: [{operator: ABOVE, priority: WARNING, threshold: 1, thresholdDuration: 300, thresholdOccurrences: ALL}, {operator: ABOVE, priority: CRITICAL, threshold: 5, thresholdDuration: 300, thresholdOccurrences: ALL}], signal: {aggregationWindow: 60, aggregationMethod: EVENT_FLOW, aggregationDelay: 120}, violationTimeLimitSeconds: 259200}) { id } }
```

3. Verify: re-read the condition
   (`nrqlConditionsSearch` filtered by name → `jq -e '.enabled == true'`) AND,
   after the entity re-evaluates, `alertSeverity != "NOT_CONFIGURED"` on the
   covered entity. Rollback: `alertsConditionDelete(accountId:, id:)`
   (introspect first).

Prefer `alertsNrqlConditionBaselineCreate`
(`baselineDirection: UPPER_AND_LOWER`) for seasonal signals instead of static
thresholds. Durations must be multiples of the aggregation window or the create
is rejected at apply time.

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
NR_IDX=0; if [ -n "${SCOUTFLO_TARGET:-}" ]; then _i=0; while [ "$_i" -lt "$NR_N" ]; do [ "$(sh "$TT" "$CFG" newrelic label "$_i")" = "$SCOUTFLO_TARGET" ] && { NR_IDX=$_i; break; }; _i=$((_i+1)); done; fi
NR_ACCT=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" account_id)
NR_REGION=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" region); NR_REGION="${NR_REGION:-US}"
case "$NR_REGION" in US|us) NR_API_HOST="api.newrelic.com" ;; EU|eu) NR_API_HOST="api.eu.newrelic.com" ;; esac
NR_KEY_VAR=$(sh "$TT" "$CFG" newrelic get "$NR_IDX" api_key_env); NR_KEY_VAR="${NR_KEY_VAR:-NEW_RELIC_USER_API_KEY}"
NEW_RELIC_USER_KEY="$(printenv "$NR_KEY_VAR" 2>/dev/null || true)"
[ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "${NR_KEY_VAR} is not set — run the doctor gate first"; exit 1; }
BK="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/newrelic/backups/$(date +%Y%m%dT%H%M%S)"; mkdir -p "$BK"
curl -sS --max-time 30 -X POST "https://${NR_API_HOST}/graphql" -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
  --data "{\"query\":\"{ actor { account(id: ${NR_ACCT}) { alerts { nrqlConditionsSearch { nrqlConditions { id name enabled type policyId nrql { query } terms { threshold thresholdDuration thresholdOccurrences operator priority } signal { aggregationWindow aggregationMethod aggregationDelay fillOption } expiration { expirationDuration openViolationOnExpiration closeViolationsOnExpiration } } } } } } }\"}" \
  | jq --arg id "<condition-id>" '.data.actor.account.alerts.nrqlConditionsSearch.nrqlConditions[] | select(.id == $id)' > "$BK/condition-<condition-id>.json"
jq -e '.id' "$BK/condition-<condition-id>.json" >/dev/null && echo "backup: $BK/condition-<condition-id>.json"
```

2. Announce and apply `alertsNrqlConditionStaticUpdate(accountId:, id:,
   condition: {…})` (introspect the update input first — announce the
   introspected shape) carrying the corrected `terms`/`signal`.
3. Verify: re-read the condition and `jq -e` the exact fields you changed
   (`[.terms[].priority] | index("WARNING")`, `.signal.aggregationDelay >= <n>`,
   duration `% window == 0`).
4. **Restore pair:** the same update mutation with the backed-up body's values,
   taken byte-for-byte from `$BK/condition-<condition-id>.json`.

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

Fixes NR-035. `taggingAddTagsToEntity(guid:, tags: [{key: "team", values:
["<team>"]}, {key: "environment", values: ["<env>"]}])` (live-verified).
Verify: re-read the entity's `tags` and `jq -e` the keys. Rollback:
`taggingDeleteTagKeys(guid:, tagKeys:)` (introspect first).

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
| Loss-of-signal flipped everywhere | open-on-expiry on a batch job's condition pages nightly at completion; judge per signal, record the deliberate exceptions |
| Fixing noise by muting | An open-ended mute is the blind spot NR-024 exists to catch; tune the condition instead, or bound the mute with a schedule |
| Mid-batch failure papered over | Stop at the failed row, record applied rows + backups, re-announce the remainder — the old approval is void |
