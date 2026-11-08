#!/bin/sh
# Full doctor regression probes with isolated HOME and allowlisted fake CLIs.
# An optional root argument permits reviewing a candidate without installing it.
set -eu
ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); doctor=root/'skills/doctor/scripts/doctor.sh'
with tempfile.TemporaryDirectory(prefix='doctor-safety-') as td:
    work=pathlib.Path(td); bins=work/'bin';bins.mkdir()
    for name in ('awk','basename','cat','cut','date','dirname','grep','head','jq','ls','mkdir','mktemp','printenv','sed','sh','sort','tail','tr','wc','rm'):
        path=shutil.which(name);assert path, ('missing test prerequisite',name)
        (bins/name).symlink_to(path)
    stub='#!'+sys.executable+'''\nimport json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:];mode=os.environ['CASE']
if name=='yq':sys.exit(1)
if name=='claude':print('2.1.140 fixture');sys.exit(0)
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps({'command':name,'args':a,'adc':os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')})+'\\n')
if name=='aws':
 if 'get-caller-identity' in a:print('{"Account":"other-account","Arn":"fixture-other-principal"}')
 else:print('{}')
 sys.exit(0)
if name=='gcloud':print('fixture-access-token');sys.exit(0)
if name!='curl':sys.exit(97)
if '--version' in a:print('curl 8.4.0 fixture');sys.exit(0)
url=a[-1];body='{"database":"ok","name":"Fixture","id":1,"slug":"fixture-org","status":"success","data":{"result":[]},"cluster":{"status":"ready"}}';code='200';ct='application/json'
if '--data-binary' in a:
 assert a[a.index('--data-binary')+1]=='SELECT 1','unexpected SQL'
 body='1';code='403';ct='text/plain'
elif url.endswith('/api/v1/version'):body='{"version":"fixture"}'
elif url.endswith('/api/v1/rules'):body='[]'
if mode=='metrics-health-fallback' and url.endswith('/ready'):code='404'
if mode=='metrics-ready-health-denied':code='403'
if 'monitoring.googleapis.com' in url:body='{"notificationChannels":[]}'
if 'api.digitalocean.com' in url:body='{"account":{"uuid":"fixture-account","status":"active"}}'
if 'api.github.com' in url:body='{"login":"fixture-org","id":1}'
if mode=='github-user-fallback' and '/orgs/' in url:code='404'
if mode.endswith('-html'):body='<html>login</html>';ct='text/html'
if mode=='gcp-empty-json':body='{}'
if mode.startswith('gcp-schema-'):
 fixtures={
  'gcp-schema-empty-list':{'notificationChannels':[]},
  'gcp-schema-page':{'notificationChannels':[{'name':'projects/fixture-project/notificationChannels/fixture','type':'email'}],'nextPageToken':'fixture-next','totalSize':2},
  'gcp-schema-defaults':{'nextPageToken':'','totalSize':0},
  'gcp-schema-wrapper':{'login':'required','status':'unauthenticated'},
  'gcp-schema-unknown-with-list':{'notificationChannels':[],'login':'required'},
  'gcp-schema-null-list':{'notificationChannels':None},
  'gcp-schema-object-list':{'notificationChannels':{}},
  'gcp-schema-scalar-item':{'notificationChannels':['not-a-channel']},
  'gcp-schema-null-item':{'notificationChannels':[None]},
  'gcp-schema-null-token':{'nextPageToken':None},
  'gcp-schema-number-token':{'nextPageToken':1},
  'gcp-schema-string-total':{'totalSize':'2'},
  'gcp-schema-fraction-total':{'totalSize':1.5},
  'gcp-schema-null-total':{'totalSize':None},
  'gcp-schema-bool-total':{'totalSize':True},
  'gcp-schema-error':{'error':{'code':403}},
 }
 body=json.dumps(fixtures[mode])

if '-o' in a:pathlib.Path(a[a.index('-o')+1]).write_text(body)
else:sys.stdout.write(body)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace(chr(92)+'n',chr(10)).replace('%{http_code}',code).replace('%{content_type}',ct))
'''
    for name in ('curl','aws','gcloud','kubectl','doctl','az','bq','terraform','gh','claude','yq'):
        p=bins/name;p.write_text(stub);p.chmod(0o700)
    envbase={'PATH':str(bins),'CLAUDE_PLUGIN_ROOT':str(root),'CURL_MAX_TIME':'1','CURL_CONNECT_TIMEOUT':'1','BASIC_U':'fixture-user','BASIC_P':'fixture-password','SIG_TOKEN':'fixture-signoz-token'}
    resolution=subprocess.run([str(bins/'sh'),'-c','for c in curl aws gcloud kubectl doctl az bq terraform gh; do command -v "$c"; done'],env=envbase,text=True,capture_output=True,check=True)
    assert all(line.startswith(str(bins)+'/') for line in resolution.stdout.splitlines()), 'unisolated CLI'
    prom='lgtm:\n  runtime_mode: external\nprometheus:\n  url: https://prom.example.invalid\n  basic_user_env: BASIC_U\n  basic_pass_env: BASIC_P\n'
    loki='lgtm:\n  runtime_mode: external\nloki:\n  url: https://loki.example.invalid\n  basic_user_env: BASIC_U\n  basic_pass_env: BASIC_P\n'
    cases=[
      ('aws-mismatch','aws:\n  account_id: expected-account\n  profile: fixture-profile\n  region: fixture-region\n  cost_checks: false\n',{},None),
      ('grafana-no-name','grafana:\n  url: https://grafana.example.invalid\n',{},None),
      ('sentry-no-name','sentry:\n  host: sentry.example.invalid\n  org: fixture-org\n',{},None),
      ('lgtm-standalone','lgtm:\n  - label: stack-a\n    runtime_mode: external\n    loki_url: https://loki.example.invalid\n',{'CLAUDE_PLUGIN_ROOT':None},None),
      ('clickstack-status','clickstack:\n  clickhouse_url: https://ch.example.invalid\n',{},None),
      ('signoz-status','signoz:\n  url: https://signoz.example.invalid\n  api_key_env: SIG_TOKEN\n  clickhouse_url: https://ch.example.invalid\n',{},None),
      ('store-bad-export','grafana:\n  url: https://grafana.example.invalid\n  token_env: FIXTURE_TOKEN\n',{},'export FIXTURE_TOKEN =fixture-secret-canary\n'),
      ('store-bad-syntax','grafana:\n  url: https://grafana.example.invalid\n  token_env: FIXTURE_TOKEN\n',{},'export FIXTURE_TOKEN="fixture-secret-canary\n'),
      ('digitalocean-good','digitalocean:\n  token_env: SIG_TOKEN\n',{},None),
      ('digitalocean-html','digitalocean:\n  token_env: SIG_TOKEN\n',{},None),
      ('github-html','github:\n  org: fixture-org\n  token_env: SIG_TOKEN\n',{},None),
      ('github-user-fallback','github:\n  org: fixture-org\n  token_env: SIG_TOKEN\n',{},None),
      ('gcp-html','gcp:\n  project: fixture-project\n  cost_checks: false\n',{},None),
      ('gcp-empty-json','gcp:\n  project: fixture-project\n  cost_checks: false\n',{},None),
      ('gcp-selected-file','gcp:\n  project: fixture-project\n  credentials_env: CUSTOM_CREDENTIAL_FILE\n  cost_checks: false\n',{},None),
      ('metrics-basic',prom,{},None),
      ('metrics-missing-value',prom,{'BASIC_P':None},None),
      ('metrics-missing-key',prom.replace('  basic_pass_env: BASIC_P\n',''),{},None),
      ('metrics-overrides-bearer',prom+'  token_env: UNSET_BEARER\n',{},None),
      ('metrics-health-fallback',loki,{},None),
      ('metrics-ready-health-denied',loki,{},None),
      ('metrics-no-leak',prom+'gcp:\n  project: fixture-project\n  cost_checks: false\n',{},None),
    ]
    gcp_schema_pass={'gcp-schema-empty-list','gcp-schema-page','gcp-schema-defaults'}
    gcp_schema_fail={'gcp-schema-wrapper','gcp-schema-unknown-with-list','gcp-schema-null-list','gcp-schema-object-list','gcp-schema-scalar-item','gcp-schema-null-item','gcp-schema-null-token','gcp-schema-number-token','gcp-schema-string-total','gcp-schema-fraction-total','gcp-schema-null-total','gcp-schema-bool-total','gcp-schema-error'}
    for name in sorted(gcp_schema_pass|gcp_schema_fail):
        cases.append((name,'gcp:\n  project: fixture-project\n  cost_checks: false\n',{},None))
    for name,cfg,extra,store in cases:
        d=work/name;d.mkdir();(d/'toolkit.yaml').write_text(cfg);(d/'calls').write_text('');(d/'credentials.json').write_text('{}')
        if store:(d/'env').write_text(store)
        env=envbase|{'HOME':str(d),'SCOUTFLO_CONFIG':str(d/'toolkit.yaml'),'SCOUTFLO_ENV_FILE':str(d/'env'),'CALL_LOG':str(d/'calls'),'CASE':name,'CUSTOM_CREDENTIAL_FILE':str(d/'credentials.json')}
        for key,value in extra.items():
            if value is None:env.pop(key,None)
            else:env[key]=value
        r=subprocess.run([str(bins/'sh'),str(doctor),'--out',str(d/'out')],cwd=work,env=env,text=True,capture_output=True,timeout=40)
        rows=[json.loads(line) for line in r.stdout.splitlines()];calls=[json.loads(line) for line in (d/'calls').read_text().splitlines()]
        reads=[c for c in calls if c['command']=='curl' and '--version' not in c['args']]
        def row(integration,check):
            found=[x for x in rows if x['integration']==integration and x['check']==check];assert len(found)==1,(name,'missing/duplicate row',integration,check,rows);return found[0]
        assert 'fixture-secret-canary' not in r.stdout+r.stderr,(name,'store secret leaked')
        assert 'fixture-password' not in r.stdout+r.stderr,(name,'basic credential leaked')
        if name=='aws-mismatch':
            assert r.returncode==3 and row('aws','identity')['result']=='fail',(name,rows)
            assert not any('cloudwatch' in x['args'] or 'compute-optimizer' in x['args'] for x in calls),(name,'read followed identity failure',calls)
        elif name in {'grafana-no-name','sentry-no-name'}:
            assert r.returncode==2 and not reads,(name,'missing credential still read',calls)
        elif name=='lgtm-standalone':
            assert r.returncode==0 and row('lgtm:stack-a','loki-reachable')['result']=='pass' and len(reads)==1,(name,rows)
        elif name in {'clickstack-status','signoz-status'}:
            probe=row('clickstack' if name.startswith('clickstack') else 'signoz','clickhouse')
            assert r.returncode==3 and probe['result']=='fail' and probe['http_code']=='403',(name,probe)
        elif name.startswith('store-'):
            assert r.returncode==3 and row('env','store-load')['result']=='fail' and not reads,(name,rows,calls)
        elif name in {'digitalocean-html','github-html','gcp-html'}:
            provider=name[:-5];check={'digitalocean':'account','github':'org','gcp':'monitoring-api'}[provider]
            assert r.returncode==3 and row(provider,check)['result']=='fail',(name,rows)
        elif name in {'digitalocean-good','github-user-fallback','gcp-empty-json'}:
            assert r.returncode==0,(name,rows)
            if name=='github-user-fallback':assert len(reads)==2 and '/users/fixture-org' in reads[1]['args'][-1],(name,reads)
        elif name.startswith('gcp-schema-'):
            expected='pass' if name in gcp_schema_pass else 'fail'
            assert r.returncode==(0 if expected=='pass' else 3) and row('gcp','monitoring-api')['result']==expected,(name,r.returncode,rows)
            assert len(reads)==1 and reads[0]['args'][-1]=='https://monitoring.googleapis.com/v3/projects/fixture-project/notificationChannels?pageSize=1',(name,reads)
            assert not any(x in reads[0]['args'] for x in ('-o','-L','--location')),(name,'unexpected output/redirect',reads)
        elif name=='gcp-selected-file':
            gs=[x for x in calls if x['command']=='gcloud']
            assert r.returncode==0 and len(gs)==1 and gs[0]['adc']==str(d/'credentials.json'),(name,gs,rows)
        elif name in {'metrics-missing-value','metrics-missing-key'}:
            assert r.returncode==2 and not reads,(name,calls,rows)
        else:
            assert r.returncode==(3 if name=='metrics-ready-health-denied' else 0),(name,rows,r.stderr)
            if name=='metrics-health-fallback':assert len(reads)==2 and row('loki','ready')['result']=='pass',(name,reads,rows)
            if name=='metrics-ready-health-denied':assert len(reads)==3 and row('loki','ready')['http_code']=='403',(name,reads,rows)
            for x in reads:
                a=x['args']
                if 'googleapis.com' in a[-1]:assert '--user' not in a and '-u' not in a,(name,'basic credentials crossed provider',a)
                else:assert '--user' in a and a[a.index('--user')+1]=='fixture-user:fixture-password' and not any('Bearer ' in p for p in a),(name,a)
        print('PASS '+name)
print(f'doctor safety boundaries: {len(cases)} passed, 0 failed; no real provider calls')
PY
