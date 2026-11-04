# Connect a native Alertmanager source

Use this recipe after the setup skill's Doctor and Live-safety gates. Also pass the Kubernetes Doctor for the independently selected source target, including its cloud identity and namespace authority. On-Call Doctor verifies the provider team; it does not authorize a cluster. Every block resolves the source through `toolkit-targets.sh`, requires `SOC_AM_KUBERNETES_TARGET` for a list, and compares `SOC_AM_CONTEXT` with both configured and live named-context identity. No block selects the ambient context or defaults to the first list entry. It changes your sender and can deliver real notifications. Incoming integration enablement is an attended, confirmed provider change; capture its before/after state with [attended verification](attended-verification.md). The incoming integration key is **not** your management API ID or either management API key.

This recipe covers a Kubernetes StatefulSet reading one `alertmanager.yml` key from a ConfigMap, with one root receiver and no child routes. It preserves that receiver and adds one narrowly matched On-Call destination. A deployment with existing child routes, multiple configuration keys, mounted templates, an operator, Helm automation, HA peers or different storage needs its own reviewed preservation plan; do not replace it with this example.

## Native receiver contract

The reference version is Alertmanager **v0.34.0**: [configuration](https://github.com/prometheus/alertmanager/blob/v0.34.0/config/notifiers.go) and [VictorOps notifier](https://github.com/prometheus/alertmanager/blob/v0.34.0/notify/victorops/victorops.go). Revalidate other versions against their installed `amtool` and matching source.

- `victorops_configs` uses the incoming integration `api_key` and selected `routing_key`. The native notifier uses `https://alert.victorops.com/integrations/generic/20131114/alert/` as its API base and constructs the credential-bearing request internally. This public base contains no credential; never log or paste the completed URL.
- `api_key_file` is supported. `routing_key_file` is **not** supported, and YAML does not expand environment variables. Protect the complete runtime configuration when it contains either sensitive field. A ConfigMap plus an API-key file still exposes a plaintext routing key.
- Do not add a made-up `entity_id` configuration field. The notifier derives the entity from the Alertmanager group key. Stable grouping and exact source-to-incident joins must be proved with real delivery.
- Set `send_resolved: true`. Native resolved delivery follows the source lifecycle; manually closing an incident does not prove source recovery.
- Do not dump `/api/v2/status`, `amtool config show`, receiver objects, raw errors or the loaded configuration. `routing_key` is a plain string in the schema and may remain visible when secret-typed fields are redacted.

## Prepare the exact change

**Judgment:** choose one approved source rule, its exact namespace and a dedicated label that excludes unrelated alerts. Group on stable problem identity. Inspect current alert cardinality before enabling delivery; increasing `repeat_interval` does not prevent the first notification for every distinct group.

- ❌ Match every critical alert and assume a long repeat interval prevents a notification burst.
- ✅ Match the selected rule, namespace and explicit test label; verify one intended group and retain every existing delivery path.

**Fixed:** capture your current StatefulSet, configuration source, content fingerprints, image, reload mechanism, templates, inhibition rules, silences, notification state and original receivers in your protected deployment store. Record how to restore them before changing anything. A restart can lose an `emptyDir` notification log or silences, reset deduplication and resend existing alerts. Preserve durable state/HA behavior or announce that exact loss and obtain approval; never describe a single-pod restart as zero impact.

Use your deployment secret tooling to render the complete candidate inside that protected store. The following is a **fragment**, not a replacement configuration. Replace the example labels and receiver names with your reviewed values; retain all existing root settings, receivers and other sections. `INCOMING_FROM_SECRET_STORE` and `ROUTE_FROM_SECRET_STORE` are substitution markers, not usable credentials. Render them without showing their values to the model, shell history, process arguments or reports.

```yaml
route:
  receiver: existing-receiver
  # Retain the existing root timing/grouping settings.
  routes:
    - receiver: oncall-validation
      matchers:
        - 'alertname="OnCallSourceProbe"'
        - 'namespace="example-workload"'
        - 'oncall_test="true"'
      continue: true
      group_by: [alertname, namespace, run_id]
    - receiver: existing-receiver
      matchers:
        - 'alertname="OnCallSourceProbe"'
        - 'namespace="example-workload"'
        - 'oncall_test="true"'
# Append to the existing receivers; do not remove existing-receiver.
receivers:
  - name: oncall-validation
    victorops_configs:
      - api_url: https://alert.victorops.com/integrations/generic/20131114/alert/
        api_key: INCOMING_FROM_SECRET_STORE
        routing_key: ROUTE_FROM_SECRET_STORE
        send_resolved: true
        message_type: CRITICAL
        monitoring_tool: Alertmanager
```

The first matching child continues to the second matching sibling, which explicitly delivers to the original receiver. **Parent fallback does not occur after a child matches.** Unmatched alerts still use the root. A real deployment may need additional matchers and assertions; approve that expanded diff before applying it.

## Capture the Kubernetes baseline and prepare the mount patch

**Fixed, read-only against Kubernetes:** this narrower mount recipe requires one ConfigMap configuration volume, an existing pod `fsGroup` for group-readable Secret files, one replica and a rolling update strategy. Stop and prepare a different reviewed plan if an assertion fails. It does not add permissions, change the security context or reset notification state. Confirm the current configuration has one root receiver and no children before using the route fragment above.

```bash
set -eu
set +x
AM_CONTEXT="${SOC_AM_CONTEXT:?Set verified context}"
AM_NS="${SOC_AM_NAMESPACE:?Set observed namespace}"
# Resolve the Kubernetes target independently of the On-Call target label.
AM_CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$AM_CFG" ]; then
  for AM_CANDIDATE in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$AM_CANDIDATE" ] && { AM_CFG="$AM_CANDIDATE"; break; }
  done
fi
[ -n "$AM_CFG" ] && [ -f "$AM_CFG" ] || { echo 'Missing toolkit config'; exit 1; }
AM_TT="${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/report-standard/toolkit-targets.sh"
AM_KIND=$(sh "$AM_TT" "$AM_CFG" kubernetes kind)
AM_COUNT=$(sh "$AM_TT" "$AM_CFG" kubernetes count)
[ "$AM_COUNT" -ge 1 ] || { echo 'No configured Kubernetes target'; exit 1; }
AM_INDEX=0
if [ "$AM_KIND" = seq ]; then
  [ -n "${SOC_AM_KUBERNETES_TARGET:-}" ] || { echo 'Select SOC_AM_KUBERNETES_TARGET independently of the On-Call label'; exit 1; }
  AM_MATCHES=0; AM_I=0
  while [ "$AM_I" -lt "$AM_COUNT" ]; do
    if [ "$(sh "$AM_TT" "$AM_CFG" kubernetes label "$AM_I")" = "$SOC_AM_KUBERNETES_TARGET" ]; then AM_INDEX=$AM_I; AM_MATCHES=$((AM_MATCHES+1)); fi
    AM_I=$((AM_I+1))
  done
  [ "$AM_MATCHES" -eq 1 ] || { echo 'Kubernetes target must match exactly once'; exit 1; }
else
  [ "$AM_KIND" = map ] && [ "$AM_COUNT" -eq 1 ] || { echo 'Unsupported Kubernetes target shape'; exit 1; }
fi
AM_CONFIGURED_CONTEXT=$(sh "$AM_TT" "$AM_CFG" kubernetes get "$AM_INDEX" context)
[ -n "$AM_CONFIGURED_CONTEXT" ] && [ "$AM_CONTEXT" = "$AM_CONFIGURED_CONTEXT" ] || { echo 'Context differs from the selected toolkit target'; exit 1; }
am_read_json() {
  AM_RAW=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" "$@" 2>/dev/null) || { echo 'Kubernetes read failed; stop without using its output' >&2; return 1; }
  printf '%s' "$AM_RAW" | python3 -c '
import json,sys
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError()
  out[k]=v
 return out
try:
 raw=sys.stdin.read(); assert len(raw)<=16777216
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 assert isinstance(x,dict)
 if sys.argv[2]=="get":
  resource=sys.argv[3]
  if resource=="secrets":
   assert x.get("kind") in ("List","SecretList") and isinstance(x.get("items"),list)
  else:
   expected={"statefulset":"StatefulSet","configmap":"ConfigMap","secret":"Secret","pod":"Pod"}[resource]
   assert x.get("kind")==expected and x["metadata"]["name"]==sys.argv[4] and x["metadata"]["namespace"]==sys.argv[1]
 print(json.dumps(x,separators=(",",":"),allow_nan=False))
except Exception:
 print("Invalid or incomplete Kubernetes JSON; output withheld",file=sys.stderr);sys.exit(1)' "$AM_NS" "$@"
}
AM_VIEW=$(am_read_json config view --minify -o json) || exit 1
printf '%s' "$AM_VIEW" | jq -e --arg context "$AM_CONTEXT" '.["current-context"] == $context and (.contexts | length == 1) and .contexts[0].name == $context' >/dev/null
unset AM_VIEW
AM_STS="${SOC_AM_STATEFULSET:?Set observed StatefulSet}"
AM_VOLUME="${SOC_AM_CONFIG_VOLUME:?Set its observed configuration volume name}"
AM_SECRET="${SOC_AM_SECRET:?Set proposed unique Secret name}"
AM_DIR="${SOC_AM_PRIVATE_DIR:?Set an existing protected deployment-store directory}"
umask 077
python3 - "$AM_DIR" <<'PY_DIRECTORY'
import os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); s=p.lstat()
assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.getuid() and not s.st_mode & 0o077
assert not any((p/n).exists() or (p/n).is_symlink() for n in ('before.json','original-configmap.json','mount.patch.json')), 'Use a fresh plan directory'
PY_DIRECTORY
set -C
AM_OBJECT=$(am_read_json get statefulset "$AM_STS" -o json) || exit 1
printf '%s' "$AM_OBJECT" > "$AM_DIR/before.json"
jq -e --arg volume "$AM_VOLUME" \
  '.spec.replicas == 1 and .spec.updateStrategy.type == "RollingUpdate" and (.spec.template.spec.securityContext.fsGroup | type == "number") and ([.spec.template.spec.volumes[] | select(.name == $volume and .configMap.name != null)] | length == 1)' "$AM_DIR/before.json" >/dev/null
AM_CM=$(jq -er --arg volume "$AM_VOLUME" '.spec.template.spec.volumes[] | select(.name == $volume) | .configMap.name' "$AM_DIR/before.json")
AM_OBJECT=$(am_read_json get configmap "$AM_CM" -o json) || exit 1
printf '%s' "$AM_OBJECT" > "$AM_DIR/original-configmap.json"
jq -e '.data | keys == ["alertmanager.yml"]' "$AM_DIR/original-configmap.json" >/dev/null
jq --arg volume "$AM_VOLUME" --arg secret "$AM_SECRET" '
  . as $before | (.spec.template.spec.volumes | to_entries | map(select(.value.name == $volume))) as $matches |
  if ($matches | length) != 1 then error("Ambiguous configuration volume") else
  $matches[0] as $v | ("/spec/template/spec/volumes/" + ($v.key | tostring)) as $path |
  [{op:"test",path:"/metadata/uid",value:$before.metadata.uid},
   {op:"test",path:"/metadata/resourceVersion",value:$before.metadata.resourceVersion},
   {op:"test",path:$path,value:$v.value},
   {op:"replace",path:$path,value:{name:$volume,secret:{secretName:$secret,defaultMode:288,items:[{key:"alertmanager.yml",path:"alertmanager.yml"}]}}}]
  end' "$AM_DIR/before.json" > "$AM_DIR/mount.patch.json"
echo 'Baseline and drift-checked mount patch prepared; no live configuration changed.'
```

The generated Secret item path must equal the path your existing mount and `--config.file` expect. Verify that invariant from the captured volume items, `volumeMounts`, process flags and container identity before approving; the example cannot relocate templates or infer a nonstandard path. Fingerprint these private files without printing their contents. The candidate and mount patch checksums are the approval binding used below.

## Validate with the installed binary

**Fixed, read-only:** prerequisites are `kubectl`, `jq`, Python 3 and PyYAML. Run this block as written after setting the inputs from your reviewed deployment plan. It privately parses the captured ConfigMap and candidate, rejects duplicate YAML/JSON fields, cyclic values, multiple documents and unsupported shapes, and requires exactly the single receiver plus two sibling routes shown above. All prior receiver definitions, root settings, templates, inhibition rules and every other section must remain structurally identical. Extra ConfigMap keys/templates or existing child routes refuse this narrow recipe. Only after the installed checks pass does it write a private checksum-bound `native-validation.json`; publication requires that receipt and a fresh unchanged original ConfigMap. It reads a protected rendered file, sends it only over `kubectl exec` stdin to the selected pod and suppresses validator output, which may contain sensitive details. It makes no provider send or Kubernetes mutation. Each `amtool` command must exit zero; any failure blocks rollout. Inputs are explicit so a fresh shell cannot inherit a different target.

<!-- oncall-alertmanager-validate:start -->
```bash
set -eu
set +x
AM_CONTEXT="${SOC_AM_CONTEXT:?Set the verified kubernetes.context}"
AM_NS="${SOC_AM_NAMESPACE:?Set the observed Alertmanager namespace}"
# Resolve the Kubernetes target independently of the On-Call target label.
AM_CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$AM_CFG" ]; then
  for AM_CANDIDATE in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$AM_CANDIDATE" ] && { AM_CFG="$AM_CANDIDATE"; break; }
  done
fi
[ -n "$AM_CFG" ] && [ -f "$AM_CFG" ] || { echo 'Missing toolkit config'; exit 1; }
AM_TT="${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/report-standard/toolkit-targets.sh"
AM_KIND=$(sh "$AM_TT" "$AM_CFG" kubernetes kind)
AM_COUNT=$(sh "$AM_TT" "$AM_CFG" kubernetes count)
[ "$AM_COUNT" -ge 1 ] || { echo 'No configured Kubernetes target'; exit 1; }
AM_INDEX=0
if [ "$AM_KIND" = seq ]; then
  [ -n "${SOC_AM_KUBERNETES_TARGET:-}" ] || { echo 'Select SOC_AM_KUBERNETES_TARGET independently of the On-Call label'; exit 1; }
  AM_MATCHES=0; AM_I=0
  while [ "$AM_I" -lt "$AM_COUNT" ]; do
    if [ "$(sh "$AM_TT" "$AM_CFG" kubernetes label "$AM_I")" = "$SOC_AM_KUBERNETES_TARGET" ]; then AM_INDEX=$AM_I; AM_MATCHES=$((AM_MATCHES+1)); fi
    AM_I=$((AM_I+1))
  done
  [ "$AM_MATCHES" -eq 1 ] || { echo 'Kubernetes target must match exactly once'; exit 1; }
else
  [ "$AM_KIND" = map ] && [ "$AM_COUNT" -eq 1 ] || { echo 'Unsupported Kubernetes target shape'; exit 1; }
fi
AM_CONFIGURED_CONTEXT=$(sh "$AM_TT" "$AM_CFG" kubernetes get "$AM_INDEX" context)
[ -n "$AM_CONFIGURED_CONTEXT" ] && [ "$AM_CONTEXT" = "$AM_CONFIGURED_CONTEXT" ] || { echo 'Context differs from the selected toolkit target'; exit 1; }
am_read_json() {
  AM_RAW=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" "$@" 2>/dev/null) || { echo 'Kubernetes read failed; stop without using its output' >&2; return 1; }
  printf '%s' "$AM_RAW" | python3 -c '
import json,sys
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError()
  out[k]=v
 return out
try:
 raw=sys.stdin.read(); assert len(raw)<=16777216
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 assert isinstance(x,dict)
 if sys.argv[2]=="get":
  resource=sys.argv[3]
  if resource=="secrets":
   assert x.get("kind") in ("List","SecretList") and isinstance(x.get("items"),list)
  else:
   expected={"statefulset":"StatefulSet","configmap":"ConfigMap","secret":"Secret","pod":"Pod"}[resource]
   assert x.get("kind")==expected and x["metadata"]["name"]==sys.argv[4] and x["metadata"]["namespace"]==sys.argv[1]
 print(json.dumps(x,separators=(",",":"),allow_nan=False))
except Exception:
 print("Invalid or incomplete Kubernetes JSON; output withheld",file=sys.stderr);sys.exit(1)' "$AM_NS" "$@"
}
AM_VIEW=$(am_read_json config view --minify -o json) || exit 1
printf '%s' "$AM_VIEW" | jq -e --arg context "$AM_CONTEXT" '.["current-context"] == $context and (.contexts | length == 1) and .contexts[0].name == $context' >/dev/null
unset AM_VIEW
AM_POD="${SOC_AM_POD:?Set the observed running pod}"
AM_CONTAINER="${SOC_AM_CONTAINER:?Set the observed Alertmanager container}"
AM_CONFIG="${SOC_AM_CONFIG:?Set the rendered configuration in the protected deployment store}"
AM_DIR="${SOC_AM_PRIVATE_DIR:?Set the same protected plan directory used for the baseline}"
AM_NEW="${SOC_AM_NEW_RECEIVER:?Set the reviewed new receiver name}"
AM_OLD="${SOC_AM_OLD_RECEIVER:?Set the preserved root receiver name}"
AM_ALERT="${SOC_AM_ALERT:?Set the exact selected source alert name}"
AM_SOURCE_NS="${SOC_AM_SOURCE_NAMESPACE:?Set the exact source namespace label}"
AM_OTHER_NS="${SOC_AM_OTHER_NAMESPACE:?Set a distinct nonmatching namespace label}"
for bin in kubectl python3 jq; do command -v "$bin" >/dev/null 2>&1 || { echo "Missing $bin"; exit 1; }; done
AM_PRESERVATION=$(python3 - "$AM_DIR" "$AM_CONFIG" "$AM_CONTEXT" "$AM_NS" "$AM_NEW" "$AM_OLD" "$AM_ALERT" "$AM_SOURCE_NS" "$AM_OTHER_NS" <<'PY_GUARD'
import copy,hashlib,json,os,pathlib,re,stat,sys
try:
 import yaml
 def require(ok):
  if not ok: raise ValueError()
 def private(path,directory=False):
  q=pathlib.Path(path); t=q.lstat()
  require((stat.S_ISDIR(t.st_mode) if directory else stat.S_ISREG(t.st_mode)) and t.st_uid==os.getuid() and not t.st_mode & 0o077)
  return q
 def pairs(items):
  out={}
  for k,v in items:
   require(k not in out); out[k]=v
  return out
 def load_json(text):
  return json.loads(text,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 class StrictLoader(yaml.SafeLoader): pass
 def mapping(loader,node,deep=False):
  result={}
  for key,value in node.value:
   k=loader.construct_object(key,deep=deep)
   require(isinstance(k,str) and k not in result)
   result[k]=loader.construct_object(value,deep=deep)
  return result
 StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,mapping)
 def load_yaml(text):
  require(len(text)<=4194304)
  obj=yaml.load(text,Loader=StrictLoader); require(isinstance(obj,dict)); return obj
 def canonical(obj): return json.dumps(obj,sort_keys=True,separators=(',',':'),allow_nan=False)
 d=private(sys.argv[1],True); candidate=private(sys.argv[2]); baseline=private(d/'original-configmap.json')
 require(candidate.resolve()==(d/'candidate.yml').resolve())
 context,namespace,new,old,alert,source_ns,other_ns=sys.argv[3:]
 require(all(re.fullmatch(r'[A-Za-z0-9_.-]+',x) for x in (new,old,alert,source_ns,other_ns)))
 require(new!=old and source_ns!=other_ns)
 cm=load_json(baseline.read_text()); require(isinstance(cm,dict) and cm.get('kind')=='ConfigMap')
 require(cm['metadata']['namespace']==namespace and isinstance(cm['metadata']['uid'],str))
 require(set(cm['data'])=={'alertmanager.yml'} and not cm.get('binaryData'))
 before=load_yaml(cm['data']['alertmanager.yml']); after=load_yaml(candidate.read_text())
 require(isinstance(before.get('route'),dict) and before['route'].get('receiver')==old and before['route'].get('routes',[])==[])
 receivers=before.get('receivers'); require(isinstance(receivers,list) and all(isinstance(r,dict) and isinstance(r.get('name'),str) for r in receivers))
 names=[r['name'] for r in receivers]; require(len(names)==len(set(names)) and names.count(old)==1 and new not in names)
 incoming=after['receivers'][-1]; require(set(incoming)=={'name','victorops_configs'} and incoming['name']==new)
 require(isinstance(incoming['victorops_configs'],list) and len(incoming['victorops_configs'])==1)
 vo=incoming['victorops_configs'][0]
 require(set(vo)=={'api_url','api_key','routing_key','send_resolved','message_type','monitoring_tool'})
 require(vo['api_url']=='https://alert.victorops.com/integrations/generic/20131114/alert/' and vo['send_resolved'] is True and vo['message_type']=='CRITICAL' and vo['monitoring_tool']=='Alertmanager')
 require(all(isinstance(vo[k],str) and vo[k] and not re.search(r'[\x00-\x20]',vo[k]) and vo[k] not in ('INCOMING_FROM_SECRET_STORE','ROUTE_FROM_SECRET_STORE') for k in ('api_key','routing_key')))
 matchers=['alertname='+json.dumps(alert),'namespace='+json.dumps(source_ns),'oncall_test="true"']
 expected=copy.deepcopy(before)
 expected['route']['routes']=[{'receiver':new,'matchers':matchers,'continue':True,'group_by':['alertname','namespace','run_id']},{'receiver':old,'matchers':matchers}]
 expected['receivers'].append(incoming)
 require(canonical(after)==canonical(expected))
 record={'context':context,'namespace':namespace,'candidate_sha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),'baseline_sha256':hashlib.sha256(baseline.read_bytes()).hexdigest(),'original_config_sha256':hashlib.sha256(cm['data']['alertmanager.yml'].encode()).hexdigest(),'preservation':'exact-single-addition'}
 require(not (d/'native-validation.json').exists())
 print(json.dumps(record,separators=(',',':')))
except Exception:
 print('Structural preservation refused; check private inputs and PyYAML installation. Configuration and errors withheld.',file=sys.stderr);sys.exit(1)
PY_GUARD
) || exit 1
am_check() {
  if ! kubectl --context "$AM_CONTEXT" -n "$AM_NS" exec -i "$AM_POD" -c "$AM_CONTAINER" -- \
    /bin/amtool "$@" < "$AM_CONFIG" >/dev/null 2>&1; then
    echo 'Alertmanager validation refused; no rollout. Inspect privately, do not print configuration or errors.'
    exit 1
  fi
}
am_check check-config /dev/stdin
am_check config routes test --config.file=/dev/stdin "--verify.receivers=$AM_NEW,$AM_OLD" \
  "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" oncall_test=true run_id=validation
am_check config routes test --config.file=/dev/stdin "--verify.receivers=$AM_OLD" \
  "alertname=$AM_ALERT" "namespace=$AM_OTHER_NS" oncall_test=true run_id=validation
am_check config routes test --config.file=/dev/stdin "--verify.receivers=$AM_OLD" \
  "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" oncall_test=false run_id=validation
am_check config routes test --config.file=/dev/stdin "--verify.receivers=$AM_OLD" \
  "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" run_id=validation
printf '%s' "$AM_PRESERVATION" | python3 -c '
import json,os,pathlib,sys
x=json.load(sys.stdin); x["installed_amtool_checks"]="passed"
p=pathlib.Path(sys.argv[1])/"native-validation.json"
fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
with os.fdopen(fd,"w") as f: json.dump(x,f); f.write("\n")' "$AM_DIR"
echo 'Configuration and four receiver assertions passed; delivery remains unverified.'
```
<!-- oncall-alertmanager-validate:end -->

Expected: the final success sentence and exit zero. A missing receiver, unintended fanout, missing original sink, wrong namespace or absent opt-in label must fail its assertion. Also evaluate representative unrelated alerts against the baseline and candidate: their receivers must be identical. Use the actual installed binary for this comparison; a local mock cannot establish native routing behavior.

## Publish the protected configuration and switch its mount

**Fixed:** prepare one uniquely named immutable Kubernetes Secret containing the complete rendered `alertmanager.yml`. Kubernetes Secrets require your normal encryption-at-rest and RBAC controls; base64 is not encryption. Preserve the original ConfigMap untouched as the rollback source. If it contains additional keys/templates, include and verify all of them in the reviewed plan before proceeding.

The exact mutation plan contains the candidate checksum, Secret name, target UID, current resourceVersion, volume index/name, old ConfigMap volume, intended Secret volume, mounted key/path, read permissions and approved rollout timeout. A Secret volume must be readable by the existing container identity; do not change the workload's security context silently. Keep the original container flags and mount path. Show the secret-free diff and restart consequences, then obtain confirmation.

The commands below are the fixed Kubernetes operations for that plan. `SOC_AM_PRIVATE_DIR` is an existing private deployment-store directory, not an audit/report folder. `candidate.yml`, `before.json` and `mount.patch.json` must be private regular files there; the approved patch contains JSON Patch `test` operations for UID, resourceVersion and the original volume before its single volume replacement. Its intended volume references the new Secret and the exact original key/path; a full StatefulSet replacement is not allowed. Before the first mutation, the executable guard checks the complete allowed patch shape and binds its Secret name, StatefulSet name/namespace/UID, resourceVersion and original volume to the current inputs and saved baseline. Changing a typed input cannot redirect creation independently of the approved patch.

```bash
set -eu
set +x
AM_CONTEXT="${SOC_AM_CONTEXT:?Set verified context}"
AM_NS="${SOC_AM_NAMESPACE:?Set observed namespace}"
# Resolve the Kubernetes target independently of the On-Call target label.
AM_CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$AM_CFG" ]; then
  for AM_CANDIDATE in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$AM_CANDIDATE" ] && { AM_CFG="$AM_CANDIDATE"; break; }
  done
fi
[ -n "$AM_CFG" ] && [ -f "$AM_CFG" ] || { echo 'Missing toolkit config'; exit 1; }
AM_TT="${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/report-standard/toolkit-targets.sh"
AM_KIND=$(sh "$AM_TT" "$AM_CFG" kubernetes kind)
AM_COUNT=$(sh "$AM_TT" "$AM_CFG" kubernetes count)
[ "$AM_COUNT" -ge 1 ] || { echo 'No configured Kubernetes target'; exit 1; }
AM_INDEX=0
if [ "$AM_KIND" = seq ]; then
  [ -n "${SOC_AM_KUBERNETES_TARGET:-}" ] || { echo 'Select SOC_AM_KUBERNETES_TARGET independently of the On-Call label'; exit 1; }
  AM_MATCHES=0; AM_I=0
  while [ "$AM_I" -lt "$AM_COUNT" ]; do
    if [ "$(sh "$AM_TT" "$AM_CFG" kubernetes label "$AM_I")" = "$SOC_AM_KUBERNETES_TARGET" ]; then AM_INDEX=$AM_I; AM_MATCHES=$((AM_MATCHES+1)); fi
    AM_I=$((AM_I+1))
  done
  [ "$AM_MATCHES" -eq 1 ] || { echo 'Kubernetes target must match exactly once'; exit 1; }
else
  [ "$AM_KIND" = map ] && [ "$AM_COUNT" -eq 1 ] || { echo 'Unsupported Kubernetes target shape'; exit 1; }
fi
AM_CONFIGURED_CONTEXT=$(sh "$AM_TT" "$AM_CFG" kubernetes get "$AM_INDEX" context)
[ -n "$AM_CONFIGURED_CONTEXT" ] && [ "$AM_CONTEXT" = "$AM_CONFIGURED_CONTEXT" ] || { echo 'Context differs from the selected toolkit target'; exit 1; }
am_read_json() {
  AM_RAW=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" "$@" 2>/dev/null) || { echo 'Kubernetes read failed; stop without using its output' >&2; return 1; }
  printf '%s' "$AM_RAW" | python3 -c '
import json,sys
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError()
  out[k]=v
 return out
try:
 raw=sys.stdin.read(); assert len(raw)<=16777216
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 assert isinstance(x,dict)
 if sys.argv[2]=="get":
  resource=sys.argv[3]
  if resource=="secrets":
   assert x.get("kind") in ("List","SecretList") and isinstance(x.get("items"),list)
  else:
   expected={"statefulset":"StatefulSet","configmap":"ConfigMap","secret":"Secret","pod":"Pod"}[resource]
   assert x.get("kind")==expected and x["metadata"]["name"]==sys.argv[4] and x["metadata"]["namespace"]==sys.argv[1]
 print(json.dumps(x,separators=(",",":"),allow_nan=False))
except Exception:
 print("Invalid or incomplete Kubernetes JSON; output withheld",file=sys.stderr);sys.exit(1)' "$AM_NS" "$@"
}
AM_VIEW=$(am_read_json config view --minify -o json) || exit 1
printf '%s' "$AM_VIEW" | jq -e --arg context "$AM_CONTEXT" '.["current-context"] == $context and (.contexts | length == 1) and .contexts[0].name == $context' >/dev/null
unset AM_VIEW
AM_STS="${SOC_AM_STATEFULSET:?Set observed StatefulSet}"
AM_SECRET="${SOC_AM_SECRET:?Set approved unique Secret name}"
AM_DIR="${SOC_AM_PRIVATE_DIR:?Set protected deployment-store directory}"
AM_CONFIG_SHA="${SOC_AM_CONFIG_SHA256:?Set approved candidate checksum}"
AM_PATCH_SHA="${SOC_AM_PATCH_SHA256:?Set approved mount patch checksum}"
umask 077
python3 - "$AM_DIR" "$AM_CONFIG_SHA" "$AM_PATCH_SHA" "$AM_CONTEXT" "$AM_NS" "$AM_SECRET" "$AM_STS" <<'PY_FILES'
import hashlib,json,os,pathlib,re,stat,sys
try:
 def require(ok):
  if not ok: raise ValueError()
 def pairs(items):
  out={}
  for k,v in items:
   require(k not in out); out[k]=v
  return out
 def private(path):
  t=path.lstat(); require(stat.S_ISREG(t.st_mode) and t.st_uid==os.getuid() and not t.st_mode & 0o077); return path.read_bytes()
 def read_json(path): return json.loads(private(path),object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 def canonical(obj): return json.dumps(obj,sort_keys=True,separators=(',',':'),allow_nan=False)
 p=pathlib.Path(sys.argv[1]); t=p.lstat(); require(stat.S_ISDIR(t.st_mode) and t.st_uid==os.getuid() and not t.st_mode & 0o077)
 require(hashlib.sha256(private(p/'candidate.yml')).hexdigest()==sys.argv[2])
 require(hashlib.sha256(private(p/'mount.patch.json')).hexdigest()==sys.argv[3])
 context,namespace,secret,sts=sys.argv[4:]
 require(bool(re.fullmatch(r'[a-z0-9]([-a-z0-9.]*[a-z0-9])?',secret)))
 v=read_json(p/'native-validation.json'); cm=read_json(p/'original-configmap.json'); before=read_json(p/'before.json'); patch=read_json(p/'mount.patch.json')
 require(v['candidate_sha256']==sys.argv[2] and v['baseline_sha256']==hashlib.sha256(private(p/'original-configmap.json')).hexdigest())
 require(v['context']==context and v['namespace']==namespace and v['preservation']=='exact-single-addition' and v['installed_amtool_checks']=='passed')
 require(before['kind']=='StatefulSet' and before['metadata']['name']==sts and before['metadata']['namespace']==namespace)
 require(all(isinstance(before['metadata'][k],str) and before['metadata'][k] for k in ('uid','resourceVersion')))
 require(before['spec']['replicas']==1 and before['spec']['updateStrategy']['type']=='RollingUpdate' and type(before['spec']['template']['spec']['securityContext']['fsGroup']) is int)
 require(cm['kind']=='ConfigMap' and cm['metadata']['namespace']==namespace and set(cm['data'])=={'alertmanager.yml'} and not cm.get('binaryData'))
 require(isinstance(patch,list) and len(patch)==4 and isinstance(patch[3],dict))
 path=patch[3].get('path',''); match=re.fullmatch(r'/spec/template/spec/volumes/(0|[1-9][0-9]*)',path); require(match is not None)
 old=before['spec']['template']['spec']['volumes'][int(match.group(1))]
 require(set(old)<= {'name','configMap'} and old['configMap']['name']==cm['metadata']['name'])
 replacement={'name':old['name'],'secret':{'secretName':secret,'defaultMode':288,'items':[{'key':'alertmanager.yml','path':'alertmanager.yml'}]}}
 expected=[{'op':'test','path':'/metadata/uid','value':before['metadata']['uid']},{'op':'test','path':'/metadata/resourceVersion','value':before['metadata']['resourceVersion']},{'op':'test','path':path,'value':old},{'op':'replace','path':path,'value':replacement}]
 require(canonical(patch)==canonical(expected))
except Exception:
 print('Approved plan binding refused; no mutation. Private values and parser details withheld.',file=sys.stderr);sys.exit(1)
PY_FILES
AM_CM=$(jq -er '.metadata.name' "$AM_DIR/original-configmap.json")
AM_OBJECT=$(am_read_json get configmap "$AM_CM" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --slurpfile before "$AM_DIR/original-configmap.json" '.metadata.uid == $before[0].metadata.uid and .metadata.namespace == $before[0].metadata.namespace and .data == $before[0].data and (.binaryData // {}) == ($before[0].binaryData // {})' >/dev/null
# These reads must succeed; an access denial is not proof a name is unused.
AM_OBJECT=$(am_read_json get secrets --field-selector "metadata.name=$AM_SECRET" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e '.items | type == "array" and length == 0' >/dev/null
AM_OBJECT=$(am_read_json get statefulset "$AM_STS" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --slurpfile before "$AM_DIR/before.json" \
    '.metadata.uid == $before[0].metadata.uid and .metadata.resourceVersion == $before[0].metadata.resourceVersion and .spec.template == $before[0].spec.template' >/dev/null
AM_SECRET_REQUEST=$(jq -n --arg name "$AM_SECRET" --arg ns "$AM_NS" --rawfile config "$AM_DIR/candidate.yml" \
  '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:$ns},type:"Opaque",immutable:true,stringData:{"alertmanager.yml":$config}}') || exit 1
printf '%s' "$AM_SECRET_REQUEST" | kubectl --context "$AM_CONTEXT" -n "$AM_NS" create -f - >/dev/null 2>&1
unset AM_SECRET_REQUEST
AM_OBJECT=$(am_read_json get secret "$AM_SECRET" -o json) || exit 1
printf '%s' "$AM_OBJECT" | python3 -c 'import base64,hashlib,json,sys; x=json.load(sys.stdin); assert x.get("immutable") is True and set(x["data"])=={"alertmanager.yml"}; assert hashlib.sha256(base64.b64decode(x["data"]["alertmanager.yml"],validate=True)).hexdigest()==sys.argv[1]' "$AM_CONFIG_SHA"
kubectl --context "$AM_CONTEXT" -n "$AM_NS" patch statefulset "$AM_STS" --type=json --patch-file "$AM_DIR/mount.patch.json" >/dev/null 2>&1
AM_OBJECT=$(am_read_json get statefulset "$AM_STS" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --slurpfile before "$AM_DIR/before.json" --slurpfile patch "$AM_DIR/mount.patch.json" --arg secret "$AM_SECRET" '
    ($patch[0] | map(select(.op == "replace"))) as $changes |
    if ($changes | length) != 1 then false else
    ($changes[0].path | split("/")[1:] | map(if test("^[0-9]+$") then tonumber else . end)) as $path |
    ($before[0] | setpath($path; $changes[0].value)) as $expected |
    .metadata.uid == $expected.metadata.uid and .spec.template == $expected.spec.template and
    ([.spec.template.spec.volumes[] | select(.secret.secretName == $secret)] | length == 1) end' >/dev/null
echo 'Secret contents and intended mount read back; rollout and loaded configuration still require verification.'
```

Expected: exact content and mount assertions pass. A timeout after either mutation is an uncertain effect: read the exact Secret/StatefulSet before retrying. Do not create a second Secret or replay the patch blindly. If the mount switch fails, preserve the original running configuration and reconcile the unused Secret by ownership; do not reinstall Alertmanager.

Maintain the Secret reference and mount in your existing Helm/GitOps values or manifest overlay so the next upgrade cannot revert or overwrite them. Publish only references and secret-free templates; generate sensitive content through the existing secret manager. Validate the next render against the approved runtime shape. A live patch alone is not a durable setup.

## Verify loaded state and real delivery

**Fixed:** bind the new pod to the expected StatefulSet/UID and confirm all expected replicas are ready after the rollout. For the one-pod recipe, run the following against the observed replacement pod. `SOC_AM_CONFIG_PATH` comes from its actual `--config.file` flag, not a guessed default. Validator stdout/stderr and loaded file bytes remain suppressed; only the hash comparison result is exposed.

```bash
set -eu
set +x
AM_CONTEXT="${SOC_AM_CONTEXT:?Set verified context}"
AM_NS="${SOC_AM_NAMESPACE:?Set observed namespace}"
# Resolve the Kubernetes target independently of the On-Call target label.
AM_CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$AM_CFG" ]; then
  for AM_CANDIDATE in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$AM_CANDIDATE" ] && { AM_CFG="$AM_CANDIDATE"; break; }
  done
fi
[ -n "$AM_CFG" ] && [ -f "$AM_CFG" ] || { echo 'Missing toolkit config'; exit 1; }
AM_TT="${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/report-standard/toolkit-targets.sh"
AM_KIND=$(sh "$AM_TT" "$AM_CFG" kubernetes kind)
AM_COUNT=$(sh "$AM_TT" "$AM_CFG" kubernetes count)
[ "$AM_COUNT" -ge 1 ] || { echo 'No configured Kubernetes target'; exit 1; }
AM_INDEX=0
if [ "$AM_KIND" = seq ]; then
  [ -n "${SOC_AM_KUBERNETES_TARGET:-}" ] || { echo 'Select SOC_AM_KUBERNETES_TARGET independently of the On-Call label'; exit 1; }
  AM_MATCHES=0; AM_I=0
  while [ "$AM_I" -lt "$AM_COUNT" ]; do
    if [ "$(sh "$AM_TT" "$AM_CFG" kubernetes label "$AM_I")" = "$SOC_AM_KUBERNETES_TARGET" ]; then AM_INDEX=$AM_I; AM_MATCHES=$((AM_MATCHES+1)); fi
    AM_I=$((AM_I+1))
  done
  [ "$AM_MATCHES" -eq 1 ] || { echo 'Kubernetes target must match exactly once'; exit 1; }
else
  [ "$AM_KIND" = map ] && [ "$AM_COUNT" -eq 1 ] || { echo 'Unsupported Kubernetes target shape'; exit 1; }
fi
AM_CONFIGURED_CONTEXT=$(sh "$AM_TT" "$AM_CFG" kubernetes get "$AM_INDEX" context)
[ -n "$AM_CONFIGURED_CONTEXT" ] && [ "$AM_CONTEXT" = "$AM_CONFIGURED_CONTEXT" ] || { echo 'Context differs from the selected toolkit target'; exit 1; }
am_read_json() {
  AM_RAW=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" "$@" 2>/dev/null) || { echo 'Kubernetes read failed; stop without using its output' >&2; return 1; }
  printf '%s' "$AM_RAW" | python3 -c '
import json,sys
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError()
  out[k]=v
 return out
try:
 raw=sys.stdin.read(); assert len(raw)<=16777216
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 assert isinstance(x,dict)
 if sys.argv[2]=="get":
  resource=sys.argv[3]
  if resource=="secrets":
   assert x.get("kind") in ("List","SecretList") and isinstance(x.get("items"),list)
  else:
   expected={"statefulset":"StatefulSet","configmap":"ConfigMap","secret":"Secret","pod":"Pod"}[resource]
   assert x.get("kind")==expected and x["metadata"]["name"]==sys.argv[4] and x["metadata"]["namespace"]==sys.argv[1]
 print(json.dumps(x,separators=(",",":"),allow_nan=False))
except Exception:
 print("Invalid or incomplete Kubernetes JSON; output withheld",file=sys.stderr);sys.exit(1)' "$AM_NS" "$@"
}
AM_VIEW=$(am_read_json config view --minify -o json) || exit 1
printf '%s' "$AM_VIEW" | jq -e --arg context "$AM_CONTEXT" '.["current-context"] == $context and (.contexts | length == 1) and .contexts[0].name == $context' >/dev/null
unset AM_VIEW
AM_STS="${SOC_AM_STATEFULSET:?Set approved StatefulSet}"
AM_POD="${SOC_AM_POD:?Set the replacement pod verified as owned by that StatefulSet}"
AM_CONTAINER="${SOC_AM_CONTAINER:?Set observed container}"
AM_PATH="${SOC_AM_CONFIG_PATH:?Set the actual mounted config.file path}"
AM_CONFIG_SHA="${SOC_AM_CONFIG_SHA256:?Set approved checksum}"
AM_TIMEOUT="${SOC_AM_ROLLOUT_TIMEOUT:?Set the approved bounded timeout, for example 120s}"
AM_UID="${SOC_AM_STATEFULSET_UID:?Set the approved StatefulSet UID}"
AM_PORT="${SOC_AM_WEB_PORT:?Set the observed local web port}"
AM_APPLIED="${SOC_AM_APPLIED_AT:?Set the recorded UTC epoch seconds before this change}"
AM_NEW="${SOC_AM_NEW_RECEIVER:?Set the approved new receiver}"
AM_OLD="${SOC_AM_OLD_RECEIVER:?Set the preserved root receiver}"
AM_ALERT="${SOC_AM_ALERT:?Set the selected alert name}"
AM_SOURCE_NS="${SOC_AM_SOURCE_NAMESPACE:?Set its namespace label}"
AM_OTHER_NS="${SOC_AM_OTHER_NAMESPACE:?Set a distinct nonmatching namespace label}"
kubectl --context "$AM_CONTEXT" -n "$AM_NS" rollout status "statefulset/$AM_STS" --timeout "$AM_TIMEOUT"
AM_OBJECT=$(am_read_json get statefulset "$AM_STS" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --arg uid "$AM_UID" '.metadata.uid == $uid and .spec.replicas == 1 and .status.observedGeneration >= .metadata.generation and .status.readyReplicas == .spec.replicas and .status.updatedReplicas == .spec.replicas and .status.currentRevision == .status.updateRevision' >/dev/null
AM_OBJECT=$(am_read_json get pod "$AM_POD" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --arg uid "$AM_UID" --arg container "$AM_CONTAINER" '([.metadata.ownerReferences[]? | select(.kind == "StatefulSet" and .uid == $uid and .controller == true)] | length == 1) and ([.status.containerStatuses[]? | select(.name == $container and .ready == true and .state.running != null)] | length == 1)' >/dev/null
kubectl --context "$AM_CONTEXT" -n "$AM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- /bin/amtool check-config "$AM_PATH" >/dev/null 2>&1
AM_DIGEST=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- /bin/sha256sum "$AM_PATH" 2>/dev/null) || exit 1
printf '%s\n' "$AM_DIGEST" | awk -v expected="$AM_CONFIG_SHA" 'NR==1 && $1==expected {ok=1} END {exit !ok}'
AM_METRICS=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- \
  /bin/wget -T 10 -qO- "http://127.0.0.1:$AM_PORT/metrics" 2>/dev/null) || exit 1
printf '%s\n' "$AM_METRICS" | awk -v since="$AM_APPLIED" '$1=="alertmanager_config_last_reload_successful" {ok=($2==1)} $1=="alertmanager_config_last_reload_success_timestamp_seconds" && $2 ~ /^[0-9]+([.][0-9]+)?$/ {fresh=($2>=since)} END {exit !(ok && fresh)}'
loaded_route() {
  kubectl --context "$AM_CONTEXT" -n "$AM_NS" exec "$AM_POD" -c "$AM_CONTAINER" -- \
    /bin/amtool config routes test "--config.file=$AM_PATH" "$@" >/dev/null 2>&1
}
loaded_route "--verify.receivers=$AM_NEW,$AM_OLD" "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" oncall_test=true run_id=validation
loaded_route "--verify.receivers=$AM_OLD" "alertname=$AM_ALERT" "namespace=$AM_OTHER_NS" oncall_test=true run_id=validation
loaded_route "--verify.receivers=$AM_OLD" "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" oncall_test=false run_id=validation
loaded_route "--verify.receivers=$AM_OLD" "alertname=$AM_ALERT" "namespace=$AM_SOURCE_NS" run_id=validation
echo 'Ready rollout, loaded fingerprint, fresh successful reload and four mounted route assertions passed; prove actual delivery next.'
```

Expected: every command exits zero. The reload timestamp must follow this change; an unchanged process using old configuration cannot pass merely because a file changed. If your image lacks the named read-only utilities or metrics, establish an equivalent verified read before mutation rather than installing tools into the running container. Preserve only status, hashes and assertion results in evidence.

Capture one approved source's pending/firing state, native sender success, populated On-Call incident and its route/policy/team/responder join. Then verify real source recovery and its matching native resolved delivery. Label a local relay as relay proof, an explicit incident close as cleanup, and an observed notification receipt as delivery proof. Source-rule presence, an `amtool` pass and an HTTP success do not alone prove a person received a page. New workload faults require their own scope, independent cleanup and recovery verification; this recipe does not inject one.

## Restore the sender

**Fixed:** first reconcile active test incidents. Disabling a route does not unsend a notification or resolve an incident already created. Prepare an inverse JSON Patch from the verified post-state: test its UID, current resourceVersion and exact Secret volume, then replace only that volume with the preserved ConfigMap volume. Assert the original ConfigMap content hash still matches the baseline. Show and confirm this inverse before execution; concurrent edits require a revised plan, not a broad restore.

```bash
set -eu
set +x
AM_CONTEXT="${SOC_AM_CONTEXT:?Set verified context}"
AM_NS="${SOC_AM_NAMESPACE:?Set observed namespace}"
# Resolve the Kubernetes target independently of the On-Call target label.
AM_CFG="${SCOUTFLO_CONFIG:-}"
if [ -z "$AM_CFG" ]; then
  for AM_CANDIDATE in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null || true)" "$HOME/.scoutflo/toolkit.yaml"; do
    [ -f "$AM_CANDIDATE" ] && { AM_CFG="$AM_CANDIDATE"; break; }
  done
fi
[ -n "$AM_CFG" ] && [ -f "$AM_CFG" ] || { echo 'Missing toolkit config'; exit 1; }
AM_TT="${CLAUDE_PLUGIN_ROOT:?Set the installed plugin root}/report-standard/toolkit-targets.sh"
AM_KIND=$(sh "$AM_TT" "$AM_CFG" kubernetes kind)
AM_COUNT=$(sh "$AM_TT" "$AM_CFG" kubernetes count)
[ "$AM_COUNT" -ge 1 ] || { echo 'No configured Kubernetes target'; exit 1; }
AM_INDEX=0
if [ "$AM_KIND" = seq ]; then
  [ -n "${SOC_AM_KUBERNETES_TARGET:-}" ] || { echo 'Select SOC_AM_KUBERNETES_TARGET independently of the On-Call label'; exit 1; }
  AM_MATCHES=0; AM_I=0
  while [ "$AM_I" -lt "$AM_COUNT" ]; do
    if [ "$(sh "$AM_TT" "$AM_CFG" kubernetes label "$AM_I")" = "$SOC_AM_KUBERNETES_TARGET" ]; then AM_INDEX=$AM_I; AM_MATCHES=$((AM_MATCHES+1)); fi
    AM_I=$((AM_I+1))
  done
  [ "$AM_MATCHES" -eq 1 ] || { echo 'Kubernetes target must match exactly once'; exit 1; }
else
  [ "$AM_KIND" = map ] && [ "$AM_COUNT" -eq 1 ] || { echo 'Unsupported Kubernetes target shape'; exit 1; }
fi
AM_CONFIGURED_CONTEXT=$(sh "$AM_TT" "$AM_CFG" kubernetes get "$AM_INDEX" context)
[ -n "$AM_CONFIGURED_CONTEXT" ] && [ "$AM_CONTEXT" = "$AM_CONFIGURED_CONTEXT" ] || { echo 'Context differs from the selected toolkit target'; exit 1; }
am_read_json() {
  AM_RAW=$(kubectl --context "$AM_CONTEXT" -n "$AM_NS" "$@" 2>/dev/null) || { echo 'Kubernetes read failed; stop without using its output' >&2; return 1; }
  printf '%s' "$AM_RAW" | python3 -c '
import json,sys
def pairs(items):
 out={}
 for k,v in items:
  if k in out: raise ValueError()
  out[k]=v
 return out
try:
 raw=sys.stdin.read(); assert len(raw)<=16777216
 x=json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
 assert isinstance(x,dict)
 if sys.argv[2]=="get":
  resource=sys.argv[3]
  if resource=="secrets":
   assert x.get("kind") in ("List","SecretList") and isinstance(x.get("items"),list)
  else:
   expected={"statefulset":"StatefulSet","configmap":"ConfigMap","secret":"Secret","pod":"Pod"}[resource]
   assert x.get("kind")==expected and x["metadata"]["name"]==sys.argv[4] and x["metadata"]["namespace"]==sys.argv[1]
 print(json.dumps(x,separators=(",",":"),allow_nan=False))
except Exception:
 print("Invalid or incomplete Kubernetes JSON; output withheld",file=sys.stderr);sys.exit(1)' "$AM_NS" "$@"
}
AM_VIEW=$(am_read_json config view --minify -o json) || exit 1
printf '%s' "$AM_VIEW" | jq -e --arg context "$AM_CONTEXT" '.["current-context"] == $context and (.contexts | length == 1) and .contexts[0].name == $context' >/dev/null
unset AM_VIEW
AM_STS="${SOC_AM_STATEFULSET:?Set approved StatefulSet}"
AM_DIR="${SOC_AM_PRIVATE_DIR:?Set protected deployment-store directory}"
AM_CM="${SOC_AM_ORIGINAL_CONFIGMAP:?Set preserved ConfigMap name}"
AM_ROLLBACK_SHA="${SOC_AM_ROLLBACK_SHA256:?Set approved inverse patch checksum}"
AM_ORIGINAL_SHA="${SOC_AM_ORIGINAL_CONFIG_SHA256:?Set original configuration checksum}"
AM_TIMEOUT="${SOC_AM_ROLLOUT_TIMEOUT:?Set approved bounded timeout}"
python3 - "$AM_DIR/restore.patch.json" "$AM_ROLLBACK_SHA" <<'PY_RESTORE'
import hashlib,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); s=p.lstat()
assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and not s.st_mode & 0o077
assert hashlib.sha256(p.read_bytes()).hexdigest()==sys.argv[2], 'Inverse changed after confirmation'
PY_RESTORE
AM_OBJECT=$(am_read_json get configmap "$AM_CM" -o json) || exit 1
printf '%s' "$AM_OBJECT" | python3 -c 'import hashlib,json,sys; x=json.load(sys.stdin); assert hashlib.sha256(x["data"]["alertmanager.yml"].encode()).hexdigest()==sys.argv[1]' "$AM_ORIGINAL_SHA"
kubectl --context "$AM_CONTEXT" -n "$AM_NS" patch statefulset "$AM_STS" --type=json --patch-file "$AM_DIR/restore.patch.json" >/dev/null 2>&1
AM_OBJECT=$(am_read_json get statefulset "$AM_STS" -o json) || exit 1
printf '%s' "$AM_OBJECT" | jq -e --arg cm "$AM_CM" '[.spec.template.spec.volumes[] | select(.configMap.name == $cm)] | length == 1' >/dev/null
kubectl --context "$AM_CONTEXT" -n "$AM_NS" rollout status "statefulset/$AM_STS" --timeout "$AM_TIMEOUT"
echo 'Original mount restored; repeat readiness, loaded fingerprint and original receiver assertions.'
```

For restoration, repeat the readiness, owner, mounted fingerprint and fresh reload assertions with the original checksum, fresh pod and restoration timestamp. The route assertion for the selected source now expects only the original receiver; compare every affected label set to its saved baseline. Do not run the forward two-receiver expectation against the restored configuration. Restore your maintained overlay as well. Only after proving no pod or workload template references the owned Secret may you retire that exact Secret using your approved secret-management procedure. Do not delete by prefix, remove the original ConfigMap or use a Helm reinstall as rollback. Record unresolved delivery or state-loss effects separately from successful configuration restoration.
