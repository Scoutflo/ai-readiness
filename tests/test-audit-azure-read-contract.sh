#!/bin/sh
# Execute the shipped fences with an isolated home and recording provider stubs.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ROOT
python3 - <<'PY'
import copy,json,os,pathlib,re,shutil,subprocess,tempfile
P=pathlib.Path; root=P(os.environ.get('AZURE_TEST_SOURCE',os.environ['ROOT']))
files=['skills/audit-azure/SKILL.md','skills/audit-azure/references/azure-checks.md','skills/audit-azure/references/azure-cost-checks.md']
blocks=[re.findall(r'```bash\n(.*?)```',(root/f).read_text(),re.S) for f in files]
failures=[]; total=0
with tempfile.TemporaryDirectory(prefix='azure-read-contract-') as temp:
 base=P(temp); (base/'scratch').mkdir(); (base/'bin').mkdir(); (base/'home/.scoutflo').mkdir(parents=True)
 cfg=base/'config.yaml'; cfg.write_text('azure:\n  - label: core\n    subscription_id: sub-a\n  - label: data\n    subscription_id: sub-b\n    tenant_id: tenant-b\nslack:\n  webhook_env: SELECTED_SLACK\n')
 stub=r'''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path; f=p(os.environ['STUB_FIXTURE']); fixture=json.loads(f.read_text()); args=sys.argv[1:]; name=p(sys.argv[0]).name
with open(os.environ['STUB_LOG'],'a') as out:
 if name=='az': out.write(json.dumps(dict(tool=name,args=args))+'\n')
 elif name=='curl' and args!=['--version']:
  url=args[-1]; headers=[args[i+1] for i,x in enumerate(args[:-1]) if x=='-H']
  data=args[args.index('-d')+1] if '-d' in args else None
  if data=='@-': data=sys.stdin.read()
  out.write(json.dumps(dict(tool=name,url=url,bearer=any(x.startswith('Authorization: Bearer ') and len(x)>22 for x in headers),args=[x for x in args if not x.startswith('Authorization:')],data=data))+'\n')
if name=='curl':
 if args==['--version']: print('curl 8.10.1');sys.exit()
 idx=p(os.environ['STUB_INDEX']); n=int(idx.read_text()) if idx.exists() else 0;idx.write_text(str(n+1))
 responses=fixture.get('responses',[dict(body={'value':[]})]); r=responses[min(n,len(responses)-1)]
 if r.get('exit'): sys.exit(r['exit'])
 body=r.get('body',{'value':[]}); body=body if isinstance(body,str) else json.dumps(body)
 fmt=args[args.index('-w')+1] if '-w' in args else ''
 if '%{http_code}' in fmt: print(body+'\n'+str(r.get('status',200))+ ('\t'+r.get('retry','') if '%header' in fmt else ''),end='')
 else: print(body,end='')
 sys.exit()
if name=='az':
 if args[:2]==['account','list']: print(json.dumps(fixture.get('accounts',[{'id':'sub-a','name':'Primary','tenantId':'tenant-a'},{'id':'sub-b','name':'Data','tenantId':'tenant-b'}])));sys.exit()
 if args[:2]==['account','show']:
  sub=args[args.index('--subscription')+1] if '--subscription' in args else 'ambient-sub'
  print(json.dumps(dict(id=sub,name='Data',tenantId=fixture.get('tenant','tenant-b'),user={'name':'review-identity'})));sys.exit()
 if args[:2]==['account','get-access-token']: print(fixture.get('token','synthetic-token'));sys.exit()
 if args[:1]==['version']: print('2.80.0');sys.exit()
 cli=fixture.get('cli',{}); keys=sorted(cli,key=len,reverse=True)
 match=next((k for k in keys if args[:len(k.split())]==k.split()),None)
 if match:
  value=cli[match]
  if isinstance(value,dict) and '_exit' in value: sys.exit(value['_exit'])
 else: value=[]
 print(json.dumps(value));sys.exit()
if name=='sleep': sys.exit()
sys.exit('unexpected provider command')
'''
 for name in ('az','curl','sleep'):
  f=base/'bin'/name;f.write_text(stub);f.chmod(0o755)
 # Any accidentally added cloud/network tool must fail locally, never find a real binary.
 for name in ('aws','gcloud','kubectl','wget','ssh','nc'):
  f=base/'bin'/name;f.write_text('#!/bin/sh\nexit 97\n');f.chmod(0o755)
 env=dict(os.environ,HOME=str(base/'home'),PATH=str(base/'bin')+':'+os.environ['PATH'],CLAUDE_PLUGIN_ROOT=str(root),SCOUTFLO_CONFIG=str(cfg),SCOUTFLO_TARGET='data',SCOUTFLO_RUN_DATE='2026-01-02',SCOUTFLO_AUDIT_DIR=str(base/'out'),STUB_FIXTURE=str(base/'fixture.json'),STUB_LOG=str(base/'calls.jsonl'),STUB_INDEX=str(base/'index'))
 for key in ('SCOUTFLO_ENV_FILE','SCOUTFLO_SLACK_WEBHOOK','SELECTED_SLACK','SCOUTFLO_SUPPRESS_SLACK','SCOUTFLO_AZURE_WORKER'):env.pop(key,None)
 raw=base/'out/azure/data/2026-01-02/raw'
 def reset(fixture=None):
  shutil.rmtree(base/'out',ignore_errors=True);raw.mkdir(parents=True)
  (base/'fixture.json').write_text(json.dumps(fixture or {}));(base/'calls.jsonl').write_text('');(base/'index').unlink(missing_ok=True)
  for n in ('action-groups','metric-alerts','scheduled-query-rules','activity-log-alerts','vms','vmss','app-gateways','load-balancers','aks-list','log-workspaces'):(raw/(n+'.json')).write_text('[]')
 def run(code,extra=None):return subprocess.run(['/bin/sh','-c',code],cwd=base,env=env| (extra or {}),capture_output=True,text=True,timeout=25)
 def calls():return [json.loads(x) for x in (base/'calls.jsonl').read_text().splitlines()]
 def check(name,condition,detail=''):
  global total
  total+=1
  if not condition:failures.append(name+': '+detail[:800]);print('FAIL',name,detail[:250])
  else: print('PASS',name)
 def write(name,value):(raw/(name+'.json')).write_text(json.dumps(value))
 def b(lane,index):return blocks[lane][index-1].replace('/tmp/',str(base/'scratch')+'/')
 for lane,fences in enumerate(blocks):
  for i,code in enumerate(fences,1):
   r=subprocess.run(['/bin/sh','-n'],input=code,text=True,capture_output=True)
   check(f'syntax {lane}:{i}',r.returncode==0,r.stderr)
 reset();r=run(b(1,2));check('inventory selected target completes',r.returncode==0,r.stderr)
 check('all CLI reads pin selected subscription',all('--subscription' in c['args'] and 'sub-b' in c['args'] for c in calls() if c['tool']=='az' and c['args'][:2]!=['account','list']),str(calls()))
 check('all ARM lists pin selected subscription',all('/subscriptions/sub-b/' in c['url'] for c in calls() if c['tool']=='curl'))
 check('selected output exists without flat output',(raw/'action-groups.json').exists() and not (base/'out/azure/2026-01-02').exists())
 reset();r=run(b(1,2),{'SCOUTFLO_TARGET':''});check('unselected list blocks before calls',r.returncode!=0 and not calls(),r.stderr)
 reset();r=run(b(1,2),{'SCOUTFLO_TARGET':'absent'});check('unknown label blocks before calls',r.returncode!=0 and not calls(),r.stderr)
 reset({'tenant':'wrong'});r=run(b(0,1));check('tenant mismatch prevents transport',r.returncode!=0 and not any(c['tool']=='curl' for c in calls()),r.stderr)
 reset({'token':''});r=run(b(0,1));check('empty bearer never reaches transport',r.returncode!=0 and not any(c['tool']=='curl' for c in calls()),r.stderr)
 reset({'responses':[{'body':'<html>Login</html>'}]});r=run(b(0,1));check('HTML 200 rejected',r.returncode!=0,r.stdout)
 reset();config=cfg.read_text();cfg.write_text('azure:\n  subscription_id: Data\n')
 reset({'accounts':[{'id':'sub-a','name':'Data'},{'id':'sub-b','name':'Data'}]});r=run(b(0,1),{'SCOUTFLO_TARGET':'azure'});check('ambiguous subscription name blocked',r.returncode!=0 and not any(c['tool']=='curl' for c in calls()),r.stderr);cfg.write_text(config)
 reset();write('metric-alerts',[{'name':'disabled','enabled':False,'scopes':['resource-a'],'actionGroups':[]}]);r=run(b(1,6));check('disabled rule not enabled coverage','DISABLED-ONLY: resource-a' in r.stdout and 'ENABLED: resource-a' not in r.stdout,r.stdout+r.stderr)
 reset();write('activity-log-alerts',[{'name':'disabled','enabled':False,'categories':['ServiceHealth','ResourceHealth'],'actionGroups':[]}]);r=run(b(1,4));check('disabled activity rule not coverage','ServiceHealth' not in r.stdout and r.returncode==0,r.stdout+r.stderr)
 live='/subscriptions/sub-b/resourceGroups/live/providers/Microsoft.Insights/actionGroups/ops';dead=live.replace('/live/','/dead/')
 reset();write('action-groups',[{'name':'ops','id':live,'enabled':True,'receivers':{'emailReceivers':1}},{'name':'ops','id':dead,'enabled':True,'receivers':{'emailReceivers':0}}]);write('metric-alerts',[{'name':'r','enabled':True,'scopes':['resource-a'],'actionGroups':[live]}]);r=run(b(1,3));check('qualified group join avoids name collision',r.returncode==0 and 'MUTE-ROUTE' not in r.stdout,r.stdout+r.stderr)
 write('metric-alerts',[{'name':'r','enabled':True,'scopes':['resource-a'],'actionGroups':[dead]}]);r=run(b(1,3));check('actual receiverless route detected','MUTE-ROUTE' in r.stdout,r.stdout+r.stderr)
 for lane,index,key in [(1,5,'monitor alert-processing-rule list'),(1,16,'monitor diagnostic-settings list')]:
  reset({'cli':{key:{'_exit':7}}});write('app-gateways',[{'name':'edge','id':'/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.Network/applicationGateways/edge'}]);r=run(b(lane,index));check('denied CLI remains blocked '+str(index),(r.returncode!=0 and 'blocked' in r.stderr) if index==5 else ('"result": "blocked"' in r.stdout and '"diagnostic_settings": null' in r.stdout),r.stdout+r.stderr)
 reset({'cli':{'aks show':{},'monitor diagnostic-settings list':[]}});write('aks-list',[{'name':'cluster-a','rg':'r','id':'/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.ContainerService/managedClusters/cluster-a'}]);r=run(b(1,10));check('AKS hyphenated name binds as data',r.returncode==0 and 'cluster-a' in r.stdout,r.stdout+r.stderr)
 path='/subscriptions/sub-b/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01';url='https://management.azure.com'+path
 helper='set -eu\n. "$CLAUDE_PLUGIN_ROOT/skills/audit-azure/scripts/read-context.sh"\nazure_identity\n'
 arm=helper+'''arm_list '/subscriptions/sub-b/providers/Microsoft.Insights/actionGroups?api-version=2023-01-01' '[.value[]|{name}]'\n'''
 reset({'responses':[{'body':{'value':[{'name':'a'}],'nextLink':'https://untrusted.invalid/next'}}]});r=run(arm);check('foreign nextLink never requested',r.returncode!=0 and len([c for c in calls() if c['tool']=='curl'])==1,r.stdout+r.stderr)
 reset({'responses':[{'body':{'value':[{'name':'a'}],'nextLink':url}}]});r=run(arm);check('repeated nextLink stops',r.returncode!=0 and len([c for c in calls() if c['tool']=='curl'])==1,r.stdout+r.stderr)
 reset({'responses':[{'body':{'value':[{'name':'a'}],'nextLink':url+'&page=2'}},{'body':{'value':[{'name':'b'}]}}]});r=run(arm);check('ARM continuation complete',r.returncode==0 and len(json.loads(r.stdout))==2,r.stdout+r.stderr)
 reset({'responses':[{'exit':28}]});r=run(arm);check('timeout remains incomplete',r.returncode!=0 and 'incomplete' in r.stderr,r.stdout+r.stderr)
 sentinel='SYNTHETIC_RECEIVER_SENTINEL';reset({'responses':[{'body':{'value':[{'id':live,'name':'ops','properties':{'enabled':True,'webhookReceivers':[{'serviceUri':sentinel}]}}]}}]});r=run(b(1,2));leaks=[]
 for f in (base/'out').rglob('*'):
  if f.is_file() and sentinel in f.read_text():leaks.append(str(f))
 check('receiver value absent from saved/output evidence',sentinel not in r.stdout and not leaks,str(leaks))
 for status in (403,429):
  reset({'responses':[{'status':status,'body':{'error':{'code':'denied'}}}]});r=run(b(2,4));check('terminal cost status blocks '+str(status),r.returncode!=0 and 'blocked' in r.stderr and 'columns' not in r.stdout,r.stdout+r.stderr)
  check('HTTP calls bounded '+str(status),all('--max-time' in c['args'] and '--max-filesize' in c['args'] and '-q' in c['args'] for c in calls() if c['tool']=='curl'))
  if status==429:check('429 exhausts five bounded attempts',len([c for c in calls() if c['tool']=='curl'])==5,r.stderr)
 reset({'responses':[{'body':{'data':[{'id':'a'}],'count':1,'totalRecords':2,'$skipToken':'page-two'}},{'body':{'data':[{'id':'b'}],'count':1,'totalRecords':2,'resultTruncated':'false'}}]});r=run(helper+'rg_query "Resources | project id"');check('Resource Graph continuation complete',r.returncode==0 and json.loads(r.stdout)['count']==2,r.stdout+r.stderr)
 posts=[c for c in calls() if c['tool']=='curl'];check('continuation keeps selected scope',len(posts)==2 and json.loads(posts[1]['data'])['subscriptions']==['sub-b'] and json.loads(posts[1]['data'])['options']['$skipToken']=='page-two',str(posts))
 reset({'responses':[{'body':{'data':[{'id':'a'}],'count':1,'totalRecords':2}}]});r=run(helper+'rg_query "Resources | project id"');check('missing Resource Graph continuation blocks',r.returncode!=0 and 'incomplete' in r.stderr,r.stdout+r.stderr)
 reset({'responses':[{'status':403,'body':{'error':{'code':'denied'}}},{'body':{'data':[{'resource_count':0}],'count':1,'totalRecords':1}}]});r=run(b(2,2));check('cost access is per-check without nonexistent doctor row',r.returncode==0 and json.loads(r.stdout)=={'AZROPT-001':'available','AZROPT-002':'unavailable','AZROPT-003..007':'available'} and all('/subscriptions/sub-b/' in c['url'] or '/providers/Microsoft.ResourceGraph/' in c['url'] for c in calls() if c['tool']=='curl'),r.stdout+r.stderr)
 reset();write('metric-alerts',[{'name':'fanout','enabled':True,'actionGroups':[live,dead],'description_length':100,'windowSize':'PT5M','severity':2}]);r=run(b(1,17));check('fanout remains candidate not proven duplicate','MULTI-DESTINATION-CANDIDATE' in r.stdout and 'DOUBLE-PAGE' not in r.stdout,r.stdout+r.stderr)
 reset();r=run(b(0,3));r2=run(b(0,4));check('fresh scope reads persisted sizing state',r.returncode==0 and r2.returncode==0,r.stderr+r2.stderr)
 reset();before=base/'out/azure/data/2026-01-01';before.mkdir();(before/'findings.json').write_text(json.dumps({'findings':[{'id':'AZR-001'},{'id':'AZR-002'}]}));now=raw.parent
 for name in ('setup-2026-01-01','2026-01-03','2025-99-99'):
  decoy=base/'out/azure/data'/name;decoy.mkdir();(decoy/'findings.json').write_text(json.dumps({'findings':[{'id':'AZR-999'}]}))
 (now/'findings.json').write_text(json.dumps({'findings':[],'checks':[{'id':'AZR-001','result':'pass'},{'id':'AZR-002','result':'blocked'}],'score':{'overall':50,'state':'assessed','scoring_model':'v2','check_set':'test','assessment':{'coverage_percent':50},'gate':{},'end_to_end':False},'severity_counts':{}}));r=run(b(0,7));history=base/'out/azure/data/history.jsonl';check('history ignores setup future and invalid dates and resolves only passing IDs',r.returncode==0 and history.exists() and json.loads(history.read_text())['lifecycle_counts']['resolved']==1,r.stdout+r.stderr)
 reset();r=run(b(0,8),{'SCOUTFLO_SUPPRESS_SLACK':'1'});check('orchestrated Slack stays quiet',r.returncode==0 and not calls(),r.stdout+r.stderr)
 reset();worker={'SCOUTFLO_AZURE_WORKER':'worker-a'};id='/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/vm-a';write('vms',[{'id':id,'name':'vm-a'}]);wl='sh "$CLAUDE_PLUGIN_ROOT/skills/audit-azure/scripts/worklist.sh" '
 r=run(wl+'start',worker);r2=run(wl+'claim',worker);r3=run(wl+'assert',worker);check('worklist creates claims and blocks unfinished report',r.returncode==0 and r2.returncode==0 and r3.returncode!=0,r.stderr+r2.stderr+r3.stderr)
 r=run(wl+'claim',{'SCOUTFLO_AZURE_WORKER':'other'});check('other worker cannot duplicate claim',r.returncode!=0,r.stderr)
 r=run(b(1,9),worker);r2=run(wl+'assert',worker);check('successful resource reads create verified receipt',r.returncode==0 and r2.returncode==0,r.stdout+r.stderr+r2.stderr)
 r=run(wl+'claim',worker|{'SCOUTFLO_RUN_DATE':'2026-01-03'});check('resume across date skips completed resources',r.returncode==0 and not r.stdout.strip(),r.stdout+r.stderr)
 # Mutate one live predicate in the extracted block: the regression must notice.
 reset();write('metric-alerts',[{'name':'disabled','enabled':False,'scopes':['resource-a'],'actionGroups':[]}]);mut=b(1,6).replace('.enabled==true','(.enabled//true)==true');r=run(mut);check('disabled-rule mutation reproduces false coverage','ENABLED: resource-a' in r.stdout,r.stdout+r.stderr)
 # Additional failure controls and configured destination behavior.
 reset({'responses':[{'body':{'value':[],'nextLink':url.replace('/sub-b/','/sub-a/')}}]});r=run(arm);check('cross-subscription continuation refused before request',r.returncode!=0 and len([c for c in calls() if c['tool']=='curl'])==1,r.stdout+r.stderr)
 reset({'responses':[{'body':{'data':[{'id':'a'}],'count':1,'totalRecords':3,'$skipToken':'same'}}]});r=run(helper+'rg_query "Resources | project id"');check('repeated Resource Graph token blocks',r.returncode!=0 and 'repeated' in r.stderr,r.stdout+r.stderr)
 reset({'responses':[{'body':{'data':[{'id':'a'}],'count':1,'totalRecords':2,'$skipToken':'next'}},{'body':{'data':[{'id':'b'}],'count':1,'totalRecords':3}}]});r=run(helper+'rg_query "Resources | project id"');check('Resource Graph cohort drift blocks',r.returncode!=0 and 'changed' in r.stderr,r.stdout+r.stderr)
 reset({'responses':[{'status':429,'retry':'60','body':{}}]});r=run(b(2,4));check('long Retry-After stops without aggressive retries',r.returncode!=0 and len([c for c in calls() if c['tool']=='curl'])==1,r.stderr)
 reset({'responses':[{'body':{'properties':{'columns':[],'rows':[],'nextLink':url}}}]});r=run(b(2,4));check('paginated spend aggregate is unavailable not partial total',r.returncode!=0,r.stdout+r.stderr)
 reset({'cli':{'monitor diagnostic-settings list':{'value':[{'name':'d','properties':{'workspaceId':'workspace','logs':[{'enabled':True,'category':'Audit'}]}}]}}});r=run(helper+"azure_diagnostics '/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/vm-a' ");check('known diagnostic wrapper is projected safely',r.returncode==0 and json.loads(r.stdout)[0]['workspaceId']=='workspace',r.stdout+r.stderr)
 summary={'findings':[],'checks':[],'score':{'overall':None,'state':'unassessed','scoring_model':'v2','check_set':'test','assessment':{'assessed_checks':0,'applicable_checks':1,'coverage_percent':0,'scored_checks':0,'blocked_checks':1,'suppressed_checks':0},'end_to_end':False,'categories':[]},'severity_counts':{'critical':0,'high':0,'medium':0,'low':0}}
 def slack_fixture():
  reset({'responses':[{'body':'ok'}]});(raw.parent/'findings.json').write_text(json.dumps(summary));(raw.parent/'report.md').write_text('# Azure\n');(base/'home/.scoutflo/env').write_text('export SELECTED_SLACK=https://slack.invalid/selected\nexport SCOUTFLO_AUDIT_DIR=/wrong/output\n')
 slack_fixture();r=run(b(0,8),{'SCOUTFLO_SLACK_WEBHOOK':'https://slack.invalid/stale'});sent=[c for c in calls() if c['tool']=='curl'];check('Slack selects configured store value without output redirection',r.returncode==0 and len(sent)==1 and sent[0]['url']=='https://slack.invalid/selected' and '/wrong/output' not in str(sent),r.stdout+r.stderr+str(sent))
 slack_fixture();(base/'home/.scoutflo/env').write_text('export UNRELATED=test\n');r=run(b(0,8),{'SCOUTFLO_SLACK_WEBHOOK':'https://slack.invalid/stale'});check('missing selected secret never falls back to stale default',r.returncode==0 and not calls(),r.stdout+r.stderr)
 slack_fixture();(raw.parent/'report.md').unlink();r=run(b(0,8));check('missing report skips Slack send',r.returncode==0 and not calls(),r.stdout+r.stderr)
 slack_fixture();jq=P(shutil.which('jq'));jqstub=base/'bin/jq';jqstub.write_text('#!/bin/sh\nif [ "$1" = -n ] && [ "$2" = --arg ] && [ "$3" = head ]; then exit 7; fi\nexec '+str(jq)+' "$@"\n');jqstub.chmod(0o755)
 r=run(b(0,8));check('encoding failure never sends empty Slack payload',r.returncode==0 and not calls(),r.stdout+r.stderr);jqstub.unlink();(base/'home/.scoutflo/env').unlink()
 reset({'cli':{'monitor diagnostic-settings list':{'_exit':7}}});write('vms',[{'id':id,'name':'vm-a'}]);run(wl+'start',worker);run(wl+'claim',worker);r=run(b(1,9),worker);r2=run(wl+'assert',worker);check('examined blocked read permits an unassessed report',r.returncode==0 and r2.returncode==0 and '"result": "blocked"' in r.stdout and '"diagnostic_settings": null' in r.stdout and '"blocked": 1' in r2.stdout,r.stdout+r.stderr+r2.stderr)
 run(wl+'release',worker);r=run(wl+'claim',worker);check('explicit recovery never repeats examined blocked row',r.returncode==0 and not r.stdout.strip(),r.stdout+r.stderr)
 reset();write('vms',[{'id':id,'name':'vm-a'}]);run(wl+'start',worker);run(wl+'claim',worker);pointer=base/'out/azure/data/.active-run'
 if pointer.exists():pointer.unlink()
 r=run(wl+'assert',worker);r2=run(wl+'finish',worker);check('lost pointer cannot allow unfinished publication',r.returncode!=0 and r2.returncode!=0,r.stderr+r2.stderr)
 r=run(wl+'start',worker);check('lost pointer recovered into original unfinished run',r.returncode==0 and pointer.exists(),r.stdout+r.stderr)
 reset({'cli':{'monitor diagnostic-settings list':{'_exit':7}}});write('vms',[{'id':id,'name':'vm-a'}]);run(wl+'start',worker);run(wl+'claim',worker);run(b(1,9),worker)
 cross=worker|{'SCOUTFLO_RUN_DATE':'2026-01-03'}
 completed=copy.deepcopy(summary);completed.update(schema='scoutflo-findings/v2',target='azure/data',checks=[{'id':'AZR-001','result':'blocked'}]);(raw.parent/'findings.json').write_text(json.dumps(completed));(raw.parent/'inventory.json').write_text(json.dumps({'schema':'scoutflo-inventory/v1','items':[],'counts':{'total':0}}));(raw.parent/'report.md').write_text('# Azure\n\n## Findings by purpose\n')
 (base/'home/.scoutflo/env').write_text('export SELECTED_SLACK=https://slack.invalid/selected\n')
 # Isolate lifecycle orchestration; shared report validators have their own suites.
 shellstub=base/'bin/sh';shellstub.write_text('#!/bin/sh\ncase "$1" in */check-findings.sh|*/check-report.sh|*/render-report-viz.sh) exit 0;; esac\nexec /bin/sh "$@"\n');shellstub.chmod(0o755)
 r=run(b(0,6),cross);r2=run(b(0,7),cross);r3=run(b(0,8),cross)
 sent=[c for c in calls() if c['tool']=='curl' and c['url'].startswith('https://slack.invalid/')]
 history=base/'out/azure/data/history.jsonl'
 check('examined blocked run finalizes across date with unassessed history and brief',r.returncode==0 and r2.returncode==0 and r3.returncode==0 and history.exists() and json.loads(history.read_text())['run_date']=='2026-01-02' and len(sent)==1 and '2026-01-02' in sent[0]['data'] and not (base/'out/azure/data/2026-01-03/findings.json').exists(),r.stderr+r2.stderr+r3.stderr+str(sent))
 closing=next((x for x in blocks[0] if 'worklist.sh" finish' in x and 'check-report.sh' not in x),'exit 1')
 r=run(closing,cross);check('final closeout clears pointer after consumers finish',r.returncode==0 and not pointer.exists(),r.stdout+r.stderr)
 shellstub.unlink();(base/'home/.scoutflo/env').unlink()
 reset();secret_marker='SYNTHETIC_STORE_SYNTAX_CANARY';(base/'home/.scoutflo/env').write_text('export SELECTED_SLACK='+secret_marker+'; )\n');r=run(b(0,1));check('malformed store reports fixed error without secret-bearing diagnostics',r.returncode!=0 and 'secret store syntax invalid' in r.stderr and secret_marker not in r.stdout+r.stderr and not calls(),r.stdout+r.stderr);(base/'home/.scoutflo/env').unlink()
 # Doctor store evaluation must not leak changes into selector/runtime state.
 reset();alternate=base/'alternate.yaml';alternate.write_text('azure:\n  subscription_id: sub-a\n');store=base/'home/.scoutflo/env'
 store.write_text('export SCOUTFLO_CONFIG='+str(alternate)+'\nexport SCOUTFLO_TARGET=azure\nexport SCOUTFLO_AUDIT_DIR='+str(base/'redirected')+'\n')
 r=run(b(0,1)+'\n'+b(1,2));sent=[c for c in calls() if c['tool']=='curl']
 check('Doctor store cannot redirect configured target or inventory output',r.returncode==0 and sent and all('/subscriptions/sub-b/' in c['url'] for c in sent) and (raw/'action-groups.json').exists() and not (base/'redirected').exists(),r.stdout+r.stderr+str(sent))
 reset();store.write_text('export HOME=/discarded-home\nexport PATH=/discarded-path\nexport CLAUDE_PLUGIN_ROOT=/discarded-plugin\nexport SCOUTFLO_CONFIG='+str(alternate)+'\nexport SCOUTFLO_TARGET=azure\nexport SCOUTFLO_AUDIT_DIR='+str(base/'redirected')+'\nexport SCOUTFLO_RUN_DATE=2000-01-01\n')
 assertions='\n'.join('[ "$'+key+'" = "$EXPECT_'+key+'" ]' for key in ('HOME','PATH','CLAUDE_PLUGIN_ROOT','SCOUTFLO_CONFIG','SCOUTFLO_TARGET','SCOUTFLO_AUDIT_DIR','SCOUTFLO_RUN_DATE'))
 extra={'EXPECT_'+key:env[key] for key in ('HOME','PATH','CLAUDE_PLUGIN_ROOT','SCOUTFLO_CONFIG','SCOUTFLO_TARGET','SCOUTFLO_AUDIT_DIR','SCOUTFLO_RUN_DATE')}
 r=run(b(0,1)+'\n'+assertions,extra);check('Doctor preserves caller HOME PATH plugin and selectors',r.returncode==0 and all('/subscriptions/sub-b/' in c['url'] for c in calls() if c['tool']=='curl'),r.stdout+r.stderr);store.unlink()
 # Exact malformed receiver case: jq formerly echoed a credential fragment to stderr.
 marker='SYNTHETIC_RAW_PROVIDER_CANARY'
 reset({'responses':[{'body':{'value':[{'id':live,'name':'ops','properties':{'enabled':True,'webhookReceivers':marker}}]}}]});r=run(b(1,2))
 check('malformed receiver fails without stdout stderr or file canary',r.returncode!=0 and 'blocked' in r.stderr and 'projection' in r.stderr and 'SYNTHETIC' not in r.stdout+r.stderr and not any(marker in f.read_text() for f in (base/'out').rglob('*') if f.is_file()),r.stdout+r.stderr)
 # Valid control: safe counts still have exactly the original meaning.
 reset({'responses':[{'body':{'value':[{'id':live,'name':'ops','properties':{'enabled':True,'webhookReceivers':[{'serviceUri':marker},{'enabled':False,'serviceUri':marker}]}}]}}]});r=run(b(1,2));check('valid receiver count projection remains unchanged',r.returncode==0 and json.loads((raw/'action-groups.json').read_text())[0]['receivers']=={'webhookReceivers':1} and marker not in r.stdout+r.stderr,r.stdout+r.stderr)
 malformed_cases=[(1,5,'monitor alert-processing-rule list',[{'name':'r','properties':marker}]),(1,10,'aks show',{'addonProfiles':{'omsagent':marker}}),(1,16,'monitor diagnostic-settings list',[{'name':'d','logs':marker}]),(1,14,'monitor diagnostic-settings subscription list',{'value':[{'name':'d','properties':marker}]}),(2,3,'advisor recommendation list',[{'name':'r','extendedProperties':marker}]),(2,4,None,{'properties':{'columns':[marker],'rows':[]}})]
 for lane,index,key,value in malformed_cases:
  reset({'cli':{key:value}} if key else {'responses':[{'body':value}]})
  write('aks-list',[{'name':'cluster-a','rg':'r','id':'/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.ContainerService/managedClusters/cluster-a'}]);write('app-gateways',[{'name':'edge','id':'/subscriptions/sub-b/resourceGroups/r/providers/Microsoft.Network/applicationGateways/edge'}])
  r=run(b(lane,index));blocked=(r.returncode!=0 or '"result": "blocked"' in r.stdout)
  check('malformed raw CLI/query projection is private '+str(lane)+':'+str(index),blocked and 'blocked' in r.stderr and 'SYNTHETIC' not in r.stdout+r.stderr,r.stdout+r.stderr)
 reset({'cli':{'monitor alert-processing-rule list':[{'name':'maintenance','properties':{'enabled':True,'actions':[{'actionType':'RemoveAllActionGroups'}],'scopes':['resource-a'],'schedule':None}}]}});r=run(b(1,5));check('valid suppression projection remains unchanged',r.returncode==0 and 'SUPPRESSION-CANDIDATE maintenance' in r.stdout,r.stdout+r.stderr)
 # Causal controls: deleting either boundary must reproduce the reported defect.
 reset();store.write_text('export SCOUTFLO_CONFIG='+str(alternate)+'\nexport SCOUTFLO_TARGET=azure\nexport SCOUTFLO_AUDIT_DIR='+str(base/'redirected')+'\n')
 mutation=b(0,1).replace('( . "$SCOUTFLO_ENV" >/dev/null 2>&1 )','. "$SCOUTFLO_ENV" >/dev/null 2>&1')
 r=run(mutation);check('removing Doctor isolation reproduces target redirection',r.returncode==0 and any('/subscriptions/sub-a/' in c['url'] for c in calls() if c['tool']=='curl'),r.stdout+r.stderr);store.unlink()
 reset({'responses':[{'body':{'value':[{'id':live,'name':'ops','properties':{'enabled':True,'webhookReceivers':marker}}]}}]})
 mutation=b(1,2).replace('azure_identity\n','azure_identity\nazure_project() { jq "$@"; }\n',1)
 r=run(mutation);check('removing projection privacy reproduces secret-fragment stderr',r.returncode!=0 and 'SYNTHETIC' in r.stderr,'expected synthetic fragment was not reproduced')
 print(f'Azure read-contract: {total-len(failures)}/{total} assertions passed')
 if failures: raise SystemExit('\n'.join(failures))
PY
