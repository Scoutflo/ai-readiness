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
  # Preserve the artifact target while flattening, so identical names in two
  # labeled source accounts cannot borrow each others findings or history.
  jq -n --arg root "$AUDITS_DIR/" --arg suffix "/$mp_date/$mp_what.json" --arg what "$mp_what" '
    [ inputs | (input_filename | ltrimstr($root) | rtrimstr($suffix)) as $target
      | (if $what == "inventory" then (.items // []) else (.findings // []) end)[]
      | . + {_audit_target: $target} ]' "$@"
}

migration_plan_load_signals() {
  if [ -e "$SIGNALS_FILE" ]; then
    if ! jq -e -s 'length == 1 and (.[0] | type == "object" and .schema == "scoutflo-fatigue-signals/v1" and (.signals | type == "array") and all(.signals[]; type == "object"))' "$SIGNALS_FILE" >/dev/null 2>&1; then
      echo '[migration-plan] optional fatigue signals are unreadable or malformed; repair or explicitly remove that input before rebuilding' >&2
      return 4
    fi
    mp_signal_validator="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/check-fatigue-signals.sh"
    if [ ! -f "$mp_signal_validator" ]; then
      echo '[migration-plan] signals validator unavailable; set CLAUDE_PLUGIN_ROOT to the installed plugin' >&2
      return 4
    fi
    if ! sh "$mp_signal_validator" "$SIGNALS_FILE" "$AUDITS_DIR" "${1:-${RUN_DATE:-$(date -u +%F)}}" >&2; then
      echo '[migration-plan] optional measured evidence failed validation; existing plan is preserved' >&2
      return 4
    fi
    # The shared validator already binds coverage to provider and target.
    # A second provider-only filter would discard other targets' valid evidence.
    jq '.signals' "$SIGNALS_FILE"
  else
    echo "[]"
  fi
}

# The deterministic disposition join. Args are JSON strings:
# $1=source items  $2=source findings  $3=signals  $4=target items  $5=mode(full|source-only)
# Precedence per object: kind no-equivalent > already-covered > drop-candidate
# > fix-then-migrate > kind default. drop/fix only WITH evidence, by construction.
migration_plan_dispositions() {
  mp_items="$1"; mp_findings="$2"; mp_signals="$3"; mp_titems="$4"; mp_mode="$5"; mp_source="${6:-datadog}"
  printf '%s' "$mp_items" | jq \
    --argjson findings "$mp_findings" \
    --argjson signals "$mp_signals" \
    --argjson titems "$mp_titems" \
    --argjson kindmap "$(migration_plan_kind_map)" \
    --arg source "$mp_source" --arg mode "$mp_mode" '
    def norm: (. // "") | ascii_downcase | gsub("^\\s+|\\s+$"; "");
    [ .[]
        | . as $it
        | ($it.name // "") as $n
        | ($it._audit_target // $source) as $source_target
        | ([ $findings[] | select((._audit_target // $source)==$source_target)
             | select(((.status as $s | [null, "configured", "validated-live"] | index($s)) != null
           and (.lifecycle as $l | [null, "new", "unchanged", "regressed"] | index($l)) != null))
             | select((.affected // []) | index($n)) ]) as $ev
        | ([ $signals[] | select(.provider==$source and (.target // .provider)==$source_target
             and .object_kind==($it.kind // "monitor") and ((.object_id // "") == $n)) ]) as $sig
        # Only the cataloged monitor -> alert_rule pair can establish an alert
        # coverage match here. Detailed query parity remains a cutover gate.
        | ([ $titems[] | select($it.kind=="monitor" and .kind=="alert_rule")
             | select(.name==$n and .enabled==true)
             | select(((.covers | norm) | IN("","none","null","-","unknown") | not) and .covers==$it.covers)
             | select((.routes_to | type)=="string" and ((.routes_to | norm) | IN("","none","null","-","unknown") | not)) ]) as $matches
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
             elif ($mode == "full") and ($matches | length)==1 then
               {disposition: "already-covered",
                disposition_reason: "one enabled, routed target alert matches the source name, cataloged kind and exact coverage; verify detailed query equivalence before cutover",
                matched_target: $matches[0].name,
                matched_target_identity: {target: ($matches[0]._audit_target // "signoz"), kind: $matches[0].kind, name: $matches[0].name}}
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
        | {source_target: $source_target, kind: ($it.kind // "monitor"),
           name: ($it.name // "(unnamed)"),
           covers: ($it.covers // null),
           enabled: (if $it.enabled == false then false else true end),
           routes_to: ($it.routes_to // null),
           flags: (if $it.enabled == false then ["disabled-at-source"] else [] end),
           equivalence_default: $kd.equivalence_default,
           evidence: ([ $ev[] | {target: $source_target, finding_id: .id, severity: (.severity // "info"), title: (.title // "")} ]
                      + [ $sig[] | {signal: true, provider: .provider, target: $source_target, object_kind: .object_kind, object_id: .object_id,
                                    fires: (.fires // null), reaches_human: (if has("reaches_human") then .reaches_human else null end),
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
      }' > "$mp_out.tmp" && mv "$mp_out.tmp" "$mp_out"
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
  s_items="$(migration_plan_collect "$mp_src" "$mp_date" inventory)" || return 4
  s_findings="$(migration_plan_collect "$mp_src" "$mp_date" findings)" || return 4
  t_items="$(migration_plan_collect "$mp_tgt" "$mp_date" inventory)" || return 4
  # Snapshot optional evidence once so validation, consumption and the resume
  # basis all refer to the same document, including its measurement window.
  signal_document=null
  if [ -e "$SIGNALS_FILE" ]; then
    signal_document="$(jq -c . "$SIGNALS_FILE" 2>/dev/null)" || {
      echo '[migration-plan] optional fatigue signals are unreadable or malformed; repair or explicitly remove that input before rebuilding' >&2
      return 4
    }
    signal_snapshot="$(mktemp)" || return 4
    if ! printf '%s\n' "$signal_document" > "$signal_snapshot"; then rm -f "$signal_snapshot"; return 4; fi
    if signals="$(SIGNALS_FILE="$signal_snapshot" migration_plan_load_signals "$mp_date")"; then
      rm -f "$signal_snapshot"
    else
      rm -f "$signal_snapshot"
      return 4
    fi
  else
    signals='[]'
  fi
  s_n="$(printf '%s' "$s_items" | jq 'length')"
  t_n="$(printf '%s' "$t_items" | jq 'length')"
  if [ "$s_n" -eq 0 ]; then
    echo "[migration-plan] no ${mp_src} inventory for ${mp_date} - run the ${mp_src} audit first (artifact-first), or pass the right date" >&2
    return 3
  fi
  sfound=1
  if [ "$t_n" -gt 0 ]; then mode="full"; tfound=1; else mode="source-only"; tfound=0; fi
  # The plan is the editable worklist. Never regenerate over completed detail
  # enrichment. Compare the complete artifact inputs, including target evidence;
  # a changed or legacy unbound input needs an explicit new run, not a blind merge.
  basis="$(jq -n --argjson source "$s_items" --argjson findings "$s_findings" --argjson target "$t_items" --argjson signals "$signals" --argjson signal_document "$signal_document" '{source:$source,findings:$findings,target:$target,signals:$signals,signals_document:$signal_document}')"
  plan_dir="$AUDITS_DIR/migration-plans/${mp_src}-to-${mp_tgt}/${mp_date}"
  if [ -e "$plan_dir/migration-plan.json" ]; then
    if [ -f "$plan_dir/input-basis.json" ] && jq -e --argjson current "$basis" '. == $current' "$plan_dir/input-basis.json" >/dev/null 2>&1; then
      echo "[migration-plan] unchanged inputs; preserved existing worklist at $plan_dir/migration-plan.json; resume its unfinished enrichment"
      return 0
    fi
    echo '[migration-plan] existing worklist preserved: inputs changed or its legacy input basis is absent. Review the existing plan and use a new dated audit run for a rebuild.' >&2
    return 4
  fi
  inv="$(migration_plan_dispositions "$s_items" "$s_findings" "$signals" "$t_items" "$mode" "$mp_src")"
  out="$(migration_plan_save "$mp_src" "$mp_tgt" "$mp_date" "$mode" "$inv" "$sfound" "$tfound")"
  printf '%s\n' "$basis" > "$plan_dir/input-basis.json.tmp" && mv "$plan_dir/input-basis.json.tmp" "$plan_dir/input-basis.json"
  # bash-3.2: precompute summary scalars; never nest several $(...) in one string.
  sum_total="$(printf '%s' "$inv" | jq 'length')"
  sum_drop="$(printf '%s' "$inv" | jq '[ .[] | select(.disposition == "drop-candidate") ] | length')"
  sum_fix="$(printf '%s' "$inv" | jq '[ .[] | select(.disposition == "fix-then-migrate") ] | length')"
  echo "[migration-plan] Written $out"
  echo "[migration-plan] mode:$mode objects:$sum_total drop-candidates:$sum_drop fix-then-migrate:$sum_fix"
}
