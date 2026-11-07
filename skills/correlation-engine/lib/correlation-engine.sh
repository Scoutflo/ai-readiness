#!/bin/sh
# correlation-engine.sh
# Builds correlation.json after any audit(s): detects overlaps and cascades and
# applies business context. Works incrementally with any audit combination
# (audit-all, sequential, or a targeted subset).
#
# Reads:  ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<target>/<date>/findings.json
#         and ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/<integration>/<label>/<date>/findings.json
#         (the report-standard layout every audit writes; the two-level form is
#         used by every multi-target labeled list AND by single-block signoz
#         (signoz/<host>/) and kubernetes (kubernetes/<context>/), which always nest)
# Writes: ${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}/correlation.json
#         (single canonical location; cost-analysis and topology-guided-setup read it here)

set -eu

AUDITS_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
CORRELATION_FILE="${AUDITS_DIR}/correlation.json"
# Pre-v0.1.80 migration remnant: business context now lives at ~/.scoutflo/business_context.json
# (the primary source, used below). This ~/.scoutflo/topology.json path is written by no current
# skill; the fallback below only fires when business_context.json is absent, then resolves to a
# non-existent file and returns the hardcoded safe defaults — the intended no-context behavior.
TOPOLOGY_FILE="${TOPOLOGY_FILE:-$HOME/.scoutflo/topology.json}"
CORRELATION_IDENTITY_LIB="${CLAUDE_PLUGIN_ROOT:-.}/skills/correlation-engine/lib"

# Collect all findings for one run date across every target directory.
# Emits a flat JSON array; each finding gains the canonical target from its
# report-directory path. Legacy object-shaped envelope targets remain readable.
# Skips the `all/` combined-report dir, the `cost-analysis/` and `cost/` derived
# dirs, and the `doctor/` dir, whose findings.json files do not follow the
# per-audit schema. Globs BOTH the one-level `<target>/<date>/` and the two-level
# `<integration>/<label>/<date>/` layouts (multi-target labels, and single-block
# signoz/kubernetes which always nest), mirroring audit-all's aggregation.
correlation_collect_findings() {
  date="$1"
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$date" || return 1
  set --
  for f in "$AUDITS_DIR"/*/"$date"/findings.json "$AUDITS_DIR"/*/*/"$date"/findings.json; do
    [ -e "$f" ] || continue
    sf_run_file "$f" || continue
    relative="${f#"$AUDITS_DIR"/}"
    case "${relative%%/*}" in
      all|cost-analysis|cost|doctor) continue ;;
    esac
    set -- "$@" "$f"
  done

  if [ "$#" -eq 0 ]; then
    echo "[]"
    return 0
  fi

  jq -n --arg root "$AUDITS_DIR/" --arg date "$date" --arg suffix "/$date/findings.json" '[ inputs | . as $doc | (input_filename | ltrimstr($root) | rtrimstr($suffix)) as $t | (.findings // [])[] | . + {target: $t, _audit_date:$date, _document_date:$doc.run_date, _document_target:$doc.target, _generated_at:$doc.generated_at, _collection:$doc.collection} ]' "$@"
}

# Only observed, open findings support correlation claims. A blocked finding is
# missing evidence, not a defect; suppressed/resolved findings cannot corroborate
# active trouble. Missing fields retain historical v1 compatibility. Keep the
# unfiltered collection for raw counters and never rewrite source artifacts.
correlation_active_findings() {
  jq '[ .[] | select(
    (.status as $s | [null, "configured", "validated-live"] | index($s)) != null
    and (.lifecycle as $l | [null, "new", "unchanged", "regressed"] | index($l)) != null
  )
    # On-Call object slugs belong to the selected account, not a shared estate
    # identity namespace. Only source-verified service tokens explicitly declared
    # as a subset of affected can support a cross-target join. Legacy On-Call
    # artifacts without that declaration stay readable and raw-counted.
    | if ((.target // "") | split("/")[0]) == "splunk_oncall" then
        . as $f | .affected =
          (if ($f.correlation_affected | type)=="array" then
             [$f.correlation_affected[] | select(type=="string")
              | select(test("\\S") and (test("^route-[0-9]+$")|not))
              | select(. as $token | ($f.affected // []) | index($token))] | unique
           else [] end)
      else . end
  ]'
}

# A shared scope-qualified identity supports a candidate overlap, never proof of
# duplicate notifications. Legacy name-only findings remain in the raw counters.
correlation_find_overlaps() {
  correlation_active_findings | jq -L "$CORRELATION_IDENTITY_LIB" '
    include "service-identity";
    [ .[] | . as $f | si_finding_bindings[] |
      {service:.affected, service_identity, key, evidence, target:$f.target, id:$f.id, title:$f.title, severity:$f.severity} ]
    | group_by(.key)
    | map(select(si_rows_consistent and (map(.target)|unique|length)>1))
    | map({overlap_id:("OVL-" + (.[0].key|@base64)),type:"redundant_monitoring",
        service:.[0].service,service_identity:.[0].service_identity,
        targets:(map(.target)|unique),findings:(map({target,finding_id:.id,title,severity,evidence})|unique),
        recommendation:("Multiple targets report findings against the verified identity for " + .[0].service + "; inspect whether these describe one linked path or independent paths before changing routing. This is not duplicate-event or delivery proof")})'
}

# Datastore-to-alerting dependency candidate, joined by the same verified scope.
# A common display name, dependency keyword or confidence number alone cannot join.
correlation_find_cascades() {
  correlation_active_findings | jq -L "$CORRELATION_IDENTITY_LIB" '
    include "service-identity";
    map(. + {_bindings:si_finding_bindings}) as $all
    | [ $all[] | . as $root
      | select((.area // "")|test("durab|data|database|reliab|backend|dependency";"i"))
      | select((((.affected // [])|join(" ")) + " " + (.title // ""))|test("database|postgres|mysql|rds|cloudsql|mongo|redis|cache|datastore|db";"i"))
      | select(._bindings|length>0)
      | {cascade_id:("CASC-"+([$root.target,$root.id]|tojson|@base64)),root_cause:{finding_id:$root.id,title:$root.title,target:$root.target,
           shared_resources:[$root._bindings[].affected],service_identities:[$root._bindings[].service_identity]},
         effects:[$all[] | select(.id!=$root.id or .target!=$root.target)
          | select((.area // "")|test("alert|routing|deliver|notif|monitor|observab|coverage";"i"))
          | . as $eff | select(any($eff._bindings[]; . as $eb | any($root._bindings[];si_compatible(.service_identity;$eb.service_identity))))
          | {finding_id:.id,title,target,condition:"shares a verified resource identity with the datastore finding; verify its signal survives if that datastore degrades"}]}
      | select(.effects|length>0)]'
}

# Collect ACTIVE coverage (positive monitors/alerts), not gaps, from every target's
# inventory.json (scoutflo-inventory/v1). This is what lets the engine tell "provider A
# reports no alarm on X, but provider B actively monitors X" — the cross-tool coverage join.
# Same dual-glob + skip set as the findings collector. Each item is tagged with its provider
# (first path segment of .target, e.g. "azure" from "azure/prod-core").
correlation_collect_coverage() {
  date="$1"
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$date" || return 1
  set --
  for f in "$AUDITS_DIR"/*/"$date"/inventory.json "$AUDITS_DIR"/*/*/"$date"/inventory.json; do
    [ -e "$f" ] || continue
    sf_run_file "$f" || continue
    relative="${f#"$AUDITS_DIR"/}"
    case "${relative%%/*}" in
      all|cost-analysis|cost|doctor) continue ;;
    esac
    set -- "$@" "$f"
  done
  if [ "$#" -eq 0 ]; then
    echo "[]"
    return 0
  fi
  jq -n -L "$CORRELATION_IDENTITY_LIB" --arg root "$AUDITS_DIR/" --arg date "$date" --arg suffix "/$date/inventory.json" '
    include "service-identity";
    [inputs | . as $doc | (input_filename|ltrimstr($root)|rtrimstr($suffix)) as $t
     | (.items // [])[] | . + {provider:($t|split("/")[0]),target:$t,
         _audit_date:$date,_document_date:$doc.generated_at[0:10],_document_target:$doc.target,_generated_at:$doc.generated_at,_collection:$doc.collection}
     | . + {_binding:si_inventory_binding}
     | .enabled=(if (.enabled|type)=="boolean" then .enabled else null end)]' "$@"
}

# Absence is meaningful only inside the explicitly selected, fully collected set.
# An empty items list can be complete; absent files, subset reads and denied reads cannot.
correlation_assess_inputs() {
  date="$1"
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$date" || return 1
  manifest="$AUDITS_DIR/coverage-assessment.json"
  if [ ! -f "$manifest" ] || ! jq -e --arg d "$date" '
    .schema=="scoutflo-coverage-assessment/v1" and .audit_date==$d
    and (.expected_targets|type)=="array" and (.expected_targets|length)>0
    and (.expected_targets|all(type=="string" and test("^[a-z0-9_-]+(/[A-Za-z0-9_.-]+)?$") and (split("/")|all(.!="." and .!=".."))))
    and ((.expected_targets|unique|length)==(.expected_targets|length))' "$manifest" >/dev/null 2>&1; then
    printf '%s\n' '{"status":"unknown","absence_assessable":false,"expected_targets":[],"targets":[],"reason":"No valid current selected-target assessment manifest; absence is unassessed"}'
    return
  fi
  if [ "$SF_RUN_MODE" = selected ] && ! jq -e --argjson run "$SF_RUN_DOCUMENT" '(.expected_targets|sort)==($run.targets|sort)' "$manifest" >/dev/null; then
    printf '%s\n' '{"status":"unknown","absence_assessable":false,"expected_targets":[],"targets":[],"reason":"Coverage denominator does not match the actual selected run queue"}'
    return
  fi
  assessment_rows='[]'
  for assessment_target in $(jq -r '.expected_targets[]' "$manifest"); do
    assessment_path="$AUDITS_DIR/$assessment_target/$date/inventory.json"
    if [ "$SF_RUN_MODE" = selected ] && ! sf_run_file "$assessment_path"; then
      assessment_row='{"status":"not-completed-this-run","complete":false}'
    elif [ -f "$assessment_path" ]; then
      assessment_row=$(jq -L "$CORRELATION_IDENTITY_LIB" --arg t "$assessment_target" --arg d "$date" '
        include "service-identity";
        {target:$t,status:(.collection.status // "unknown"),scope:(.collection.scope // "unknown"),observed_at:.collection.observed_at,
         complete:(.target==$t and .schema=="scoutflo-inventory/v1" and (.generated_at|si_utc) and .generated_at[0:10]==$d and .collection.observed_at<=.generated_at and (.items|type)=="array" and (.collection|si_valid_collection($d)) and .collection.status=="complete" and .collection.scope=="target")}' "$assessment_path" 2>/dev/null) || assessment_row='{"status":"unreadable","complete":false}'
    else assessment_row='{"status":"missing","complete":false}'; fi
    assessment_rows=$(printf '%s\n' "$assessment_rows" | jq --arg t "$assessment_target" --argjson row "$assessment_row" '. + [$row + {target:$t}]')
  done
  printf '%s\n' "$assessment_rows" | jq '{expected_targets:map(.target),targets:.,absence_assessable:all(.complete),status:(if all(.complete) then "complete" else "incomplete" end),reason:"Absence conclusions apply only within the declared assessed targets"}'
}

# Advisory only: literal activation, current bound identity, real route and
# another provider are all required. No monitor can cover a missing responder.
correlation_find_coverage() {
  cov="$1"
  assessment="${CORRELATION_ASSESSMENT:-}"
  [ -n "$assessment" ] || assessment='{}'
  correlation_active_findings | jq -L "$CORRELATION_IDENTITY_LIB" --argjson cov "$cov" --argjson assessment "$assessment" '
    include "service-identity";
    def route_value: if (.routes_to|type)=="string" then .routes_to|ascii_downcase|gsub("^\\s+|\\s+$";"") else null end;
    def route_unknown: route_value as $r | $r==null or (["unknown","unverified","unavailable","redacted","[redacted]","masked"]|index($r))!=null;
    def routed: (route_unknown|not) and (route_value as $r | $r!="" and $r!="none" and $r!="-");
    [ .[] | . as $f | ($f.target|split("/")[0]) as $prov
      | select($prov!="splunk_oncall")
      | select((($f.coverage_gap.signal|type)=="string" and ($f.coverage_gap.signal|test("\\S")))
          or (($f.scoring_scope // "readiness")=="readiness" and (($f.area // "")|test("coverage|alert|monitor|metric";"i"))
          and (($f.title // "")|test("no |missing|lacks|absent|not configured|no metric|without";"i"))))
      | ($f|si_finding_bindings) as $bindings
      | ($f.affected // [])[] as $resource | select($resource|si_text)
      | [$bindings[]|select(.affected==$resource)] as $bound
      | [$cov[] | select(.provider!=$prov and ((.kind // "")|test("^(monitor|alarm|alert|alert_rule|alert_policy|log_alert|activity_log_alert|uptime_check)$")))] as $monitors
      | [$monitors[] | . as $item | select(.enabled==true and routed and ._binding!=null)
          | select(any($bound[];si_compatible(.service_identity;$item._binding.service_identity)))] as $matches
      | any($monitors[]; . as $item | ._binding!=null and any($bound[];
          .key==$item._binding.key and (si_compatible(.service_identity;$item._binding.service_identity)|not))) as $scope_conflict
      | {finding_id:$f.id,target:$f.target,resource:$resource,covered_by:[]} +
        (if $scope_conflict then
          {classification:"unmappable",reason:"conflicting-service-qualifiers",recommendation:"Current observations disagree on the environment or region of this identity; reconcile the scope before concluding coverage or absence"}
         elif ($matches|length)>0 then
          {classification:"covered-elsewhere",covered_by:[$matches[]|{provider,target,inventory_name:.name,routes_to,match:"exact",service_identity:._binding.service_identity,evidence:._binding.evidence}],
           recommendation:("single-tool-dependency: a current, enabled, routed monitor shares the verified identity for " + $resource + "; confirm it covers " + ($f.coverage_gap.signal // "the missing signal") + " before de-prioritizing. Configuration does not prove delivery")}
         elif ($bound|length)==0 then
          {classification:"unmappable",reason:"missing-current-service-identity",recommendation:"No current scope-qualified binding for this resource; collect source identity evidence before joining or concluding absence"}
         elif any($monitors[]; .enabled==null or (.enabled==true and (._binding==null or route_unknown))) then
          {classification:"unmappable",reason:"unknown-activation-or-identity",recommendation:"A possible monitor has unknown activation or unverified identity; verify it before concluding coverage or absence"}
         elif $assessment.absence_assessable==true and (($assessment.expected_targets // [])|index($f.target))!=null then
          {classification:"true-gap",reason:"no-observed-coverage-within-assessed-targets",recommendation:"No active routed cross-tool coverage observed within the declared assessed targets; verify the missing signal before changing priority"}
         else
          {classification:"unmappable",reason:"incomplete-assessed-inputs",recommendation:"No matching coverage observed in supplied inputs; selected-target collection is incomplete or unknown, so absence remains unassessed"}
         end)]'
}

# Load business context (with safe defaults).
# Precedence: business_context.json (derived from the SSOT) is authoritative;
# legacy topology.json:.business_context is the migration fallback.
correlation_load_context() {
  BC_JSON="${BC_JSON:-$HOME/.scoutflo/business_context.json}"
  if [ -f "$BC_JSON" ]; then
    jq '{
      environment: (.environment // "production"),
      cost_sensitivity: (.cost_sensitivity // "medium"),
      critical_dependencies: (.critical_dependencies // [])
    }' "$BC_JSON"
  elif [ -f "$TOPOLOGY_FILE" ]; then
    jq '.business_context // {
      environment: "production",
      cost_sensitivity: "medium",
      critical_dependencies: []
    }' "$TOPOLOGY_FILE"
  else
    jq -n '{
      environment: "production",
      cost_sensitivity: "medium",
      critical_dependencies: []
    }'
  fi
}

# Apply business context: annotate findings; never change the audit-owned
# severity field, only add advisory annotations. Reads findings on stdin.
correlation_apply_context() {
  context=$(correlation_load_context)
  environment=$(printf '%s\n' "$context" | jq -r '.environment // "production"')
  critical_deps=$(printf '%s\n' "$context" | jq '.critical_dependencies // []')

  jq \
    --arg env "$environment" \
    --argjson crit_deps "$critical_deps" \
    '
    map(
      . as $f |
      if ($env == "staging" and (.severity == "low" or .severity == "medium")) then
        . + {context_note: "staging environment: gap may be intentional"}
      elif ((($f.affected // []) | map(. as $a | $crit_deps | index($a)) | any(. != null))) then
        . + {context_note: "touches a business-critical dependency"}
      else
        .
      end
    )
  '
}

# Write correlation.json.
correlation_save() {
  audit_date="$1"
  overlaps="$2"
  cascades="$3"
  findings="$4"
  coverage="${5:-[]}"
  assessment="${CORRELATION_ASSESSMENT:-}"
  [ -n "$assessment" ] || assessment='{}'
  mkdir -p "$AUDITS_DIR"

  total_raw=$(printf '%s\n' "$findings" | jq 'length')
  total_overlaps=$(printf '%s\n' "$overlaps" | jq 'length')
  total_cascades=$(printf '%s\n' "$cascades" | jq 'length')
  cov_covered=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="covered-elsewhere")] | length')
  cov_true_gap=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="true-gap")] | length')
  cov_unmappable=$(printf '%s\n' "$coverage" | jq '[.[] | select(.classification=="unmappable")] | length')
  # Candidate duplicates are counted per DISTINCT finding, never per
  # (finding, service) row. Overlap groups are per-service, so one finding
  # that names many affected services sits in many groups; the old
  # sum-of-(group-size - 1) counted such a finding once per group and drove
  # total_findings_deduplicated negative on real inputs (raw 32, "dupes" 38,
  # total -6). Instead: within each group each finding appears once, one
  # representative per group is kept (the first in jq's stable unique order),
  # and the union across groups counts every candidate duplicate at most once.
  # This guarantees 0 <= dupes < total_raw, so the dedup total reconciles
  # (dedup = raw - dupes) and can never go negative.
  dupes=$(printf '%s\n' "$overlaps" | jq '
    [ .[] | .findings
      | map({target, finding_id}) | unique   # one row per finding per group
      | .[1:] | .[]                          # all but the kept representative
    ]
    | unique | length                        # each finding at most once overall
  ')
  total_dedup=$((total_raw - dupes))

  jq -n \
    --arg version "2.0" \
    --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    --arg audit_date "$audit_date" \
    --argjson run_selection "${CORRELATION_RUN_SELECTION:-null}" \
    --argjson total_raw "$total_raw" \
    --argjson total_overlaps "$total_overlaps" \
    --argjson total_cascades "$total_cascades" \
    --argjson total_dedup "$total_dedup" \
    --argjson overlaps "$overlaps" \
    --argjson cascades "$cascades" \
    --argjson coverage "$coverage" \
    --argjson assessment "$assessment" \
    --argjson cov_covered "$cov_covered" \
    --argjson cov_true_gap "$cov_true_gap" \
    --argjson cov_unmappable "$cov_unmappable" \
    '{
      version: $version,
      generated_at: $generated_at,
      audit_date: $audit_date,
      total_findings_raw: $total_raw,
      total_findings_deduplicated: $total_dedup,
      total_overlaps_detected: $total_overlaps,
      total_cascades_detected: $total_cascades,
      total_coverage_covered_elsewhere: $cov_covered,
      total_coverage_true_gap: $cov_true_gap,
      total_coverage_unmappable: $cov_unmappable,
      overlaps: $overlaps,
      cascades: $cascades,
      coverage: $coverage,
      assessment: $assessment,
      method: "current scope-qualified service identity joins for candidate overlaps, dependency cascades and cross-tool coverage; absence only within complete declared assessed targets; advisory only, never mutates source scores or proves duplicate delivery"
    } | if $run_selection.mode=="selected" then . + {run_selection:$run_selection} else . end' > "$CORRELATION_FILE.tmp.$$" || { rm -f "$CORRELATION_FILE.tmp.$$"; return 1; }
  if [ -n "${CORRELATION_RUN_SELECTION:-}" ]; then
    sf_run_prepare "$AUDITS_DIR" "$audit_date" || { rm -f "$CORRELATION_FILE.tmp.$$"; return 1; }
    jq -en --argjson before "$CORRELATION_RUN_SELECTION" --argjson after "$SF_RUN_DOCUMENT" '$before==$after' >/dev/null || { rm -f "$CORRELATION_FILE.tmp.$$"; echo '[correlation] selected run changed during analysis; rerun' >&2; return 1; }
  fi
  mv "$CORRELATION_FILE.tmp.$$" "$CORRELATION_FILE" || return 1

  echo "[correlation] Written $CORRELATION_FILE"
  echo "[correlation] Raw findings: $total_raw | Deduplicated: $total_dedup | Overlaps: $total_overlaps | Cascades: $total_cascades | Coverage: covered-elsewhere=$cov_covered true-gap=$cov_true_gap unmappable=$cov_unmappable"
}

# Main entry point
correlation_run() {
  audit_date="${1:-.}"
  [ "$audit_date" = "." ] && audit_date="$(date -u +%Y-%m-%d)"

  echo "[correlation] Starting analysis for $audit_date..."
  . "${CLAUDE_PLUGIN_ROOT:-.}/report-standard/run-selection.sh"
  sf_run_prepare "$AUDITS_DIR" "$audit_date" || return 1
  CORRELATION_RUN_SELECTION=$SF_RUN_DOCUMENT
  # A failed current read must not leave an earlier derived result looking current.
  rm -f "$CORRELATION_FILE" || return 1

  CORRELATION_ASSESSMENT=$(correlation_assess_inputs "$audit_date") || return 1
  findings=$(correlation_collect_findings "$audit_date") || return 1

  if [ "$(printf '%s\n' "$findings" | jq 'length')" -eq 0 ]; then
    # The root file is reused across dates and same-day reruns. Replace stale
    # groups with this run's explicit empty result before consumers read it.
    correlation_save "$audit_date" '[]' '[]' '[]' '[]' || return 1
    echo "[correlation] No findings to correlate for $audit_date; empty result recorded"
    return 0
  fi

  findings=$(printf '%s\n' "$findings" | correlation_apply_context)
  overlaps=$(printf '%s\n' "$findings" | correlation_find_overlaps)
  cascades=$(printf '%s\n' "$findings" | correlation_find_cascades)
  coverage_items=$(correlation_collect_coverage "$audit_date")
  coverage=$(printf '%s\n' "$findings" | correlation_find_coverage "$coverage_items")

  correlation_save "$audit_date" "$overlaps" "$cascades" "$findings" "$coverage" || return 1

  echo "[correlation] Done. Ready for cost-analysis and review by the owning setup skill."
}

# Read helpers for integration consumers. Missing optional output is distinct
# from a malformed existing artifact; never disguise failed reads as no findings.
correlation_read_array() {
  [ -e "$CORRELATION_FILE" ] || { printf '[]\n'; return 0; }
  if ! jq -e -s --arg key "$1" 'length==1 and (.[0] | type=="object" and (.[$key]==null or (.[$key]|type)=="array"))' "$CORRELATION_FILE" >/dev/null 2>&1; then
    echo '[correlation] cannot read current correlation artifact; rerun correlation before consuming it' >&2
    return 1
  fi
  jq --arg key "$1" '.[$key] // []' "$CORRELATION_FILE"
}

correlation_get_overlaps() {
  correlation_read_array overlaps
}

correlation_get_cascades() {
  correlation_read_array cascades
}

correlation_get_coverage() {
  correlation_read_array coverage
}

correlation_find_related() {
  finding_id="$1"
  related_overlaps="$(correlation_read_array overlaps)" || return 1
  printf '%s\n' "$related_overlaps" | jq --arg id "$finding_id" \
    '[.[] | select(any(.findings[]?; .finding_id == $id))] | first // {}'
}
