import copy, datetime, json, os, pathlib, re, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]).resolve(); scripts=root/'skills/audit-datadog/scripts'
passes=[]
def check(name,condition):
    assert condition,name
    passes.append(name)
def run(command,env,stdin=None):
    return subprocess.run(command,input=stdin,text=True,capture_output=True,env=env)
def project(mode,value,env,code='200',ct='application/json'):
    return run(['sh',str(scripts/'project-read.sh'),mode],env,json.dumps(value)+'\n'+code+' '+ct)
with tempfile.TemporaryDirectory(prefix='datadog-evidence-') as tmp:
    tmp=pathlib.Path(tmp); home=tmp/'home'; home.mkdir(); bindir=tmp/'bin'; bindir.mkdir()
    cfg=tmp/'toolkit.yaml'; cfg.write_text('datadog:\n  - label: west\n    site: datadoghq.com\n    api_key_env: WEST_API\n    app_key_env: WEST_APP\n  - label: europe\n    site: datadoghq.eu\n    api_key_env: EUROPE_API\n    app_key_env: EUROPE_APP\n')
    store=tmp/'env'; store.write_text('export WEST_API=synthetic-west-api\nexport WEST_APP=synthetic-west-app\nexport EUROPE_API=synthetic-europe-api\nexport EUROPE_APP=synthetic-europe-app\n')
    date=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'); past='2020-01-01T00:00:00Z'
    base={'id':101,'name':'Latency threshold','type':'metric alert','query':'avg(last_5m):avg:system.cpu.user{service:payments,env:prod} > 80','message':'Notify @victorops-unverified-route','draft_status':'published','tags':['service:payments','env:prod'],'created':past,'overall_state':'OK','overall_state_modified':None,'priority':None,'options':{'notify_no_data':False,'silenced':{},'thresholds':{'critical':80},'renotify_interval':0}}
    fixture=tmp/'responses.json'; fixture.write_text(json.dumps({'monitors':[base],'quality':{'monitors':[{'id':101,'quality_issues':[]}],'metadata':{'total_count':1}},'downtimes':{'data':[]},'slos':{'data':[]},'events':{'events':[]},'events-v2':{'data':[],'meta':{}},'synthetics':{'tests':[]},'org':{'orgs':[{'name':'Example'}]},'rules':{'data':[]},'policies':{'data':[]},'estimated':{'data':[]},'top':{'usage':[]}}))
    log=tmp/'calls.jsonl'
    (bindir/'curl').write_text('''#!/usr/bin/env python3
import json,os,sys,urllib.parse
args=sys.argv[1:]
if args==['--version']: print('curl 8.12.0 test');sys.exit(0)
url=args[-1]; p=urllib.parse.urlsplit(url); q=urllib.parse.parse_qs(p.query)
d=json.load(open(os.environ['DD_TEST_FIXTURE']))
with open(os.environ['DD_TEST_CALLS'],'a') as f:f.write(json.dumps({'url':url,'headers':[args[i+1] for i,x in enumerate(args[:-1]) if x=='-H']})+'\\n')
if os.environ.get('DD_TEST_DENIED'):
 print('raw-error-token-MUST-NOT-LEAK');print('403 text/html');sys.exit(0)
path=p.path
if path=='/api/v1/validate':out={'valid':True}
elif path=='/api/v1/monitor':out=d['monitors']
elif path=='/api/v1/monitor/search':out=d['quality']
elif path=='/api/v2/downtime':out=d['downtimes']
elif path=='/api/v1/slo':out=d['slos']
elif path=='/api/v1/events':out=d['events']
elif path=='/api/v2/events/search':out=d['events-v2']
elif path=='/api/v1/synthetics/tests':out=d['synthetics']
elif path=='/api/v1/org':out=d['org']
elif path=='/api/v2/monitor/notification_rule':out=d['rules']
elif path=='/api/v2/monitor/policy':out=d['policies']
elif path=='/api/v2/usage/estimated_cost':out=d['estimated']
elif path=='/api/v1/usage/top_avg_metrics':out=d['top']
else:print('unknown test path');print('404 application/json');sys.exit(0)
print(json.dumps(out));print('200 application/json')
'''); (bindir/'curl').chmod(0o755)
    intent=tmp/'intent.json'; intent.write_text(json.dumps({'declared_by':'operator','evidence_ref':'approved-requirements','critical_services':['payments'],'missing_data_required_monitor_ids':[]}))
    env=dict(os.environ,HOME=str(home),PATH=str(bindir)+os.pathsep+os.environ['PATH'],CLAUDE_PLUGIN_ROOT=str(root),SCOUTFLO_CONFIG=str(cfg),SCOUTFLO_ENV_FILE=str(store),SCOUTFLO_TARGET='europe',SCOUTFLO_AUDIT_DIR=str(tmp/'audits'),SCOUTFLO_DATADOG_COVERAGE_INTENT=str(intent),DD_TEST_FIXTURE=str(fixture),DD_TEST_CALLS=str(log))
    for k in ('DATADOG_API_KEY','DATADOG_APP_KEY','WEST_API','WEST_APP','EUROPE_API','EUROPE_APP'): env.pop(k,None)
    inv=run(['sh',str(scripts/'inventory.sh')],env)
    check('full fixed inventory succeeds',inv.returncode==0)
    raw=tmp/'audits/datadog/europe'/date/'raw'
    calls=[json.loads(x) for x in log.read_text().splitlines()]
    check('every request uses selected EU site',all(x['url'].startswith('https://api.datadoghq.eu/') for x in calls))
    check('every request uses selected credential pair',all('DD-API-KEY: synthetic-europe-api' in x['headers'] and 'DD-APPLICATION-KEY: synthetic-europe-app' in x['headers'] for x in calls))
    check('selected output nested; no flat collision',raw.is_dir() and not (tmp/'audits/datadog'/date).exists())
    safe=json.loads((raw/'monitors.json').read_text())[0]
    check('ordinary metric false notify flag preserved',safe['options']['notify_no_data'] is False)
    check('safe metric query semantics retained',safe['query']==base['query'] and safe['query_state']=='observed')
    cov=run(['sh',str(scripts/'coverage.sh')],env); check('coverage recipe succeeds',cov.returncode==0)
    row=json.loads(cov.stdout)[0]
    check('unresolved VictorOps never proves human delivery',row['human_delivery']=='unverified' and row['end_to_end'] is False and row['unverified_destination_monitors']==1 and 'effective_monitors' not in row)
    check('ordinary notify_no_data=false not discarded',row['source_eligible_monitors']==1)
    declared=json.loads(intent.read_text()); declared['missing_data_required_monitor_ids']=[101]; intent.write_text(json.dumps(declared))
    cov=run(['sh',str(scripts/'coverage.sh')],env); row=json.loads(cov.stdout)[0]
    check('explicit heartbeat requirement excludes false flag',row['source_eligible_monitors']==0 and any('declared-missing-data-notification-required' in x['reasons'] for x in row['excluded']))
    declared['missing_data_required_monitor_ids']=[]; intent.write_text(json.dumps(declared))
    packet=json.loads((raw/'source-routing-evidence.json').read_text()); receipt=json.loads((raw/'source-routing-capture.json').read_text())
    check('source packet never upgrades handle mapping',packet['source_target']=='datadog/europe' and packet['records'][0]['route_env'] is None and packet['records'][0]['route_verification']=='candidate')
    import hashlib
    check('source capture receipt binds canonical records',receipt['records_sha256']==hashlib.sha256(json.dumps(packet['records'],sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()).hexdigest())
    bound=run(['sh',str(root/'skills/audit-splunk-oncall/scripts/source-evidence.sh'),'source-vars',str(raw/'source-routing-evidence.json')],env)
    check('real On-Call binder accepts candidate source receipt without vars',bound.returncode==0 and not bound.stdout.strip())
    # Assignment-only stores are valid; generation changes cannot reuse old evidence.
    original_store=store.read_text(); store.write_text(original_store.replace('export ',''))
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('assignment-only store resolves selected credentials',r.returncode==0)
    store.write_text(original_store.replace('synthetic-europe-api','synthetic-second-org-api'))
    before=log.read_text()
    for consumer in ('coverage.sh','source-evidence.sh','export-inventory.sh'):
        r=run(['sh',str(scripts/consumer)],env)
        check('credential rotation invalidates '+consumer,r.returncode!=0 and log.read_text()==before)
    meta=(raw/'monitors.json.capture.json').read_text()
    check('binding stores keyed generation only','synthetic-' not in meta and len(json.loads(meta)['credential_generation'])==64)
    store.write_text(original_store)
    invobj=json.loads((raw.parent/'inventory.json').read_text())
    check('canonical collection stays partial for unreconciled catalog totals',invobj['collection']['status']=='partial' and invobj['collection']['scope']=='subset' and invobj['counts']['total']==len(invobj['items']))
    check('unqualified service tag never supplies active cross-tool proof',all('service_identity' not in x and x.get('enabled') is not True for x in invobj['items']))
    compatible=run(['sh',str(root/'report-standard/check-correlation-evidence.sh'),str(raw.parent/'inventory.json')],env)
    check('canonical inventory collection passes shared validator',compatible.returncode==0)
    # Distinct observed handles are independently addressable source paths.
    two=copy.deepcopy(base); two['message']='@victorops-team-a @victorops-team-b'
    responses=json.loads(fixture.read_text()); responses['monitors']=[two]; fixture.write_text(json.dumps(responses))
    r=run(['sh',str(scripts/'inventory.sh')],env)
    packet=json.loads((raw/'source-routing-evidence.json').read_text())
    check('two paging handles export two stable candidate records',r.returncode==0 and len(packet['records'])==2 and len({v['record_id'] for v in packet['records']})==2 and all(len(v['definition']['notification_handles'])==1 and v['route_verification']=='candidate' for v in packet['records']))
    bound=run(['sh',str(root/'skills/audit-splunk-oncall/scripts/source-evidence.sh'),'source-vars',str(raw/'source-routing-evidence.json')],env)
    check('real On-Call binder accepts both distinct candidate paths',bound.returncode==0 and not bound.stdout.strip())
    responses['monitors']=[base]; fixture.write_text(json.dumps(responses))
    # The selected named pair cannot fall back to populated default credentials.
    missing=dict(env,DATADOG_API_KEY='ambient-wrong-api',DATADOG_APP_KEY='ambient-wrong-app')
    store.write_text('export WEST_API=synthetic-west-api\nexport WEST_APP=synthetic-west-app\n')
    before=log.read_text(); r=run(['sh',str(scripts/'inventory.sh')],missing)
    check('missing selected credentials fail before any call',r.returncode!=0 and log.read_text()==before)
    store.write_text('export WEST_API=synthetic-west-api\nexport WEST_APP=synthetic-west-app\nexport EUROPE_API=synthetic-europe-api\nexport EUROPE_APP=synthetic-europe-app\n')
    for label in ('absent',''):
        before=log.read_text(); r=run(['sh',str(scripts/'inventory.sh')],dict(env,SCOUTFLO_TARGET=label))
        check('missing/unknown label cannot choose first: '+repr(label),r.returncode!=0 and log.read_text()==before)
    # Error and unsupported content cannot become empty successful captures.
    r=run(['sh',str(scripts/'inventory.sh')],dict(env,DD_TEST_DENIED='1'))
    check('raw error body never printed or retained',r.returncode!=0 and 'raw-error-token' not in r.stdout+r.stderr and not (raw/'monitors.json').exists())
    for mode,value in [('monitors',{'error':'secret'}),('monitors',[]),('validate',{'valid':True})]:
        r=project(mode,value,env,ct='text/html')
        check('HTML fails before publication: '+mode+str(type(value)),r.returncode!=0 and not r.stdout)
    # Secrets appear in free text, query literals, nested names, scopes and URL paths.
    probes=['X-VO-Api-Key: PRIVATE_SENTINEL','x-vo-api-id=PRIVATE_SENTINEL','https://alert.victorops.com/integrations/generic/20131114/alert/PRIVATE_SENTINEL/route','https:\\/\\/alert.victorops.com\\/integrations\\/generic\\/20131114\\/alert\\/PRIVATE_SENTINEL','--token=PRIVATE_SENTINEL']
    for n,probe in enumerate(probes):
        v=copy.deepcopy(base); v.update(message='@victorops-safe '+probe,name=probe,query='avg(last_5m):avg:metric{api_key:PRIVATE_SENTINEL} > 1',tags=['service:payments',probe]); v['options']['silenced']={probe:0}
        r=project('monitors',[v],env); check('secret-shaped fields projected before output '+str(n),r.returncode==0 and 'PRIVATE_SENTINEL' not in r.stdout+r.stderr)
        out=json.loads(r.stdout)[0]; check('omitted query is explicit '+str(n),out['query'] is None and out['query_state']=='omitted')
    conditional=copy.deepcopy(base); conditional['message']='{{#is_recovery}} @victorops-qa {{/is_recovery}}'
    r=project('monitors',[conditional],env)
    check('conditional handle cannot establish alert eligibility',r.returncode==0 and json.loads(r.stdout)[0]['handles_complete'] is False)
    invalid=copy.deepcopy(base); invalid['options']['notify_no_data']='false'
    r=project('monitors',[invalid],env)
    check('wrong boolean shape blocks instead of coercing',r.returncode!=0 and not r.stdout)
    # Arbitrary log text never passes as a supported numeric metric query.
    v=copy.deepcopy(base); v.update(type='log alert',query='logs("arbitrary PRIVATE_SENTINEL").index("*") > 0')
    r=project('monitors',[v],env); check('unsupported query body omitted',r.returncode==0 and 'PRIVATE_SENTINEL' not in r.stdout and json.loads(r.stdout)[0]['query_state']=='omitted')
    # Restore complete captured fixture then execute every reference fence in a fresh shell.
    r=run(['sh',str(scripts/'inventory.sh')],env); check('fresh inventory restores failed evidence',r.returncode==0)
    doc=(root/'skills/audit-datadog/references/datadog-checks.md').read_text()
    for i,b in enumerate(re.findall(r'```bash\n(.*?)\n```',doc,re.S)):
        r=run(['bash','-c',b],env)
        check('reference fresh-shell block '+str(i),r.returncode==0)
    # Doctor, identity, sizing and scope checkpoint are stateless too; report-writing
    # fences use canonical report validators tested by their owning suites.
    main=(root/'skills/audit-datadog/SKILL.md').read_text()
    for i,b in enumerate(re.findall(r'```bash\n(.*?)\n```',main,re.S)[:4]):
        r=run(['bash','-c',b],env)
        check('main fresh-shell preflight block '+str(i),r.returncode==0)
    # Replay suppression/intent false positives through the real collector and fences.
    fences=re.findall(r'```bash\n(.*?)\n```',doc,re.S)
    mute_fence=next(x for x in fences if '# DD-020:' in x)
    decay_fence=next(x for x in fences if 'DOWNTIME_DECAY_DAYS=' in x)
    threshold_fence=next(x for x in fences if '# DD-019:' in x)
    dt={'id':'downtime-1','attributes':{'scope':['env:prod'],'status':'active','schedule':{'start':past,'end':None},'monitor_identifier':{'monitor_id':101},'message':'Permanent approved maintenance policy','created':past}}
    for label,scope in [('redacted',['token:PRIVATE_SENTINEL']),('missing',None),('wrong-type',{}),('empty',[])]:
        d=copy.deepcopy(dt); d['attributes']['scope']=scope
        responses=json.loads(fixture.read_text()); responses['downtimes']={'data':[d]}; fixture.write_text(json.dumps(responses))
        r=run(['sh',str(scripts/'inventory.sh')],env); cov=run(['sh',str(scripts/'coverage.sh')],env)
        row=json.loads(cov.stdout)[0]
        check('unknown downtime scope never becomes suppression '+label,r.returncode==0 and row['source_eligibility_unknown_ids']==[101] and not row['excluded'])
        r=run(['bash','-c',mute_fence],env)
        check('DD020/021 fence blocks unknown scope '+label,r.returncode==0 and 'silenced_monitor_count' not in r.stdout and 'blocked' in r.stdout and 'PRIVATE_SENTINEL' not in r.stdout)
    for until in ['secret=PRIVATE_SENTINEL','not-an-epoch',False,{},-1]:
        v=copy.deepcopy(base); v['options']['silenced']={'*':until}
        responses['monitors']=[v]; responses['downtimes']={'data':[]}; fixture.write_text(json.dumps(responses))
        r=run(['sh',str(scripts/'inventory.sh')],env); cov=run(['sh',str(scripts/'coverage.sh')],env)
        row=json.loads(cov.stdout)[0]
        check('invalid silenced timestamp stays unknown '+repr(until),r.returncode==0 and row['source_eligibility_unknown_ids']==[101] and not row['excluded'])
        r=run(['bash','-c',mute_fence],env)
        check('DD020 fence never invents indefinite mute '+repr(until),r.returncode==0 and 'muted_scopes' not in r.stdout and 'blocked' in r.stdout and 'PRIVATE_SENTINEL' not in r.stdout)
    responses['monitors']=[base]; responses['downtimes']={'data':[dt]}; fixture.write_text(json.dumps(responses))
    run(['sh',str(scripts/'inventory.sh')],env)
    r=run(['bash','-c',decay_fence],env)
    check('permanent maintenance never becomes temporary intent',r.returncode==0 and 'review-candidate' not in r.stdout)
    dt['attributes']['message']='temporary test downtime, safe to delete'; responses['downtimes']={'data':[dt]}; fixture.write_text(json.dumps(responses))
    run(['sh',str(scripts/'inventory.sh')],env)
    r=run(['bash','-c',decay_fence],env)
    check('actual temporary wording yields review candidate',r.returncode==0 and 'review-candidate' in r.stdout)
    r=run(['bash','-c',decay_fence],dict(env,DOWNTIME_DECAY_DAYS='10000'))
    check('DD023 custom decay days affect actual fence',r.returncode==0 and 'review-candidate' not in r.stdout)
    dt['attributes']['message']='WIP revert me'; responses['downtimes']={'data':[dt]}; fixture.write_text(json.dumps(responses))
    custom=dict(env,SCOUTFLO_DATADOG_TEMPORARY_WORDS='WIP|revert me')
    run(['sh',str(scripts/'inventory.sh')],custom); r=run(['bash','-c',decay_fence],custom)
    check('custom intent terms evaluated at capture not invented',r.returncode==0 and 'review-candidate' in r.stdout and 'WIP' in r.stdout)
    proof=tmp/'lower-bound.json'
    for comparator in ('> 0','>= 0','> -1'):
        v=copy.deepcopy(base); v['query']='avg(last_5m):avg:system.cpu.user{service:payments} '+comparator
        responses['monitors']=[v]; responses['downtimes']={'data':[]}; fixture.write_text(json.dumps(responses))
        run(['sh',str(scripts/'inventory.sh')],env)
        r=run(['bash','-c',threshold_fence],env)
        check('name heuristic alone never proves tautology '+comparator,r.returncode==0 and '"assessment": "fail"' not in r.stdout)
        proof.write_text(json.dumps([{'monitor_id':101,'query_sha256':hashlib.sha256(v['query'].encode()).hexdigest(),'lower_bound':0,'declared_by':'operator','evidence_ref':'metric-domain-proof'}]))
        r=run(['bash','-c',threshold_fence],dict(env,SCOUTFLO_DATADOG_NONNEGATIVE_EVIDENCE=str(proof)))
        check('strict-positive distinction with domain proof '+comparator,r.returncode==0 and (('"assessment": "fail"' in r.stdout)==(comparator!='> 0')))
    responses['monitors']=[base]; responses['downtimes']={'data':[]}; fixture.write_text(json.dumps(responses))
    run(['sh',str(scripts/'inventory.sh')],env)
    # APIv2 group scope is a search string; simple conjunctions retain only safe terms.
    for scope,expected,state in [('*',['*'],'observed'),('env:prod',['env:prod'],'observed'),('env:prod AND team:core',['env:prod','team:core'],'observed'),('env:(staging OR prod)',[],'omitted'),('',[],'omitted')]:
        d=copy.deepcopy(dt);d['attributes']['scope']=scope
        projected=project('downtimes',{'data':[d]},env);item=json.loads(projected.stdout)[0]
        check('v2 group scope projection '+repr(scope),projected.returncode==0 and item['scope']==expected and item['scope_state']==state)
    # Exact active-window and monitor-identifier semantics change source eligibility.
    observed=json.loads((raw/'monitors.json').read_text())
    observed[0]['options']['silenced']={'*':1}
    (raw/'monitors.json').write_text(json.dumps(observed))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp monitors.json'],env)
    current={'scope_state':'observed','schedule_state':'observed','identifier_state':'observed','id':'dt-1','scope':['env:prod'],'status':'scheduled','start':'2099-01-01T00:00:00Z','end':None,'monitor_identifier':{'monitor_id':101,'monitor_tags':[]}}
    (raw/'downtimes.json').write_text(json.dumps([current]))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp downtimes.json'],env)
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('expired mute and future downtime do not suppress',r.returncode==0 and json.loads(r.stdout)[0]['source_eligible_monitors']==1)
    current.update(status='active',start=past)
    (raw/'downtimes.json').write_text(json.dumps([current]))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp downtimes.json'],env)
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('matching monitor tags cannot prove whole-monitor group suppression',r.returncode==0 and json.loads(r.stdout)[0]['source_eligibility_unknown_ids']==[101] and not json.loads(r.stdout)[0]['excluded'])
    group=run(['bash','-c',mute_fence],env)
    check('scoped group blast radius remains blocked, never zero or full monitor count',group.returncode==0 and 'group-level suppression' in group.stdout and 'silenced_monitor_count' not in group.stdout)
    current['scope']=['*']
    current['monitor_identifier']['monitor_id']='101'
    (raw/'downtimes.json').write_text(json.dumps([current]))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp downtimes.json'],env)
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('string downtime ID matches numeric monitor ID',r.returncode==0 and any('active-suppression' in x['reasons'] for x in json.loads(r.stdout)[0]['excluded']))
    r=run(['bash','-c',mute_fence],env)
    check('DD021 fence normalizes accepted ID primitive types',r.returncode==0 and '"silenced_monitor_count": 1' in r.stdout)
    current['monitor_identifier']['monitor_id']=999
    (raw/'downtimes.json').write_text(json.dumps([current]))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp downtimes.json'],env)
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('scope alone cannot suppress another monitor',r.returncode==0 and json.loads(r.stdout)[0]['source_eligible_monitors']==1)
    observed=json.loads((raw/'monitors.json').read_text());observed[0]['options']['silenced']={'env:prod':0}
    (raw/'monitors.json').write_text(json.dumps(observed))
    run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/audit-datadog/scripts/datadog-context.sh"; dd_stamp monitors.json'],env)
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('legacy group mute is not whole-monitor suppression despite matching tags',r.returncode==0 and json.loads(r.stdout)[0]['source_eligibility_unknown_ids']==[101] and not json.loads(r.stdout)[0]['excluded'])
    # Same IDs on a second site must produce a distinct target-bound evidence file.
    r=run(['sh',str(scripts/'inventory.sh')],dict(env,SCOUTFLO_TARGET='west'))
    check('overlapping IDs stay target-separated',r.returncode==0 and (tmp/'audits/datadog/west'/date/'raw/monitors.json').exists() and raw.exists())
    # Mutations prove the behavioral assertions detect the original defect classes.
    altered=tmp/'coverage-mutant.sh'
    body=(scripts/'coverage.sh').read_text()
    altered.write_text(body.replace("str(v['id']) in {str(x) for x in heartbeat}","True"))
    r=run(['sh',str(altered)],env)
    check('mutation: blanket no-data exclusion is caught',r.returncode==0 and json.loads(r.stdout)[0]['source_eligible_monitors']!=1)
    altered.write_text(body.replace("'human_delivery':'unverified'","'human_delivery':'verified'"))
    r=run(['sh',str(altered)],env)
    check('mutation: inferred human delivery is caught',r.returncode==0 and json.loads(r.stdout)[0]['human_delivery']!='unverified')
    # Deliberate tiers and unavailable transition metadata remain observations.
    saved_responses=copy.deepcopy(json.loads(fixture.read_text()))
    fast=copy.deepcopy(base); fast['query']='avg(last_5m):avg:system.cpu.user{service:payments,env:prod} > 80'
    slow=copy.deepcopy(base); slow.update(id=102,name='Deliberate slow critical tier',query='avg(last_15m):avg:system.cpu.user{service:payments,env:prod} > 95')
    no_data=copy.deepcopy(base); no_data.update(id=103,name='Observed No Data',overall_state='No Data',overall_state_modified=None,query='avg(last_5m):avg:custom.queue.depth{service:payments,env:prod} > 2')
    responses=copy.deepcopy(saved_responses); responses['monitors']=[fast,slow,no_data]; responses['quality']={'monitors':[{'id':v['id'],'quality_issues':[]} for v in responses['monitors']],'metadata':{'total_count':3}}; responses['downtimes']={'data':[]}; fixture.write_text(json.dumps(responses))
    r=run(['sh',str(scripts/'inventory.sh')],env); check('tier and No Data observations capture',r.returncode==0)
    observation_fence=next(x for x in fences if '# DD-036:' in x)
    def stream(text):
        values=[]; decoder=json.JSONDecoder(); text=text.strip()
        while text:
            obj,n=decoder.raw_decode(text); values.append(obj); text=text[n:].strip()
        return values
    r=run(['bash','-c',observation_fence],env); values=stream(r.stdout)
    overlap=values[1][0]; no_transition=values[2][0]
    check('legitimate window/threshold overlap never fails automatically',r.returncode==0 and overlap['monitor_ids']==[101,102] and overlap['assessment']=='review-candidate' and overlap['intent']=='unverified' and len(set(overlap['queries']))==2)
    check('null transition does not imply no evaluations',no_transition['id']==103 and no_transition['assessment']=='review-candidate' and no_transition['observed_state']=='No Data' and no_transition['evaluation_history']=='unverified' and no_transition['transition_metadata']=='null-or-omitted')
    r=run(['bash','-c',observation_fence],dict(env,NO_TRANSITION_DAYS='10000'))
    check('No Data review age changes actual selector',r.returncode==0 and stream(r.stdout)[2]==[])
    r=run(['bash','-c',observation_fence],dict(env,NEVER_EVALUATED_DAYS='10000'))
    check('legacy No Data age alias remains effective',r.returncode==0 and stream(r.stdout)[2]==[])
    no_data['created']=None; responses['monitors']=[fast,slow,no_data]; fixture.write_text(json.dumps(responses))
    run(['sh',str(scripts/'inventory.sh')],env); r=run(['bash','-c',observation_fence],env)
    check('missing No Data creation time stays blocked',r.returncode==0 and stream(r.stdout)[2][0]['assessment']=='blocked')
    fixture.write_text(json.dumps(saved_responses)); run(['sh',str(scripts/'inventory.sh')],env)
    # Worklist claims survive interruption; evidence is mandatory and tamper-bound.
    wl=scripts/'assessment-worklist.sh'; large=dict(env,MEDIUM_MAX_OBJECTS='0')
    r=run(['sh',str(wl),'check'],large); check('large assessment requires actual worklist',r.returncode!=0)
    run(['sh',str(wl),'init'],large)
    first=run(['sh',str(wl),'claim','1'],large); second=run(['sh',str(wl),'claim','1'],large)
    check('interrupted assessment resumes exact claimed batch',first.returncode==0 and first.stdout==second.stdout and json.loads(first.stdout)['monitor_ids']==['101'])
    r=run(['sh',str(wl),'done',str(raw/'absent.json')],large); check('missing assessment evidence cannot mark done',r.returncode!=0)
    batch=raw/'assessment-batch.json'; batch.write_text(json.dumps({'monitor_ids':['101'],'checks':[{'id':'DD-033','result':'blocked'}]}))
    r=run(['sh',str(wl),'done',str(batch)],large)
    check('completed assessment unblocks report gate',r.returncode==0 and run(['sh',str(wl),'check'],large).returncode==0)
    batch.write_text('{}'); check('tampered assessment proof invalidates completion',run(['sh',str(wl),'check'],large).returncode!=0)
    # History resolution needs current same-ID passing evidence, not mere disappearance.
    out=raw.parent; previous=out.parent/'2020-01-01'; previous.mkdir(exist_ok=True)
    previous.joinpath('findings.json').write_text(json.dumps({'target':'datadog/europe','findings':[{'id':'DD-001'},{'id':'DD-002'}]}))
    current={'target':'datadog/europe','score':{'overall':75,'state':'assessed','scoring_model':'v2','check_set':'synthetic','assessment':{'coverage_percent':50},'gate':False,'end_to_end':False},'severity_counts':{},'checks':[{'id':'DD-001','result':'pass'},{'id':'DD-002','result':'blocked'}],'findings':[]}
    out.joinpath('findings.json').write_text(json.dumps(current))
    r=run(['sh',str(scripts/'history.sh')],env)
    history=[json.loads(x) for x in (out.parent/'history.jsonl').read_text().splitlines()]
    check('history resolves only demonstrated passing check',r.returncode==0 and history[-1]['lifecycle_counts']['resolved']==1)
    run(['sh',str(scripts/'history.sh')],env)
    check('same-day history is replaced instead of duplicated',len((out.parent/'history.jsonl').read_text().splitlines())==1)
    # Site/date/digest receipt prevents reusing a file moved from another target.
    data=(raw/'monitors.json').read_bytes(); (raw/'monitors.json').write_bytes(data+b' ')
    r=run(['sh',str(scripts/'coverage.sh')],env)
    check('modified evidence cannot retain verified status',r.returncode!=0)
    cfg.write_text('datadog:\n  site: datadoghq.eu\n  api_key_env: EUROPE_API\n  app_key_env: EUROPE_APP\n')
    r=run(['sh',str(scripts/'inventory.sh')],env)
    check('legacy single-target remains flat on configured site',r.returncode==0 and (tmp/'audits/datadog'/date/'raw/monitors.json').exists())
print('Datadog evidence regressions: '+str(len(passes))+' passed')
for item in passes: print('PASS '+item)
