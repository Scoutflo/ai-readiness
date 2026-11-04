#!/bin/sh
# Exercise the exact public guard/route commands; stand-ins do not prove native delivery.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy,hashlib,json,os,pathlib,re,shutil,subprocess,sys,tempfile
import yaml
root=pathlib.Path(sys.argv[1]); doc=root/'skills/setup-splunk-oncall/references/alertmanager-source.md'
s=doc.read_text(); match=re.search(r'<!-- oncall-alertmanager-validate:start -->\s*```bash\n(.*?)\n```\s*<!-- oncall-alertmanager-validate:end -->',s,re.S)
assert match,'Missing published validation block'
work=pathlib.Path(tempfile.mkdtemp(prefix='oncall-am-test-')); checks=0
try:
    private=work/'private'; private.mkdir(mode=0o700)
    config=private/'candidate.yml'; baseline=private/'original-configmap.json'; receipt=private/'native-validation.json'
    before={'global':{'resolve_timeout':'5m'},'route':{'receiver':'existing-receiver','group_wait':'20s'},'receivers':[{'name':'existing-receiver','webhook_configs':[{'url':'https://sink.example.com/alerts'}]}],'inhibit_rules':[{'source_matchers':['severity="critical"'],'target_matchers':['severity="warning"'],'equal':['service']}],'templates':['/etc/alertmanager/*.tmpl']}
    cm={'apiVersion':'v1','kind':'ConfigMap','metadata':{'name':'example-config','namespace':'example-alerting','uid':'config-uid'},'data':{'alertmanager.yml':yaml.safe_dump(before,sort_keys=False)}}
    matchers=['alertname="OnCallSourceProbe"','namespace="example-workload"','oncall_test="true"']
    candidate=copy.deepcopy(before)
    candidate['route']['routes']=[{'receiver':'oncall-validation','matchers':matchers,'continue':True,'group_by':['alertname','namespace','run_id']},{'receiver':'existing-receiver','matchers':matchers}]
    candidate['receivers'].append({'name':'oncall-validation','victorops_configs':[{'api_url':'https://alert.victorops.com/integrations/generic/20131114/alert/','api_key':'synthetic-api','routing_key':'synthetic-route','send_resolved':True,'message_type':'CRITICAL','monitoring_tool':'Alertmanager'}]})
    def fixtures(wanted=None,original=None,raw=None):
        config.write_text(raw if raw is not None else yaml.safe_dump(wanted or candidate,sort_keys=False));config.chmod(0o600)
        baseline.write_text(json.dumps(original or cm));baseline.chmod(0o600)
    fixtures()
    cfg=work/'toolkit.yaml';cfg.write_text('kubernetes:\n  context: selected-context\n')
    script=work/'validate.sh'; script.write_text(match.group(1)+'\n')
    bin=work/'bin'; bin.mkdir(); calls=work/'calls.jsonl'
    stub=bin/'kubectl'; stub.write_text('''#!/usr/bin/env python3
import hashlib,json,os,sys
args=sys.argv[1:]
assert args[:4]==['--context','selected-context','-n','example-alerting']
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps(args[4:])+'\\n')
if args[4:]==['config','view','--minify','-o','json']:
 x={'current-context':os.environ.get('ACTUAL_CONTEXT','selected-context'),'contexts':[{'name':os.environ.get('ACTUAL_CONTEXT','selected-context'),'context':{'cluster':'example-cluster','user':'example-operator'}}]}
 raw=json.dumps(x)
 if os.environ.get('READ_FAULT')=='multiple':raw+='\\n'+raw
 if os.environ.get('READ_FAULT')=='duplicate':raw='{"current-context":"wrong","current-context":"selected-context","contexts":'+json.dumps(x['contexts'])+'}'
 if os.environ.get('READ_FAULT')=='array':raw='[]'
 if os.environ.get('READ_FAULT')=='html':raw='<html>synthetic-api synthetic-route</html>'
 print(raw)
 sys.exit(9 if os.environ.get('READ_FAULT')=='nonzero-valid-json' else 0)
if args[4]=='get':
 raw=json.dumps({'kind':'List','items':[]})
 fault=os.environ.get('READ_FAULT')
 if fault=='multiple':raw+='\\n'+raw
 if fault=='duplicate':raw='{"kind":"List","items":[{}],"items":[]}'
 if fault=='array':raw='[]'
 if fault=='html':raw='<html>synthetic-api synthetic-route</html>'
 if fault=='missing-items':raw='{"kind":"List"}'
 if fault=='null-items':raw='{"kind":"List","items":null}'
 print(raw)
 sys.exit(9 if fault=='nonzero-valid-json' else 0)
assert args[4:10]==['exec','-i','example-alertmanager-0','-c','alertmanager','--']
assert args[10]=='/bin/amtool'
raw=sys.stdin.buffer.read()
assert hashlib.sha256(raw).hexdigest()==os.environ['EXPECTED_SHA']
assert not any(x in ' '.join(args) for x in ('synthetic-api','synthetic-route'))
rows=[json.loads(x) for x in open(os.environ['CALLS']) if json.loads(x)[0]=='exec']
if os.environ.get('FAIL_AT')==str(len(rows)):
 print('synthetic-api synthetic-route config error',file=sys.stderr)
 print('synthetic-api synthetic-route rejected payload')
 sys.exit(17)
'''); stub.chmod(0o755)
    base=dict(os.environ,PATH=str(bin)+os.pathsep+os.environ['PATH'],CALLS=str(calls),SCOUTFLO_CONFIG=str(cfg),CLAUDE_PLUGIN_ROOT=str(root),SOC_AM_CONTEXT='selected-context',SOC_AM_NAMESPACE='example-alerting',SOC_AM_POD='example-alertmanager-0',SOC_AM_CONTAINER='alertmanager',SOC_AM_CONFIG=str(config),SOC_AM_PRIVATE_DIR=str(private),SOC_AM_NEW_RECEIVER='oncall-validation',SOC_AM_OLD_RECEIVER='existing-receiver',SOC_AM_ALERT='OnCallSourceProbe',SOC_AM_SOURCE_NAMESPACE='example-workload',SOC_AM_OTHER_NAMESPACE='different-workload')
    def run(extra=None):
        global checks
        if calls.exists():calls.unlink()
        if receipt.exists():receipt.unlink()
        env=dict(base,EXPECTED_SHA=hashlib.sha256(config.read_bytes()).hexdigest());env.update(extra or {})
        r=subprocess.run(['sh',str(script)],env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        assert not any(x in r.stdout for x in ('synthetic-api','synthetic-route')),'Sensitive output escaped'
        checks+=1
        rows=[json.loads(x) for x in calls.read_text().splitlines()] if calls.exists() else []
        return r,rows
    r,rows=run();assert r.returncode==0,r.stdout
    native=[x[7:] for x in rows if x[0]=='exec']
    assert len(native)==5 and native[0]==['check-config','/dev/stdin'],native
    assert native[1]==['config','routes','test','--config.file=/dev/stdin','--verify.receivers=oncall-validation,existing-receiver','alertname=OnCallSourceProbe','namespace=example-workload','oncall_test=true','run_id=validation']
    assert all(x[:4]==['config','routes','test','--config.file=/dev/stdin'] and x[4]=='--verify.receivers=existing-receiver' for x in native[2:])
    assert 'namespace=different-workload' in native[2] and 'oncall_test=false' in native[3]
    assert not any(x.startswith('oncall_test=') for x in native[4])
    assert 'delivery remains unverified' in r.stdout
    # E3 red/green: receiver names alone cannot catch destination/inhibition drift.
    mutations={
      'changed-existing-destination':lambda x:x['receivers'][0]['webhook_configs'][0].update(url='https://wrong.example.com/alerts'),
      'dropped-inhibits':lambda x:x.pop('inhibit_rules'),
      'changed-root-timing':lambda x:x['route'].update(group_wait='1s'),
      'changed-templates':lambda x:x.update(templates=[]),
      'changed-global':lambda x:x['global'].update(resolve_timeout='1m'),
      'additional-receiver':lambda x:x['receivers'].append({'name':'unexpected'}),
      'broad-child':lambda x:x['route']['routes'][0].update(matchers=[]),
      'missing-preserved-sibling':lambda x:x['route']['routes'].pop(),
      'wrong-endpoint':lambda x:x['receivers'][-1]['victorops_configs'][0].update(api_url='https://wrong.example.com/alerts'),
    }
    for name,change in mutations.items():
        altered=copy.deepcopy(candidate);change(altered);fixtures(altered)
        r,rows=run();assert r.returncode!=0,name+' passed the public guard'
        assert not any(x[0]=='exec' for x in rows),name+' reached amtool before structural rejection'
        assert not receipt.exists(),name+' left a success receipt'
    fixtures()
    for n in range(1,6):
        r,rows=run({'FAIL_AT':str(n)});native=[x for x in rows if x[0]=='exec']
        assert r.returncode!=0 and len(native)==n and not receipt.exists()
        assert 'assertions passed' not in r.stdout
    for fault in ('nonzero-valid-json','multiple','duplicate','array','html'):
        r,rows=run({'READ_FAULT':fault});assert r.returncode!=0 and not any(x[0]=='exec' for x in rows),fault+' read passed'
    for extra in ({'SOC_AM_CONTEXT':'wrong-context'},{'ACTUAL_CONTEXT':'wrong-context'},{'SOC_AM_OTHER_NAMESPACE':'example-workload'},{'SOC_AM_NEW_RECEIVER':'existing-receiver'},{'SOC_AM_ALERT':'unsafe,label'}):
        r,rows=run(extra);assert r.returncode!=0 and not any(x[0]=='exec' for x in rows)
    cfg.write_text('kubernetes:\n  - label: primary\n    context: selected-context\n  - label: second\n    context: second-context\n')
    for extra in ({},{'SOC_AM_KUBERNETES_TARGET':'missing'},{'SOC_AM_KUBERNETES_TARGET':'second'}):
        r,rows=run(extra);assert r.returncode!=0 and rows==[],'Ambiguous/wrong list target passed'
    r,rows=run({'SOC_AM_KUBERNETES_TARGET':'primary'});assert r.returncode==0,r.stdout
    cfg.write_text('kubernetes:\n  context: selected-context\n')
    for malformed in (yaml.safe_dump(candidate,sort_keys=False)+'route: {}\n','a: &shared {}\nroute: *shared\n'):
        fixtures(raw=malformed);r,rows=run();assert r.returncode!=0 and not any(x[0]=='exec' for x in rows)
    bad=copy.deepcopy(cm);bad['data']['extra.tmpl']='template';fixtures(original=bad);r,rows=run();assert r.returncode!=0
    bad=copy.deepcopy(cm);raw=copy.deepcopy(before);raw['route']['routes']=[{'receiver':'existing-receiver'}];bad['data']['alertmanager.yml']=yaml.safe_dump(raw);fixtures(original=bad);r,rows=run();assert r.returncode!=0
    fixtures();baseline.write_text(baseline.read_text()+'\n{}');r,rows=run();assert r.returncode!=0
    fixtures();baseline.chmod(0o644);r,rows=run();assert r.returncode!=0;baseline.chmod(0o600)
    config.chmod(0o644);r,rows=run();assert r.returncode!=0;config.chmod(0o600)
    private.chmod(0o755);r,rows=run();assert r.returncode!=0;private.chmod(0o700)
    link=private/'link.yml';link.symlink_to(config);r,rows=run({'SOC_AM_CONFIG':str(link)});assert r.returncode!=0
    fixtures();r,rows=run();assert r.returncode==0,r.stdout
    result=json.loads(receipt.read_text());assert result['candidate_sha256']==hashlib.sha256(config.read_bytes()).hexdigest()
    assert result['baseline_sha256']==hashlib.sha256(baseline.read_bytes()).hexdigest()
    assert result['context']=='selected-context' and result['namespace']=='example-alerting'
    assert not any(x in receipt.read_text() for x in ('synthetic-api','synthetic-route'))
    assert receipt.stat().st_mode & 0o077==0
    # Exercise the identical strict read helper used by all five published blocks.
    blocks=re.findall(r'```bash\n(.*?)\n```',s,re.S)
    helpers=[re.search(r'(am_read_json\(\) \{.*?\n\})\nAM_VIEW=',b,re.S).group(1) for b in blocks]
    assert len(helpers)==5 and len(set(helpers))==1
    assert not re.search(r'kubectl[^\n]*\bget\b',s)
    assert all('|| exit 1' in line for line in s.splitlines() if '=$(am_read_json ' in line)
    publish=next(b for b in blocks if "<<'PY_FILES'" in b)
    absence=re.search(r'(AM_OBJECT=\$\(am_read_json get secrets[^\n]+\n[^\n]+jq -e[^\n]+)',publish).group(1)
    script.write_text('set -eu\nAM_CONTEXT=selected-context\nAM_NS=example-alerting\nAM_SECRET=example-secret\n'+helpers[0]+'\n'+absence+'\necho "Strict read accepted"\n')
    r,rows=run();assert r.returncode==0,r.stdout
    for fault in ('nonzero-valid-json','multiple','duplicate','array','html','missing-items','null-items'):
        r,rows=run({'READ_FAULT':fault});assert r.returncode!=0 and 'Strict read accepted' not in r.stdout,fault+' list read passed'
        assert len(rows)==1 and rows[0][0]=='get'
    # Execute the actual pre-write plan binder, including changed input/patch cases.
    script.write_text(match.group(1)+'\n');fixtures();r,rows=run();assert r.returncode==0,r.stdout
    before_sts={'kind':'StatefulSet','metadata':{'name':'example-alertmanager','namespace':'example-alerting','uid':'sts-uid','resourceVersion':'7'},'spec':{'replicas':1,'updateStrategy':{'type':'RollingUpdate'},'template':{'spec':{'securityContext':{'fsGroup':65534},'volumes':[{'name':'configuration','configMap':{'name':'example-config'}}]}}}}
    old=before_sts['spec']['template']['spec']['volumes'][0];path='/spec/template/spec/volumes/0'
    mount=[{'op':'test','path':'/metadata/uid','value':'sts-uid'},{'op':'test','path':'/metadata/resourceVersion','value':'7'},{'op':'test','path':path,'value':old},{'op':'replace','path':path,'value':{'name':'configuration','secret':{'secretName':'example-secret','defaultMode':288,'items':[{'key':'alertmanager.yml','path':'alertmanager.yml'}]}}}]
    binder=re.search(r"<<'PY_FILES'\n(.*?)\nPY_FILES",publish,re.S).group(1)
    def bind(secret='example-secret',name='example-alertmanager',patch=None,state=None):
        global checks
        f=private/'before.json';f.write_text(json.dumps(state or before_sts));f.chmod(0o600)
        f=private/'mount.patch.json';f.write_text(json.dumps(patch if patch is not None else mount));f.chmod(0o600)
        args=[str(private),hashlib.sha256(config.read_bytes()).hexdigest(),hashlib.sha256(f.read_bytes()).hexdigest(),'selected-context','example-alerting',secret,name]
        r=subprocess.run([sys.executable,'-',*args],input=binder,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        assert not any(x in r.stdout for x in ('synthetic-api','synthetic-route'))
        checks+=1;return r.returncode
    assert bind()==0
    assert bind(secret='other-secret')!=0 and bind(name='wrong-statefulset')!=0
    for change in (lambda p:p.pop(0),lambda p:p[0].update(value='wrong-uid'),lambda p:p[1].update(value='8'),lambda p:p[3]['value']['secret'].update(defaultMode=420),lambda p:p[3]['value']['secret']['items'][0].update(path='wrong.yml')):
        altered=copy.deepcopy(mount);change(altered);assert bind(patch=altered)!=0
    changed=copy.deepcopy(before_sts);changed['metadata']['namespace']='different-namespace';assert bind(state=changed)!=0
    assert bind()==0
    print('Alertmanager source:',checks,'checks passed; structural preservation, selected-context and exit-status controls; no network.')
finally:
    shutil.rmtree(work)
PY
