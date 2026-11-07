#!/bin/sh
# Local-only RCA selection. Never mutates an audit or trusts a cached correlation.
set -eu
: "${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}"
: "${RCA_TARGET:?Set the canonical audit target, including its label}"
: "${RCA_RESOURCE:?Set an exact affected resource or finding ID}"
: "${RCA_RUN_DATE:?Set the selected report run date}"
jq -en --arg t "$RCA_TARGET" --arg r "$RCA_RESOURCE" --arg d "$RCA_RUN_DATE" '
  ($t|test("^[a-z0-9_-]+(/[A-Za-z0-9_.-]+)?$") and (split("/")|all(.!="." and .!="..")))
  and ($r|test("\\S") and (test("[[:cntrl:]]")|not))
  and (try ($d|strptime("%Y-%m-%d")|mktime|.<=now and strftime("%Y-%m-%d")==$d) catch false)' >/dev/null || { echo 'Invalid RCA target, exact resource or run date' >&2; exit 2; }
. "$CLAUDE_PLUGIN_ROOT/skills/correlation-engine/lib/correlation-engine.sh"
mode=${1:-reports}
if [ "$mode" = topology ]; then
  : "${RCA_TOPOLOGY:?Set the selected local estate-topology.json path}"
  jq -e --arg t "$RCA_TARGET" --arg r "$RCA_RESOURCE" --arg d "$RCA_RUN_DATE" --arg kind "${RCA_ENTITY_TYPE:-}" '
    select(.schema=="scoutflo-estate-topology/v1" and .audit_date==$d)
    | . as $map | [.entities[] | select(.target==$t and .name==$r and ($kind=="" or .entity_type==$kind))] as $seeds
    | if ($seeds|length)!=1 then error("Choose one exact target/resource/entity type in the selected map") else . end
    | [$map.relationships[] | select(.from_id==$seeds[0].id or .to_id==$seeds[0].id)
      | . as $edge
      | {from:([$map.entities[]|select(.id==$edge.from_id)][0]),to:([$map.entities[]|select(.id==$edge.to_id)][0]),relation,evidence,source,
         role:(if (.relation|test("^(DEPLOYED_AS|PART_OF|ROUTES_TO)$")) then "identity"
           elif (.relation|test("^(CALLS|ServiceEntry|STORES_DATA_IN|CACHES_IN|PUBLISHES_TO|SUBSCRIBES_TO|CONSUMES|USES|CONFIGURED_BY|EXPOSED_VIA)$")) then
             if .from_id==$seeds[0].id then "suspect(up)" else "blast(down)" end
           elif (.relation|test("^(MONITORED_BY|SENDS_)")) then "observation" else "other" end)}] as $edges
    | {target:$t,resource:$r,run_date:$d,generated_at,source_maps,completeness,edges:$edges,
       limitation:"Saved topology reference only; revalidate source hashes and current runtime before causal claims. Missing edges do not prove absent coverage or delivery."}' "$RCA_TOPOLOGY"
  exit
fi
findings=$(correlation_collect_findings "$RCA_RUN_DATE")
selected=$(printf '%s' "$findings" | jq --arg t "$RCA_TARGET" --arg r "$RCA_RESOURCE" --arg d "$RCA_RUN_DATE" '
  [.[]|select(.target==$t and ._document_target==$t and (._document_date==$d or ._document_date==null))
   | select(.id==$r or ((.affected // [])|index($r))!=null)]')
case "$mode" in
  reports)
    printf '%s' "$selected" | jq --arg d "$RCA_RUN_DATE" '{run_date:$d,mode:"report-reference",findings:[.[]|{target,id,severity,area,title,affected,status,lifecycle,run_date:(._document_date // $d),date_source:(if ._document_date==null then "legacy-directory" else "document" end),generated_at:._generated_at}],limitation:"Historical report evidence is reference, not current runtime proof"}' ;;
  correlation|coverage)
    # Recompute from the retained generation; never borrow a stale global file.
    CORRELATION_ASSESSMENT=$(correlation_assess_inputs "$RCA_RUN_DATE")
    if [ "$mode" = coverage ]; then
      cov=$(correlation_collect_coverage "$RCA_RUN_DATE")
      result=$(printf '%s' "$findings" | correlation_find_coverage "$cov")
      printf '%s' "$result" | jq --arg t "$RCA_TARGET" --arg r "$RCA_RESOURCE" --arg d "$RCA_RUN_DATE" --argjson selected "$selected" --argjson assessment "$CORRELATION_ASSESSMENT" '
        {run_date:$d,target:$t,assessment:$assessment,coverage:[.[]|. as $row|select(.target==$t and any($selected[];.id==$row.finding_id) and (.resource==$r or any($selected[];.id==$r)))],limitation:"Advisory configuration evidence; no score mutation or proof of delivery"}'
    else
      overlaps=$(printf '%s' "$findings" | correlation_find_overlaps)
      cascades=$(printf '%s' "$findings" | correlation_find_cascades)
      printf '%s' "$selected" | jq -L "$CORRELATION_IDENTITY_LIB" --arg t "$RCA_TARGET" --arg r "$RCA_RESOURCE" --arg d "$RCA_RUN_DATE" --argjson overlaps "$overlaps" --argjson cascades "$cascades" '
        include "service-identity";
        . as $selected | [ .[]|. as $f|si_finding_bindings[]|select(.affected==$r or $f.id==$r)] as $bindings
        | {target:$t,run_date:$d,
           overlaps:[$overlaps[]|. as $o|select(any($o.findings[];.target==$t and (.finding_id as $id|any($selected[];.id==$id))))
             | select(any($bindings[];si_compatible(.service_identity;$o.service_identity)))],
           cascades:[$cascades[]|. as $c|select(($c.root_cause.target==$t and any($selected[];.id==$c.root_cause.finding_id)) or any($c.effects[];. as $e|.target==$t and any($selected[];.id==$e.finding_id)))
             | select(any($c.root_cause.service_identities[];. as $identity|any($bindings[];si_compatible(.service_identity;$identity))))],
           limitation:"Current-generation qualified candidates within the selected report date; verify causes live and assess source independence"}'
    fi ;;
  *) echo 'Use reports, topology, correlation or coverage' >&2; exit 2 ;;
esac
