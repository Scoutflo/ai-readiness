#!/bin/sh
# Execute every SKILL Bash block in fresh isolated shells; no provider calls.
set -eu
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
python3 -u - "$ROOT" <<'PY'
import base64, copy, datetime, json, os, pathlib, re, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]); skill = root/'skills/audit-alertmanager/SKILL.md'
source = pathlib.Path(os.environ.get('ALR_TEST_SKILL', skill)).read_text()
blocks = re.findall(r'^```bash\n(.*?)^```', source, re.M|re.S)
assert len(blocks) == 6, 'inventory every SKILL Bash block when adding/removing one'
passed = 0
def check(label, yes):
    global passed
    assert yes, label
    passed += 1; print('PASS:', label)
with tempfile.TemporaryDirectory() as tmp:
    work = pathlib.Path(tmp); home = work/'home'; home.mkdir(); bin = work/'bin'; bin.mkdir()
    cfg = work/'toolkit.yaml'; envfile = work/'env'; envfile.write_text('CUSTOM_PROM_TOKEN=fixture-token\n')
    cfg.write_text('prometheus:\n  url: https://prometheus.example.com\n  alertmanager_url: https://alertmanager.example.com\n  token_env: CUSTOM_PROM_TOKEN\n')
    mock = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]; mode=os.environ.get('MOCK_MODE','valid')
assert os.environ.get('KUBECONFIG') != 'store-only-kube', 'unrelated store variable imported'
if '--version' in args: print('curl 8.10.0 fixture');sys.exit()
if '-d' in args:
    Path(os.environ['MOCK_SLACK']).write_text(sys.stdin.read());sys.exit()
assert '-q' in args and '--max-redirs' in args and '--max-filesize' in args
assert args[args.index('-H')+1] == os.environ.get('MOCK_EXPECT_AUTH','Authorization: Bearer fixture-token'), 'wrong credential binding'
url=args[-1]; assert url.startswith(('https://prometheus.example.com/','https://alertmanager.example.com/')), 'wrong target'
Path(os.environ['MOCK_CALLS']).open('a').write(url+'\\n')
if mode=='transport':sys.exit(28)
code='403' if mode=='forbidden' else '200'
ct='text/html' if mode=='html' else 'application/json'
if url.endswith('/api/v1/rules'):
    n=int(os.environ.get('MOCK_RULES','10'))
    data={'status':'success','data':{'groups':[{'name':'group','file':'rules.yaml','rules':[{'name':'Alert'+str(i),'type':'alerting'} for i in range(n)]+[{'name':'RecordedMetric','type':'recording'}]}]}}
    if mode=='malformed-rules':data={'status':'success','data':{}}
    if mode=='partial':data['warnings']=['partial response']
    if mode=='unknown-rule':data['data']['groups'][0]['rules'][0]['type']='unknown'
else:
    assert url.endswith('/api/v2/receivers')
    data=[{'name':'receiver'+str(i)} for i in range(int(os.environ.get('MOCK_RECEIVERS','2')))]
    if mode=='malformed-receivers':data={}
if mode=='invalid-json': print('{broken')
else: print(json.dumps(data))
print(code+' '+ct,end='')
'''
    (bin/'curl').write_text(mock); (bin/'curl').chmod(0o755)
    (bin/'kubectl').write_text('''#!/usr/bin/env python3
import json,os,sys
args=sys.argv[1:];assert args[:2]==['--context','fixture-context'],'ambient context used'
mode=os.environ.get('MOCK_KUBE','valid')
if mode=='denied':sys.exit(1)
if args[2:4]==['config','view']:
 print(json.dumps({'contexts':[{'name':'wrong' if mode=='context-mismatch' else 'fixture-context','context':{'cluster':'fixture-cluster','user':'fixture-user'}}], 'clusters':[{'name':'fixture-cluster'}], 'users':[{'name':'wrong' if mode=='user-mismatch' else 'fixture-user'}]}))
else:
 assert args[2:5]==['get','namespace','monitoring']
 print(json.dumps({'metadata':{'name':'wrong' if mode=='namespace-mismatch' else 'monitoring'}}))
'''); (bin/'kubectl').chmod(0o755)
    env = dict(os.environ, HOME=str(home), PATH=str(bin)+':'+os.environ['PATH'], CLAUDE_PLUGIN_ROOT=str(root), SCOUTFLO_CONFIG=str(cfg), SCOUTFLO_ENV_FILE=str(envfile), SCOUTFLO_AUDIT_DIR=str(work/'audits'), MOCK_CALLS=str(work/'calls'), MOCK_SLACK=str(work/'slack'), PROM_TOKEN='ambient-wrong', TOTAL='999999')
    for key in ['SCOUTFLO_SLACK_WEBHOOK','SMALL_MAX_OBJECTS','MEDIUM_MAX_OBJECTS','ALR_BATCH_SIZE','MOCK_RULES','MOCK_RECEIVERS','MOCK_MODE','MOCK_KUBE','MOCK_EXPECT_AUTH','PROM_BASIC_USER','PROM_BASIC_PASS']:
        env.pop(key,None)
    def run(n, extra=None, input=''):
        e=dict(env);e.update(extra or {})
        return subprocess.run(['/bin/sh','-c',blocks[n]],cwd=work,env=e,input=input,capture_output=True,text=True,timeout=90)
    def ok(n,label,extra=None,input=''):
        r=run(n,extra,input);check(label,r.returncode==0);return r
    ok(0,'doctor block runs with isolated config and secret store')
    ok(1,'live gate accepts configured HTTP target without inventing Kubernetes scope')
    initial=cfg.read_text();cfg.write_text(initial+'kubernetes:\n  context: fixture-context\n  monitoring_namespace: monitoring\n')
    ok(1,'live gate uses configured context and asserts live namespace')
    for mode in ['context-mismatch','user-mismatch','namespace-mismatch','denied']:
        check('live gate rejects '+mode,run(1,{'MOCK_KUBE':mode}).returncode != 0)
    cfg.write_text(initial)
    r=ok(2,'sizing block runs in fresh shell and ignores inherited TOTAL')
    check('recording rules excluded; small selected','alert_rules=10 receivers=2 total=12 path=small' in r.stdout)
    for alias in ['omitted','null']:
        cfg.write_text(initial.replace('  token_env: CUSTOM_PROM_TOKEN\n','' if alias=='omitted' else '  token_env: null\n  basic_user_env: null\n  basic_pass_env: null\n'))
        ok(2,'legacy shell bearer retained with '+alias+' alias',{'PROM_TOKEN':'fixture-token'})
        basic='Authorization: Basic '+base64.b64encode(b'fixture-user:fixture-password').decode()
        ok(2,'legacy shell basic retained with '+alias+' aliases',{'PROM_TOKEN':'fixture-token','PROM_BASIC_USER':'fixture-user','PROM_BASIC_PASS':'fixture-password','MOCK_EXPECT_AUTH':basic})
    cfg.write_text(initial)
    old_store=envfile.read_text();envfile.write_text('')
    before=(work/'calls').read_text()
    check('missing custom bearer refuses before calls despite valid legacy token',run(2,{'PROM_TOKEN':'fixture-token'}).returncode!=0 and (work/'calls').read_text()==before)
    cfg.write_text(initial.replace('  token_env: CUSTOM_PROM_TOKEN\n','  basic_user_env: CUSTOM_MISSING_USER\n'))
    check('missing custom basic refuses before calls despite valid legacy pair',run(2,{'PROM_BASIC_USER':'fixture-user','PROM_BASIC_PASS':'fixture-password','MOCK_EXPECT_AUTH':basic}).returncode!=0 and (work/'calls').read_text()==before)
    cfg.write_text(initial);envfile.write_text(old_store)
    original_store=envfile.read_text(); wrong_dir=work/'store-redirected-audits'
    envfile.write_text(original_store+'SCOUTFLO_AUDIT_DIR="'+str(wrong_dir)+'"\nKUBECONFIG=store-only-kube\n')
    (work/'audits/alertmanager/estate-sizing.json').unlink()
    ok(2,'only configured credential is imported from conflicting store')
    check('whole-store AUDIT_DIR and KUBECONFIG cannot redirect sizing',(work/'audits/alertmanager/estate-sizing.json').exists() and not wrong_dir.exists())
    envfile.write_text(original_store)
    r=ok(2,'successful empty arrays remain real zero',{'MOCK_RULES':'0','MOCK_RECEIVERS':'0'})
    check('empty result is not an unavailable count','total=0 path=small' in r.stdout)
    for mode in ['forbidden','transport','html','invalid-json','malformed-rules','malformed-receivers','partial','unknown-rule']:
        r=run(2,{'MOCK_MODE':mode})
        check('sizing rejects '+mode+' without zero fallback',r.returncode != 0 and 'counts unavailable, never zero' in r.stderr and 'total=' not in r.stdout)
        if mode=='forbidden': check('forbidden retains safe HTTP status','HTTP status: 403' in r.stderr)
        if mode=='transport': check('transport retains safe curl exit','curl exit 28' in r.stderr)
        if mode=='html': check('HTML retains safe response category','unsupported content type' in r.stderr)
    r=ok(2,'medium path has named tunable boundary',{'MOCK_RULES':'21'})
    check('medium path printed','path=medium' in r.stdout)
    r=run(2,{'MOCK_RULES':'81'},'yes\ncheckout\n')
    check('large below shared helper threshold confirms then refuses unsupported exclusions',r.returncode==2 and 'Scope blocked: exclusions recorded' in r.stdout)
    receipt=json.loads((work/'audits/alertmanager/estate-sizing.json').read_text())
    check('large checkpoint confirms and records exclusion','Proceed?' in r.stdout and receipt['excluded_services']==['checkout'] and receipt['objects']==83)
    captured=datetime.datetime.fromisoformat(receipt['observed_at'].replace('Z','+00:00'))
    check('scope receipt records fresh timezone-aware observation',captured.tzinfo is not None and 0 <= (datetime.datetime.now(datetime.timezone.utc)-captured).total_seconds() < 60)
    expected_binding=__import__('hashlib').sha256(json.dumps(['https://prometheus.example.com','https://alertmanager.example.com']).encode()).hexdigest()
    check('scope receipt matches reference endpoint binding',receipt['target_binding']==expected_binding and receipt['path']=='large')
    r=ok(2,'tuned medium threshold drives the same checkpoint',{'MOCK_RULES':'10','SMALL_MAX_OBJECTS':'3','MEDIUM_MAX_OBJECTS':'5','ALR_BATCH_SIZE':'2'},'yes\n\n')
    check('tuned threshold does not bypass pause','path=large' in r.stdout and 'Proceed?' in r.stdout)
    r=ok(2,'large shared helper path confirms',{'MOCK_RULES':'1000'},'yes\n\n')
    check('shared helper confirm present','Continue?' in r.stdout)
    for threshold in ['0','-1','x','01']:
        check('invalid threshold rejected '+threshold,run(2,{'SMALL_MAX_OBJECTS':threshold}).returncode!=0)
    old=envfile.read_text();envfile.write_text('')
    check('missing configured secret is not replaced by ambient token',run(2).returncode!=0);envfile.write_text(old)
    cfg.write_text('prometheus:\n  - url: https://prometheus.example.com\n    alertmanager_url: https://alertmanager.example.com\n')
    check('ambiguous target list rejected before reads',run(2).returncode!=0)
    cfg.write_text(initial.replace('https://prometheus.example.com','https://prometheus.example.com?token=secret'))
    check('credential-bearing URL rejected',run(2).returncode!=0)
    cfg.write_text(initial)
    # Authored output fixture: complete active ledger, every check blocked.
    # This validates emission/consumer mechanics, not provider judgments.
    today=datetime.datetime.now(datetime.timezone.utc).date().isoformat(); out=work/'audits/alertmanager'/today;out.mkdir()
    cats=[];checks=[]
    for name,weight,ids in re.findall(r'^\| ([^|]+?) \| (\d+) \| ((?:ALR-\d+,? ?)+) \|',source,re.M):
        rows=[{'id':i,'category':name,'result':'blocked','reason':'Fixture read denied'} for i in re.findall(r'ALR-\d+',ids)]
        checks+=rows;cats.append(dict(name=name,weight=int(weight),score=0,maturity='unassessed',checks_passed=0,checks_partial=0,checks_failed=0,checks_blocked=len(rows),checks_suppressed=0,checks_not_in_scope=0,checks_total=0))
    assert len(cats)==6 and len(checks)==21
    findings=[dict(id=c['id'],title='Evidence unavailable for '+c['id'],severity='info',area=c['category'],status='blocked',lifecycle='new',scoring_scope='readiness',report_lanes=['general-audit'],points_recoverable=0,affected=['fixture-service'],evidence=[{'command':'fixture-read '+c['id'],'observed':'HTTP 403 fixture '+c['id']}],recommendation='Restore the configured read scope',remediation='/scoutflo:connect',impact='This check cannot establish readiness') for c in checks]
    f=dict(schema='scoutflo-findings/v2',toolkit_version=json.loads((root/'.claude-plugin/plugin.json').read_text())['version'],skill='audit-alertmanager',target='alertmanager',run_date=today,generated_at=today+'T12:00:00Z',checks=checks,findings=findings,estate={'objects':12,'path':'small'},severity_counts=dict(critical=0,high=0,medium=0,low=0,info=len(findings)),score=dict(overall=None,state='unassessed',gate=85,end_to_end=False,scoring_model='assessed-only-v1',check_set='',assessment=dict(applicable_checks=21,assessed_checks=0,scored_checks=0,blocked_checks=21,suppressed_checks=0,not_in_scope_checks=0,coverage_percent=0),categories=cats,excluded=[dict(name=c['name'],weight=c['weight'],reason='Fixture read denied') for c in cats]))
    lines=sorted(['chk\t'+c['id']+'\t'+c['category'] for c in checks]+['cat\t'+c['name']+'\t'+str(c['weight']) for c in cats]+['gate\t85'])
    fingerprint=subprocess.run(['cksum'],input='\n'.join(lines)+'\n',capture_output=True,text=True,check=True).stdout.split();f['score']['check_set']='cksum-v2:'+':'.join(fingerprint[:2])
    (out/'findings.json').write_text(json.dumps(f))
    inv=dict(schema='scoutflo-inventory/v1',target='alertmanager',generated_at=f['generated_at'],scope='fixture-observed-receivers',counts={'total':1,'by_kind':{'receiver':1}},items=[{'name':'fixture-receiver','kind':'receiver'}]);(out/'inventory.json').write_text(json.dumps(inv))
    def render(mode,file):
        return subprocess.run(['/bin/sh',str(root/'report-standard/render-report-viz.sh'),mode,str(file)],capture_output=True,text=True,check=True).stdout
    index='| ID | Title | Priority |\n| --- | --- | --- |\n'+'\n'.join('| '+x['id']+' | '+x['title']+' | info |' for x in findings)
    cards='\n\n'.join('### '+x['title']+'\n\n**What\'s wrong:** Evidence unavailable.\n\n**Where:** fixture-service\n\n**Why it matters:** Readiness unassessed.\n\n**How to fix:** Restore configured read scope.\n\n**Done when:** Read succeeds and check is reassessed.\n\n<sub>ref: '+x['id']+' · '+x['area']+' · new, blocked</sub>' for x in findings)
    evidence='\n\n'.join('### '+x['id']+'\n\n`'+x['evidence'][0]['command']+'`\n\n'+x['evidence'][0]['observed'] for x in findings)
    report='# Alertmanager audit: fixture\n\n| | |\n| --- | --- |\n| Target | alertmanager |\n| Date | '+today+' (UTC) |\n| Toolkit version | '+f['toolkit_version']+' |\n| Skill | audit-alertmanager |\n\n'+render('at-a-glance',out/'findings.json')+'\n## Executive summary\n\n**Readiness: unassessed** 0/21 applicable checks assessed; no human receipt proved.\n\n## Scorecard\n\nAll six categories excluded: configured read denied.\n\n'+render('lanes',out/'findings.json')+'\n## Findings\n\n'+index+'\n\n'+cards+'\n\n'+render('inventory',out/'inventory.json')+'\n## Next safe actions\n\nRestore the configured read scope and rerun.\n\n## Evidence appendix\n\n'+evidence+'\n'
    (out/'report.md').write_text(report)
    r=run(3);check('output block validates full blocked ledger, inventory and report',r.returncode==0 or print(r.stdout,r.stderr))
    ok(3,'same-date output rerun replaces history row')
    check('history remains one derived row',len((out.parent/'history.jsonl').read_text().splitlines())==1)
    check('titles-only index has no command evidence','HTTP 403' not in index and 'fixture-read' not in index)
    check('each command output appears once in evidence appendix',all(report.count(x['evidence'][0]['observed'])==1 for x in findings))
    ok(4,'Slack block with no webhook makes no send');check('Slack opt-out retained',not (work/'slack').exists())
    ok(4,'Slack block sends only to local stand-in',{'SCOUTFLO_SLACK_WEBHOOK':'https://slack.example.com/fixture','SLACK_MAX_FINDINGS':'2'})
    slack=json.loads((work/'slack').read_text())['text']
    check('Slack blocked headline and tunable title cap','readiness unassessed' in slack and slack.count('Evidence unavailable for')==2 and 'fixture-read' not in slack and 'HTTP 403' not in slack)
    for mode in ['none','workspace','per-resource','per-resource+workspace','ssot-md']:
        sd=home/'.scoutflo';sd.mkdir(exist_ok=True)
        for name in ['business_context.json','computed_metadata.jsonl','business_context.md']:(sd/name).unlink(missing_ok=True)
        if 'workspace' in mode:(sd/'business_context.json').write_text(json.dumps({'environment':'testing','critical_dependencies':['fixture-service'],'service_slas':[],'environment_map':[]}))
        if 'per-resource' in mode:(sd/'computed_metadata.jsonl').write_text('{"resource":"fixture-service"}\n')
        if mode=='ssot-md':(sd/'business_context.md').write_text('## Environment\nStage: testing\n## Cost Sensitivity\nPrimary: medium\n## Critical Services\n`fixture-service`\n## Exclusions\n`excluded-service`\n')
        r=ok(5,'metadata block runs fresh in '+mode+' mode')
        check('metadata mode correct '+mode,'metadata mode: '+mode in r.stdout)
    if os.environ.get('ALR_TEST_OUTPUT_DIR'):
        dest=pathlib.Path(os.environ['ALR_TEST_OUTPUT_DIR']);dest.mkdir(parents=True,exist_ok=True)
        shutil.copytree(out,dest/'report-fixture',dirs_exist_ok=True)
        shutil.copy2(out.parent/'history.jsonl',dest/'history.jsonl')
        shutil.copy2(work/'slack',dest/'slack-fixture.json')
print('ALERTMANAGER-SCOPE-CONTRACT-OK:',passed,'assertions; all',len(blocks),'Bash blocks executed with isolated stand-ins')
PY
