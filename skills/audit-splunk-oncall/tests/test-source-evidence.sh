#!/bin/sh
# Real fixed binder/evaluator, synthetic sources, no provider or network calls.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy, datetime as dt, hashlib, json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); helper=root/'skills/audit-splunk-oncall/scripts/source-evidence.sh'
passed=0
def canonical(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
def sha(v): return hashlib.sha256(canonical(v)).hexdigest()
def assert_(condition,label):
    global passed
    if not condition: raise AssertionError(label)
    passed+=1
with tempfile.TemporaryDirectory() as tmp:
    work=pathlib.Path(tmp); os.chmod(work,0o700)
    bind=work/'bound.json'; source=work/'source.json'; capture=work/'capture.json'; mapping=work/'mapping.json'
    def write(p,v): p.write_bytes(canonical(v)); p.chmod(0o600)
    now=dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    cred={'api_id_env':'READ_ID','api_key_env':'READ_KEY','fingerprint':'a'*64}
    secrets={'GOOD_ROUTE':'private-good-value','BAD_ROUTE':'private-missing-value','AMBIG_ROUTE':'private-ambiguous-value'}
    routes={'routingKeys':[{'routingKey':'private-good-value','targets':[{'policySlug':'policy-one'}]},{'routingKey':'private-ambiguous-value','targets':[{'policySlug':'policy-one'}]},{'routingKey':'private-ambiguous-value','targets':[{'policySlug':'policy-one'}]}]}
    records=[]
    for rid,env,verified in [('good','GOOD_ROUTE','verified'),('missing','BAD_ROUTE','verified'),('candidate',None,'candidate'),('unmapped','GOOD_ROUTE','verified'),('ambiguous','AMBIG_ROUTE','verified')]:
        records.append({'record_id':rid,'source_id':'monitor-'+rid,'route_env':env,'route_verification':verified,'definition':{'source_id':'monitor-'+rid,'kind':'rule','receiver_id':'receiver-one','enabled':True,'destination_kind':'oncall-inbound'}})
    original={'schema':'scoutflo-alert-source-evidence/v1','producer':'audit-generic','source_provider':'generic','source_target':'generic/region-a','observed_at':now,'verification':{'kind':'api-read','status':'verified','evidence_ref':'capture.json'},'records':records}
    def emit(s):
        write(source,s)
        write(capture,{'schema':'scoutflo-alert-source-capture/v1',**{k:s[k] for k in ['producer','source_provider','source_target','observed_at']},'verification':{k:s['verification'][k] for k in ['kind','status']},'records_sha256':sha(s['records'])})
        write(mapping,{'schema':'scoutflo-oncall-source-mapping/v1','source_provider':s['source_provider'],'source_target':s['source_target'],'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'expected_oncall_target':'splunk_oncall/region-a','records':[{'record_id':r['record_id'],'expected_policy':'policy-one','expected_team':'team-one'} for r in s['records'] if r['record_id']!='unmapped']})
    def run(mode,path=source,target='splunk_oncall/region-a',key='private-read-key',cb=None,values=None,expected=0,extra=None):
        args=['/bin/sh',str(helper),mode,str(path)]
        if mode in ['bind','validate','match']: args.append(target)
        if mode=='bind': args.append(str(mapping))
        wire=(key+'\n').encode()+canonical(cb or cred)+b'\n'+canonical(secrets if values is None else values)+b'\n'
        if mode=='match': wire+=canonical(routes)
        result=subprocess.run(args,input=wire,capture_output=True,env=dict(os.environ,**(extra or {})),timeout=20)
        assert_(result.returncode==expected,mode+' exit '+str(result.returncode)+' '+result.stderr.decode())
        assert_(not any(x.encode() in result.stdout+result.stderr for x in ['private-read-key',*secrets.values()]),'no secrets in output')
        return json.loads(result.stdout) if expected==0 and mode not in ['source-vars','packet-vars'] else result
    emit(original)
    packet=run('bind'); write(bind,packet)
    assert_([r['status'] for r in packet['records']]==['bound','bound','blocked','blocked','bound'],'candidate and missing mapping remain blocked')
    assert_(all(r['binding_hmac'] is None for r in packet['records'] if r['status']=='blocked'),'no fabricated candidate binding')
    run('validate',bind)
    matches=run('match',bind)
    assert_(matches['records'][0]['route_aliases']==['route-1'] and matches['records'][1]['route_aliases']==[],'exact join retains no-match')
    assert_(len(matches['records'][4]['route_aliases'])==2,'ambiguity retained')
    # Baseline contains identical route/policy/team slugs across two accounts.
    run('validate',bind,target='splunk_oncall/region-b',expected=2)
    mutant=work/'target-guard-disabled.sh'
    mutated=helper.read_text().replace("p['expected_oncall_target']!=target or ","")
    assert_(mutated!=helper.read_text(),'target mutation applied')
    mutant.write_text(mutated)
    wire=b'private-read-key\n'+canonical(cred)+b'\n'+canonical(secrets)+b'\n'
    mutation=subprocess.run(['/bin/sh',str(mutant),'validate',str(bind),'splunk_oncall/region-b'],input=wire,capture_output=True,timeout=20)
    assert_(mutation.returncode==0,'same replay escapes the disabled selected-target guard')
    edited=copy.deepcopy(packet); edited['expected_oncall_target']='splunk_oncall/region-b'; write(bind,edited)
    run('validate',bind,target='splunk_oncall/region-b',expected=2)
    write(bind,packet)
    run('validate',bind,cb=dict(cred,fingerprint='b'*64),expected=2)
    run('validate',bind,key='rotated-read-generation',expected=2)
    run('validate',bind,values=dict(secrets,GOOD_ROUTE='other-generation'),expected=2)
    run('validate',bind,values={},expected=2)
    source.write_bytes(source.read_bytes()+b'\n'); run('validate',bind,expected=2)
    emit(original); capture.write_bytes(capture.read_bytes()+b'\n'); run('validate',bind,expected=2)
    emit(original)
    for field,value in [('source_target','generic/region-b'),('observed_at','2000-01-01T00:00:00Z')]:
        s=copy.deepcopy(original); s[field]=value; emit(s); run('validate',bind,expected=2)
    emit(original)
    for kind,status in [('import-only','verified'),('api-read','candidate'),('attended','blocked')]:
        s=copy.deepcopy(original); s['verification'].update(kind=kind,status=status); emit(s); p=run('bind')
        assert_(all(r['status']=='blocked' for r in p['records']),'unattested source cannot be upgraded')
    s=copy.deepcopy(original); s['producer']='attended-source'; s['verification']['kind']='attended'; emit(s)
    p=run('bind'); assert_(p['records'][0]['verification_kind']=='attended' and p['records'][0]['status']=='bound','completed attended observation remains labeled')
    emit(original); capture.unlink(); run('bind',expected=2)
    emit(original); c=json.loads(capture.read_bytes()); c['source_target']='generic/other'; write(capture,c); run('bind',expected=2)
    emit(original); c=json.loads(capture.read_bytes()); c['records_sha256']='0'*64; write(capture,c); run('bind',expected=2)
    emit(original); capture.rename(work/'elsewhere.json'); capture.symlink_to(work/'elsewhere.json'); run('bind',expected=2); capture.unlink()
    s=copy.deepcopy(original); s['records'][0]['definition']['query']='secret-config-canary'; emit(s); run('bind',expected=2)
    s=copy.deepcopy(original); s['records'][0]['source_id']='https://unsafe.example/path'; emit(s); run('bind',expected=2)
    s=copy.deepcopy(original); s['records'][1]['record_id']='good'; emit(s); run('bind',expected=2)
    emit(original); source.write_text('{"schema":1,"schema":2}'); run('bind',expected=2)
    source.write_bytes(b' '*2097153); run('bind',expected=2)
    emit(original); m=json.loads(mapping.read_bytes()); m['records'].append(m['records'][0]); write(mapping,m); run('bind',expected=2)
    emit(original); m=json.loads(mapping.read_bytes()); m['source_target']='generic/other'; write(mapping,m); run('bind',expected=2)
    # Real published evaluator against one safely projected management snapshot.
    emit(original); packet=run('bind'); write(bind,packet); matches=run('match',bind)
    text=(root/'skills/audit-splunk-oncall/tests/test-verify-path.sh').read_text()
    snapshot=json.loads(text.split('cat > "$WORK/base.json" <<\'JSON\'\n',1)[1].split('\nJSON',1)[0])
    snapshot.update(target='splunk_oncall/region-a',credential_binding=cred,source_matches=matches,started_at=now,finished_at=now)
    def assess(s):
        result=subprocess.run(['/bin/sh',str(helper),'evaluate',str(root)],input=canonical(s),capture_output=True,timeout=60)
        assert_(result.returncode==0,'local batch evaluation '+result.stderr.decode())
        return json.loads(result.stdout)
    assessment=assess(snapshot)
    assert_(assessment['total']==5 and assessment['assessed']==2 and assessment['counts']=={'verified':1,'not-met':1,'blocked':3,'inapplicable':0},'all five path records retained in exact denominators')
    assert_(assessment['delivery_proven'] is False,'metadata is not human receipt')
    foreign=copy.deepcopy(snapshot); foreign['target']='splunk_oncall/region-b'
    assert_(assess(foreign)['counts']['blocked']==5,'selector independently rejects foreign target')
    foreign=copy.deepcopy(snapshot); foreign['source_matches']['records'][0]['expected_team']='team-other'
    assert_(assess(foreign)['records'][0]['status']=='not-met','actual owner mismatch is explicit')
    s=copy.deepcopy(original); s['records']=[copy.deepcopy(records[0]) for _ in range(100)]
    for i,r in enumerate(s['records']): r['record_id']='path-'+str(i)
    emit(s); p=run('bind'); write(bind,p); m=run('match',bind)
    assert_(len(m['records'])==100 and all(r['binding_verified'] for r in m['records']),'one private routing snapshot handles one hundred source paths')
print('ONCALL-SOURCE-EVIDENCE-OK:',passed,'assertions; real binder and published evaluator; no provider calls')
PY
