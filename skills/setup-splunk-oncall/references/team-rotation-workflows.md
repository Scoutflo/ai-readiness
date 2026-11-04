# Team, rotation and shift workflows

Use these fixed recipes after the setup skill's Doctor and change protocol. They make one announced configuration change at a time. They never invite a person, enroll a contact, send a notification, alter an API key or operate on an arbitrary URL.

## Select the change

| `SOC_OPERATION` | Exact supported payload in `SOC_CHANGE_JSON` | Verification and reversal |
| --- | --- | --- |
| `team-create` | `{name,description}` | Read the complete team list, require a unique new matching team, then read its metadata. The provider also creates an implicit default escalation policy. Record the team slug; retirement is a separate confirmed change. |
| `team-update` | `{name,description}` | Compare all permitted metadata before the PUT; read it again and preserve fields other than the version. Restore the exact saved payload while the post-write state still matches. A rename that changes identity stops as unknown. |
| `member-add` | `{username}` for an already enrolled person | Read the selected person and team members; verify exactly one verified member was added and metadata was preserved. Removing membership can reassign duty and uses the separate procedure below. |
| `rotation-create` | `{label,shifts:[Shift]}` | Create one unique group, then compare every shift's complete configuration and roster. Inline Shift may include `usernames`; those people must already be verified team members. |
| `rotation-rename` | `{label}` | Verify the label changed and every shift/roster field stayed equal. Restore only against the saved post-write state. |
| `shift-create` | Complete `Shift`, without `usernames` | POST to the group; verify one new unstaffed shift, complete configuration, and unchanged siblings. Use `roster-add` to staff it. |
| `shift-update` | Complete `Shift`, without `usernames` | Full replacement, not PATCH: every required field is present, roster is preserved, and readback matches. The original complete Shift can be restored. |
| `roster-add` | `{username,position?}` | Add a verified existing team member once; compare the exact new member, order and preserved scheduled user. Staffing a previously empty unassigned shift expects that new verified responder. `position` is zero-based; omission appends. No implicit team-membership side effect is permitted. |
| `roster-move` | `{username,position,memberSlug?}` | Require a unique selected roster member and an in-range position; verify exact order and unchanged verified scheduled user. Restoration refuses changed scheduled-user or roster state. |
| `roster-remove` | `{username,replacement?,memberSlug?}` | Keep at least one other distinct responder. Removing the scheduled user requires a different existing replacement. Verify exact remaining roster and the verified replacement; removing a non-current member preserves the scheduled user. A later reversal is a newly timed change, not automatic undo. |
| `scheduled-set` | `{username,position?,memberSlug?}` | Select an existing verified roster member; verify scheduled-user equality and unchanged roster/configuration. Reversal is a new time-aware plan. A null scheduled read is unknown/unassigned, not a populated user. |
| `team-retire`, `rotation-retire`, `shift-retire` | `{}` plus `SOC_CREATED_RUN` | Only an object proved created by a successful journal for this credential generation. Read all policy dependencies, including cross-team rotation references; remove children before parents. Verify absence in a successful complete parent list. Re-creation can change IDs; deletion is not same-ID restoration. |

`Shift` contains `label`, IANA `timezone`, integer `start` in epoch milliseconds, integer `duration` in days (1 through the provider maximum 90), `shifttype` (`std`, `fts`, `cstm`, `pho`) and `mask`. Optional `mask2` and `mask3` are preserved when present. A mask is `{day:{su,m,t,w,th,f,sa},time:[{start:{hour,minute},end:{hour,minute}}]}` with boolean days and numeric clock components. For the provider's all-day `std` shape, use 00:00 to 00:00; live reads normalize a 23:59 end to 00:00. The recipe refuses any unannounced normalization instead of silently treating it as exact preservation. Choose timing from the actual coverage need; the API's 90-day bound is not a scheduling recommendation. No default shift, person, start time or working-hours policy is invented.

The numeric group ID addresses the rotation API. The `rtg-…` slug addresses an escalation policy. The recipe never substitutes one for the other. V1 group detail uses `id`/`teamslug`; shift detail uses `rot_id`/`group_id`/`team_slug`. Preview is bounded to one week. This verifies the returned configuration and roster, not future coverage, delivery or every handoff interval.

## Prepare and execute one action

Set `SOC_OPERATION`, unique `SOC_RUN_ID`, and `SOC_CHANGE_JSON` to the exact nonsecret payload above. `SOC_OBJECT_TEAM` selects the team to modify, defaulting to the configured identity anchor. Set `SOC_GROUP_ID` and `SOC_SHIFT_ID` for operations on those objects. `SCOUTFLO_TARGET` must name one configured label for list configurations. `SOC_MODE` is `plan` (read-only), `apply`, `restore`, or `reconcile` (read-only after an uncertain apply).

The plan file is private mode 0600 under a 0700 action folder. It contains the exact payload, identities, permitted before-state and a private credential fingerprint; it never contains credential values. Review that file and the affected people before approving. Only after explicit conversation approval, set `SOC_APPROVED_PLAN` to `apply:<printed SHA-256>` or `restore:<same SHA-256>`. A supplied checksum is a binding, not permission. Reuse the same run ID only for that plan. Do not alter a saved plan to bypass drift.

For retirement, `SOC_CREATED_RUN` points to the successful creation action under the same resolved target. Team membership is not account deletion. Even an unused team's retirement is a separate announced deletion; preserve its local record. A run-owned empty non-default team may retire with its sole implicit default policy only when that policy has the team slug, empty steps and an explicit false custom-paging flag. The approved plan announces both deletions. No members, rotations, additional policies, routing or nested-policy consumers, overrides or maintenance may remain. Other team retirement needs attended review; this is not a general cascade delete. Unknown dependency types, incomplete reads and unsupported fields stop before mutation. No unreviewed default-team change is allowed.

**Fixed step:** run as written. Every invocation resolves target and credentials afresh. The provider has no proven conditional-write operation, so a read/write race remains possible; keep the selected objects stable during the attended action. After any timeout, malformed response or 429, retain the request-start journal. Honor Retry-After before `reconcile`, which makes reads only. No POST or DELETE is retried automatically.

<!-- oncall-team-rotation:start -->
```bash
set -eu
set +x
umask 077
SOC_MODE="${SOC_MODE:-plan}"
SOC_RUN_ID="${SOC_RUN_ID:-}"
SOC_OPERATION="${SOC_OPERATION:-}"
SOC_CHANGE_JSON="${SOC_CHANGE_JSON:-}"
[ -n "$SOC_CHANGE_JSON" ] || SOC_CHANGE_JSON='{}'
SOC_APPROVED_PLAN="${SOC_APPROVED_PLAN:-}"
SOC_OBJECT_TEAM="${SOC_OBJECT_TEAM:-}"
SOC_GROUP_ID="${SOC_GROUP_ID:-}"
SOC_SHIFT_ID="${SOC_SHIFT_ID:-}"
SOC_CREATED_RUN="${SOC_CREATED_RUN:-}"
case "$SOC_RUN_ID" in ''|*[!A-Za-z0-9_-]*) echo 'Set a safe unique SOC_RUN_ID'; exit 1;; esac
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
export SOC_MODE SOC_RUN_ID SOC_OPERATION SOC_CHANGE_JSON SOC_APPROVED_PLAN SOC_OBJECT_TEAM SOC_GROUP_ID SOC_SHIFT_ID SOC_CREATED_RUN
export SOC_TEAM SOC_SEG SOC_ID SOC_READ SOC_WRITE SOC_CREDENTIAL_FINGERPRINT
python3 - <<'PY_WORKFLOW'
import copy, hashlib, json, os, pathlib, re, subprocess, sys
from zoneinfo import ZoneInfo

class Stop(Exception): pass
def need(test, reason):
    if not test: raise Stop(reason)
def canonical(value): return json.dumps(value, sort_keys=True, separators=(',', ':'))
def digest(value): return hashlib.sha256(canonical(value).encode()).hexdigest()
def ident(value):
    need(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9_.-]{1,128}', value), 'Unsafe object identity')
    return value
def number(value): return isinstance(value, int) and not isinstance(value, bool) and value >= 0
def text(value, empty=False):
    need(isinstance(value, str) and len(value) <= 1024 and (empty or value.strip()), 'Missing or oversized metadata')
    need(not re.search(r'://|@|[\r\n]|token|password|secret|api.?key', value, re.I), 'Metadata is unsafe for a local plan')
    return value
def pairs(rows):
    out = {}
    for key, value in rows:
        need(key not in out, 'Duplicate JSON key')
        out[key] = value
    return out
def parse(value):
    return json.loads(value, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Stop('Non-finite JSON number')))
def clean(value):
    encoded = canonical(value)
    need(all(key not in encoded for key in credentials), 'Credential-shaped content refused')
    return value
def exclusive(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream: stream.write(canonical(clean(value)) + '\n')
def read_local(path):
    need(path.is_file() and not path.is_symlink(), 'Missing or unsafe local record')
    return parse(path.read_text())
def request(method, path, payload=None, tier='read'):
    # Paths are constructed only in the fixed operation branches below.
    need(path.startswith('/api-public/v1/'), 'Unsupported API path')
    subprocess.run(['sleep', '1'], check=True)
    lines = ['header = '+json.dumps('X-VO-Api-Id: '+credentials[0]),
             'header = '+json.dumps('X-VO-Api-Key: '+credentials[1 if tier == 'read' else 2])]
    if payload is not None:
        lines += ['header = "Content-Type: application/json"', 'data = '+json.dumps(canonical(payload))]
    proc = subprocess.run(['curl', '-q', '-sS', '--config', '-', '--request', method, '--proto', '=https',
        '--max-redirs', '0', '--connect-timeout', '5', '--max-time', '20', '--max-filesize', '1048576',
        '-w', '\n%{http_code}', 'https://api.victorops.com'+path], input='\n'.join(lines)+'\n', text=True,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    need(proc.returncode == 0, 'Transport incomplete; no write retry')
    body, sep, status = proc.stdout.rpartition('\n')
    need(sep and status.isdigit(), 'Transport status missing')
    if status == '429': raise Stop('HTTP 429: pause for Retry-After; no automatic read or write retry')
    need(status == '200' or (method != 'GET' and status == '204'), 'HTTP '+status+': request not confirmed; no role inferred')
    if method != 'GET': return status  # Empty 204 is valid; a subsequent GET is the effect proof.
    try: value = parse(body)
    except (ValueError, Stop): raise Stop('Expected one complete JSON response')
    need(isinstance(value, (dict, list)) or (value is None and path.endswith('/scheduled')), 'Unsupported read response')
    return value

def team_read(slug, tier='read'):
    raw = request('GET', '/api-public/v1/team/'+ident(slug), tier=tier)
    keys = {'_selfUrl','_membersUrl','_policiesUrl','_adminsUrl','slug','name','description','memberCount','version','isDefaultTeam'}
    need(isinstance(raw,dict) and set(raw)<=keys and raw.get('slug') == slug, 'Team identity or fields unsupported')
    need(number(raw.get('memberCount')) and number(raw.get('version')) and isinstance(raw.get('isDefaultTeam'),bool), 'Team counters or default flag missing')
    for key, suffix in [('_selfUrl',''),('_membersUrl','/members'),('_policiesUrl','/policies'),('_adminsUrl','/admins')]:
        path='/api-public/v1/team/'+slug+suffix
        need(raw.get(key) in (path,'https://api.victorops.com'+path), 'Team link is not canonical')
    return clean({'slug':slug,'name':text(raw.get('name')),'description':(text(raw['description'],True) if isinstance(raw.get('description'),str) else None),
                  'memberCount':raw['memberCount'],'version':raw['version'],'isDefaultTeam':raw['isDefaultTeam']})
def teams_read():
    raw=request('GET','/api-public/v1/team')
    need(isinstance(raw,list), 'Team list shape unsupported')
    rows=[{'slug':ident(x['slug']),'name':text(x['name'])} for x in raw]
    need(len({x['slug'] for x in rows})==len(rows), 'Duplicate team identity')
    return sorted(rows,key=lambda x:x['slug'])
def members_read(team):
    raw=request('GET','/api-public/v1/team/'+team+'/members')
    need(isinstance(raw,dict) and set(raw)<={'members','_selfUrl','_teamUrl'} and isinstance(raw.get('members'),list), 'Team membership unavailable')
    rows=[]
    for item in raw['members']:
        need(isinstance(item.get('verified'),bool), 'Member enrollment state unknown')
        rows.append({'username':ident(item.get('username')),'verified':item['verified']})
    need(len({x['username'] for x in rows})==len(rows), 'Duplicate team member identity')
    return sorted(rows,key=lambda x:x['username'])
def eligible(username):
    user=request('GET','/api-public/v1/user/'+ident(username))
    need(user.get('username')==username and user.get('verified') is True, 'Selected responder is not a verified enrolled user')
    # This endpoint does not establish every role; server refusal remains a refusal.
    return username

def mask(value):
    need(isinstance(value,dict) and set(value)=={'day','time'}, 'Shift mask shape unsupported')
    need(isinstance(value['day'],dict) and set(value['day'])=={'su','m','t','w','th','f','sa'} and all(isinstance(v,bool) for v in value['day'].values()), 'Shift mask days unsupported')
    need(isinstance(value['time'],list) and len(value['time'])>0, 'Shift mask time missing')
    for span in value['time']:
        need(set(span)=={'start','end'}, 'Shift mask interval unsupported')
        for point in span.values():
            need(set(point)=={'hour','minute'} and number(point['hour']) and point['hour']<=24 and number(point['minute']) and point['minute']<60 and (point['hour']<24 or point['minute']==0), 'Shift mask time invalid')
    return value
SHIFT_KEYS={'label','timezone','start','duration','shifttype','mask','mask2','mask3'}
def shift_payload(value, inline=False):
    need(isinstance(value,dict) and set(value)<=SHIFT_KEYS|({'usernames'} if inline else set()) and {'label','timezone','start','duration','shifttype','mask'}<=set(value), 'Use the complete documented shift payload; usernames only belongs to inline rotation creation')
    text(value['label']); text(value['timezone']); ZoneInfo(value['timezone'])
    need(number(value['start']) and number(value['duration']) and 1<=value['duration']<=90, 'Shift needs epoch milliseconds and duration 1..90 days')
    need(value['shifttype'] in ('std','fts','cstm','pho'), 'Unknown shift type')
    for key in ('mask','mask2','mask3'):
        if key in value: mask(value[key])
    if inline:
        need(isinstance(value.get('usernames',[]),list), 'Inline usernames must be an array')
        for user in value.get('usernames',[]): ident(user)
        need(len(set(value.get('usernames',[])))==len(value.get('usernames',[])), 'Duplicate inline responders require an explicit later roster plan')
    return clean(value)
def shift_project(raw,team,gid,sid=None):
    allowed=SHIFT_KEYS|{'org_slug','team_slug','rot_id','group_id','periods','oncall','current','next','usernames','shiftMembers'}
    need(isinstance(raw,dict) and set(raw)<=allowed and raw.get('team_slug')==team and raw.get('group_id')==gid and number(raw.get('rot_id')), 'Shift identity or fields unsupported')
    if sid is not None: need(raw['rot_id']==sid,'Shift identity mismatch')
    cfg=shift_payload({k:v for k,v in raw.items() if k in SHIFT_KEYS and v is not None})
    need(isinstance(raw.get('shiftMembers'),list), 'Shift roster unavailable')
    roster=[{'slug':ident(x.get('slug')),'username':ident(x.get('username'))} for x in raw['shiftMembers']]
    need(len({x['slug'] for x in roster})==len(roster),'Duplicate roster identity')
    if 'usernames' in raw: need(raw['usernames']==[x['username'] for x in roster],'Roster representations disagree')
    return clean({'id':raw['rot_id'],'team':team,'group':gid,'config':cfg,'members':roster})
def group_list(team):
    raw=request('GET','/api-public/v1/teams/'+team+'/rotations')
    need(isinstance(raw,dict) and set(raw)<={'rotationGroups','_selfUrl'} and isinstance(raw.get('rotationGroups'),list),'Rotation list unavailable')
    rows=[]
    for item in raw['rotationGroups']:
        need(item.get('teamSlug')==team and number(item.get('groupId')),'Rotation list identity mismatch')
        rows.append({'id':item['groupId'],'slug':ident(item.get('slug')),'label':text(item.get('label'))})
    need(len({x['id'] for x in rows})==len(rows),'Duplicate rotation ID')
    return sorted(rows,key=lambda x:x['id'])
def group_read(team,gid):
    raw=request('GET','/api-public/v1/teams/'+team+'/rotations/'+str(gid)+'?skip=0&count=1')
    need(isinstance(raw,dict) and set(raw)<={'orgslug','teamslug','id','label','shifts'} and raw.get('id')==gid and raw.get('teamslug')==team and isinstance(raw.get('shifts'),list),'Rotation identity or fields unsupported')
    return clean({'id':gid,'team':team,'label':text(raw.get('label')),'shifts':[shift_project(s,team,gid) for s in raw['shifts']]})
def shift_read(team,gid,sid):
    return shift_project(request('GET','/api-public/v1/teams/'+team+'/rotations/'+str(gid)+'/'+str(sid)+'?skip=0&count=1'),team,gid,sid)
def scheduled_read(team,gid,sid):
    raw=request('GET','/api-public/v1/teams/'+team+'/rotations/'+str(gid)+'/'+str(sid)+'/scheduled')
    if raw is None:return None
    need(isinstance(raw,dict) and isinstance(raw.get('verified'),bool),'Scheduled user is not exposed; do not guess from period existence')
    return {'username':ident(raw.get('username')),'verified':raw['verified']}
def policy_catalog():
    raw=request('GET','/api-public/v1/policies');need(isinstance(raw,dict) and set(raw)<={'policies','_selfUrl'} and isinstance(raw.get('policies'),list),'Policy dependency census unavailable')
    rows=[]
    for item in raw['policies']:
        need(isinstance(item,dict) and set(item)=={'team','policy'} and isinstance(item['team'],dict) and isinstance(item['policy'],dict),'Policy census shape unsupported')
        rows.append({'team':ident(item['team'].get('slug')),'slug':ident(item['policy'].get('slug')),'name':text(item['policy']['name']) if 'name' in item['policy'] else None})
    need(len({x['slug'] for x in rows})==len(rows),'Duplicate policy identity')
    return sorted(rows,key=lambda x:x['slug'])
def checked_policy(slug):
    detail=request('GET','/api-public/v1/policies/'+slug)
    need(isinstance(detail,dict) and set(detail)<={'slug','name','ignoreCustomPagingPolicies','steps','_selfUrl'} and detail.get('slug')==slug and isinstance(detail.get('steps'),list),'Policy dependency detail unavailable')
    entries=[]
    for step in detail['steps']:
        need(isinstance(step,dict) and set(step)<={'timeout','entries'} and isinstance(step.get('entries'),list),'Policy dependency step unsupported')
        if 'timeout' in step:need(number(step['timeout']),'Policy dependency timeout unsupported')
        entries.extend(step['entries'])
    for entry in entries:
        need(isinstance(entry,dict),'Policy dependency entry unsupported')
        kind=entry.get('executionType')
        field={'user':'user','rotation_group':'rotationGroup','rotation_group_next':'rotationGroup','rotation_group_previous':'rotationGroup','webhook':'webhook','email':'email','policy_routing':'targetPolicy'}.get(kind)
        need(field is not None and set(entry)=={'executionType',field} and isinstance(entry[field],dict),'Policy dependency target shape unsupported')
        obj=entry[field]
        key={'user':'username','rotationGroup':'slug','webhook':'slug','email':'address','targetPolicy':'policySlug'}[field]
        allowed={'user':{'username','firstName','lastName'},'rotationGroup':{'slug','label'},'webhook':{'slug','label'},'email':{'address'},'targetPolicy':{'policySlug','policyName'}}[field]
        need(set(obj)<=allowed and isinstance(obj.get(key),str) and bool(obj[key].strip()),'Policy dependency identity missing')
        if field!='email':ident(obj[key])
    return detail,entries
def dependencies(team,gid=None):
    rows=[];target=[] if gid is None else [x['slug'] for x in group_list(team) if x['id']==gid]
    if gid is not None:need(len(target)==1,'Rotation slug cannot be resolved')
    for item in policy_catalog():
        if gid is None and item['team']!=team:continue
        detail,entries=checked_policy(item['slug'])
        if gid is None:rows.append(item['slug'])
        elif any(x['executionType'].startswith('rotation_group') and x['rotationGroup']['slug']==target[0] for x in entries):rows.append(item['slug'])
    return sorted(rows)
def routing_census():
    raw=request('GET','/api-public/v1/org/routing-keys')
    need(isinstance(raw,dict) and set(raw)<={'routingKeys','_selfUrl'} and isinstance(raw.get('routingKeys'),list),'Routing dependency census unavailable')
    rows=[]
    for item in raw['routingKeys']:
        need(isinstance(item,dict) and set(item)<={'routingKey','targets','isDefault','isMultiResponder'} and isinstance(item.get('routingKey'),str) and item['routingKey'] and isinstance(item.get('targets'),list) and type(item.get('isDefault')) is bool,'Routing dependency shape unsupported')
        targets=[]
        for target in item['targets']:
            need(isinstance(target,dict) and set(target)<={'policySlug','policyName','_teamUrl'},'Routing target unsupported');targets.append(ident(target.get('policySlug')))
        if 'isMultiResponder' in item:need(type(item['isMultiResponder']) is bool,'Routing mode unsupported')
        rows.append({'identity_hash':digest(item['routingKey']),'targets':sorted(targets),'isDefault':item['isDefault'],'mode':item.get('isMultiResponder')})
    need(len({x['identity_hash'] for x in rows})==len(rows),'Duplicate routing identity')
    return sorted(rows,key=lambda x:x['identity_hash'])
def empty_override_maintenance():
    overrides=request('GET','/api-public/v1/overrides')
    need(isinstance(overrides,dict) and set(overrides)<={'overrides','_selfUrl'} and overrides.get('overrides')==[],'Existing or unreadable overrides require attended retirement review')
    maintenance=request('GET','/api-public/v1/maintenancemode')
    need(isinstance(maintenance,dict) and set(maintenance)<={'activeInstances','companyId'} and maintenance.get('activeInstances')==[],'Existing or unreadable maintenance requires attended retirement review')
    return {'overrides':[],'maintenance':[]}
def team_retirement_dependencies(team):
    catalog=policy_catalog();implicit=None;nested=[]
    for item in catalog:
        detail,entries=checked_policy(item['slug'])
        if item['team']==team:
            need(item['slug']==team and implicit is None and detail['steps']==[] and detail.get('ignoreCustomPagingPolicies') is False,'Only the empty implicit default policy may retire with an empty owned team')
            implicit={'slug':team,'name':text(detail.get('name')),'steps':[],'ignoreCustomPagingPolicies':False}
        elif any(e['executionType']=='policy_routing' and e['targetPolicy']['policySlug']==team for e in entries):nested.append(item['slug'])
    routes=routing_census();known={x['slug'] for x in catalog}
    need(all(t in known for r in routes for t in r['targets']),'Unresolved routing target prevents retirement')
    need(not nested and not any(team in r['targets'] for r in routes),'Implicit policy has routing or nested-policy consumers')
    return {'catalog':catalog,'implicit_policy':implicit,'routes':routes,'nested_consumers':nested,**empty_override_maintenance()}
def without_version(value):
    return {k:v for k,v in value.items() if k!='version'}
def selected_state(operation,team,gid,sid,payload):
    if operation=='team-create': return {'teams':teams_read()}
    meta=team_read(team); need(meta['isDefaultTeam'] is False,'Default team mutation is refused')
    if operation=='team-update': return {'team':meta}
    if operation=='member-add': return {'team':meta,'members':members_read(team)}
    if operation=='rotation-create': return {'team':meta,'groups':group_list(team),'members':members_read(team)}
    if operation=='team-retire': return {'team':meta,'members':members_read(team),'groups':group_list(team),'teams':teams_read(),'dependencies':team_retirement_dependencies(team)}
    group=group_read(team,gid)
    if operation in ('rotation-rename','shift-create'): return {'group':group}
    if operation=='rotation-retire': return {'group':group,'dependencies':dependencies(team,gid)}
    shift=shift_read(team,gid,sid)
    if operation=='shift-update': return {'shift':shift}
    if operation=='shift-retire': return {'shift':shift,'dependencies':dependencies(team,gid)}
    return {'shift':shift,'members':members_read(team),'scheduled':scheduled_read(team,gid,sid)}

def validate_payload(op,p):
    need(isinstance(p,dict),'Change JSON must be an object')
    if op in ('team-create','team-update'):
        need(set(p)=={'name','description'},'Team changes require exact name and description');text(p['name']);text(p['description'],True)
    elif op=='rotation-create':
        need(set(p)<={'label','shifts'} and 'label' in p and isinstance(p.get('shifts',[]),list),'Rotation payload unsupported');text(p['label'])
        for shift in p.get('shifts',[]): shift_payload(shift,True)
    elif op=='rotation-rename': need(set(p)=={'label'},'Rename only changes label');text(p['label'])
    elif op in ('shift-create','shift-update'): shift_payload(p)
    elif op in ('member-add','roster-add','roster-move','roster-remove','scheduled-set'):
        permitted={'username'} if op=='member-add' else {'username','position','memberSlug','replacement'}
        need('username' in p and set(p)<=permitted,'Membership payload unsupported');ident(p['username'])
        if 'position' in p: need(number(p['position']),'Position must be a nonnegative integer')
        if 'memberSlug' in p: ident(p['memberSlug'])
        if 'replacement' in p: ident(p['replacement'])
        if op=='roster-add': need(set(p)<={'username','position'},'Roster add accepts username/position only')
        if op=='roster-move': need('position' in p and 'replacement' not in p,'Move requires position')
        if op=='roster-remove': need('position' not in p,'Remove does not accept position')
        if op=='scheduled-set': need('replacement' not in p,'Scheduled selection has no replacement field')
    else: need(p=={},'Retirement has no payload')
    return clean(p)

def expected_change(op,before,p):
    desired=copy.deepcopy(before)
    if op=='team-update':
        need(isinstance(before['team']['description'],str),'Team metadata replacement requires a restorable description')
        desired['team'].update(p)
    elif op=='rotation-rename': desired['group']['label']=p['label']
    elif op=='shift-update': desired['shift']['config']=p
    elif op in ('roster-add','roster-move','roster-remove','scheduled-set'):
        roster=before['shift']['members']; selected=[(i,x) for i,x in enumerate(roster) if x['username']==p['username'] and ('memberSlug' not in p or x['slug']==p['memberSlug'])]
        if op=='roster-add':
            need(not selected,'Responder already appears in the shift; do not create duplicate roster entries')
            need(p.get('position',len(roster))<=len(roster),'Roster position outside current bounds')
        else:
            need(len(selected)==1,'Select exactly one existing roster member, using memberSlug for duplicates')
            if op=='roster-move': need(p['position']<len(roster),'Roster position outside current bounds')
            if op=='roster-remove':
                need(len({x['username'] for x in roster})>1,'Do not remove the last distinct responder')
                if (before['scheduled'] or {}).get('username')==p['username']:
                    need(p.get('replacement') and p['replacement']!=p['username'] and any(x['username']==p['replacement'] for x in roster),'Removing the scheduled user needs a different existing replacement')
        need(any(x['username']==p['username'] and x['verified'] for x in before['members']),'Select a verified existing team member before roster changes')
    elif op=='member-add': need(not any(x['username']==p['username'] for x in before['members']),'Member already belongs to team')
    elif op=='rotation-create':
        need(not any(x['label']==p['label'] for x in before['groups']),'Rotation label collision')
        members={x['username'] for x in before['members'] if x['verified']}
        need(all(u in members for shift in p.get('shifts',[]) for u in shift.get('usernames',[])),'Inline shift responders must already be verified team members')
    elif op=='shift-create': need(not any(x['config']['label']==p['label'] for x in before['group']['shifts']),'Shift label collision')
    elif op=='team-create': need(not any(x['name']==p['name'] for x in before['teams']),'Team name collision')
    elif op.endswith('-retire'):
        if op=='team-retire':need(not before['groups'] and not before['members'] and before['team']['memberCount']==0,'Automatic team retirement requires no members or rotations')
        else:need(not before['dependencies'],'Retirement blocked by referencing policies')
        if op=='rotation-retire': need(not before['group']['shifts'],'Retire owned shifts first')
    return desired

def effect(op,before,observed,p):
    if op=='team-update': return without_version(observed['team'])==without_version({**before['team'],**p})
    if op=='rotation-rename': return observed=={'group':{**before['group'],'label':p['label']}}
    if op=='shift-update': return observed=={'shift':{**before['shift'],'config':p}}
    if op=='member-add':
        return observed['members']==sorted(before['members']+[{'username':p['username'],'verified':True}],key=lambda x:x['username']) and without_version(observed['team'])=={**without_version(before['team']),'memberCount':before['team']['memberCount']+1}
    if op.startswith('roster-') or op=='scheduled-set':
        if observed['members']!=before['members'] or observed['shift']['config']!=before['shift']['config']: return False
        old=before['shift']['members']; new=observed['shift']['members']
        duty=observed['scheduled']
        if duty is not None and (duty.get('verified') is not True or not any(x['username']==duty.get('username') for x in new)):return False
        expected_duty=before['scheduled']
        if op=='roster-add' and not old and before['scheduled'] is None:expected_duty={'username':p['username'],'verified':True}
        if op=='roster-remove' and (before['scheduled'] or {}).get('username')==p['username']:expected_duty={'username':p.get('replacement'),'verified':True}
        if op.startswith('roster-') and duty!=expected_duty:return False
        selected=[(i,x) for i,x in enumerate(old) if x['username']==p['username'] and ('memberSlug' not in p or x['slug']==p['memberSlug'])]
        if op=='roster-add':
            extra=[x for x in new if x['slug'] not in {y['slug'] for y in old}]
            if len(extra)!=1 or extra[0]['username']!=p['username']: return False
            expected=copy.deepcopy(old);expected.insert(p.get('position',len(old)),extra[0]);return new==expected
        if len(selected)!=1:return False
        idx,item=selected[0]; expected=copy.deepcopy(old)
        if op=='roster-move': expected.pop(idx);expected.insert(p['position'],item);return new==expected
        if op=='roster-remove': expected.pop(idx);return new==expected
        return new==old and observed['scheduled']=={'username':p['username'],'verified':True}
    return False

try:
    credentials=[os.environ['SOC_ID'],os.environ['SOC_READ'],os.environ['SOC_WRITE']]
    op=os.environ['SOC_OPERATION']; mode=os.environ['SOC_MODE'];run=ident(os.environ['SOC_RUN_ID'])
    ops={'team-create','team-update','member-add','rotation-create','rotation-rename','shift-create','shift-update','roster-add','roster-move','roster-remove','scheduled-set','team-retire','rotation-retire','shift-retire'}
    need(op in ops and mode in ('plan','apply','restore','reconcile'),'Unsupported operation or mode')
    anchor=ident(os.environ['SOC_TEAM']);team=ident(os.environ.get('SOC_OBJECT_TEAM') or anchor)
    gid=int(os.environ.get('SOC_GROUP_ID') or '0');sid=int(os.environ.get('SOC_SHIFT_ID') or '0')
    need(gid>=0 and sid>=0,'Negative object ID')
    segment=os.environ['SOC_SEG']; identity={'target':segment,'anchor':anchor,'team':team,'group':gid,'shift':sid,'operation':op,'credential_fingerprint':os.environ['SOC_CREDENTIAL_FINGERPRINT']}
    need(team_read(anchor)==team_read(anchor,'write'),'Read/setup credentials disagree on anchor state')
    parent=pathlib.Path(os.environ.get('SCOUTFLO_AUDIT_DIR','./scoutflo-audits'))/segment
    out=parent/('setup-'+run);planpath=out/'plan.json'
    if mode=='plan':
        need(not os.environ.get('SOC_APPROVED_PLAN'),'Do not preapprove an unseen plan')
        payload=validate_payload(op,parse(os.environ.get('SOC_CHANGE_JSON','{}')))
        for username in sorted({payload['username']} if 'username' in payload else {u for shift in payload.get('shifts',[]) for u in shift.get('usernames',[])}):eligible(username)
        if 'replacement' in payload:eligible(payload['replacement'])
        before=selected_state(op,team,gid,sid,payload); expected_change(op,before,payload)
        ownership=None
        if op.endswith('-retire'):
            owner=ident(os.environ.get('SOC_CREATED_RUN',''))
            ownership=read_local(parent/('setup-'+owner)/'applied.json')
            need(ownership.get('created') and ownership.get('credential_fingerprint')==identity['credential_fingerprint'] and ownership.get('target')==segment,'Retirement needs this target/credential generation successful create journal')
            owned=ownership['created'];field={'team-retire':'team','rotation-retire':'group','shift-retire':'shift'}[op]
            allowed_creator={'team-retire':{'team-create'},'rotation-retire':{'rotation-create'},'shift-retire':{'shift-create','rotation-create'}}[op]
            need(ownership.get('operation') in allowed_creator,'The referenced journal did not create this kind of object')
            need(owned.get('team')==team and (field=='team' or owned.get('group')==gid) and (field!='shift' or owned.get('shift')==sid or sid in owned.get('shifts',[])),'Created-object ownership mismatch')
        parent.mkdir(parents=True,exist_ok=True);out.mkdir(mode=0o700)
        plan={'schema':'scoutflo-oncall-workflow/v1',**identity,'payload':payload,'before':before,'ownership':ownership,'provider_side_effects':(['implicit default escalation policy'] if op=='team-create' else ['delete the empty implicit default escalation policy'] if op=='team-retire' and before['dependencies']['implicit_policy'] else [])}
        exclusive(planpath,plan)
        print(json.dumps({'operation':op,'target':segment,'plan_file':str(planpath),'planned_fields':sorted(payload),'approval':'apply:'+digest(plan)}))
        print('Read-only plan. Review the complete private plan and confirm its exact effects before applying.')
        sys.exit(0)
    need(out.is_dir() and not out.is_symlink(),'Missing or unsafe run directory')
    plan=read_local(planpath);need(all(plan.get(k)==v for k,v in identity.items()),'Plan target, operation or credentials changed')
    payload=validate_payload(op,plan['payload']);before=plan['before'];expected_change(op,before,payload)
    if mode!='reconcile':need(os.environ.get('SOC_APPROVED_PLAN')==mode+':'+digest(plan),'Exact action/plan approval required')
    restoreable={'team-update','rotation-rename','shift-update','roster-move'}
    if mode=='restore':
        need(op in restoreable,'This operation is not an automatic inverse; prepare a separate guarded retirement or duty-change plan')
        applied=read_local(out/'applied.json');before=applied['observed']
        if op=='team-update':payload={k:plan['before']['team'][k] for k in ('name','description')}
        elif op=='rotation-rename':payload={'label':plan['before']['group']['label']}
        elif op=='shift-update':payload=plan['before']['shift']['config']
        else:
            original=plan['before']['shift']['members'];matches=[(i,x) for i,x in enumerate(original) if x['username']==payload['username'] and ('memberSlug' not in payload or x['slug']==payload['memberSlug'])]
            need(len(matches)==1,'Original roster member ambiguous');payload={'username':matches[0][1]['username'],'memberSlug':matches[0][1]['slug'],'position':matches[0][0]}
    current=None if mode=='reconcile' and op.endswith('-retire') else selected_state(op,team,gid,sid,payload)
    creating=op in ('team-create','rotation-create','shift-create')
    retiring=op.endswith('-retire')
    if mode!='reconcile':need(current==before,'Drift from approved state; do not overwrite parallel work')
    if mode=='reconcile':need((out/'apply.started').is_file(),'No attempted apply to reconcile')
    if mode!='reconcile':
        for username in sorted({payload['username']} if 'username' in payload else {u for shift in payload.get('shifts',[]) for u in shift.get('usernames',[])}):eligible(username)
        if 'replacement' in payload:eligible(payload['replacement'])
        for path in (out/(mode+'.started'),out/(mode+'.result.json')):
            need(not path.exists() and not path.is_symlink(),'Attempt/result already exists; reconcile instead of replaying')
        if mode=='apply':need(not (out/'applied.json').exists() and not (out/'applied.json').is_symlink(),'Applied record already exists')
        exclusive(out/(mode+'.started'),{'operation':op,'action':mode,'effect':'unknown'})
        base='/api-public/v1/teams/'+team+'/rotations'
        method,path,body='PUT','',payload
        if op=='team-create':method,path='POST','/api-public/v1/team'
        elif op=='team-update':path='/api-public/v1/team/'+team
        elif op=='member-add':method,path='POST','/api-public/v1/team/'+team+'/members'
        elif op=='rotation-create':method,path='POST',base
        elif op=='rotation-rename':path=base+'/'+str(gid)
        elif op=='shift-create':method,path='POST',base+'/'+str(gid)
        elif op=='shift-update':path=base+'/'+str(gid)+'/'+str(sid)
        elif op.startswith('roster-'):method,path={'roster-add':'POST','roster-move':'PUT','roster-remove':'DELETE'}[op],base+'/'+str(gid)+'/'+str(sid)+'/members'
        elif op=='scheduled-set':path=base+'/'+str(gid)+'/'+str(sid)+'/scheduled'
        elif op=='team-retire':method,path,body='DELETE','/api-public/v1/team/'+team,None
        elif op=='rotation-retire':method,path,body='DELETE',base+'/'+str(gid),None
        elif op=='shift-retire':method,path,body='DELETE',base+'/'+str(gid)+'/'+str(sid),None
        write_status='unknown'
        try:write_status='received-'+request(method,path,body,'write')
        except Stop as exc:
            write_status=str(exc)
            if write_status.startswith('HTTP 4') and not write_status.startswith('HTTP 408'):raise
    else:write_status='reconciled-without-retry'
    created=None
    if creating:
        if op=='team-create':
            rows=teams_read();old={x['slug'] for x in before['teams']};new=[x for x in rows if x['slug'] not in old and x['name']==payload['name']]
            need(len(new)==1 and [x for x in rows if x['slug'] in old]==before['teams'],'Creation is absent, ambiguous or accompanied by concurrent team changes')
            newteam=team_read(new[0]['slug']);need(newteam['name']==payload['name'] and newteam['description']==payload['description'] and not newteam['isDefaultTeam'],'Team creation fields differ')
            observed={'team':newteam};created={'team':newteam['slug']}
        elif op=='rotation-create':
            rows=group_list(team);old={x['id'] for x in before['groups']};new=[x for x in rows if x['id'] not in old and x['label']==payload['label']]
            need(len(new)==1 and [x for x in rows if x['id'] in old]==before['groups'],'Creation is absent, ambiguous or accompanied by concurrent rotation changes')
            group=group_read(team,new[0]['id']);need(len(group['shifts'])==len(payload.get('shifts',[])),'Created shift count differs')
            for actual,wanted in zip(group['shifts'],payload.get('shifts',[])):
                need(actual['config']=={k:v for k,v in wanted.items() if k!='usernames'} and [x['username'] for x in actual['members']]==wanted.get('usernames',[]),'Created shift fields or roster differ')
            observed={'group':group};created={'team':team,'group':group['id'],'rotation_slug':new[0]['slug'],'shifts':[x['id'] for x in group['shifts']]}
        else:
            group=group_read(team,gid);old={x['id'] for x in before['group']['shifts']};new=[x for x in group['shifts'] if x['id'] not in old and x['config']['label']==payload['label']]
            need(len(new)==1 and [x for x in group['shifts'] if x['id'] in old]==before['group']['shifts'] and group['label']==before['group']['label'],'Creation is absent, ambiguous or accompanied by concurrent shift changes')
            need(new[0]['config']==payload and new[0]['members']==[],'Standalone shift creation differs or silently populated roster')
            observed={'shift':new[0]};created={'team':team,'group':gid,'shift':new[0]['id']}
    elif retiring:
        if op=='team-retire':
            need(teams_read()==[x for x in before['teams'] if x['slug']!=team],'Team removal or unrelated team census preservation differs')
            need(policy_catalog()==[x for x in before['dependencies']['catalog'] if x['slug']!=team],'Implicit policy removal or unrelated policy preservation differs')
            need(routing_census()==before['dependencies']['routes'],'Unrelated routing changed during team retirement')
            empty_override_maintenance()
        elif op=='rotation-retire':need(all(x['id']!=gid for x in group_list(team)),'Rotation still exists')
        else:need(all(x['id']!=sid for x in group_read(team,gid)['shifts']),'Shift still exists')
        observed={'retired':True}
    else:
        observed=selected_state(op,team,gid,sid,payload);need(effect(op,before,observed,payload),'Readback differs from requested or preserved fields; do not retry')
    receipt={'target':segment,'credential_fingerprint':identity['credential_fingerprint'],'operation':op,'observed':observed,'created':created}
    if mode in ('apply','reconcile') and not (out/'applied.json').exists():exclusive(out/'applied.json',receipt)
    exclusive(out/(mode+'.result.json'),{'action':mode,'effect':'verified-by-readback','write_response':write_status})
    print(json.dumps({'operation':op,'action':mode,'effect':'verified-by-readback','record':str(out),'created_identity_recorded':created is not None}))
except (Stop,ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as exc:
    # Provider bodies, payloads, credentials and personal contact values never reach errors.
    message=str(exc) if isinstance(exc,Stop) else 'Invalid input, unsupported response or unsafe local record'
    print(message,file=sys.stderr);sys.exit(1)

PY_WORKFLOW
unset SOC_ID SOC_READ SOC_WRITE SOC_VALUE SOC_CREDENTIAL_FINGERPRINT SOC_HASH_LINE
```
<!-- oncall-team-rotation:end -->

## Membership removal and replacement

The team-member DELETE takes a required `replacement` body. It can reassign references outside the member list; adding the original member back is not its inverse. For an existing person's removal, first enumerate that team's rotations, policy entries and override assignments, name the exact eligible replacement and affected intervals, and obtain approval for the complete reassignment. Use the provider's supported member-removal flow, then compare each named reference and rendered interval with the plan. Do not infer successful reassignment from a missing member row. This is a documented guided workflow until complete reassignment/restore behavior is observed; the fixed recipe deliberately offers no generic member DELETE.

A pending invitation is not an enrolled responder. Neither duplicate usernames in a shift nor two policies selecting one person prove independent fallback. Do not send invitations to make a verification fixture pass.

## Readback, records and remaining proof

A bodyless HTTP 204 is a valid roster-write acknowledgment; it proves no resulting state until the independent GET matches. A successful action records `verified-by-readback` for the requested fields and preserved state. It does not turn schema research into delivery proof. This recipe is grounded in the official [VictorOps v1 specification](https://portal.victorops.com/api-docs/victorops-api-v1.yaml) and populated November 2026 team/rotation/shift reads. Each write family's live permission, creation, replacement and retirement proof must be recorded separately by the operator; a dry run or fixture test is not a live pass.

After verification, run `/scoutflo:audit-splunk-oncall` with the same target and the read-only credential. If a capability is unavailable for the observed product shape, keep the exact missing field or permission explicit and use the supported provider UI with a complete before/after review; do not invent an API fallback.

- ❌ Put `usernames` into standalone shift PUT and assume staffing changed.
- ✅ Replace the complete timing configuration, verify the roster stayed equal, then make a separately approved roster change and verify it.
- ❌ Delete a rotation because its team belongs to this run.
- ✅ Match the exact rotation's successful creation journal, prove policy references absent, retire its owned shifts, then confirm the rotation is absent from a complete list.
- ❌ Retry a create after a timeout.
- ✅ Keep the attempt marker, reconcile the unique planned name and full fields against the prior list, and stop on absent or ambiguous evidence.
