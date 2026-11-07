#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json,os,pathlib,re,subprocess,sys,tempfile,time,unittest
root=pathlib.Path(sys.argv.pop());base=root/'skills/map-topology'
class Checks(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.p=pathlib.Path(self.tmp.name);self.bins=self.p/'bin';self.bins.mkdir();self.calls=self.p/'calls';self.calls.write_text('');self.fixture=self.p/'fixture.json'
  for n in ['aws','gcloud','doctl','az','curl','crane','istioctl','gh']:
   f=self.bins/n;f.write_text('#!/bin/sh\nexit 99\n');f.chmod(0o700)
  f=self.bins/'kubectl';f.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(self.calls)+'"\ncase "$*" in *api-resources*) echo applications.argoproj.io;; *"get namespace "*) printf \'%s\\n\' \'{"items":[{"metadata":{"name":"alpha"}},{"metadata":{"name":"bravo"}}]}\';; *) cat "'+str(self.fixture)+'";; esac\n');f.chmod(0o700)
  self.cfg=self.p/'config.yaml';self.cfg.write_text('kubernetes:\n  - label: east\n    context: context-east\n  - label: west\n    context: context-west\n');self.fixture.write_text('{"items":[]}')
  self.env={'PATH':str(self.bins)+':'+os.environ['PATH'],'HOME':str(self.p),'PYTHONDONTWRITEBYTECODE':'1','CLAUDE_PLUGIN_ROOT':str(root),'SCOUTFLO_CONFIG':str(self.cfg),'SCOUTFLO_TARGET':'east','SCOUTFLO_AUDIT_DIR':str(self.p/'audits'),'SCOUTFLO_TOPOLOGY_WORK_DIR':str(self.p/'work')}
  self.pre='set -euo pipefail\n. "$CLAUDE_PLUGIN_ROOT/skills/map-topology/scripts/context.sh"\nmap_context\n'
 def tearDown(self):self.tmp.cleanup()
 def runsh(self,code,extra=None):return subprocess.run(['bash','-c',self.pre+code],env={**self.env,**(extra or {})},capture_output=True,text=True,timeout=30)
 def test_duplicate_label_never_selects_first(self):
  self.cfg.write_text(self.cfg.read_text().replace('label: west','label: east'));r=self.runsh('map_get service -A');self.assertNotEqual(r.returncode,0);self.assertEqual(self.calls.read_text(),'')
 def test_invalid_kinds_and_overrides_block_before_provider(self):
  bad=[['secret','-A'],['configmap','-A'],['service,secret','-A'],['service/other','-A'],['service','--context','wrong'],['service','--context=wrong'],['service','--token','replacement'],['service','--token=replacement'],['service','--server=https://foreign.example.test'],['service','-s','https://foreign.example.test'],['service','--as','someone'],['service','--kubeconfig','/tmp/foreign'],['service','--raw=/api/v1/secrets'],['service','-f','local.yaml'],['service','--watch'],['service','--output','yaml'],['service','--namespace=../bad']]
  for args in bad:
   r=subprocess.run(['python3',str(base/'lib/topology-read.py'),'get',*args],env={**self.env,'KUBE_CONTEXT':'context-east'},capture_output=True,text=True,timeout=5)
   self.assertNotEqual(r.returncode,0,args);self.assertEqual(self.calls.read_text(),'',args)
 def test_supported_exact_namespace_and_combined_kind(self):
  for kind,args in [('service',['-A']),('pod',['-n','shop']),('service',['--namespace=shop']),('namespace',[]),('namespaces,deployments,statefulsets,daemonsets',['-A'])]:
   r=subprocess.run(['python3',str(base/'lib/topology-read.py'),'get',kind,*args],env={**self.env,'KUBE_CONTEXT':'context-east'},capture_output=True,text=True,timeout=5);self.assertEqual(r.returncode,0,(kind,r.stderr))
  self.assertTrue(all(x.startswith('--context context-east get ') for x in self.calls.read_text().splitlines()))
 def test_actual_argocd_multisource_fallback(self):
  self.fixture.write_text(json.dumps({'items':[{'metadata':{'name':'web','namespace':'gitops'},'spec':{'sources':[{'repoURL':'https://github.com/example/web','path':'apps/web','targetRevision':'main'}],'destination':{'namespace':'shop'}},'status':{'sync':{'revisions':['a'*40]},'resources':[{'kind':'Deployment','name':'web','namespace':'shop'}]}}]}))
  # The actual recipe detects Application CRDs using the first table column.
  q=self.bins/'kubectl';q.write_text(q.read_text().replace('echo applications.argoproj.io','echo "applications argoproj.io"'))
  code=next(b for b in re.findall(r'```bash\n(.*?)\n```',(base/'references/istio-queries.md').read_text(),re.S) if 'argocd-evidence.json' in b)
  r=subprocess.run(['bash','-c',code],env=self.env,capture_output=True,text=True,timeout=30);self.assertEqual(r.returncode,0,r.stderr)
  rows=[json.loads(x) for x in r.stdout.splitlines()];self.assertEqual(len(rows),1);self.assertEqual(rows[0]['source_repo_evidence'][0]['candidate_repo'],'example/web');self.assertEqual(rows[0]['deployed_revision'],'a'*40)
  fixture=json.loads(self.fixture.read_text());fixture['items'][0]['spec']['sources'].append({'repoURL':'https://github.com/example/config','path':'config'});self.fixture.write_text(json.dumps(fixture))
  r=subprocess.run(['bash','-c',code],env=self.env,capture_output=True,text=True,timeout=30);self.assertEqual(r.returncode,0,r.stderr)
  row=json.loads(r.stdout);self.assertIn('multiple sources',row['skipped']);self.assertNotIn('source_repo_evidence',row);self.assertNotIn('deployed_revision',row)
 def fence(self,file,needle):
  return next(b for b in re.findall(r'```bash\n(.*?)\n```',(base/'references'/file).read_text(),re.S) if needle in b)
 def test_denied_gcp_flow_logs_stay_unknown(self):
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-gcp.md','vpc-flow-logs-configs list')],env={**self.env,'GCP_PROJECT':'example-project'},capture_output=True,text=True,timeout=10)
  self.assertIn('unknown',r.stdout.lower());self.assertNotIn('not enabled',r.stdout.lower())
 def test_denied_azure_identity_stays_unknown(self):
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-azure.md','PID=')],env={**self.env,'AZ_SUB':'example-subscription','RG':'example-group','APP':'example-app'},capture_output=True,text=True,timeout=10)
  self.assertIn('unknown',r.stdout.lower());self.assertNotIn('no managed identity',r.stdout.lower())
 def test_sentry_origin_comes_from_selected_config(self):
  self.cfg.write_text('sentry:\n  host: https://sentry.example.test\n  org: example-org\n  token_env: SENTRY_FIXTURE_TOKEN\n')
  f=self.bins/'curl';f.write_text('#!/bin/sh\nout=""\nwhile [ "$#" -gt 0 ]; do case "$1" in -o) shift;out="$1";; https://*) printf "%s\\n" "$1" >> "'+str(self.calls)+'";; esac;shift;done\nprintf \'%s\\n\' \'[]\' > "$out"\nprintf "200 application/json"\n');f.chmod(0o700)
  r=subprocess.run(['bash','-c',self.fence('non-k8s-sources.md','SENTRY_ORG')],env={**self.env,'SENTRY_FIXTURE_TOKEN':'synthetic-placeholder','SENTRY_HOST':'https://wrong.example.test','SENTRY_ORG':'example-org'},capture_output=True,text=True,timeout=10)
  self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(self.calls.read_text().splitlines(),['https://sentry.example.test/api/0/organizations/example-org/projects/'])
 def test_optional_catalog_denials_are_visible(self):
  cases=[('gcp','gcloud','exit 99',['cloud sql','pubsub','storage'],{'GCP_PROJECT':'example-project'}),('azure','az','case "$*" in *"postgres flexible-server"*|*"mysql flexible-server"*|*"eventhubs namespace"*) exit 99;; *) printf \'[]\\n\';; esac',['postgres','mysql','eventhubs'],{'AZ_SUB':'example-subscription'}),('aws','aws','case "$*" in *"sqs list-queues"*|*"kafka list-clusters-v2"*|*"opensearch list-domain-names"*) exit 99;; *) printf \'[]\\n\';; esac',['sqs','kafka','opensearch'],{'AWS_PROFILE_CFG':'fixture','AWS_REGION_CFG':'fixture-region'})]
  for provider,binary,body,labels,extra in cases:
   f=self.bins/binary;f.write_text('#!/bin/sh\n'+body+'\n');f.chmod(0o700)
   r=subprocess.run(['bash','-c',self.fence('cloud-mode-'+provider+'.md','CAT=')],env={**self.env,**extra,'TMPDIR':str(self.p)},capture_output=True,text=True,timeout=10)
   self.assertEqual(r.returncode,0,r.stderr)
   for label in labels:self.assertIn(label+' catalog: unknown',r.stderr)
 def test_other_failed_cloud_reads_are_unknown(self):
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-azure.md','FLB=')],env={**self.env,'AZ_SUB':'example-subscription','AZ_REGION':'fixture-region'},capture_output=True,text=True,timeout=10);self.assertIn('availability unknown',r.stdout);self.assertNotIn('none with Traffic Analytics',r.stdout)
  f=self.bins/'aws';f.write_text('#!/bin/sh\ncase "$*" in *get-function-event-invoke-config*) exit 99;; *list-event-source-mappings*) printf \'[]\\n\';; *) printf \'{}\\n\';; esac\n');f.chmod(0o700)
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-aws.md','EIC=')],env={**self.env,'AWS_PROFILE_CFG':'fixture','AWS_REGION_CFG':'fixture-region','FN':'fixture-function','TMPDIR':str(self.p)},capture_output=True,text=True,timeout=10);self.assertEqual(r.returncode,0,r.stderr);self.assertIn('destinations: unknown',r.stdout);self.assertNotIn('no event-invoke',r.stdout)
 def test_successful_empty_read_is_distinct_from_denial(self):
  for binary in ['gcloud','az']:
   f=self.bins/binary;f.write_text('#!/bin/sh\nexit 0\n');f.chmod(0o700)
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-gcp.md','vpc-flow-logs-configs list')],env={**self.env,'GCP_PROJECT':'example-project'},capture_output=True,text=True,timeout=10);self.assertIn('not enabled',r.stdout);self.assertNotIn('unknown',r.stdout)
  r=subprocess.run(['bash','-c',self.fence('cloud-mode-azure.md','PID=')],env={**self.env,'AZ_SUB':'example-subscription','RG':'example-group','APP':'example-app'},capture_output=True,text=True,timeout=10);self.assertIn('no managed identity returned',r.stdout);self.assertNotIn('unknown',r.stdout)
 def test_batch_reads_progress_after_acquiring_lock(self):
  self.assertEqual(self.runsh('map_run init').returncode,0)
  # Pause writer B just before it acquires the actual lock, simulating scheduling
  # after its preliminary read; writer A can finish one batch in the meantime.
  wrapper=self.p/'paused.py';ready=self.p/'ready';resume=self.p/'resume'
  wrapper.write_text('import importlib.util,pathlib,time\ns=importlib.util.spec_from_file_location("work",'+repr(str(base/'lib/worklist.py'))+');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\nold=pathlib.Path.mkdir\ndef paused(p,*a,**kw):\n if p.name=="worklist.lock":\n  pathlib.Path('+repr(str(ready))+').touch()\n  end=time.monotonic()+10\n  while not pathlib.Path('+repr(str(resume))+').exists():\n   if time.monotonic()>end:raise RuntimeError("fixture synchronization failed")\n   time.sleep(.01)\n return old(p,*a,**kw)\npathlib.Path.mkdir=paused\nm.main()\n')
  b=subprocess.Popen(['bash','-c',self.pre+'python3 "$1" batch','_',str(wrapper)],env={**self.env,'SCOUTFLO_TOPOLOGY_BATCH_SIZE':'1'},stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
  try:
   end=time.monotonic()+5
   while not ready.exists() and time.monotonic()<end:time.sleep(.01)
   self.assertTrue(ready.exists());a=self.runsh('map_run batch',{'SCOUTFLO_TOPOLOGY_BATCH_SIZE':'1'});self.assertEqual(a.returncode,0,a.stderr)
   resume.touch();stdout,stderr=b.communicate(timeout=10);self.assertEqual(b.returncode,0,stderr)
   self.assertEqual(self.runsh('map_run complete').returncode,0,stdout)
   self.assertEqual(sum(' get deployment ' in x for x in self.calls.read_text().splitlines()),2)
  finally:
   if b.poll() is None:b.kill();b.communicate()
unittest.main()
PY
