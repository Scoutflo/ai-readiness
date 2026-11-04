# Assert attended configuration changes

The attended editor procedures use this read-only verifier before and after a save. It is a fixed set of management reads and exact comparators, not an API write executor. Management-visible fields come from GET responses; a screenshot or a person's assurance cannot replace them. Unsupported fields, partial collections and missing UI observations refuse verification. **Do not save an attended change until `check-before` passes and every required field is observable.**

## Choose the assertion

| `SOC_VERIFY_KIND` | Fixed management read and exact safe projection | Additional UI observation |
| --- | --- | --- |
| `route-mode` | Organization routing keys: exact selected key, full policy set, default flag and API mode when present | `isMultiResponder` boolean, explicitly UI-observed when API mode is absent |
| `policy` | Policy detail: name, custom-paging flag, ordered steps/delays and every target identity; email values use private keyed digests | None; direct destination equality is asserted by its keyed digest |
| `membership` | Selected team members: complete unique usernames and verified flags | None; also verify every reassigned shift/policy/override separately |
| `shift` | Selected shift: full timing/masks, ordered roster and scheduled verified user | `interval_start`, `interval_end`, `coverage_matches` for the exact rendered interval |
| `overrides` | Complete override list: identities, user, timezone, interval and all assignment references | `interval_start`, `interval_end`, `coverage_matches` for the affected rendered interval |
| `maintenance` | Complete active instances: identities, global flag and exact keyed routing identities | `end_mechanism_present`; its concrete owner/provider expiry remains in the approved plan |
| `alert-rules` | Complete ordered rules: predicate, rank, stop flag, route and annotation digests; no volatile update timestamps | `positive_match` and `negative_match` from the provider preview; false is a failed intended test |
| `paging` | Selected user's complete ordered policy steps, timeouts, rule types and contact IDs/types | None; contact verification is a separate check |
| `contacts` | Contact collections: type and keyed identity/label; verified when the API exposes it | `selected_contact_hash`, `selected_contact_present` and `selected_contact_verified` for the exact selected contact; omitted API verification remains null, never false |
| `incoming` | Exact management routing mapping for the source's protected route reference | `integration_enabled`; the sender's loaded-config check stays in its owning source workflow |
| `value-digest` | No object read beyond the identity anchor; compute the keyed digest of one protected proposed value | None; supplies an expected hash for a changed private predicate, annotation, email or routing value |

`SOC_OBJECT_ID` is the policy slug for `policy`, or enrolled username for `paging`/`contacts`. `SOC_GROUP_ID` and `SOC_SHIFT_ID` select a shift. Route/incoming assertions take `SOC_ROUTE_ENV`, the name of a protected secret-store variable. Their binding also includes `route_value_hash`, the private HMAC of that variable's actual value. Changing the protected routing value requires a new baseline and approval even when the variable name and routing configuration stay identical. `value-digest` takes `SOC_VALUE_ENV`, also a variable name, never a literal value; it can supply this same digest for the UI observation's object binding. Hashes are private HMACs bound to the read credential; rotation of that credential requires a new baseline. Raw routing values are never retained in the receipt.

The verifier accepts only the declared fields and types. If a provider variant differs, stop and name that shape gap; do not reduce the comparator to a count or manually mark it matched. New IDs allocated by an attended create must come from the saved provider object view and be bound into the expected record; they are not guessed. Deletion is checked through complete parent collections. A missing object or a failed GET is not a successful comparison.

## Before, expected change and after

1. Create a private directory with mode 0700 for this attended action under the selected target's setup folder. Choose a new `SOC_VERIFY_OUTPUT` filename for every read; files are created exclusively with mode 0600. Set `SOC_VERIFY_KIND`, the selectors above and `SOC_VERIFY_MODE=capture`, then run the block. For kinds needing UI facts, supply the observation described below first. This captures the complete safe baseline.
2. Preserve that baseline. Make a separate expected-state copy containing only the approved field changes. Keep `schema`, `binding`, `credential_fingerprint`, `captured_at` and original UI observation provenance unchanged. `api` must retain every unaffected projected field; `ui.values` must name the exact intended UI state. Compute new private-value hashes with `value-digest` using protected store variables. Do not copy raw contact, annotation or incoming values into expected files.
3. Immediately before the attended save, run `SOC_VERIFY_MODE=check-before` with `SOC_VERIFY_EXPECTED` pointing to the unchanged baseline, a fresh UI observation where required and a new output path. It performs fresh GETs and exact equality. Any difference refuses the save. Set `SOC_VERIFY_EXPECTED_SHA256` to the SHA-256 of the selected expected file; bind the intended after-file checksum and affected objects to the explicit change approval; editing it afterward requires a revised confirmation.
4. Save the approved provider edit once. Run `check-after` with the approved expected after-file, new GETs, a new output path and a separately captured UI after-observation. API equality must hold. UI values must also equal the plan, with a later timestamp and different evidence digest. A reused screenshot, stale observation, false required coverage/match predicate or unverifiable field fails. Keep the receipt as **UI-observed**, never API proof of an omitted field.
5. For restoration, retain the verified post-state as the new before-file, prepare the exact inverse after-file, obtain its approval and repeat `check-before` → attended save → `check-after`. Repeat assertions for every dependency changed by a member reassignment or retirement. If any comparison fails, stop subsequent edits and reconcile without replaying the save.

## Capture UI-only facts

`SOC_UI_OBSERVATION` points to a private JSON observation written from the current trusted browser-tool output or a human's current provider view. It has exactly `source` (`provider-ui`), `observer` (`browser-tool` or `human`), `observed_at` (UTC epoch seconds), `object` (the baseline's exact `binding` object), `evidence_file` (private redacted tool/view record), `evidence_sha256` (hash of that actual record), and `values` (only the fields in the table for this kind). The observation must be at most five minutes old. Capture no credentials, addresses, device tokens or full integration URLs. The evidence digest binds the observation to a file; it does **not** authenticate the human assertion or convert UI evidence into API data. Record the actual tool/view provenance, never manufacture a file to satisfy the guard. If a control is hidden or unreadable, do not save the change.

For an intended enabled/verified/covered/matching result, the corresponding boolean must be true in the after-file. Disabling an integration or ending maintenance is a separately approved inverse with its exact intended state. The end procedure must be established before beginning maintenance; the verifier cannot supply a missing timer or absent operator.

<!-- oncall-attended-verification:start -->
```bash
set -eu
set +x
umask 077
SOC_VERIFY_MODE="${SOC_VERIFY_MODE:-capture}"
SOC_VERIFY_KIND="${SOC_VERIFY_KIND:-}"
SOC_VERIFY_OUTPUT="${SOC_VERIFY_OUTPUT:-}"
SOC_VERIFY_EXPECTED="${SOC_VERIFY_EXPECTED:-}"
SOC_VERIFY_EXPECTED_SHA256="${SOC_VERIFY_EXPECTED_SHA256:-}"
SOC_UI_OBSERVATION="${SOC_UI_OBSERVATION:-}"
SOC_OBJECT_ID="${SOC_OBJECT_ID:-}"
SOC_GROUP_ID="${SOC_GROUP_ID:-}"
SOC_SHIFT_ID="${SOC_SHIFT_ID:-}"
SOC_ROUTE_ENV="${SOC_ROUTE_ENV:-}"
SOC_VALUE_ENV="${SOC_VALUE_ENV:-}"
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for candidate in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null 2>&1 || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$candidate" ] && { CFG="$candidate"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'Missing config'; exit 1; }
for bin in curl jq shasum python3; do command -v "$bin" >/dev/null 2>&1 || { echo "Missing $bin"; exit 1; }; done
python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || { echo 'Python 3.9 or newer is required'; exit 1; }
SOC_CURL_VERSION=$(curl --version | awk 'NR==1 {print $2}')
printf '%s\n' "$SOC_CURL_VERSION" | awk -F. '$1>8 || ($1==8 && $2>=4) {ok=1} END {exit !ok}' || { echo 'curl 8.4 or newer is required for bounded reads'; exit 1; }
TT="${CLAUDE_PLUGIN_ROOT:-.}/report-standard/toolkit-targets.sh"
SOC_KIND=$(sh "$TT" "$CFG" splunk_oncall kind); SOC_N=$(sh "$TT" "$CFG" splunk_oncall count)
[ "$SOC_N" -ge 1 ] || { echo 'No splunk_oncall target'; exit 1; }
SOC_IDX=0
if [ "$SOC_KIND" = seq ]; then
  SOC_LABELS=$(sh "$TT" "$CFG" splunk_oncall labels)
  SOC_LI=0
  while [ "$SOC_LI" -lt "$SOC_N" ]; do
    case "$(sh "$TT" "$CFG" splunk_oncall get "$SOC_LI" label)" in ''|*[!A-Za-z0-9_-]*) echo 'List targets require explicit safe labels'; exit 1;; esac
    SOC_LI=$((SOC_LI+1))
  done
  printf '%s\n' "$SOC_LABELS" | awk '$0 !~ /^[A-Za-z0-9_-]+$/ || seen[$0]++ {bad=1} END {exit bad}' || { echo 'Invalid or duplicate target labels'; exit 1; }
  [ -n "${SCOUTFLO_TARGET:-}" ] || { echo 'Select SCOUTFLO_TARGET for setup'; exit 1; }
  SOC_MATCHES=0; SOC_I=0
  while [ "$SOC_I" -lt "$SOC_N" ]; do
    if [ "$(sh "$TT" "$CFG" splunk_oncall label "$SOC_I")" = "$SCOUTFLO_TARGET" ]; then SOC_IDX=$SOC_I; SOC_MATCHES=$((SOC_MATCHES+1)); fi
    SOC_I=$((SOC_I+1))
  done
  [ "$SOC_MATCHES" -eq 1 ] || { echo 'SCOUTFLO_TARGET must match exactly one splunk_oncall label'; exit 1; }
fi
SOC_LABEL=$(sh "$TT" "$CFG" splunk_oncall label "$SOC_IDX")
case "$SOC_LABEL" in ''|*[!A-Za-z0-9_-]*) echo 'Unsafe target label'; exit 1;; esac
SOC_SEG=splunk_oncall; [ "$SOC_KIND" != seq ] || SOC_SEG="splunk_oncall/$SOC_LABEL"
SOC_TEAM=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" team_slug)
case "$SOC_TEAM" in ''|*[!A-Za-z0-9_-]*) echo 'Invalid team_slug'; exit 1;; esac
SOC_ID_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_id_env)
SOC_READ_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" api_key_env)
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f './.scoutflo/env' ]; then SCOUTFLO_ENV='./.scoutflo/env'; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
soc_secret() {
  case "$1" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1;; esac
  sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || exit 1; fi; printenv "$2"' _ "$SCOUTFLO_ENV" "$1" 2>/dev/null
}
SOC_ID=$(soc_secret "$SOC_ID_VAR") || { echo 'Missing management API ID'; exit 1; }
SOC_READ=$(soc_secret "$SOC_READ_VAR") || { echo 'Missing read-only key'; exit 1; }
[ -n "$SOC_ID" ] && [ -n "$SOC_READ" ] || { echo 'Read credentials are empty'; exit 1; }
for SOC_HEADER in "$SOC_ID" "$SOC_READ"; do
  printf '%s' "$SOC_HEADER" | jq -Rse 'test("[\\r\\n]")|not' >/dev/null || { echo 'Invalid header'; exit 1; }
done
SOC_ROUTE_SECRET=''; SOC_VALUE_SECRET=''
case "$SOC_VERIFY_KIND" in route-mode|incoming) SOC_ROUTE_SECRET=$(soc_secret "$SOC_ROUTE_ENV") || { echo 'Missing protected route'; exit 1; };; value-digest) SOC_VALUE_SECRET=$(soc_secret "$SOC_VALUE_ENV") || { echo 'Missing protected expected value'; exit 1; };; esac
export SOC_VERIFY_EXPECTED_SHA256
export SOC_ID SOC_READ SOC_TEAM SOC_SEG SOC_VERIFY_MODE SOC_VERIFY_KIND SOC_VERIFY_OUTPUT SOC_VERIFY_EXPECTED SOC_UI_OBSERVATION SOC_OBJECT_ID SOC_GROUP_ID SOC_SHIFT_ID SOC_ROUTE_ENV SOC_ROUTE_SECRET SOC_VALUE_SECRET
python3 - <<'PY_VERIFY'
import hashlib,hmac,json,os,pathlib,re,subprocess,sys,time
class Stop(Exception):pass
def require(ok,msg):
    if not ok:raise Stop(msg)
def canonical(x):return json.dumps(x,sort_keys=True,separators=(',',':'))
def ident(x):
    require(isinstance(x,str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,128}',x) and x not in ('.','..'),'Invalid identity');return x
def boolean(x):require(type(x) is bool,'Expected boolean');return x
def integer(x):require(type(x) is int and x>=0,'Expected nonnegative integer');return x
def string(x):require(isinstance(x,str) and len(x)<=4096,'Expected bounded string');return x
def safe_text(x):
    string(x);require(not re.search(r'://|@|[\r\n]|token|password|secret|api.?key',x,re.I),'Unsafe display metadata');return x
def shape(x,required,optional=()):
    require(isinstance(x,dict) and set(required)<=set(x)<=set(required)|set(optional),'Unsupported field set');return x
def array(x):require(isinstance(x,list),'Expected complete array');return x
def digest(x):return hmac.new(os.environ['SOC_READ'].encode(),canonical(x).encode(),hashlib.sha256).hexdigest()
def pairs(items):
    out={}
    for k,v in items:require(k not in out,'Duplicate JSON field');out[k]=v
    return out
def parse(x):return json.loads(x,object_pairs_hook=pairs,parse_constant=lambda x:(_ for _ in ()).throw(Stop('Invalid JSON number')))
def load(path):
    path=pathlib.Path(path);require(path.is_file() and not path.is_symlink(),'Unsafe record path');return parse(path.read_text())
def save(path,value):
    require(not any(s in canonical(value) for s in (os.environ['SOC_ID'],os.environ['SOC_READ'])),'Credential content refused')
    fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as f:f.write(canonical(value)+'\n')
def get(path):
    subprocess.run(['sleep','1'],check=True)
    cfg='header = '+json.dumps('X-VO-Api-Id: '+os.environ['SOC_ID'])+'\nheader = '+json.dumps('X-VO-Api-Key: '+os.environ['SOC_READ'])+'\n'
    r=subprocess.run(['curl','-q','-sS','--config','-','--request','GET','--proto','=https','--max-redirs','0','--connect-timeout','5','--max-time','20','--max-filesize','1048576','-w','\n%{http_code}','https://api.victorops.com'+path],input=cfg,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    require(r.returncode==0,'Incomplete read; no mutation authorized')
    body,sep,status=r.stdout.rpartition('\n');require(sep and status=='200','Read failed or throttled; stop without retry')
    return parse(body)
def user(x):
    shape(x,('username',),('verified','firstName','lastName'));return ident(x['username'])
def route():
    require(route_key,'Set the protected route variable')
    raw=shape(get('/api-public/v1/org/routing-keys'),('routingKeys',),('_selfUrl',));rows=array(raw['routingKeys']);matches=[]
    for r in rows:
        shape(r,('routingKey','targets','isDefault'),('isMultiResponder',));string(r['routingKey']);boolean(r['isDefault'])
        targets=[]
        for t in array(r['targets']):shape(t,('policySlug',),('policyName','_teamUrl'));targets.append(ident(t['policySlug']))
        require(len(set(targets))==len(targets),'Duplicate route target')
        if r['routingKey']==route_key:matches.append({'policy_slugs':sorted(targets),'is_default':r['isDefault'],'api_mode':boolean(r['isMultiResponder']) if 'isMultiResponder' in r else None})
    require(len(matches)==1,'Selected route is absent or ambiguous');return matches[0]
def policy():
    raw=shape(get('/api-public/v1/policies/'+ident(object_id)),('slug','name','steps','ignoreCustomPagingPolicies'),('_selfUrl',));require(raw['slug']==object_id,'Policy identity differs')
    steps=[]
    for s in array(raw['steps']):
        shape(s,('timeout','entries'));entries=[]
        for e in array(s['entries']):
            k=e.get('executionType');field={'user':'user','rotation_group':'rotationGroup','rotation_group_next':'rotationGroup','rotation_group_previous':'rotationGroup','policy_routing':'targetPolicy','webhook':'webhook','email':'email'}.get(k)
            require(field is not None,'Unknown policy target type');shape(e,('executionType',field));v=e[field]
            if field=='user':shape(v,('username',),('firstName','lastName'));ref=ident(v['username'])
            elif field=='targetPolicy':shape(v,('policySlug',),('policyName',));ref=ident(v['policySlug'])
            elif field=='email':shape(v,('address',));ref=digest(string(v['address']))
            else:shape(v,('slug',),('label',));ref=ident(v['slug'])
            entries.append({'kind':k,'identity':ref})
        steps.append({'timeout':integer(s['timeout']),'entries':entries})
    return {'name':safe_text(raw['name']),'ignore_custom_paging':boolean(raw['ignoreCustomPagingPolicies']),'steps':steps}
def members():
    raw=shape(get('/api-public/v1/team/'+team+'/members'),('members',),('_selfUrl','_teamUrl'));rows=[]
    for u in array(raw['members']):require(isinstance(u,dict),'Invalid member');rows.append({'username':ident(u.get('username')),'verified':boolean(u.get('verified'))})
    require(len({u['username'] for u in rows})==len(rows),'Duplicate member');return {'members':sorted(rows,key=lambda x:x['username'])}
def shift():
    base='/api-public/v1/teams/'+team+'/rotations/'+str(group_id)+'/'+str(shift_id)
    r=get(base+'?skip=0&count=1');fields=('label','timezone','start','duration','shifttype','mask')
    shape(r,fields+('team_slug','group_id','rot_id','shiftMembers'),('mask2','mask3','org_slug','usernames','periods','current','next','oncall'))
    require(r['team_slug']==team and r['group_id']==group_id and r['rot_id']==shift_id,'Shift identity differs')
    cfg={k:r[k] for k in fields+('mask2','mask3') if k in r and r[k] is not None}
    for k in ('label','timezone','shifttype'):safe_text(cfg[k])
    integer(cfg['start']);integer(cfg['duration'])
    for key in ('mask','mask2','mask3'):
        if key not in cfg:continue
        m=shape(cfg[key],('day','time'));shape(m['day'],('su','m','t','w','th','f','sa'))
        for val in m['day'].values():boolean(val)
        for span in array(m['time']):
            shape(span,('start','end'))
            for point in span.values():shape(point,('hour','minute'));require(integer(point['hour'])<=24 and integer(point['minute'])<60,'Invalid clock')
    roster=[{'slug':ident(u.get('slug')),'username':ident(u.get('username'))} for u in array(r['shiftMembers'])]
    if 'usernames' in r:require(r['usernames']==[u['username'] for u in roster],'Roster projections disagree')
    duty=get(base+'/scheduled')
    if duty is not None:duty={'username':ident(duty.get('username')),'verified':boolean(duty.get('verified'))}
    return {'config':cfg,'roster':roster,'scheduled':duty}
def overrides():
    r=shape(get('/api-public/v1/overrides'),('overrides',),('_selfUrl',));rows=[]
    for x in array(r['overrides']):
        shape(x,('publicId','user','timezone','start','end','assignments'));assign=[]
        for a in array(x['assignments']):
            shape(a,('team','policy','assigned','user'),('_selfUrl',));assign.append({'team':ident(a['team']),'policy':ident(a['policy']),'assigned':boolean(a['assigned']),'user':ident(a['user'])})
        rows.append({'id':ident(x['publicId']),'user':user(x['user']),'timezone':safe_text(x['timezone']),'start':safe_text(x['start']),'end':safe_text(x['end']),'assignments':assign})
    return {'overrides':sorted(rows,key=lambda x:x['id'])}
def maintenance():
    r=shape(get('/api-public/v1/maintenancemode'),('activeInstances',),('companyId',));rows=[]
    for x in array(r['activeInstances']):
        shape(x,('instanceId','isGlobal','targets'),('startedBy','startedAt'));targets=[]
        for t in array(x['targets']):shape(t,('type','names'));require(t['type']=='RoutingKeys','Unknown maintenance target');targets.extend(digest(string(n)) for n in array(t['names']))
        rows.append({'id':ident(x['instanceId']),'is_global':boolean(x['isGlobal']),'route_hashes':sorted(targets)})
    return {'instances':sorted(rows,key=lambda x:x['id'])}
def rules():
    rows=[]
    for r in array(get('/api-public/v1/alertRules')):
        shape(r,('id','alertField','alertValueMatch','matchType','rank','stopFlag','annotations'),('lastUpdated','lastUpdatedBy','notes','routeKey'));ann=[]
        for a in array(r['annotations']):shape(a,('id','annotationType','fieldName','fieldValue','flags'));ann.append({'id':integer(a['id']),'kind':safe_text(a['annotationType']),'field':safe_text(a['fieldName']),'value_hash':digest(string(a['fieldValue'])),'flags':integer(a['flags'])})
        require(r['matchType'] in ('WILDCARD','REGEX'),'Unknown match type')
        rows.append({'id':integer(r['id']),'field':safe_text(r['alertField']),'match_hash':digest(string(r['alertValueMatch'])),'match_type':r['matchType'],'rank':integer(r['rank']),'stop':boolean(r['stopFlag']),'route_hash':digest(string(r.get('routeKey',''))),'annotations':ann})
    return {'rules':sorted(rows,key=lambda x:(x['rank'],x['id']))}
def paging():
    raw=shape(get('/api-public/v1/profile/'+ident(object_id)+'/policies'),('steps',),('_selfUrl',));steps=[]
    for s in array(raw['steps']):
        shape(s,('index','timeout','rules'));rs=[]
        for r in array(s['rules']):
            shape(r,('index','type','contact'));c=shape(r['contact'],('id','type'));require(r['type'] in ('push','email','sms','phone'),'Unknown paging rule')
            rs.append({'index':integer(r['index']),'type':r['type'],'contact':{'id':integer(c['id']),'type':safe_text(c['type'])}})
        steps.append({'index':integer(s['index']),'timeout':integer(s['timeout']),'rules':rs})
    return {'steps':steps}
def contacts():
    raw=shape(get('/api-public/v1/user/'+ident(object_id)+'/contact-methods'),('devices','emails','phones'));out={}
    for kind in ('devices','emails','phones'):
        rows=[]
        for c in array(raw[kind]):
            shape(c,('label','extId'),('deviceType','_selfUrl','id','verified'))
            rows.append({'identity_hash':digest(string(c['extId'])),'label_hash':digest(string(c['label'])),'type':safe_text(c.get('deviceType',kind)),'verified':boolean(c['verified']) if 'verified' in c else None})
        out[kind]=sorted(rows,key=lambda x:x['identity_hash'])
    return out
UI_FIELDS={'value-digest':{},'route-mode':{'isMultiResponder':bool},'policy':{},'membership':{},'shift':{'interval_start':str,'interval_end':str,'coverage_matches':bool},'overrides':{'interval_start':str,'interval_end':str,'coverage_matches':bool},'maintenance':{'end_mechanism_present':bool},'alert-rules':{'positive_match':bool,'negative_match':bool},'paging':{},'contacts':{'selected_contact_hash':str,'selected_contact_present':bool,'selected_contact_verified':bool},'incoming':{'integration_enabled':bool}}
def ui_observation():
    fields=UI_FIELDS[kind]
    if not fields:return None
    r=shape(load(os.environ['SOC_UI_OBSERVATION']),('source','observer','observed_at','object','evidence_file','evidence_sha256','values'))
    require(r['source']=='provider-ui' and r['observer'] in ('human','browser-tool'),'UI observation provenance missing')
    require(r['object']==binding,'UI observation belongs to another object')
    require(type(r['observed_at']) is int and 0<=time.time()-r['observed_at']<=300,'UI observation is stale or from the future')
    e=pathlib.Path(r['evidence_file']);require(e.is_file() and not e.is_symlink(),'UI evidence file unavailable')
    require(hashlib.sha256(e.read_bytes()).hexdigest()==r['evidence_sha256'],'UI evidence checksum differs')
    shape(r['values'],fields)
    for key,typ in fields.items():require(type(r['values'][key]) is typ,'UI observed field has wrong type')
    for val in r['values'].values():
        if isinstance(val,str):safe_text(val)
    return {k:r[k] for k in ('source','observer','observed_at','evidence_sha256','values')}
try:
    mode=os.environ['SOC_VERIFY_MODE'];kind=os.environ['SOC_VERIFY_KIND'];require(mode in ('capture','check-before','check-after'),'Choose capture/check-before/check-after')
    require(kind in UI_FIELDS,'Unsupported verification kind')
    team=ident(os.environ['SOC_TEAM']);object_id=os.environ.get('SOC_OBJECT_ID','');group_id=int(os.environ.get('SOC_GROUP_ID') or '0');shift_id=int(os.environ.get('SOC_SHIFT_ID') or '0');route_key=os.environ.get('SOC_ROUTE_SECRET','')
    require(group_id>=0 and shift_id>=0,'Invalid rotation identity')
    if object_id:ident(object_id)
    binding={'target':os.environ['SOC_SEG'],'team':team,'kind':kind,'object':object_id,'group':group_id,'shift':shift_id,'route_ref':os.environ.get('SOC_ROUTE_ENV','')}
    if kind in ('route-mode','incoming'):
        require(route_key,'Set the protected route variable');binding['route_value_hash']=digest(string(route_key))
    fingerprint=digest([os.environ['SOC_ID'],os.environ['SOC_READ']])
    anchor=get('/api-public/v1/team/'+team);require(isinstance(anchor,dict) and anchor.get('slug')==team,'Team anchor differs')
    projections={'value-digest':lambda:{'value_hash':digest(string(os.environ['SOC_VALUE_SECRET']))},'route-mode':route,'incoming':route,'policy':policy,'membership':members,'shift':shift,'overrides':overrides,'maintenance':maintenance,'alert-rules':rules,'paging':paging,'contacts':contacts}
    current=projections[kind]();ui=ui_observation();now=int(time.time())
    if kind=='route-mode' and current['api_mode'] is not None:require(ui['values']['isMultiResponder']==current['api_mode'],'UI and API responder mode disagree')
    if kind=='contacts':
        values=ui['values'];require(re.fullmatch(r'[a-f0-9]{64}',values['selected_contact_hash']),'Invalid selected contact digest')
        selected=[c for rows in current.values() for c in rows if c['identity_hash']==values['selected_contact_hash']]
        require(len(selected)==int(values['selected_contact_present']),'UI contact presence disagrees with API')
        require(values['selected_contact_present'] or not values['selected_contact_verified'],'Absent contact cannot be verified')
        if selected and selected[0]['verified'] is not None:require(selected[0]['verified']==values['selected_contact_verified'],'UI and API contact verification disagree')
    if mode=='check-after' and kind in ('shift','overrides'):require(ui['values']['coverage_matches'],'Rendered coverage did not match')
    if mode=='check-after' and kind=='alert-rules':require(ui['values']['positive_match'] and ui['values']['negative_match'],'Rule preview did not match expected positive and negative cases')
    if mode=='check-after' and kind=='maintenance' and current['instances']:require(ui['values']['end_mechanism_present'],'Active maintenance has no established end mechanism')
    record={'schema':'scoutflo-oncall-attended/v1','binding':binding,'credential_fingerprint':fingerprint,'captured_at':now,'api':current,'ui':ui}
    if mode!='capture':
        expected_path=pathlib.Path(os.environ['SOC_VERIFY_EXPECTED'])
        require(hashlib.sha256(expected_path.read_bytes()).hexdigest()==os.environ['SOC_VERIFY_EXPECTED_SHA256'],'Expected file differs from its approved checksum')
        expected=load(expected_path);shape(expected,('schema','binding','credential_fingerprint','captured_at','api','ui'))
        require(expected['schema']==record['schema'] and expected['binding']==binding and expected['credential_fingerprint']==fingerprint,'Expected record target or credentials differ')
        require(type(expected['captured_at']) is int and 0<=now-expected['captured_at']<=1800,'Expected plan is stale; re-read and approve')
        require(current==expected['api'],'API fields differ from exact expected state')
        require((ui is None and expected['ui'] is None) or (ui is not None and isinstance(expected['ui'],dict) and ui['values']==expected['ui'].get('values')),'UI-only fields differ or were not observed')
        if mode=='check-after' and ui is not None:require(ui['observed_at']>expected['ui']['observed_at'] and ui['evidence_sha256']!=expected['ui']['evidence_sha256'],'After-state needs a fresh independently captured UI observation')
    out=pathlib.Path(os.environ['SOC_VERIFY_OUTPUT']);require(out.parent.is_dir() and not out.parent.is_symlink() and out.parent.stat().st_mode & 0o077==0,'Create a private mode-0700 output directory first');save(out,record)
    print(canonical({'mode':mode,'kind':kind,'api':'captured' if mode=='capture' else 'exact-match','ui':'not-required' if ui is None else 'UI-observed, not API proof','record':str(out)}))
except (Stop,KeyError,ValueError,TypeError,OSError,subprocess.SubprocessError) as e:
    print(str(e) if isinstance(e,Stop) else 'Invalid or unsupported verification input; do not save a UI change',file=sys.stderr);sys.exit(1)

PY_VERIFY
unset SOC_ID SOC_READ SOC_ROUTE_SECRET SOC_VALUE_SECRET SOC_HEADER
```
<!-- oncall-attended-verification:end -->

Run the setup Doctor and live-safety gates first. These assertions need only the configured read-only key; they never load a setup key or send a notification. Each operation's populated live schema and permission must still be observed before declaring its UI workflow verified. The hermetic suite executes the published block; it is not live provider evidence.
