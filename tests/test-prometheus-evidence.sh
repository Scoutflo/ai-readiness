#!/bin/sh
# Exercise the published recipes against local stand-ins, never a live service.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, os, re, subprocess, sys, tempfile
root = Path(sys.argv[1])
skill = (root/'skills/audit-prometheus/SKILL.md').read_text()
ref = (root/'skills/audit-prometheus/references/prometheus-checks.md').read_text()
def block(text, heading):
    return re.search(r'^```bash\n(.*?)^```', text[text.index(heading):], re.M|re.S).group(1)
with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    for sub in ['bin','home/.scoutflo','cwd/.scoutflo','audits']:
        (work/sub).mkdir(parents=True)
    config = work/'cwd/.scoutflo/toolkit.yaml'
    config.write_text('prometheus:\n  url: https://metrics.example.invalid\n')
    stub = work/'bin/curl'
    stub.write_text(r'''#!/bin/sh
set -eu
dst=''; fmt=''; url=''; query=''; authed=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) dst=$2; shift;; -w) fmt=$2; shift;;
    --data-urlencode) query=$2; shift;; -H) authed=yes; shift;;
    http*) url=$1;;
  esac
  shift
done
case "$url" in https://metrics.example.invalid/*) :;; *) exit 98;; esac
if [ "$CASE" = denied ] || { [ "$CASE" = config_denied ] && [ "$url" = https://metrics.example.invalid/api/v1/status/config ]; }; then exit 22; fi
code=200; ct=application/json
case "$url" in
  */status/buildinfo) body='{"status":"success","data":{"version":"3"}}';;
  */targets*) body='{"status":"success","data":{"activeTargets":[]}}';;
  */rules) body='{"status":"success","data":{"groups":[]}}';;
  */status/config)
    if [ "$CASE" = config_empty ]; then body='{"status":"success","data":{"yaml":"remote_write: []"}}'
    else body='{"status":"success","data":{"yaml":"scrape_configs: []"}}'; fi;;
  *) body='{"status":"success","data":{"resultType":"vector","result":[]}}';;
esac
if [ "$CASE" = malformed ]; then body='<html>Sign in</html>'; ct=text/html; fi
if [ "$query" = 'query=vector(1)' ] && [ "$authed" = no ]; then
  case "$CASE" in
    html) body='<html>Sign in</html>'; ct=text/html;;
    public) body='{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"1"]}]}}';;
    auth_required) code=403; body='{}';;
  esac
fi
if [ -n "$dst" ]; then printf '%s' "$body" > "$dst"; else printf '%s' "$body"; fi
if [ -n "$fmt" ]; then printf '%s' "$fmt" | sed "s/%{http_code}/$code/g;s|%{content_type}|$ct|g"; fi
''')
    stub.chmod(0o755)
    env = dict(os.environ, HOME=str(work/'home'), PATH=str(work/'bin')+':'+os.environ['PATH'],
               CLAUDE_PLUGIN_ROOT=str(root), SCOUTFLO_CONFIG=str(config),
               SCOUTFLO_ENV_FILE=str(work/'home/.scoutflo/env'), SCOUTFLO_AUDIT_DIR=str(work/'audits'))
    assert subprocess.check_output(['sh','-c','command -v curl'],env=env,text=True).strip() == str(stub)
    cases = 0
    def run(code, mode):
        global cases
        result = subprocess.run(['sh','-c',code],cwd=work/'cwd',env=dict(env,CASE=mode),
                                capture_output=True,text=True,input='yes\n',timeout=20)
        cases += 1
        return result.returncode, result.stdout + result.stderr
    sizing = block(skill,'## Estate sizing')
    for mode in ['denied','malformed']:
        rc,out = run(sizing,mode)
        assert rc != 0 and 'blocked' in out and 'sizing-path=small' not in out, out
    rc,out = run(sizing,'empty')
    assert rc == 0 and 'scored_objects=0 sizing-path=small' in out, out
    rc,out = run(block(skill,'### Scope checkpoint'),'empty')
    assert rc == 0, out
    # A failed new census invalidates the previous one; a fresh checkpoint cannot reuse it.
    run(sizing,'denied')
    rc,out = run(block(skill,'### Scope checkpoint'),'empty')
    assert rc != 0, out
    remote = block(ref,'## 7. Remote-write')
    for mode in ['denied','config_denied','empty']:
        rc,out = run(remote,mode)
        assert 'PROM-040 blocked' in out and 'PROM-040 not-in-scope' not in out, out
    rc,out = run(remote,'config_empty')
    assert rc == 0 and 'PROM-040 not-in-scope (inapplicable)' in out, out
    exposure = block(ref,'### PROM-051')
    rc,out = run(exposure,'html')
    assert 'PROM-051 blocked' in out and 'evidence: unauthenticated query access' not in out, out
    rc,out = run(exposure,'public')
    assert rc == 0 and 'evidence: unauthenticated query access' in out, out
    rc,out = run(exposure,'auth_required')
    assert rc == 0 and 'unauthenticated query was denied' in out, out
    guard = block(skill,'### Empty / hidden-scope guardrail')
    rc,out = run(guard,'denied')
    assert rc != 0 and 'has ZERO' not in out, out
    rc,out = run(guard,'empty')
    assert rc == 0 and 'has ZERO active scrape targets' in out, out
    # Secret stores may contain historical routing variables; loading credentials
    # must not change this caller's selected config/output directory.
    (work/'home/.scoutflo/env').write_text("export SCOUTFLO_CONFIG=/missing/wrong-config\nexport SCOUTFLO_AUDIT_DIR=/missing/wrong-output\n")
    check = '. "$CLAUDE_PLUGIN_ROOT/skills/audit-prometheus/scripts/prometheus-http.sh"; [ "$SCOUTFLO_CONFIG" = "'+str(config)+'" ] && [ "$SCOUTFLO_AUDIT_DIR" = "'+str(work/'audits')+'" ]'
    rc,out = run(check,'empty')
    assert rc == 0, out
    (work/'home/.scoutflo/env').unlink()
    # Every reference block that uses the shared helpers declares them in that shell.
    for recipe in re.findall(r'^```bash\n(.*?)^```', ref, re.M|re.S):
        if re.search(r'\bpqq?(?:_json)?\s+[\'\"]', recipe):
            assert '/scripts/prometheus-http.sh"' in recipe, recipe
        if re.search(r'^\s*RESPONSE=\$\(pqq?_json ', recipe, re.M):
            rc,out = run(recipe,'denied')
            assert rc != 0 and 'blocked' in out, (recipe, out)
    previous = work/'previous.json'; current = work/'current.json'
    previous.write_text(json.dumps({'findings':[{'id':'PROM-001'},{'id':'PROM-002'}]}))
    for result, expected in [('pass','1'),('blocked','0'),('not-in-scope','0')]:
        current.write_text(json.dumps({'checks':[{'id':'PROM-001','result':result}]}))
        observed = subprocess.check_output(['sh',str(root/'skills/audit-prometheus/scripts/resolved-count.sh'),str(current),str(previous)],env=env,text=True).strip()
        assert observed == expected, (result,observed)
        cases += 1
    print(f'TESTS-OK: {cases} fresh-shell Prometheus evidence cases; zero live calls')
PY
