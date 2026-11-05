#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy, datetime as dt, json, os, pathlib, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); lib=root/'skills/alert-fatigue/lib/alert-fatigue.sh'
with tempfile.TemporaryDirectory(prefix='af-native-history-') as temp:
    base=pathlib.Path(temp); audit=base/'audits'; date=dt.datetime.now(dt.timezone.utc); rd=date.strftime('%Y-%m-%d')
    start=(date-dt.timedelta(days=2)).replace(hour=0,minute=0,second=0,microsecond=0); end=start+dt.timedelta(days=1)
    def iso(d):return d.isoformat(timespec='seconds').replace('+00:00','Z')
    row={'incident_number':'1','phase':'UNACKED','started_at':iso(start+dt.timedelta(hours=1)),'last_alert_at':iso(start+dt.timedelta(hours=2)),'provider_alert_count':5,'entity_ref':'entity-'+'a'*24,'service_ref':None,'host_ref':None,'teams':['team-one'],'responders':['responder-'+'b'*24],'policies':[],'transitions':[{'phase':'UNACKED','at':iso(start+dt.timedelta(hours=1)),'manual':None}]}
    snapshot={'schema':'scoutflo-oncall-history/v1','target':'splunk_oncall','generated_at':iso(date),'window':{'started_after':iso(start),'started_before':iso(end),'query_phases':['resolved','triggered','acknowledged']},'collection':{'status':'complete','complete':True,'pages':1,'expected_total':1,'next_offset':1,'reason':None,'atomic_snapshot':False,'verification':'response-asserted'},'incidents':[row],'context':[],'workload':None}
    # Block accidental network access from the local-only aggregator.
    bins=base/'bin'; bins.mkdir(); bins.joinpath('curl').write_text('#!/bin/sh\necho unexpected-network >&2\nexit 99\n'); bins.joinpath('curl').chmod(0o755)
    env=dict(os.environ,CLAUDE_PLUGIN_ROOT=str(root),SCOUTFLO_AUDIT_DIR=str(audit),PATH=str(bins)+os.pathsep+os.environ['PATH'])
    def write(target,doc):
        d=audit/target/rd; d.mkdir(parents=True,exist_ok=True); (d/'oncall-history.json').write_text(json.dumps(doc));return d/'oncall-history.json'
    def run(okay=True):
        p=subprocess.run(['sh','-c','. "$1"; alert_fatigue_run "$2"','_',str(lib),rd],env=env,capture_output=True,text=True)
        assert (p.returncode==0)==okay,(p.returncode,p.stderr,p.stdout)
        out=json.loads((audit/'alert-fatigue.json').read_text()); return {r['af_id']:r for r in out['af_findings']},out
    f=write('splunk_oncall',snapshot); result,out=run()
    af=result['AF-005']; assert af['status']=='not-in-scope' and af['total_fires']==0
    assert af['incident_history_status']=='measured' and af['incident_history'][0]['population_incidents']==1
    assert af['incident_history'][0]['provider_alert_count']==5 and af['incident_history'][0]['notification_attempts'] is None
    assert result['AF-003']['status']=='not-in-scope' and result['AF-004']['status']=='not-in-scope'
    # Invalid cohort starts must not leak response/recurrence/assignment
    # measurements into AF or either report, while selected duty/context stays.
    for started in (iso(start-dt.timedelta(hours=1)),None):
        rejected=copy.deepcopy(snapshot); rejected['incidents'][0].update(phase='RESOLVED',started_at=started)
        rejected['incidents'][0]['transitions']=[{'phase':phase,'at':iso(start+dt.timedelta(hours=1,minutes=n)),'manual':None} for n,phase in enumerate(('UNACKED','ACKED','RESOLVED'))]
        rejected['context']=[{'incident_number':'7','original_alert_read':True,'message_type':'CRITICAL','fields_present':{'entity':True,'description':True,'monitoring_tool':True,'display_name':False},'raw_fields_present':{'service':True,'environment':True,'owner':False,'runbook':False,'impact':None},'interpretation':'presence-only'}]
        rejected['workload']={'team':'team-one','started_at':iso(start),'ended_at':iso(end),'lag_seconds':900,'users':[{'user_ref':'log-user-'+'c'*24,'reported_total':{'hours':5,'minutes':12},'reported_adjusted_total':None,'intervals':[{'on':iso(start),'off':iso(start+dt.timedelta(hours=5,minutes=12))}]}],'interpretation':'assignment-time-not-interruptions'}
        f.write_text(json.dumps(rejected));result,out=run();native=result['AF-005']['incident_history'][0]
        assert native['status']=='blocked' and native['observed_incidents']==0 and native['population_incidents'] is None
        assert native['collected_incidents']==1 and native['excluded_incidents']==1 and '1 excluded' in native['reason']
        assert native['response']['ack_samples']==0 and native['response']['resolution_samples']==0
        assert native['response']['mean_ack_seconds_observed_subset'] is None and native['response']['mean_resolution_seconds_observed_subset'] is None
        assert native['recurrence']['ranked_entities']==[] and native['workload']['incident_assignment_counts']==[]
        assert native['workload']['assignment_time']==rejected['workload'] and native['context']==rejected['context']
        viz=root/'report-standard/render-report-viz.sh';html=base/'rejected.html'
        p=subprocess.run(['sh',str(viz),'alert-fatigue',str(audit/'alert-fatigue.json'),str(audit),rd],env=env,capture_output=True,text=True)
        assert p.returncode==0,p.stderr
        md=p.stdout
        p=subprocess.run(['sh',str(viz),'alert-fatigue-html',str(audit/'alert-fatigue.json'),str(html),str(audit),rd],env=env,capture_output=True,text=True)
        assert p.returncode==0,p.stderr
        for report in (md,html.read_text()):
            assert '1 excluded' in report and '0 have verified starts' in report, 'excluded cohort diagnostic hidden'
            assert '7260' not in report and '7320' not in report, 'out-of-window response latency displayed'
            assert 'log-user-'+'c'*24 in report and '5 h 12 min' in report, 'independent duty evidence hidden'
            assert 'Raw context' in report, 'independent original context hidden'
    f.write_text(json.dumps(snapshot))
    # Labeled targets must remain separate; native entity refs are not service joins.
    second=copy.deepcopy(snapshot); second['target']='splunk_oncall/secondary'; second['incidents'][0]['incident_number']='2'
    f2=write(second['target'],second); result,out=run(); assert len(result['AF-005']['incident_history'])==2
    assert result['AF-002']['storms']==[]
    # Incomplete cohorts show observed rows without a population total.
    partial=copy.deepcopy(second); partial['collection'].update(status='partial',complete=False,expected_total=101,reason='page-budget')
    f2.write_text(json.dumps(partial)); result,out=run()
    pending=[s for s in result['AF-005']['incident_history'] if s['target']==second['target']][0]
    assert pending['status']=='blocked' and pending['population_incidents'] is None and pending['observed_incidents']==1
    # Same-day cross-target artifacts, raw injections and stale provenance fail
    # before local roll-up; source content never appears in the blocked summary.
    for change in ('wrong-target','raw','stale'):
        bad=copy.deepcopy(second)
        if change=='wrong-target':bad['target']='splunk_oncall/unrelated'
        elif change=='raw':bad['raw']='secret-content-must-not-leak'
        else:bad['generated_at']=iso(date-dt.timedelta(days=1))
        f2.write_text(json.dumps(bad)); result,out=run(False)
        assert out['input_validation']['status']=='blocked' and result['AF-005']['incident_history_status']=='blocked'
        assert 'secret-content-must-not-leak' not in json.dumps(out)
        assert result['AF-003']['status']=='not-in-scope'
    f.unlink();f2.unlink();result,out=run();assert result['AF-005']['incident_history']==[] and result['AF-005']['incident_history_status']=='not-in-scope'
    print('PASS: native On-Call incident units, multi-target/date isolation, incomplete cohorts and privacy without provider calls')
PY
