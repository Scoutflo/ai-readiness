#!/bin/sh
# Literal generic JSON probe, with canaries for transient raw response writes.
set -eu
ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)}"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]);source=(root/'skills/doctor/scripts/doctor.sh').read_text()
function=source[source.index('http_get() {'):source.index('\ntransport_hint() {')]
canary='fixture-channel-credential-canary'
with tempfile.TemporaryDirectory(prefix='doctor-json-memory-') as td:
    work=pathlib.Path(td);bins=work/'bin';bins.mkdir();stub=bins/'curl'
    stub.write_text('#!'+sys.executable+'''\nimport json,os,pathlib,sys
a=sys.argv[1:];mode=os.environ['JSON_MODE']
if '--version' in a:
 print('curl '+('8.3.0' if mode=='old-curl' else 'unknown' if mode=='unknown-curl' else '8.4.0'));sys.exit(0)
with open(os.environ['JSON_CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
body=json.dumps({'items':[{'credential':'fixture-channel-credential-canary'}]});code='200';ct='application/json'
if mode=='html':body='<html>fixture-channel-credential-canary</html>';ct='text/html'
elif mode=='malformed':body='{fixture-channel-credential-canary'
elif mode=='empty':body=''
elif mode=='two-documents':body+='\\n'+body
elif mode=='missing-items':body='{}'
elif mode=='null-items':body='{"items":null}'
elif mode=='error':body='{"items":[],"error":"fixture-channel-credential-canary"}'
elif mode=='denied':code='403'
elif mode=='redirect':code='302'
if '-o' in a:
 pathlib.Path(a[a.index('-o')+1]).write_text(body)
 pathlib.Path(os.environ['JSON_CAPTURE']).write_text(body)
else:sys.stdout.write(body)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace(chr(92)+'n',chr(10)).replace('%{http_code}',code).replace('%{content_type}',ct))
if mode=='transport':sys.exit(28)
if mode=='oversized':sys.exit(63)
''');stub.chmod(0o700)
    script='set -eu\nCONNECT_TIMEOUT=1; MAX_TIME=2\n'+function+'''
http_get https://example.invalid/api fixture-token '' 'type=="object" and (.items|type=="array") and (has("error")|not)'
printf '%s|%s|%s\\n' "$HTTP_CODE" "$CURL_RC" "$HTTP_JSON_VALID"
'''
    modes=('good','html','malformed','empty','two-documents','missing-items','null-items','error','denied','redirect','transport','oversized','old-curl','unknown-curl')
    for mode in modes:
        calls=work/'calls';calls.write_text('');capture=work/'capture';capture.unlink(missing_ok=True)
        env={**os.environ,'PATH':str(bins)+os.pathsep+os.environ['PATH'],'TMPDIR':str(work),'JSON_MODE':mode,'JSON_CALLS':str(calls),'JSON_CAPTURE':str(capture)}
        result=subprocess.run(['/bin/sh'],input=script,env=env,text=True,capture_output=True,timeout=10)
        assert canary not in result.stdout+result.stderr and not capture.exists(),(mode,'raw body escaped memory')
        assert result.returncode==0,(mode,result.stderr)
        assert result.stdout.rstrip().endswith('|1' if mode=='good' else '|0'),(mode,result.stdout)
        argv=[json.loads(x) for x in calls.read_text().splitlines()]
        assert len(argv)==(0 if mode in {'old-curl','unknown-curl'} else 1),(mode,argv)
        for a in argv:
            assert a[0]=='-q' and '-o' not in a and '--location' not in a and '-L' not in a,(mode,a)
            assert a[a.index('--max-filesize')+1]=='2097152' and a[a.index('--proto')+1]=='=http,https' and a[a.index('--max-redirs')+1]=='0',(mode,a)
        print('PASS '+mode)
print('doctor generic JSON status memory: 14 passed, 0 failed; no real provider calls')
PY
