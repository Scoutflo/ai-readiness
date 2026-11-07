#!/usr/bin/env python3
"""Compose explicit local topology exports without changing the import contract.

No discovery, network, secret reads, or implicit entity/endpoint merges. Existing
`observed` export edges describe configuration unless separate traffic proof exists.
"""
import argparse
import datetime as dt
import hashlib
import html
import json
import os
import re
import tempfile
from pathlib import Path

MAX_BYTES = 8 * 1024 * 1024

def fail(message):
    raise ValueError(message)

def text(value):
    return isinstance(value, str) and bool(value.strip()) and not re.search(r'[\x00-\x1f]', value)

def stamp(value, day):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value):
        fail('Observation timestamp must be strict UTC')
    parsed = dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)
    if value[:10] != day or parsed > dt.datetime.now(dt.timezone.utc):
        fail('Observation is stale for audit_date or is in the future')
    return value

def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result: fail("Duplicate JSON key")
        result[key] = value
    return result

def read(path):
    if not path.is_file() or path.stat().st_size > MAX_BYTES:
        fail('Missing or oversized local artifact')
    raw = path.read_bytes()
    doc = json.loads(raw, object_pairs_hook=strict_object, parse_constant=lambda _: fail("Non-finite JSON number"))
    if not isinstance(doc, dict): fail("Artifact must be a JSON object")
    json.dumps(doc, allow_nan=False)  # Includes overflow such as 1e999, not only NaN literals.
    return doc, hashlib.sha256(raw).hexdigest()

def endpoint(value):
    if not isinstance(value, dict) or value.get('entity_type') not in {'service', 'resource'} or not all(text(value.get(k)) for k in ['target','name']):
        fail('Endpoint requires target, entity_type and name')
    return value['target'], value['entity_type'], value['name']

def identifier(key):
    return 'estate-' + hashlib.sha256(json.dumps(key).encode()).hexdigest()[:24]

def compose(manifest_path):
    manifest, _ = read(manifest_path)
    if manifest.get('schema') != 'scoutflo-estate-topology-manifest/v1':
        fail('Unsupported composition manifest')
    day = manifest.get('audit_date')
    if not isinstance(day,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}',day): fail('audit_date is required')
    sources = manifest.get('sources')
    if not isinstance(sources,list) or not 1 <= len(sources) <= 50: fail('Select 1 to 50 source maps')
    entities, relationships, source_maps, unresolved = [], [], [], []
    by_key, selected_targets, selected_paths, selected_digests = {}, set(), set(), set()
    for source in sources:
        if not isinstance(source, dict): fail('Source entry must be an object')
        target = source.get('target')
        if not text(target) or not re.fullmatch(r'[a-z0-9_-]+(/[A-Za-z0-9_.-]+)?',target) or target in selected_targets:
            fail('Source targets must be unique canonical audit targets')
        path = (manifest_path.parent / source['path']).resolve()
        if path in selected_paths: fail('The same source map cannot be relabeled as two targets')
        selected_paths.add(path);selected_targets.add(target)
        doc, digest = read(path)
        content_digest = hashlib.sha256(json.dumps(doc,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()
        if content_digest in selected_digests: fail('Identical source content cannot be relabeled as two targets')
        selected_digests.add(content_digest)
        for field in ['target','source_target','audit_target']:
            if field in doc and doc[field] != target: fail('Source target contradicts manifest')
        if 'audit_date' in doc and doc['audit_date'] != day: fail('Source audit date contradicts manifest')
        if doc.get('version') != 'scoutflo-topology-export/v1': fail('Only per-target topology export v1 is accepted')
        generated = stamp(doc.get('generated_at'),day)
        cluster = doc.get('cluster',{})
        if not isinstance(cluster,dict):fail('Invalid cluster metadata')
        declaration = source.get('collection', {})
        captured = doc.get('collection')
        if not isinstance(declaration, dict) or (captured is not None and not isinstance(captured, dict)):
            fail('Invalid collection metadata')
        if captured is not None and declaration:
            for field in ['status','scope','observed_at']:
                if declaration.get(field) != captured.get(field): fail('Source collection contradicts manifest')
        collection = captured if captured is not None else declaration
        status, scope = collection.get('status','unknown'), collection.get('scope','unknown')
        if status not in {'complete','partial','blocked','unknown'} or scope not in {'target','subset','unknown'}: fail('Invalid source collection state')
        if status == 'complete' and scope != 'target': fail('Complete collection requires target scope')
        if status in {'complete','partial'}:
            observed=stamp(collection.get('observed_at'),day)
            if observed!=generated:fail('Collection timestamp must match source map generation')
        source_maps.append(dict(target=target,sha256=digest,generated_at=generated,collection=dict(status=status,scope=scope),cluster=cluster))
        for plural, kind in [('services','service'),('resources','resource')]:
            if not isinstance(doc.get(plural),list): fail('Source map services/resources must be arrays')
            for entity in doc[plural]:
                key=endpoint(dict(target=target,entity_type=kind,name=entity.get('name')))
                if key in by_key: fail('Duplicate entity identity inside a source map')
                attrs=entity.get('attributes',{})
                if not isinstance(attrs,dict):fail('Invalid entity attributes')
                if cluster.get('cluster_id') and attrs.get('cluster_id') and cluster['cluster_id']!=attrs['cluster_id']:
                    fail('Entity cluster identity contradicts source map')
                row=dict(id=identifier(key),target=target,entity_type=kind,name=key[2],source=entity)
                by_key[key]=row;entities.append(row)
        edges=[]
        for field in ['relationships','edges']:
            group=doc.get(field,[])
            if not isinstance(group,list):fail('Source relationships must be an array')
            edges.extend((field,edge) for edge in group)
        def local_endpoint(value):
            if text(value):
                matches=[(target,kind,value) for kind in ['service','resource'] if (target,kind,value) in by_key]
                if len(matches)!=1:fail('Legacy relationship endpoint is absent or ambiguous')
                return matches[0]
            if not isinstance(value,dict):fail('Invalid source relationship endpoint')
            if 'target' in value and value['target']!=target:fail('Source relationship crosses its declared target')
            return endpoint(dict(value,target=target))
        for field,edge in edges:
            a=local_endpoint(edge['from']);b=local_endpoint(edge['to'])
            if a not in by_key or b not in by_key:fail('Source relationship references an absent entity')
            relation=edge.get('relation',edge.get('type'))
            if 'relation' in edge and 'type' in edge and edge['relation']!=edge['type']:
                fail('Source relationship type contradicts relation')
            if not text(relation):fail('Relationship needs a relation')
            # The old observed assertion means live objects, not runtime traffic.
            assertion = edge.get('assertion_type')
            if assertion not in {None,'observed','asserted','inferred'}: fail('Unsupported source assertion type')
            kind = {'observed':'configuration','asserted':'asserted','inferred':'inferred',None:'unknown'}[assertion]
            relationships.append(dict(from_id=identifier(a),to_id=identifier(b),relation=relation,evidence=dict(kind=kind,target=target,observed_at=generated,ref='source-map/'+field,source_sha256=digest),source=edge))
    if len(entities)>50000:fail('Composition exceeds 50000 entities; narrow the selected maps')
    for link in manifest.get('links',[]):
        a,b=endpoint(link['from']),endpoint(link['to'])
        if a not in by_key or b not in by_key:fail('Reviewed cross-map link references an absent entity')
        relation=link.get('relation')
        if not text(relation):fail('Reviewed link needs a relation')
        proof_path=(manifest_path.parent/link['evidence_file']).resolve()
        proof,digest=read(proof_path)
        if proof.get('schema')!='scoutflo-topology-observation/v1' or proof.get('audit_date')!=day:fail('Reviewed link requires a current typed observation')
        kind=proof.get('kind')
        if kind not in {'configuration','observed-traffic','asserted'}:fail('Unsupported link evidence kind')
        observed=stamp(proof.get('observed_at'),day)
        if proof.get('target') not in {a[0],b[0]} or endpoint(proof.get('from'))!=a or endpoint(proof.get('to'))!=b or proof.get('relation')!=relation or not text(proof.get('ref')):
            fail('Reviewed link evidence does not match its endpoints, target and relation')
        if kind=='observed-traffic' and proof.get('observation_type') not in {'trace','flow-log','request-log','delivery-receipt'}:
            fail('Traffic evidence requires a trace, flow/request log or delivery receipt')
        relationships.append(dict(from_id=identifier(a),to_id=identifier(b),relation=relation,evidence=dict(kind=kind,target=proof['target'],observed_at=observed,ref=proof['ref'],source_sha256=digest)))
    for link in manifest.get('unresolved_links',[]):
        a=endpoint(link['from'])
        if a not in by_key or not text(link.get('reason')):fail('Unresolved link needs an existing source and a reason')
        unresolved.append(dict(from_id=identifier(a),reason=link['reason'],destination_status='unresolved'))
    return dict(schema='scoutflo-estate-topology/v1',audit_date=day,generated_at=dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),import_ready=False,
                scope='selected-local-maps',source_maps=source_maps,entities=entities,relationships=relationships,unresolved_links=unresolved,
                completeness='complete-within-selected-maps' if all(s['collection']==dict(status='complete',scope='target') for s in source_maps) and not unresolved else 'partial-or-unknown',
                limitations=['Configured relationships do not prove traffic or delivery.','Repeated names, private addresses and endpoint strings are never merged automatically.','This local composition is not a Scoutflo server topology import.'])

def write_atomic(path,content):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.estate-topology-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as stream:stream.write(content)
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args()
    # Distinct local filename prevents accidental replacement of importable maps.
    if args.output.name!='estate-topology.json':fail('Output must be named estate-topology.json')
    result=compose(args.manifest.resolve())
    write_atomic(args.output,json.dumps(result,indent=2,allow_nan=False)+'\n')
    counts={k:sum(x['evidence']['kind']==k for x in result['relationships']) for k in ['configuration','observed-traffic','asserted','inferred','unknown']}
    report='# Selected estate topology\n\n'+f"{len(result['source_maps'])} maps; {len(result['entities'])} distinct scoped entities. Completeness: {result['completeness']}.\n\n"+f"Relationships: {counts['configuration']} configured, {counts['observed-traffic']} observed traffic, {counts['asserted']} asserted, {counts['inferred']} inferred, {counts['unknown']} unknown. Unresolved destinations: {len(result['unresolved_links'])}.\n\n"+'\n'.join('- '+x for x in result['limitations'])+'\n'
    def cell(value):return html.escape(str(value)).replace('|','\\|').replace('\n',' ')
    report+='\n| Target | Collection | Source generation |\n| --- | --- | --- |\n'
    for source in result['source_maps']:
        report+=f"| {cell(source['target'])} | {cell(source['collection']['status'])}/{cell(source['collection']['scope'])} | {cell(source['generated_at'])} |\n"
    names={x['id']:x['target']+' / '+x['name'] for x in result['entities']}
    report+='\n| From | Relation | To | Evidence |\n| --- | --- | --- | --- |\n'
    for link in result['relationships'][:1000]:
        report+=f"| {cell(names[link['from_id']])} | {cell(link['relation'])} | {cell(names[link['to_id']])} | {cell(link['evidence']['kind'])} |\n"
    if len(result['relationships'])>1000:report+='\nFirst 1,000 relationships shown; the JSON retains every selected link.\n'
    for link in result['unresolved_links']:
        report+='\n- Unresolved from '+cell(names[link['from_id']])+': '+cell(link['reason'])+'\n'
    write_atomic(args.output.with_suffix('.md'),report)
    print(f"ESTATE-TOPOLOGY-OK maps={len(result['source_maps'])} entities={len(result['entities'])} links={len(result['relationships'])} completeness={result['completeness']}")

if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError) as error:
        raise SystemExit('ESTATE-TOPOLOGY-ERROR: '+str(error))
