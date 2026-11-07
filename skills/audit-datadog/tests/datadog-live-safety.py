import json, os, pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
source = (root / 'skills/audit-datadog/SKILL.md').read_text()
section = source.split('## Live-safety gate\n', 1)[1].split('\n## ', 1)[0]
block = re.findall(r'```bash\n(.*?)\n```', section, re.S)[0]
cases = ('good', 'org-denied', 'denied', 'monitor-denied', 'html', 'transport',
         'partial', 'malformed', 'object', 'null', 'no-body', 'empty')
passed = []
with tempfile.TemporaryDirectory(prefix='datadog-live-safety-') as work:
    work = pathlib.Path(work)
    bindir = work / 'bin'
    bindir.mkdir()
    # Only local dependencies are reachable. No real curl or cloud CLI is on PATH.
    for name in ('sh', 'head', 'awk', 'sed', 'cat', 'tr', 'date', 'mkdir', 'printenv', 'jq'):
        binary = shutil.which(name)
        assert binary, 'Missing test dependency: ' + name
        (bindir / name).symlink_to(binary)
    (bindir / 'python3').symlink_to(sys.executable)
    curl = bindir / 'curl'
    curl.write_text('#!' + sys.executable + '''
import json, os, sys
args = sys.argv[1:]
if args == ['--version']:
    print('curl 8.4.0 fixture')
    sys.exit(0)
assert '--max-time' in args and args[args.index('--max-time') + 1] == '45'
assert '--max-filesize' in args and args[args.index('--max-filesize') + 1] == '8388608'
assert '--proto' in args and args[args.index('--proto') + 1] == '=https'
assert '-L' not in args and '--location' not in args
assert 'DD-API-KEY: fixture-selected-api' in args
assert 'DD-APPLICATION-KEY: fixture-selected-app' in args
url = args[-1]
assert url.startswith('https://api.' + os.environ['EXPECTED_SITE'] + '/')
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps(url) + '\\n')
org = url.endswith('/api/v1/org')
assert org or url.endswith('/api/v1/monitor?page_size=3')
mode = os.environ['CASE']
body = {'orgs': [{'name': 'Example account'}]} if org else [{
    'id': 1, 'name': 'Example monitor', 'type': 'metric alert',
    'query': 'avg(last_5m):avg:cpu{service:example} > 1',
    'message': 'token=PRIVATE_SENTINEL', 'options': {'silenced': {}}}]
code, content_type, status = '200', 'application/json', 0
if mode == 'denied' or (org and mode in ('org-denied', 'empty')) or (not org and mode == 'monitor-denied'):
    body, code = {'errors': ['token=PRIVATE_SENTINEL']}, '403'
elif mode == 'html':
    body, content_type = '<html>token=PRIVATE_SENTINEL</html>', 'text/html'
elif mode == 'transport':
    sys.exit(28)
elif not org:
    if mode == 'partial': status = 18
    elif mode == 'malformed': body = '[{"id":1,"name":"PRIVATE_SENTINEL"}'
    elif mode == 'object': body = {'monitors': []}
    elif mode == 'null': body = None
    elif mode == 'no-body': body = ''
    elif mode == 'empty': body = []
print(body if isinstance(body, str) else json.dumps(body))
print(code + ' ' + content_type)
sys.exit(status)
''')
    curl.chmod(0o700)
    for layout, site, stored in (('single', 'datadoghq.com', False),
                                 ('single', 'us3.datadoghq.com', True),
                                 ('list', 'datadoghq.eu', True)):
        lane = layout + '-' + site
        home = work / lane
        home.mkdir()
        config, store = home / 'toolkit.yaml', home / 'env'
        selected = ('    site: ' + site + '\n    api_key_env: SELECTED_API\n'
                    '    app_key_env: SELECTED_APP\n')
        if layout == 'list':
            config.write_text('datadog:\n  - label: other\n    site: datadoghq.com\n'
                              '    api_key_env: OTHER_API\n    app_key_env: OTHER_APP\n'
                              '  - label: selected\n' + selected)
        else:
            config.write_text('datadog:\n' + selected.replace('    ', '  '))
        if stored:
            store.write_text('SELECTED_API=fixture-selected-api\nSELECTED_APP=fixture-selected-app\n')
        env = dict(PATH=str(bindir), HOME=str(home), PYTHONDONTWRITEBYTECODE='1',
                   CLAUDE_PLUGIN_ROOT=str(root), SCOUTFLO_CONFIG=str(config),
                   SCOUTFLO_ENV_FILE=str(store), SCOUTFLO_TARGET='selected',
                   SCOUTFLO_AUDIT_DIR=str(home / 'audits'), EXPECTED_SITE=site,
                   SELECTED_API='ambient-wrong-api' if stored else 'fixture-selected-api',
                   SELECTED_APP='ambient-wrong-app' if stored else 'fixture-selected-app',
                   OTHER_API='other-wrong-api', OTHER_APP='other-wrong-app')
        for shell in ('/bin/sh', '/bin/bash'):
            for case in cases:
                name = lane + '/' + pathlib.Path(shell).name + '/' + case
                calls = home / ('calls-' + pathlib.Path(shell).name + '-' + case)
                r = subprocess.run([shell, '-c', block], env=dict(env, CASE=case, CALLS=str(calls)),
                                   cwd=home, text=True, capture_output=True)
                success = case in ('good', 'org-denied', 'empty')
                assert (r.returncode == 0) == success, name + ': wrong exit status'
                marker = 'Compare this identity to the intended account: '
                assert (marker in r.stdout) == success, name + ': incorrect continuation'
                assert 'PRIVATE_SENTINEL' not in r.stdout + r.stderr, name + ': raw response leaked'
                assert len(calls.read_text().splitlines()) == 2, name + ': expected only the two identity reads'
                if success:
                    expected = ('datadog/selected' if layout == 'list' else 'datadog') + ' on ' + site
                    assert marker + expected in r.stdout, name + ': wrong selected target'
                    # Parse the actual sample, excluding only the preceding org/fallback line.
                    sample = json.loads(r.stdout.split('\n', 1)[1].split(marker, 1)[0])
                    assert sample == ([] if case == 'empty' else [{'id': 1, 'name': 'Example monitor'}]), name + ': wrong safe identities'
                else:
                    assert 'Example monitor' not in r.stdout, name + ': failed sample was published'
                passed.append(name)
print('Datadog live-safety regressions: ' + str(len(passed)) + ' passed')
for name in passed:
    print('PASS ' + name)
