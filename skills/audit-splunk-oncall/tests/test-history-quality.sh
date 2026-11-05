#!/bin/sh
# Fresh-process transport fixtures plus adversarial local-artifact checks.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import datetime as dt, json, os, pathlib, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); reader=root/'skills/audit-splunk-oncall/scripts/history.sh'
with tempfile.TemporaryDirectory(prefix='oncall-history-tests-') as temp:
    base=pathlib.Path(temp); bins=base/'bin'; bins.mkdir(); home=base/'home'; home.mkdir()
    config=base/'toolkit.yaml'; config.write_text('splunk_oncall:\n  team_slug: test-team\n  api_id_env: TEST_API_ID\n  api_key_env: TEST_API_KEY\n')
    date=dt.datetime.now(dt.timezone.utc); start=(date-dt.timedelta(days=2)).replace(hour=0,minute=0,second=0,microsecond=0); end=start+dt.timedelta(days=1)
    def iso(d): return d.isoformat().replace('+00:00','Z')
    env=dict(os.environ, HOME=str(home),PATH=str(bins)+os.pathsep+os.environ['PATH'],SCOUTFLO_CONFIG=str(config),SCOUTFLO_ENV_FILE=str(base/'absent-env'),TEST_API_ID='fixture-api-id',TEST_API_KEY='fixture-key-do-not-emit',FIXTURE_ROOT=str(base),FIXTURE_START=iso(start),FIXTURE_END=iso(end))
    bins.joinpath('sleep').write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$FIXTURE_ROOT/sleeps"\n'); bins.joinpath('sleep').chmod(0o755)
    bins.joinpath('curl').write_text('''#!/usr/bin/env python3
import datetime as dt,json,os,pathlib,sys,urllib.parse
if sys.argv[1:]==['--version']:
 print('curl 8.4.0 fixture');sys.exit(0)
args=sys.argv[1:];base=pathlib.Path(os.environ['FIXTURE_ROOT']);u=urllib.parse.urlsplit(args[-1]);q=urllib.parse.parse_qs(u.query)
assert u.scheme=='https' and u.netloc=='api.victorops.com' and '--max-redirs' in args and args[args.index('--max-redirs')+1]=='0'
assert '--max-filesize' in args and '-X' not in args and '--data' not in args and '-d' not in args
with (base/'requests').open('a') as f:f.write(args[-1]+'\\n')
scenario=os.environ.get('SCENARIO','normal');start=dt.datetime.fromisoformat(os.environ['FIXTURE_START'].replace('Z','+00:00'))
def iso(d):return d.isoformat().replace('+00:00','Z')
def row(n):
 st=start+dt.timedelta(seconds=60*n)
 r={'incidentNumber':str(n),'currentPhase':'resolved','startTime':iso(st),'lastAlertTime':iso(st+dt.timedelta(seconds=120)),'alertCount':7,'entityId':'one-condition' if n<3 else 'another-condition','service':'api','host':'node','routingKey':'hidden-routing-credential','pagedTeams':['test-team'],'pagedUsers':['sample-responder'],'pagedPolicies':[{'team':{'slug':'test-team','name':'Do not retain name'},'policy':{'slug':'policy-one','name':'Do not retain name'}}],'transitions':[{'name':'triggered','at':iso(st)},{'name':'acknowledged','at':iso(st+dt.timedelta(seconds=60)),'by':'secret-contact@example.test'},{'name':'resolved','at':iso(st+dt.timedelta(seconds=120)),'message':'secret raw description'}]}
 if n==2:r.update(currentPhase='triggered',alertCount=2,transitions=[{'name':'triggered','at':iso(st)}])
 if n==3:r.update(alertCount=1,transitions=[{'name':'triggered','at':iso(st)},{'name':'resolved','at':iso(st+dt.timedelta(seconds=30))}])
 if scenario=='unknown' and n==1:r['transitions'][1]['name']='some-unknown-state'
 return r
if u.path=='/api-public/v1/team/test-team':
 counter=base/(scenario+'-anchors');a=int(counter.read_text()) if counter.exists() else 0;counter.write_text(str(a+1))
 if scenario=='final-denied' and a==1:print('{}\\n403',end='');sys.exit(0)
 out={'slug':'wrong-team' if scenario=='identity' or scenario=='final-identity' and a==1 else 'test-team'}
elif u.path=='/api-reporting/v2/incidents':
 assert q['currentPhase']==['resolved,triggered,acknowledged'] and q['limit']==['100'] and q['startedAfter']==[os.environ['FIXTURE_START']] and q['startedBefore']==[os.environ['FIXTURE_END']]
 counter=base/'history-count';calls=int(counter.read_text()) if counter.exists() else 0;counter.write_text(str(calls+1));offset=int(q['offset'][0]);total=101 if scenario in ['multi','changed','duplicate'] else 3
 if scenario=='changed' and offset:total=102
 rows=[row(n+1) for n in range(offset,min(offset+100,total))]
 if scenario=='duplicate' and offset:rows[0]['incidentNumber']='1'
 if scenario=='short':rows=rows[:-1]
 out={'offset':offset,'limit':100,'total':total,'incidents':rows}
 if scenario=='bad-json':print('{"offset":0,"offset":0}\\n200',end='');sys.exit(0)
 if scenario=='denied':print('{"secret":"never print body"}\\n429',end='');sys.exit(0)
elif u.path=='/api-public/v1/incidents/7':out={'incidentNumber':'7','firstAlertUuid':'11111111-1111-1111-1111-111111111111','lastAlertId':'22222222-2222-2222-2222-222222222222'}
elif u.path=='/api-public/v1/alerts/11111111-1111-1111-1111-111111111111':out={'messageType':'CRITICAL','entityId':'one-condition','stateMessage':'sensitive description','monitoringTool':'Prometheus','entityDisplayName':'private name','apiKey':'hidden-ingestion-key','raw':json.dumps({'service':'api','environment':'qa','owner':'private owner','runbook_url':'https://example.test/private/hidden-ingestion-key','routing_key':'hidden-routing-credential'})}
elif u.path=='/api-reporting/v1/team/test-team/oncall/log':out={'teamSlug':'test-team','start':q['start'][0],'end':q['end'][0],'userLogs':[{'userId':'private-user-id','total':{'hours':8,'minutes':0},'adjustedTotal':{'hours':8,'minutes':0},'log':[{'on':q['start'][0],'off':iso(start+dt.timedelta(hours=8)),'duration':{'hours':8,'minutes':0}}]}]}
else:raise AssertionError('unexpected fixture path')
print(json.dumps(out));print('200',end='')
'''); bins.joinpath('curl').chmod(0o755)
    def run(args, extra=None, okay=True):
        p=subprocess.run(['sh',str(reader),*args],env={**env,**(extra or {})},capture_output=True,text=True)
        assert (p.returncode==0)==okay, (p.returncode,p.stderr)
        return p
    def collect(name,extra=None,opts=(),okay=True):
        p=run(['--start',iso(start),'--end',iso(end),'--state-dir',str(base/name),*opts],extra,okay)
        return json.loads(p.stdout) if p.stdout.strip() else None
    normal=collect('normal',opts=['--context-incident','7','--workload-team','test-team'])
    assert normal['collection']['complete'] and normal['collection']['pages']==1
    assert len(normal['incidents'])==3 and normal['incidents'][1]['phase']=='UNACKED'
    assert normal['incidents'][0]['transitions'][1]['phase']=='ACKED' and normal['incidents'][0]['transitions'][1]['manual'] is None
    encoded=json.dumps(normal)
    for forbidden in ['fixture-key-do-not-emit','hidden-routing-credential','hidden-ingestion-key','private owner','private name','private-user-id','secret-contact','sensitive description','https://','raw"','routingKey']:
        assert forbidden not in encoded, forbidden
    assert normal['context'][0]['raw_fields_present']['runbook'] and not normal['context'][0]['raw_fields_present']['impact']
    assert normal['workload']['users'][0]['reported_total']['hours']==8 and normal['workload']['lag_seconds']==900
    assert '22222222-2222-2222-2222-222222222222' not in base.joinpath('requests').read_text()
    # A completed cache is not a new live observation and cannot be re-dated.
    state_file=base/'normal/state.json'; saved=json.loads(state_file.read_text()); old=iso(date-dt.timedelta(hours=12));saved['snapshot']['generated_at']=old;state_file.write_text(json.dumps(saved))
    requests_before=base.joinpath('requests').read_text()
    reused=collect('normal',opts=['--context-incident','7','--workload-team','test-team'])
    assert reused['generated_at']==old and base.joinpath('requests').read_text()==requests_before
    snapshot=base/'snapshot.json'; snapshot.write_text(encoded)
    before=base.joinpath('requests').read_text()
    summary=json.loads(run(['--summarize',str(snapshot),'--run-date',date.strftime('%Y-%m-%d'),'--target','splunk_oncall'],{'SCOUTFLO_CONFIG':str(base/'no-config'),'TEST_API_ID':'','TEST_API_KEY':''}).stdout)
    assert base.joinpath('requests').read_text()==before
    assert summary['population_incidents']==3 and summary['provider_alert_count']==10 and summary['notification_attempts'] is None
    assert summary['response']['ack_samples']==1 and summary['response']['unacknowledged_or_censored']==2 and summary['response']['mean_ack_seconds_observed_subset']==60
    assert summary['recurrence']['ranked_entities'][0]['incidents']==2 and summary['recovery']['resolved_without_observed_ack']==['3']
    assert summary['workload']['fairness'] is None and summary['recovery']['end_to_end_delivery_proved'] is False
    # The old default resolved-only bug cannot hide an unresolved row.
    assert summary['phase_counts']['UNACKED']==1
    partial=collect('multi',{'SCENARIO':'multi'}); assert not partial['collection']['complete'] and partial['collection']['next_offset']==100
    # Changed credentials cannot resume or cause another request.
    before=base.joinpath('requests').read_text()
    assert collect('multi',{'SCENARIO':'multi','TEST_API_KEY':'different-fixture-key'},okay=False) is None
    assert base.joinpath('requests').read_text()==before
    partial=collect('multi',{'SCENARIO':'multi'}); assert not partial['collection']['complete'] and partial['collection']['next_offset']==101
    complete=collect('multi',{'SCENARIO':'multi'}); assert complete['collection']['complete'] and complete['collection']['pages']==3
    assert any(float(n)>=59 for n in base.joinpath('sleeps').read_text().splitlines()), 'resume did not preserve rate budget'
    changed=collect('changed',{'SCENARIO':'changed'},opts=['--page-budget','3']); assert changed['collection']['status']=='blocked' and changed['collection']['reason']=='changed-cohort'
    duplicate=collect('duplicate',{'SCENARIO':'duplicate'},opts=['--page-budget','3']); assert duplicate['collection']['status']=='blocked' and duplicate['collection']['next_offset']==100
    for scenario in ['short','bad-json','denied']:
        blocked=collect(scenario,{'SCENARIO':scenario},okay=False); assert blocked['collection']['status']=='blocked' and blocked['collection']['expected_total'] is None
    assert collect('identity',{'SCENARIO':'identity'},okay=False) is None
    for scenario in ['final-identity','final-denied']:
        blocked=collect(scenario,{'SCENARIO':scenario},okay=False)
        assert blocked['collection']['status']=='blocked' and not blocked['collection']['complete']
        saved=json.loads((base/scenario/'state.json').read_text());assert saved['final_identity_verified'] is False
        before=base.joinpath('requests').read_text()
        assert collect(scenario,{'SCENARIO':scenario},okay=False) is None
        assert base.joinpath('requests').read_text()==before, 'known failed final identity must not resume as complete'
    unknown=collect('unknown',{'SCENARIO':'unknown'}); snapshot.write_text(json.dumps(unknown))
    un=json.loads(run(['--summarize',str(snapshot)]).stdout); assert un['response']['missing_or_unverified_transitions']==1 and un['response']['ack_samples']==0
    # Reject malformed local projections and stale/wrong-target artifacts even
    # though they look like current measured evidence to a superficial reader.
    for mutate in [lambda x:x.update(raw='secret'),lambda x:x['collection'].update(expected_total=99),lambda x:x['incidents'][0].update(provider_alert_count=-1),lambda x:x['incidents'][0].update(entity_ref='https://example.test/secret')]:
        bad=json.loads(encoded); mutate(bad);snapshot.write_text(json.dumps(bad));run(['--summarize',str(snapshot)],okay=False)
    snapshot.write_text(encoded)
    run(['--summarize',str(snapshot),'--target','splunk_oncall/other'],okay=False)
    run(['--summarize',str(snapshot),'--run-date','2000-01-01'],okay=False)
    future=json.loads(encoded); future['incidents'][0]['transitions'][1]['at']=iso(date+dt.timedelta(days=1));snapshot.write_text(json.dumps(future))
    s=json.loads(run(['--summarize',str(snapshot)]).stdout); assert s['response']['ack_samples']==0 and s['response']['missing_or_unverified_transitions']==1
    for missing in (None,[],[{'phase':'UNACKED','at':normal['incidents'][0]['started_at'],'manual':None}]):
        bad=json.loads(encoded);bad['incidents'][0]['transitions']=missing;snapshot.write_text(json.dumps(bad))
        s=json.loads(run(['--summarize',str(snapshot)]).stdout)
        assert s['response']['missing_or_unverified_transitions']==1 and s['response']['ack_samples']==0
    print('PASS: history privacy, cohort/pagination, resume binding, throttling, lowercase phases, censored response, context, workload and hostile evidence')
PY
