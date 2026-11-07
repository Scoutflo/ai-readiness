#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib,json,os,subprocess,sys,tempfile
from pathlib import Path
root=Path(sys.argv[1]);day='2026-01-15'
with tempfile.TemporaryDirectory() as temp:
    folder=Path(temp);out=folder/'alert-fatigue.json';env=dict(os.environ,CLAUDE_PLUGIN_ROOT=str(root),SCOUTFLO_AUDIT_DIR=str(folder))
    target=folder/'clickstack/primary'/day;target.mkdir(parents=True)
    findings=target/'findings.json'
    findings.write_text(json.dumps(dict(target='clickstack/primary',run_date=day,generated_at=day+'T00:00:00Z',collection=dict(status='partial',scope='subset',reason='Alerting-only review',observed_at=day+'T00:00:00Z'),findings=[dict(id='CS-040',area='alerting',title='Alert channel is missing',severity='high',affected=['rule-one'],status='configured')])))
    signals=folder/'fatigue-signals.json';signals.write_text(json.dumps(dict(schema='scoutflo-fatigue-signals/v1',generated_at=day+'T00:00:00Z',window='7d',signals=[dict(provider='grafana',target='grafana',object_id='rule-one',object_kind='grafana_rule',fires=7,source_finding_ids=[])],provider_coverage=[dict(provider='grafana',tier='fire-history',status='collected',verification='spec-only')])))
    before=hashlib.sha256(signals.read_bytes()).hexdigest()
    def run():
        p=subprocess.run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"; alert_fatigue_run "$1"','sh',day],env=env,capture_output=True,text=True)
        assert p.returncode==0,(p.stdout,p.stderr)
        return json.loads(out.read_text())
    result=run();coverage=result['fire_history_coverage']
    assert result['totals']['alerting_noise_findings']==1
    assert any(x['provider']=='clickstack' and x['target']=='clickstack/primary' and x['status']=='verify-pending' for x in coverage)
    assert any(x['provider']=='grafana' and x['status']=='collected' for x in coverage)
    assert next(x for x in result['af_findings'] if x['af_id']=='AF-005')['total_fires']==7
    assert hashlib.sha256(signals.read_bytes()).hexdigest()==before
    findings.write_text(json.dumps(dict(target='clickstack/primary',run_date=day,findings=[])));result=run()
    assert result['totals']['alerting_noise_findings']==0 and any(x['provider']=='clickstack' for x in result['fire_history_coverage'])
    findings.write_text(json.dumps(dict(target='clickstack/primary',run_date='2026-01-14',findings=[])));result=run()
    assert not any(x['provider']=='clickstack' for x in result['fire_history_coverage'])
    print('clickstack-standalone: 7 assertions passed; config and empty runs, honest unsupported history, other provider measurements preserved')
PY
