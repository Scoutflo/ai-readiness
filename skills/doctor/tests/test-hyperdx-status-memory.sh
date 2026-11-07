#!/bin/sh
# Exercise the actual authenticated probe and retain attempted raw writes.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]);source=(root/'skills/doctor/scripts/doctor.sh').read_text()
start=source.index('        note "doctor: checking ${CS_INT} hyperdx-api-key:')
end=source.index('\n      fi\n    fi\n  fi',start)
probe=source[start:end]
assert 'for _b in' in probe and 'hyperdx-api-key' in probe
canary='fixture-hdx-query-private-canary'
with tempfile.TemporaryDirectory(prefix='doctor-hdx-memory-') as td:
    work=pathlib.Path(td);bins=work/'bin';bins.mkdir()
    curl=bins/'curl'
    curl.write_text('#!'+sys.executable+'''\nimport json,os,pathlib,sys
a=sys.argv[1:];mode=os.environ['HDX_TEST_MODE']
if a==['--version']:
 print('curl '+('8.3.0' if mode=='old-curl' else '8.4.0'));sys.exit(0)
with open(os.environ['HDX_TEST_CALLS'],'a') as f:f.write(json.dumps(a)+'\\n')
body=json.dumps([{'query':'fixture-hdx-query-private-canary'}]);code='200';ct='application/json'
if mode=='object':body=json.dumps({'data':[]})
elif mode=='proxy' and '/api/api/v2/' not in a[-1]:code='404'
elif mode=='html':body='<html>fixture-hdx-query-private-canary</html>';ct='text/html'
elif mode=='malformed':body='{fixture-hdx-query-private-canary'
elif mode=='empty':body=''
elif mode=='two-documents':body+='\\n'+body
elif mode=='wrong-shape':body=json.dumps('fixture-hdx-query-private-canary')
elif mode=='null-data':body=json.dumps({'data':None})
elif mode=='error-data':body=json.dumps({'data':{'error':'denied'}})
elif mode=='denied':code='401'
elif mode=='forbidden':code='403'
elif mode=='redirect':code='302'
if '-o' in a:
 pathlib.Path(a[a.index('-o')+1]).write_text(body)
 pathlib.Path(os.environ['HDX_TEST_CAPTURE']).write_text(body)
else:sys.stdout.write(body)
if '-w' in a:sys.stdout.write(a[a.index('-w')+1].replace('\\\\n','\\n').replace('%{http_code}',code).replace('%{content_type}',ct))
if mode=='transport':sys.exit(28)
if mode=='oversized':sys.exit(63)
''');curl.chmod(0o755)
    script='''set -eu
note() { :; }
row() { printf '%s|%s|%s|%s|%s|%s|%s\n' "$@"; }
http_hint() { printf 'http %s' "$1"; }
CONNECT_TIMEOUT=5;CS_INT=clickstack;HDX_URL_CFG=https://example.invalid;HDX_API_KEY=dummy-test-key;HDX_KEY_VAR=TEST_KEY
'''+probe+'\n'
    modes=('good','object','proxy','html','malformed','empty','two-documents','wrong-shape','denied','forbidden','redirect','transport','oversized','null-data','error-data','old-curl')
    for mode in modes:
        calls=work/'calls';calls.write_text('');capture=work/'capture';capture.unlink(missing_ok=True)
        env={**os.environ,'PATH':str(bins)+os.pathsep+os.environ['PATH'],'TMPDIR':str(work),'HDX_TEST_MODE':mode,'HDX_TEST_CALLS':str(calls),'HDX_TEST_CAPTURE':str(capture)}
        r=subprocess.run(['sh'],input=script,text=True,capture_output=True,env=env,timeout=10)
        assert r.returncode==0,(mode,r.stderr)
        assert ('|pass|' if mode in {'good','object','proxy'} else '|fail|') in r.stdout,(mode,r.stdout)
        assert canary not in r.stdout+r.stderr and not capture.exists(),(mode,'raw body escaped memory')
        rows=[json.loads(x) for x in calls.read_text().splitlines()]
        assert len(rows)==(0 if mode=='old-curl' else 1 if mode in {'good','object'} else 2),(mode,len(rows))
        for argv in rows:
            assert '-o' not in argv and '--max-filesize' in argv and '-q' in argv and '--proto' in argv
        if mode in {'denied','forbidden'}:
            assert 'this status alone cannot identify' in r.stdout and 'this looks like' not in r.stdout
        print('PASS '+mode)
print('doctor HyperDX status memory: 16 passed, 0 failed; no real provider calls')
PY
