#!/bin/sh
# Current-input and cross-target regressions; only synthetic local files.
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$ROOT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/af-current.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM
export SCOUTFLO_AUDIT_DIR="$WORK/all/audits"
RD="2026-09-08"
mkdir -p "$SCOUTFLO_AUDIT_DIR"
AFJ="$SCOUTFLO_AUDIT_DIR/alert-fatigue.json"
VIZ="$ROOT/report-standard/render-report-viz.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 (wanted $3, got $2)"; fi; }
run_af() { python3 "$ROOT/skills/correlation-engine/tests/qualified-fixtures.py" "$SCOUTFLO_AUDIT_DIR" "$RD"; /bin/sh -c '. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"; alert_fatigue_run "$1"' sh "$RD" > "$WORK/run.log" 2>&1; }
finding() {
  mkdir -p "$SCOUTFLO_AUDIT_DIR/$1/$RD"
  printf '%s\n' "$2" > "$SCOUTFLO_AUDIT_DIR/$1/$RD/findings.json"
}
render() {
  sh "$VIZ" alert-fatigue "$AFJ" "$SCOUTFLO_AUDIT_DIR" "$RD" > "$WORK/report.md"
  sh "$VIZ" alert-fatigue-html "$AFJ" "$WORK/report.html" "$SCOUTFLO_AUDIT_DIR" "$RD" >/dev/null
}
signal() { jq -nc --argjson s "$1" '{schema:"scoutflo-fatigue-signals/v1",generated_at:"2026-09-08T12:00:00Z",window:"7d",signals:[$s]}' > "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"; }

# Names local to two accounts are not canonical service identities.
for t in primary secondary; do
  finding "splunk_oncall/$t" '{"target":"splunk_oncall","findings":[{"id":"SOC-003","title":"Paging route missing","area":"paging","severity":"high","affected":["policy-1"],"correlation_affected":[],"status":"configured","lifecycle":"new"}]}'
done
run_af; rc=$?
check "On-Call current config accepted" "$rc" 0
check "two same-named account policies do not overlap" "$(jq -r '.totals.cross_source_storms' "$AFJ")" 0
check "file target identity keeps both accounts" "$(jq -r '.totals.tools_with_noise' "$AFJ")" 2
for t in primary secondary; do
  f="$SCOUTFLO_AUDIT_DIR/splunk_oncall/$t/$RD/findings.json"
  jq --arg t "splunk_oncall/$t" '.target=$t | .findings[0].affected += ["checkout","route-1"] | .findings[0].correlation_affected=["checkout","route-1","fabricated"]' "$f" > "$WORK/f.json"; mv "$WORK/f.json" "$f"
done
run_af
check "verified service subset joins but aliases/non-subsets do not" "$(jq -r '[.af_findings[]|select(.af_id=="AF-002")|.storms[].service]|join(",")' "$AFJ")" checkout
render
check "local policy remains available in rendered fix detail" "$(grep -c 'policy-1' "$WORK/report.md")" 2

# Empty and config-only HTML must distinguish no measurement from measured zero.
check "config-only HTML contains no measured-zero cards" "$(grep -Ec '0</span><span class="l">(no configured receiver|chronic / stuck) \(measured\)' "$WORK/report.html")" 0
rm -rf "$SCOUTFLO_AUDIT_DIR/splunk_oncall"
run_af; render
check "empty HTML explicitly says not measured" "$(grep -o 'not measured' "$WORK/report.html" | wc -l | tr -d ' ')" 2
signal '{"provider":"grafana","target":"grafana","object_id":"rule-1","object_kind":"grafana_rule","fires":0,"reaches_human":true,"stuck":false,"source_finding_ids":[]}'
run_af; render
check "standalone measured zero accepted" "$(jq -r '.af_findings[]|select(.af_id=="AF-005")|.status' "$AFJ")" measured
check "measured zero retained in HTML" "$(grep -Ec '0</span><span class="l">(no configured receiver|chronic / stuck) \(measured\)' "$WORK/report.html")" 2

# Validation rejection must replace old measurements and invalidate old renders.
for fault in stale missing-time phantom impossible malformed coverage negative; do
  signal '{"provider":"grafana","target":"grafana","object_id":"rule-1","object_kind":"grafana_rule","fires":400,"reaches_human":false,"stuck":true,"source_finding_ids":[]}'
  run_af
  printf 'old measured 400\n' > "$SCOUTFLO_AUDIT_DIR/alert-fatigue-report.md"
  printf 'old measured 400\n' > "$SCOUTFLO_AUDIT_DIR/alert-fatigue-report.html"
  case "$fault" in
    stale) edit='.generated_at="2025-01-01T00:00:00Z"';;
    missing-time) edit='del(.generated_at)';;
    phantom) edit='.signals[0].source_finding_ids=["NOT-IN-CURRENT-RUN"]';;
    impossible) edit='.signals[0].off_hours_fires=999';;
    malformed) edit='';;
    coverage) edit='.provider_coverage=[{provider:"grafana",tier:"fire-history",status:"verify-pending",reason:"read unavailable"}]';;
    negative) edit='.signals[0].fires=-1';;
  esac
  if [ -n "$edit" ]; then jq "$edit" "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json" > "$WORK/s.json"; mv "$WORK/s.json" "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"; else printf '{broken-json' > "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"; fi
  run_af; rc=$?
  check "$fault fails the real entry point" "$rc" 1
  check "$fault replaces prior volume with blocked current tier" "$(jq -r '.af_findings[]|select(.af_id=="AF-005")|[.status,(.total_fires==null)]|@csv' "$AFJ")" '"blocked",true'
  check "$fault old derived reports removed" "$(if [ -e "$SCOUTFLO_AUDIT_DIR/alert-fatigue-report.md" ] || [ -e "$SCOUTFLO_AUDIT_DIR/alert-fatigue-report.html" ]; then echo retained; else echo absent; fi)" absent
  render
  check "$fault reason visible in Markdown and HTML" "$(if grep -qi 'blocked' "$WORK/report.md" && grep -qi 'blocked' "$WORK/report.html"; then echo yes; else echo no; fi)" yes
done

# The selected operator input is gated too; negative/malformed counts cannot
# become a computed negative ratio or leave an older valid ratio behind.
rm -f "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"
for invalid in '{"window":"7d","alerts_fired":-420,"incidents":7}' '{"window":"7d","alerts_fired":"420","incidents":7}' '{broken-json'; do
  printf '%s\n' '{"window":"7d","alerts_fired":420,"incidents":7}' > "$SCOUTFLO_AUDIT_DIR/fatigue.json"
  run_af
  printf '%s\n' "$invalid" > "$SCOUTFLO_AUDIT_DIR/fatigue.json"
  run_af; rc=$?
  check "invalid operator counts reject actual run" "$rc" 1
  check "invalid operator counts replace previous computed ratio" "$(jq -r '.af_findings[]|select(.af_id=="AF-003")|.status' "$AFJ")" blocked
done
rm -f "$SCOUTFLO_AUDIT_DIR/fatigue.json"

# Source references remain provable even with no findings, but IDs are optional
# for genuine standalone observations. Reserved labels and structured legacy
# targets retain their original finding/fix in both renderers.
rm -f "$SCOUTFLO_AUDIT_DIR/fatigue-signals.json"
finding signoz/alpha '{"target":{"type":"signoz","name":"alpha"},"findings":[{"id":"SIG-040","title":"Alert route alpha missing","area":"alerting","severity":"high","affected":["alpha-rule"],"recommendation":"Repair alpha route","remediation":"setup-signoz#alpha"}]}'
finding signoz/beta '{"target":{"type":"signoz","name":"beta"},"findings":[{"id":"SIG-040","title":"Alert route beta missing","area":"alerting","severity":"high","affected":["beta-rule"],"recommendation":"Repair beta route","remediation":"setup-signoz#beta"}]}'
finding splunk_oncall/doctor '{"target":"splunk_oncall/doctor","findings":[{"id":"SOC-003","title":"Paging doctor route missing","area":"paging","severity":"high","affected":["local-policy"],"recommendation":"Repair doctor route","remediation":"setup-splunk-oncall#route"}]}'
finding all '{"target":"all","findings":[{"id":"COMBINED","title":"Paging rollup duplicate","area":"paging","severity":"high","affected":["combined"]}]}'
run_af; rc=$?
check "legacy object target does not crash" "$rc" 0
check "distinct legacy instances and reserved label retained" "$(jq -r '.totals.tools_with_noise' "$AFJ")" 3
render
for text in 'Repair alpha route' 'Repair beta route' 'Repair doctor route' 'alpha-rule' 'beta-rule' 'local-policy' 'setup-splunk-oncall#route'; do
  check "renderer keeps $text in Markdown and HTML" "$(if grep -q "$text" "$WORK/report.md" && grep -q "$text" "$WORK/report.html"; then echo yes; else echo no; fi)" yes
done
signal '{"provider":"signoz","target":"signoz/alpha","object_id":"alpha-rule","object_kind":"alert_rule","fires":1,"source_finding_ids":["SIG-040"]}'
run_af; rc=$?
check "reserved parent does not hide real source references" "$rc" 0
echo "alert-fatigue current-inputs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
