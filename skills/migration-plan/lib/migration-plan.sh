#!/bin/sh
# migration-plan.sh
# Deterministic core of the migration-plan skill: builds the DISPOSITION SKELETON
# of a source->target migration plan from artifacts ALREADY ON DISK. Zero provider
# calls in this library (same invariant as alert-fatigue.sh / correlation-engine.sh)
# - the skill's own read-only detail pulls happen in the skill lane, per the pair
# catalog (references/<source>-to-<target>.md), and enrich what this emits.
#
# What it does:
#   1. Collects the SOURCE audit artifacts (inventory.json + findings.json) for a
#      run date - artifact-first: if the audit ran, nothing is re-pulled.
#   2. Collects the TARGET inventory the same way (absent -> source-only mode).
#   3. Loads the optional fatigue-signals.json (measured fire-history evidence).
#   4. Joins them into one EVIDENCE-CITED disposition per source object:
#        migrate | fix-then-migrate | drop-candidate | already-covered | no-equivalent
#      A drop/fix disposition is only ever proposed WITH evidence (a finding id or
#      a measured signal) - the plan proposes, the human decides; nothing is
#      silently dropped.
#   5. Writes the migration-plan.json skeleton the skill then enriches with
#      per-object target shapes + equivalence classes from the pair catalog, and
#      that report-standard/check-migration-plan.sh validates before rendering.
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<source>/<date>/{inventory,findings}.json
#         (and the two-level <source>/<label>/<date>/ layout - signoz/kubernetes
#         always nest, multi-target labels too; same dual-glob as every consumer)
#         ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/**/<date>/inventory.json
#         Optional: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/fatigue-signals.json
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/migration-plans/<source>-to-<target>/<date>/migration-plan.json
#
# Never mutates a provider. Never re-scores a finding. A tier with no data is
# stated (source-only mode), never guessed.

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
SIGNALS_FILE="${ALERT_FATIGUE_SIGNALS:-${AUDITS_DIR}/fatigue-signals.json}"

# Supported pairs: the lib carries a per-source kind map; a pair without a catalog
# fails honestly (the SKILL's supported-pairs table is the user-facing mirror).
migration_plan_pair_supported() {
  case "$1-to-$2" in
    datadog-to-signoz) return 0 ;;
    *) return 1 ;;
  esac
}

# Per-kind defaults for the datadog source: disposition default + default
# equivalence class, refined per object by the skill using the pair catalog.
# synthetic_test/composite have NO SigNoz equivalent (alternatives live in the
# catalog); slo is carried by MANUAL reconstruction; downtime maps approximately
# to planned maintenance.
migration_plan_kind_map() {
  jq -n '{
    monitor:        {disposition: "migrate",       equivalence_default: "approximate"},
    slo:            {disposition: "migrate",       equivalence_default: "manual"},
    downtime:       {disposition: "migrate",       equivalence_default: "approximate"},
    dashboard:      {disposition: "migrate",       equivalence_default: "manual"},
    synthetic_test: {disposition: "no-equivalent", equivalence_default: "none"},
    composite:      {disposition: "no-equivalent", equivalence_default: "none"},
    log_pipeline:   {disposition: "migrate",       equivalence_default: "manual"}
  }'
}

# Collect one provider's artifacts for the date across the one- and two-level
# layouts. $1=provider $2=date $3=what (inventory|findings). Emits a JSON array
# (inventory items or findings, flattened across label dirs).
migration_plan_collect() {
  mp_prov="$1"; mp_date="$2"; mp_what="$3"
  set --
  for f in "$AUDITS_DIR/$mp_prov/$mp_date/$mp_what.json" "$AUDITS_DIR/$mp_prov"/*/"$mp_date/$mp_what.json"; do
    [ -e "$f" ] || continue
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then echo "[]"; return 0; fi
  if [ "$mp_what" = "inventory" ]; then
    jq -s '[ .[] | (.items // [])[] ]' "$@"
  else
    jq -s '[ .[] | (.findings // [])[] ]' "$@"
  fi
}

migration_plan_load_signals() {
  if [ -f "$SIGNALS_FILE" ]; then
    jq '(.signals // [])' "$SIGNALS_FILE" 2>/dev/null || echo "[]"
  else
    echo "[]"
  fi
}

# The deterministic disposition join. Args are JSON strings:
# $1=source items  $2=source findings  $3=signals  $4=target items  $5=mode(full|source-only)
# Precedence per object: kind no-equivalent > already-covered > drop-candidate
# > fix-then-migrate > kind default. drop/fix only WITH evidence, by construction.
migration_plan_dispositions() {
  mp_items="$1"; mp_findings="$2"; mp_signals="$3"; mp_titems="$4"; mp_mode="$5"
  printf '%s' "$mp_items" | jq \
    --argjson findings "$mp_findings" \
    --argjson signals "$mp_signals" \
    --argjson titems "$mp_titems" \
    --argjson kindmap "$(migration_plan_kind_map)" \
    --arg mode "$mp_mode" '
    def norm: (. // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "");
    ([ $titems[] | (.name | norm) ]) as $tnames
    | [ .[]
        | . as $it
        | (($it.name // "") | norm) as $n
        | ([ $findings[] | select((.affected // []) | map(norm) | index($n)) ]) as $ev
        | ([ $signals[] | select(((.object_id // "") | norm) == $n) ]) as $sig
        | ($ev | map((.title // "") | ascii_downcase) | join(" | ")) as $evtitles
        | (($kindmap[$it.kind // "monitor"] // {disposition: "migrate", equivalence_default: "manual"})) as $kd
        | (
            ($ev | map(select((.title // "") | ascii_downcase
                | test("never.?evaluat|never.?fired|stale|duplicate|dead.?weight")))) as $dropev
          | ($sig | map(select((.fires // null) == 0))) as $dropsig
          | ($ev | map(select((.title // "") | ascii_downcase
                | test("no notification|no.?handle|dead.*handle|placeholder|@all|@everyone|zero.?subscriber|reaches nobody|pages nobody|tautolog|impossible")))) as $fixev
          | ($sig | map(select(.reaches_human == false))) as $fixsig
          | (if $kd.disposition == "no-equivalent" then
               {disposition: "no-equivalent",
                disposition_reason: ("kind " + ($it.kind // "?") + " has no native equivalent on the target; see the pair catalog for the alternative")}
             elif ($mode == "full") and ($tnames | index($n)) != null then
               {disposition: "already-covered",
                disposition_reason: "an object with this name already exists on the target - migrating it would double-page during the parallel run",
                matched_target: $it.name}
             elif (($dropev | length) > 0) or (($dropsig | length) > 0) then
               {disposition: "drop-candidate",
                disposition_reason: "the audit/fire-history evidence says this object is dead weight - migration is the moment to shed it, pending your confirmation"}
             elif (($fixev | length) > 0) or (($fixsig | length) > 0) then
               {disposition: "fix-then-migrate",
                disposition_reason: "routing/threshold is broken at the source - fix it at (or before) migration rather than importing the defect"}
             else
               {disposition: $kd.disposition, disposition_reason: ("kind default for " + ($it.kind // "monitor"))}
             end)
          ) as $d
        | {kind: ($it.kind // "monitor"),
           name: ($it.name // "(unnamed)"),
           covers: ($it.covers // null),
           enabled: (if $it.enabled == false then false else true end),
           routes_to: ($it.routes_to // null),
           flags: (if $it.enabled == false then ["disabled-at-source"] else [] end),
           equivalence_default: $kd.equivalence_default,
           evidence: ([ $ev[] | {finding_id: .id, severity: (.severity // "info"), title: (.title // "")} ]
                      + [ $sig[] | {signal: true, object_id: .object_id,
                                    fires: (.fires // null), reaches_human: (.reaches_human // null),
                                    source_finding_ids: (.source_finding_ids // [])} ])}
          + $d
      ]'
}

# Assemble + write migration-plan.json. $1=source $2=target $3=date $4=mode
# $5=inventory-json  $6=source-found(0/1)  $7=target-found(0/1)
migration_plan_save() {
  mp_src="$1"; mp_tgt="$2"; mp_date="$3"; mp_mode="$4"; mp_inv="$5"; mp_sfound="$6"; mp_tfound="$7"
  mp_out_dir="$AUDITS_DIR/migration-plans/${mp_src}-to-${mp_tgt}/${mp_date}"
  mkdir -p "$mp_out_dir"
  mp_out="$mp_out_dir/migration-plan.json"
  printf '%s' "$mp_inv" | jq \
    --arg src "$mp_src" --arg tgt "$mp_tgt" --arg date "$mp_date" --arg mode "$mp_mode" \
    --arg gen "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --argjson sfound "$mp_sfound" --argjson tfound "$mp_tfound" '
    . as $inv
    | {
        schema: "scoutflo-migration-plan/v1",
        generated_at: $gen,
        run_date: $date,
        mode: $mode,
        source: {provider: $src, artifacts_found: ($sfound == 1)},
        target: {provider: $tgt, artifacts_found: ($tfound == 1)},
        totals: {
          objects: ($inv | length),
          migrate: ([ $inv[] | select(.disposition == "migrate") ] | length),
          fix_then_migrate: ([ $inv[] | select(.disposition == "fix-then-migrate") ] | length),
          drop_candidates: ([ $inv[] | select(.disposition == "drop-candidate") ] | length),
          already_covered: ([ $inv[] | select(.disposition == "already-covered") ] | length),
          no_equivalent: ([ $inv[] | select(.disposition == "no-equivalent") ] | length)
        },
        inventory: $inv,
        gaps: ([ $inv[] | select(.disposition == "no-equivalent") | .kind ] | unique
               | map({kind: ., status: "no-native-equivalent",
                      alternative: "pending-catalog: fill from references/<source>-to-<target>.md before rendering"})),
        cutover: {
          historical_telemetry: "does-not-transfer",
          note: "config carries over per this plan; historical metrics/logs/traces in the source do NOT transfer - continuity comes from a dual-write/parallel-run window, and the source is sunset only after the audit-parity gate passes",
          parallel_run: "pending-skill: fill per the pair catalog cutover playbook",
          audit_parity_gate: "re-run the source and target audits + correlation; sunset the source only when target coverage parity holds and no true-gap regressions appear"
        },
        method: "deterministic disposition skeleton from artifacts on disk (inventory + findings + optional fatigue-signals); zero provider calls in this library; drop/fix dispositions carry evidence by construction; the skill enriches target shapes + equivalence per the pair catalog and check-migration-plan.sh gates the result"
      }' > "$mp_out"
  echo "$mp_out"
}

# Main entry. $1=source $2=target $3=date (default: today UTC)
migration_plan_run() {
  mp_src="${1:?source provider}"; mp_tgt="${2:?target provider}"; mp_date="${3:-}"
  [ -n "$mp_date" ] || mp_date="$(date -u +%Y-%m-%d)"
  if ! migration_plan_pair_supported "$mp_src" "$mp_tgt"; then
    echo "[migration-plan] unsupported pair: ${mp_src} -> ${mp_tgt} - no pair catalog exists; refusing to improvise a mapping" >&2
    return 2
  fi
  echo "[migration-plan] Building ${mp_src} -> ${mp_tgt} disposition skeleton for ${mp_date}..."
  s_items="$(migration_plan_collect "$mp_src" "$mp_date" inventory)"
  s_findings="$(migration_plan_collect "$mp_src" "$mp_date" findings)"
  t_items="$(migration_plan_collect "$mp_tgt" "$mp_date" inventory)"
  signals="$(migration_plan_load_signals)"
  s_n="$(printf '%s' "$s_items" | jq 'length')"
  t_n="$(printf '%s' "$t_items" | jq 'length')"
  if [ "$s_n" -eq 0 ]; then
    echo "[migration-plan] no ${mp_src} inventory for ${mp_date} - run the ${mp_src} audit first (artifact-first), or pass the right date" >&2
    return 3
  fi
  sfound=1
  if [ "$t_n" -gt 0 ]; then mode="full"; tfound=1; else mode="source-only"; tfound=0; fi
  inv="$(migration_plan_dispositions "$s_items" "$s_findings" "$signals" "$t_items" "$mode")"
  out="$(migration_plan_save "$mp_src" "$mp_tgt" "$mp_date" "$mode" "$inv" "$sfound" "$tfound")"
  # bash-3.2: precompute summary scalars; never nest several $(...) in one string.
  sum_total="$(printf '%s' "$inv" | jq 'length')"
  sum_drop="$(printf '%s' "$inv" | jq '[ .[] | select(.disposition == "drop-candidate") ] | length')"
  sum_fix="$(printf '%s' "$inv" | jq '[ .[] | select(.disposition == "fix-then-migrate") ] | length')"
  echo "[migration-plan] Written $out"
  echo "[migration-plan] mode:$mode objects:$sum_total drop-candidates:$sum_drop fix-then-migrate:$sum_fix"
}
