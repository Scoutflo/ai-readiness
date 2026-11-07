#!/bin/sh
# Fixed local judgment worklist. No provider calls and no credentials in receipts.
set -eu
set +x
. "${CLAUDE_PLUGIN_ROOT}/skills/audit-clickstack/scripts/target-context.sh"
export PYTHONDONTWRITEBYTECODE=1
CS_WL_CH_KEY=$(cs_secret clickhouse_password_env CH_KEY)
CS_WL_HDX_KEY=$(cs_secret hyperdx_api_key_env HDX_API_KEY)
CS_WL_HDX_EMAIL=$(cs_secret hyperdx_email_env HDX_EMAIL)
CS_WL_HDX_PASSWORD=$(cs_secret hyperdx_password_env HDX_PASSWORD)
CS_WL_NAMES=$(for field in clickhouse_password_env hyperdx_api_key_env hyperdx_email_env hyperdx_password_env; do sh "$TT" "$CFG" clickstack get "$CS_IDX" "$field"; done)
export CS_WL_CH_KEY CS_WL_HDX_KEY CS_WL_HDX_EMAIL CS_WL_HDX_PASSWORD CS_WL_NAMES CH_URL CH_USER HDX_URL
umask 077
python3 - "${1:-check}" "$CS_OUT" "$CS_SEG" "${2:-50}" <<'PY'
import datetime,fcntl,hashlib,hmac,json,os,pathlib,re,stat,sys,tempfile
class Blocked(Exception): pass
def need(value):
    if not value: raise Blocked()
def pairs(items):
    out={}
    for k,v in items: need(k not in out); out[k]=v
    return out
def read(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_size<=8388608)
    return json.loads(path.read_text(),object_pairs_hook=pairs)
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def canon(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()
def safe(value):
    secrets=[os.environ.get(k,'') for k in ('CS_WL_CH_KEY','CS_WL_HDX_KEY','CS_WL_HDX_PASSWORD')]
    return isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}',value) and not re.search(r'(?i)(?:token|secret|password|credential|api[-_]?key|X-VO-Api-(?:Id|Key))[:=]',value) and not any(len(k)>=4 and k in value for k in secrets)
def recent(value):
    at=datetime.datetime.strptime(value,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    need(0<=(datetime.datetime.now(datetime.timezone.utc)-at).total_seconds()<=86400)
    return at
def validate_proof(value,claimed,runid,binding):
    need(isinstance(value,dict) and set(value)=={'run_id','binding_sha256','objects','checks'})
    need(value['run_id']==runid and value['binding_sha256']==hashlib.sha256(canon(binding)).hexdigest())
    objects=value['objects'];checks=value['checks'];need(isinstance(objects,list) and isinstance(checks,list) and checks)
    need(all(isinstance(v,dict) and set(v)=={'kind','id'} and isinstance(v['kind'],str) and safe(v['id']) for v in objects))
    need(claimed and {(r['kind'],r['id']) for r in objects}==claimed and len(objects)==len(claimed))
    need(all(isinstance(v,dict) and set(v)=={'id','result'} and isinstance(v['id'],str) and re.fullmatch(r'CS-[0-9]{3}',v['id']) and v['result'] in ('pass','partial','fail','blocked','not-in-scope') for v in checks))
    ids={v['id'] for v in checks};need(len(ids)==len(checks))
    required=set()
    for kind,_ in claimed:required.update({'service':{'CS-010','CS-011'},'alert':{'CS-040'},'dashboard':{'CS-041'},'source':{'CS-041'}}[kind])
    need(required<=ids)
try:
    mode,out,target,arg=sys.argv[1:];out=pathlib.Path(out).resolve();raw=out/'raw';day=out.name
    need(re.fullmatch(r'clickstack(?:/[A-Za-z0-9_-]+)?',target))
    scopepath=raw/'assessment-scope.json';scope=read(scopepath)
    need(set(scope)=={'target','observed_at','declared_by','evidence_ref','services','capture_refs'} and scope['target']==target)
    need(recent(scope['observed_at']).strftime('%Y-%m-%d')==day and safe(scope['declared_by']))
    need(isinstance(scope['services'],list) and all(safe(v) for v in scope['services']) and len(set(scope['services']))==len(scope['services']))
    ref=scope['evidence_ref'];need(isinstance(ref,str) and re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\.(?:json|md)',ref) and '..' not in ref.split('/'))
    evidence=out/ref;need(not evidence.is_symlink() and evidence.is_file() and out in evidence.resolve().parents)
    captures={'scope':digest(scopepath),'scope_evidence':digest(evidence)}
    refs=scope['capture_refs'];need(isinstance(refs,list) and len(refs)<=1000 and len(set(refs))==len(refs))
    need(not os.environ['CH_URL'] or refs)
    for ref in refs:
        need(isinstance(ref,str) and re.fullmatch(r'raw/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\.(?:json|md)',ref) and '..' not in ref.split('/'))
        capture=out/ref;need(capture.is_file() and not capture.is_symlink() and out in capture.resolve().parents and capture.stat().st_size<=8388608)
        captures[ref]=digest(capture)
    rows=[{'kind':'service','id':v,'status':'pending'} for v in scope['services']]
    if os.environ['HDX_URL']:
        hdxpath=raw/'hyperdx-configuration.json';hdx=read(hdxpath)
        need(hdx['schema']=='scoutflo-hyperdx-configuration/v1' and hdx['target']==target and recent(hdx['observed_at']).strftime('%Y-%m-%d')==day)
        captures['hyperdx']=digest(hdxpath)
        for surface,kind in (('alerts','alert'),('dashboards','dashboard'),('sources','source')):
            resource=hdx['resources'][surface];need(resource['status'] in ('complete','partial','blocked') and isinstance(resource['items'],list))
            ids=[v['id'] for v in resource['items']];need(all(safe(v) for v in ids) and len(set(ids))==len(ids))
            rows.extend({'kind':kind,'id':v,'status':'pending'} for v in ids)
    parent=out.parent;keypath=parent/'.assessment-key'
    try:
        fd=os.open(keypath,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:pass
    else:
        with os.fdopen(fd,'wb') as f:f.write(os.urandom(32))
    need(not keypath.is_symlink() and keypath.stat().st_uid==os.getuid() and stat.S_IMODE(keypath.stat().st_mode)==0o600)
    key=keypath.read_bytes();need(len(key)==32)
    secret_context=[os.environ[k] for k in ('CH_URL','CH_USER','HDX_URL','CS_WL_NAMES','CS_WL_CH_KEY','CS_WL_HDX_KEY','CS_WL_HDX_EMAIL','CS_WL_HDX_PASSWORD')]
    generation=hmac.new(key,canon([target,*secret_context]),hashlib.sha256).hexdigest()
    binding={'target':target,'run_date':day,'credential_generation':generation,'captures':captures}
    runs=parent/'runs';runs.mkdir(exist_ok=True);need(not runs.is_symlink())
    lockfd=os.open(runs/'.assessment.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    need(os.fstat(lockfd).st_uid==os.getuid() and stat.S_IMODE(os.fstat(lockfd).st_mode)==0o600)
    with os.fdopen(lockfd,'a+') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        found=[]
        for path in runs.glob('*/clickstack-worklist.json'):
            value=read(path)
            if value.get('binding')==binding:found.append((path,value))
        if found:path,state=sorted(found,key=lambda x:str(x[0]))[-1]
        else:
            runid=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'-'+captures['scope'][:8]
            path=runs/runid/'clickstack-worklist.json';state={'schema':'scoutflo-clickstack-assessment/v1','run_id':runid,'binding':binding,'rows':rows}
        need(state.get('schema')=='scoutflo-clickstack-assessment/v1' and isinstance(state.get('rows'),list))
        expected={(r['kind'],r['id']) for r in rows}
        need(all(isinstance(r,dict) and isinstance(r.get('kind'),str) and safe(r.get('id')) and r.get('status') in ('pending','claimed','done') for r in state['rows']))
        need({(r['kind'],r['id']) for r in state['rows']}==expected and len(state['rows'])==len(expected))
        need(state.get('run_id')==path.parent.name)
        if mode=='check':
            need(path.exists() and all(r['status']=='done' for r in state['rows']))
            for row in state['rows']:
                proof=out/row['evidence_ref'];need(proof.is_file() and not proof.is_symlink() and out in proof.resolve().parents and digest(proof)==row['evidence_sha256'])
                peers={(r['kind'],r['id']) for r in state['rows'] if r.get('evidence_ref')==row['evidence_ref']}
                validate_proof(read(proof),peers,state['run_id'],binding)
            print('ClickStack assessment worklist complete; collection completeness is separate.');sys.exit(0)
        if mode=='claim':
            n=int(arg);need(1<=n<=1000)
            selected=[r for r in state['rows'] if r['status']=='claimed'] or [r for r in state['rows'] if r['status']=='pending'][:n]
            for row in selected:row['status']='claimed'
            print(json.dumps({'run_id':state['run_id'],'run_date':day,'binding_sha256':hashlib.sha256(canon(binding)).hexdigest(),'objects':[{'kind':r['kind'],'id':r['id']} for r in selected]},sort_keys=True))
        elif mode=='done':
            proof=pathlib.Path(arg);need(proof.is_file() and not proof.is_symlink());proof=proof.resolve();need(out in proof.parents)
            claimed={(r['kind'],r['id']) for r in state['rows'] if r['status']=='claimed'}
            validate_proof(read(proof),claimed,state['run_id'],binding)
            for row in state['rows']:
                if (row['kind'],row['id']) in claimed:row.update(status='done',evidence_ref=str(proof.relative_to(out)),evidence_sha256=digest(proof))
            print('Recorded exact completed ClickStack assessment batch.')
        else:need(mode=='init')
        path.parent.mkdir(exist_ok=True)
        fd,temp=tempfile.mkstemp(dir=path.parent,prefix='.worklist-')
        with os.fdopen(fd,'wb') as f:f.write(canon(state)+b'\n')
        os.chmod(temp,0o600);os.replace(temp,path)
        if mode=='init':print(str(path))
except Exception:
    print('ClickStack assessment blocked: current scope/capture, credential binding, lock or exact assessment proof is unavailable.',file=sys.stderr);sys.exit(2)
PY
