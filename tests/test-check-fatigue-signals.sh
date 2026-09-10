#!/bin/sh
# test-check-fatigue-signals.sh — hermetic tests for the fatigue-signals.json
# validator. Run by ci/run-tests.sh under /bin/sh. No network, synthetic fixtures.
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
V="$ROOT/report-standard/check-fatigue-signals.sh"
[ -f "$V" ] || { echo "FAIL: validator not found at $V"; exit 1; }

WORK="${TMPDIR:-/tmp}/afsig-test.$$"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM
export SCOUTFLO_AUDIT_DIR="$WORK/aud"; DATE="2026-09-08"
mkdir -p "$SCOUTFLO_AUDIT_DIR/aws/$DATE"
jq -n '{schema:"scoutflo-findings/v2",target:"aws",findings:[{id:"AWS-SNS",title:"x",severity:"high",affected:["s"],impact:"i",recommendation:"r",remediation:"setup-aws#x"}]}' \
  > "$SCOUTFLO_AUDIT_DIR/aws/$DATE/findings.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
# expect: pass|fail
run() { jq -n "$2" > "$WORK/s.json"; sh "$V" "$WORK/s.json" "$SCOUTFLO_AUDIT_DIR" "$DATE" >/dev/null 2>&1; rc=$?
  if [ "$1" = pass ]; then [ "$rc" -eq 0 ] && ok "$3" || bad "$3 (expected pass, got exit $rc)";
  else [ "$rc" -ne 0 ] && ok "$3" || bad "$3 (expected fail, got exit 0)"; fi; }

run pass '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"cloudwatch_alarm",fires:48,flapping:true,stuck:false,reaches_human:false,off_hours_fires:30,source_finding_ids:["AWS-SNS"]}],provider_coverage:[{provider:"aws",tier:"fire-history",status:"collected",objects:1}]}' "a well-formed signals file passes"
run pass '{schema:"scoutflo-fatigue-signals/v1",signals:[]}' "an empty signals array passes (a provider with no history is honest)"
run fail '{schema:"wrong/v9",signals:[]}' "wrong schema fails"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:{}}' "signals not an array fails"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",fires:"48"}]}' "fires as a string fails (type check)"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",reaches_human:"false"}]}' "reaches_human as a string fails (the // bool trap the plugin has hit)"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",fires:10,off_hours_fires:99}]}' "off_hours_fires > fires fails (impossible)"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",off_hours_fires:5}]}' "off_hours_fires present without fires fails"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[],provider_coverage:[{provider:"dd",tier:"fire-history",status:"verify-pending"}]}' "verify-pending with no reason fails (honesty)"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[],provider_coverage:[{provider:"dd",tier:"fire-history",status:"made-up"}]}' "an unknown coverage status fails"
run pass '{schema:"scoutflo-fatigue-signals/v1",signals:[],provider_coverage:[{provider:"dd",tier:"fire-history",status:"verify-pending",reason:"events read 403"}]}' "verify-pending WITH a reason passes"
run fail '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",source_finding_ids:["NOPE-999"]}]}' "a hallucinated source_finding_id (absent from this run) fails"
run pass '{schema:"scoutflo-fatigue-signals/v1",signals:[{provider:"aws",object_id:"a1",object_kind:"k",source_finding_ids:["AWS-SNS"]}]}' "a real source_finding_id (present in this run) passes"
run fail '{schema:"scoutflo-fatigue-signals/v1",incident_feed:{status:"collected",source:"pagerduty"}}' "incident_feed collected without alerts_fired/incidents fails"
run pass '{schema:"scoutflo-fatigue-signals/v1",signals:[],incident_feed:{status:"collected",source:"pagerduty",alerts_fired:420,incidents:7}}' "incident_feed collected with counts passes"

echo "check-fatigue-signals: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
