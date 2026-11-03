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
for k in schema toolkit_version skill target run_date generated_at providers_covered providers_excluded summary findings; do
  jq -e --arg k "$k" 'has($k)' "$F" >/dev/null 2>&1 || fail "missing required envelope field: $k"
done
sch="$(jq -r '.schema // ""' "$F")"
[ "$sch" = "scoutflo-cost/v1" ] || fail "schema is '$sch', expected 'scoutflo-cost/v1'"
skill="$(jq -r '.skill // ""' "$F")"
[ "$skill" = "audit-cost" ] || fail "skill is '$skill', expected 'audit-cost'"

# The v1 schema is unchanged. Historical files may omit the later summary fields;
# new runs must carry them explicitly, including null/[] for unavailable evidence.
version_ok=$(jq -r '.toolkit_version | if type == "string" then test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?(\\+[0-9A-Za-z.-]+)?$") else false end' "$F")
[ "$version_ok" = true ] || fail "toolkit_version must be a semantic version; an invalid version cannot select legacy validation"
if [ "$version_ok" = true ]; then
  modern=$(jq -r '.toolkit_version | split("-")[0] | split("+")[0] | split(".") | map(tonumber) | . >= [0,1,238]' "$F")
  if [ "$modern" = true ]; then
    for k in observed_monthly_spend savings_pct_of_spend unassessed_monthly_spend unit_economics; do
      jq -e --arg k "$k" '.summary | has($k)' "$F" >/dev/null 2>&1 || fail "missing required current summary field: $k (use null or [] when unavailable)"
    done
  fi
fi

# Validate later fields whenever present, including on a historical file. Unknown
# spend is null, never zero; a foreign-currency denominator cannot justify a USD %.
jq -e '
  def text: type == "string" and test("\\S");
  def nonnegative: type == "number" and isfinite and . >= 0;
  def close($a; $b): (($a - $b) | fabs) <= (0.000001 * ([1, ($a|fabs), ($b|fabs)] | max));
  . as $r | .summary as $s
  | (if ($s | has("observed_monthly_spend")) and $s.observed_monthly_spend != null then
       $s.observed_monthly_spend | type == "object" and (.amount | nonnegative)
       and (.currency | type == "string" and test("^[A-Z]{3}$"))
       and (.period | text) and (.source | text)
     else true end)
  and (if ($s | has("savings_pct_of_spend")) then
       if $s.observed_monthly_spend == null or $s.observed_monthly_spend.amount == 0
          or $s.observed_monthly_spend.currency != "USD" then $s.savings_pct_of_spend == null
       else ($s.savings_pct_of_spend | nonnegative)
          and (($s.savings_pct_of_spend - ($s.monthly_savings_identified_usd / $s.observed_monthly_spend.amount * 100)) | fabs) <= 0.01
       end
     else true end)
  and (if ($s | has("unassessed_monthly_spend")) and $s.unassessed_monthly_spend != null then
       $s.unassessed_monthly_spend | type == "object" and (.amount | nonnegative)
       and (.currency | type == "string" and test("^[A-Z]{3}$")) and (.reason | text)
       and (.projects_or_targets | type == "array" and length > 0 and all(.[]; text))
     else true end)
  and (if ($s | has("unit_economics")) then
       ($s.unit_economics | type == "array") and
       (if ($s.unit_economics | length) == 0 then any($r.findings[]; .id == "COST-UNIT-004") else true end)
       and all($s.unit_economics[];
         (.unit_name | text)
         and (.estimated_monthly_savings_usd == null) and (.indicative_monthly_usd == null)
         and (if has("excluded_reason") then
           (.excluded_reason | text)
           and all([.unit_cost, .unit_cost_prev, .trend_pct, .spend, .spend_prev, .volume, .volume_prev][]; . == null)
         else
           (.per | type == "number" and isfinite and . > 0)
           and (.spend | nonnegative) and (.spend_prev | nonnegative)
           and (.volume | type == "number" and isfinite and . > 0)
           and (.volume_prev | type == "number" and isfinite and . > 0)
           and (.unit_cost | nonnegative) and (.unit_cost_prev | nonnegative)
           and (.currency | type == "string" and test("^[A-Z]{3}$"))
           and (.spend_source | text) and (.volume_source | text) and (.basis | text)
           and close(.unit_cost; (.spend / .volume * .per))
           and close(.unit_cost_prev; (.spend_prev / .volume_prev * .per))
           and (if .unit_cost_prev == 0 then .trend_pct == null
                else (.trend_pct | type == "number" and isfinite)
                  and ((.trend_pct - ((.unit_cost - .unit_cost_prev) / .unit_cost_prev * 100)) | fabs) <= 0.01 end)
         end))
     else true end)
  and all($r.findings[] | select(.id | startswith("COST-UNIT-"));
      .estimated_monthly_savings_usd == null and .indicative_monthly_usd == null)
' "$F" >/dev/null 2>&1 || fail "spend/unit-economics contract: show sourced inputs, reconcile USD percentage and unit quotients, disclose unassessed targets, and never price COST-UNIT findings"

# 2. THE ONE HARD RULE — money integrity.
# 2a. monthly_savings_identified_usd must equal the sum of exactly the non-null
#     estimated_monthly_savings_usd values (never a presence fact, never invented).
declared_m="$(jq -r '.summary.monthly_savings_identified_usd // 0' "$F")"
actual_m="$(jq -r '[.findings[].estimated_monthly_savings_usd | select(. != null)] | add // 0' "$F")"
if [ "$declared_m" != "$actual_m" ]; then
  fail "summary.monthly_savings_identified_usd=$declared_m != sum of native per-finding figures=$actual_m (the total must sum ONLY provider-native figures, nothing recomputed or invented)"
fi
# 2b. annual = monthly * 12, compared to the cent. Exact string equality would
#     falsely reject correct reports whose fractional-dollar sums land on IEEE-754
#     representation noise (e.g. 19.99 * 12 -> 239.88000000000002 != "239.88").
jq -e '
  ([.findings[].estimated_monthly_savings_usd | select(. != null)] | add // 0) as $m
  | ((.summary.annual_savings_identified_usd // 0) - ($m * 12)) as $d
  | (if $d < 0 then -$d else $d end) < 0.01
' "$F" >/dev/null \
  || fail "summary.annual_savings_identified_usd=$(jq -r '.summary.annual_savings_identified_usd // 0' "$F") != monthly*12=$(jq -rn --argjson m "$actual_m" '$m * 12') (must match to the cent)"
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

# 2g. THE INDICATIVE CLASS stays out of the savings total, and stays sourced.
#     An indicative figure is computed from the provider's published price for a SKU already on
#     the bill. It is useful precisely because whole categories of waste are never
#     provider-priced — but the moment it is summed into the headline, or stated without its
#     basis, it becomes the invented dollar this file exists to prevent.
noind="$(jq -r '.findings[] | select((.indicative_monthly_usd // null) != null and ((.indicative_source // "") == "")) | .id' "$F")"
[ -z "$noind" ] || fail "findings with indicative_monthly_usd but no indicative_source (an indicative figure must name the published SKU price and the single step it prices): $(echo "$noind" | tr '\n' ' ')"
bothfig="$(jq -r '.findings[] | select((.indicative_monthly_usd // null) != null and (.estimated_monthly_savings_usd // null) != null) | .id' "$F")"
[ -z "$bothfig" ] || fail "findings carrying BOTH estimated_monthly_savings_usd and indicative_monthly_usd (a figure is provider-native or indicative, never both — pick the native one): $(echo "$bothfig" | tr '\n' ' ')"
ind_sum="$(jq -r '[.findings[].indicative_monthly_usd | select(. != null)] | add // 0' "$F")"
d_ind="$(jq -r '.summary.indicative_monthly_usd // 0' "$F")"
jq -e --argjson a "$ind_sum" --argjson d "$d_ind" '(($d - $a) | if . < 0 then -. else . end) < 0.01' "$F" >/dev/null 2>&1 \
  || fail "summary.indicative_monthly_usd=$d_ind != sum of per-finding indicative figures=$ind_sum"
# The hard one: the savings total must NOT have absorbed any indicative figure.
jq -e --argjson a "$ind_sum" '
  ([.findings[].estimated_monthly_savings_usd | select(. != null)] | add // 0) as $native
  | ((.summary.monthly_savings_identified_usd // 0) - $native) as $d
  | (if $d < 0 then -$d else $d end) < 0.01
' "$F" >/dev/null 2>&1 \
  || fail "summary.monthly_savings_identified_usd includes something other than provider-native figures — an indicative (published-list-price) figure must never be summed into the savings total; report it in summary.indicative_monthly_usd instead"

# 2h. A WINDOWED NUMBER MUST NAME ITS WINDOW, and must not mix bases.
#     "Peaked under 10% all week" and "usage was 6% at 15:30" are different claims. A finding
#     that carries both lets a point-in-time snapshot be read as a sustained trend.
nobasis="$(jq -r '.findings[] | select((.utilization // "") != "" and ((.basis // "") == "")) | .id' "$F")"
[ -z "$nobasis" ] || fail "findings reporting a utilization with no basis (state 'p95 over 7d', 'max over 7d', or 'snapshot <ts>' so a snapshot is never read as a trend): $(echo "$nobasis" | tr '\n' ' ')"
mixed="$(jq -r '.findings[] | select(((.basis // "") | test("snapshot"; "i")) and ((.basis // "") | test("over [0-9]+[dhm]"; "i"))) | .id' "$F")"
[ -z "$mixed" ] || fail "findings whose basis mixes a snapshot with a window (split them into separate findings; one basis per finding): $(echo "$mixed" | tr '\n' ' ')"

# 2e. EXCLUSION DISCLOSURE. "Never silently dropped" was stated in the schema but
#     nothing enforced it, so a run whose cost scope was blocked could emit a clean-looking
#     report with no dollars and no reason — indistinguishable from "we looked and found
#     no waste". Live consequence: a customer read a thin cost section as good news.
#     Every excluded provider must name itself and a reason.
jq -e '(.providers_excluded | type) == "array"' "$F" >/dev/null 2>&1 \
  || fail "providers_excluded must be an array (use [] when nothing was excluded)"
badx="$(jq -r '[.providers_excluded[]? | select(((.provider // "") == "") or ((.reason // "") == "")) | (.provider // "?")] | join(" ")' "$F" 2>/dev/null)"
[ -z "$badx" ] || fail "providers_excluded entries missing a provider or a reason (an exclusion with no reason is a silent drop): $badx"
dupx="$(jq -r '[.providers_excluded[]?.provider] as $x | [.providers_covered[]? | select(. as $c | $x | index($c))] | join(" ")' "$F" 2>/dev/null)"
[ -z "$dupx" ] || fail "provider(s) in BOTH providers_covered and providers_excluded (a provider either ran or it did not): $dupx"

# 2f. A ZERO TOTAL MUST BE EXPLAINED. If not one provider produced a native figure, the
#     report has to say why — otherwise "could not look" renders identically to "nothing
#     to save", which is the exact failure this rule exists to stop.
if [ "$n_native" = "0" ]; then
  nx="$(jq -r '(.providers_excluded | length) // 0' "$F" 2>/dev/null)"
  [ "${nx:-0}" -gt 0 ] || fail "no finding carries a provider-native dollar figure, yet providers_excluded is empty: a \$0 cost report with no stated reason is indistinguishable from a blocked run. Record why each configured provider produced no figure (missing scope, API disabled, cost_checks:false, or 'returned no COST recommendations with full scope confirmed')."
fi

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
