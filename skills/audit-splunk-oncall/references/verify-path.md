# Verify a repaired paging path

This is a read-only verification recipe for [SOC-001 through SOC-007](oncall-checks.md). It runs the shipped collector again and asserts a named, current relationship. It does not change configuration, emit a score or turn a false predicate into a finding. A failed verification needs the catalog's completeness, scope and confirming-read rules before a finding can be authored. An `inapplicable` selector result is not permission to emit a scored `by-design` exclusion: that needs the business-context SSOT and `resource_intent` provenance. Triage does not run these deep selectors. Setup's planning-only capabilities remain planning-only.

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

SOC-001 examines routes that contain the named policy and requires nonempty, unique target sets resolving uniquely in the global policy census. It does not prove an approved route-key mapping or preservation of unrelated/default routes: those need exact private-key comparison and before/after change evidence. SOC-002 verifies the exact intended team. SOC-003 verifies one supported immediate escalation step and its user/rotation identities. Additional steps or nonzero delays remain blocked rather than receiving invented timing semantics.

SOC-004 checks referenced rotation rosters and any reported current assignment, not future coverage. A policy with no rotation is inapplicable for this verification. Unknown modes and a current assignment outside the roster are blocked. SOC-005 requires current users to agree with eligible direct targets or the referenced rotations' current assignments. An unexplained override is blocked. A known unstaffed alternate shift does not erase a separately verified current direct-user path; keep that SOC-004 defect separate. Repeat missing-current observations after at least one second before reporting a gap, and name both observation times; one verification failure is not that confirmation.

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
RESULT=$(printf '%s' "$SNAPSHOT" | jq -ce -s --arg check "$CHECK" --arg policy "$POLICY" --arg team "$TEAM" --argjson selected "$POLICY_SET" --argjson minimum "$MINIMUM" '
  def outcome($s;$why): {status:$s,reason:$why};
  def blocked($why): outcome("blocked";$why);
  def unmet($why): outcome("not-met";$why);
  def passed: outcome("verified";"Requested current relationship is verified");
  def eligible($d;$u): [$d.members[]|select(.username==$u)] | length==1 and .[0].verified==true;
  def routes($s;$p): [$s.routes[]|select(.policies|index($p))];
  def routing($s;$p): routes($s;$p) as $r |
    if ($r|length)==0 then unmet("No configured route targets the selected policy")
    elif any($r[]; ((.out_of_scope_policies//[])|length)>0 or (.policies|length!=(unique|length))) then blocked("Route targets are ambiguous or outside the complete scope")
    elif all($r[]; (.policies|length)>0 and all(.policies[]; . as $id | [$s.policies[]|select(.slug==$id)] | length==1)) then passed
    elif any($r[].policies[]; . as $id | [$s.policies[]|select(.slug==$id)] | length>1) then blocked("Policy identity is ambiguous")
    else unmet("A configured route target does not resolve") end;
  def ownership($s;$p): [$s.policies[]|select(.slug==$p)] as $owners |
    if ($owners|length)>1 then blocked("Policy owner mapping is ambiguous")
    elif ($owners|length)==0 then unmet("Selected policy is absent from complete ownership inventory")
    else [$s.teams[]|select(.slug==$owners[0].team)] as $teams |
      if ($teams|length)>1 then blocked("Owning team identity is ambiguous")
      elif ($teams|length)==0 then unmet("Owning team is absent from complete inventory")
      else passed + {owner:$owners[0].team} end end;
  def path($s;$p): routing($s;$p) as $route | ownership($s;$p) as $own |
    if $route.status!="verified" then blocked("Routing prerequisite is not verified")
    elif $own.status!="verified" then $own
    else [$s.policy_details[]|select(.slug==$p)] as $details | [$s.team_details[]|select(.team==$own.owner)] as $td |
      if ($details|length)!=1 or ($td|length)!=1 then blocked("Policy or team detail is missing or ambiguous")
      elif ($td[0].members|map(.username)|length!=(unique|length)) then blocked("Member identity is ambiguous")
      elif ($details[0].steps|length)==0 then unmet("No escalation step exists")
      elif ($details[0].steps|length)!=1 or $details[0].steps[0].timeout!=0 then blocked("Later-step or delay semantics are not verified")
      else $details[0].steps[0].entries as $entries |
        if ($entries|length)==0 then unmet("No escalation target exists")
        elif any($entries[];.type!="user" and .type!="rotation_group") then blocked("Unsupported escalation target type")
        elif any($entries[]; .type=="user" and (eligible($td[0];.user)|not)) then unmet("A direct user is not one verified enrolled member")
        elif any($entries[]; .type=="rotation_group" and (.rotation as $id | [$td[0].groups[]|select(.slug==$id and .teamSlug==$own.owner)] | length>1)) then blocked("Rotation slug is ambiguous")
        elif any($entries[]; .type=="rotation_group" and (.rotation as $id | [$td[0].groups[]|select(.slug==$id and .teamSlug==$own.owner)] | length==0)) then unmet("Referenced rotation does not resolve")
        else [$entries[]|select(.type=="rotation_group")|.rotation as $id|$td[0].groups[]|select(.slug==$id)]|unique_by(.groupId) as $groups |
          if any($groups[]; .groupId as $id | [$td[0].rotations[]|select(.groupId==$id)] | length!=1) then blocked("Numeric rotation identity is missing or ambiguous")
          else passed + {owner:$own.owner,entries:$entries,data:$td[0],rotations:[$groups[]|.groupId as $id|$td[0].rotations[]|select(.groupId==$id)]} end
        end
      end
    end;
  def staffing($p):
    if $p.status!="verified" then $p
    elif ($p.rotations|length)==0 then outcome("inapplicable";"Selected policy has no rotation target")
    elif any($p.rotations[].shifts[];.shifttype!="std" and .shifttype!="pho") then blocked("Unknown shift mode")
    elif any($p.rotations[].shifts[];.current_user!=null and (.current_user as $u|.members|index($u)==null)) then blocked("Current assignment may be an unverified override")
    elif any($p.rotations[];(.shifts|length)==0) or any($p.rotations[].shifts[];(.members|length)==0 or any(.members[];eligible($p.data;.)|not)) then unmet("A referenced shift lacks eligible enrolled staff")
    else passed end;
  def current_path($s;$id): path($s;$id) as $p |
    if $p.status!="verified" then blocked("Supported escalation prerequisite is not verified")
    elif ($p.rotations|length)>0 and staffing($p).status=="blocked" then blocked("Referenced rotation semantics or override is not verified")
    else [$s.current[]|select(.policy==$id)] as $now |
      if ($now|length)>1 then blocked("Current policy row is ambiguous")
      elif ($now|length)==0 or ($now[0].users|length)==0 then unmet("No current responder observed; confirm with another read before a finding")
      elif $now[0].team!=$p.owner then blocked("Current policy owner disagrees")
      elif any($now[0].users[];eligible($p.data;.)|not) then unmet("Current responder is not an eligible enrolled team member")
      else ([$p.entries[]|select(.type=="user")|.user]+[$p.rotations[].shifts[].current_user|select(.!=null)]|unique) as $expected |
        if any($now[0].users[];. as $u|$expected|index($u)==null) then blocked("Current assignment differs from the supported path; override proof required")
        else passed + {owner:$p.owner,users:($now[0].users|unique)} end
      end
    end;
  if length!=1 then blocked("Collector returned an ambiguous document set") else .[0] as $s |
    if $s.complete_reads!=true or $s.scope!="account" or ([$s.teams,$s.policies,$s.routes,$s.current,$s.policy_details,$s.team_details]|all(type=="array")|not) then blocked("A complete account snapshot is required")
    elif $check=="SOC-001" then routing($s;$policy)
    elif $check=="SOC-002" then ownership($s;$policy) | if .status=="verified" and .owner!=$team then unmet("Owner differs from the explicitly intended team") else . end
    elif $check=="SOC-003" then path($s;$policy)
    elif $check=="SOC-004" then staffing(path($s;$policy))
    elif $check=="SOC-005" then current_path($s;$policy)
    elif $check=="SOC-006" then [$selected[]|current_path($s;.)] as $paths |
      if any($paths[];.status!="verified") then blocked("A required current policy path is not verified")
      else ([$paths[].users[]]|unique|length) as $n | (if $n>=$minimum then passed else unmet("Distinct current eligible responders are below the explicit requirement") end)+{observed_responders:$n,required_responders:$minimum} end
    else current_path($s;$policy) as $p |
      if ($s.source_match|type)!="object" or ($s.source_match.route_aliases|type)!="array" or ($s.source_match.policies|type)!="array" then blocked("Exact source-key comparison is unavailable")
      elif ($s.source_match.route_aliases|length)>1 then blocked("Source key matched multiple route identities")
      elif ($s.source_match.route_aliases|length)==0 or ($s.source_match.policies|index($policy))==null then unmet("Exact source key does not select the intended policy")
      elif $p.status!="verified" then blocked("Expected response path is not verified")
      elif $p.owner!=$team then unmet("Source path owner differs from intended team")
      else passed end
    end
  end | {check:$check,policy:$policy,status,reason} + (if has("observed_responders") then {observed_responders,required_responders} else {} end)
' 2>/dev/null) || { echo 'Verification blocked by an unsupported snapshot shape'; exit 2; }
printf '%s\n' "$RESULT"
case "$(printf '%s' "$RESULT" | jq -r '.status')" in verified) exit 0;; not-met) exit 1;; inapplicable) exit 3;; *) exit 2;; esac
```
<!-- oncall-verify-path:end -->

The snapshot remains in memory; this block writes no files. Keep the small result beside the reviewed change only after redaction. A `verified` result proves the named predicate at the collector's observation times. Record those times from the corresponding audit evidence, keep the unchanged-object/rollback proof separately, and rerun the complete audit before claiming the overall paging path repaired.
