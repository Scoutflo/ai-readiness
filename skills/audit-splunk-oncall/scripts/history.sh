#!/bin/sh
# Bounded GET recipe; interpretation and score decisions live in history-quality.md.
set -eu
set +x
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)
export SCOUTFLO_HISTORY_PLUGIN_ROOT="$ROOT"
exec python3 - "$@" <<'PY'
import argparse, collections, datetime as dt, hashlib, json, math, os, pathlib, re, subprocess, sys, time, urllib.parse

SCHEMA = 'scoutflo-oncall-history/v1'
PHASES = ['resolved', 'triggered', 'acknowledged']
STATES = {'RESOLVED', 'UNACKED', 'ACKED'}
# Public schema uses uppercase response phases; populated reporting reads use
# lowercase phases and transition verbs. Keep this explicit, not case guessing.
PHASE_MAP = {'RESOLVED':'RESOLVED','UNACKED':'UNACKED','ACKED':'ACKED',
             'resolved':'RESOLVED','triggered':'UNACKED','acknowledged':'ACKED'}
MAX_BODY = 2097152
MAX_STATE = 16777216
MAX_INCIDENTS = 10000
UTC = dt.timezone.utc

class Stop(Exception): pass
def need(ok, message):
    if not ok: raise Stop(message)
def pairs(items):
    out = {}
    for k, v in items:
        need(k not in out, 'duplicate JSON member')
        out[k] = v
    return out
def decode(value):
    try: return json.loads(value, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Stop('non-finite JSON number')))
    except (ValueError, UnicodeError, RecursionError): raise Stop('invalid JSON document')
def stamp(value):
    # datetime silently truncates precision beyond microseconds. Reject that
    # input instead; unknown provider times must not become rounded evidence.
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:?\d{2})', value): return None
    try:
        v = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        return v.astimezone(UTC)
    except ValueError: return None
def iso(value): return value.isoformat().replace('+00:00', 'Z')
def now(): return dt.datetime.now(UTC)
def integer(value): return type(value) is int and value >= 0
def number(value): return type(value) in (int, float) and math.isfinite(value) and value >= 0
def slug(value): return isinstance(value, str) and bool(re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value))
def ident(value): return isinstance(value, str) and bool(re.fullmatch(r'[0-9]{1,20}', value))
def digest(value): return hashlib.sha256(value.encode()).hexdigest()
def ref(kind, value):
    # Hash only ordinary source identity, never a routing key or credential field.
    return kind + '-' + digest(value)[:24] if isinstance(value, str) and value.strip() else None
def text_present(value): return isinstance(value, str) and bool(value.strip())
def atomic(path, value):
    need(not path.is_symlink(), 'refuse a symlink artifact')
    tmp = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w') as f: json.dump(value, f, separators=(',', ':')); f.write('\n')
        os.replace(tmp, path)
    finally:
        if tmp.exists(): tmp.unlink()
def local(path, maximum=MAX_STATE):
    p = pathlib.Path(path)
    need(p.is_file() and not p.is_symlink() and p.stat().st_size <= maximum, 'invalid or oversized local evidence')
    return decode(p.read_bytes())

def project_incident(row, secrets):
    need(isinstance(row, dict), 'incident must be an object')
    need(ident(row.get('incidentNumber')), 'history identity missing or unverified')
    def safe_text(value):
        return value if isinstance(value, str) and len(value) <= 4096 and not any(s and s in value for s in secrets) else None
    def native_list(value):
        if not isinstance(value, list) or not all(slug(x) and safe_text(x) for x in value): return None
        return sorted(set(value))
    entity = safe_text(row.get('entityId'))
    service = safe_text(row.get('service'))
    host = safe_text(row.get('host'))
    users = row.get('pagedUsers')
    users = sorted(set(ref('responder', x) for x in users)) if isinstance(users, list) and all(text_present(safe_text(x)) for x in users) else None
    policies = row.get('pagedPolicies')
    if isinstance(policies, list) and all(isinstance(p, dict) and isinstance(p.get('policy'), dict) and isinstance(p.get('team'), dict) and slug(p['policy'].get('slug')) and slug(p['team'].get('slug')) for p in policies):
        policies = sorted({(p['policy']['slug'], p['team']['slug']) for p in policies})
        policies = [{'policy': p, 'team': t} for p, t in policies] if all(safe_text(p) and safe_text(t) for p,t in policies) else None
    else: policies = None
    transitions = row.get('transitions')
    # Transition names are deliberately retained only as phase observations.
    # Unknown names cannot silently become ACKED/RESOLVED or latency samples.
    if isinstance(transitions, list) and all(isinstance(t, dict) for t in transitions):
        transitions = [{'phase': PHASE_MAP.get(t.get('name')) if isinstance(t.get('name'),str) else None,
                        'at': iso(stamp(t['at'])) if stamp(t.get('at')) else None,
                        'manual': t.get('manually') if type(t.get('manually')) is bool else None} for t in transitions]
    else: transitions = None
    return {'incident_number': row['incidentNumber'], 'phase': PHASE_MAP.get(row.get('currentPhase')) if isinstance(row.get('currentPhase'),str) else None,
            'started_at': iso(stamp(row['startTime'])) if stamp(row.get('startTime')) else None,
            'last_alert_at': iso(stamp(row['lastAlertTime'])) if stamp(row.get('lastAlertTime')) else None,
            'provider_alert_count': row.get('alertCount') if integer(row.get('alertCount')) else None,
            'entity_ref': ref('entity', entity), 'service_ref': ref('service', service), 'host_ref': ref('host', host),
            'teams': native_list(row.get('pagedTeams')), 'responders': users, 'policies': policies, 'transitions': transitions}

def validate_snapshot(doc, run_date=None, target=None):
    need(isinstance(doc, dict) and set(doc) == {'schema','target','generated_at','window','collection','incidents','context','workload'}, 'invalid history artifact fields')
    need(doc['schema'] == SCHEMA and re.fullmatch(r'splunk_oncall(?:/[A-Za-z0-9_-]+)?', str(doc['target'])), 'invalid history schema or target')
    generated = stamp(doc['generated_at'])
    need(generated is not None and generated <= now() + dt.timedelta(seconds=60), 'invalid history collection timestamp')
    if run_date: need(generated.strftime('%Y-%m-%d') == run_date, 'history belongs to a different run date')
    if target: need(doc['target'] == target, 'history target does not match artifact directory')
    w = doc['window']
    need(isinstance(w, dict) and set(w) == {'started_after','started_before','query_phases'}, 'invalid history window')
    start, end = stamp(w['started_after']), stamp(w['started_before'])
    need(start is not None and end is not None and start < end <= generated and w['query_phases'] == PHASES, 'invalid history cohort or phases')
    c = doc['collection']
    need(isinstance(c, dict) and set(c) == {'status','complete','pages','expected_total','next_offset','reason','atomic_snapshot','verification'}, 'invalid history collection state')
    need(c['status'] in ('complete','partial','blocked') and type(c['complete']) is bool and c['complete'] == (c['status']=='complete') and c['atomic_snapshot'] is False, 'invalid history completeness')
    need(integer(c['pages']) and integer(c['next_offset']) and (c['expected_total'] is None or integer(c['expected_total'])), 'invalid history counts')
    need(c['verification'] in ('response-asserted','spec-only') and c['reason'] in (None,'page-budget','changed-cohort','population-budget','read-failed','shape-unverified'), 'invalid history provenance')
    need(not c['complete'] or c['pages']>=1 and c['reason'] is None and c['verification']=='response-asserted', 'complete history needs a verified response')
    need(c['status']!='partial' or c['reason']=='page-budget', 'partial history must state its remaining work')
    need(c['status']!='blocked' or c['reason'] is not None, 'blocked history needs its reason')
    rows = doc['incidents']; need(isinstance(rows, list) and len(rows) <= MAX_INCIDENTS, 'invalid incident projection')
    seen = set()
    keys = {'incident_number','phase','started_at','last_alert_at','provider_alert_count','entity_ref','service_ref','host_ref','teams','responders','policies','transitions'}
    for r in rows:
        need(isinstance(r, dict) and set(r)==keys and ident(r['incident_number']) and r['incident_number'] not in seen, 'invalid or duplicate projected incident')
        seen.add(r['incident_number'])
        need(r['phase'] in STATES or r['phase'] is None, 'unknown projected phase')
        for k in ('started_at','last_alert_at'): need(r[k] is None or stamp(r[k]) is not None, 'invalid projected time')
        need(r['provider_alert_count'] is None or integer(r['provider_alert_count']), 'invalid projected alert count')
        for k, prefix in [('entity_ref','entity'),('service_ref','service'),('host_ref','host')]:
            need(r[k] is None or re.fullmatch(prefix+r'-[a-f0-9]{24}',str(r[k])), 'invalid identity reference')
        need(r['teams'] is None or isinstance(r['teams'],list) and all(slug(v) for v in r['teams']), 'invalid team projection')
        need(r['responders'] is None or isinstance(r['responders'],list) and all(re.fullmatch(r'responder-[a-f0-9]{24}',str(v)) for v in r['responders']), 'invalid responder projection')
        need(r['policies'] is None or isinstance(r['policies'],list) and all(isinstance(v,dict) and set(v)=={'team','policy'} and slug(v['team']) and slug(v['policy']) for v in r['policies']), 'invalid policy projection')
        need(r['transitions'] is None or isinstance(r['transitions'],list), 'invalid transition projection')
        for t in r['transitions'] or []:
            need(isinstance(t,dict) and set(t)=={'phase','at','manual'} and (t['phase'] is None or t['phase'] in STATES) and (t['at'] is None or stamp(t['at']) is not None) and (t['manual'] is None or type(t['manual']) is bool), 'invalid transition evidence')
    need(c['next_offset']==len(rows) and (not c['complete'] or c['expected_total']==len(rows)), 'history count/completeness mismatch')
    need(c['expected_total'] is None or len(rows)<=c['expected_total'], 'observed history exceeds its declared cohort')
    ctx=doc['context']; need(isinstance(ctx,list) and len(ctx)<=1, 'invalid original-context projection')
    for v in ctx:
        need(isinstance(v,dict) and set(v)=={'incident_number','original_alert_read','message_type','fields_present','raw_fields_present','interpretation'} and ident(v['incident_number']) and v['original_alert_read'] is True and v['message_type'] in (None,'INFO','WARNING','ACKNOWLEDGEMENT','CRITICAL','RECOVERY') and v['interpretation']=='presence-only', 'invalid original-context fields')
        for k, allowed in [('fields_present',{'entity','description','monitoring_tool','display_name'}),('raw_fields_present',{'service','environment','owner','runbook','impact'})]:
            need(isinstance(v[k],dict) and set(v[k])==allowed and all(type(b) is bool or b is None for b in v[k].values()), 'invalid context presence')
    load=doc['workload']; need(load is None or isinstance(load,dict), 'invalid workload projection')
    if load is not None:
        need(set(load)=={'team','started_at','ended_at','lag_seconds','users','interpretation'} and slug(load['team']) and stamp(load['started_at'])==start and stamp(load['ended_at'])==end and load['lag_seconds']==900 and load['interpretation']=='assignment-time-not-interruptions' and isinstance(load['users'],list), 'invalid workload metadata')
        for u in load['users']:
            need(isinstance(u,dict) and set(u)=={'user_ref','reported_total','reported_adjusted_total','intervals'} and re.fullmatch(r'log-user-[a-f0-9]{24}',str(u['user_ref'])), 'invalid workload user')
            for k in ('reported_total','reported_adjusted_total'):
                need(u[k] is None or isinstance(u[k],dict) and set(u[k])=={'hours','minutes'} and all(number(n) for n in u[k].values()), 'invalid reported duration')
            need(isinstance(u['intervals'],list), 'invalid workload intervals')
            for i in u['intervals']:
                need(isinstance(i,dict) and set(i)=={'on','off'} and (i['on'] is None or stamp(i['on'])) and (i['off'] is None or stamp(i['off'])), 'invalid workload interval')
    return doc

def summarize(doc):
    validate_snapshot(doc)
    collected_rows=doc['incidents']; c=doc['collection']; start=stamp(doc['window']['started_after']); end=stamp(doc['window']['started_before']); collected=stamp(doc['generated_at'])
    # A provider response is not proof that every row belongs to its requested
    # cohort. Keep the safe projection intact, but exclude unknown/outside
    # starts from every measurement labeled incidents-started-in-window.
    missing=sum(stamp(r['started_at']) is None for r in collected_rows)
    outside=sum(stamp(r['started_at']) is not None and not start < stamp(r['started_at']) < end for r in collected_rows)
    rows=[r for r in collected_rows if stamp(r['started_at']) is not None and start < stamp(r['started_at']) < end]
    phase_counts=collections.Counter(r['phase'] or 'unknown' for r in rows)
    ack_samples=[]; resolve_samples=[]; aged=[]; invalid=0; no_ack_resolved=[]
    groups=collections.defaultdict(list); responders=collections.Counter(); team_assignments=collections.Counter()
    for r in rows:
        st=stamp(r['started_at']); transitions=r['transitions']
        if r['phase'] in ('UNACKED','ACKED') and st<=collected: aged.append({'incident_number':r['incident_number'],'phase':r['phase'],'age_seconds':(collected-st).total_seconds()})
        ts=[] if transitions is None else [(t['phase'],stamp(t['at'])) for t in transitions]
        # Only documented phase spellings survive projection. Missing/unknown
        # names/times keep the response denominator explicit, never a zero.
        bad=not transitions or any(p is None or at is None or st is None or at<st or at>collected for p,at in ts)
        if not bad:
            ack_times=[at for p,at in ts if p=='ACKED']; resolution_times=[at for p,at in ts if p=='RESOLVED']
            if ack_times and resolution_times and min(ack_times)>min(resolution_times): bad=True
        missing_terminal=r['phase'] in ('ACKED','RESOLVED') and not any(p==r['phase'] for p,_ in ts)
        if bad or missing_terminal or r['phase'] is None: invalid+=1
        if st and not bad:
            ack=[at for p,at in ts if p=='ACKED']; resolved=[at for p,at in ts if p=='RESOLVED']
            if ack: ack_samples.append((min(ack)-st).total_seconds())
            if resolved: resolve_samples.append((min(resolved)-st).total_seconds())
            if r['phase']=='RESOLVED' and not ack: no_ack_resolved.append(r['incident_number'])
        if r['entity_ref']:
            groups[(r['entity_ref'],r['service_ref'],r['host_ref'])].append(r)
        responders.update(r['responders'] or []); team_assignments.update(r['teams'] or [])
    cohort_ok=c['complete'] and missing==0 and outside==0
    rank=[]
    for key, members in groups.items():
        rank.append({'entity_ref':key[0],'service_ref':key[1],'host_ref':key[2],'incidents':len(members),'incident_numbers':[r['incident_number'] for r in members], 'provider_alert_count':sum(r['provider_alert_count'] for r in members) if all(r['provider_alert_count'] is not None for r in members) else None})
    rank.sort(key=lambda x:(-x['incidents'],x['entity_ref']))
    all_counts=all(r['provider_alert_count'] is not None for r in rows)
    summary={'target':doc['target'],'window':doc['window'],'generated_at':doc['generated_at'],'status':'measured' if cohort_ok else 'blocked',
      'complete_window':cohort_ok,'observed_incidents':len(rows),'population_incidents':len(rows) if cohort_ok else None,'expected_incidents':c['expected_total'],
      'collected_incidents':len(collected_rows),'excluded_incidents':missing+outside,
      'reason':f"Collected {len(collected_rows)} incident rows; {len(rows)} have verified starts strictly inside the requested window; {missing+outside} excluded ({missing} missing or unverified start, {outside} outside the exclusive window). Collection status: {c['status']}.",
      'count_unit':'incidents-started-in-window','phase_counts':dict(phase_counts),'incidents_without_start':missing,'incidents_outside_window':outside,
      'provider_alert_count':sum(r['provider_alert_count'] for r in rows) if rows and all_counts else None,
      'provider_alert_count_unit':'alerts-received-over-incident-lifetime','notification_attempts':None,'human_receipts':None,
      'response':{'observed_incidents':len(rows),'ack_samples':len(ack_samples),'resolution_samples':len(resolve_samples),'missing_or_unverified_transitions':invalid,
        'mean_ack_seconds_observed_subset':sum(ack_samples)/len(ack_samples) if ack_samples else None,
        'mean_resolution_seconds_observed_subset':sum(resolve_samples)/len(resolve_samples) if resolve_samples else None,
        'unacknowledged_or_censored':len(rows)-len(ack_samples),'open_aging':sorted(aged,key=lambda x:-x['age_seconds'])[:20]},
      'recurrence':{'ranked_entities':rank[:20],'incidents_missing_entity':sum(r['entity_ref'] is None for r in rows),'interpretation':'review-candidates-not-proven-noise'},
      'recovery':{'resolved_without_observed_ack':no_ack_resolved,'interpretation':'not-actionability-or-false-positive-evidence','end_to_end_delivery_proved':False},
      'workload':{'incident_assignment_counts':[{'responder_ref':k,'incidents':v} for k,v in responders.most_common(20)],'team_assignment_counts':[{'team':k,'incidents':v} for k,v in team_assignments.most_common(20)],
        'assignment_time':doc['workload'],'interpretation':'assignments-not-pages-or-human-interruptions','off_hours':None,'fairness':None},
      'context':doc['context'],'limitations':['Start-window cohort excludes earlier open backlog.','Alert counts include incident lifetime and cannot be used as source-window fires.','Transition phase spelling and time semantics need populated verification; subset means are not population MTTA/MTTR.','Grouping is exact hashed entity/service/host equality, not causal deduplication.','Human receipt, actionability, missed incidents and response objectives need separate evidence.']}
    return summary

def resolve_config():
    root=os.environ['SCOUTFLO_HISTORY_PLUGIN_ROOT']; home=pathlib.Path.home()
    cfg=os.environ.get('SCOUTFLO_CONFIG')
    if not cfg:
        active=home/'.scoutflo/active-config'
        options=['./.scoutflo/toolkit.yaml',active.read_text().strip() if active.is_file() else '',str(home/'.scoutflo/toolkit.yaml')]
        cfg=next((x for x in options if x and pathlib.Path(x).is_file()),None)
    need(cfg and pathlib.Path(cfg).is_file(), 'config missing; run /scoutflo:connect')
    def tt(*args):
        p=subprocess.run(['sh',root+'/report-standard/toolkit-targets.sh',cfg,'splunk_oncall',*map(str,args)],capture_output=True,text=True)
        need(p.returncode==0,'configured target could not be resolved'); return p.stdout.strip()
    kind=tt('kind'); count=tt('count'); need(count.isdigit() and int(count)>0,'no On-Call target configured')
    idx=0; target='splunk_oncall'
    if kind=='seq':
        labels=[tt('get',i,'label') for i in range(int(count))]
        need(all(slug(x) for x in labels) and len(set(labels))==len(labels),'ambiguous configured target labels')
        selected=os.environ.get('SCOUTFLO_TARGET'); need(selected in labels,'select a configured SCOUTFLO_TARGET'); idx=labels.index(selected); target+='/'+selected
    team=tt('get',idx,'team_slug'); need(slug(team),'invalid anchor team')
    names=[tt('get',idx,'api_id_env'),tt('get',idx,'api_key_env')]
    need(all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',v) for v in names),'invalid credential variable names')
    env_file=os.environ.get('SCOUTFLO_ENV_FILE') or ('./.scoutflo/env' if pathlib.Path('./.scoutflo/env').is_file() else str(home/'.scoutflo/env'))
    secrets=[]
    for name in names:
        p=subprocess.run(['sh','-c','set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1; fi; printenv "$2"','_',env_file,name],capture_output=True,text=True)
        value=p.stdout.rstrip('\n'); need(p.returncode==0 and value and '\n' not in value and '\r' not in value,'read-only credential missing or invalid; run /scoutflo:connect'); secrets.append(value)
    return target,team,secrets

def collect(args):
    start,end=stamp(args.start),stamp(args.end)
    need(start is not None and end is not None and start<end<=now(),'supply a closed ISO8601 start/end window in the past with at most six fractional digits')
    need(args.state_dir and 1<=args.page_budget<=20,'use a private state directory and page budget 1..20')
    need(not args.context_incident or ident(args.context_incident),'invalid selected incident number')
    need(not args.workload_team or slug(args.workload_team),'invalid selected workload team')
    target,team,secrets=resolve_config()
    version=subprocess.run(['curl','--version'],capture_output=True,text=True)
    match=re.match(r'curl (\d+)\.(\d+)',version.stdout)
    need(match and tuple(map(int,match.groups())) >= (8,4),'curl 8.4 or newer required for bounded unknown-length bodies')
    state_dir=pathlib.Path(args.state_dir); need(not state_dir.is_symlink(),'refuse symlink state directory'); state_dir.mkdir(mode=0o700,parents=True,exist_ok=True)
    need(state_dir.stat().st_uid==os.getuid() and state_dir.stat().st_mode & 0o077 == 0,'state directory must be private (0700)')
    lock=state_dir/'.lock'
    try: lock.mkdir(mode=0o700)
    except FileExistsError: raise Stop('history run is locked; do not start a competing reader')
    try:
        state_file=state_dir/'state.json'
        state=local(state_file) if state_file.exists() else None
        salt=state.get('credential_salt') if isinstance(state,dict) else os.urandom(32).hex()
        need(isinstance(salt,str) and re.fullmatch(r'[a-f0-9]{64}',salt),'resume binding is unverified; start a new run')
        binding={'target':target,'anchor':team,'window':[iso(start),iso(end)],'credential':digest(salt+'\0'+'\0'.join(secrets)),'context':args.context_incident,'workload':args.workload_team}
        if state_file.exists():
            need(state.get('binding')==binding,'resume target, window, selections or credentials changed; start a separate run')
            need(state.get('stage') in ('pages','verify','done'),'invalid resume stage')
            validate_snapshot(state['snapshot']); need(state['snapshot']['collection']['status']!='blocked','blocked cohort must be recollected in a new run')
            if state['stage']=='done' and state.get('final_identity_verified') is True and (not args.context_incident or state['snapshot']['context']) and (not args.workload_team or state['snapshot']['workload'] is not None):
                # Reusing completed evidence must retain its real collection
                # timestamp. A new audit needs a new read, not a re-dated cache.
                print(json.dumps(state['snapshot'],separators=(',',':'))); return
        else:
            state={'binding':binding,'credential_salt':salt,'first_page':None,'stage':'pages','snapshot':{'schema':SCHEMA,'target':target,'generated_at':iso(now()),'window':{'started_after':iso(start),'started_before':iso(end),'query_phases':PHASES},'collection':{'status':'partial','complete':False,'pages':0,'expected_total':None,'next_offset':0,'reason':'page-budget','atomic_snapshot':False,'verification':'spec-only'},'incidents':[],'context':[],'workload':None}}
        # Shared per-credential budget survives run changes and process restarts.
        budget_root=pathlib.Path.home()/'.scoutflo/runtime/oncall-history'
        need(not budget_root.is_symlink(),'refuse symlink budget directory'); budget_root.mkdir(mode=0o700,parents=True,exist_ok=True)
        need(budget_root.stat().st_uid==os.getuid() and budget_root.stat().st_mode & 0o077 == 0,'reporting budget directory must be private (0700)')
        budget_key=digest('\0'.join(secrets)); budget_file=budget_root/(budget_key+'.json'); budget_lock=budget_root/(budget_key+'.lock')
        def get(path, reporting=False):
            need(path.startswith(('/api-public/v1/','/api-reporting/')) and '\n' not in path and '#' not in path,'invalid fixed request path')
            if reporting:
                try: budget_lock.mkdir(mode=0o700)
                except FileExistsError: raise Stop('reporting credential already in use; wait for the other reader')
            try:
                if reporting:
                    prev=local(budget_file,1024) if budget_file.exists() else {'next_request':0}
                    need(isinstance(prev,dict) and number(prev.get('next_request')),'invalid reporting budget')
                    delay=max(0,prev['next_request']-time.time())
                    if delay: subprocess.run(['sleep',str(math.ceil(delay))],check=True)
                    atomic(budget_file,{'next_request':time.time()+60})
                else: subprocess.run(['sleep','1'],check=True)
                command=['curl','-q','-sS','--proto','=https','--max-time','25','--max-redirs','0','--max-filesize',str(MAX_BODY),'-H','X-VO-Api-Id: '+secrets[0],'-H','X-VO-Api-Key: '+secrets[1],'-H','Accept: application/json','-H','Accept-Encoding: identity','-w','\n%{http_code}','https://api.victorops.com'+path]
                result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
                need(result.returncode==0 and len(result.stdout)<=MAX_BODY+5,'bounded management read failed')
                body,sep,status=result.stdout.rpartition(b'\n'); need(sep and status==b'200','management read refused; no retry')
                return decode(body)
            except (subprocess.SubprocessError,OSError): raise Stop('management transport unavailable')
            finally:
                if reporting: budget_lock.rmdir()
        anchor=get('/api-public/v1/team/'+team); need(isinstance(anchor,dict) and anchor.get('slug')==team,'configured identity mismatch')
        snap=state['snapshot']; c=snap['collection']
        try:
            for _ in range(args.page_budget):
                if state['stage']=='done': break
                offset=0 if state['stage']=='verify' else c['next_offset']
                query=urllib.parse.urlencode({'startedAfter':iso(start),'startedBefore':iso(end),'currentPhase':','.join(PHASES),'offset':offset,'limit':100})
                response=get('/api-reporting/v2/incidents?'+query,True)
                need(isinstance(response,dict) and all(integer(response.get(k)) for k in ('offset','limit','total')) and response['offset']==offset and response['limit']==100 and isinstance(response.get('incidents'),list),'history pagination shape unverified')
                total=response['total']; rows=[project_incident(r,secrets) for r in response['incidents']]
                need(len(rows)==min(100,max(0,total-offset)),'history page is truncated or inconsistent')
                c['pages']+=1; c['verification']='response-asserted'
                first=digest(json.dumps(rows,sort_keys=True,separators=(',',':')))
                if c['expected_total'] is None: c['expected_total']=total
                if total!=c['expected_total'] or (state['stage']=='verify' and first!=state['first_page']):
                    c.update(status='blocked',complete=False,reason='changed-cohort'); break
                if total>MAX_INCIDENTS:
                    c.update(status='blocked',complete=False,reason='population-budget'); break
                if state['stage']=='verify': state['stage']='done'
                else:
                    known={r['incident_number'] for r in snap['incidents']}
                    ids=[r['incident_number'] for r in rows]
                    if len(set(ids))!=len(ids) or any(i in known for i in ids):
                        c.update(status='blocked',complete=False,reason='changed-cohort'); break
                    if offset==0: state['first_page']=first
                    snap['incidents'].extend(rows); c['next_offset']=len(snap['incidents'])
                    if c['next_offset']==total: state['stage']='done' if total<=100 else 'verify'
                if state['stage']=='done': c.update(status='complete',complete=True,reason=None)
                snap['generated_at']=iso(now()); atomic(state_file,state)
            if args.context_incident and not snap['context']:
                detail=get('/api-public/v1/incidents/'+args.context_incident)
                need(isinstance(detail,dict) and detail.get('incidentNumber')==args.context_incident,'selected incident identity unverified')
                uuid=detail.get('firstAlertUuid'); need(isinstance(uuid,str) and re.fullmatch(r'[A-Fa-f0-9-]{36}',uuid),'original alert UUID unverified')
                alert=get('/api-public/v1/alerts/'+uuid); need(isinstance(alert,dict),'original alert shape unverified')
                raw=None
                if isinstance(alert.get('raw'),str):
                    try: raw=decode(alert['raw'])
                    except Stop: pass
                raw=raw if isinstance(raw,dict) else None
                fields={k:text_present(alert.get(v)) for k,v in {'entity':'entityId','description':'stateMessage','monitoring_tool':'monitoringTool','display_name':'entityDisplayName'}.items()}
                candidates={'service':['service','service_name'],'environment':['environment','env'],'owner':['owner','team'],'runbook':['runbook','runbook_url'],'impact':['impact','severity']}
                presence={k:any(text_present(raw.get(v)) for v in values) if raw is not None else None for k,values in candidates.items()}
                snap['context']=[{'incident_number':args.context_incident,'original_alert_read':True,'message_type':alert.get('messageType') if alert.get('messageType') in ('INFO','WARNING','ACKNOWLEDGEMENT','CRITICAL','RECOVERY') else None,'fields_present':fields,'raw_fields_present':presence,'interpretation':'presence-only'}]
                snap['generated_at']=iso(now())
            if args.workload_team and snap['workload'] is None:
                load=get('/api-reporting/v1/team/'+args.workload_team+'/oncall/log?'+urllib.parse.urlencode({'start':iso(start),'end':iso(end)}))
                need(isinstance(load,dict) and load.get('teamSlug')==args.workload_team and stamp(load.get('start'))==start and stamp(load.get('end'))==end and isinstance(load.get('userLogs'),list),'workload identity/window/shape unverified')
                users=[]
                for u in load['userLogs']:
                    need(isinstance(u,dict) and text_present(u.get('userId')) and isinstance(u.get('log'),list),'workload user shape unverified')
                    def duration(v): return {k:v[k] for k in ('hours','minutes')} if isinstance(v,dict) and all(number(v.get(k)) for k in ('hours','minutes')) else None
                    intervals=[]
                    for i in u['log']:
                        need(isinstance(i,dict),'workload interval shape unverified')
                        intervals.append({'on':iso(stamp(i['on'])) if stamp(i.get('on')) else None,'off':iso(stamp(i['off'])) if stamp(i.get('off')) else None})
                    users.append({'user_ref':ref('log-user',u['userId']),'reported_total':duration(u.get('total')),'reported_adjusted_total':duration(u.get('adjustedTotal')),'intervals':intervals})
                snap['workload']={'team':args.workload_team,'started_at':iso(start),'ended_at':iso(end),'lag_seconds':900,'users':users,'interpretation':'assignment-time-not-interruptions'}
                snap['generated_at']=iso(now())
        except Stop:
            c.update(status='blocked',complete=False,reason='read-failed'); snap['generated_at']=iso(now()); atomic(state_file,state)
            print(json.dumps(snap,separators=(',',':'))); raise
        try:
            anchor=get('/api-public/v1/team/'+team); need(isinstance(anchor,dict) and anchor.get('slug')==team,'configured identity changed')
        except Stop:
            c.update(status='blocked',complete=False,reason='read-failed'); state['final_identity_verified']=False
            snap['generated_at']=iso(now()); atomic(state_file,state)
            print(json.dumps(snap,separators=(',',':'))); raise
        state['final_identity_verified']=True
        validate_snapshot(snap); atomic(state_file,state)
        print(json.dumps(snap,separators=(',',':')))
    finally: lock.rmdir()

parser=argparse.ArgumentParser(description='Read-only bounded On-Call history recipe. No paging or acknowledgement writes.')
parser.add_argument('--start'); parser.add_argument('--end'); parser.add_argument('--state-dir'); parser.add_argument('--page-budget',type=int,default=1)
parser.add_argument('--context-incident'); parser.add_argument('--workload-team'); parser.add_argument('--summarize'); parser.add_argument('--run-date'); parser.add_argument('--target')
args=parser.parse_args()
try:
    if args.summarize:
        need(not any((args.start,args.end,args.state_dir,args.context_incident,args.workload_team)),'summary mode accepts local evidence only')
        doc=validate_snapshot(local(args.summarize),args.run_date,args.target); print(json.dumps(summarize(doc),separators=(',',':')))
    else:
        need(not args.run_date and not args.target,'collection target comes from toolkit config'); collect(args)
except (Stop,OSError,ValueError,KeyError,TypeError,RecursionError) as e:
    # Provider bodies and selected config/credential values never appear here.
    print('oncall-history: '+(str(e) if isinstance(e,Stop) else 'invalid local evidence or environment'),file=sys.stderr); sys.exit(1)
PY
