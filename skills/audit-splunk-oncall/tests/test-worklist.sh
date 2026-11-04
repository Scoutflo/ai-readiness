#!/bin/sh
# Execute the exact published worklist fence with an isolated provider stand-in.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, os, re, shutil, subprocess, sys, tempfile
root=Path(sys.argv[1])
code=re.findall(r'```bash\n(.*?)```',(root/'skills/audit-splunk-oncall/references/api-contract.md').read_text(),re.S)[0]
passed=0
with tempfile.TemporaryDirectory(prefix='oncall-worklist-') as temp:
 t=Path(temp); bindir=t/'bin';bindir.mkdir();plugin=t/'plugin';reader=plugin/'skills/audit-splunk-oncall/scripts/collect.sh';reader.parent.mkdir(parents=True)
 for name in ['sh','awk','basename','cat','chmod','cp','date','dirname','grep','head','jq','mkdir','mktemp','mv','printenv','rm','rmdir','sed','sort','tail','tr','wc']:
  os.symlink(shutil.which(name),bindir/name)
 real_hash=shutil.which('shasum')
 if not real_hash: raise AssertionError('shasum is required for this worklist fixture')
 (bindir/'shasum').write_text('#!/bin/sh\ncase "${HASH_FAILURE:-}" in empty) exit 2;; output) printf "%064d\\n" 0; exit 2;; esac\nexec "'+real_hash+'" "$@"\n')
 (bindir/'shasum').chmod(0o700)
 for name in ['curl','aws','gcloud','kubectl','doctl','az','gh','claude']:
  (bindir/name).write_text('#!/bin/sh\nprintf "UNEXPECTED_NETWORK_CLI\\n" >> "$CALLS"\nexit 99\n');(bindir/name).chmod(0o700)
 reader.write_text('''#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$CALLS"
if [ "${1:-}" = --plan ]; then
  [ "${MUTATE_AT:-}" != plan ] || printf "export TEST_ID='changed-id'\\nexport TEST_KEY='changed-key'\\n" > "$SCOUTFLO_ENV_FILE"
  cat "$PLAN_FILE"
elif [ "${1:-}" = --team ] && [ "$#" -eq 2 ] && [ "$2" = team-common ]; then
  [ "${MUTATE_AT:-}" != batch ] || printf "export TEST_ID='changed-id'\\nexport TEST_KEY='changed-key'\\n" > "$SCOUTFLO_ENV_FILE"
  jq -n --arg target "$TARGET_VALUE" '{scope:"team-common",target:$target,complete_reads:true}'
else exit 98; fi
''')
 script=t/'worklist.sh';script.write_text(code);store=t/'store.env';calls=t/'calls';plan=t/'plan.json'
 env={'PATH':str(bindir),'HOME':str(t),'CLAUDE_PLUGIN_ROOT':str(plugin),'SCOUTFLO_ENV_FILE':str(store),'CALLS':str(calls),'PLAN_FILE':str(plan)}
 for name in ['curl','aws','gcloud','kubectl','doctl','az','gh','claude']:
  found=subprocess.check_output(['/bin/sh','-c','command -v '+name],env=env,text=True).strip()
  assert found==str(bindir/name), name
 def reset(label=''):
  store.write_text("export TEST_ID='fixture-id'\nexport TEST_KEY='fixture-key'\n")
  store.chmod(0o600);calls.write_text('');target='splunk_oncall'+('/'+label if label else '')
  plan.write_text(json.dumps({'target':target,'anchor_team':'team-common','credential_refs':{'api_id_env':'TEST_ID','api_key_env':'TEST_KEY'},'team_slugs':['team-common']}))
  return target
 def run(target,runid,mode='init',expect=0,extra=None):
  p=subprocess.run(['/bin/sh',str(script)],cwd=t,env=env|{'SCOUTFLO_AUDIT_DIR':str(t/'audits'),'SCOUTFLO_RUN_ID':runid,'SCOUTFLO_BATCH_MODE':mode,'TARGET_VALUE':target}|(extra or {}),capture_output=True,text=True)
  assert (p.returncode==0)==(expect==0),(mode,p.returncode,p.stdout,p.stderr)
  assert not any(x in p.stdout+p.stderr for x in ['fixture-id','fixture-key','changed-id','changed-key'])
  assert 'UNEXPECTED_NETWORK_CLI' not in calls.read_text()
  return p
 def ok(name):
  global passed
  passed+=1;print('PASS '+name)
 for label in ['', 'secondary']:
  target=reset(label);runid='stable';run(target,runid);folder=t/'audits'/target/'runs'/runid
  assert (folder/'credential.sha256').stat().st_mode & 0o777==0o600
  assert 'credential.sha256' not in (folder/'worklist.json').read_text()
  run(target,runid,'finish',expect=1);run(target,runid,'batch');r=run(target,runid,'finish')
  assert json.loads(r.stdout)['teams'][0]['state']=='done'
  ok('stable resume with private binding '+(label or 'single'))
  before=(folder/'worklist.json').read_bytes()
  store.write_text("export TEST_ID='changed-id'\nexport TEST_KEY='changed-key'\n")
  run(target,runid,'finish',expect=1)
  assert (folder/'worklist.json').read_bytes()==before
  ok('same-slug credential switch rejects saved snapshots '+(label or 'single'))
  reset(label);(folder/'credential.sha256').unlink();run(target,runid,'finish',expect=1)
  ok('legacy unbound worklist refuses reuse '+(label or 'single'))
 target=reset('errors')
 store.write_text("export TEST_ID='fixture-id'\n")
 run(target,'unset',expect=1);ok('unset selected credential cannot bind')
 for failure in ['empty','output']:
  reset('errors');run(target,'hash-'+failure,expect=1,extra={'HASH_FAILURE':failure})
  ok('failed digest command is rejected '+failure)
 reset('errors');run(target,'during-plan',expect=1,extra={'MUTATE_AT':'plan'})
 ok('store change during preflight rejected')
 reset('errors');run(target,'during-batch');folder=t/'audits'/target/'runs/during-batch'
 run(target,'during-batch','batch',expect=1,extra={'MUTATE_AT':'batch'})
 assert json.loads((folder/'worklist.json').read_text())['teams'][0]['state']=='pending'
 assert not (folder/'team-common.json').exists()
 ok('credential change during batch preserves pending state')
 print(f'On-Call worklist: {passed} passed; zero provider calls')
PY
