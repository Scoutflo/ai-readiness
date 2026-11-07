#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime,fcntl,hashlib,json,os,pathlib,re,subprocess,sys,tempfile,unittest
root=pathlib.Path(sys.argv.pop());script=root/'skills/map-topology/lib/cloud-worklist.py'
class Worklist(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);bins=self.p/'bin';bins.mkdir();self.provider=self.p/'provider-called'
  for name in ['aws','gcloud','az','doctl','kubectl','curl']:
   f=bins/name;f.write_text('#!/bin/sh\ntouch "'+str(self.provider)+'"\nexit 99\n');f.chmod(0o700)
  self.env={**os.environ,'PATH':str(bins)+':'+os.environ['PATH'],'HOME':str(self.p),'PYTHONDONTWRITEBYTECODE':'1'}
  self.config=self.p/'toolkit.yaml';self.config.write_text('aws:\n  - label: east\n    profile: fixture-east\n    region: fixture-region\n  - label: west\n    profile: fixture-west\n    region: fixture-region\n')
  self.capture=self.p/'capture.json';self.capture.write_text('{"services":["service-a","service-b"]}')
  self.at=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ');self.catalog=self.p/'catalog.json';self.audit=self.p/'audits'
  self.cat={'schema':'scoutflo-cloud-topology-catalog/v1','target':'aws/east','audit_date':self.at[:10],'observed_at':self.at,'collection':{'status':'complete','scope':'target'},'services':[{'id':x,'kind':'ecs','lanes':['declared']} for x in ['service-a','service-b']],'captures':[self.evidence()]};self.save()
  self.args=['--catalog',str(self.catalog),'--config',str(self.config),'--target','aws/east','--root',str(self.audit)]
 def tearDown(self):
  self.assertFalse(self.provider.exists(),'local assessment invoked a provider');self.tmp.cleanup()
 def evidence(self):
  observed=next((c['observed_at'] for c in getattr(self,'cat',{}).get('captures',[]) if c['ref']=='capture.json'),self.at)
  return {'ref':'capture.json','sha256':hashlib.sha256(self.capture.read_bytes()).hexdigest(),'observed_at':observed}
 def save(self):self.catalog.write_text(json.dumps(self.cat))
 def runit(self,command,arg=None,extra=None):
  return subprocess.run(['python3',str(script),*self.args,*(extra or []),command,*([str(arg)] if arg is not None else [])],env=self.env,capture_output=True,text=True,timeout=15)
 def ok(self,r):self.assertEqual(r.returncode,0,r.stderr);return json.loads(r.stdout) if r.stdout else None
 def start(self):self.ok(self.runit('init'));return self.ok(self.runit('claim','1'))
 def receipt(self,claim,blocked=False):
  value={'schema':'scoutflo-cloud-topology-assessment/v1','run_id':claim['run_id'],'binding_sha256':claim['binding_sha256'],'services':[{'id':r['id'],'checks':[{'lane':lane,'result':'blocked' if blocked else 'complete','reason':'access_denied' if blocked else None,'evidence':[] if blocked else [self.evidence()]} for lane in r['lanes']]} for r in claim['services']]}
  path=self.p/('receipt-'+claim['services'][0]['id']+'.json');path.write_text(json.dumps(value));return path
 def finish_all(self,blocked=False):
  self.ok(self.runit('init'));claim=self.ok(self.runit('claim','100'));p=self.receipt(claim,blocked);self.ok(self.runit('done',p));return p
 def test_interrupted_batch_resumes_and_completed_rows_are_skipped(self):
  first=self.start();self.assertEqual(self.ok(self.runit('claim','10')),first)
  self.assertNotEqual(self.runit('finish').returncode,0);self.ok(self.runit('done',self.receipt(first)))
  self.ok(self.runit('init'));second=self.ok(self.runit('claim','1'));self.assertEqual(second['services'][0]['id'],'service-b')
  self.ok(self.runit('done',self.receipt(second)));result=self.ok(self.runit('finish'));self.assertTrue(result['assessment_complete']);self.assertFalse(result['collection_completeness_proven'])
 def test_wrong_target_and_duplicate_config_label_fail(self):
  self.start();self.args[self.args.index('--target')+1]='aws/west';self.assertNotEqual(self.runit('claim').returncode,0)
  self.args[self.args.index('--target')+1]='aws/east';self.config.write_text(self.config.read_text().replace('label: west','label: east'));self.assertNotEqual(self.runit('claim').returncode,0)
 def test_config_metadata_drift_cannot_resume(self):
  self.start();self.config.write_text(self.config.read_text().replace('fixture-east','fixture-new'));self.assertNotEqual(self.runit('claim').returncode,0)
 def test_catalog_scope_drift_cannot_resume(self):
  self.start();self.cat['services'].append({'id':'service-c','kind':'ecs','lanes':['declared']});self.save();self.assertNotEqual(self.runit('init').returncode,0)
 def test_changed_capture_blocks_done_and_finish(self):
  claim=self.start();proof=self.receipt(claim);self.capture.write_text('{"changed":true}');self.assertNotEqual(self.runit('done',proof).returncode,0)
 def test_generation_mismatch_rejected(self):
  self.cat['captures'][0]['observed_at']='2020-01-01T00:00:00Z';self.save();self.assertNotEqual(self.runit('init').returncode,0)
 def test_staggered_capture_times_and_original_receipts_pass(self):
  earlier=(datetime.datetime.strptime(self.at,'%Y-%m-%dT%H:%M:%SZ')-datetime.timedelta(seconds=5)).strftime('%Y-%m-%dT%H:%M:%SZ')
  self.cat['captures'][0]['observed_at']=earlier
  second=self.p/'capture-later.json';second.write_text('{"projected":true}');self.cat['captures'].append({'ref':second.name,'sha256':hashlib.sha256(second.read_bytes()).hexdigest(),'observed_at':self.at});self.save()
  self.finish_all();self.assertTrue(self.ok(self.runit('finish'))['assessment_complete'])
 def test_altered_source_time_and_early_new_evidence_rejected(self):
  earlier=(datetime.datetime.strptime(self.at,'%Y-%m-%dT%H:%M:%SZ')-datetime.timedelta(seconds=5)).strftime('%Y-%m-%dT%H:%M:%SZ')
  self.cat['captures'][0]['observed_at']=earlier;self.save();claim=self.start();proof=self.receipt(claim);value=json.loads(proof.read_text());value['services'][0]['checks'][0]['evidence'][0]['observed_at']=self.at;proof.write_text(json.dumps(value));self.assertNotEqual(self.runit('done',proof).returncode,0)
  new=self.p/'new-capture.json';new.write_text('{"projected":true}');value['services'][0]['checks'][0]['evidence']=[{'ref':new.name,'sha256':hashlib.sha256(new.read_bytes()).hexdigest(),'observed_at':earlier}];proof.write_text(json.dumps(value));self.assertNotEqual(self.runit('done',proof).returncode,0)
  value['services'][0]['checks'][0]['evidence'][0]['observed_at']=self.at;proof.write_text(json.dumps(value));self.ok(self.runit('done',proof))
 def test_future_source_generation_rejected(self):
  future=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ');self.cat['captures'][0]['observed_at']=future;self.save();self.assertNotEqual(self.runit('init').returncode,0)
 def test_missing_or_unrelated_service_lane_rejected(self):
  claim=self.start();path=self.receipt(claim);value=json.loads(path.read_text());value['services'][0]['checks']=[];path.write_text(json.dumps(value));self.assertNotEqual(self.runit('done',path).returncode,0)
  path=self.receipt(claim);value=json.loads(path.read_text());value['services'][0]['id']='service-b';path.write_text(json.dumps(value));self.assertNotEqual(self.runit('done',path).returncode,0)
  self.assertEqual(self.ok(self.runit('claim','1')),claim)
 def test_blocked_assessment_does_not_prove_complete_collection(self):
  self.cat['collection']={'status':'blocked','scope':'unknown'};self.cat['captures']=[];self.save();self.finish_all(blocked=True);result=self.ok(self.runit('finish'));self.assertTrue(result['assessment_complete']);self.assertEqual(result['source_collection']['status'],'blocked');self.assertFalse(result['collection_completeness_proven'])
 def test_partial_catalog_retained_as_partial(self):
  self.cat['collection']={'status':'partial','scope':'subset'};self.save();self.finish_all();result=self.ok(self.runit('finish'));self.assertEqual(result['source_collection']['status'],'partial');self.assertFalse(result['collection_completeness_proven'])
 def test_tampered_receipt_and_unsafe_capture_ref_fail(self):
  proof=self.finish_all();proof.write_text(proof.read_text()+' ');self.assertNotEqual(self.runit('finish').returncode,0)
  self.cat['captures'][0]['ref']='../outside.json';self.save();self.assertNotEqual(self.runit('init').returncode,0)
 def test_lock_contention_and_pending_new_run_fail(self):
  self.start();self.assertNotEqual(self.runit('init',extra=['--new-run']).returncode,0)
  with (self.audit/'map-topology/cloud-runs/aws__east/.lock').open('a+') as lock:
   fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);self.assertNotEqual(self.runit('claim').returncode,0)
  self.ok(self.runit('claim'))
 def test_batches_cannot_reuse_one_receipt_filename(self):
  first=self.start();old=self.receipt(first);self.ok(self.runit('done',old));second=self.ok(self.runit('claim','1'));new=self.receipt(second);old.write_text(new.read_text());self.assertNotEqual(self.runit('done',old).returncode,0)
 def test_empty_duplicate_and_raw_catalog_keys_rejected(self):
  original=json.loads(json.dumps(self.cat))
  for change in ['empty','duplicate','raw']:
   self.cat=json.loads(json.dumps(original))
   if change=='empty':self.cat['services']=[]
   elif change=='duplicate':self.cat['services'].append(self.cat['services'][0])
   else:self.cat['raw_env_values']={'SYNTHETIC_TOKEN':'must-not-persist'}
   self.save();self.assertNotEqual(self.runit('init').returncode,0)
 def test_actual_fresh_shell_fences(self):
  fences=re.findall(r'```bash\n(.*?)\n```',(root/'skills/map-topology/references/cloud-worklist.md').read_text(),re.S)
  self.assertEqual(len(fences),4)
  env={**self.env,'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(self.config),'SCOUTFLO_CLOUD_TARGET':'aws/east','SCOUTFLO_CLOUD_SERVICE_CATALOG':str(self.catalog),'SCOUTFLO_AUDIT_DIR':str(self.audit),'SCOUTFLO_CLOUD_BATCH_SIZE':'100'}
  def run(code):return subprocess.run(['bash','-c',code],env=env,capture_output=True,text=True,timeout=15)
  self.ok(run(fences[0]));claim=self.ok(run(fences[1]));env['SCOUTFLO_CLOUD_ASSESSMENT_RECEIPT']=str(self.receipt(claim));self.ok(run(fences[2]));self.assertTrue(self.ok(run(fences[3]))['assessment_complete'])
unittest.main()
PY
