#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import fcntl,concurrent.futures,hashlib,hmac,json,os,pathlib,re,subprocess,sys,tempfile,threading,time,unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=pathlib.Path(sys.argv.pop())
CANARY='PRIVATE_TOKEN_NOT_FOR_REPORT'
KEY='unit-password-canary-42'
QUERY='SELECT name, total_rows FROM system.tables FORMAT JSON'
def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=True,allow_nan=False).encode()
def packet(rows):return json.dumps({'meta':[],'data':rows,'rows':len(rows)}).encode()
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);self.seen=[];self.state={'probe':'plain','anonymous':'denied','rows':[{'name':'otel_logs','total_rows':'12'}]}
  owner=self
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_POST(self):
    sql=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode();key=self.headers.get('X-ClickHouse-Key');user=self.headers.get('X-ClickHouse-User');status=200
    if key is None:
     a=owner.state['anonymous']
     status,body={'denied':(401,b'Code: 516. DB::Exception: Authentication failed. (AUTHENTICATION_FAILED)'), 'generic':(403,CANARY.encode()), 'html':(200,b'<html>'+CANARY.encode()+b'</html>'), 'accessible':(200,b'1\n')}[a]
    elif sql.strip()=='SELECT 1':
     mode=owner.state['probe']
     if mode=='denied':status,body=403,CANARY.encode()
     elif mode=='html':body=b'<html>'+CANARY.encode()+b'</html>'
     elif mode=='redirect':status,body=302,b''
     elif mode=='imprecise':status,body=500,b'Code: 164. DB::Exception: other readonly problem '+CANARY.encode()
     elif mode=='plain' and self.path=='/?readonly=1':status,body=500,b"Code: 164. DB::Exception: Cannot modify 'readonly' setting in readonly mode. (READONLY)"
     else:body=b'1\n'
    elif owner.state.get('status'):status,body=owner.state['status'],CANARY.encode()
    elif 'body' in owner.state:body=owner.state['body']
    elif 'system.columns' in sql:body=packet([{'table':'otel_metrics_gauge','name':'Timestamp','type':'DateTime64(9)'},{'table':'otel_metrics_gauge','name':'ServiceName','type':'String'}])
    elif sql.startswith('SHOW GRANTS'):body=packet([{'GRANTS':'GRANT SELECT ON secret_db.* TO readonly_user'}])
    elif sql.startswith('SHOW CREATE'):body=packet([{'statement':'CREATE TABLE otel_logs (ts DateTime) ENGINE = MergeTree ORDER BY ts TTL ts + toIntervalDay(7)'}])
    else:body=packet(owner.state['rows'])
    owner.seen.append({'path':self.path,'sql':sql,'key':key,'user':user,'status':status})
    self.send_response(status)
    if status==302:self.send_header('Location','http://127.0.0.1:1/'+CANARY)
    if owner.state.get('oversize'):self.send_header('Content-Length','1048577')
    else:self.send_header('Content-Length',str(len(body)))
    self.end_headers()
    try:self.wfile.write(body)
    except (BrokenPipeError,ConnectionResetError):pass
  self.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
  self.url='http://127.0.0.1:'+str(self.server.server_port);self.cfg=self.p/'toolkit.yaml';self.store=self.p/'env';self.out=self.p/'audits'
  self.configure();self.store.write_text('KEY_A=wrong-account\nKEY_B='+KEY+'\n')
  (self.p/'home').mkdir();(self.p/'bin').mkdir()
  for binary in ('curl','gcloud','aws','kubectl','gh','wget'):
   f=self.p/'bin'/binary;f.write_text('#!/bin/sh\necho "Unexpected provider binary" >&2\nexit 99\n');f.chmod(0o755)
  self.env={'PATH':str(self.p/'bin')+':'+os.environ['PATH'],'HOME':str(self.p/'home'),'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(self.cfg),'SCOUTFLO_ENV_FILE':str(self.store),'SCOUTFLO_AUDIT_DIR':str(self.out),'SCOUTFLO_TARGET':'region-b','PYTHONDONTWRITEBYTECODE':'1'}
 def tearDown(self):
  self.server.shutdown();self.server.server_close();self.thread.join();self.tmp.cleanup()
 def configure(self,url=None,user='scoutflo_ro',key_env='KEY_B'):
  self.cfg.write_text('clickstack:\n  - label: region-a\n    clickhouse_url: '+self.url+'\n    clickhouse_password_env: KEY_A\n  - label: region-b\n    clickhouse_url: '+(url or self.url)+'\n    clickhouse_user: '+user+'\n    clickhouse_password_env: '+key_env+'\n')
 def runq(self,sql=QUERY,env=None):
  return self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/audit-clickstack/scripts/clickhouse-context.sh"\nchq "$1"',sql,env)
 def shell(self,block,arg='',env=None):
  return subprocess.run(['bash','--noprofile','--norc','-c','set -eu\n'+block,'_',arg],env=self.env if env is None else env,capture_output=True,text=True,timeout=30)
 def ok(self,r):self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertNotIn(KEY,r.stdout+r.stderr);self.assertNotIn(CANARY,r.stdout+r.stderr);return json.loads(r.stdout)
 def blocked(self,r):self.assertNotEqual(r.returncode,0);self.assertEqual(r.stdout,'');self.assertNotIn(KEY,r.stderr);self.assertNotIn(CANARY,r.stderr)
 def cache(self):return next(self.out.rglob('clickhouse-probe.json'))
 def probes(self):return sum(s['status']==500 and s['sql']=='SELECT 1' for s in self.seen)
 def resign(self,value,key=KEY):
  value.pop('hmac',None);value['hmac']=hmac.new(key.encode(),canonical(value),hashlib.sha256).hexdigest();self.cache().write_bytes(canonical(value))
 def test_busy_probe_lock_has_bounded_fail_closed_wait(self):
  self.ok(self.runq());lock=self.cache().with_name(self.cache().name+'.lock');before=len(self.seen)
  with lock.open('a+') as held:
   fcntl.flock(held,fcntl.LOCK_EX);start=time.monotonic();self.blocked(self.runq());elapsed=time.monotonic()-start
  self.assertLess(elapsed,8);self.assertEqual(len(self.seen),before)
 def test_assignment_only_selected_target_and_probe_reuse(self):
  a=self.ok(self.runq());b=self.ok(self.runq());self.assertEqual(a['data'][0]['total_rows'],12)
  self.assertEqual(a['_scoutflo']['target'],'clickstack/region-b');self.assertEqual(a['_scoutflo']['probe']['new_code164_errors'],1)
  self.assertEqual(b['_scoutflo']['probe']['source'],'cache');self.assertEqual(b['_scoutflo']['probe']['new_code164_errors'],0);self.assertEqual(self.probes(),1)
  self.assertTrue(all(x['key']==KEY for x in self.seen));self.assertEqual(self.cache().stat().st_mode&0o777,0o600)
  self.assertNotIn(KEY,self.cache().read_text());self.assertNotIn(CANARY,self.cache().read_text())
 def test_missing_target_key_and_wrong_label_never_fallback(self):
  for env in ({k:v for k,v in self.env.items() if k!='SCOUTFLO_TARGET'},{**self.env,'SCOUTFLO_TARGET':'missing'}):self.blocked(self.runq(env=env))
  self.store.write_text('KEY_A=wrong-account\n');self.blocked(self.runq());self.assertEqual(self.seen,[])
 def test_direct_env_fallback_and_store_precedence(self):
  self.store.write_text('KEY_B='+KEY+'\n');self.ok(self.runq(env={**self.env,'KEY_B':'wrong-inherited-key'}));self.assertTrue(all(x['key']==KEY for x in self.seen))
  self.store.write_text('');self.ok(self.runq(env={**self.env,'KEY_B':KEY}))
 def test_credential_user_target_url_and_name_generation(self):
  self.ok(self.runq());self.assertEqual(self.probes(),1)
  self.store.write_text('KEY_A=wrong-account\nKEY_B=next-password\n');self.ok(self.runq());self.assertEqual(self.probes(),2)
  self.configure(user='different_user');self.ok(self.runq());self.assertEqual(self.probes(),3)
  self.configure(url=self.url+'/',user='different_user');self.ok(self.runq());self.assertEqual(self.probes(),3)
  self.configure(url=self.url.replace('127.0.0.1','localhost'),user='different_user');self.ok(self.runq());self.assertEqual(self.probes(),4)
  self.store.write_text('KEY_A=next-password\nKEY_B=next-password\n');self.configure(url=self.url.replace('127.0.0.1','localhost'),user='different_user',key_env='KEY_A');self.ok(self.runq());self.assertEqual(self.probes(),5)
  self.ok(self.runq(env={**self.env,'SCOUTFLO_TARGET':'region-a'}));self.assertEqual(self.probes(),6)
 def test_expired_future_tampered_receipts_are_not_reused(self):
  self.ok(self.runq())
  for at in (int(time.time())-1801,int(time.time())+60):
   value=json.loads(self.cache().read_text());value['observed_at']=at;self.resign(value);self.ok(self.runq())
  self.assertEqual(self.probes(),3)
  value=json.loads(self.cache().read_text());value['mode']='ro';self.cache().write_text(json.dumps(value));self.ok(self.runq());self.assertEqual(self.probes(),4)
 def test_nonprivate_symlink_and_corrupt_cache_block(self):
  self.ok(self.runq());cache=self.cache();cache.chmod(0o644);before=len(self.seen);self.blocked(self.runq());self.assertEqual(len(self.seen),before)
  cache.chmod(0o600);cache.write_text('{bad');self.blocked(self.runq());self.assertEqual(len(self.seen),before)
  cache.unlink();cache.symlink_to(self.store);self.blocked(self.runq());self.assertEqual(len(self.seen),before)
 def test_concurrent_shells_emit_one_own_readonly_error(self):
  with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(lambda _:self.runq(),range(4)))
  for r in results:self.ok(r)
  self.assertEqual(self.probes(),1)
 def test_ro_mode_and_cached_preflight_is_live(self):
  self.state['probe']='ro';a=self.ok(self.runq());self.assertEqual(a['_scoutflo']['probe']['mode'],'ro');self.assertEqual(self.probes(),0)
  one=self.runq('SELECT 1');self.assertEqual(one.stdout,'1\n');self.assertEqual(self.seen[-1]['sql'],'SELECT 1');self.assertEqual(self.seen[-1]['path'],'/?readonly=1')
  self.state['probe']='denied';self.blocked(self.runq('SELECT 1'))
 def test_imprecise_readonly_html_redirect_and_denial_never_fallback(self):
  for mode in ('imprecise','html','redirect','denied'):
   with self.subTest(mode=mode):self.state['probe']=mode;before=len(self.seen);self.blocked(self.runq());self.assertEqual(len(self.seen),before+1)
 def test_sql_mutations_functions_comments_and_bad_formats_stop_before_http(self):
  for sql in ('INSERT INTO otel_logs VALUES (1)','SELECT 1; DROP TABLE otel_logs','SELECT name FROM system.tables SETTINGS readonly=0',"SELECT url('http://example.test') FROM system.tables",'SELECT * FROM system.tables, s3Cluster(1)','SELECT getServerPort() FROM system.tables','SELECT * FROM other_private_table','SELECT * FROM otel_logs -- comment','SELECT * FROM otel_logs /*x*/','SELECT name FROM system.tables FORMAT CSV','SELECT name FROM system.tables WHERE name=\'unterminated'):
   with self.subTest(sql=sql):self.blocked(self.runq(sql));self.assertEqual(self.seen,[])
 def test_known_old_format_and_backticks(self):
  for sql in ('SELECT name,total_rows FROM system.tables FORMAT TabSeparatedWithNames','SELECT `ServiceName`,countIf(`Timestamp` >= now() - INTERVAL 60 MINUTE) AS rows FROM `otel_metrics_gauge` GROUP BY `ServiceName` FORMAT JSON'):
   self.ok(self.runq(sql));self.assertTrue(self.seen[-1]['sql'].endswith('FORMAT JSON'))
 def test_full_projection_suppresses_ddl_failure_hosts_unknowns(self):
  self.state['rows']=[{'ServiceName':'checkout-api.eu_1','total_rows':'42','engine':'MergeTree','create_table_query':"CREATE TABLE otel_logs (ts DateTime) ENGINE = S3('https://private.invalid/"+CANARY+"', '"+KEY+"') ORDER BY ts TTL ts + toIntervalDay(7)",'latest_fail_reason':CANARY,'host_ip':['192.0.2.0/24'],'auth_type':['sha256_password'],CANARY:KEY,'database':KEY,'type':CANARY}]
  data=self.ok(self.runq())
  row=data['data'][0];self.assertEqual(row['ServiceName'],'checkout-api.eu_1');self.assertEqual(row['ttl'],{'present':True,'days':7,'assessment':'known'});self.assertIs(row['fail_reason_present'],True)
  self.assertEqual(row['host_scope']['restricted'],True);self.assertIsNone(row['database']);self.assertIsNone(row['type']);self.assertNotIn('192.0.2.0',json.dumps(data));self.assertNotIn('CREATE TABLE',json.dumps(data));self.assertIn('unrecognized-column',data['_scoutflo']['unknown_fields'])
 def test_ttl_absence_engine_only_complex_and_column_ttl(self):
  cases=[('create_table_query','CREATE TABLE otel_logs (ts DateTime) ENGINE = MergeTree ORDER BY ts',False,None,'known'),('engine_full','MergeTree ORDER BY ts',None,None,'unknown'),('create_table_query','CREATE TABLE otel_logs (ts DateTime) ENGINE = MergeTree ORDER BY ts TTL ts + INTERVAL 30 DAY DELETE',True,30,'known'),('create_table_query','CREATE TABLE otel_logs (ts DateTime) ENGINE = MergeTree ORDER BY ts TTL ts + toIntervalMonth(1)',True,None,'unknown'),('create_table_query','CREATE TABLE otel_logs (ts DateTime TTL ts + INTERVAL 2 DAY) ENGINE = MergeTree ORDER BY ts',True,None,'unknown'),('create_table_query','CREATE TABLE otel_logs (ts DateTime) ENGINE = MergeTree TTL ts + INTERVAL 2 DAY, ts + INTERVAL 4 DAY TO DISK '+"'archive'",True,None,'unknown'),('create_table_query','nonsense',None,None,'unknown')]
  for field,ddl,present,days,state in cases:
   with self.subTest(field=field,ddl=ddl):self.state['rows']=[{field:ddl}];ttl=self.ok(self.runq())['data'][0]['ttl'];self.assertEqual(ttl,{'present':present,'days':days,'assessment':state})
  self.state['rows']=[{'create_table_query':cases[0][1],'engine_full':'MergeTree'}];self.assertIs(self.ok(self.runq())['data'][0]['ttl']['present'],False)
 def test_grants_projection_does_not_expose_scope(self):
  data=self.ok(self.runq('SHOW GRANTS FOR scoutflo_ro FORMAT JSON'));row=data['data'][0];self.assertEqual(row['privileges'],['SELECT']);self.assertTrue(row['readonly_evidenced']);self.assertNotIn('secret_db',json.dumps(data))
  data=self.ok(self.runq('SHOW CREATE TABLE otel_logs FORMAT JSON'));self.assertEqual(data['data'][0]['ttl']['days'],7)
 def test_fixed_identity_query_and_sensitive_identity_projection(self):
  query='SELECT hostName() AS host, currentUser() AS user, currentDatabase() AS database, version() AS version FORMAT JSON'
  self.state['rows']=[{'host':'clickhouse-a.internal','user':'scoutflo_ro','database':'telemetry','version':'25.8.4.13'}]
  self.assertEqual(self.ok(self.runq(query))['data'][0],self.state['rows'][0])
  self.state['rows']=[{'host':CANARY,'user':KEY,'database':KEY,'version':CANARY}]
  self.assertTrue(all(v is None for v in self.ok(self.runq(query))['data'][0].values()))
 def test_default_probe_exact_provider_semantics(self):
  for response,expected in [('denied','denied'),('generic','unverified'),('html','unverified'),('accessible','accessible')]:
   self.state['anonymous']=response;r=self.shell('. "$CLAUDE_PLUGIN_ROOT/skills/audit-clickstack/scripts/clickhouse-context.sh"\nchq_default_probe');self.assertEqual(self.ok(r)['default_user_access'],expected);self.assertIsNone(self.seen[-1]['key'])
 def test_query_bad_json_truncation_duplicate_error_oversize(self):
  self.ok(self.runq())
  bodies=[b'<html>'+CANARY.encode()+b'</html>',b'{"data":[],"data":[1],"rows":0}',b'{"data":[],"rows":1}',b'{"data":[],"rows":0,"exception":"'+CANARY.encode()+b'"}',b'{"data":[{"rows":NaN}],"rows":1}',b'{"data":[1],"rows":1}',b'{"data":[]}']
  for body in bodies:
   with self.subTest(body=body):self.state['body']=body;self.blocked(self.runq())
  del self.state['body'];self.state['status']=403;self.blocked(self.runq());del self.state['status'];self.state['oversize']=True;self.blocked(self.runq())
 def test_invalid_endpoint_does_not_contact_other_hosts(self):
  for url in (self.url+'/?key='+KEY,self.url+'/private',self.url.replace('http://','http://user:password@'),'file:///etc/passwd'):
   self.configure(url=url);self.blocked(self.runq());self.assertEqual(self.seen,[])
 def test_all_reference_clickhouse_fences_in_fresh_shells(self):
  raw=self.out/'clickstack'/'region-b'/time.strftime('%Y-%m-%d',time.gmtime())/'raw';raw.mkdir(parents=True)
  (raw/'semantic-proof.md').write_text('Synthetic verified service mapping for hermetic recipe execution.\n')
  (raw/'metrics-service-map.json').write_text(json.dumps({'target':'clickstack/region-b','observed_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'mappings':[{'table':'otel_metrics_gauge','timestamp_column':'Timestamp','service_column':'ServiceName','semantic_evidence_ref':'semantic-proof.md','service_semantics_confirmed':True}]}))
  doc=(root/'skills/audit-clickstack/references/clickstack-checks.md').read_text();blocks=[b for b in re.findall(r'```bash\n(.*?)\n```',doc,re.S) if re.search(r'\bchq(?:_|\s)',b)]
  self.assertGreaterEqual(len(blocks),12)
  for index,block in enumerate(blocks):
   with self.subTest(block=index):r=self.shell(block);self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertNotIn(CANARY,r.stdout+r.stderr)
  self.assertEqual(self.probes(),1)
unittest.main()
PY
