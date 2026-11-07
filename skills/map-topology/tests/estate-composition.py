"""Synthetic configuration versus traffic and cross-cluster identity regressions."""
import copy
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT=Path(os.environ['CLAUDE_PLUGIN_ROOT'])
SCRIPT=ROOT/'skills/map-topology/lib/compose-estate.py'
DAY,STAMP='2026-01-15','2026-01-15T10:00:00Z'

def ep(target,name,kind='service'):return dict(target=target,entity_type=kind,name=name)

def source(cluster):
    return dict(version='scoutflo-topology-export/v1',generated_at=STAMP,cluster=dict(cluster_id=cluster),services=[dict(name='checkout',attributes=dict(cluster_id=cluster,namespace='shop',service_name='checkout')),dict(name='database',attributes=dict(cluster_id=cluster,namespace='shop',service_name='database'))],resources=[],relationships=[])

count=0
with tempfile.TemporaryDirectory() as directory:
    folder=Path(directory)
    base_sources=[]
    for label in ['east','west']:
        doc=source('cluster-'+label);doc['relationships']=[{'from':dict(entity_type='service',name='checkout'),'to':dict(entity_type='service',name='database'),'relation':'CALLS','assertion_type':'observed'}]
        path=folder/(label+'.json');path.write_text(json.dumps(doc))
        base_sources.append(dict(target='kubernetes/'+label,path=path.name,collection=dict(status='complete',scope='target',observed_at=STAMP)))
    before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in folder.glob('*.json')}
    def run(label,change=None,valid=True,proof_kind=None):
        global count
        manifest=dict(schema='scoutflo-estate-topology-manifest/v1',audit_date=DAY,sources=copy.deepcopy(base_sources),links=[],unresolved_links=[])
        if proof_kind:
            a,b=ep('kubernetes/east','checkout'),ep('kubernetes/west','database')
            proof=dict(schema='scoutflo-topology-observation/v1',audit_date=DAY,target='kubernetes/east',observed_at=STAMP,kind=proof_kind,ref='retained-observation/flow-1',**{'from':a,'to':b,'relation':'CALLS'})
            if proof_kind=='observed-traffic':proof['observation_type']='flow-log'
            (folder/'proof.json').write_text(json.dumps(proof))
            manifest['links']=[dict(evidence_file='proof.json',**{'from':a,'to':b,'relation':'CALLS'})]
        if change:change(manifest)
        mf=folder/'manifest.json';mf.write_text(json.dumps(manifest));out=folder/label/'estate-topology.json'
        completed=subprocess.run(['python3',str(SCRIPT),str(mf),str(out)],capture_output=True,text=True)
        assert (completed.returncode==0)==valid,(label,completed.stdout,completed.stderr)
        count+=1;print('PASS',label)
        if valid:return json.loads(out.read_text())
    output=run('same-name-distinct-clusters')
    assert len(output['entities'])==4 and len({x['id'] for x in output['entities']})==4
    assert output['import_ready'] is False and all(x['evidence']['kind']=='configuration' for x in output['relationships'])
    output=run('explicit-config-cross-map',proof_kind='configuration');assert output['relationships'][-1]['evidence']['kind']=='configuration'
    output=run('explicit-observed-traffic',proof_kind='observed-traffic');assert sum(x['evidence']['kind']=='observed-traffic' for x in output['relationships'])==1
    output=run('partial-source',lambda m:m['sources'][1]['collection'].update(status='partial',scope='subset'));assert output['completeness']=='partial-or-unknown'
    output=run('unknown-source',lambda m:m['sources'][1].pop('collection'));assert output['completeness']=='partial-or-unknown'
    output=run('unresolved-storage',lambda m:m['unresolved_links'].append({'from':ep('kubernetes/east','checkout'),'reason':'Storage account unknown'}));assert len(output['unresolved_links'])==1 and output['completeness']=='partial-or-unknown'
    run('duplicate-source-target',lambda m:m['sources'][1].update(target='kubernetes/east'),valid=False)
    run('relabel-same-map',lambda m:m['sources'][1].update(path='east.json'),valid=False)
    run('generation-mismatch',lambda m:m['sources'][0]['collection'].update(observed_at='2026-01-15T09:00:00Z'),valid=False)
    run('stale-map',lambda m:m.update(audit_date='2026-01-16'),valid=False)
    run('unknown-endpoint',lambda m:m['links'][0]['to'].update(name='not-in-map'),valid=False,proof_kind='configuration')
    def bad_proof(m):
        p=folder/'proof.json';doc=json.loads(p.read_text());doc['target']='kubernetes/other';p.write_text(json.dumps(doc))
    run('wrong-proof-target',bad_proof,valid=False,proof_kind='configuration')
    def fake_traffic(m):
        p=folder/'proof.json';doc=json.loads(p.read_text());doc.pop('observation_type');p.write_text(json.dumps(doc))
    run('traffic-needs-receipt-kind',fake_traffic,valid=False,proof_kind='observed-traffic')
    def stale_proof(m):
        p=folder/'proof.json';doc=json.loads(p.read_text());doc['observed_at']='2026-01-14T10:00:00Z';p.write_text(json.dumps(doc))
    run('stale-link-proof',stale_proof,valid=False,proof_kind='configuration')
    def future_proof(m):
        p=folder/'proof.json';doc=json.loads(p.read_text());doc['observed_at']='2099-01-15T10:00:00Z';p.write_text(json.dumps(doc))
    run('future-link-proof',future_proof,valid=False,proof_kind='configuration')
    assert all(hashlib.sha256(p.read_bytes()).hexdigest()==digest for p,digest in before.items()),'source mutation'
print(f'estate-composition: {count} scenarios passed; per-target source hashes unchanged')
