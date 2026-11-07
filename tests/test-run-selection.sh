#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import concurrent.futures,datetime,hashlib,json,os,pathlib,re,shutil,subprocess,sys,tempfile,unittest
root=pathlib.Path(sys.argv.pop());now=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0);day=now.strftime('%Y-%m-%d');stamp=now.strftime('%Y-%m-%dT%H:%M:%SZ');start=(now-datetime.timedelta(seconds=10)).strftime('%Y-%m-%dT%H:%M:%SZ')
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);self.a=self.p/'audit space';self.a.mkdir();(self.p/'home').mkdir();(self.p/'bin').mkdir()
  for name in ('curl','wget','aws','gcloud','kubectl','az'):
   f=self.p/'bin'/name;f.write_text('#!/bin/sh\necho forbidden >&2\nexit 99\n');f.chmod(0o755)
  self.env={'PATH':str(self.p/'bin')+':'+os.environ['PATH'],'HOME':str(self.p/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_AUDIT_DIR':str(self.a),'PYTHONDONTWRITEBYTECODE':'1'}
  self.plan={'schema':'scoutflo-audit-plan/v1','audit_date':day,'started_at':start,'targets':['aws/east','aws/west'],'completed_targets':[],'completion_receipts':{}};self.saveplan()
  for t in ['aws/east','aws/west','grafana/unselected']:self.fixture(t)
 def tearDown(self):self.tmp.cleanup()
 def saveplan(self): (self.a/'run-plan.json').write_text(json.dumps(self.plan))
 def fixture(self,t,collection=False):
  p=self.a/t/day;p.mkdir(parents=True,exist_ok=True)
  f={'schema':'scoutflo-findings/v1','toolkit_version':'0.1.78','skill':'audit-fixture','target':t,'run_date':day,'generated_at':stamp,'score':{'overall':100,'gate':85,'end_to_end':False,'categories':[{'name':'Signals','weight':100,'score':100,'maturity':'proactive','checks_passed':1,'checks_total':1}],'excluded':[]},'severity_counts':dict.fromkeys(['critical','high','medium','low','info'],0),'findings':[]}
  i={'schema':'scoutflo-inventory/v1','target':t,'generated_at':stamp,'counts':{'total':0,'by_kind':{}},'items':[]}
  if collection:
   for doc in (f,i):doc['collection']={'status':'complete','scope':'target','observed_at':stamp}
  (p/'findings.json').write_text(json.dumps(f));(p/'inventory.json').write_text(json.dumps(i))
  (p/'report.md').write_text('# Audit\n\n| Target | '+t+' |\n| Date | '+day+' (UTC) |\n| Toolkit version | 0.1.78 |\n| Skill | audit-fixture |\n\n## At a glance\n\n**Score: 100/100**\n\n## Executive summary\n\n**Score: 100/100**\n\n## Scorecard\n\nSignals assessed.\n\n## Inventory\n\nNo objects observed.\n\n## Findings\n\nNo observed defects.\n\n## Next safe actions\n\nVerify coverage.\n\n## Evidence appendix\n\nSynthetic local validator fixture.\n')
 def command(self,*args):return subprocess.run(['python3',str(root/'report-standard/run-selection.py'),args[0],str(self.a),day,*args[1:]],env=self.env,capture_output=True,text=True,timeout=65)
 def complete(self,t):r=self.command('complete',t);self.assertEqual(r.returncode,0,r.stdout+r.stderr);return r
 def shell(self,b):return subprocess.run(['sh','-c','set -eu\n'+b],env=self.env,capture_output=True,text=True,timeout=65)
 def edits(self,t,name,fn):p=self.a/t/day/name;d=json.loads(p.read_text());fn(d);p.write_text(json.dumps(d))
 def test_real_validators_allow_fresh_legacy_without_claiming_collection(self):
  self.complete('aws/east');p=json.loads((self.a/'run-plan.json').read_text());self.assertEqual(p['completed_targets'],['aws/east']);self.assertEqual(set(p['completion_receipts']['aws/east']['artifacts']),{'findings.json','inventory.json','report.md'})
  r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/correlation-engine/lib/correlation-engine.sh"\ncorrelation_assess_inputs '+day);self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(json.loads(r.stdout)['absence_assessable'])
 def test_native_fractional_history_completes_and_orders_by_instant(self):
  second=(now-datetime.timedelta(seconds=2)).strftime('%Y-%m-%dT%H:%M:%S')
  self.plan['started_at']=second+'Z';self.saveplan()
  history=self.a/'aws/east'/day/'oncall-history.json'
  history.write_text(json.dumps({'target':'aws/east','generated_at':second+'.500000Z'}))
  self.complete('aws/east');self.assertEqual(self.command('snapshot').returncode,0)
  self.plan['started_at']=second+'.600000Z';self.saveplan()
  r=self.command('complete','aws/east');self.assertNotEqual(r.returncode,0);self.assertIn('Native history does not belong',r.stderr)
 def test_previous_same_day_generation_cannot_complete(self):
  self.edits('aws/east','findings.json',lambda d:d.update(generated_at=day+'T00:00:00Z'));r=self.command('complete','aws/east');self.assertNotEqual(r.returncode,0);self.assertEqual(json.loads((self.a/'run-plan.json').read_text())['completed_targets'],[])
 def test_old_future_or_conflicting_collection_cannot_complete(self):
  for value in [day+'T00:00:00Z','2099-01-01T00:00:00Z']:
   self.fixture('aws/east',True);self.edits('aws/east','inventory.json',lambda d:d['collection'].update(observed_at=value));self.assertNotEqual(self.command('complete','aws/east').returncode,0)
  self.fixture('aws/east');self.edits('aws/east','inventory.json',lambda d:d.update(target='aws/west'));self.assertNotEqual(self.command('complete','aws/east').returncode,0)
 def test_real_score_report_and_inventory_validation_blocks(self):
  for name,fn in [('findings.json',lambda d:d['score'].update(overall=10)),('inventory.json',lambda d:d['counts'].update(total=99))]:
   self.fixture('aws/east');self.edits('aws/east',name,fn);self.assertNotEqual(self.command('complete','aws/east').returncode,0)
  self.fixture('aws/east');(self.a/'aws/east'/day/'report.md').write_text('# Incomplete\n');self.assertNotEqual(self.command('complete','aws/east').returncode,0)
 def test_unselected_and_unfinished_never_consume_old_files(self):
  self.complete('aws/east')
  block='. "$CLAUDE_PLUGIN_ROOT/report-standard/run-selection.sh"\nsf_run_prepare "$SCOUTFLO_AUDIT_DIR" '+day+'\nfor f in "$SCOUTFLO_AUDIT_DIR"/*/*/'+day+'/findings.json; do sf_run_file "$f" || continue; echo "$f"; done'
  r=self.shell(block);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(r.stdout.strip(),str(self.a/'aws/east'/day/'findings.json'))
  self.assertNotEqual(self.command('complete','grafana/unselected').returncode,0)
 def test_recorded_receipt_drift_is_fatal_even_between_prepare_and_read(self):
  self.complete('aws/east');p=self.a/'aws/east'/day/'findings.json'
  r=self.shell('. "$CLAUDE_PLUGIN_ROOT/report-standard/run-selection.sh"\nsf_run_prepare "$SCOUTFLO_AUDIT_DIR" '+day+'\nprintf " " >> "'+str(p)+'"\nsf_run_file "'+str(p)+'" || echo SHOULD_NOT_CONTINUE');self.assertNotEqual(r.returncode,0);self.assertNotIn('SHOULD_NOT_CONTINUE',r.stdout);self.assertNotEqual(self.command('snapshot').returncode,0)
 def test_parallel_completions_merge_without_lost_targets(self):
  with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:results=list(ex.map(lambda t:self.command('complete',t),['aws/east','aws/west']))
  for r in results:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  self.assertEqual(set(json.loads((self.a/'run-plan.json').read_text())['completed_targets']),{'aws/east','aws/west'})
 def test_malformed_plan_never_legacy_fallback(self):
  for text in ['{bad','{"schema":"scoutflo-audit-plan/v1","started_at":NaN}',json.dumps({**self.plan,'targets':['aws/east','aws/east']})]:
   (self.a/'run-plan.json').write_text(text);self.assertNotEqual(self.command('snapshot').returncode,0)
 def test_no_plan_legacy_behavior_preserved(self):
  (self.a/'run-plan.json').unlink();self.assertEqual(json.loads(self.command('snapshot').stdout),{'mode':'legacy'})
 def test_actual_aggregation_readers_exclude_unfinished(self):
  self.complete('aws/east')
  for lib,fn in [('correlation-engine','correlation_collect_findings'),('alert-fatigue','alert_fatigue_collect_findings'),('cost-analysis','cost_analysis_aggregate_findings')]:
   # Inject a valid, unselected raw finding; it must never enter a selected aggregate.
   self.edits('grafana/unselected','findings.json',lambda d:d.update(findings=[{'id':'MARKER-001','area':'cost-optimization','title':'unselected-marker'}]))
   r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/'+lib+'/lib/'+lib+'.sh"\n'+fn+' '+day);self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(json.loads(r.stdout),[])
 def test_selected_cost_ignores_stale_same_day_overlap_cache(self):
  self.complete('aws/east')
  (self.a/'correlation.json').write_text(json.dumps({'audit_date':day,'overlaps':[{'findings':[{'target':'aws/east','finding_id':'FX-001'}],'recommendation':'stale-cache-marker'}]}))
  r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/cost-analysis/lib/cost-analysis.sh"\ncost_analysis_deduplicate \'[{"id":"FX-001","source_target":"aws/east"}]\' '+day)
  self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(json.loads(r.stdout)[0]['deduplicated']);self.assertNotIn('stale-cache-marker',r.stdout)
 def test_measured_fatigue_excludes_unfinished_and_unscoped_population(self):
  self.complete('aws/east')
  signals={'schema':'scoutflo-fatigue-signals/v1','generated_at':stamp,'window':'last hour','signals':[{'provider':'aws','target':'aws/'+r,'object_id':'alarm-'+r,'object_kind':'alarm','fires':2} for r in ['east','west']], 'provider_coverage':[{'provider':'aws','target':'aws/'+r,'status':'collected','tier':'fire-history'} for r in ['east','west']], 'incident_feed':{'status':'collected','alerts_fired':4,'incidents':2}}
  (self.a/'fatigue-signals.json').write_text(json.dumps(signals))
  r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"\naudit_date='+day+'\nalert_fatigue_prepare_signals\nprintf \'%s\' "$AF_SIGNALS_DOCUMENT"')
  self.assertEqual(r.returncode,0,r.stderr);d=json.loads(r.stdout);self.assertEqual([x['target'] for x in d['signals']],['aws/east']);self.assertEqual(d['incident_feed']['status'],'verify-pending');self.assertEqual(d['provider_coverage'][1]['status'],'verify-pending')
 def test_measured_fatigue_orders_mixed_precision_by_instant(self):
  second=(now-datetime.timedelta(seconds=5)).strftime('%Y-%m-%dT%H:%M:%S')
  self.plan['started_at']=second+'.600000Z';self.saveplan();self.complete('aws/east')
  for suffix,fresh in [('Z',False),('.5Z',False),('.599999Z',False),('.5999999Z',False),('.599999999Z',False),('.6Z',True),('.600000Z',True),('.6000000Z',True),('.6000001Z',True),('.600001Z',True),('.7Z',True)]:
   with self.subTest(suffix=suffix):
    signals={'schema':'scoutflo-fatigue-signals/v1','generated_at':second+suffix,'window':'last hour','signals':[{'provider':'aws','target':'aws/east','object_id':'alarm-east','object_kind':'alarm','fires':7}], 'provider_coverage':[{'provider':'aws','target':'aws/east','status':'collected','tier':'fire-history'}], 'incident_feed':{'status':'collected','target':'aws/east','alerts_fired':7,'incidents':2}}
    (self.a/'fatigue-signals.json').write_text(json.dumps(signals))
    r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"\naudit_date='+day+'\nalert_fatigue_prepare_signals\nprintf \'%s\' "$AF_SIGNALS_DOCUMENT"')
    self.assertEqual(r.returncode,0,r.stderr);doc=json.loads(r.stdout)
    self.assertEqual(len(doc['signals']),1 if fresh else 0)
    self.assertEqual(doc['provider_coverage'][0]['status'],'collected' if fresh else 'verify-pending')
    self.assertEqual(doc['incident_feed']['status'],'collected' if fresh else 'verify-pending')
 def test_actual_renderers_exclude_unfinished_without_inherited_plugin_root(self):
  self.complete('aws/east');env={**self.env};env.pop('CLAUDE_PLUGIN_ROOT',None)
  for mode in ['rollup','inventory-rollup','exec-summary','env-compare']:
   args=[day,'qa',str(self.a)] if mode=='env-compare' else [str(self.a),day]
   r=subprocess.run(['sh',str(root/'report-standard/render-report-viz.sh'),mode,*args],env=env,capture_output=True,text=True,timeout=65)
   self.assertEqual(r.returncode,0,r.stderr);self.assertIn('across 1 stack(s)' if mode=='exec-summary' else 'aws/east',r.stdout);self.assertNotIn('aws/west','\n'.join(line for line in r.stdout.splitlines() if not line.startswith('Selected run:')));self.assertNotIn('grafana/unselected',r.stdout)
  self.edits('aws/east','findings.json',lambda d:d.update(target='aws/west'))
  r=subprocess.run(['sh',str(root/'report-standard/render-report-viz.sh'),'rollup',str(self.a),day],env=env,capture_output=True,text=True)
  self.assertNotEqual(r.returncode,0);self.assertNotIn('Stacks end-to-end',r.stdout)
 def test_measured_fatigue_refuses_same_second_future(self):
  instant=now-datetime.timedelta(seconds=5);second=instant.strftime('%Y-%m-%dT%H:%M:%S')
  self.plan['started_at']=second+'.1Z';self.saveplan();self.complete('aws/east')
  signals={'schema':'scoutflo-fatigue-signals/v1','generated_at':second+'.75Z','window':'last hour','signals':[{'provider':'aws','target':'aws/east','object_id':'alarm-east','object_kind':'alarm','fires':7}],'provider_coverage':[{'provider':'aws','target':'aws/east','status':'collected','tier':'fire-history'}]}
  (self.a/'fatigue-signals.json').write_text(json.dumps(signals))
  jq=shutil.which('jq');shim=self.p/'bin/jq'
  shim.write_text('#!'+sys.executable+'\nimport os,sys\na=sys.argv[1:]\nif a[:2]==["--argjson","run"]:a[-1]="def now: '+str(instant.timestamp()+.5)+'; "+a[-1]\nos.execv('+repr(jq)+',['+repr(jq)+']+a)\n');shim.chmod(0o755)
  r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"\naudit_date='+day+'\nalert_fatigue_prepare_signals\nprintf \'%s\' "$AF_SIGNALS_DOCUMENT"')
  self.assertEqual(r.returncode,0,r.stderr);doc=json.loads(r.stdout);self.assertEqual(doc['signals'],[]);self.assertEqual(doc['provider_coverage'][0]['status'],'verify-pending')
 def test_current_coverage_requires_completion_and_fresh_collections(self):
  self.fixture('aws/east',True);self.fixture('aws/west',True);self.complete('aws/east')
  (self.a/'coverage-assessment.json').write_text(json.dumps({'schema':'scoutflo-coverage-assessment/v1','audit_date':day,'expected_targets':['aws/east','aws/west']}))
  run=lambda:self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/correlation-engine/lib/correlation-engine.sh"\ncorrelation_assess_inputs '+day)
  r=run();self.assertEqual(r.returncode,0,r.stderr);self.assertFalse(json.loads(r.stdout)['absence_assessable']);self.complete('aws/west');self.assertTrue(json.loads(run().stdout)['absence_assessable'])
  (self.a/'coverage-assessment.json').write_text(json.dumps({'schema':'scoutflo-coverage-assessment/v1','audit_date':day,'expected_targets':['aws/east']}));self.assertFalse(json.loads(run().stdout)['absence_assessable'])
 def aggregate(self,lib):
  return self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/'+lib+'/lib/'+lib+'.sh"\n'+('correlation_run' if lib=='correlation-engine' else lib.replace('-','_')+'_run')+' '+day)
 def aggregate_path(self,lib):
  return self.a/({'correlation-engine':'correlation.json','alert-fatigue':'alert-fatigue.json','cost-analysis':'cost-analysis/'+day+'/findings.json'}[lib])
 def check_aggregate(self,path):
  return self.shell('. "$CLAUDE_PLUGIN_ROOT/report-standard/run-selection.sh"\nsf_run_prepare "$SCOUTFLO_AUDIT_DIR" '+day+'\nsf_run_aggregate_file "'+str(path)+'"')
 def test_all_aggregate_producers_bind_exact_completed_snapshot(self):
  self.complete('aws/east');expected=json.loads(self.command('snapshot').stdout)
  for lib in ['correlation-engine','alert-fatigue','cost-analysis']:
   r=self.aggregate(lib);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
   path=self.aggregate_path(lib);self.assertEqual(json.loads(path.read_text())['run_selection'],expected)
   r=self.check_aggregate(path);self.assertEqual(r.returncode,0,r.stderr)
  self.complete('aws/west')
  for lib in ['correlation-engine','alert-fatigue','cost-analysis']:
   r=self.check_aggregate(self.aggregate_path(lib));self.assertNotEqual(r.returncode,0);self.assertIn('RUN-AGGREGATE-FAIL',r.stderr)
 def test_aggregate_rejects_tampered_snapshot_date_generation_and_legacy(self):
  self.complete('aws/east');r=self.aggregate('alert-fatigue');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
  path=self.aggregate_path('alert-fatigue');original=json.loads(path.read_text())
  mutations=[lambda d:d.pop('run_selection'),lambda d:d['run_selection'].update(completed_targets=[]),lambda d:d.update(audit_date='2000-01-01'),lambda d:d.update(generated_at=day+'T00:00:00Z'),lambda d:d.update(generated_at='2099-01-01T00:00:00Z')]
  for change in mutations:
   d=json.loads(json.dumps(original));change(d);path.write_text(json.dumps(d));self.assertNotEqual(self.check_aggregate(path).returncode,0)
 def test_aggregate_orders_mixed_precision_by_instant(self):
  second=(now-datetime.timedelta(seconds=5)).strftime('%Y-%m-%dT%H:%M:%S')
  self.plan['started_at']=second+'.600000Z';self.saveplan();self.complete('aws/east')
  path=self.a/'aggregate.json';snapshot=json.loads(self.command('snapshot').stdout)
  for suffix,fresh in [('Z',False),('.5Z',False),('.599999Z',False),('.6Z',True),('.600000Z',True),('.600001Z',True),('.7Z',True)]:
   with self.subTest(suffix=suffix):
    path.write_text(json.dumps({'generated_at':second+suffix,'audit_date':day,'run_selection':snapshot}))
    r=self.check_aggregate(path);self.assertEqual(r.returncode==0,fresh,r.stderr)
 def test_plan_completion_during_each_aggregate_cannot_publish(self):
  for lib,collector,entry in [('correlation-engine','correlation_collect_findings','correlation_run'),('alert-fatigue','alert_fatigue_collect_findings','alert_fatigue_run'),('cost-analysis','cost_analysis_aggregate_findings','cost_analysis_run')]:
   self.saveplan();self.complete('aws/east')
   block='. "$CLAUDE_PLUGIN_ROOT/skills/'+lib+'/lib/'+lib+'.sh"\n'+collector+'() { python3 "$CLAUDE_PLUGIN_ROOT/report-standard/run-selection.py" complete "$SCOUTFLO_AUDIT_DIR" '+day+' aws/west >/dev/null || return 1; printf \'[]\\n\'; }\nif '+entry+' '+day+'; then echo SHOULD_NOT_SUCCEED; else exit 1; fi'
   r=self.shell(block);self.assertNotEqual(r.returncode,0,r.stdout+r.stderr);self.assertNotIn('SHOULD_NOT_SUCCEED',r.stdout);self.assertIn('selected run changed during analysis',r.stderr);self.assertFalse(self.aggregate_path(lib).exists())
 def test_no_plan_aggregate_envelopes_keep_legacy_behavior(self):
  (self.a/'run-plan.json').unlink()
  for lib in ['correlation-engine','alert-fatigue','cost-analysis']:
   r=self.aggregate(lib);self.assertEqual(r.returncode,0,r.stdout+r.stderr);path=self.aggregate_path(lib)
   self.assertNotIn('run_selection',json.loads(path.read_text()));self.assertEqual(self.check_aggregate(path).returncode,0)

unittest.main()
PY
