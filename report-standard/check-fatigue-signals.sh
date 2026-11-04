#!/bin/sh
# Validate a local scoutflo-fatigue-signals/v1 snapshot before consumption.
# Usage: check-fatigue-signals.sh <signals.json> <audits-dir> <run-date>
# Structure/provenance checks do not prove provider observations are true.
set -eu
SIG="${1:?fatigue-signals.json}"
AUD="${2:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}}"
RD="${3:-$(date -u +%F)}"
command -v jq >/dev/null 2>&1 || { echo 'check-fatigue-signals: jq not installed' >&2; exit 1; }
[ -f "$SIG" ] && [ -r "$SIG" ] || { echo 'FATIGUE-SIGNALS-FAIL: input must be a readable regular file'; exit 1; }
# Require one JSON object. In particular, do not coerce malformed input to [].
jq -se 'length==1 and (.[0]|type)=="object"' "$SIG" >/dev/null 2>&1 \
  || { echo 'FATIGUE-SIGNALS-FAIL: input must contain one JSON object'; exit 1; }
jq -e '(.signals|type)=="array" and all(.signals[]; type=="object")
  and ((has("provider_coverage")|not) or ((.provider_coverage|type)=="array" and all(.provider_coverage[]; type=="object")))
  and ((has("incident_feed")|not) or (.incident_feed|type)=="object")' "$SIG" >/dev/null 2>&1 \
  || { echo 'FATIGUE-SIGNALS-FAIL: invalid signals, coverage or incident-feed shape'; exit 1; }

# Source IDs are optional for standalone observations. Every supplied ID must
# exist, including when the current run has NO findings. Retain v1's ID-only
# check: legacy findings can have structured targets and historical signals can
# omit target. This validates references, not a cross-account service mapping.
set --
for f in "$AUD"/*/"$RD"/findings.json "$AUD"/*/*/"$RD"/findings.json; do
  [ -f "$f" ] || continue
  relative="${f#"$AUD"/}"
  case "${relative%%/*}" in all|cost-analysis|cost|doctor|alert-fatigue) continue ;; esac
  set -- "$@" "$f"
done
VALID='[]'
if [ "$#" -gt 0 ]; then
  VALID="$(jq -s '[.[] | (.findings // [])[] | .id | select(type=="string" and length>0)]' "$@")" \
    || { echo 'FATIGUE-SIGNALS-FAIL: current findings cannot be read'; exit 1; }
fi
errors="$(jq -r --arg rd "$RD" --argjson valid "$VALID" '
  def text: type=="string" and test("\\S");
  def nonnegative: type=="number" and .>=0;
  . as $doc
  | [
    (if .schema!="scoutflo-fatigue-signals/v1" then "wrong schema" else empty end),
    # generated_at already belongs to the v1 output contract. An old or undated
    # measured snapshot is not evidence for a requested new run. Empty coverage-
    # only files need no timestamp because they make no measurement claims.
    (if ((.signals|length)>0 or .incident_feed.status=="collected") then
       (if ((.generated_at|type)!="string") then "measured input needs generated_at UTC provenance"
        elif ((.generated_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))|not) then "generated_at must be UTC ISO8601"
        elif ((try (.generated_at | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601 | strftime("%Y-%m-%d")) catch "") != $rd) then "generated_at does not belong to the requested run date"
        else empty end),
       (if (.window|text|not) then "measured input needs a stated window" else empty end)
     else empty end),
    (.signals | to_entries[] | .key as $i | .value as $s
      | (["provider","object_id","object_kind"][] as $k
           | if ($s[$k]|text|not) then "signal[\($i)] \($k) must be a nonempty string" else empty end),
        (if ($s|has("target")) and ($s.target|text|not) then "signal[\($i)] target must be a nonempty string" else empty end),
        (["fires","transitions","stuck_days"][] as $k
           | if ($s|has($k)) and ($s[$k]|nonnegative|not) then "signal[\($i)] \($k) must be a nonnegative number" else empty end),
        (["flapping","stuck","reaches_human"][] as $k
           | if ($s|has($k)) and ($s[$k]|type)!="boolean" then "signal[\($i)] \($k) must be boolean" else empty end),
        (if ($s|has("off_hours_fires")) and $s.off_hours_fires!=null then
           if ($s.off_hours_fires|nonnegative|not) then "signal[\($i)] off_hours_fires must be nonnegative or null"
           elif ($s.fires|nonnegative|not) then "signal[\($i)] off_hours_fires needs fires"
           elif $s.off_hours_fires>$s.fires then "signal[\($i)] off_hours_fires > fires (impossible)"
           else empty end else empty end),
        (if ($s|has("source_finding_ids")) then
           if ($s.source_finding_ids|type)!="array" then "signal[\($i)] source_finding_ids must be an array"
           else $s.source_finding_ids[] | if (text|not) then "signal[\($i)] source ID must be a nonempty string"
             elif (. as $id | $valid | index($id))==null then "signal[\($i)] source finding ID absent from this run"
             else empty end end else empty end),
        (($doc.provider_coverage // [])[]
          | select(.provider==$s.provider and (.tier // "fire-history")=="fire-history"
                   and ((has("target")|not) or .target==($s.target // $s.provider)))
          | if .status!="collected" then "signal[\($i)] contradicts non-collected provider coverage" else empty end)),
    ((.provider_coverage // []) | to_entries[] | .key as $i | .value as $c
      | (if ($c.provider|text|not) then "provider_coverage[\($i)] provider must be a nonempty string" else empty end),
        (if (["collected","verify-pending","spec-unverified","not-in-scope"] | index($c.status))==null
           then "provider_coverage[\($i)] invalid status" else empty end),
        (if $c.status=="verify-pending" and ($c.reason|text|not) then "provider_coverage[\($i)] verify-pending needs a reason" else empty end)),
    (if .incident_feed.status=="collected" then .incident_feed as $f
      | (["alerts_fired","incidents"][] as $k
          | if ($f[$k]|nonnegative|not) then "incident_feed \($k) must be nonnegative" else empty end),
        (["mtta_seconds","mttr_seconds"][] as $k
          | if ($f|has($k)) and ($f[$k]|nonnegative|not) then "incident_feed \($k) must be nonnegative" else empty end),
        (if ($f|has("actionable_pct")) and (($f.actionable_pct|nonnegative|not) or $f.actionable_pct>100)
          then "incident_feed actionable_pct must be 0 to 100" else empty end)
     else empty end)
  ] | .[]' "$SIG")" || { echo 'FATIGUE-SIGNALS-FAIL: input could not be validated'; exit 1; }
if [ -n "$errors" ]; then
  printf '%s\n' "$errors" | sed 's/^/  FAIL /'
  echo FATIGUE-SIGNALS-FAIL
  exit 1
fi
echo FATIGUE-SIGNALS-OK
