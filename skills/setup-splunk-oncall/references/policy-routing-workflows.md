# Escalation policies and routing keys

These workflows configure existing, verified responders and rotations. They do not send alerts, invite people, enroll contacts or change the default routing key. They use the management API, not the incoming-alert endpoint. Creation, replacement and retirement are different actions; a deleted object is not restored under the same identity.

## Inputs and exact change protocol

Run the single block below in a fresh shell for each mode. Run the main skill's Doctor gate first. The configured `team_slug` is both the account anchor and the team for these policy operations. Use a separate labeled config when operating on another team; never change the shared default config during parallel work.

| Input | Meaning |
| --- | --- |
| `SOC_OPERATION` | `policy-create`, `policy-replace`, `policy-retire`, `route-create`, `route-replace`, or `route-retire` |
| `SOC_MODE` | `plan`, `apply`, `restore`, `inspect`, or read-only `reconcile`; default `plan` |
| `SOC_RUN_ID` | Unique safe local action label; reuse only for the saved plan |
| `SOC_POLICY_SLUG` | Existing policy for replace/retire; not used for creation |
| `SOC_POLICY_FILE` | Private JSON file for policy create/replace. Create: `{name,ignoreCustomPagingPolicies,steps}`. Replace: `{ignoreCustomPagingPolicies,steps}`. Flags must be explicit; no default false. |
| `SOC_ROUTE_ENV` | Name of a dedicated secret-store variable for the routing key. Create plan generates and saves a value if absent; other operations require an existing value. Values are never printed or accepted as command-line arguments. |
| `SOC_ROUTE_TARGETS` | Comma-separated exact existing policy slugs for route create/replace; all must belong to the configured team |
| `SOC_CREATED_RUN` | Creation journal label proving run ownership before a retirement plan |
| `SOC_UNUSED_CONFIRMED` | `yes` only after checking external senders/active use for a retirement or create-restoration; it is not inferred from an empty management list |
| `SOC_APPROVED_PLAN` | `apply:<sha256>` or `restore:<sha256>`, supplied only after the conversation approves the printed exact plan and effect. Read-only reconcile retains the original `apply:` checksum. Never preset during plan. |
| `SOC_LEGACY_ATTEMPT_PLAN_SHA256` | Original approved checksum recovered from a contemporaneous operator receipt, only for an older attempted policy-create journal without `plan_sha256`; never a newly computed replacement. |

A policy step is `{timeout:<whole minutes>,entries:[...]}`. Automatic policy entries support `user:{username}`, `rotationGroup:{slug}` with `rotation_group`, `rotation_group_next`, or `rotation_group_previous`, and `targetPolicy:{policySlug}` with `policy_routing`. The selected users must be enrolled team members; referenced rotations must belong to the selected team; referenced policies are cycle-checked. Email and webhook entries require the guided destination workflow below because their authority and private payloads differ.

For route replacement, current GET must expose a boolean `isMultiResponder`. The block refuses when it is absent. An old receipt or a user-entered false is not API preservation proof; use the guided UI procedure below. Route create does not invent a mode absent from the documented POST payload.

The plan directory is mode 0700, files 0600, under the resolved target. The checksum binds approval to exact saved bytes, but does not itself grant permission. Plan/apply compare both credential tiers against the configured team and bind the exact credential generation privately. Apply rechecks the complete relevant state and dependencies. Policy changes bind the exact hashed routing identities and mappings before and after the write; an unchanged consumer count is insufficient. All collection reads reject unknown pagination/count/total fields rather than treating a subset as complete. POST/PUT/DELETE is attempted once; an uncertain response is reconciled by GET. A persistent attempt marker prevents retries, including after process termination. `inspect` makes reads and reports equality only; it never clears that marker. After an interrupted policy-create readback, `reconcile` may complete the ownership receipt using fresh reads and the original approved checksum; it never retries POST or clears the attempt marker. Other unknown operations remain inspect-only until their own recovery is supported. There is no conditional provider update, so keep the attended object stable between preread and write.

## Prepare, apply, inspect, reconcile or restore

The provider's Swagger documents the operations below, including PUT policy replacement despite older POST prose describing policies as immutable. Live acceptance and full field preservation must be recorded per operation against your account; a successful plan or fixture test is not write proof. Unknown fields or unsupported policy variants stop before a mutation.

<!-- oncall-policy-routing:start -->
```bash
set -eu
set +x
umask 077
SOC_MODE="${SOC_MODE:-plan}"
SOC_LEGACY_ATTEMPT_PLAN_SHA256="${SOC_LEGACY_ATTEMPT_PLAN_SHA256:-}"
export SOC_LEGACY_ATTEMPT_PLAN_SHA256
SOC_RUN_ID="${SOC_RUN_ID:-}"
SOC_OPERATION="${SOC_OPERATION:-}"
case "$SOC_MODE" in plan|apply|restore|inspect|reconcile) ;; *) echo 'Invalid mode'; exit 1;; esac
case "$SOC_OPERATION" in policy-create|policy-replace|policy-retire|route-create|route-replace|route-retire) ;; *) echo 'Choose a documented policy or route operation'; exit 1;; esac
case "$SOC_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo 'Set a safe unique SOC_RUN_ID'; exit 1;; esac
CFG="${SCOUTFLO_CONFIG:-}"
[ -n "$CFG" ] || for candidate in './.scoutflo/toolkit.yaml' "$(cat "$HOME/.scoutflo/active-config" 2>/dev/null 2>&1 || true)" "$HOME/.scoutflo/toolkit.yaml"; do [ -f "$candidate" ] && { CFG="$candidate"; break; }; done
[ -n "$CFG" ] && [ -f "$CFG" ] || { echo 'Missing config'; exit 1; }
for bin in curl jq shasum python3; do command -v "$bin" >/dev/null 2>&1 || { echo "Missing $bin"; exit 1; }; done
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
SOC_WRITE_VAR=$(sh "$TT" "$CFG" splunk_oncall get "$SOC_IDX" setup_api_key_env)
SCOUTFLO_ENV="${SCOUTFLO_ENV_FILE:-}"
[ -n "$SCOUTFLO_ENV" ] || { if [ -f './.scoutflo/env' ]; then SCOUTFLO_ENV='./.scoutflo/env'; else SCOUTFLO_ENV="$HOME/.scoutflo/env"; fi; }
soc_secret() {
  case "$1" in ''|[0-9]*|*[!A-Za-z0-9_]*) return 1;; esac
  sh -c 'set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || exit 1; fi; printenv "$2"' _ "$SCOUTFLO_ENV" "$1" 2>/dev/null
}
SOC_ID=$(soc_secret "$SOC_ID_VAR") || { echo 'Missing management API ID'; exit 1; }
SOC_READ=$(soc_secret "$SOC_READ_VAR") || { echo 'Missing read-only key'; exit 1; }
SOC_WRITE=$(soc_secret "$SOC_WRITE_VAR") || { echo 'Missing separate setup key'; exit 1; }
[ -n "$SOC_ID" ] && [ -n "$SOC_READ" ] && [ -n "$SOC_WRITE" ] && [ "$SOC_READ" != "$SOC_WRITE" ] || { echo 'Require separate nonempty credentials'; exit 1; }
for SOC_VALUE in "$SOC_ID" "$SOC_READ" "$SOC_WRITE"; do
  printf '%s' "$SOC_VALUE" | jq -Rse 'test("[\\r\\n]")|not' >/dev/null 2>&1 || { echo 'Invalid credential format'; exit 1; }
done
# NUL-separated components cannot collide by concatenation; header values exclude NUL.
# The digest stays in the protected plan. Do not print it or use it as tenant proof.
SOC_HASH_LINE=$(printf '%s\0' "$SOC_ID" "$SOC_READ" "$SOC_WRITE" | shasum -a 256) || { echo 'Cannot bind credentials; hash failed'; exit 1; }
SOC_CREDENTIAL_FINGERPRINT=${SOC_HASH_LINE%% *}
printf '%s\n' "$SOC_CREDENTIAL_FINGERPRINT" | grep -Eq '^[a-f0-9]{64}$' || { echo 'Invalid credential fingerprint'; exit 1; }
SOC_APPROVED_PLAN="${SOC_APPROVED_PLAN:-}"
SOC_POLICY_SLUG="${SOC_POLICY_SLUG:-}"
SOC_POLICY_FILE="${SOC_POLICY_FILE:-}"
SOC_ROUTE_ENV="${SOC_ROUTE_ENV:-}"
SOC_ROUTE_TARGETS="${SOC_ROUTE_TARGETS:-}"
SOC_CREATED_RUN="${SOC_CREATED_RUN:-}"
SOC_UNUSED_CONFIRMED="${SOC_UNUSED_CONFIRMED:-}"
SCOUTFLO_AUDIT_DIR="${SCOUTFLO_AUDIT_DIR:-./scoutflo-audits}"
export SOC_APPROVED_PLAN SOC_POLICY_SLUG SOC_POLICY_FILE SOC_ROUTE_ENV SOC_ROUTE_TARGETS SOC_CREATED_RUN SOC_UNUSED_CONFIRMED SCOUTFLO_AUDIT_DIR
export SOC_MODE SOC_RUN_ID SOC_OPERATION SOC_TEAM SOC_SEG SOC_ID_VAR SOC_READ_VAR SOC_WRITE_VAR
export SOC_ID SOC_READ SOC_WRITE SOC_CREDENTIAL_FINGERPRINT SCOUTFLO_ENV
python3 - <<'PYCODE'
import hashlib, json, os, re, secrets, stat, subprocess, sys, time
from pathlib import Path

class Stop(Exception): pass
class HTTP(Stop):
    def __init__(self, code): self.code=code; super().__init__('Provider request not confirmed: '+str(code))
def require(value, message):
    if not value: raise Stop(message)
def no_duplicates(pairs):
    result={}
    for key,value in pairs:
        require(key not in result, 'Duplicate JSON key refused')
        result[key]=value
    return result
def decode(raw):
    try: return json.loads(raw, object_pairs_hook=no_duplicates, parse_constant=lambda x: (_ for _ in ()).throw(Stop('Nonfinite JSON number refused')))
    except (ValueError, UnicodeError): raise Stop('Malformed JSON refused')
def encode(value): return json.dumps(value, sort_keys=True, separators=(',',':'))
def ident(value):
    require(isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_-]{1,160}',value), 'Invalid object identity')
    return value
def text(value):
    require(isinstance(value,str) and 0<len(value)<=1024 and re.fullmatch(r'[A-Za-z0-9 .,;:()/_-]+',value) and not re.search(r'://|@|token|password|secret|api.?key|[A-Za-z0-9_-]{40,}',value,re.I), 'Unsafe metadata refused')
    return value
def private_read(path):
    st=path.lstat()
    require(stat.S_ISREG(st.st_mode) and not (st.st_mode&0o077), 'Expected a private regular file')
    require(st.st_size<=1048576, 'Local input exceeds bound')
    return decode(path.read_text())
def create(path,value):
    raw=encode(value)+'\n'
    for secret in (api_id,read_key,write_key,route_value):
        require(not secret or secret not in raw, 'Sensitive value refused in journal')
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as out: out.write(raw)
def request(method,path,key,body=None):
    # Callers below choose fixed operations. No caller-supplied URL/method/body API.
    require(path.startswith('/api-public/v1/'), 'Management path refused')
    config=['url = '+json.dumps('https://api.victorops.com'+path),
            'header = '+json.dumps('X-VO-Api-Id: '+api_id),
            'header = '+json.dumps('X-VO-Api-Key: '+key)]
    if body is not None:
        config+=['header = "Content-Type: application/json"','data = '+json.dumps(encode(body))]
    time.sleep(1)
    p=subprocess.run(['curl','-q','-sS','--config','-','--request',method,'--proto','=https','--max-redirs','0',
                      '--connect-timeout','5','--max-time','20','--max-filesize','1048576','-w','\n%{http_code}'],
                     input='\n'.join(config)+'\n',capture_output=True,text=True)
    if p.returncode: raise HTTP('transport-unknown')
    raw,sep,code=p.stdout.rpartition('\n')
    require(sep and re.fullmatch(r'[0-9]{3}',code), 'Incomplete transport status')
    if code!='200': raise HTTP(code)
    if method=='DELETE' and not raw.strip(): return None
    value=decode(raw)
    require(isinstance(value,list) if path=='/api-public/v1/alertRules' and method=='GET' else isinstance(value,dict), 'Expected one complete management JSON value')
    return value

def team(key):
    value=request('GET','/api-public/v1/team/'+anchor,key)
    require(value.get('slug')==anchor and value.get('isDefaultTeam') is False, 'Wrong or default team')
    require(isinstance(value.get('name'),str) and isinstance(value.get('version'),(int,float)), 'Incomplete team identity')
    return value

def collection(value,key,metadata=()):
    # No supported pagination exists for these documented complete envelopes.
    # Unknown next/cursor/count/total/status fields are not completeness proof.
    require(isinstance(value,dict) and set(value)<=({key}|set(metadata)) and isinstance(value.get(key),list),
            'Incomplete or unsupported collection envelope; no absence conclusion')
    require(all(isinstance(value[k],str) for k in metadata if k in value),'Invalid collection metadata')
    return value[key]

def policy_list():
    value=request('GET','/api-public/v1/policies',read_key)
    items=collection(value,'policies')
    rows=[]
    for item in items:
        require(isinstance(item,dict) and isinstance(item.get('policy'),dict) and isinstance(item.get('team'),dict), 'Invalid policy summary')
        rows.append({'slug':ident(item['policy'].get('slug')),'name':text(item['policy'].get('name')),'team':ident(item['team'].get('slug'))})
    require(len({x['slug'] for x in rows})==len(rows), 'Ambiguous policy collection')
    return sorted(rows,key=lambda x:x['slug'])

def steps(value, read=False):
    require(isinstance(value,list) and value, 'Policy needs explicit nonempty steps')
    result=[]; target_owners=None
    for step in value:
        require(isinstance(step,dict) and set(step)=={'timeout','entries'}, 'Unknown or missing policy step field')
        require(type(step['timeout']) is int and step['timeout']>=0, 'Timeout must be nonnegative whole minutes')
        require(isinstance(step['entries'],list) and step['entries'], 'Empty policy step refused')
        entries=[]
        for entry in step['entries']:
            require(isinstance(entry,dict), 'Invalid entry')
            kind=entry.get('executionType')
            if kind in ('rotation_group','rotation_group_next','rotation_group_previous'): field,key,extra='rotationGroup','slug',{'label'}
            elif kind=='user': field,key,extra='user','username',{'firstName','lastName'}
            elif kind=='policy_routing': field,key,extra='targetPolicy','policySlug',{'name','policyName','teamSlug'}
            else: raise Stop('Entry type requires the guided destination workflow; no speculative replacement')
            require(set(entry)=={'executionType',field} and isinstance(entry[field],dict), 'Policy entry must contain only its matching target')
            allowed={key}|(extra if read else set())
            require(set(entry[field])<=allowed and key in entry[field], 'Unknown target field')
            for k in set(entry[field])-{key}: text(entry[field][k])
            if field=='targetPolicy' and 'teamSlug' in entry[field]:
                if target_owners is None: target_owners={x['slug']:x['team'] for x in policy_list()}
                target=ident(entry[field][key]); returned_team=ident(entry[field]['teamSlug'])
                require(target in target_owners and target_owners[target]==returned_team,'Nested target team contradicts the policy ownership census')
            # teamSlug is observed identity evidence, checked above. It is not a
            # writable field; normalized replacement payloads retain policySlug.
            entries.append({'executionType':kind,field:{key:ident(entry[field][key])}})
        result.append({'timeout':step['timeout'],'entries':entries})
    return result

def policy(slug):
    value=request('GET','/api-public/v1/policies/'+ident(slug),read_key)
    require(set(value)=={'name','slug','ignoreCustomPagingPolicies','steps'} and value.get('slug')==slug, 'Unknown or mismatched policy shape')
    text(value['name']); require(type(value['ignoreCustomPagingPolicies']) is bool,'Missing policy flag')
    steps(value['steps'],True)
    return value

def payload(value): return {'ignoreCustomPagingPolicies':value['ignoreCustomPagingPolicies'],'steps':steps(value['steps'],True)}
def routes():
    value=request('GET','/api-public/v1/org/routing-keys',read_key)
    rows=collection(value,'routingKeys',('_selfUrl',))
    seen=set()
    for row in rows:
        require(isinstance(row,dict) and set(row)<= {'routingKey','targets','isDefault','isMultiResponder'}, 'Unknown routing field')
        key=row.get('routingKey'); require(isinstance(key,str) and key and key not in seen,'Missing or duplicate routing identity'); seen.add(key)
        require(type(row.get('isDefault')) is bool and isinstance(row.get('targets'),list),'Missing routing state')
        if 'isMultiResponder' in row: require(type(row['isMultiResponder']) is bool,'Invalid responder mode')
        for target in row['targets']:
            require(isinstance(target,dict) and set(target)<= {'policyName','policySlug','_teamUrl'},'Unknown routing target field')
            ident(target.get('policySlug')); text(target.get('policyName'))
    return rows

def route_census(rows):
    return sorted([{'identity':hashlib.sha256(x['routingKey'].encode()).hexdigest(),
                    'targets':sorted(t['policySlug'] for t in x['targets']),
                    'isDefault':x['isDefault'],'isMultiResponder':x.get('isMultiResponder')}
                   for x in rows],key=lambda x:x['identity'])

def selected_route(rows):
    found=[x for x in rows if x['routingKey']==route_value]
    require(len(found)<=1,'Ambiguous routing identity')
    if not found: return None
    row=found[0]; require(row['isDefault'] is False,'Default routing key is protected')
    targets=sorted(ident(x['policySlug']) for x in row['targets'])
    require(targets and len(set(targets))==len(targets),'Empty or duplicated route targets')
    return {'targets':targets,'isMultiResponder':row.get('isMultiResponder')}

def validate_dependencies(wanted, summaries, replacing=None):
    users=None; groups=None; graph={x['slug']:x for x in summaries}
    def visit(body, stack):
        nonlocal users,groups
        for step in steps(body['steps'],True):
            for entry in step['entries']:
                kind=entry['executionType']
                if kind=='user':
                    username=entry['user']['username']; require(not username.startswith('invited_'),'Pending invitation is not an enrolled responder')
                    if users is None:
                        data=request('GET','/api-public/v1/team/'+anchor+'/members',read_key)
                        members=collection(data,'members',('_selfUrl','_teamUrl'))
                        identities=[ident(x.get('username')) for x in members]
                        require(len(identities)==len(set(identities)),'Ambiguous member census'); users=set(identities)
                    require(username in users,'Selected user is not a team member')
                    user=request('GET','/api-public/v1/user/'+username,read_key)
                    require(user.get('username')==username and (user.get('verified') is True or user.get('verified')=='true'),'Enrollment is not verified; use the guided UI check')
                elif kind.startswith('rotation_group'):
                    if groups is None:
                        data=request('GET','/api-public/v1/teams/'+anchor+'/rotations',read_key)
                        rows=collection(data,'rotationGroups')
                        groups={ident(x.get('slug')):x for x in rows}
                        require(len(groups)==len(rows),'Ambiguous rotation census')
                    group=groups.get(entry['rotationGroup']['slug'])
                    require(group is not None and group.get('teamSlug')==anchor,'Rotation is not bound to the selected team')
                else:
                    slug=entry['targetPolicy']['policySlug']; require(slug in graph and slug not in stack,'Missing target policy or policy cycle')
                    require(graph[slug]['team']==anchor,'Cross-team policy target needs a separately reviewed workflow')
                    visit(policy(slug),stack|{slug})
    visit(wanted,{replacing} if replacing else set())

def private_route():
    global route_value
    name=ident(os.environ.get('SOC_ROUTE_ENV',''))
    require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',name) and name not in (id_env,read_env,write_env),'Use a distinct safe route variable name')
    loader='set +x; set -a; if [ -f "$1" ]; then . "$1" >/dev/null 2>&1 || exit 43; fi; value=$(printenv "$2") || exit 44; printf %s "$value"'
    found=subprocess.run(['sh','-c',loader,'_',str(store),name],capture_output=True,text=True)
    if found.returncode==44 and operation=='route-create' and mode=='plan':
        require(not store.is_symlink() and (not store.exists() or stat.S_ISREG(store.stat().st_mode)), 'Unsafe secret store')
        require(not store.exists() or not (store.stat().st_mode&0o077),'Secret store must be private')
        store.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
        lock=Path(str(store)+'.scoutflo-lock')
        fd=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); os.close(fd)
        try:
            check=subprocess.run(['sh','-c',loader,'_',str(store),name],capture_output=True,text=True)
            require(check.returncode==44,'Route variable changed during preparation; re-plan')
            route_value=secrets.token_urlsafe(32)
            fd=os.open(store,os.O_WRONLY|os.O_CREAT|os.O_APPEND|getattr(os,'O_NOFOLLOW',0),0o600)
            with os.fdopen(fd,'a') as out: out.write('\n'+name+"='"+route_value+"'\n"); out.flush(); os.fsync(out.fileno())
        finally: lock.unlink()
    else:
        require(found.returncode==0,'Missing routing value or secret-store read failed')
        route_value=found.stdout
    require(re.fullmatch(r'[A-Za-z0-9_-]{1,200}',route_value or ''),'Routing value requires a supported opaque format')
    return name

def no_route_consumers():
    rules=request('GET','/api-public/v1/alertRules',read_key)
    require(all(isinstance(x,dict) and isinstance(x.get('routeKey'),str) for x in rules),'Alert-rule routing dependencies are incomplete')
    require(all(x['routeKey']!=route_value for x in rules),'Routing key is referenced by an alert transformation')
    maintenance=request('GET','/api-public/v1/maintenancemode',read_key)
    instances=collection(maintenance,'activeInstances',('companyId',))
    for item in instances:
        require(type(item.get('isGlobal')) is bool and isinstance(item.get('targets'),list) and item['targets'],'Unknown maintenance scope')
        require(item['isGlobal'] is False,'Global maintenance is active; resolve it before retirement')
        for target in item['targets']:
            require(target.get('type')=='RoutingKeys' and isinstance(target.get('names'),list) and target['names'] and all(isinstance(x,str) for x in target['names']),'Unknown or global maintenance target')
            require(route_value not in target['names'],'Routing key is under active maintenance')

def policy_consumes(slug,target):
    # Dependency inspection does not turn an unrelated empty/email/webhook
    # policy into a supported replacement payload or persist its private fields.
    value=request('GET','/api-public/v1/policies/'+ident(slug),read_key)
    require(set(value)=={'name','slug','ignoreCustomPagingPolicies','steps'} and value.get('slug')==slug and type(value.get('ignoreCustomPagingPolicies')) is bool and isinstance(value.get('name'),str),'Unknown dependency policy shape')
    require(isinstance(value['steps'],list),'Unknown dependency steps')
    found=False; target_owners=None
    kinds={'rotation_group':'rotationGroup','rotation_group_next':'rotationGroup','rotation_group_previous':'rotationGroup',
           'user':'user','policy_routing':'targetPolicy','webhook':'webhook','email':'email'}
    for step in value['steps']:
        require(isinstance(step,dict) and set(step)=={'timeout','entries'} and type(step['timeout']) is int and step['timeout']>=0 and isinstance(step['entries'],list),'Incomplete dependency step')
        for entry in step['entries']:
            require(isinstance(entry,dict) and isinstance(entry.get('executionType'),str),'Unknown dependency entry')
            field=kinds.get(entry['executionType'])
            require(field is not None and set(entry)=={'executionType',field} and isinstance(entry[field],dict),'Unknown dependency target')
            key,optional={'rotationGroup':('slug',{'label'}),'user':('username',{'firstName','lastName'}),
                          'targetPolicy':('policySlug',{'name','policyName','teamSlug'}),'webhook':('slug',{'label'}),'email':('address',set())}[field]
            require(set(entry[field])<=({key}|optional) and isinstance(entry[field].get(key),str) and entry[field][key] and all(isinstance(x,str) for x in entry[field].values()),'Incomplete dependency target fields')
            if field!='email': ident(entry[field][key])
            if field=='targetPolicy':
                if 'teamSlug' in entry[field]:
                    if target_owners is None: target_owners={x['slug']:x['team'] for x in policy_list()}
                    nested=entry[field]['policySlug']; returned_team=ident(entry[field]['teamSlug'])
                    require(nested in target_owners and target_owners[nested]==returned_team,'Dependency target team contradicts the policy ownership census')
                found=entry[field]['policySlug']==target or found
    return found

def no_policy_consumers(slug,summaries,route_rows):
    require(all(all(t['policySlug']!=slug for t in r['targets']) for r in route_rows),'Policy still has routing-key consumers')
    for row in summaries:
        if row['slug']==slug: continue
        require(not policy_consumes(row['slug'],slug),'Policy still has nested-policy consumers')
    overrides=request('GET','/api-public/v1/overrides',read_key)
    entries=collection(overrides,'overrides',('_selfUrl',))
    require(not entries,'Existing overrides require guided dependency review before retirement')

try:
    mode=os.environ['SOC_MODE']; operation=os.environ['SOC_OPERATION']; run=ident(os.environ['SOC_RUN_ID'])
    anchor=ident(os.environ['SOC_TEAM']); target=os.environ['SOC_SEG']
    api_id=os.environ['SOC_ID']; read_key=os.environ['SOC_READ']; write_key=os.environ['SOC_WRITE']; route_value=''
    id_env=os.environ['SOC_ID_VAR']; read_env=os.environ['SOC_READ_VAR']; write_env=os.environ['SOC_WRITE_VAR']
    fingerprint=os.environ['SOC_CREDENTIAL_FINGERPRINT']; store=Path(os.environ['SCOUTFLO_ENV'])
    approved=os.environ.get('SOC_APPROVED_PLAN','')
    root=Path(os.environ.get('SCOUTFLO_AUDIT_DIR','./scoutflo-audits'))/target
    out=root/('setup-'+run); plan_path=out/'plan.json'
    require(team(read_key)==team(write_key),'Credential tiers disagree on the selected team')
    summaries=policy_list()
    is_route=operation.startswith('route-')
    route_env=private_route() if is_route else None
    route_rows=routes()
    object_id=ident(os.environ.get('SOC_POLICY_SLUG','')) if operation in ('policy-replace','policy-retire') else None
    if object_id:
        require(any(x['slug']==object_id and x['team']==anchor for x in summaries) or (mode=='inspect' and not any(x['slug']==object_id for x in summaries)),'Selected policy belongs to another team or is absent')
    before=selected_route(route_rows) if is_route else (policy(object_id) if object_id and any(x['slug']==object_id for x in summaries) else None)
    if mode=='plan':
        require(not approved,'Do not preapprove an unseen plan')
        require(not out.exists() and not out.is_symlink(),'Run directory exists; inspect instead of replaying')
        if operation.startswith('policy-') and not operation.endswith('retire'):
            supplied=private_read(Path(os.environ.get('SOC_POLICY_FILE','')))
            keys={'name','ignoreCustomPagingPolicies','steps'} if operation=='policy-create' else {'ignoreCustomPagingPolicies','steps'}
            require(isinstance(supplied,dict) and set(supplied)==keys,'Policy file must contain the exact documented payload fields')
            require(type(supplied['ignoreCustomPagingPolicies']) is bool,'Policy flag must be explicit')
            after={'ignoreCustomPagingPolicies':supplied['ignoreCustomPagingPolicies'],'steps':steps(supplied['steps'])}
            if operation=='policy-create':
                after.update(name=text(supplied['name']),teamSlug=anchor)
                require(not any(x['name']==after['name'] and x['team']==anchor for x in summaries),'Policy name already exists; inspect it, do not POST again')
            validate_dependencies(after,summaries,object_id)
        elif is_route and not operation.endswith('retire'):
            targets=[ident(x) for x in os.environ.get('SOC_ROUTE_TARGETS','').split(',')]
            require(targets and len(targets)==len(set(targets)),'Provide a nonempty unique policy target list')
            require(all(any(x['slug']==slug and x['team']==anchor for x in summaries) for slug in targets),'Route policy missing or outside selected team')
            for slug in targets: validate_dependencies(policy(slug),summaries,slug)
            if operation=='route-create': require(before is None,'Routing key already exists; no duplicate POST')
            else: require(before is not None and type(before['isMultiResponder']) is bool,'Current responder mode is unavailable; use the guided UI workflow')
            after={'targets':sorted(targets)}
            if before is not None: after['isMultiResponder']=before['isMultiResponder']
        else:
            require(before is not None,'Selected object is absent')
            require(os.environ.get('SOC_UNUSED_CONFIRMED')=='yes','Confirm no external senders or active use before retirement')
            created_run=ident(os.environ.get('SOC_CREATED_RUN',''))
            created_dir=root/('setup-'+created_run)
            require(not created_dir.is_symlink(),'Unsafe ownership journal')
            created=private_read(created_dir/'applied.json'); source=private_read(created_dir/'plan.json')
            require(source.get('operation')==operation.replace('retire','create') and source.get('credential_fingerprint')==fingerprint and source.get('target')==target and source.get('team')==anchor,'No matching run-owned creation proof')
            require(created.get('object_id')==(route_env if is_route else object_id),'Ownership identity mismatch')
            if is_route: require(source.get('route_fingerprint')==hashlib.sha256(route_value.encode()).hexdigest(),'Creation record belongs to a different routing value')
            if not is_route: no_policy_consumers(object_id,summaries,route_rows)
            else: no_route_consumers()
            after=None
        root.mkdir(mode=0o700,parents=True,exist_ok=True); out.mkdir(mode=0o700)
        plan={'schema':'scoutflo-oncall-policy-route/v1','operation':operation,'target':target,'team':anchor,
              'credential_fingerprint':fingerprint,'object_id':route_env if is_route else object_id,
              'route_fingerprint':hashlib.sha256(route_value.encode()).hexdigest() if is_route else None,
              'before':before,'after':after,'policy_census':summaries,'route_census':route_census(route_rows),
              'routing_consumers':sum(any(t['policySlug']==object_id for t in row['targets']) for row in route_rows) if not is_route else None,
              'created_at':int(time.time())}
        create(plan_path,plan)
        digest=hashlib.sha256(plan_path.read_bytes()).hexdigest()
        print(encode({k:plan[k] for k in ('operation','target','team','object_id','before','after','routing_consumers')}))
        print('Plan checksum: '+digest); print('Read-only provider plan prepared; approve the exact action before apply.')
        sys.exit(0)
    require(out.is_dir() and not out.is_symlink(),'Missing or unsafe plan directory')
    plan=private_read(plan_path); digest=hashlib.sha256(plan_path.read_bytes()).hexdigest()
    require(plan.get('schema')=='scoutflo-oncall-policy-route/v1' and plan.get('operation')==operation and plan.get('target')==target and plan.get('team')==anchor and plan.get('credential_fingerprint')==fingerprint,'Plan target, operation or credentials changed')
    require(plan.get('object_id')==(route_env if is_route else object_id),'Selected identity differs from plan')
    if is_route: require(plan.get('route_fingerprint')==hashlib.sha256(route_value.encode()).hexdigest(),'Routing secret changed; prepare a new plan')
    if mode=='reconcile':
        require(operation=='policy-create' and plan.get('before') is None and plan.get('object_id') is None,'Reconcile supports only an attempted policy creation')
        require(approved=='apply:'+digest,'Supply the original approved create checksum for read-only reconciliation')
        attempt=private_read(out/'apply.started')
        require(attempt.get('operation')=='policy-create' and type(attempt.get('attempted_at')) is int and type(plan.get('created_at')) is int and plan['created_at']<=attempt['attempted_at']<=int(time.time()),'Original creation attempt is unavailable or invalid')
        original_hash=attempt.get('plan_sha256')
        if original_hash is None:
            # Older journals did not retain approval bytes. Recover the checksum
            # from the original operator receipt, never from an edited plan.
            original_hash=os.environ.get('SOC_LEGACY_ATTEMPT_PLAN_SHA256','')
        require(original_hash==digest,'Attempt does not bind the original approved plan; retain it and inspect only')
        require(not (out/'applied.json').exists() and not (out/'applied.json').is_symlink(),'Creation ownership receipt already exists; inspect it, do not replace it')
        require(not (out/'reconcile.result.json').exists() and not (out/'reconcile.result.json').is_symlink(),'Reconciliation result exists; inspect instead of replacing it')
        require(plan.get('route_census')==route_census(route_rows),'Routing identities or mappings changed; ownership remains unverified')
        desired=plan['after']
        require(isinstance(desired,dict) and set(desired)=={'name','teamSlug','ignoreCustomPagingPolicies','steps'} and desired['teamSlug']==anchor and type(desired['ignoreCustomPagingPolicies']) is bool,'Saved create payload is invalid')
        text(desired['name']);steps(desired['steps'])
        prior=plan['policy_census'];prior_ids={x['slug'] for x in prior}
        found=[x for x in summaries if x['team']==anchor and x['name']==desired['name'] and x['slug'] not in prior_ids]
        require(len(found)==1,'Created identity is absent or ambiguous; no retry or ownership claim')
        created_id=found[0]['slug']
        require([x for x in summaries if x['slug']!=created_id]==prior,'Unrelated policy census changed; ownership remains unverified')
        observed=policy(created_id)
        require(observed['name']==desired['name'] and payload(observed)=={k:desired[k] for k in ('ignoreCustomPagingPolicies','steps')},'Created policy differs from the approved full payload')
        validate_dependencies(observed,summaries,created_id)
        # Revalidate the exact census and routes after dependency reads. No read
        # is a conditional write guarantee; keep this object stable externally.
        final_summaries=policy_list();final_routes=routes()
        require(final_summaries==summaries and route_census(final_routes)==plan['route_census'],'Dependencies changed during reconciliation; preserve the attempt')
        final_observed=policy(created_id)
        require(final_observed==observed,'Created policy changed during reconciliation')
        create(out/'applied.json',{'object_id':created_id,'observed':observed,'route_census':route_census(final_routes),'at':int(time.time()),'provenance':'reconciled-without-retry','original_plan_sha256':digest})
        create(out/'reconcile.result.json',{'operation':operation,'effect':'verified-by-fresh-readback','write_retried':False,'at':int(time.time())})
        print('Original policy creation verified by fresh reads; ownership receipt recorded without a write retry.')
        sys.exit(0)
    if mode=='inspect':
        if operation=='policy-create':
            found=[x for x in summaries if x['team']==anchor and x['name']==plan['after']['name'] and x['slug'] not in {x['slug'] for x in plan['policy_census']}]
            require(len(found)<=1,'Creation identity remains ambiguous')
            before=policy(found[0]['slug']) if found else None
        print(encode({'operation':operation,'present':before is not None,'matches_before':before==plan['before'],
                      'matches_desired': (before is not None and (payload(before)=={k:plan['after'][k] for k in ('ignoreCustomPagingPolicies','steps')} if not is_route else (before['targets']==plan['after']['targets'] and ('isMultiResponder' not in plan['after'] or before['isMultiResponder'] is plan['after']['isMultiResponder'])))) if plan['after'] else before is None,
                      'attempt_recorded':(out/'apply.started').exists()})); sys.exit(0)
    require(approved==mode+':'+digest,'Exact plan/action approval required')
    require(plan['policy_census']==summaries,'Policy census changed; re-plan instead of overwriting parallel work')
    # Counts are only a display summary. Exact hashed identities plus mappings
    # bind every consumer, including same-count replacements and restore impact.
    expected_routes=plan['route_census'] if mode=='apply' else private_read(out/'applied.json').get('route_census')
    require(expected_routes==route_census(route_rows),'Routing identities or mappings changed; re-plan the exact impact')
    desired=plan['after']; expected=plan['before']; retiring=operation.endswith('retire')
    if mode=='restore':
        require(operation.endswith('replace'),'Creation/retirement has no automatic restore; use run-owned retirement or a separately approved recreation')
        applied=private_read(out/'applied.json'); expected=applied['observed']
        desired=payload(plan['before']) if not is_route else plan['before']
    require(before==expected,'Selected object drifted; re-plan')
    if retiring: require(os.environ.get('SOC_UNUSED_CONFIRMED')=='yes','Reconfirm no external senders or active use now')
    if not is_route and desired is not None:
        keys={'name','teamSlug','ignoreCustomPagingPolicies','steps'} if operation=='policy-create' else {'ignoreCustomPagingPolicies','steps'}
        require(isinstance(desired,dict) and set(desired)==keys and type(desired.get('ignoreCustomPagingPolicies')) is bool,'Invalid saved policy payload')
        if operation=='policy-create': require(desired['teamSlug']==anchor and text(desired['name']),'Saved policy targets another team')
        steps(desired['steps']); validate_dependencies(desired,summaries,object_id)
    if is_route and desired is not None:
        keys={'targets'} if operation=='route-create' else {'targets','isMultiResponder'}
        require(isinstance(desired,dict) and set(desired)==keys and isinstance(desired.get('targets'),list) and desired['targets'] and len(set(desired['targets']))==len(desired['targets']),'Invalid saved routing payload')
        if operation=='route-replace': require(type(desired['isMultiResponder']) is bool and desired['isMultiResponder']==before['isMultiResponder'],'Responder mode must remain unchanged')
        for slug in desired['targets']:
            require(any(x['slug']==slug and x['team']==anchor for x in summaries),'Route target disappeared or changed team')
            validate_dependencies(policy(slug),summaries,slug)
    if operation=='policy-retire': no_policy_consumers(object_id,summaries,route_rows)
    if operation=='route-retire': no_route_consumers()
    for filename in (mode+'.started',mode+'.result.json')+ (('applied.json',) if mode=='apply' else ()):
        require(not (out/filename).exists() and not (out/filename).is_symlink(),'Attempt or result exists; inspect unknown outcome, never replay')
    create(out/(mode+'.started'),{'attempted_at':int(time.time()),'operation':operation,'plan_sha256':digest})
    if operation=='policy-create': method,path,body='POST','/api-public/v1/policies',desired
    elif operation=='policy-replace': method,path,body='PUT','/api-public/v1/policies/'+object_id,desired
    elif operation=='policy-retire': method,path,body='DELETE','/api-public/v1/policies/'+object_id,None
    elif operation=='route-create': method,path,body='POST','/api-public/v1/org/routing-keys',dict(desired,routingKey=route_value)
    elif operation=='route-replace': method,path,body='PUT','/api-public/v1/org/routing-keys/'+route_value,dict(desired,routingKey=route_value)
    else: method,path,body='DELETE','/api-public/v1/org/routing-keys/'+route_value,None
    response='complete'
    try: request(method,path,write_key,body)
    except HTTP as error:
        response=str(error.code)
        if error.code=='429':
            create(out/(mode+'.result.json'),{'effect':'unknown','write_response':'429','next':'honor Retry-After; inspect only after provider interval'})
            raise Stop('Throttled; preserve attempt and wait before a separately resumed read, never replay')
    except Stop: response='invalid-response'
    observed=None
    final_summaries=policy_list(); final_routes=routes()
    if not is_route: require(route_census(final_routes)==route_census(route_rows),'Policy consumer mappings changed during write; reconcile')
    if is_route:
        observed=selected_route(final_routes)
        selected_hash=hashlib.sha256(route_value.encode()).hexdigest()
        require([x for x in route_census(final_routes) if x['identity']!=selected_hash]==[x for x in route_census(route_rows) if x['identity']!=selected_hash],'Unrelated routing state changed; reconcile')
        if retiring: require(observed is None,'Route retirement unverified')
        else:
            require(observed is not None and observed['targets']==desired['targets'],'Routing mapping readback differs')
            if operation=='route-replace': require(observed['isMultiResponder'] is desired['isMultiResponder'],'Responder mode preservation not verified')
        affected_id=route_env
    elif retiring:
        require(not any(x['slug']==object_id for x in final_summaries),'Policy retirement unverified'); affected_id=object_id
    else:
        if operation=='policy-create':
            found=[x for x in final_summaries if x['team']==anchor and x['name']==desired['name'] and x['slug'] not in {x['slug'] for x in summaries}]
            require(len(found)==1,'Creation identity ambiguous; no retry or deletion'); object_id=found[0]['slug']
        observed=policy(object_id)
        require(payload(observed)=={k:desired[k] for k in ('ignoreCustomPagingPolicies','steps')},'Policy replacement readback differs')
        require(observed['name']==(desired['name'] if operation=='policy-create' else expected['name']),'Policy name was not preserved')
        affected_id=object_id
    # Census comparison allows only the announced create/delete; no unrelated
    # policies may disappear or move teams while completing this operation.
    retained=[x for x in final_summaries if x['slug']!=object_id] if operation in ('policy-create','policy-retire') else final_summaries
    old=[x for x in summaries if x['slug']!=object_id] if operation=='policy-retire' else summaries
    require(retained==old,'Unrelated policy census changed; reconcile before another operation')
    if mode=='apply': create(out/'applied.json',{'object_id':affected_id,'observed':observed,'route_census':route_census(final_routes),'at':int(time.time())})
    create(out/(mode+'.result.json'),{'operation':operation,'action':mode,'effect':'verified-by-readback','write_response':response,'at':int(time.time())})
    print(mode+' effect verified by exact readback; re-audit with the read-only key.')
except (Stop,OSError,KeyError,TypeError,AttributeError,ValueError,RecursionError) as error:
    # Never include provider response bodies, URLs, credentials or arbitrary input
    # in errors. Only our fixed diagnostic messages are safe to display.
    print(str(error) if isinstance(error,Stop) else 'Local state or response shape unavailable; preserve the journal and reconcile',file=sys.stderr)
    sys.exit(1)
PYCODE
unset SOC_ID SOC_READ SOC_WRITE SOC_CREDENTIAL_FINGERPRINT SOC_HASH_LINE
```
<!-- oncall-policy-routing:end -->

## Recover an interrupted creation readback

If policy creation was attempted once but its first readback failed, keep `apply.started`, the unchanged plan and the original approved checksum. After grounding/fixing the read shape, run the same block with `SOC_MODE=reconcile`, `SOC_OPERATION=policy-create`, original `SOC_RUN_ID`, target/config, and `SOC_APPROVED_PLAN=apply:<original checksum>`. This mode issues GETs only. It requires a unique new policy absent from the original census, exact name/team/flag/ordered payload, valid dependencies, and unchanged prior policy/routing state before writing the local ownership receipt. A missing or ambiguous object does not authorize POST or deletion.

Older attempt records lack `plan_sha256`. Only for those records, supply `SOC_LEGACY_ATTEMPT_PLAN_SHA256` from the **contemporaneous original approved checksum** in the operator's receipt. Do not compute a new checksum from an edited plan and call it original. A mismatch stops; the original attempt marker is never removed. `reconcile.result.json` states `write_retried:false`. Normal owned retirement may use the verified creation receipt afterward; it still requires its separate unused-consumer checks and approved deletion plan. Reconciliation of other action types is not advertised by this recipe.

## Guided destination and mode workflow

Before any attended save, run the [attended verification capture and asserted comparison](attended-verification.md#before-expected-change-and-after) for the exact object. Its `check-before` must accept the fresh current projection and checksum-bound expected change; after the single save, `check-after` must assert the resulting projection. For fields absent from the API, include fresh, timestamped UI evidence and preserve the explicit UI-observed classification. A screenshot or a successful save alone is insufficient.

If the block refuses an email/webhook target or an unobservable responder mode, keep the prepared evidence and use the provider's current policy/routing editor. Read the current object first, show only safe destination aliases plus the exact step ordering/delays, and obtain the destination owner's approval for any new recipient. Existing webhook slugs come from `GET /api-public/v1/webhooks`; never copy webhook URLs into a plan or treat presence as successful delivery.

For route repair, open the selected existing non-default key in the routing editor, verify its current responder mode, and record a redacted before view. Announce the exact policy-set change and preservation of the key and mode. After confirmation, edit only that mapping, save once, then re-read the management routing list and compare the complete target set. Also verify the mode in the UI; if the API omits it, record UI-observed preservation rather than API proof. To restore, first compare the current UI and API state with the saved post-change state, announce the inverse mapping, confirm, save once and verify both surfaces again. Drift requires a new plan. The recipe must not be weakened to accept an assumed `false`.

Email and webhook policy entries need the same full step/order/flag before-and-after comparison. The public API documents their request variants; this recipe deliberately does not persist private email addresses or webhook destination URLs. Use the provider's editor for the selected approved existing destination, preserve every unedited step and flag, and re-read the resulting policy. New webhook enrollment remains a distinct provider UI integration action. Never trigger a notification solely to test syntax.

## Retirement and interrupted writes

Delete only an object this run family created and whose current lack of external senders/active use has been confirmed. Route retirement protects the default key, refuses alert-transformation and maintenance references, and verifies absence while keeping its protected secret reference for reconciliation. Policy retirement reads the full policy collection, including unrelated empty/email/webhook policies, solely to detect nested consumers; those reads do not authorize editing those variants. It refuses any routing-key or nested-policy consumer and requires an empty override census; existing overrides need a guided dependency review instead. This deliberately fails closed because deleting the sole target policy can also delete a routing key. A delete is not reversible under the same identity. A new create after retirement needs a new plan and may create a different slug.

A failed write response may still mean the provider accepted it. The block re-reads after a bounded failure except 429, records exact observed equality when available, and never repeats a started mutation. Use `inspect` after the appropriate provider retry interval to resolve an interrupted attempt. If identity or outcome is still ambiguous, retain the journal and use the provider UI; do not delete another object to make the test look clean.

## Evidence limits

The field contracts come from the public [VictorOps Swagger](https://portal.victorops.com/api-docs/victorops-api-v1.yaml): policy POST/GET/PUT/DELETE and organization routing-key GET/POST/PUT/DELETE. Populated policy/route read shapes and route POST mapping were observed in November 2026. Each newly enabled lifecycle path still needs its own dated effect/readback/restore receipt; no operation's live success is inferred from another operation or from these hermetic tests. UI-only mode preservation and cross-person coverage are separately stated observations, not notification-delivery proof.
