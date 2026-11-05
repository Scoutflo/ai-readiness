# Verify a repaired paging path

This is a read-only verification recipe for [SOC-001 through SOC-007](oncall-checks.md). It runs the shipped collector again and asserts a named, current relationship. It does not change configuration, emit a score or turn a false predicate into a finding. A failed verification needs the catalog's completeness, scope and confirming-read rules before a finding can be authored. An `inapplicable` selector result is not permission to emit a scored `by-design` exclusion: that needs the business-context SSOT and `resource_intent` provenance. Triage does not run these deep selectors. Setup executes its guarded recipes or attended editor workflows under separate change approval. These verification reads never authorize or perform their mutations.

## Select the exact verification

Use the same `SCOUTFLO_CONFIG` and `SCOUTFLO_TARGET` as the audit. The collector resolves credentials and the configured account anchor; this recipe never loads an elevated key. Supply these non-secret selectors from the reviewed change or explicit intended path:

| Input | Requirement |
| --- | --- |
| `SCOUTFLO_VERIFY_CHECK` | One of `SOC-001` through `SOC-007` |
| `SCOUTFLO_VERIFY_POLICY` | Required exact policy slug; never choose a policy by name or the first result |
| `SCOUTFLO_VERIFY_TEAM` | Exact intended owning-team slug, required for SOC-002 and SOC-007 |
| `SCOUTFLO_VERIFY_POLICIES` | Optional JSON array for SOC-006, containing the required policy set including `SCOUTFLO_VERIFY_POLICY`; defaults to that one policy |
| `SCOUTFLO_VERIFY_MIN_RESPONDERS` | SOC-006's explicit positive integer requirement; literal `none` only when the operator declares no redundancy requirement. Missing is blocked. |
| `SCOUTFLO_VERIFY_SOURCE_EVIDENCE` | SOC-007's existing, verified, safely projected source-side evidence record, described below |
| `SCOUTFLO_VERIFY_SOURCE_MAX_AGE_SECONDS` | Positive integer freshness window; example default `3600`. Choose a shorter window for frequently changed sources. |
| `SCOUTFLO_VERIFY_CLOCK_SKEW_SECONDS` | Positive integer allowance for source clock skew; example default `60`. Set from the observed clock accuracy. |
| `SCOUTFLO_VERIFY_SOURCE_SCOPE` | Literal `none` only for an explicit declaration that no sender is in scope; never set from missing evidence |

SOC-001 examines routes that contain the named policy and requires nonempty, unique target sets resolving uniquely in the global policy census. It does not prove an approved route-key mapping or preservation of unrelated/default routes: those need exact private-key comparison and before/after change evidence. SOC-002 verifies the exact intended team. SOC-003 verifies the complete bounded ordered escalation graph, including minute-valued relative delays, nested policies and observed current/next/previous rotation identities. The shared [effective-quality evaluator](effective-quality.md) preserves intentional delays and only applies a timing goal when explicitly declared. Unobserved prior assignments, effective overrides and unsupported notification semantics stay explicit. No audit writes are introduced.

SOC-004 checks referenced rotation rosters and any reported current assignment, not future coverage. A policy with no rotation is inapplicable for this verification. Unknown modes and a current assignment outside the roster require effective override evidence. Standard, period-handoff, custom and follow-the-sun membership are distinguished from rendered future coverage (SOC-016). SOC-005 requires current users to agree with eligible direct targets or the referenced rotations' current assignments. An unexplained override is blocked. A known unstaffed alternate shift does not erase a separately verified current direct-user path; keep that SOC-004 defect separate. Repeat missing-current observations after at least one second before reporting a gap, and name both observation times; one verification failure is not that confirmation.

SOC-006 deduplicates actual current users across the explicitly selected policy set. Two policies reaching one person count as one person. SOC-007 additionally requires one exact source-key match and the expected policy/team/current path. None of these predicates proves notification delivery, independent devices, tomorrow's schedule or incident-history completeness.

## Source-side evidence for SOC-007

Prepare this record from an already verified source-side read, never by guessing a receiver handle or copying an incoming URL. The file contains metadata only: `source_id`, UTC `observed_at` in `YYYY-MM-DDTHH:MM:SSZ` form, `route_env` naming the protected source routing-key variable, `expected_policy`, `expected_team`, and `verified: true`. The verification flag records a completed source-side verification; setting a flag cannot make an unverified source trustworthy. Check the underlying source evidence and its provenance before using the file. Do not put the key, incoming URL, raw source configuration or contact values in it.

The recipe uses an example freshness window of one hour and clock-skew allowance of one minute. These are operator policy defaults, not provider guarantees. Set the named positive-integer inputs above for the source change rate and measured clock accuracy; a longer window must be an explicit choice. A changed source invalidates that evidence immediately. Re-read the source when it is stale or has changed. The collector receives only `--source-route-env <variable-name>` and returns `source_match.route_aliases` and `source_match.policies`; the value comparison happens in memory before projection. Missing evidence or an unpopulated source-match contract is blocked, not a passing or deliberately excluded source.

## Fresh read and assertion

All helpers below are local to this one block. The output is a small JSON verification result. Exit 0 means the specific predicate was verified, 1 means the complete observed state did not meet it, 2 means blocked/unknown, and 3 means explicitly inapplicable. These are verification outcomes, not audit severities or findings.

<!-- oncall-verify-path:start -->
```bash
set -eu
set +x
[ "${SCOUTFLO_TRIAGE:-0}" = 0 ] || { echo 'Deep path verification requires an explicit full run (SCOUTFLO_TRIAGE=0)'; exit 2; }
CHECK="${SCOUTFLO_VERIFY_CHECK:-}"
POLICY="${SCOUTFLO_VERIFY_POLICY:-}"
TEAM="${SCOUTFLO_VERIFY_TEAM:-}"
MINIMUM="${SCOUTFLO_VERIFY_MIN_RESPONDERS:-}"
SOURCE_FILE="${SCOUTFLO_VERIFY_SOURCE_EVIDENCE:-}"
case "$CHECK" in SOC-001|SOC-002|SOC-003|SOC-004|SOC-005|SOC-006|SOC-007) ;; *) echo 'Select SCOUTFLO_VERIFY_CHECK'; exit 2;; esac
case "$POLICY" in ''|*[!A-Za-z0-9_-]*) echo 'Set an exact SCOUTFLO_VERIFY_POLICY'; exit 2;; esac
case "$TEAM" in *[!A-Za-z0-9_-]*) echo 'Invalid intended team'; exit 2;; esac
case "$CHECK" in SOC-002) [ -n "$TEAM" ] || { echo 'Set the exact intended SCOUTFLO_VERIFY_TEAM'; exit 2; };; SOC-007) [ "${SCOUTFLO_VERIFY_SOURCE_SCOPE:-}" = none ] || [ -n "$TEAM" ] || { echo 'Set the exact intended SCOUTFLO_VERIFY_TEAM'; exit 2; };; esac
command -v jq >/dev/null || { echo 'jq is required'; exit 2; }
POLICY_SET="${SCOUTFLO_VERIFY_POLICIES:-}"
[ -n "$POLICY_SET" ] || POLICY_SET=$(jq -nc --arg p "$POLICY" '[$p]')
printf '%s' "$POLICY_SET" | jq -e --arg p "$POLICY" 'type=="array" and length>0 and all(.[];type=="string" and test("^[A-Za-z0-9_-]+$")) and (length==(unique|length)) and index($p)!=null' >/dev/null 2>&1 || { echo 'Invalid or ambiguous policy set'; exit 2; }
if [ "$CHECK" = SOC-006 ]; then
  if [ "$MINIMUM" = none ]; then echo '{"status":"inapplicable","reason":"Explicit declaration: no responder redundancy requirement"}'; exit 3; fi
  printf '%s' "$MINIMUM" | jq -Rse 'test("^[1-9][0-9]*$") and (tonumber|isinfinite|not)' >/dev/null 2>&1 || { echo 'Declare a positive responder minimum or explicitly none'; exit 2; }
else MINIMUM=1; fi
READER="${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/scripts/collect.sh"
if [ "$CHECK" = SOC-007 ]; then
  if [ "${SCOUTFLO_VERIFY_SOURCE_SCOPE:-}" = none ]; then echo '{"status":"inapplicable","reason":"Explicit declaration: no sender in scope"}'; exit 3; fi
  [ -n "$SOURCE_FILE" ] && [ -f "$SOURCE_FILE" ] || { echo 'Verified source-side evidence is required'; exit 2; }
  MAX_AGE="${SCOUTFLO_VERIFY_SOURCE_MAX_AGE_SECONDS:-3600}"
  CLOCK_SKEW="${SCOUTFLO_VERIFY_CLOCK_SKEW_SECONDS:-60}"
  for WINDOW in "$MAX_AGE" "$CLOCK_SKEW"; do
    printf '%s' "$WINDOW" | jq -Rse 'test("^[1-9][0-9]*$") and (tonumber|isinfinite|not)' >/dev/null 2>&1 || { echo 'Source evidence time windows must be positive integers'; exit 2; }
  done
  SOURCE=$(jq -ce -s --argjson age "$MAX_AGE" --argjson skew "$CLOCK_SKEW" --arg p "$POLICY" --arg t "$TEAM" 'select(length==1) | .[0] | select(type=="object" and .verified==true and (.source_id|type=="string" and length>0) and (.route_env|type=="string" and test("^[A-Za-z_][A-Za-z0-9_]*$")) and .expected_policy==$p and .expected_team==$t) | (.observed_at|fromdateiso8601) as $at | select($at<=now+$skew and $at>=now-$age) | {route_env}' "$SOURCE_FILE" 2>/dev/null) || { echo 'Source evidence is invalid, stale or for another path'; exit 2; }
  [ -n "$SOURCE" ] || { echo 'Source evidence did not select one verified path'; exit 2; }
  ROUTE_ENV=$(printf '%s' "$SOURCE" | jq -er '.route_env')
  SNAPSHOT=$(sh "$READER" --source-route-env "$ROUTE_ENV") || { echo 'Current source/path read is blocked'; exit 2; }
else
  SNAPSHOT=$(sh "$READER") || { echo 'Current path read is blocked'; exit 2; }
fi
# Execute the single shipped cookbook so audit and setup verification cannot drift.
EVALUATOR=$(awk '/oncall-effective-quality:start/ {active=1;next} /oncall-effective-quality:end/ {active=0} active && /^```bash/ {fence=1;next} active && /^```/ {fence=0;next} active && fence {print}' "${CLAUDE_PLUGIN_ROOT}/skills/audit-splunk-oncall/references/effective-quality.md")
[ -n "$EVALUATOR" ] || { echo 'Effective-quality cookbook is unavailable'; exit 2; }
RC=0
RESULT=$(printf '%s' "$SNAPSHOT" | SCOUTFLO_ONCALL_SNAPSHOT='' sh -c "$EVALUATOR") || RC=$?
printf '%s\n' "$RESULT"
exit "$RC"
```
<!-- oncall-verify-path:end -->

The snapshot remains in memory; this block writes no files. Keep the small result beside the reviewed change only after redaction. A `verified` result proves the named predicate at the collector's observation times. Record those times from the corresponding audit evidence, keep the unchanged-object/rollback proof separately, and rerun the complete audit before claiming the overall paging path repaired.
