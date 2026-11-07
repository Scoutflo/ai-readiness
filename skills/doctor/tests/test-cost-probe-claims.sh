#!/bin/sh
# Execute the full doctor with synthetic AWS/GCP cost-read outcomes only.
set -eu
ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]);doctor=root/'skills/doctor/scripts/doctor.sh'
with tempfile.TemporaryDirectory(prefix='doctor-cost-claims-') as td:
    work=pathlib.Path(td);bins=work/'bin';bins.mkdir()
    for name in ('awk','basename','cat','cut','date','dirname','grep','head','jq','ls','mkdir','mktemp','printenv','sed','sh','sort','tail','tr','wc','rm'):
        path=shutil.which(name);assert path,name;(bins/name).symlink_to(path)
    code='#!'+sys.executable+'''\nimport json,os,pathlib,sys
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:];mode=os.environ['CASE']
if name=='yq':sys.exit(1)
if name=='claude':print('2.1.140 fixture');sys.exit(0)
if name=='curl' and '--version' in a:print('curl 8.4.0 fixture');sys.exit(0)
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps({'command':name,'args':a,'prompts':os.environ.get('CLOUDSDK_CORE_DISABLE_PROMPTS')})+'\\n')
if name=='aws':
 if 'get-caller-identity' in a:print('{"Account":"expected-account"}')
 elif 'describe-alarms' in a:print('{}')
 elif 'get-enrollment-status' in a:
  if mode=='aws-refused':sys.exit(254)
  print(json.dumps({'status':'Inactive' if mode=='aws-inactive' else 'Active'}))
 else:raise AssertionError('unexpected AWS operation '+repr(a))
 sys.exit(0)
if name=='gcloud':
 if a==['auth','print-access-token']:print('fixture-gcp-token');sys.exit(0)
 assert a[:3]==['recommender','recommendations','list'],a
 assert os.environ.get('CLOUDSDK_CORE_DISABLE_PROMPTS')=='1',a
 is_commitment=any('UsageCommitmentRecommender' in x for x in a)
 if mode=='gcp-both-unknown' or (is_commitment and mode.startswith('gcp-partial-')):
  print('SERVICE_DISABLED' if mode=='gcp-partial-disabled' else 'PERMISSION_DENIED' if mode=='gcp-partial-denied' else 'temporary transport unavailable',file=sys.stderr);sys.exit(1)
 sys.exit(0)
if name=='bq':
 assert a[0]=='ls' and '--project_id=fixture-billing-project' in a,a
 assert os.environ.get('CLOUDSDK_CORE_DISABLE_PROMPTS')=='1',a
 if mode=='gcp-billing-denied':print('403 permission denied',file=sys.stderr);sys.exit(1)
 print(json.dumps([{'tableReference':{'tableId':'gcp_billing_export_resource_v1_fixture' if mode=='gcp-billing-detailed' else 'gcp_billing_export_v1_fixture'}}]));sys.exit(0)
if name=='curl':
 body='{"notificationChannels":[]}';meta='200 application/json'
 if '-o' in a:pathlib.Path(a[a.index('-o')+1]).write_text(body)
 else:sys.stdout.write(body)
 if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace(chr(92)+'n',chr(10)).replace('%{http_code}','200').replace('%{content_type}','application/json'))
 sys.exit(0)
raise AssertionError('unexpected CLI '+name)
'''
    for name in ('aws','gcloud','bq','curl','claude','yq','kubectl','doctl','az','terraform','gh'):
        f=bins/name;f.write_text(code);f.chmod(0o700)
    base={'PATH':str(bins),'CLAUDE_PLUGIN_ROOT':str(root)}
    proof=subprocess.run([str(bins/'sh'),'-c','for c in aws gcloud bq curl kubectl doctl az terraform gh; do command -v "$c"; done'],env=base,text=True,capture_output=True,check=True)
    assert all(x.startswith(str(bins)+'/') for x in proof.stdout.splitlines())
    modes=('aws-active','aws-inactive','aws-refused','aws-disabled','gcp-partial-unknown','gcp-partial-disabled','gcp-partial-denied','gcp-both-unknown','gcp-billing-standard','gcp-billing-detailed','gcp-billing-denied')
    for mode in modes:
        d=work/mode;d.mkdir();calls=d/'calls';calls.write_text('')
        if mode.startswith('aws-'):
            cfg='aws:\n  account_id: expected-account\n  profile: fixture-profile\n  region: fixture-region\n'
            if mode=='aws-disabled':cfg+='  cost_checks: false\n'
        else:
            cfg='gcp:\n  project: fixture-project\n  region: fixture-region\n'
            if mode.startswith('gcp-billing-'):cfg+='  billing_project: fixture-billing-project\n  billing_bq_dataset: fixture_dataset\n'
        (d/'config').write_text(cfg)
        env=base|{'HOME':str(d),'SCOUTFLO_CONFIG':str(d/'config'),'SCOUTFLO_ENV_FILE':str(d/'no-env'),'CASE':mode,'CALLS':str(calls)}
        r=subprocess.run([str(bins/'sh'),str(doctor),'--out',str(d/'out')],env=env,cwd=work,text=True,capture_output=True,timeout=45)
        rows=[json.loads(x) for x in r.stdout.splitlines()];ops=[json.loads(x) for x in calls.read_text().splitlines()]
        assert r.returncode==0,(mode,r.returncode,rows,r.stderr)
        selected=[x for x in rows if x['integration']==('aws' if mode.startswith('aws') else 'gcp') and x['check']=='cost-permissions'];assert len(selected)==1;cost=selected[0]
        assert all(not any(x in c['args'] for x in ('enable','add-iam-policy-binding','enroll','update-enrollment-status','login')) for c in ops),(mode,ops)
        if mode.startswith('aws-'):
            metadata=[x for x in ops if 'get-enrollment-status' in x['args']];assert len(metadata)==(0 if mode=='aws-disabled' else 1),(mode,ops)
            assert not any(any(svc in x['args'] for svc in ('ce','support','get-ec2-instance-recommendations')) for x in ops),(mode,ops)
            if mode in ('aws-active','aws-inactive'):
                assert cost['result']=='pass' and 'Only compute-optimizer:GetEnrollmentStatus' in cost['hint'] and 'Enrollment state, recommendation reads, Cost Explorer and Support access are not verified' in cost['hint'],(mode,cost)
            else:assert cost['result']=='skipped',(mode,cost)
        else:
            reco=[x for x in ops if x['command']=='gcloud' and x['args'][:3]==['recommender','recommendations','list']];assert len(reco)==2,(mode,ops)
            assert all('--project=fixture-project' in x['args'] and x['prompts']=='1' for x in reco)
            if mode in ('gcp-partial-unknown','gcp-both-unknown'):
                assert cost['result']=='skipped' and 'not recognised' in cost['hint'],(mode,cost)
                assert 'services enable' not in cost['hint'] and 'add-iam-policy-binding' not in cost['hint'] and 'recommendations list' in cost['hint'],(mode,cost)
            elif mode in ('gcp-partial-disabled','gcp-partial-denied'):
                assert cost['result']=='skipped' and 'Unlock:' in cost['hint'],(mode,cost)
            if mode.startswith('gcp-billing-'):
                billing=[x for x in rows if x['integration']=='gcp' and x['check']=='billing-export'];assert len(billing)==1
                expected='skipped' if mode=='gcp-billing-denied' else 'pass';assert billing[0]['result']==expected,(mode,billing)
                if expected=='pass':assert ('DETAILED' if mode.endswith('detailed') else 'STANDARD') in billing[0]['hint'],(mode,billing)
        print('PASS '+mode)
print('doctor cost probe claims: 11 passed, 0 failed; no real provider calls')
PY
