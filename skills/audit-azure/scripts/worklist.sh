#!/bin/sh
# Local-only Azure batch state. It never invokes a provider or a transport.
set -eu
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-azure/scripts/read-context.sh"
export AZ_LABEL SUB RUN_DATE TARGET_DIR RAW_DIR AZ_RUN_ID AZ_RUN_DIR
python3 - "$@" <<'PY'
import hashlib,json,os,pathlib,sys,uuid
p=pathlib.Path; e=os.environ; target=p(e['TARGET_DIR']); command=sys.argv[1]
target.mkdir(parents=True,exist_ok=True)
lock=target/'.worklist.lock'
try: lock.mkdir()
except FileExistsError: sys.exit('Azure worklist locked: wait for the other local operation; reclaim only after confirming it stopped')
def save(path,value):
    tmp=path.with_name(path.name+'.tmp'); tmp.write_text(json.dumps(value,sort_keys=True)+'\n'); tmp.chmod(0o600); tmp.replace(path)
try:
    active=target/'.active-run'
    if command=='start' and not active.exists():
        # Never strand pending state by inventing another run after a lost pointer.
        pending=[]
        for f in (target/'runs').glob('*/worklist.json'):
            data=json.loads(f.read_text())
            if not data.get('published'): pending.append(f)
        if len(pending)>1: sys.exit('Several unfinished runs: choose one explicitly before continuing')
        if pending:
            active.write_text(pending[0].parent.name+'\n')
        else:
            raw=p(e['RAW_DIR']); items=[]
            if (raw/'.inventory-pending').exists(): sys.exit('Incomplete inventory cannot seed a worklist')
            for kind in ('vms','vmss','app-gateways','load-balancers'):
                for item in json.loads((raw/(kind+'.json')).read_text()):
                    items.append(dict(id=item['id'],name=item['name'],kind=kind,state='pending'))
            ids=[x['id'].lower() for x in items]
            if len(ids)!=len(set(ids)): sys.exit('Duplicate resource identity in inventory')
            run=target/'runs'/uuid.uuid4().hex; run.mkdir(parents=True); run.chmod(0o700)
            # Only the inventory's already projected JSON is copied.
            (run/'raw').mkdir()
            for f in raw.glob('*.json'): (run/'raw'/f.name).write_bytes(f.read_bytes())
            save(run/'worklist.json',dict(target=e['AZ_LABEL'],subscription_config=e['SUB'],run_date=e['RUN_DATE'],items=items,published=False))
            active.write_text(run.name+'\n')
    if not active.exists():
        unfinished=[f for f in (target/'runs').glob('*/worklist.json') if not json.loads(f.read_text()).get('published')]
        if unfinished: sys.exit('Azure blocked: unfinished run lost its pointer; run start to recover before publishing')
        if command in ('assert','finish'): sys.exit(0)
        sys.exit('No active worklist; run start after complete inventory')
    run=target/'runs'/active.read_text().strip(); path=run/'worklist.json'; data=json.loads(path.read_text())
    if data['target']!=e['AZ_LABEL'] or data['subscription_config']!=e['SUB']: sys.exit('Worklist target mismatch')
    owner=e.get('SCOUTFLO_AZURE_WORKER','')
    if command in ('claim','done','release') and not owner: sys.exit('Set SCOUTFLO_AZURE_WORKER to a stable token for this operator')
    if command=='claim':
        batch=int(e.get('BATCH_SIZE','10'))
        if not 1<=batch<=100: sys.exit('BATCH_SIZE must be 1..100')
        claimed=[x for x in data['items'] if x['state']=='claimed']
        if any(x.get('owner')!=owner for x in claimed): sys.exit('Another worker owns this batch; do not duplicate reads')
        if not claimed:
            for item in [x for x in data['items'] if x['state']=='pending'][:batch]: item.update(state='claimed',owner=owner)
    elif command=='done':
        resource,receipt=sys.argv[2:]; receipt=p(receipt).resolve()
        if receipt.parent!= (run/'raw').resolve(): sys.exit('Receipt is outside this run')
        proof=json.loads(receipt.read_text())
        rows=[x for x in data['items'] if x['id']==resource and x['state']=='claimed' and x.get('owner')==owner]
        if len(rows)!=1 or proof.get('resource_id')!=resource: sys.exit('Read receipt or claimed resource mismatch')
        required=['diagnostic_settings']+(['extensions'] if rows[0]['kind'] in ('vms','vmss') else [])
        statuses=proof.get('read_status',{})
        for field in required:
            if statuses.get(field)=='complete' and isinstance(proof.get(field),list): continue
            if statuses.get(field)=='blocked' and proof.get(field) is None and proof.get('reason'): continue
            sys.exit('Missing success or explicit blocked-read evidence')
        blocked=any(statuses[x]=='blocked' for x in required)
        if proof.get('result')!=('blocked' if blocked else 'examined'): sys.exit('Read disposition contradicts receipt')
        rows[0].update(state='blocked' if blocked else 'done',receipt=receipt.name,sha256=hashlib.sha256(receipt.read_bytes()).hexdigest())
    elif command=='release':
        # Explicit attended recovery after this worker stopped; completed rows are untouched.
        for item in data['items']:
            if item['state']=='claimed' and item.get('owner')==owner: item.update(state='pending',owner='')
    elif command in ('assert','finish'):
        if any(x['state'] not in ('done','blocked') for x in data['items']): sys.exit('Azure blocked: worklist incomplete; do not publish a partial report')
        for item in data['items']:
            if hashlib.sha256((run/'raw'/item['receipt']).read_bytes()).hexdigest()!=item['sha256']: sys.exit('Read receipt changed since completion')
        if command=='finish': data['published']=True; active.unlink()
    elif command not in ('start','status'): sys.exit('Unknown worklist command')
    save(path,data)
    if command=='claim':
        for item in data['items']:
            if item['state']=='claimed' and item.get('owner')==owner: print(json.dumps(item))
    else: print(json.dumps(dict(run_id=run.name,done=sum(x['state']=='done' for x in data['items']),blocked=sum(x['state']=='blocked' for x in data['items']),pending=sum(x['state'] not in ('done','blocked') for x in data['items']))))
finally: lock.rmdir()
PY
