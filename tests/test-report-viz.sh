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

echo "Test 2: at-a-glance picks the MAX points_recoverable as the top lever"
printf '%s' "$AAG" | grep -q 'GRAF-051' && fail "surfaced the lower-points finding as the top lever"
echo "PASS"

echo "Test 3: scorecard renders a bar per category and keeps the excluded row"
SC="$(sh "$VIZ" scorecard "$WORK/f.json")"
printf '%s' "$SC" | grep -q 'Alert delivery | 30 | 60/100' || fail "category row missing/wrong"
printf '%s' "$SC" | grep -q 'Traces | 20 | excluded' || fail "excluded category row dropped"
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
RU="$(sh "$VIZ" rollup "$WORK/roll" 2026-08-16)"
printf '%s' "$RU" | grep -q 'Stacks passing the 85 gate: 1/3' || fail "gate count wrong (want 1/3)"
printf '%s' "$RU" | grep -qi 'never a combined average' || fail "missing no-average note"
# worst-first: aws (20) must appear before sentry (91)
printf '%s' "$RU" | awk '/`aws`/{a=NR} /`sentry`/{s=NR} END{exit !(a<s)}' || fail "rollup not worst-first ordered"
echo "PASS"

echo
echo "=== report-viz self-test passed ==="
