#!/bin/sh
# Execute the published send block: only this environment's configured destination may receive it.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import datetime, json, os, pathlib, re, shlex, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
blocks = re.findall(r'```bash\n(.*?)\n```', (root/'skills/audit-all/SKILL.md').read_text(), re.S)
blocks = [b for b in blocks if 'BRIEF_FILE=' in b and '--data @-' in b]
assert len(blocks) == 1, 'published send block was not uniquely extracted'
with tempfile.TemporaryDirectory(prefix='audit-all-slack-') as folder:
    work = pathlib.Path(folder); home = work/'home'; home.mkdir()
    stub = work/'bin'; stub.mkdir(); script = work/'send.sh'; script.write_text(blocks[0])
    curl = stub/'curl'
    curl.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["CALLS"],"a") as f: f.write(json.dumps({"args":sys.argv[1:],"body":sys.stdin.read()})+"\\n")\nif os.environ.get("FAIL_SEND"): print(sys.argv[-1],file=sys.stderr);sys.exit(22)\nprint("ok")\n')
    curl.chmod(0o755)
    real_jq = shutil.which('jq'); assert real_jq, 'jq prerequisite missing'
    (stub/'jq').write_text('#!/bin/sh\nif [ "${FAIL_ENCODE:-}" = 1 ] && [ "${1:-}" = -Rs ]; then exit 44; fi\nexec '+shlex.quote(real_jq)+' "$@"\n')
    (stub/'jq').chmod(0o755)
    # Force the shared portable config path; never depend on an installed yq flavor.
    (stub/'yq').write_text('#!/bin/sh\nexit 1\n'); (stub/'yq').chmod(0o755)
    count = 0
    for shell in ['/bin/sh', '/bin/bash']:
        for name, config, store, exports, expected in [
            ('exported custom', 'CUSTOM_BRIEF', None, {'CUSTOM_BRIEF':'https://selected.example.com/brief','SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, 'selected'),
            ('stored custom', 'CUSTOM_BRIEF', "export CUSTOM_BRIEF='https://selected.example.com/brief'\nexport SCOUTFLO_AUDIT_DIR='/wrong/output'\n", {'SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, 'selected'),
            ('store wins', 'CUSTOM_BRIEF', "export CUSTOM_BRIEF='https://selected.example.com/brief'\n", {'CUSTOM_BRIEF':'https://stale.example.com/brief'}, 'selected'),
            ('missing selected', 'CUSTOM_BRIEF', None, {'SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, None),
            ('empty selected', 'CUSTOM_BRIEF', "export CUSTOM_BRIEF=''\n", {'SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, None),
            ('default explicitly configured', 'SCOUTFLO_SLACK_WEBHOOK', None, {'SCOUTFLO_SLACK_WEBHOOK':'https://selected.example.com/brief'}, 'selected'),
            ('no destination configured', '', None, {'SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, None),
            ('malformed store', 'CUSTOM_BRIEF', "export CUSTOM_BRIEF='unterminated\n", {'CUSTOM_BRIEF':'https://stale.example.com/brief'}, None),
            ('invalid variable', 'bad-name', None, {'SCOUTFLO_SLACK_WEBHOOK':'https://stale.example.com/brief'}, None),
            ('different environment', 'SECOND_BRIEF', None, {'CUSTOM_BRIEF':'https://stale.example.com/brief','SECOND_BRIEF':'https://selected.example.com/brief'}, 'selected'),
            ('failed send hides destination', 'CUSTOM_BRIEF', None, {'CUSTOM_BRIEF':'https://selected.example.com/brief','FAIL_SEND':'1'}, 'selected'),
            ('missing brief', 'CUSTOM_BRIEF', None, {'CUSTOM_BRIEF':'https://selected.example.com/brief','NO_BRIEF':'1'}, None),
            ('empty brief', 'CUSTOM_BRIEF', None, {'CUSTOM_BRIEF':'https://selected.example.com/brief','EMPTY_BRIEF':'1'}, None),
            ('JSON encoding failed', 'CUSTOM_BRIEF', None, {'CUSTOM_BRIEF':'https://selected.example.com/brief','FAIL_ENCODE':'1'}, None),
        ]:
            cfg = work/'selected.yaml'; cfg.write_text('slack:\n  webhook_env: '+config+'\n')
            secret = work/'store'; secret.unlink(missing_ok=True)
            if store is not None: secret.write_text(store)
            calls = work/'calls.jsonl'; calls.write_text('')
            output = work/'output with spaces'
            brief = output/'all'/datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d')/'brief.txt'
            brief.parent.mkdir(parents=True,exist_ok=True); brief.write_text('Selected environment summary')
            if exports.get('NO_BRIEF'): brief.unlink()
            if exports.get('EMPTY_BRIEF'): brief.write_text('')
            env = {'HOME':str(home),'PATH':str(stub)+os.pathsep+os.environ['PATH'],'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_ENV_FILE':str(secret),'SCOUTFLO_AUDIT_DIR':str(output),'CLAUDE_PLUGIN_ROOT':str(root),'CALLS':str(calls),**exports}
            where = subprocess.check_output([shell,'-c','command -v curl'],env=env,text=True).strip()
            assert where == str(curl), where
            result = subprocess.run([shell,str(script)],cwd=work,env=env,capture_output=True,text=True)
            assert result.returncode == 0, (name,result.stderr)
            sent = [json.loads(x) for x in calls.read_text().splitlines()]
            assert len(sent) == (1 if expected else 0), (name,sent,result.stdout)
            if expected:
                assert sent[0]['args'][-1] == 'https://selected.example.com/brief', (name,sent)
                assert json.loads(sent[0]['body']) == {'text':'Selected environment summary'}
            assert 'https://' not in result.stdout+result.stderr, (name,'destination leaked')
            count += 1
    print('AUDIT-ALL-SLACK-OK:',count,'fresh-shell cases; zero network calls')
PY
