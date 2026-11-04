#!/bin/sh
# Forced local hashing failures; no provider calls or real credential stores.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
export AF_HASH_TEST_ROOT="$ROOT"
python3 - <<'PY'
import datetime,hashlib,json,os,pathlib,shutil,subprocess,tempfile,time
root=pathlib.Path(os.environ['AF_HASH_TEST_ROOT']); work=pathlib.Path(tempfile.mkdtemp(prefix='af-hash-'))
passed=failed=0
try:
    lib=pathlib.Path(os.environ.get('AF_WORKFLOW_LIB',root/'skills/alert-fatigue/lib/collection-workflow.sh'))
    plugin=work/'plugin'; (plugin/'report-standard').mkdir(parents=True)
    for name in ['toolkit-targets.sh','check-fatigue-signals.sh']:
        shutil.copyfile(root/'report-standard'/name,plugin/'report-standard'/name)
    bins=work/'bin'; bins.mkdir(); real=shutil.which('shasum')
    sha=bins/'shasum'
    sha.write_text('''#!/usr/bin/env python3
import os,sys,subprocess
b=sys.stdin.buffer.read(); mode=os.environ.get('AF_HASH_MODE','ok')
if mode=='fail': sys.exit(73)
if mode=='valid-but-failed': print('0'*64+'  -'); sys.exit(73)
if mode=='empty': sys.exit(0)
if mode=='short': print('ab  -'); sys.exit(0)
if mode=='nonhex': print('z'*64+'  -'); sys.exit(0)
if mode=='extra': print('0'*64+'  -\\nunexpected'); sys.exit(0)
if mode=='result-fail' and b'"signal"' in b: sys.exit(73)
r=subprocess.run([os.environ['AF_REAL_SHASUM'],'-a','256'],input=b,capture_output=True)
sys.stdout.buffer.write(r.stdout); sys.stderr.buffer.write(r.stderr); sys.exit(r.returncode)
'''); sha.chmod(0o755)
    for cmd in ['curl','aws','gcloud','kubectl','az','doctl','wget','ssh','helm','gh','claude']:
        p=bins/cmd; p.write_text('#!/bin/sh\nexit 97\n'); p.chmod(0o755)
    base=os.environ.copy(); base.update(PATH=str(bins)+':'+base['PATH'],AF_REAL_SHASUM=real,AF_HASH_LIB=str(lib),CLAUDE_PLUGIN_ROOT=str(plugin),HOME=str(work/'home'))
    now=int(time.time()); date=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')
    def fixture(name):
        d=work/name; d.mkdir(); run=d/'run'; (run/'jobs').mkdir(parents=True)
        plan={'schema':'scoutflo-fatigue-collection/v1','run_id':name,'run_date':date,'provider':'prometheus','target_label':'prometheus','identity':{'expected':'known','path':['identity']},'window':{'start':now-600,'end':now,'description':'10m'},'limits':{'batch_size':1,'max_pages':1,'page_size':10},'objects':[{'job_id':'one','object_id':'RuleOne','object_kind':'alert'}]}
        (d/'plan.json').write_text(json.dumps(plan)); (d/'config.yaml').write_text('prometheus:\n  url: https://example.test\n  token_env: AF_FIXTURE_TOKEN\n')
        (d/'input').write_text('known hash input\n')
        (d/'result.json').write_text(json.dumps({'signal':{'provider':'prometheus','target':'prometheus','object_id':'RuleOne','object_kind':'alert','distinct_active_since_values':1,'source_finding_ids':[]},'proof':{'window':plan['window'],'method':'fixture sample','response_assertions_passed':True,'complete_window':False,'count_semantics':'sampled-state-values'}}))
        e=base|dict(AFC_RUN=str(run),AFC_PLAN=str(d/'plan.json'),AFC_BASIS='fixture-basis',AFC_TARGET='prometheus',AFC_PROVIDER='prometheus',AFC_ROOT=str(plugin),AFC_AUDITS=str(d/'audits'),AF_FIXTURE_TOKEN='synthetic-credential-a',SCOUTFLO_ENV_FILE=str(d/'absent-store'),SCOUTFLO_CONFIG=str(d/'config.yaml'),SCOUTFLO_AUDIT_DIR=str(d/'audits'),AF_COLLECTION_PLAN=str(d/'plan.json'),AF_HASH_INPUT=str(d/'input'),AF_RESULT=str(d/'result.json'))
        return d,run,e
    def run(e,action,mode='ok'):
        script='. "$AF_HASH_LIB"; afc_get() { case "$1" in token_env) printf "%s\\n" AF_FIXTURE_TOKEN;; esac; }; '+action
        return subprocess.run(['/bin/sh','-c',script],env=e|{'AF_HASH_MODE':mode},text=True,capture_output=True)
    def check(label,ok,detail=''):
        global passed,failed
        if ok: passed+=1; print('ok '+label,flush=True)
        else: failed+=1; print('FAIL '+label+' '+detail,flush=True)
    d,r,e=fixture('positive')
    out=run(e,'afc_hash "$AF_HASH_INPUT"')
    check('real hash succeeds with exact digest',out.returncode==0 and out.stdout.strip()==hashlib.sha256((d/'input').read_bytes()).hexdigest())
    for mode in ['fail','valid-but-failed','empty','short','nonhex','extra']:
        d,r,e=fixture('reject-'+mode)
        out=run(e,'afc_hash "$AF_HASH_INPUT"',mode)
        check(mode+' file hash returns nonzero and no digest',out.returncode!=0 and not out.stdout.strip())
        out=run(e,'afc_load_auth',mode)
        check(mode+' cannot initialize credential binding',out.returncode!=0 and not (r/'.auth-binding').exists(),out.stderr)
        check(mode+' failed initialization cleans only temporary state',not (r/'.auth-init-lock').exists() and not list(r.glob('.auth-init.*')) and not list(r.glob('.auth-hash.*')))
        if mode=='fail':
            changed=run(e|{'AF_FIXTURE_TOKEN':'synthetic-credential-b'},'afc_load_auth',mode)
            check('repeated hash failure cannot reuse empty binding across credentials',changed.returncode!=0 and not (r/'.auth-binding').exists())
    d,r,e=fixture('preserve')
    initial=run(e,'afc_load_auth'); binding=r/'.auth-binding/binding.json'
    snapshot=binding.read_bytes() if binding.exists() else None
    check('healthy binding is initialized',initial.returncode==0 and snapshot is not None)
    changed=e|{'AF_FIXTURE_TOKEN':'synthetic-credential-b'}
    out=run(changed,'afc_load_auth','fail')
    check('hash failure cannot accept changed credential',out.returncode!=0)
    check('existing binding is unchanged on hash failure',snapshot is not None and binding.read_bytes()==snapshot)
    out=run(e,'afc_load_auth')
    check('same credential resumes after transient hash failure',out.returncode==0)
    # Check the upstream status too: partial material must not become a digest.
    d,r,e=fixture('producer')
    out=run(e,'afc_auth_stream() { printf partial; return 73; }; afc_load_auth')
    check('failed credential producer cannot establish binding',out.returncode!=0 and not (r/'.auth-binding').exists())
    # Exercise the real afc_open callsite: an empty hash cannot become basis "/".
    d,r,e=fixture('basis')
    out=run(e,'afc_open "$AF_COLLECTION_PLAN"','fail')
    check('afc_open refuses a failed basis hash',out.returncode!=0)
    # Exercise receipt and staged result callsites after genuine auth hashing.
    d,r,e=fixture('receipts')
    prepare='afc_load_auth; jq -n --arg basis "$AFC_BASIS" --arg target "$AFC_TARGET" --arg gen "$AFC_AUTH_GENERATION" --argjson at "$(date -u +%s)" \'{basis:$basis,target:$target,auth_generation:$gen,checked_at:$at}\' > "$AFC_RUN/identity.json"; '
    out=run(e,prepare+'afc_complete one "$AF_RESULT"; afc_assemble')
    check('healthy result completes and assembles',out.returncode==0,out.stderr)
    receipt=r/'jobs/one/complete.json'; result=r/'jobs/one/result.json'
    original_receipt=receipt.read_bytes() if receipt.exists() else None
    original_result=result.read_bytes() if result.exists() else None
    out=run(e,'afc_receipt_ok one','result-fail')
    check('receipt reuse refuses failed result hash',out.returncode!=0)
    check('prior result and receipt survive failed validation',original_receipt is not None and receipt.read_bytes()==original_receipt and result.read_bytes()==original_result)
    d,r,e=fixture('staging'); run(e,'afc_load_auth'); (r/'jobs/one').mkdir(); prior=r/'jobs/one/result.json'; prior.write_text('prior uncommitted evidence\n')
    out=run(e,prepare+'afc_complete one "$AF_RESULT"','result-fail')
    check('result hash failure refuses completion',out.returncode!=0 and not (r/'jobs/one/complete.json').exists())
    check('failed staged hash preserves existing uncommitted evidence',prior.read_text()=='prior uncommitted evidence\n' and not list((r/'jobs/one').glob('.result.*')) and not (r/'jobs/one/.lock').exists())
    leaked=[]
    for path in work.glob('*/run/**/*'):
        if path.is_file() and any(v in path.read_bytes() for v in [b'synthetic-credential-a',b'synthetic-credential-b']): leaked.append(str(path.relative_to(work)))
    check('hash failures persist no raw credential bytes',not leaked,str(leaked))
finally:
    shutil.rmtree(work)
print(f'collection-hash: {passed} passed, {failed} failed (zero real provider calls)')
raise SystemExit(bool(failed))
PY
