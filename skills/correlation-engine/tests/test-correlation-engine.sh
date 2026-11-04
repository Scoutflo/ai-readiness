#!/bin/sh
# test-correlation-engine.sh — tests the real correlation library
# (lib/correlation-engine.sh) under /bin/sh with runtime-built fixtures.
#
# Pins the counter arithmetic that broke on a real campaign: overlap groups are
# per-service, so one finding naming many affected services sits in many groups;
# the old sum-of-(group-size - 1) counted that finding once per group and drove
# total_findings_deduplicated NEGATIVE on real inputs (raw 32, "dupes" 38,
# total -6). These tests enforce the invariants that make the counter sane:
#   I1. every counter in correlation.json is a number >= 0
#   I2. 0 <= total_findings_deduplicated <= total_findings_raw
#   I3. dedup total reconciles with inputs:
#         total_findings_raw == sum of findings across input files, and
#         total_findings_deduplicated == raw - (distinct candidate duplicates
#         recomputed from the overlaps the engine itself emitted)
#   I4. every finding an overlap references exists in this run's inputs
# All fixture names are synthetic (svc-*, TGT*); no real estate values.

set -eu

LIB_DIR="$(cd "$(dirname "$0")/../lib" && pwd)"

fail() { echo "FAIL: $1" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

DATE="2026-01-15"

# write_findings <dir> <target> <findings-json-array>
write_findings() {
  mkdir -p "$1/$2/$DATE"
  jq -n --arg t "$2" --argjson f "$3" \
    '{target: $t, audit_date: "2026-01-15", findings: $f}' \
    > "$1/$2/$DATE/findings.json"
}

# write_findings_2level <dir> <integration> <label> <target-field> <findings-json-array>
# Writes the two-level <integration>/<label>/<date>/findings.json layout a
# multi-target labeled audit (and single-block signoz/kubernetes) emits.
write_findings_2level() {
  mkdir -p "$1/$2/$3/$DATE"
  jq -n --arg t "$4" --argjson f "$5" \
    '{target: $t, audit_date: "2026-01-15", findings: $f}' \
    > "$1/$2/$3/$DATE/findings.json"
}

# run_engine <audit-dir> — runs correlation_run in a subshell so each case gets
# its own SCOUTFLO_AUDIT_DIR (the lib resolves paths at source time) and no
# machine state (~/.scoutflo business context / topology) leaks in.
run_engine() {
  (
    SCOUTFLO_AUDIT_DIR="$1"
    BC_JSON="$1/absent-business-context.json"
    TOPOLOGY_FILE="$1/absent-topology.json"
    export SCOUTFLO_AUDIT_DIR BC_JSON TOPOLOGY_FILE
    . "$LIB_DIR/correlation-engine.sh"
    correlation_run "$DATE"
  ) > /dev/null
}

# check_invariants <audit-dir> <label> — asserts I1-I4 on <dir>/correlation.json
# against the actual input findings.json files under <dir>/*/<date>/.
check_invariants() {
  dir="$1"; label="$2"
  corr="$dir/correlation.json"
  [ -f "$corr" ] || fail "$label: correlation.json was not written"

  expected_raw=$(jq -s '[ .[] | (.findings // []) | length ] | add // 0' \
    "$dir"/*/"$DATE"/findings.json)
  known_ids=$(jq -s \
    '[ .[] | (.target // "unknown") as $t | (.findings // [])[] | "\($t)/\(.id)" ]' \
    "$dir"/*/"$DATE"/findings.json)

  jq -e --argjson expected_raw "$expected_raw" --argjson known "$known_ids" '
    # distinct candidate duplicates, recomputed from the emitted overlaps:
    # one row per finding per group, keep one representative per group,
    # count each finding at most once across groups
    ([ .overlaps[] | .findings | map({target, finding_id}) | unique
       | .[1:] | .[] ] | unique | length) as $dupes
    | ( [ .total_findings_raw, .total_findings_deduplicated,
          .total_overlaps_detected, .total_cascades_detected ]
        | all(type == "number" and . >= 0) )                          # I1
    and (.total_findings_deduplicated <= .total_findings_raw)          # I2
    and (.total_findings_raw == $expected_raw)                         # I3a
    and (.total_findings_deduplicated
         == (.total_findings_raw - $dupes))                            # I3b
    and (.total_overlaps_detected == (.overlaps | length))
    and (.total_cascades_detected == (.cascades | length))
    and ([ .overlaps[].findings[] | "\(.target)/\(.finding_id)" ]
         | all(. as $x | $known | index($x) != null))                  # I4
  ' "$corr" > /dev/null \
    || fail "$label: counter invariants violated: $(jq -c '{total_findings_raw, total_findings_deduplicated, total_overlaps_detected, total_cascades_detected}' "$corr")"
}

echo "=== Correlation Engine Tests (lib-backed) ==="

echo "Test 1: multi-service overlap — dedup counter must not go negative"
# The exact shape that produced -6 in production, reduced: two findings from
# two targets, each naming the SAME four affected services. Overlap grouping
# yields four per-service groups all containing the same two findings; the old
# arithmetic counted 4 duplicates from 2 raw findings (dedup = -2).
D1="$TMP_ROOT/case1"
write_findings "$D1" "target-a" '[
  {"id": "AAA-001", "title": "alert coverage gap", "severity": "high", "area": "alerting",
   "affected": ["svc-api", "svc-db", "svc-cache", "svc-queue"]}
]'
write_findings "$D1" "target-b" '[
  {"id": "BBB-001", "title": "monitor coverage gap", "severity": "medium", "area": "alerting",
   "affected": ["svc-api", "svc-db", "svc-cache", "svc-queue"]}
]'
run_engine "$D1"
check_invariants "$D1" "case1"
dedup=$(jq '.total_findings_deduplicated' "$D1/correlation.json")
[ "$dedup" -eq 1 ] || fail "case1: expected dedup 1 (2 raw - 1 duplicate), got $dedup"
echo "PASS"

echo "Test 2: NEGATIVE control — this shape must still trip the OLD arithmetic"
# Falsifiability: recompute the pre-fix formula (sum of group-size-1) on the
# overlaps the engine just emitted. If it no longer exceeds raw, this scenario
# stopped exercising the bug class and the suite is asserting nothing.
old_dupes=$(jq '[.overlaps[] | (.findings | length) - 1] | add // 0' "$D1/correlation.json")
raw=$(jq '.total_findings_raw' "$D1/correlation.json")
[ "$old_dupes" -gt "$raw" ] \
  || fail "negative control: old formula gives $old_dupes dupes for $raw raw — scenario no longer exercises the over-count"
echo "PASS (old formula would give $raw - $old_dupes = negative)"

echo "Test 3: hub finding across many groups is one duplicate, not six"
# One hub finding shares a service with six spoke findings across two other
# targets (the real campaign's 17-group TOPO-001 shape). Old arithmetic said
# 6 duplicates; only the hub is a candidate duplicate.
D3="$TMP_ROOT/case3"
write_findings "$D3" "target-a" '[
  {"id": "HUB-001", "title": "shared topology gap", "severity": "high", "area": "coverage",
   "affected": ["svc-1", "svc-2", "svc-3", "svc-4", "svc-5", "svc-6"]}
]'
write_findings "$D3" "target-b" '[
  {"id": "EDGE-001", "title": "gap one",   "severity": "low", "area": "alerting", "affected": ["svc-1"]},
  {"id": "EDGE-002", "title": "gap two",   "severity": "low", "area": "alerting", "affected": ["svc-2"]},
  {"id": "EDGE-003", "title": "gap three", "severity": "low", "area": "alerting", "affected": ["svc-3"]}
]'
write_findings "$D3" "target-c" '[
  {"id": "EDGE-004", "title": "gap four", "severity": "low", "area": "alerting", "affected": ["svc-4"]},
  {"id": "EDGE-005", "title": "gap five", "severity": "low", "area": "alerting", "affected": ["svc-5"]},
  {"id": "EDGE-006", "title": "gap six",  "severity": "low", "area": "alerting", "affected": ["svc-6"]}
]'
run_engine "$D3"
check_invariants "$D3" "case3"
dedup=$(jq '.total_findings_deduplicated' "$D3/correlation.json")
[ "$dedup" -eq 6 ] || fail "case3: expected dedup 6 (7 raw - 1 hub duplicate), got $dedup"
echo "PASS"

echo "Test 4: no cross-target overlap — dedup equals raw"
D4="$TMP_ROOT/case4"
write_findings "$D4" "target-a" '[
  {"id": "AAA-001", "title": "gap", "severity": "low", "area": "alerting", "affected": ["svc-one"]}
]'
write_findings "$D4" "target-b" '[
  {"id": "BBB-001", "title": "gap", "severity": "low", "area": "alerting", "affected": ["svc-two"]}
]'
run_engine "$D4"
check_invariants "$D4" "case4"
jq -e '.total_findings_deduplicated == 2 and .total_overlaps_detected == 0' \
  "$D4/correlation.json" > /dev/null \
  || fail "case4: expected dedup == raw == 2 with 0 overlaps: $(jq -c '{total_findings_raw, total_findings_deduplicated, total_overlaps_detected}' "$D4/correlation.json")"
echo "PASS"

echo "Test 5: duplicate service entries inside one affected list count once"
# A finding listing the same service twice must not inflate its group row count.
D5="$TMP_ROOT/case5"
write_findings "$D5" "target-a" '[
  {"id": "AAA-001", "title": "gap", "severity": "low", "area": "alerting",
   "affected": ["svc-api", "svc-api"]}
]'
write_findings "$D5" "target-b" '[
  {"id": "BBB-001", "title": "gap", "severity": "low", "area": "alerting", "affected": ["svc-api"]}
]'
run_engine "$D5"
check_invariants "$D5" "case5"
dedup=$(jq '.total_findings_deduplicated' "$D5/correlation.json")
[ "$dedup" -eq 1 ] || fail "case5: expected dedup 1 (2 raw - 1 duplicate), got $dedup"
echo "PASS"

echo "Test 6: no findings for the date records an explicit current empty result"
D6="$TMP_ROOT/case6"
mkdir -p "$D6"
run_engine "$D6" || fail "case6: engine must exit 0 when there is nothing to correlate"
jq -e --arg d "$DATE" '.audit_date==$d and .total_findings_raw==0 and .overlaps==[] and .cascades==[] and .coverage==[]' "$D6/correlation.json" >/dev/null \
  || fail "case6: empty current correlation result missing"
echo "PASS"

echo "Test 7: two-level <integration>/<label>/<date> layout is collected (dual-glob regression lock)"
# A multi-target labeled audit (e.g. azure/prod-core/) writes findings.json one
# level deeper than a single-target audit. The engine globs BOTH the one-level
# <target>/<date>/ and the two-level <integration>/<label>/<date>/ layouts; a
# one-level-only regression would silently drop these findings. Here the
# two-level finding shares an affected service with a one-level finding, so it
# must be BOTH collected (raw == 2) AND detected as a cross-target overlap.
D7="$TMP_ROOT/case7"
write_findings "$D7" "target-a" '[
  {"id": "AAA-001", "title": "one-level gap", "severity": "high", "area": "alerting",
   "affected": ["svc-shared"]}
]'
write_findings_2level "$D7" "azure" "prod-core" "azure/prod-core" '[
  {"id": "AZ-001", "title": "two-level gap", "severity": "medium", "area": "alerting",
   "affected": ["svc-shared"]}
]'
run_engine "$D7"
corr7="$D7/correlation.json"
[ -f "$corr7" ] || fail "case7: correlation.json was not written"
raw7=$(jq '.total_findings_raw' "$corr7")
[ "$raw7" -eq 2 ] \
  || fail "case7: two-level finding not collected — expected raw 2, got $raw7 (one-level-only glob regression)"
jq -e '
  [ .overlaps[] | select(.service == "svc-shared") | .findings[]
    | "\(.target)/\(.finding_id)" ]
  | any(. == "azure/prod-core/AZ-001")
' "$corr7" > /dev/null \
  || fail "case7: two-level finding azure/prod-core/AZ-001 not detected as an overlap on svc-shared — dual-glob broken: $(jq -c '{total_findings_raw, total_overlaps_detected, overlaps}' "$corr7")"
echo "PASS"

# --- case 8: cross-tool COVERAGE correlation (gap-covered-elsewhere) ------------
# A coverage-gap finding in one provider that is actively + routed-monitored by
# ANOTHER provider must be classified covered-elsewhere (single-tool-dependency),
# a gap nothing covers must be true-gap, and a disabled/route-less monitor must
# NOT count as coverage. This locks the inventory.json read + the honesty bar.
printf 'testing: cross-tool coverage classification (covered-elsewhere / true-gap / disabled-excluded) ... '
D8="$TMP_ROOT/case8"
write_findings "$D8" "azure" '[
  {"id": "AZR-002", "title": "no metric alerts on checkout", "severity": "critical", "area": "coverage", "affected": ["checkout"]},
  {"id": "AZR-003", "title": "no metric alerts on legacy-batch", "severity": "high", "area": "coverage", "affected": ["legacy-batch"]},
  {"id": "AZR-004", "title": "no metric alerts on search", "severity": "high", "area": "coverage", "affected": ["search"]}
]'
# Datadog inventory: an ACTIVE routed monitor on checkout; a DISABLED monitor on search.
mkdir -p "$D8/datadog/$DATE"
jq -n '{target: "datadog", audit_date: "2026-01-15", items: [
  {"kind": "monitor", "name": "checkout latency", "covers": "checkout", "enabled": true, "routes_to": "pagerduty"},
  {"kind": "monitor", "name": "search errors", "covers": "search", "enabled": false, "routes_to": "slack"}
]}' > "$D8/datadog/$DATE/inventory.json"
run_engine "$D8"
corr8="$D8/correlation.json"
[ -f "$corr8" ] || fail "case8: correlation.json was not written"
jq -e '.coverage[] | select(.finding_id=="AZR-002" and .classification=="covered-elsewhere" and (.covered_by[0].inventory_name=="checkout latency") and (.covered_by[0].match=="exact"))' "$corr8" >/dev/null \
  || fail "case8: AZR-002 (checkout) not classified covered-elsewhere by the active Datadog monitor: $(jq -c '.coverage' "$corr8")"
jq -e '.coverage[] | select(.finding_id=="AZR-003" and .classification=="true-gap")' "$corr8" >/dev/null \
  || fail "case8: AZR-003 (legacy-batch, nothing covers it) not classified true-gap: $(jq -c '.coverage' "$corr8")"
jq -e '.coverage[] | select(.finding_id=="AZR-004" and .classification=="true-gap")' "$corr8" >/dev/null \
  || fail "case8: AZR-004 (search) must be true-gap — the covering monitor is disabled, so it is NOT active coverage: $(jq -c '.coverage' "$corr8")"
[ "$(jq '.total_coverage_covered_elsewhere' "$corr8")" -eq 1 ] \
  || fail "case8: expected total_coverage_covered_elsewhere=1, got $(jq '.total_coverage_covered_elsewhere' "$corr8")"
# never mutate a finding's severity — coverage is advisory only
jq -e '.coverage[] | select(.finding_id=="AZR-002") | has("severity") | not' "$corr8" >/dev/null \
  || fail "case8: coverage entry must not carry/rewrite a finding severity (advisory only)"
echo "PASS"

# --- case 9: coverage_gap.signal precision --------------------------------------
# A finding carrying an explicit coverage_gap object is recognized as a coverage
# gap (no area+title heuristic needed) and the covered-elsewhere reframe names the
# exact signal, closing the service-matches-but-signal-differs blind spot.
printf 'testing: coverage_gap.signal drives precise covered-elsewhere wording ... '
D9="$TMP_ROOT/case9"
write_findings "$D9" "azure" '[
  {"id": "AZR-050", "title": "metric alert coverage", "severity": "critical", "area": "coverage", "affected": ["checkout"], "coverage_gap": {"signal": "CPU% metric alert", "kind": "metric_alert"}}
]'
mkdir -p "$D9/datadog/$DATE"
jq -n '{target: "datadog", audit_date: "2026-01-15", items: [
  {"kind": "monitor", "name": "checkout latency", "covers": "checkout", "enabled": true, "routes_to": "pagerduty"}
]}' > "$D9/datadog/$DATE/inventory.json"
run_engine "$D9"
corr9="$D9/correlation.json"
[ -f "$corr9" ] || fail "case9: correlation.json was not written"
jq -e '.coverage[] | select(.finding_id=="AZR-050" and .classification=="covered-elsewhere" and (.recommendation | test("CPU% metric alert")))' "$corr9" >/dev/null \
  || fail "case9: covered-elsewhere recommendation did not name the coverage_gap.signal (CPU% metric alert): $(jq -c '.coverage' "$corr9")"
echo "PASS"

# --- case 10: non-monitor alerting kinds count as coverage (v0.1.152 regex fix) -
# Before v0.1.152 the active() kind-regex only matched monitor|alert_rule|log_alert|
# activity_log_alert, so an AWS alarm / GCP alert_policy / ClickStack alert covering an
# Azure coverage-gap was silently dropped and the gap was falsely called true-gap. Lock
# the fix: an active+routed AWS alarm and GCP alert_policy must classify the matching
# Azure gaps covered-elsewhere, while a resource nothing covers stays true-gap.
printf 'testing: AWS alarm / GCP alert_policy count as active cross-tool coverage (kind-regex fix) ... '
D10="$TMP_ROOT/case10"
write_findings "$D10" "azure" '[
  {"id": "AZR-101", "title": "no metric alerts on checkout", "severity": "critical", "area": "coverage", "affected": ["checkout"]},
  {"id": "AZR-102", "title": "no metric alerts on search",   "severity": "high",     "area": "coverage", "affected": ["search"]},
  {"id": "AZR-103", "title": "no metric alerts on legacy-batch", "severity": "high",  "area": "coverage", "affected": ["legacy-batch"]}
]'
# AWS inventory: an ACTIVE routed CloudWatch alarm (kind alarm) on checkout.
mkdir -p "$D10/aws/$DATE"
jq -n '{target: "aws", audit_date: "2026-01-15", items: [
  {"kind": "alarm", "name": "checkout 5xx", "covers": "checkout", "enabled": true, "routes_to": "sns-payments"}
]}' > "$D10/aws/$DATE/inventory.json"
# GCP inventory: an ACTIVE routed alert policy (kind alert_policy) on search.
mkdir -p "$D10/gcp/$DATE"
jq -n '{target: "gcp", audit_date: "2026-01-15", items: [
  {"kind": "alert_policy", "name": "search latency", "covers": "search", "enabled": true, "routes_to": "pagerduty"}
]}' > "$D10/gcp/$DATE/inventory.json"
run_engine "$D10"
corr10="$D10/correlation.json"
[ -f "$corr10" ] || fail "case10: correlation.json was not written"
jq -e '.coverage[] | select(.finding_id=="AZR-101" and .classification=="covered-elsewhere" and (.covered_by[0].provider=="aws") and (.covered_by[0].inventory_name=="checkout 5xx"))' "$corr10" >/dev/null \
  || fail "case10: AZR-101 (checkout) not covered by the AWS alarm kind — the kind-regex still drops non-monitor alerting kinds: $(jq -c '.coverage' "$corr10")"
jq -e '.coverage[] | select(.finding_id=="AZR-102" and .classification=="covered-elsewhere" and (.covered_by[0].provider=="gcp"))' "$corr10" >/dev/null \
  || fail "case10: AZR-102 (search) not covered by the GCP alert_policy kind: $(jq -c '.coverage' "$corr10")"
jq -e '.coverage[] | select(.finding_id=="AZR-103" and .classification=="true-gap")' "$corr10" >/dev/null \
  || fail "case10: AZR-103 (legacy-batch, nothing covers it) must stay true-gap: $(jq -c '.coverage' "$corr10")"
[ "$(jq '.total_coverage_covered_elsewhere' "$corr10")" -eq 2 ] \
  || fail "case10: expected total_coverage_covered_elsewhere=2 (alarm + alert_policy), got $(jq '.total_coverage_covered_elsewhere' "$corr10")"
echo "PASS"

# --- case 11: only observed, open findings support any correlation claim -------
printf 'testing: blocked / suppressed / resolved findings cannot corroborate gaps or cascades ... '
D11="$TMP_ROOT/case11"
write_findings "$D11" "aws" '[
  {"id":"AWS-201","title":"Database db-open has no backup","area":"data-durability","severity":"high","status":"configured","lifecycle":"new","affected":["db-open"]},
  {"id":"AWS-202","title":"Database db-blocked has no backup","area":"data-durability","severity":"high","status":"blocked","lifecycle":"new","affected":["db-blocked"]},
  {"id":"AWS-203","title":"Database db-suppressed has no backup","area":"data-durability","severity":"high","status":"validated-live","lifecycle":"suppressed","affected":["db-suppressed"]},
  {"id":"AWS-204","title":"Database db-resolved has no backup","area":"data-durability","severity":"high","status":"configured","lifecycle":"resolved","affected":["db-resolved"]}
]'
write_findings_2level "$D11" "azure" "primary" "azure/primary" '[
  {"id":"AZR-201","title":"Missing alerts on db-open","area":"coverage","severity":"high","status":"validated-live","lifecycle":"regressed","affected":["db-open"]},
  {"id":"AZR-202","title":"Missing alerts on db-blocked","area":"coverage","severity":"high","status":"blocked","lifecycle":"new","affected":["db-blocked"],"coverage_gap":{"signal":"CPU","kind":"metric_alert"}},
  {"id":"AZR-203","title":"Missing alerts on db-suppressed","area":"coverage","severity":"high","status":"configured","lifecycle":"suppressed","affected":["db-suppressed"]},
  {"id":"AZR-204","title":"Missing alerts on db-resolved","area":"coverage","severity":"high","status":"configured","lifecycle":"resolved","affected":["db-resolved"]}
]'
run_engine "$D11"
jq -e '.total_findings_raw==8 and .total_findings_deduplicated==7
  and [.overlaps[].service]==["db-open"]
  and [.cascades[].root_cause.finding_id]==["AWS-201"]
  and [.cascades[].effects[].finding_id]==["AZR-201"]
  and [.coverage[].finding_id]==["AZR-201"]' "$D11/correlation.json" >/dev/null \
  || fail 'case11: evidence or lifecycle exclusions leaked into a derived claim or raw counters changed'
echo "PASS"

# --- case 12: the real blocked On-Call shape cannot become missing monitors -----
# Private account identifiers are replaced by synthetic policy/team identifiers.
printf 'testing: unknown responder requirement is not a real cross-tool coverage gap ... '
D12="$TMP_ROOT/case12"
write_findings_2level "$D12" "splunk_oncall" "trial" "splunk_oncall/trial" '[
  {"id":"SOC-006","title":"Responder redundancy could not be assessed because no minimum was declared","severity":"low","area":"current-coverage","status":"blocked","lifecycle":"new","scoring_scope":"readiness","affected":["policy-a","policy-b","team-a"]},
  {"id":"SOC-007","title":"Alert-source to paging-path join could not be assessed because no source evidence was supplied","severity":"low","area":"source-correlation","status":"blocked","lifecycle":"new","scoring_scope":"readiness","affected":["team-a"]}
]'
before12=$(cksum "$D12/splunk_oncall/trial/$DATE/findings.json")
run_engine "$D12"
jq -e '.total_findings_raw==2 and .total_findings_deduplicated==2 and .coverage==[] and .overlaps==[] and .cascades==[]' "$D12/correlation.json" >/dev/null \
  || fail 'case12: blocked On-Call evidence became a real coverage gap'
[ "$before12" = "$(cksum "$D12/splunk_oncall/trial/$DATE/findings.json")" ] \
  || fail 'case12: correlation rewrote a canonical artifact'
echo "PASS"

# --- case 13: non-scored observations need explicit gap intent ------------------
# Cost/topology observations still support overlap deduplication. Their wording
# alone cannot turn incident lineage or other non-scored facts into monitor gaps.
printf 'testing: non-scored overlap compatibility and explicit coverage-gap intent ... '
D13="$TMP_ROOT/case13"
write_findings "$D13" "aws" '[
  {"id":"AWSOPT-001","title":"Missing metric correlation context","severity":"info","area":"metric-context","status":"configured","lifecycle":"new","scoring_scope":"non-scored","affected":["checkout"]},
  {"id":"TOPO-001","title":"Signal mapping needs review","severity":"info","area":"topology-readiness","status":"configured","lifecycle":"new","scoring_scope":"non-scored","affected":["search"],"coverage_gap":{"signal":"trace-error alert","kind":"metric_alert"}}
]'
write_findings "$D13" "grafana" '[
  {"id":"GRAF-001","title":"Cost observation","severity":"info","area":"cost-optimization","scoring_scope":"non-scored","affected":["checkout"]}
]'
run_engine "$D13"
jq -e '[.overlaps[].service]==["checkout"] and [.coverage[].finding_id]==["TOPO-001"]' "$D13/correlation.json" >/dev/null \
  || fail 'case13: non-scored heuristic fabricated a gap or legacy cost overlap was lost'
echo "PASS"

# --- case 14: run-local route aliases are never cross-target identities ---------
printf 'testing: On-Call route ordinals cannot correlate across labeled targets ... '
D14="$TMP_ROOT/case14"
for label in alpha beta; do
  write_findings_2level "$D14" "splunk_oncall" "$label" "splunk_oncall/$label" '[
    {"id":"SOC-001","title":"Configured route has an unresolved policy target","severity":"high","area":"routing-integrity","status":"configured","lifecycle":"new","scoring_scope":"readiness","affected":["route-1"],"correlation_affected":["route-1"]}
  ]'
done
run_engine "$D14"
jq -e '.total_findings_raw==2 and .total_findings_deduplicated==2 and .overlaps==[] and .cascades==[] and .coverage==[]' "$D14/correlation.json" >/dev/null \
  || fail 'case14: run-local routing aliases became shared resources'
# Do not erase another provider actual resource merely because its name matches.
write_findings "$D14" "aws" '[{"id":"AWS-001","title":"Observed gap","severity":"high","affected":["route-1"]}]'
write_findings "$D14" "grafana" '[{"id":"GRAF-001","title":"Observed gap","severity":"high","affected":["route-1"]}]'
run_engine "$D14"
jq -e '[.overlaps[].targets]==[["aws","grafana"]]' "$D14/correlation.json" >/dev/null \
  || fail 'case14: On-Call alias defense changed legacy identities or retained an On-Call member'
echo "PASS"

# An account-local object name does not establish cross-target service identity.
printf 'testing: bare On-Call policy/team slugs require verified service binding ... '
for label in alpha beta; do
  write_findings_2level "$D14" "splunk_oncall" "$label" "splunk_oncall/$label" '[
    {"id":"SOC-004","title":"Observed policy staffing gap","severity":"high","status":"configured","lifecycle":"new","affected":["policy-a","team-a","checkout"]}
  ]'
done
run_engine "$D14"
jq -e '[.overlaps[].targets]==[["aws","grafana"]]' "$D14/correlation.json" >/dev/null \
  || fail 'case14b: unbound On-Call account-local slugs corroborated a cross-target claim'
for label in alpha beta; do
  f="$D14/splunk_oncall/$label/$DATE/findings.json"
  jq '.findings[0].correlation_affected=["checkout","not-in-affected","route-1"]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
run_engine "$D14"
jq -e '[.overlaps[].service]|sort==["checkout","route-1"]' "$D14/correlation.json" >/dev/null \
  || fail 'case14b: declared shared service did not join or undeclared/alias tokens leaked'
jq -e '.overlaps[]|select(.service=="checkout")|.targets==["splunk_oncall/alpha","splunk_oncall/beta"]' "$D14/correlation.json" >/dev/null \
  || fail 'case14b: explicit source-verified service identity was lost'
echo "PASS"

# A successful empty rerun replaces prior groups instead of serving stale RCA.
printf 'testing: empty current run replaces previous correlation output ... '
rm "$D14/aws/$DATE/findings.json" "$D14/grafana/$DATE/findings.json" \
  "$D14/splunk_oncall/alpha/$DATE/findings.json" "$D14/splunk_oncall/beta/$DATE/findings.json"
run_engine "$D14"
jq -e --arg d "$DATE" '.audit_date==$d and .total_findings_raw==0
  and .total_findings_deduplicated==0 and .overlaps==[] and .cascades==[] and .coverage==[]' "$D14/correlation.json" >/dev/null \
  || fail 'case15: zero findings retained old correlation groups'
echo "PASS"

printf 'testing: paging routes and policies are not coverage-bearing monitors ... '
D16="$TMP_ROOT/case16"
write_findings "$D16" "azure" '[{"id":"AZR-001","title":"No metric alert for checkout","area":"coverage","severity":"high","status":"configured","affected":["checkout"]}]'
mkdir -p "$D16/splunk_oncall/primary/$DATE"
printf '%s\n' '{"target":"splunk_oncall/primary","items":[{"kind":"route","name":"route-1","covers":"checkout","enabled":true,"routes_to":"policy-a"},{"kind":"escalation_policy","name":"policy-a","covers":"checkout","enabled":true,"routes_to":"person-a"}]}' > "$D16/splunk_oncall/primary/$DATE/inventory.json"
run_engine "$D16"
jq -e '[.coverage[].classification]==["true-gap"]' "$D16/correlation.json" >/dev/null \
  || fail 'case16: an On-Call paging object masqueraded as an upstream monitor'
echo "PASS"

printf 'testing: reserved roll-up names apply only to root providers, never labels or ancestors ... '
D17="$TMP_ROOT/all/case17"
write_findings_2level "$D17" "azure" "all" "azure/all" '[{"id":"AZR-001","title":"No metric alert for checkout","area":"coverage","severity":"high","affected":["checkout"]}]'
write_findings "$D17" "all" '[{"id":"SKIP-001","title":"Derived rollup","severity":"high","affected":["checkout"]}]'
mkdir -p "$D17/datadog/doctor/$DATE"
printf '%s\n' '{"target":"datadog/doctor","items":[{"kind":"monitor","name":"checkout-alert","covers":"checkout","enabled":true,"routes_to":"primary-oncall"}]}' > "$D17/datadog/doctor/$DATE/inventory.json"
run_engine "$D17"
jq -e '.total_findings_raw==1 and .overlaps==[] and [.coverage[].classification]==["covered-elsewhere"] and [.coverage[].target]==["azure/all"]' "$D17/correlation.json" >/dev/null \
  || fail 'case17: label/ancestor was skipped or top-level derived report was included'
echo "PASS"

echo
printf 'testing: legacy object targets retain canonical labeled paths ... '
D18="$TMP_ROOT/case18"
write_findings_2level "$D18" "signoz" "primary" "signoz/primary" '[{"id":"SIG-001","title":"No metric alert","area":"coverage","affected":["checkout"],"severity":"high"}]'
f="$D18/signoz/primary/$DATE/findings.json"
jq '.target={type:"signoz",host:"example.invalid",version:"legacy"}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
mkdir -p "$D18/datadog/secondary/$DATE"
printf '%s\n' '{"target":{"type":"datadog","name":"secondary"},"items":[{"kind":"monitor","name":"checkout-alert","covers":"checkout","enabled":true,"routes_to":"oncall"}]}' > "$D18/datadog/secondary/$DATE/inventory.json"
run_engine "$D18"
jq -e '.total_findings_raw==1 and [.coverage[].target]==["signoz/primary"] and [.coverage[].classification]==["covered-elsewhere"]' "$D18/correlation.json" >/dev/null || fail 'case18: legacy target object crashed or lost canonical identity'
echo "PASS"

printf 'testing: failed consumer reads cannot masquerade as empty output ... '
GETTER_DIR="$TMP_ROOT/getters"; mkdir -p "$GETTER_DIR"
for getter in correlation_get_overlaps correlation_get_cascades correlation_get_coverage correlation_find_related; do
  printf '{broken' > "$GETTER_DIR/correlation.json"
  if SCOUTFLO_AUDIT_DIR="$GETTER_DIR" sh -c '. "$1"; "$2" example' sh "$LIB_DIR/correlation-engine.sh" "$getter" > "$TMP_ROOT/getter.out" 2> "$TMP_ROOT/getter.err"; then fail "case19: $getter treated malformed output as absent"; fi
  grep -q 'cannot read current correlation artifact' "$TMP_ROOT/getter.err" || fail "case19: $getter omitted diagnostic"
  printf '%s\n' '{"overlaps":false,"cascades":false,"coverage":false}' > "$GETTER_DIR/correlation.json"
  if SCOUTFLO_AUDIT_DIR="$GETTER_DIR" sh -c '. "$1"; "$2" example' sh "$LIB_DIR/correlation-engine.sh" "$getter" > "$TMP_ROOT/getter.out" 2> "$TMP_ROOT/getter.err"; then fail "case19: $getter treated wrong-typed false as absent"; fi
  rm "$GETTER_DIR/correlation.json"
  SCOUTFLO_AUDIT_DIR="$GETTER_DIR" sh -c '. "$1"; "$2" example' sh "$LIB_DIR/correlation-engine.sh" "$getter" > "$TMP_ROOT/getter.out" || fail "case19: $getter rejected absent optional output"
  jq -e 'type=="array" or type=="object"' "$TMP_ROOT/getter.out" >/dev/null || fail "case19: missing optional output has wrong shape"
done
echo "PASS"

echo "=== All correlation-engine tests passed ==="
