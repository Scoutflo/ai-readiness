#!/bin/sh
# check-fatigue-signals.sh — validate a fatigue-signals.json (the measured
# fire-history tier) before the alert-fatigue library analyzes it.
#
# Why this exists: fatigue-signals.json is the ONE alert-fatigue input produced by
# the model-driven fire-history collection lane (references/fire-history-reads.md),
# not by a deterministic emitter — so it is the highest hallucination risk in the
# whole capability, yet it fed AF-004/005/006 with no gate. This validator makes a
# malformed or invented signals file fail closed: it checks the schema envelope,
# per-signal field types, provider_coverage honesty, the incident_feed block, the
# off-hours-vs-fires sanity bound, AND — the key never-fabricate invariant — that
# every source_finding_ids entry actually exists in THIS run's findings (the same
# "cite a real finding id" rule AF-001/002 already enforce). It checks structure
# and cross-reference, never whether a measured number is TRUE about the live
# system (only a live run proves that).
#
# Usage: check-fatigue-signals.sh <fatigue-signals.json> <audits-dir> <run-date>
# Exit 0 = valid (prints FATIGUE-SIGNALS-OK). Exit 1 = violation (lists each).
set -eu

SIG="${1:?fatigue-signals.json}"
AUD="${2:-${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}}"
RD="${3:-$(date -u +%F)}"
command -v jq >/dev/null 2>&1 || { echo "check-fatigue-signals: jq not installed" >&2; exit 1; }
[ -f "$SIG" ] || { echo "check-fatigue-signals: no such file: $SIG" >&2; exit 1; }

fail=0
bad() { echo "  FAIL $1"; fail=$((fail+1)); }

# valid JSON?
jq -e . "$SIG" >/dev/null 2>&1 || { echo "  FAIL not valid JSON"; echo "FATIGUE-SIGNALS-FAIL"; exit 1; }

# 1. envelope
[ "$(jq -r '.schema // ""' "$SIG")" = "scoutflo-fatigue-signals/v1" ] \
  || bad "schema is not scoutflo-fatigue-signals/v1"
jq -e '(.signals // null) | type == "array"' "$SIG" >/dev/null 2>&1 \
  || bad ".signals must be an array"

# 2. per-signal required fields + types (booleans are bool-or-absent, numerics number-or-absent;
#    test presence with has(), never coerce a bool with //).
bad_sig="$(jq -r '
  [ (.signals // []) | to_entries[]
    | .key as $i | .value as $s
    | [ (if ($s.provider|type) != "string" then "signal[\($i)] provider not a string" else empty end),
        (if ($s.object_id|type) != "string" then "signal[\($i)] object_id not a string" else empty end),
        (if ($s.object_kind|type) != "string" then "signal[\($i)] object_kind not a string" else empty end),
        (if ($s|has("fires")) and ($s.fires|type) != "number" then "signal[\($i)] fires not a number" else empty end),
        (if ($s|has("transitions")) and ($s.transitions|type) != "number" then "signal[\($i)] transitions not a number" else empty end),
        (if ($s|has("stuck_days")) and ($s.stuck_days|type) != "number" then "signal[\($i)] stuck_days not a number" else empty end),
        (if ($s|has("flapping")) and ($s.flapping|type) != "boolean" then "signal[\($i)] flapping not a boolean" else empty end),
        (if ($s|has("stuck")) and ($s.stuck|type) != "boolean" then "signal[\($i)] stuck not a boolean" else empty end),
        (if ($s|has("reaches_human")) and ($s.reaches_human|type) != "boolean" then "signal[\($i)] reaches_human not a boolean" else empty end),
        (if ($s|has("off_hours_fires")) and (($s.off_hours_fires) != null) and ($s.off_hours_fires|type) != "number" then "signal[\($i)] off_hours_fires not number-or-null" else empty end),
        (if ($s|has("source_finding_ids")) and ($s.source_finding_ids|type) != "array" then "signal[\($i)] source_finding_ids not an array" else empty end),
        (if ($s|has("off_hours_fires")) and (($s.off_hours_fires) != null) and ($s|has("fires")) and (($s.off_hours_fires) > ($s.fires)) then "signal[\($i)] off_hours_fires > fires (impossible)" else empty end),
        (if ($s|has("off_hours_fires")) and (($s.off_hours_fires) != null) and (($s|has("fires"))|not) then "signal[\($i)] off_hours_fires present without fires" else empty end)
      ] | .[] ]
  | .[]' "$SIG" 2>/dev/null)"
if [ -n "$bad_sig" ]; then
  printf '%s\n' "$bad_sig" | while IFS= read -r m; do echo "  FAIL $m"; done
  fail=$((fail + $(printf '%s\n' "$bad_sig" | grep -c .)))
fi

# 3. provider_coverage honesty: status in the allowed set; verify-pending carries a reason.
bad_cov="$(jq -r '
  [ (.provider_coverage // []) | to_entries[] | .key as $i | .value as $c
    | [ (if ($c.provider|type) != "string" then "provider_coverage[\($i)] provider not a string" else empty end),
        (if ([ "collected","verify-pending","spec-unverified","not-in-scope" ] | index($c.status // "")) == null
           then "provider_coverage[\($i)] status not in {collected,verify-pending,spec-unverified,not-in-scope}" else empty end),
        (if (($c.status // "") == "verify-pending") and (($c.reason // "") == "") then "provider_coverage[\($i)] verify-pending needs a reason" else empty end)
      ] | .[] ] | .[]' "$SIG" 2>/dev/null)"
if [ -n "$bad_cov" ]; then
  printf '%s\n' "$bad_cov" | while IFS= read -r m; do echo "  FAIL $m"; done
  fail=$((fail + $(printf '%s\n' "$bad_cov" | grep -c .)))
fi

# 4. incident_feed: when collected, alerts_fired + incidents must both be numbers.
if jq -e '(.incident_feed.status // "") == "collected"' "$SIG" >/dev/null 2>&1; then
  jq -e '(.incident_feed.alerts_fired|type) == "number" and (.incident_feed.incidents|type) == "number"' "$SIG" >/dev/null 2>&1 \
    || bad "incident_feed.status=collected but alerts_fired/incidents are not both numbers"
fi

# 5. never-fabricate cross-reference: every source_finding_ids entry exists in THIS run's findings.
#    Match by finding id ONLY (not target+id): a findings.json .target can be a structured
#    object (audit-signoz) while a signal target is a plain provider label, so a target-join
#    would false-fail. Id-only still catches a hallucinated/absent id (the real risk).
set --
for f in "$AUD"/*/"$RD"/findings.json "$AUD"/*/*/"$RD"/findings.json; do
  [ -e "$f" ] || continue
  case "$f" in */all/*|*/cost-analysis/*|*/cost/*|*/doctor/*|*/alert-fatigue/*) continue ;; esac
  set -- "$@" "$f"
done
if [ "$#" -gt 0 ]; then
  VALID="$(jq -s '[ .[] | (.findings // [])[] | (.id // "") | select(. != "") ]' "$@")"
  bad_ref="$(jq -r --argjson valid "$VALID" '
    ($valid | map({(.): true}) | add // {}) as $set
    | [ (.signals // [])[] | . as $s | ($s.source_finding_ids // [])[]
        | select(($set[.]) != true)
        | "signal " + ($s.provider // "?") + "/" + ($s.object_id // "?") + " cites finding id " + . + " absent from this run findings" ]
    | .[]' "$SIG" 2>/dev/null)"
  if [ -n "$bad_ref" ]; then
    printf '%s\n' "$bad_ref" | while IFS= read -r m; do echo "  FAIL $m"; done
    fail=$((fail + $(printf '%s\n' "$bad_ref" | grep -c .)))
  fi
fi
# A pure-standalone fire-history run with no config audit today has no findings to
# join against — that is not a violation (nothing to cross-check).

if [ "$fail" -eq 0 ]; then echo "FATIGUE-SIGNALS-OK"; exit 0; else echo "FATIGUE-SIGNALS-FAIL ($fail)"; exit 1; fi
