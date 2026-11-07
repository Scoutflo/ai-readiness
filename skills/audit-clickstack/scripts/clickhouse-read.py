#!/usr/bin/env python3
"""Fixed ClickHouse audit transport and known-column projection."""
import fcntl, hashlib, hmac, http.client, ipaddress, json, math, os, pathlib, re, stat, sys, tempfile, time, urllib.parse
LIMIT=1048576
TTL=1800
TABLES={'tables','columns','parts','errors','mutations','replicas','disks','merge_tree_settings','query_log','users'}
NUMBERS={'logs','spans','rows','lag_s','total','total_rows','total_bytes','code','value','is_done','is_readonly','absolute_delay','queue_size','active_parts','bytes','free_space','total_space','used_pct','exception_code','n','is_session_expired'}
IDENTIFIERS={'ServiceName','tbl','table','name','database','mutation_id','host','user'}
DATES={'latest','last_error_time','oldest','newest','event_time'}
ENGINES={'MergeTree','ReplicatedMergeTree','ReplacingMergeTree','ReplicatedReplacingMergeTree','AggregatingMergeTree','ReplicatedAggregatingMergeTree','SummingMergeTree','ReplicatedSummingMergeTree','Distributed','Memory','Log','TinyLog','Null','View','MaterializedView'}
PRIVILEGES={'SELECT','SHOW','SHOW TABLES','SHOW DATABASES','SHOW COLUMNS','SHOW DICTIONARIES','SHOW USERS','SHOW GRANTS','USAGE','INSERT','ALTER','CREATE','DROP','TRUNCATE','OPTIMIZE','SYSTEM','ALL','NONE','ACCESS MANAGEMENT'}
FUNCTIONS={'count','countif','sum','max','min','datediff','now','currentdatabase','round','nullif','tostartofminute','in','from'}
class Blocked(Exception): pass
def need(v):
    if not v: raise Blocked()
def canonical(v): return json.dumps(v,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
def pairs(values):
    out={}
    for k,v in values: need(k not in out); out[k]=v
    return out
def parse(raw):
    need(len(raw)<=LIMIT)
    return json.loads(raw,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(Blocked()))
def clean(v,key,pattern=r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}'):
    if not isinstance(v,str) or not re.fullmatch(pattern,v) or (key and key in v): return None
    if re.search(r'(?i)(?:bearer|password|api[-_]?key|credential|authorization|token|secret)[_:=]|(?:ghp_|github_pat_|sk_live_|NRAK-)|[A-Za-z0-9_-]{40,}',v): return None
    return v

def target_url(value):
    u=urllib.parse.urlsplit(value)
    need(u.scheme in ('http','https') and u.hostname and not u.username and not u.password and not u.query and not u.fragment)
    need(not any(ord(c)<33 for c in value) and not re.search(r'%0[ad]',value,re.I) and u.path in ('','/'))
    need(1<=(u.port or (443 if u.scheme=='https' else 80))<=65535)
    return u

def sql_read(sql):
    need(isinstance(sql,str) and 0<len(sql)<=16384 and not any(ord(c)<32 and c not in '\n\t\r' for c in sql))
    need(not any(x in sql for x in (';','--','/*','*/')))
    s=re.sub(r'\s+FORMAT\s+(?:JSON|TabSeparatedWithNames|TabSeparatedRaw|TabSeparated)\s*$','',sql.strip(),flags=re.I)
    if re.fullmatch(r'SELECT\s+1',s,re.I): return 'SELECT 1','one'
    if re.fullmatch(r'SELECT\s+hostName\(\)\s+AS\s+host,\s*currentUser\(\)\s+AS\s+user,\s*currentDatabase\(\)\s+AS\s+database,\s*version\(\)\s+AS\s+version',s,re.I): return s+' FORMAT JSON','identity'
    if re.fullmatch(r'SHOW\s+CREATE\s+TABLE\s+(?:[A-Za-z_][A-Za-z0-9_]*\.)?[A-Za-z_][A-Za-z0-9_]*',s,re.I): return s+' FORMAT JSON','ddl'
    if re.fullmatch(r'SHOW\s+GRANTS\s+FOR\s+[A-Za-z_][A-Za-z0-9_.-]*',s,re.I): return s+' FORMAT JSON','grants'
    need(re.match(r'^SELECT\s',s,re.I) is not None)
    stripped=re.sub(r"'(?:''|\\.|[^'])*'", '', s)
    need("'" not in stripped and '"' not in stripped)
    stripped=re.sub(r'`([A-Za-z_][A-Za-z0-9_]*)`',r'\1',stripped)
    need('`' not in stripped)
    need(not re.search(r'\b(?:INSERT|UPDATE|DELETE|ALTER|DROP|TRUNCATE|CREATE|ATTACH|DETACH|RENAME|SYSTEM|INTO|OUTFILE|INFILE|SETTINGS|FORMAT|KILL|WATCH|EXPLAIN)\b',re.sub(r'\bsystem\.','',stripped,flags=re.I),re.I))
    refs=re.findall(r'\b(?:FROM|JOIN)\s+([^\s,()]+|\()',stripped,re.I); need(refs)
    for ref in refs:
        if ref=='(': continue
        need(bool(re.fullmatch(r'otel_[A-Za-z0-9_]+',ref)) or ref.startswith('system.') and ref[7:] in TABLES)
    need(all(name.lower() in FUNCTIONS for name in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\(',stripped)))
    return s+' FORMAT JSON','select'

def request(url,user,key,sql,readonly=False,anonymous=False):
    u=target_url(url)
    conn=(http.client.HTTPSConnection if u.scheme=='https' else http.client.HTTPConnection)(u.hostname,u.port,timeout=20)
    headers={'Content-Type':'text/plain; charset=utf-8','Accept':'application/json','Accept-Encoding':'identity'}
    if not anonymous: headers.update({'X-ClickHouse-User':user,'X-ClickHouse-Key':key})
    try:
        deadline=time.monotonic()+20
        conn.connect(); sock=conn.sock
        def remaining():
            left=deadline-time.monotonic(); need(left>0); sock.settimeout(left)
        remaining(); conn.request('POST','/?readonly=1' if readonly else '/',sql.encode(),headers)
        remaining()
        response=conn.getresponse(); length=response.getheader('Content-Length')
        if length is not None: need(length.isdigit() and int(length)<=LIMIT)
        chunks=[]; total=0
        while not response.isclosed():
            remaining(); chunk=response.read1(min(65536,LIMIT+1-total))
            if not chunk: break
            total+=len(chunk); need(total<=LIMIT); chunks.append(chunk)
        body=b''.join(chunks)
        return response.status,body
    finally: conn.close()

def probe_response(status,body):
    if status==200 and body.strip()==b'1': return 'ro',0
    text=body.decode('utf-8',errors='replace')
    if status>=400 and re.match(r'\s*Code:\s*164\.\s*DB::Exception:',text) and re.search(r"Cannot modify ['\"]?readonly['\"]? setting in readonly mode",text): return 'plain',1
    raise Blocked()

def bound_probe(path,url,user,key,target,key_env):
    cache=pathlib.Path(path); cache.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    need(not cache.is_symlink() and not cache.parent.is_symlink())
    lock=cache.with_name(cache.name+'.lock'); need(not lock.is_symlink())
    fd=os.open(lock,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'a+') as locked:
        deadline=time.monotonic()+5
        while True:
            try: fcntl.flock(locked,fcntl.LOCK_EX|fcntl.LOCK_NB); break
            except BlockingIOError:
                need(time.monotonic()<deadline); time.sleep(.05)
        now=int(time.time()); generation={'target':target,'url':url.rstrip('/'),'user':user,'password_env':key_env}
        def mac(v): return hmac.new(key.encode(),canonical(v),hashlib.sha256).hexdigest()
        if cache.exists():
            info=cache.stat(); need(info.st_uid==os.getuid() and stat.S_IMODE(info.st_mode)&0o077==0)
            with cache.open('rb') as f: saved=parse(f.read(LIMIT+1))
            if isinstance(saved,dict) and set(saved)=={'schema','binding','mode','observed_at','code164_count','hmac'}:
                payload={k:v for k,v in saved.items() if k!='hmac'}
                if saved['schema']=='scoutflo-clickhouse-probe/v1' and saved['binding']==generation and saved['mode'] in ('ro','plain') and type(saved['observed_at']) is int and 0<=now-saved['observed_at']<=TTL and saved['code164_count'] in (0,1) and isinstance(saved['hmac'],str) and hmac.compare_digest(saved['hmac'],mac(payload)):
                    return saved['mode'],{'mode':saved['mode'],'source':'cache','code164_count':saved['code164_count'],'new_code164_errors':0,'observed_at':saved['observed_at']}
        status,body=request(url,user,key,'SELECT 1',readonly=True); mode,count=probe_response(status,body)
        if mode=='plain':
            status,body=request(url,user,key,'SELECT 1'); need(status==200 and body.strip()==b'1')
        value={'schema':'scoutflo-clickhouse-probe/v1','binding':generation,'mode':mode,'observed_at':now,'code164_count':count}; value['hmac']=mac(value)
        outfd,tmp=tempfile.mkstemp(prefix='.probe-',dir=cache.parent)
        try:
            with os.fdopen(outfd,'wb') as f: f.write(canonical(value)+b'\n')
            os.chmod(tmp,0o600); os.replace(tmp,cache)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
        return mode,{'mode':mode,'source':'fresh','code164_count':count,'new_code164_errors':count,'observed_at':now}

def ttl_projection(value,full_ddl=True):
    need(isinstance(value,str))
    # Ignore engine credentials/string literals, comments, and quoted names.
    # Only one table-level TTL after the closed column declaration is understood.
    text=re.sub(r"'(?:''|\\.|[^'])*'", "''", value)
    text=re.sub(r'`([A-Za-z_][A-Za-z0-9_]*)`',r'\1',text)
    valid=not any(x in text for x in ('--','/*','*/','`','"')) and "'" not in text.replace("''",'')
    if full_ddl: valid=valid and bool(re.match(r'^\s*CREATE\s+TABLE\s',text,re.I)) and '(' in text and text.count('(')==text.count(')')
    ttl=list(re.finditer(r'\bTTL\b',text,re.I))
    if not ttl: return {'present':False if full_ddl and valid else None,'days':None,'assessment':'known' if full_ddl and valid else 'unknown'}
    match=re.search(r'\bTTL\s+(?:toDateTime\([A-Za-z_][A-Za-z0-9_]*\)|[A-Za-z_][A-Za-z0-9_]*)\s*\+\s*(?:toIntervalDay\(\s*([0-9]{1,6})\s*\)|INTERVAL\s+([0-9]{1,6})\s+DAY)(?:\s+DELETE)?\s*(?:SETTINGS\b[^;]*|$)',text,re.I) if valid and len(ttl)==1 else None
    if match and text[:match.start()].count('(')!=text[:match.start()].count(')'): match=None
    return {'present':True,'days':int(match[1] or match[2]) if match else None,'assessment':'known' if match else 'unknown'}

def hosts(value):
    try:
        if isinstance(value,str): value=json.loads(value)
        need(isinstance(value,list) and value)
        nets=[ipaddress.ip_network(x,strict=False) for x in value]
        return {'any_network':any(n.prefixlen==0 for n in nets),'loopback_only':all(n.is_loopback for n in nets),'restricted':all(n.prefixlen>0 for n in nets),'assessment':'known'}
    except (ValueError,TypeError,Blocked): return {'any_network':None,'loopback_only':None,'restricted':None,'assessment':'unknown'}

def project(body,kind,key):
    data=parse(body); need(isinstance(data,dict) and isinstance(data.get('data'),list) and len(data['data'])<=50000)
    need(type(data.get('rows')) is int and data['rows']==len(data['data']))
    need(not data.get('exception') and not data.get('error'))
    output=[]; unknown=set(); omitted=set()
    for row in data['data']:
        need(isinstance(row,dict)); out={}
        for name,value in row.items():
            if name in NUMBERS:
                if isinstance(value,str) and re.fullmatch(r'-?\d+(?:\.\d+)?',value): value=float(value) if '.' in value else int(value)
                if type(value) not in (int,float) or not math.isfinite(value): out[name]=None; omitted.add(name)
                else: out[name]=value
            elif name in IDENTIFIERS:
                out[name]=clean(value,key)
                if out[name] is None: omitted.add(name)
            elif name in DATES:
                if isinstance(value,str) and re.fullmatch(r'\d{4}-\d\d-\d\d(?:[ T]\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|[+-]\d\d:\d\d)?)?',value): out[name]=value
                else: out[name]=None; omitted.add(name)
            elif name=='version':
                out[name]=value if isinstance(value,str) and re.fullmatch(r'\d{1,4}(?:\.\d{1,8}){1,4}',value) else None
                if out[name] is None: omitted.add(name)
            elif name in ('engine_full','create_table_query','statement') and (name!='statement' or kind=='ddl'):
                if name!='engine_full' or 'ttl' not in out: out['ttl']=ttl_projection(value,name!='engine_full')
            elif name=='latest_fail_reason': need(isinstance(value,str)); out['fail_reason_present']=bool(value)
            elif name=='host_ip': out['host_scope']=hosts(value)
            elif name=='engine':
                out[name]=value if value in ENGINES else None
                if out[name] is None: omitted.add(name)
            elif name=='kind':
                out[name]=value if value in ('gauge','sum','histogram','summary','logs','spans','metrics') else None
                if out[name] is None: omitted.add(name)
            elif name=='auth_type':
                values=value if isinstance(value,list) else [value]; known={'no_password','plaintext_password','sha256_password','double_sha1_password','ldap','kerberos','ssl_certificate','bcrypt_password','ssh_key','http','jwt'}
                out[name]=values if all(v in known for v in values) else None
                if out[name] is None: omitted.add(name)
            elif name=='type':
                allowed={'String','FixedString','Date','Date32','DateTime','DateTime64','UInt8','UInt16','UInt32','UInt64','UInt128','UInt256','Int8','Int16','Int32','Int64','Int128','Int256','Float32','Float64','Bool','UUID','IPv4','IPv6','Decimal','Decimal32','Decimal64','Decimal128','Decimal256','Nullable','LowCardinality','Array','Map','Tuple','Nothing','UTC'}
                out[name]=clean(value,key,r'[A-Za-z][A-Za-z0-9_(), .\x27]{0,127}')
                if out[name] is not None and not all(t in allowed for t in re.findall(r'[A-Za-z_][A-Za-z0-9_]*',value)): out[name]=None
                if out[name] is None: omitted.add(name)
            elif kind=='grants' and name in ('GRANTS','grant','statement'):
                need(isinstance(value,str)); match=re.match(r'GRANT\s+(.+?)\s+ON\s+',value,re.I)
                privileges=[p.strip().upper() for p in match[1].split(',')] if match else []; known=bool(privileges) and all(p in PRIVILEGES for p in privileges)
                out.update(privileges=privileges if known else [],readonly_evidenced=known and 'WITH GRANT OPTION' not in value.upper() and all(p in {'SELECT','SHOW','SHOW TABLES','SHOW DATABASES','SHOW COLUMNS','SHOW DICTIONARIES','SHOW USERS','SHOW GRANTS','USAGE','NONE'} for p in privileges),scope_redacted=True,assessment='known' if known else 'unknown')
            else: unknown.add('unrecognized-column')
        output.append(out)
    return output,sorted(unknown),sorted(omitted)

try:
    action,url,user,target,key_env,cache=sys.argv[1:]; target_url(url)
    need(clean(user,'') is not None and re.fullmatch(r'clickstack(?:/[A-Za-z0-9_-]+)?',target) and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',key_env))
    key=sys.stdin.buffer.readline(8193).decode().rstrip('\n'); need(key and len(key)<=8192 and not any(ord(c)<32 for c in key))
    sql=sys.stdin.buffer.read(16385).decode(); need(len(sql)<=16384)
    if action=='default-probe':
        status,body=request(url,user,key,'SELECT 1',anonymous=True); state='unverified'
        if status==200 and body.strip()==b'1': state='accessible'
        elif status in (401,403) and re.match(rb'\s*Code:\s*(?:194|516)\.\s*DB::Exception:',body) and b'AUTHENTICATION_FAILED' in body: state='denied'
        print(json.dumps({'default_user_access':state})); sys.exit(0)
    need(action=='query'); query,kind=sql_read(sql)
    mode,probe=bound_probe(cache,url,user,key,target,key_env)
    if kind=='one':
        if probe['source']=='cache':
            status,body=request(url,user,key,'SELECT 1',readonly=(mode=='ro')); need(status==200 and body.strip()==b'1')
        print('1'); sys.exit(0)
    status,body=request(url,user,key,query,readonly=(mode=='ro')); need(status==200)
    rows,unknown,omitted=project(body,kind,key)
    print(json.dumps({'data':rows,'rows':len(rows),'_scoutflo':{'target':target,'projection':'known-clickhouse-columns/v1','unknown_fields':unknown,'omitted_fields':omitted,'probe':probe}},sort_keys=True,allow_nan=False))
except Exception:
    print('ClickHouse read blocked: invalid binding, unsupported SQL, transport or projected evidence; no raw response retained.',file=sys.stderr); sys.exit(2)
