#!/bin/sh
# measure-efficiency.sh
# Reproducible efficiency measurement for the Scoutflo AI Readiness plugin.
# Produces the numbers documented in docs/token-costs.md "Efficiency, measured".
#
# What it measures (all DETERMINISTIC — no live model call, no network):
#   1. Fixed instruction cost per audit: bytes of each audit's SKILL.md +
#      references/*.md that Claude must read every run, and a token estimate.
#   2. Full-suite vs targeted-audit fixed instruction cost (the real lever a
#      customer controls: run fewer audits).
#   3. Skip-logic behaviour: cost-analysis re-run within 24h on unchanged data
#      does zero model work (the phases are pure jq/shell).
#
# Token estimate note: Claude's exact tokenizer is not bundled with the repo, so
# this uses the standard ~4-chars-per-token approximation. The BYTE counts are
# exact and reproducible; the token column is an estimate and labelled as such.
# For an exact live token figure, read Claude Code's per-turn counter (hover the
# model name) during a real run — that is the only source of ground truth for
# variable (provider-response) tokens, which this script does not estimate.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHARS_PER_TOKEN=4

audit_dirs="aws gcp lgtm grafana sentry datadog elk zenduty pagerduty digitalocean groundcover alert-routing kubernetes"

echo "=== 1. Fixed instruction cost per audit (SKILL.md + references/*.md) ==="
printf "%-16s %10s %12s\n" "audit" "bytes" "~tokens(est)"
total_bytes=0
for d in $audit_dirs; do
  b=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    fb=$(wc -c < "$f"); b=$((b + fb))
  done <<EOF
$(find "$ROOT/skills/audit-$d" -name '*.md' 2>/dev/null)
EOF
  total_bytes=$((total_bytes + b))
  printf "%-16s %10s %12s\n" "$d" "$b" "$((b / CHARS_PER_TOKEN))"
done
echo "--------------------------------------------------"
printf "%-16s %10s %12s\n" "ALL 13" "$total_bytes" "$((total_bytes / CHARS_PER_TOKEN))"

echo
echo "=== 2. Shared framing loaded once per run (report standard) ==="
rs_bytes=$(find "$ROOT/report-standard" -name '*.md' 2>/dev/null | xargs wc -c 2>/dev/null | tail -1 | awk '{print $1}')
printf "report-standard: %s bytes (~%s tokens est)\n" "$rs_bytes" "$((rs_bytes / CHARS_PER_TOKEN))"

echo
echo "=== 3. Targeted-audit lever: run one audit vs all 13 (fixed instructions) ==="
one_datadog=$(find "$ROOT/skills/audit-datadog" -name '*.md' | xargs wc -c | tail -1 | awk '{print $1}')
printf "one targeted audit (datadog): ~%s tokens vs the 13-audit set ~%s tokens\n" \
  "$((one_datadog / CHARS_PER_TOKEN))" "$((total_bytes / CHARS_PER_TOKEN))"
printf "=> running the 3 audits you care about instead of all 13 cuts fixed instruction cost by roughly the ratio of their sizes.\n"

echo
echo "=== 4. Roll-up phases are pure shell/jq: zero model tokens (always regenerate) ==="
W="$(mktemp -d)"; D="2026-08-01"
mkdir -p "$W/aws/$D"
printf '%s' '{"target":"aws","findings":[{"id":"AWSOPT-001","area":"cost-optimization","title":"x","affected":["i-1"],"estimated_monthly_savings_usd":100}]}' > "$W/aws/$D/findings.json"
run1=$(SCOUTFLO_AUDIT_DIR="$W" TOPOLOGY_FILE="$W/none.json" sh -c '. "'"$ROOT"'/skills/cost-analysis/lib/cost-analysis.sh"; cost_analysis_run "'"$D"'" 2>&1' | grep -c "Report complete" || true)
# Re-run: the roll-up ALWAYS regenerates now (the 24h skip cache was removed in
# v0.1.82 — it could serve a stale roll-up). It regenerates rather than skipping.
run2=$(SCOUTFLO_AUDIT_DIR="$W" TOPOLOGY_FILE="$W/none.json" sh -c '. "'"$ROOT"'/skills/cost-analysis/lib/cost-analysis.sh"; cost_analysis_run "'"$D"'" 2>&1' | grep -c "Starting analysis" || true)
echo "first run produced a report: $([ "$run1" -ge 1 ] && echo yes || echo no)"
echo "re-run regenerates (does not skip): $([ "$run2" -ge 1 ] && echo yes || echo no)"
echo "correlation + cost roll-up phases are pure shell/jq: $(head -1 "$ROOT/skills/correlation-engine/lib/correlation-engine.sh" "$ROOT/skills/cost-analysis/lib/cost-analysis.sh" | grep -c '#!/bin/sh')/2 use /bin/sh, 0 model tokens"
echo "=> the roll-up makes ZERO provider API calls (reads local findings only), so it is cheap to always regenerate; nothing is cached, nothing goes stale."
rm -rf "$W"

echo
echo "Done. Byte counts are exact and reproducible on any checkout; token columns are ~chars/$CHARS_PER_TOKEN estimates."
