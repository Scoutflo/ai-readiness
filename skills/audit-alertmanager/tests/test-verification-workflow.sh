#!/bin/sh
# Execute literal reference recipes with stand-ins; no provider or cluster calls.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy,datetime,hashlib,json,os,pathlib,re,subprocess,sys,tempfile
sys.stdout.reconfigure(line_buffering=True)
root=pathlib.Path(sys.argv[1]); reference=pathlib.Path(os.environ.get('ALR_TEST_REFERENCE',root/'skills/audit-alertmanager/references/verification-chain.md')).read_text()
blocks=re.findall(r'```bash\n(.*?)```',reference,re.S); passed=0
def check(name,ok):
 global passed
 assert ok,name
 passed+=1; print('PASS '+name)
with tempfile.TemporaryDirectory(prefix='alr-workflow-') as td:
 work=pathlib.Path(td);bin=work/'bin';bin.mkdir();config=work/'toolkit.yaml';store=work/'env';calls=work/'calls'
 (bin/'yq').write_text('#!/bin/sh\nexit 1\n');(bin/'yq').chmod(0o755) # exercise the shipped flat-config fallback
 config.write_text('prometheus:\n  url: https://prometheus.example.com\n  alertmanager_url: https://alertmanager.example.com\n');store.write_text('');calls.write_text('')
 stub=r'''#!PYTHON
import json,os,pathlib,sys,time,urllib.parse
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:];mode=os.environ.get('ALR_MODE','good')
if name=='sleep':sys.exit(0)
if name=='curl' and '--version' in a:print('curl 8.4.0 fixture');sys.exit(0)
with open(os.environ['ALR_CALLS'],'a') as f:f.write(json.dumps({'command':name,'args':a})+'\n')
labels={'severity':'critical','service':'example-service','namespace':'example-ns','environment':'qa'}
annotations={k:'fixture meaning' for k in ['summary','impact','triage_scope','handoff_note']};annotations['confirmation_query']='vector(1)'
rules=[{'type':'alerting','name':n,'labels':labels,'annotations':annotations,'health':'ok','lastError':'','duration':300,'keepFiringFor':60} for n in ['RuleA','RuleB']]
if mode=='metadata-missing':rules[0]['annotations']={}
if mode=='unknown-type':rules[0]['type']='future-rule-type'
if mode=='missing-rule':rules=rules[1:]
if name=='kubectl':
 if 'port-forward' in a:time.sleep(10);sys.exit(0)
 if mode=='transport':sys.exit(1)
 if 'exec' in a: print('route: {receiver: page}\nreceivers: [{name: page, victorops_configs: [{routing_key: fixture-secret-canary}]}]');sys.exit(0)
 if 'alertmanagerconfig' in a:body={'spec':{'route':{'receiver':'page'},'receivers':[{'name':'page','victoropsConfigs':[{'routingKey':'fixture-secret-canary'}]}]}}
 else:body={'items':[{'metadata':{'namespace':'example-ns','name':'example-rules'}}],'spec':{'groups':[{'rules':rules}]}}
 print(json.dumps(body));sys.exit(0)
if name in ('dig','nslookup'):
 if mode=='transport':sys.exit(1)
 if 'NS' in a:print('ns.example.invalid.');sys.exit(0)
 if '+comments' in a:
  print(';; ->>HEADER<<- opcode: QUERY, status: '+('NXDOMAIN' if mode=='nxdomain' and a[-1]!='example.invalid' else 'NOERROR')+', id: 1');sys.exit(0)
 print('192.0.2.1');sys.exit(0)
url=a[-1];code='200';ct='application/json';now=int(time.time());query=urllib.parse.unquote(url)
for n,v in enumerate(a):
 if v=='--data-urlencode':query+=' '+a[n+1]
body={'status':'success','data':{'resultType':'vector','result':[{'metric':{'instance':'fixture','integration':'webhook','alertname':'RuleA','namespace':'example-ns'},'value':[now,'1']}]}}
if '/api/v2/status' in url:body={'cluster':{'status':'starting' if mode=='not-ready' else 'ready','peers':[]},'versionInfo':{'version':'0.29.0'},'config':{'original':'route: {receiver: page}\nreceivers: [{name: page, victorops_configs: [{routing_key: fixture-secret-canary}]}]'}}
elif '/api/v1/rules' in url:body={'status':'success','data':{'groups':[{'file':'fixture.rules','name':'your-rule-group','rules':rules}]}}
elif '/buildinfo' in url:body={'status':'success','data':{'version':'2.55.0' if mode=='pre3' else ('not-a-version' if mode=='bad-version' else '3.0.0')}}
elif '/query_range' in url:body={'status':'success','data':{'resultType':'matrix','result':[{'metric':labels,'values':[[now-300,'1'],[now,'1']]}]}}
elif '/api/v2/alerts' in url:body=[]
elif '/api/v2/silences' in url:body=[]
elif '/issues/' in url:body=[]
if 'last_reload_success_timestamp_seconds' in query:
 body['data']['result'][0]['value'][1]=str(now-200000 if mode=='stale-reload' else now)
 if mode=='mismatch-reload':body['data']['result'][0]['metric']['instance']='different'
elif 'last_reload_successful' in query and mode=='failed-reload':body['data']['result'][0]['value'][1]='0'
if mode in ('empty-vector','metrics-empty','metrics-malformed','metrics-bad-labels') and '/query' in url and 'query_range' not in url:body['data']['result']=[]
if mode=='rules-warning' and '/api/v1/rules' in url:body['warnings']=['partial rule response']
if mode=='confirmation-denied' and 'vector(1)' in query:code='403'
if mode=='denied':code='403'
if mode=='transport':sys.exit(28)
if mode=='wrong-shape':body={'unexpected':True}
if mode=='api-error':body={'status':'error','error':'fixture-secret-canary'}
raw=json.dumps(body)
if url.endswith('/metrics'):
 ct='text/plain; version=0.0.4';raw='alertmanager_notifications_total{integration=\"webhook\",ignored=\"fixture-secret-canary\"} 42\nalertmanager_notifications_failed_total{integration=\"webhook\"} 0\n'
 if mode=='metrics-bad-labels':raw='alertmanager_notifications_total{integration=\"webhook\",broken} 42\n'
 if mode=='metrics-empty':raw='# no notification counters\n'
 if mode=='metrics-malformed':raw='alertmanager_notifications_total{integration=\"webhook\"} fixture-secret-canary\n'
if mode=='html':raw='<html>fixture-secret-canary</html>';ct='text/html'
if mode=='malformed':raw='{fixture-secret-canary'
if mode=='empty-body':raw=''
if mode=='two-docs':raw=raw+'\n'+raw
if '-o' in a:pathlib.Path(a[a.index('-o')+1]).write_text(raw)
else:sys.stdout.write(raw)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace('\\n','\n').replace('%{http_code}',code).replace('%{content_type}',ct))
'''.replace('PYTHON',sys.executable)
 for name in ['curl','kubectl','dig','nslookup','sleep']:
  path=bin/name;path.write_text(stub);path.chmod(0o755)
 env={**os.environ,'PATH':str(bin)+os.pathsep+os.environ['PATH'],'HOME':str(work/'home'),'TMPDIR':str(work),'SCOUTFLO_ENV_FILE':str(store),'SCOUTFLO_CONFIG':str(config),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_AUDIT_DIR':str(work/'audits'),'ALR_CALLS':str(calls),'ALR_DNS_ZONE':'example.invalid','SENTRY_TOKEN':'fixture-readonly','ALR_RUN_ID':'fixture-run','ALR_BATCH_SIZE':'1'}
 for name in ['curl','kubectl','dig','nslookup','sleep']:
  actual=subprocess.run(['sh','-c','command -v '+name],capture_output=True,text=True,env=env,check=True).stdout.strip()
  check('stand-in '+name,actual==str(bin/name))
 def run(b,mode='good',extra=None):
  return subprocess.run(['sh'],input=b,text=True,capture_output=True,env={**env,'ALR_MODE':mode,**(extra or {})},cwd=work,timeout=30)
 worklist=[b for b in blocks if 'ALR_RUN_ID=' in b]
 check('four worklist stages present',len(worklist)==4)
 seed,collect,review,finish=worklist
 receipt=work/'audits/alertmanager/estate-sizing.json';receipt.parent.mkdir(parents=True,exist_ok=True)
 sizing={'objects':3,'path':'large','batch_size':1,'excluded_services':[],'target_binding':hashlib.sha256(json.dumps(['https://prometheus.example.com','https://alertmanager.example.com']).encode()).hexdigest(),'observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
 def put_sizing(value=sizing):receipt.write_text(json.dumps(value))
 put_sizing()
 ordinary=[b for b in blocks if b not in worklist]
 for i,b in enumerate(ordinary):
  p=run(b)
  check('fresh ordinary block '+str(i)+' '+p.stderr[-180:],p.returncode==0)
  check('ordinary block private '+str(i),'fixture-secret-canary' not in p.stdout+p.stderr)
 # HTTP error propagation is checked for every HTTP recipe, including zero-match paths.
 http=[b for b in ordinary if 'curl ' in b]
 for mode in ['denied','transport','html','malformed','empty-body','two-docs','wrong-shape']:
  for i,b in enumerate(http):
   p=run(b,mode)
   check(mode+' blocks recipe '+str(i),p.returncode!=0 and 'fixture-secret-canary' not in p.stdout+p.stderr)
 dispatch=next(b for b in ordinary if 'NEED_DIRECT=' in b)
 p=run(dispatch,'empty-vector');check('direct metrics fallback preserves lifetime-only boundary',p.returncode!=0 and 'lifetime-only' in p.stdout and 'windowed_delivery' in p.stdout and 'fixture-secret-canary' not in p.stdout+p.stderr)
 for mode in ['metrics-empty','metrics-malformed','metrics-bad-labels']:
  p=run(dispatch,mode);check(mode+' fallback cannot invent zero counters',p.returncode!=0 and 'lifetime-only' not in p.stdout and 'fixture-secret-canary' not in p.stdout+p.stderr)
 for mode in ['unknown-type','rules-warning']:
  for i,b in enumerate(x for x in ordinary if '/api/v1/rules' in x):
   check(mode+' rule consumer '+str(i),run(b,mode).returncode!=0)
 reload=next(b for b in ordinary if 'RELOAD_MAX_AGE_SECONDS=' in b)
 for mode in ['failed-reload','stale-reload','empty-vector','mismatch-reload']:
  check('reload '+mode,run(reload,mode).returncode!=0)
 forward=next(b for b in ordinary if 'port-forward svc/' in b)
 check('cleanup cannot erase non-ready assertion',run(forward,'not-ready').returncode!=0)
 version=next(b for b in ordinary if 'PMAJOR=' in b)
 p=run(version,'bad-version');check('unknown version blocks without pre3',p.returncode!=0 and 'not-in-scope' not in p.stdout)
 check('verified pre3 skips normalization only',run(version,'pre3').returncode==0)
 dns=next(b for b in ordinary if 'ALR_DNS_ZONE' in b)
 p=run(dns,'nxdomain');check('NXDOMAIN is evidence not decommission claim',p.returncode!=0 and 'lifecycle/decommission remains unverified' in p.stdout)
 # Worklist: failing seeding never creates a valid state; successful seed is immutable.
 for b in [seed,collect]:
  for case,modified in [('missing',None),('excluded',dict(sizing,excluded_services=['excluded-service'])),('wrong-target',dict(sizing,target_binding='wrong')),('stale',dict(sizing,observed_at='2020-01-01T00:00:00Z')),('no-timestamp',{k:v for k,v in sizing.items() if k!='observed_at'}),('not-large',dict(sizing,path='small'))]:
   if modified is None:receipt.unlink(missing_ok=True)
   else:put_sizing(modified)
   calls.write_text('');p=run(b);check('scope '+case+' blocks before read '+('seed' if b==seed else 'collect'),p.returncode!=0 and calls.read_text()=='')
  put_sizing()
 for mode in ['denied','malformed','wrong-shape','unknown-type','rules-warning']:
  p=run(seed,mode);check('seed '+mode+' creates no worklist',p.returncode!=0 and not (work/'audits/alertmanager/runs/fixture-run/worklist.tsv').exists())
 p=run(seed);check('seed actual loaded identities',p.returncode==0)
 d=work/'audits/alertmanager/runs/fixture-run';before=(d/'worklist.tsv').read_bytes()
 check('second seed refuses overwrite',run(seed).returncode!=0 and (d/'worklist.tsv').read_bytes()==before)
 check('fresh run refuses abandoned pending scope',run(seed,extra={'ALR_RUN_ID':'another-run'}).returncode!=0)
 check('pending prevents complete publication',run(finish).returncode!=0)
 (d/'worklist.lock').mkdir();check('existing lock prevents claim',run(collect).returncode!=0);(d/'worklist.lock').rmdir()
 for mode in ['denied','wrong-shape','confirmation-denied','missing-rule','unknown-type','rules-warning']:
  p=run(collect,mode);check('collection '+mode+' remains pending',p.returncode!=0 and (d/'worklist.tsv').read_bytes()==before and not (d/'worklist.lock').exists())
 p=run(collect);check('collection performs read but never marks done',p.returncode==0 and (d/'worklist.tsv').read_bytes()==before)
 observation=d/'observations/rule-0.json';check('bounded batch stores one real observation',observation.exists() and not (d/'observations/rule-1.json').exists())
 obs=json.loads(observation.read_text());check('observation records verification',obs['confirmation']=='observed' and obs['missing_labels']==[] and obs['missing_annotations']==[])
 opts={'ALR_RULE_ID':'rule-0','ALR_OBSERVATION_SHA256':'0'*64,'ALR_REVIEW_RESULT':'pass','ALR_REVIEW_REASON':'Verified the declared metadata and observed confirmation query'}
 check('wrong hash cannot mark done',run(review,extra=opts).returncode!=0 and (d/'worklist.tsv').read_bytes()==before)
 opts['ALR_OBSERVATION_SHA256']=hashlib.sha256(observation.read_bytes()).hexdigest()
 check('failed revalidation refuses stale prior observation',run(collect,'confirmation-denied').returncode!=0 and run(review,extra=opts).returncode!=0)
 check('recollect after blocked attempt',run(collect).returncode==0)
 opts['ALR_OBSERVATION_SHA256']=hashlib.sha256(observation.read_bytes()).hexdigest()
 check('attended review marks exact observed item',run(review,extra=opts).returncode==0)
 old_observation=observation.read_bytes();p=run(collect);check('resume skips completed rule',p.returncode==0 and observation.read_bytes()==old_observation and (d/'observations/rule-1.json').exists())
 check('partially reviewed scope stays incomplete',run(finish).returncode!=0)
 second=d/'observations/rule-1.json';opts.update(ALR_RULE_ID='rule-1',ALR_OBSERVATION_SHA256=hashlib.sha256(second.read_bytes()).hexdigest())
 check('review remaining observed item',run(review,extra=opts).returncode==0)
 check('complete only after every review',run(finish).returncode==0)
 empty_opts={'ALR_RUN_ID':'empty-predicate-run'}
 check('seed independent empty-predicate review case',run(seed,extra=empty_opts).returncode==0)
 check('collect successful empty predicate',run(collect,'empty-vector',extra=empty_opts).returncode==0)
 empty_obs=work/'audits/alertmanager/runs/empty-predicate-run/observations/rule-0.json'
 empty_opts.update(ALR_RULE_ID='rule-0',ALR_OBSERVATION_SHA256=hashlib.sha256(empty_obs.read_bytes()).hexdigest(),ALR_REVIEW_RESULT='pass',ALR_REVIEW_REASON='Independent base-series evidence and current rule state establish this predicate is correctly inactive')
 check('unexplained empty predicate cannot pass',run(review,extra=empty_opts).returncode!=0)
 empty_opts['ALR_EMPTY_QUERY_INTERPRETATION']='valid-inactive-predicate'
 check('attended evidenced empty predicate may complete',run(review,extra=empty_opts).returncode==0)
 saved=(d/'worklist.tsv').read_text();(d/'worklist.tsv').write_text(saved.splitlines()[0]+'\n');check('removed worklist row cannot shrink scope',run(finish).returncode!=0);(d/'worklist.tsv').write_text(saved)
 second.write_text(second.read_text()+' ');check('changed evidence invalidates completion',run(finish).returncode!=0)
 # Reusing this run against another configured target must fail before any provider read.
 config.write_text('prometheus:\n  url: https://other.example.invalid\n  alertmanager_url: https://alertmanager.example.com\n');calls.write_text('')
 p=run(collect);check('target mismatch blocks before reads',p.returncode!=0 and calls.read_text()=='')
 print('verification workflow: '+str(passed)+' passed, 0 failed; zero real provider/cluster calls')
PY
