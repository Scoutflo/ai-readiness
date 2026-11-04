#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
export ROOT
python3 - <<'PY'
import copy,hashlib,hmac,json,os,pathlib,shlex,shutil,subprocess,sys,tempfile,time
root=pathlib.Path(os.environ['ROOT']);work=pathlib.Path(tempfile.mkdtemp(prefix='oncall-attended-'));checks=0
try:
    doc=(root/'skills/setup-splunk-oncall/references/attended-verification.md').read_text()
    block=doc.split('<!-- oncall-attended-verification:start -->')[1].split('<!-- oncall-attended-verification:end -->')[0].split('```bash\n')[1].rsplit('```',1)[0]
    script=work/'verify.sh';script.write_text(block);subprocess.run(['sh','-n',str(script)],check=True)
    bin=work/'bin';bin.mkdir();(work/'home').mkdir();out=work/'out';out.mkdir(mode=0o700)
    cfg=work/'config';cfg.write_text('splunk_oncall:\n  api_id_env: FIXTURE_ID\n  api_key_env: FIXTURE_READ\n  setup_api_key_env: MUST_NOT_LOAD\n  team_slug: team-safe\n')
    store=work/'env';store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nPRIVATE_ROUTE='synthetic-route-value'\nPRIVATE_VALUE='private-value'\n")
    active_route_value='synthetic-route-value'
    for name in ('sleep','yq','aws','gcloud','kubectl','claude'):
        (bin/name).write_text('#!/bin/sh\nexit '+('0' if name=='sleep' else '98')+'\n');(bin/name).chmod(0o700)
    stub=r'''#!/usr/bin/env python3
import json,os,sys,pathlib,urllib.parse
args=sys.argv[1:]
if args==['--version']:print('curl 8.12.0 fixture');sys.exit(0)
assert args[args.index('--request')+1]=='GET'
assert args[-1].startswith('https://api.victorops.com/api-public/v1/')
assert '--max-filesize' in args and args[args.index('--max-redirs')+1]=='0'
headers=sys.stdin.read();assert 'fixture-read-key' in headers and 'fixture-id' in headers and 'MUST_NOT_LOAD' not in headers
p=urllib.parse.urlparse(args[-1]).path
with open(os.environ['CALLS'],'a') as f:f.write('GET '+p+'\n')
if os.environ.get('FAULT')=='html':sys.stdout.write('<html>login</html>\n200');sys.exit(0)
if os.environ.get('FAULT')=='denied':sys.stdout.write('{}\n403');sys.exit(0)
if os.environ.get('FAULT')=='throttle':sys.stdout.write('{}\n429');sys.exit(0)
r=json.loads(pathlib.Path(os.environ['RESPONSES']).read_text())[p]
sys.stdout.write(json.dumps(r)+'\n200')
'''
    (bin/'curl').write_text(stub);(bin/'curl').chmod(0o700)
    def digest(v):return hmac.new(b'fixture-read-key',json.dumps(v,sort_keys=True,separators=(',',':')).encode(),hashlib.sha256).hexdigest()
    masks={'day':{x:True for x in ('su','m','t','w','th','f','sa')},'time':[{'start':{'hour':0,'minute':0},'end':{'hour':0,'minute':0}}]}
    responses={
      '/api-public/v1/team/team-safe':{'slug':'team-safe','name':'Example team'},
      '/api-public/v1/org/routing-keys':{'routingKeys':[{'routingKey':'synthetic-route-value','targets':[{'policySlug':'policy-safe','policyName':'Example policy'}],'isDefault':False}]},
      '/api-public/v1/policies/policy-safe':{'slug':'policy-safe','name':'Example policy','ignoreCustomPagingPolicies':False,'steps':[{'timeout':0,'entries':[{'executionType':'email','email':{'address':'private-person@example.invalid'}}]}]},
      '/api-public/v1/team/team-safe/members':{'members':[{'username':'alice','verified':True,'email':'private-person@example.invalid'}]},
      '/api-public/v1/teams/team-safe/rotations/10/20':{'label':'Example shift','timezone':'UTC','start':1793793600000,'duration':1,'shifttype':'std','mask':masks,'team_slug':'team-safe','group_id':10,'rot_id':20,'shiftMembers':[{'slug':'member-safe','username':'alice'}],'usernames':['alice']},
      '/api-public/v1/teams/team-safe/rotations/10/20/scheduled':{'username':'alice','verified':True,'email':'private-person@example.invalid'},
      '/api-public/v1/overrides':{'overrides':[{'publicId':'override-safe','user':{'username':'alice','firstName':'Private Name'},'timezone':'UTC','start':'2026-11-04T01:00:00Z','end':'2026-11-04T02:00:00Z','assignments':[{'team':'team-safe','policy':'policy-safe','assigned':True,'user':'bob'}]}]},
      '/api-public/v1/maintenancemode':{'companyId':'org-safe','activeInstances':[{'instanceId':'maintenance-safe','isGlobal':False,'targets':[{'type':'RoutingKeys','names':['synthetic-route-value']}]}]},
      '/api-public/v1/alertRules':[{'id':1,'alertField':'entity_id','alertValueMatch':'private-value','matchType':'WILDCARD','rank':1,'stopFlag':False,'routeKey':'synthetic-route-value','annotations':[{'id':2,'annotationType':'s','fieldName':'note','fieldValue':'private-value','flags':0}]}],
      '/api-public/v1/profile/alice/policies':{'steps':[{'index':0,'timeout':1,'rules':[{'index':0,'type':'email','contact':{'id':3,'type':'email'}}]}]},
      '/api-public/v1/user/alice/contact-methods':{'devices':[],'emails':[{'label':'private-person@example.invalid','extId':'private-contact','deviceType':'email'}],'phones':[]}}
    responsefile=work/'responses';calls=work/'calls';calls.write_text('');responsefile.write_text(json.dumps(responses))
    ui_values={'route-mode':{'isMultiResponder':False},'policy':{},'membership':{},'shift':{'interval_start':'2026-11-04T01:00:00Z','interval_end':'2026-11-04T02:00:00Z','coverage_matches':True},'overrides':{'interval_start':'2026-11-04T01:00:00Z','interval_end':'2026-11-04T02:00:00Z','coverage_matches':True},'maintenance':{'end_mechanism_present':True},'alert-rules':{'positive_match':True,'negative_match':True},'paging':{},'contacts':{'selected_contact_hash':digest('private-contact'),'selected_contact_present':True,'selected_contact_verified':True},'incoming':{'integration_enabled':True},'value-digest':{}}
    def binding(kind):
        b={'target':'splunk_oncall','team':'team-safe','kind':kind,'object':'policy-safe' if kind=='policy' else 'alice' if kind in ('paging','contacts') else '', 'group':10 if kind=='shift' else 0,'shift':20 if kind=='shift' else 0,'route_ref':'PRIVATE_ROUTE' if kind in ('route-mode','incoming') else ''}
        if kind in ('route-mode','incoming'):b['route_value_hash']=digest(active_route_value)
        return b
    def ui(kind,name,age=20,values=None):
        if not ui_values[kind]:return ''
        evidence=out/(name+'-evidence');evidence.write_text('Redacted provider view: '+name)
        r={'source':'provider-ui','observer':'browser-tool','observed_at':int(time.time())-age,'object':binding(kind),'evidence_file':str(evidence),'evidence_sha256':hashlib.sha256(evidence.read_bytes()).hexdigest(),'values':values if values is not None else ui_values[kind]}
        p=out/(name+'-ui.json');p.write_text(json.dumps(r));return str(p)
    def check(ok,msg):
        global checks
        assert ok,msg;checks+=1
    def run(kind,mode='capture',name=None,expected=None,observation=None,extra=None):
        name=name or kind+'-'+mode;record=out/(name+'.json');b=binding(kind)
        env={'PATH':str(bin)+os.pathsep+os.environ['PATH'],'HOME':str(work/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_ENV_FILE':str(store),'SOC_VERIFY_KIND':kind,'SOC_VERIFY_MODE':mode,'SOC_VERIFY_OUTPUT':str(record),'SOC_OBJECT_ID':b['object'],'SOC_GROUP_ID':str(b['group']),'SOC_SHIFT_ID':str(b['shift']),'SOC_ROUTE_ENV':b['route_ref'],'SOC_VALUE_ENV':'PRIVATE_VALUE','RESPONSES':str(responsefile),'CALLS':str(calls)}
        env['SOC_UI_OBSERVATION']=observation if observation is not None else ui(kind,name)
        if expected:env['SOC_VERIFY_EXPECTED']=str(expected);env['SOC_VERIFY_EXPECTED_SHA256']=hashlib.sha256(expected.read_bytes()).hexdigest()
        if extra:env.update(extra)
        r=subprocess.run(['sh',str(script)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        check(not any(v in r.stdout for v in ('fixture-id','fixture-read-key','synthetic-route-value','different-route-value','private-person@example.invalid','private-value')),'Secret leaked to output')
        return r,record
    records={}
    for kind in ui_values:
        r,p=run(kind);check(r.returncode==0,kind+' capture failed: '+r.stdout);records[kind]=p
        check(p.stat().st_mode & 0o077==0,'Receipt was not private')
        check(not any(x in p.read_text() for x in ('fixture-id','fixture-read-key','synthetic-route-value','private-person@example.invalid','private-value')),'Receipt contained private provider data')
    r,p=run('route-mode','check-before',expected=records['route-mode']);check(r.returncode==0,'Unchanged baseline failed: '+r.stdout)
    # A same-named store variable must stay bound to the actual selected route.
    # Both routes exist and have identical payloads; this reproduces the reviewer
    # case without relying on an absent key, changed mode or changed policy set.
    original_routes=copy.deepcopy(responses['/api-public/v1/org/routing-keys'])
    rows=responses['/api-public/v1/org/routing-keys']['routingKeys']
    rows.append({**copy.deepcopy(rows[0]),'routingKey':'different-route-value'})
    responsefile.write_text(json.dumps(responses))
    for kind in ('route-mode','incoming'):
        r,p=run(kind,'check-before',name=kind+'-same-key-extra-route',expected=records[kind]);check(r.returncode==0,'Unrelated equal-payload route changed selected identity: '+r.stdout)
        check(json.loads(p.read_text())['binding']['route_value_hash']==digest(active_route_value),'Receipt lacks selected value HMAC')
    active_route_value='different-route-value'
    store.write_text(store.read_text().replace("PRIVATE_ROUTE='synthetic-route-value'", "PRIVATE_ROUTE='different-route-value'"))
    for kind in ('route-mode','incoming'):
        for mode in ('check-before','check-after'):
            r,p=run(kind,mode,name=kind+'-rotated-'+mode,expected=records[kind],observation=ui(kind,kind+'-rotated-'+mode,age=1))
            check(r.returncode!=0 and not p.exists() and 'Expected record target or credentials differ' in r.stdout,'Same reference with a different actual route reused the plan: '+r.stdout)
        r,p=run(kind,'check-before',name=kind+'-rotated-old-ui',expected=records[kind],observation=str(out/(kind+'-capture-ui.json')))
        check(r.returncode!=0 and not p.exists() and 'another object' in r.stdout,'Old UI payload concealed route value rotation')
        r,p=run(kind,name=kind+'-rotated-new-baseline')
        check(r.returncode==0 and json.loads(p.read_text())['binding']['route_value_hash']==digest(active_route_value),'Fresh rotated baseline did not bind new route')
        check(not any(x in p.read_text() for x in ('synthetic-route-value','different-route-value')),'Raw routing token leaked to private receipt')
    # Rotation in the store with the old provider payload retained is also a
    # refusal, never permission to reuse that old route implicitly.
    responses['/api-public/v1/org/routing-keys']=copy.deepcopy(original_routes);responsefile.write_text(json.dumps(responses))
    for kind in ('route-mode','incoming'):
        for mode in ('check-before','check-after'):
            r,p=run(kind,mode,name=kind+'-rotated-old-provider-'+mode,expected=records[kind],observation=ui(kind,kind+'-rotated-old-provider-'+mode,age=1))
            check(r.returncode!=0 and not p.exists() and 'absent or ambiguous' in r.stdout,'Rotated reference silently reused old provider payload')
    active_route_value='synthetic-route-value'
    store.write_text(store.read_text().replace("PRIVATE_ROUTE='different-route-value'", "PRIVATE_ROUTE='synthetic-route-value'"))
    # The after-file contains an exact approved mapping, and a fresh UI view.
    expected=out/'expected-route.json';wanted=json.loads(records['route-mode'].read_text());wanted['api']['policy_slugs']=['policy-second'];expected.write_text(json.dumps(wanted))
    responses['/api-public/v1/org/routing-keys']['routingKeys'][0]['targets']=[{'policySlug':'policy-second'}];responsefile.write_text(json.dumps(responses))
    r,p=run('route-mode','check-after',expected=expected,observation=ui('route-mode','after-route',age=2));check(r.returncode==0,'Approved mapping with UI mode failed: '+r.stdout)
    for fault in ('html','denied','throttle'):
        r,p=run('policy',name='bad-'+fault,extra={'FAULT':fault});check(r.returncode!=0 and not p.exists(),'Failed GET was accepted')
    r,p=run('route-mode','check-after',name='bad-reused-ui',expected=expected,observation=str(out/'route-mode-capture-ui.json'));check(r.returncode!=0,'Reused UI evidence was accepted')
    r,p=run('route-mode','check-after',name='bad-stale-ui',expected=expected,observation=ui('route-mode','stale',age=600));check(r.returncode!=0,'Stale UI evidence was accepted')
    r,p=run('route-mode','check-after',name='bad-mode',expected=expected,observation=ui('route-mode','wrong-mode',age=1,values={'isMultiResponder':True}));check(r.returncode!=0,'Unapproved UI mode was accepted')
    r,p=run('route-mode','check-after',name='bad-checksum',expected=expected,observation=ui('route-mode','checksum',age=1),extra={'SOC_VERIFY_EXPECTED_SHA256':'0'*64});check(r.returncode!=0,'Changed expected file was accepted')
    # Wrong management fields cannot be excused by a matching UI assertion.
    responses['/api-public/v1/org/routing-keys']['routingKeys'][0]['targets']=[{'policySlug':'outside-policy'}];responsefile.write_text(json.dumps(responses))
    r,p=run('route-mode','check-after',name='bad-api-drift',expected=expected,observation=ui('route-mode','api-drift',age=1));check(r.returncode!=0,'Wrong API target was accepted')
    # Unsupported paging identities and incomplete collections fail closed.
    responses['/api-public/v1/overrides']['next']='unknown-page';responsefile.write_text(json.dumps(responses))
    r,p=run('overrides',name='bad-pagination');check(r.returncode!=0,'Unconsumed page was accepted')
    observation=ui('contacts','wrong-contact',values={**ui_values['contacts'],'selected_contact_hash':'f'*64})
    r,p=run('contacts',name='bad-contact-identity',observation=observation);check(r.returncode!=0,'UI verification of another contact passed')
    r,p=run('route-mode',name='bad-unobservable-ui',observation='');check(r.returncode!=0 and not p.exists(),'Missing UI observation was accepted')
    bad=ui('route-mode','wrong-evidence');ob=json.loads(pathlib.Path(bad).read_text());ob['evidence_sha256']='0'*64;pathlib.Path(bad).write_text(json.dumps(ob))
    r,p=run('route-mode',name='bad-evidence-hash',observation=bad);check(r.returncode!=0,'Mismatched UI evidence file was accepted')
    prior=calls.read_text();wrapper=bin/'python3'
    wrapper.write_text('#!/bin/sh\nif [ "$1" = -c ]; then exit 1; fi\nexec '+shlex.quote(sys.executable)+' "$@"\n');wrapper.chmod(0o700)
    r,p=run('policy',name='unsupported-python');check(r.returncode!=0 and calls.read_text()==prior,'Unsupported Python reached API access');wrapper.unlink()
    check(all(row.startswith('GET ') for row in calls.read_text().splitlines()),'Verifier issued a mutation')
    print('attended verification:',checks,'checks passed; fixed reads only')
finally:
    shutil.rmtree(work)
PY
