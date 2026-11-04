#!/bin/sh
# Execute the published cookbook, not a second implementation. All inputs are
# synthetic local artifacts. A denying curl prevents accidental provider reads.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, os, re, subprocess, sys, tempfile
root=Path(sys.argv[1]); source=root/'skills/audit-splunk-oncall/references/lifecycle.md'
code=re.findall(r'```bash\n(.*?)```',source.read_text(),re.S)[0]
version=json.loads((root/'.claude-plugin/plugin.json').read_text())['version']
passed=0
with tempfile.TemporaryDirectory(prefix='oncall-lifecycle-') as td:
 t=Path(td); base=t/'audits'; target=base/'splunk_oncall'; target.mkdir(parents=True)
 (t/'bin').mkdir(); (t/'bin/curl').write_text('#!/bin/sh\necho "UNEXPECTED NETWORK" >&2\nexit 99\n'); (t/'bin/curl').chmod(0o755)
 cfg=t/'toolkit.yaml'; cfg.write_text('splunk_oncall:\n  team_slug: team-a\n  api_id_env: UNUSED_ID\n  api_key_env: UNUSED_KEY\n')
 env={'PATH':str(t/'bin')+':'+os.environ['PATH'],'HOME':td,'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_AUDIT_DIR':str(base)}
 def ok(name,condition=True):
  global passed
  if not condition: raise AssertionError(name)
  passed+=1;print('PASS '+name)
 cats=[('Routing integrity',30,[1,2]),('Escalation and staffing',35,[3,4]),('Current coverage',25,[5,6]),('Source correlation',10,[7])]
 def seed(day,results,**extra):
  out=target/day;out.mkdir(exist_ok=True);checks=[];findings=[]
  for cat,weight,ids in cats:
   for n in ids:
    rid=f'SOC-{n:03}'; result=results.get(n,'pass'); c={'id':rid,'category':cat,'result':result,'evidence':'synthetic safe observation'}
    if result in ['partial','blocked','not-in-scope']: c['reason']='synthetic reason'
    if result=='not-in-scope': c['not_in_scope_reason']='by-design'
    checks.append(c)
    if result in ['partial','fail','blocked']:
     findings.append({'id':rid,'title':'Synthetic observed gap','severity':'medium','area':cat.lower().replace(' ','-'),'status':'blocked' if result=='blocked' else 'configured','lifecycle':'new','points_recoverable':0,'scoring_scope':'readiness','report_lanes':['general-audit','ai-sre-readiness'],'affected':['policy-a'],'evidence':[{'command':'synthetic fixture observation','observed':result}],'recommendation':'Inspect the exact synthetic path.','remediation':'setup-splunk-oncall#escalation-policies'})
  doc={'schema':'scoutflo-findings/v2','toolkit_version':version,'skill':'audit-splunk-oncall','target':'splunk_oncall','run_date':day,'generated_at':day+'T12:00:00Z','checks':checks,'score':{'gate':85,'end_to_end':False,'scoring_model':'assessed-only-v1','categories':[{'name':c,'weight':w} for c,w,_ in cats]},'severity_counts':{},'findings':findings}|extra
  (out/'findings.json').write_text(json.dumps(doc));return out
 def run(day,phase='derive',expect=0,extras={}):
  p=subprocess.run(['/bin/sh','-c',code],env=env|{'SCOUTFLO_RUN_DATE':day,'SCOUTFLO_LIFECYCLE_PHASE':phase}|extras,capture_output=True,text=True)
  if (expect==0 and p.returncode!=0) or (expect!=0 and p.returncode==0): raise AssertionError(f'{phase} {day} unexpected exit {p.returncode}\n{p.stdout}\n{p.stderr}')
  assert 'UNEXPECTED NETWORK' not in p.stderr
  return p
 def doc(day): return json.loads((target/day/'findings.json').read_text())
 def result(day,n): return next(c for c in doc(day)['checks'] if c['id']==f'SOC-{n:03}')
 def finding(day,n): return next(f for f in doc(day)['findings'] if f['id']==f'SOC-{n:03}')
 def normalize(entries,raw='explicit synthetic exemptions\n'):
  src=base/'exemptions.yaml';src.write_text(raw)
  crc=subprocess.check_output(['cksum'],input=src.read_bytes()).decode().split()
  normal=t/'normalized.json';normal.write_text(json.dumps({'source_cksum':':'.join(crc[:2]),'entries':entries}))
  env['SCOUTFLO_EXEMPTIONS_JSON']=str(normal);return normal
 def report(day):
  f=target/day/'findings.json';d=doc(day)
  lanes=subprocess.check_output(['/bin/sh',str(root/'report-standard/render-report-viz.sh'),'lanes',str(f)],text=True)
  score='**Readiness: unassessed**' if d['score']['overall'] is None else f"**Score: {d['score']['overall']}/100**"
  body=f'# Synthetic On-Call audit\n\n| | |\n| --- | --- |\n| Target | splunk_oncall |\n| Date | {day} |\n| Toolkit version | {version} |\n| Skill | audit-splunk-oncall |\n\n## At a glance\n\n{score}\n\n## Executive summary\n\nSynthetic fixture only.\n\n## Scorecard\n\nSafe fixture.\n\n{lanes}\n## Findings\n\nSynthetic fixture details are in JSON.\n\n## Next safe actions\n\nInspect fixtures.\n\n## Evidence appendix\n\nSynthetic only.\n'
  (f.parent/'report.md').write_text(body)
 seed('2026-11-01',{2:'fail',3:'partial',4:'fail',6:'blocked',7:'blocked'});run('2026-11-01')
 d=doc('2026-11-01');ok('first run uses new; scoring and fingerprint pass the real validator',all(f['lifecycle']=='new' for f in d['findings']) and d['score']['assessment']['blocked_checks']==2)
 seed('2026-11-02',{3:'partial',4:'fail',6:'blocked',7:'blocked'});run('2026-11-02');d=doc('2026-11-02')
 ok('actual pass resolves prior finding; persistent finding is unchanged',d['delta']['resolved']==['SOC-002'] and finding('2026-11-02',4)['lifecycle']=='unchanged')
 old=doc('2026-11-02');old['score']['scoring_model']='historical-model';(target/'2026-11-02/findings.json').write_text(json.dumps(old))
 seed('2026-11-03',{2:'fail',4:'fail',6:'blocked',7:'blocked'});run('2026-11-03');d=doc('2026-11-03')
 ok('regression survives incompatible score model',finding('2026-11-03',2)['lifecycle']=='regressed' and not d['delta']['score_comparable'] and d['delta']['score_change'] is None)
 normalize([{'id':'SOC-004','reason':'Explicit fixture risk accepted','approved_by':'Fixture owner','expires':'2026-11-04'},{'id':'SOC-006','reason':'Cannot hide unknown evidence','expires':'2026-11-05'}])
 seed('2026-11-04',{2:'fail',4:'fail',6:'blocked',7:'blocked'});run('2026-11-04');d=doc('2026-11-04')
 ok('live exemption retains failure in ledger and suppresses same-ID finding',result('2026-11-04',4)['result']=='fail' and result('2026-11-04',4)['suppressed'] and finding('2026-11-04',4)['lifecycle']=='suppressed' and finding('2026-11-04',4)['points_recoverable']==0)
 ok('suppression remains assessed and cannot hide blocked checks',d['score']['assessment']['suppressed_checks']==1 and result('2026-11-04',6).get('suppressed') is None and finding('2026-11-04',6)['status']=='blocked')
 seed('2026-11-05',{2:'fail',4:'fail',6:'blocked',7:'blocked'});run('2026-11-05')
 ok('expired exemption reactivates with explicit expiry flag',finding('2026-11-05',4)['exemption_expired'] and finding('2026-11-05',4)['lifecycle']=='unchanged' and not result('2026-11-05',4).get('suppressed',False) and finding('2026-11-05',4)['points_recoverable']>0)
 normal=normalize([42,{'id':'SOC-004','reason':'bad date','expires':'2026-02-30'},{'id':'SOC-002','reason':'duplicate a','expires':'2026-11-30'},{'id':'SOC-002','reason':'duplicate b','expires':'2026-11-30'}])
 p=run('2026-11-05');ok('malformed dates and duplicate exemptions ignored with diagnostic','Ignored 4 malformed or duplicate exemption entries' in p.stderr and doc('2026-11-05')['score']['assessment']['suppressed_checks']==0)
 before=(target/'2026-11-05/findings.json').read_bytes();(base/'exemptions.yaml').write_text('changed bytes\n');run('2026-11-05',expect=1)
 ok('stale normalization fails without altering canonical findings',(target/'2026-11-05/findings.json').read_bytes()==before)
 (base/'exemptions.yaml').unlink();env.pop('SCOUTFLO_EXEMPTIONS_JSON');report('2026-11-05');run('2026-11-05','history',expect=1)
 ok('history blocks changed exemption source until regeneration',not (target/'history.jsonl').exists())
 run('2026-11-05');report('2026-11-05');run('2026-11-05','history')
 history=target/'history.jsonl'; row=json.loads(history.read_text());ok('history derives canonical score and lifecycle counts',row['run_date']=='2026-11-05' and row['overall']==doc('2026-11-05')['score']['overall'] and row['lifecycle_counts']['resolved']==len(doc('2026-11-05')['delta']['resolved']))
 oldrow=dict(row,run_date='2026-10-31');oldline=json.dumps(oldrow,separators=(',',':'))
 history.write_text(oldline+'\n'+history.read_text()+'not json\n');p=run('2026-11-05','history');lines=history.read_text().splitlines()
 ok('same-day history replaces one row and preserves other rows',len(lines)==2 and lines[0]==oldline and sum(json.loads(x)['run_date']=='2026-11-05' for x in lines)==1)
 ok('malformed history retained privately with diagnostic','Malformed history rows quarantined' in p.stderr and any(p.read_text()=='not json\n' for p in target.glob('history-rejected.*.jsonl')))
 seed('2026-11-06',{2:'blocked',4:'fail',6:'blocked',7:'blocked'});run('2026-11-06');ok('blocked is not resolved','SOC-002' not in doc('2026-11-06')['delta']['resolved'])
 bad=doc('2026-11-06');bad['findings'][0]['remediation']='';(target/'2026-11-06/findings.json').write_text(json.dumps(bad));before=(target/'2026-11-06/findings.json').read_bytes();run('2026-11-06',expect=1)
 ok('shared findings validator blocks malformed emission without replacing input',(target/'2026-11-06/findings.json').read_bytes()==before)
 seed('2026-11-07',{4:'fail'});current=doc('2026-11-07');current['findings'][0]['affected']=['policy-new'];(target/'2026-11-07/findings.json').write_text(json.dumps(current))
 # The malformed previous candidate is intentionally repaired for this independent test.
 seed('2026-11-06',{2:'blocked',4:'fail',6:'blocked',7:'blocked'});run('2026-11-06');run('2026-11-07')
 ok('stable-ID delta records concrete affected-resource changes',doc('2026-11-07')['delta']['affected_changes']==[{'id':'SOC-004','added':['policy-new'],'removed':['policy-a']}])
 seed('2026-11-08',{n:'blocked' for n in range(1,8)});run('2026-11-08');d=doc('2026-11-08')
 ok('fully blocked run stays unassessed and never resolves missing findings',d['score']['overall'] is None and d['score']['state']=='unassessed' and d['delta']['resolved']==[])
 f=target/'2026-11-08/findings.json';wrong=doc('2026-11-08');wrong['target']='splunk_oncall/other';f.write_text(json.dumps(wrong));before=f.read_bytes();run('2026-11-08',expect=1)
 ok('mismatched current artifact target fails before replacement',f.read_bytes()==before)
 seed('2026-11-08',{n:'blocked' for n in range(1,8)});run('2026-11-08')
 seed('2026-11-09',{4:'fail'});aliased=doc('2026-11-09');aliased['findings'][0]['affected']=['route-1']
 current_file=target/'2026-11-09/findings.json';current_file.write_text(json.dumps(aliased));before=current_file.read_bytes();p=run('2026-11-09',expect=1)
 ok('current run-local route aliases are rejected before publishing',current_file.read_bytes()==before and 'Run-local route aliases' in p.stderr)
 seed('2026-11-09',{4:'fail'});old=doc('2026-11-08');old['findings'][3]['affected']=['policy-a','route-1']
 old_file=target/'2026-11-08/findings.json';old_file.write_text(json.dumps(old));before=old_file.read_bytes();run('2026-11-09')
 ok('historical aliases do not become resource changes or rewrite history',doc('2026-11-09')['delta']['affected_changes']==[] and old_file.read_bytes()==before)
 seed('2026-11-10',{4:'fail',5:'fail',6:'fail',7:'fail'});run('2026-11-10')
 seed('2026-11-11',{n:'blocked' for n in range(3,8)},scope='triage');run('2026-11-11');d=doc('2026-11-11')
 ok('triage and full scores are incomparable despite identical check sets',d['score']['check_set']==doc('2026-11-10')['score']['check_set'] and not d['delta']['score_comparable'] and d['delta']['score_change'] is None and d['delta']['resolved']==[])
 report('2026-11-11');run('2026-11-11','history');rows=[json.loads(x) for x in history.read_text().splitlines()]
 ok('history retains scope for downstream compatible-score filtering',next(r for r in rows if r['run_date']=='2026-11-11')['scope']=='triage')
 seed('2026-11-12',{n:'blocked' for n in range(3,8)},scope='triage');run('2026-11-12')
 ok('same-scope triage remains comparable',doc('2026-11-12')['delta']['score_comparable'] and doc('2026-11-12')['delta']['score_change']==0)
 seed('2026-11-13',{4:'fail'},scope='account');run('2026-11-13');seed('2026-11-14',{4:'fail'});run('2026-11-14')
 ok('legacy missing scope and explicit full-account scope remain comparable',doc('2026-11-14')['delta']['score_comparable'])
 seed('2026-11-15',{4:'fail'});bound=doc('2026-11-15');bound['findings'][0]['affected']=['policy-a','checkout'];bound['findings'][0]['correlation_affected']=['unobserved-service']
 bound_file=target/'2026-11-15/findings.json';bound_file.write_text(json.dumps(bound));before=bound_file.read_bytes();run('2026-11-15',expect=1)
 ok('correlation service binding must be a subset of affected',bound_file.read_bytes()==before)
 bound['findings'][0]['correlation_affected']=['checkout'];bound_file.write_text(json.dumps(bound));run('2026-11-15')
 ok('declared service binding is preserved after lifecycle validation',doc('2026-11-15')['findings'][0]['correlation_affected']==['checkout'])
 print(f'On-Call lifecycle: {passed} passed, 0 failed')
PY
