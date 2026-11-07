"""Synthetic regression checks for scoped topology and safe recipe execution."""
import copy,importlib.util,json,os,pathlib,re,subprocess,tempfile
ROOT=pathlib.Path(os.environ['CLAUDE_PLUGIN_ROOT']);BASE=ROOT/'skills/map-topology';COUNT=0

def load(name,file):
 s=importlib.util.spec_from_file_location(name,BASE/'lib'/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
composer=load('composer','compose-estate.py');ident=load('identity','identity-check.py');reader=load('reader','topology-read.py')
def ok(label,cond):
 global COUNT
 assert cond,label;COUNT+=1;print('PASS',label)
def rejects(label,fn):
 try:fn()
 except (ValueError,TypeError,KeyError):ok(label,True);return
 raise AssertionError(label)
def fences(path):return re.findall(r'```(?:bash|sh)\n(.*?)```',path.read_text(),re.S)
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d);stamp='2026-01-15T10:00:00Z';collection=dict(status='complete',scope='target',observed_at=stamp)
 doc=dict(version='scoutflo-topology-export/v1',generated_at=stamp,cluster={'cluster_id':'cluster-a'},services=[{'name':'web','attributes':{'cluster_id':'cluster-a'}}],resources=[{'name':'db','attributes':{}}],relationships=[{'from':{'name':'web','entity_type':'service'},'to':{'name':'db','entity_type':'resource'},'relation':'USES','assertion_type':'inferred'}])
 manifest=dict(schema='scoutflo-estate-topology-manifest/v1',audit_date='2026-01-15',sources=[dict(target='kubernetes/east',path='source.json',collection=collection)])
 source=p/'source.json';mf=p/'manifest.json';source.write_text(json.dumps(doc));mf.write_text(json.dumps(manifest))
 ok('inferred-not-promoted',composer.compose(mf)['relationships'][0]['evidence']['kind']=='inferred')
 mutation=copy.deepcopy(doc);mutation['collection']=dict(collection,status='blocked');source.write_text(json.dumps(mutation));rejects('blocked-source-cannot-be-promoted',lambda:composer.compose(mf))
 mutation['collection']=collection;mutation['target']='kubernetes/west';source.write_text(json.dumps(mutation));rejects('source-target-contradiction',lambda:composer.compose(mf))
 source.write_text(json.dumps(doc));mf.write_text(json.dumps(manifest).replace('"status": "complete"','"status":"blocked","status":"complete"'));rejects('duplicate-json-status',lambda:composer.compose(mf))
 mf.write_text(json.dumps(manifest));source.write_text(json.dumps(doc).replace('"attributes": {}','"attributes": {"score":NaN}'));rejects('nonfinite-source',lambda:composer.compose(mf))
 source.write_text(json.dumps(doc));(p/'copy.json').write_text(json.dumps(doc,indent=2));mutation=copy.deepcopy(manifest);mutation['sources'].append(dict(manifest['sources'][0],target='kubernetes/west',path='copy.json'));mf.write_text(json.dumps(mutation));rejects('identical-content-different-format',lambda:composer.compose(mf))
 svc=dict(name='web',service_type='backend',environment='prod',business_criticality='high',attributes=dict(service_name='web',namespace='shop',cluster_id='cluster-a'))
 resource=dict(name='web-workload',resource_type='kubernetes_deployment',attributes=dict(workload_name='web',workload_type='deployment',namespace='shop',cluster_id='cluster-a'))
 edge={'from':{'name':'web','entity_type':'service'},'to':{'name':'web-workload','entity_type':'resource'},'relation':'DEPLOYED_AS'}
 topology=dict(cluster={'cluster_id':'cluster-a'},services=[svc],resources=[resource],relationships=[edge]);ok('valid-identity-join',ident.check(topology)[0]['t2'])
 for wl_kind,resource_kind in [('statefulset','kubernetes_stateful_set'),('daemonset','kubernetes_daemon_set'),('cronjob','kubernetes_cron_job')]:
  m=copy.deepcopy(topology);m['resources'][0]['attributes']['workload_type']=wl_kind;m['resources'][0]['resource_type']=resource_kind;ok('valid-'+wl_kind,ident.check(m)[0]['t2'])
 for label,change in [('foreign-cluster',lambda x:x['resources'][0]['attributes'].update(cluster_id='cluster-b')),('foreign-namespace',lambda x:x['resources'][0]['attributes'].update(namespace='other')),('bad-endpoint-type',lambda x:x['relationships'][0]['to'].update(entity_type='service')),('second-bad-edge',lambda x:x['relationships'].append(dict(edge,to={'name':'absent','entity_type':'resource'}))),('duplicate-resource-name',lambda x:x['resources'].append(copy.deepcopy(resource))),('empty-cluster',lambda x:x['services'][0]['attributes'].update(cluster_id=''))]:
  m=copy.deepcopy(topology);change(m);ok(label,not ident.check(m)[0]['t2'])
 raw={'items':[{'metadata':{'name':'web','namespace':'shop','annotations':{'private':'SYNTHETIC_SECRET'},'labels':{'app':'web'}},'spec':{'selector':{'app':'web'},'template':{'metadata':{'labels':{'app':'web'}},'spec':{'containers':[{'name':'web','image':'example/web:1','env':[{'name':'TOKEN','value':'SYNTHETIC_SECRET'}],'args':['SYNTHETIC_SECRET']}]}}}}]}
 safe=reader.project('deployment',raw);ok('env-args-annotations-never-persist','SYNTHETIC_SECRET' not in json.dumps(safe));ok('workload-image-survives',safe['items'][0]['spec']['template']['spec']['containers'][0]['image']=='example/web:1')
 m=copy.deepcopy(raw);m['items'][0]['spec']['selector']['secret-token']='SYNTHETIC_SECRET';ok('omitted-selector-cannot-broaden',reader.project('service',m)['items'][0]['spec']['selector_projection_complete'] is False)
 bins=p/'bin';bins.mkdir();fixture=p/'fixture.json';fixture.write_text(json.dumps(raw));tools=['aws','gcloud','doctl','az','curl','crane','istioctl','gh']
 for name in tools:
  q=bins/name;q.write_text('#!/bin/sh\necho BLOCKED-UNEXPECTED-PROVIDER >&2\nexit 97\n');q.chmod(0o700)
 q=bins/'kubectl';q.write_text('#!/bin/sh\nif [ "${SYNTHETIC_FAIL_SERVICE:-}" = yes ] && [ "${4:-}" = service ]; then exit 97; fi\ncase "$*" in *"get namespace "*) printf \'%s\\n\' \'{"items":[{"metadata":{"name":"shop"}}]}\';; *) cat "'+str(fixture)+'";; esac\n');q.chmod(0o700)
 cfg=p/'toolkit.yaml';cfg.write_text('kubernetes:\n  - label: east\n    context: cluster-east\n  - label: west\n    context: cluster-west\n')
 env={'PATH':str(bins)+':'+os.environ['PATH'],'HOME':str(p),'CLAUDE_PLUGIN_ROOT':str(ROOT),'SCOUTFLO_CONFIG':str(cfg),'SCOUTFLO_TARGET':'east','SCOUTFLO_AUDIT_DIR':str(p/'audits'),'SCOUTFLO_TOPOLOGY_WORK_DIR':str(p/'work')}
 def shell(code,extra=None):return subprocess.run(['bash','-c',code],env=dict(env,**(extra or {})),capture_output=True,text=True)
 pre='. "$CLAUDE_PLUGIN_ROOT/skills/map-topology/scripts/context.sh"\nmap_context\n'
 r=shell(pre+'printf "%s" "$KUBE_CONTEXT"');ok('fresh-selected-context',r.returncode==0 and r.stdout=='cluster-east')
 r=shell(pre,{'SCOUTFLO_TARGET':'unknown'});ok('unknown-target-blocked',r.returncode!=0)
 r=shell(pre,{'SCOUTFLO_TARGET':''});ok('list-needs-explicit-selection',r.returncode!=0)
 join=next(b for b in fences(BASE/'references/istio-queries.md') if 'svc-workloads.tsv' in b)
 r=shell(join);ok('actual-fresh-join-block',r.returncode==0 and 'shop\tweb\tdeployment/web' in r.stdout)
 ok('actual-saved-workload-hides-secret','SYNTHETIC_SECRET' not in (p/'work/workloads.json').read_text())
 r=shell(pre+'map_run init');ok('worklist-init',r.returncode==0)
 r=shell(pre+'map_run complete');ok('pending-worklist-blocked',r.returncode!=0)
 r=shell(pre+'map_run batch',{'SYNTHETIC_FAIL_SERVICE':'yes'});ok('failed-pull-does-not-finish-namespace',r.returncode!=0 and 'pending=1' in shell(pre+'map_run status').stdout)
 r=shell(pre+'map_run batch');ok('batch-captures-projected',r.returncode==0)
 r=shell(pre+'map_run complete');ok('completed-receipts-pass',r.returncode==0)
 r=shell(pre+'map_run status',{'SCOUTFLO_TARGET':'west'});ok('worklist-context-change-blocked',r.returncode!=0)
 run=pathlib.Path(shell(pre+'map_run path').stdout.strip());(run/'raw/shop.deployment.json').write_text('{}');ok('tampered-capture-blocked',shell(pre+'map_run complete').returncode!=0)
 (run/'worklist.lock').mkdir();os.utime(run/'worklist.lock',(1,1));ok('old-lock-never-auto-reclaimed',shell(pre+'map_run batch').returncode!=0)
 # All published shell fences parse in a fresh Bash process. Provider-specific
 # prerequisites remain explicit; no cloud commands are invoked by this parse check.
 total=0
 for path in [BASE/'SKILL.md',*sorted((BASE/'references').glob('*.md'))]:
  for code in fences(path):
   r=subprocess.run(['bash','-n'],input=code,capture_output=True,text=True);ok(path.name+'-syntax-'+str(total),r.returncode==0);total+=1
 catalog=dict(schema='scoutflo-topology-ip-catalog/v1',audit_date='2026-01-15',sources=[dict(target='gcp/east',observed_at=stamp,status='complete',records=[{'ip':'192.0.2.8','owner':'web-a'}]),dict(target='aws/west',observed_at=stamp,status='complete',records=[{'ip':'192.0.2.8','owner':'web-b'}])]);cat=p/'catalog.json';cat.write_text(json.dumps(catalog));openings=p/'openings.tsv';openings.write_text('192.0.2.8/32\tdatabase\n192.0.2.0/24\twide-db\n')
 r=subprocess.run(['python3',str(BASE/'lib/ip-attribution.py'),str(cat),str(openings)],capture_output=True,text=True);ok('shared-nat-ambiguous-no-edge',r.returncode==0 and 'AMBIGUOUS' in r.stdout and 'CANDIDATE' not in r.stdout and 'wide CIDR' in r.stdout)
 catalog['sources'][1]['records']=[];cat.write_text(json.dumps(catalog));r=subprocess.run(['python3',str(BASE/'lib/ip-attribution.py'),str(cat),str(openings)],capture_output=True,text=True);ok('unique-host-review-candidate',r.returncode==0 and 'CANDIDATE' in r.stdout)
 catalog['sources'][1]['status']='partial';cat.write_text(json.dumps(catalog));r=subprocess.run(['python3',str(BASE/'lib/ip-attribution.py'),str(cat),str(openings)],capture_output=True,text=True);ok('partial-catalog-cannot-prove-unique-owner','UNKNOWN' in r.stdout and 'CANDIDATE' not in r.stdout)
print('map-evidence-hardening:',COUNT,'checks passed')
