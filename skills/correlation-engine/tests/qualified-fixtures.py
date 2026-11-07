"""Give legacy synthetic positive fixtures explicit identity/collection proof.

Only the regression suites call this. Production never infers identity from names.
The separate evidence-boundary suite deliberately does not use this helper.
"""
import json
import sys
from pathlib import Path

root, day = Path(sys.argv[1]), sys.argv[2]
stamp = day + 'T00:00:00Z'
collection = dict(status='complete', scope='target', observed_at=stamp)
targets = set()
for p in list(root.glob(f'*/{day}/findings.json')) + list(root.glob(f'*/*/{day}/findings.json')):
    target = str(p.parent.parent.relative_to(root))
    if target.split('/')[0] in {'all', 'doctor', 'cost', 'cost-analysis', 'alert-fatigue'}:
        continue
    original = p.read_text()
    doc = json.loads(original); doc.update(run_date=day, generated_at=stamp, collection=collection)
    doc.setdefault("target",target)
    for f in doc['findings']:
        f['correlation_bindings'] = [dict(affected=name, service_identity=dict(kind='kubernetes', cluster_id='cluster-fixture', namespace='shop', service_name=name), evidence=dict(target=target, observed_at=stamp, ref='fixture/service-selector')) for name in f.get('affected', [])]
    if doc != json.loads(original):
        p.write_text(json.dumps(doc))
    inv = p.with_name('inventory.json')
    if not inv.exists():
        inv.write_text(json.dumps(dict(items=[])))
for p in list(root.glob(f'*/{day}/inventory.json')) + list(root.glob(f'*/*/{day}/inventory.json')):
    target = str(p.parent.parent.relative_to(root))
    if target.split('/')[0] in {'all', 'doctor', 'cost', 'cost-analysis', 'alert-fatigue'}:
        continue
    targets.add(target)
    original = p.read_text()
    doc = json.loads(original); doc.update(schema="scoutflo-inventory/v1", generated_at=stamp, collection=collection)
    doc.setdefault("target",target)
    for item in doc.get('items', []):
        if item.get('covers'):
            item.update(service_identity=dict(kind='kubernetes', cluster_id='cluster-fixture', namespace='shop', service_name=item['covers']), identity_evidence=dict(target=target, observed_at=stamp, ref='fixture/monitor-selector'))
    if doc != json.loads(original):
        p.write_text(json.dumps(doc))
(root / 'coverage-assessment.json').write_text(json.dumps(dict(schema='scoutflo-coverage-assessment/v1', audit_date=day, expected_targets=sorted(targets))))
