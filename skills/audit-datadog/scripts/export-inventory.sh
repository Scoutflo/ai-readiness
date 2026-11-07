#!/bin/sh
# Canonical catalog from the credential-bound safe capture. No identity is invented.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json monitor-quality.json downtimes.json
if [ -f "$RAW_DIR/slos.json" ]; then dd_require slos.json; fi
umask 077
python3 - "$RAW_DIR" "$OUT" "$DD_SEG" <<'PY'
import collections,datetime,json,pathlib,sys
p,out,target=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]),sys.argv[3]
items=[]
for surface,kind in [('monitors','monitor'),('slos','slo'),('downtimes','downtime')]:
    f=p/(surface+'.json')
    if not f.exists(): continue
    for v in json.loads(f.read_text()):
        services=[t[8:] for t in v.get('tags',[]) if t.startswith('service:')]
        item={'name':v.get('name') or kind+'-'+str(v['id']),'kind':kind,'covers':services[0] if len(services)==1 else '-','severity':None,'attrs':{'source_id':str(v['id']),'evidence_ref':'raw/'+surface+'.json'}}
        if kind=='monitor':
            item['routes_to']='unknown'
            if v.get('draft_status')!='published': item['enabled']=False
            # A published monitor with unresolved destination/suppression is not proof
            # of active cross-tool coverage. Keep activation unknown until verified.
        items.append(item)
now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
collection={'status':'partial','scope':'subset','observed_at':now,'reason':'Monitor total reconciled; SLO/downtime page termination has no independently reconciled totals. Full catalog absence remains unproven.'}
inventory={'schema':'scoutflo-inventory/v1','target':target,'generated_at':now,'collection':collection,'counts':{'total':len(items),'by_kind':dict(collections.Counter(v['kind'] for v in items))},'items':items}
(out/'inventory.json').write_text(json.dumps(inventory,indent=2,sort_keys=True)+'\n')
(p/'collection.json').write_text(json.dumps(collection,sort_keys=True)+'\n')
for f in (out/'inventory.json',p/'collection.json'): f.chmod(0o600)
PY
dd_stamp collection.json
