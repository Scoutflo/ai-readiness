#!/bin/sh
# Fresh-shell execution of the published policy/route recipe. No provider calls.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PYTEST'
import copy,json,os,re,shutil,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]); ref=Path(os.environ.get('SCOUTFLO_ONCALL_RECIPE',str(root/'skills/setup-splunk-oncall/references/policy-routing-workflows.md')))
source=ref.read_text().split('<!-- oncall-policy-routing:start -->',1)[1].split('<!-- oncall-policy-routing:end -->',1)[0].split('```bash\n',1)[1].split('\n```',1)[0]
passed=0

def check(ok,message):
    global passed
    if not ok: raise AssertionError(message)
    passed+=1

stub=r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
if sys.argv[1:]==['--version']:
 print('curl 8.12.0 fixture');sys.exit(0)
a=sys.argv[1:];method=a[a.index('--request')+1]
config={}
for line in sys.stdin.read().splitlines():
 k,v=line.split(' = ',1);config.setdefault(k,[]).append(json.loads(v))
headers=config.get('header',[]);url=config['url'][0];prefix='https://api.victorops.com/api-public/v1/'
assert url.startswith(prefix); path=url[len(prefix):]
assert 'X-VO-Api-Id: fixture-id' in headers
assert any(x in headers for x in ('X-VO-Api-Key: fixture-read-key','X-VO-Api-Key: fixture-write-key'))
if method!='GET':assert 'X-VO-Api-Key: fixture-write-key' in headers
assert '--proto' in a and a[a.index('--proto')+1]=='=https' and '--max-redirs' in a
assert not any('fixture-id' in x or 'fixture-read-key' in x or 'fixture-write-key' in x or x.startswith('https:') for x in a)
state=Path(os.environ['FIXTURE_STATE']); data=json.loads(state.read_text());fault=os.environ.get('FIXTURE_FAULT','')
safe_path='org/routing-keys/{key}' if path.startswith('org/routing-keys/') else path
with Path(str(state)+'.calls').open('a') as f:f.write(json.dumps({'method':method,'path':safe_path,'argv':a})+'\n')
if fault in ('html','redirect','denied','empty','truncated','wrong-type'):
 if fault=='truncated':print('{bad',end='');sys.exit(28)
 print({'html':'<html>login</html>\n200','redirect':'{}\n302','denied':'{"message":"fixture-read-key"}\n401','empty':'\n200','wrong-type':'[]\n200'}[fault],end='');sys.exit(0)
if fault=='write-denied' and method!='GET':print('{"message":"fixture-write-key"}\n401',end='');sys.exit(0)
if fault=='write-throttled' and method!='GET':print('{}\n429',end='');sys.exit(0)
body=json.loads(config['data'][0]) if 'data' in config else None
result={}
if path=='team/team-safe':
 result={'slug':'team-safe','name':'Response team','version':1,'isDefaultTeam':False}
 if fault=='wrong-write-team' and 'X-VO-Api-Key: fixture-write-key' in headers:result['slug']='team-other'
 if fault=='wrong-write-account' and 'X-VO-Api-Key: fixture-write-key' in headers:result['name']='Unrelated response team'
elif path=='team/team-safe/members':result={'members':[{'username':'person-one','verified':True}]}
elif path=='user/person-one':result={'username':'person-one','verified':True}
elif path=='teams/team-safe/rotations':result={'rotationGroups':[{'slug':'rtg-one','teamSlug':'team-safe','groupId':'7','label':'Primary'}]}
elif path=='policies':
 if method=='POST':
  assert set(body)=={'name','teamSlug','steps','ignoreCustomPagingPolicies'} and body['teamSlug']=='team-safe'
  data['policies']['pol-created']={k:v for k,v in body.items() if k!='teamSlug'};data['policies']['pol-created']['slug']='pol-created';data['teams']['pol-created']='team-safe'
  result=data['policies']['pol-created']
 else:result={'policies':[{'policy':{'slug':slug,'name':row['name'],'_selfUrl':'/api-public/v1/policies/'+slug},'team':{'slug':data['teams'][slug],'name':'Response team'}} for slug,row in sorted(data['policies'].items())]}
elif path.startswith('policies/'):
 slug=path.split('/')[1]
 if method=='PUT':
  assert set(body)=={'steps','ignoreCustomPagingPolicies'}
  data['policies'][slug].update(body)
 if method=='DELETE':data['policies'].pop(slug);data['teams'].pop(slug);result={}
 else:result=data['policies'][slug]
elif path=='org/routing-keys' or path.startswith('org/routing-keys/'):
 if method=='POST':
  assert set(body)=={'routingKey','targets'}
  assert body['routingKey'] not in data['routes']
  data['routes'][body['routingKey']]={'targets':body['targets'],'isDefault':False}
  result=body
 elif method=='PUT':
  key=path.split('/')[-1];assert body['routingKey']==key and type(body['isMultiResponder']) is bool
  data['routes'][key]={'targets':body['targets'],'isDefault':False,'isMultiResponder':body['isMultiResponder']};result=body
 elif method=='DELETE':key=path.split('/')[-1];data['routes'].pop(key);result={'result':'success','routingKey':key}
 else:
  result={'routingKeys':[dict({'routingKey':key,'targets':[{'policySlug':x,'policyName':data['policies'][x]['name'],'_teamUrl':'/api-public/v1/team/'+data['teams'][x]} for x in value['targets']],'isDefault':value['isDefault']},**({'isMultiResponder':value['isMultiResponder']} if 'isMultiResponder' in value else {})) for key,value in data['routes'].items()]}
elif path=='overrides':result={'overrides':data['overrides']}
elif path=='alertRules':result=data['rules']
elif path=='maintenancemode':result={'activeInstances':data['maintenance']}
else:raise AssertionError('Unexpected request path '+safe_path)
if fault=='create-readback-shape' and path=='policies/pol-created' and method=='GET':
 result=dict(result);result['futureShape']=True
if fault=='nested-read-metadata' and path.startswith('policies/') and method=='GET':
 for step in result.get('steps',[]):
  for entry in step.get('entries',[]):
   if entry.get('executionType')=='policy_routing':
    target=entry['targetPolicy']['policySlug'];entry['targetPolicy'].update(teamSlug=data['teams'][target],name='Untrusted display alias',policyName='Another display alias')
if fault=='partial-policy-list' and path=='policies' and method=='GET':
 result['policies']=[x for x in result['policies'] if x['policy']['slug']!='pol-other'];result['next']='unconsumed-page'
if fault=='policy-count-mismatch' and path=='policies' and method=='GET':result['total']=len(result['policies'])+1
incomplete={'partial-routing-list':'org/routing-keys','partial-member-list':'team/team-safe/members','partial-rotation-list':'teams/team-safe/rotations','partial-overrides-list':'overrides','partial-maintenance-list':'maintenancemode'}
if fault in incomplete and path==incomplete[fault] and method=='GET':result['next']='unconsumed-page'
if fault=='swap-consumers-during-write' and method=='PUT' and path=='policies/pol-current':
 data['routes']['source-a']['targets']=['pol-other'];data['routes']['source-b']['targets']=['pol-current']
if method!='GET':
 state.write_text(json.dumps(data))
 if fault=='ambiguous':sys.exit(28)
 if fault=='result-symlink':
  p=Path(os.environ['SCOUTFLO_AUDIT_DIR'])/'splunk_oncall'/('setup-'+os.environ['SOC_RUN_ID'])/'apply.result.json';p.symlink_to('/dev/null')
 if fault=='applied-symlink':
  p=Path(os.environ['SCOUTFLO_AUDIT_DIR'])/'splunk_oncall'/('setup-'+os.environ['SOC_RUN_ID'])/'applied.json';p.symlink_to('/dev/null')
print(json.dumps(result)+'\n200',end='')
'''
with tempfile.TemporaryDirectory(prefix='oncall-policy-route-test-') as temp:
 work=Path(temp);(work/'bin').mkdir();(work/'home').mkdir();(work/'patch').mkdir()
 (work/'recipe.sh').write_text(source);subprocess.run(['sh','-n',str(work/'recipe.sh')],check=True)
 (work/'bin/curl').write_text(stub);(work/'bin/curl').chmod(0o755)
 for command in ('aws','gcloud','kubectl','doctl','claude','yq'):
  (work/'bin'/command).write_text('#!/bin/sh\nexit 98\n');(work/'bin'/command).chmod(0o755)
 # Only remove delays in the private process sandbox; HTTP remains a separate stub.
 (work/'patch/sitecustomize.py').write_text('import time\ntime.sleep=lambda seconds: None\n')
 config=work/'config.yaml';config.write_text('splunk_oncall:\n  api_id_env: FIXTURE_ID\n  api_key_env: FIXTURE_READ\n  setup_api_key_env: FIXTURE_WRITE\n  team_slug: team-safe\n')
 store=work/'store';state=work/'state.json';out=work/'out';inputfile=work/'policy.json'
 base={'policies':{'pol-current':{'slug':'pol-current','name':'Current policy','ignoreCustomPagingPolicies':False,'steps':[{'timeout':0,'entries':[{'executionType':'rotation_group','rotationGroup':{'slug':'rtg-one','label':'Primary'}}]}]},'pol-other':{'slug':'pol-other','name':'Other policy','ignoreCustomPagingPolicies':False,'steps':[{'timeout':0,'entries':[{'executionType':'user','user':{'username':'person-one'}}]}]}},'teams':{'pol-current':'team-safe','pol-other':'team-safe'},'routes':{'default-value':{'targets':['pol-other'],'isDefault':True}},'overrides':[],'rules':[],'maintenance':[]}
 base['policies']['team-safe']={'slug':'team-safe','name':'Automatic empty policy','ignoreCustomPagingPolicies':False,'steps':[]};base['teams']['team-safe']='team-safe'
 def reset():
  shutil.rmtree(out,ignore_errors=True);state.write_text(json.dumps(base));Path(str(state)+'.calls').write_text('')
  store.write_text("FIXTURE_ID='fixture-id'\nFIXTURE_READ='fixture-read-key'\nFIXTURE_WRITE='fixture-write-key'\n");store.chmod(0o600)
 def state_edit(fn):
  x=json.loads(state.read_text());fn(x);state.write_text(json.dumps(x))
 def save_input(create=False):
  x={'ignoreCustomPagingPolicies':True,'steps':[{'timeout':2,'entries':[{'executionType':'rotation_group','rotationGroup':{'slug':'rtg-one'}}]}]}
  if create:x['name']='New response policy'
  inputfile.write_text(json.dumps(x));inputfile.chmod(0o600)
 def calls():return [json.loads(x) for x in Path(str(state)+'.calls').read_text().splitlines()]
 def writes():return [x for x in calls() if x['method']!='GET']
 def folder(run):return out/'splunk_oncall'/('setup-'+run)
 def run(operation='policy-replace',mode='plan',runid='replace',approve=False,fault='',extra=None):
  env={'PATH':str(work/'bin')+':'+os.environ['PATH'],'HOME':str(work/'home'),'PYTHONPATH':str(work/'patch'),
       'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(config),'SCOUTFLO_ENV_FILE':str(store),'SCOUTFLO_AUDIT_DIR':str(out),
       'SOC_OPERATION':operation,'SOC_MODE':mode,'SOC_RUN_ID':runid,'SOC_POLICY_SLUG':'pol-current' if operation in ('policy-replace','policy-retire') else '',
       'SOC_POLICY_FILE':str(inputfile),'FIXTURE_STATE':str(state),'FIXTURE_FAULT':fault,'SOC_ROUTE_ENV':'FIXTURE_ROUTE','SOC_ROUTE_TARGETS':'pol-current'}
  if extra:env.update(extra)
  if approve:
   import hashlib
   env['SOC_APPROVED_PLAN']=mode+':'+hashlib.sha256((folder(runid)/'plan.json').read_bytes()).hexdigest()
  p=subprocess.run(['sh',str(work/'recipe.sh')],env=env,capture_output=True,text=True)
  output=p.stdout+p.stderr
  check(not any(x in output for x in ('fixture-id','fixture-read-key','fixture-write-key')),'Credential leaked in output')
  if 'FIXTURE_ROUTE=' in store.read_text():
   route=re.findall("FIXTURE_ROUTE='([^']+)'",store.read_text())[0]
   check(route not in output,'Routing value leaked in output')
   if out.exists():
    for file in out.rglob('*.json'):
     if not file.is_symlink():check(route not in file.read_text(),'Routing value leaked in a journal')
  return p
 def good(p,message):check(p.returncode==0,message+'\n'+p.stdout+p.stderr)
 def bad(p,message):check(p.returncode!=0,message+' unexpectedly passed')
 # Exact independent reproductions: same-size consumer swap and a hidden nested consumer.
 reset();save_input()
 state_edit(lambda x:x['routes'].update({'source-a':{'targets':['pol-current'],'isDefault':False},'source-b':{'targets':['pol-other'],'isDefault':False}}))
 good(run(),'Same-count source impact plan')
 state_edit(lambda x:(x['routes']['source-a'].update(targets=['pol-other']),x['routes']['source-b'].update(targets=['pol-current'])))
 bad(run(mode='apply',approve=True),'Same-count different consumers');check(not writes(),'Same-count consumer swap wrote')
 reset();save_input()
 state_edit(lambda x:x['routes'].update({'source-a':{'targets':['pol-current'],'isDefault':False},'source-b':{'targets':['pol-other'],'isDefault':False}}))
 good(run(),'Postwrite consumer impact plan')
 bad(run(mode='apply',approve=True,fault='swap-consumers-during-write'),'Postwrite consumer preservation')
 check(len(writes())==1 and not (folder('replace')/'applied.json').exists(),'Postwrite consumer drift certified or retried')
 reset();save_input(True)
 good(run(operation='policy-create',runid='hidden-owner'),'Hidden consumer create plan')
 good(run(operation='policy-create',mode='apply',runid='hidden-owner',approve=True),'Hidden consumer create apply')
 state_edit(lambda x:x['policies']['pol-other'].update(steps=[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-created'}}]}]))
 count=len(writes());owned={'SOC_POLICY_SLUG':'pol-created','SOC_CREATED_RUN':'hidden-owner','SOC_UNUSED_CONFIRMED':'yes'}
 bad(run(operation='policy-retire',runid='partial-retire',fault='partial-policy-list',extra=owned),'Partial census hides nested consumer')
 check(len(writes())==count and 'pol-created' in json.loads(state.read_text())['policies'],'Partial census permitted deletion')
 for fault in ('partial-policy-list','policy-count-mismatch','partial-routing-list','partial-rotation-list'):
  reset();save_input();bad(run(fault=fault),fault);check(not writes(),fault+' permitted mutation')
 reset();save_input()
 bad(run(operation='route-create',runid='partial-members',fault='partial-member-list',extra={'SOC_ROUTE_TARGETS':'pol-other'}),'Partial member census');check(not writes(),'Partial member census wrote')
 reset();save_input()
 good(run(),'Policy replacement plan');check(not writes(),'Plan wrote provider state')
 bad(run(mode='apply'),'Apply without exact approval');check(not writes(),'Unapproved write occurred')
 good(run(mode='apply',approve=True),'Policy replacement apply');check(len(writes())==1,'Apply did not write exactly once')
 good(run(mode='restore',approve=True),'Policy replacement restore');check(len(writes())==2,'Restore did not write once')
 check(json.loads(state.read_text())['policies']['pol-current']['ignoreCustomPagingPolicies'] is False,'Restore lost original flag')
 bad(run(mode='apply',approve=True),'Replay');check(len(writes())==2,'Replay wrote again')
 reset();save_input(True)
 good(run(operation='policy-create',runid='created'),'Policy create plan')
 good(run(operation='policy-create',mode='apply',runid='created',approve=True),'Policy create apply')
 good(run(operation='policy-create',mode='inspect',runid='created'),'Inspect created policy')
 p=run(operation='policy-create',mode='inspect',runid='created');check('"present":true' in p.stdout and '"matches_desired":true' in p.stdout,'Inspect lost created identity')
 bad(run(operation='policy-create',mode='restore',runid='created',approve=True),'Create cannot pretend same-ID restore')
 retire={'SOC_POLICY_SLUG':'pol-created','SOC_CREATED_RUN':'created','SOC_UNUSED_CONFIRMED':'yes'}
 good(run(operation='policy-retire',runid='retire',extra=retire),'Owned policy retire plan')
 good(run(operation='policy-retire',mode='apply',runid='retire',approve=True,extra=retire),'Owned policy retire apply')
 good(run(operation='policy-retire',mode='inspect',runid='retire',extra=retire),'Inspect retired policy absence')
 reset();save_input()
 good(run(operation='route-create',runid='route'),'Route create plan')
 check(not writes() and store.stat().st_mode&0o777==0o600,'Route plan called provider or weakened store')
 good(run(operation='route-create',mode='apply',runid='route',approve=True),'Route create apply')
 bad(run(operation='route-replace',runid='route-fix'),'Unknown responder mode cannot be replaced')
 check(len(writes())==1,'Unknown mode wrote')
 state_edit(lambda x:x['routes'][next(k for k in x['routes'] if k!='default-value')].update(isMultiResponder=True))
 good(run(operation='route-replace',runid='route-fix',extra={'SOC_ROUTE_TARGETS':'pol-current,pol-other'}),'Known-mode mapping plan')
 good(run(operation='route-replace',mode='apply',runid='route-fix',approve=True,extra={'SOC_ROUTE_TARGETS':'pol-current,pol-other'}),'Known-mode mapping apply')
 good(run(operation='route-replace',mode='restore',runid='route-fix',approve=True),'Mapping restore')
 route_extra={'SOC_CREATED_RUN':'route','SOC_UNUSED_CONFIRMED':'yes'}
 good(run(operation='route-retire',runid='route-retire',extra=route_extra),'Route retirement plan')
 good(run(operation='route-retire',mode='apply',runid='route-retire',approve=True,extra=route_extra),'Route retirement apply')
 check(len(json.loads(state.read_text())['routes'])==1,'Route retirement harmed default')
 # Retirement must refuse active dependencies, changed object identity and absent ownership proof.
 reset();save_input(True);good(run(operation='policy-create',runid='owned'),'Owned policy dependency plan')
 good(run(operation='policy-create',mode='apply',runid='owned',approve=True),'Owned policy dependency apply')
 policy_owned={'SOC_POLICY_SLUG':'pol-created','SOC_CREATED_RUN':'owned','SOC_UNUSED_CONFIRMED':'yes'}
 count=len(writes());bad(run(operation='policy-retire',runid='partial-overrides',fault='partial-overrides-list',extra=policy_owned),'Partial override census');check(len(writes())==count,'Partial override census wrote')
 state_edit(lambda x:x['routes'].update({'dependent-value':{'targets':['pol-created'],'isDefault':False}}))
 bad(run(operation='policy-retire',runid='dependent-policy',extra=policy_owned),'Policy routing dependency');check(len(writes())==count,'Dependent policy retired')
 state_edit(lambda x:x['routes'].pop('dependent-value'))
 state_edit(lambda x:x['policies']['pol-other'].update(steps=[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-created'}}]}]))
 bad(run(operation='policy-retire',runid='nested-policy',extra=policy_owned),'Nested policy dependency');check(len(writes())==count,'Nested dependency retired')
 state_edit(lambda x:x['policies']['pol-other'].update(steps=copy.deepcopy(base['policies']['pol-other']['steps'])))
 state_edit(lambda x:x['overrides'].append({'purpose':'Fixture override'}))
 bad(run(operation='policy-retire',runid='override-policy',extra=policy_owned),'Unknown override dependency');check(len(writes())==count,'Override dependency retired')
 state_edit(lambda x:x['overrides'].clear())
 bad(run(operation='policy-retire',runid='wrong-owner',extra=dict(policy_owned,SOC_POLICY_SLUG='pol-current')),'Wrong creation identity');check(len(writes())==count,'Unowned policy retired')
 reset();save_input();good(run(operation='route-create',runid='owned-route'),'Owned route plan')
 good(run(operation='route-create',mode='apply',runid='owned-route',approve=True),'Owned route apply')
 route_key=next(k for k in json.loads(state.read_text())['routes'] if k!='default-value')
 route_owned={'SOC_CREATED_RUN':'owned-route','SOC_UNUSED_CONFIRMED':'yes'};count=len(writes())
 bad(run(operation='route-retire',runid='partial-maintenance',fault='partial-maintenance-list',extra=route_owned),'Partial maintenance census');check(len(writes())==count,'Partial maintenance census wrote')
 state_edit(lambda x:x['rules'].append({'routeKey':route_key}))
 bad(run(operation='route-retire',runid='dependent-route',extra=route_owned),'Alert-rule route dependency');check(len(writes())==count,'Dependent route retired')
 state_edit(lambda x:x['rules'].clear());state_edit(lambda x:x['maintenance'].append({'isGlobal':False,'targets':[{'type':'RoutingKeys','names':[route_key]}]}))
 bad(run(operation='route-retire',runid='maintenance-route',extra=route_owned),'Maintenance route dependency');check(len(writes())==count,'Maintenance route retired')
 state_edit(lambda x:x['maintenance'].clear())
 bad(run(operation='route-retire',runid='no-use-proof',extra=dict(route_owned,SOC_UNUSED_CONFIRMED='')),'Missing external no-use proof');check(len(writes())==count,'Unconfirmed route retired')
 good(run(operation='route-retire',runid='changed-route-census',extra=route_owned),'Route retirement census plan')
 state_edit(lambda x:x['routes']['default-value'].update(isMultiResponder=True))
 bad(run(operation='route-retire',mode='apply',runid='changed-route-census',approve=True,extra=route_owned),'Unrelated route drift');check(len(writes())==count,'Routing census drift wrote')
 store.write_text(store.read_text().replace(route_key,'different-private-value'))
 bad(run(operation='route-retire',mode='apply',runid='changed-route-census',approve=True,extra=route_owned),'Changed routing value');check(len(writes())==count,'Changed routing secret wrote')
 # Failure probes must stop before any mutation.
 for fault in ('html','empty','redirect','denied','truncated','wrong-type','wrong-write-team','wrong-write-account'):
  reset();save_input();bad(run(fault=fault),fault);check(not writes(),fault+' wrote')
 reset();save_input();good(run(),'Drift plan');state_edit(lambda x:x['policies']['pol-current'].update(ignoreCustomPagingPolicies=True))
 bad(run(mode='apply',approve=True),'Prewrite drift');check(not writes(),'Drift wrote')
 reset();save_input();good(run(),'Credential plan');store.write_text(store.read_text().replace('fixture-write-key','replacement-write-key'))
 bad(run(mode='apply',approve=True),'Credential rotation');check(not writes(),'Changed credentials wrote')
 reset();save_input();good(run(),'Payload plan');plan=folder('replace')/'plan.json';d=json.loads(plan.read_text());d['after']['unexpected']='field';plan.write_text(json.dumps(d))
 bad(run(mode='apply',approve=True),'Mutated saved payload');check(not writes(),'Invalid payload wrote')
 reset();save_input();good(run(),'Symlink plan');(folder('replace')/'apply.result.json').symlink_to('/dev/null')
 bad(run(mode='apply',approve=True),'Result symlink');check(not writes(),'Pre-existing symlink wrote')
 for fault in ('write-denied','write-throttled','result-symlink','applied-symlink'):
  reset();save_input();good(run(),'Write failure plan');bad(run(mode='apply',approve=True,fault=fault),fault)
  check(len(writes())==1,fault+' retried');check((folder('replace')/'apply.started').exists(),'Attempt marker lost')
  if fault=='write-throttled':check(calls()[-1]['method']=='PUT','429 caused immediate extra request')
  bad(run(mode='apply',approve=True),'Attempt replay');check(len(writes())==1,'Attempt replay wrote')
 reset();save_input(True);good(run(operation='policy-create',runid='unknown'),'Ambiguous create plan')
 good(run(operation='policy-create',mode='apply',runid='unknown',approve=True,fault='ambiguous'),'Ambiguous create reconciles by read')
 check(len(writes())==1,'Ambiguous POST retried')
 reset();save_input();store.write_text(store.read_text()+"FIXTURE_ROUTE='default-value'\n")
 bad(run(operation='route-replace',runid='default'),'Default route protected');check(not writes(),'Default route mutated')
 # A created object whose readback failed is reconciled by reads, never POST.
 import hashlib
 def failed_create():
  reset();save_input(True);good(run(operation='policy-create',runid='recovery'),'Interrupted create plan')
  bad(run(operation='policy-create',mode='apply',runid='recovery',approve=True,fault='create-readback-shape'),'Readback shape must fail after POST')
  check(len(writes())==1 and (folder('recovery')/'apply.started').exists() and not (folder('recovery')/'applied.json').exists(),'Attempt was not preserved')
  return hashlib.sha256((folder('recovery')/'plan.json').read_bytes()).hexdigest()
 def recover(original,extra=None):
  return run(operation='policy-create',mode='reconcile',runid='recovery',extra={'SOC_APPROVED_PLAN':'apply:'+original,**(extra or {})})
 original=failed_create();good(recover(original),'Read-only ownership reconciliation')
 check(len(writes())==1,'Reconcile sent a write')
 recovered=json.loads((folder('recovery')/'applied.json').read_text());check(recovered['object_id']=='pol-created' and recovered['provenance']=='reconciled-without-retry','Reconciled receipt missing provenance')
 check((folder('recovery')/'apply.started').exists(),'Reconcile cleared attempt marker')
 bad(recover(original),'Repeated reconciliation must not replace receipt');check(len(writes())==1,'Repeated reconcile wrote')
 good(run(operation='policy-retire',runid='recovered-retire',extra={'SOC_POLICY_SLUG':'pol-created','SOC_CREATED_RUN':'recovery','SOC_UNUSED_CONFIRMED':'yes'}),'Reconciled ownership can prepare normal guarded retirement')
 for mutation in ('no-attempt','ambiguous','payload','census','routes','plan-binding'):
  original=failed_create()
  if mutation=='no-attempt':(folder('recovery')/'apply.started').unlink()
  elif mutation=='ambiguous':state_edit(lambda x:(x['policies'].update({'pol-second':{**x['policies']['pol-created'],'slug':'pol-second'}}),x['teams'].update({'pol-second':'team-safe'})))
  elif mutation=='payload':state_edit(lambda x:x['policies']['pol-created']['steps'][0].update(timeout=99))
  elif mutation=='census':state_edit(lambda x:x['policies']['pol-other'].update(name='Renamed by another operator'))
  elif mutation=='routes':state_edit(lambda x:x['routes'].update({'another-private-key':{'targets':['pol-current'],'isDefault':False}}))
  else:
   f=folder('recovery')/'apply.started';v=json.loads(f.read_text());v['plan_sha256']='0'*64;f.write_text(json.dumps(v))
  bad(recover(original),'Reconcile must refuse '+mutation);check(not (folder('recovery')/'applied.json').exists() and len(writes())==1,'Unsafe recovery granted ownership or wrote: '+mutation)
 original=failed_create();f=folder('recovery')/'apply.started';v=json.loads(f.read_text());v.pop('plan_sha256');f.write_text(json.dumps(v))
 bad(recover(original),'Legacy attempt requires original receipt checksum')
 bad(recover(original,{'SOC_LEGACY_ATTEMPT_PLAN_SHA256':'0'*64}),'Wrong legacy checksum')
 good(recover(original,{'SOC_LEGACY_ATTEMPT_PLAN_SHA256':original}),'Explicit original legacy checksum and exact state permit recovery')
 check(len(writes())==1,'Legacy recovery retried creation')
 # A same-name policy on another team is never selected by accident.
 reset();save_input();state_edit(lambda x:x['teams'].update({'pol-current':'team-other'}))
 bad(run(),'Wrong-team policy');check(not writes(),'Wrong-team policy changed')
 # Every input entry must use exactly its matching documented target shape.
 for alter in ('empty','unknown','two-targets','bad-timeout','self-cycle'):
  reset();save_input();d=json.loads(inputfile.read_text())
  if alter=='empty':d['steps']=[]
  if alter=='unknown':d['steps'][0]['entries'][0]['executionType']='team'
  if alter=='two-targets':d['steps'][0]['entries'][0]['user']={'username':'person-one'}
  if alter=='bad-timeout':d['steps'][0]['timeout']=-1
  if alter=='self-cycle':d['steps'][0]['entries']=[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-current'}}]
  inputfile.write_text(json.dumps(d));bad(run(),alter);check(not writes(),alter+' wrote')
 # Operator inputs must not silently become the first target in a list.
 reset();save_input();config.write_text('splunk_oncall:\n  - label: primary\n    api_id_env: FIXTURE_ID\n    api_key_env: FIXTURE_READ\n    setup_api_key_env: FIXTURE_WRITE\n    team_slug: team-safe\n')
 bad(run(),'Missing target label');check(not writes(),'Missing label wrote')
 good(run(extra={'SCOUTFLO_TARGET':'primary'}),'Explicit list label')
 # Populated GET metadata is asserted before it is stripped from write payloads.
 config.write_text('splunk_oncall:\n  api_id_env: FIXTURE_ID\n  api_key_env: FIXTURE_READ\n  setup_api_key_env: FIXTURE_WRITE\n  team_slug: team-safe\n')
 reset();save_input();nested=json.loads(inputfile.read_text());nested['steps']=[{'timeout':5,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-other'}}]}];inputfile.write_text(json.dumps(nested))
 good(run(runid='nested-live-shape'),'Nested policy plan')
 good(run(mode='apply',runid='nested-live-shape',approve=True,fault='nested-read-metadata'),'Nested populated teamSlug readback')
 check((folder('nested-live-shape')/'applied.json').exists(),'Nested observed shape did not verify')
 reset();save_input();state_edit(lambda x:x['policies']['pol-current'].update(steps=[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-other','teamSlug':'wrong-team','name':'Other policy','policyName':'Current policy'}}]}]))
 bad(run(runid='wrong-nested-team'),'Contradictory nested target team');check(not writes(),'Contradictory nested owner permitted a write')
 reset();save_input(True);good(run(operation='policy-create',runid='nested-owner'),'Owned policy for dependency read');good(run(operation='policy-create',mode='apply',runid='nested-owner',approve=True),'Create owned fixture')
 state_edit(lambda x:x['policies']['pol-other'].update(steps=[{'timeout':0,'entries':[{'executionType':'policy_routing','targetPolicy':{'policySlug':'pol-current','teamSlug':'team-safe','policyName':'Harmless alias','name':'Different alias'}}]}]))
 owned={'SOC_POLICY_SLUG':'pol-created','SOC_CREATED_RUN':'nested-owner','SOC_UNUSED_CONFIRMED':'yes'}
 good(run(operation='policy-retire',runid='nested-unrelated-valid',extra=owned),'Known unrelated nested consumer census')
 count=len(writes());state_edit(lambda x:x['policies']['pol-other']['steps'][0]['entries'][0]['targetPolicy'].update(teamSlug='wrong-team'))
 bad(run(operation='policy-retire',runid='nested-unrelated-wrong',extra=owned),'Unrelated nested ownership mismatch must still block retirement');check(len(writes())==count,'Unrelated ownership mismatch permitted deletion')
 print('policy-routing workflows: '+str(passed)+' assertions passed; no provider calls')
PYTEST
