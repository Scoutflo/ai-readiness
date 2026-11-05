#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy, json, os, pathlib, re, subprocess, sys, tempfile
import yaml
root=pathlib.Path(sys.argv[1]); helper=root/'skills/audit-alertmanager/scripts/project-config.sh'
passed=0
def check(name,ok):
 global passed
 if not ok: raise AssertionError(name)
 passed+=1; print('ok '+name)
secrets=['fixture-incoming-canary','fixture-routing-canary','fixture-header-canary','fixture-detail-canary','fixture-template-canary']
config={'global':{'resolve_timeout':'5m','smtp_auth_password':secrets[0]},'route':{'receiver':'page','group_by':['alertname','namespace'],'group_wait':'10s','group_interval':'5m','repeat_interval':'1h','matchers':['severity="critical"'],'routes':[{'receiver':'chat','continue':True,'match':{'le':'1'},'mute_time_intervals':['quiet']}]},'receivers':[{'name':'page','victorops_configs':[{'api_key':secrets[0],'routing_key':secrets[1],'api_url':'https://example.invalid/'+secrets[0],'send_resolved':True,'http_config':{'authorization':{'credentials':secrets[2]}},'custom_fields':{'details':secrets[3]}}]},{'name':'chat','slack_configs':[{'channel':'#ops','api_url':'https://example.invalid/'+secrets[0]}]}],'inhibit_rules':[{'source_matchers':['severity="critical"'],'target_matchers':['severity="warning"'],'equal':['alertname']}],'time_intervals':[{'name':'quiet','time_intervals':[{'times':[{'start_time':'01:00','end_time':'02:00'}],'weekdays':['saturday','sunday'],'location':'UTC'}]}],'templates':[secrets[4]]}
raw=yaml.safe_dump(config,sort_keys=False)
envelope={'cluster':{'status':'ready','peers':[]},'versionInfo':{'version':'0.29.0'},'config':{'original':raw}}
def project(mode,data): return subprocess.run(['sh',str(helper),mode],input=data,text=True,capture_output=True)
p=project('yaml',raw); check('native config projects',p.returncode==0); d=json.loads(p.stdout)
check('no credential URL header details template values',not any(v in p.stdout+p.stderr for v in secrets))
check('native type and resolved flag preserved',d['receivers'][0]['targets'][0]['type']=='victorops' and d['receivers'][0]['targets'][0]['send_resolved'] is True)
check('channel and destination class retained safely',d['receivers'][1]['targets'][0]['channel']=='#ops' and d['receivers'][0]['targets'][0]['destination_class']=='placeholder')
check('route order matchers timing preserved',d['route']==config['route'])
check('inhibition and interval definitions preserved',d['inhibit_rules']==config['inhibit_rules'] and d['time_intervals']==config['time_intervals'])
check('safe projection cannot assert credential equality',d['credential_equality']=='unassessed')
crd={'spec':{'route':{'receiver':'page','groupBy':['alertname']},'receivers':[{'name':'page','victoropsConfigs':[{'apiKey':{'name':secrets[0]},'routingKey':secrets[1],'sendResolved':True}]}]}}
p=project('crd',json.dumps(crd)); check('Operator native type retained',p.returncode==0 and json.loads(p.stdout)['receivers'][0]['targets'][0]['type']=='victorops')
check('Operator credential values discarded',not any(v in p.stdout+p.stderr for v in secrets))
http=json.dumps(envelope)+'\n200 application/json'
p=project('http-status',http); check('status YAML string is parsed before output',p.returncode==0 and 'config.original' not in p.stdout and secrets[1] not in p.stdout)
p=project('http-metadata',http); check('metadata mode never emits config',p.returncode==0 and json.loads(p.stdout)=={'cluster':{'status':'ready','peer_count':0},'version':'0.29.0'})
cases=[('refused','http-status',json.dumps(envelope)+'\n403 application/json'),('HTML','http-status',secrets[0]+'\n200 text/html'),('malformed','http-status','{'+secrets[0]+'\n200 application/json'),('wrong-config','yaml','route: []\nreceivers: []'),('duplicate-YAML','yaml','route: {}\nroute: {}\nreceivers: []'),('recursive','yaml','route: &r {receiver: page, routes: [*r]}\nreceivers: []'),('oversized','yaml','x'*(2097152+1)),('depth','yaml','route: '+('['*35)+'0'+(']'*35)+'\nreceivers: []'),('duplicate-JSON','crd','{"spec":{},"spec":{}}')]
for name,mode,body in cases:
 p=project(mode,body); check(name+' blocks without raw error',p.returncode==2 and not p.stdout and not any(v in p.stderr for v in secrets))
 if name=='refused':check('safe refused HTTP evidence retained','HTTP 403' in p.stderr)
 if name=='HTML':check('safe HTML HTTP evidence retained','HTTP 200' in p.stderr)

# Known incoming URLs remain secret-bearing even in an ordinary retained field.
url='https://alert.victorops.com/integrations/generic/20131114/alert/'+secrets[0]+'/route'
for surface in ('receiver','route','matcher','interval','field-name','metadata','type-header'):
 c=copy.deepcopy(config); e=copy.deepcopy(envelope); mode='yaml'
 if surface=='receiver':c['receivers'][0]['name']=url
 elif surface=='route':c['route']['receiver']=url
 elif surface=='matcher':c['route']['matchers']=['service="'+url+'"']
 elif surface=='interval':c['time_intervals'][0]['name']=url
 elif surface=='field-name':c['global'][url]='ignored'
 elif surface=='type-header':c['receivers'][0]['X-VO-Api-Key: '+secrets[0]+'_configs']=[{}]
 else:mode='http-metadata';e['versionInfo']['version']=url
 body=yaml.safe_dump(c) if mode=='yaml' else json.dumps(e)+'\n200 application/json'
 p=project(mode,body);check('credential URL in '+surface+' refuses safely',p.returncode==2 and not p.stdout and secrets[0] not in p.stderr)

# Execute all published status-reading blocks in independent shells. Fixed stand-ins
# never contact a network/cluster; sensitive fixture text must not enter output files.
reference=(root/'skills/audit-alertmanager/references/verification-chain.md').read_text()
blocks=[x for x in re.findall(r'```bash\n(.*?)```',reference,re.S) if '/api/v2/status' in x]
check('all status entry paths use projection preflight',len(blocks)==9 and all('sh "$AM_PROJECT" check' in b for b in blocks))
with tempfile.TemporaryDirectory(prefix='alr-projection-test-') as td:
 work=pathlib.Path(td); bindir=work/'bin'; bindir.mkdir(); inputs=work/'inputs'; inputs.mkdir(); out=work/'output'; out.mkdir()
 (inputs/'status.json').write_text(json.dumps(envelope)); (inputs/'config.yaml').write_text(raw); (inputs/'crd.json').write_text(json.dumps(crd))
 calls=work/'calls'; calls.write_text('')
 stub='''#!'''+sys.executable+'''
import json,os,pathlib,sys,time
name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]; src=pathlib.Path(os.environ['ALR_FIXTURES'])
if name=='curl' and '--version' in a: print('curl 8.4.0 fixture');sys.exit(0)
with open(os.environ['ALR_CALLS'],'a') as f:f.write(name+'\\n')
if name in ('dig','nslookup'): print('127.0.0.1');sys.exit(0)
if name=='kubectl':
 if 'port-forward' in a: time.sleep(20);sys.exit(0)
 print((src/('config.yaml' if 'exec' in a else 'crd.json')).read_text());sys.exit(0)
url=a[-1]; code='200'; ct='application/json'; body='{}'
if '/api/v2/status' in url:
 assert a[0]=='-q' and '--max-redirs' in a and '--proto' in a and '--max-filesize' in a
 body=(src/'status.json').read_text()
 if os.environ.get('ALR_BAD')=='refused':code='403'
 if os.environ.get('ALR_BAD')=='malformed':body='fixture-routing-canary malformed'
 if os.environ.get('ALR_BAD')=='header':ct='text/html fixture-routing-canary'
elif 'buildinfo' in url: body=json.dumps({'status':'success','data':{'version':'3.0.0'}})
elif '/api/v2/alerts' in url:body='[]'
elif '/api/v1/query' in url:
 query=' '.join(a); value=str(int(time.time())) if 'last_reload_success_timestamp_seconds' in query else '1'
 body=json.dumps({'status':'success','data':{'resultType':'vector','result':[{'metric':{'instance':'fixture'},'value':[int(time.time()),value]}]}})
if '-o' in a:pathlib.Path(a[a.index('-o')+1]).write_text(body)
else:sys.stdout.write(body)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace('\\\\n','\\n').replace('%{http_code}',code).replace('%{content_type}',ct))
'''
 for name in ('curl','kubectl','dig','nslookup'):
  q=bindir/name;q.write_text(stub);q.chmod(0o755)
 env={**os.environ,'PATH':str(bindir)+os.pathsep+os.environ['PATH'],'HOME':str(work/'home'),'TMPDIR':str(out),'SCOUTFLO_CONFIG':str(work/'toolkit.yaml'),'SCOUTFLO_ENV_FILE':str(work/'empty-env'),'CLAUDE_PLUGIN_ROOT':str(root),'ALR_FIXTURES':str(inputs),'ALR_CALLS':str(calls)}
 (work/'toolkit.yaml').write_text('prometheus:\n  url: https://example.invalid\n  alertmanager_url: https://example.invalid\n');(work/'empty-env').write_text('')
 for i,b in enumerate(blocks):
  run=subprocess.run(['sh'],input=b,text=True,capture_output=True,env=env,cwd=out,timeout=15)
  check('fresh status block '+str(i+1)+' succeeds',run.returncode==0)
  check('fresh status block '+str(i+1)+' emits no secrets',not any(v in run.stdout+run.stderr for v in secrets))
  check('fresh status block '+str(i+1)+' persists no secrets',all(not any(v in f.read_text(errors='replace') for v in secrets) for f in out.rglob('*') if f.is_file()))
 # All config/hygiene entry paths fail closed on refused/malformed status, not an
 # empty/no-match success; metadata-only preflight similarly cannot print pass.
 for kind in ('refused','malformed','header'):
  for i,b in enumerate(blocks):
   run=subprocess.run(['sh'],input=b,text=True,capture_output=True,env={**env,'ALR_BAD':kind},cwd=out,timeout=15)
   check(kind+' fresh block '+str(i+1)+' blocks',run.returncode!=0 and not any(v in run.stdout+run.stderr for v in secrets))
 # Dependency failures must precede every provider read, even the cheap probe.
 q=bindir/'python3';q.write_text('#!/bin/sh\nexit 1\n');q.chmod(0o755)
 for i,b in enumerate(blocks):
  calls.write_text('');run=subprocess.run(['sh'],input=b,text=True,capture_output=True,env=env,cwd=out,timeout=15)
  check('missing PyYAML blocks before reads '+str(i+1),run.returncode!=0 and calls.read_text()=='')
print('alertmanager config projection: '+str(passed)+' passed, 0 failed (zero real provider calls)')
PY
