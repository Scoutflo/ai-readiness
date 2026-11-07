#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import copy,datetime,json,os,pathlib,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]);stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ');date=stamp[:10]
identity={'kind':'kubernetes','cluster_id':'cluster-a','namespace':'prod','service_name':'checkout'}
evidence={'target':'datadog/a','observed_at':stamp,'ref':'raw/source.json#monitor-1'}
collection={'status':'complete','scope':'target','observed_at':stamp}
base={'schema':'scoutflo-inventory/v1','target':'datadog/a','generated_at':stamp,'items':[{'name':'m1','service_identity':identity,'identity_evidence':evidence}],'collection':collection}
count=0
with tempfile.TemporaryDirectory() as temp:
 p=pathlib.Path(temp);f=p/'inventory.json'
 def check(doc,valid):
  global count
  f.write_text(json.dumps(doc));r=subprocess.run(['sh',str(root/'report-standard/check-correlation-evidence.sh'),str(f)],capture_output=True,text=True)
  assert (r.returncode==0)==valid,(doc,r.stdout,r.stderr);count+=1
 check(base,True)
 legacy=copy.deepcopy(base);legacy.pop('collection');legacy['items']=[{'name':'m1'}];check(legacy,True)
 for key,value in [('cluster_id',''),('kind','future-kind')]:
  x=copy.deepcopy(base);x['items'][0]['service_identity'][key]=value;check(x,False)
 for key,value in [('target','datadog/b'),('observed_at','2000-01-01T00:00:00Z'),('ref','../secret'),('ref','https://example.test/secret')]:
  x=copy.deepcopy(base);x['items'][0]['identity_evidence'][key]=value;check(x,False)
 x=copy.deepcopy(base);x['collection']['status']='partial';check(x,False);x['collection']['reason']='page unavailable';check(x,True)
 x=copy.deepcopy(base);x['items'][0].pop('identity_evidence');check(x,False)
 findings={'schema':'scoutflo-findings/v2','target':'datadog/a','generated_at':stamp,'run_date':date,'collection':collection,'findings':[{'affected':['checkout'],'correlation_bindings':[{'affected':'checkout','service_identity':identity,'evidence':evidence}]}]}
 check(findings,True);findings['findings'][0]['correlation_bindings'][0]['affected']='other';check(findings,False)
 out=p/'audits';out.mkdir();plan=out/'run-plan.json';env={**os.environ,'SCOUTFLO_AUDIT_DIR':str(out)}
 for targets,valid in [(['datadog/a','clickstack/b'],True),([],False),(['datadog/a','datadog/a'],False),(['../bad'],False)]:
  plan.write_text(json.dumps({'schema':'scoutflo-audit-plan/v1','audit_date':date,'started_at':stamp,'targets':targets,'completed_targets':[],'completion_receipts':{}}));r=subprocess.run(['sh',str(root/'report-standard/write-coverage-assessment.sh'),str(plan)],env=env,capture_output=True,text=True)
  assert (r.returncode==0)==valid,(targets,r.stderr);count+=1
  if valid:assert json.loads((out/'coverage-assessment.json').read_text())['expected_targets']==targets
  else:assert json.loads((out/'coverage-assessment.json').read_text())['status']=='blocked'
print(str(count)+' evidence-schema/queue cases PASS')
PY
