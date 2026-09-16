# New Relic audit — check catalog and cookbook

Lookup material for the `audit-newrelic` workflow. The workflow itself lives in
[SKILL.md](../SKILL.md). Every call below is **read-only**: NerdGraph `query`
documents only, sent as a documented read-by-POST (a GraphQL query body creates
nothing). GraphQL **mutations are forbidden in their entirety** — see section 13.
Classify by effect, not verb: this surface has exactly one POST endpoint
(`/graphql`), and the query/mutation split inside the document is what separates a
read from a write.

## 1. Read surface and auth

- One endpoint per region: `https://api.newrelic.com/graphql` (US) or
  `https://api.eu.newrelic.com/graphql` (EU). The region is chosen at account
  creation; `newrelic.region` in toolkit.yaml selects the host.
- Auth: a **User API key** sent as the `API-Key` header. A missing and an invalid
  key are **indistinguishable** — both return HTTP 401 with body
  `{"errors":[{"message":"authentication required"}]}` (confirmed live). A valid
  key on the wrong region's endpoint returns HTTP 403 with
  `"not authorized for account region"` — a distinct, diagnosable state.
- The User key authorizes NerdGraph reads; the account's ingest (license) keys are
  a different key family this audit never needs and never reads back.
- Every response is JSON. Assert it: a 200 whose body is not JSON with the
  expected `data` path is a proxy/SPA fall-through and fails closed.
- NerdGraph allows **25 concurrent requests per user** — this audit is sequential,
  so it never approaches the limit; do not parallelize the pull.

Shared helper used by every block below (define once per shell):

```bash
# nrq '<graphql query>' -> prints the JSON body; fails closed on non-200/non-JSON.
# The query string is a *query* document only. $NR_API_HOST and the key variable
# are resolved by the doctor gate. Read-only by construction.
nrq() {
  # Never send an empty auth header: a named-but-unset key variable stops here.
  [ -n "${NEW_RELIC_USER_KEY:-}" ] || { echo "NEW_RELIC_USER_KEY is not set — run the doctor gate first" >&2; return 1; }
  _b="$(mktemp)"
  _m="$(curl -s -o "$_b" -w '%{http_code} %{content_type}' --max-time 30 \
    -X POST "https://${NR_API_HOST}/graphql" \
    -H 'Content-Type: application/json' -H "API-Key: ${NEW_RELIC_USER_KEY}" \
    --data "$(jq -n --arg q "$1" '{query:$q}')")" || { rm -f "$_b"; echo "transport error" >&2; return 1; }
  _c="${_m%% *}"; _ct="${_m#* }"
  case "$1" in mutation*|*" mutation "*) rm -f "$_b"; echo "FORBIDDEN: mutation document" >&2; return 1;; esac
  [ "$_c" = "200" ] && printf '%s' "$_ct" | grep -qi json && jq -e '.data' "$_b" >/dev/null 2>&1 \
    || { echo "nrq failed: HTTP ${_c} content-type=${_ct} $(jq -r '.errors[0].message // empty' "$_b" 2>/dev/null)" >&2; rm -f "$_b"; return 1; }
  cat "$_b"; rm -f "$_b"
}
# nrql '<NRQL>' -> the .results array of an account-scoped NRQL read.
nrql() {
  nrq "query { actor { account(id: ${NR_ACCT}) { nrql(query: \"$1\") { results } } } }" \
    | jq '.data.actor.account.nrql.results'
}
```

## 2. Check catalog

One permanent ID per check. IDs never change or get reused; retired checks keep
their number.

| ID | Category | Check | Typical fail severity |
| --- | --- | --- | --- |
| NR-001 | Reachability and data health | NerdGraph reachable on the configured region host with a valid User key (`actor.user` resolves, 200+JSON); 401 = key missing/invalid (one state), 403 `account region` = wrong region host | critical |
| NR-002 | Reachability and data health | The configured `account_id` is accessible to this key (`actor.account(id:)` returns it; `actor.accounts` names what the key CAN see for remediation) | critical |
| NR-003 | Reachability and data health | Ingest is alive: `SHOW EVENT TYPES` returns telemetry types and a recent Span/Metric count is non-zero — zero everything routes to the empty/hidden-scope guardrail, never a confident fail | high |
| NR-004 | Reachability and data health | `NrIntegrationError` is clean over the window — NR documents that HTTP 200 can still mean dropped/mangled data (stale >20-min spans rejected, oversize attributes truncated, cumulative→delta conversion anomalies); this event type is the only visibility | high |
| NR-005 | Reachability and data health | Metric cardinality below the rollup cutoff — >100k unique series per metric name/day silently stops rollups so >60-min charts break while ingest continues; cardinality-limit NrIntegrationErrors are the breach evidence | medium |
| NR-006 | Reachability and data health | Ingest concentration understood: `bytecountestimate()` per signal type, ranked — a surprise-heavy source (unfiltered logs, cluster-wide metrics) is a budget risk; on a free-tier account the 100GB hard lockout is the ceiling | medium |
| NR-010 | Alert delivery | Enabled alert conditions exist on a producing estate (entities + telemetry present but zero enabled conditions = an unwatched estate) | critical |
| NR-011 | Alert delivery | Every policy that has enabled conditions is caught by an enabled workflow (issuesFilter on `labels.policyIds`, or a catch-all `predicates: []`); the auto-created "Service Levels default policy" arrives WITH an enabled error-budget condition and no workflow (live-verified) — reported at MEDIUM naming the platform behavior, never suppressed and never critical | critical (medium for the platform artifact) |
| NR-012 | Alert delivery | Workflow → channel → destination linkage intact: workflow `destinationsEnabled`, channel exists, channel's `destinationId` resolves, destination `active: true` | high |
| NR-013 | Alert delivery | Destination posture honest: types inventoried; `active` is configuration, not proof of delivery — delivery is `configured`, upgraded to `validated-live` only by an observed notification; webhook destinations are domain-validated at create but can rot after | medium |
| NR-014 | Alert delivery | Flagship: the per-critical-service paging path — service entity → an enabled condition whose NRQL covers it → policy → enabled workflow → active destination; assembled end-to-end, cited link by link | critical |
| NR-020 | Alert noise | Paging conditions carry both WARNING and CRITICAL terms (a critical-only condition gives no early tier) | medium |
| NR-021 | Alert noise | Evaluation sanity: `thresholdDuration` a multiple of `aggregationWindow`; `thresholdOccurrences: ALL` on volatile signals; `aggregationDelay` ≥ real data latency (late points are excluded from streaming evaluation FOREVER — charts-vs-alerts divergence is documented behavior); a signal with >65-min gaps on EVENT_FLOW stalls and must use EVENT_TIMER | high |
| NR-022 | Alert noise | Loss-of-signal posture: presence/traffic-canary conditions carry an `expiration` block with a deliberate `openViolationOnExpiration` | medium |
| NR-023 | Alert noise | No disabled condition counted as coverage (`enabled: false` = dead weight — delete or re-enable, never park) | medium |
| NR-024 | Alert noise | Muting hygiene: no ENABLED muting rule without a schedule/end (an open-ended active mute is a silent blind spot); disabled rules and schedule-bound windows are fine | high |
| NR-025 | Alert noise | Measured fire-history: `NrAiIncident` over the window — chronic opens (open with no close), top-noisy conditions by open count, and incidents opened while `muted: true`; feeds the alert-fatigue roll-up | high |
| NR-026 | Alert noise | `incidentPreference` deliberate per policy: PER_POLICY on a many-condition policy over-groups (one incident hides N failures); PER_CONDITION_AND_TARGET on a wide policy is a fan-out storm risk | low |
| NR-030 | Coverage and topology | Alertable entities with `alertSeverity: NOT_CONFIGURED` — the zero-coverage signal; escalated when the entity backs a critical service | high |
| NR-031 | Coverage and topology | Critical services present as entities AND recently reporting — an EXT entity expires from the UI after 8 idle days (telemetry stays in NRDB), so an expected-but-absent service is either dead telemetry or expiry | high |
| NR-032 | Coverage and topology | Service topology present: `relatedEntities` CALLS edges exist for core services (NR synthesizes the service map from spans; missing edges = no blast-radius context) | medium |
| NR-033 | Coverage and topology | Golden signals resolvable: each critical entity's `goldenMetrics` NRQL returns data (ready-made throughput/errorRate/latency queries — cite them, never author parallel ones) | medium |
| NR-034 | Coverage and topology | Synthetics coverage and health: monitors exist for the public endpoints; recent `SyntheticCheck` results are SUCCESS; a disabled/failing monitor is named | medium |
| NR-035 | Coverage and topology | Ownership tags (`team`, `environment`) on key entities — untagged entities cannot route or be excluded by business context | low |
| NR-040 | SLO and dashboards | SLOs defined for critical services (SERVICE_LEVEL entities exist and target them); creating an SLO auto-spawns the "Service Levels default policy" — expected, not a finding | medium |
| NR-041 | SLO and dashboards | Dashboards exist and cover the golden signals; entity counting de-dups page entities (a one-page dashboard = 2 DASHBOARD entities) | low |
| NR-042 | SLO and dashboards | Change tracking wired: `Deployment` events exist (deployment markers give incident RCA its change context) | low |

Cost & ingest (non-scored, `NROPT-NNN`, `points_recoverable: 0`): ingest ranked by
source and cap proximity, plus retention/E2M opportunities. Sourced only from the
account's own NRQL/consumption reads; see section 11.

## 3. Target profile

Works against any New Relic account (free or paid tier, US or EU region) with a
User API key. OTel-instrumented estates surface services as `domain = 'EXT'` /
`THIRD_PARTY_SERVICE_ENTITY`; NR-agent estates as `domain = 'APM'`. Coverage
checks query BOTH domains — an audit that queries only APM on an OTel estate sees
zero services (a live-caught design correction, not a hypothetical).

**What 100/100 looks like, per scorecard category** (the benchmark the score
measures distance from — every threshold below is an example to tune):

- **Reachability and data health (100):** the key resolves the configured account
  on the right region host; every expected signal type is arriving;
  `NrIntegrationError` is empty over the window (no silent rejections,
  truncations, or conversion anomalies); no metric family approaches the
  cardinality rollup cutoff; ingest is understood and deliberately budgeted
  (no surprise-dominant source, no unplanned cap proximity).
- **Alert delivery (100):** every policy with enabled conditions is caught by an
  enabled workflow; every workflow's channel resolves to an `active` destination;
  each critical service has a complete, live-verified paging path (entity →
  covering condition → policy → workflow → destination) — and the SLO default
  policy's error-budget condition has been deliberately wired or disabled.
- **Alert noise (100):** paging conditions carry WARNING and CRITICAL terms;
  evaluation settings match the data (delay ≥ latency, durations are window
  multiples, sparse signals on EVENT_TIMER); presence-style conditions carry
  loss-of-signal expiration; zero disabled conditions parked as coverage; every
  ENABLED muting rule is schedule-bound; fire-history shows no chronic opens and
  no fires-while-muted; incidentPreference is deliberate per policy.
- **Coverage and topology (100):** zero alertable entities at
  `alertSeverity: NOT_CONFIGURED` among services that matter; every critical
  service present and reporting; CALLS edges exist for core call paths; golden
  metrics resolve with data; public endpoints have healthy synthetics; key
  entities carry `team`/`environment` tags.
- **SLO and dashboards (100):** each critical service has an SLO; golden-signal
  dashboards exist; deployment markers flow from the deploy pipeline.

## 4. Raw pull (one pass; every later check reads these files)

```bash
set -eu
RAW_DIR="$(mktemp -d)"; export RAW_DIR
# Policies (id, name, incidentPreference)
nrq "query { actor { account(id: ${NR_ACCT}) { alerts { policiesSearch { totalCount policies { id name incidentPreference } } } } } }" \
  | jq '.data.actor.account.alerts.policiesSearch' > "${RAW_DIR}/policies.json"
# Conditions with the full noise-control field set (terms/signal/expiration; type covers static+baseline)
nrq "query { actor { account(id: ${NR_ACCT}) { alerts { nrqlConditionsSearch { totalCount nrqlConditions { id name enabled type policyId nrql { query } terms { threshold thresholdDuration thresholdOccurrences operator priority } signal { aggregationWindow aggregationMethod aggregationDelay fillOption } expiration { expirationDuration openViolationOnExpiration closeViolationsOnExpiration } } } } } } }" \
  | jq '.data.actor.account.alerts.nrqlConditionsSearch' > "${RAW_DIR}/conditions.json"
# Workflows (filter predicates + destination configurations)
nrq "query { actor { account(id: ${NR_ACCT}) { aiWorkflows { workflows { totalCount entities { id name workflowEnabled destinationsEnabled issuesFilter { predicates { attribute operator values } } destinationConfigurations { channelId notificationTriggers } } } } } } }" \
  | jq '.data.actor.account.aiWorkflows.workflows' > "${RAW_DIR}/workflows.json"
# Destinations + channels (the delivery plane)
nrq "query { actor { account(id: ${NR_ACCT}) { aiNotifications { destinations { entities { id name type active } } channels { entities { id name type destinationId } } } } } }" \
  | jq '.data.actor.account.aiNotifications' > "${RAW_DIR}/notifications.json"
# Muting rules incl. schedule (schedule: null = no schedule)
nrq "query { actor { account(id: ${NR_ACCT}) { alerts { mutingRules { id name enabled schedule { startTime endTime timeZone repeat repeatCount endRepeat } } } } } }" \
  | jq '.data.actor.account.alerts.mutingRules' > "${RAW_DIR}/muting.json"
# Entities: OTel (EXT) + NR-agent (APM) services, synthetics, SLOs, dashboards — paginated
for q in "domain = 'EXT'" "domain = 'APM'" "domain = 'SYNTH'" "type = 'SERVICE_LEVEL'" "type = 'DASHBOARD'"; do
  slug="$(printf '%s' "$q" | tr -cd 'A-Za-z_' | tr 'A-Z' 'a-z')"
  CURSOR=""; : > "${RAW_DIR}/entities-${slug}.jsonl"; PAGE=0
  while [ "$PAGE" -lt 20 ]; do
    if [ -n "$CURSOR" ]; then CUR_ARG="(cursor: \\\"${CURSOR}\\\")"; else CUR_ARG=""; fi
    OUT="$(nrq "query { actor { entitySearch(query: \"$q\") { count results${CUR_ARG} { nextCursor entities { guid name entityType alertSeverity tags { key values } } } } } }")"
    printf '%s' "$OUT" | jq -c '.data.actor.entitySearch.results.entities[]?' >> "${RAW_DIR}/entities-${slug}.jsonl"
    CURSOR="$(printf '%s' "$OUT" | jq -r '.data.actor.entitySearch.results.nextCursor // empty')"
    [ -n "$CURSOR" ] || break; PAGE=$((PAGE+1))
  done
done
# NRQL data-plane reads (fire-history, rejection visibility, ingest, change tracking)
nrql "SHOW EVENT TYPES SINCE 1 day ago"                                                              > "${RAW_DIR}/event-types.json"
nrql "SELECT count(*) FROM NrIntegrationError FACET category, message SINCE 1 day ago LIMIT 20"     > "${RAW_DIR}/integration-errors.json"
nrql "SELECT count(*) FROM NrAiIncident FACET conditionName, event SINCE 7 days ago LIMIT 50"       > "${RAW_DIR}/incident-history.json"
nrql "SELECT count(*) FROM NrAiIncident WHERE muted IS TRUE SINCE 7 days ago"                        > "${RAW_DIR}/muted-fires.json"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Metric SINCE 1 day ago"                              > "${RAW_DIR}/ingest-metric.json"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Span SINCE 1 day ago"                                > "${RAW_DIR}/ingest-span.json"
nrql "SELECT bytecountestimate()/1e9 AS gb FROM Log SINCE 1 day ago"                                 > "${RAW_DIR}/ingest-log.json"
nrql "SELECT sum(GigabytesIngested) FROM NrConsumption FACET usageMetric SINCE 30 days ago LIMIT 20" > "${RAW_DIR}/consumption.json"
nrql "SELECT count(*) FROM Deployment SINCE 30 days ago"                                             > "${RAW_DIR}/deployments.json"
nrql "SELECT count(*), latest(result) FROM SyntheticCheck FACET monitorName SINCE 1 day ago LIMIT 20" > "${RAW_DIR}/synth-results.json"
echo "raw pull complete -> ${RAW_DIR}"
```

Bounded per-entity reads (critical services only, ≤10 — never the whole estate):

```bash
# For each critical-service guid (from business context joined to entities-*.jsonl):
nrq "query { actor { entity(guid: \"${GUID}\") { relatedEntities { results { type source { entity { name } } target { entity { name } } } } goldenMetrics { metrics { name query } } } } }" \
  | jq '.data.actor.entity' > "${RAW_DIR}/entity-${GUID}.json"
```

## 5. Reachability and data health (NR-001 … NR-006)

**NR-001/NR-002** run in the doctor gate (SKILL.md) — the three-outcome probe. In
the audit they are re-asserted from the gate's result, never re-derived loosely.
Remediation inline: 401 → mint/repair the User key (one.newrelic.com → API keys)
and store it under the env var `newrelic.api_key_env` names; 403 `account region`
→ set `newrelic.region` to the account's real region; wrong/missing account →
`actor.accounts` in the gate output lists the ids this key can see.

**NR-003, ingest alive + the empty/hidden-scope guardrail.**

```bash
jq -r 'length' "${RAW_DIR}/event-types.json"    # 0 event types = nothing ingested in 24h
jq -s 'map(.[0].gb // 0) | add' "${RAW_DIR}/ingest-metric.json" "${RAW_DIR}/ingest-span.json" "${RAW_DIR}/ingest-log.json"
```

Healthy: event types exist and at least one signal has non-zero bytes. **Guardrail
(fold of the empty/hidden-scope rule into this category):** reachable + valid key +
**zero** event types and zero entities → mark the coverage/alerting-dependent
categories (`Alert delivery`, `Alert noise`, `Coverage and topology`, `SLO and
dashboards`) `blocked` with reason "account reachable but empty — nothing is
shipping telemetry to it (or this key's account is the wrong one)", keep this
category scorable, renormalize, and never report a confident low score from an
empty read. Fail (NR-003, high) only when telemetry exists but a signal the estate
clearly produces (e.g. entities exist with zero spans) is absent.

**NR-004, NrIntegrationError — the "200 ≠ ingested" check.**

```bash
jq -r '.[] | "\(.count)x [\(.facet[0])] \(.facet[1])"' "${RAW_DIR}/integration-errors.json"
```

Healthy: empty. Fail (NR-004, high): rejection/truncation/conversion errors
present — quote category + message + count; the classes to expect: stale (>20 min)
spans silently rejected, attribute values truncated at 4095 chars, cumulative→delta
conversion anomalies, cardinality-limit breaches. Fix inline: correct the source
(clock skew/buffering for stale spans; trim attributes at the collector; prefer
delta temporality in SDKs). Verification: the facet count stops growing after the
fix. **Never treat exporter-side 200s as proof — this event type is the proof.**

**NR-005, cardinality posture.**

```bash
jq -r '.[] | select((.facet[1] // "") | test("cardinality|limit"; "i")) | "\(.count)x \(.facet[1])"' "${RAW_DIR}/integration-errors.json"
```

Healthy: no cardinality-class integration errors. Fail (NR-005, medium): breaches
present — name the metric family; consequence is silent (rollups stop for the day;
charts beyond ~60 min go empty/wrong while RAW still works). Fix inline: attribute
hygiene at the collector; NR-side metric normalization rules.

**NR-006, ingest concentration.** Rank the per-signal GB/day (raw pull) and — when
`NrConsumption` has populated (it lags ~a day) — by `usageMetric`. Fail (NR-006,
medium) when one source dominates disproportionately to its value (the classic:
unfiltered container logs, cluster-wide infra metrics) or a free-tier account is
pacing past 100GB/month (hard lockout: ingest AND UI access stop until month end).
This check states measured GB only — the dollar view lives in the non-scored
NROPT section.

## 6. Alert delivery (NR-010 … NR-014)

**NR-010, enabled conditions exist.**

```bash
jq '[.nrqlConditions[] | select(.enabled == true)] | length' "${RAW_DIR}/conditions.json"
```

Zero enabled conditions while entities and telemetry exist = an unwatched estate
(critical). Zero because the whole account is empty routes to the NR-003
guardrail instead.

**NR-011, every conditioned policy is caught by a workflow.** Join policies →
conditions → workflows:

```bash
jq -r '.policies[].id' "${RAW_DIR}/policies.json" | while read -r PID; do
  N_COND="$(jq --arg p "$PID" '[.nrqlConditions[] | select(.policyId == $p and .enabled == true)] | length' "${RAW_DIR}/conditions.json")"
  [ "$N_COND" -gt 0 ] || continue    # a policy with no enabled conditions has nothing to route (see the default-policy note)
  CAUGHT="$(jq --arg p "$PID" '[.entities[] | select(.workflowEnabled == true)
    | select((.issuesFilter.predicates | length) == 0
             or any(.issuesFilter.predicates[]; .attribute == "labels.policyIds" and (.values | index($p))))] | length' "${RAW_DIR}/workflows.json")"
  [ "$CAUGHT" -gt 0 ] || echo "NR-011 FAIL: policy ${PID} has ${N_COND} enabled condition(s) but NO enabled workflow catches it — its incidents notify nobody"
done
```

**Recognize the platform artifact — precisely (live-corrected):** creating any SLO
auto-spawns a policy named "Service Levels default policy" (PER_POLICY) **that
arrives WITH an enabled "Service Levels default alert condition"** (STATIC on
`ServiceLevelSnapshot` `remainingErrorBudget`) — and NO workflow catches it. So
the join above WILL flag it, and that is correct: on any account where someone
created an SLO, **error-budget incidents notify nobody by default**. Report it as
NR-011 at **medium** (not critical — it is a platform default, not an authored
policy someone forgot), name it as auto-created, and give the deliberate choice
as the fix: wire a workflow to it, or consciously disable the auto condition.
A user-authored conditioned policy caught by no workflow stays **critical**.
Fix inline: Alerts → Workflows → add a workflow filtered on the policy (or a
deliberate catch-all with `predicates: []`). Verification: re-run the join —
every conditioned policy is caught.

**NR-012, linkage intact.**

```bash
jq -r '.channels.entities[] | select(.destinationId as $d | ([$d] - [(.destinations.entities[]?.id)]) | length > 0) | .id' "${RAW_DIR}/notifications.json" 2>/dev/null || true
jq -r '.destinations.entities[] | select(.active != true) | "inactive destination: \(.name) (\(.type))"' "${RAW_DIR}/notifications.json"
jq -r '.entities[] | select(.workflowEnabled == true and .destinationsEnabled != true) | "workflow \(.name): destinations disabled"' "${RAW_DIR}/workflows.json"
```

Any dangling `destinationId`, inactive destination behind an enabled workflow, or
`destinationsEnabled: false` on an enabled workflow is the finding (high) — the
workflow triggers and delivers nowhere.

**NR-013, destination posture honesty.** Inventory `type`/`active` per
destination. `active: true` proves configuration, not delivery: only an observed
notification (e.g. the NR-025 fire-history join showing an incident that notified)
upgrades delivery to `validated-live` — state which level each destination earned.
Webhook destinations are domain-validated at creation but the endpoint can rot
afterwards; a webhook destination with no observed delivery in the window is
`configured`, flagged for a controlled re-verify (a mutation this audit never
performs — name it as the operator's step).

**NR-014, the flagship paging path.** For each critical service (business
context; fall back to the top-N entities by reporting volume): entity exists →
some enabled condition's `nrql.query` selects it (match the service name/guid in
the query text) → that condition's policy → NR-011's workflow join → NR-012's
active destination. Emit one narrative finding per broken link, citing the exact
link: *"checkout has an entity and traffic, but no enabled condition's NRQL covers
it — a checkout incident tonight pages nobody"* / *"…condition exists but its
policy is caught by no workflow…"*. This is the check no NR screen assembles
end-to-end.

## 7. Alert noise (NR-020 … NR-026)

**NR-020, two-term tiering.**

```bash
jq -r '.nrqlConditions[] | select(.enabled == true)
  | select(([.terms[]?.priority] | index("WARNING")) == null)
  | "single-tier condition: \(.name) (critical-only)"' "${RAW_DIR}/conditions.json"
```

**NR-021, evaluation sanity.** Three mechanical reads per enabled condition:
(a) `thresholdDuration % aggregationWindow != 0` → invalid-by-schema drift risk;
(b) `thresholdOccurrences == "AT_LEAST_ONCE"` on a volatile signal → single-spike
paging (judgment: confirm the signal is spiky before filing); (c) compare
`aggregationDelay` against observed data latency — and for any condition whose
NRQL targets a signal with gaps >65 min on `EVENT_FLOW`, flag the stall risk
(windows never close; the alert silently never fires) with the fix: switch that
condition to `EVENT_TIMER`. Document the divergence honestly: **late points are
excluded from streaming evaluation forever but appear in charts later** — "the
chart shows a breach but no alert fired" is this misconfiguration, not a platform
bug.

**NR-022, loss-of-signal.**

```bash
jq -r '.nrqlConditions[] | select(.enabled == true and (.terms[]?.operator == "BELOW"))
  | select(.expiration == null or .expiration.expirationDuration == null)
  | "presence-style condition without loss-of-signal expiration: \(.name)"' "${RAW_DIR}/conditions.json"
```

A BELOW/presence condition with no `expiration` cannot distinguish "signal healthy"
from "signal stopped arriving" — the very outage it watches for mutes it.

**NR-023, disabled conditions.**

```bash
jq -r '.nrqlConditions[] | select(.enabled == false) | "disabled condition (dead weight): \(.name)"' "${RAW_DIR}/conditions.json"
```

**NR-024, muting hygiene.**

```bash
jq -r '.[] | select(.enabled == true and (.schedule == null or (.schedule.endTime == null and .schedule.repeat == null)))
  | "ENABLED open-ended muting rule: \(.name) — a silent blind spot"' "${RAW_DIR}/muting.json"
```

**NR-025, measured fire-history.**

```bash
jq -r 'group_by(.facet[0]) | map({condition: .[0].facet[0],
  opens:  ([.[] | select(.facet[1]=="open")  | .count] | add // 0),
  closes: ([.[] | select(.facet[1]=="close") | .count] | add // 0)})
  | sort_by(-.opens) | .[] | "\(.condition): \(.opens) opens / \(.closes) closes"' "${RAW_DIR}/incident-history.json"
jq -r '.[0].count // 0' "${RAW_DIR}/muted-fires.json"
```

Findings: a condition with opens and zero closes across the window = chronic
(desensitization risk, name the duration); the top-noisy conditions by opens; any
incidents opened while `muted: true` (noise the team deliberately hid instead of
fixing). These measured rows are exactly what the `alert-fatigue` fire-history
lane consumes — `NrAiIncident` carries `openTime`, `conditionName`, `priority`,
`muted`, `entity.guid` (all confirmed live).

**NR-026, incidentPreference.**

```bash
jq -r '.policies[] | "\(.name): \(.incidentPreference)"' "${RAW_DIR}/policies.json"
```

Judgment with facts: PER_POLICY on a policy carrying many unrelated conditions
over-groups (one open incident masks the next failure); PER_CONDITION_AND_TARGET
on a wide-facet condition fans out per target. State the condition count per
policy next to the preference; recommend, never auto-decide.

## 8. Coverage and topology (NR-030 … NR-035)

**NR-030, zero-coverage entities.**

```bash
cat "${RAW_DIR}"/entities-domainext.jsonl "${RAW_DIR}"/entities-domainapm.jsonl 2>/dev/null \
  | jq -r 'select(.alertSeverity == "NOT_CONFIGURED") | .name' | sort -u
```

`NOT_CONFIGURED` = no alerting evaluates this entity (confirmed live as the
zero-coverage enum). Escalate to critical when the entity is a business-context
critical service; compute the blast radius (how many critical services are
unwatched, of how many total).

**NR-031, critical services present and reporting.** Join the business-context
critical list against the entity files; an expected-but-absent service is either
dead telemetry or **entity expiry** (EXT entities vanish from the UI after 8 idle
days; the telemetry history is still queryable in NRDB — check
`SELECT count(*) FROM Span WHERE service.name = '<svc>' SINCE 8 days ago` to
distinguish "never reported" from "stopped").

**NR-032, topology present.** From the bounded per-entity reads: zero
`relatedEntities` CALLS edges on a core service that clearly has upstreams =
missing blast-radius context (medium). NR synthesizes these from spans — missing
edges usually mean broken context propagation between those services.

**NR-033, golden signals resolvable.** Run ONE goldenMetric query per critical
entity (they ship as ready-made NRQL — confirmed live) and confirm data returns;
an empty golden metric on a reporting entity is a naming/instrumentation gap.

**NR-034, synthetics.**

```bash
wc -l < "${RAW_DIR}/entities-domainsynth.jsonl"
jq -r '.[] | "\(.facet): \(."latest.result") (\(.count) checks)"' "${RAW_DIR}/synth-results.json"
```

Zero SYNTH entities while public endpoints exist in business context = no
outside-in uptime coverage (medium). A monitor whose latest result is not SUCCESS
is named with its failure count.

**NR-035, ownership tags.**

```bash
cat "${RAW_DIR}"/entities-domainext.jsonl 2>/dev/null \
  | jq -r 'select(([.tags[]?.key] | index("team")) == null) | .name' | head -20
```

## 9. SLO and dashboards (NR-040 … NR-042)

**NR-040:** count SERVICE_LEVEL entities; join to critical services. Zero SLOs on
an estate with declared SLAs (business context) is the finding (medium). Note the
auto-spawned default policy (see NR-011) — its existence proves someone created an
SLO, not a misconfiguration.

**NR-041:** DASHBOARD entity count **de-duplicated for page entities** (a one-page
dashboard registers 2 DASHBOARD-type entities — confirmed live; de-dup by name or
count unique names). Judgment: do dashboards exist for the golden signals of the
critical services?

**NR-042:** `Deployment` event count over 30 days. Zero = change tracking unwired
— incidents lack "what changed" context (low; the fix is one
`changeTrackingCreateDeployment` call in the deploy pipeline — named as the
operator's step, never performed by this audit).

## 10. Rate limits, pagination, retries

- Sequential calls only; 25-concurrent-per-user is the NerdGraph limit and this
  audit must never contribute to exhausting it (CI/Terraform on the same user
  suffers first).
- `entitySearch` paginates by `nextCursor` (the raw pull loops, hard-capped at 20
  pages); `policiesSearch`/`nrqlConditionsSearch` return `nextCursor` the same way
  on estates larger than one page — extend the same loop when `totalCount` exceeds
  the first page.
- On a 429 or `TOO_MANY_REQUESTS`: wait 30s, retry once; a second failure marks
  the affected checks `blocked`, never silently skipped.

## 11. Ingest & cost section (non-scored, `NROPT-NNN`)

Reported and never scored — `scoring_scope: "non-scored"`, `points_recoverable: 0`,
`area: "cost-optimization"` (the roll-up's exact selector — contract C18),
rendered under its own heading after Topology Readiness. **Never invent a dollar.**
A free/unknown-plan account gets GB figures only; a dollar appears solely when the
account's own consumption data exposes billed amounts.

- **NROPT-001, ingest ranked by source:** `NrConsumption` by `usageMetric` (30d),
  falling back to `bytecountestimate()` per signal type when consumption has not
  yet populated (it lags ~a day — say which source the numbers came from). Name
  the top sources and the 100GB free-tier proximity where applicable.
- **NROPT-002, governance opportunities (advisory):** long-window trends kept as
  raw events that events-to-metrics rules would keep for 13 months at a fraction
  of the bytes; retention windows above need; high-cardinality attributes that
  normalization rules would fold. Pure pointers — no invented savings figure.

## 12. NRQL / event reference (confirmed live unless noted)

| Event type | What it holds |
| --- | --- |
| `NrIntegrationError` | ingest rejections/truncations/conversion anomalies (`category`, `message`) |
| `NrAiIncident` | fire history: `event` (open/close), `openTime`, `conditionName`, `policyId`, `priority`, `muted`, `entity.guid`, `threshold` |
| `NrConsumption` | billed ingest (`GigabytesIngested` by `usageMetric`; ~daily lag) |
| `SyntheticCheck` | synthetics results (`result`, `duration`, `monitorName`) |
| `Deployment` | change-tracking markers (`version`, `entity.guid`) |
| `Span` / `Metric` / `Log` | the telemetry itself; `bytecountestimate()` works on each |

Entity model: OTel services = `domain 'EXT'`, `THIRD_PARTY_SERVICE_ENTITY`;
NR-agent services = `domain 'APM'`; synthetics = `domain 'SYNTH'`;
`alertSeverity ∈ {NOT_ALERTING, WARNING, CRITICAL, NOT_CONFIGURED}`
(NOT_CONFIGURED confirmed live; the other three are the documented remainder —
confirm-live-per-estate before citing a specific one in a finding).

## 13. Forbidden mutations

This audit sends **GraphQL `query` documents only**. Every NerdGraph `mutation` is
forbidden — including the harmless-looking ones: no `alertsPolicy*`,
`alertsNrqlCondition*`, `aiNotifications*`, `aiWorkflows*`, `alertsMutingRule*`,
`dashboard*`, `serviceLevel*`, `synthetics*`, `workload*`, `taggingAddTagsToEntity`,
`changeTrackingCreateDeployment`, `apiAccessCreateKeys`, `entityManagement*`,
`nrqlDropRulesCreate`, or any other mutation field. No test notifications, no
"quick fixes", no key creation, no tag writes. The `nrq` helper hard-rejects any
document starting with `mutation`. Reads that LOOK like writes are limited to the
one documented read-by-POST: the `/graphql` endpoint itself carrying a query
document. If a check seems to need a mutation, the check is wrong — name the
operator's step in the finding instead.
