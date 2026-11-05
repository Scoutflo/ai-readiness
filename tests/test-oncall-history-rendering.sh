#!/bin/sh
# Native incident summaries remain visible beside, and independent of, fire history.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VIZ="$ROOT/report-standard/render-report-viz.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
RD=2026-01-03
mkdir -p "$WORK/audits"
fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -Fq "$2" "$1" || fail "missing $2 in $(basename "$1")"; }
lacks() { if grep -Fq "$2" "$1"; then fail "unexpected $2 in $(basename "$1")"; fi; }
render() {
  sh "$VIZ" alert-fatigue "$1" "$WORK/audits" "$RD" > "$WORK/report.md"
  sh "$VIZ" alert-fatigue-html "$1" "$WORK/report.html" "$WORK/audits" "$RD" >/dev/null
}

cat > "$WORK/native.json" <<'JSON'
{
  "schema":"scoutflo-alert-fatigue/v1","scoring_scope":"non-scored",
  "totals":{"alerting_noise_findings":0,"cross_source_storms":0,"tools_with_noise":0,"fire_history_objects":0},
  "af_findings":[
    {"af_id":"AF-001","source_findings":[],"by_source":[]},
    {"af_id":"AF-003","status":"not-in-scope","reason":"Comparable alert counts were not supplied."},
    {"af_id":"AF-004","status":"not-in-scope"},
    {"af_id":"AF-005","status":"not-in-scope","total_fires":0,"objects_with_history":0,"incident_history_status":"measured","incident_history":[
      {"target":"splunk_oncall/alpha","status":"measured","complete_window":true,
       "window":{"started_after":"2026-01-01T00:00:00Z","started_before":"2026-01-03T00:00:00Z","query_phases":["resolved","triggered","acknowledged"]},
       "observed_incidents":3,"population_incidents":3,"expected_incidents":3,"count_unit":"incidents-started-in-window",
       "provider_alert_count":45,"provider_alert_count_unit":"alerts-received-over-incident-lifetime",
       "response":{"ack_samples":2,"resolution_samples":1,"mean_ack_seconds_observed_subset":30.125,"mean_resolution_seconds_observed_subset":0,"missing_or_unverified_transitions":1,"unacknowledged_or_censored":2},
       "limitations":["Recipient assignment does not prove receipt."]}
    ]},
    {"af_id":"AF-006","status":"not-in-scope"},
    {"af_id":"AF-007","histogram":[]}
  ]
}
JSON
render "$WORK/native.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'Native incident history'
  has "$f" 'splunk_oncall/alpha'
  has "$f" '2026-01-01T00:00:00Z'
  has "$f" 'resolved, triggered, acknowledged'
  has "$f" 'observed subset'
  has "$f" '30.13'
  has "$f" 'Recipient assignment does not prove receipt.'
  lacks "$f" '45 total fires'
  lacks "$f" '3 total fires'
  lacks "$f" 'null'
  lacks "$f" 'MTTA/MTTR'
done
has "$WORK/report.md" '| splunk_oncall/alpha | measured | 2026-01-01T00:00:00Z | 2026-01-03T00:00:00Z | resolved, triggered, acknowledged | yes | 3 | 3 | 45 |'
has "$WORK/report.md" '| splunk_oncall/alpha | 2 | 30.13 | 1 | 0 | 1 | 2 |'
lacks "$WORK/report.md" 'No alerting-noise findings and no measured fire-history were supplied'

# Incomplete history never renders a bogus complete population, but keeps its
# observed sample and query window. Text cannot inject Markdown/HTML structure.
jq '.af_findings[3].incident_history_status="blocked"
  | .af_findings[3].incident_history[0] |= (.status="blocked" | .complete_window=false
      | .observed_incidents=2 | .population_incidents=999 | .target="alpha|<script>unsafe</script>"
      | .reason="collection <incomplete> | narrow the window")' "$WORK/native.json" > "$WORK/partial.json"
render "$WORK/partial.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'blocked'
  has "$f" 'no; full-window totals unavailable'
  has "$f" 'not measured'
  has "$f" '&lt;script&gt;unsafe&lt;/script&gt;'
  has "$f" 'collection &lt;incomplete&gt;'
  lacks "$f" '<script>unsafe</script>'
  lacks "$f" '999'
done
has "$WORK/report.md" 'alpha&#124;&lt;script&gt;'

# A measured empty window has a real zero population, while zero transition
# samples cannot produce a zero-duration response measurement.
jq '.af_findings[3].incident_history[0] |= (.observed_incidents=0 | .population_incidents=0
  | .expected_incidents=0 | .provider_alert_count=0 | .response.ack_samples=0
  | .response.resolution_samples=0 | .response.mean_ack_seconds_observed_subset=0
  | .response.mean_resolution_seconds_observed_subset=0 | .response.missing_or_unverified_transitions=0
  | .response.unacknowledged_or_censored=0)' "$WORK/native.json" > "$WORK/zero.json"
render "$WORK/zero.json"
has "$WORK/report.md" '| yes | 0 | 0 | 0 |'
has "$WORK/report.md" '| splunk_oncall/alpha | 0 | not measured | 0 | not measured | 0 | 0 |'

# Unknown future units and shape variants fail closed rather than guessing or
# rendering object/array JSON as a measurement.
jq '.af_findings[3].incident_history[0] |= (.count_unit="future-event-unit"
  | .observed_incidents=777 | .population_incidents=777 | .window="future-shape"
  | .response=[42] | .limitations={"not":"text"})' "$WORK/native.json" > "$WORK/future.json"
render "$WORK/future.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'blocked'
  has "$f" 'not recorded'
  lacks "$f" '777'
  lacks "$f" 'null'
done

# Old fire-only input remains readable, with unchanged fire counters and no
# fabricated native incident section; both lanes can coexist in newer input.
jq '.totals.fire_history_objects=1 | .af_findings[3] |= (.status="measured"
  | .total_fires=13 | .objects_with_history=1 | .flapping_objects=0
  | .top_offenders=[{"object_id":"alarm-a","provider":"example","fires":13,"flapping":false,"reaches_human":true,"fatigue_impact":13}]
  | del(.incident_history,.incident_history_status))' "$WORK/native.json" > "$WORK/legacy.json"
render "$WORK/legacy.json"
has "$WORK/report.md" '13 total fires across 1 object(s)'
has "$WORK/report.html" 'Measured fire-history'
for f in "$WORK/report.md" "$WORK/report.html"; do lacks "$f" '>Native incident history<'; done
lacks "$WORK/report.md" '### Native incident history'
jq --slurpfile native "$WORK/native.json" '.af_findings[3].incident_history=$native[0].af_findings[3].incident_history
  | .af_findings[3].incident_history_status="measured"' "$WORK/legacy.json" > "$WORK/mixed.json"
render "$WORK/mixed.json"
has "$WORK/report.md" '13 total fires across 1 object(s)'
has "$WORK/report.md" '### Native incident history'
has "$WORK/report.html" '>Native incident history<'
# Useful native observations must reach both views, not remain buried in JSON.
# These are synthetic refs and durations, never copied from a provider receipt.
jq '.af_findings[3].incident_history[0] |= (
  .recurrence={interpretation:"review-candidates-not-proven-noise",incidents_missing_entity:0,
    ranked_entities:[{entity_ref:"entity-aaaaaaaaaaaaaaaaaaaaaaaa",service_ref:"service-bbbbbbbbbbbbbbbbbbbbbbbb",host_ref:null,
      incidents:2,incident_numbers:["7","8"],provider_alert_count:12}]}
  | .workload={interpretation:"assignments-not-pages-or-human-interruptions",off_hours:null,fairness:null,
    incident_assignment_counts:[{responder_ref:"responder-cccccccccccccccccccccccc",incidents:3}],
    team_assignment_counts:[{team:"team-blue",incidents:3}],
    assignment_time:{team:"team-blue",started_at:"2026-01-01T00:00:00Z",ended_at:"2026-01-03T00:00:00Z",
      lag_seconds:900,interpretation:"assignment-time-not-interruptions",users:[{user_ref:"log-user-dddddddddddddddddddddddd",
        reported_total:{hours:5,minutes:12},reported_adjusted_total:{hours:4,minutes:7},
        intervals:[{on:"2026-01-01T00:00:00Z",off:"2026-01-01T03:00:00Z"},
                   {on:"2026-01-01T01:00:00Z",off:"2026-01-01T04:00:00Z"}]}]}}
  | .context=[{incident_number:"9",original_alert_read:true,message_type:"CRITICAL",interpretation:"presence-only",
      fields_present:{entity:true,description:true,monitoring_tool:true,display_name:null},
      raw_fields_present:{service:false,environment:false,owner:null,runbook:true,impact:false}}]
)' "$WORK/native.json" > "$WORK/details.json"
render "$WORK/details.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'Recurrence candidates'
  has "$f" 'entity-aaaaaaaaaaaaaaaaaaaaaaaa'
  has "$f" '7, 8'
  has "$f" 'Observed incident assignments'
  has "$f" 'responder-cccccccccccccccccccccccc'
  has "$f" 'team-blue'
  has "$f" 'Reported duty observations'
  has "$f" 'log-user-dddddddddddddddddddddddd'
  has "$f" '5 h 12 min'
  has "$f" '4 h 7 min'
  has "$f" '2026-01-01T01:00:00Z to 2026-01-01T04:00:00Z'
  has "$f" 'reporting lag 900 seconds'
  has "$f" 'Do not sum overlapping intervals'
  has "$f" 'Selected original-alert context'
  has "$f" 'service, environment, impact'
  has "$f" 'Presence is not correctness'
  has "$f" 'may be outside the incident cohort'
  has "$f" 'Off-hours and fairness are not assessed'
  lacks "$f" '12 total fires'
  lacks "$f" '6 h 0 min'
done
has "$WORK/report.md" '| entity-aaaaaaaaaaaaaaaaaaaaaaaa | service-bbbbbbbbbbbbbbbbbbbbbbbb | not recorded | 2 | 7, 8 | 12 |'
has "$WORK/report.md" '| Responder | responder-cccccccccccccccccccccccc | 3 |'
has "$WORK/report.md" '| 9 | CRITICAL | Raw context | runbook | service, environment, impact | owner |'
has "$WORK/report.md" '| 9 | CRITICAL | Basic | entity, description, monitoring_tool | none observed | display_name |'

# Partial observations retain useful rows with their exact window, never a
# complete-population claim. Contradictory recurrence counts are unavailable.
jq '.af_findings[3].incident_history[0] |= (.status="blocked"|.complete_window=false|.population_incidents=null)' "$WORK/details.json" > "$WORK/detail-partial.json"
render "$WORK/detail-partial.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'no; full-window totals unavailable'
  has "$f" 'entity-aaaaaaaaaaaaaaaaaaaaaaaa'
  has "$f" 'Observed details for splunk_oncall/alpha'
done
jq '.af_findings[3].incident_history[0].recurrence.ranked_entities[0].incidents=444' "$WORK/details.json" > "$WORK/detail-count.json"
render "$WORK/detail-count.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'Inconsistent recurrence counts are unavailable.'
  lacks "$f" '444'
done

# Unknown units cannot sneak nested incident counts, duty measurements or
# original-context claims past the top-level guard.
jq '.af_findings[3].incident_history[0] |= (.count_unit="future-units"|.observed_incidents=777
  | .recurrence.ranked_entities[0].incidents=777 | .workload.incident_assignment_counts[0].incidents=777)' "$WORK/details.json" > "$WORK/detail-future.json"
render "$WORK/detail-future.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  lacks "$f" '777'
  lacks "$f" 'entity-aaaaaaaaaaaaaaaaaaaaaaaa'
  lacks "$f" '5 h 12 min'
  lacks "$f" 'CRITICAL'
  has "$f" 'No supported rows supplied'
done

# Malformed optional structures do not abort rendering or stringify secrets.
# Truthy strings are unknown, never present/absent evidence. HTML/table text is escaped.
jq '.af_findings[3].incident_history[0] |= (.target="alpha|<em>unsafe</em>"
  | .recurrence.ranked_entities=[null,42,{entity_ref:{secret:"DO-NOT-RENDER"},incidents:"888",incident_numbers:[{},42]}]
  | .workload.incident_assignment_counts="DO-NOT-RENDER"
  | .workload.team_assignment_counts=[null,{team:"<script>unsafe</script>",incidents:-1}]
  | .workload.assignment_time.users[0].reported_total={hours:"DO-NOT-RENDER",minutes:5}
  | .workload.assignment_time.users[0].intervals=[null,42,{on:"<script>unsafe</script>",off:null}]
  | .context[0].raw_fields_present={service:"true",environment:"false",owner:"DO-NOT-RENDER",runbook:false,impact:true}
  | .context += [null,42])' "$WORK/details.json" > "$WORK/detail-hostile.json"
render "$WORK/detail-hostile.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  lacks "$f" 'DO-NOT-RENDER'
  lacks "$f" '<script>unsafe</script>'
  lacks "$f" '<em>unsafe</em>'
  lacks "$f" '888'
  has "$f" '&lt;em&gt;unsafe&lt;/em&gt;'
  has "$f" 'service, environment, owner'
done
has "$WORK/report.md" '| 9 | CRITICAL | Raw context | impact | runbook | service, environment, owner |'

# Duty data from a different window cannot be presented as this cohort. Two
# targets retain separate detail sections rather than merging equal entity refs.
jq '.af_findings[3].incident_history[0].workload.assignment_time.started_at="2025-12-31T00:00:00Z"' "$WORK/details.json" > "$WORK/detail-wrong-window.json"
render "$WORK/detail-wrong-window.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  lacks "$f" '5 h 12 min'
  has "$f" 'A supported duty log matching this window was not supplied'
done
jq '.af_findings[3].incident_history += [.af_findings[3].incident_history[0] | .target="splunk_oncall/beta"
  | .workload.team_assignment_counts[0].team="team-gold"]' "$WORK/details.json" > "$WORK/detail-multitarget.json"
render "$WORK/detail-multitarget.json"
for f in "$WORK/report.md" "$WORK/report.html"; do
  has "$f" 'Observed details for splunk_oncall/alpha'
  has "$f" 'Observed details for splunk_oncall/beta'
  has "$f" 'team-blue'
  has "$f" 'team-gold'
done
echo 'ONCALL-HISTORY-RENDERING-OK: native, partial, zero, escaped, future, legacy, mixed, recurrence, assignments, duty, context and malformed reports'
