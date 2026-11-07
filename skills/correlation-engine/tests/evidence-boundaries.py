import copy
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(os.environ['CLAUDE_PLUGIN_ROOT'])
DAY, STAMP = '2026-01-15', '2026-01-15T00:00:00Z'
identity = dict(kind='kubernetes', cluster_id='cluster-east', namespace='shop', service_name='checkout')
collection = dict(status='complete', scope='target', observed_at=STAMP)

def evidence(target):
    return dict(target=target, observed_at=STAMP, ref='fixture/current-source-selector')

def finding(target, item_id='SRC-001'):
    return dict(schema='scoutflo-findings/v2',target=target,run_date=DAY,generated_at=STAMP,collection=copy.deepcopy(collection), score=63, findings=[dict(id=item_id, severity='high', area='alerting', title='Missing latency alert', affected=['checkout'], correlation_bindings=[dict(affected='checkout', service_identity=copy.deepcopy(identity), evidence=evidence(target))])])

def inventory(target):
    return dict(schema='scoutflo-inventory/v1',target=target,generated_at=STAMP,collection=copy.deepcopy(collection), items=[dict(name='Latency', kind='monitor', covers='checkout', enabled=True, routes_to='primary-policy', service_identity=copy.deepcopy(identity), identity_evidence=evidence(target))])

cases = 0
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    def run(label, mutate=None, expected='unmappable', overlap=False, manifest=False, cascade=None):
        global cases
        target = root / label; target.mkdir()
        docs = {'azure/east/findings':finding('azure/east'), 'datadog/west/findings':finding('datadog/west','DD-001'), 'azure/east/inventory':dict(schema='scoutflo-inventory/v1',target='azure/east',generated_at=STAMP,collection=copy.deepcopy(collection),items=[]), 'datadog/west/inventory':inventory('datadog/west')}
        if mutate: mutate(docs)
        for key, doc in docs.items():
            if doc is None: continue
            source, artifact = key.rsplit('/',1)
            path = target/source/DAY/(artifact+'.json'); path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(doc))
        if manifest:
            (target/'coverage-assessment.json').write_text(json.dumps(dict(schema='scoutflo-coverage-assessment/v1',audit_date=DAY,expected_targets=['azure/east','datadog/west'])))
        before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in target.rglob('*.json')}
        env=dict(os.environ,SCOUTFLO_AUDIT_DIR=str(target),BC_JSON=str(target/'absent'),TOPOLOGY_FILE=str(target/'absent'))
        subprocess.run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/correlation-engine/lib/correlation-engine.sh"; correlation_run "$1"', 'sh', DAY],env=env,check=True,capture_output=True)
        result=json.loads((target/'correlation.json').read_text())
        row=next(x for x in result['coverage'] if x['target']=='azure/east')
        assert row['classification']==expected,(label,row)
        assert bool(result['overlaps'])==overlap,(label,result['overlaps'])
        if cascade is not None:assert bool(result['cascades'])==cascade,(label,result['cascades'])
        subprocess.run(['sh','-c','. "$CLAUDE_PLUGIN_ROOT/skills/alert-fatigue/lib/alert-fatigue.sh"; alert_fatigue_run "$1"','sh',DAY],env=env,check=True,capture_output=True)
        af=json.loads((target/'alert-fatigue.json').read_text())
        assert bool(af['totals']['cross_source_storms'])==overlap,(label,af)
        assert all(hashlib.sha256(p.read_bytes()).hexdigest()==digest for p,digest in before.items()),'source mutation'
        cases+=1
        print('PASS',label)
        return result
    def monitor(d): return d['datadog/west/inventory']['items'][0]
    def binding(d): return d['datadog/west/findings']['findings'][0]['correlation_bindings'][0]
    run('positive-same-identity',expected='covered-elsewhere',overlap=True)
    for value in [None,'true',1]:
        run('unknown-activation-'+str(value),lambda d,v=value:monitor(d).update(enabled=v),overlap=True,manifest=True)
    for route in ['unknown',' unverified ','[redacted]',{},False]:
        run('unknown-route-'+str(cases),lambda d,v=route:monitor(d).update(routes_to=v),overlap=True,manifest=True)
    run('missing-activation',lambda d:monitor(d).pop('enabled'),overlap=True,manifest=True)
    def different_cluster(d):
        monitor(d)['service_identity']['cluster_id']='cluster-west'
        binding(d)['service_identity']['cluster_id']='cluster-west'
    run('same-name-different-cluster',different_cluster)
    run('scoped-absence-different-cluster',different_cluster,expected='true-gap',manifest=True)
    def environment_conflict(d):
        d['azure/east/findings']['findings'][0]['correlation_bindings'][0]['service_identity']['environment']='production'
        monitor(d)['service_identity']['environment']='staging';binding(d)['service_identity']['environment']='staging'
    run('explicit-environment-conflict',environment_conflict)
    run('complete-inputs-do-not-resolve-scope-conflict',environment_conflict,manifest=True)
    def legacy(d):
        for key in ['azure/east/findings','datadog/west/findings']:d[key]['findings'][0].pop('correlation_bindings')
        monitor(d).pop('service_identity')
    run('legacy-name-only',legacy,manifest=True)
    run('missing-inventory',lambda d:d.update({'datadog/west/inventory':None}),overlap=True,manifest=True)
    run('disabled-without-manifest',lambda d:monitor(d).update(enabled=False),overlap=True)
    run('disabled-complete-assessed-targets',lambda d:monitor(d).update(enabled=False),expected='true-gap',overlap=True,manifest=True)
    for state in ['partial','blocked']:
        def partial(d,state=state):
            monitor(d)['enabled']=False; d['datadog/west/inventory']['collection'].update(status=state,reason='Fixture partial or denied collection')
        run('inventory-'+state,partial,overlap=True,manifest=True)
    def subset(d):
        monitor(d)['enabled']=False;d['datadog/west/inventory']['collection']['scope']='subset'
    run('subset-inventory',subset,overlap=True,manifest=True)
    for field,value in [('observed_at','2026-01-14T00:00:00Z'),('observed_at','2099-01-15T00:00:00Z'),('target','datadog/other'),('ref','')]:
        def invalid(d,field=field,value=value):
            monitor(d)['identity_evidence'][field]=value;binding(d)['evidence'][field]=value
        run('invalid-evidence-'+field+'-'+str(cases),invalid,manifest=True)
    def ambiguous(d):
        f=d['azure/east/findings']['findings'][0]; b=copy.deepcopy(f['correlation_bindings'][0]);b['service_identity']['cluster_id']='cluster-other';f['correlation_bindings'].append(b)
    run('ambiguous-finding-identity',ambiguous,manifest=True)
    def provider_identity(d):
        ident=dict(kind='provider-resource',provider='database',account_scope='account-test',resource_id='db-primary',region='east')
        for k in ['azure/east/findings','datadog/west/findings']:d[k]['findings'][0]['correlation_bindings'][0]['service_identity']=copy.deepcopy(ident)
        monitor(d)['service_identity']=copy.deepcopy(ident)
    run('provider-resource-scope',provider_identity,expected='covered-elsewhere',overlap=True)
    def missing_account(d):
        provider_identity(d);monitor(d)['service_identity'].pop('account_scope');binding(d)['service_identity'].pop('account_scope')
    run('provider-resource-no-account',missing_account,manifest=True)
    def datastore(d):
        f=d['datadog/west/findings']['findings'][0];f.update(area='database reliability',title='Database noisy alert routing fails')
    run('scoped-datastore-cascade',datastore,expected='covered-elsewhere',overlap=True,cascade=True)
    def repeated_ids(d):
        for key in ['azure/east/findings','datadog/west/findings']:
            d[key]['findings'][0].update(id='SAME-001',area='database alerting',title='Missing database latency alert')
    duplicate=run('same-check-two-target-cascades',repeated_ids,expected='covered-elsewhere',overlap=True,cascade=True)
    assert len(duplicate['cascades'])==2 and len({r['cascade_id'] for r in duplicate['cascades']})==2
    def other_datastore(d):
        datastore(d);different_cluster(d)
    run('different-cluster-no-cascade',other_datastore,cascade=False)
    def unknown_unrelated(d):
        monitor(d).pop('service_identity');monitor(d)['covers']='friendly-alias'
    run('unbound-alias-blocks-absence',unknown_unrelated,overlap=True,manifest=True)
    def missing_namespace(d):
        monitor(d)['service_identity'].pop('namespace');binding(d)['service_identity'].pop('namespace')
    run('missing-namespace',missing_namespace,manifest=True)
    run('inventory-envelope-target-mismatch',lambda d:d['datadog/west/inventory'].update(target='datadog/other'),overlap=True,manifest=True)
    run('finding-envelope-target-mismatch',lambda d:d['azure/east/findings'].update(target='azure/other'),manifest=True)
    run('wrong-finding-run-date',lambda d:d['azure/east/findings'].update(run_date='2026-01-14'),manifest=True)
    run('wrong-inventory-generation-date',lambda d:d['datadog/west/inventory'].update(generated_at='2026-01-14T00:00:00Z'),overlap=True,manifest=True)
    run('generated-before-observation',lambda d:d['datadog/west/inventory'].update(generated_at='2026-01-14T23:59:59Z'),overlap=True,manifest=True)
    run('unsafe-evidence-ref',lambda d:monitor(d)['identity_evidence'].update(ref='../other-target/file.json'),overlap=True,manifest=True)
print(f'evidence-boundaries: {cases} scenarios passed; correlation and AF; source hashes unchanged')
