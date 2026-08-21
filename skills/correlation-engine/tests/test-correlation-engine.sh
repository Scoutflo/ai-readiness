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

echo "Test 6: no findings for the date — clean no-op, no correlation.json"
D6="$TMP_ROOT/case6"
mkdir -p "$D6"
run_engine "$D6" || fail "case6: engine must exit 0 when there is nothing to correlate"
[ ! -f "$D6/correlation.json" ] \
  || fail "case6: correlation.json must not be written for an empty run"
echo "PASS"

echo
echo "=== All correlation-engine tests passed ==="
