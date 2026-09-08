# Fire-history reads — the measured tier (read-only, per provider)

The config-tier audits answer *"is this rule shaped well?"*. This lane answers the
question that actually proves fatigue: *"how did each alert BEHAVE — how often did it
fire, does it flap, is it stuck, does it reach a human?"* Those are **measured** numbers,
so the alert-fatigue skill collects them itself with **read-only** calls, normalizes them
into `fatigue-signals.json`, and the roll-up library
([lib/alert-fatigue.sh](../lib/alert-fatigue.sh)) analyzes them (AF-004…007) alongside the
config findings. **The provider calls happen HERE, in the skill's collection lane (the
audit lane is allowed to call providers); the roll-up library still makes zero provider
calls.** Every call below is a GET or a documented read-by-POST (a query/search body, no
state change) — this lane never mutates.

**Never fabricate.** A provider that cannot expose history (no permission / API not
present) marks that provider's fire-history tier `verify-pending` in
`provider_coverage[]` — never a guessed number. **Off-hours has no native field anywhere**
— it is always *derived* from a fire timestamp against the business-hours window; say so.

**Bounded.** Honor the estate-scope checkpoint: page/window the history reads (all the
APIs below paginate) and cap the object set on a large estate before pulling per-object
history, so the lane never grinds.

**Reuse the config audit's inventory — don't re-enumerate.** If the provider's audit
already ran today (its `inventory.json` / `findings.json` exist under the audits dir),
take the **object set** (the alarms/rules/monitors and their routing) from there and pull
only the **history delta** per object — never re-list the whole estate. Example:
`audit-aws` already enumerates every CloudWatch alarm and its `AlarmActions`/SNS wiring
(and often flags the zero-subscriber and stuck-in-ALARM cases at the config tier); the
fire-history lane reads that inventory for the alarm set + routing verdict and adds only
`DescribeAlarmHistory` per alarm — it does not re-run `describe-alarms` across the account.
This keeps the two consistent (one enumeration, no double-pull) and bounds the lane on a
large estate. Cite the config finding in each signal's `source_finding_ids` so the analysis
joins back rather than restating.

## Output contract — `fatigue-signals.json` (`scoutflo-fatigue-signals/v1`)

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
    { "provider": "aws",     "tier": "fire-history", "status": "collected", "objects": 118 },
    { "provider": "datadog", "tier": "fire-history", "status": "verify-pending", "reason": "events read returned 403 (needs events_read scope)" }
  ],
  "incident_feed": {          // OPTIONAL — the incident-feed tier for AF-003 (see §incident-feed)
    "status": "collected", "source": "pagerduty", "window": "30d",
    "alerts_fired": 420, "incidents": 7, "mtta_seconds": 180, "mttr_seconds": 3600, "actionable_pct": 38 }
}
```

Only emit a field you actually measured. A missing field is honest; a fabricated one is a bug.

---

## AWS CloudWatch  (VERIFIED read-only)

- **Fire history:** `aws cloudwatch describe-alarm-history --history-item-type StateUpdate --start-date <ts> --end-date <ts> [--alarm-name N] [--max-records 100] [--next-token …]`. Each `AlarmHistoryItems[]` has `AlarmName`, `Timestamp`, `HistoryData` (JSON) and `HistorySummary` (text). **`fires`** = count of items whose transition ends in `ALARM`; **`transitions`/`flapping`** = order items by `Timestamp` and count `OK↔ALARM` oscillations. *Caveat:* the `HistoryData` internal keys (`newState.stateValue`/`oldState.stateValue`) are **UNVERIFIED as documented field names** — parse defensively and fall back to `HistorySummary` text.
- **Stuck:** `aws cloudwatch describe-alarms` → an alarm with `StateValue == "ALARM"`; `stuck_since` = `StateTransitionedTimestamp` ("most recently changed"); `stuck_days` = now − that. (`StateUpdatedTimestamp` is the looser field; prefer `StateTransitionedTimestamp`.)
- **reaches_human (dead-end):** for each alarm, `AlarmActions[]` → filter `arn:aws:sns:*` → `aws sns list-subscriptions-by-topic --topic-arn <arn>` → `reaches_human=false` when `Subscriptions` is empty, or all `SubscriptionArn == "PendingConfirmation"` (**PendingConfirmation sentinel is UNVERIFIED on the API page — confirm live**), or the alarm's `ActionsEnabled == false`.
- **off_hours_fires:** bucket each `StateUpdate` `Timestamp` (UTC → business TZ) against the business-hours window.

## Datadog  (VERIFIED read-only; v2 search is a read-only POST)

- **Fire history:** v1 `GET /api/v1/events?sources=alert&start=<unixsec>&end=<unixsec>` (≤1000 results; fields `alert_type`, `date_happened`, `tags`, `title`) — count `sources=alert` events per monitor; **or** v2 `POST /api/v2/events/search` (body `filter{query:"source:alert monitor_id:<id>",from,to}`) where `data[].attributes.attributes.status ∈ {error,warn}` = fire and `ok` = recovery, grouped by **`aggregation_key`** (unique per monitor id since 2025-03-01; there is **no `monitor_id` field** on the alert-event attributes — use `aggregation_key` or a `monitor_id:` query scope).
- **Stuck:** `GET /api/v1/monitor/{id}` → `overall_state ∈ {Alert,Warn}` with `state.groups[*].last_triggered_ts` far in the past and no later `last_resolved_ts`; `stuck_since ≈ last_triggered_ts`. (`state.groups[].triggering_value` and `overall_state_modified` are **UNVERIFIED/absent in the API client** — use `last_triggered_ts`/`last_resolved_ts`.)
- **flapping:** sort a monitor's events by `date_happened`/`timestamp`, count trigger↔recovery oscillations.
- **Mute-aware:** `GET /api/v2/downtime` — exclude muted windows from the noise count.
- **off_hours_fires:** bucket `date_happened` (Unix **seconds**; v2 `timestamp` may be ms — verify unit live) against business hours.

## Grafana Alerting  (VERIFIED read-only)

- **Fire history:** `GET /api/annotations?type=alert&from=<ms>&to=<ms>[&alertId=N&limit=N]` — per-annotation `time`, `timeEnd`, `newState`, `prevState`, `tags`. `fires` = annotations where `newState` = Alerting; `flapping` = count `Alerting↔Normal` oscillations by rule. (The Loki-backed `GET /api/v1/rules/history?ruleUID=…&from=&to=` gives richer per-transition history but **requires a Loki state-history backend**; its emitted frame field names are **UNVERIFIED** — prefer annotations when Loki isn't configured.)
- **Stuck:** `GET /api/prometheus/grafana/api/v1/rules` → rule `state == "firing"/"Alerting"`; `stuck_since` = the alert's `activeAt` (Prometheus rules schema).
- **off_hours_fires:** bucket annotation `time` (epoch **ms**) against business hours.

## Prometheus  (VERIFIED read-only)

Query `GET /api/v1/query` / `query_range` over the two synthetic series (both VERIFIED from
prometheus.io + `rules/alerting.go`): `ALERTS{alertstate="pending|firing"}` (value `1` while
active) and `ALERTS_FOR_STATE` (value = the alert's `ActiveAt` **Unix-seconds** timestamp).

- **fires / top-noisy:** `sort_desc(count by (alertname)(count_over_time(ALERTS{alertstate="firing"}[<window>])))`.
- **flapping:** `changes(ALERTS_FOR_STATE{...}[<window>])` — each clear→re-fire resets `ActiveAt`, so `changes()` = number of distinct fire episodes.
- **stuck / chronic:** `count_over_time(ALERTS{alertstate="firing"}[<window>]) / (<window_seconds> / <eval_interval_seconds>) > 0.9`; `stuck_since` = `time() - ALERTS_FOR_STATE` seconds continuously active.
- **off_hours_fires:** derive from the fire-episode start (`ALERTS_FOR_STATE` value / first `changes()` step).

## Alertmanager  (VERIFIED read-only)

- **Notification volume (scraped counters, query via Prometheus PromQL):** `alertmanager_notifications_total{integration}` ("total attempted notifications"), `alertmanager_notifications_failed_total{integration,reason}`, `alertmanager_notifications_suppressed_total{reason}` ("silenced/inhibited/outside active/within muted"). Noise-by-channel = `sort_desc(sum by (integration)(increase(alertmanager_notifications_total[<window>])))`; suppression ratio = suppressed ÷ total. (`alertmanager_alerts{state}` gauge name is **UNVERIFIED** — confirm from a live `/metrics`.)
- **Batching / effectively-disabled:** `GET /api/v2/alerts/groups` (real notification units vs raw alert count); `GET /api/v2/silences` → an `active` silence with a long `endsAt-startsAt` whose `matchers` cover a currently-firing alert (cross-join `GET /api/v2/alerts?active=true&silenced=true`) = an alert silenced into oblivion → `reaches_human=false`, reason "covered by a long-standing silence".

## SigNoz  (read routes VERIFIED from source; the history API is undocumented publicly)

Rule history routes (registered in `http_handler.go`, `ViewAccess`, POST-bodied analytical
reads — no mutation): `POST /api/v1/rules/{id}/history/stats|timeline|top_contributors|overall_status`,
request `{start,end (epoch ms),state,filters,offset,limit,order}`.
- **fires:** `Stats.TotalCurrentTriggers` (vs `TotalPastTriggers` for trend), or count `timeline.items[]` where `state=="firing"`.
- **flapping:** count firing↔normal transitions per `fingerprint` in `history/timeline`.
- **stuck / since-when:** a `fingerprint` whose earliest firing `unixMilli` is far in the past with no intervening `normal`; `stuck_since` = that `unixMilli`.
- **top-noisy:** `history/top_contributors`. **Resolution health:** `Stats.CurrentAvgResolutionTime`.
- The ClickHouse alert-state-history table is a fallback but its **name is UNVERIFIED** — prefer the REST routes; if neither is reachable, mark SigNoz fire-history `verify-pending`.

---

## Incident-feed tier — the TRUE ratio, MTTA/MTTR, %-actionable (for AF-003)

Populate `incident_feed{}` in `fatigue-signals.json` from a read-only incident/ack stream so
AF-003 is a **measured** ratio, not an operator guess. General derivation: **ratio** = (alerts
fired in window, from the reads above) ÷ (correlated incidents); **MTTA** = mean(first-ack −
created); **MTTR** = mean(resolved − created); **%-actionable** = incidents acked/actioned ÷
total (auto-resolved-without-ack ≈ noise); **off-hours** from `created_at`.

- **PagerDuty** (VERIFIED): `GET /incidents?since=&until=&statuses[]=` + `GET /incidents/{id}/log_entries` for exact ack/resolve times. MTTA = `acknowledgements[0].at − created_at`; %-actionable = incidents with a non-empty `acknowledgements[]`. (`POST /analytics/metrics/incidents/all` is a read-only rollup with native business/off/sleep-hour interruption splits, but its **response field names are UNVERIFIED** — prefer `GET /incidents`+`log_entries`.)
- **incident.io** (VERIFIED): `GET /v2/incidents` — read `duration_metrics[].value_seconds` and `incident_timestamp_values[]` directly for MTTA/MTTR; exclude `incident_status.category ∈ {declined,canceled,merged}` from actionable.
- **Opsgenie** (VERIFIED): `GET /v2/alerts` (noise; `count` = de-dup occurrence = flap signal; `report.ackTime`/`report.closeTime` are seconds-to-ack/close, read directly) + `GET /v1/incidents`.
- **Zenduty** (**UNVERIFIED** — docs migrated to Xurrent this session): a read-only incidents list with `creation_date` + a numeric status; **re-confirm against the live API before use** — until then mark Zenduty incident-feed `verify-pending`.

Absent any incident feed **and** an operator `fatigue.json`, AF-003 is `not-in-scope` — the
true ratio/MTTA/MTTR/%-actionable are never fabricated.
