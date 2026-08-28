#!/bin/sh
# test-report-viz.sh — the report visuals generator renders correctly and safely
# from a canonical findings.json, and degrades on empty/missing inputs.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIZ="$ROOT/report-standard/render-report-viz.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

cat > "$WORK/f.json" <<'EOF'
{"schema":"scoutflo-findings/v1","toolkit_version":"0.1.101","skill":"audit-grafana","target":"acme-prod","run_date":"2026-08-15","generated_at":"2026-08-15T00:00:00Z","estate":{"path":"medium","objects":420},
"score":{"overall":72,"categories":[{"name":"Alert delivery","weight":30,"score":60,"maturity":"reactive","checks_passed":3,"checks_total":5},{"name":"Alert noise","weight":25,"score":80,"maturity":"proactive","checks_passed":8,"checks_total":10},{"name":"Coverage","weight":25,"score":92,"maturity":"systematic","checks_passed":11,"checks_total":12}],"excluded":[{"name":"Traces","weight":20,"reason":"blocked"}]},
"severity_counts":{"critical":1,"high":2,"medium":4,"low":3,"info":1},
"findings":[{"id":"GRAF-014","area":"alert-delivery","severity":"critical","points_recoverable":11,"title":"No default receiver"},{"id":"GRAF-051","area":"coverage","severity":"medium","points_recoverable":2,"title":"stale datasource"}]}
EOF
printf '%s\n' '{"run_date":"2026-08-03","overall":66}' '{"run_date":"2026-08-10","overall":63}' '{"run_date":"2026-08-15","overall":72}' > "$WORK/h.jsonl"
cat > "$WORK/topo.json" <<'EOF'
{"relationships":[{"from":{"name":"orders-api"},"to":{"name":"checkout"},"relation":"CALLS"},{"from":{"name":"checkout"},"to":{"name":"payments-db"},"relation":"CALLS"}]}
EOF

echo "=== report-viz self-test ==="

echo "Test 1: at-a-glance renders score bar, trend sparkline, checks, severity histogram, top lever"
AAG="$(sh "$VIZ" at-a-glance "$WORK/f.json" "$WORK/h.jsonl")"
printf '%s' "$AAG" | grep -q '\*\*Score: 72/100\*\*' || fail "no canonical score line"
printf '%s' "$AAG" | grep -q '█' || fail "no Unicode bar rendered"
printf '%s' "$AAG" | grep -q 'Trend' || fail "no trend line"
printf '%s' "$AAG" | grep -q 'Checks passed: \*\*22/27\*\*' || fail "checks-passed sum wrong (want 22/27)"
printf '%s' "$AAG" | grep -q '🔴 critical' || fail "no severity histogram"
printf '%s' "$AAG" | grep -q 'GRAF-014' || fail "top lever (highest points_recoverable) not surfaced"
echo "PASS"

echo "Test 7a: v2 renders readiness and assessment coverage as separate facts"
cat > "$WORK/v2.json" <<'EOF'
{"schema":"scoutflo-findings/v2","toolkit_version":"0.1.153","skill":"audit-grafana","target":"example","run_date":"2026-08-28","generated_at":"2026-08-28T00:00:00Z","score":{"overall":90,"state":"assessed","gate":85,"end_to_end":false,"scoring_model":"assessed-only-v1","check_set":"cksum-v1:1:1","assessment":{"applicable_checks":10,"assessed_checks":4,"scored_checks":4,"blocked_checks":6,"suppressed_checks":0,"not_in_scope_checks":2,"coverage_percent":40},"categories":[{"name":"Signals","weight":100,"score":90,"maturity":"proactive","checks_passed":3,"checks_total":4,"checks_blocked":6,"checks_suppressed":0}],"excluded":[]},"severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"findings":[]}
EOF
printf '%s\n' \
  '{"run_date":"2026-08-20","overall":10,"scoring_model":"legacy","check_set":"old"}' \
  '{"run_date":"2026-08-27","overall":80,"scoring_model":"assessed-only-v1","check_set":"cksum-v1:1:1"}' \
  '{"run_date":"2026-08-28","overall":90,"scoring_model":"assessed-only-v1","check_set":"cksum-v1:1:1"}' > "$WORK/v2-history.jsonl"
V2="$(sh "$VIZ" at-a-glance "$WORK/v2.json" "$WORK/v2-history.jsonl")"
printf '%s' "$V2" | grep -q 'Assessment coverage: \*\*4/10 (40%)\*\*' || fail "v2 assessment coverage missing"
printf '%s' "$V2" | grep -q '80 → 90' || fail "compatible v2 trend missing"
printf '%s' "$V2" | grep -q '10 →' && fail "incompatible score leaked into v2 trend"
echo "PASS"

echo "Test 7b: fully blocked v2 run renders unassessed, never 0/100"
jq '.score.overall=null | .score.state="unassessed" | .score.assessment={"applicable_checks":3,"assessed_checks":0,"scored_checks":0,"blocked_checks":3,"suppressed_checks":0,"not_in_scope_checks":0,"coverage_percent":0}' "$WORK/v2.json" > "$WORK/v2-unassessed.json"
VU="$(sh "$VIZ" at-a-glance "$WORK/v2-unassessed.json")"
printf '%s' "$VU" | grep -q 'Readiness: unassessed' || fail "unassessed state not rendered"
printf '%s' "$VU" | grep -q 'Score: 0/100' && fail "unassessed state rendered as zero readiness"
echo "PASS"

echo "Test 7b.1: an all-suppressed v2 run explains exemptions rather than missing evidence"
jq '.score.overall=null | .score.state="unassessed" | .score.assessment={"applicable_checks":2,"assessed_checks":2,"scored_checks":0,"blocked_checks":0,"suppressed_checks":2,"not_in_scope_checks":0,"coverage_percent":100}' "$WORK/v2.json" > "$WORK/v2-all-suppressed.json"
VS="$(sh "$VIZ" at-a-glance "$WORK/v2-all-suppressed.json")"
printf '%s' "$VS" | grep -q 'all assessed gaps are covered by explicit exemptions' \
  || fail "all-suppressed run was misreported as missing evidence"
printf '%s' "$VS" | grep -q 'No applicable check produced enough evidence' \
  && fail "all-suppressed run incorrectly claimed no evidence"
echo "PASS"

echo "Test 7c: findings-by-purpose renders general and AI SRE lanes without duplicating evidence"
jq '.findings=[
  {"id":"FX-001","severity":"high","title":"Paging route is broken","report_lanes":["general-audit","ai-sre-readiness"]},
  {"id":"FX-002","severity":"medium","title":"Service identity is inconsistent","report_lanes":["ai-sre-readiness"]},
  {"id":"FX-003","severity":"low","title":"Approved exception","lifecycle":"suppressed","report_lanes":["general-audit"]}
]' "$WORK/v2.json" > "$WORK/v2-lanes.json"
LANES="$(sh "$VIZ" lanes "$WORK/v2-lanes.json")"
printf '%s' "$LANES" | grep -q '^### General audit' || fail "general-audit lane missing"
printf '%s' "$LANES" | grep -q '^### AI SRE readiness' || fail "AI SRE readiness lane missing"
[ "$(printf '%s' "$LANES" | grep -c 'FX-001')" -eq 2 ] || fail "dual-lane finding did not appear once in each lane"
[ "$(printf '%s' "$LANES" | grep -c 'FX-002')" -eq 1 ] || fail "AI-only finding leaked into the general lane"
printf '%s' "$LANES" | grep -q 'FX-003' && fail "suppressed finding leaked into an active review lane"
printf '%s' "$LANES" | grep -qi 'observed' && fail "lane view exposed raw evidence"
echo "PASS"

echo "Test 2: at-a-glance picks the MAX points_recoverable as the top lever"
printf '%s' "$AAG" | grep -q 'GRAF-051' && fail "surfaced the lower-points finding as the top lever"
echo "PASS"

echo "Test 3: scorecard renders a bar per category and keeps the excluded row"
SC="$(sh "$VIZ" scorecard "$WORK/f.json")"
printf '%s' "$SC" | grep -q 'Alert delivery | 30 | 60/100' || fail "category row missing/wrong"
printf '%s' "$SC" | grep -q 'Traces | 20 | excluded' || fail "excluded category row dropped"
echo "PASS"

echo "Test 3b: a category present in categories and excluded renders exactly once"
jq '.score.categories += [{"name":"Traces","weight":20,"score":0,"maturity":"reactive","checks_passed":0,"checks_total":0,"checks_blocked":2}]' "$WORK/f.json" > "$WORK/f-category-and-excluded.json"
SC2="$(sh "$VIZ" scorecard "$WORK/f-category-and-excluded.json")"
[ "$(printf '%s' "$SC2" | grep -c '^| Traces |')" -eq 1 ] || fail "excluded category rendered more than once"
printf '%s' "$SC2" | grep -q 'Traces | 20 | excluded' || fail "excluded category rendered as a numeric score"
echo "PASS"

echo "Test 4: mermaid-topo emits a flowchart touching the target, with the target class"
MT="$(sh "$VIZ" mermaid-topo "$WORK/topo.json" checkout)"
printf '%s' "$MT" | grep -q '```mermaid' || fail "no mermaid fence"
printf '%s' "$MT" | grep -q 'flowchart LR' || fail "no flowchart"
printf '%s' "$MT" | grep -q 'class checkout target' || fail "target not classed"
printf '%s' "$MT" | grep -q 'orders_api' || fail "upstream edge to target not rendered"
echo "PASS"

echo "Test 5: html is a self-contained doc with the score, scorecard bars, and finding rows"
sh "$VIZ" html "$WORK/f.json" "$WORK/r.html" "$WORK/h.jsonl" >/dev/null
grep -q '<!doctype html>' "$WORK/r.html" || fail "html not a full document"
[ "$(grep -c '<!doctype html>' "$WORK/r.html")" -eq 1 ] || fail "more than one document root"
grep -q '>72<' "$WORK/r.html" || fail "score not in the donut"
grep -q 'GRAF-014' "$WORK/r.html" || fail "finding not in the table"
grep -qi 'keep within your team' "$WORK/r.html" || fail "missing privacy caveat in footer"
echo "PASS"

echo "Test 5b: HTML keeps suppressed findings out of the active table and lists them separately"
jq '.findings=[
  {"id":"FX-010","severity":"high","title":"Active defect","lifecycle":"new","points_recoverable":5},
  {"id":"FX-011","severity":"medium","title":"Approved exception","lifecycle":"suppressed","points_recoverable":0}
]' "$WORK/v2.json" > "$WORK/v2-html-suppressed.json"
sh "$VIZ" html "$WORK/v2-html-suppressed.json" "$WORK/v2-suppressed.html" >/dev/null
grep -q 'Suppressed findings' "$WORK/v2-suppressed.html" || fail "HTML omitted the suppressed-findings section"
[ "$(grep -c 'FX-011' "$WORK/v2-suppressed.html")" -eq 1 ] || fail "suppressed finding was duplicated into the active HTML table"
grep -q 'FX-010' "$WORK/v2-suppressed.html" || fail "active finding missing from HTML"
echo "PASS"

echo "Test 6: html has NO external asset references (self-contained, no network)"
grep -qiE 'src="http|href="http|<link |<img ' "$WORK/r.html" && fail "html references an external asset"
echo "PASS"

echo "Test 7: empty estate (no findings, no history) degrades without crashing"
cat > "$WORK/empty.json" <<'EOF'
{"schema":"scoutflo-findings/v1","toolkit_version":"0.1.101","skill":"audit-x","target":"t","run_date":"2026-08-15","generated_at":"2026-08-15T00:00:00Z","score":{"overall":0,"categories":[],"excluded":[]},"severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"findings":[]}
EOF
sh "$VIZ" at-a-glance "$WORK/empty.json" >/dev/null 2>&1 || fail "at-a-glance crashed on empty estate"
sh "$VIZ" html "$WORK/empty.json" "$WORK/e.html" >/dev/null 2>&1 || fail "html crashed on empty estate"
echo "PASS"

echo "Test 8: overlaps renders the cross-stack correlation from correlation.json"
cat > "$WORK/corr.json" <<'EOF'
{"overlaps":[{"overlap_id":"OVL-checkout","type":"redundant_monitoring","service":"checkout","targets":["datadog","grafana","lgtm"],"findings":[{"target":"datadog","finding_id":"DD-033","title":"no monitor","severity":"high"},{"target":"grafana","finding_id":"GRAF-091","title":"no rule","severity":"high"}],"recommendation":"consolidate the paging path"}],"cascades":[]}
EOF
OV="$(sh "$VIZ" overlaps "$WORK/corr.json")"
printf '%s' "$OV" | grep -q '## Cross-stack correlation' || fail "no correlation heading"
printf '%s' "$OV" | grep -q 'checkout' || fail "overlap service not rendered"
printf '%s' "$OV" | grep -q 'datadog, grafana, lgtm' || fail "overlap stacks not joined"
printf '%s' "$OV" | grep -q 'DD-033' || fail "per-overlap finding detail missing"
printf '%s' "$OV" | grep -qi 'no cross-stack cascade' || fail "empty-cascade line missing"
echo "PASS"

echo "Test 9: overlaps degrades cleanly when nothing correlates / file absent"
printf '%s' "$(sh "$VIZ" overlaps "$WORK/none.json")" | grep -qi 'correlation.json' || fail "missing-file degrade wrong"
echo '{"overlaps":[],"cascades":[]}' > "$WORK/empty-corr.json"
printf '%s' "$(sh "$VIZ" overlaps "$WORK/empty-corr.json")" | grep -qi 'No cross-stack overlaps' || fail "empty-overlaps degrade wrong"
echo "PASS"

echo "Test 10: rollup renders a gate-count meter + worst-first per-stack bars (no average)"
for pair in grafana:82 aws:20 sentry:91; do
  n="${pair%%:*}"; s="${pair##*:}"; mkdir -p "$WORK/roll/$n/2026-08-16"
  printf '{"schema":"scoutflo-findings/v1","skill":"audit-%s","target":"%s","run_date":"2026-08-16","generated_at":"x","score":{"overall":%s,"categories":[],"excluded":[]},"severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"findings":[]}' "$n" "$n" "$s" > "$WORK/roll/$n/2026-08-16/findings.json"
done
# Two-level layout: signoz/kubernetes always nest as <int>/<label>/<date>/, so the rollup
# must reach findings via its two-level glob too — regression-lock for the dual-glob fix.
mkdir -p "$WORK/roll/kubernetes/ctx-a/2026-08-16"
printf '{"schema":"scoutflo-findings/v1","skill":"audit-kubernetes","target":"kubernetes/ctx-a","run_date":"2026-08-16","generated_at":"x","score":{"overall":90,"categories":[],"excluded":[]},"severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"findings":[]}' > "$WORK/roll/kubernetes/ctx-a/2026-08-16/findings.json"
RU="$(sh "$VIZ" rollup "$WORK/roll" 2026-08-16)"
printf '%s' "$RU" | grep -q 'Stacks passing the 85 gate: 2/4' || fail "gate count wrong (want 2/4 incl. the two-level kubernetes/ctx-a stack)"
printf '%s' "$RU" | grep -q '`kubernetes/ctx-a` | 90/100' || fail "two-level kubernetes/ctx-a score row missing from rollup"
printf '%s' "$RU" | grep -qi 'never a combined average' || fail "missing no-average note"
# worst-first: aws (20) must appear before sentry (91)
printf '%s' "$RU" | awk '/`aws`/{a=NR} /`sentry`/{s=NR} END{exit !(a<s)}' || fail "rollup not worst-first ordered"
echo "PASS"

echo "Test 10b: rollup keeps an unassessed v2 run neutral instead of displaying 0/100"
mkdir -p "$WORK/roll/elk/2026-08-16"
printf '{"schema":"scoutflo-findings/v2","skill":"audit-elk","target":"elk","run_date":"2026-08-16","generated_at":"x","score":{"overall":null,"state":"unassessed","categories":[],"excluded":[]},"severity_counts":{"critical":0,"high":0,"medium":0,"low":0,"info":0},"findings":[]}' > "$WORK/roll/elk/2026-08-16/findings.json"
RU2="$(sh "$VIZ" rollup "$WORK/roll" 2026-08-16)"
printf '%s' "$RU2" | grep -q '`elk` | unassessed' || fail "unassessed stack missing from rollup"
printf '%s' "$RU2" | grep -q '`elk` | 0/100' && fail "unassessed stack rendered as zero readiness"
printf '%s' "$RU2" | grep -q 'Stacks passing the 85 gate: 2/5' || fail "unassessed stack not counted in the rollup denominator"
echo "PASS"

echo "Test 11: inventory-rollup includes BOTH the one-level and the two-level (kubernetes/ctx-a) stacks"
# reuse the roll dir from Test 10: a one-level inventory.json + a two-level one (single-block
# kubernetes always nests) — the dual-glob must reach both. (regression-lock for the fix.)
printf '{"schema":"scoutflo-inventory/v1","target":"grafana","generated_at":"x","counts":{"total":3,"by_kind":{"alert_rule":2,"contact_point":1}},"items":[]}' > "$WORK/roll/grafana/2026-08-16/inventory.json"
printf '{"schema":"scoutflo-inventory/v1","target":"kubernetes/ctx-a","generated_at":"x","counts":{"total":5,"by_kind":{"workload":4,"networkpolicy":1}},"items":[]}' > "$WORK/roll/kubernetes/ctx-a/2026-08-16/inventory.json"
IR="$(sh "$VIZ" inventory-rollup "$WORK/roll" 2026-08-16)"
printf '%s' "$IR" | grep -q '## Estate inventory' || fail "no estate inventory heading"
printf '%s' "$IR" | grep -q '`grafana` | 3 |' || fail "one-level grafana inventory row missing"
printf '%s' "$IR" | grep -q '`kubernetes/ctx-a` | 5 |' || fail "two-level kubernetes/ctx-a inventory row missing"
printf '%s' "$IR" | grep -q 'workload: 4' || fail "two-level by-kind counts missing"
echo "PASS"

echo
echo "=== report-viz self-test passed ==="
