#!/bin/sh
# Exercise the published fixed-operation recipe in fresh shells; no network.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
export ROOT
python3 - <<'PY_TEST'
import copy, hashlib, json, os, pathlib, shutil, subprocess, tempfile
root=pathlib.Path(os.environ['ROOT'])
work=pathlib.Path(tempfile.mkdtemp(prefix='oncall-team-workflows-'))
checks=0
try:
    doc=(root/'skills/setup-splunk-oncall/references/team-rotation-workflows.md').read_text()
    block=doc.split('<!-- oncall-team-rotation:start -->',1)[1].split('<!-- oncall-team-rotation:end -->',1)[0].split('```bash\n',1)[1].rsplit('```',1)[0]
    script=work/'recipe.sh';script.write_text(block)
    subprocess.run(['sh','-n',str(script)],check=True)
    bin=work/'bin';bin.mkdir();(work/'home').mkdir();state=work/'state.json'
    config=work/'config.yaml';config.write_text('splunk_oncall:\n  api_id_env: FIXTURE_ID\n  api_key_env: FIXTURE_READ\n  setup_api_key_env: FIXTURE_WRITE\n  team_slug: team-anchor\n')
    store=work/'store';store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nFIXTURE_WRITE='fixture-write-key'\n")
    (bin/'sleep').write_text('#!/bin/sh\nexit 0\n');(bin/'sleep').chmod(0o700)
    for tool in ['aws','gcloud','kubectl','doctl','claude','yq']:
        (bin/tool).write_text('#!/bin/sh\nexit 98\n');(bin/tool).chmod(0o700)
    stub=r'''#!/usr/bin/env python3
import json,os,sys,pathlib,urllib.parse,re
args=sys.argv[1:]
if args==['--version']:print('curl 8.12.0 fixture');sys.exit(0)
method=args[args.index('--request')+1];url=args[-1]
assert url.startswith('https://api.victorops.com/api-public/v1/')
assert '--max-filesize' in args and args[args.index('--max-redirs')+1]=='0' and args[0]=='-q'
config=sys.stdin.read();headers=[json.loads(x.split(' = ',1)[1]) for x in config.splitlines() if x.startswith('header = ')]
assert 'X-VO-Api-Id: fixture-id' in headers
assert any(x in headers for x in ['X-VO-Api-Key: fixture-read-key','X-VO-Api-Key: fixture-write-key'])
if method!='GET':assert 'X-VO-Api-Key: fixture-write-key' in headers
payload=next((json.loads(json.loads(x.split(' = ',1)[1])) for x in config.splitlines() if x.startswith('data = ')),None)
f=pathlib.Path(os.environ['FIXTURE_STATE']);s=json.loads(f.read_text());p=urllib.parse.urlparse(url).path
with open(str(f)+'.calls','a') as log:log.write(method+' '+p+'\n')
case=os.environ.get('FIXTURE_CASE','')
if case=='html':sys.stdout.write('<html>login</html>\n200');sys.exit(0)
if case=='duplicate-json':sys.stdout.write('{"slug":"team-anchor","slug":"other"}\n200');sys.exit(0)
if case=='wrong-anchor' and p.endswith('/team-anchor'):sys.stdout.write('{}\n200');sys.exit(0)
if method!='GET' and case in ['denied','throttled']:
 sys.stdout.write('{}\n'+('401' if case=='denied' else '429'));sys.exit(0)
def tmeta(t):
 d={k:t[k] for k in ['slug','name','description','version','isDefaultTeam']};d['memberCount']=len(t['members'])
 for field,suffix in [('_selfUrl',''),('_membersUrl','/members'),('_policiesUrl','/policies'),('_adminsUrl','/admins')]:d[field]='https://api.victorops.com/api-public/v1/team/'+t['slug']+suffix
 return d
def member(u,i):return {'slug':'member-'+str(i),'username':u}
def shift(p,team,gid,sid):
 d={k:v for k,v in p.items() if k!='usernames'};d.update({'org_slug':'org-fixture','team_slug':team,'group_id':gid,'rot_id':sid,'periods':[],'shiftMembers':[member(u,100+n) for n,u in enumerate(p.get('usernames',[]))],'usernames':p.get('usernames',[])})
 return d
def gget(team,gid):return next(x for x in s['teams'][team]['groups'] if x['id']==gid)
def sget(team,gid,sid):return next(x for x in gget(team,gid)['shifts'] if x['rot_id']==sid)
answer={}
try:
 if p=='/api-public/v1/team':
  if method=='GET':answer=[tmeta(t) for t in s['teams'].values()]
  else:
   assert method=='POST';tid='team-new';assert tid not in s['teams'];s['teams'][tid]={'slug':tid,'name':payload['name'],'description':payload['description'],'version':1,'isDefaultTeam':False,'members':[],'groups':[]};answer=tmeta(s['teams'][tid]);s['policies'].append({'team':{'slug':tid},'policy':{'slug':tid}});s['policy_details'][tid]={'slug':tid,'name':payload['name'],'steps':[],'ignoreCustomPagingPolicies':False}
 elif p.startswith('/api-public/v1/user/'):
  u=p.rsplit('/',1)[1];answer={'username':u,'verified':u!='pending' and u not in s.get('inactive',[]),'email':'private-person@example.invalid'}
 elif p=='/api-public/v1/policies':answer={'policies':s['policies']}
 elif p=='/api-public/v1/org/routing-keys':answer={'routingKeys':s.get('routes',[])}
 elif p=='/api-public/v1/overrides':answer={'overrides':s.get('overrides',[])}
 elif p=='/api-public/v1/maintenancemode':answer={'activeInstances':s.get('maintenance',[])}
 elif p.startswith('/api-public/v1/policies/'):
  slug=p.rsplit('/',1)[1];answer=s['policy_details'][slug]
 elif re.fullmatch('/api-public/v1/team/[^/]+/members',p):
  team=p.split('/')[-2];t=s['teams'][team]
  if method=='POST':t['members'].append({'username':payload['username'],'verified':True});t['version']+=1
  answer={'members':t['members']}
 elif re.fullmatch('/api-public/v1/team/[^/]+',p):
  team=p.rsplit('/',1)[1];t=s['teams'][team]
  if method=='PUT':t.update(payload);t['version']+=1
  if method=='DELETE':
   del s['teams'][team];s['policies']=[x for x in s['policies'] if x['team']['slug']!=team];s['policy_details'].pop(team,None)
  else:answer=tmeta(t)
 elif p.startswith('/api-public/v1/teams/'):
  pieces=p.split('/');team=pieces[4];t=s['teams'][team]
  if len(pieces)==6:
   if method=='GET':answer={'rotationGroups':[{'teamSlug':team,'groupId':g['id'],'slug':'rtg-'+str(g['id']),'label':g['label']} for g in t['groups']]}
   else:
    assert method=='POST';gid=s['gid'];s['gid']+=1;g={'orgslug':'org-fixture','teamslug':team,'id':gid,'label':payload['label'],'shifts':[]}
    for sp in payload.get('shifts',[]):sid=s['sid'];s['sid']+=1;g['shifts'].append(shift(sp,team,gid,sid))
    t['groups'].append(g);answer=g
  else:
   gid=int(pieces[6]);g=gget(team,gid)
   if len(pieces)==7:
    if method=='PUT':g['label']=payload['label']
    elif method=='POST':sid=s['sid'];s['sid']+=1;g['shifts'].append(shift(payload,team,gid,sid))
    elif method=='DELETE':t['groups']=[x for x in t['groups'] if x['id']!=gid]
    answer=g
   else:
    sid=int(pieces[7]);sh=sget(team,gid,sid)
    if len(pieces)==8:
     if method=='PUT':
      kept={k:v for k,v in sh.items() if k not in ['label','timezone','start','duration','shifttype','mask','mask2','mask3']};sh.clear();sh.update(kept);sh.update(payload)
     elif method=='DELETE':g['shifts']=[x for x in g['shifts'] if x['rot_id']!=sid]
     answer=sh
    elif pieces[8]=='members':
     roster=sh['shiftMembers'];u=payload['username']
     if roster:s.setdefault('scheduled',{}).setdefault(str(sid),roster[0]['username'])
     if method=='POST':roster.insert(payload.get('position',len(roster)),member(u,s['member']));s['member']+=1
     else:
      matches=[(i,x) for i,x in enumerate(roster) if x['username']==u and ('memberSlug' not in payload or x['slug']==payload['memberSlug'])];assert len(matches)==1;i,x=matches[0];roster.pop(i)
      if method=='PUT':roster.insert(payload['position'],x)
      elif s.get('scheduled',{}).get(str(sid))==u:s['scheduled'][str(sid)]=payload.get('replacement')
     sh['usernames']=[x['username'] for x in roster]
    else:
     assert pieces[8]=='scheduled'
     if method=='PUT':s.setdefault('scheduled',{})[str(sid)]=payload['username']
     u=s.get('scheduled',{}).get(str(sid)) or next((x['username'] for x in sh['shiftMembers']),None)
     answer=None if u is None else {'username':u,'verified':not s.get('unverified_scheduled',False),'firstName':'Private name'}
 else:raise AssertionError('Unexpected path')
except (KeyError,StopIteration):sys.stdout.write('{}\n404');sys.exit(0)
if method!='GET' and case=='wrong-readback':
 for t in s['teams'].values():t['description']='Unexpected unrelated edit'
if method!='GET' and case=='scheduled-drift':s.setdefault('scheduled',{})['200']='outside-user'
if method!='GET' and case=='scheduled-unverified':s['unverified_scheduled']=True
if case=='paginated' and p=='/api-public/v1/policies':answer['next']='unhandled-page'
f.write_text(json.dumps(s))
if method!='GET' and case=='timeout-after-write':sys.exit(28)
sys.stdout.write('\n204' if method!='GET' and p.endswith('/members') and '/rotations/' in p else json.dumps(answer)+'\n200')
'''
    (bin/'curl').write_text(stub);(bin/'curl').chmod(0o700)
    def reset():
        shutil.rmtree(work/'out',ignore_errors=True)
        state.write_text(json.dumps({'gid':100,'sid':200,'member':300,'scheduled':{},'policies':[],'policy_details':{},'teams':{'team-anchor':{'slug':'team-anchor','name':'Example response','description':'Approved ownership','version':1,'isDefaultTeam':False,'members':[{'username':'alice','verified':True},{'username':'bob','verified':True}],'groups':[]}}}))
        pathlib.Path(str(state)+'.calls').write_text('')
    def check(test,message):
        global checks
        if not test:raise AssertionError(message)
        checks+=1
    def run(op,mode='plan',run_id='action',payload=None,team='',gid='',sid='',case='',owner='',approved=None,config_path=None,target='',extra=None):
        env={k:v for k,v in os.environ.items() if k in ('PATH','SYSTEMROOT')}
        env.update({'PATH':str(bin)+os.pathsep+os.environ['PATH'],'HOME':str(work/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(config_path or config),'SCOUTFLO_ENV_FILE':str(store),'SCOUTFLO_AUDIT_DIR':str(work/'out'),'FIXTURE_STATE':str(state),'FIXTURE_CASE':case,'SOC_MODE':mode,'SOC_OPERATION':op,'SOC_RUN_ID':run_id,'SOC_OBJECT_TEAM':team,'SOC_GROUP_ID':str(gid),'SOC_SHIFT_ID':str(sid),'SOC_CREATED_RUN':owner})
        if target:env['SCOUTFLO_TARGET']=target
        if extra:env.update(extra)
        if payload is not None:env['SOC_CHANGE_JSON']=json.dumps(payload)
        p=work/'out/splunk_oncall'/pathlib.Path(target if target else '.')/('setup-'+run_id)/'plan.json'
        if approved is None and mode in ('apply','restore') and p.exists():
            doc=json.loads(p.read_text());summ=hashlib.sha256(json.dumps(doc,sort_keys=True,separators=(',',':')).encode()).hexdigest();approved=mode+':'+summ
        if approved is not None:env['SOC_APPROVED_PLAN']=approved
        result=subprocess.run(['sh',str(script)],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        check(not any(v in result.stdout for v in ('fixture-id','fixture-read-key','fixture-write-key')),'Credential leaked')
        return result
    def expect(op,mode='plan',**kw):
        r=run(op,mode,**kw);check(r.returncode==0,op+' '+mode+' failed: '+r.stdout);return r
    def fail(op,mode='plan',**kw):
        before=pathlib.Path(str(state)+'.calls').read_text().splitlines();r=run(op,mode,**kw);check(r.returncode!=0,op+' unexpectedly succeeded');after=pathlib.Path(str(state)+'.calls').read_text().splitlines()[len(before):];return r,after
    def pair(op,**kw):expect(op,**kw);expect(op,'apply',**kw)
    mask={'day':{x:True for x in ('su','m','t','w','th','f','sa')},'time':[{'start':{'hour':0,'minute':0},'end':{'hour':0,'minute':0}}]}
    shift={'label':'Example shift','timezone':'UTC','start':1793793600000,'duration':1,'shifttype':'std','mask':mask}
    reset();pair('team-create',payload={'name':'New response team','description':'Owned setup graph'},run_id='create-team')
    applied=json.loads((work/'out/splunk_oncall/setup-create-team/applied.json').read_text());check(applied['created']=={'team':'team-new'},'Created team identity not recorded')
    fail('team-create','apply',payload={},run_id='create-team')
    pair('member-add',team='team-new',payload={'username':'alice'},run_id='add-member')
    fail('member-add',team='team-new',payload={'username':'pending'},run_id='pending')
    pair('team-update',team='team-new',payload={'name':'Updated response team','description':'Updated metadata'},run_id='metadata');expect('team-update','restore',team='team-new',run_id='metadata')
    fail('team-retire',team='team-new',payload={},owner='create-team',run_id='nonempty-team-block')
    # Model separately approved membership removal; only empty owned teams qualify.
    changed=json.loads(state.read_text());changed['teams']['team-new']['members']=[];state.write_text(json.dumps(changed))
    pair('team-retire',team='team-new',payload={},owner='create-team',run_id='retire-team')
    check('team-new' not in json.loads(state.read_text())['teams'],'Team retirement missing')
    expect('team-retire','reconcile',team='team-new',run_id='retire-team')
    reset();pair('rotation-create',payload={'label':'Example rotation','shifts':[{**shift,'usernames':['alice','bob']}]},run_id='rotation')
    pair('rotation-rename',gid=100,payload={'label':'Renamed rotation'},run_id='rename');expect('rotation-rename','restore',gid=100,run_id='rename')
    pair('shift-update',gid=100,sid=200,payload={**shift,'duration':2},run_id='shift-update');expect('shift-update','restore',gid=100,sid=200,run_id='shift-update')
    pair('roster-move',gid=100,sid=200,payload={'username':'bob','position':0},run_id='move');expect('roster-move','restore',gid=100,sid=200,run_id='move')
    pair('scheduled-set',gid=100,sid=200,payload={'username':'bob'},run_id='scheduled')
    pair('roster-remove',gid=100,sid=200,payload={'username':'alice'},run_id='remove')
    fail('roster-remove',gid=100,sid=200,payload={'username':'bob'},run_id='last-person')
    pair('roster-add',gid=100,sid=200,payload={'username':'alice','position':1},run_id='add-roster')
    pair('shift-create',gid=100,payload={**shift,'label':'Second shift'},run_id='new-shift')
    pair('roster-add',gid=100,sid=201,payload={'username':'alice'},run_id='staff-new')
    fail('shift-update',gid=100,sid=201,payload={**shift,'usernames':['bob']},run_id='ignored-usernames')
    pair('shift-retire',gid=100,sid=201,payload={},owner='new-shift',run_id='retire-new')
    pair('shift-retire',gid=100,sid=200,payload={},owner='rotation',run_id='retire-inline')
    pair('rotation-retire',gid=100,payload={},owner='rotation',run_id='retire-rotation')
    check(json.loads(state.read_text())['teams']['team-anchor']['groups']==[],'Rotation cleanup incomplete')
    for case in ('html','duplicate-json','wrong-anchor'):
        reset();r,calls=fail('team-create',payload={'name':'New response team','description':'Safe metadata'},case=case);check(all(x.startswith('GET ') for x in calls),'Invalid read led to a write')
    for case in ('denied','throttled'):
        reset();expect('team-create',payload={'name':'New response team','description':'Safe metadata'});r,calls=fail('team-create','apply',case=case);check(sum(x.startswith('POST ') for x in calls)==1,'Write was retried')
        if case=='throttled':check(calls[-1].startswith('POST '),'429 triggered another request')
    reset();expect('team-create',payload={'name':'New response team','description':'Safe metadata'});expect('team-create','apply',case='timeout-after-write');check('team-new' in json.loads(state.read_text())['teams'],'Uncertain creation was not reconciled by read')
    reset();expect('team-update',payload={'name':'Example response','description':'Changed metadata'});r,calls=fail('team-update','apply',approved='apply:wrong');check(all(x.startswith('GET ') for x in calls),'Wrong approval wrote')
    changed=json.loads(state.read_text());changed['teams']['team-anchor']['version']+=1;state.write_text(json.dumps(changed));r,calls=fail('team-update','apply');check(all(x.startswith('GET ') for x in calls),'Drift wrote')
    reset();expect('team-create',payload={'name':'New response team','description':'Safe metadata'});os.symlink('/dev/null',work/'out/splunk_oncall/setup-action/apply.started');r,calls=fail('team-create','apply');check(all(x.startswith('GET ') for x in calls),'Symlink attempt marker permitted write')
    reset();fail('team-create',payload={'name':'https://example.com','description':'Unsafe metadata'})
    reset();fail('unsupported-operation',payload={})
    reset();pair('rotation-create',payload={'label':'Example rotation','shifts':[]},run_id='rotation');r,calls=fail('team-retire',payload={},owner='rotation',run_id='wrong-owner');check(all(x.startswith('GET ') for x in calls),'Child creation journal authorized team deletion')
    # Existing active policy prevents retirement, even with valid ownership.
    changed=json.loads(state.read_text());changed['policies']=[{'team':{'slug':'team-anchor'},'policy':{'slug':'policy-safe'}}];changed['policy_details']={'policy-safe':{'slug':'policy-safe','steps':[{'entries':[{'executionType':'rotation_group','rotationGroup':{'slug':'rtg-100'}}]}]}};state.write_text(json.dumps(changed));fail('rotation-retire',gid=100,payload={},owner='rotation',run_id='referenced')
    changed['policies'][0]['team']['slug']='another-team';state.write_text(json.dumps(changed));fail('rotation-retire',gid=100,payload={},owner='rotation',run_id='cross-team-reference')
    # The default-policy exception is a narrow announced empty-team operation.
    for fault in ('extra-policy','nonempty-policy','custom-paging','routing-consumer','nested-consumer','override','maintenance'):
        reset();pair('team-create',payload={'name':'New response team','description':'Owned setup graph'},run_id='owned-team')
        changed=json.loads(state.read_text())
        if fault=='extra-policy':
            changed['policies'].append({'team':{'slug':'team-new'},'policy':{'slug':'extra-policy'}})
            changed['policy_details']['extra-policy']={'slug':'extra-policy','name':'Extra policy','steps':[],'ignoreCustomPagingPolicies':False}
        elif fault=='nonempty-policy':changed['policy_details']['team-new']['steps']=[{'timeout':0,'entries':[{'executionType':'user','user':{'username':'alice'}}]}]
        elif fault=='custom-paging':changed['policy_details']['team-new']['ignoreCustomPagingPolicies']=True
        elif fault=='routing-consumer':changed['routes']=[{'routingKey':'private-route','isDefault':False,'targets':[{'policySlug':'team-new'}]}]
        elif fault=='nested-consumer':
            changed['policies'].append({'team':{'slug':'team-anchor'},'policy':{'slug':'nested-policy'}})
            changed['policy_details']['nested-policy']={'slug':'nested-policy','name':'Nested policy','steps':[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'team-new'}}]}],'ignoreCustomPagingPolicies':False}
        else:changed['overrides' if fault=='override' else 'maintenance']=[{}]
        state.write_text(json.dumps(changed));r,calls=fail('team-retire',team='team-new',owner='owned-team',payload={},run_id='retire-guard')
        check(all(x.startswith('GET ') for x in calls),'Empty-team exception allowed '+fault)
    reset();pair('team-create',payload={'name':'New response team','description':'Owned setup graph'},run_id='owned-team')
    expect('team-retire',team='team-new',owner='owned-team',payload={},run_id='empty-retire')
    plan=json.loads((work/'out/splunk_oncall/setup-empty-retire/plan.json').read_text())
    check(plan['provider_side_effects']==['delete the empty implicit default escalation policy'],'Implicit policy deletion was not announced')
    expect('team-retire','apply',team='team-new',run_id='empty-retire')
    check('team-new' not in json.loads(state.read_text())['teams'] and json.loads(state.read_text())['policies']==[],'Owned implicit policy was not removed with team')
    # Scheduled assignment is part of the announced roster effect, not incidental data.
    for op in ('roster-add','roster-move','roster-remove'):
        reset();users=['alice'] if op=='roster-add' else ['alice','bob']
        pair('rotation-create',payload={'label':'Example rotation','shifts':[{**shift,'usernames':users}]},run_id='owned')
        changed=json.loads(state.read_text());changed['scheduled']['200']='alice';state.write_text(json.dumps(changed))
        payload={'username':'bob',**({'position':0} if op=='roster-move' else {})}
        expect(op,gid=100,sid=200,payload=payload,run_id='duty')
        r,calls=fail(op,'apply',gid=100,sid=200,run_id='duty',case='scheduled-drift')
        check(sum(not x.startswith('GET ') for x in calls)==1,'Unapproved duty change retried mutation')
        check(not (work/'out/splunk_oncall/setup-duty/applied.json').exists(),'Foreign scheduled responder was marked verified')
    reset();pair('rotation-create',payload={'label':'Example rotation','shifts':[{**shift,'usernames':['alice','bob']}]},run_id='owned')
    expect('roster-remove',gid=100,sid=200,payload={'username':'alice','replacement':'bob'},run_id='replace-current')
    fail('roster-remove','apply',gid=100,sid=200,run_id='replace-current',case='scheduled-unverified')
    # A malformed target is unknown dependency state, not absence.
    reset();pair('rotation-create',payload={'label':'Example rotation','shifts':[]},run_id='owned')
    for target in ({},{'slug':''},{'slug':'rtg-100','unrecognized':True}):
        changed=json.loads(state.read_text());changed['policies']=[{'team':{'slug':'another-team'},'policy':{'slug':'malformed-policy'}}]
        changed['policy_details']={'malformed-policy':{'slug':'malformed-policy','steps':[{'entries':[{'executionType':'rotation_group','rotationGroup':target}]}]}};state.write_text(json.dumps(changed))
        r,calls=fail('rotation-retire',gid=100,payload={},owner='owned',run_id='malformed')
        check(all(x.startswith('GET ') for x in calls),'Malformed rotation target authorized retirement')
    # Target selection and custom credential names in a store-only fresh shell.
    reset();multi=work/'multi.yaml'
    multi.write_text('splunk_oncall:\n  - label: first\n    api_id_env: ABSENT_ID\n    api_key_env: ABSENT_READ\n    setup_api_key_env: ABSENT_WRITE\n    team_slug: other-team\n  - label: second\n    api_id_env: CUSTOM_ID\n    api_key_env: CUSTOM_READ\n    setup_api_key_env: CUSTOM_WRITE\n    team_slug: team-anchor\n')
    store.write_text("CUSTOM_ID='fixture-id'\nCUSTOM_READ='fixture-read-key'\nCUSTOM_WRITE='fixture-write-key'\nSCOUTFLO_AUDIT_DIR='/must-not-leak-from-store'\n")
    for target in ('','missing'):
        r,calls=fail('team-create',payload={'name':'New response team','description':'Safe metadata'},config_path=multi,target=target)
        check(calls==[],'Unselected multi-target attempted API access')
    pair('team-create',payload={'name':'New response team','description':'Safe metadata'},config_path=multi,target='second')
    check((work/'out/splunk_oncall/second/setup-action/applied.json').exists(),'Labeled target output path missing')
    # Credential generation is part of the plan identity, even with the same label.
    store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nFIXTURE_WRITE='fixture-write-key'\n")
    reset();expect('team-update',payload={'name':'Example response','description':'Changed metadata'})
    store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-write-key'\nFIXTURE_WRITE='fixture-read-key'\n")
    r,calls=fail('team-update','apply');check(all(x.startswith('GET ') for x in calls),'Changed credential generation wrote')
    store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nFIXTURE_WRITE='fixture-read-key'\n")
    r,calls=fail('team-create',payload={'name':'New response team','description':'Safe metadata'});check(calls==[],'Shared read/write key passed setup')
    store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nFIXTURE_WRITE='fixture-write-key'\n")
    # A malformed write response does not prove effect; changed readback stays unknown.
    reset();expect('team-update',payload={'name':'Example response','description':'Changed metadata'})
    r,calls=fail('team-update','apply',case='wrong-readback');check(sum(x.startswith('PUT ') for x in calls)==1,'Mismatched readback retried write')
    check(not (work/'out/splunk_oncall/setup-action/applied.json').exists(),'Mismatched readback recorded success')
    reset();expect('member-add',payload={'username':'charlie'})
    changed=json.loads(state.read_text());changed['inactive']=['charlie'];state.write_text(json.dumps(changed))
    r,calls=fail('member-add','apply');check(all(x.startswith('GET ') for x in calls),'Newly inactive user was added after planning')
    # Existing output records must be rejected before the write, including dangling links.
    reset();expect('team-create',payload={'name':'New response team','description':'Safe metadata'})
    os.symlink(str(work/'missing'),work/'out/splunk_oncall/setup-action/applied.json')
    r,calls=fail('team-create','apply');check(all(x.startswith('GET ') for x in calls),'Dangling applied record permitted write')
    # A run directory is exclusive; neither repeated planning nor default-team mutation is allowed.
    reset();expect('team-create',payload={'name':'New response team','description':'Safe metadata'});fail('team-create',payload={'name':'New response team','description':'Safe metadata'})
    changed=json.loads(state.read_text());changed['teams']['team-anchor']['isDefaultTeam']=True;state.write_text(json.dumps(changed))
    r,calls=fail('team-update',payload={'name':'Example response','description':'Changed metadata'},run_id='default-team');check(all(x.startswith('GET ') for x in calls),'Default team mutation passed')
    reset();r,calls=fail('team-retire',payload={},owner='unavailable',case='paginated');check('Policy dependency census unavailable' in r.stdout,'Unconsumed policy page was treated as a complete census')
    check(all(p.stat().st_mode & 0o077==0 for p in (work/'out').rglob('*.json')),'Private journal permissions widened')
    check(all('private-person@example.invalid' not in p.read_text() and 'Private name' not in p.read_text() for p in (work/'out').rglob('*.json')),'Provider contact fields entered a journal')
    # Nested team metadata must agree even for an unrelated dependency policy.
    reset();pair('rotation-create',payload={'label':'Example rotation','shifts':[]},run_id='nested-owner')
    changed=json.loads(state.read_text());changed['policies']=[{'team':{'slug':'team-anchor'},'policy':{'slug':'nested-parent'}},{'team':{'slug':'team-anchor'},'policy':{'slug':'nested-child'}}]
    changed['policy_details']={'nested-parent':{'slug':'nested-parent','steps':[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'nested-child','teamSlug':'team-anchor','name':'Wrong friendly alias','policyName':'Another alias'}}]}]},'nested-child':{'slug':'nested-child','steps':[]}}
    state.write_text(json.dumps(changed));expect('rotation-retire',gid=100,payload={},owner='nested-owner',run_id='nested-metadata-valid')
    changed['policy_details']['nested-parent']['steps'][0]['entries'][0]['targetPolicy']['teamSlug']='different-team';state.write_text(json.dumps(changed))
    r,calls=fail('rotation-retire',gid=100,payload={},owner='nested-owner',run_id='nested-metadata-wrong');check(all(x.startswith('GET ') for x in calls),'Nested team mismatch authorized rotation retirement')
    print('team-rotation workflows:',checks,'checks passed')
finally:
    shutil.rmtree(work)
PY_TEST
