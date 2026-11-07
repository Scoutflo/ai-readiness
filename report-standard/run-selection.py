#!/usr/bin/env python3
"""Bind an orchestrated run to completed local artifact generations; no provider IO."""
import datetime as dt, fcntl, hashlib, json, os, pathlib, re, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parent
NAMES=('findings.json','inventory.json','report.md')
def fail(message): raise ValueError(message)
def utc(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z',value): fail('Invalid UTC timestamp')
    stamp=dt.datetime.fromisoformat(value.replace('Z','+00:00'))
    if stamp>dt.datetime.now(dt.timezone.utc): fail('Future generation')
    return stamp
def target(value):
    return isinstance(value,str) and bool(re.fullmatch(r'[a-z0-9_-]+(/[A-Za-z0-9_.-]+)?',value)) and all(p not in {'.','..'} for p in value.split('/')) and value.split('/')[0] not in {'all','cost','cost-analysis','doctor','alert-fatigue'}
def read(path,limit=16*1024*1024):
    if path.is_symlink() or not path.is_file() or path.stat().st_size>limit: fail('Missing, symlink or oversized run artifact')
    return path.read_bytes()
def unique(pairs):
    out={}
    for k,v in pairs:
        if k in out:fail('Duplicate JSON field')
        out[k]=v
    return out
def load(path,limit=16*1024*1024):return json.loads(read(path,limit),object_pairs_hook=unique,parse_constant=lambda _:fail("Nonfinite JSON value"))
def digest(path):return hashlib.sha256(read(path)).hexdigest()
def plan_for(base,day):
    path=base/'run-plan.json'
    if not path.exists() and not path.is_symlink():return None
    p=load(path,1024*1024)
    if p.get('schema')!='scoutflo-audit-plan/v1':fail('Invalid run plan schema')
    date=p.get('audit_date');started=p.get('started_at');utc(started)
    if not isinstance(date,str) or started[:10]!=date:fail('Run start/date mismatch')
    ts=p.get('targets');done=p.get('completed_targets',[]);receipts=p.get('completion_receipts',{})
    if not isinstance(ts,list) or not 1<=len(ts)<=256 or not all(map(target,ts)) or len(set(ts))!=len(ts):fail('Invalid selected targets')
    if not isinstance(done,list) or not all(map(target,done)) or len(set(done))!=len(done) or not set(done)<=set(ts):fail('Invalid completed targets')
    if not isinstance(receipts,dict) or set(receipts)!=set(done):fail('Completion receipt mismatch')
    if date!=day:return None # Explicit historical standalone reads retain their date.
    for t in done:
        r=receipts[t]
        if not isinstance(r,dict):fail('Invalid completion receipt')
        utc(r.get('completed_at'));artifacts=r.get('artifacts')
        if not isinstance(artifacts,dict) or not set(NAMES)<=set(artifacts) or not set(artifacts)<=set(NAMES+('oncall-history.json',)):fail('Incomplete completion receipt')
        for name,h in artifacts.items():
            if not isinstance(h,str) or not re.fullmatch('[0-9a-f]{64}',h) or digest(base/t/day/name)!=h:fail('Completed artifact drift; revalidate and record completion')
        if utc(r['completed_at'])<utc(started):fail('Completion precedes run start')
    return p
def complete(base,day,t):
    if not target(t):fail('Invalid target')
    # Existing drift must be reviewed; never silently re-sign a changed completion.
    p=plan_for(base,day)
    if p is None or t not in p['targets']:fail('Target is not in the current selected queue')
    dest=base/t/day
    f=load(dest/'findings.json');i=load(dest/'inventory.json')
    for doc in (f,i):
        utc(doc.get('generated_at'))
        if doc.get('target')!=t or doc['generated_at'][:10]!=day or utc(doc['generated_at'])<utc(p['started_at']):fail('Artifact target/date/generation does not match this run')
    if f.get('run_date')!=day or i.get('schema')!='scoutflo-inventory/v1':fail('Findings/inventory envelope mismatch')
    for doc in (f,i):
        if "collection" not in doc:continue # Legacy completion is not collection completeness.
        c=doc['collection']
        utc(c.get('observed_at'))
        if utc(c['observed_at'])<utc(p['started_at']) or utc(c['observed_at'])>utc(doc['generated_at']):fail('Collection predates selected run or follows generation')
    report=read(dest/'report.md').decode()
    for field,expected in [('Target',t),('Date',day)]:
        rows=re.findall(r'^\|\s*'+field+r'\s*\|\s*([^|]+)\|',report,re.M)
        actual=rows[0].strip().strip('`') if len(rows)==1 else None
        allowed={expected,expected+' (UTC)'} if field=='Date' else {expected}
        if actual not in allowed:fail('Report header does not match target/date')
    before={n:digest(dest/n) for n in NAMES}
    for script,name in [('check-findings.sh','findings.json'),('check-correlation-evidence.sh','inventory.json'),('check-report.sh','report.md')]:
        result=subprocess.run(['sh',str(ROOT/script),str(dest/name)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
        if result.returncode:fail('Run completion validation failed: '+script)
    if before!={n:digest(dest/n) for n in NAMES}:fail('Artifacts changed during validation')
    history=dest/'oncall-history.json'
    if history.exists():
        h=load(history);utc(h.get('generated_at'))
        if h.get('target')!=t or h['generated_at'][:10]!=day or utc(h['generated_at'])<utc(p['started_at']):fail('Native history does not belong to this target/run generation')
        before['oncall-history.json']=digest(history)
    p.setdefault('completed_targets',[])
    if t not in p['completed_targets']:p['completed_targets'].append(t)
    p.setdefault('completion_receipts',{})[t]={'completed_at':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),'artifacts':before}
    fd,tmp=tempfile.mkstemp(prefix='.run-plan-',dir=base)
    try:
        with os.fdopen(fd,'w') as out:json.dump(p,out,indent=2);out.write('\n')
        os.replace(tmp,base/'run-plan.json')
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
    print('RUN-COMPLETION-OK: '+t)
def main():
    if len(sys.argv)<4:fail('Use snapshot|complete ROOT DATE [TARGET]')
    command,base,day=sys.argv[1:4];base=pathlib.Path(base)
    if re.search(r'[\x00-\x1f]',str(base)):fail('Audit root contains control characters')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}',day):fail('Invalid selected run date')
    if command=='complete':
        lock=base/'.run-plan.lock'
        if lock.is_symlink():fail('Unsafe run plan lock')
        fd=os.open(lock,os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0),0o600)
        try:
            deadline=time.monotonic()+5
            while True:
                try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);break
                except BlockingIOError:
                    if time.monotonic()>deadline:fail('Run completion is busy; retry after the active writer finishes')
                    time.sleep(.05)
            complete(base,day,sys.argv[4])
        finally:os.close(fd)
        return
    if command=='verify-file':
        path=pathlib.Path(sys.argv[4]);expected=sys.argv[5]
        if digest(path)!=expected:fail('Completed artifact drift before read')
        return
    if command=='coverage-plan':
        p=plan_for(base,day)
        if p is None:fail('Coverage requires the canonical current run plan')
        print(json.dumps({'schema':'scoutflo-coverage-assessment/v1','audit_date':day,'expected_targets':p['targets']}));return
    if command!='snapshot':fail('Unknown run selection command')
    p=plan_for(base,day)
    print(json.dumps({'mode':'legacy'} if p is None else {'mode':'selected','started_at':p['started_at'],'targets':p['targets'],'completed_targets':p.get('completed_targets',[]),'completion_receipts':p.get('completion_receipts',{})}))
if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,IndexError,TypeError,subprocess.TimeoutExpired) as exc:
        print('RUN-SELECTION-FAIL: '+str(exc),file=sys.stderr);sys.exit(1)
