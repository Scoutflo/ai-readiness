#!/bin/sh
# Private synthetic credentials only; never run provider binaries or real stores.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
export AF_AUTH_TEST_ROOT="$ROOT"
python3 - <<'PY'
import datetime, json, os, pathlib, shutil, subprocess, tempfile, time
root=pathlib.Path(os.environ['AF_AUTH_TEST_ROOT'])
work=pathlib.Path(tempfile.mkdtemp(prefix='af-auth-'))
passed=failed=0
try:
    plugin=work/'plugin'
    (plugin/'skills/alert-fatigue/lib').mkdir(parents=True)
    (plugin/'skills/doctor/scripts').mkdir(parents=True)
    (plugin/'report-standard').mkdir()
    shutil.copyfile(os.environ.get('AF_WORKFLOW_LIB',root/'skills/alert-fatigue/lib/collection-workflow.sh'),plugin/'skills/alert-fatigue/lib/collection-workflow.sh')
    for name in ['toolkit-targets.sh','check-fatigue-signals.sh']:
        shutil.copyfile(root/'report-standard'/name,plugin/'report-standard'/name)
    (plugin/'skills/doctor/scripts/doctor.sh').write_text('''#!/bin/sh
set -eu
provider=$(sed -n '1s/:$//p' "$2")
printf 'doctor\\n' >> "$AF_TEST_CALLS"
printf '{"integration":"%s","configured":"yes","check":"fixture","result":"pass"}\\n' "$provider"
''')
    bins=work/'bin'; bins.mkdir()
    for command in ['curl','aws','gcloud','kubectl','az','doctl','wget','ssh','helm','gh','claude']:
        p=bins/command; p.write_text('#!/bin/sh\necho "provider denied in auth fixture" >&2\nexit 97\n'); p.chmod(0o755)
    env=os.environ.copy()
    env.update(CLAUDE_PLUGIN_ROOT=str(plugin),PATH=str(bins)+':'+env['PATH'],HOME=str(work/'home'))
    now=int(time.time()); date=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    def case(name,provider,metadata,secrets,seq=False):
        d=work/name; d.mkdir()
        config=d/'config.yaml'
        body=''.join('  '+k+': '+json.dumps(v)+'\n' for k,v in metadata.items())
        config.write_text(provider+':\n'+(('  - label: primary\n'+''.join('  '+line+'\n' for line in body.splitlines())) if seq else body))
        plan={'schema':'scoutflo-fatigue-collection/v1','run_id':name,'run_date':date,'provider':provider,'target_label':'primary' if seq else provider,'identity':{'expected':'known-scope','path':['identity']},'window':{'start':now-600,'end':now,'description':'10m'},'limits':{'batch_size':1,'max_pages':1,'page_size':10},'objects':[{'job_id':'first','object_id':'RuleOne','object_kind':'alert'}]}
        (d/'plan.json').write_text(json.dumps(plan)); (d/'identity.json').write_text('{"identity":"known-scope"}')
        target=provider+'/primary' if seq else provider
        (d/'result.json').write_text(json.dumps({'signal':{'provider':provider,'target':target,'object_id':'RuleOne','object_kind':'alert','source_finding_ids':[],'distinct_active_since_values':1},'proof':{'window':plan['window'],'response_assertions_passed':True,'method':'synthetic sample','complete_window':False,'count_semantics':'sampled-state-values'}}))
        e=env|dict(SCOUTFLO_CONFIG=str(config),SCOUTFLO_ENV_FILE=str(d/'env'),SCOUTFLO_AUDIT_DIR=str(d/'audits'),AF_COLLECTION_PLAN=str(d/'plan.json'),AF_TEST_CALLS=str(d/'calls'),TEST_IDENTITY=str(d/'identity.json'),TEST_RESULT=str(d/'result.json'))
        # Every value is a test-only constant, never copied from the host.
        write_secrets(d,secrets)
        return d,e
    def write_secrets(d,secrets):
        (d/'env').write_text(''.join("export "+k+"='"+v+"'\n" for k,v in secrets.items()))
    def run(e,action):
        return subprocess.run(['/bin/sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/collection-workflow.sh"; afc_open "$AF_COLLECTION_PLAN"; '+action],env=e,text=True,capture_output=True)
    def check(label,condition,detail=''):
        global passed,failed
        if condition: passed+=1; print('ok '+label)
        else: failed+=1; print('FAIL '+label+' '+detail)
    defaults=[('grafana','token_env','GRAFANA_TOKEN',{'url':'https://example.test'}),('pagerduty','token_env','PAGERDUTY_TOKEN',{'region':'us'}),('zenduty','token_env','ZENDUTY_TOKEN',{'tier':'read-only'}),('elk','token_env','KIBANA_API_KEY',{'kibana_url':'https://example.test'}),('sentry','token_env','SENTRY_TOKEN',{'host':'https://example.test','org':'example'}),('groundcover','token_env','GROUNDCOVER_API_KEY',{'api_url':'https://example.test'}),('signoz','api_key_env','SIGNOZ_API_KEY',{'url':'https://example.test'}),('newrelic','api_key_env','NEW_RELIC_USER_API_KEY',{'account_id':'1234'})]
    for provider,key,default,metadata in defaults:
        d,e=case('default-'+provider,provider,metadata,{default:'fixture-default-secret'})
        r=run(e,'afc_load_auth')
        check(provider+' owning single-map credential default works',r.returncode==0,r.stderr)
        projected=d/'audits/alert-fatigue/runs'/('default-'+provider)/'config.yaml'
        check(provider+' resolved default name enters immutable projection',projected.exists() and default in projected.read_text())
    d,e=case('custom-missing','grafana',{'url':'https://example.test','token_env':'AF_MISSING_CUSTOM'},{'GRAFANA_TOKEN':'fixture-default-secret'})
    r=run(e,'afc_load_auth'); check('explicit missing custom name never falls back',r.returncode!=0)
    d,e=case('list-missing','grafana',{'url':'https://example.test'},{'GRAFANA_TOKEN':'fixture-default-secret'},seq=True)
    r=run(e,'afc_load_auth'); check('labeled target cannot borrow single-map default',r.returncode!=0)
    d,e=case('default-datadog','datadog',{'site':'datadoghq.com'},{'DATADOG_API_KEY':'fixture-dd-api','DATADOG_APP_KEY':'fixture-dd-app'})
    check('Datadog owning paired single-map defaults work',run(e,'afc_load_auth').returncode==0)
    vectors=[('bearer','prometheus',{'url':'https://example.test','token_env':'AF_TEST_TOKEN'},{'AF_TEST_TOKEN':'fixture-token'},'AF_TEST_TOKEN'),('basic-user','prometheus',{'url':'https://example.test','basic_user_env':'AF_TEST_USER','basic_pass_env':'AF_TEST_PASS'},{'AF_TEST_USER':'fixture-user','AF_TEST_PASS':'fixture-pass'},'AF_TEST_USER'),('basic-pass','prometheus',{'url':'https://example.test','basic_user_env':'AF_TEST_USER','basic_pass_env':'AF_TEST_PASS'},{'AF_TEST_USER':'fixture-user','AF_TEST_PASS':'fixture-pass'},'AF_TEST_PASS'),('api-key','datadog',{'site':'datadoghq.com','api_key_env':'AF_TEST_API','app_key_env':'AF_TEST_APP'},{'AF_TEST_API':'fixture-api','AF_TEST_APP':'fixture-app'},'AF_TEST_API'),('app-key','datadog',{'site':'datadoghq.com','api_key_env':'AF_TEST_API','app_key_env':'AF_TEST_APP'},{'AF_TEST_API':'fixture-api','AF_TEST_APP':'fixture-app'},'AF_TEST_APP'),('oncall-id','splunk_oncall',{'api_id_env':'AF_TEST_ID','api_key_env':'AF_TEST_KEY'},{'AF_TEST_ID':'fixture-id','AF_TEST_KEY':'fixture-key'},'AF_TEST_ID'),('oncall-key','splunk_oncall',{'api_id_env':'AF_TEST_ID','api_key_env':'AF_TEST_KEY'},{'AF_TEST_ID':'fixture-id','AF_TEST_KEY':'fixture-key'},'AF_TEST_KEY')]
    for component in ['prometheus','alertmanager','vmalert']:
        vectors.append(('lgtm-'+component,'lgtm',{'runtime_mode':'direct',component+'_url':'https://example.test',component+'_token_env':'AF_TEST_LGTM'},{'AF_TEST_LGTM':'fixture-lgtm'},'AF_TEST_LGTM'))
    for name,provider,metadata,secrets,changed in vectors:
        d,e=case(name,provider,metadata,secrets)
        a=run(e,'afc_load_auth'); same=run(e,'afc_load_auth')
        binding=d/'audits/alert-fatigue/runs'/name/'.auth-binding/binding.json'
        old=binding.read_bytes() if binding.exists() else None
        write_secrets(d,secrets|{changed:secrets[changed]+'-changed'})
        b=run(e,'afc_load_auth')
        check(name+' unchanged resumes and changed credential is refused',a.returncode==0 and same.returncode==0 and b.returncode!=0,b.stderr)
        check(name+' cannot replace immutable generation',old is not None and binding.read_bytes()==old)
    # Every boundary rechecks the live named store, even when the identity labels match.
    d,e=case('bound-job','prometheus',{'url':'https://example.test','token_env':'AF_TEST_TOKEN'},{'AF_TEST_TOKEN':'fixture-tenant-a'})
    initial=run(e,'afc_preflight; afc_verify_identity "$TEST_IDENTITY"; afc_complete first "$TEST_RESULT"; afc_assemble')
    check('same credential completes and assembles',initial.returncode==0,initial.stderr)
    rundir=d/'audits/alert-fatigue/runs/bound-job'
    calls=(d/'calls').read_bytes()
    check('completed reuse returns 3 without fresh provider calls',run(e,'afc_claim first').returncode==3 and (d/'calls').read_bytes()==calls)
    for action in ['afc_load_auth','afc_gate','afc_receipt_ok first','afc_assemble']:
        write_secrets(d,{'AF_TEST_TOKEN':'fixture-tenant-b'})
        r=run(e,action)
        check(action+' refuses changed generation',r.returncode!=0)
    check('rejected generation makes no new provider call',(d/'calls').read_bytes()==calls)
    write_secrets(d,{'AF_TEST_TOKEN':'fixture-tenant-a'})
    auth=rundir/'.auth-binding'; saved=d/'binding-saved'
    if auth.exists(): shutil.move(auth,saved)
    r=run(e,'afc_load_auth')
    check('old job evidence missing binding fails closed',r.returncode!=0 and not auth.exists())
    if saved.exists(): shutil.move(saved,auth)
    receipt=rundir/'jobs/first/complete.json'
    if receipt.exists():
        original=receipt.read_bytes(); record=json.loads(original); record.pop('auth_generation',None); receipt.write_text(json.dumps(record))
        r=run(e,'afc_receipt_ok first'); check('legacy receipt without generation cannot be reused',r.returncode!=0); receipt.write_bytes(original)
    else: check('legacy receipt without generation cannot be reused',False)
    check('unchanged credential can assemble preserved completed evidence',run(e,'afc_assemble').returncode==0)
    # An existing initializer is exclusive and cannot be silently broken.
    d2,e2=case('locked-init','prometheus',{'url':'https://example.test','token_env':'AF_TEST_TOKEN'},{'AF_TEST_TOKEN':'fixture-tenant-a'})
    run(e2,':'); r2=d2/'audits/alert-fatigue/runs/locked-init'; (r2/'.auth-init-lock').mkdir()
    check('parallel credential initializer is refused',run(e2,'afc_load_auth').returncode!=0 and not (r2/'.auth-binding').exists())
    check('salt and binding are private',auth.exists() and auth.stat().st_mode&0o077==0 and all(p.stat().st_mode&0o077==0 for p in auth.iterdir()))
    leaks=[]
    for p in work.glob('*/audits/**/*'):
        if p.is_file() and any(value in p.read_bytes() for value in [b'fixture-tenant-a',b'fixture-tenant-b',b'fixture-pass',b'fixture-api',b'fixture-app',b'fixture-default-secret']): leaks.append(str(p.relative_to(work)))
    check('no credential value persists in run evidence',not leaks,str(leaks))
    docs=(root/'skills/alert-fatigue/SKILL.md').read_text()+(root/'skills/alert-fatigue/references/collection-workflow.md').read_text()
    check('DigitalOcean config lane remains outside measured-history harness','outside the history harness' in docs and 'DO-017/026/073' in docs and 'verify-pending' in docs)
finally:
    shutil.rmtree(work)
print(f'collection-auth: {passed} passed, {failed} failed (zero real provider calls)')
raise SystemExit(bool(failed))
PY
