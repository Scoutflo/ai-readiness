# Fire-history reads ; the measured tier (read-only, per provider)

The config-tier audits answer *"is this rule shaped well?"*. This lane answers the
question that actually proves fatigue: *"how did each alert BEHAVE ; how often did it
fire, does it flap, is it stuck, does it reach a human?"* Those are **measured** numbers,
so the alert-fatigue skill collects them itself with **read-only** calls, normalizes them
into `fatigue-signals.json`, and the roll-up library
([lib/alert-fatigue.sh](../lib/alert-fatigue.sh)) analyzes them (AF-004…007) alongside the
config findings. **The provider calls happen HERE, in the skill's collection lane (the
audit lane is allowed to call providers); the roll-up library still makes zero provider
calls.** Every call below is a GET or a documented read-by-POST (a query/search body, no
state change) ; this lane never mutates.

**Never fabricate.** A provider that cannot expose history (no permission / API not
present) marks that provider's fire-history tier `verify-pending` in
`provider_coverage[]` ; never a guessed number. **Off-hours has no native field anywhere**
; it is always *derived* from a fire timestamp against the business-hours window; say so.

**Bounded and resumable.** Use [collection-workflow.md](collection-workflow.md)
for the selected-target doctor/identity gate, immutable window/object plan and
per-job success receipts. API lists paginate; analytical queries instead need
explicit windows and result/point limits. A cap is not evidence of exhaustion.
Resume pending jobs and never overwrite or re-pull a completed verified result.

**Reuse the config audit's inventory ; don't re-enumerate.** If the provider's audit
already ran today (its `inventory.json` / `findings.json` exist under the audits dir),
take the **object set** (the alarms/rules/monitors and their routing) from there and pull
only the **history delta** per object ; never re-list the whole estate. Example:
`audit-aws` already enumerates every CloudWatch alarm and its `AlarmActions`/SNS wiring
(and often flags the zero-subscriber and stuck-in-ALARM cases at the config tier); the
fire-history lane reads that inventory for the alarm set + routing verdict and adds only
`DescribeAlarmHistory` per alarm ; it does not re-run `describe-alarms` across the account.
This keeps the two consistent (one enumeration, no double-pull) and bounds the lane on a
large estate. Cite the config finding in each signal's `source_finding_ids` so the analysis
joins back rather than restating.

## Output contract ; `fatigue-signals.json` (`scoutflo-fatigue-signals/v1`)

Write it to `${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue-signals.json`:

```json
{
  "schema": "scoutflo-fatigue-signals/v1",
  "generated_at": "<UTC ISO8601>",
  "window": "30d",
  "signals": [
    { "provider": "aws", "target": "aws",
      "object_id": "<alarm/rule/monitor id>", "object_kind": "cloudwatch_alarm",
      "fires": 48,              // transitions INTO the firing state in the window (measured)
      "transitions": 96,        // total state changes (flap proxy); omit if unknown
      "flapping": true,         // transitions/day above a threshold; omit if not derivable
      "stuck": false,           // currently firing continuously for a long time
      "stuck_since": "2025-10-01T00:00:00Z",  // when it entered the current firing state
      "stuck_days": 0,
      "off_hours_fires": 30,    // fires whose timestamp is outside business hours; null if TZ/window unknown
      "reaches_human": false,   // routing resolves to a live receiver/subscriber/workflow/channel
      "reach_reason": "SNS topic has 0 subscribers",
      "source_finding_ids": ["AWS-SNS"] }   // link back to the config finding(s)
  ],
  "provider_coverage": [
    { "provider": "aws",     "tier": "fire-history", "status": "collected", "objects": 118, "verification": "spec-only" },
    { "provider": "datadog", "tier": "fire-history", "status": "verify-pending", "reason": "events read returned 403 (needs events_read scope)" }
  ],
  "incident_feed": {          // OPTIONAL ; the incident-feed tier for AF-003 (see §incident-feed)
    "status": "collected", "source": "pagerduty", "window": "30d",
    "alerts_fired": 420, "incidents": 7, "mtta_seconds": 180, "mttr_seconds": 3600, "actionable_pct": 38 }
}
```

Only emit a field you actually measured. A missing field is honest; a fabricated one is a bug.

`generated_at` is the UTC collection timestamp and `window` states the observation
window. Any nonempty signals or collected incident feed must carry both. The
validator binds the timestamp to the requested run date; missing or older
provenance is blocked until recollected. This date binding cannot prove two
same-day snapshots are simultaneous. Signal `target`, when supplied, is the
audit directory identity, including its optional label (`signoz/primary`). Legacy
signals without it retain the provider label for joins; they cannot identify an
arbitrary named target. Config findings with structured envelope targets remain
readable via their artifact directory. `source_finding_ids` may be omitted or empty
for standalone observations, but every supplied ID must exist in current findings,
including when that set is empty. The v1 ID-existence check does not prove an
account or service mapping; those require independently verified target identity.

**Validate before analyzing.** After writing `fatigue-signals.json`, run
[`report-standard/check-fatigue-signals.sh`](../../../report-standard/check-fatigue-signals.sh)
`<fatigue-signals.json> <audits-dir> <run-date>` ; it fails closed on a malformed
schema, absent/stale measurement provenance, negative counts, a wrong field type, an `off_hours_fires > fires` impossibility, a
`verify-pending` with no reason, or a `source_finding_ids` entry that cites a
finding absent from this run (the never-fabricate cross-check). Do not feed a file
that does not print `FATIGUE-SIGNALS-OK` into the analysis. The roll-up entry point enforces this gate again on a local snapshot before autoload, so bypassing the manual step cannot turn rejected input into measurements. A signal also cannot contradict an explicit non-collected provider coverage entry. Historical missing coverage entries remain readable; that omission does not establish coverage of the whole estate.

## Assert the provider response before deriving a signal

Run these assertions on the selected target response after checking the provider
command exit. Do not pipe a failed command straight into jq; jq can exit zero on
empty input. Every consumed field must have the expected type. A zero-length
array is valid only after the response wrapper, identity, query interval and
pagination/exhaustion are established. Keep missing data absent and record the
exact failed predicate with its job.

| Read | Required predicate and derivation boundary |
| --- | --- |
| CloudWatch history | `jq -e '(.AlarmHistoryItems|type)=="array" and all(.AlarmHistoryItems[]; (.AlarmName|type)=="string" and (.Timestamp|type)=="string" and (.HistoryData|type)=="string")'`; parse each HistoryData JSON and assert the observed old/new state fields before counting distinct transitions into ALARM for the exact alarm. Deduplicate by stable event identity/contents across pages; absent/unknown state schema blocks fires. `NextToken` must be exhausted without repeats |
| SNS subscriptions | `jq -e '(.Subscriptions|type)=="array"'`; reconcile every returned `TopicArn` with the queried ARN and exhaust `NextToken`. Empty confirmed subscribers proves no SNS subscription, not human delivery; pending/unknown subscription state cannot be guessed |
| Datadog Events v1 | `jq -e '(.events|type)=="array" and all(.events[]; (.id|type)=="number" and (.date_happened|type)=="number")'`; retain only the exact monitor/aggregation identity and explicit trigger events, deduplicate event IDs and bound the interval. Split saturated time buckets until completeness is established; a 1,000-row cap is not exhaustion |
| Grafana annotations | `jq -e 'type=="array" and all(.[]; (.id|type)=="number" and (.time|type)=="number")'`; assert exact rule UID/ID and observed new/previous state fields before counting trigger episodes. A deployment without state fields cannot provide fires from generic annotations. Paginate/split saturated windows and deduplicate annotation IDs |
| Alertmanager counters | Assert Prometheus `status=="success"`, the expected vector/matrix wrapper, exact integration labels and numeric values. Counter increase is an estimate of attempted notifications over a range and may be fractional due to extrapolation; it is not rule fires or confirmed delivery. Preserve reset/partial scrape caveats |
| SigNoz history | Assert the deployed route's actual wrapper, rule identity, numeric timestamps, pagination and trigger/clear enum before normalization. The historical `Stats.TotalCurrentTriggers` and backend table names below are candidate fields, not authority: without a populated observed schema, omit fires and record verify-pending |
| New Relic NRQL | `jq -e '(.errors // []|length)==0 and (.data.actor.account.nrql.results|type)=="array"'`; match configured account and exact condition, window and event semantics. A grouped count needs a complete unsaturated query. Correlate open/close by a confirmed unique incident identity; missing linkage cannot prove continuous stuck state |
| PagerDuty incidents | `jq -e '(.incidents|type)=="array" and (.more|type)=="boolean"'`; paginate until `.more==false`, deduplicate IDs, then assert timestamp/ack fields for each read. Count incidents separately from source alert occurrences; do not use incidents for both numerator and denominator |
| Other incident feeds | Require the selected deployment's observed JSON wrapper, unique identity, trigger/ack/resolve semantics and a proved end cursor. Unknown Zenduty/incident.io/Opsgenie shapes remain verify-pending; never invent fields from a similar vendor |

For exact event counts, require both `complete_window:true` and
`count_semantics:"exact-events"` in the per-job proof. These declarations must be
supported by the exhausted read and assertions above; they are not substitutes
for evidence. State samples and notification counters use their own measurement
fields, never `fires`. The shared signals validator then checks the normalized
artifact before either completion or analysis.

## Live-verification status & checklist (the measured tier is doc-verified, not yet live-proven)

**Honesty rule for this whole lane:** the per-provider read blocks below are
**doc-verified** (each field tagged VERIFIED / UNVERIFIED against the vendor's own
API reference), but the measured tier as a whole has **not yet been confirmed
against a live tenant per provider**. Until it is, set each provider's
`provider_coverage[].verification` to **`spec-only`**; the report surfaces that so
AF-004/005/006 are never presented as battle-tested when they are not. On the first
live run against an authorized estate, confirm the UNVERIFIED fields below parse as
expected, then set `verification: "live-verified"` for that provider. This closes
the plugin's own live-smoke gate (AGENTS Done-criteria #5) provider by provider.

| Provider | Read blocks | Confirm on first live run (the UNVERIFIED fields) |
| --- | --- | --- |
| **AWS CloudWatch** | `DescribeAlarmHistory` + SNS subscriber check | `HistoryData` keys (`newState.stateValue`/`oldState.stateValue`); the SNS `PendingConfirmation` sentinel |
| **Datadog** | Events v1/v2 + monitor state | `aggregation_key` uniqueness per monitor; the v2 `timestamp` unit (ms vs s) |
| **Grafana** | annotations / Loki state-history | Loki `GET /api/v1/rules/history` frame field names (prefer annotations if Loki absent) |
| **Prometheus** | `ALERTS`/`ALERTS_FOR_STATE` PromQL | Confirm sample_step_seconds, window bounds, alert identity and HA deduplication against the deployment; sampled values do not establish exact fires, episodes or continuous stuck duration. |
| **Alertmanager** | notification counters + silences | the `alertmanager_alerts{state}` gauge name (confirm from a live `/metrics`) |
| **SigNoz** | `rules/{id}/history/*` POST routes | route reachability + `Stats.TotalCurrentTriggers` shape; ClickHouse table name is UNVERIFIED (prefer REST) |
| **New Relic** | `NrAiIncident` NRQL via NerdGraph | field set CONFIRMED LIVE against a real fired incident (event/openTime/conditionName/priority/muted/entity.guid, 2026-09) ; first live run may set `live-verified` directly after re-confirming on the target tenant |
| **PagerDuty** | `GET /incidents` + `log_entries` | `analytics/metrics` response fields (prefer `log_entries` until confirmed) |
| **incident.io / Opsgenie** | incidents lists | `duration_metrics[]` / `report.ackTime` shapes |
| **Splunk On-Call (VictorOps)** | Bounded incident observations in `audit-splunk-oncall` | A complete fatigue feed, historical pagination and notification-delivery counts remain **verify-pending**; do not derive MTTA/MTTR or alert-to-incident ratios from one observed lifecycle |
| **Zenduty** | incidents list | **entirely UNVERIFIED** (docs migrated to Xurrent) ; keep `verify-pending` until re-confirmed |

**Per-provider checklist (run once, on an authorized estate):** (1) run the read
block read-only; (2) confirm each UNVERIFIED field above is present and parses (fall
back to the documented text/alternate field if not, and note it); (3) confirm
`fires`/`stuck`/`reaches_human` derive sane values against a known object; (4) set
`verification: "live-verified"`; (5) if a read is blocked (403/absent), mark that
provider `verify-pending` with the reason ; never emit a guessed number.

---

## AWS CloudWatch  (VERIFIED read-only)

- **Fire history:** `aws cloudwatch describe-alarm-history --history-item-type StateUpdate --start-date <ts> --end-date <ts> [--alarm-name N] [--max-records 100] [--next-token …]`. Each `AlarmHistoryItems[]` has `AlarmName`, `Timestamp`, `HistoryData` (JSON) and `HistorySummary` (text). **`fires`** = count of items whose transition ends in `ALARM`; **`transitions`/`flapping`** = order items by `Timestamp` and count `OK↔ALARM` oscillations. *Caveat:* the `HistoryData` internal keys (`newState.stateValue`/`oldState.stateValue`) are **UNVERIFIED as documented field names** ; parse defensively and fall back to `HistorySummary` text.
- **Stuck:** `aws cloudwatch describe-alarms` → an alarm with `StateValue == "ALARM"`; `stuck_since` = `StateTransitionedTimestamp` ("most recently changed"); `stuck_days` = now − that. (`StateUpdatedTimestamp` is the looser field; prefer `StateTransitionedTimestamp`.)
- **reaches_human (dead-end):** for each alarm, `AlarmActions[]` → filter `arn:aws:sns:*` → `aws sns list-subscriptions-by-topic --topic-arn <arn>` → `reaches_human=false` when `Subscriptions` is empty, or all `SubscriptionArn == "PendingConfirmation"` (**PendingConfirmation sentinel is UNVERIFIED on the API page ; confirm live**), or the alarm's `ActionsEnabled == false`.
- **off_hours_fires:** bucket each `StateUpdate` `Timestamp` (UTC → business TZ) against the business-hours window.

## Datadog  (VERIFIED read-only; v2 search is a read-only POST)

- **Fire history:** v1 `GET /api/v1/events?sources=alert&start=<unixsec>&end=<unixsec>` (≤1000 results; fields `alert_type`, `date_happened`, `tags`, `title`) ; count `sources=alert` events per monitor; **or** v2 `POST /api/v2/events/search` (body `filter{query:"source:alert monitor_id:<id>",from,to}`) where `data[].attributes.attributes.status ∈ {error,warn}` = fire and `ok` = recovery, grouped by **`aggregation_key`** (unique per monitor id since 2025-03-01; there is **no `monitor_id` field** on the alert-event attributes ; use `aggregation_key` or a `monitor_id:` query scope).
- **Stuck:** `GET /api/v1/monitor/{id}` → `overall_state ∈ {Alert,Warn}` with `state.groups[*].last_triggered_ts` far in the past and no later `last_resolved_ts`; `stuck_since ≈ last_triggered_ts`. (`state.groups[].triggering_value` and `overall_state_modified` are **UNVERIFIED/absent in the API client** ; use `last_triggered_ts`/`last_resolved_ts`.)
- **flapping:** sort a monitor's events by `date_happened`/`timestamp`, count trigger↔recovery oscillations.
- **Mute-aware:** `GET /api/v2/downtime` ; exclude muted windows from the noise count.
- **off_hours_fires:** bucket `date_happened` (Unix **seconds**; v2 `timestamp` may be ms ; verify unit live) against business hours.

## Grafana Alerting  (VERIFIED read-only)

- **Fire history:** `GET /api/annotations?type=alert&from=<ms>&to=<ms>[&alertId=N&limit=N]` ; per-annotation `time`, `timeEnd`, `newState`, `prevState`, `tags`. `fires` = annotations where `newState` = Alerting; `flapping` = count `Alerting↔Normal` oscillations by rule. (The Loki-backed `GET /api/v1/rules/history?ruleUID=…&from=&to=` gives richer per-transition history but **requires a Loki state-history backend**; its emitted frame field names are **UNVERIFIED** ; prefer annotations when Loki isn't configured.)
- **Stuck:** `GET /api/prometheus/grafana/api/v1/rules` → rule `state == "firing"/"Alerting"`; `stuck_since` = the alert's `activeAt` (Prometheus rules schema).
- **off_hours_fires:** bucket annotation `time` (epoch **ms**) against business hours.

## Prometheus (sampled state, not an exact fire-event log)

`count by(alertname)(count_over_time(ALERTS[window]))` counts series, not
fire episodes. `changes(ALERTS_FOR_STATE)` counts changes visible in samples;
it misses an initial episode and episodes between samples. Neither may populate
`fires`, notification volume, MTTA/MTTR or delivered-page counts.

Use the bounded query below to collect distinct active-since values *observed
while firing*. The normalizer exposes only `distinct_active_since_values`,
which the analysis does not mistake for `fires`. It deduplicates equal timestamps
across HA series and reports only how many distinct values were observed. A
restart/state restoration can adjust active-since values without a new fire, so
this is not even a guaranteed episode lower bound. It asserts neither complete
history nor continuous firing. `ALERTS_FOR_STATE` starts with pending state; therefore its timestamp is
not the exact moment firing began. A currently firing rule whose `activeAt` is
old is not sufficient proof of a continuous stuck duration. Keep `stuck` absent
unless a complete transition log proves no intervening clear.

Before this block, run the [collection workflow](collection-workflow.md) doctor
and explicit deployment-identity recipe in the same selected run. The five-minute
receipt is checked again. Each new read also repeats doctor and the fixed identity query with the same freshly loaded credentials used for its history query; a changed credential generation requires a new run and cannot reuse earlier results, even if scope labels match. `AF_JOB_ID` names
one pending inventory object. A completed receipt skips the provider call.

```bash
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/alert-fatigue/lib/collection-workflow.sh"
afc_open "${AF_COLLECTION_PLAN:?path to collection plan}"
[ "$AFC_PROVIDER" = prometheus ] || { echo 'this recipe is Prometheus-only'; exit 1; }
AFC_JOB_ID="${AF_JOB_ID:?selected pending job}"
AFC_CLAIM=0; afc_claim "$AFC_JOB_ID" || AFC_CLAIM=$?
[ "$AFC_CLAIM" -ne 3 ] || { echo 'already complete; no provider call'; exit 0; }
[ "$AFC_CLAIM" -eq 0 ] || exit "$AFC_CLAIM"
AFC_ATTEMPT=$(mktemp -d "$AFC_RUN/jobs/$AFC_JOB_ID/attempt.XXXXXX")
AFC_STAGE=preflight
trap 'AFC_RC=$?; jq -n --arg stage "$AFC_STAGE" --argjson exit_code "$AFC_RC" '\''{stage:$stage,exit_code:$exit_code}'\'' > "$AFC_ATTEMPT/status.json"; afc_release "$AFC_JOB_ID"' EXIT HUP INT TERM
afc_preflight
AFC_URL=$(afc_get url)
AFC_QUERY=$(jq -er '.identity.query | select(type=="string" and length>0)' "$AFC_PLAN")
AFC_LABEL_KEY=$(jq -er '.identity.label | select(type=="string" and length>0)' "$AFC_PLAN")
set -- --fail --silent --show-error --max-time 20 --get
if [ -n "$AFC_BASIC_USER" ]; then set -- "$@" -u "$AFC_BASIC_USER:$AFC_BASIC_PASS"
elif [ -n "$AFC_TOKEN" ]; then set -- "$@" -H "Authorization: Bearer $AFC_TOKEN"; fi
AFC_RESPONSE=$(curl "$@" --data-urlencode "query=$AFC_QUERY" "$AFC_URL/api/v1/query")
printf '%s' "$AFC_RESPONSE" | jq -e --arg label "$AFC_LABEL_KEY" '
  select(.status=="success" and .data.resultType=="vector" and (.data.result|length)==1)
  | {identity:.data.result[0].metric[$label]} | select((.identity|type)=="string" and (.identity|length)>0)
' > "$AFC_RUN/identity-response.json"
afc_verify_identity "$AFC_RUN/identity-response.json"
AFC_OBJECT=$(jq -er --arg id "$AFC_JOB_ID" '.objects[]|select(.job_id==$id)|.object_id' "$AFC_PLAN")
AFC_START=$(jq -r .window.start "$AFC_PLAN"); AFC_END=$(jq -r .window.end "$AFC_PLAN")
AFC_STEP=$(jq -er '.thresholds.sample_step_seconds | select(type=="number" and .>0)' "$AFC_PLAN")
AFC_LIMIT=$(jq -r .limits.page_size "$AFC_PLAN")
jq -ne --argjson start "$AFC_START" --argjson end "$AFC_END" --argjson step "$AFC_STEP" \
  '($end-$start)/$step<=11000' >/dev/null || { echo 'query exceeds point budget; narrow the window or choose a coarser stated resolution'; exit 1; }
AFC_MATCHER=$(jq -n --arg name "$AFC_OBJECT" '$name')
AFC_QUERY="ALERTS_FOR_STATE{alertname=$AFC_MATCHER} and ignoring(alertstate) ALERTS{alertname=$AFC_MATCHER,alertstate=\"firing\"}"
set -- --fail --silent --show-error --max-time 20 --max-filesize 1048576 --get
if [ -n "$AFC_BASIC_USER" ]; then set -- "$@" -u "$AFC_BASIC_USER:$AFC_BASIC_PASS"
elif [ -n "$AFC_TOKEN" ]; then set -- "$@" -H "Authorization: Bearer $AFC_TOKEN"; fi
AFC_STAGE=history-read
AFC_RESPONSE=$(curl "$@" --data-urlencode "query=$AFC_QUERY" --data-urlencode "start=$AFC_START" \
  --data-urlencode "end=$AFC_END" --data-urlencode "step=$AFC_STEP" --data-urlencode "limit=$AFC_LIMIT" "$AFC_URL/api/v1/query_range")
AFC_STAGE=response-assertions
AFC_RESULT="$AFC_ATTEMPT/candidate.json"
printf '%s' "$AFC_RESPONSE" | afc_prometheus_result "$AFC_JOB_ID" > "$AFC_RESULT"
afc_complete "$AFC_JOB_ID" "$AFC_RESULT"
AFC_STAGE=complete
```

Expected: a valid empty range records zero distinct sampled-state values, with
`fires` absent. Wrong wrapper, wrong alert identity, nonnumeric values, time
outside the requested window, query warnings, the series cap, transport failure
or response-size cap produces no completion receipt. Its pending job can resume
without re-pulling completed jobs. The point/response caps are execution safety
budgets, not alert policies; split a larger window into explicit jobs rather than
silently truncating it.

To establish **exact fires**, collect a durable rule-transition/event log that
covers the entire requested interval, including pagination, unique event IDs,
rule/instance identity and trigger/clear semantics. Grafana's annotations or
rule history can provide such a feed for Grafana-managed rules; use that provider
recipe with complete cursor exhaustion and its actual schema. An Alertmanager
notification counter measures attempted notifications, not Prometheus fire
transitions. If no complete event log exists, exact `fires` stays unavailable;
do not manufacture it from state samples.


## Alertmanager  (VERIFIED read-only)

- **Notification volume (scraped counters, query via Prometheus PromQL):** `alertmanager_notifications_total{integration}` ("total attempted notifications"), `alertmanager_notifications_failed_total{integration,reason}`, `alertmanager_notifications_suppressed_total{reason}` ("silenced/inhibited/outside active/within muted"). Noise-by-channel = `sort_desc(sum by (integration)(increase(alertmanager_notifications_total[<window>])))`; suppression ratio = suppressed ÷ total. (`alertmanager_alerts{state}` gauge name is **UNVERIFIED** ; confirm from a live `/metrics`.)
- **Batching / effectively-disabled:** `GET /api/v2/alerts/groups` (real notification units vs raw alert count); `GET /api/v2/silences` → an `active` silence with a long `endsAt-startsAt` whose `matchers` cover a currently-firing alert (cross-join `GET /api/v2/alerts?active=true&silenced=true`) = an alert silenced into oblivion → `reaches_human=false`, reason "covered by a long-standing silence".

## SigNoz  (read routes VERIFIED from source; the history API is undocumented publicly)

Rule history routes (registered in `http_handler.go`, `ViewAccess`, POST-bodied analytical
reads ; no mutation): `POST /api/v1/rules/{id}/history/stats|timeline|top_contributors|overall_status`,
request `{start,end (epoch ms),state,filters,offset,limit,order}`.
- **fires:** `Stats.TotalCurrentTriggers` (vs `TotalPastTriggers` for trend), or count `timeline.items[]` where `state=="firing"`.
- **flapping:** count firing↔normal transitions per `fingerprint` in `history/timeline`.
- **stuck / since-when:** a `fingerprint` whose earliest firing `unixMilli` is far in the past with no intervening `normal`; `stuck_since` = that `unixMilli`.
- **top-noisy:** `history/top_contributors`. **Resolution health:** `Stats.CurrentAvgResolutionTime`.
- The ClickHouse alert-state-history table is a fallback but its **name is UNVERIFIED** ; prefer the REST routes; if neither is reachable, mark SigNoz fire-history `verify-pending`.

---

## New Relic  (fields CONFIRMED LIVE against a real fired incident, 2026-09)

One read: the `NrAiIncident` event type via a NerdGraph NRQL query (a documented
read-by-POST ; a `query` document on `/graphql`, no mutation):

```
SELECT count(*) FROM NrAiIncident FACET conditionName, event SINCE 7 days ago LIMIT 100
SELECT count(*) FROM NrAiIncident WHERE muted IS TRUE SINCE 7 days ago
```

Confirmed-live fields per row ; **both halves of the cycle now live-verified**
(`open` rows from a genuinely fired condition; `close` rows observed after its
threshold was raised in a remediation session, with `aiIssues.state` moving
`ACTIVATED` → `CLOSED`): `event` (`open`/`close`), `openTime`,
`conditionName`, `conditionId`, `policyId`, `policyName`, `priority`
(`WARNING`/`CRITICAL`), `muted`, `entity.guid`, `threshold`.
- **fires:** count of `event = 'open'` rows per condition over the window.
- **flapping:** open/close alternation rate per condition (join opens to closes
  by `incidentId` when present; a high open count with matching closes inside
  short gaps is the flap signature).
- **stuck / since-when:** opens with **no matching close** across the window;
  `stuck_since` = the earliest such `openTime`.
- **top-noisy:** the FACET ranking by opens. **muted fires:** the `muted IS TRUE`
  count ; noise the team hid instead of fixing.
- **off-hours:** derived (as everywhere) from `openTime` against the
  business-hours window ; no native field.
- Casing nuance (observed live): `priority` on raw `close` rows came back
  lowercase (`warning`/`critical`) ; compare case-insensitively when joining
  opens to closes.
- Issue-level state (`aiIssues.issues` → `state: ACTIVATED/CLOSED`, both
  live-verified) confirms the
  incident→issue grouping when needed; the incident rows above are the volume
  truth. Auth is the same User key as `audit-newrelic`; a 401/403 marks the
  provider `verify-pending`, never a guessed number.

---

## Incident-feed tier ; the TRUE ratio, MTTA/MTTR, %-actionable (for AF-003)

Populate `incident_feed{}` in `fatigue-signals.json` from a read-only incident/ack stream so
AF-003 is a **measured** ratio, not an operator guess. General derivation: **ratio** = (alerts
fired in window, from the reads above) ÷ (correlated incidents); **MTTA** = mean(first-ack −
created); **MTTR** = mean(resolved − created); **%-actionable** = incidents acked/actioned ÷
total (auto-resolved-without-ack ≈ noise); **off-hours** from `created_at`.

- **PagerDuty** (VERIFIED): `GET /incidents?since=&until=&statuses[]=` + `GET /incidents/{id}/log_entries` for exact ack/resolve times. MTTA = `acknowledgements[0].at − created_at`; %-actionable = incidents with a non-empty `acknowledgements[]`. (`POST /analytics/metrics/incidents/all` is a read-only rollup with native business/off/sleep-hour interruption splits, but its **response field names are UNVERIFIED** ; prefer `GET /incidents`+`log_entries`.)
- **incident.io** (VERIFIED): `GET /v2/incidents` ; read `duration_metrics[].value_seconds` and `incident_timestamp_values[]` directly for MTTA/MTTR; exclude `incident_status.category ∈ {declined,canceled,merged}` from actionable.
- **Opsgenie** (VERIFIED): `GET /v2/alerts` (noise; `count` = de-dup occurrence = flap signal; `report.ackTime`/`report.closeTime` are seconds-to-ack/close, read directly) + `GET /v1/incidents`.
- **Zenduty** (**UNVERIFIED** ; docs migrated to Xurrent this session): a read-only incidents list with `creation_date` + a numeric status; **re-confirm against the live API before use** ; until then mark Zenduty incident-feed `verify-pending`.

Absent any incident feed **and** an operator `fatigue.json`, AF-003 is `not-in-scope` ; the
true ratio/MTTA/MTTR/%-actionable are never fabricated.
