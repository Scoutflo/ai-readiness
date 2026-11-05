#!/bin/sh
# Exercise the literal doctor function; stand-ins retain any attempted file write.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
source = (root/'skills/doctor/scripts/doctor.sh').read_text()
function = source[source.index('\nlive_check() {')+1:source.index('\n# authed_json_check <int>')]
canary = 'fixture-routing-capture-canary'
passed = 0
with tempfile.TemporaryDirectory(prefix='doctor-am-memory-') as td:
    work = pathlib.Path(td); bins = work/'bin'; bins.mkdir()
    curl = bins/'curl'
    curl.write_text('#!'+sys.executable+'''\nimport json,os,pathlib,sys
a=sys.argv[1:]; mode=os.environ['AM_TEST_MODE']
if '--version' in a:
 print('curl '+('8.3.0' if mode=='old-curl' else '8.4.0'));sys.exit(0)
with open(os.environ['AM_TEST_CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
body=json.dumps({'cluster':{'status':'ready'},'config':{'original':'routing_key: fixture-routing-capture-canary'}})
code='200'; ct='application/json'
if mode=='html': body='<html>fixture-routing-capture-canary</html>';ct='text/html'
elif mode=='malformed':body='{fixture-routing-capture-canary'
elif mode=='empty':body=''
elif mode=='two-documents':body=body+'\\n'+body
elif mode=='denied':code='403'
elif mode=='redirect':code='302'
elif mode=='no-identity':body=json.dumps({'config':{'original':'fixture-routing-capture-canary'}})
if '-o' in a:
 pathlib.Path(a[a.index('-o')+1]).write_text(body)
 # A durable mirror lets the test catch a raw temp file even after unlink.
 pathlib.Path(os.environ['AM_TEST_CAPTURE']).write_text(body)
else:sys.stdout.write(body)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace('\\\\n','\\n').replace('%{http_code}',code).replace('%{content_type}',ct))
if mode=='transport':sys.exit(28)
if mode=='oversized':sys.exit(63)
'''); curl.chmod(0o755)
    script = '''set -eu
note() { :; }
row() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@"; }
transport_hint() { printf 'transport %s' "$1"; }
http_hint() { printf 'http %s' "$1"; }
CONNECT_TIMEOUT=5; MAX_TIME=15
'''+function+'''
live_check alertmanager status https://example.invalid/api/v2/status none '' '.cluster != null or .versionInfo != null'
'''
    calls=work/'calls'; capture=work/'capture'
    for mode in ('good','html','malformed','empty','two-documents','denied','redirect','no-identity','transport','oversized','old-curl'):
        calls.write_text(''); capture.unlink(missing_ok=True)
        env={**os.environ,'PATH':str(bins)+os.pathsep+os.environ['PATH'],'TMPDIR':str(work),'AM_TEST_MODE':mode,'AM_TEST_CALLS':str(calls),'AM_TEST_CAPTURE':str(capture)}
        run=subprocess.run(['sh'],input=script,text=True,capture_output=True,env=env,timeout=10)
        assert run.returncode==0, (mode,'function must report row',run.stderr)
        assert ('|pass|' if mode=='good' else '|fail|') in run.stdout, (mode,run.stdout)
        assert canary not in run.stdout+run.stderr and not capture.exists(), (mode,'raw config escaped capture boundary')
        if mode=='old-curl': assert calls.read_text()=='', 'old curl made provider read'
        else:
            argv=json.loads(calls.read_text()); assert '-o' not in argv and '--max-filesize' in argv and '-q' in argv and '--proto' in argv
        passed+=1; print('PASS '+mode)
print('doctor Alertmanager status memory: '+str(passed)+' passed, 0 failed; no real provider calls')
PY
