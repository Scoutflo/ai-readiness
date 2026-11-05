# History, response and incident noise

Use this read-only lane for SOC-012, SOC-013, SOC-014, SOC-015 and SOC-017 after the normal doctor and identity gate. It supplies evidence for your checks; it does not assign severity, create a new score, page someone or change an incident. Read the complete check catalog before choosing a result.

## Collection

Choose explicit historical UTC bounds and state them in the report. The history API defaults to resolved incidents only; this recipe always requests `resolved,triggered,acknowledged`, offset 0 and limit 100. Query values differ from the schema's uppercase response phases. Populated responses have also returned lowercase phases and transition verbs. The recipe explicitly normalizes these known values; unknown strings remain missing evidence.

```bash
set -eu
umask 077
PLUGIN="${CLAUDE_PLUGIN_ROOT:?installed plugin root}"
START="${SCOUTFLO_HISTORY_START:?explicit UTC window start}"
END="${SCOUTFLO_HISTORY_END:?explicit UTC window end in the past}"
STATE="${SCOUTFLO_HISTORY_STATE:?private fixed run directory retained for resume}"
OUT="${SCOUTFLO_ONCALL_RUN_DIR:?this target and fixed audit date directory}"
mkdir -p "$OUT"
sh "$PLUGIN/skills/audit-splunk-oncall/scripts/history.sh" \
  --start "$START" --end "$END" --state-dir "$STATE" \
  > "$OUT/oncall-history.json"
```

The reader resolves the configured target and read-only credential names through the shared toolkit parser, then checks the anchor team's identity before and after collection. Management requests use fixed-origin HTTPS GET with no redirects, a 25-second timeout and a 2 MiB body ceiling. API errors are not empty lists. The reader emits only safe projections, never raw responses, messages, contact details, routing keys, incoming-alert credentials or URLs. Entity/service/host and responder identities become opaque deterministic references; they are grouping keys within this evidence, not canonical service mappings.

One request is sufficient for a small cohort of at most 100 incidents. The default invocation budget is one history request. Larger cohorts retain their offset and safe rows; rerun the **same command and state directory** until `collection.complete` is true. `--page-budget N` permits 1 through 20 reporting requests in one invocation. Every reporting request respects the provider's one-call-per-minute budget, including restarts; a shared private credential-budget lock prevents this recipe from racing with another run. Coordinate other clients using the same account because a local lock cannot govern their requests.

Resume binds the exact target, anchor team, credentials, window and optional selected reads. A changed binding fails closed. State is private and locked; do not steal a lock while a reader may be active. An interrupted transport attempt has already consumed its rate budget. Duplicate IDs, short pages, changed totals, changed first-page evidence on a multipage verification pass, unsupported shapes and denied reads prevent a complete cohort. A multipage pass is a bounded observation, never an atomic database snapshot. More than 10,000 incidents requires narrower windows; no truncation can become a population total. Keep adjacent windows' exclusive boundary semantics explicit before combining them.

An empty complete response proves that the provider returned no incidents for those exact filters; it does not prove parsing of optional incident fields, zero historical backlog, zero source alerts or healthy paging. `collection.verification: response-asserted` means assertions passed on the returned response; it does not claim a representative workload or tenant-independent grounding.

Optional selected reads use the same window and credential binding:

- `--context-incident NUMBER` fetches the selected incident's `firstAlertUuid` and then its original alert from the fixed management API. It records only known field-presence booleans. It never follows the latest alert instead of the original, dereferences an arbitrary runbook URL or stores raw JSON. A selected context observation is not coverage of all incidents.
- `--workload-team SLUG` reads that team's historical on-call log with explicit start/end. It retains reported duration components and safe interval timestamps. The endpoint can lag by 15 minutes. Its user IDs and incident `pagedUsers` usernames are different identity namespaces and cannot be joined by position or spelling assumptions.

Run local validation and measurement in a fresh shell:

```bash
set -eu
PLUGIN="${CLAUDE_PLUGIN_ROOT:?installed plugin root}"
OUT="${SCOUTFLO_ONCALL_RUN_DIR:?this target and fixed audit date directory}"
RUN_DATE="${SCOUTFLO_RUN_DATE:?fixed audit UTC date}"
TARGET="${SCOUTFLO_ONCALL_TARGET:?splunk_oncall or splunk_oncall/label}"
sh "$PLUGIN/skills/audit-splunk-oncall/scripts/history.sh" \
  --summarize "$OUT/oncall-history.json" --run-date "$RUN_DATE" --target "$TARGET" \
  > "$OUT/oncall-history-summary.json"
```

This mode makes no provider calls and needs no credentials. It rejects wrong target/date, unrecognized projection fields, unsafe or malformed identifiers, invalid times and contradictory counts. Collection time belongs to the selected audit UTC date; this does not mean every event happened that day.

## Assessment

| Check | Evaluate from these observations | Evidence needed before a failure or pass |
| --- | --- | --- |
| SOC-012 response and aging | First observed acknowledgement/resolution latency, sample counts, missing transitions, censored/open incidents and current age | Your explicit response objective, complete requested cohort, validated transition names/units, timezone and age reference. Report observed-subset means with their denominator. Missing acknowledgements stay censored; do not discard them or call the resulting subset mean population MTTA. Older open incidents need a separate backlog read because they fall outside this start-window cohort. |
| SOC-013 recurring incident noise | Exact entity/service/host recurrence ranking, incident counts, phase distribution and incident-lifetime alert totals | Your paging budget, representative window and source evidence linking repeated episodes. A frequent entity is a review candidate. A new incident can be a legitimate recurrence; an acknowledged or automatically resolved incident does not establish actionability or false positives. |
| SOC-014 entity and recovery | Same entity across original trigger and recovery, repeated episodes, resolution transitions and missing identities | Correlated source lifecycle evidence proving that recovery belongs to the same monitored condition and preserves identity. A resolution alone does not prove automatic recovery, meaningful deduplication, correct source grouping or human delivery. Source-side `send_resolved`, labels, grouping, debounce and severity decisions belong in their source audit/setup lane. |
| SOC-015 responder workload | Incident assignment counts by safe responder/team reference and selected team's reported duty intervals | Intended staffing/weights, business hours/timezone, holiday policy, complete source notification or interruption data if claimed, and a window older than log lag. Duty time is not interruptions; `pagedUsers` is not a notification-attempt count. Do not declare unfairness from unequal assignments without a declared duty model. |
| SOC-017 actionable context | Presence of entity, original description, monitoring tool, display name and selected raw service/environment/owner/runbook/impact fields | Human review that values are correct, useful and relate to the intended service. Presence is not correctness or runbook reachability. Missing keys in a selected original alert justify a bounded observation, not an account-wide absence claim. |

Keep missing or incomplete scored evidence `blocked` using the existing result enum. “Unknown” is explanatory language only. An intentional exemption needs the existing provenance and expiry mechanism. Low incident counts, a clean QA fixture or one successful notification cannot establish a healthy production distribution. Keep observed source identifiers separate from source-verified canonical `correlation_affected` mappings.

## Fatigue handoff

Retain `oncall-history.json` beside the exact target/date `findings.json`. `/scoutflo:alert-fatigue` discovers both map and labeled-target paths and validates them locally. It adds native history under AF-005 `incident_history[]`, with its own `incident_history_status`; existing fire counts remain unchanged. It does not promote a history projection into `fatigue-signals.json` or generate a fabricated `fires` value.

The units remain separate:

- `population_incidents`: incidents that started inside a complete requested window. Incomplete or malformed cohorts have no population value.
- `observed_incidents`: rows actually collected, including a clearly incomplete subset.
- `provider_alert_count`: reported alerts received across those incidents' **lifetimes**, which can extend outside the requested start window. This is not a source-window event count or notification count.
- `notification_attempts` and `human_receipts`: unknown unless separately observed with their own provenance. Neither acknowledgement nor a list of paged users supplies these counts.

AF-003 requires separately grounded matching source-event and incident cohorts. Native history alone cannot produce an alert-to-incident ratio, actionable percentage, false-positive rate, recall or missed-incident count. Comparing incident counts across targets also requires a verified correlation; two tools observing one path are not necessarily duplicate pages.

## Acceptance

Before shipping a changed interpretation, execute the history fixture suite and the alert-fatigue native-history suite in fresh shells. Exercise a complete lowercase populated response, unresolved/censored incidents, unknown and future transitions, optional fields absent, hostile raw credentials, original versus latest alert identity, same-day wrong target, stale collection, duplicate JSON/incident IDs, short pages, moving totals, interruption and changed credentials. Confirm that reports preserve population denominators and never turn partial collection into zero noise or a pass.

Pressure scenario: a team says “all 101 incidents were resolved, so mark fatigue healthy” after the first 100-row page, while one ACKED incident and later status updates shift the second page. Resume the fixed window with the reporting budget; keep the population blocked until IDs, totals and boundary verification reconcile. Show the observed subset, ask for the declared paging/response objectives, and route source grouping or recovery fixes to the source setup skill. Do not send a test page from this audit or infer that resolved incidents were non-actionable.

Official contracts: [incident history API](https://portal.victorops.com/api-docs/), [On-Call documentation](https://help.splunk.com/en/splunk-on-call). The public API specification describes all incident fields as optional. Live populated field assertions and representative behavioral proof remain separate gates.
