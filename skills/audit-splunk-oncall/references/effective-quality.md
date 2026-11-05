# Effective paging quality

This fixed, read-only evaluator is shared by audit judgment and setup's fresh-read verification. It evaluates safely projected collector evidence; it never contacts the provider, executes evidence text, changes configuration, or emits a score. A verified configuration predicate is not proof of notification receipt or future unchanged configuration. See [the catalog](oncall-checks.md) for finding severity, scope and confirming-read requirements.

## Inputs and evidence boundaries

Run the block against the current collector snapshot on standard input, or set `SCOUTFLO_ONCALL_SNAPSHOT` to that JSON file. Use `SCOUTFLO_VERIFY_CHECK` and `SCOUTFLO_VERIFY_POLICY` for one exact check and policy. `SCOUTFLO_VERIFY_TEAM`, `SCOUTFLO_VERIFY_POLICIES` and `SCOUTFLO_VERIFY_MIN_RESPONDERS` retain [the verification contract](verify-path.md). `SCOUTFLO_ONCALL_MAX_ESCALATION_MINUTES`, when explicitly declared, limits configured escalation delay to the first eligible human; it excludes unproved personal-policy/source latency. Missing timing goals do not create a failure. `SCOUTFLO_ONCALL_REQUIRED_CHANNELS` is an optional JSON array of `email`, `phone`, `sms`, `push`; absence means a viable configured channel, not a universal two-channel requirement.

`SCOUTFLO_ONCALL_HORIZON_START` and `SCOUTFLO_ONCALL_HORIZON_END` are timezone-qualified ISO8601 timestamps for SOC-016. Collection requests explicit `daysForward` (1–123), `daysSkip` (0–90) and each relevant `step` (0–3). Provider-resolved rolls carry precise observed intervals. The API's initial-user row is not silently expanded across uncovered boundary time. Unsupported later steps, interval gaps whose completeness is unknown, and unresolved override effects require the attended evidence below. An unassigned absence does not itself remove its original responder.

The result is `{check,policy,status,reason,evidence,affected}`; statuses and exits are `verified`/0, `not-met`/1, `blocked`/2 and `inapplicable`/3. These are verifier outcomes, not new `checks[].result` enums. A nonzero result is not automatically a scored failure. The catalog requires exact scope, completeness and confirming evidence. SOC-006 additionally preserves `observed_responders` and `required_responders` at the top level. For a deliberately selected team batch, set `SCOUTFLO_ONCALL_SELECTED_SCOPE` to its exact `scope`; default is `account`. External/nested dependencies outside that batch remain blocked, and the caller must preserve subset scope in the report. Legacy snapshots remain usable for their existing core checks; missing new evidence blocks only its corresponding quality predicate.

## Attended evidence for state the API cannot establish

Set `SCOUTFLO_ONCALL_MODE=basis` with a snapshot to print its `definition_sha256`, then return to normal mode. The hash binds the full projected definition set, including current assignments and optional quality projections; capture a new hash after any relevant change. Sensitive rule predicates, annotation/contact values and policy destinations are bound by opaque keyed `definition_fingerprint` values in the safe snapshot; changing one invalidates the attended record even when its visible flags or IDs remain identical. Never replace these with unkeyed hashes of low-entropy contact values. It includes the collector's private HMAC credential binding and excludes collection timestamps only. Credential rotation requires a fresh baseline and attended observation. Older snapshots without a credential binding cannot receive new attended quality certification. Do not transfer this evidence across targets or redefine its source observations to match a new hash.

`SCOUTFLO_ONCALL_ATTENDED_EVIDENCE` may name one operator-verified JSON record, at most 1 MiB. Its required envelope is `schema: scoutflo-oncall-quality-attended/v1`, exact `target`, `definition_sha256`, timezone-qualified `observed_at`, `verified: true`, and nonempty `evidence_ref` identifying the safely stored UI/export receipt. Default freshness is 900 seconds (`SCOUTFLO_ONCALL_ATTENDED_MAX_AGE_SECONDS`, 1–3600). Future observations beyond 60 seconds, stale records, changed definitions, foreign targets, duplicate keys and malformed inputs are rejected. A verified flag records a completed attended observation; it cannot turn an unverified claim into evidence. Inspect the source receipt first. Never include contact values, incoming URLs, credentials, arbitrary incident text or UI page dumps.

Optional sections, only for observations actually made:

- `global_paging`: `{enforced: false, propagation_complete: true}` when the UI confirms no global enforcement. When enforced, provide `enforced: true`, `propagation_complete: true`, and `users:[{user,policy_complete:true,effective_steps:[{index,timeout,rules:[{channel,contact_id,contact_type}]}],push_available:boolean}]` for every assessed user. Steps are the complete effective order/selected contacts observed after propagation, not copied personal settings. A genuinely single-step policy may use `effective_rules` instead of `effective_steps`, still with `policy_complete: true`. A missing selected contact falling back to push requires observed push availability; fallback semantics alone do not prove enrollment.
- `personal_selection`: `[{policy,user,effective_slug}]` for every custom-policy-enabled selection actually verified for this escalation path and observation time. The primary policy is read directly only when the escalation flag explicitly ignores custom policies. A singleton list, absent flag or inactive time mask never establishes the effective selection. No runtime emulation of undocumented precedence is attempted.
- `maintenance`: `[{id,expected_active:true,owner_confirmed:true,end_at}]` for an intentional, owned interval. `end_at` is the declared intended end, not a fabricated provider expiry. `SCOUTFLO_ONCALL_EXPECT_PAGING=1` declares this selected path must currently accept new pages; any matching active maintenance then fails. Without that requirement or an observed intent record, active maintenance is reported as blocked intent, not automatically faulty.
- `transformations`: `[{id,cases:[{matched:boolean,expected_route_aliases:[...],observed_route_aliases:[...],identity_preserved:boolean,severity_expected:boolean}]}]`. Each current rule needs at least one matching and one nonmatching observed example, with downstream route/identity/severity checked after the ordered pipeline. These are source-proven paired observations, not a locally guessed Java-regex match. Preserve complete rule ordering and `stopFlag` in the bound snapshot. An unknown/wrong type or incomplete case stays blocked. No literal source values are necessary.
- `schedules`: `[{policy,step,start,end,complete:true,boundaries_verified:true,intervals:[{start,end,users:[...]}]}]`. Record the exact requested interval and every rendered coverage segment, including explicitly empty-user gaps, after overrides. Evidence must cover each requested step; it cannot omit an inconvenient interval. This provides a usable verification path for UI-rendered gaps, partial-day/custom schedules and DST. An absence awaiting an assignee remains an observation unless effective coverage or the declared absence requirement proves a defect.

`SCOUTFLO_ONCALL_REQUIRE_TEAM_ADMIN=1` declares a dedicated team-admin requirement for SOC-018; `0` declares that requirement absent. An empty team-admin list without that declaration remains blocked because inherited global ownership is not established by this endpoint. A listed administrator outside team membership likewise needs actual enrollment/role evidence, not an inferred failure.

New collected fields are additive under `quality` (`scoutflo-oncall-quality/v1`). Each optional read has `status` and `data`: `collected`, `read-blocked`, `schema-blocked`, `identity-blocked`, or `budget-exhausted`. Endpoint denial is not an empty collection. `selected_users` is deduplicated; `user_collection_complete`, counts and bounded call budget expose any uncollected tail. No elevated credential fallback exists.

## Evaluate one observed relationship

<!-- oncall-effective-quality:start -->
```bash
set -eu
set +x
command -v python3 >/dev/null || { echo 'Python 3 is required for the fixed quality evaluator'; exit 2; }
python3 -c 'import sys; sys.exit(sys.version_info < (3,9))' || { echo 'Python 3.9 or newer is required'; exit 2; }
if [ -n "${SCOUTFLO_ONCALL_SNAPSHOT:-}" ]; then
  [ -f "$SCOUTFLO_ONCALL_SNAPSHOT" ] || { echo 'Select a current collector snapshot'; exit 2; }
  exec 3< "$SCOUTFLO_ONCALL_SNAPSHOT"
else
  exec 3<&0
fi
python3 - <<'PY' 3<&3
import datetime as dt, hashlib, json, math, os, re, sys
class Verdict(Exception):
    def __init__(self,status,reason,evidence=None): self.status,self.reason,self.evidence=status,reason,evidence or {}
def stop(status,reason,**evidence): raise Verdict(status,reason,evidence)
def blocked(reason,**evidence): stop('blocked',reason,**evidence)
def unmet(reason,**evidence): stop('not-met',reason,**evidence)
def unique_object(pairs):
    out={}
    for key,value in pairs:
        if key in out: raise ValueError('duplicate key')
        out[key]=value
    return out
def read_json(stream,limit):
    raw=stream.read(limit+1)
    if len(raw)>limit: raise ValueError('bound')
    return json.loads(raw,object_pairs_hook=unique_object,parse_constant=lambda _: (_ for _ in ()).throw(ValueError('number')))
def integer(v): return type(v) is int or type(v) is float and math.isfinite(v) and v.is_integer()
def identity(v): return isinstance(v,str) and re.fullmatch(r'[A-Za-z0-9_-]+',v) is not None
def stamp(v):
    if not isinstance(v,str): raise ValueError('timestamp')
    t=dt.datetime.fromisoformat(v.replace('Z','+00:00'))
    if t.tzinfo is None: raise ValueError('timezone')
    return t.astimezone(dt.timezone.utc)
def one(rows,key,value,missing):
    found=[r for r in rows if r.get(key)==value]
    if len(found)>1: blocked('Ambiguous '+key+' identity')
    if not found: blocked(missing)
    return found[0]
def arr(value):
    if not isinstance(value,list): blocked('Incomplete collection shape')
    return value
s={}; check=os.environ.get('SCOUTFLO_VERIFY_CHECK',''); policy=os.environ.get('SCOUTFLO_VERIFY_POLICY','')
try:
    with os.fdopen(3) as source: s=read_json(source,16777216)
    if not isinstance(s,dict): raise ValueError('snapshot')
    basis={k:s.get(k) for k in ('target','scope','credential_binding','routing_definition_fingerprint','teams','policies','routes','current','policy_details','team_details','quality')}
    digest=hashlib.sha256(json.dumps(basis,sort_keys=True,separators=(',',':'),ensure_ascii=True).encode()).hexdigest()
    if os.environ.get('SCOUTFLO_ONCALL_MODE')=='basis':
        print(json.dumps({'target':s.get('target'),'definition_sha256':digest})); sys.exit(0)
    if check not in ['SOC-%03d'%n for n in (1,2,3,4,5,6,7,9,10,11,16,18)] or not identity(policy): blocked('Select a supported check and exact policy')
    expected_scope=os.environ.get('SCOUTFLO_ONCALL_SELECTED_SCOPE','account')
    if s.get('complete_reads') is not True or s.get('scope')!=expected_scope or (expected_scope!='account' and not identity(expected_scope)): blocked('A complete explicitly selected snapshot scope is required')
    for k in ('teams','policies','routes','current','policy_details','team_details'): arr(s.get(k))
    q=s.get('quality') if isinstance(s.get('quality'),dict) else {}
    attended={}
    attended_path=os.environ.get('SCOUTFLO_ONCALL_ATTENDED_EVIDENCE')
    if attended_path:
        binding=s.get('credential_binding')
        if not isinstance(binding,dict) or not isinstance(binding.get('fingerprint'),str) or not re.fullmatch(r'[a-f0-9]{64}',binding['fingerprint']): blocked('Attended assessment requires a fresh credential-bound collector snapshot')
        with open(attended_path) as source: attended=read_json(source,1048576)
        age=int(os.environ.get('SCOUTFLO_ONCALL_ATTENDED_MAX_AGE_SECONDS','900'))
        observed=stamp(attended.get('observed_at')); now=dt.datetime.now(dt.timezone.utc)
        if not 1<=age<=3600 or attended.get('schema')!='scoutflo-oncall-quality-attended/v1' or attended.get('target')!=s.get('target') or attended.get('definition_sha256')!=digest or attended.get('verified') is not True or not isinstance(attended.get('evidence_ref'),str) or not attended['evidence_ref'].strip() or not -60<=(now-observed).total_seconds()<=age:
            blocked('Attended evidence is stale, foreign, incomplete or bound to changed definitions')
    def ownership(p):
        owners=[x for x in s['policies'] if x.get('slug')==p]
        if len(owners)>1: blocked('Policy owner mapping is ambiguous')
        if not owners:
            if s.get('scope')!='account': blocked('Policy dependency lies outside the explicitly selected team scope')
            unmet('Selected policy is absent from complete ownership inventory')
        teams=[x for x in s['teams'] if x.get('slug')==owners[0].get('team')]
        if len(teams)>1: blocked('Owning team identity is ambiguous')
        if not teams: unmet('Owning team is absent from complete inventory')
        return owners[0]['team']
    def routing(p):
        rows=[r for r in s['routes'] if p in arr(r.get('policies'))]
        if not rows: unmet('No configured route targets the selected policy')
        for r in rows:
            targets=r['policies']
            if r.get('out_of_scope_policies') or len(targets)!=len(set(targets)): blocked('Route targets are ambiguous or outside complete scope')
            for target in targets: ownership(target)
        return rows
    def team_data(t):
        d=one(s['team_details'],'team',t,'Team detail is missing')
        users=[m.get('username') for m in arr(d.get('members'))]
        if len(users)!=len(set(users)): blocked('Member identity is ambiguous')
        return d
    def eligible(t,u): return len([m for m in team_data(t)['members'] if m.get('username')==u and m.get('verified') is True])==1
    graph_budget=[0]
    def graph(p,stack=(),delay=0):
        graph_budget[0]+=1
        if graph_budget[0]>50000: blocked('Policy graph exceeds the bounded traversal work budget')
        if len(stack)>=32: blocked('Policy graph exceeds the bounded traversal depth')
        if p in stack: unmet('Escalation policy cycle is observed',cycle=list(stack)+( [p]))
        owner=ownership(p); d=team_data(owner); detail=one(s['policy_details'],'slug',p,'Policy detail is missing')
        steps=arr(detail.get('steps'))
        if not steps: unmet('No escalation step exists',defective_policy=p)
        leaves=[]; refs=[]; elapsed=delay
        for index,step in enumerate(steps):
            timeout=step.get('timeout')
            if not integer(timeout) or timeout<0: blocked('Invalid escalation timeout')
            elapsed+=timeout
            if elapsed>525600: blocked('Escalation delay exceeds the bounded interpretation window')
            for entry in arr(step.get('entries')):
                graph_budget[0]+=1
                if graph_budget[0]>50000: blocked('Policy graph exceeds the bounded traversal work budget')
                kind=entry.get('type'); base={'owner':owner,'policy':p,'step':index,'delay_minutes':elapsed,'type':kind}
                if kind=='user':
                    u=entry.get('user')
                    if not identity(u): blocked('Direct-user identity is unverified')
                    if not eligible(owner,u): unmet('A direct user is not one verified enrolled member',defective_policy=p)
                    leaves.append(dict(base,user=u))
                elif kind in ('rotation_group','rotation_group_next','rotation_group_previous'):
                    groups=[g for g in arr(d.get('groups')) if g.get('slug')==entry.get('rotation') and g.get('teamSlug')==owner]
                    if len(groups)>1: blocked('Rotation slug is ambiguous')
                    if not groups: unmet('Referenced rotation does not resolve',defective_policy=p)
                    rotation=one(arr(d.get('rotations')),'groupId',groups[0].get('groupId'),'Numeric rotation identity is missing')
                    refs.append({'owner':owner,'rotation':rotation,'kind':kind})
                    shifts=arr(rotation.get('shifts'))
                    for shift in shifts:
                        user=shift.get('current_user') if kind=='rotation_group' else shift.get('next_user')
                        if kind=='rotation_group_previous':
                            current=shift.get('current_period')
                            if not isinstance(current,dict): blocked('Previous rotation needs observed prior/current periods')
                            current_start=stamp(current.get('start')); previous=[]
                            for period in arr(shift.get('periods')):
                                if stamp(period.get('end'))<=current_start: previous.append(period)
                            if not previous: blocked('Previous rotation member is outside the observed period window')
                            latest=max(stamp(x['end']) for x in previous); previous=[x for x in previous if stamp(x['end'])==latest]
                            if len(previous)!=1: blocked('Previous rotation assignment is ambiguous')
                            user=previous[0].get('username')
                        if kind!='rotation_group' and user is None: blocked('Requested next/previous rotation assignment is unobserved')
                        leaves.append(dict(base,user=user,rotation=groups[0]['slug']))
                    if not shifts: leaves.append(dict(base,user=None,rotation=groups[0]['slug']))
                elif kind=='policy_routing':
                    target=entry.get('policy')
                    if not identity(target): blocked('Nested policy reference is unverified')
                    target_owner=ownership(target); hint=entry.get('policy_team')
                    if hint is not None and (not identity(hint) or hint!=target_owner): blocked('Nested target team contradicts the unique policy ownership census')
                    nested,nested_refs=graph(target,stack+(p,),elapsed)
                    for leaf in nested:leaf.setdefault('nested_ownership',[]).append({'target_policy':target,'target_team':target_owner,'basis':'returned-team-and-census' if hint is not None else 'census-only; legacy target team absent'})
                    leaves+=nested; refs+=nested_refs
                elif kind in ('email','webhook'):
                    if entry.get('destination_present') is not True: blocked('External destination reference is unverified')
                    leaves.append(dict(base,user=None,external=True))
                else: blocked('Unsupported escalation target type')
        if not leaves: unmet('No escalation target exists',defective_policy=p)
        return leaves,refs
    def path(p): routing(p); return graph(p)
    def staffing(refs):
        if not refs: stop('inapplicable','Selected policy has no rotation target')
        for ref in refs:
            shifts=arr(ref['rotation'].get('shifts'))
            if not shifts: unmet('A referenced rotation has no staffed shift')
            for shift in shifts:
                if shift.get('shifttype') not in ('std','pho','fts','cstm'): blocked('Unknown shift mode')
                members=arr(shift.get('members')); current=shift.get('current_user')
                if current is not None and current not in members: blocked('Current assignment needs an effective override proof')
                if not members or any(not eligible(ref['owner'],u) for u in members): unmet('A referenced shift lacks eligible enrolled staff')
    def current_path(p):
        leaves,refs=path(p); owner=ownership(p)
        # Empty alternate shifts do not invalidate an independently verified direct path.
        try: staffing(refs)
        except Verdict as v:
            if v.status=='blocked': raise
        now=[x for x in s['current'] if x.get('policy')==p]
        if len(now)>1: blocked('Current policy row is ambiguous')
        if not now: blocked('Current API omitted this policy; effective assignment visibility or propagation is unverified')
        if now[0].get('team')!=owner: blocked('Current policy owner disagrees')
        if not arr(now[0].get('users')): unmet('The explicit current policy row has no responders; confirm with a second read before a finding')
        # The current endpoint describes the immediate path. Delayed fallback users
        # remain in graph evidence but cannot be substituted for current coverage.
        expected={x['user'] for x in leaves if x.get('user') and x['delay_minutes']==0}
        all_expected={x['user'] for x in leaves if x.get('user')}
        users=set(now[0]['users'])
        for u in users:
            owners={x['owner'] for x in leaves if x.get('user')==u}
            if not owners: blocked('Current assignment differs from the resolved path; override proof required')
            if not any(eligible(t,u) for t in owners): unmet('Current responder is not an eligible member on the resolved path')
        if not users<=expected:
            if users<=all_expected: blocked('Current endpoint includes delayed-step users; effective step proof is required')
            blocked('Current assignment differs from the resolved path; override proof required')
        return users,leaves,refs
    def collected(value,description):
        if not isinstance(value,dict) or value.get('status')!='collected': blocked(description+' read is incomplete or unavailable')
        return value.get('data')
    def contacts_check():
        leaves,_=path(policy)
        targets=sorted({(x['user'],x['policy']) for x in leaves if x.get('user') and eligible(x['owner'],x['user'])})
        if not targets or any(x.get('user') is None and not x.get('external') for x in leaves): blocked('The full configured responder set is not established for contact assessment')
        gp=attended.get('global_paging')
        if not isinstance(gp,dict) or type(gp.get('enforced')) is not bool or gp.get('propagation_complete') is not True: blocked('Observe global paging enforcement and completed propagation in the attended evidence')
        required=json.loads(os.environ.get('SCOUTFLO_ONCALL_REQUIRED_CHANNELS','[]'))
        if not isinstance(required,list) or any(x not in ('email','phone','sms','push') for x in required): blocked('Invalid required-channel declaration')
        proved=[]
        for user,selected_policy in targets:
            item=one(arr(q.get('selected_users')),'user',user,'Selected responder profile was not collected')
            contacts=arr(collected(item.get('contacts'),'Contact')); push=None; terminal=None
            if gp['enforced']:
                effective=one(arr(gp.get('users')),'user',user,'Effective global policy for this user is missing')
                if effective.get('policy_complete') is not True: blocked('Observe all effective global notification steps, not only the first rule')
                steps=effective.get('effective_steps')
                if steps is None: steps=[{'index':0,'timeout':0,'rules':arr(effective.get('effective_rules'))}]
                steps=arr(steps); push=effective.get('push_available')
                terminal=effective.get('terminal_action')
            else:
                detail=one(s['policy_details'],'slug',selected_policy,'Policy detail missing')
                if type(detail.get('ignore_custom_paging')) is not bool: blocked('Custom-policy precedence flag is unknown')
                if detail.get('ignore_custom_paging') is True:
                    steps=arr(collected(item.get('primary'),'Primary personal policy'))
                    # v1 primary response does not establish terminal repeat behavior.
                else:
                    candidates=arr(collected(item.get('personal'),'Personal policy'))
                    choices=[x for x in attended.get('personal_selection',[]) if x.get('policy')==selected_policy and x.get('user')==user]
                    if len(choices)!=1: blocked('Timed/custom personal selection needs one attended effective-policy observation; a singleton list is not effectiveness proof')
                    chosen=one(candidates,'slug',choices[0].get('effective_slug'),'Observed personal policy absent')
                    steps=arr(chosen.get('steps')); terminal=chosen.get('terminal_action')
            if not steps: unmet('An effective personal policy has no notification steps')
            if any(not integer(x.get('index')) or not integer(x.get('timeout')) or x['timeout']<0 for x in steps): blocked('Notification step ordering or timeout is unverified')
            if len({x['index'] for x in steps})!=len(steps): blocked('Notification step order is ambiguous')
            step_results=[]
            for ordinal,step in enumerate(sorted(steps,key=lambda x:x['index'])):
                rules=arr(step.get('rules')); channels=set(); unknown=False
                for rule in rules:
                    channel=rule.get('channel')
                    if channel=='push':
                        if push is True: channels.add(channel)
                        elif push is not False: unknown=True
                    elif channel in ('email','phone','sms'):
                        kind='email' if channel=='email' else 'phone'
                        if rule.get('contact_type') not in (None,kind): unmet('Notification rule references a different contact type')
                        linked=[c for c in contacts if c.get('kind')==kind and c.get('id')==rule.get('contact_id') and rule.get('contact_id') is not None]
                        if len(linked)>1: blocked('Contact identity is ambiguous')
                        if linked and linked[0].get('verified') is True: channels.add(channel)
                        elif linked and linked[0].get('verified') is None: unknown=True
                        elif not linked and any(c.get('kind')==kind and c.get('id') is None for c in contacts): unknown=True
                    else: unknown=True
                if not channels or (ordinal==0 and not set(required)<=channels):
                    if unknown: blocked('Required effective contact or device verification is unknown')
                    unmet('An effective notification step has no verified required channel',user=user,policy=selected_policy,notification_step=step['index'])
                step_results.append({'index':step['index'],'channels':sorted(channels),'configured_timeout_minutes':step['timeout']})
            proved.append({'user':user,'policy':selected_policy,'steps':step_results,'terminal_action':terminal if terminal=='repeat_last_step' else None})
        return {'effective_users':proved,'scope':'all observed configured terminal policies and notification steps; future roster changes require SOC-016','delivery_proven':False}
    evidence={}
    if check=='SOC-001': evidence={'routes':[r['alias'] for r in routing(policy)]}
    elif check=='SOC-002':
        owner=ownership(policy)
        if not os.environ.get('SCOUTFLO_VERIFY_TEAM'): blocked('Declare the intended owning team')
        if owner!=os.environ['SCOUTFLO_VERIFY_TEAM']: unmet('Owner differs from the explicitly intended team')
        evidence={'owner':owner}
    elif check=='SOC-003':
        leaves,refs=path(policy)
        humans=[x for x in leaves if x.get('user') and eligible(x['owner'],x['user'])]
        if not humans:
            if leaves and all(x.get('external') for x in leaves): blocked('External-only policy has no evidenced enrolled-human response path')
            roster_candidates=[(ref['owner'],u) for ref in refs for shift in arr(ref['rotation'].get('shifts')) for u in arr(shift.get('members'))]
            if any(eligible(t,u) for t,u in roster_candidates): blocked('Staff exist but the effective terminal assignment is unobserved')
            unmet('The resolved escalation graph has no eligible human terminal')
        limit=os.environ.get('SCOUTFLO_ONCALL_MAX_ESCALATION_MINUTES')
        if limit is not None:
            if not re.fullmatch(r'[0-9]+',limit): blocked('Declare a nonnegative whole-minute escalation objective')
            if not humans: blocked('No eligible timed human is established for the declared objective')
            if min(x['delay_minutes'] for x in humans)>int(limit): unmet('Configured delay to the first eligible human exceeds the declared objective',first_human_minutes=min(x['delay_minutes'] for x in humans),required_minutes=int(limit))
        evidence={'ordered_terminals':leaves,'first_human_minutes':min((x['delay_minutes'] for x in humans),default=None),'notification_effectiveness':'assess SOC-009 separately'}
    elif check=='SOC-004':
        leaves,refs=path(policy); staffing(refs); evidence={'referenced_rotations':len(refs)}
    elif check in ('SOC-005','SOC-007'):
        if check=='SOC-007':
            match=s.get('source_match')
            if not isinstance(match,dict): blocked('Exact source-key comparison is unavailable')
            aliases=arr(match.get('route_aliases'))
            if len(aliases)>1: blocked('Source key matched multiple route identities')
            if not aliases or policy not in arr(match.get('policies')): unmet('Exact source key does not select the intended policy')
            if ownership(policy)!=os.environ.get('SCOUTFLO_VERIFY_TEAM'): unmet('Source path owner differs from intended team')
        users,leaves,refs=current_path(policy); evidence={'users':sorted(users),'delivery_proven':False}
    elif check=='SOC-006':
        minimum=os.environ.get('SCOUTFLO_VERIFY_MIN_RESPONDERS','')
        if minimum=='none': stop('inapplicable','Explicit declaration: no responder redundancy requirement')
        if not re.fullmatch(r'[1-9][0-9]*',minimum): blocked('Declare a positive responder minimum or explicitly none')
        selected=json.loads(os.environ.get('SCOUTFLO_VERIFY_POLICIES') or json.dumps([policy]))
        if not isinstance(selected,list) or policy not in selected or len(set(selected))!=len(selected) or not all(identity(x) for x in selected): blocked('Invalid explicit policy set')
        users=set()
        for p in selected:
            try: users.update(current_path(p)[0])
            except Verdict: blocked('A required current policy path is not verified')
        evidence={'observed_responders':len(users),'required_responders':int(minimum)}
        if len(users)<int(minimum): unmet('Distinct current eligible responders are below the explicit requirement',**evidence)
    elif check=='SOC-009': evidence=contacts_check()
    elif check=='SOC-010':
        routes={r['alias'] for r in routing(policy)}; modes=arr(collected(q.get('maintenance'),'Maintenance'))
        relevant=[m for m in modes if m.get('global') is True or routes.intersection(arr(m.get('route_aliases')))]
        for mode in modes:
            if mode.get('unmatched_targets',0): blocked('An active maintenance target cannot be uniquely resolved')
        if relevant and os.environ.get('SCOUTFLO_ONCALL_EXPECT_PAGING')=='1': unmet('Active maintenance suppresses a path declared to accept new pages',instances=[m['id'] for m in relevant])
        for mode in relevant:
            intended=one(arr(attended.get('maintenance')),'id',mode['id'],'Active maintenance needs its declared owner and intended end')
            if intended.get('expected_active') is not True or intended.get('owner_confirmed') is not True: unmet('Active maintenance lacks the declared intentional ownership')
            if stamp(intended.get('end_at'))<=dt.datetime.now(dt.timezone.utc): unmet('Active maintenance continues after its declared intended end',instances=[mode['id']])
        evidence={'active_instances':[m['id'] for m in relevant],'global_instances':[m['id'] for m in relevant if m.get('global')],'new_incidents_only':True}
    elif check=='SOC-011':
        routing(policy); rules=arr(collected(q.get('transformations'),'Transformation'))
        if len({r.get('rank') for r in rules})!=len(rules) or len({r.get('id') for r in rules})!=len(rules): blocked('Rule identity or order is ambiguous')
        for rule in rules:
            if rule.get('route_rewrite') is True and len(arr(rule.get('route_aliases')))!=1: unmet('An observed route rewrite does not resolve to one routing identity',rule_id=rule['id'])
            proof=one(arr(attended.get('transformations')),'id',rule['id'],'Ordered transformation needs observed matching and nonmatching cases')
            cases=arr(proof.get('cases'))
            if not any(x.get('matched') is True for x in cases) or not any(x.get('matched') is False for x in cases): blocked('Transformation proof needs both positive and negative examples')
            for case in cases:
                expected=arr(case.get('expected_route_aliases')); actual=arr(case.get('observed_route_aliases'))
                known_aliases={r['alias'] for r in s['routes']}
                if any(not isinstance(x,str) or not re.fullmatch(r'route-[1-9][0-9]*',x) for x in expected+actual) or not set(expected+actual)<=known_aliases: blocked('Transformation evidence uses invalid or foreign route aliases')
                if type(case.get('identity_preserved')) is not bool or type(case.get('severity_expected')) is not bool: blocked('Transformation outcome evidence is incomplete')
                if set(expected)!=set(actual) or not case['identity_preserved'] or not case['severity_expected']: unmet('Observed ordered transformation changes the intended route, identity or severity',rule_id=rule['id'])
        evidence={'ordered_rule_ids':[r['id'] for r in sorted(rules,key=lambda x:x['rank'])],'predicate_engine':'provider-observed; no local regex emulation'}
    elif check=='SOC-016':
        leaves,refs=path(policy); start=stamp(os.environ.get('SCOUTFLO_ONCALL_HORIZON_START')); end=stamp(os.environ.get('SCOUTFLO_ONCALL_HORIZON_END'))
        if end<=start or (end-start).total_seconds()>123*86400: blocked('Declare a positive horizon within 123 days')
        owner=ownership(policy); detail=one(s['policy_details'],'slug',policy,'Policy detail missing'); needed=[i for i,st in enumerate(detail['steps']) if any(e.get('type') not in ('email','webhook') for e in st['entries'])]
        if not needed: stop('inapplicable','No enrolled-human schedule step is configured')
        summaries=[]
        for step in needed:
            proof=[r for r in attended.get('schedules',[]) if r.get('policy')==policy and r.get('step')==step]
            explicit=False
            if proof:
                if len(proof)!=1: blocked('Schedule evidence is ambiguous')
                proof=proof[0]
                if proof.get('complete') is not True or proof.get('boundaries_verified') is not True or stamp(proof.get('start'))!=start or stamp(proof.get('end'))!=end: blocked('Attended schedule evidence does not cover the exact requested horizon')
                intervals=arr(proof.get('intervals')); explicit=True
            else:
                if step>3: blocked('Later escalation step exceeds the public schedule query limit; provide attended intervals')
                reads=[r for r in q.get('schedules',[]) if r.get('team')==owner and r.get('step')==step]
                if len(reads)!=1: blocked('Requested schedule step was not collected')
                data=collected(reads[0],'Future schedule'); row=one(arr(data.get('policies')),'policy',policy,'Selected policy schedule is absent')
                if row.get('overrides'): blocked('Effective override intervals require attended boundary evidence')
                intervals=[{'start':r['start'],'end':r['end'],'users':[r['user']] if r.get('user') else []} for e in arr(row.get('entries')) for r in arr(e.get('rolls'))]
            parsed=[]
            for interval in intervals:
                a,b=stamp(interval.get('start')),stamp(interval.get('end'))
                if b<=a: blocked('Schedule interval has invalid ordering')
                if a<end and b>start:
                    users=arr(interval.get('users'))
                    if not users and not explicit: blocked('Provider roll omits an authoritative assignment; confirm the rendered empty interval')
                    terminal_owners={x['owner'] for x in leaves}
                    if any(not any(eligible(t,u) for t in terminal_owners) for u in users): unmet('Future interval contains an ineligible responder on its resolved terminal teams',step=step)
                    parsed.append((max(a,start),min(b,end),bool(users)))
            bounds=sorted({start,end}|{t for a,b,_ in parsed for t in (a,b)})
            gaps=[]
            for a,b in zip(bounds,bounds[1:]):
                covering=[x for x in parsed if x[0]<=a and x[1]>=b]
                if not covering:
                    if not explicit: blocked('Provider rolls do not establish complete boundary/gap semantics; supply attended rendered intervals')
                    gaps.append([a.isoformat(),b.isoformat()])
                elif not any(x[2] for x in covering): gaps.append([a.isoformat(),b.isoformat()])
            if gaps: unmet('Observed future coverage has an uncovered interval',step=step,gaps=gaps)
            summaries.append({'step':step,'intervals':len(parsed),'basis':'attended-rendered' if explicit else 'explicit-provider-rolls'})
        evidence={'start':start.isoformat(),'end':end.isoformat(),'steps':summaries,'coverage':'configuration at observation time'}
    elif check=='SOC-018':
        leaves,refs=path(policy); owner=ownership(policy)
        admin=one(arr(q.get('team_admins')),'team',owner,'Team admin read was not collected'); admins=arr(collected(admin,'Team administrator'))
        admin_required=os.environ.get('SCOUTFLO_ONCALL_REQUIRE_TEAM_ADMIN','')
        if admin_required not in ('','0','1'): blocked('Declare whether a dedicated team administrator is required')
        if not admins:
            if admin_required=='1': unmet('Owning team has no administrator required by the declared governance policy')
            if admin_required!='0': blocked('An empty team-admin census needs the dedicated-admin requirement or observed global ownership')
        if any(not eligible(owner,u) for u in admins): blocked('Team-admin enrollment or inherited global ownership is not established by team membership')
        incoming={x for r in s['routes'] for x in r['policies']}|{e.get('policy') for d in s['policy_details'] for step in d['steps'] for e in step['entries'] if e.get('type')=='policy_routing'}
        candidates=sorted(d['slug'] for d in s['policy_details'] if d['slug'] not in incoming)
        evidence={'team_admins':len(set(admins)),'unreferenced_policy_candidates':candidates,'candidate_meaning':'no observed route/nested consumer; external use and retention intent still unknown','global_access_governance':'attended evidence required; not inferred from team admin list'}
    stop('verified','Requested observed relationship is verified',**evidence)
except Verdict as verdict:
    result={'check':check,'policy':policy,'status':verdict.status,'reason':verdict.reason,'evidence':verdict.evidence,'affected':[policy] if identity(policy) else []}
    if check=='SOC-006': result.update({k:v for k,v in verdict.evidence.items() if k in ('observed_responders','required_responders')})
    print(json.dumps(result,separators=(',',':'),allow_nan=False))
    sys.exit({'verified':0,'not-met':1,'blocked':2,'inapplicable':3}[verdict.status])
except (ValueError,TypeError,KeyError,OSError,AttributeError,OverflowError):
    print(json.dumps({'check':check,'policy':policy if identity(policy) else None,'status':'blocked','reason':'Malformed, unsupported or incomplete projected evidence','evidence':{},'affected':[]})); sys.exit(2)
PY
```
<!-- oncall-effective-quality:end -->

## Retest and interpretation

SOC-003 now checks the full bounded policy graph (32 reference levels and 50,000 visited entries), including ordered relative-minute delays and nested dependencies. It preserves a waiting step's delay even when that step has no recipients. SOC-004 examines referenced shifts and eligible membership; SOC-005 separately verifies observed immediate users, so an unused or unstaffed alternate does not erase a valid immediate direct-user path. Next/previous rotations use observed next/prior periods, never inferred roster order. An incomplete prior period or an override that changes the effective user needs the exact attended/rendered proof; it is not silently treated as absent.

For maintenance/rules, repeat the exact read after an approved repair and rebind attended evidence to the new definitions. For contacts/global policy, verify the effective selected users after propagation and obtain separate receipt evidence only when required. For future coverage, compare the same horizon and each relevant step, including adjacent intervals and DST. For lifecycle candidates, confirm source use and retained-purpose requirements before proposing retirement. This recipe never authorizes deletion or broad administrative changes.
