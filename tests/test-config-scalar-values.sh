#!/bin/sh
# Verify real yq, no yq, and an incompatible yq flavor without provider access.
set -eu
ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]);tt=root/'report-standard/toolkit-targets.sh'
doctor=root/'skills/doctor/scripts/doctor.sh';yq=shutil.which('yq')
assert yq, 'Tests require mikefarah yq v4; the plugin runtime still supports no yq'
version=subprocess.run([yq,'--version'],capture_output=True,text=True,check=True).stdout
assert 'mikefarah/yq/' in version and 'version v4.' in version, 'Tests require mikefarah yq v4'
passed=0;failed=[]
def check(name, condition, observed):
    global passed
    if condition:passed+=1
    else:failed.append(name);print('FAIL '+name+': '+repr(observed))
with tempfile.TemporaryDirectory(prefix='config-scalar-values-') as td:
    work=pathlib.Path(td)
    values={'bool_false':'false','bool_true':'true','zero':'0','text_false':'"false"','text_null':'"null"','empty':'""','null_value':'null'}
    scalar=''.join('  '+k+': '+v+'\n' for k,v in values.items())
    config=work/'scalars.yaml';config.write_text('gcp:\n'+scalar+'azure:\n  - label: one\n'+''.join('    '+k+': '+v+'\n' for k,v in values.items())+'  - label: two\n    bool_false: true\n')
    original=config.read_bytes()
    for parser in ('yq','fallback','jq-yq'):
        bins=work/parser;bins.mkdir()
        for name in ('awk','basename','cat','cut','date','dirname','grep','head','jq','ls','mkdir','mktemp','printenv','sed','sh','sort','tail','tr','wc','rm'):
            path=shutil.which(name);assert path,name;(bins/name).symlink_to(path)
        code='#!'+sys.executable+'''\nimport json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:]
if name=='yq':
 if os.environ['PARSER_CASE']!='jq-yq':sys.exit(1)
 # A jq-backed yq accepts the old keys/scalar expressions but not YAML tag.
 import subprocess,yaml
 body=json.dumps(yaml.safe_load(pathlib.Path(a[-1]).read_text()))
 p=subprocess.run([os.environ['REAL_JQ'],*a[:-1]],input=body,text=True,capture_output=True)
 sys.stdout.write(p.stdout);sys.stderr.write(p.stderr);sys.exit(p.returncode)
if name=='claude':print('2.1.140 fixture');sys.exit(0)
if name=='curl' and a==['--version']:print('curl 8.4.0 fixture');sys.exit(0)
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps({'command':name,'args':a})+'\\n')
if name=='gcloud':
 if a==['auth','print-access-token']:print('fixture-token');sys.exit(0)
 assert a[:3]==['recommender','recommendations','list'],a
 assert os.environ.get('CLOUDSDK_CORE_DISABLE_PROMPTS')=='1'
 assert '--project=fixture-project' in a or '--project=fixture-other' in a,a
 sys.exit(0)
if name=='curl':
 assert a[-1] in ['https://monitoring.googleapis.com/v3/projects/fixture-project/notificationChannels?pageSize=1','https://monitoring.googleapis.com/v3/projects/fixture-other/notificationChannels?pageSize=1'],a
 assert not any(x in a for x in ['-X','--data','--data-binary','-L','--location'])
 body='{"notificationChannels":[]}'
 if '-o' in a:pathlib.Path(a[a.index('-o')+1]).write_text(body)
 else:sys.stdout.write(body)
 if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace(chr(92)+'n',chr(10)).replace('%{http_code}','200').replace('%{content_type}','application/json'))
 sys.exit(0)
raise AssertionError('Unexpected provider operation '+name)
'''
        for name in ('gcloud','curl','claude','yq','aws','bq','kubectl','doctl','az','helm','terraform','gh'):
            p=bins/name;p.write_text(code);p.chmod(0o700)
        if parser=='yq':
            (bins/'yq').unlink();(bins/'yq').symlink_to(yq)
        env={'PATH':str(bins),'HOME':str(work/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'PARSER_CASE':parser,'REAL_JQ':shutil.which('jq')}
        proof=subprocess.run([str(bins/'sh'),'-c','for c in curl gcloud aws bq kubectl doctl az helm terraform gh; do command -v "$c"; done'],env=env,text=True,capture_output=True,check=True)
        assert len(proof.stdout.splitlines())==10 and all(p.startswith(str(bins)+'/') for p in proof.stdout.splitlines())
        if parser=='jq-yq':
            keys=subprocess.run([str(bins/'yq'),'-r','. | keys | length',str(config)],env=env,text=True,capture_output=True)
            tag=subprocess.run([str(bins/'yq'),'-r','. | tag',str(config)],env=env,text=True,capture_output=True)
            assert keys.returncode==0 and keys.stdout.strip()=='2', 'jq-yq control must accept the old capability probe: '+keys.stderr
            assert tag.returncode!=0 and 'tag/0 is not defined' in tag.stderr, 'jq-yq control must reject YAML tag: '+tag.stderr
        expected={'bool_false':'false','bool_true':'true','zero':'0','text_false':'false','text_null':'null','empty':'','missing':''}
        # The flat fallback historically returns the literal unquoted null text.
        # Preserve that existing behavior; this fix does not claim full YAML parity.
        expected['null_value']='' if parser=='yq' else 'null'
        for block in ('gcp','azure'):
            for key,value in expected.items():
                p=subprocess.run([str(bins/'sh'),str(tt),str(config),block,'get','0',key],env=env,capture_output=True,text=True,timeout=10)
                check(parser+' '+block+' '+key,p.returncode==0 and p.stdout.rstrip('\n')==value,(p.returncode,p.stdout))
        p=subprocess.run([str(bins/'sh'),str(tt),str(config),'azure','get','1','bool_false'],env=env,capture_output=True,text=True,timeout=10)
        check(parser+' selected list item',p.returncode==0 and p.stdout.rstrip('\n')=='true',(p.returncode,p.stdout))
        cases=[('false','false',0),('quoted-false','"false"',0),('true','true',2),('zero','0',2),('missing',None,2),('null','null',2),('empty','""',2)]
        for name,value,expected_reads in cases:
            for shape in ('map','list'):
                case=work/(parser+'-'+name+'-'+shape);case.mkdir();calls=case/'calls';calls.write_text('')
                if shape=='map':text='gcp:\n  project: fixture-project\n';indent='  '
                else:text='gcp:\n  - label: one\n    project: fixture-project\n';indent='    '
                if value is not None:text+=indent+'cost_checks: '+value+'\n'
                cfg=case/'toolkit.yaml';cfg.write_text(text)
                runenv=env|{'HOME':str(case),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_ENV_FILE':str(case/'no-env'),'CALLS':str(calls)}
                p=subprocess.run([str(bins/'sh'),str(doctor),'--out',str(case/'out')],env=runenv,cwd=case,text=True,capture_output=True,timeout=40)
                try:rows=[json.loads(x) for x in p.stdout.splitlines()]
                except ValueError:rows=[]
                ops=[json.loads(x) for x in calls.read_text().splitlines()]
                reads=[x for x in ops if x['command']=='gcloud' and x['args'][:3]==['recommender','recommendations','list']]
                cost=[x for x in rows if x['integration']=='gcp' and x['check']=='cost-permissions']
                ok=p.returncode==0 and len(reads)==expected_reads and len(cost)==1
                if expected_reads==0:ok=ok and cost[0]['result']=='skipped' and 'cost_checks is false' in cost[0]['hint']
                else:ok=ok and cost[0]['result']=='pass'
                check(parser+' Doctor '+name+' '+shape,ok,{'exit':p.returncode,'recommender_calls':len(reads),'cost_rows':cost})
                check(parser+' Doctor monitoring '+name+' '+shape,len([x for x in rows if x['check']=='monitoring-api' and x['result']=='pass'])==1,rows)
        case=work/(parser+'-mixed');case.mkdir();calls=case/'calls';calls.write_text('')
        cfg=case/'toolkit.yaml';cfg.write_text('gcp:\n  - label: one\n    project: fixture-project\n    cost_checks: false\n  - label: two\n    project: fixture-other\n    cost_checks: true\n')
        runenv=env|{'HOME':str(case),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_ENV_FILE':str(case/'no-env'),'CALLS':str(calls)}
        p=subprocess.run([str(bins/'sh'),str(doctor),'--out',str(case/'out')],env=runenv,cwd=case,text=True,capture_output=True,timeout=40)
        rows=[json.loads(x) for x in p.stdout.splitlines()];ops=[json.loads(x) for x in calls.read_text().splitlines()]
        reads=[x for x in ops if x['command']=='gcloud' and x['args'][:3]==['recommender','recommendations','list']]
        cost=[(x['integration'],x['result']) for x in rows if x['check']=='cost-permissions']
        check(parser+' Doctor selected mixed list',p.returncode==0 and len(reads)==2 and all('--project=fixture-other' in x['args'] for x in reads) and cost==[('gcp (one)','skipped'),('gcp (two)','pass')],{'exit':p.returncode,'reads':reads,'cost':cost})
        print('Executed '+parser+' scalar and full Doctor paths')
    check('config input unchanged',config.read_bytes()==original,'config bytes')
print('config scalar values: '+str(passed)+' passed, '+str(len(failed))+' failed; no real provider calls')
if failed:sys.exit(1)
PY
