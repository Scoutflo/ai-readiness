#!/bin/sh
# Additive evidence fields: old artifacts stay readable; malformed new claims fail.
set -eu
FILE="${1:?usage: check-correlation-evidence.sh artifact.json}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
jq -e -L "$ROOT/skills/correlation-engine/lib" '
 include "service-identity";
 def collection_shape($date):
   type=="object" and (.status=="complete" or .status=="partial" or .status=="blocked")
   and (.scope=="target" or .scope=="subset") and (.observed_at|si_utc)
   and .observed_at[0:10]==$date
   and (if .status=="complete" then true else (.reason|si_text) end);
 def evidence_shape($doc):
   type=="object" and .target==$doc.target and (.observed_at|si_utc)
   and .observed_at==$doc.collection.observed_at and (.ref|si_text)
   and (.ref|test("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*(#[A-Za-z0-9_.:-]+)?$"))
   and (.ref|split("/")|all(.!=".." and .!="."));
 . as $doc | (.run_date // .generated_at[0:10]) as $date
 | (if has("collection") then .collection|collection_shape($date) else true end)
 and (if $doc.schema=="scoutflo-inventory/v1" then
   all($doc.items[]?; . as $item |
     if has("service_identity") or has("identity_evidence") then
       ($doc|has("collection")) and (.service_identity|si_valid_identity)
       and (.identity_evidence|evidence_shape($doc))
     else true end)
 else all($doc.findings[]?; . as $finding |
   if has("correlation_bindings") then
     (.correlation_bindings|type=="array") and all(.correlation_bindings[];
       (.affected|si_text) and (.affected as $a | $finding.affected | index($a)!=null)
       and (.service_identity|si_valid_identity) and (.evidence|evidence_shape($doc)))
   else true end) end)
' "$FILE" >/dev/null 2>&1 || { echo 'EVIDENCE-FAIL: invalid collection, qualified identity or generation evidence' >&2; exit 1; }
echo 'EVIDENCE-OK'
