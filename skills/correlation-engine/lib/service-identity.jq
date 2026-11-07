# Shared, local-only identity rules. Collection generation is part of the proof;
# a friendly name or a provider target label is never a cross-target identity.
def si_text: type=="string" and test("\\S") and (test("[[:cntrl:]]")|not);
def si_utc:
  type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
  and (try (. as $s | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | . <= now and (strftime("%Y-%m-%dT%H:%M:%SZ")==$s)) catch false);
def si_valid_identity:
  type=="object"
  and (if .kind=="kubernetes" then
    ([.cluster_id,.namespace,.service_name] | all(si_text))
    elif .kind=="provider-resource" then
    ([.provider,.account_scope,.resource_id] | all(si_text)) else false end)
  and ([.region,.environment] | all(.==null or si_text));
def si_key:
  if .kind=="kubernetes" then [.kind,.cluster_id,.namespace,.service_name]
  else [.kind,.provider,.account_scope,.resource_id] end | tojson;
def si_compatible($a;$b):
  ($a|si_valid_identity) and ($b|si_valid_identity) and (($a|si_key)==($b|si_key))
  and all(["region","environment"][]; . as $q | $a[$q]==null or $b[$q]==null or $a[$q]==$b[$q]);
def si_valid_collection($audit_date):
  type=="object" and (.status=="complete" or .status=="partial")
  and (.scope=="target" or .scope=="subset")
  and (.observed_at|si_utc) and (.observed_at[0:10]==$audit_date)
  and (if .status=="partial" then (.reason|si_text) else true end);
def si_valid_evidence($target;$collection;$audit_date):
  type=="object" and (.ref|si_text) and (.ref|test("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*(#[A-Za-z0-9_.:-]+)?$") and (split("/")|all(.!=".." and .!="."))) and .target==$target
  and ($collection|si_valid_collection($audit_date)) and .observed_at==$collection.observed_at;
# Conflicting supplemental scope blocks a group rather than merging its members.
def si_rows_consistent:
  . as $rows | all(["region","environment"][]; . as $q | ([$rows[].service_identity[$q] | select(.!=null)]|unique|length)<=1);

def si_current_document:
  ._document_date==._audit_date and ._document_target==.target and (._generated_at|si_utc)
  and ._generated_at[0:10]==._audit_date and ._collection.observed_at<=._generated_at;
def si_finding_bindings:
  . as $f | if (si_current_document|not) then [] else
  [($f.correlation_bindings // [])[]? | select(type=="object")
   | select(.affected as $a | ($f.affected // []) | index($a))
   | select(if (($f.target // "")|split("/")[0])=="splunk_oncall" then
       .affected as $a | (($f.correlation_affected // []) | index($a))!=null and ($a|test("^route-[0-9]+$")|not)
     else true end)
   | select(.service_identity|si_valid_identity)
   | select(.evidence|si_valid_evidence($f.target;$f._collection;$f._audit_date))
   | . + {key:(.service_identity|si_key)}] | group_by(.affected) | map(select((map(.key)|unique|length)==1 and si_rows_consistent) | .[0]) end;
def si_inventory_binding:
  . as $i | if ($i|si_current_document) and ($i.service_identity|si_valid_identity)
    and ($i.identity_evidence|si_valid_evidence($i.target;$i._collection;$i._audit_date))
    then {service_identity:$i.service_identity,key:($i.service_identity|si_key),evidence:$i.identity_evidence} else null end;
