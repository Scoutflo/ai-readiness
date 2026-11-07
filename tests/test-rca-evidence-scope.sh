#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime,json,os,pathlib,re,subprocess,sys,tempfile,unittest
root=pathlib.Path(sys.argv.pop());day=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d');stamp=day+'T00:00:00Z'
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);self.a=self.p/'audits space';(self.p/'home').mkdir();(self.p/'bin').mkdir()
  self.env={'PATH':str(self.p/'bin')+':'+os.environ['PATH'],'HOME':str(self.p/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_AUDIT_DIR':str(self.a),'RCA_TARGET':'aws/east','RCA_RESOURCE':'checkout','RCA_RUN_DATE':day,'PYTHONDONTWRITEBYTECODE':'1'}
  for name in ('curl','wget','aws','gcloud','az','kubectl'):
   self.binary(name,'echo "Unexpected provider call" >&2; exit 99')
  for provider in ('aws','grafana'):
   for region in ('east','west'):
    target=provider+'/'+region;identity={'kind':'kubernetes','cluster_id':region,'namespace':'shop','service_name':'checkout'};proof={'target':target,'observed_at':stamp,'ref':'raw/selector.json'}
    self.write(target,'findings.json',{'schema':'scoutflo-findings/v2','target':target,'run_date':day,'generated_at':stamp,'collection':{'status':'complete','scope':'target','observed_at':stamp},'findings':[{'id':'CHECK-001','area':'alerting','severity':'high','title':'Missing alert','affected':['checkout'],'correlation_bindings':[{'affected':'checkout','service_identity':identity,'evidence':proof}]}]})
    self.write(target,'inventory.json',{'schema':'scoutflo-inventory/v1','target':target,'generated_at':stamp,'collection':{'status':'complete','scope':'target','observed_at':stamp},'items':[] if provider=='aws' else [{'kind':'alert','name':region+'-monitor','covers':'checkout','enabled':True,'routes_to':'pager','service_identity':identity,'identity_evidence':proof}]})
  (self.a/'coverage-assessment.json').write_text(json.dumps({'schema':'scoutflo-coverage-assessment/v1','audit_date':day,'expected_targets':['aws/east','aws/west','grafana/east','grafana/west']}))
 def tearDown(self):self.tmp.cleanup()
 def binary(self,name,body):p=self.p/'bin'/name;p.write_text('#!/bin/sh\n'+body+'\n');p.chmod(0o755)
 def write(self,t,name,value):p=self.a/t/day/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(value));return p
 def edit(self,t,name,fn):p=self.a/t/day/name;d=json.loads(p.read_text());fn(d);p.write_text(json.dumps(d))
 def runsh(self,code,extra=None):return subprocess.run(['sh','-c','set -eu\n'+code],env={**self.env,**(extra or {})},cwd=self.p,capture_output=True,text=True,timeout=30)
 def read(self,mode,extra=None):r=self.runsh('sh "$CLAUDE_PLUGIN_ROOT/skills/rca/scripts/read-evidence.sh" '+mode,extra);self.assertEqual(r.returncode,0,r.stdout+r.stderr);return json.loads(r.stdout)
 def test_reports_exact_target_date_resource_and_dates_visible(self):
  d=self.read('reports');self.assertEqual(len(d['findings']),1);self.assertEqual(d['findings'][0]['target'],'aws/east');self.assertEqual(d['findings'][0]['run_date'],day)
  self.assertEqual(self.read('reports',{'RCA_RESOURCE':'check'})['findings'],[])
  self.edit('aws/east','findings.json',lambda d:d.update(target='aws/west'));self.assertEqual(self.read('reports')['findings'],[])
 def test_conflicting_date_hidden_legacy_explicitly_labeled(self):
  self.edit('aws/east','findings.json',lambda d:d.update(run_date='2000-01-01'));self.assertEqual(self.read('reports')['findings'],[])
  self.edit('aws/east','findings.json',lambda d:d.pop('run_date'));self.assertEqual(self.read('reports')['findings'][0]['date_source'],'legacy-directory');self.assertEqual(self.read('correlation')['overlaps'],[])
 def test_same_names_across_regions_do_not_join(self):
  d=self.read('correlation');self.assertEqual(len(d['overlaps']),1);self.assertEqual(d['overlaps'][0]['targets'],['aws/east','grafana/east'])
  c=self.read('coverage')['coverage'];self.assertEqual(len(c),1);self.assertEqual(c[0]['covered_by'][0]['target'],'grafana/east');self.assertNotIn('west',json.dumps(c))
 def test_cache_poisoning_ignored_and_unknown_activation_preserved(self):
  (self.a/'correlation.json').write_text('{bad-stale-data')
  before=(self.a/'correlation.json').read_bytes();self.assertEqual(len(self.read('correlation')['overlaps']),1)
  self.edit('grafana/east','inventory.json',lambda d:d['items'][0].update(enabled=None))
  self.assertEqual(self.read('coverage')['coverage'][0]['classification'],'unmappable');self.assertEqual((self.a/'correlation.json').read_bytes(),before)
 def test_stale_or_future_bindings_do_not_join(self):
  self.edit('grafana/east','findings.json',lambda d:d.update(generated_at='2099-01-01T00:00:00Z'));self.assertEqual(self.read('correlation')['overlaps'],[])
  self.edit('grafana/east','inventory.json',lambda d:d['items'][0]['identity_evidence'].update(observed_at='2000-01-01T00:00:00Z'));self.assertEqual(self.read('coverage')['coverage'][0]['classification'],'unmappable')
 def test_absence_is_scoped_and_source_files_unchanged(self):
  self.edit('grafana/east','inventory.json',lambda d:d.update(items=[]));self.edit('grafana/west','inventory.json',lambda d:d.update(items=[]))
  before={p:p.read_bytes() for p in self.a.rglob('*.json')};row=self.read('coverage')['coverage'][0];self.assertEqual(row['classification'],'true-gap');self.assertIn('declared assessed targets',row['recommendation'])
  self.assertEqual(before,{p:p.read_bytes() for p in self.a.rglob('*.json')})
  (self.a/'coverage-assessment.json').unlink();self.assertEqual(self.read('coverage')['coverage'][0]['classification'],'unmappable')
 def test_topology_qualified_ids_and_configuration_preserved(self):
  entities=[{'id':r+n,'target':'kubernetes/'+r,'entity_type':'service','name':n} for r in ('east','west') for n in ('checkout','database')]
  edges=[{'from_id':r+'checkout','to_id':r+'database','relation':'CALLS','evidence':{'kind':'configuration','observed_at':stamp,'target':'kubernetes/'+r}} for r in ('east','west')]
  p=self.p/'map.json';p.write_text(json.dumps({'schema':'scoutflo-estate-topology/v1','audit_date':day,'generated_at':stamp,'entities':entities,'relationships':edges,'source_maps':[],'completeness':'partial-or-unknown'}))
  block=next(b for b in re.findall(r'```bash\n(.*?)\n```',(root/'skills/rca/SKILL.md').read_text(),re.S) if 'read-evidence.sh" topology' in b)
  result=self.runsh(block,{'RCA_TARGET':'kubernetes/east','RCA_TOPOLOGY':str(p)});self.assertEqual(result.returncode,0,result.stderr);d=json.loads(result.stdout);self.assertEqual(len(d['edges']),1);self.assertEqual(d['edges'][0]['to']['id'],'eastdatabase');self.assertEqual(d['edges'][0]['evidence']['kind'],'configuration');self.assertIn('Missing edges do not prove',d['limitation'])
 def live(self,server='https://cluster-b.example.test',extra=None,code=None):
  cfg=self.p/'config.yaml';cfg.write_text('kubernetes:\n  - label: a\n    context: context-a\n  - label: b\n    context: context-b\n')
  self.binary('kubectl', '''printf '%s\\n' "$*" >> "$HOME/calls"
case "$*" in
 *"config get-contexts"*) echo context-b ;;
 *"auth can-i"*) echo yes ;;
 *"config view"*) printf '%s' '{"clusters":[{"cluster":{"server":"'''+server+'''"}}]}' ;;
 *"version"*) echo '{"serverVersion":{"gitVersion":"v1.30.0"}}' ;;
 *"get pod"*) echo '{"status":{"phase":"Running","containerStatuses":[]}}' ;;
 *"get events"*) echo '{"items":[]}' ;;
 *"logs"*) echo 'synthetic bounded log' ;;
 *) exit 99 ;;
esac''')
  return self.runsh(code or '. "$CLAUDE_PLUGIN_ROOT/skills/rca/scripts/live-context.sh"',{'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_TARGET':'b','RCA_TARGET':'kubernetes/b','RCA_EXPECTED_SERVER':'https://cluster-b.example.test',**(extra or {})})
 def test_live_selected_context_identity_and_foreign_endpoint(self):
  r=self.live();self.assertEqual(r.returncode,0,r.stderr);self.assertTrue(all('--context context-b' in x for x in (self.p/'home/calls').read_text().splitlines()))
  (self.p/'home/calls').write_text('');r=self.live('https://foreign.example.test');self.assertNotEqual(r.returncode,0);self.assertNotIn('Verified',r.stdout)
  self.assertNotIn('auth can-i',(self.p/'home/calls').read_text());self.assertNotIn('version',(self.p/'home/calls').read_text())
 def test_live_unknown_label_and_report_scope_mismatch_stop(self):
  for extra in ({'SCOUTFLO_TARGET':'missing'},{'RCA_TARGET':'kubernetes/a'}):
   r=self.live(extra=extra);self.assertNotEqual(r.returncode,0,r.stdout)
 def test_events_rollout_redact_before_stdout_and_preserve_json(self):
  canary='synthetic-credential-do-not-print'
  self.binary('kubectl',"printf '%s' "+"'"+json.dumps({'items':[{'message':'X-VO-Api-Key: '+canary,'reason':'Warning'}],'status':{'conditions':[{'message':'https://alert.victorops.com/integrations/generic/20131114/alert/'+canary+'/route','status':'False'}]}})+"'")
  for call in ('probe_events c n p','probe_rollout c n d'):
   r=self.runsh('. "$CLAUDE_PLUGIN_ROOT/skills/live-evidence/lib/live-evidence.sh"\n'+call);self.assertEqual(r.returncode,0,r.stderr);self.assertNotIn(canary,r.stdout+r.stderr);json.loads(r.stdout);self.assertIn('[REDACTED]',r.stdout)
  r=self.runsh('. "$CLAUDE_PLUGIN_ROOT/skills/live-evidence/lib/live-evidence.sh"\nunset CLAUDE_PLUGIN_ROOT\nprobe_events c n p');self.assertNotEqual(r.returncode,0);self.assertEqual(r.stdout,'');self.assertNotIn(canary,r.stderr)
 def test_exact_audit_all_top_findings_block_with_spaces(self):
  code=next(b for b in re.findall(r'```bash\n(.*?)\n```',(root/'skills/audit-all/SKILL.md').read_text(),re.S) if 'sort_by(.rank)' in b)
  self.write('all','findings.json',{'target':'all','findings':[{'title':'not-a-per-audit'}]})
  r=self.runsh(code);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(len(r.stdout.splitlines()),4);self.assertNotIn('not-a-per-audit',r.stdout)
 def test_exact_doctor_and_live_blocks(self):
  blocks=re.findall(r'```bash\n(.*?)\n```',(root/'skills/rca/SKILL.md').read_text(),re.S)
  r=self.runsh(blocks[0]);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  for block in blocks:
   if 'live-context.sh' not in block:continue
   r=self.live(code=block,extra={'RCA_NAMESPACE':'shop','RCA_POD':'checkout-pod'});self.assertEqual(r.returncode,0,r.stdout+r.stderr)
 def test_exact_rca_local_blocks(self):
  for b in re.findall(r'```bash\n(.*?)\n```',(root/'skills/rca/SKILL.md').read_text(),re.S):
   if 'read-evidence.sh' in b and ' topology' not in b:
    r=self.runsh(b);self.assertEqual(r.returncode,0,r.stderr);json.loads(r.stdout)
unittest.main()
PY
