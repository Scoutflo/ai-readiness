#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime,fcntl,json,os,pathlib,subprocess,sys,tempfile,unittest
root=pathlib.Path(sys.argv.pop());script=root/'skills/audit-clickstack/scripts/assessment-worklist.sh'
class Checks(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.temp.name);self.cfg=self.p/'config.yaml';self.store=self.p/'env';self.audits=self.p/'audits'
  self.now=datetime.datetime.now(datetime.timezone.utc);self.day=self.now.strftime('%Y-%m-%d');self.out=self.audits/'clickstack'/'region-b'/self.day;(self.out/'raw').mkdir(parents=True)
  self.cfg.write_text('clickstack:\n  - label: region-a\n    clickhouse_url: https://wrong.example.test\n  - label: region-b\n    clickhouse_url: https://database.example.test\n    clickhouse_user: auditor\n    clickhouse_password_env: CH_B\n    hyperdx_url: https://sources.example.test\n    hyperdx_api_key_env: HDX_B\n')
  self.store.write_text('CH_B=private-read-credential\nHDX_B=private-source-credential\n')
  self.env={**os.environ,'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(self.cfg),'SCOUTFLO_ENV_FILE':str(self.store),'SCOUTFLO_AUDIT_DIR':str(self.audits),'SCOUTFLO_TARGET':'region-b'};self.env.pop('SCOUTFLO_CLICKSTACK_RUN_DATE',None)
  self.bin=self.p/'bin';self.bin.mkdir()
  for binary in ('curl','gcloud','aws','kubectl','clickhouse-client'):
   stub=self.bin/binary;stub.write_text('#!/bin/sh\necho unexpected-provider-call >&2\nexit 97\n');stub.chmod(0o755)
  self.env['PATH']=str(self.bin)+os.pathsep+self.env['PATH'];self.scope={'target':'clickstack/region-b','observed_at':self.now.strftime('%Y-%m-%dT%H:%M:%SZ'),'declared_by':'operator','evidence_ref':'raw/intended-services.md','services':['checkout','expected-missing'],'capture_refs':['raw/coverage-projection.json']}
  self.hdx={'schema':'scoutflo-hyperdx-configuration/v1','target':'clickstack/region-b','observed_at':self.scope['observed_at'],'resources':{name:{'status':'partial','items':[{'id':name+'-1'}]} for name in ('alerts','dashboards','sources')}}
  (self.out/'raw/coverage-projection.json').write_text(json.dumps({'data':[{'ServiceName':'checkout','rows':12}]}))
  self.write_inputs()
 def tearDown(self):self.temp.cleanup()
 def write_inputs(self):
  (self.out/'raw/intended-services.md').write_text('Operator declared both services in scope; absent observations remain assessed as unknown or absent when collection allows.\n')
  (self.out/'raw/assessment-scope.json').write_text(json.dumps(self.scope))
  (self.out/'raw/hyperdx-configuration.json').write_text(json.dumps(self.hdx))
 def run_helper(self,*args,success=True):
  r=subprocess.run(['sh',str(script),*map(str,args)],env=self.env,capture_output=True,text=True,timeout=30)
  self.assertEqual(r.returncode==0,success,r.stdout+r.stderr)
  for key in ('private-read-credential','private-source-credential','unexpected-provider-call'):self.assertNotIn(key,r.stdout+r.stderr)
  return r
 def claim(self,n=50):return json.loads(self.run_helper('claim',n).stdout)
 def proof(self,claim,name='batch.json'):
  proof={k:claim[k] for k in ('run_id','binding_sha256','objects')};proof['checks']=[{'id':v,'result':'blocked'} for v in ('CS-010','CS-011','CS-040','CS-041')]
  path=self.out/'raw'/name;path.write_text(json.dumps(proof));return path,proof
 def test_four_families_pending_resume_and_exact_completion(self):
  statepath=pathlib.Path(self.run_helper('init').stdout.strip());self.run_helper('check',success=False)
  c=self.claim();self.assertEqual(c,self.claim(1));self.assertEqual({x['kind'] for x in c['objects']},{'service','alert','dashboard','source'});self.assertIn({'kind':'service','id':'expected-missing'},c['objects'])
  proof,_=self.proof(c);self.run_helper('done',proof);r=self.run_helper('check');self.assertIn('collection completeness is separate',r.stdout)
  state=json.loads(statepath.read_text());self.assertTrue(all(x['status']=='done' for x in state['rows']));self.assertEqual(statepath.stat().st_mode&0o777,0o600)
  for path in self.audits.rglob('clickstack-worklist.json'):
   self.assertNotIn('credential\"',path.read_text());self.assertNotIn('https://',path.read_text())
 def test_missing_family_checks_and_wrong_batch_proof_rejected(self):
  c=self.claim();p,value=self.proof(c);value['checks']=[{'id':'CS-010','result':'pass'}];p.write_text(json.dumps(value));self.run_helper('done',p,success=False)
  p,value=self.proof(c);value['objects'].pop();p.write_text(json.dumps(value));self.run_helper('done',p,success=False)
  p,value=self.proof(c);value['run_id']='other-run';p.write_text(json.dumps(value));self.run_helper('done',p,success=False)
  p,value=self.proof(c);value['binding_sha256']='0'*64;p.write_text(json.dumps(value));self.run_helper('done',p,success=False)
 def test_capture_and_proof_changes_do_not_resume_old_done(self):
  c=self.claim();p,_=self.proof(c);self.run_helper('done',p);self.run_helper('check')
  p.write_text(p.read_text()+' ');self.run_helper('check',success=False)
  self.hdx['resources']['sources']['status']='complete';self.write_inputs();new=self.claim();self.assertNotEqual(new['run_id'],c['run_id']);self.run_helper('done',p,success=False)
 def test_clickhouse_evidence_capture_changes_invalidate_assessment(self):
  c=self.claim();p,_=self.proof(c);self.run_helper('done',p);self.run_helper('check')
  (self.out/'raw/coverage-projection.json').write_text('{"data":[]}');self.run_helper('check',success=False)
  fresh=self.claim();self.assertNotEqual(c['run_id'],fresh['run_id']);self.run_helper('done',p,success=False)
  self.scope['capture_refs']=[];self.write_inputs();self.run_helper('claim',success=False)
 def test_credentials_names_url_and_declared_scope_each_bind(self):
  previous=self.claim()['run_id']
  for change in ('credential','env-name','url','scope'):
   if change=='credential':self.store.write_text('CH_B=rotated-read-credential\nHDX_B=private-source-credential\n')
   elif change=='env-name':self.cfg.write_text(self.cfg.read_text().replace('clickhouse_password_env: CH_B','clickhouse_password_env: CH_ROTATED'));self.store.write_text(self.store.read_text()+'CH_ROTATED=rotated-read-credential\n')
   elif change=='url':self.cfg.write_text(self.cfg.read_text().replace('database.example.test','new-database.example.test'))
   else:self.scope['services'].append('payments');self.write_inputs()
   current=self.claim()['run_id'];self.assertNotEqual(previous,current,change);previous=current
 def test_target_ambiguity_and_wrong_capture_target_block(self):
  self.env.pop('SCOUTFLO_TARGET');self.run_helper('init',success=False);self.env['SCOUTFLO_TARGET']='region-b'
  self.hdx['target']='clickstack/region-a';self.write_inputs();self.run_helper('init',success=False)
 def test_expired_future_and_wrong_date_block(self):
  for offset in (-90000,120):
   self.scope['observed_at']=(self.now+datetime.timedelta(seconds=offset)).strftime('%Y-%m-%dT%H:%M:%SZ');self.write_inputs();self.run_helper('init',success=False)
  self.env['SCOUTFLO_CLICKSTACK_RUN_DATE']='2099-01-01';self.run_helper('init',success=False)
  self.env['SCOUTFLO_CLICKSTACK_RUN_DATE']='invalid';self.run_helper('init',success=False)
 def test_unchanged_capture_can_resume_explicit_prior_date(self):
  previous=self.now.replace(hour=0,minute=0,second=0,microsecond=0)-datetime.timedelta(seconds=1)
  self.day=previous.strftime('%Y-%m-%d');self.out=self.audits/'clickstack'/'region-b'/self.day;(self.out/'raw').mkdir(parents=True)
  self.scope['observed_at']=previous.strftime('%Y-%m-%dT%H:%M:%SZ');self.hdx['observed_at']=self.scope['observed_at'];(self.out/'raw/coverage-projection.json').write_text('{"data":[]}');self.write_inputs();self.env['SCOUTFLO_CLICKSTACK_RUN_DATE']=self.day
  claim=self.claim();self.assertEqual(claim,self.claim());self.assertEqual(claim['run_date'],self.day)
  self.scope['observed_at']=(self.now-datetime.timedelta(seconds=90000)).strftime('%Y-%m-%dT%H:%M:%SZ');self.write_inputs();self.run_helper('claim',success=False)
 def test_active_os_lock_never_reclaimed_by_age(self):
  self.run_helper('init');lock=self.out.parent/'runs/.assessment.lock'
  with lock.open('a+') as stream:
   fcntl.flock(stream,fcntl.LOCK_EX);os.utime(lock,(1,1));self.run_helper('claim',success=False)
  self.run_helper('claim')
 def test_state_cannot_drop_or_duplicate_objects(self):
  path=pathlib.Path(self.run_helper('init').stdout.strip());original=json.loads(path.read_text())
  for rows in ([],original['rows']+original['rows'][:1],original['rows'][1:]):
   changed={**original,'rows':rows};path.write_text(json.dumps(changed));self.run_helper('check',success=False)
   self.run_helper('claim',success=False)
 def test_symlink_proofs_and_scope_path_escape_block(self):
  c=self.claim();p,_=self.proof(c);link=self.out/'raw/link.json';link.symlink_to(p);self.run_helper('done',link,success=False)
  self.scope['evidence_ref']='../outside.md';self.write_inputs();self.run_helper('init',success=False)
 def test_duplicate_json_and_secret_ids_block(self):
  (self.out/'raw/assessment-scope.json').write_text('{"target":"clickstack/region-b","target":"clickstack/region-b"}');self.run_helper('init',success=False)
  self.scope['services']=['token:private-read-credential'];self.write_inputs();self.run_helper('init',success=False)
 def test_no_hyperdx_explicit_scope_still_assessed(self):
  self.cfg.write_text(self.cfg.read_text().replace('    hyperdx_url: https://sources.example.test\n',''))
  c=self.claim();self.assertEqual({x['kind'] for x in c['objects']},{'service'});p,_=self.proof(c);self.run_helper('done',p);self.run_helper('check')
unittest.main()
PY
