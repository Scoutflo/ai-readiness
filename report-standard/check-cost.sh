#!/bin/sh
# check-cost.sh — validate an audit-cost findings.json against cost-schema.md
# (schema scoutflo-cost/v1). This is the money-integrity gate: it enforces that
# every summed dollar came verbatim from a provider-native recommendation source
# and that no dollar figure was invented, plus per-finding schema completeness.
#
# Why separate from check-findings.sh: a cost report is a ranked-savings report
# with NO 0-100 score, so the scored-schema checks (score reconciles with
# scorecard) do not apply; instead this enforces the savings-summary arithmetic
# and the "never invent a number" rule.
#
# Usage: report-standard/check-cost.sh path/to/cost-findings.json
# Exit 0 = valid (prints COST-OK). Exit 1 = violation (lists each).
set -eu

F="${1:?usage: check-cost.sh path/to/findings.json}"
[ -f "$F" ] || { echo "COST-FAIL: no such file: $F"; exit 1; }
command -v jq >/dev/null || { echo "COST-FAIL: jq not installed"; exit 1; }
jq empty "$F" 2>/dev/null || { echo "COST-FAIL: $F is not valid JSON"; exit 1; }

FAIL=0
fail() { echo "COST-FAIL: $1"; FAIL=1; }

# 1. Envelope.
for k in schema toolkit_version skill target run_date generated_at providers_covered summary findings; do
  jq -e --arg k "$k" 'has($k)' "$F" >/dev/null 2>&1 || fail "missing required envelope field: $k"
done
sch="$(jq -r '.schema // ""' "$F")"
[ "$sch" = "scoutflo-cost/v1" ] || fail "schema is '$sch', expected 'scoutflo-cost/v1'"
skill="$(jq -r '.skill // ""' "$F")"
[ "$skill" = "audit-cost" ] || fail "skill is '$skill', expected 'audit-cost'"

# 2. THE ONE HARD RULE — money integrity.
# 2a. monthly_savings_identified_usd must equal the sum of exactly the non-null
#     estimated_monthly_savings_usd values (never a presence fact, never invented).
declared_m="$(jq -r '.summary.monthly_savings_identified_usd // 0' "$F")"
actual_m="$(jq -r '[.findings[].estimated_monthly_savings_usd | select(. != null)] | add // 0' "$F")"
if [ "$declared_m" != "$actual_m" ]; then
  fail "summary.monthly_savings_identified_usd=$declared_m != sum of native per-finding figures=$actual_m (the total must sum ONLY provider-native figures, nothing recomputed or invented)"
fi
# 2b. annual = monthly * 12.
declared_a="$(jq -r '.summary.annual_savings_identified_usd // 0' "$F")"
expect_a="$(jq -rn --argjson m "$actual_m" '$m * 12')"
[ "$declared_a" = "$expect_a" ] || fail "summary.annual_savings_identified_usd=$declared_a != monthly*12=$expect_a"
# 2c. any finding with a non-null dollar figure MUST name a savings_source (proof
#     it came from a provider API), and vice-versa a source with no figure is odd.
nosrc="$(jq -r '.findings[] | select(.estimated_monthly_savings_usd != null and ((.savings_source // "") == "")) | .id' "$F")"
[ -z "$nosrc" ] || fail "findings with a dollar figure but no savings_source (a figure must cite its provider-native source): $(echo "$nosrc" | tr '\n' ' ')"
# 2d. counts split must be honest.
n_native="$(jq '[.findings[] | select(.estimated_monthly_savings_usd != null)] | length' "$F")"
n_presence="$(jq '[.findings[] | select(.estimated_monthly_savings_usd == null)] | length' "$F")"
d_native="$(jq -r '.summary.opportunities_with_native_figure // -1' "$F")"
d_presence="$(jq -r '.summary.presence_fact_opportunities // -1' "$F")"
[ "$n_native" = "$d_native" ] || fail "summary.opportunities_with_native_figure=$d_native != actual $n_native"
[ "$n_presence" = "$d_presence" ] || fail "summary.presence_fact_opportunities=$d_presence != actual $n_presence"
d_total="$(jq -r '.summary.opportunities_total // -1' "$F")"
n_total="$(jq '.findings | length' "$F")"
[ "$d_total" = "$n_total" ] || fail "summary.opportunities_total=$d_total != actual findings count $n_total"

# 3. Ranking: native-figure findings must be sorted by descending savings, and
#    must all appear before presence-fact findings (the report leads with money).
order_ok="$(jq -r '
  ([.findings[].estimated_monthly_savings_usd]) as $s
  | ($s | map(. != null)) as $isnum
  # once a null appears, no non-null may follow (native block first)
  | (reduce range(0; ($isnum|length)) as $i ({seen_null:false, ok:true};
        if $isnum[$i] then (if .seen_null then .ok=false else . end)
        else .seen_null=true end)).ok' "$F")"
[ "$order_ok" = "true" ] || fail "findings are not ordered native-figure-first (report must lead with the priced opportunities, then presence facts)"

# 4. Per-finding required fields + enums.
for k in id title provider area signal status affected estimated_monthly_savings_usd savings_source evidence recommendation; do
  miss="$(jq -r --arg k "$k" '.findings[] | select(has($k) | not) | .id // "?"' "$F")"
  [ -z "$miss" ] || fail "findings missing required field '$k': $(echo "$miss" | tr '\n' ' ')"
done
# 4a. id format COST-<PROV>-NNN.
badids="$(jq -r '.findings[].id | select(test("^COST-[A-Z0-9]{2,10}-[0-9]{2,4}$") | not)' "$F")"
[ -z "$badids" ] || fail "malformed cost finding IDs (want COST-<PROV>-NNN): $(echo "$badids" | tr '\n' ' ')"
dupe="$(jq -r '[.findings[].id] | (length) - (unique | length)' "$F")"
[ "$dupe" = "0" ] || fail "$dupe duplicate finding ID(s)"
# 4b. area must be cost-optimization.
badarea="$(jq -r '.findings[] | select(.area != "cost-optimization") | .id' "$F")"
[ -z "$badarea" ] || fail "findings whose area is not 'cost-optimization': $(echo "$badarea" | tr '\n' ' ')"
# 4c. status enum.
badstatus="$(jq -r '.findings[] | select(.status | IN("validated-live","configured","blocked") | not) | .id' "$F")"
[ -z "$badstatus" ] || fail "findings with invalid status: $(echo "$badstatus" | tr '\n' ' ')"
# 4d. affected must be a non-empty array naming a concrete resource.
noaff="$(jq -r '.findings[] | select((.affected | type != "array") or (.affected | length == 0)) | .id' "$F")"
[ -z "$noaff" ] || fail "findings with no concrete resource in 'affected' (per-resource detail is required, never a vague scope): $(echo "$noaff" | tr '\n' ' ')"
# 4e. evidence with command + observed.
noev="$(jq -r '.findings[] | select((.evidence | type != "array") or (.evidence | length == 0) or ((.evidence[0].command // "") == "") or ((.evidence[0].observed // "") == "")) | .id' "$F")"
[ -z "$noev" ] || fail "findings with empty/incomplete evidence: $(echo "$noev" | tr '\n' ' ')"

# 5. providers_covered non-empty (a run that covered nothing should not emit a file).
[ "$(jq '.providers_covered | length' "$F")" -gt 0 ] || fail "providers_covered is empty (no provider ran; emit no report or record the exclusions)"

# 6. largest_single_lever, when present, must match the top native finding.
has_lever="$(jq -r '.summary | has("largest_single_lever") and (.largest_single_lever != null)' "$F")"
if [ "$has_lever" = "true" ] && [ "$n_native" -gt 0 ]; then
  lev_id="$(jq -r '.summary.largest_single_lever.id' "$F")"
  top_id="$(jq -r '[.findings[] | select(.estimated_monthly_savings_usd != null)] | max_by(.estimated_monthly_savings_usd) | .id' "$F")"
  [ "$lev_id" = "$top_id" ] || fail "summary.largest_single_lever.id=$lev_id is not the highest-savings finding ($top_id)"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "COST-OK: $F conforms to scoutflo-cost/v1 (savings summed only from provider-native figures; \$${actual_m}/mo across ${n_native} priced + ${n_presence} presence-fact opportunities)"
else
  echo "COST-DRIFT: fix the violations above and re-emit; see report-standard/cost-schema.md"
  exit 1
fi
