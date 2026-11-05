#!/bin/sh
# Run the exact one-shot recipe. Fixtures are synthetic, bounded, and offline.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import copy,datetime as dt,hashlib,json,os,pathlib,subprocess,sys,tempfile
root=pathlib.Path(sys.argv[1]); doc=(root/'skills/audit-splunk-oncall/references/effective-quality.md').read_text()
block=doc.split('<!-- oncall-effective-quality:start -->')[1].split('<!-- oncall-effective-quality:end -->')[0].split('```bash\n')[1].rsplit('```',1)[0]
now=dt.datetime.now(dt.timezone.utc).replace(microsecond=0); start=now+dt.timedelta(days=1); end=start+dt.timedelta(days=2)
def iso(x):return x.isoformat().replace('+00:00','Z')
def col(data):return {'status':'collected','data':data}
base={'credential_binding':{'api_id_env':'TEST_ID','api_key_env':'TEST_KEY','fingerprint':'1'*64},'target':'splunk_oncall','scope':'account','complete_reads':True,'started_at':iso(now),'finished_at':iso(now),'teams':[{'slug':'team-one'}],'policies':[{'slug':'policy-one','team':'team-one'},{'slug':'policy-two','team':'team-one'}],'routes':[{'alias':'route-1','policies':['policy-one']},{'alias':'route-2','policies':['policy-two']}],'policy_details':[{'slug':'policy-one','ignore_custom_paging':True,'steps':[{'timeout':0,'entries':[{'type':'user','user':'user-one'}]}]},{'slug':'policy-two','ignore_custom_paging':True,'steps':[{'timeout':0,'entries':[{'type':'user','user':'user-two'}]}]}],'current':[{'policy':'policy-one','team':'team-one','users':['user-one']}],'team_details':[{'team':'team-one','members':[{'username':'user-one','verified':True},{'username':'user-two','verified':True}],'groups':[{'slug':'rotation-one','groupId':1,'teamSlug':'team-one'}],'rotations':[{'groupId':1,'shifts':[{'shiftId':1,'shifttype':'std','timezone':'UTC','members':['user-one','user-two'],'current_user':'user-one','next_user':'user-two','current_period':{'start':iso(now),'end':iso(start),'username':'user-one'},'periods':[{'start':iso(now-dt.timedelta(days=1)),'end':iso(now),'username':'user-two'}]}]}]}]}
steps=[{'index':0,'timeout':5,'rules':[{'index':0,'channel':'email','contact_id':1,'contact_type':'email'}]}]
base['quality']={'schema':'scoutflo-oncall-quality/v1','selected_users':[{'user':'user-one','primary':col(steps),'personal':col([{'slug':'primary-one','rank':0,'steps':steps}]),'contacts':col([{'id':1,'kind':'email','verified':True}])}],'maintenance':col([]),'transformations':col([]),'team_admins':[dict(col(['user-one']),team='team-one')],'overrides':col([]),'schedules':[dict(col({'team':'team-one','policies':[{'policy':'policy-one','entries':[{'type':'user','user':'user-one','rolls':[{'start':iso(start),'end':iso(end),'user':'user-one'}]}],'overrides':[]}]}),team='team-one',step=0,days_forward=14,days_skip=0)]}
count=0
with tempfile.TemporaryDirectory(prefix='oncall-effective-') as tmp:
    work=pathlib.Path(tmp); recipe=work/'recipe.sh';recipe.write_text(block)
    subprocess.run(['sh','-n',str(recipe)],check=True)
    def basis(s):
        d={k:s.get(k) for k in ('target','scope','credential_binding','routing_definition_fingerprint','teams','policies','routes','current','policy_details','team_details','quality')}
        return hashlib.sha256(json.dumps(d,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    def run(name,check,expected,change=lambda s:None,att=None,extra=None,proof_change=None):
        global count
        s=copy.deepcopy(base);change(s);snapshot=work/'snapshot.json';snapshot.write_text(json.dumps(s))
        env={k:v for k,v in os.environ.items() if not k.startswith('SCOUTFLO_')}
        env.update(SCOUTFLO_ONCALL_SNAPSHOT=str(snapshot),SCOUTFLO_VERIFY_CHECK=check,SCOUTFLO_VERIFY_POLICY='policy-one',SCOUTFLO_VERIFY_TEAM='team-one',SCOUTFLO_ONCALL_HORIZON_START=iso(start),SCOUTFLO_ONCALL_HORIZON_END=iso(end))
        if extra:env.update(extra)
        if att is not None:
            proof={'schema':'scoutflo-oncall-quality-attended/v1','target':s['target'],'definition_sha256':basis(s),'observed_at':iso(now),'verified':True,'evidence_ref':'local-safe-receipt',**copy.deepcopy(att)}
            if proof_change:proof_change(proof)
            f=work/'attended.json';f.write_text(json.dumps(proof));env['SCOUTFLO_ONCALL_ATTENDED_EVIDENCE']=str(f)
        result=subprocess.run(['sh',str(recipe)],env=env,capture_output=True,text=True)
        try: out=json.loads(result.stdout)
        except ValueError:raise AssertionError((name,result.returncode,result.stdout,result.stderr))
        assert result.returncode==expected,(name,expected,result.returncode,out,result.stderr)
        assert out.get('status')=={0:'verified',1:'not-met',2:'blocked',3:'inapplicable'}[expected],(name,out)
        assert 'private-route-canary' not in result.stdout and 'private-contact-canary' not in result.stdout,name
        count+=1; return out
    def mutate_delay(s):s['policy_details'][0]['steps']=[{'timeout':4,'entries':[]},{'timeout':6,'entries':[{'type':'policy_routing','policy':'policy-two'}]}]
    r=run('delayed nested path','SOC-003',0,mutate_delay); assert r['evidence']['first_human_minutes']==10
    run('declared short objective','SOC-003',1,mutate_delay,extra={'SCOUTFLO_ONCALL_MAX_ESCALATION_MINUTES':'5'})
    run('intentional waiting room','SOC-003',0,mutate_delay,extra={'SCOUTFLO_ONCALL_MAX_ESCALATION_MINUTES':'15'})
    def cycle(s):s['policy_details'][0]['steps'][0]['entries']=[{'type':'policy_routing','policy':'policy-two'}];s['policy_details'][1]['steps'][0]['entries']=[{'type':'policy_routing','policy':'policy-one'}]
    def nested_team(s,team='team-one'):s['policy_details'][0]['steps'][0]['entries']=[{'type':'policy_routing','policy':'policy-two','policy_team':team}]
    r=run('nested returned team agrees with census','SOC-003',0,nested_team);assert r['evidence']['ordered_terminals'][0]['nested_ownership'][0]['basis']=='returned-team-and-census'
    run('nested returned team conflicts with census','SOC-003',2,lambda s:nested_team(s,'other-team'))
    run('nested cycle','SOC-003',1,cycle)
    run('dangling nested edge','SOC-003',1,lambda s:s['policy_details'][0]['steps'][0].update(entries=[{'type':'policy_routing','policy':'missing-policy'}]))
    run('unknown entry union','SOC-003',2,lambda s:s['policy_details'][0]['steps'][0].update(entries=[{'type':'future-target'}]))
    run('external-only is not human','SOC-003',2,lambda s:s['policy_details'][0]['steps'][0].update(entries=[{'type':'webhook','destination_present':True}]))
    def rotation(s,kind='rotation_group'):s['policy_details'][0]['steps'][0]['entries']=[{'type':kind,'rotation':'rotation-one'}]
    def no_staff(s):
        rotation(s);s['team_details'][0]['rotations'][0]['shifts'][0].update(members=[],current_user=None,next_user=None)
    run('rotation objects without staff cannot pass','SOC-003',1,no_staff)
    run('next member observed','SOC-003',0,lambda s:rotation(s,'rotation_group_next'))
    run('previous observed period','SOC-003',0,lambda s:rotation(s,'rotation_group_previous'))
    def previous_missing(s):rotation(s,'rotation_group_previous');s['team_details'][0]['rotations'][0]['shifts'][0]['periods']=[]
    run('previous not guessed from roster','SOC-003',2,previous_missing)
    def custom(s):rotation(s);s['team_details'][0]['rotations'][0]['shifts'][0]['shifttype']='cstm'
    run('custom shift membership','SOC-004',0,custom)
    run('delayed path cannot replace now','SOC-005',2,lambda s:s['policy_details'][0]['steps'][0].update(timeout=5))
    run('omitted current row is unverified visibility','SOC-005',2,lambda s:s.update(current=[]))
    run('explicit empty current row is observed absence','SOC-005',1,lambda s:s['current'][0].update(users=[]))
    run('wrong owner with empty current responders is identity uncertainty','SOC-005',2,lambda s:s['current'][0].update(team='other-team',users=[]))
    run('wrong owner with populated current responders is identity uncertainty','SOC-005',2,lambda s:s['current'][0].update(team='other-team'))
    run('declared no redundancy','SOC-006',3,extra={'SCOUTFLO_VERIFY_MIN_RESPONDERS':'none'})
    run('one actual person below two','SOC-006',1,extra={'SCOUTFLO_VERIFY_MIN_RESPONDERS':'2'})
    gp={'global_paging':{'enforced':False,'propagation_complete':True}}
    def bad_fallback(s):s['quality']['selected_users'][0]['primary']['data'].append({'index':1,'timeout':5,'rules':[{'channel':'sms','contact_id':99,'contact_type':'phone'}]})
    run('healthy first notification cannot mask dead fallback','SOC-009',1,bad_fallback,att=gp)
    run('unknown custom precedence cannot pass','SOC-009',2,lambda s:s['policy_details'][0].update(ignore_custom_paging=None),att=gp)
    def inactive_single(s):
        s['policy_details'][0]['ignore_custom_paging']=False
        s['quality']['selected_users'][0]['personal']['data'][0].update(rank=1,time_mask={**{k:False for k in ('sunday','monday','tuesday','wednesday','thursday','friday','saturday')},'timeZone':'UTC','startTime':'00:00','endTime':'00:01'})
    run('single inactive custom policy is not effective proof','SOC-009',2,inactive_single,att=gp)
    run('global unknown','SOC-009',2)
    run('effective verified email QA','SOC-009',0,att=gp)
    run('unverified referenced contact','SOC-009',1,lambda s:s['quality']['selected_users'][0]['contacts']['data'][0].update(verified=False),att=gp)
    run('unknown contact id','SOC-009',2,lambda s:s['quality']['selected_users'][0]['contacts']['data'][0].update(id=None),att=gp)
    run('required channel absent','SOC-009',1,att=gp,extra={'SCOUTFLO_ONCALL_REQUIRED_CHANNELS':'["sms"]'})
    run('global pending propagation','SOC-009',2,att={'global_paging':{'enforced':True,'propagation_complete':False}})
    enforced={'global_paging':{'enforced':True,'propagation_complete':True,'users':[{'user':'user-one','effective_rules':[{'channel':'push'}],'push_available':True,'policy_complete':True}]}}
    run('global observed push fallback','SOC-009',0,att=enforced)
    run('global device missing','SOC-009',1,att=enforced,proof_change=lambda p:p['global_paging']['users'][0].update(push_available=False))
    def multi(s):s['policy_details'][0]['ignore_custom_paging']=False;s['quality']['selected_users'][0]['personal']['data'].append({'slug':'custom-one','rank':1,'steps':copy.deepcopy(steps)})
    run('timed selection unknown','SOC-009',2,multi,att=gp)
    run('timed selection observed','SOC-009',0,multi,att={**gp,'personal_selection':[{'policy':'policy-one','user':'user-one','effective_slug':'custom-one'}]})
    for name,alter in [('foreign target',lambda p:p.update(target='splunk_oncall/other')),('changed basis',lambda p:p.update(definition_sha256='0'*64)),('stale evidence',lambda p:p.update(observed_at=iso(now-dt.timedelta(hours=1)))),('future evidence',lambda p:p.update(observed_at=iso(now+dt.timedelta(hours=1))))]:run(name,'SOC-009',2,att=gp,proof_change=alter)
    run('no active maintenance','SOC-010',0)
    def maintenance(s):s['quality']['maintenance']['data']=[{'id':'maintenance-one','global':False,'route_aliases':['route-1'],'unmatched_targets':0,'started_at_ms':1}]
    run('active intent absent','SOC-010',2,maintenance)
    run('explicit availability conflicts with mute','SOC-010',1,maintenance,extra={'SCOUTFLO_ONCALL_EXPECT_PAGING':'1'})
    intended={'maintenance':[{'id':'maintenance-one','expected_active':True,'owner_confirmed':True,'end_at':iso(now+dt.timedelta(hours=1))}]}
    run('owned intended maintenance','SOC-010',0,maintenance,att=intended)
    run('maintenance past declared end','SOC-010',1,maintenance,att=intended,proof_change=lambda p:p['maintenance'][0].update(end_at=iso(now-dt.timedelta(minutes=1))))
    def global_maintenance(s):maintenance(s);s['quality']['maintenance']['data'][0].update(global_=True)
    def unresolved(s):maintenance(s);s['quality']['maintenance']['data'][0]['unmatched_targets']=1
    run('unresolved route target','SOC-010',2,unresolved)
    run('denied not off','SOC-010',2,lambda s:s['quality'].update(maintenance={'status':'read-blocked','data':None}))
    run('empty rules','SOC-011',0)
    def rules(s):s['quality']['transformations']['data']=[{'id':1,'rank':0,'stop':True,'route_rewrite':False,'route_aliases':[],'match_type':'REGEX','identity_mutation':False}]
    run('regex never guessed','SOC-011',2,rules)
    cases={'transformations':[{'id':1,'cases':[{'matched':True,'expected_route_aliases':['route-1'],'observed_route_aliases':['route-1'],'identity_preserved':True,'severity_expected':True},{'matched':False,'expected_route_aliases':['route-2'],'observed_route_aliases':['route-2'],'identity_preserved':True,'severity_expected':True}]}]}
    run('observed positive negative pipeline','SOC-011',0,rules,att=cases)
    run('wrong resulting route','SOC-011',1,rules,att=cases,proof_change=lambda p:p['transformations'][0]['cases'][0].update(observed_route_aliases=['route-2']))
    run('foreign alias in case','SOC-011',2,rules,att=cases,proof_change=lambda p:p['transformations'][0]['cases'][0].update(observed_route_aliases=['route-99']))
    run('one-sided rule test','SOC-011',2,rules,att=cases,proof_change=lambda p:p['transformations'][0].update(cases=p['transformations'][0]['cases'][:1]))
    run('identity collision observed','SOC-011',1,rules,att=cases,proof_change=lambda p:p['transformations'][0]['cases'][0].update(identity_preserved=False))
    run('future explicit rolls cover horizon','SOC-016',0)
    run('direct row empty rolls unknown not gap','SOC-016',2,lambda s:s['quality']['schedules'][0]['data']['policies'][0]['entries'][0].update(rolls=[]))
    schedule={'schedules':[{'policy':'policy-one','step':0,'start':iso(start),'end':iso(end),'complete':True,'boundaries_verified':True,'intervals':[{'start':iso(start),'end':iso(end),'users':['user-one']}]}]}
    def cross_team(s):
        s['policy_details'][0]['steps'][0]['entries']=[{'type':'policy_routing','policy':'policy-two'}]
        s['policies'][1]['team']='team-two';s['teams'].append({'slug':'team-two'})
        s['team_details'][0]['members']=s['team_details'][0]['members'][:1]
        s['team_details'].append({'team':'team-two','members':[{'username':'user-two','verified':True}],'groups':[],'rotations':[]})
    nested_schedule=copy.deepcopy(schedule);nested_schedule['schedules'][0]['intervals'][0]['users']=['user-two']
    run('nested policy future user belongs to terminal team','SOC-016',0,cross_team,att=nested_schedule)
    run('attended exact horizon','SOC-016',0,att=schedule)
    run('attended explicit gap','SOC-016',1,att=schedule,proof_change=lambda p:p['schedules'][0]['intervals'][0].update(users=[]))
    run('partial boundary proof','SOC-016',2,att=schedule,proof_change=lambda p:p['schedules'][0].update(boundaries_verified=False))
    run('foreign horizon','SOC-016',2,att=schedule,proof_change=lambda p:p['schedules'][0].update(end=iso(end+dt.timedelta(days=1))))
    run('ineligible future staff','SOC-016',1,att=schedule,proof_change=lambda p:p['schedules'][0]['intervals'][0].update(users=['unknown-user']))
    run('team owner enrolled','SOC-018',0)
    run('missing team administrator unknown intent','SOC-018',2,lambda s:s['quality']['team_admins'][0].update(data=[]))
    run('declared required team administrator missing','SOC-018',1,lambda s:s['quality']['team_admins'][0].update(data=[]),extra={'SCOUTFLO_ONCALL_REQUIRE_TEAM_ADMIN':'1'})
    run('global role never inferred','SOC-018',2,lambda s:s['quality']['team_admins'][0].update(status='read-blocked',data=None))
    def nestedonly(s):s['routes']=s['routes'][:1];s['policy_details'][0]['steps'][0]['entries'].append({'type':'policy_routing','policy':'policy-two'})
    r=run('nested-only policy is used','SOC-018',0,nestedonly);assert r['evidence']['unreferenced_policy_candidates']==[]
    # The evaluator must not echo arbitrary data, even when the input is malformed.
    run('arbitrary text is data','SOC-009',2,lambda s:s['quality']['selected_users'][0]['contacts'].update(status='private-contact-canary'))
print('EFFECTIVE-QUALITY-OK:',count,'semantic cases; exact published recipe; zero provider calls')
PY
