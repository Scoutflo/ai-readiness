#!/bin/sh
# Local large-estate judgment batches; provider captures remain fixed full reads.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-datadog/scripts/datadog-context.sh"
dd_require monitors.json monitor-quality.json downtimes.json
if [ -f "$RAW_DIR/slos.json" ]; then dd_require slos.json; fi
umask 077
python3 - "${1:-check}" "$TARGET_DIR" "$RAW_DIR" "${2:-50}" <<'PY'
import datetime,hashlib,json,os,pathlib,sys
mode,target,raw,arg=sys.argv[1:]; target,raw=pathlib.Path(target),pathlib.Path(raw)
meta=json.loads((raw/'monitors.json.capture.json').read_text()); monitors=json.loads((raw/'monitors.json').read_text())
binding={k:meta[k] for k in ('source_target','source_site','credential_generation','run_date')}
binding['captures']={name:json.loads((raw/(name+'.json.capture.json')).read_text()) for name in ('monitors','monitor-quality','downtimes','slos') if (raw/(name+'.json')).exists()}
runs=target/'runs'; runs.mkdir(exist_ok=True)
lock=runs/'.assessment-lock'
try: lock.mkdir()
except FileExistsError: sys.exit('Assessment worklist is locked; inspect the active owner before retrying.')
try:
    matches=[]
    for f in runs.glob('*/datadog-worklist.json'):
        value=json.loads(f.read_text())
        if value.get('binding')==binding: matches.append((f,value))
    if matches: path,state=sorted(matches,key=lambda x:str(x[0]))[-1]
    else:
        run_id=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+meta['evidence_sha256'][:8]
        path=runs/run_id/'datadog-worklist.json'
        state={'schema':'scoutflo-datadog-assessment/v1','run_id':run_id,'binding':binding,'rows':[{'monitor_id':str(m['id']),'status':'pending'} for m in monitors]}
    if mode=='check':
        large=len(monitors)>int(os.environ.get('MEDIUM_MAX_OBJECTS','150'))
        if large or path.exists():
            assert path.exists() and all(v['status']=='done' for v in state['rows']), 'pending or missing large-estate assessment rows'
            for row in state['rows']:
                proof=raw.parent/row['evidence_ref']; assert proof.is_file() and hashlib.sha256(proof.read_bytes()).hexdigest()==row['evidence_sha256'], 'assessment proof missing or changed'
        print('Assessment worklist complete or small-estate path.'); sys.exit(0)
    if mode=='claim':
        n=int(arg); assert 1<=n<=1000
        # Interrupted claims are offered unchanged; never abandon them for a new batch.
        selected=[r for r in state['rows'] if r['status']=='claimed'] or [r for r in state['rows'] if r['status']=='pending'][:n]
        for r in selected: r['status']='claimed'
        print(json.dumps({'run_id':state['run_id'],'run_date':meta['run_date'],'monitor_ids':[r['monitor_id'] for r in selected]}))
    elif mode=='done':
        proof=pathlib.Path(arg).resolve(); assert proof.is_file() and raw.parent.resolve() in proof.parents and not proof.is_symlink()
        data=json.loads(proof.read_text()); claimed={r['monitor_id'] for r in state['rows'] if r['status']=='claimed'}
        assert claimed and set(data)=={'monitor_ids','checks'} and set(data['monitor_ids'])==claimed
        assert isinstance(data['checks'],list) and data['checks'] and all(set(v)=={'id','result'} and v['result'] in ('pass','partial','fail','blocked','not-in-scope') for v in data['checks'])
        for r in state['rows']:
            if r['monitor_id'] in claimed: r.update(status='done',evidence_ref=str(proof.relative_to(raw.parent.resolve())),evidence_sha256=hashlib.sha256(proof.read_bytes()).hexdigest())
        print('Recorded completed assessment batch.')
    elif mode!='init': raise ValueError('unknown worklist operation')
    path.parent.mkdir(exist_ok=True)
    temp=path.with_suffix('.tmp'); temp.write_text(json.dumps(state,sort_keys=True)+'\n'); temp.chmod(0o600); temp.replace(path)
    if mode=='init': print(str(path))
finally: lock.rmdir()
PY
