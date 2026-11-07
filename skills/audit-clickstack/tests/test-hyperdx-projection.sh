#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import contextlib,importlib.util,io,json,os,pathlib,subprocess,sys,tempfile,threading,unittest
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
root=pathlib.Path(sys.argv.pop())
spec=importlib.util.spec_from_file_location('hdx',root/'skills/audit-clickstack/scripts/hyperdx-projection.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
canary='PRIVATE_TOKEN_NOT_FOR_REPORT'
def page(rows,total=None,offset=0):
 return {'data':rows,'meta':{'total':len(rows) if total is None else total,'limit':100,'offset':offset}}
def alert(i='a1',channel=True):
 return {'id':i,'state':'OK','source':'tile','dashboardId':'d1','tileId':'t1','channel':{'type':'webhook',**({'webhookId':'w1'} if channel else {})},'message':'https://alert.victorops.com/integrations/'+canary,'query':canary}
def fake(responses):
 c=m.Client('https://api.example.test',key='test');c.mode='key';c.prefix='/api/v2';seen=[]
 def req(path,login=False):
  seen.append(path);value=responses.pop(0)
  if isinstance(value,Exception): raise value
  return value
 c.request=req
 return c,seen
class Checks(unittest.TestCase):
 def test_exact_pagination_and_secret_projection(self):
  c,seen=fake([page([alert()],2),page([alert('a2')],2,1)])
  r=c.collect('alerts');self.assertEqual(r['status'],'complete');self.assertEqual(len(r['items']),2)
  self.assertEqual(seen,['/api/v2/alerts?limit=100&offset=0','/api/v2/alerts?limit=100&offset=1'])
  self.assertNotIn(canary,json.dumps(r));self.assertNotIn('message',json.dumps(r))
 def test_total_drift_duplicate_and_denial(self):
  for last in (page([alert('a2')],3,1),page([alert()],2,1),m.Blocked('http-403'),page([],2,1)):
   c,_=fake([page([alert()],2),last]);r=c.collect('alerts');self.assertEqual(r['status'],'blocked')
 def test_missing_metadata_not_empty(self):
  c,_=fake([{'data':[]}]);self.assertEqual(c.collect('alerts')['status'],'blocked')
 def test_unknown_shape_and_duplicate_key(self):
  c,_=fake([{'wrong':[]}]);self.assertEqual(c.collect('webhooks')['status'],'blocked')
  with self.assertRaises(m.Blocked):json.loads('{"data":[],"data":[1]}',object_pairs_hook=m.unique_object)
 def test_explicit_unset_key_never_uses_login(self):
  old=os.environ.get('HDX_CAPTURE_MODE');os.environ['HDX_CAPTURE_MODE']='key'
  try:
   c=m.Client('https://api.example.test',key='',email='user',password='secret');seen=[]
   c.request=lambda *a,**k:seen.append(a)
   with self.assertRaises(m.Blocked):c.select()
   self.assertEqual(seen,[])
  finally:
   if old is None:os.environ.pop('HDX_CAPTURE_MODE',None)
   else:os.environ['HDX_CAPTURE_MODE']=old
 def test_source_id_join_does_not_certify_database(self):
  resources={k:{'status':'complete','items':[]} for k in ('alerts','sources','connections','webhooks','dashboards')}
  resources['sources']['items']=[{'id':'s1','connection_id':'c1'}];resources['connections']['items']=[{'id':'c1'}]
  _,rows=m.joins(resources);self.assertEqual(rows[0]['data_freshness'],'unverified')
  self.assertEqual(rows[0]['data_binding'],'attended-exact-endpoint-database-table-proof-required')
 def test_destination_is_only_class(self):
  for url,cls in [('https://alert.victorops.com/'+canary,'public'),('https://webhook.site/'+canary,'placeholder'),('http://127.0.0.1/'+canary,'loopback'),('https://hooks.example.com/'+canary,'placeholder'),('https://private.internal/'+canary,'private'),('https://***.com/'+canary,'masked')]:
   r=m.destination(url);self.assertEqual(r['destination_class'],cls);self.assertNotIn(canary,json.dumps(r))
 def test_disabled_unknown_multichannel(self):
  a=alert();a['state']='future-state';a['channels']=[a['channel'],{'type':'webhook'}]
  r=m.project('alerts',a);self.assertIsNone(r['enabled']);self.assertEqual(len(r['channels']),2)
  a['state']='DISABLED';self.assertIs(m.project('alerts',a)['enabled'],False)
 def test_zero_alerts_does_not_hide_sources(self):
  resources={k:{'status':'complete','items':[]} for k in ('alerts','sources','connections','webhooks','dashboards')}
  resources['sources']['items']=[{'id':'s1','connection_id':'c1'}];resources['connections']['items']=[{'id':'c1'}]
  rows,sources=m.joins(resources);self.assertEqual(rows,[]);self.assertEqual(sources[0]['resolution'],'resolved')
 def test_exact_receiver_absence_vs_partial(self):
  resources={k:{'status':'complete','items':[]} for k in ('alerts','sources','connections','webhooks','dashboards')}
  resources['alerts']['items']=[m.project('alerts',alert())]
  rows,_=m.joins(resources);self.assertEqual(rows[0]['definition']['receiver_resolution'],'absent')
  resources['webhooks']['status']='partial';rows,_=m.joins(resources);self.assertEqual(rows[0]['definition']['receiver_resolution'],'blocked')
  resources['webhooks']['items']=[m.project('webhooks',{'id':'w1','url':'https://alert.victorops.com/'+canary})]
  rows,_=m.joins(resources);self.assertEqual(rows[0]['route_verification'],'candidate')
  self.assertNotIn(canary,json.dumps(rows))
 def test_missing_receiver_id(self):
  resources={k:{'status':'complete','items':[]} for k in ('alerts','sources','connections','webhooks','dashboards')}
  resources['alerts']['items']=[m.project('alerts',alert(channel=False))]
  rows,_=m.joins(resources);self.assertEqual(rows[0]['definition']['receiver_resolution'],'missing-id')
 def test_receiver_missing_empty_malformed_and_omitted_are_distinct(self):
  for value,expected in [(None,'empty'),('', 'empty'),(True,'malformed'),({'opaque':'shape'},'malformed'),('token:'+canary,'omitted'),('https://receiver.example.test/'+canary,'omitted')]:
   with self.subTest(expected=expected,value=value):
    a=alert();a['channel']['webhookId']=value;projected=m.project('alerts',a)
    self.assertEqual(projected['channels'][0]['receiver_id_state'],expected)
    resources={k:{'status':'complete','items':[]} for k in ('alerts','sources','connections','webhooks','dashboards')};resources['alerts']['items']=[projected]
    rows,_=m.joins(resources);self.assertEqual(rows[0]['definition']['receiver_resolution'],'missing-id' if expected=='empty' else 'blocked')
    self.assertNotIn(canary,json.dumps(projected)+json.dumps(rows));self.assertNotIn('receiver_id_state',rows[0]['definition'])
  self.assertEqual(m.project('alerts',alert(channel=False))['channels'][0]['receiver_id_state'],'missing')
 def test_credential_shaped_ids_are_never_persistable(self):
  for value in ['X-VO-Api-Key:'+canary,'x-vo-api-id:'+canary,'token:'+canary,'password:'+canary,'ghp_'+canary,'https://receiver.example.test/'+canary]:
   with self.subTest(value=value):
    self.assertIsNone(m.ident(value))
    with self.assertRaises(m.Blocked):m.project('webhooks',{'id':value,'url':'https://example.test'})
  prior=os.environ.get('HDX_CAPTURE_KEY');os.environ['HDX_CAPTURE_KEY']='opaque-key-for-test'
  try:self.assertIsNone(m.ident('prefix-opaque-key-for-test-suffix'))
  finally:
   if prior is None:os.environ.pop('HDX_CAPTURE_KEY',None)
   else:os.environ['HDX_CAPTURE_KEY']=prior
  for value in ('507f1f77bcf86cd799439011','receiver-prod.eu_1','source:region-a','token-bucket-service'):
   self.assertEqual(m.ident(value),value)
 def test_malformed_dashboard_tiles_do_not_disappear(self):
  for row in ({'id':'d1'},{'id':'d1','tiles':None}):
   with self.assertRaises(m.Blocked):m.project('dashboards',row)
  self.assertEqual(m.project('dashboards',{'id':'d1','tiles':[]})['tiles'],[])
  for tile in ('unsupported',None,{'id':'t1','config':'unsupported'},{'id':'t1'}):
   with self.subTest(tile=tile):
    c,_=fake([{'data':[{'id':'d1','tiles':[tile]}]}]);r=c.collect('dashboards')
    self.assertEqual(r['status'],'blocked');self.assertEqual(r['items'],[])
 def test_legacy_modes_are_separate(self):
  c,seen=fake([[],[],[]]);c.mode='session';c.prefix='/api';r=c.collect('webhooks')
  self.assertEqual(seen,['/api/webhooks?service=slack','/api/webhooks?service=generic','/api/webhooks?service=incidentio']);self.assertEqual(r['status'],'partial')
 def test_skipped_connections_stay_partial(self):
  c,_=fake([{'data':[{'id':'c1','host':'https://db.internal/'+canary}], 'meta':{'skipped':1}}]);r=c.collect('connections')
  self.assertEqual(r['reason'],'provider-omitted-objects');self.assertNotIn(canary,json.dumps(r))
 def test_transport_completion_replaces_stale_verified_artifacts(self):
  state={'framing':'length'}
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def respond(self,body):
    framing=state['framing']
    if framing=='bad-status':
     self.wfile.write(b'INVALID '+canary.encode()+b'\r\n\r\n');self.close_connection=True;return
    self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Connection','close')
    if framing in ('chunked','incomplete-chunked'):self.send_header('Transfer-Encoding','chunked')
    elif framing!='eof':self.send_header('Content-Length','invalid' if framing=='invalid-length' else str(m.MAX_BYTES+1 if framing=='oversize' else len(body)+(25 if framing=='short' else 0)))
    self.end_headers()
    try:
     if framing in ('chunked','incomplete-chunked'):
      self.wfile.write(format(len(body),'x').encode()+b'\r\n'+body+b'\r\n')
      if framing=='chunked':self.wfile.write(b'0\r\n\r\n')
     else:self.wfile.write(body)
    except (BrokenPipeError,ConnectionResetError):pass
    self.close_connection=True
   def do_GET(self):self.respond(json.dumps({**page([]),'private_text':canary}).encode())
   def do_POST(self):
    self.rfile.read(int(self.headers.get('Content-Length','0')));self.respond(b'{"ok":true}')
  server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   with tempfile.TemporaryDirectory() as tmp:
    out=pathlib.Path(tmp);url='http://127.0.0.1:'+str(server.server_port)
    env={'PATH':os.environ['PATH'],'PYTHONDONTWRITEBYTECODE':'1','HDX_CAPTURE_URL':url,'HDX_CAPTURE_KEY':canary,'HDX_CAPTURE_MODE':'key'}
    cmd=[sys.executable,str(root/'skills/audit-clickstack/scripts/hyperdx-projection.py'),str(out),'clickstack']
    def invoke():
     r=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=30)
     self.assertNotIn(canary,r.stdout+r.stderr)
     files={f.name:f.read_bytes() for f in out.glob('*.json')};self.assertEqual(len(files),3)
     for raw in files.values():self.assertNotIn(canary.encode(),raw)
     return r,files
    for framing in ('length','chunked','eof'):
     with self.subTest(framing=framing):
      state['framing']=framing;r,files=invoke();self.assertEqual(r.returncode,0,r.stderr)
      self.assertEqual(json.loads(files['alert-source-capture.json'])['verification']['status'],'verified')
      self.assertEqual(json.loads(files['hyperdx-configuration.json'])['resources']['alerts']['status'],'complete')
      self.assertIsNone(m.Client(url,email='user',password=canary).request('/api/login/password',login=True))
    for framing in ('short','incomplete-chunked','bad-status','invalid-length','oversize'):
     with self.subTest(framing=framing):
      state['framing']='length';r,before=invoke();self.assertEqual(r.returncode,0,r.stderr)
      state['framing']=framing;r,after=invoke();self.assertNotEqual(r.returncode,0)
      self.assertTrue(all(before[name]!=raw for name,raw in after.items()))
      self.assertEqual(json.loads(after['alert-source-capture.json'])['verification']['status'],'blocked')
      self.assertEqual(json.loads(after['alert-source-evidence.json'])['verification']['status'],'blocked')
      self.assertEqual(json.loads(after['alert-source-evidence.json'])['records'],[])
      resources=json.loads(after['hyperdx-configuration.json'])['resources'];self.assertTrue(all(v['status']=='blocked' and v['scope']=='subset' for v in resources.values()))
      with self.assertRaises(m.Blocked):m.Client(url,email='user',password=canary).request('/api/login/password',login=True)
  finally:server.shutdown();server.server_close();thread.join()
 def test_shell_multi_target_zero_requests_and_live_loopback(self):
  seen=[]
  class Handler(BaseHTTPRequestHandler):
   def log_message(self,*args):pass
   def do_GET(self):
    seen.append((self.path,self.headers.get('Authorization')))
    path=self.path.split('?')[0]
    data={'alerts':page([alert()]),'webhooks':page([{'id':'w1','url':'https://alert.victorops.com/'+canary,'body':canary}]),'sources':{'data':[{'id':'s1','connection':'c1','password':canary}]},'connections':{'data':[{'id':'c1','host':'https://db.internal/'+canary,'password':canary}]},'dashboards':{'data':[{'id':'d1','tiles':[{'id':'t1','config':{'sourceId':'s1','query':canary}}]}]}}.get(path.rsplit('/',1)[-1])
    body=json.dumps(data).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(body)
  server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
  try:
   with tempfile.TemporaryDirectory() as tmp:
    p=pathlib.Path(tmp);cfg=p/'config.yaml';store=p/'env';out=p/'audits'
    cfg.write_text('clickstack:\n  - label: region-a\n    hyperdx_url: http://127.0.0.1:'+str(server.server_port)+'\n    hyperdx_api_key_env: KEY_A\n  - label: region-b\n    hyperdx_url: http://127.0.0.1:'+str(server.server_port)+'\n    hyperdx_api_key_env: KEY_B\n')
    store.write_text('KEY_A=wrong-target\nKEY_B='+canary+'\n')
    env={**os.environ,'CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_ENV_FILE':str(store),'SCOUTFLO_AUDIT_DIR':str(out)};env.pop('SCOUTFLO_TARGET',None)
    cmd=['sh',str(root/'skills/audit-clickstack/scripts/collect-hyperdx.sh')]
    r=subprocess.run(cmd,env=env,capture_output=True,text=True);self.assertNotEqual(r.returncode,0);self.assertEqual(seen,[])
    env['SCOUTFLO_TARGET']='region-b';r=subprocess.run(cmd,env=env,capture_output=True,text=True);self.assertEqual(r.returncode,0,r.stdout+r.stderr)
    self.assertTrue(seen);self.assertTrue(all(auth=='Bearer '+canary for _,auth in seen));self.assertNotIn(canary,r.stdout+r.stderr)
    files=list(out.rglob('*.json'));self.assertEqual(len(files),3)
    for f in files:self.assertNotIn(canary,f.read_text());self.assertIn('region-b',str(f))
    packet=json.loads(next(out.rglob('alert-source-evidence.json')).read_text());self.assertEqual(packet['records'][0]['definition']['source_id'],'s1')
    self.assertEqual(packet['records'][0]['route_verification'],'candidate')
  finally:server.shutdown();server.server_close();thread.join()
unittest.main()
PY
