#!/usr/bin/env python3
"""Durable namespace recipe: atomic batch lock and safe projected captures only."""
import datetime, hashlib, importlib.util, json, os, re, socket, sys, tempfile
from pathlib import Path
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('reader',Path(__file__).with_name('topology-read.py'));reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)

def atomic(path,data):
    fd,tmp=tempfile.mkstemp(prefix='.topology-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:f.write(data)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def read_rows(path):
    rows=[line.split('\t') for line in (path/'worklist.tsv').read_text().splitlines()]
    if not rows or any(len(r)!=2 or r[1] not in {'pending','done'} or not re.fullmatch(r'[a-z0-9][a-z0-9-]*',r[0]) for r in rows) or len({r[0] for r in rows})!=len(rows):raise ValueError('invalid namespace worklist')
    return rows

def main():
    command=sys.argv[1];root=Path(os.environ['MAP_ROOT'])/'map-topology';root.mkdir(parents=True,exist_ok=True)
    identity={k:os.environ[k] for k in ['MAP_TARGET','KUBE_CONTEXT','NS_EXCLUDE']}
    active=root/'active-run';explicit=os.environ.get('SCOUTFLO_TOPOLOGY_RUN_DIR')
    path=Path(explicit) if explicit else Path(active.read_text().strip()) if active.exists() else None
    if command=='init' and os.environ.get('SCOUTFLO_TOPOLOGY_NEW_RUN')=='1':
        if path and (path/'worklist.tsv').exists() and any(line.endswith('\tpending') for line in (path/'worklist.tsv').read_text().splitlines()):raise ValueError('unfinished run exists; resume it before starting another')
        if path and (path/'worklist.lock').exists():raise ValueError('run is locked')
        path=None
    if command=='init' and path is None:
        data=reader.read('namespace',[]);ex=re.compile(identity['NS_EXCLUDE']);names=sorted(x['metadata']['name'] for x in data['items'] if not ex.search(x['metadata']['name']))
        if not names:raise ValueError('no in-scope namespaces; do not certify an empty worklist')
        run=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%f')+'Z'
        path=root/'runs'/run;path.mkdir(parents=True,exist_ok=False);(path/'raw').mkdir()
        atomic(path/'identity.json',json.dumps(identity));atomic(path/'worklist.tsv',''.join(n+'\tpending\n' for n in names));atomic(active,str(path.resolve())+'\n')
    if path is None or not (path/'worklist.tsv').is_file():raise ValueError('selected run missing; run Worklist build and resume first')
    if json.loads((path/'identity.json').read_text())!=identity:raise ValueError('run identity or namespace scope changed; select the matching run')
    rows=read_rows(path)
    lock=path/'worklist.lock'
    if command=='path':print(path);return
    if command=='lock-status':
        if lock.exists():raise ValueError('run is locked; verify the recorded process before manual stale-lock recovery')
        print('batch lock available; batch execution acquires it atomically');return
    if command=='batch':
        lock.mkdir()  # Atomic. Never reclaim a potentially live worker based on age.
        try:
            # A worker may have completed after our preliminary read, before
            # this lock was acquired. Select pending work from current state.
            rows=read_rows(path)
            (lock/'owner.json').write_text(json.dumps({'pid':os.getpid(),'host':socket.gethostname()}))
            size=int(os.environ.get('SCOUTFLO_TOPOLOGY_BATCH_SIZE','10'))
            if not 1<=size<=100:raise ValueError('batch size must be 1..100; tune within the bounded namespace recipe')
            kinds=os.environ.get('SCOUTFLO_TOPOLOGY_KINDS','deployment statefulset daemonset service endpoints ingress').split()
            if not kinds or len(kinds)!=len(set(kinds)):raise ValueError('invalid capture kind list')
            old=path/'kinds.json'
            if old.exists() and json.loads(old.read_text())!=kinds:raise ValueError('capture kinds changed during run')
            if not old.exists():atomic(old,json.dumps(kinds))
            pending=[r for r in rows if r[1]=='pending'][:size]
            for row in pending:
                digests={}
                for kind in kinds:
                    safe=reader.read(kind,['-n',row[0]])
                    filename=row[0]+'.'+kind+'.json';body=json.dumps(safe,allow_nan=False)
                    atomic(path/'raw'/filename,body);digests[filename]=hashlib.sha256(body.encode()).hexdigest()
                atomic(path/'raw'/(row[0]+'.receipt.json'),json.dumps(digests))
                row[1]='done';atomic(path/'worklist.tsv',''.join('\t'.join(r)+'\n' for r in rows))
                print('done: '+row[0])
        finally:
            (lock/'owner.json').unlink(missing_ok=True);lock.rmdir()
    if command=='complete':
        if lock.exists() or any(r[1]!='done' for r in rows):raise ValueError('worklist pending or batch locked; do not publish')
        kinds=json.loads((path/'kinds.json').read_text())
        for ns,_ in rows:
            receipt=json.loads((path/'raw'/(ns+'.receipt.json')).read_text())
            if set(receipt)!={ns+'.'+k+'.json' for k in kinds}:raise ValueError('capture receipt misses a declared kind')
            for name,digest in receipt.items():
                if hashlib.sha256((path/'raw'/name).read_bytes()).hexdigest()!=digest:raise ValueError('capture file changed or missing')
        print('worklist pending: 0');return
    if command not in {'init','status','batch'}:raise ValueError('unsupported worklist command')
    print('run: '+str(path));print('done='+str(sum(r[1]=='done' for r in rows))+' pending='+str(sum(r[1]=='pending' for r in rows)))

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError) as error:raise SystemExit('TOPOLOGY-WORKLIST-BLOCKED: '+str(error))
