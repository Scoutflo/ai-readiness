#!/bin/sh
# Fixed local evidence recipe. No transport, source discovery or provider writes.
set -eu
set +x
exec 3<&0
python3 - "$@" <<'PY' 3<&3
import datetime as dt, hashlib, hmac, json, os, pathlib, re, subprocess, sys

LIMIT=2097152
def reject(): raise ValueError('unverified evidence')
def obj(pairs):
    d={}
    for k,v in pairs:
        if k in d: reject()
        d[k]=v
    return d
def parse(raw):
    if len(raw)>LIMIT: reject()
    return json.loads(raw,object_pairs_hook=obj,parse_constant=lambda _:reject())
def read(path):
    p=pathlib.Path(path)
    if p.is_symlink() or not p.is_file(): reject()
    with p.open('rb') as f: raw=f.read(LIMIT+1)
    return parse(raw),hashlib.sha256(raw).hexdigest()
def canon(value): return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
def sha(value): return hashlib.sha256(canon(value)).hexdigest()
def exact(value,keys):
    if not isinstance(value,dict) or set(value)!=set(keys.split()): reject()
def safe(v,pattern=r'[A-Za-z0-9_][A-Za-z0-9_.:/-]{0,255}'):
    return isinstance(v,str) and re.fullmatch(pattern,v) is not None and '//' not in v and '..' not in v
def slug(v): return safe(v,r'[A-Za-z0-9_-]{1,128}')
def envname(v): return safe(v,r'[A-Za-z_][A-Za-z0-9_]{0,127}')
def digest(v): return isinstance(v,str) and re.fullmatch(r'[a-f0-9]{64}',v) is not None
def fresh(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ',value): reject()
    age=os.environ.get('SCOUTFLO_VERIFY_SOURCE_MAX_AGE_SECONDS','3600')
    skew=os.environ.get('SCOUTFLO_VERIFY_CLOCK_SKEW_SECONDS','60')
    if not re.fullmatch(r'[1-9][0-9]{0,7}',age) or not re.fullmatch(r'[1-9][0-9]{0,7}',skew): reject()
    elapsed=(dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(value.replace('Z','+00:00'))).total_seconds()
    if not -int(skew)<=elapsed<=int(age): reject()
def definition(provider,d):
    # Only fixed safe projections enter the packet. No free text, URL or query.
    if provider=='datadog':
        exact(d,'monitor_id monitor_type notification_handles enabled service_tags source_site')
        if not safe(d['monitor_id']) or not safe(d['monitor_type'],r'[a-zA-Z0-9_ -]{1,64}') or d['source_site'] not in ['datadoghq.com','us3.datadoghq.com','us5.datadoghq.com','datadoghq.eu','ap1.datadoghq.com','ap2.datadoghq.com','ddog-gov.com']: reject()
        for k,pattern in [('notification_handles',r'@[A-Za-z0-9][A-Za-z0-9_.-]{0,159}'),('service_tags',r'service:[A-Za-z0-9][A-Za-z0-9_.-]{0,127}')]:
            if not isinstance(d[k],list) or len(d[k])>1000 or not all(safe(v,pattern) for v in d[k]): reject()
    elif provider=='clickstack':
        exact(d,'alert_id source_id connection_id enabled channel_type receiver_id receiver_resolution destination_class destination_kind')
        if not all(v is None or safe(v) for v in [d['alert_id'],d['source_id'],d['connection_id'],d['receiver_id']]) or not safe(d['channel_type']): reject()
        if d['receiver_resolution'] not in ['resolved','missing-id','absent','ambiguous','blocked'] or d['destination_class'] not in ['public','private','loopback','placeholder','masked','unknown'] or d['destination_kind'] not in ['intermediary','oncall-inbound','other','unknown']: reject()
    else:
        exact(d,'source_id kind receiver_id enabled destination_kind')
        if not safe(d['source_id']) or not safe(d['kind']) or not (d['receiver_id'] is None or safe(d['receiver_id'])) or d['destination_kind'] not in ['oncall-inbound','intermediary','other','unknown']: reject()
    if d['enabled'] is not None and type(d['enabled']) is not bool: reject()
def source(path):
    s,sd=read(path)
    exact(s,'schema producer source_provider source_target observed_at verification records')
    if s['schema']!='scoutflo-alert-source-evidence/v1' or s['source_provider'] not in ['datadog','clickstack','alertmanager','prometheus','grafana','sentry','kubernetes','generic']: reject()
    if s['producer'] not in ['audit-'+s['source_provider'],'attended-source'] or not safe(s['source_target']) or not re.fullmatch(re.escape(s['source_provider'])+r'(?:/[A-Za-z0-9_-]{1,128})?',s['source_target']): reject()
    fresh(s['observed_at'])
    v=s['verification']; exact(v,'kind status evidence_ref')
    if v['kind'] not in ['api-read','attended','import-only'] or v['status'] not in ['verified','candidate','blocked']: reject()
    if s['producer']=='attended-source' and v['kind']!='attended': reject()
    if not safe(v['evidence_ref'],r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}'): reject()
    receipt_path=pathlib.Path(path).resolve().parent/v['evidence_ref']
    receipt,rd=read(receipt_path)
    exact(receipt,'schema producer source_provider source_target observed_at verification records_sha256')
    if receipt['schema']!='scoutflo-alert-source-capture/v1' or any(receipt[k]!=s[k] for k in ['producer','source_provider','source_target','observed_at']): reject()
    exact(receipt['verification'],'kind status')
    if receipt['verification']!={k:v[k] for k in ['kind','status']} or receipt['records_sha256']!=sha(s['records']): reject()
    if not isinstance(s['records'],list) or not 1<=len(s['records'])<=2000: reject()
    ids=set()
    for r in s['records']:
        exact(r,'record_id source_id route_env route_verification definition')
        if not safe(r['record_id']) or r['record_id'] in ids or not safe(r['source_id']): reject()
        ids.add(r['record_id'])
        if r['route_env'] is not None and not envname(r['route_env']): reject()
        if r['route_verification'] not in ['verified','candidate','blocked']: reject()
        definition(s['source_provider'],r['definition'])
    return s,sd,rd
def binding(value):
    exact(value,'api_id_env api_key_env fingerprint')
    if not all(envname(value[k]) for k in ['api_id_env','api_key_env']) or not digest(value['fingerprint']): reject()
def mapping(path,s,sd,target):
    m,_=read(path); exact(m,'schema source_provider source_target source_sha256 expected_oncall_target records')
    if m['schema']!='scoutflo-oncall-source-mapping/v1' or m['source_provider']!=s['source_provider'] or m['source_target']!=s['source_target'] or m['source_sha256']!=sd or m['expected_oncall_target']!=target: reject()
    if not isinstance(m['records'],list) or len(m['records'])>2000: reject()
    out={}; ids={r['record_id'] for r in s['records']}
    for r in m['records']:
        exact(r,'record_id expected_policy expected_team')
        if r['record_id'] not in ids or r['record_id'] in out or not slug(r['expected_policy']) or not slug(r['expected_team']): reject()
        out[r['record_id']]=r
    return out
def packet(path):
    p,_=read(path); exact(p,'schema source_file source_sha256 receipt_sha256 source_provider source_target observed_at expected_oncall_target credential_binding records')
    if p['schema']!='scoutflo-oncall-source-binding/v1' or not isinstance(p['source_file'],str) or not pathlib.Path(p['source_file']).is_absolute(): reject()
    binding(p['credential_binding'])
    s,sd,rd=source(p['source_file'])
    if p['source_sha256']!=sd or p['receipt_sha256']!=rd or any(p[k]!=s[k] for k in ['source_provider','source_target','observed_at']): reject()
    if not isinstance(p['records'],list) or len(p['records'])!=len(s['records']): reject()
    for row,r in zip(p['records'],s['records']):
        exact(row,'record_id source_id source_definition_sha256 route_env verification_kind expected_policy expected_team status reason binding_hmac')
        if any(row[k]!=r[k] for k in ['record_id','source_id','route_env']) or row['verification_kind']!=s['verification']['kind'] or row['source_definition_sha256']!=sha({'source_provider':s['source_provider'],'source_target':s['source_target'],'source_id':r['source_id'],'definition':r['definition']}): reject()
        if row['status'] not in ['bound','blocked'] or not safe(row['reason']) or (row['binding_hmac'] is not None and not digest(row['binding_hmac'])): reject()
        if not all(row[k] is None or slug(row[k]) for k in ['expected_policy','expected_team']): reject()
    return p,s
def material():
    with os.fdopen(3,'rb') as f:
        key=f.readline(8193).rstrip(b'\n'); cred=parse(f.readline(8193)); values=parse(f.readline(LIMIT+1)); rest=f.read(LIMIT+1)
    if not key or b'\r' in key or b'\n' in key or len(key)>8192: reject()
    binding(cred)
    if not isinstance(values,dict) or not all(envname(k) and isinstance(v,str) and len(v)<=8192 and '\n' not in v and '\r' not in v for k,v in values.items()): reject()
    return key,cred,values,parse(rest) if rest else None
def mac(key,p,row,value):
    body={k:v for k,v in p.items() if k!='records'}
    body['record']={k:v for k,v in row.items() if k not in ['binding_hmac','status','reason']}
    # Keyed evidence only: no unkeyed route hash or secret-derived persistent ID.
    return hmac.new(key,canon({'binding':body,'route':value}),hashlib.sha256).hexdigest()
def eligible(s,r):
    return s['verification']['kind'] in ['api-read','attended'] and s['verification']['status']=='verified' and r['route_verification']=='verified' and envname(r['route_env'])
try:
    mode=sys.argv[1]
    if mode=='source-vars':
        s,_,_=source(sys.argv[2]); print('\n'.join(sorted({r['route_env'] for r in s['records'] if eligible(s,r)}))); sys.exit(0)
    if mode=='packet-vars':
        p,s=packet(sys.argv[2]); print('\n'.join(sorted({r['route_env'] for r in s['records'] if eligible(s,r)}))); sys.exit(0)
    if mode in ['bind','validate','match']:
        target=sys.argv[3]
        if not isinstance(target,str) or not re.fullmatch(r'splunk_oncall(?:/[A-Za-z0-9_-]{1,128})?',target): reject()
        key,cred,values,routes=material()
        if mode=='bind':
            s,sd,rd=source(sys.argv[2]); selected=mapping(sys.argv[4],s,sd,target)
            p={'schema':'scoutflo-oncall-source-binding/v1','source_file':str(pathlib.Path(sys.argv[2]).resolve()),'source_sha256':sd,'receipt_sha256':rd,'source_provider':s['source_provider'],'source_target':s['source_target'],'observed_at':s['observed_at'],'expected_oncall_target':target,'credential_binding':cred,'records':[]}
            for r in s['records']:
                m=selected.get(r['record_id'],{})
                row={k:r[k] for k in ['record_id','source_id','route_env']}
                row.update(source_definition_sha256=sha({'source_provider':s['source_provider'],'source_target':s['source_target'],'source_id':r['source_id'],'definition':r['definition']}),verification_kind=s['verification']['kind'],expected_policy=m.get('expected_policy'),expected_team=m.get('expected_team'),status='blocked',reason='source-route-unverified',binding_hmac=None)
                if eligible(s,r):
                    row['reason']='mapping-missing' if not m else 'route-variable-unset'
                    if m and values.get(r['route_env']):
                        row.update(status='bound',reason='bound'); row['binding_hmac']=mac(key,p,row,values[r['route_env']])
                p['records'].append(row)
            print(json.dumps(p,separators=(',',':'))); sys.exit(0)
        p,s=packet(sys.argv[2])
        if p['expected_oncall_target']!=target or p['credential_binding']!=cred: reject()
        if mode=='match':
            if not isinstance(routes,dict) or not isinstance(routes.get('routingKeys'),list): reject()
            for r in routes['routingKeys']:
                if not isinstance(r,dict) or not isinstance(r.get('routingKey'),str) or not isinstance(r.get('targets'),list) or not all(isinstance(t,dict) and slug(t.get('policySlug')) for t in r['targets']): reject()
        rows=[]
        for row,r in zip(p['records'],s['records']):
            result={k:row[k] for k in ['record_id','source_id','source_definition_sha256','verification_kind','expected_policy','expected_team']}
            result.update(status='blocked',reason=row['reason'],binding_verified=False,route_aliases=[],policies=[])
            if row['status']=='bound':
                if not eligible(s,r) or not values.get(row['route_env']) or not hmac.compare_digest(row['binding_hmac'] or '',mac(key,p,row,values[row['route_env']])): reject()
                result.update(status='compared',reason='exact-key-comparison',binding_verified=True)
                if mode=='match':
                    matches=[(i,x) for i,x in enumerate(routes['routingKeys']) if x['routingKey']==values[row['route_env']]]
                    result['route_aliases']=['route-'+str(i+1) for i,_ in matches]
                    result['policies']=sorted({t['policySlug'] for _,x in matches for t in x['targets']})
            rows.append(result)
        if mode=='validate': print('{"status":"bound-input-validated"}'); sys.exit(0)
        print(json.dumps({'schema':'scoutflo-oncall-source-matches/v1','target':target,'credential_binding':cred,'source_provider':s['source_provider'],'source_target':s['source_target'],'observed_at':s['observed_at'],'source_sha256':p['source_sha256'],'receipt_sha256':p['receipt_sha256'],'records':rows},separators=(',',':'))); sys.exit(0)
    if mode=='evaluate':
        # Execute the same fixed selector over one snapshot, without recollection.
        with os.fdopen(3,'rb') as f: snapshot=parse(f.read(LIMIT+1))
        matches=snapshot.get('source_matches')
        if not isinstance(matches,dict) or matches.get('schema')!='scoutflo-oncall-source-matches/v1' or not isinstance(matches.get('records'),list): reject()
        root=pathlib.Path(sys.argv[2])
        text=(root/'skills/audit-splunk-oncall/references/effective-quality.md').read_text()
        cookbook=text.split('<!-- oncall-effective-quality:start -->',1)[1].split('<!-- oncall-effective-quality:end -->',1)[0].split('```bash\n',1)[1].rsplit('```',1)[0]
        results=[]
        for r in matches['records']:
            if not isinstance(r,dict) or not safe(r.get('record_id')): reject()
            env=dict(os.environ,SCOUTFLO_VERIFY_CHECK='SOC-007',SCOUTFLO_VERIFY_POLICY=r.get('expected_policy') or 'unbound',SCOUTFLO_VERIFY_TEAM=r.get('expected_team') or '',SCOUTFLO_VERIFY_SOURCE_RECORD=r['record_id'],SCOUTFLO_ONCALL_SNAPSHOT='',SCOUTFLO_ONCALL_MODE='')
            done=subprocess.run(['/bin/sh','-c',cookbook],input=canon(snapshot),capture_output=True,env=env,timeout=30)
            value=parse(done.stdout)
            if done.returncode not in [0,1,2,3] or value.get('status') not in ['verified','not-met','blocked','inapplicable']: reject()
            results.append({'record_id':r['record_id'],'source_id':r['source_id'],'expected_policy':r.get('expected_policy'),'expected_team':r.get('expected_team'),'status':value['status'],'reason':value['reason'],'evidence':value.get('evidence',{})})
        counts={status:sum(x['status']==status for x in results) for status in ['verified','not-met','blocked','inapplicable']}
        print(json.dumps({'schema':'scoutflo-oncall-source-assessment/v1','target':snapshot['target'],'source_provider':matches['source_provider'],'source_target':matches['source_target'],'source_sha256':matches['source_sha256'],'source_observed_at':matches['observed_at'],'management_started_at':snapshot.get('started_at'),'management_finished_at':snapshot.get('finished_at'),'unit':'source-path-records','total':len(results),'assessed':counts['verified']+counts['not-met'],'counts':counts,'delivery_proven':False,'records':results},separators=(',',':'))); sys.exit(0)
    reject()
except (ValueError,TypeError,KeyError,IndexError,OSError,AttributeError,OverflowError,RecursionError,subprocess.SubprocessError):
    print('Source evidence is unbound, changed, stale, foreign or unsupported; reread its source and rebuild the private binding',file=sys.stderr); sys.exit(2)
PY
