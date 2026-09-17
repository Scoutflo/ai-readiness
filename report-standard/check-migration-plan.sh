#!/bin/sh
# check-migration-plan.sh — validate a migration-plan.json before it is rendered
# or handed to a customer.
#
# Why this exists: the plan skeleton is deterministic (lib/migration-plan.sh),
# but the skill's enrichment pass — target shapes, equivalence classes, gap
# alternatives — is model-produced, which makes it the hallucination risk of the
# capability. This validator makes a dishonest or malformed plan fail closed:
#   - every object carries exactly one disposition from the closed enum, with a reason
#   - a drop-candidate or fix-then-migrate NEVER ships without evidence (a finding
#     id or a measured signal) — no evidence-free drops, ever
#   - drop/fix evidence finding-ids must exist in THIS run's source findings when
#     the audits dir is supplied (the same never-fabricate cross-check the
#     fatigue-signals validator runs)
#   - already-covered requires full mode + a matched_target (you cannot claim
#     target coverage in source-only mode — that would be fabricated)
#   - equivalence, when present, is from the closed class enum; a no-equivalent
#     object/kind must carry a real alternative (no bare "gap")
#   - cutover.historical_telemetry MUST be "does-not-transfer" — the structural
#     lock on the "no data loss" honesty (config carries; history does not)
#   - totals reconcile with the inventory
#
# Usage: check-migration-plan.sh <migration-plan.json> [audits-dir] [run-date]
# Read-only. POSIX sh + jq. Exit 0 = PASS, 1 = FAIL (each failure named).

set -eu

PLAN="${1:?usage: check-migration-plan.sh <migration-plan.json> [audits-dir] [run-date]}"
ADIR="${2:-}"
RDATE="${3:-}"

fail=0
bad() { echo "CHECK-MIGRATION-PLAN: $1"; fail=1; }

[ -f "$PLAN" ] || { echo "CHECK-MIGRATION-PLAN: no such file: $PLAN"; exit 1; }
jq -e . "$PLAN" >/dev/null 2>&1 || { echo "CHECK-MIGRATION-PLAN: not valid JSON: $PLAN"; exit 1; }

# --- envelope ---------------------------------------------------------------
jq -e '.schema == "scoutflo-migration-plan/v1"' "$PLAN" >/dev/null || bad "schema is not scoutflo-migration-plan/v1"
jq -e '.mode == "full" or .mode == "source-only"' "$PLAN" >/dev/null || bad "mode must be full|source-only"
jq -e '(.source.provider | type) == "string" and (.target.provider | type) == "string"' "$PLAN" >/dev/null || bad "source.provider/target.provider missing"
jq -e '(.inventory | type) == "array" and (.inventory | length) > 0' "$PLAN" >/dev/null || bad "inventory missing or empty"

# --- per-object invariants ---------------------------------------------------
BADOBJ="$(jq -r '
  [ .inventory[]
    | select(
        ((.name // "") == "")
        or ((.kind // "") == "")
        or (((.disposition // "") | IN("migrate","fix-then-migrate","drop-candidate","already-covered","no-equivalent")) | not)
        or ((.disposition_reason // "") == "")
      )
    | (.name // "(unnamed)") ]
  | .[0:5] | join(", ")' "$PLAN")"
[ -z "$BADOBJ" ] || bad "objects with missing name/kind/reason or disposition outside the enum: $BADOBJ"

# drop-candidate / fix-then-migrate must carry evidence — never an evidence-free drop
NOEV="$(jq -r '
  [ .inventory[]
    | select(.disposition == "drop-candidate" or .disposition == "fix-then-migrate")
    | select(((.evidence // []) | length) == 0)
    | .name ] | .[0:5] | join(", ")' "$PLAN")"
[ -z "$NOEV" ] || bad "drop-candidate/fix-then-migrate WITHOUT evidence (never allowed): $NOEV"

# already-covered only in full mode, and must name the matched target object
BADCOV="$(jq -r '
  .mode as $m
  | [ .inventory[]
      | select(.disposition == "already-covered")
      | select(($m != "full") or ((.matched_target // "") == "")) | .name ]
  | .[0:5] | join(", ")' "$PLAN")"
[ -z "$BADCOV" ] || bad "already-covered claimed in source-only mode or without matched_target (fabricated coverage): $BADCOV"

# equivalence class, when present, is from the closed enum
BADEQ="$(jq -r '
  [ .inventory[]
    | select(has("equivalence"))
    | select(((.equivalence // "") | IN("direct","approximate","manual","none")) | not)
    | .name ] | .[0:5] | join(", ")' "$PLAN")"
[ -z "$BADEQ" ] || bad "equivalence outside direct|approximate|manual|none: $BADEQ"

# every no-equivalent object has a real alternative (its own, or a gaps[] row for its kind)
NOALT="$(jq -r '
  (.gaps // []) as $g
  | [ .inventory[]
      | . as $it
      | select($it.disposition == "no-equivalent")
      | select(
          (($it.alternative // "") == "")
          and (([ $g[]
                  | select(.kind == $it.kind)
                  | select(((.alternative // "") | length) > 0)
                  | select((.alternative // "") | startswith("pending-catalog") | not) ] | length) == 0)
        )
      | $it.name ] | .[0:5] | join(", ")' "$PLAN")"
[ -z "$NOALT" ] || bad "no-equivalent objects without a real alternative (bare gaps are not allowed): $NOALT"

# the structural honesty lock: history never migrates
jq -e '.cutover.historical_telemetry == "does-not-transfer"' "$PLAN" >/dev/null \
  || bad 'cutover.historical_telemetry must be "does-not-transfer" (config carries over; history does not — never claim otherwise)'

# --- totals reconcile ---------------------------------------------------------
jq -e '
  (.inventory | length) as $n
  | (.totals.objects == $n)
  and (.totals.migrate == ([ .inventory[] | select(.disposition == "migrate") ] | length))
  and (.totals.fix_then_migrate == ([ .inventory[] | select(.disposition == "fix-then-migrate") ] | length))
  and (.totals.drop_candidates == ([ .inventory[] | select(.disposition == "drop-candidate") ] | length))
  and (.totals.already_covered == ([ .inventory[] | select(.disposition == "already-covered") ] | length))
  and (.totals.no_equivalent == ([ .inventory[] | select(.disposition == "no-equivalent") ] | length))
' "$PLAN" >/dev/null || bad "totals do not reconcile with the inventory dispositions"

# --- never-fabricate cross-check: evidence finding-ids exist in this run ------
if [ -n "$ADIR" ] && [ -n "$RDATE" ]; then
  SRC="$(jq -r '.source.provider' "$PLAN")"
  set --
  for f in "$ADIR/$SRC/$RDATE/findings.json" "$ADIR/$SRC"/*/"$RDATE/findings.json"; do
    [ -e "$f" ] || continue
    set -- "$@" "$f"
  done
  if [ "$#" -gt 0 ]; then
    KNOWN="$(jq -s '[ .[] | (.findings // [])[] | .id ] | unique' "$@")"
    GHOST="$(jq -r --argjson known "$KNOWN" '
      [ .inventory[]
        | select(.disposition == "drop-candidate" or .disposition == "fix-then-migrate")
        | .evidence[]? | select(has("finding_id")) | .finding_id
        | select(IN($known[]) | not) ]
      | unique | .[0:5] | join(", ")' "$PLAN")"
    [ -z "$GHOST" ] || bad "evidence cites finding-ids that do not exist in this run's $SRC findings (fabricated evidence): $GHOST"
  else
    echo "CHECK-MIGRATION-PLAN: note — no $SRC findings for $RDATE under $ADIR; evidence cross-check skipped (validator still enforces evidence presence)"
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "CHECK-MIGRATION-PLAN FAILED"
  exit 1
fi
echo "CHECK-MIGRATION-PLAN-OK ($PLAN)"
